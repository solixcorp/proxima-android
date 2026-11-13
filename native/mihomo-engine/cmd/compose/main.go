// Command compose combines overlays for one verified staged Mihomo module.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type overlay struct{ Replace map[string]string }

// Decode object keys before insertion into a map: ordinary json.Unmarshal
// discards duplicates, including differently escaped spellings of the same key.
type uniqueObject[V any] map[string]V

func (o *uniqueObject[V]) UnmarshalJSON(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	if token != json.Delim('{') {
		return fmt.Errorf("overlay JSON value must be an object")
	}
	values := make(uniqueObject[V])
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		key := token.(string) // The decoder requires object keys to be strings.
		if _, exists := values[key]; exists {
			return fmt.Errorf("duplicate JSON key: %q", key)
		}
		var value V
		if err := decoder.Decode(&value); err != nil {
			return err
		}
		values[key] = value
	}
	if _, err := decoder.Token(); err != nil {
		return err
	}
	*o = values
	return nil
}

var sourcePins = map[string]string{
	"config/config.go":         "14d577a607eb5fff79513057bc16052520b62731d9af9817481f3baf980e8653",
	"hub/executor/executor.go": "183595fd58704d60d2137463e751938c1a02a23b57ef1d977b647e3640b64849",
}

func compose(root string, inputs []string) ([]byte, error) {
	if !filepath.IsAbs(root) || filepath.Clean(root) != root {
		return nil, fmt.Errorf("staged root must be absolute")
	}
	for path, expected := range sourcePins {
		source, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			return nil, err
		}
		if fmt.Sprintf("%x", sha256.Sum256(source)) != expected {
			return nil, fmt.Errorf("pinned Mihomo source checksum mismatch: %s", path)
		}
	}
	result := overlay{Replace: make(map[string]string)}
	for _, input := range inputs {
		data, err := os.ReadFile(input)
		if err != nil {
			return nil, err
		}
		var document uniqueObject[uniqueObject[string]]
		if err := json.Unmarshal(data, &document); err != nil {
			return nil, err
		}
		replacements, exists := document["Replace"]
		if !exists || len(document) != 1 {
			return nil, fmt.Errorf("overlay must contain exactly one Replace object: %s", input)
		}
		next := overlay{Replace: replacements}
		if len(next.Replace) == 0 {
			return nil, fmt.Errorf("empty overlay: %s", input)
		}
		for original, replacement := range next.Replace {
			relative, err := filepath.Rel(root, original)
			if err != nil || !filepath.IsAbs(original) || filepath.Clean(original) != original || !filepath.IsLocal(relative) {
				return nil, fmt.Errorf("overlay does not target shared staged module: %s", original)
			}
			if _, exists := result.Replace[original]; exists {
				return nil, fmt.Errorf("overlay conflict: %s", original)
			}
			if !filepath.IsAbs(replacement) {
				return nil, fmt.Errorf("replacement must be an absolute file: %s", replacement)
			}
			for _, path := range []string{original, replacement} {
				info, err := os.Stat(path)
				if err != nil {
					return nil, err
				}
				if !info.Mode().IsRegular() {
					return nil, fmt.Errorf("overlay input is not a file: %s", path)
				}
			}
			result.Replace[original] = replacement
		}
	}
	return json.MarshalIndent(result, "", "  ")
}

func main() {
	if len(os.Args) < 5 {
		fmt.Fprintln(os.Stderr, "usage: compose <staged-mihomo> <output.json> <provider.json> <network.json> [...]")
		os.Exit(2)
	}
	data, err := compose(os.Args[1], os.Args[3:])
	if err == nil {
		err = os.WriteFile(os.Args[2], data, 0o600)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("Verified parser/executor checksums and composed non-conflicting overlays")
}
