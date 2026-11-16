package mihomoruntime

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	tun "github.com/metacubex/sing-tun"
	"github.com/metacubex/sing/common/buf"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
	"golang.org/x/sys/unix"
)

type capturedPacket struct {
	packet C.UDPPacket
	meta   C.Metadata
}

// This is the caller-owned tunnel boundary, not a replacement stack or handler.
type packetSink struct {
	packets chan capturedPacket
	tcp     func(net.Conn, *C.Metadata)
}

func (s *packetSink) HandleTCPConn(conn net.Conn, metadata *C.Metadata) {
	if s.tcp != nil {
		s.tcp(conn, metadata)
	} else {
		_ = conn.Close()
	}
}

func (s *packetSink) HandleUDPPacket(packet C.UDPPacket, metadata *C.Metadata) {
	s.packets <- capturedPacket{packet, *metadata}
}

func (*packetSink) NatTable() C.NatTable { return nil }

func packetPair(t *testing.T) (int, *os.File) {
	t.Helper()
	pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, fd := range pair {
		if err := unix.SetNonblock(fd, true); err != nil {
			t.Fatal(err)
		}
	}
	peer := os.NewFile(uintptr(pair[1]), "packet-peer")
	t.Cleanup(func() { _ = unix.Close(pair[0]); _ = peer.Close() })
	return pair[0], peer
}

func rawFD(t *testing.T, file *os.File) int {
	t.Helper()
	conn, err := file.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	fd := -1
	if err = conn.Control(func(value uintptr) { fd = int(value) }); err != nil {
		t.Fatal(err)
	}
	return fd
}

func receive(t *testing.T, packets <-chan capturedPacket) capturedPacket {
	t.Helper()
	select {
	case packet := <-packets:
		return packet
	case <-time.After(5 * time.Second):
		t.Fatal("real Mihomo packet handler did not receive the datagram")
		return capturedPacket{}
	}
}

func ipv4UDP(payload string) []byte {
	packet := make([]byte, 28+len(payload))
	packet[0], packet[8], packet[9] = 0x45, 64, 17
	binary.BigEndian.PutUint16(packet[2:4], uint16(len(packet)))
	copy(packet[12:16], []byte{10, 0, 0, 2})
	copy(packet[16:20], []byte{198, 51, 100, 7})
	var sum uint32
	for i := 0; i < 20; i += 2 {
		sum += uint32(binary.BigEndian.Uint16(packet[i:]))
	}
	for sum>>16 != 0 {
		sum = (sum & 65535) + (sum >> 16)
	}
	binary.BigEndian.PutUint16(packet[10:12], ^uint16(sum))
	binary.BigEndian.PutUint16(packet[20:22], 34001)
	binary.BigEndian.PutUint16(packet[22:24], 43210)
	binary.BigEndian.PutUint16(packet[24:26], uint16(len(packet)-20))
	// IPv4 permits the zero UDP checksum.
	copy(packet[28:], payload)
	return packet
}

func TestActualMihomoPacketRoundTrip(t *testing.T) {
	fd, peer := packetPair(t)
	sink := &packetSink{packets: make(chan capturedPacket, 1)}
	s, err := OpenBorrowed(fd, Options{Stack: "mips", MTU: 1500}, sink)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if _, err = peer.Write(ipv4UDP("request")); err != nil {
		t.Fatal(err)
	}
	got := receive(t, sink.packets)
	defer got.packet.Drop()
	if string(got.packet.Data()) != "request" || got.meta.Type != C.TUN ||
		got.meta.SrcIP.String() != "10.0.0.2" || got.meta.SrcPort != 34001 ||
		got.meta.DstIP.String() != "198.51.100.7" || got.meta.DstPort != 43210 ||
		got.meta.InName != "PROXIMA-TUN" {
		t.Fatalf("wrong actual core metadata/payload: %+v, %q", got.meta, got.packet.Data())
	}
	if _, err = got.packet.WriteBack([]byte("response"), &net.UDPAddr{
		IP: net.ParseIP("198.51.100.7"), Port: 43210,
	}); err != nil {
		t.Fatal(err)
	}
	if err = peer.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 1500)
	n, err := peer.Read(reply)
	if err != nil {
		t.Fatal(err)
	}
	if n < 28 || string(reply[28:n]) != "response" ||
		net.IP(reply[12:16]).String() != "198.51.100.7" ||
		net.IP(reply[16:20]).String() != "10.0.0.2" {
		t.Fatalf("wrong actual stack response: %x", reply[:n])
	}
}

