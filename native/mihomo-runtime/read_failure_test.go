package mihomoruntime

import (
	"context"
	"errors"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/listener/sing"
	"github.com/metacubex/mihomo/log"
	tun "github.com/metacubex/sing-tun"
	"golang.org/x/sys/unix"
)

// The device is a fault injector; stack and Mihomo handler remain the real core.
// A second read signals the regression, then blocks until cleanup rather than
// allowing a broken implementation to flood the test log indefinitely.
type failedPacketDevice struct {
	readEntered chan struct{}
	failRead    chan struct{}
	retried     chan struct{}
	closed      chan struct{}
	reads       atomic.Int32
	closeOnce   sync.Once
}

func (d *failedPacketDevice) Read([]byte) (int, error) {
	if d.reads.Add(1) == 1 {
		close(d.readEntered)
		select {
		case <-d.failRead:
			return 0, unix.EIO
		case <-d.closed:
			return 0, os.ErrClosed
		}
	}
	close(d.retried)
	<-d.closed
	return 0, os.ErrClosed
}

func (*failedPacketDevice) Write([]byte) (int, error) { return 0, unix.EIO }

func (d *failedPacketDevice) Close() error {
	d.closeOnce.Do(func() { close(d.closed) })
	return nil
}

func TestPersistentPacketReadErrorTerminatesActualCoreLoop(t *testing.T) {
	device := &failedPacketDevice{
		readEntered: make(chan struct{}),
		failRead:    make(chan struct{}),
		retried:     make(chan struct{}),
		closed:      make(chan struct{}),
	}
	handler, err := sing.NewListenerHandler(sing.ListenerConfig{
		Tunnel: &packetSink{packets: make(chan capturedPacket, 1)},
	})
	if err != nil {
		t.Fatal(err)
	}
	core, err := tun.NewStack("mips", tun.StackOptions{
		Context:    context.Background(),
		Tun:        device,
		TunOptions: tun.Options{MTU: 1500},
		Handler:    &flowHandler{ListenerHandler: handler, conns: make(map[net.Conn]struct{})},
		Logger:     log.SingLogger,
	})
	if err != nil {
		t.Fatal(err)
	}
	stack := core.(*tun.Mipstack)
	t.Cleanup(func() {
		_ = device.Close()
		_ = stack.Close()
		stack.WaitPacketLoops()
	})
	if err = stack.Start(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-device.readEntered:
	case <-time.After(5 * time.Second):
		t.Fatal("real stack did not start its packet read")
	}
	if err := stack.PacketReadError(); err != nil {
		t.Fatalf("reported a read error before the device failed: %v", err)
	}
	close(device.failRead)
	select {
	case <-stack.PacketReadDone():
	case <-device.retried:
		t.Fatal("persistent device error caused a second read instead of termination")
	case <-time.After(5 * time.Second):
		t.Fatal("terminal read error did not publish loop completion")
	}
	if got := device.reads.Load(); got != 1 {
		t.Fatalf("packet reads = %d, want exactly one", got)
	}
	if err := stack.PacketReadError(); !errors.Is(err, unix.EIO) {
		t.Fatalf("lost terminal device error: %v", err)
	}
}
