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
	"sort"
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

// CPUInstanceEntry defines a CPU instance type with its resource capacity.
// The webhook selects the smallest instance type whose vCPUs and memory are
// >= the workspace's requested resources.
type CPUInstanceEntry struct {
	InstanceType string `json:"instanceType"`
	VCPUs        int    `json:"vcpus"`
	MemoryGiB    int    `json:"memoryGiB"`
}

var (
	gpuConfig        gpuResourceConfig
	gpuConfigMu      sync.RWMutex
	gpuInstanceTypes   []string // instance types that should be avoided by non-GPU workloads
	gpuInstanceTypesMu sync.RWMutex
	cpuInstanceTypes   []CPUInstanceEntry // sorted by vcpus then memory
	cpuInstanceTypesMu sync.RWMutex
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

func getGPUInstanceTypes() []string {
	gpuInstanceTypesMu.RLock()
	defer gpuInstanceTypesMu.RUnlock()
	return gpuInstanceTypes
}

func setGPUInstanceTypes(types []string) {
	gpuInstanceTypesMu.Lock()
	defer gpuInstanceTypesMu.Unlock()
	gpuInstanceTypes = types
}

func getCPUInstanceTypes() []CPUInstanceEntry {
	cpuInstanceTypesMu.RLock()
	defer cpuInstanceTypesMu.RUnlock()
	return cpuInstanceTypes
}

func setCPUInstanceTypes(entries []CPUInstanceEntry) {
	cpuInstanceTypesMu.Lock()
	defer cpuInstanceTypesMu.Unlock()
	// Sort by vcpus first, then memory, so lookup can find smallest fit
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].VCPUs != entries[j].VCPUs {
			return entries[i].VCPUs < entries[j].VCPUs
		}
		return entries[i].MemoryGiB < entries[j].MemoryGiB
	})
	cpuInstanceTypes = entries
}

// parseGPUInstanceTypesFromConfigMap extracts the list of GPU instance types
// from a ConfigMap's "instance-types.json" data key.
func parseGPUInstanceTypesFromConfigMap(cm *corev1.ConfigMap) ([]string, error) {
	data, ok := cm.Data["instance-types.json"]
	if !ok {
		return nil, fmt.Errorf("ConfigMap %s/%s missing 'instance-types.json' key", cm.Namespace, cm.Name)
	}
	var types []string
	if err := json.Unmarshal([]byte(data), &types); err != nil {
		return nil, fmt.Errorf("failed to parse instance-types.json: %w", err)
	}
	return types, nil
}

// watchGPUInstanceTypesConfigMap watches the GPU instance types ConfigMap and
// updates the in-memory list on changes. Blocks until ctx is cancelled.
func watchGPUInstanceTypesConfigMap(ctx context.Context, clientset kubernetes.Interface, namespace, name string) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		// Initial load
		cm, err := clientset.CoreV1().ConfigMaps(namespace).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			log.Printf("[anti-affinity] WARNING: cannot read ConfigMap %s/%s: %v", namespace, name, err)
		} else {
			if types, err := parseGPUInstanceTypesFromConfigMap(cm); err != nil {
				log.Printf("[anti-affinity] WARNING: %v", err)
			} else {
				setGPUInstanceTypes(types)
				log.Printf("[anti-affinity] Loaded %d GPU instance types from ConfigMap", len(types))
			}
		}

		// Watch for changes
		watcher, err := clientset.CoreV1().ConfigMaps(namespace).Watch(ctx, metav1.ListOptions{
			FieldSelector: "metadata.name=" + name,
		})
		if err != nil {
			log.Printf("[anti-affinity] WARNING: cannot watch ConfigMap: %v (will retry)", err)
			continue
		}

		for event := range watcher.ResultChan() {
			if event.Type == watch.Modified || event.Type == watch.Added {
				if cm, ok := event.Object.(*corev1.ConfigMap); ok {
					if types, err := parseGPUInstanceTypesFromConfigMap(cm); err != nil {
						log.Printf("[anti-affinity] WARNING: %v", err)
					} else {
						setGPUInstanceTypes(types)
						log.Printf("[anti-affinity] Reloaded %d GPU instance types from ConfigMap", len(types))
					}
				}
			}
			if event.Type == watch.Deleted {
				log.Printf("[anti-affinity] WARNING: ConfigMap deleted, clearing GPU instance types")
				setGPUInstanceTypes(nil)
			}
		}
		log.Printf("[anti-affinity] Watch ended, restarting...")
	}
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

