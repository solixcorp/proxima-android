package mihomodns

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	coreDNS "github.com/metacubex/mihomo/dns"
	"github.com/metacubex/sing/common/buf"
	M "github.com/metacubex/sing/common/metadata"
	D "github.com/miekg/dns"
)

var testDestination = netip.MustParseAddrPort("172.19.0.2:53")

func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func receive[T any](t *testing.T, ch <-chan T) T {
	t.Helper()
	select {
	case result := <-ch:
		return result
	case <-testContext(t).Done():
		t.Fatal("timed out waiting for the expected event")
		var zero T
		return zero
	}
}

func newSession(t *testing.T) *Session {
	t.Helper()
	s, err := New([]netip.AddrPort{testDestination})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Wait)
	return s
}

func installService(t *testing.T, service resolver.Service, hook dialer.SocketControl) {
	t.Helper()
	oldService, oldHook := resolver.DefaultService, dialer.DefaultSocketHook
	resolver.DefaultService, dialer.DefaultSocketHook = service, hook
	t.Cleanup(func() {
		resolver.DefaultService, dialer.DefaultSocketHook = oldService, oldHook
	})
}

func query(name string, qtype uint16) *D.Msg {
	m := new(D.Msg)
	m.SetQuestion(name, qtype)
	m.Id = 0x3412
	return m
}

func packet(t *testing.T, m *D.Msg) *buf.Buffer {
	t.Helper()
	data, err := m.Pack()
	if err != nil {
		t.Fatal(err)
	}
	buffer := buf.NewSize(len(data))
	if _, err := buffer.Write(data); err != nil {
		buffer.Release()
		t.Fatal(err)
	}
	return buffer
}

type packetSink struct {
	data        []byte
	destination M.Socksaddr
}

func (s *packetSink) FrontHeadroom() int { return 32 }
func (s *packetSink) RearHeadroom() int  { return 16 }

func (s *packetSink) WritePacket(b *buf.Buffer, destination M.Socksaddr) error {
	defer b.Release()
	if b.Start() < s.FrontHeadroom() {
		return errors.New("missing packet writer headroom")
	}
	s.data = append([]byte(nil), b.Bytes()...)
	s.destination = destination
	return nil
}

func udpQuery(t *testing.T, s *Session, m *D.Msg) (*D.Msg, int) {
	t.Helper()
	sink := new(packetSink)
	handled, err := s.HandleUDP(testContext(t), packet(t, m), M.SocksaddrFromNetIP(testDestination), sink)
	if err != nil || !handled {
		t.Fatalf("UDP handling: handled=%v err=%v", handled, err)
	}
	if sink.destination.AddrPort() != testDestination {
		t.Fatalf("reply source = %v", sink.destination)
	}
	reply := new(D.Msg)
	if err := reply.Unpack(sink.data); err != nil {
		t.Fatal(err)
	}
	return reply, len(sink.data)
}

type nativeFixture struct {
	hooks       atomic.Int32
	queries     atomic.Int32
	entered     chan struct{}
	release     chan struct{}
	once        sync.Once
	enteredOnce sync.Once
}

// Every upstream is a local authoritative wire fixture. The hook both records
// actual native socket creation and refuses every destination except that sink.
func newNativeFixture(t *testing.T, network string) *nativeFixture {
	t.Helper()
	f := &nativeFixture{entered: make(chan struct{}), release: make(chan struct{})}
	t.Cleanup(func() { f.once.Do(func() { close(f.release) }) })
	ready, exited := make(chan struct{}), make(chan error, 1)
	server := &D.Server{NotifyStartedFunc: func() { close(ready) }}
	server.Handler = D.HandlerFunc(func(w D.ResponseWriter, req *D.Msg) {
		f.queries.Add(1)
		if req.Question[0].Name == "pending.example." {
			f.enteredOnce.Do(func() { close(f.entered) })
			<-f.release
		}
		reply := new(D.Msg)
		reply.SetReply(req)
		reply.RecursionAvailable = true
		if req.Question[0].Qtype == D.TypeTXT {
			for range 14 {
				reply.Answer = append(reply.Answer, &D.TXT{
					Hdr: D.RR_Header{Name: req.Question[0].Name, Rrtype: D.TypeTXT, Class: D.ClassINET, Ttl: 300},
					Txt: []string{strings.Repeat("x", 220)},
				})
			}
		} else {
			reply.Answer = []D.RR{&D.A{
				Hdr: D.RR_Header{Name: req.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 300},
				A:   net.IPv4(192, 0, 2, 27),
			}}
		}
		if err := w.WriteMsg(reply); err != nil {
			t.Errorf("local upstream reply: %v", err)
		}
	})
	var address string
	if network == "udp" {
		pc, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		server.PacketConn, address = pc, pc.LocalAddr().String()
	} else {
		ln, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		server.Listener, address = ln, ln.Addr().String()
	}
	go func() { exited <- server.ActivateAndServe() }()
	receive(t, ready)
	t.Cleanup(func() {
		f.once.Do(func() { close(f.release) })
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.ShutdownContext(ctx); err != nil {
			t.Errorf("upstream shutdown: %v", err)
		}
		if err := receive(t, exited); err != nil {
			t.Errorf("upstream serve: %v", err)
		}
	})
	ns := coreDNS.NameServer{Net: network, Addr: address}
	rs := coreDNS.NewResolver(coreDNS.Config{Main: []coreDNS.NameServer{ns}, IPv6: true})
	service := coreDNS.NewService(rs.Resolver, coreDNS.NewEnhancer(coreDNS.EnhancerConfig{
		IPv6: true, EnhancedMode: C.DNSNormal,
	}))
	installService(t, service, func(_, target string, raw syscall.RawConn) error {
		if target != address {
			return errors.New("test blocked an unexpected outbound DNS destination")
		}
		return raw.Control(func(uintptr) { f.hooks.Add(1) })
	})
	return f
}
