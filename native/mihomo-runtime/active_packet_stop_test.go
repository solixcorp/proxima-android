package mihomoruntime

import (
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"golang.org/x/sys/unix"
)

type gatedPacketSink struct {
	packetSink
	entered   chan capturedPacket
	writeNow  chan struct{}
	writeDone chan error
	leaveNow  chan struct{}
	exited    chan struct{}
}

func (s *gatedPacketSink) HandleUDPPacket(packet C.UDPPacket, metadata *C.Metadata) {
	defer close(s.exited)
	defer packet.Drop()
	s.entered <- capturedPacket{packet, *metadata}
	<-s.writeNow
	_, err := packet.WriteBack([]byte("during stop"), &net.UDPAddr{
		IP: net.ParseIP("198.51.100.7"), Port: 43210,
	})
	s.writeDone <- err
	<-s.leaveNow
}

func TestCloseWhileActualPacketHandlerIsActive(t *testing.T) {
	fd, peer := packetPair(t)
	sink := &gatedPacketSink{
		entered:   make(chan capturedPacket, 1),
		writeNow:  make(chan struct{}),
		writeDone: make(chan error, 1),
		leaveNow:  make(chan struct{}),
		exited:    make(chan struct{}),
	}
	s, err := OpenBorrowed(fd, Options{Stack: "mips", MTU: 1500}, sink)
	if err != nil {
		t.Fatal(err)
	}
	writeNow := sync.OnceFunc(func() { close(sink.writeNow) })
	leaveNow := sync.OnceFunc(func() { close(sink.leaveNow) })
	t.Cleanup(func() {
		writeNow()
		leaveNow()
		_ = s.Close()
	})
	if _, err = peer.Write(ipv4UDP("active real packet")); err != nil {
		t.Fatal(err)
	}
	packet := receive(t, sink.entered)
	if string(packet.packet.Data()) != "active real packet" || packet.meta.Type != C.TUN {
		t.Fatalf("real stack/handler did not deliver the expected packet: %+v", packet.meta)
	}

	// The actual synchronous UDP forwarder now holds the real read loop in
	// this callback. No more packets are sent. This otherwise-blocked read is
	// an event observer: os.ErrClosed proves Close reached descriptor teardown.
	ioStopped := make(chan error, 1)
	go func() {
		_, err := s.device.Read(make([]byte, 1))
		ioStopped <- err
	}()
	closeDone := make(chan error, 1)
	go func() {
		err := s.Close()
		select {
		case <-sink.exited:
		default:
			err = errors.Join(err, fmt.Errorf("Close returned before active packet callback exited"))
		}
		closeDone <- err
	}()
	select {
	case err := <-ioStopped:
		if !errors.Is(err, os.ErrClosed) {
			t.Fatalf("packet descriptor was not interrupted by Close: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not interrupt packet descriptor I/O")
	}
	select {
	case <-s.ReadDone():
		t.Fatal("real read loop exited while its synchronous packet callback was held")
	default:
	}

	// Exercise a real packet response while the stack is being torn down.
	// Its linearization may precede or follow stack closure; only success or
	// the real stack's documented closed error is valid.
	writeNow()
	select {
	case err := <-sink.writeDone:
		if err != nil && !errors.Is(err, net.ErrClosed) && !errors.Is(err, os.ErrClosed) {
			t.Fatalf("unexpected real packet response error during stop: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("real packet response did not finish during stop")
	}
	select {
	case err := <-closeDone:
		t.Fatalf("Close completed while the packet callback was still held: %v", err)
	default:
	}
	leaveNow()
	select {
	case err := <-closeDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not join active packet processing after release")
	}
	select {
	case <-s.ReadDone():
	default:
		t.Fatal("Close returned before publishing read-loop completion")
	}
	if err := s.ReadError(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("lost expected shutdown read cause: %v", err)
	}
	if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != nil {
		t.Fatalf("active-packet shutdown closed the borrowed fd: %v", err)
	}
}
