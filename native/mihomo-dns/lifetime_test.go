package mihomodns

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"sync"
	"testing"
	"testing/synctest"

	"github.com/metacubex/sing/common/buf"
	M "github.com/metacubex/sing/common/metadata"
	D "github.com/miekg/dns"
)

type observedConn struct {
	net.Conn
	writes  bool
	entered chan struct{}
	once    sync.Once
}

func (c *observedConn) Read(p []byte) (int, error) {
	if !c.writes {
		c.once.Do(func() { close(c.entered) })
	}
	return c.Conn.Read(p)
}

func (c *observedConn) Write(p []byte) (int, error) {
	if c.writes {
		c.once.Do(func() { close(c.entered) })
	}
	return c.Conn.Write(p)
}

func TestCancellationInterruptsTCPReadAndWrite(t *testing.T) {
	for _, tc := range []struct {
		name   string
		writes bool
		stop   bool
	}{
		{"session/read", false, true},
		{"session/write", true, true},
		{"request/read", false, false},
		{"request/write", true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			newFakeIPFixture(t)
			s := newSession(t)
			client, server := net.Pipe()
			defer client.Close()
			wrapped := &observedConn{Conn: server, writes: tc.writes, entered: make(chan struct{})}
			ctx, cancel := context.WithCancel(testContext(t))
			defer cancel()
			done := make(chan error, 1)
			go func() {
				_, err := s.HandleTCP(ctx, wrapped, testDestination)
				done <- err
			}()
			if tc.writes {
				if err := (&D.Conn{Conn: client}).WriteMsg(query("blocked.example.", D.TypeA)); err != nil {
					t.Fatal(err)
				}
			}
			receive(t, wrapped.entered)

			if tc.stop {
				s.Stop()
			} else {
				cancel()
			}

			if err := receive(t, done); !errors.Is(err, context.Canceled) {
				t.Fatalf("TCP cancellation error = %v", err)
			}
			drained := make(chan struct{})
			go func() { s.Wait(); close(drained) }()
			receive(t, drained)
			if _, err := client.Read(make([]byte, 1)); !errors.Is(err, io.EOF) {
				t.Fatalf("TCP peer remains open after drain: %v", err)
			}
		})
	}
}

func TestUDPCancellationDrainsRelayButNotNativeUpstreamWorker(t *testing.T) {
	if os.Getenv("MIHOMO_DNS_PROCESS_TEST") != "1" {
		runProcessTest(t)
		return
	}
	f := newNativeFixture(t, "udp")
	allocations := trackAllocations(t)
	s := newSession(t)
	m := query("pending.example.", D.TypeA)
	input := packet(t, m)
	sink := new(packetSink)
	done := make(chan error, 1)
	ctx := testContext(t)
	go func() {
		_, err := s.HandleUDP(ctx, input, M.SocksaddrFromNetIP(testDestination), sink)
		done <- err
	}()
	receive(t, f.entered)

	s.Stop()
	drained := make(chan struct{})
	go func() { s.Wait(); close(drained) }()
	receive(t, drained)
	allocations.assertReleased(t, 2)

	if err := receive(t, done); !errors.Is(err, context.Canceled) {
		t.Fatalf("UDP cancellation error = %v", err)
	}
	if sink.data != nil {
		t.Fatal("a canceled UDP lookup wrote a response")
	}
	// The sink is deliberately still blocked. Native singleflight/cache refresh
	// workers have no exported join API; do not race them by restoring globals
	// or closing their sink. The process owns all of these resources until exit.
	if _, err := os.Stdout.WriteString(processDrained + "\n"); err != nil {
		t.Fatal(err)
	}
	os.Exit(0)
}

type blockedPacketWriter struct {
	entered chan struct{}
	closed  chan struct{}
}

func (w *blockedPacketWriter) WritePacket(*buf.Buffer, M.Socksaddr) error {
	close(w.entered)
	<-w.closed
	return net.ErrClosed
}

func TestWaitJoinsPendingUDPWriterAfterTransportInterruption(t *testing.T) {
	// synctest supplies a scheduler barrier, not an elapsed-time assertion. The
	// actual native fake-IP service runs inside the bubble without network I/O.
	synctest.Test(t, func(t *testing.T) {
		newFakeIPFixture(t)
		s := newSession(t)
		writer := &blockedPacketWriter{entered: make(chan struct{}), closed: make(chan struct{})}
		input := packet(t, query("writer.example.", D.TypeA))
		done := make(chan error, 1)
		go func() {
			_, err := s.HandleUDP(context.Background(), input, M.SocksaddrFromNetIP(testDestination), writer)
			done <- err
		}()
		receive(t, writer.entered)
		s.Stop()
		drained := make(chan struct{})
		go func() { s.Wait(); close(drained) }()
		synctest.Wait()
		select {
		case <-drained:
			t.Error("Wait returned while a packet writer still owned its reply")
		default:
		}

		close(writer.closed) // The TUN worker's transport interruption barrier.

		if err := receive(t, done); !errors.Is(err, net.ErrClosed) {
			t.Fatalf("interrupted packet write error = %v", err)
		}
		receive(t, drained)
		s.Wait()
	})
}
