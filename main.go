package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// GPUResourceEntry defines the CPU and memory allocation for a specific GPU count.
type GPUResourceEntry struct {
	GPUs   int    `json:"gpus"`
	CPU    string `json:"cpu"`
	Memory string `json:"memory"`
}

// gpuResourceConfig maps instance-type → list of GPU resource entries.
type gpuResourceConfig map[string][]GPUResourceEntry

var (
	gpuConfig   gpuResourceConfig
	gpuConfigMu sync.RWMutex
)

func getGPUConfig() gpuResourceConfig {
	gpuConfigMu.RLock()
	defer gpuConfigMu.RUnlock()
	return gpuConfig
}

func setGPUConfig(cfg gpuResourceConfig) {
	gpuConfigMu.Lock()
	defer gpuConfigMu.Unlock()
	gpuConfig = cfg
}

// parseGPUConfigFromConfigMap extracts the gpu resource config from a ConfigMap's
// "config.json" data key.
func parseGPUConfigFromConfigMap(cm *corev1.ConfigMap) (gpuResourceConfig, error) {
	data, ok := cm.Data["config.json"]
	if !ok {
		return nil, fmt.Errorf("ConfigMap %s/%s missing 'config.json' key", cm.Namespace, cm.Name)
	}
	var cfg gpuResourceConfig
	if err := json.Unmarshal([]byte(data), &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config.json: %w", err)
	}
	return cfg, nil
}

// watchConfigMap starts a watch on the GPU resource ConfigMap and updates the
// in-memory config on changes. Blocks until ctx is cancelled.
func watchConfigMap(ctx context.Context, clientset kubernetes.Interface, namespace, name string) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		// Initial load
		cm, err := clientset.CoreV1().ConfigMaps(namespace).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			log.Printf("[gpu-config] WARNING: cannot read ConfigMap %s/%s: %v", namespace, name, err)
		} else {
			if cfg, err := parseGPUConfigFromConfigMap(cm); err != nil {
				log.Printf("[gpu-config] WARNING: %v", err)
			} else {
				setGPUConfig(cfg)
				log.Printf("[gpu-config] Loaded %d instance types from ConfigMap", len(cfg))
			}
		}

		// Watch for changes
		watcher, err := clientset.CoreV1().ConfigMaps(namespace).Watch(ctx, metav1.ListOptions{
			FieldSelector: "metadata.name=" + name,
		})
		if err != nil {
			log.Printf("[gpu-config] WARNING: cannot watch ConfigMap: %v (will retry)", err)
			continue
		}

		for event := range watcher.ResultChan() {
			if event.Type == watch.Modified || event.Type == watch.Added {
				if cm, ok := event.Object.(*corev1.ConfigMap); ok {
					if cfg, err := parseGPUConfigFromConfigMap(cm); err != nil {
						log.Printf("[gpu-config] WARNING: %v", err)
					} else {
						setGPUConfig(cfg)
						log.Printf("[gpu-config] Reloaded %d instance types from ConfigMap", len(cfg))
					}
				}
			}
			if event.Type == watch.Deleted {
				log.Printf("[gpu-config] WARNING: ConfigMap deleted, clearing GPU config")
				setGPUConfig(nil)
			}
		}
		log.Printf("[gpu-config] Watch ended, restarting...")
	}
}

func main() {
	configMapName := os.Getenv("GPU_CONFIGMAP_NAME")
	if configMapName == "" {
		configMapName = "gpu-instance-resources"
	}
	configMapNamespace := os.Getenv("GPU_CONFIGMAP_NAMESPACE")
	if configMapNamespace == "" {
		configMapNamespace = "jupyter-k8s-system"
	}

	// Set up in-cluster Kubernetes client for ConfigMap watching
	config, err := rest.InClusterConfig()
	if err != nil {
		log.Printf("[gpu-config] WARNING: cannot create in-cluster config: %v (GPU resource patching disabled)", err)
	} else {
		clientset, err := kubernetes.NewForConfig(config)
		if err != nil {
			log.Printf("[gpu-config] WARNING: cannot create clientset: %v (GPU resource patching disabled)", err)
		} else {
			ctx := context.Background()
			go watchConfigMap(ctx, clientset, configMapNamespace, configMapName)
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", mutateHandler)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })

	cert, err := tls.LoadX509KeyPair("/certs/tls.crt", "/certs/tls.key")
	if err != nil {
		log.Fatalf("Failed to load certs: %v", err)
	}

	server := &http.Server{
		Addr:    ":8443",
		Handler: mux,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{cert},
		},
	}
	log.Println("Starting hyperpod-spaces-user-webhook on :8443")
	log.Fatal(server.ListenAndServeTLS("", ""))
}

func mutateHandler(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read body", 400)
		return
	}

	var review admissionv1.AdmissionReview
	if err := json.Unmarshal(body, &review); err != nil {
		http.Error(w, "unmarshal", 400)
		return
	}

	response := admit(review.Request)
	review.Response = response
	review.Response.UID = review.Request.UID

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(review)
}

func admit(req *admissionv1.AdmissionRequest) *admissionv1.AdmissionResponse {
	if req.Operation != admissionv1.Create && req.Operation != admissionv1.Update {
		return &admissionv1.AdmissionResponse{Allowed: true}
	}

	if strings.HasPrefix(req.UserInfo.Username, "system:") {
		log.Printf("Allowing system user: %s", req.UserInfo.Username)
		return &admissionv1.AdmissionResponse{Allowed: true}
	}

	username := req.UserInfo.Username
	if idx := strings.LastIndex(username, "-"); idx != -1 {
		username = username[:idx] + "@" + username[idx+1:]
	}
	log.Printf("Processing workspace from user: %s", username)

	patches := buildPatches(username, req.Object.Raw)

	patchBytes, _ := json.Marshal(patches)
	patchType := admissionv1.PatchTypeJSONPatch

	return &admissionv1.AdmissionResponse{
		Allowed:   true,
		Patch:     patchBytes,
		PatchType: &patchType,
	}
}

