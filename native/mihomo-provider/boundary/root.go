// Package boundary owns the process-stable provider filesystem capability.
// Configure it before parsing providers; close it only after their users stop.
package boundary

import (
	"errors"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

var (
	ErrURL          = errors.New("provider URL requires HTTPS, a host, and no userinfo")
	ErrPath         = errors.New("provider path must remain under the configured root")
	ErrUnconfigured = errors.New("provider root is not configured")
	ErrConfigured   = errors.New("provider root cannot be rebound")
	state           struct {
		sync.RWMutex
		root *os.Root
		path string
	}
)

// ConfigureRoot opens a trusted app-private directory once per process.
// The caller controls this directory; config files must never choose it.
// Closing does not allow rebinding old workers to a new root.
func ConfigureRoot(directory string) error {
	state.Lock()
	defer state.Unlock()
	if state.root != nil {
		return ErrConfigured
	}
	absolute, err := filepath.Abs(directory)
	if err != nil {
		return err
	}
	root, err := os.OpenRoot(absolute)
	if err != nil {
		return err
	}
	state.root, state.path = root, absolute
	return nil
}

// CloseRoot revokes future path operations, not already-open descriptors.
// Callers must first close providers and the upstream cache database.
func CloseRoot() error {
	state.RLock()
	defer state.RUnlock()
	if state.root == nil {
		return ErrUnconfigured
	}
	return state.root.Close()
}

// URL preserves native/mihomo/providerpolicy.URL's transport policy.
func URL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Opaque != "" {
		return ErrURL
	}
	return nil
}

func resolve(path string) (*os.Root, string, error) {
	state.RLock()
	defer state.RUnlock()
	if state.root == nil {
		return nil, "", ErrUnconfigured
	}
	if strings.Contains(path, "\\") {
		return nil, "", ErrPath
	}
	for _, component := range strings.Split(path, "/") {
		if component == ".." {
			return nil, "", ErrPath
		}
	}
	name := path
	for strings.HasPrefix(name, "./") {
		name = strings.TrimPrefix(name, "./")
	}
	if filepath.IsAbs(path) {
		var err error
		name, err = filepath.Rel(state.path, path)
		if err != nil {
			return nil, "", ErrPath
		}
	}
	if !fs.ValidPath(name) {
		return nil, "", ErrPath
	}
	return state.root, name, nil
}

func Open(path string) (*os.File, error) {
	return OpenFile(path, os.O_RDONLY, 0)
}

// OpenFile is also the bbolt Options.OpenFile callback.
func OpenFile(path string, flags int, mode os.FileMode) (*os.File, error) {
	root, name, err := resolve(path)
	if err != nil {
		return nil, err
	}
	return root.OpenFile(name, flags, mode)
}

func ReadFile(path string) ([]byte, error) {
	root, name, err := resolve(path)
	if err != nil {
		return nil, err
	}
	return root.ReadFile(name)
}

func Stat(path string) (os.FileInfo, error) {
	root, name, err := resolve(path)
	if err != nil {
		return nil, err
	}
	return root.Stat(name)
}

func ReadDir(path string) ([]os.DirEntry, error) {
	f, err := Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	entries, err := f.ReadDir(-1)
	slices.SortFunc(entries, func(a, b os.DirEntry) int { return strings.Compare(a.Name(), b.Name()) })
	return entries, err
}

// CheckPath preflights raw config before filepath.Join can erase traversal.
// It complements, but never replaces, descriptor-relative I/O confinement.
func CheckPath(path string) error {
	_, err := Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func Remove(path string) error {
	root, name, err := resolve(path)
	if err != nil {
		return err
	}
	return root.Remove(name)
}

func Chtimes(path string, atime, mtime time.Time) error {
	root, name, err := resolve(path)
	if err != nil {
		return err
	}
	return root.Chtimes(name, atime, mtime)
}
