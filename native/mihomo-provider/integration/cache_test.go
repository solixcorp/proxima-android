package integration

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/component/profile/cachefile"
)

func TestCacheRejectsEscapingDatabase(t *testing.T) {
	// The real upstream database is a sync.Once singleton. An independent
	// process is required to test its initial open without a production reset.
	if os.Getenv("PROVIDER_CACHE_CHILD") != "1" {
		cmd := exec.CommandContext(t.Context(), os.Args[0], "-test.run=^TestCacheRejectsEscapingDatabase$", "-test.v")
		cmd.Env = append(os.Environ(), "PROVIDER_CACHE_CHILD=1")
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("isolated cache test: %v\n%s", err, output)
		}
		return
	}
	outside := filepath.Join(t.TempDir(), "database")
	check(t, os.WriteFile(outside, []byte("private"), 0o600))
	check(t, os.Symlink(outside, filepath.Join(rootDir, "cache.db")))
	if cachefile.Cache().DB != nil {
		t.Fatal("cache opened an escaping database")
	}
	contents, err := os.ReadFile(outside)
	check(t, err)
	if string(contents) != "private" {
		t.Fatalf("outside database changed: %q", contents)
	}
}
