package engine

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"sync"

	"github.com/metacubex/mihomo/config"
	P "github.com/metacubex/mihomo/constant/provider"
)

var (
	ErrConsumed = errors.New("provider initialization stage already consumed")
	ErrStopped  = errors.New("provider initialization stage stopped")
)

// ProviderError preserves the actual Initial error for errors.Is/errors.As.
type ProviderError struct {
	Kind string
	Name string
	Err  error
}

func (e *ProviderError) Error() string {
	return fmt.Sprintf("initialize %s provider %q: %v", e.Kind, e.Name, e.Err)
}
func (e *ProviderError) Unwrap() error { return e.Err }

type providerEntry struct {
	kind     string
	name     string
	provider P.Provider
}

// ProviderStage owns one attempt, not the providers themselves. The caller must
// have established private paths, protected networking, and any required routing
// before constructing providers. Config must correspond to the supplied revision.
// This stage cannot establish that semantic relationship on the caller's behalf.
type ProviderStage struct {
	mu        sync.Mutex
	revision  Revision
	providers []providerEntry
	consumed  bool
	stopped   bool
	cancel    context.CancelFunc
	done      chan struct{}
}

func NewProviderStage(revision Revision, cfg *config.Config) (*ProviderStage, error) {
	if cfg == nil {
		return nil, errors.New("parsed Mihomo configuration is required")
	}
	s := &ProviderStage{revision: revision}
	for name, provider := range cfg.Providers {
		if provider == nil {
			return nil, fmt.Errorf("nil proxy provider %q", name)
		}
		s.providers = append(s.providers, providerEntry{"proxy", name, provider})
	}
	for name, provider := range cfg.RuleProviders {
		if provider == nil {
			return nil, fmt.Errorf("nil rule provider %q", name)
		}
		s.providers = append(s.providers, providerEntry{"rule", name, provider})
	}
	// Proxy providers must precede rules; stable names make the first error
	// deterministic. No concurrent Initial calls or background success path.
	sort.Slice(s.providers, func(i, j int) bool {
		a, b := s.providers[i], s.providers[j]
		if a.kind != b.kind {
			return a.kind < b.kind
		}
		return a.name < b.name
	})
	return s, nil
}

// Initialize calls each admitted provider's real Initial exactly once. The first
// failure stops admission; unattempted providers remain uninitialized. Nil means
// only that these Initial calls returned nil. It is never executor readiness.
//
// Upstream Initial has no context parameter. Cancellation/Stop therefore waits
// for an in-flight Initial to return and then rejects its result. Do not turn
// this into an abandoned goroutine: its workers could outlive the protection
// lease. A supervisor must terminate and reap a stuck session process.
func (s *ProviderStage) Initialize(ctx context.Context, expected Revision) error {
	s.mu.Lock()
	if s.stopped {
		s.mu.Unlock()
		return ErrStopped
	}
	if s.consumed {
		s.mu.Unlock()
		return ErrConsumed
	}
	if expected != s.revision {
		s.mu.Unlock()
		return ErrStale
	}
	if err := ctx.Err(); err != nil {
		s.mu.Unlock()
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	s.consumed, s.cancel, s.done = true, cancel, make(chan struct{})
	s.mu.Unlock()
	defer func() {
		cancel()
		close(s.done)
	}()
	for _, entry := range s.providers {
		if err := s.admit(ctx); err != nil {
			return err
		}
		err := entry.provider.Initial()
		if err != nil {
			return errors.Join(&ProviderError{entry.kind, entry.name, err}, ctx.Err())
		}
		if err := ctx.Err(); err != nil {
			return err
		}
	}
	return ctx.Err()
}

// A nil context observation while holding mu is the per-provider admission
// point. Stop closes admission under this same mutex. If admission wins, that
// call may enter Initial after Stop begins, but Stop must drain it. Parent
// cancellation observed before this point rejects the call; cancellation after
// admission cannot revoke it and is checked again when Initial returns.
func (s *ProviderStage) admit(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopped {
		return context.Canceled
	}
	return ctx.Err()
}

// Stop permanently closes admission and waits for the admitted Initial call.
// It does NOT close providers or join their background workers. Keep paths and
// the socket lease alive until the owner has joined them or reaped the process.
func (s *ProviderStage) Stop() {
	s.mu.Lock()
	s.stopped = true
	if s.cancel != nil {
		s.cancel()
	}
	done := s.done
	s.mu.Unlock()
	if done != nil {
		<-done
	}
}
