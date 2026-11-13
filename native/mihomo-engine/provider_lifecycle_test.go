package engine

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	proxyprovider "github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/resource"
	P "github.com/metacubex/mihomo/constant/provider"
	nativeDNS "github.com/metacubex/mihomo/dns"
	ruleprovider "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
	foundation "proxima.local/mihomo"
	"proxima.local/mihomo-provider/boundary"
	"proxima.local/mihomo/session"
)

func TestEngineProvidersProcess(t *testing.T) {
	for _, scenario := range []string{"https-mrs", "http", "userinfo", "redirect-http", "redirect-userinfo", "redirect-https", "certificate", "refused", "initial", "missing", "symlink", "traversal", "absolute", "unsafe-constructor", "refresh", "pending", "watch", "health"} {
		t.Run(scenario, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestProviderChild$", "-test.v")
			cmd.Env = append(os.Environ(), "PROXIMA_PROVIDER_CHILD="+scenario)
			if output, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("child %s: %v\n%s", scenario, err, output)
			}
		})
	}
}

type providerProtector struct{ dnsProtector }

func (p *providerProtector) Close() error {
	// A release callback must never run before every owned worker group drained.
	if n := resource.ProximaActiveWorkers(); n != 0 {
		p.t.Errorf("release before provider join: %d", n)
	}
	if n := proxyprovider.ProximaActiveHealthChecks(); n != 0 {
		p.t.Errorf("release before health join: %d", n)
	}
	if n := nativeDNS.ProximaActiveWorkers(); n != 0 {
		p.t.Errorf("release before resolver join: %d", n)
	}
	return p.dnsProtector.Close()
}

func providerEvent(t *testing.T, event <-chan struct{}) {
	t.Helper()
	select {
	case <-event:
	case <-time.After(5 * time.Second):
		t.Fatal("provider event timeout")
	}
}

