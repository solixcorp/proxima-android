package main

import (
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"testing"
)

func TestEveryPatchRequiresThePinnedCompleteSource(t *testing.T) {
	root := os.Getenv("MIHOMO_ENGINE_TEST_SOURCE")
	if root == "" {
		t.Fatal("verified staged core required")
	}
	for path := range pins {
		t.Run(path, func(t *testing.T) {
			source, err := os.ReadFile(filepath.Join(root, path))
			if err != nil {
				t.Fatal(err)
			}
			result, err := patch(path, source)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := parser.ParseFile(token.NewFileSet(), path, result, parser.AllErrors); err != nil {
				t.Fatal(err)
			}
			if _, err := patch(path, append(source, '\n')); err == nil {
				t.Fatal("changed source accepted")
			}
			if _, err := patch(path, result); err == nil {
				t.Fatal("already patched source accepted")
			}
		})
	}
}
