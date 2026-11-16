//go:build go1.25

package dialer

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"
)

type proximaCountedConn struct {
	net.Conn
	closes atomic.Int32
}

func (c *proximaCountedConn) Close() error {
	c.closes.Add(1)
	return c.Conn.Close()
}

// Instantiate the actual upstream connection, then control only completion of
// its transport dial. No lifecycle implementation is copied into the test.
func proximaDeferred(t *testing.T, ctx context.Context, dial func(context.Context, []byte) (net.Conn, error)) *tfoConn {
	t.Helper()
	c, err := dialTFO(ctx, net.Dialer{}, "tcp4", "127.0.0.1:9")
	if err != nil {
		t.Fatal(err)
	}
	tc := c.(*tfoConn)
	tc.dialFn = dial
	t.Cleanup(func() { _ = tc.Close() })
	return tc
}

func TestProximaTFOCloseOwnsLateDial(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		a, b := net.Pipe()
		defer b.Close()
		owned := &proximaCountedConn{Conn: a}
		release := make(chan struct{})
		var calls atomic.Int32
		c := proximaDeferred(t, context.Background(), func(context.Context, []byte) (net.Conn, error) {
			calls.Add(1)
			<-release // Deliberately complete successfully after cancellation.
			return owned, nil
		})
		first := make(chan error, 1)
		go func() { _, err := c.Write([]byte("first")); first <- err }()
		synctest.Wait()
		if calls.Load() != 1 {
			t.Fatalf("dial calls = %d", calls.Load())
		}
		reader, writer := make(chan error, 1), make(chan error, 1)
		go func() { _, err := c.Read(make([]byte, 1)); reader <- err }()
		go func() { _, err := c.Write([]byte("second")); writer <- err }()
		synctest.Wait()
		if err := c.Close(); err != nil {
			t.Fatal(err)
		}
		synctest.Wait()
		// Waiting readers/writers must unblock even while dialFn still owns
		// its late result. No sleeps or scheduler timing select the ordering.
		if len(reader) != 1 || len(writer) != 1 {
			t.Fatal("Close left a reader or competing writer blocked")
		}
		if err := <-reader; !errors.Is(err, net.ErrClosed) {
			t.Fatalf("reader: %v", err)
		}
		if err := <-writer; !errors.Is(err, net.ErrClosed) {
			t.Fatalf("competing writer: %v", err)
		}
		close(release)
		synctest.Wait()
		if err := <-first; !errors.Is(err, net.ErrClosed) {
			t.Fatalf("late dial: %v", err)
		}
		_ = c.Close()
		if calls.Load() != 1 || owned.closes.Load() != 1 || c.Upstream() != nil {
			t.Fatalf("calls=%d closes=%d upstream=%v", calls.Load(), owned.closes.Load(), c.Upstream())
		}
	})
}

func TestProximaTFOConcurrentFirstWritesAndReaders(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		a, b := net.Pipe()
		defer b.Close()
		owned := &proximaCountedConn{Conn: a}
		release := make(chan struct{})
		var calls atomic.Int32
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		c := proximaDeferred(t, ctx, func(ctx context.Context, early []byte) (net.Conn, error) {
			calls.Add(1)
			<-release
			if _, err := owned.Write(early); err != nil {
				return nil, err
			}
			return owned, nil
		})
		const writers = 8
		writes := make(chan error, writers)
		reads := make(chan error, 3)
		payload := make(chan []byte, 1)
		peerErr := make(chan error, 1)
		go func() {
			buf := make([]byte, writers)
			_, err := io.ReadFull(b, buf)
			payload <- buf
			peerErr <- err
			if err == nil {
				_, err = b.Write([]byte("ack"))
				if err != nil {
					t.Error(err)
				}
			}
		}()
		for i := 0; i < writers; i++ {
			i := i
			go func() {
				n, err := c.Write([]byte{byte(i)})
				if err == nil && n != 1 {
					err = io.ErrShortWrite
				}
				writes <- err
			}()
		}
		for i := 0; i < 3; i++ {
			go func() { _, err := c.Read(make([]byte, 1)); reads <- err }()
		}
		synctest.Wait()
		if calls.Load() != 1 {
			t.Fatalf("concurrent first writes started %d dials", calls.Load())
		}
		close(release)
		// Exercise every observer while the dial result is published.
		for i := 0; i < 8; i++ {
			go func() {
				_ = c.LocalAddr()
				_ = c.RemoteAddr()
				_ = c.Upstream()
				_ = c.NeedHandshake()
				_ = c.NeedAdditionalReadDeadline()
				_ = c.ReaderReplaceable()
				_ = c.WriterReplaceable()
				_ = c.SetDeadline(time.Time{})
				_ = c.SetReadDeadline(time.Time{})
				_ = c.SetWriteDeadline(time.Time{})
			}()
		}
		synctest.Wait()
		if len(writes) != writers || len(reads) != 3 {
			t.Fatal("dial completion did not broadcast to all I/O waiters")
		}
		for i := 0; i < writers; i++ {
			if err := <-writes; err != nil {
				t.Fatal(err)
			}
		}
		for i := 0; i < 3; i++ {
			if err := <-reads; err != nil {
				t.Fatal(err)
			}
		}
		if err := <-peerErr; err != nil {
			t.Fatal(err)
		}
		seen := make(map[byte]bool)
		for _, v := range <-payload {
			seen[v] = true
		}
		if len(seen) != writers || calls.Load() != 1 {
			t.Fatalf("payloads=%v dial calls=%d", seen, calls.Load())
		}
		// Cancelling a completed dial must not invalidate its live stream.
		cancel()
		after := make(chan error, 1)
		go func() {
			buf := make([]byte, 1)
			_, err := b.Read(buf)
			if err == nil && buf[0] != 'x' {
				err = errors.New("wrong post-cancel payload")
			}
			after <- err
		}()
		if _, err := c.Write([]byte("x")); err != nil {
			t.Fatal(err)
		}
		if err := <-after; err != nil {
			t.Fatal(err)
		}
		var closes atomic.Int32
		for i := 0; i < 8; i++ {
			go func() {
				if c.Close() == nil {
					closes.Add(1)
				}
			}()
		}
		synctest.Wait()
		if closes.Load() != 8 || owned.closes.Load() != 1 {
			t.Fatalf("Close returned=%d underlying closes=%d", closes.Load(), owned.closes.Load())
		}
	})
}

