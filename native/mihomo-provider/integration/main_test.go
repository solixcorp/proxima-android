package integration

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/profile/cachefile"
	C "github.com/metacubex/mihomo/constant"
	"proxima.local/mihomo-provider/boundary"
)

var rootDir string

func TestMain(m *testing.M) {
	directory, err := os.MkdirTemp("", "mihomo-provider-")
	if err != nil {
		panic(err)
	}
	rootDir = directory
	if err := boundary.ConfigureRoot(rootDir); err != nil {
		panic(err)
	}
	C.SetHomeDir(rootDir)
	code := m.Run()
	if cachefile.Cache().DB != nil {
		if err := cachefile.Cache().Close(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			code = 1
		}
	}
	if err := boundary.CloseRoot(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		code = 1
	}
	if err := os.RemoveAll(directory); err != nil {
		fmt.Fprintln(os.Stderr, err)
		code = 1
	}
	os.Exit(code)
}

func testPath(t *testing.T) string {
	t.Helper()
	return filepath.Join(rootDir, strings.ReplaceAll(t.Name(), "/", "-"), "provider.yaml")
}

func check(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