func TestProviderChild(t *testing.T) {
	scenario := os.Getenv("PROXIMA_PROVIDER_CHILD")
	if scenario == "" {
		t.Skip("subprocess only")
	}
	root := testRoot
	fd, _ := pair(t)
	const proxyBody = "proxies:\n - {name: passive, type: direct}\n"
	const ruleBody = "payload:\n - '+.example.test'\n"
	var mrs bytes.Buffer
	if err := ruleprovider.ConvertToMrs([]byte(ruleBody), P.Domain, P.YamlRule, &mrs); err != nil {
		t.Fatal(err)
	}
	var requests, escaped atomic.Int32
	entered := make(chan struct{})
	var once sync.Once
	failUpdates := atomic.Bool{}
	sink := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { escaped.Add(1) }))
	defer sink.Close()
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := requests.Add(1)
		if strings.HasPrefix(scenario, "redirect-") && r.URL.Path != "/final" {
			target := sink.URL
			if scenario == "redirect-userinfo" {
				target = strings.Replace(server.URL, "https://", "https://user:secret@", 1) + "/final"
			}
			if scenario == "redirect-https" {
				target = server.URL + "/final"
			}
			http.Redirect(w, r, target, http.StatusFound)
			return
		}
		if scenario == "health" && r.Method == http.MethodHead {
			once.Do(func() { close(entered) })
			<-r.Context().Done()
			return
		}
		if scenario == "pending" && n > 1 {
			once.Do(func() { close(entered) })
			<-r.Context().Done()
			return
		}
		if scenario == "refresh" && failUpdates.Load() {
			once.Do(func() { close(entered) })
			_, _ = w.Write([]byte("invalid mrs"))
			return
		}
		switch r.URL.Path {
		case "/proxy":
			if scenario == "initial" {
				_, _ = w.Write([]byte("not a provider"))
				return
			}
			if scenario == "unsafe-constructor" {
				_, _ = w.Write([]byte("proxies:\n - {name: background, type: tailscale}\n"))
				return
			}
			_, _ = w.Write([]byte(proxyBody))
		case "/mrs":
			_, _ = w.Write(mrs.Bytes())
		default:
			_, _ = w.Write([]byte(ruleBody))
		}
	}))
	defer server.Close()
	if scenario != "certificate" {
		if err := ca.AddCertificate(string(server.Certificate().Raw)); err != nil {
			t.Fatal(err)
		}
	}
	url := server.URL + "/rule"
	if scenario == "http" {
		url = sink.URL
	}
	if scenario == "userinfo" {
		url = strings.Replace(url, "https://", "https://user:secret@", 1)
	}
	source := minimal + fmt.Sprintf("rule-providers:\n r: {type: http, behavior: domain, path: rules/cache, url: '%s', interval: 1}\n", url)
	switch scenario {
	case "https-mrs":
		source += fmt.Sprintf("proxy-providers:\n p: {type: http, path: proxies/cache, url: '%s/proxy', interval: 1}\n", server.URL)
		source = strings.Replace(source, "interval: 1}", "interval: 1}\n m: {type: http, behavior: domain, format: mrs, path: rules/mrs, url: '"+server.URL+"/mrs', interval: 1}", 1)
	case "initial", "unsafe-constructor":
		source = minimal + fmt.Sprintf("proxy-providers:\n p: {type: http, url: '%s/proxy', path: proxies/cache, interval: 1}\n", server.URL)
	case "refresh":
		source = strings.Replace(source, "url: '"+url+"'", "format: mrs, url: '"+server.URL+"/mrs'", 1)
	case "missing", "watch", "symlink", "traversal", "absolute":
		path := "rules/file"
		if scenario == "watch" {
			if err := os.MkdirAll(filepath.Join(root, "rules"), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, path), []byte(ruleBody), 0600); err != nil {
				t.Fatal(err)
			}
		}
		if scenario == "symlink" {
			outside := t.TempDir()
			if err := os.WriteFile(filepath.Join(outside, "provider"), []byte(ruleBody), 0600); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
				t.Fatal(err)
			}
			path = "escape/provider"
		}
		if scenario == "traversal" {
			path = "../escape"
		}
		if scenario == "absolute" {
			path = filepath.Join(root, "absolute")
		}
		source = minimal + fmt.Sprintf("rule-providers:\n r: {type: file, behavior: domain, path: '%s'}\n", path)
	case "health":
		source = minimal + fmt.Sprintf("proxy-providers:\n p: {type: http, path: proxies/cache, url: '%s/proxy', interval: 1, health-check: {enable: true, lazy: false, interval: 1, timeout: 15000, url: '%s/health'}}\n", server.URL, server.URL)
	}
	p := &providerProtector{dnsProtector: dnsProtector{t: t, reject: scenario == "refused"}}
	before := fdCount(t)
	s, err := StartWithOptions([]byte(source), fd, p, Options{ProviderRoot: root})
	wantFailure := map[string]bool{"http": true, "userinfo": true, "redirect-http": true, "redirect-userinfo": true, "certificate": true, "refused": true, "initial": true, "missing": true, "symlink": true, "traversal": true, "absolute": true, "unsafe-constructor": true}[scenario]
	if wantFailure {
		if err == nil || s != nil || p.closed.Load() != 1 || tunnel.Status() == tunnel.Running {
			t.Fatalf("provider failure not rolled back: %v %v", s, err)
		}
		if escaped.Load() != 0 {
			t.Fatal("URL policy violation reached redirect target")
		}
		if resource.ProximaActiveWorkers() != 0 || proxyprovider.ProximaActiveHealthChecks() != 0 || nativeDNS.ProximaActiveWorkers() != 0 {
			t.Fatal("startup failure leaked workers")
		}
		if scenario == "refused" && p.protects.Load() == 0 {
			t.Fatal("provider bypassed protector")
		}
		// Server-side accepted TLS descriptors are owned by the fixture and can
		// outlive client failure briefly; close fixtures before checking native FDs.
		server.CloseClientConnections()
		if scenario == "http" || scenario == "userinfo" || scenario == "missing" || scenario == "symlink" || scenario == "traversal" || scenario == "absolute" || scenario == "refused" {
			if after := fdCount(t); after != before {
				t.Fatalf("rollback FDs %d -> %d: %v", before, after, err)
			}
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	defer s.Stop()
	if scenario == "https-mrs" {
		if s.cfg.Providers["p"].Count() != 1 || s.cfg.RuleProviders["r"].Count() != 1 || s.cfg.RuleProviders["m"].Count() != 1 {
			t.Fatal("actual providers not initialized")
		}
		if requests.Load() != 3 || p.protects.Load() < 3 {
			t.Fatal("provider fetch not protected", requests.Load(), p.protects.Load())
		}
		if data, err := os.ReadFile(filepath.Join(root, "proxies/cache")); err != nil || string(data) != proxyBody {
			t.Fatal("real cache missing", err)
		}
	}
	if scenario == "refresh" {
		failUpdates.Store(true)
		providerEvent(t, entered) // actual timer, not a synthetic Update implementation
		if err := s.cfg.RuleProviders["r"].Update(); err == nil {
			t.Fatal("invalid refresh reported success")
		}
		if len(s.ProviderErrors()) != 1 || s.cfg.RuleProviders["r"].Count() != 1 || tunnel.Status() != tunnel.Running {
			t.Fatal("failed refresh lost last-good core")
		}
		if data, err := os.ReadFile(filepath.Join(root, "rules/cache")); err != nil || !bytes.Equal(data, mrs.Bytes()) {
			t.Fatal("failed refresh corrupted cache", err)
		}
		failUpdates.Store(false)
		if err := s.cfg.RuleProviders["r"].Update(); err != nil {
			t.Fatal(err)
		}
		if len(s.ProviderErrors()) != 0 {
			t.Fatal("successful refresh did not clear error")
		}
	}
	if scenario == "watch" {
		updated := make(chan struct{}, 1)
		registration := tunnel.Tunnel.RuleUpdateCallback().Register(func(P.RuleProvider) {
			select {
			case updated <- struct{}{}:
			default:
			}
		})
		defer registration.Close()
		if err := boundary.WriteFile("rules/file", []byte("payload:\n - '+.example.test'\n - '+.second.test'\n")); err != nil {
			t.Fatal(err)
		}
		providerEvent(t, updated)
		if s.cfg.RuleProviders["r"].Count() != 2 {
			t.Fatal("confined file watcher did not reload")
		}
	}
	if scenario == "pending" || scenario == "health" {
		providerEvent(t, entered)
	}
	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	if escaped.Load() != 0 || resource.ProximaActiveWorkers() != 0 || proxyprovider.ProximaActiveHealthChecks() != 0 || nativeDNS.ProximaActiveWorkers() != 0 {
		t.Fatal("Stop did not return worker groups to baseline")
	}
	if _, err := foundation.Sessions.Prepare(fd, &testProtector{}); !errors.Is(err, session.ErrRetired) {
		t.Fatal("joined stop allowed process reuse", err)
	}
	if err := boundary.WriteFile("late", []byte("denied")); err == nil {
		t.Fatal("provider root not revoked")
	}
}
