// Package diagnostics joins the real packet, DNS and protected-socket modules
// into a DNS diagnostic. It is not a profile executor or a complete VPN.
package diagnostics

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"

	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	coreDNS "github.com/metacubex/mihomo/dns"
	"github.com/metacubex/sing/common/buf"
	M "github.com/metacubex/sing/common/metadata"
	foundation "proxima.local/mihomo"
	mihomodns "proxima.local/mihomo-dns"
	mihomoruntime "proxima.local/mihomo-runtime"
	"proxima.local/mihomo/session"
)

var (
	ErrProcessUsed = errors.New("diagnostic process already used; terminate and reap it before another session")
	ErrNonDNS      = errors.New("DNS diagnostic received an unselected flow; full VPN routing is not implemented")
)

var process struct {
	sync.Mutex
	used bool
}

// Options are explicit diagnostic settings, never derived by rewriting a
// profile. Upstream must be a literal IP:port; no system/bootstrap resolver runs.
type Options struct {
	Stack       string
	MTU         uint32
	Destination netip.AddrPort
	Upstream    netip.AddrPort
	Network     string
}

// Session is one process's diagnostic lifetime. Done certifies local drain,
// not termination of upstream global workers. Stop then revokes the lease.
// The supervisor must still terminate and reap the process.
type Session struct {
	token     session.Token
	packets   *mihomoruntime.Session
	dns       *mihomodns.Session
	tunnel    *dnsTunnel
	protector *protector
	failures  chan error
	stop      chan struct{}
	done      chan struct{}
	stopOnce  sync.Once
	closeMu   sync.Mutex
	closeErr  error
	closed    bool
	result    error
}

type protector struct {
	allowed atomic.Bool
	protect func(int) bool
	fail    func(error)
}

func (p *protector) Protect(fd int) bool {
	if !p.allowed.Load() {
		return false
	}
	if !p.protect(fd) {
		p.fail(session.ErrProtection)
		return false
	}
	return true
}

// Callback ownership stays with the caller until Start fails or Stop returns.
// Registry.Close drains in-flight callbacks before this method is called.
func (p *protector) Close() error { return nil }

// Start borrows fd and protect. It returns only after the real packet stack
// starts. Exactly one admitted attempt is allowed for the entire OS process,
// including failed startup. The caller keeps fd stable until this returns and
// keeps the callback alive until Stop; a failed Start has already drained it.
func Start(fd int, options Options, protect func(int) bool) (*Session, error) {
	if options.Stack != "mips" {
		return nil, fmt.Errorf("DNS diagnostic requires explicit mips stack, got %q; system/gvisor/mixed are not implemented", options.Stack)
	}
	if options.MTU == 0 || protect == nil {
		return nil, errors.New("diagnostic MTU and socket protector are required")
	}
	for _, addr := range []netip.AddrPort{options.Destination, options.Upstream} {
		if !addr.IsValid() || addr.Port() == 0 || addr.Addr().IsUnspecified() || addr.Addr().IsMulticast() {
			return nil, errors.New("diagnostic DNS endpoints must be concrete unicast IP:port addresses")
		}
	}
	if options.Network != "udp" && options.Network != "tcp" {
		return nil, errors.New("diagnostic DNS upstream transport must be udp or tcp")
	}
	process.Lock()
	defer process.Unlock()
	if process.used {
		return nil, ErrProcessUsed
	}
	process.used = true
	s := &Session{failures: make(chan error, 1), stop: make(chan struct{}), done: make(chan struct{})}
	s.protector = &protector{protect: protect, fail: s.fail}
	s.protector.allowed.Store(true)
	token, err := foundation.Sessions.Prepare(fd, s.protector)
	if err != nil {
		return nil, fmt.Errorf("prepare protected diagnostic session: %w", err)
	}
	s.token = token
	rollback := func(cause error) (*Session, error) {
		s.protector.allowed.Store(false)
		if s.tunnel != nil {
			s.tunnel.stopAdmission()
		}
		if s.dns != nil {
			s.dns.Stop()
			if s.tunnel != nil {
				s.tunnel.calls.Wait()
			}
			s.dns.Wait()
		}
		return nil, errors.Join(cause, foundation.Sessions.Close(token))
	}
	// This process owns these globals until exit. There is no in-process reset
	// or resolver replacement, even after failed startup.
	rs := coreDNS.NewResolver(coreDNS.Config{
		Main: []coreDNS.NameServer{{Net: options.Network, Addr: options.Upstream.String()}},
		IPv6: true,
	})
	resolver.DefaultService = coreDNS.NewService(rs.Resolver, coreDNS.NewEnhancer(coreDNS.EnhancerConfig{
		IPv6: true, EnhancedMode: C.DNSNormal,
	}))
	s.dns, err = mihomodns.New([]netip.AddrPort{options.Destination})
	if err != nil {
		return rollback(err)
	}
	s.tunnel = &dnsTunnel{dns: s.dns, fail: s.fail}
	s.packets, err = mihomoruntime.OpenBorrowed(fd, mihomoruntime.Options{
		Stack: options.Stack, MTU: options.MTU,
	}, s.tunnel)
	if err != nil {
		return rollback(err)
	}
	go s.run()
	return s, nil
}