func TestActualCoreStartupFailuresRollback(t *testing.T) {
	fd, _ := packetPair(t)
	sink := &packetSink{packets: make(chan capturedPacket, 1)}
	for _, tc := range []struct {
		options Options
		want    string
	}{
		{Options{Stack: "mips", MTU: 1500, TCPCongestionControl: "does-not-exist"}, "construct mips stack"},
		{Options{Stack: "mips", MTU: 1}, "start mips stack"},
		{Options{Stack: "mips", MTU: 65536}, "start mips stack"},
	} {
		t.Run(tc.want+fmt.Sprint(tc.options.MTU), func(t *testing.T) {
			// Probe the lowest free slot; failed startup must return that slot.
			slot, err := unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, 3)
			if err != nil {
				t.Fatal(err)
			}
			_ = unix.Close(slot)
			for i := 0; i < 10; i++ {
				s, err := OpenBorrowed(fd, tc.options, sink)
				if err == nil || s != nil || !strings.Contains(err.Error(), tc.want) {
					t.Fatalf("startup result = %v, %v; want %q", s, err, tc.want)
				}
				if _, err := unix.FcntlInt(uintptr(slot), unix.F_GETFD, 0); !errors.Is(err, unix.EBADF) {
					t.Fatalf("failed startup retained fd %d: %v", slot, err)
				}
			}
			if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != nil {
				t.Fatalf("borrowed fd was closed: %v", err)
			}
		})
	}
}

func TestRejectUnsupportedStackAndUnsafeDescriptors(t *testing.T) {
	fd, _ := packetPair(t)
	sink := &packetSink{packets: make(chan capturedPacket, 1)}
	for _, stack := range []string{"", "system", "mixed", "gvisor", "unknown"} {
		if s, err := OpenBorrowed(fd, Options{Stack: stack, MTU: 1500}, sink); err == nil || s != nil {
			t.Fatalf("silently accepted stack %q", stack)
		}
	}
	if s, err := OpenBorrowed(-1, Options{Stack: "mips", MTU: 1500}, sink); err == nil || s != nil {
		t.Fatal("accepted invalid fd")
	}
	if s, err := OpenBorrowed(fd, Options{Stack: "mips"}, sink); err == nil || s != nil {
		t.Fatal("accepted unspecified MTU")
	}
	if err := unix.SetNonblock(fd, false); err != nil {
		t.Fatal(err)
	}
	if s, err := OpenBorrowed(fd, Options{Stack: "mips", MTU: 1500}, sink); err == nil || s != nil {
		t.Fatal("accepted blocking descriptor")
	}
	flags, err := unix.FcntlInt(uintptr(fd), unix.F_GETFL, 0)
	if err != nil || flags&unix.O_NONBLOCK != 0 {
		t.Fatalf("changed borrowed flags: %d, %v", flags, err)
	}
	file, err := os.CreateTemp(t.TempDir(), "not-tun")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	fileFD := int(file.Fd())
	if err := unix.SetNonblock(fileFD, true); err != nil {
		t.Fatal(err)
	}
	if s, err := OpenBorrowed(fileFD, Options{Stack: "mips", MTU: 1500}, sink); err == nil || s != nil {
		if s != nil {
			_ = s.Close()
		}
		t.Fatal("accepted unpollable regular file")
	}
}

func TestCallerCanCloseBorrowedAliasAfterStartup(t *testing.T) {
	fd, peer := packetPair(t)
	alias, err := unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, 3)
	if err != nil {
		t.Fatal(err)
	}
	sink := &packetSink{packets: make(chan capturedPacket, 1)}
	s, err := OpenBorrowed(alias, Options{Stack: "mips", MTU: 1500}, sink)
	_ = unix.Close(alias)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := peer.Write(ipv4UDP("after caller close")); err != nil {
		t.Fatal(err)
	}
	packet := receive(t, sink.packets)
	defer packet.packet.Drop()
	if string(packet.packet.Data()) != "after caller close" {
		t.Fatal("closing caller alias changed the independently owned descriptor")
	}
}

