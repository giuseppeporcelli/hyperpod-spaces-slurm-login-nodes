package main

import (
	"testing"
)

func rawObj(specJSON string) []byte {
	return []byte(`{"apiVersion":"workspace.jupyter.org/v1alpha1","kind":"Workspace","spec":` + specJSON + `}`)
}

func findPatch(patches []map[string]interface{}, path string) map[string]interface{} {
	for _, p := range patches {
		if p["path"] == path {
			return p
		}
	}
	return nil
}

func findEnv(envs []map[string]string, name string) (string, bool) {
	for _, e := range envs {
		if e["name"] == name {
			return e["value"], true
		}
	}
	return "", false
}

// --- buildPatches env tests ---

func TestEnv_AddsWhenMissing(t *testing.T) {
	patches := buildPatches("testuser", rawObj(`{}`))
	p := findPatch(patches, "/spec/env")
	if p == nil {
		t.Fatal("patch not found")
	}
	envs := p["value"].([]map[string]string)

	if v, ok := findEnv(envs, "SPACES_WEBHOOK_USERNAME"); !ok || v != "testuser" {
		t.Errorf("SPACES_WEBHOOK_USERNAME: got %q", v)
	}
}

func TestEnv_PreservesExistingVars(t *testing.T) {
	patches := buildPatches("testuser", rawObj(`{"env":[{"name":"FOO","value":"bar"}]}`))
	p := findPatch(patches, "/spec/env")
	if p == nil {
		t.Fatal("patch not found")
	}
	envs := p["value"].([]map[string]string)

	if v, ok := findEnv(envs, "FOO"); !ok || v != "bar" {
		t.Errorf("FOO not preserved: got %q", v)
	}
	if v, ok := findEnv(envs, "SPACES_WEBHOOK_USERNAME"); !ok || v != "testuser" {
		t.Errorf("SPACES_WEBHOOK_USERNAME: got %q", v)
	}
}

func TestEnv_OnlyOneEnvPatch(t *testing.T) {
	patches := buildPatches("testuser", rawObj(`{"env":[{"name":"X","value":"1"}]}`))
	envPatchCount := 0
	for _, p := range patches {
		if p["path"] == "/spec/env" {
			envPatchCount++
		}
	}
	if envPatchCount != 1 {
		t.Errorf("expected 1 env patch, got %d", envPatchCount)
	}
}

func TestEnv_StripsUserSuppliedWebhookUsername(t *testing.T) {
	patches := buildPatches("realuser", rawObj(`{"env":[{"name":"SPACES_WEBHOOK_USERNAME","value":"malicious"},{"name":"FOO","value":"bar"}]}`))
	p := findPatch(patches, "/spec/env")
	if p == nil {
		t.Fatal("patch not found")
	}
	envs := p["value"].([]map[string]string)

	if v, ok := findEnv(envs, "SPACES_WEBHOOK_USERNAME"); !ok || v != "realuser" {
		t.Errorf("SPACES_WEBHOOK_USERNAME: expected 'realuser', got %q", v)
	}
	if v, ok := findEnv(envs, "FOO"); !ok || v != "bar" {
		t.Errorf("FOO not preserved: got %q", v)
	}
	if len(envs) != 2 {
		t.Errorf("expected 2 env vars, got %d: %v", len(envs), envs)
	}
}

// --- GPU resource patching tests ---

func TestGPU_NoGPURequest_NoPatch(t *testing.T) {
	patches := buildPatches("testuser", rawObj(`{"resources":{"requests":{"cpu":"2","memory":"8Gi"}}}`))
	p := findPatch(patches, "/spec/resources")
	if p != nil {
		t.Error("should not patch resources when no GPU requested")
	}
}

func TestGPU_NoNodeSelector_NoPatch(t *testing.T) {
	patches := buildPatches("testuser", rawObj(`{"resources":{"limits":{"nvidia.com/gpu":"1"}}}`))
	p := findPatch(patches, "/spec/resources")
	if p != nil {
		t.Error("should not patch resources when no node selector present")
	}
}

func TestGPU_NoConfigEntry_NoPatch(t *testing.T) {
	// Set a config that doesn't include the requested instance type
	setGPUConfig(gpuResourceConfig{
		"ml.g5.xlarge": {{GPUs: 1, CPU: "4", Memory: "16Gi"}},
	})
	defer setGPUConfig(nil)

	patches := buildPatches("testuser", rawObj(`{
		"resources":{"limits":{"nvidia.com/gpu":"1"}},
		"nodeSelector":{"beta.kubernetes.io/instance-type":"ml.p4d.24xlarge"}
	}`))
	p := findPatch(patches, "/spec/resources")
	if p != nil {
		t.Error("should not patch resources when instance type not in config")
	}
}

func TestGPU_NoMatchingGPUCount_NoPatch(t *testing.T) {
	setGPUConfig(gpuResourceConfig{
		"ml.g5.12xlarge": {
			{GPUs: 1, CPU: "12", Memory: "48Gi"},
			{GPUs: 4, CPU: "48", Memory: "192Gi"},
		},
	})
	defer setGPUConfig(nil)

	// Request 2 GPUs but config only has entries for 1 and 4
	patches := buildPatches("testuser", rawObj(`{
		"resources":{"limits":{"nvidia.com/gpu":"2"}},
		"nodeSelector":{"beta.kubernetes.io/instance-type":"ml.g5.12xlarge"}
	}`))
	p := findPatch(patches, "/spec/resources")
	if p != nil {
		t.Error("should not patch resources when GPU count not in config entries")
	}
}