func TestProximaTFOWriteDeadlineOwnsLateDial(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		a, b := net.Pipe()
		defer b.Close()
		owned := &proximaCountedConn{Conn: a}
		release := make(chan struct{})
		entered := make(chan context.Context, 1)
		c := proximaDeferred(t, context.Background(), func(ctx context.Context, data []byte) (net.Conn, error) {
			entered <- ctx
			<-release
			if string(data) != "cancel" {
				t.Errorf("dial retained caller buffer after Write returned: %q", data)
			}
			return owned, nil
		})
		result := make(chan error, 1)
		data := []byte("cancel")
		go func() { _, err := c.Write(data); result <- err }()
		synctest.Wait()
		ctx := <-entered
		if err := c.SetWriteDeadline(time.Now().Add(time.Second)); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Second)
		synctest.Wait()
		if len(result) != 1 {
			t.Fatal("Write did not honor its deadline while dial completion was blocked")
		}
		if err := <-result; !errors.Is(err, os.ErrDeadlineExceeded) {
			t.Fatalf("write: %v", err)
		}
		if !errors.Is(context.Cause(ctx), os.ErrDeadlineExceeded) {
			t.Fatalf("in-flight dial not cancelled by write deadline: %v", context.Cause(ctx))
		}
		copy(data, "REUSED")
		if err := c.SetWriteDeadline(time.Time{}); err != nil {
			t.Fatal(err)
		}
		if _, err := c.Write([]byte("again")); !errors.Is(err, os.ErrDeadlineExceeded) {
			t.Fatalf("timed-out establishment was replayed: %v", err)
		}
		close(release)
		synctest.Wait()
		if owned.closes.Load() != 1 || c.Upstream() != nil {
			t.Fatalf("closes=%d upstream=%v", owned.closes.Load(), c.Upstream())
		}
	})
}

func TestProximaTFODialFailureIsShared(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		release := make(chan struct{})
		refused := errors.New("controlled protection refusal")
		var calls atomic.Int32
		c := proximaDeferred(t, context.Background(), func(context.Context, []byte) (net.Conn, error) {
			calls.Add(1)
			<-release
			return nil, refused
		})
		results := make(chan error, 4)
		for i := 0; i < 4; i++ {
			go func() { _, err := c.Write([]byte("refused")); results <- err }()
		}
		synctest.Wait()
		close(release)
		synctest.Wait()
		if len(results) != 4 {
			t.Fatal("failure did not wake all writers")
		}
		for i := 0; i < 4; i++ {
			if err := <-results; !errors.Is(err, refused) {
				t.Fatalf("write: %v", err)
			}
		}
		if _, err := c.Write([]byte("again")); !errors.Is(err, refused) {
			t.Fatal(err)
		}
		if calls.Load() != 1 {
			t.Fatalf("dial retried: %d calls", calls.Load())
		}
	})
}
