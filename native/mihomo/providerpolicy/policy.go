// Package providerpolicy contains the provider security boundary to be used by
// the future engine adapter. Upstream provider I/O is not wired to it yet.
package providerpolicy

import (
	"errors"
	"io/fs"
	"net/url"
	"os"
	"strings"
)

var (
	ErrURL  = errors.New("provider URL requires HTTPS, a host, and no userinfo")
	ErrPath = errors.New("provider path must be relative without traversal")
)

// URL preserves the application's existing provider transport policy.
// Apply it to every redirect too, before issuing the next request.
func URL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Opaque != "" {
		return nil, ErrURL
	}
	return u, nil
}

// Store uses descriptor-relative filesystem operations, rather than a
// check-then-open pathname check. os.Root prevents traversal and symlink escape
// during the actual operation on Android and the supported host platforms.
// The root must be a trusted app-private directory; this is not a sandbox for
// malicious processes with the same UID or permission to create bind mounts.
type Store struct {
	root *os.Root
}

func Open(directory string) (*Store, error) {
	root, err := os.OpenRoot(directory)
	if err != nil {
		return nil, err
	}
	return &Store{root: root}, nil
}

func (s *Store) Close() error {
	return s.root.Close()
}

func providerPath(path string) error {
	if path == "." || !fs.ValidPath(path) || strings.Contains(path, "\\") {
		return ErrPath
	}
	return nil
}

func (s *Store) Read(path string) ([]byte, error) {
	if err := providerPath(path); err != nil {
		return nil, err
	}
	return s.root.ReadFile(path)
}

// Write confines the actual write, including any existing final symlink.
// It is not an atomic cache update. A future provider adapter must parse before
// publication and implement atomic replacement inside the same root.
func (s *Store) Write(path string, contents []byte) error {
	if err := providerPath(path); err != nil {
		return err
	}
	return s.root.WriteFile(path, contents, 0o600)
}
