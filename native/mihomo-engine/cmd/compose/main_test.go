package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixture(t *testing.T) string {
	t.Helper()
	root := os.Getenv("MIHOMO_ENGINE_TEST_SOURCE")
	if root == "" {
		t.Fatal("MIHOMO_ENGINE_TEST_SOURCE must point to checksum-verified staged core")
	}
	return root
}

func input(t *testing.T, replacements map[string]string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "overlay.json")
	data, err := json.Marshal(overlay{Replace: replacements})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestComposeValidatesSourceAndRejectsConflicts(t *testing.T) {
	root := fixture(t)
	config := filepath.Join(root, "config/config.go")
	executor := filepath.Join(root, "hub/executor/executor.go")
	a := input(t, map[string]string{config: config})
	b := input(t, map[string]string{executor: executor})
	data, err := compose(root, []string{a, b})
	if err != nil {
		t.Fatal(err)
	}
	var got overlay
	if err := json.Unmarshal(data, &got); err != nil || len(got.Replace) != 2 {
		t.Fatalf("bad composition: %v", err)
	}
	if _, err := compose(root, []string{a, a}); err == nil || !strings.Contains(err.Error(), "conflict") {
		t.Fatalf("duplicate mapping accepted: %v", err)
	}
}

func TestComposeRejectsOtherStageMissingFileAndDeletion(t *testing.T) {
	root := fixture(t)
	config := filepath.Join(root, "config/config.go")
	for _, replacements := range []map[string]string{
		{filepath.Join(t.TempDir(), "config.go"): config},
		{config: filepath.Join(t.TempDir(), "missing.go")},
		{config: ""},
		{root + "/config/../config/config.go": config},
		{},
	} {
		if _, err := compose(root, []string{input(t, replacements)}); err == nil {
			t.Fatalf("unsafe overlay accepted: %#v", replacements)
		}
	}
	if _, err := compose(t.TempDir(), nil); err == nil {
		t.Fatal("unverified source accepted")
	}
}

func TestComposeRejectsTamperedPinnedSource(t *testing.T) {
	root := t.TempDir()
	for path := range sourcePins {
		target := filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, []byte("package changed"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := compose(root, nil); err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatalf("tampered core accepted: %v", err)
	}
}

func TestComposeRejectsDuplicateJSONKeysInOneInput(t *testing.T) {
	root := fixture(t)
	config := filepath.Join(root, "config/config.go")
	executor := filepath.Join(root, "hub/executor/executor.go")
	configKey, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	escapedConfigKey := strings.Replace(string(configKey), "/", `\u002f`, 1)
	for name, data := range map[string]string{
		"identical path":    fmt.Sprintf(`{"Replace":{%q:%q,%q:%q}}`, config, config, config, config),
		"conflicting path":  fmt.Sprintf(`{"Replace":{%q:%q,%q:%q}}`, config, config, config, executor),
		"escaped path":      fmt.Sprintf(`{"Replace":{%q:%q,%s:%q}}`, config, config, escapedConfigKey, executor),
		"duplicate Replace": fmt.Sprintf(`{"Replace":{%q:%q},"Replace":{%q:%q}}`, config, config, executor, executor),
		"escaped Replace":   fmt.Sprintf(`{"Replace":{%q:%q},"\u0052eplace":{%q:%q}}`, config, config, executor, executor),
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "duplicate.json")
			if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := compose(root, []string{path}); err == nil || !strings.Contains(err.Error(), "duplicate JSON key") {
				t.Fatalf("duplicate input accepted or wrong rejection: %v", err)
			}
		})
	}
}
