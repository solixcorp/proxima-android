package integration

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/resource"
)

func TestVehicleConfinementDuringSymlinkReplacement(t *testing.T) {
	base := filepath.Dir(testPath(t))
	check(t, os.MkdirAll(filepath.Join(base, "safe"), 0o700))
	check(t, os.WriteFile(filepath.Join(base, "safe", "data"), []byte("public"), 0o600))
	outside := t.TempDir()
	check(t, os.WriteFile(filepath.Join(outside, "data"), []byte("private"), 0o600))
	slot := filepath.Join(base, "slot")
	check(t, os.Symlink("safe", slot))
	reader := resource.NewFileVehicle(filepath.Join(slot, "data"))
	writer := resource.NewFileVehicle(filepath.Join(slot, "cache"))
	initial, _, err := reader.Read(context.Background(), utils.HashType{})
	check(t, err)
	if string(initial) != "public" {
		t.Fatalf("safe baseline = %q", initial)
	}
	done := make(chan struct{})
	stopped := make(chan error, 1)
	go func() {
		for {
			for _, target := range []string{outside, "safe"} {
				select {
				case <-done:
					stopped <- nil
					return
				default:
				}
				next := filepath.Join(base, "next")
				if err := os.Symlink(target, next); err != nil {
					stopped <- err
					return
				}
				if err := os.Rename(next, slot); err != nil {
					stopped <- err
					return
				}
			}
		}
	}()
	defer func() {
		close(done)
		check(t, <-stopped)
	}()
	for range 200 {
		buf, _, err := reader.Read(context.Background(), utils.HashType{})
		if err == nil && string(buf) != "public" {
			t.Fatalf("read escaped during replacement: %q", buf)
		}
		// Both a confined successful write and a rejected symlink are allowed.
		// The independent outside-file assertion checks the write's boundary.
		if err := writer.Write([]byte("cache")); err != nil {
			continue
		}
	}
	if _, err := os.Stat(filepath.Join(outside, "cache")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("write escaped during replacement: %v", err)
	}
}
