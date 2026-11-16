package boundary_test

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"proxima.local/mihomo-provider/boundary"
)

func TestRootCapabilityFailsClosedAcrossLifecycle(t *testing.T) {
	if _, err := boundary.ReadFile("provider"); !errors.Is(err, boundary.ErrUnconfigured) {
		t.Fatalf("unconfigured read: %v", err)
	}
	root := t.TempDir()
	if err := boundary.ConfigureRoot(root); err != nil {
		t.Fatal(err)
	}
	if err := boundary.ConfigureRoot(t.TempDir()); !errors.Is(err, boundary.ErrConfigured) {
		t.Fatalf("rebind: %v", err)
	}
	if err := boundary.WriteFile("provider", []byte("local")); err != nil {
		t.Fatal(err)
	}
	if err := boundary.CloseRoot(); err != nil {
		t.Fatal(err)
	}
	if _, err := boundary.ReadFile(filepath.Join(root, "provider")); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("closed read: %v", err)
	}
	if err := boundary.ConfigureRoot(root); !errors.Is(err, boundary.ErrConfigured) {
		t.Fatalf("rebind after close: %v", err)
	}
}
