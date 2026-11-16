// Package mihomoruntime owns a raw-IP packet descriptor and Mihomo's mips stack.
// It does not configure Mihomo, start providers, or establish VPN connectivity.
package mihomoruntime

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter/inbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/sing"
	"github.com/metacubex/mihomo/log"
	tun "github.com/metacubex/sing-tun"
	"github.com/metacubex/sing/common/buf"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
	"golang.org/x/sys/unix"
	mihomodns "proxima.local/mihomo-dns"
	"proxima.local/mihomo-dns/diagnostic"
)

// Options describes the already-established raw-IP device. MTU must match the
// device. Stack is mandatory; only "mips" is supported by this component.
type Options struct {
	Stack                string
	MTU                  uint32
	TCPCongestionControl string
	// Optional pinned sing_tun DNS hijack destinations. DNS must be initialized.
	DNSHijack []netip.AddrPort
}

// Session is a single-use packet-stack owner. A successful OpenBorrowed means
// local stack initialization completed, not that a VPN is connected.
// Close serializes teardown and is safe to call concurrently and repeatedly.
type Session struct {
	mu       sync.Mutex
	device   *os.File
	stack    *tun.Mipstack
	handler  *flowHandler
	cancel   context.CancelFunc
	closed   bool
	closeErr error
}

// OpenBorrowed duplicates fd with close-on-exec; it never adopts or closes fd.
// The caller must keep fd open and stable until this call returns, and must
// supply a nonblocking descriptor carrying complete IP packets without framing.
// All descriptor aliases must preserve O_NONBLOCK for the session's lifetime.
// Android VpnService establishes and validates the actual TUN, routes and MTU.
// fd 0 is valid. All acquired resources are rolled back on any startup error.
//
// The supplied tunnel must already have its own protected-network and lifetime
// policy. This function does not start or stop the tunnel's external workers.
func OpenBorrowed(fd int, options Options, tunnel C.Tunnel) (session *Session, err error) {
	if options.Stack != "mips" {
		return nil, fmt.Errorf("unsupported stack %q: this component requires mips", options.Stack)
	}
	if tunnel == nil {
		return nil, errors.New("tunnel is required")
	}
	if options.MTU == 0 {
		return nil, errors.New("the established device MTU is required")
	}
	duplicate, err := unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, 3)
	if err != nil {
		return nil, fmt.Errorf("duplicate packet fd: %w", err)
	}
	// O_NONBLOCK is shared by dup's open-file description. Do not change the
	// caller's flags. Go's pollable os.File can interrupt reads/writes on Close.
	flags, err := unix.FcntlInt(uintptr(duplicate), unix.F_GETFL, 0)
	if err != nil || flags&unix.O_NONBLOCK == 0 {
		closeErr := unix.Close(duplicate)
		if err == nil {
			err = errors.New("packet fd must already be nonblocking")
		}
		return nil, errors.Join(err, closeErr)
	}
	s := &Session{device: os.NewFile(uintptr(duplicate), "mihomo-packet")}
	defer func() {
		if err != nil {
			err = errors.Join(err, s.Close())
		}
	}()
	info, err := s.device.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat packet fd: %w", err)
	}
	if info.Mode()&(os.ModeCharDevice|os.ModeSocket) == 0 {
		return nil, errors.New("packet fd must be a TUN character device or packet socket")
	}
	// Darwin can register a regular file with kqueue, so pollability alone is
	// not a packet-device check. Also require interruptible I/O for valid types.
	if err = s.device.SetReadDeadline(time.Time{}); err != nil {
		return nil, fmt.Errorf("packet fd is not pollable: %w", err)
	}
	if err = s.device.SetWriteDeadline(time.Time{}); err != nil {
		return nil, fmt.Errorf("packet fd is not writable through the poller: %w", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	handler, err := sing.NewListenerHandler(sing.ListenerConfig{
		Tunnel: tunnel,
		Type:   C.TUN,
		Additions: []inbound.Addition{
			inbound.WithInName("PROXIMA-TUN"),
		},
	})
	if err != nil {
		return nil, fmt.Errorf("create Mihomo packet handler: %w", err)
	}
	s.handler = &flowHandler{ListenerHandler: handler, conns: make(map[net.Conn]struct{})}
	if len(options.DNSHijack) != 0 {
		s.handler.dns, err = mihomodns.NewHijack(options.DNSHijack)
		if err != nil {
			return nil, fmt.Errorf("initialize DNS interception: %w", err)
		}
	}
	stack, err := tun.NewStack(options.Stack, tun.StackOptions{
		Context:              ctx,
		Tun:                  s.device,
		TunOptions:           tun.Options{MTU: options.MTU},
		Handler:              s.handler,
		Logger:               log.SingLogger,
		ICMPTimeout:          sing.ICMPTimeout,
		UDPTimeout:           sing.UDPTimeout,
		TCPCongestionControl: options.TCPCongestionControl,
	})
	if err != nil {
		return nil, fmt.Errorf("construct mips stack: %w", err)
	}
	// The exact pinned NewStack("mips") contract returns *tun.Mipstack.
	// Own it before Start so Start failure runs Close as well.
	s.stack = stack.(*tun.Mipstack)
	if err = s.stack.Start(); err != nil {
		return nil, fmt.Errorf("start mips stack: %w", err)
	}
	return s, nil
}

// ReadDone closes when packet input exits, including during Close. An unexpected
// exit requires the owner to call Close; it does not mean teardown has completed.
func (s *Session) ReadDone() <-chan struct{} {
	return s.stack.PacketReadDone()
}

// ReadError returns the final raw-device read error after ReadDone closes, or
// nil before then. Normal Close may produce an error wrapping os.ErrClosed.
// Close reports teardown errors separately and does not discard this cause.
func (s *Session) ReadError() error {
	return s.stack.PacketReadError()
}

// Close stops handler admission, interrupts packet I/O, closes the real stack,
// joins its patched read/write loops, and drains admitted handler calls.
// It does not join workers or retained UDP packets owned by the supplied tunnel.
// No timeout returns a false "stopped" result while owned work is still running.
func (s *Session) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return s.closeErr
	}
	s.closed = true
	if s.handler != nil {
		s.handler.stopAdmission()
	}
	if s.cancel != nil {
		s.cancel()
	}
	var deviceErr, stackErr error
	if s.device != nil {
		deviceErr = s.device.Close()
	}
	if s.stack != nil {
		stackErr = s.stack.Close()
		s.stack.WaitPacketLoops()
	}
	if s.handler != nil {
		s.handler.calls.Wait()
		if s.handler.dns != nil {
			s.handler.dns.Wait()
		}
	}
	s.closeErr = errors.Join(deviceErr, stackErr)
	return s.closeErr
}

