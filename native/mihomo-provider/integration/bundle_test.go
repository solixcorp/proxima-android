package integration

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/resource"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/rules/bundle"
)

// sevenzip v1.6.4 testdata/t0.7z, containing bar="bar\n" and foo="foo\n".
// Copyright (c) 2020 Matt Dainty; see testdata/LICENSE.sevenzip.
const storedArchive = "N3q8ryccAASgR6WICAAAAAAAAABmAAAAAAAAAN2R8/FiYXIKZm9vCgEEBgACCQQEAAcLAgABAQABAQAMBAQACAoB6bOiBKhlMn4AAAUCGQUAAAAAABERAGIAYQByAAAAZgBvAG8AAAAZAgAAFBIBAACFM3PyY9YBAFgCcvJj1gEVCgEAIICkgSCApIEAAA=="

func TestFetcherExtractsRealBundleIntoConfinedCache(t *testing.T) {
	archive, err := base64.StdEncoding.DecodeString(storedArchive)
	check(t, err)
	path := filepath.Join(rootDir, "BundleMRS.7z")
	check(t, os.WriteFile(path, archive, 0o600))
	t.Cleanup(func() { check(t, os.Remove(path)) })
	vehicle := resource.NewHTTPVehicle("https://unreachable.invalid", testPath(t), "", nil, time.Second, 0)
	fetcher := resource.NewFetcher("bundle", 0, vehicle, bundle.MakeBundleFile("foo"), stringParser, nil)
	defer fetcher.Close()
	value, err := fetcher.Initial()
	check(t, err)
	cache, err := os.ReadFile(vehicle.Path())
	check(t, err)
	if value != "foo\n" || string(cache) != "foo\n" {
		t.Fatalf("bundle value=%q cache=%q", value, cache)
	}
}

func TestBundleCannotReadEscapingArchive(t *testing.T) {
	archive, err := base64.StdEncoding.DecodeString(storedArchive)
	check(t, err)
	outside := filepath.Join(t.TempDir(), "bundle")
	check(t, os.WriteFile(outside, archive, 0o600))
	path := filepath.Join(rootDir, "BundleMRS.7z")
	check(t, os.Symlink(outside, path))
	t.Cleanup(func() { check(t, os.Remove(path)) })
	file, err := bundle.Open("foo")
	if err == nil {
		file.Close()
		t.Fatal("bundle opened an escaping archive")
	}
}

func TestBundleReadsConfinedMultipleVolumes(t *testing.T) {
	archive, err := base64.StdEncoding.DecodeString(storedArchive)
	check(t, err)
	oldName := C.BundleMRSName
	C.BundleMRSName = "split.7z.001"
	defer func() { C.BundleMRSName = oldName }()
	first := filepath.Join(rootDir, "split.7z.001")
	second := filepath.Join(rootDir, "split.7z.002")
	check(t, os.WriteFile(first, archive[:50], 0o600))
	check(t, os.WriteFile(second, archive[50:], 0o600))
	t.Cleanup(func() {
		check(t, os.Remove(first))
		check(t, os.Remove(second))
	})
	vehicle := resource.NewHTTPVehicle("https://unreachable.invalid", testPath(t), "", nil, time.Second, 0)
	fetcher := resource.NewFetcher("volumes", 0, vehicle, bundle.MakeBundleFile("bar"), stringParser, nil)
	defer fetcher.Close()
	value, err := fetcher.Initial()
	check(t, err)
	if value != "bar\n" {
		t.Fatalf("multiple-volume extraction = %q", value)
	}
}
