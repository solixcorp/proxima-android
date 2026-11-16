package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"go.yaml.in/yaml/v3"
)

func TestSharedAdmissionBehavior(t *testing.T) {
	data, err := os.ReadFile("../../test/fixtures/mihomo_admission_parity.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Proxy   map[string]any `json:"proxy"`
		Allowed bool           `json:"allowed"`
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	// JSON numbers must match the int values produced by the YAML decoder.
	decoder.UseNumber()
	if err := decoder.Decode(&cases); err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases {
		if n, ok := tc.Proxy["version"].(json.Number); ok {
			i, err := n.Int64()
			if err != nil {
				t.Fatal(err)
			}
			tc.Proxy["version"] = int(i)
		}
		if err := admitProxy(tc.Proxy); (err == nil) != tc.Allowed {
			t.Errorf("%v: %v", tc.Proxy, err)
		}
	}
}

// Compare the actual Dart constants, not two independently maintained fixtures.
// A changed declaration syntax fails closed and requires updating this parser.
func TestDartAdmissionKeyParity(t *testing.T) {
	source, err := os.ReadFile("../../lib/core/mihomo_proxy_admission.dart")
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		dart   string
		native map[string]string
	}{
		{"proxyOptions", protocolKeys}, {"nestedOptions", transportKeys},
	} {
		t.Run(tc.dart, func(t *testing.T) {
			re := regexp.MustCompile(`(?s)static const ` + tc.dart + ` = <String, String>\{(.*?)\n  \};`)
			block := re.FindStringSubmatch(string(source))
			if len(block) != 2 {
				t.Fatal("Dart declaration missing or changed syntax")
			}
			entry := regexp.MustCompile(`(?m)^    '([^']+)': '([^']*)',$`)
			matches := entry.FindAllStringSubmatch(block[1], -1)
			lines := strings.Split(strings.TrimSpace(block[1]), "\n")
			if len(matches) != len(lines) || len(matches) != len(tc.native) {
				t.Fatalf("unparsed or missing entries: parsed=%d lines=%d native=%d", len(matches), len(lines), len(tc.native))
			}
			seen := map[string]bool{}
			for _, m := range matches {
				want, ok := tc.native[m[1]]
				if !ok || seen[m[1]] {
					t.Fatalf("unknown/duplicate Dart key %q", m[1])
				}
				seen[m[1]] = true
				a, b := strings.Fields(m[2]), strings.Fields(want)
				sort.Strings(a)
				sort.Strings(b)
				if strings.Join(a, " ") != strings.Join(b, " ") {
					t.Errorf("%s: Dart %v != Go %v", m[1], a, b)
				}
			}
		})
	}
}

func TestSubscriptionStartProcess(t *testing.T) {
	for _, scenario := range []string{"all", "constructor-failure", "admission-failure"} {
		t.Run(scenario, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestSubscriptionStartChild$", "-test.v")
			cmd.Env = append(os.Environ(), "PROXIMA_SUBSCRIPTION_CHILD="+scenario)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("%v\n%s", err, out)
			}
		})
	}
}

func TestSubscriptionStartChild(t *testing.T) {
	scenario := os.Getenv("PROXIMA_SUBSCRIPTION_CHILD")
	if scenario == "" {
		t.Skip("subprocess only")
	}
	fixtures := protocolFixtures(t)
	names := make([]string, 0, len(fixtures))
	for i, p := range fixtures {
		p["name"] = fmt.Sprintf("node%d", i)
		names = append(names, p["name"].(string))
	}
	if scenario == "constructor-failure" {
		fixtures[4]["cipher"] = "not-a-cipher"
	}
	if scenario == "admission-failure" {
		fixtures[4]["skip-cert-verify"] = true
	}
	if scenario == "constructor-failure" {
		if err := admitProxy(fixtures[4]); err != nil {
			t.Fatalf("invalid cipher should pass admission before constructor: %v", err)
		}
	}
	proxyYAML, err := yaml.Marshal(fixtures)
	if err != nil {
		t.Fatal(err)
	}
	groupYAML, err := yaml.Marshal([]map[string]any{{"name": "chosen", "type": "select", "proxies": names}})
	if err != nil {
		t.Fatal(err)
	}
	source := strings.Replace(minimal, "MATCH,DIRECT", "MATCH,chosen", 1) + "proxies:\n" + string(proxyYAML) + "proxy-groups:\n" + string(groupYAML)
	fd, _ := pair(t)
	p := &testProtector{}
	s, err := Start([]byte(source), fd, p)
	if scenario != "all" {
		if err == nil || s != nil {
			t.Fatalf("expected %s rejection: %v", scenario, err)
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	if len(s.cfg.Proxies) < len(fixtures) {
		t.Fatalf("missing constructed proxies: %d", len(s.cfg.Proxies))
	}
	for _, name := range names {
		if _, ok := s.cfg.Proxies[name]; !ok {
			t.Fatalf("missing constructed proxy %s", name)
		}
	}
	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
}
