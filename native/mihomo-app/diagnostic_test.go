package diagnostics

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	D "github.com/miekg/dns"
	"golang.org/x/sys/unix"
	foundation "proxima.local/mihomo"
	"proxima.local/mihomo/session"
)

// Each scenario gets a fresh OS process. Reaping it is the final join of
// Mihomo's unexported global resolver workers; tests never reset core globals.
func TestDiagnosticProcess(t *testing.T) {
	if scenario := os.Getenv("PROXIMA_DIAGNOSTIC_CHILD"); scenario != "" {
		runScenario(t, scenario)
		return
	}
	for _, scenario := range []string{"udp", "tcp", "refused", "pending", "non-dns", "read-exit", "start-error"} {
		t.Run(scenario, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestDiagnosticProcess$", "-test.v")
			command.Env = append(os.Environ(), "PROXIMA_DIAGNOSTIC_CHILD="+scenario)
			output, err := command.CombinedOutput()
			if err != nil {
				t.Fatalf("diagnostic child did not pass and reap: %v\n%s", err, output)
			}
			t.Logf("reaped actual-core diagnostic child:\n%s", output)
		})
	}
}

func await[T any](t *testing.T, ch <-chan T) T {
	t.Helper()
	select {
	case value := <-ch:
		return value
	case <-time.After(5 * time.Second):
		t.Fatal("expected event did not occur")
		var zero T
		return zero
	}
}

type fixture struct {
	server   *D.Server
	address  netip.AddrPort
	entered  chan struct{}
	release  chan struct{}
	requests atomic.Int32
	once     sync.Once
}

func localDNS(t *testing.T, transport string, pending bool) *fixture {
	t.Helper()
	f := &fixture{entered: make(chan struct{}), release: make(chan struct{})}
	ready, exited := make(chan struct{}), make(chan error, 1)
	f.server = &D.Server{NotifyStartedFunc: func() { close(ready) }}
	f.server.Handler = D.HandlerFunc(func(writer D.ResponseWriter, request *D.Msg) {
		f.requests.Add(1)
		f.once.Do(func() { close(f.entered) })
		if pending {
			<-f.release
		}
		reply := new(D.Msg)
		reply.SetReply(request)
		reply.Answer = []D.RR{&D.A{
			Hdr: D.RR_Header{Name: request.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60},
			A:   net.IPv4(192, 0, 2, 27),
		}}
		_ = writer.WriteMsg(reply)
	})
	var address string
	if transport == "tcp" {
		listener, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		f.server.Listener, address = listener, listener.Addr().String()
	} else {
		packet, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		f.server.PacketConn, address = packet, packet.LocalAddr().String()
	}
	f.address = netip.MustParseAddrPort(address)
	go func() { exited <- f.server.ActivateAndServe() }()
	await(t, ready)
	t.Cleanup(func() {
		close(f.release)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := f.server.ShutdownContext(ctx); err != nil {
			t.Error(err)
		}
		if err := await(t, exited); err != nil {
			t.Error(err)
		}
	})
	return f
}

