package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"testing"
)

func TestPatchRejectsDifferentSourceBeforeEditing(t *testing.T) {
	source := []byte("package original\n")
	p := patch{path: "upstream.go", hash: fmt.Sprintf("%x", sha256.Sum256(source)), edits: []edit{
		{"original", "patched"},
	}}
	got, err := apply(source, p)
	if err != nil || string(got) != "package patched\n" {
		t.Fatalf("valid patch: %q %v", got, err)
	}
	if _, err := apply([]byte("package changed\n"), p); !errors.Is(err, errSource) {
		t.Fatalf("modified upstream accepted: %v", err)
	}
}

func TestPatchRejectsAmbiguousAnchor(t *testing.T) {
	source := []byte("package original\n// original\n")
	p := patch{path: "upstream.go", hash: fmt.Sprintf("%x", sha256.Sum256(source)), edits: []edit{
		{"original", "patched"},
	}}
	if _, err := apply(source, p); !errors.Is(err, errSource) {
		t.Fatalf("ambiguous patch accepted: %v", err)
	}
}
