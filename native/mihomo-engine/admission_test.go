package engine

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"

	"github.com/metacubex/mihomo/config"
	P "github.com/metacubex/mihomo/constant/provider"
)

// Admission is a synchronization boundary: Err must be observed while holding
// the same lock that closes admission. This probe deterministically detects the
// original unlocked check/call gap without relying on goroutine scheduling.
type admissionContext struct {
	context.Context
	check func()
}

func (c admissionContext) Err() error {
	c.check()
	return c.Context.Err()
}

func TestProviderAdmissionSerializesWithStop(t *testing.T) {
	stage := &ProviderStage{}
	checked := false
	ctx := admissionContext{Context: context.Background(), check: func() {
		checked = true
		if stage.mu.TryLock() {
			stage.mu.Unlock()
			t.Error("provider admission checked context outside Stop mutex")
		}
	}}
	if err := stage.admit(ctx); err != nil {
		t.Fatal(err)
	}
	if !checked {
		t.Fatal("provider admission did not observe cancellation")
	}
	stage.Stop()
	// Use an uncancelled context to verify Stop's admission state itself.
	if err := stage.admit(context.Background()); !errors.Is(err, context.Canceled) {
		t.Fatalf("provider admitted after Stop closed admission: %v", err)
	}
}

func TestStopPreventsNextProviderAdmission(t *testing.T) {
	first := actualRule(t, "a-first", "stop-first/absent.yaml")
	later := actualRule(t, "z-later", "stop-later/absent.yaml")
	synctest.Test(t, func(t *testing.T) {
		a := &heldRule{RuleProvider: first, entered: make(chan struct{}), release: make(chan struct{})}
		b := &heldRule{RuleProvider: later, entered: make(chan struct{}), release: make(chan struct{})}
		close(b.release)
		stage, err := NewProviderStage(Revision{}, &config.Config{RuleProviders: map[string]P.RuleProvider{
			"a-first": a, "z-later": b,
		}})
		if err != nil {
			t.Fatal(err)
		}
		result := make(chan error, 1)
		go func() { result <- stage.Initialize(context.Background(), Revision{}) }()
		<-a.entered
		stopped := make(chan struct{})
		go func() { stage.Stop(); close(stopped) }()
		// A is held in Initial; Stop must close admission then block on its drain.
		synctest.Wait()
		if err := stage.Initialize(context.Background(), Revision{}); !errors.Is(err, ErrStopped) {
			t.Errorf("Stop did not close admission: %v", err)
		}
		select {
		case <-stopped:
			t.Error("Stop returned before admitted Initial finished")
		default:
		}
		close(a.release)
		synctest.Wait()
		if err := <-result; !errors.Is(err, context.Canceled) {
			t.Errorf("stopped attempt reported success: %v", err)
		}
		<-stopped
		if a.calls.Load() != 1 || b.calls.Load() != 0 {
			t.Fatalf("admission after Stop: first=%d later=%d", a.calls.Load(), b.calls.Load())
		}
	})
}

func TestParentCancellationPreventsNextProviderAdmission(t *testing.T) {
	first := actualRule(t, "a-first", "cancel-first/absent.yaml")
	later := actualRule(t, "z-later", "cancel-later/absent.yaml")
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		a := &heldRule{RuleProvider: first, entered: make(chan struct{}), release: make(chan struct{})}
		b := &heldRule{RuleProvider: later, entered: make(chan struct{}), release: make(chan struct{})}
		close(b.release)
		stage, err := NewProviderStage(Revision{}, &config.Config{RuleProviders: map[string]P.RuleProvider{
			"a-first": a, "z-later": b,
		}})
		if err != nil {
			t.Fatal(err)
		}
		result := make(chan error, 1)
		go func() { result <- stage.Initialize(ctx, Revision{}) }()
		<-a.entered
		cancel()
		close(a.release)
		synctest.Wait()
		if err := <-result; !errors.Is(err, context.Canceled) {
			t.Errorf("cancelled attempt reported success: %v", err)
		}
		if a.calls.Load() != 1 || b.calls.Load() != 0 {
			t.Fatalf("admission after parent cancellation: first=%d later=%d", a.calls.Load(), b.calls.Load())
		}
		stage.Stop()
	})
}