// lookupGPUResources finds the CPU/memory allocation for a given instance type
// and GPU count. Returns cpu, memory, found.
func lookupGPUResources(instanceType string, gpuCount int) (cpu string, memory string, found bool) {
	cfg := getGPUConfig()
	if cfg == nil {
		return "", "", false
	}
	entries, ok := cfg[instanceType]
	if !ok {
		return "", "", false
	}
	for _, entry := range entries {
		if entry.GPUs == gpuCount {
			return entry.CPU, entry.Memory, true
		}
	}
	return "", "", false
}

func buildPatches(usernameWithoutDomain string, rawObject []byte) []map[string]interface{} {
	patches := []map[string]interface{}{}
	var obj map[string]interface{}
	if err := json.Unmarshal(rawObject, &obj); err != nil {
		return patches
	}

	spec, _ := obj["spec"].(map[string]interface{})

	// --- Env patch: inject SPACES_WEBHOOK_USERNAME ---
	envList, _ := spec["env"].([]interface{})
	newEnv := []map[string]string{}
	for _, e := range envList {
		if em, ok := e.(map[string]interface{}); ok {
			name := fmt.Sprintf("%v", em["name"])
			// Strip any user-supplied SPACES_WEBHOOK_USERNAME — the webhook
			// is the sole authority for this value.
			if name == "SPACES_WEBHOOK_USERNAME" {
				log.Printf("Stripping user-supplied SPACES_WEBHOOK_USERNAME from env")
				continue
			}
			newEnv = append(newEnv, map[string]string{"name": name, "value": fmt.Sprintf("%v", em["value"])})
		}
	}
	newEnv = append(newEnv,
		map[string]string{"name": "SPACES_WEBHOOK_USERNAME", "value": usernameWithoutDomain},
	)
	patches = append(patches, map[string]interface{}{
		"op":    "add",
		"path":  "/spec/env",
		"value": newEnv,
	})

	// --- GPU resource patch: set CPU/memory based on instance type + GPU count ---
	patches = append(patches, buildGPUResourcePatches(spec)...)

	return patches
}

// buildGPUResourcePatches checks if the workspace requests GPUs and has a node
// selector for instance type. If both are present and a matching config entry
// exists, it returns patches to set the CPU and memory resources.
func buildGPUResourcePatches(spec map[string]interface{}) []map[string]interface{} {
	var patches []map[string]interface{}

	// Extract GPU count from spec.resources.limits["nvidia.com/gpu"]
	gpuCount := extractGPUCount(spec)
	if gpuCount == 0 {
		return nil
	}

	// Extract instance type from spec.nodeSelector["beta.kubernetes.io/instance-type"]
	instanceType := extractInstanceType(spec)
	if instanceType == "" {
		log.Printf("[gpu-resources] GPU requested (%d) but no instance-type node selector found", gpuCount)
		return nil
	}

	// Look up the resource allocation
	cpu, memory, found := lookupGPUResources(instanceType, gpuCount)
	if !found {
		log.Printf("[gpu-resources] No config entry for instance-type=%s gpus=%d", instanceType, gpuCount)
		return nil
	}

	log.Printf("[gpu-resources] Patching resources for instance-type=%s gpus=%d: cpu=%s memory=%s", instanceType, gpuCount, cpu, memory)

	// Build the resources patch. We set both requests and limits to the same
	// values to guarantee the pod gets exactly what it needs on the GPU node.
	resources := map[string]interface{}{
		"requests": map[string]interface{}{
			"cpu":            cpu,
			"memory":         memory,
			"nvidia.com/gpu": strconv.Itoa(gpuCount),
		},
		"limits": map[string]interface{}{
			"cpu":            cpu,
			"memory":         memory,
			"nvidia.com/gpu": strconv.Itoa(gpuCount),
		},
	}

	patches = append(patches, map[string]interface{}{
		"op":    "add",
		"path":  "/spec/resources",
		"value": resources,
	})

	return patches
}

// extractGPUCount reads the nvidia.com/gpu value from spec.resources.limits
// or spec.resources.requests.
func extractGPUCount(spec map[string]interface{}) int {
	resources, _ := spec["resources"].(map[string]interface{})
	if resources == nil {
		return 0
	}

	// Check limits first, then requests
	for _, key := range []string{"limits", "requests"} {
		section, _ := resources[key].(map[string]interface{})
		if section == nil {
			continue
		}
		gpuVal, ok := section["nvidia.com/gpu"]
		if !ok {
			continue
		}
		switch v := gpuVal.(type) {
		case float64:
			return int(v)
		case string:
			if n, err := strconv.Atoi(v); err == nil {
				return n
			}
		}
	}
	return 0
}

// extractInstanceType reads the beta.kubernetes.io/instance-type value from
// spec.nodeSelector.
func extractInstanceType(spec map[string]interface{}) string {
	nodeSelector, _ := spec["nodeSelector"].(map[string]interface{})
	if nodeSelector == nil {
		return ""
	}
	if v, ok := nodeSelector["beta.kubernetes.io/instance-type"]; ok {
		return fmt.Sprintf("%v", v)
	}
	// Also check the newer label
	if v, ok := nodeSelector["node.kubernetes.io/instance-type"]; ok {
		return fmt.Sprintf("%v", v)
	}
	return ""
}
