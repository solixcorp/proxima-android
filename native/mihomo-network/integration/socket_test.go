package integration

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"os"
	"syscall"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/listener/redir"
	"github.com/metacubex/mihomo/listener/tproxy"
	"golang.org/x/sys/unix"
	mihomo "proxima.local/mihomo"
	"proxima.local/mihomo/session"
)

type protector struct {
	t     *testing.T
	calls int
	allow bool
}

func (p *protector) Close() error { return nil }
func (p *protector) Protect(fd int) bool {
	p.calls++
	sa, err := unix.Getsockname(fd)
	if err != nil {
		p.t.Fatal(err)
	}
	switch sa := sa.(type) {
	case *unix.SockaddrInet4:
		if sa.Port != 0 {
			p.t.Fatalf("protection after bind: %d", sa.Port)
		}
	case *unix.SockaddrInet6:
		if sa.Port != 0 {
			p.t.Fatalf("protection after bind: %d", sa.Port)
		}
	default:
		p.t.Fatalf("unexpected traffic socket: %T", sa)
	}
	if _, err := unix.Getpeername(fd); !errors.Is(err, unix.ENOTCONN) {
		p.t.Fatalf("protection after connect: %v", err)
	}
	return p.allow
}

func lease(t *testing.T, allow bool) *protector {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	defer w.Close()
	p := &protector{t: t, allow: allow}
	token, err := mihomo.Sessions.Prepare(int(r.Fd()), p)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := mihomo.Sessions.Close(token); err != nil {
			t.Error(err)
		}
	})
	return p
}

func TestListenerProtectionBeforeBind(t *testing.T) {
	for _, active := range []bool{false, true} {
		t.Run(map[bool]string{false: "inactive", true: "refused"}[active], func(t *testing.T) {
			want := session.ErrInactive
			var p *protector
			if active {
				p = lease(t, false)
				want = session.ErrProtection
			}
			for _, tfo := range []bool{false, true} {
				inbound.SetTfo(tfo)
				defer inbound.SetTfo(false)
				config := inbound.NewListenConfig()
				config.SetRouteMark(123) // Hook must supersede a privileged mark.
				for name, open := range map[string]func() error{
					"inbound-tcp": func() error {
						c, e := config.Listen(context.Background(), "tcp4", "127.0.0.1:0")
						if c != nil {
							c.Close()
						}
						return e
					},
					"inbound-udp": func() error {
						c, e := config.ListenPacket(context.Background(), "udp4", "127.0.0.1:0")
						if c != nil {
							c.Close()
						}
						return e
					},
					"redir": func() error {
						c, e := redir.New("127.0.0.1:0", nil)
						if c != nil {
							c.Close()
						}
						return e
					},
					"tproxy-tcp": func() error {
						c, e := tproxy.New("127.0.0.1:0", nil)
						if c != nil {
							c.Close()
						}
						return e
					},
					"tproxy-udp": func() error {
						c, e := tproxy.NewUDP("127.0.0.1:0", nil)
						if c != nil {
							c.Close()
						}
						return e
					},
					"dialer-udp": func() error {
						c, e := dialer.ListenPacket(context.Background(), "udp4", "127.0.0.1:0", netip.AddrPort{})
						if c != nil {
							c.Close()
						}
						return e
					},
				} {
					t.Run(name, func(t *testing.T) {
						before := 0
						if p != nil {
							before = p.calls
						}
						if err := open(); !errors.Is(err, want) {
							t.Fatalf("want %v, got %v", want, err)
						}
						if p != nil && p.calls != before+1 {
							t.Fatalf("protection calls: %d", p.calls-before)
						}
					})
				}
			}
		})
	}
}

func TestTCPAndTFORefusalHasNoConnection(t *testing.T) {
	for _, tfo := range []bool{false, true} {
		t.Run(map[bool]string{false: "tcp", true: "tfo"}[tfo], func(t *testing.T) {
			p := lease(t, false)
			server, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
			if err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			type key struct{}
			ctx := context.WithValue(context.Background(), key{}, "caller")
			seenContext := false
			nd := &net.Dialer{ControlContext: func(ctx context.Context, _, _ string, _ syscall.RawConn) error {
				seenContext = ctx.Value(key{}) == "caller"
				return nil
			}}
			c, err := dialer.DialContext(ctx, "tcp4", server.Addr().String(), dialer.WithTFO(tfo), dialer.WithNetDialer(nd))
			if tfo {
				if err != nil {
					t.Fatal(err)
				}
				defer c.Close()
				if p.calls != 0 {
					t.Fatal("TFO was replaced by eager TCP")
				}
				_, err = c.Write([]byte("must never leave this process"))
			}
			if !errors.Is(err, session.ErrProtection) {
				t.Fatalf("refusal: %v", err)
			}
			if p.calls != 1 || !seenContext {
				t.Fatalf("calls=%d caller context=%v", p.calls, seenContext)
			}
			server.SetDeadline(time.Now().Add(30 * time.Millisecond))
			accepted, err := server.Accept()
			if accepted != nil {
				accepted.Close()
				t.Fatal("refused socket connected")
			}
			if ne, ok := err.(net.Error); !ok || !ne.Timeout() {
				t.Fatalf("accept: %v", err)
			}
		})
	}
}

func TestDeferredTFOSurvivesCallerCleanup(t *testing.T) {
	p := lease(t, false)
	ctx, cancel := context.WithCancel(context.Background())
	c, err := dialer.DialContext(ctx, "tcp4", "127.0.0.1:9", dialer.WithTFO(true))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	cancel()
	if _, err := c.Write([]byte("protected")); !errors.Is(err, session.ErrProtection) {
		t.Fatalf("caller cleanup invalidated the returned connection: %v", err)
	}
	if p.calls != 1 {
		t.Fatalf("first write did not reach socket protection: %d", p.calls)
	}
}

func TestVirtualDialerRemainsUsable(t *testing.T) {
	// A virtual stream creates no OS socket; its outer transport owns protection.
	p := lease(t, false)
	a, b := net.Pipe()
	defer b.Close()
	c, err := dialer.DialContext(context.Background(), "tcp4", "127.0.0.1:9",
		dialer.WithNetDialer(dialer.NetDialerFunc(func(context.Context, string, string) (net.Conn, error) {
			return a, nil
		})))
	if err != nil {
		a.Close()
		t.Fatal(err)
	}
	c.Close()
	if p.calls != 0 {
		t.Fatal("virtual stream was treated as a raw socket")
	}
}

func TestApprovedInboundSocketWorks(t *testing.T) {
	p := lease(t, true)
	c, err := inbound.NewListenConfig().ListenPacket(context.Background(), "udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	sender, err := net.Dial("udp4", c.LocalAddr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer sender.Close()
	if _, err := sender.Write([]byte("ok")); err != nil {
		t.Fatal(err)
	}
	c.SetReadDeadline(time.Now().Add(time.Second))
	b := make([]byte, 2)
	n, _, err := c.ReadFrom(b)
	if err != nil || string(b[:n]) != "ok" || p.calls != 1 {
		t.Fatalf("approved UDP: %q calls=%d err=%v", b[:n], p.calls, err)
	}
}
