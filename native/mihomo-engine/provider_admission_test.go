package engine

import (
	"context"
	"strings"
	"testing"
)

func TestProviderAdmissionBoundary(t *testing.T) {
	for _, tc := range []struct {
		yaml    string
		allowed bool
	}{
		{"proxy-providers: {p: {type: http, url: 'https://example.test/p'}}", true},
		{"rule-providers: {r: {type: file, path: ./r.mrs, format: mrs, behavior: ipcidr}}", true},
		{"proxy-providers: {p: {type: inline, payload: [{name: p, type: direct}]}}", true},
		{"proxy-providers: {p: {type: http, url: 'http://example.test/p'}}", false},
		{"proxy-providers: {p: {type: http, url: 'https://user@example.test/p'}}", false},
		{"proxy-providers: {p: {type: file, path: /private/cache}}", false},
		{"proxy-providers: {p: {type: file, path: ./../cache}}", false},
		{"proxy-providers: {p: {type: http, url: 'https://example.test/p', proxy: DIRECT}}", false},
		{"proxy-providers: {p: {type: http, url: 'https://example.test/p', skip-cert-verify: true}}", false},
		{"proxy-providers: {p: {type: file, path: cache, interval: -1}}", false},
		{"proxy-providers: {p: {type: file, path: cache, health-check: {enable: true, url: 'http://example.test'}}}", false},
		{"rule-providers: {r: {type: file, path: rules, behavior: classical}}", false},
		{"proxies: []", false}, {"proxy-groups: []", false},
	} {
		t.Run(tc.yaml, func(t *testing.T) {
			source := []byte(minimal + tc.yaml + "\n")
			snapshot, err := Decode(context.Background(), source, RevisionOf(source))
			if err != nil {
				t.Fatal(err)
			}
			raw, err := snapshot.Raw(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if err := admit(source, raw); (err == nil) != tc.allowed {
				t.Fatalf("admission allowed=%v: %v", tc.allowed, err)
			}
		})
	}
	for _, kind := range []string{"direct", "http", "socks5"} {
		if err := passiveProviderProxy(map[string]any{"name": "p", "type": kind}); err != nil {
			t.Fatal(err)
		}
	}
	for _, proxy := range []map[string]any{
		{"name": "p", "type": "tailscale"}, {"name": "p", "type": "wireguard"},
		{"name": "p", "type": "http", "skip-cert-verify": true},
		{"name": "p", "type": "socks5", "dialer-proxy": "p"},
	} {
		if err := passiveProviderProxy(proxy); err == nil {
			t.Fatal("unsafe constructor admitted", proxy)
		}
	}
	fd, _ := pair(t)
	p := &testProtector{}
	if s, err := Start([]byte(minimal+"rule-providers: {r: {type: file, path: rules, behavior: domain}}\n"), fd, p); s != nil || err == nil || !strings.Contains(err.Error(), "ProviderRoot") || p.closed.Load() != 1 {
		t.Fatal("profile chose root", s, err)
	}
}
