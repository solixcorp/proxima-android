package engine

import (
	"bytes"
	"encoding/binary"
	"net"
	"os"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// Run alone: a core is intentionally never restarted in one process.
// Measures serial four-byte UDP ping/pong including host socket and scheduling.
func BenchmarkMipstackUDP(b *testing.B) {
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		b.Fatal(err)
	}
	var ip net.IP
	for _, a := range addresses {
		if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil && !n.IP.IsLoopback() {
			ip = n.IP.To4()
			break
		}
	}
	if ip == nil {
		b.Fatal("non-loopback IPv4 required")
	}
	sink, err := net.ListenUDP("udp4", &net.UDPAddr{IP: ip})
	if err != nil {
		b.Fatal(err)
	}
	defer sink.Close()
	go func() {
		data := make([]byte, 1500)
		for {
			n, addr, err := sink.ReadFromUDP(data)
			if err != nil {
				return
			}
			_, _ = sink.WriteToUDP(data[:n], addr)
		}
	}()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		b.Fatal(err)
	}
	defer unix.Close(fds[0])
	if err := unix.SetNonblock(fds[0], true); err != nil {
		b.Fatal(err)
	}
	if err := unix.SetNonblock(fds[1], true); err != nil {
		b.Fatal(err)
	}
	peer := os.NewFile(uintptr(fds[1]), "benchmark-peer")
	defer peer.Close()
	s, err := Start([]byte(minimal), fds[0], &testProtector{})
	if err != nil {
		b.Fatal(err)
	}
	defer s.Stop()
	packet := make([]byte, 32)
	packet[0], packet[8], packet[9] = 0x45, 64, 17
	binary.BigEndian.PutUint16(packet[2:4], uint16(len(packet)))
	copy(packet[12:16], []byte{10, 0, 0, 2})
	copy(packet[16:20], ip)
	binary.BigEndian.PutUint16(packet[10:12], dnsChecksum(packet[:20]))
	binary.BigEndian.PutUint16(packet[20:22], 34001)
	binary.BigEndian.PutUint16(packet[22:24], uint16(sink.LocalAddr().(*net.UDPAddr).Port))
	binary.BigEndian.PutUint16(packet[24:26], 12)
	copy(packet[28:], "ping")
	reply := make([]byte, 1500)
	b.SetBytes(8)
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		if _, err := peer.Write(packet); err != nil {
			b.Fatal(err)
		}
		if err := peer.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
			b.Fatal(err)
		}
		n, err := peer.Read(reply)
		if err != nil {
			b.Fatal(err)
		}
		if n < 28 || !bytes.Equal(reply[28:n], []byte("ping")) {
			b.Fatal("bad reply")
		}
	}
}

// Run separately from other engine benchmarks, because Start is process-once.
func BenchmarkMipstackTCP(b *testing.B) {
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		b.Fatal(err)
	}
	var ip net.IP
	for _, a := range addresses {
		if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil && !n.IP.IsLoopback() {
			ip = n.IP.To4()
			break
		}
	}
	if ip == nil {
		b.Fatal("non-loopback IPv4 required")
	}
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: ip})
	if err != nil {
		b.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.AcceptTCP()
		if err != nil {
			return
		}
		defer conn.Close()
		data := make([]byte, 1500)
		for {
			n, err := conn.Read(data)
			if err != nil {
				return
			}
			if _, err = conn.Write(data[:n]); err != nil {
				return
			}
		}
	}()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		b.Fatal(err)
	}
	defer unix.Close(fds[0])
	for _, fd := range fds {
		if err := unix.SetNonblock(fd, true); err != nil {
			b.Fatal(err)
		}
	}
	peer := os.NewFile(uintptr(fds[1]), "benchmark-peer")
	defer peer.Close()
	s, err := Start([]byte(minimal), fds[0], &testProtector{})
	if err != nil {
		b.Fatal(err)
	}
	defer s.Stop()
	packet := func(seq, ack uint32, flags byte, payload []byte) []byte {
		p := dnsTCP(seq, ack, flags, payload)
		copy(p[16:20], ip)
		binary.BigEndian.PutUint16(p[22:24], uint16(listener.Addr().(*net.TCPAddr).Port))
		binary.BigEndian.PutUint16(p[10:12], 0)
		binary.BigEndian.PutUint16(p[10:12], dnsChecksum(p[:20]))
		binary.BigEndian.PutUint16(p[36:38], 0)
		pseudo := make([]byte, 12+len(p)-20)
		copy(pseudo, p[12:20])
		pseudo[9] = 6
		binary.BigEndian.PutUint16(pseudo[10:12], uint16(len(p)-20))
		copy(pseudo[12:], p[20:])
		binary.BigEndian.PutUint16(p[36:38], dnsChecksum(pseudo))
		return p
	}
	write := func(p []byte) {
		if _, err := peer.Write(p); err != nil {
			b.Fatal(err)
		}
	}
	read := func() []byte {
		if err := peer.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
			b.Fatal(err)
		}
		p := make([]byte, 1500)
		n, err := peer.Read(p)
		if err != nil {
			b.Fatal(err)
		}
		if n < 40 {
			b.Fatal("short TCP packet")
		}
		return p[:n]
	}
	write(packet(100, 0, 2, nil))
	syn := read()
	if syn[33]&0x12 != 0x12 {
		b.Fatal("missing SYN ACK")
	}
	ack := binary.BigEndian.Uint32(syn[24:28]) + 1
	seq := uint32(101)
	write(packet(seq, ack, 16, nil))
	b.SetBytes(8)
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		write(packet(seq, ack, 24, []byte("ping")))
		seq += 4
		for {
			p := read()
			header := 20 + int(p[32]>>4)*4
			if header > len(p) {
				b.Fatal("bad TCP header")
			}
			if len(p) == header {
				continue
			}
			if !bytes.Equal(p[header:], []byte("ping")) {
				b.Fatal("bad TCP reply")
			}
			ack = binary.BigEndian.Uint32(p[24:28]) + uint32(len(p)-header)
			write(packet(seq, ack, 16, nil))
			break
		}
	}
}
