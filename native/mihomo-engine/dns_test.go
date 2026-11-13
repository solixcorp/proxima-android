package engine

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/tunnel"
	D "github.com/miekg/dns"
	"golang.org/x/sys/unix"
	foundation "proxima.local/mihomo"
	"proxima.local/mihomo/session"
)

func TestDNSAdmissionAndSafeDefaults(t *testing.T) {
	for _, extra := range []string{"", "dns: {}\n", "dns: {enable: true, enhanced-mode: redir-host}\n",
		"dns: {nameserver: [udp://127.0.0.1:12345, tcp://127.0.0.1:12345, quic://1.1.1.1, tls://1.1.1.1, https://dns.google/dns-query]}\n"} {
		source := []byte(minimal + extra)
		snapshot, err := Decode(context.Background(), source, RevisionOf(source))
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := snapshot.Raw(context.Background())
		if err := admit(source, raw); err != nil {
			t.Fatal(err)
		}
		if !raw.DNS.Enable || raw.DNS.UseSystemHosts || raw.DNS.FallbackFilter.GeoIP || raw.DNS.EnhancedMode.String() != "redir-host" ||
			len(raw.Tun.DNSHijack) != 1 || raw.Tun.DNSHijack[0] != "172.19.0.2:53" {
			t.Fatalf("unsafe defaults: %+v", raw.DNS)
		}
		for _, server := range raw.DNS.DefaultNameserver {
			if !strings.HasPrefix(server, "https://") {
				t.Fatal("plaintext default bootstrap", server)
			}
		}
		if string(snapshot.Bytes()) != string(source) {
			t.Fatal("admission changed snapshot")
		}
	}
	fd, _ := pair(t)
	before := fdCount(t)
	for _, dns := range []string{
		"{enhanced-mode: fake-ip, fake-ip-range: 198.18.0.1/16}", "{enhanced-mode: normal}", "{enable: false}",
		"{nameserver: []}", "{default-nameserver: []}", "{nameserver: [http://127.0.0.1/dns-query]}",
		"{nameserver: [https://user:pass@dns.google/dns-query]}", "{nameserver: ['https://dns.google/dns-query#skip-cert-verify=true']}",
		"{nameserver: ['quic://1.1.1.1#DIRECT']}", "{nameserver: ['system']}", "{nameserver: ['dhcp://en0']}",
		"{nameserver: ['https://dns.google/dns-query?q=1']}", "{nameserver: ['udp://0.0.0.0']}",
		"{nameserver: ['tcp://127.0.0.1:0']}", "{default-nameserver: ['https://dns.google/dns-query']}",
		"{use-system-hosts: true}", "{respect-rules: true}", "{listen: '0.0.0.0:53'}", "{nameserver-policy: {example.com: system}}",
		"{fallback-filter: {geoip: true}}",
	} {
		p := &testProtector{}
		s, err := Start([]byte(minimal+"dns: "+dns+"\n"), fd, p)
		if err == nil || s != nil || p.closed.Load() != 1 {
			t.Fatalf("unsafe DNS accepted %s: %v", dns, err)
		}
		if strings.Contains(dns, "fake-ip") && !strings.Contains(err.Error(), "not supported yet") {
			t.Fatal("unclear fake-ip error", err)
		}
	}
	if fdCount(t) != before {
		t.Fatal("DNS admission rollback leaked descriptors")
	}
}

type dnsProtector struct {
	testProtector
	reject bool
	t      *testing.T
}

func (p *dnsProtector) Protect(fd int) bool {
	p.protects.Add(1)
	addr, err := unix.Getsockname(fd)
	if err != nil {
		p.t.Error(err)
		return false
	}
	switch a := addr.(type) {
	case *unix.SockaddrInet4:
		if a.Port != 0 {
			p.t.Error("DNS socket bound before protection")
			return false
		}
	case *unix.SockaddrInet6:
		if a.Port != 0 {
			p.t.Error("DNS socket bound before protection")
			return false
		}
	default:
		p.t.Errorf("unexpected DNS socket %T", addr)
		return false
	}
	return !p.reject
}

