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

// --- buildPatches tests ---

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
	if len(patches) != 1 {
		t.Errorf("expected 1 patch, got %d", len(patches))
	}
	if patches[0]["path"] != "/spec/env" {
		t.Errorf("expected /spec/env patch, got %s", patches[0]["path"])
	}
}

func TestEnv_StripsUserSuppliedWebhookUsername(t *testing.T) {
	patches := buildPatches("realuser", rawObj(`{"env":[{"name":"SPACES_WEBHOOK_USERNAME","value":"malicious"},{"name":"FOO","value":"bar"}]}`))
	p := findPatch(patches, "/spec/env")
	if p == nil {
		t.Fatal("patch not found")
	}
	envs := p["value"].([]map[string]string)

	// Should use the webhook-injected value, not the user-supplied one
	if v, ok := findEnv(envs, "SPACES_WEBHOOK_USERNAME"); !ok || v != "realuser" {
		t.Errorf("SPACES_WEBHOOK_USERNAME: expected 'realuser', got %q", v)
	}

	// Should preserve other env vars
	if v, ok := findEnv(envs, "FOO"); !ok || v != "bar" {
		t.Errorf("FOO not preserved: got %q", v)
	}

	// Should only have 2 env vars (FOO + webhook-injected), not 3
	if len(envs) != 2 {
		t.Errorf("expected 2 env vars, got %d: %v", len(envs), envs)
	}
}



