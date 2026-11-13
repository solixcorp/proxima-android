package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"proxima.local/mihomo/session"
)

func assertManagementRetired(t *testing.T, s *Session) {
	t.Helper()
	if _, _, err := s.TrafficStats(); !errors.Is(err, ErrNotRunning) {
		t.Fatal("inactive stats", err)
	}
	if _, err := s.DelayTest("DIRECT", "https://127.0.0.1", 10); !errors.Is(err, ErrNotRunning) {
		t.Fatal("inactive delay", err)
	}
	if _, err := s.ConnectionsSnapshot(); !errors.Is(err, ErrNotRunning) {
		t.Fatal("inactive snapshot", err)
	}
	if err := s.Select("group", "node"); !errors.Is(err, ErrNotRunning) {
		t.Fatal("inactive select", err)
	}
}

func TestManagementBeforeStart(t *testing.T) {
	assertManagementRetired(t, nil)
	assertManagementRetired(t, &Session{})
}

func TestManagementProcess(t *testing.T) {
	for _, scenario := range []string{"success", "timeout", "refused", "stop", "certificate", "redirect", "select"} {
		t.Run(scenario, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestManagementChild$", "-test.v")
			cmd.Env = append(os.Environ(), "PROXIMA_MANAGEMENT_CHILD="+scenario)
			if output, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("child %s: %v\n%s", scenario, err, output)
			}
		})
	}
}

