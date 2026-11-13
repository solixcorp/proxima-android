package integration

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/resource"
)

func stringParser(buf []byte) (string, error) { return string(buf), nil }

func TestFileVehicleRejectsEscapes(t *testing.T) {
	outside := filepath.Join(t.TempDir(), "secret")
	check(t, os.WriteFile(outside, []byte("private"), 0o600))
	link := testPath(t)
	check(t, os.MkdirAll(filepath.Dir(link), 0o700))
	check(t, os.Symlink(outside, link))
	parent := filepath.Join(filepath.Dir(link), "parent")
	check(t, os.Symlink(filepath.Dir(outside), parent))
	for _, path := range []string{outside, link, filepath.Join(parent, "secret"), "../secret"} {
		vehicle := resource.NewFileVehicle(path)
		buf, _, err := vehicle.Read(context.Background(), utils.HashType{})
		if err == nil || len(buf) != 0 {
			t.Fatalf("escaped read %q: bytes=%q error=%v", path, buf, err)
		}
	}
}

func TestVehicleWriteCannotFollowEscapingParent(t *testing.T) {
	outside := t.TempDir()
	link := filepath.Dir(testPath(t))
	check(t, os.Symlink(outside, link))
	vehicle := resource.NewFileVehicle(filepath.Join(link, "new"))
	if err := vehicle.Write([]byte("escaped")); err == nil {
		t.Fatal("write through escaping directory succeeded")
	}
	if _, err := os.Stat(filepath.Join(outside, "new")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("outside file was created: %v", err)
	}
}

func TestVehicleWriteReplacesFinalSymlinkWithoutTouchingTarget(t *testing.T) {
	outside := filepath.Join(t.TempDir(), "secret")
	check(t, os.WriteFile(outside, []byte("private"), 0o600))
	link := testPath(t)
	check(t, os.MkdirAll(filepath.Dir(link), 0o700))
	check(t, os.Symlink(outside, link))
	vehicle := resource.NewFileVehicle(link)
	check(t, vehicle.Write([]byte("provider")))
	bytes, err := os.ReadFile(outside)
	check(t, err)
	if string(bytes) != "private" {
		t.Fatalf("outside target overwritten: %q", bytes)
	}
	buf, _, err := vehicle.Read(context.Background(), utils.HashType{})
	check(t, err)
	if string(buf) != "provider" {
		t.Fatalf("replacement bytes = %q", buf)
	}
}

func TestFetcherInitialUsesConfinedCache(t *testing.T) {
	path := testPath(t)
	vehicle := resource.NewHTTPVehicle("https://unreachable.invalid", path, "", nil, time.Second, 0)
	check(t, vehicle.Write([]byte("cached")))
	fetcher := resource.NewFetcher("cache", 0, vehicle, nil, stringParser, nil)
	defer fetcher.Close()
	contents, err := fetcher.Initial()
	check(t, err)
	if contents != "cached" {
		t.Fatalf("initial contents = %q", contents)
	}
}

func TestFetcherRejectsInvalidPayloadBeforeCachePublication(t *testing.T) {
	path := testPath(t)
	vehicle := resource.NewHTTPVehicle("https://unreachable.invalid", path, "", nil, time.Second, 0)
	check(t, vehicle.Write([]byte("previous")))
	parseError := errors.New("invalid provider")
	fetcher := resource.NewFetcher("parse", 0, vehicle, nil, func([]byte) (string, error) {
		return "", parseError
	}, nil)
	defer fetcher.Close()
	_, _, err := fetcher.SideUpdate([]byte("broken"))
	if !errors.Is(err, parseError) {
		t.Fatalf("parser error = %v", err)
	}
	buf, err := os.ReadFile(path)
	check(t, err)
	if string(buf) != "previous" {
		t.Fatalf("invalid payload replaced prior cache: %q", buf)
	}
}

func TestFetcherTimestampRefreshCannotEscape(t *testing.T) {
	outside := filepath.Join(t.TempDir(), "secret")
	check(t, os.WriteFile(outside, []byte("private"), 0o600))
	old := time.Unix(1_000_000, 0)
	check(t, os.Chtimes(outside, old, old))
	path := testPath(t)
	vehicle := resource.NewHTTPVehicle("https://unreachable.invalid", path, "", nil, time.Second, 0)
	fetcher := resource.NewFetcher("timestamp", 0, vehicle, nil, stringParser, nil)
	defer fetcher.Close()
	_, _, err := fetcher.SideUpdate([]byte("same"))
	check(t, err)
	check(t, os.Remove(path))
	check(t, os.Symlink(outside, path))
	_, _, err = fetcher.SideUpdate([]byte("same"))
	if err == nil {
		t.Fatal("timestamp refresh through escaping link succeeded")
	}
	info, err := os.Stat(outside)
	check(t, err)
	if !info.ModTime().Equal(old) {
		t.Fatalf("outside modification time changed: %v", info.ModTime())
	}
}

func TestFileFetcherAutomaticallyReloadsConfinedFile(t *testing.T) {
	path := testPath(t)
	vehicle := resource.NewFileVehicle(path)
	check(t, vehicle.Write([]byte("first")))
	updates := make(chan string, 4)
	fetcher := resource.NewFetcher("watch", 0, vehicle, nil, stringParser, func(value string) {
		updates <- value
	})
	defer fetcher.Close()
	_, err := fetcher.Initial()
	check(t, err)
	if first := <-updates; first != "first" {
		t.Fatalf("initial = %q", first)
	}
	check(t, vehicle.Write([]byte("second")))
	select {
	case got := <-updates:
		if got != "second" {
			t.Fatalf("reloaded = %q", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("file provider did not reload")
	}
}