func (s *Session) fail(err error) {
	select {
	case s.failures <- err:
	default:
	}
}

func (s *Session) run() {
	select {
	case s.result = <-s.failures:
	case <-s.packets.ReadDone():
		s.result = fmt.Errorf("diagnostic packet input stopped: %w", s.packets.ReadError())
	case <-s.stop:
	}
	s.protector.allowed.Store(false)
	s.tunnel.stopAdmission()
	s.dns.Stop()
	// DNS cancellation precedes TCP drain; packet transport interruption
	// precedes joining UDP dispatchers that may be writing a reply.
	s.result = errors.Join(s.result, s.packets.Close())
	s.tunnel.calls.Wait()
	s.dns.Wait()
	close(s.done)
}

// Done is a local drain/failure notification. The process still must exit.
func (s *Session) Done() <-chan struct{} { return s.done }

// Wait blocks until local packet and DNS work has drained and returns the real
// terminal cause. It does not revoke/release the callback: call Stop afterwards.
func (s *Session) Wait() error {
	<-s.done
	return s.result
}

// Stop is concurrent/idempotent. After it returns, no callback can still use
// the caller's protector. Existing core-global resolver workers are not joined;
// they cannot create protected sockets, and this process cannot start again.
func (s *Session) Stop() error {
	s.closeMu.Lock()
	defer s.closeMu.Unlock()
	if s.closed {
		return s.closeErr
	}
	s.stopOnce.Do(func() { close(s.stop) })
	<-s.done
	s.closeErr = errors.Join(s.result, foundation.Sessions.Close(s.token))
	s.closed = true
	return s.closeErr
}

type dnsTunnel struct {
	dns     *mihomodns.Session
	fail    func(error)
	mu      sync.Mutex
	stopped bool
	calls   sync.WaitGroup
}

func (t *dnsTunnel) admit() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.stopped {
		return false
	}
	t.calls.Add(1)
	return true
}

func (t *dnsTunnel) stopAdmission() {
	t.mu.Lock()
	t.stopped = true
	t.mu.Unlock()
}

func (t *dnsTunnel) HandleTCPConn(conn net.Conn, metadata *C.Metadata) {
	if !t.admit() {
		_ = conn.Close()
		return
	}
	defer t.calls.Done()
	handled, err := t.dns.HandleTCP(context.Background(), conn, netip.AddrPortFrom(metadata.DstIP, metadata.DstPort))
	if !handled {
		_ = conn.Close()
		t.fail(ErrNonDNS)
	} else if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, net.ErrClosed) && !errors.Is(err, mihomodns.ErrStopped) {
		t.fail(err)
	}
}

func (t *dnsTunnel) HandleUDPPacket(packet C.UDPPacket, metadata *C.Metadata) {
	if !t.admit() {
		packet.Drop()
		return
	}
	destination := netip.AddrPortFrom(metadata.DstIP, metadata.DstPort)
	if !t.dns.Matches(destination) {
		packet.Drop()
		t.fail(ErrNonDNS)
		t.calls.Done()
		return
	}
	// The native sing callback transfers its packet. Retain it until the reply
	// writer returns; the copied request is separately owned by the DNS module.
	go func() {
		defer t.calls.Done()
		defer packet.Drop()
		request := buf.NewSize(len(packet.Data()))
		_, _ = request.Write(packet.Data())
		_, err := t.dns.HandleUDP(context.Background(), request, M.SocksaddrFromNetIP(destination), packetWriter{packet})
		if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, mihomodns.ErrStopped) {
			t.fail(err)
		}
	}()
}

// The raw packet handler never consults a NAT table on this DNS-only path.
func (*dnsTunnel) NatTable() C.NatTable { return nil }

type packetWriter struct{ packet C.UDPPacket }

func (w packetWriter) WritePacket(reply *buf.Buffer, destination M.Socksaddr) error {
	_, err := w.packet.WriteBack(reply.Bytes(), destination.UDPAddr())
	if err == nil {
		reply.Release()
	}
	return err
}
