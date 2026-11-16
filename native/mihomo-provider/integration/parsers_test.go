package integration

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	proxyprovider "github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/component/resource"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/rules/bundle"
	ruleprovider "github.com/metacubex/mihomo/rules/provider"
	"proxima.local/mihomo-provider/boundary"
)

func TestProviderParsersRejectUnsafeURLDespiteValidCache(t *testing.T) {
	path := testPath(t)
	check(t, resource.NewFileVehicle(path).Write([]byte("payload:\n  - example.com\n")))
	mapping := map[string]any{
		"type": "http", "behavior": "domain", "url": "http://example.com/provider",
		"path": path,
	}
	_, ruleErr := ruleprovider.ParseRuleProvider("rule", mapping, nil, bundle.MakeBundleFile)
	_, proxyErr := proxyprovider.ParseProxyProvider("proxy", mapping, nil)
	if !errors.Is(ruleErr, boundary.ErrURL) || !errors.Is(proxyErr, boundary.ErrURL) {
		t.Fatalf("cached unsafe URL: rule=%v proxy=%v", ruleErr, proxyErr)
	}
}

func TestProviderParsersRejectRawTraversalAndOutsidePaths(t *testing.T) {
	for _, kind := range []string{"file", "http"} {
		for _, path := range []string{
			"rules/../cache.yaml", "./rules/../cache.yaml", "./../outside.yaml",
			"././rules/../../outside.yaml", filepath.Join(t.TempDir(), "outside.yaml"),
		} {
			mapping := map[string]any{
				"type": kind, "behavior": "domain", "url": "https://example.com/provider",
				"path": path,
			}
			_, ruleErr := ruleprovider.ParseRuleProvider("rule", mapping, nil, bundle.MakeBundleFile)
			_, proxyErr := proxyprovider.ParseProxyProvider("proxy", mapping, nil)
			if !errors.Is(ruleErr, boundary.ErrPath) || !errors.Is(proxyErr, boundary.ErrPath) {
				t.Fatalf("unsafe %s path %q: rule=%v proxy=%v", kind, path, ruleErr, proxyErr)
			}
		}
	}
}

func TestProviderParsersAcceptLeadingDotPaths(t *testing.T) {
	for _, kind := range []string{"file", "http"} {
		for _, prefix := range []struct{ name, path string }{{"single", "./"}, {"repeated", "././"}} {
			t.Run(kind+"/"+prefix.name, func(t *testing.T) {
				path := testPath(t)
				relative, err := filepath.Rel(rootDir, path)
				check(t, err)
				check(t, resource.NewFileVehicle(path).Write([]byte("existing")))
				mapping := map[string]any{
					"type": kind, "behavior": "domain", "url": "https://unreachable.invalid/provider",
					"path": prefix.path + filepath.ToSlash(relative),
				}
				checkVehicle := func(t *testing.T, vehicle P.Vehicle) {
					t.Helper()
					check(t, vehicle.Write([]byte(t.Name())))
					contents, err := os.ReadFile(path)
					check(t, err)
					if string(contents) != t.Name() {
						t.Fatalf("parsed provider wrote to the wrong cache: %q", contents)
					}
				}
				t.Run("rule", func(t *testing.T) {
					provider, err := ruleprovider.ParseRuleProvider("rule", mapping, nil, bundle.MakeBundleFile)
					check(t, err)
					native := provider.(*ruleprovider.RuleSetProvider)
					defer native.Close()
					checkVehicle(t, native.Vehicle())
				})
				t.Run("proxy", func(t *testing.T) {
					provider, err := proxyprovider.ParseProxyProvider("proxy", mapping, nil)
					check(t, err)
					native := provider.(*proxyprovider.ProxySetProvider)
					defer native.Close()
					checkVehicle(t, native.Vehicle())
				})
			})
		}
	}
}

func TestProviderParsersRejectDotPrefixedSymlinkEscape(t *testing.T) {
	outside := filepath.Join(t.TempDir(), "private")
	check(t, os.WriteFile(outside, []byte("private"), 0o600))
	link := testPath(t)
	check(t, os.MkdirAll(filepath.Dir(link), 0o700))
	check(t, os.Symlink(outside, link))
	relative, err := filepath.Rel(rootDir, link)
	check(t, err)
	for _, kind := range []string{"file", "http"} {
		mapping := map[string]any{
			"type": kind, "behavior": "domain", "url": "https://unreachable.invalid/provider",
			"path": "./" + filepath.ToSlash(relative),
		}
		_, ruleErr := ruleprovider.ParseRuleProvider("rule", mapping, nil, bundle.MakeBundleFile)
		_, proxyErr := proxyprovider.ParseProxyProvider("proxy", mapping, nil)
		if ruleErr == nil || proxyErr == nil {
			t.Fatalf("escaping %s symlink accepted: rule=%v proxy=%v", kind, ruleErr, proxyErr)
		}
	}
}
