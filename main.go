package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
)



func main() {
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



func buildPatches(usernameWithoutDomain string, rawObject []byte) []map[string]interface{} {
	patches := []map[string]interface{}{}
	var obj map[string]interface{}
	if err := json.Unmarshal(rawObject, &obj); err == nil {
		spec, _ := obj["spec"].(map[string]interface{})

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
	}

	return patches
}