func TestManagementChild(t *testing.T) {
	scenario := os.Getenv("PROXIMA_MANAGEMENT_CHILD")
	if scenario == "" {
		t.Skip("subprocess only")
	}
	fd, peer := pair(t)
	var requests, escaped atomic.Int32
	entered := make(chan struct{}, 32)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if r.Method != http.MethodHead {
			t.Error("URLTest did not use native HEAD")
		}
		if r.URL.Path == "/pending" {
			entered <- struct{}{}
			<-r.Context().Done()
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	if scenario != "certificate" {
		if err := ca.AddCertificate(string(server.Certificate().Raw)); err != nil {
			t.Fatal(err)
		}
	}
	p := &dnsProtector{t: t, reject: scenario == "refused"}
	config := minimal + "proxies: [{name: node, type: direct}, {name: blocked, type: reject}]\nproxy-groups: [{name: group, type: select, proxies: [node, blocked]}]\n"
	var proxyHits [2]atomic.Int32
	if scenario == "select" {
		var endpoints [2]string
		for i := range endpoints {
			i := i
			dummy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				proxyHits[i].Add(1)
				http.Error(w, "dummy proxy", http.StatusBadGateway)
			}))
			defer dummy.Close()
			host, port, err := net.SplitHostPort(dummy.Listener.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			endpoints[i] = fmt.Sprintf("{name: dummy%d, type: http, server: %s, port: %s}", i, host, port)
		}
		config = minimal + fmt.Sprintf("proxies: [{name: node, type: direct}, {name: blocked, type: reject}, %s, %s]\nproxy-groups: [{name: group, type: select, proxies: [node, blocked, dummy0, dummy1]}]\n", endpoints[0], endpoints[1])
	}
	s, err := Start([]byte(config), fd, p)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Stop()
	up, down, err := s.TrafficStats()
	if err != nil || up != 0 || down != 0 {
		t.Fatal("nonzero initial session totals", up, down, err)
	}
	if scenario == "select" {
		for _, input := range [][2]string{{"missing", "node"}, {"group", "missing"}, {"node", "node"}} {
			if err := s.Select(input[0], input[1]); err == nil {
				t.Fatalf("accepted invalid select %v", input)
			}
		}
		for i := 0; i < 2; i++ {
			if err := s.Select("group", fmt.Sprintf("dummy%d", i)); err != nil {
				t.Fatal(err)
			}
			_, _ = s.DelayTest("group", server.URL, 3000) // dummy returns 502 to CONNECT
			if proxyHits[i].Load() != 1 || proxyHits[1-i].Load() != int32(i) {
				t.Fatalf("URLTest did not use selected dummy %d: %d/%d", i, proxyHits[0].Load(), proxyHits[1].Load())
			}
		}
		if err := s.Select("group", "node"); err != nil {
			t.Fatal(err)
		}
		if _, err := s.DelayTest("group", server.URL, 3000); err != nil {
			t.Fatal(err)
		}
		if err := s.Select("group", "blocked"); err != nil {
			t.Fatal(err)
		}
		if _, err := s.DelayTest("group", server.URL, 3000); err == nil {
			t.Fatal("reject was not selected")
		}
		if requests.Load() != 1 {
			t.Fatal("selected route unexpectedly reached target", requests.Load())
		}
		var wg sync.WaitGroup
		for i := 0; i < 12; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				for j := 0; j < 20; j++ {
					if err := s.Select("group", []string{"node", "blocked"}[i%2]); err != nil {
						t.Error(err)
					}
					_, _ = s.DelayTest("group", server.URL, 3000)
				}
			}(i)
		}
		wg.Wait()
		if _, _, err := s.TrafficStats(); err != nil {
			t.Fatal(err)
		}
		if _, err := s.ConnectionsSnapshot(); err != nil {
			t.Fatal(err)
		}
		for i := 0; i < 8; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for j := 0; j < 100; j++ {
					if err := s.Select("group", "node"); err != nil && !errors.Is(err, ErrNotRunning) {
						t.Error(err)
						return
					}
				}
			}()
		}
		if err := s.Stop(); err != nil {
			t.Fatal(err)
		}
		wg.Wait()
		assertManagementRetired(t, s)
		return
	}
	if scenario == "success" {
		// The global singleton is not the adapter's aggregation source.
		statistic.DefaultManager.PushUploaded(900000)
		actualRoundTrip(t, fd, peer, &p.testProtector)
		up, down, err = s.TrafficStats()
		if err != nil || up != 4 || down != 4 {
			t.Fatalf("actual ping/pong totals %d/%d: %v", up, down, err)
		}
		data, err := s.ConnectionsSnapshot()
		if err != nil {
			t.Fatal(err)
		}
		var connections []Connection
		if err := json.Unmarshal(data, &connections); err != nil {
			t.Fatal(err)
		}
		if len(connections) != 1 || connections[0].Network != "udp" || connections[0].Upload != 4 || connections[0].Download != 4 || len(connections[0].Chains) == 0 || connections[0].Rule != "Match" || connections[0].Start.IsZero() {
			t.Fatalf("not the actual tracker: %s", data)
		}
		for _, input := range []struct {
			name, url string
			timeout   int
		}{
			{"missing", server.URL, 1000}, {"DIRECT", "http://127.0.0.1", 1000},
			{"DIRECT", strings.Replace(server.URL, "https://", "https://user:pass@", 1), 1000},
			{"DIRECT", server.URL, 0}, {"DIRECT", server.URL, 60001},
		} {
			if _, err := s.DelayTest(input.name, input.url, input.timeout); err == nil {
				t.Fatalf("unsafe delay accepted: %+v", input)
			}
		}
		if requests.Load() != 0 {
			t.Fatal("invalid probes reached server")
		}
		var wg sync.WaitGroup
		for i := 0; i < 24; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				name := []string{"DIRECT", "node", "group"}[i%3]
				if delay, err := s.DelayTest(name, server.URL, 5000); err != nil || delay < 1 {
					t.Errorf("concurrent native probe %d: %d %v", i, delay, err)
				}
			}(i)
		}
		wg.Wait()
		if requests.Load() != 24 || p.protects.Load() < 25 {
			t.Fatal("probes did not use protected sockets", requests.Load(), p.protects.Load())
		}
		// Management probes deliberately bypass tunnel trackers/traffic accounting.
		if up, down, err = s.TrafficStats(); err != nil || up != 4 || down != 4 {
			t.Fatal("probe polluted user traffic", up, down, err)
		}
	}
	if scenario == "timeout" {
		if _, err := s.DelayTest("DIRECT", server.URL+"/pending", 100); !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal("probe timeout", err)
		}
		if requests.Load() != 1 || p.protects.Load() == 0 {
			t.Fatal("timeout did not exercise actual protected request")
		}
	}
	if scenario == "refused" {
		if _, err := s.DelayTest("group", server.URL, 1000); !errors.Is(err, session.ErrProtection) {
			t.Fatal("false protector did not fail actual URLTest", err)
		}
		if p.protects.Load() == 0 || requests.Load() != 0 {
			t.Fatal("refused probe bypassed protection")
		}
	}
	if scenario == "certificate" {
		if _, err := s.DelayTest("DIRECT", server.URL, 1000); err == nil {
			t.Fatal("untrusted probe TLS succeeded")
		}
		if p.protects.Load() == 0 || requests.Load() != 0 {
			t.Fatal("certificate test did not use protected TLS")
		}
	}
	if scenario == "redirect" {
		sink := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { escaped.Add(1) }))
		defer sink.Close()
		redirect := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, sink.URL, 302) }))
		defer redirect.Close()
		if err := ca.AddCertificate(string(redirect.Certificate().Raw)); err != nil {
			t.Fatal(err)
		}
		if _, err := s.DelayTest("DIRECT", redirect.URL, 1000); err != nil {
			t.Fatal(err)
		}
		if escaped.Load() != 0 {
			t.Fatal("URLTest followed downgrade redirect")
		}
	}
	var wg sync.WaitGroup
	finished := make(chan struct{})
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-finished:
					return
				default:
				}
				_, _, err := s.TrafficStats()
				if err != nil && !errors.Is(err, ErrNotRunning) {
					t.Error(err)
					return
				}
				_, err = s.ConnectionsSnapshot()
				if err != nil && !errors.Is(err, ErrNotRunning) {
					t.Error(err)
					return
				}
			}
		}()
	}
	if scenario == "stop" {
		probe := make(chan error, 1)
		go func() {
			_, err := s.DelayTest("node", server.URL+"/pending", 60000)
			probe <- err
		}()
		providerEvent(t, entered)
		if err := s.Stop(); err != nil {
			t.Fatal(err)
		}
		if err := <-probe; !errors.Is(err, context.Canceled) {
			t.Fatal("Stop did not cancel probe", err)
		}
	} else if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	close(finished)
	wg.Wait()
	assertManagementRetired(t, s)
	if p.closed.Load() != 1 {
		t.Fatal("protector not released exactly once")
	}
}