// Each real core lifetime is isolated and reaped, never reset in-process.
func TestEngineDNSProcess(t *testing.T) {
	if scenario := os.Getenv("PROXIMA_ENGINE_DNS_CHILD"); scenario != "" {
		engineDNSScenario(t, scenario)
		return
	}
	for _, scenario := range []string{"udp", "aaaa", "tcp-upstream", "tcp-tun", "doh", "doh-redirect", "udp-refused", "tcp-refused", "doh-refused", "quic-refused", "pending", "dns-init", "wildcard"} {
		t.Run(scenario, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestEngineDNSProcess$", "-test.v")
			cmd.Env = append(os.Environ(), "PROXIMA_ENGINE_DNS_CHILD="+scenario)
			if output, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("DNS child %s: %v\n%s", scenario, err, output)
			}
		})
	}
}

func engineDNSScenario(t *testing.T, scenario string) {
	var requests, redirects atomic.Int32
	entered, release := make(chan struct{}, 8), make(chan struct{})
	defer close(release)
	answer := func(query *D.Msg) *D.Msg {
		requests.Add(1)
		select {
		case entered <- struct{}{}:
		default:
		}
		if scenario == "pending" {
			<-release
		}
		reply := new(D.Msg)
		reply.SetReply(query)
		reply.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: query.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60}, A: net.IPv4(192, 0, 2, 27)}}
		switch query.Question[0].Qtype {
		case D.TypeAAAA:
			reply.Answer = []D.RR{&D.AAAA{Hdr: D.RR_Header{Name: query.Question[0].Name, Rrtype: D.TypeAAAA, Class: D.ClassINET, Ttl: 60}, AAAA: net.ParseIP("2001:db8::27")}}
		case D.TypeTXT:
			reply.Answer = []D.RR{&D.TXT{Hdr: D.RR_Header{Name: query.Question[0].Name, Rrtype: D.TypeTXT, Class: D.ClassINET, Ttl: 60}, Txt: []string{"real-mihomo"}}}
		}
		return reply
	}
	upstream := ""
	var stopServer func()
	if strings.HasPrefix(scenario, "doh") {
		redirect := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { redirects.Add(1) }))
		defer redirect.Close()
		server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if scenario == "doh-redirect" {
				http.Redirect(w, r, redirect.URL, http.StatusFound)
				return
			}
			data, err := base64.RawURLEncoding.DecodeString(r.URL.Query().Get("dns"))
			if err != nil {
				t.Error(err)
				return
			}
			query := new(D.Msg)
			if err := query.Unpack(data); err != nil {
				t.Error(err)
				return
			}
			payload, _ := answer(query).Pack()
			w.Header().Set("Content-Type", "application/dns-message")
			_, _ = w.Write(payload)
		}))
		if err := ca.AddCertificate(string(server.Certificate().Raw)); err != nil {
			t.Fatal(err)
		}
		upstream, stopServer = server.URL+"/dns-query", server.Close
	} else {
		transport := "udp"
		if strings.HasPrefix(scenario, "tcp") {
			transport = "tcp"
		}
		server := &D.Server{Handler: D.HandlerFunc(func(w D.ResponseWriter, q *D.Msg) { _ = w.WriteMsg(answer(q)) })}
		address := ""
		if transport == "tcp" {
			listener, err := net.Listen("tcp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			server.Listener, address = listener, listener.Addr().String()
		} else {
			packet, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			server.PacketConn, address = packet, packet.LocalAddr().String()
		}
		ready, exited := make(chan struct{}), make(chan error, 1)
		server.NotifyStartedFunc = func() { close(ready) }
		go func() { exited <- server.ActivateAndServe() }()
		<-ready
		upstream = transport + "://" + address
		stopServer = func() {
			_ = server.Shutdown()
			if err := <-exited; err != nil {
				t.Error(err)
			}
		}
		if scenario == "quic-refused" {
			upstream = "quic://" + address
		}
	}
	// The pending fixture must be released before Shutdown waits for its handler.
	defer func() {
		if scenario != "pending" {
			stopServer()
		}
	}()
	fd, peer := pair(t)
	p := &dnsProtector{reject: strings.HasSuffix(scenario, "refused"), t: t}
	config := minimal + fmt.Sprintf("dns: {enable: true, enhanced-mode: redir-host, nameserver: ['%s']}\n", upstream)
	if scenario == "aaaa" {
		config = minimal + fmt.Sprintf("ipv6: true\ndns: {ipv6: true, nameserver: ['%s']}\n", upstream)
	}
	if scenario == "wildcard" {
		config = strings.Replace(config, "dns-hijack: []", "dns-hijack: ['udp://any:53']", 1)
	}
	if scenario == "dns-init" {
		dialer.DefaultSocketHook = nil
	}
	before := fdCount(t)
	s, err := Start([]byte(config), fd, p)
	if scenario == "dns-init" {
		if err == nil || s != nil || !strings.Contains(err.Error(), "socket hook") {
			t.Fatal("DNS initialization failure not surfaced", err)
		}
		if p.closed.Load() != 1 || fdCount(t) != before || tunnel.Status() == tunnel.Running {
			t.Fatal("DNS init did not roll back entire Start", err)
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	defer s.Stop()
	query := new(D.Msg)
	query.SetQuestion("engine-phase12.example.", D.TypeA)
	if scenario == "aaaa" {
		query.SetQuestion("engine-phase12.example.", D.TypeAAAA)
	}
	if scenario == "tcp-tun" {
		query.SetQuestion("engine-phase12.example.", D.TypeTXT)
	}
	query.Id = 0x3412
	payload, _ := query.Pack()
	if scenario == "tcp-tun" {
		tcpDNSRoundTrip(t, peer, query, payload)
	} else {
		packet := dnsUDP(payload)
		if scenario == "wildcard" {
			copy(packet[16:20], net.IPv4(192, 0, 2, 53).To4())
			packet[10], packet[11] = 0, 0
			binary.BigEndian.PutUint16(packet[10:12], dnsChecksum(packet[:20]))
		}
		if _, err := peer.Write(packet); err != nil {
			t.Fatal(err)
		}
		if scenario == "pending" {
			select {
			case <-entered:
			case <-time.After(5 * time.Second):
				t.Fatal("upstream not entered")
			}
			stopped := make(chan error, 1)
			go func() { stopped <- s.Stop() }()
			select {
			case err := <-stopped:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("pending DNS prevented drain")
			}
			if p.protects.Load() == 0 {
				t.Fatal("unprotected pending upstream")
			}
			// Close the fixture only after its query returns. Native retry workers
			// cannot open new sockets after the scoped dial gate was stopped.
			t.Cleanup(stopServer)
			return
		}
		replyPacket := dnsReadPacket(t, peer)
		if replyPacket[9] != 17 || binary.BigEndian.Uint16(replyPacket[20:22]) != 53 || !net.IP(replyPacket[12:16]).Equal(net.IP(packet[16:20])) {
			t.Fatalf("wrong intercepted reply source: %x", replyPacket)
		}
		if p.reject || scenario == "doh-redirect" {
			reply := new(D.Msg)
			if err := reply.Unpack(replyPacket[28:]); err != nil {
				t.Fatal(err)
			}
			if reply.Rcode != D.RcodeServerFailure {
				t.Fatal("failed upstream fabricated success", reply)
			}
			if requests.Load() != 0 || redirects.Load() != 0 {
				t.Fatal("protection/redirect denial reached upstream")
			}
		} else {
			dnsAssertAnswer(t, query, replyPacket[28:])
		}
	}
	if p.protects.Load() == 0 {
		t.Fatal("DNS bypassed session protector")
	}
	if p.reject {
		d := tunnel.NewDNSDialer(nil, nil, "")
		network := "udp"
		if scenario == "tcp-refused" || scenario == "doh-refused" {
			network = "tcp"
		}
		if _, err := d.DialContext(context.Background(), network, "127.0.0.1:53"); !errors.Is(err, session.ErrProtection) {
			t.Fatal("false protector did not fail DNS dial", err)
		}
		if _, err := d.ListenPacket(context.Background(), "udp", "127.0.0.1:53"); !errors.Is(err, session.ErrProtection) {
			t.Fatal("false protector did not fail DNS packet socket", err)
		}
	}
	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	if p.closed.Load() != 1 {
		t.Fatal("protector not released")
	}
	// A late upstream refresh cannot reach even the old session's hook.
	count := p.protects.Load()
	_, err = tunnel.NewDNSDialer(nil, nil, "").DialContext(context.Background(), "udp", "127.0.0.1:53")
	if !errors.Is(err, net.ErrClosed) || p.protects.Load() != count {
		t.Fatal("late DNS dial was admitted", err)
	}
	if err := foundation.Sessions.Protect(s.token, fd); !errors.Is(err, session.ErrInactive) {
		t.Fatal("DNS stop left active lease", err)
	}
	if resolver.DefaultService == nil {
		t.Fatal("did not initialize actual Mihomo DNS")
	}
}

func dnsAssertAnswer(t *testing.T, query *D.Msg, payload []byte) {
	t.Helper()
	reply := new(D.Msg)
	if err := reply.Unpack(payload); err != nil {
		t.Fatal(err)
	}
	if reply.Id != query.Id || !reply.Response || len(reply.Answer) != 1 {
		t.Fatalf("wrong real DNS answer: %v", reply)
	}
	switch rr := reply.Answer[0].(type) {
	case *D.A:
		if rr.A.String() != "192.0.2.27" {
			t.Fatal(reply)
		}
	case *D.AAAA:
		if rr.AAAA.String() != "2001:db8::27" {
			t.Fatal(reply)
		}
	case *D.TXT:
		if len(rr.Txt) != 1 || rr.Txt[0] != "real-mihomo" {
			t.Fatal(reply)
		}
	default:
		t.Fatal("unexpected DNS record", reply)
	}
}
func dnsReadPacket(t *testing.T, peer *os.File) []byte {
	t.Helper()
	if err := peer.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 1500)
	n, err := peer.Read(data)
	if err != nil {
		t.Fatal(err)
	}
	if n < 28 {
		t.Fatal("short IP packet")
	}
	return data[:n]
}
func dnsChecksum(data []byte) uint16 {
	var sum uint32
	for len(data) >= 2 {
		sum += uint32(binary.BigEndian.Uint16(data))
		data = data[2:]
	}
	if len(data) != 0 {
		sum += uint32(data[0]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 65535) + (sum >> 16)
	}
	return ^uint16(sum)
}
func dnsIP(protocol byte, size int) []byte {
	p := make([]byte, size)
	p[0], p[8], p[9] = 0x45, 64, protocol
	binary.BigEndian.PutUint16(p[2:4], uint16(size))
	copy(p[12:16], []byte{10, 0, 0, 2})
	copy(p[16:20], []byte{172, 19, 0, 2})
	binary.BigEndian.PutUint16(p[10:12], dnsChecksum(p[:20]))
	return p
}
func dnsUDP(payload []byte) []byte {
	p := dnsIP(17, 28+len(payload))
	binary.BigEndian.PutUint16(p[20:22], 34001)
	binary.BigEndian.PutUint16(p[22:24], 53)
	binary.BigEndian.PutUint16(p[24:26], uint16(8+len(payload)))
	copy(p[28:], payload)
	return p
}
func dnsTCP(seq, ack uint32, flags byte, payload []byte) []byte {
	p := dnsIP(6, 40+len(payload))
	binary.BigEndian.PutUint16(p[20:22], 34002)
	binary.BigEndian.PutUint16(p[22:24], 53)
	binary.BigEndian.PutUint32(p[24:28], seq)
	binary.BigEndian.PutUint32(p[28:32], ack)
	p[32], p[33] = 5<<4, flags
	binary.BigEndian.PutUint16(p[34:36], 65535)
	copy(p[40:], payload)
	pseudo := make([]byte, 12+len(p)-20)
	copy(pseudo, p[12:20])
	pseudo[9] = 6
	binary.BigEndian.PutUint16(pseudo[10:12], uint16(len(p)-20))
	copy(pseudo[12:], p[20:])
	binary.BigEndian.PutUint16(p[36:38], dnsChecksum(pseudo))
	return p
}
func tcpDNSRoundTrip(t *testing.T, peer *os.File, query *D.Msg, payload []byte) {
	t.Helper()
	write := func(p []byte) {
		if _, err := peer.Write(p); err != nil {
			t.Fatal(err)
		}
	}
	write(dnsTCP(100, 0, 2, nil))
	synAck := dnsReadPacket(t, peer)
	if synAck[9] != 6 || synAck[33]&0x12 != 0x12 {
		t.Fatalf("not SYN ACK: %x", synAck)
	}
	ack := binary.BigEndian.Uint32(synAck[24:28]) + 1
	write(dnsTCP(101, ack, 16, nil))
	framed := make([]byte, 2+len(payload))
	binary.BigEndian.PutUint16(framed, uint16(len(payload)))
	copy(framed[2:], payload)
	seq := uint32(101 + len(framed))
	write(dnsTCP(101, ack, 24, framed))
	var response []byte
	for len(response) < 2 || len(response) < 2+int(binary.BigEndian.Uint16(response)) {
		p := dnsReadPacket(t, peer)
		header := 20 + int(p[32]>>4)*4
		if header > len(p) {
			t.Fatal("bad TCP header")
		}
		if len(p) > header {
			response = append(response, p[header:]...)
			ack = binary.BigEndian.Uint32(p[24:28]) + uint32(len(p)-header)
			write(dnsTCP(seq, ack, 16, nil))
		}
	}
	dnsAssertAnswer(t, query, response[2:])
}
