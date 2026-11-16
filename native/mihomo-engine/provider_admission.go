package engine

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/metacubex/mihomo/config"
	"proxima.local/mihomo-provider/boundary"
)

// Provider definitions and their routing references share the protocol policy. Unknown
// options fail closed rather than relying on upstream's weakly typed decoder.
func admitProviders(raw *config.RawConfig) error {
	for _, section := range []struct {
		name    string
		entries map[string]map[string]any
		keys    string
	}{
		{"proxy-providers", raw.ProxyProvider, "type path url interval size-limit header health-check payload"},
		{"rule-providers", raw.RuleProvider, "type path url interval size-limit header behavior format payload"},
	} {
		for name, mapping := range section.entries {
			fail := func(reason string) error { return fmt.Errorf("%s.%s: %s", section.name, name, reason) }
			for key := range mapping {
				if !strings.Contains(" "+section.keys+" ", " "+key+" ") {
					return fail("unsupported option " + key)
				}
			}
			kind, _ := mapping["type"].(string)
			if kind != "http" && kind != "file" && kind != "inline" {
				return fail("type must be http, file or inline")
			}
			if kind == "http" {
				u, _ := mapping["url"].(string)
				if err := boundary.URL(u); err != nil {
					return fail(err.Error())
				}
			}
			if value, ok := mapping["path"]; ok {
				p, ok := value.(string)
				if !ok || p == "" || filepath.IsAbs(p) || strings.Contains(p, "\\") {
					return fail("path must be relative to trusted provider root")
				}
				for _, part := range strings.Split(p, "/") {
					if part == ".." {
						return fail("path traversal forbidden")
					}
				}
			} else if kind == "file" {
				return fail("file path required")
			}
			if n, ok := mapping["interval"]; ok {
				switch v := n.(type) {
				case int:
					if v < 0 || v > 31536000 {
						return fail("invalid interval")
					}
				default:
					return fail("interval must be integer seconds")
				}
			}
			if section.name == "rule-providers" {
				behavior, _ := mapping["behavior"].(string)
				if behavior != "domain" && behavior != "ipcidr" {
					return fail("only domain/ipcidr behavior admitted; classical geodata/resource paths are not audited")
				}
				if format, ok := mapping["format"]; ok && format != "yaml" && format != "text" && format != "mrs" {
					return fail("unsupported format")
				}
			}
			if hc, ok := mapping["health-check"]; ok {
				h, ok := hc.(map[string]any)
				if !ok {
					return fail("health-check must be mapping")
				}
				for k := range h {
					if !strings.Contains(" enable url interval timeout lazy expected-status ", " "+k+" ") {
						return fail("unsupported health-check option " + k)
					}
				}
				if u, ok := h["url"]; ok {
					s, ok := u.(string)
					if !ok {
						return fail("invalid health-check URL")
					}
					if err := boundary.URL(s); err != nil {
						return fail(err.Error())
					}
				}
				for _, key := range []string{"interval", "timeout"} {
					if n, ok := h[key]; ok {
						v, ok := n.(int)
						if !ok || v < 0 || v > 31536000 {
							return fail("invalid health-check " + key)
						}
					}
				}
			}
		}
	}
	return nil
}

// Called by the real upstream provider parser AFTER decryption/conversion and
// overrides, BEFORE any outbound constructor (also on every refresh).
func passiveProviderProxy(mapping map[string]any) error {
	return admitProxy(mapping)
}