// parseCPUInstanceTypesFromConfigMap extracts the CPU instance types config from
// a ConfigMap's "config.json" data key.
func parseCPUInstanceTypesFromConfigMap(cm *corev1.ConfigMap) ([]CPUInstanceEntry, error) {
	data, ok := cm.Data["config.json"]
	if !ok {
		return nil, fmt.Errorf("ConfigMap %s/%s missing 'config.json' key", cm.Namespace, cm.Name)
	}
	var entries []CPUInstanceEntry
	if err := json.Unmarshal([]byte(data), &entries); err != nil {
		return nil, fmt.Errorf("failed to parse config.json: %w", err)
	}
	return entries, nil
}

// watchCPUInstanceTypesConfigMap watches the CPU instance types ConfigMap and
// updates the in-memory list on changes. Blocks until ctx is cancelled.
func watchCPUInstanceTypesConfigMap(ctx context.Context, clientset kubernetes.Interface, namespace, name string) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		// Initial load
		cm, err := clientset.CoreV1().ConfigMaps(namespace).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			log.Printf("[cpu-instance-types] WARNING: cannot read ConfigMap %s/%s: %v", namespace, name, err)
		} else {
			if entries, err := parseCPUInstanceTypesFromConfigMap(cm); err != nil {
				log.Printf("[cpu-instance-types] WARNING: %v", err)
			} else {
				setCPUInstanceTypes(entries)
				log.Printf("[cpu-instance-types] Loaded %d CPU instance types from ConfigMap", len(entries))
			}
		}

		// Watch for changes
		watcher, err := clientset.CoreV1().ConfigMaps(namespace).Watch(ctx, metav1.ListOptions{
			FieldSelector: "metadata.name=" + name,
		})
		if err != nil {
			log.Printf("[cpu-instance-types] WARNING: cannot watch ConfigMap: %v (will retry)", err)
			continue
		}

		for event := range watcher.ResultChan() {
			if event.Type == watch.Modified || event.Type == watch.Added {
				if cm, ok := event.Object.(*corev1.ConfigMap); ok {
					if entries, err := parseCPUInstanceTypesFromConfigMap(cm); err != nil {
						log.Printf("[cpu-instance-types] WARNING: %v", err)
					} else {
						setCPUInstanceTypes(entries)
						log.Printf("[cpu-instance-types] Reloaded %d CPU instance types from ConfigMap", len(entries))
					}
				}
			}
			if event.Type == watch.Deleted {
				log.Printf("[cpu-instance-types] WARNING: ConfigMap deleted, clearing CPU instance types")
				setCPUInstanceTypes(nil)
			}
		}
		log.Printf("[cpu-instance-types] Watch ended, restarting...")
	}
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

	// Load the name of the GPU instance types ConfigMap for anti-affinity rules
	gpuInstanceTypesConfigMap := os.Getenv("GPU_INSTANCE_TYPES_CONFIGMAP")
	if gpuInstanceTypesConfigMap == "" {
		gpuInstanceTypesConfigMap = "gpu-instance-types"
	}

	// Load the name of the CPU instance types ConfigMap for node selector injection
	cpuInstanceTypesConfigMap := os.Getenv("CPU_INSTANCE_TYPES_CONFIGMAP")
	if cpuInstanceTypesConfigMap == "" {
		cpuInstanceTypesConfigMap = "cpu-instance-types"
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
			go watchGPUInstanceTypesConfigMap(ctx, clientset, configMapNamespace, gpuInstanceTypesConfigMap)
			go watchCPUInstanceTypesConfigMap(ctx, clientset, configMapNamespace, cpuInstanceTypesConfigMap)
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

	// --- CPU instance type patch: inject node selector based on requested vCPUs/memory ---
	if p := buildCPUNodeSelectorPatch(spec); p != nil {
		patches = append(patches, p)
	}

	// --- Anti-affinity patch: prevent non-GPU workloads from landing on GPU nodes ---
	if p := buildAntiAffinityPatch(spec); p != nil {
		patches = append(patches, p)
	}

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

// buildCPUNodeSelectorPatch selects the appropriate CPU instance type based on
// the workspace's requested vCPUs and memory (when no GPUs are requested).
// It finds the smallest configured instance type that satisfies both the vCPU
// and memory requirements, and injects a node.kubernetes.io/instance-type node
// selector. Returns nil if GPUs are requested, no resources are specified, or
// no matching instance type is found.
func buildCPUNodeSelectorPatch(spec map[string]interface{}) map[string]interface{} {
	// Only applies to non-GPU workloads
	if extractGPUCount(spec) > 0 {
		return nil
	}

	// If a node selector for instance type is already set, don't override it
	if extractInstanceType(spec) != "" {
		return nil
	}

	entries := getCPUInstanceTypes()
	if len(entries) == 0 {
		return nil
	}

	// Extract requested CPU and memory
	reqCPU, reqMemGiB := extractRequestedResources(spec)
	if reqCPU == 0 && reqMemGiB == 0 {
		return nil
	}

	// Find the smallest instance type that satisfies both constraints
	for _, entry := range entries {
		if entry.VCPUs >= reqCPU && entry.MemoryGiB >= reqMemGiB {
			log.Printf("[cpu-instance-types] Matched instance type %s (vcpus=%d, memGiB=%d) for request (cpu=%d, mem=%d GiB)",
				entry.InstanceType, entry.VCPUs, entry.MemoryGiB, reqCPU, reqMemGiB)

			// Build or extend the nodeSelector
			nodeSelector := map[string]interface{}{}
			if existing, _ := spec["nodeSelector"].(map[string]interface{}); existing != nil {
				for k, v := range existing {
					nodeSelector[k] = v
				}
			}
			nodeSelector["node.kubernetes.io/instance-type"] = entry.InstanceType

			return map[string]interface{}{
				"op":    "add",
				"path":  "/spec/nodeSelector",
				"value": nodeSelector,
			}
		}
	}

	log.Printf("[cpu-instance-types] No instance type found that satisfies request (cpu=%d, mem=%d GiB)", reqCPU, reqMemGiB)
	return nil
}

// extractRequestedResources reads the vCPU and memory values from
// spec.resources.requests (falling back to limits). Returns vcpus as integer
// cores and memory in GiB.
func extractRequestedResources(spec map[string]interface{}) (vcpus int, memoryGiB int) {
	resources, _ := spec["resources"].(map[string]interface{})
	if resources == nil {
		return 0, 0
	}

	// Check requests first, then limits
	for _, key := range []string{"requests", "limits"} {
		section, _ := resources[key].(map[string]interface{})
		if section == nil {
			continue
		}

		if vcpus == 0 {
			if cpuVal, ok := section["cpu"]; ok {
				vcpus = parseCPUValue(cpuVal)
			}
		}
		if memoryGiB == 0 {
			if memVal, ok := section["memory"]; ok {
				memoryGiB = parseMemoryGiBValue(memVal)
			}
		}
	}
	return vcpus, memoryGiB
}

// parseCPUValue converts a CPU resource value (e.g. "4", "4000m", 4) to integer cores.
func parseCPUValue(val interface{}) int {
	switch v := val.(type) {
	case float64:
		return int(v)
	case string:
		// Handle millicores (e.g. "4000m")
		if strings.HasSuffix(v, "m") {
			if n, err := strconv.Atoi(strings.TrimSuffix(v, "m")); err == nil {
				return n / 1000
			}
		}
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return 0
}

// parseMemoryGiBValue converts a memory resource value (e.g. "24Gi", "24576Mi",
// "25769803776") to integer GiB.
func parseMemoryGiBValue(val interface{}) int {
	switch v := val.(type) {
	case float64:
		// Raw bytes
		return int(v / (1024 * 1024 * 1024))
	case string:
		if strings.HasSuffix(v, "Gi") {
			if n, err := strconv.Atoi(strings.TrimSuffix(v, "Gi")); err == nil {
				return n
			}
		}
		if strings.HasSuffix(v, "Mi") {
			if n, err := strconv.Atoi(strings.TrimSuffix(v, "Mi")); err == nil {
				return n / 1024
			}
		}
		if strings.HasSuffix(v, "Ti") {
			if n, err := strconv.Atoi(strings.TrimSuffix(v, "Ti")); err == nil {
				return n * 1024
			}
		}
		// Plain number = bytes
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return int(n / (1024 * 1024 * 1024))
		}
	}
	return 0
}

// buildAntiAffinityPatch returns a JSON patch that adds a node affinity rule
// to prevent non-GPU workloads from being scheduled on GPU instance types.
// Returns nil if the workload requests GPUs or if no GPU instance types are configured.
func buildAntiAffinityPatch(spec map[string]interface{}) map[string]interface{} {
	instanceTypes := getGPUInstanceTypes()
	if len(instanceTypes) == 0 {
		return nil
	}

	// If the workload requests GPUs, don't add anti-affinity
	if extractGPUCount(spec) > 0 {
		return nil
	}

	log.Printf("[anti-affinity] Non-GPU workload detected, adding node affinity to avoid GPU instance types: %v", instanceTypes)

	// Build a node affinity with requiredDuringSchedulingIgnoredDuringExecution
	// that excludes GPU instance types using NotIn operator.
	affinity := map[string]interface{}{
		"nodeAffinity": map[string]interface{}{
			"requiredDuringSchedulingIgnoredDuringExecution": map[string]interface{}{
				"nodeSelectorTerms": []interface{}{
					map[string]interface{}{
						"matchExpressions": []interface{}{
							map[string]interface{}{
								"key":      "beta.kubernetes.io/instance-type",
								"operator": "NotIn",
								"values":   instanceTypes,
							},
						},
					},
				},
			},
		},
	}

	return map[string]interface{}{
		"op":    "add",
		"path":  "/spec/affinity",
		"value": affinity,
	}
}