func TestConcurrentStopPreservesBorrowedAndReusedFD(t *testing.T) {
	fd, _ := packetPair(t)
	s, err := OpenBorrowed(fd, Options{Stack: "mips", MTU: 1500},
		&packetSink{packets: make(chan capturedPacket, 1)})
	if err != nil {
		t.Fatal(err)
	}
	ownedFD := rawFD(t, s.device)
	flags, err := unix.FcntlInt(uintptr(ownedFD), unix.F_GETFD, 0)
	if err != nil || flags&unix.FD_CLOEXEC == 0 {
		t.Fatalf("duplicate is not close-on-exec: %d, %v", flags, err)
	}
	var closers sync.WaitGroup
	for i := 0; i < 32; i++ {
		closers.Add(1)
		go func() {
			defer closers.Done()
			if err := s.Close(); err != nil {
				t.Errorf("concurrent close: %v", err)
			}
		}()
	}
	closers.Wait()
	if _, err := unix.FcntlInt(uintptr(ownedFD), unix.F_GETFD, 0); !errors.Is(err, unix.EBADF) {
		t.Fatalf("owned fd remains open: %v", err)
	}
	reused, err := unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, ownedFD)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(reused)
	if reused != ownedFD {
		t.Fatalf("could not exercise fd reuse: got %d want %d", reused, ownedFD)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	for _, fd := range []int{fd, reused} {
		if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != nil {
			t.Fatalf("stale stop closed caller/reused fd %d: %v", fd, err)
		}
	}
}

func TestStopDrainsAdmittedTCPAndRejectsLateCalls(t *testing.T) {
	fd, _ := packetPair(t)
	entered, exited := make(chan struct{}), make(chan struct{})
	sink := &packetSink{packets: make(chan capturedPacket, 1), tcp: func(conn net.Conn, _ *C.Metadata) {
		close(entered)
		_, _ = io.Copy(io.Discard, conn)
		close(exited)
	}}
	s, err := OpenBorrowed(fd, Options{Stack: "mips", MTU: 1500}, sink)
	if err != nil {
		t.Fatal(err)
	}
	left, right := net.Pipe()
	defer right.Close()
	callDone := make(chan error, 1)
	go func() { callDone <- s.handler.NewConnection(context.Background(), left, M.Metadata{}) }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("TCP callback not entered")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-exited:
	default:
		t.Fatal("Close returned before admitted TCP callback exited")
	}
	if err := <-callDone; err != nil {
		t.Fatal(err)
	}
	late, peer := net.Pipe()
	defer peer.Close()
	if err := s.handler.NewConnection(context.Background(), late, M.Metadata{}); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("late TCP call was admitted: %v", err)
	}
	s.handler.NewPacket(context.Background(), netip.AddrPort{}, buf.New(), M.Metadata{},
		func(N.PacketConn) N.PacketWriter { t.Error("late packet initialized"); return nil })
	select {
	case packet := <-sink.packets:
		packet.packet.Drop()
		t.Fatal("late UDP packet was admitted")
	default:
	}
	if _, err := s.handler.PrepareConnection("", M.Socksaddr{}, M.Socksaddr{}, nil, 0); !errors.Is(err, tun.ErrDrop) {
		t.Fatalf("ICMP was not explicitly dropped: %v", err)
	}
}

func TestBorrowedFDZero(t *testing.T) {
	if os.Getenv("PROXIMA_FD_ZERO_CHILD") != "1" {
		executable, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		command := exec.CommandContext(ctx, executable, "-test.run=^TestBorrowedFDZero$", "-test.v")
		command.Env = append(os.Environ(), "PROXIMA_FD_ZERO_CHILD=1")
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("fd 0 subprocess failed: %v\n%s", err, output)
		}
		return
	}
	fd, peer := packetPair(t)
	if err := unix.Dup2(fd, 0); err != nil {
		t.Fatal(err)
	}
	defer unix.Close(0)
	sink := &packetSink{packets: make(chan capturedPacket, 1)}
	s, err := OpenBorrowed(0, Options{Stack: "mips", MTU: 1500}, sink)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := peer.Write(ipv4UDP("zero")); err != nil {
		t.Fatal(err)
	}
	packet := receive(t, sink.packets)
	packet.packet.Drop()
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := unix.FcntlInt(0, unix.F_GETFD, 0); err != nil {
		t.Fatalf("fd zero was not borrowed: %v", err)
	}
}
