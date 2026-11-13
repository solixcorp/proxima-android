package engine

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	proxyprovider "github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/component/resource"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/rules/bundle"
	ruleprovider "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
	"proxima.local/mihomo-provider/boundary"
)

var testRoot string

func TestMain(m *testing.M) {
	var err error
	testRoot, err = os.MkdirTemp("", "mihomo-engine-")
	if err != nil {
		panic(err)
	}
	if err := os.Chmod(testRoot, 0o700); err != nil {
		panic(err)
	}
	if err := boundary.ConfigureRoot(testRoot); err != nil {
		panic(err)
	}
	C.SetHomeDir(testRoot)
	C.SetConfig(filepath.Join(testRoot, "effective.yaml"))
	// config.parseRuleProviders registers this real callback before constructing
	// providers. These factory-level tests deliberately do not run semantic parse.
	ruleprovider.SetTunnel(tunnel.Tunnel)
	code := m.Run()
	if cachefile.Cache().DB != nil {
		if err := cachefile.Cache().Close(); err != nil {
			code = 1
		}
	}
	if err := boundary.CloseRoot(); err != nil {
		code = 1
	}
	if err := os.RemoveAll(testRoot); err != nil {
		code = 1
	}
	os.Exit(code)
}

func closeProvider(t *testing.T, provider any) {
	t.Helper()
	closer, ok := provider.(io.Closer)
	if !ok {
		t.Fatal("actual provider lacks Close")
	}
	t.Cleanup(func() {
		if err := closer.Close(); err != nil {
			t.Error(err)
		}
	})
}

func actualRule(t *testing.T, name, path string) P.RuleProvider {
	t.Helper()
	provider, err := ruleprovider.ParseRuleProvider(name, map[string]any{
		"type": "file", "behavior": "domain", "path": path,
	}, nil, bundle.MakeBundleFile)
	if err != nil {
		t.Fatal(err)
	}
	closeProvider(t, provider)
	return provider
}

func TestRealRuleProviderInitialErrorIsReturned(t *testing.T) {
	provider := actualRule(t, "missing", "absent/rules.yaml")
	stage, err := NewProviderStage(Revision{}, &config.Config{RuleProviders: map[string]P.RuleProvider{"missing": provider}})
	if err != nil {
		t.Fatal(err)
	}
	err = stage.Initialize(context.Background(), Revision{})
	var failure *ProviderError
	if !errors.As(err, &failure) || failure.Kind != "rule" || failure.Name != "missing" || !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("real missing-file Initial error not preserved: %v", err)
	}
	if err := stage.Initialize(context.Background(), Revision{}); !errors.Is(err, ErrConsumed) {
		t.Fatal(err)
	}
	stage.Stop()
}

func TestRealProxyProviderPayloadErrorIsReturned(t *testing.T) {
	path := "proxy/invalid.yaml"
	if err := resource.NewFileVehicle(filepath.Join(testRoot, path)).Write([]byte("proxies:\n  - {name: broken, type: unsupported-protocol}\n")); err != nil {
		t.Fatal(err)
	}
	provider, err := proxyprovider.ParseProxyProvider("bad-proxy", map[string]any{"type": "file", "path": path}, nil)
	if err != nil {
		t.Fatal(err)
	}
	closeProvider(t, provider)
	stage, err := NewProviderStage(Revision{}, &config.Config{Providers: map[string]P.ProxyProvider{"bad-proxy": provider}})
	if err != nil {
		t.Fatal(err)
	}
	var failure *ProviderError
	if err := stage.Initialize(context.Background(), Revision{}); !errors.As(err, &failure) || failure.Kind != "proxy" {
		t.Fatalf("actual proxy payload error lost: %v", err)
	}
}

func TestFirstRealProviderFailurePreventsLaterInitialization(t *testing.T) {
	first := actualRule(t, "a-missing", "first/missing.yaml")
	later := &heldRule{
		RuleProvider: actualRule(t, "z-later", "later/missing.yaml"),
		entered:      make(chan struct{}), release: make(chan struct{}),
	}
	close(later.release)
	cfg := &config.Config{RuleProviders: map[string]P.RuleProvider{"z-later": later, "a-missing": first}}
	stage, err := NewProviderStage(Revision{}, cfg)
	if err != nil {
		t.Fatal(err)
	}
	delete(cfg.RuleProviders, "a-missing")
	err = stage.Initialize(context.Background(), Revision{})
	if !errors.Is(err, os.ErrNotExist) || later.calls.Load() != 0 {
		t.Fatalf("failure was swallowed or provider map was not captured: %v", err)
	}
}

