// Command overlay generates checksum-gated upstream source replacements.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"go/format"
	"os"
	"path/filepath"
	"strings"
)

var errSource = errors.New("upstream source does not match pinned Mihomo v1.19.33")

type edit struct {
	before string
	after  string
}

type patch struct {
	path  string
	hash  string
	edits []edit
}

func apply(source []byte, p patch) ([]byte, error) {
	if fmt.Sprintf("%x", sha256.Sum256(source)) != p.hash {
		return nil, fmt.Errorf("%w: %s checksum", errSource, p.path)
	}
	text := string(source)
	for _, e := range p.edits {
		if strings.Count(text, e.before) != 1 {
			return nil, fmt.Errorf("%w: %s anchor %q", errSource, p.path, e.before)
		}
		text = strings.Replace(text, e.before, e.after, 1)
	}
	return format.Source([]byte(text))
}

func generate(source, output string) error {
	replacements := make(map[string]string)
	// Validate every input before publishing any output.
	patched := make(map[string][]byte)
	for _, p := range patches {
		content, err := os.ReadFile(filepath.Join(source, p.path))
		if err != nil {
			return err
		}
		content, err = apply(content, p)
		if err != nil {
			return err
		}
		patched[p.path] = content
	}
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
	if len(os.Args) != 3 {
		panic("usage: overlay <mihomo-v1.19.33-module-dir> <output-dir>")
	}
	source, err := filepath.Abs(os.Args[1])
	if err != nil {
		panic(err)
	}
	output, err := filepath.Abs(os.Args[2])
	if err != nil {
		panic(err)
	}
	if err := generate(source, output); err != nil {
		panic(err)
	}
	fmt.Printf("Verified %d Mihomo v1.19.33 source checksums; generated %s\n", len(patches), filepath.Join(output, "overlay.json"))
}
