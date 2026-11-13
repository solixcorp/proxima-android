package engine

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/ca"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	ruleprovider "github.com/metacubex/mihomo/rules/provider"
)

func TestRoutingAdmission(t *testing.T) {
	for _, tc := range []struct {
		extra, rule string
		allowed     bool
	}{
		{"proxies: [{name: p, type: direct}]\nproxy-groups: [{name: g, type: select, proxies: [p]}]\n", "MATCH,g", true},
		{"rule-providers: {r: {type: inline, behavior: domain, payload: ['+.test']}}\n", "RULE-SET,r,REJECT", true},
		{"", "DOMAIN,example.test,DIRECT", true},
		{"", "DOMAIN-SUFFIX,example.test,DIRECT", true},
		{"", "DOMAIN-KEYWORD,example,DIRECT", true},
		{"", "DOMAIN-REGEX,^example[.]test$,REJECT", true},
		{"", "DOMAIN-WILDCARD,*.test,REJECT", true},
		{"", "IP-CIDR,192.0.2.0/24,DIRECT,no-resolve", true},
		{"", "IP-CIDR6,2001:db8::/32,DIRECT,no-resolve", true},
		{"", "GEOIP,CN,DIRECT", false}, {"", "GEOSITE,cn,DIRECT", false},
		{"", "IP-ASN,123,DIRECT", false}, {"", "PROCESS-NAME,app,DIRECT", false},
		{"", "AND,((GEOIP,CN)),DIRECT", false}, {"", "RULE-SET,missing,DIRECT", false},
		{"proxy-groups: [{name: g, type: relay, proxies: [DIRECT]}]\n", "MATCH,g", false},
		{"proxy-groups: [{name: g, type: url-test, proxies: [DIRECT], url: 'http://example.test'}]\n", "MATCH,g", false},
		{"proxy-groups: [{name: g, type: fallback, proxies: [DIRECT], interval: -1}]\n", "MATCH,g", false},
		{"proxy-groups: [{name: g, type: select, proxies: [DIRECT], interval: 1}]\n", "MATCH,g", false},
		{"proxies: [{name: DIRECT, type: direct}]\n", "MATCH,DIRECT", false},
		{"proxies: [{name: p, type: direct}, {name: p, type: anytls}]\n", "MATCH,p", false},
	} {
		source := []byte(strings.Replace(minimal, "MATCH,DIRECT", tc.rule, 1) + tc.extra)
		snapshot, err := Decode(context.Background(), source, RevisionOf(source))
		if err != nil {
			t.Fatal(err)
		}
		raw, err := snapshot.Raw(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if err := admit(source, raw); (err == nil) != tc.allowed {
			t.Fatalf("%s / %s: %v", tc.extra, tc.rule, err)
		}
	}
}

func TestEngineRoutingProcess(t *testing.T) {
	for _, scenario := range []string{"select", "url-test", "fallback", "load-balance", "provider-mrs", "group-health", "parse-rollback"} {
		t.Run(scenario, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestRoutingChild$", "-test.v")
			cmd.Env = append(os.Environ(), "PROXIMA_ROUTING_CHILD="+scenario)
			if output, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("%s: %v\n%s", scenario, err, output)
			}
		})
	}
}

func TestRoutingChild(t *testing.T) {
	scenario := os.Getenv("PROXIMA_ROUTING_CHILD")
	if scenario == "" {
		t.Skip("subprocess only")
	}
	fd, peer := pair(t)
	p := &routingProtector{t: t}
	source := strings.Replace(minimal, "MATCH,DIRECT", "MATCH,chosen", 1)
	kind := scenario
	if scenario == "provider-mrs" || scenario == "parse-rollback" {
		kind = "select"
	}
	if scenario == "group-health" {
		kind = "url-test"
	}
	source += "proxies: [{name: local, type: direct}]\n"
	group := fmt.Sprintf("proxy-groups: [{name: chosen, type: %s, proxies: [local]}]\n", kind)
	options := Options{}
	if scenario == "provider-mrs" {
		options.ProviderRoot = testRoot
		var mrs bytes.Buffer
		if err := ruleprovider.ConvertToMrs([]byte("payload:\n - '0.0.0.0/0'\n"), P.IPCIDR, P.YamlRule, &mrs); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(testRoot, "routes.mrs"), mrs.Bytes(), 0600); err != nil {
			t.Fatal(err)
		}
		source = strings.Replace(source, "rules: ['MATCH,chosen']", "rules: ['RULE-SET,r,chosen,no-resolve', 'MATCH,REJECT']", 1)
		source += "rule-providers: {r: {type: file, path: routes.mrs, behavior: ipcidr, format: mrs}}\nproxy-providers: {p: {type: inline, payload: [{name: provider-direct, type: direct}]}}\n"
		group = "proxy-groups: [{name: chosen, type: select, use: [p]}]\n"
	}
	entered := make(chan struct{})
	if scenario == "group-health" {
		var once sync.Once
		server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { once.Do(func() { close(entered) }); <-r.Context().Done() }))
		defer server.Close()
		if err := ca.AddCertificate(string(server.Certificate().Raw)); err != nil {
			t.Fatal(err)
		}
		group = fmt.Sprintf("proxy-groups: [{name: chosen, type: url-test, proxies: [local], lazy: false, interval: 1, timeout: 15000, url: '%s'}]\n", server.URL)
	}
	source += group
	if scenario != "provider-mrs" {
		source = strings.Replace(source, "rules: ['MATCH,chosen']", "rules: ['DOMAIN,example.test,chosen', 'DOMAIN-SUFFIX,example.test,chosen', 'DOMAIN-KEYWORD,example,chosen', 'DOMAIN-REGEX,^example[.]test$,chosen', 'DOMAIN-WILDCARD,*.test,chosen', 'MATCH,chosen']", 1)
	}
	if scenario == "parse-rollback" {
		// A timer-owning adapter exists before the group's missing reference fails.
		source = strings.Replace(source, "name: local, type: direct", "name: local, type: anytls, server: 127.0.0.1, port: 29473, password: secret", 1)
		source = strings.Replace(source, "proxies: [local]", "proxies: [missing]", 1)
	}
	s, err := StartWithOptions([]byte(source), fd, p, options)
	if scenario == "parse-rollback" {
		if err == nil || s != nil || p.closed.Load() != 1 {
			t.Fatalf("parse rollback: %v %v", s, err)
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	defer s.Stop()
	if scenario == "group-health" {
		providerEvent(t, entered)
	} else {
		actualRoundTrip(t, fd, peer, &p.testProtector)
	}
	if scenario != "provider-mrs" {
		// The real parser supplies native domain matchers, not geodata downloads.
		for _, rule := range s.cfg.Rules[:5] {
			if match, target := rule.Match(&C.Metadata{Host: "example.test"}, C.RuleMatchHelper{}); !match || target != "chosen" {
				t.Fatalf("native matcher %s: %v %s", rule.RuleType(), match, target)
			}
		}
	}
	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	if outboundgroup.ProximaGroupWorkers() != 0 {
		t.Fatal("group task survived Stop")
	}
}

type routingProtector struct {
	testProtector
	t *testing.T
}

func (p *routingProtector) Close() error {
	if n := outboundgroup.ProximaGroupWorkers(); n != 0 {
		p.t.Errorf("release before group join: %d", n)
	}
	return p.testProtector.Close()
}