// Synthetic trackers exercise only serialization bounds, not networking proof.
type snapshotTracker struct {
	statistic.Tracker
	id   string
	info *statistic.TrackerInfo
}

func (t snapshotTracker) ID() string                   { return t.id }
func (t snapshotTracker) Info() *statistic.TrackerInfo { return t.info }

func TestManagementScopeAndBounds(t *testing.T) {
	a, b := &Session{management: newManagement(new(statistic.Manager))}, &Session{management: newManagement(new(statistic.Manager))}
	a.management.running, b.management.running = true, true
	defer a.management.retire()
	defer b.management.retire()
	a.management.stats.PushUploaded(123)
	b.management.stats.PushDownloaded(456)
	if up, down, err := a.TrafficStats(); up != 123 || down != 0 || err != nil {
		t.Fatal(up, down, err)
	}
	if up, down, err := b.TrafficStats(); up != 0 || down != 456 || err != nil {
		t.Fatal(up, down, err)
	}
	if allocs := testing.AllocsPerRun(1000, func() { _, _, _ = a.TrafficStats() }); allocs != 0 {
		t.Fatal("polling allocates", allocs)
	}
	for i := 0; i <= MaxSnapshotConnections; i++ {
		a.management.stats.Join(snapshotTracker{id: fmt.Sprint(i), info: &statistic.TrackerInfo{}})
	}
	if data, err := a.ConnectionsSnapshot(); !errors.Is(err, ErrSnapshotTooLarge) || data != nil {
		t.Fatal("large snapshot was not rejected", len(data), err)
	}
	b.management.stats.Join(snapshotTracker{id: "huge", info: &statistic.TrackerInfo{RulePayload: strings.Repeat("x", 65537)}})
	if data, err := b.ConnectionsSnapshot(); !errors.Is(err, ErrSnapshotTooLarge) || data != nil {
		t.Fatal("unbounded individual row", len(data), err)
	}
}

func BenchmarkTrafficStats(b *testing.B) {
	s := &Session{management: newManagement(new(statistic.Manager))}
	s.management.running = true
	defer s.management.retire()
	b.ReportAllocs()
	for b.Loop() {
		_, _, _ = s.TrafficStats()
	}
}
