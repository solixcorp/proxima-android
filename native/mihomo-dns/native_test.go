package mihomodns

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"strconv"
	"syscall"
	"testing"

	"github.com/metacubex/mihomo/component/fakeip"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	coreDNS "github.com/metacubex/mihomo/dns"
	M "github.com/metacubex/sing/common/metadata"
	D "github.com/miekg/dns"
)

func TestUDPUsesNativeServiceAndProtectedTransport(t *testing.T) {
	f := newNativeFixture(t, "udp")
	s := newSession(t)
	m := query("native.example.", D.TypeA)
	m.SetEdns0(1232, true)

	reply, _ := udpQuery(t, s, m)

	if reply.Id != m.Id || !reply.Response || !reply.Authoritative || reply.Rcode != D.RcodeSuccess {
		t.Fatalf("native service reply header = %+v", reply.MsgHdr)
	}
	if len(reply.Answer) != 1 || reply.Answer[0].(*D.A).A.String() != "192.0.2.27" {
		t.Fatalf("unexpected native upstream answer: %v", reply.Answer)
	}
	if opt := reply.IsEdns0(); opt == nil || opt.UDPSize() != 1232 || !opt.Do() {
		t.Fatalf("native service did not echo EDNS: %v", opt)
	}
	if f.hooks.Load() != 1 || f.queries.Load() != 1 {
		t.Fatalf("protected DNS transport: hooks=%d queries=%d", f.hooks.Load(), f.queries.Load())
	}
}

func TestUDPTruncatesAtClientLimit(t *testing.T) {
	newNativeFixture(t, "udp")
	s := newSession(t)
	for _, size := range []uint16{0, 1232, 4096} {
		t.Run(strconv.Itoa(int(size)), func(t *testing.T) {
			m := query("large.example.", D.TypeTXT)
			limit := D.MinMsgSize
			if size != 0 {
				m.SetEdns0(size, false)
				limit = min(int(size), resolver.SafeDnsPacketSize)
			}
			reply, length := udpQuery(t, s, m)
			if !reply.Truncated || length > limit || len(reply.Answer) == 14 {
				t.Fatalf("UDP limit=%d bytes=%d TC=%v answers=%d", limit, length, reply.Truncated, len(reply.Answer))
			}
		})
	}
}

func TestTCPPreservesFullRepliesAndMultipleQueries(t *testing.T) {
	f := newNativeFixture(t, "tcp")
	s := newSession(t)
	client, server := net.Pipe()
	t.Cleanup(func() { client.Close() })
	done := make(chan error, 1)
	ctx := testContext(t)
	go func() {
		_, err := s.HandleTCP(ctx, server, testDestination)
		done <- err
	}()
	wire := &D.Conn{Conn: client}
	for _, name := range []string{"large-tcp.example.", "second-tcp.example."} {
		m := query(name, D.TypeTXT)
		m.Id++
		if err := wire.WriteMsg(m); err != nil {
			t.Fatal(err)
		}
		reply, err := wire.ReadMsg()
		if err != nil {
			t.Fatal(err)
		}
		if reply.Id != m.Id || !reply.Authoritative || reply.Truncated || len(reply.Answer) != 14 {
			t.Fatalf("TCP native reply: header=%+v answers=%d", reply.MsgHdr, len(reply.Answer))
		}
	}
	if err := client.Close(); err != nil {
		t.Fatal(err)
	}
	if err := receive(t, done); err != nil {
		t.Fatal(err)
	}
	if f.hooks.Load() != 2 || f.queries.Load() != 2 {
		t.Fatalf("protected TCP upstream: hooks=%d queries=%d", f.hooks.Load(), f.queries.Load())
	}
}

func TestNativeFakeIPMappingSurvivesInterception(t *testing.T) {
	pool := newFakeIPFixture(t)
	s := newSession(t)

	reply, _ := udpQuery(t, s, query("fake.example.", D.TypeA))

	if reply.Rcode != D.RcodeSuccess || len(reply.Answer) != 1 {
		t.Fatalf("native fake-IP response: %v", reply)
	}
	ip, ok := netip.AddrFromSlice(reply.Answer[0].(*D.A).A)
	if !ok || !pool.IPNet().Contains(ip.Unmap()) {
		t.Fatalf("answer outside configured fake-IP range: %v", reply.Answer)
	}
	if host, found := pool.LookBack(ip.Unmap()); !found || host != "fake.example" {
		t.Fatalf("native fake-IP reverse mapping: host=%q found=%v", host, found)
	}
}

