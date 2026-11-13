package main

import (
	"crypto/sha256"
	"fmt"
	"testing"
)

func TestChecksumAndAnchorGate(t *testing.T) {
	src := []byte("package demo\nvar old = 1\n")
	p := patch{Path: "demo.go", Hash: fmt.Sprintf("%x", sha256.Sum256(src)), Edits: []edit{{"old", "protected"}}}
	if _, err := apply(src, p); err != nil {
		t.Fatal(err)
	}
	if _, err := apply(append(src, '\n'), p); err == nil {
		t.Fatal("changed source accepted")
	}
	p.Edits[0].Before = "missing"
	if _, err := apply(src, p); err == nil {
		t.Fatal("missing anchor accepted")
	}
	p.Edits[0].Before = "a"
	if _, err := apply(src, p); err == nil {
		t.Fatal("ambiguous anchor accepted")
	}
}

func TestFullReplacementRemainsChecksumGated(t *testing.T) {
	src := []byte("package old\n")
	p := patch{Path: "tfo.go", Hash: fmt.Sprintf("%x", sha256.Sum256(src)), Replacement: protectedTFO}
	if _, err := apply(src, p); err != nil {
		t.Fatal(err)
	}
	if _, err := apply([]byte("package changed\n"), p); err == nil {
		t.Fatal("full replacement bypassed the source checksum")
	}
}