func TestGPU_MatchFound_PatchesResources(t *testing.T) {
	setGPUConfig(gpuResourceConfig{
		"ml.g5.12xlarge": {
			{GPUs: 1, CPU: "12", Memory: "48Gi"},
			{GPUs: 2, CPU: "24", Memory: "96Gi"},
			{GPUs: 4, CPU: "48", Memory: "192Gi"},
		},
	})
	defer setGPUConfig(nil)

	patches := buildPatches("testuser", rawObj(`{
		"resources":{"limits":{"nvidia.com/gpu":"2"}},
		"nodeSelector":{"beta.kubernetes.io/instance-type":"ml.g5.12xlarge"}
	}`))
	p := findPatch(patches, "/spec/resources")
	if p == nil {
		t.Fatal("expected /spec/resources patch")
	}

	resources := p["value"].(map[string]interface{})
	requests := resources["requests"].(map[string]interface{})
	limits := resources["limits"].(map[string]interface{})

	if requests["cpu"] != "24" {
		t.Errorf("requests.cpu: expected '24', got %v", requests["cpu"])
	}
	if requests["memory"] != "96Gi" {
		t.Errorf("requests.memory: expected '96Gi', got %v", requests["memory"])
	}
	if requests["nvidia.com/gpu"] != "2" {
		t.Errorf("requests.nvidia.com/gpu: expected '2', got %v", requests["nvidia.com/gpu"])
	}
	if limits["cpu"] != "24" {
		t.Errorf("limits.cpu: expected '24', got %v", limits["cpu"])
	}
	if limits["memory"] != "96Gi" {
		t.Errorf("limits.memory: expected '96Gi', got %v", limits["memory"])
	}
	if limits["nvidia.com/gpu"] != "2" {
		t.Errorf("limits.nvidia.com/gpu: expected '2', got %v", limits["nvidia.com/gpu"])
	}
}

func TestGPU_GPUInRequests_AlsoWorks(t *testing.T) {
	setGPUConfig(gpuResourceConfig{
		"ml.p4d.24xlarge": {
			{GPUs: 8, CPU: "96", Memory: "1152Gi"},
		},
	})
	defer setGPUConfig(nil)

	// GPU specified in requests instead of limits
	patches := buildPatches("testuser", rawObj(`{
		"resources":{"requests":{"nvidia.com/gpu":"8"}},
		"nodeSelector":{"beta.kubernetes.io/instance-type":"ml.p4d.24xlarge"}
	}`))
	p := findPatch(patches, "/spec/resources")
	if p == nil {
		t.Fatal("expected /spec/resources patch")
	}

	resources := p["value"].(map[string]interface{})
	requests := resources["requests"].(map[string]interface{})
	if requests["cpu"] != "96" {
		t.Errorf("requests.cpu: expected '96', got %v", requests["cpu"])
	}
	if requests["memory"] != "1152Gi" {
		t.Errorf("requests.memory: expected '1152Gi', got %v", requests["memory"])
	}
}

func TestGPU_NewerNodeSelectorLabel(t *testing.T) {
	setGPUConfig(gpuResourceConfig{
		"ml.g5.xlarge": {
			{GPUs: 1, CPU: "4", Memory: "16Gi"},
		},
	})
	defer setGPUConfig(nil)

	// Uses node.kubernetes.io/instance-type instead of beta label
	patches := buildPatches("testuser", rawObj(`{
		"resources":{"limits":{"nvidia.com/gpu":"1"}},
		"nodeSelector":{"node.kubernetes.io/instance-type":"ml.g5.xlarge"}
	}`))
	p := findPatch(patches, "/spec/resources")
	if p == nil {
		t.Fatal("expected /spec/resources patch with newer node selector label")
	}
}

func TestGPU_NumericGPUValue(t *testing.T) {
	setGPUConfig(gpuResourceConfig{
		"ml.g5.xlarge": {
			{GPUs: 1, CPU: "4", Memory: "16Gi"},
		},
	})
	defer setGPUConfig(nil)

	// GPU value as a number (JSON unmarshals to float64)
	patches := buildPatches("testuser", rawObj(`{
		"resources":{"limits":{"nvidia.com/gpu":1}},
		"nodeSelector":{"beta.kubernetes.io/instance-type":"ml.g5.xlarge"}
	}`))
	p := findPatch(patches, "/spec/resources")
	if p == nil {
		t.Fatal("expected /spec/resources patch with numeric GPU value")
	}
}

func TestGPU_NilConfig_NoPatch(t *testing.T) {
	setGPUConfig(nil)

	patches := buildPatches("testuser", rawObj(`{
		"resources":{"limits":{"nvidia.com/gpu":"1"}},
		"nodeSelector":{"beta.kubernetes.io/instance-type":"ml.g5.xlarge"}
	}`))
	p := findPatch(patches, "/spec/resources")
	if p != nil {
		t.Error("should not patch resources when config is nil")
	}
}