func TestUDPTruncatesOversizedOPTAndTCPReturnsFullAnswer(t *testing.T) {
	for _, size := range []uint16{0, 512, 1232, 4096} {
		t.Run(strconv.Itoa(int(size)), func(t *testing.T) {
			pool := newFakeIPFixture(t)
			s := newSession(t)
			m := query("oversized.example.", D.TypeA)
			m.SetEdns0(size, true)
			m.IsEdns0().Option = append(m.IsEdns0().Option, &D.EDNS0_PADDING{Padding: make([]byte, 3000)})
			limit := min(max(int(size), D.MinMsgSize), resolver.SafeDnsPacketSize)

			reply, length := udpQuery(t, s, m)

			if length > limit || !reply.Truncated {
				t.Fatalf("UDP limit=%d bytes=%d TC=%v", limit, length, reply.Truncated)
			}
			if !reply.Response || !reply.Authoritative || reply.Id != m.Id || reply.Rcode != D.RcodeSuccess ||
				len(reply.Question) != 1 || reply.Question[0] != m.Question[0] {
				t.Fatalf("truncated native reply lost its header or question: %v", reply)
			}
			opt := reply.IsEdns0()
			if opt == nil || opt.UDPSize() != size || !opt.Do() || len(opt.Option) != 0 {
				t.Fatalf("truncated reply lost native OPT metadata or retained oversized options: %v", opt)
			}

			// Retry the same query over the actual native TCP relay. The UDP
			// transport limit must not alter the service or its complete response.
			client, server := net.Pipe()
			defer client.Close()
			ctx := testContext(t)
			done := make(chan error, 1)
			go func() {
				_, err := s.HandleTCP(ctx, server, testDestination)
				done <- err
			}()
			wire := &D.Conn{Conn: client}
			if err := wire.WriteMsg(m); err != nil {
				t.Fatal(err)
			}
			full, err := wire.ReadMsg()
			if err != nil {
				t.Fatal(err)
			}
			if full.Truncated || full.Id != m.Id || full.Rcode != D.RcodeSuccess || len(full.Answer) != 1 {
				t.Fatalf("TCP retry did not return the complete native answer: %v", full)
			}
			fullOpt := full.IsEdns0()
			if fullOpt == nil || len(fullOpt.Option) != 1 {
				t.Fatalf("TCP retry lost native OPT data: %v", fullOpt)
			}
			padding, ok := fullOpt.Option[0].(*D.EDNS0_PADDING)
			if !ok || len(padding.Padding) != 3000 {
				t.Fatalf("TCP retry changed native padding: %v", fullOpt.Option[0])
			}
			ip, ok := netip.AddrFromSlice(full.Answer[0].(*D.A).A)
			if !ok {
				t.Fatalf("invalid TCP native address: %v", full.Answer)
			}
			if host, found := pool.LookBack(ip.Unmap()); !found || host != "oversized.example" {
				t.Fatalf("TCP retry lost native fake-IP mapping: host=%q found=%v", host, found)
			}
			if err := client.Close(); err != nil {
				t.Fatal(err)
			}
			if err := receive(t, done); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func newFakeIPFixture(t *testing.T) *fakeip.Pool {
	t.Helper()
	pool, err := fakeip.New(fakeip.Options{IPNet: netip.MustParsePrefix("198.18.0.0/16"), Size: 64})
	if err != nil {
		t.Fatal(err)
	}
	enhancer := coreDNS.NewEnhancer(coreDNS.EnhancerConfig{
		EnhancedMode: C.DNSFakeIP, FakeIPPool: pool, FakeIPSkipper: &fakeip.Skipper{}, FakeIPTTL: 60,
	})
	rs := coreDNS.NewResolver(coreDNS.Config{})
	installService(t, coreDNS.NewService(rs.Resolver, enhancer), func(string, string, syscall.RawConn) error {
		t.Error("native fake-IP query unexpectedly opened an upstream socket")
		return errors.New("unexpected upstream")
	})
	return pool
}

func TestUnselectedAndLatePacketsCannotChangeRouting(t *testing.T) {
	f := newNativeFixture(t, "udp")
	s := newSession(t)
	m := query("unselected.example.", D.TypeA)
	input := packet(t, m)
	defer input.Release()
	sink := new(packetSink)

	handled, err := s.HandleUDP(testContext(t), input, M.SocksaddrFromNetIP(netip.MustParseAddrPort("192.0.2.53:53")), sink)
	if err != nil || handled || len(input.Bytes()) == 0 || sink.data != nil {
		t.Fatalf("unselected packet consumed: handled=%v err=%v", handled, err)
	}
	s.Wait()
	handled, err = s.HandleUDP(context.Background(), packet(t, m), M.SocksaddrFromNetIP(testDestination), sink)
	if !handled || !errors.Is(err, ErrStopped) || sink.data != nil || f.hooks.Load() != 0 {
		t.Fatalf("late selected packet escaped: handled=%v err=%v hooks=%d", handled, err, f.hooks.Load())
	}
}