func TestRealRuleProviderInitialLoadsRules(t *testing.T) {
	path := "rules/valid.yaml"
	if err := resource.NewFileVehicle(filepath.Join(testRoot, path)).Write([]byte("payload:\n  - example.com\n  - example.org\n")); err != nil {
		t.Fatal(err)
	}
	provider := actualRule(t, "valid", path)
	stage, err := NewProviderStage(Revision{}, &config.Config{RuleProviders: map[string]P.RuleProvider{"valid": provider}})
	if err != nil {
		t.Fatal(err)
	}
	if err := stage.Initialize(context.Background(), Revision{}); err != nil {
		t.Fatal(err)
	}
	if provider.Count() != 2 {
		t.Fatalf("actual provider did not load: count=%d", provider.Count())
	}
	stage.Stop()
}

func TestComposedProviderBoundaryRejectsUnsafePathAndURL(t *testing.T) {
	for _, mapping := range []map[string]any{
		{"type": "file", "behavior": "domain", "path": "../outside.yaml"},
		{"type": "http", "behavior": "domain", "url": "http://127.0.0.1:1/provider"},
	} {
		_, err := ruleprovider.ParseRuleProvider("unsafe", mapping, nil, bundle.MakeBundleFile)
		if !errors.Is(err, boundary.ErrPath) && !errors.Is(err, boundary.ErrURL) {
			t.Fatalf("required provider overlay missing: %v", err)
		}
	}
}

// This wrapper controls timing only; the embedded provider is an actual core
// provider. Real provider parsing and failure behavior are tested above.
type heldRule struct {
	P.RuleProvider
	entered chan struct{}
	release chan struct{}
	calls   atomic.Int32
	err     error
}

func (p *heldRule) Initial() error {
	p.calls.Add(1)
	close(p.entered)
	<-p.release
	return p.err
}

func TestStopWaitsForAdmittedInitialAndCannotPublishSuccess(t *testing.T) {
	held := &heldRule{
		RuleProvider: actualRule(t, "held", "held/absent.yaml"),
		entered:      make(chan struct{}), release: make(chan struct{}),
	}
	stage, err := NewProviderStage(Revision{}, &config.Config{RuleProviders: map[string]P.RuleProvider{"held": held}})
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() { result <- stage.Initialize(context.Background(), Revision{}) }()
	select {
	case <-held.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("Initial not admitted")
	}
	cancelled := make(chan struct{})
	var once sync.Once
	stage.mu.Lock()
	cancel := stage.cancel
	stage.cancel = func() { cancel(); once.Do(func() { close(cancelled) }) }
	stage.mu.Unlock()
	stopped := make(chan struct{})
	go func() { stage.Stop(); close(stopped) }()
	select {
	case <-cancelled:
	case <-time.After(5 * time.Second):
		t.Fatal("Stop failed to cancel")
	}
	select {
	case <-stopped:
		t.Fatal("Stop returned while Initial was blocked")
	default:
	}
	close(held.release)
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancelled Initial reported success: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Initialize failed to return")
	}
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		t.Fatal("Stop failed to join Initial")
	}
	if held.calls.Load() != 1 {
		t.Fatal("Initial repeated")
	}
	if err := stage.Initialize(context.Background(), Revision{}); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
}

func TestStaleCancelledAndStoppedStagesDoNotInitialize(t *testing.T) {
	held := &heldRule{RuleProvider: actualRule(t, "never", "never/absent.yaml"), entered: make(chan struct{}), release: make(chan struct{})}
	stage, err := NewProviderStage(RevisionOf([]byte("old")), &config.Config{RuleProviders: map[string]P.RuleProvider{"never": held}})
	if err != nil {
		t.Fatal(err)
	}
	if err := stage.Initialize(context.Background(), RevisionOf([]byte("new"))); !errors.Is(err, ErrStale) {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := stage.Initialize(ctx, RevisionOf([]byte("old"))); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	stage.Stop()
	if err := stage.Initialize(context.Background(), RevisionOf([]byte("old"))); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
	if held.calls.Load() != 0 {
		t.Fatal("inadmissible provider was initialized")
	}
}

func TestConcurrentInitializeAdmitsOnlyOnce(t *testing.T) {
	provider := &heldRule{RuleProvider: actualRule(t, "one", "one/absent.yaml"), entered: make(chan struct{}), release: make(chan struct{})}
	close(provider.release)
	stage, err := NewProviderStage(Revision{}, &config.Config{RuleProviders: map[string]P.RuleProvider{"one": provider}})
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	var successes atomic.Int32
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			err := stage.Initialize(context.Background(), Revision{})
			if err == nil {
				successes.Add(1)
			} else if !errors.Is(err, ErrConsumed) {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if successes.Load() != 1 || provider.calls.Load() != 1 {
		t.Fatal("provider initialized more than once")
	}
}
