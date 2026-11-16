// Package mihomodns intercepts explicitly selected DNS destinations using the
// configured Mihomo DefaultService. It does not configure DNS or create sockets.
package mihomodns

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"sync"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
)

var (
	ErrTargets    = errors.New("DNS interception requires concrete destination addresses and ports")
	ErrService    = errors.New("Mihomo DefaultService must be configured before DNS interception")
	ErrSocketHook = errors.New("Mihomo protected socket hook must be installed before DNS interception")
	ErrStopped    = errors.New("DNS session stopped")
)

// Session owns admitted relay calls, not Mihomo's process-global resolver
// workers. Construct one per worker process after configuring native DNS and
// installing its protected socket hook. Do not replace either global while it
// is running. An old process must exit before another session uses its state.
type Session struct {
	targets  map[netip.AddrPort]struct{}
	wildcard bool
	mu       sync.Mutex
	stopped  bool
	active   map[*operation]struct{}
	calls    sync.WaitGroup
}

type operation struct {
	ctx    context.Context
	cancel context.CancelFunc
}

// New selects only the supplied exact destinations. It has no implicit Android
// address, wildcard hijacking, DNS config rewrite, or routing fallback.
func New(targets []netip.AddrPort) (*Session, error) {
	return newRelaySession(targets, false)
}

// NewHijack additionally accepts explicit unspecified-address :53 targets,
// matching pinned sing_tun's wildcard semantics for BOTH UDP and TCP.
func NewHijack(targets []netip.AddrPort) (*Session, error) {
	return newRelaySession(targets, true)
}

func newRelaySession(targets []netip.AddrPort, allowWildcard bool) (*Session, error) {
	if len(targets) == 0 {
		return nil, ErrTargets
	}
	selected := make(map[netip.AddrPort]struct{}, len(targets))
	wildcard := false
	for _, target := range targets {
		if !target.IsValid() || target.Port() == 0 || (target.Addr().IsUnspecified() && (!allowWildcard || target.Port() != 53)) {
			return nil, fmt.Errorf("%w: %s", ErrTargets, target)
		}
		selected[target] = struct{}{}
		wildcard = wildcard || target.Addr().IsUnspecified()
	}
	if resolver.DefaultService == nil {
		return nil, ErrService
	}
	if dialer.DefaultSocketHook == nil {
		return nil, ErrSocketHook
	}
	return &Session{targets: selected, wildcard: wildcard, active: make(map[*operation]struct{})}, nil
}

// Matches allows the TUN owner to select the path before obtaining a UDP writer.
// Matching stays stable after Stop so late DNS packets cannot escape to routing.
func (s *Session) Matches(destination netip.AddrPort) bool {
	_, ok := s.targets[destination]
	return ok || (s.wildcard && destination.Port() == 53)
}

func (s *Session) begin(ctx context.Context) (*operation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopped {
		return nil, ErrStopped
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	op := &operation{ctx: ctx, cancel: cancel}
	s.active[op] = struct{}{}
	s.calls.Add(1)
	return op, nil
}

func (s *Session) finish(op *operation) {
	op.cancel()
	s.mu.Lock()
	delete(s.active, op)
	s.mu.Unlock()
	s.calls.Done()
}

// Stop closes admission and cancels admitted requests. TCP cancellation closes
// the stream. A sing PacketWriter has no Close or context API: the TUN owner must
// also interrupt its packet transport before Wait to unblock any pending write.
func (s *Session) Stop() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stopped = true
	for op := range s.active {
		op.cancel()
	}
}

// Wait first calls Stop and then joins every admitted relay call and its TCP
// cancellation callback. It never reports a false drain on timeout. Before
// calling it, interrupt the packet writer transport and join dispatchers that
// could still invoke HandleTCP/HandleUDP. It does not join upstream DNS workers;
// terminating and reaping the worker process is the final teardown barrier.
func (s *Session) Wait() {
	s.Stop()
	s.calls.Wait()
}

// HandleTCP returns false without touching conn for an unselected destination.
// For a selected destination it always owns and closes conn, even on rejection.
// Calls are synchronous; the TUN owner owns and joins its dispatch goroutines.
func (s *Session) HandleTCP(ctx context.Context, conn net.Conn, destination netip.AddrPort) (bool, error) {
	if !s.Matches(destination) {
		return false, nil
	}
	op, err := s.begin(ctx)
	if err != nil {
		return true, errors.Join(err, conn.Close())
	}
	defer s.finish(op)

	closed := make(chan struct{})
	var closeErr error
	stopClose := context.AfterFunc(op.ctx, func() {
		closeErr = conn.Close()
		close(closed)
	})
	err = resolver.RelayDnsConn(op.ctx, conn, resolver.DefaultDnsReadTimeout)
	if !stopClose() {
		<-closed
	}
	if errors.Is(closeErr, net.ErrClosed) {
		closeErr = nil
	}
	return true, errors.Join(err, op.ctx.Err(), closeErr)
}
