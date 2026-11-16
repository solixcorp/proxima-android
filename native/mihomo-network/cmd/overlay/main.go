// Command overlay emits source replacements only for the audited source pin.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"go/format"
	"os"
	"path/filepath"
	"strings"
)

type edit struct{ Before, After string }
type patch struct {
	Path, Hash  string
	Edits       []edit
	Replacement string
}

func apply(source []byte, p patch) ([]byte, error) {
	if fmt.Sprintf("%x", sha256.Sum256(source)) != p.Hash {
		return nil, fmt.Errorf("pinned source checksum mismatch: %s", p.Path)
	}
	if p.Replacement != "" {
		return format.Source([]byte(p.Replacement))
	}
	text := string(source)
	for _, e := range p.Edits {
		if strings.Count(text, e.Before) != 1 {
			return nil, fmt.Errorf("pinned source anchor mismatch: %s", p.Path)
		}
		text = strings.Replace(text, e.Before, e.After, 1)
	}
	if len(p.Edits) == 0 {
		return source, nil
	}
	return format.Source([]byte(text))
}

func generate(source, tfo, output string) error {
	patched := make(map[string][]byte)
	// Validate all Mihomo and TFO inputs before publishing replacements.
	for _, p := range patches {
		base := source
		if strings.HasPrefix(p.Path, "tfo/") {
			base = tfo
		}
		path := strings.TrimPrefix(p.Path, "tfo/")
		content, err := os.ReadFile(filepath.Join(base, path))
		if err != nil {
			return err
		}
		content, err = apply(content, p)
		if err != nil {
			return err
		}
		if len(p.Edits) != 0 || p.Replacement != "" {
			patched[path] = content
		}
	}
	replacements := make(map[string]string)
	for path, content := range patched {
		destination := filepath.Join(output, path)
		if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(destination, content, 0o644); err != nil {
			return err
		}
		replacements[filepath.Join(source, path)] = destination
	}
	data, err := json.MarshalIndent(struct{ Replace map[string]string }{replacements}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(output, "overlay.json"), data, 0o644)
}

func main() {
	if len(os.Args) != 4 {
		panic("usage: overlay <mihomo-v1.19.33-dir> <pinned-tfo-dir> <output-dir>")
	}
	paths := make([]string, 3)
	for i, arg := range os.Args[1:] {
		var err error
		paths[i], err = filepath.Abs(arg)
		if err != nil {
			panic(err)
		}
	}
	if err := generate(paths[0], paths[1], paths[2]); err != nil {
		panic(err)
	}
	fmt.Printf("Verified %d pinned source checksums; generated socket protection overlay\n", len(patches))
}
