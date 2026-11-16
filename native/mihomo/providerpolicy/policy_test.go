package providerpolicy_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	"proxima.local/mihomo/providerpolicy"
)

func TestProviderURLPreservesHTTPSPolicy(t *testing.T) {
	for _, tc := range []struct {
		raw string
		ok  bool
	}{
		{"https://rules.example/list.yaml", true},
		{"https://rules.example:8443/list?q=1", true},
		{"https://[::1]/list", true},
		{"http://rules.example/list", false},
		{"file:///list", false},
		{"https:///list", false},
		{"https://user:password@rules.example/list", false},
		{"https://@rules.example/list", false},
		{"https:opaque", false},
		{"https://%zz/list", false},
	} {
		t.Run(tc.raw, func(t *testing.T) {
			u, err := providerpolicy.URL(tc.raw)
			if tc.ok {
				require.NoError(t, err)
				require.Equal(t, tc.raw, u.String())
			} else {
				require.ErrorIs(t, err, providerpolicy.ErrURL)
			}
		})
	}
}

func TestProviderStoreConfinesActualReadsAndWrites(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	secret := filepath.Join(outside, "private")
	require.NoError(t, os.WriteFile(secret, []byte("unchanged"), 0o600))
	require.NoError(t, os.Symlink(outside, filepath.Join(root, "escape")))
	require.NoError(t, os.Symlink(secret, filepath.Join(root, "file-link")))
	store, err := providerpolicy.Open(root)
	require.NoError(t, err)
	defer func() { require.NoError(t, store.Close()) }()

	for _, path := range []string{
		"../private", "/private", "a/../private", "escape/private",
		"escape/new-file", "file-link", ".", "a\\..\\private",
	} {
		t.Run(path, func(t *testing.T) {
			require.Error(t, store.Write(path, []byte("modified")))
			_, err := store.Read(path)
			require.Error(t, err)
		})
	}

	contents, err := os.ReadFile(secret)
	require.NoError(t, err)
	require.Equal(t, "unchanged", string(contents))
	_, err = os.Stat(filepath.Join(outside, "new-file"))
	require.ErrorIs(t, err, os.ErrNotExist)
}

func TestProviderStoreReadsAndWritesWithinRoot(t *testing.T) {
	root := t.TempDir()
	store, err := providerpolicy.Open(root)
	require.NoError(t, err)
	defer func() { require.NoError(t, store.Close()) }()

	require.NoError(t, store.Write("provider.yaml", []byte("payload:\n  - example.com\n")))

	contents, err := store.Read("provider.yaml")
	require.NoError(t, err)
	require.Equal(t, "payload:\n  - example.com\n", string(contents))
}