// flowHandler gates delivery into the real Mihomo handler. In particular, a
// delayed stack goroutine cannot enter the caller's tunnel after Close returns.
type flowHandler struct {
	*sing.ListenerHandler
	mu      sync.Mutex
	stopped bool
	conns   map[net.Conn]struct{}
	calls   sync.WaitGroup
	dns     *mihomodns.Session
}

func (h *flowHandler) NewConnection(ctx context.Context, conn net.Conn, metadata M.Metadata) error {
	h.mu.Lock()
	if h.stopped {
		h.mu.Unlock()
		_ = conn.Close()
		return os.ErrClosed
	}
	h.conns[conn] = struct{}{}
	h.calls.Add(1)
	h.mu.Unlock()
	defer func() {
		_ = conn.Close()
		h.mu.Lock()
		delete(h.conns, conn)
		h.mu.Unlock()
		h.calls.Done()
	}()
	if h.dns != nil {
		if h.dns.Matches(metadata.Destination.AddrPort()) {
			diagnostic.Event("tcp-received")
		}
		if handled, err := h.dns.HandleTCP(ctx, conn, metadata.Destination.AddrPort()); handled {
			diagnostic.Failure("tcp-relay", err)
			return err
		}
	}
	return h.ListenerHandler.NewConnection(ctx, conn, metadata)
}

func (h *flowHandler) NewPacket(ctx context.Context, key netip.AddrPort, buffer *buf.Buffer, metadata M.Metadata, init func(N.PacketConn) N.PacketWriter) {
	h.mu.Lock()
	if h.stopped {
		h.mu.Unlock()
		buffer.Release()
		return
	}
	h.calls.Add(1)
	h.mu.Unlock()
	defer h.calls.Done()
	if h.dns != nil && h.dns.Matches(metadata.Destination.AddrPort()) {
		diagnostic.Event("udp-received")
		writer := init(nil)
		// Own this dispatcher before dropping the callback's admission count.
		h.calls.Add(1)
		go func() {
			defer h.calls.Done()
			_, err := h.dns.HandleUDP(ctx, buffer, metadata.Destination, writer)
			if err != nil {
				diagnostic.Failure("udp-relay", err)
			} else {
				diagnostic.Event("udp-replied")
			}
		}()
		return
	}
	h.ListenerHandler.NewPacket(ctx, key, buffer, metadata, init)
}

func (h *flowHandler) PrepareConnection(string, M.Socksaddr, M.Socksaddr, tun.DirectRouteContext, time.Duration) (tun.DirectRouteDestination, error) {
	// No unprotected ICMP socket and no synthetic successful ping.
	return nil, tun.ErrDrop
}

func (h *flowHandler) stopAdmission() {
	h.mu.Lock()
	h.stopped = true
	if h.dns != nil {
		h.dns.Stop()
	}
	conns := make([]net.Conn, 0, len(h.conns))
	for conn := range h.conns {
		conns = append(conns, conn)
	}
	h.mu.Unlock()
	for _, conn := range conns {
		_ = conn.Close()
	}
}
