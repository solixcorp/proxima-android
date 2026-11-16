// Package engine provides a standalone, error-returning Mihomo core adapter,
// raw configuration snapshots and a separate provider-initialization stage.
package engine

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"

	"github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
	_ "proxima.local/mihomo" // Permanent fail-closed upstream socket hook.
)

var (
	ErrStale    = errors.New("effective configuration revision changed")
	ErrDocument = errors.New("effective configuration must be one nonempty YAML mapping")
)

type Revision [sha256.Size]byte

func RevisionOf(effective []byte) Revision { return sha256.Sum256(effective) }

// Snapshot retains the exact effective YAML. It is never serialized back from
// RawConfig, which would lose unknown fields, aliases, comments, and spelling.
type Snapshot struct {
	source   []byte
	revision Revision
}

// Decode uses the actual pinned Mihomo raw decoder, including its defaults and
// typed-field errors. This is deliberately not config.Parse: semantic parsing
// can download geodata, allocate providers, and mutate process-wide globals.
// Only plaintext effective YAML is accepted. Decryption belongs before this API.
func Decode(ctx context.Context, effective []byte, expected Revision) (*Snapshot, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	source := bytes.Clone(effective)
	revision := RevisionOf(source)
	if revision != expected {
		return nil, ErrStale
	}
	s := &Snapshot{source: source, revision: revision}
	if _, err := s.Raw(ctx); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Snapshot) Revision() Revision { return s.revision }

func (s *Snapshot) Bytes() []byte { return bytes.Clone(s.source) }

// Raw returns a fresh decoded value; callers cannot mutate the stored snapshot.
// Unknown fields remain in Bytes even when upstream RawConfig does not model them.
func (s *Snapshot) Raw(ctx context.Context) (*config.RawConfig, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var document yaml.Node
	decoder := yaml.NewDecoder(bytes.NewReader(s.source))
	if err := decoder.Decode(&document); err != nil {
		return nil, fmt.Errorf("effective YAML: %w", err)
	}
	if len(document.Content) != 1 || document.Content[0].Kind != yaml.MappingNode || len(document.Content[0].Content) == 0 {
		return nil, ErrDocument
	}
	var trailing yaml.Node
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err != nil {
			return nil, fmt.Errorf("effective YAML trailing document: %w", err)
		}
		return nil, ErrDocument
	}
	raw, err := config.UnmarshalRawConfig(s.source)
	if err != nil {
		return nil, fmt.Errorf("Mihomo raw configuration: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return raw, nil
}