func packetPair(t *testing.T, kind int) (int, *os.File) {
	t.Helper()
	pair, err := unix.Socketpair(unix.AF_UNIX, kind, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, fd := range pair {
		if err := unix.SetNonblock(fd, true); err != nil {
			t.Fatal(err)
		}
	}
	peer := os.NewFile(uintptr(pair[1]), "diagnostic-peer")
	t.Cleanup(func() { _ = unix.Close(pair[0]); _ = peer.Close() })
	return pair[0], peer
}

func runScenario(t *testing.T, scenario string) {
	transport := "udp"
	if scenario == "tcp" {
		transport = "tcp"
	}
	sink := localDNS(t, transport, scenario == "pending")
	kind := unix.SOCK_DGRAM
	if scenario == "read-exit" {
		kind = unix.SOCK_STREAM
	}
	fd, peer := packetPair(t, kind)
	options := Options{Stack: "mips", MTU: 1500,
		Destination: netip.MustParseAddrPort("172.19.0.2:53"),
		Upstream:    sink.address, Network: transport}
	var protections atomic.Int32
	protect := func(socket int) bool {
		protections.Add(1)
		address, err := unix.Getsockname(socket)
		if err != nil {
			t.Error(err)
			return false
		}
		switch address := address.(type) {
		case *unix.SockaddrInet4:
			if address.Port != 0 {
				t.Error("socket was already bound before protection")
				return false
			}
		case *unix.SockaddrInet6:
			if address.Port != 0 {
				t.Error("socket was already bound before protection")
				return false
			}
		default:
			t.Errorf("unexpected socket family %T", address)
			return false
		}
		return scenario != "refused"
	}
	if dialer.DefaultSocketHook == nil {
		t.Fatal("permanent protection hook absent")
	}
	if scenario == "start-error" {
		options.MTU = 1
	}
	s, err := Start(fd, options, protect)
	if scenario == "start-error" {
		if err == nil || s != nil || !strings.Contains(err.Error(), "start mips stack") {
			t.Fatalf("real startup failure not surfaced: %v", err)
		}
		if _, err = unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != nil {
			t.Fatal("borrowed fd closed", err)
		}
		if _, err = Start(fd, options, protect); !errors.Is(err, ErrProcessUsed) {
			t.Fatal("failed process reused", err)
		}
		if protections.Load() != 0 || sink.requests.Load() != 0 {
			t.Fatal("startup failure sent DNS")
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Stop() })
	if _, err = Start(fd, options, protect); !errors.Is(err, ErrProcessUsed) {
		t.Fatal("parallel process reused", err)
	}
	query := new(D.Msg)
	query.SetQuestion("integrated.example.", D.TypeA)
	query.Id = 0x3412
	payload, err := query.Pack()
	if err != nil {
		t.Fatal(err)
	}
	switch scenario {
	case "udp", "pending", "refused":
		writePacket(t, peer, udpPacket(payload, 53))
		if scenario == "pending" {
			await(t, sink.entered)
			done := make(chan error, 1)
			go func() { done <- s.Stop() }()
			if err := await(t, done); err != nil {
				t.Fatal(err)
			}
			if protections.Load() == 0 {
				t.Fatal("resolver bypassed protection")
			}
			// The upstream is still held; cancellation drained the integrated
			// dispatcher rather than waiting for a fabricated successful reply.
			select {
			case <-sink.release:
				t.Fatal("fixture released too early")
			default:
			}
		} else if scenario == "refused" {
			await(t, s.Done())
			if err := s.Wait(); !errors.Is(err, session.ErrProtection) {
				t.Fatalf("lost protection failure: %v", err)
			}
			if err := s.Stop(); !errors.Is(err, session.ErrProtection) {
				t.Fatalf("lost stop failure: %v", err)
			}
			if sink.requests.Load() != 0 {
				t.Fatal("refused protection reached upstream")
			}
		} else {
			packet := readPacket(t, peer)
			if packet[9] != 17 || net.IP(packet[12:16]).String() != "172.19.0.2" ||
				binary.BigEndian.Uint16(packet[20:22]) != 53 {
				t.Fatalf("wrong DNS reply source: %x", packet)
			}
			assertAnswer(t, query, packet[28:])
		}
	case "tcp":
		// Exercise a real TCP handshake and length-framed DNS request through
		// the mips packet stack, sing adapter and native DNS relay.
		writePacket(t, peer, tcpPacket(100, 0, 2, nil))
		synAck := readPacket(t, peer)
		if synAck[9] != 6 || synAck[33]&0x12 != 0x12 {
			t.Fatalf("not TCP SYN ACK: %x", synAck)
		}
		ack := binary.BigEndian.Uint32(synAck[24:28]) + 1
		writePacket(t, peer, tcpPacket(101, ack, 16, nil))
		framed := make([]byte, len(payload)+2)
		binary.BigEndian.PutUint16(framed, uint16(len(payload)))
		copy(framed[2:], payload)
		seq := uint32(101 + len(framed))
		writePacket(t, peer, tcpPacket(101, ack, 24, framed))
		var response []byte
		for len(response) < 2 || len(response) < 2+int(binary.BigEndian.Uint16(response)) {
			packet := readPacket(t, peer)
			header := 20 + int(packet[32]>>4)*4
			if header > len(packet) {
				t.Fatal("invalid TCP header")
			}
			if len(packet) > header {
				response = append(response, packet[header:]...)
				ack = binary.BigEndian.Uint32(packet[24:28]) + uint32(len(packet)-header)
				writePacket(t, peer, tcpPacket(seq, ack, 16, nil))
			}
		}
		assertAnswer(t, query, response[2:])
	case "non-dns":
		writePacket(t, peer, udpPacket(payload, 54))
		await(t, s.Done())
		if !errors.Is(s.Wait(), ErrNonDNS) {
			t.Fatal("unselected traffic was silently accepted", s.Wait())
		}
		if protections.Load() != 0 || sink.requests.Load() != 0 {
			t.Fatal("unselected traffic escaped")
		}
	case "read-exit":
		if err := unix.Shutdown(fd, unix.SHUT_RD); err != nil {
			t.Fatal(err)
		}
		await(t, s.Done())
		if !errors.Is(s.Wait(), io.EOF) {
			t.Fatalf("real packet read cause was not preserved: %v", s.Wait())
		}
		if protections.Load() != 0 || sink.requests.Load() != 0 {
			t.Fatal("read failure sent DNS")
		}
	}
	if scenario == "udp" || scenario == "tcp" {
		if protections.Load() == 0 || sink.requests.Load() != 1 {
			t.Fatalf("native path: hooks=%d queries=%d", protections.Load(), sink.requests.Load())
		}
		var stops sync.WaitGroup
		for range 8 {
			stops.Add(1)
			go func() {
				defer stops.Done()
				if err := s.Stop(); err != nil {
					t.Error(err)
				}
			}()
		}
		stops.Wait()
	}
	_ = s.Stop()
	if err := foundation.Sessions.Protect(s.token, fd); !errors.Is(err, session.ErrInactive) {
		t.Fatal("closed lease still active", err)
	}
	if _, err := Start(fd, options, protect); !errors.Is(err, ErrProcessUsed) {
		t.Fatal("stopped process reused", err)
	}
	if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != nil {
		t.Fatal("borrowed fd closed", err)
	}
}

func TestRejectUnsupportedDiagnosticSettings(t *testing.T) {
	options := Options{Stack: "mips", MTU: 1500,
		Destination: netip.MustParseAddrPort("172.19.0.2:53"),
		Upstream:    netip.MustParseAddrPort("127.0.0.1:5553"), Network: "udp"}
	for _, stack := range []string{"", "system", "gvisor", "mixed"} {
		options.Stack = stack
		if s, err := Start(-1, options, func(int) bool { t.Fatal("unexpected protection"); return false }); err == nil || s != nil {
			t.Fatalf("silently substituted requested stack %q", stack)
		}
	}
}

func assertAnswer(t *testing.T, query *D.Msg, payload []byte) {
	t.Helper()
	reply := new(D.Msg)
	if err := reply.Unpack(payload); err != nil {
		t.Fatal(err)
	}
	if reply.Id != query.Id || !reply.Response || len(reply.Answer) != 1 ||
		reply.Answer[0].(*D.A).A.String() != "192.0.2.27" {
		t.Fatalf("wrong native DNS answer: %v", reply)
	}
}

func writePacket(t *testing.T, peer *os.File, packet []byte) {
	t.Helper()
	if _, err := peer.Write(packet); err != nil {
		t.Fatal(err)
	}
}

func readPacket(t *testing.T, peer *os.File) []byte {
	t.Helper()
	if err := peer.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	packet := make([]byte, 1500)
	n, err := peer.Read(packet)
	if err != nil {
		t.Fatal(err)
	}
	if n < 28 {
		t.Fatalf("short raw packet: %x", packet[:n])
	}
	return packet[:n]
}

func checksum(data []byte) uint16 {
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

func ipPacket(protocol byte, length int) []byte {
	packet := make([]byte, length)
	packet[0], packet[8], packet[9] = 0x45, 64, protocol
	binary.BigEndian.PutUint16(packet[2:4], uint16(length))
	copy(packet[12:16], []byte{10, 0, 0, 2})
	copy(packet[16:20], []byte{172, 19, 0, 2})
	binary.BigEndian.PutUint16(packet[10:12], checksum(packet[:20]))
	return packet
}

func udpPacket(payload []byte, port uint16) []byte {
	packet := ipPacket(17, 28+len(payload))
	binary.BigEndian.PutUint16(packet[20:22], 34001)
	binary.BigEndian.PutUint16(packet[22:24], port)
	binary.BigEndian.PutUint16(packet[24:26], uint16(8+len(payload)))
	copy(packet[28:], payload)
	return packet
}

func tcpPacket(seq, ack uint32, flags byte, payload []byte) []byte {
	packet := ipPacket(6, 40+len(payload))
	binary.BigEndian.PutUint16(packet[20:22], 34002)
	binary.BigEndian.PutUint16(packet[22:24], 53)
	binary.BigEndian.PutUint32(packet[24:28], seq)
	binary.BigEndian.PutUint32(packet[28:32], ack)
	packet[32], packet[33] = 5<<4, flags
	binary.BigEndian.PutUint16(packet[34:36], 65535)
	copy(packet[40:], payload)
	pseudo := make([]byte, 12+len(packet)-20)
	copy(pseudo, packet[12:20])
	pseudo[9] = 6
	binary.BigEndian.PutUint16(pseudo[10:12], uint16(len(packet)-20))
	copy(pseudo[12:], packet[20:])
	binary.BigEndian.PutUint16(packet[36:38], checksum(pseudo))
	return packet
}
