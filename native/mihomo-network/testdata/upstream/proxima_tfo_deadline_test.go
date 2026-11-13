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

func proximaTimeout(t *testing.T, err error) {
	t.Helper()
	if !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("want I/O deadline exceeded, got %v", err)
	}
	if e, ok := err.(net.Error); !ok || !e.Timeout() {
		t.Fatalf("deadline error does not implement net.Error.Timeout: %v", err)
	}
}

func TestProximaTFOCallerCleanupBeforeFirstWrite(t *testing.T) {
	for _, cancelEarly := range []bool{true, false} {
		t.Run(map[bool]string{true: "cancel", false: "expired-parent-deadline"}[cancelEarly], func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				a, b := net.Pipe()
				defer b.Close()
				type key struct{}
				parent, cancel := context.WithTimeout(context.WithValue(context.Background(), key{}, "caller"), time.Second)
				defer cancel()
				c := proximaDeferred(t, parent, func(ctx context.Context, data []byte) (net.Conn, error) {
					if ctx.Err() != nil || ctx.Value(key{}) != "caller" {
						t.Errorf("dial context: err=%v value=%v", ctx.Err(), ctx.Value(key{}))
					}
					if deadline, ok := ctx.Deadline(); !ok || deadline.Sub(time.Now()) != DefaultTCPTimeout {
						t.Errorf("establishment budget did not start at first write: %v", deadline)
					}
					if _, err := a.Write(data); err != nil {
						return nil, err
					}
					return a, nil
				})
				if cancelEarly {
					cancel()
				}
				// This also exceeds the old creation-time five-second timeout.
				time.Sleep(2 * DefaultTCPTimeout)
				got := make(chan string, 1)
				go func() {
					data := make([]byte, 5)
					_, err := io.ReadFull(b, data)
					if err != nil {
						t.Error(err)
					}
					got <- string(data)
				}()
				if _, err := c.Write([]byte("hello")); err != nil {
					t.Fatal(err)
				}
				if data := <-got; data != "hello" {
					t.Fatalf("data=%q", data)
				}
			})
		})
	}
}

func TestProximaTFORejectsAlreadyCancelledDial(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	c, err := dialTFO(ctx, net.Dialer{}, "tcp4", "127.0.0.1:9")
	if c != nil || !errors.Is(err, context.Canceled) {
		if c != nil {
			c.Close()
		}
		t.Fatalf("connection=%v error=%v", c, err)
	}
}

func TestProximaTFOCallerCleanupDuringEstablishment(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		a, b := net.Pipe()
		defer b.Close()
		parent, cancel := context.WithCancel(context.Background())
		defer cancel()
		release := make(chan struct{})
		entered := make(chan context.Context, 1)
		c := proximaDeferred(t, parent, func(ctx context.Context, data []byte) (net.Conn, error) {
			entered <- ctx
			<-release
			if _, err := a.Write(data); err != nil {
				return nil, err
			}
			return a, nil
		})
		result := make(chan error, 1)
		go func() { _, err := c.Write([]byte("x")); result <- err }()
		synctest.Wait()
		ctx := <-entered
		cancel()
		synctest.Wait()
		if ctx.Err() != nil || len(result) != 0 {
			t.Fatal("post-return caller cleanup cancelled the connection's establishment")
		}
		go func() {
			data := make([]byte, 1)
			if _, err := io.ReadFull(b, data); err != nil {
				t.Error(err)
			}
		}()
		close(release)
		if err := <-result; err != nil {
			t.Fatal(err)
		}
	})
}

func TestProximaTFOCloseCancelsEstablishment(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		entered := make(chan context.Context, 1)
		c := proximaDeferred(t, context.Background(), func(ctx context.Context, _ []byte) (net.Conn, error) {
			entered <- ctx
			<-ctx.Done()
			return nil, ctx.Err()
		})
		result := make(chan error, 1)
		go func() { _, err := c.Write([]byte("x")); result <- err }()
		synctest.Wait()
		ctx := <-entered
		if err := c.Close(); err != nil {
			t.Fatal(err)
		}
		synctest.Wait()
		if ctx.Err() != context.Canceled {
			t.Fatalf("dial context: %v", ctx.Err())
		}
		if err := <-result; !errors.Is(err, net.ErrClosed) {
			t.Fatalf("write: %v", err)
		}
	})
}

func TestProximaTFOEstablishmentTimeoutStartsAtWrite(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var calls atomic.Int32
		c := proximaDeferred(t, context.Background(), func(ctx context.Context, _ []byte) (net.Conn, error) {
			calls.Add(1)
			<-ctx.Done()
			return nil, ctx.Err()
		})
		time.Sleep(2 * DefaultTCPTimeout)
		result := make(chan error, 1)
		go func() { _, err := c.Write([]byte("x")); result <- err }()
		synctest.Wait()
		if calls.Load() != 1 || len(result) != 0 {
			t.Fatal("idle time consumed establishment budget")
		}
		time.Sleep(DefaultTCPTimeout)
		synctest.Wait()
		if err := <-result; !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("write: %v", err)
		}
	})
}

func TestProximaTFOPendingExpiredDeadlinesCanBeCleared(t *testing.T) {
	for _, kind := range []string{"both", "read", "write"} {
		t.Run(kind, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				a, b := net.Pipe()
				defer b.Close()
				var calls atomic.Int32
				c := proximaDeferred(t, context.Background(), func(_ context.Context, data []byte) (net.Conn, error) {
					calls.Add(1)
					if _, err := a.Write(data); err != nil {
						return nil, err
					}
					return a, nil
				})
				set := c.SetDeadline
				if kind == "read" {
					set = c.SetReadDeadline
				}
				if kind == "write" {
					set = c.SetWriteDeadline
				}
				if err := set(time.Now().Add(time.Second)); err != nil {
					t.Fatal(err)
				}
				time.Sleep(time.Second)
				if kind != "write" {
					_, err := c.Read(make([]byte, 1))
					proximaTimeout(t, err)
				}
				if kind != "read" {
					_, err := c.Write([]byte("expired"))
					proximaTimeout(t, err)
				}
				if calls.Load() != 0 {
					t.Fatal("expired pre-dial I/O opened a transport")
				}
				if err := set(time.Time{}); err != nil {
					t.Fatal(err)
				}
				reply := make(chan error, 1)
				go func() {
					data := make([]byte, 1)
					_, err := io.ReadFull(b, data)
					if err == nil {
						_, err = b.Write(data)
					}
					reply <- err
				}()
				if _, err := c.Write([]byte("x")); err != nil {
					t.Fatal(err)
				}
				data := make([]byte, 1)
				if _, err := c.Read(data); err != nil {
					t.Fatal(err)
				}
				if data[0] != 'x' {
					t.Fatalf("data=%q", data)
				}
				if err := <-reply; err != nil {
					t.Fatal(err)
				}
			})
		})
	}
}

func TestProximaTFOReadDeadlineDoesNotCancelEstablishment(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		a, b := net.Pipe()
		defer b.Close()
		release := make(chan struct{})
		entered := make(chan context.Context, 1)
		c := proximaDeferred(t, context.Background(), func(ctx context.Context, data []byte) (net.Conn, error) {
			entered <- ctx
			<-release
			if _, err := a.Write(data); err != nil {
				return nil, err
			}
			return a, nil
		})
		writer, reader := make(chan error, 1), make(chan error, 1)
		go func() { _, err := c.Write([]byte("x")); writer <- err }()
		go func() { _, err := c.Read(make([]byte, 1)); reader <- err }()
		synctest.Wait()
		ctx := <-entered
		c.SetReadDeadline(time.Now().Add(time.Second))
		time.Sleep(time.Second)
		synctest.Wait()
		if len(reader) != 1 {
			t.Fatal("pending read ignored new deadline")
		}
		proximaTimeout(t, <-reader)
		if ctx.Err() != nil || len(writer) != 0 {
			t.Fatal("read deadline cancelled the writer's dial")
		}
		c.SetReadDeadline(time.Time{})
		go func() {
			data := make([]byte, 1)
			if _, err := io.ReadFull(b, data); err != nil {
				t.Error(err)
				return
			}
			if _, err := b.Write(data); err != nil {
				t.Error(err)
			}
		}()
		close(release)
		if err := <-writer; err != nil {
			t.Fatal(err)
		}
		if _, err := c.Read(make([]byte, 1)); err != nil {
			t.Fatal(err)
		}
	})
}

func TestProximaTFOWriteDeadlineExtensionAndClearing(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		a, b := net.Pipe()
		defer b.Close()
		release := make(chan struct{})
		entered := make(chan context.Context, 1)
		c := proximaDeferred(t, context.Background(), func(ctx context.Context, _ []byte) (net.Conn, error) {
			entered <- ctx
			<-release
			return a, nil
		})
		c.SetWriteDeadline(time.Now().Add(time.Second))
		result := make(chan error, 1)
		go func() { _, err := c.Write([]byte("x")); result <- err }()
		synctest.Wait()
		ctx := <-entered
		c.SetWriteDeadline(time.Now().Add(3 * time.Second))
		time.Sleep(2 * time.Second)
		synctest.Wait()
		if ctx.Err() != nil || len(result) != 0 {
			t.Fatal("obsolete timer cancelled extended deadline")
		}
		c.SetWriteDeadline(time.Time{})
		time.Sleep(2 * time.Second)
		synctest.Wait()
		if ctx.Err() != nil || len(result) != 0 {
			t.Fatal("cleared deadline cancelled establishment")
		}
		close(release)
		if err := <-result; err != nil {
			t.Fatal(err)
		}
	})
}

func TestProximaTFOPendingDeadlinesTransferToConnection(t *testing.T) {
	for _, combined := range []bool{false, true} {
		t.Run(map[bool]string{false: "independent", true: "combined"}[combined], func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				a, b := net.Pipe()
				defer b.Close()
				release := make(chan struct{})
				c := proximaDeferred(t, context.Background(), func(context.Context, []byte) (net.Conn, error) {
					<-release
					return a, nil
				})
				c.SetDeadline(time.Now().Add(time.Second))
				first := make(chan error, 1)
				go func() { _, err := c.Write([]byte("early")); first <- err }()
				synctest.Wait()
				// Set new deadlines while establishment is blocked. Publication
				// must transfer these current values, not its initial snapshot.
				c.SetReadDeadline(time.Now().Add(2 * time.Second))
				c.SetWriteDeadline(time.Now().Add(3 * time.Second))
				if combined {
					c.SetDeadline(time.Now().Add(2 * time.Second))
				}
				close(release)
				if err := <-first; err != nil {
					t.Fatal(err)
				}
				reader, writer := make(chan error, 1), make(chan error, 1)
				go func() { _, err := c.Read(make([]byte, 1)); reader <- err }()
				go func() { _, err := c.Write([]byte("later")); writer <- err }()
				synctest.Wait()
				time.Sleep(2 * time.Second)
				synctest.Wait()
				if len(reader) != 1 {
					t.Fatal("pending read deadline was not transferred")
				}
				proximaTimeout(t, <-reader)
				if !combined {
					if len(writer) != 0 {
						t.Fatal("read deadline affected independent write")
					}
					time.Sleep(time.Second)
					synctest.Wait()
				}
				if len(writer) != 1 {
					t.Fatal("pending write deadline was not transferred")
				}
				proximaTimeout(t, <-writer)
			})
		})
	}
}

func TestProximaTFOCombinedDeadlineCancelsPendingIO(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		entered := make(chan context.Context, 1)
		c := proximaDeferred(t, context.Background(), func(ctx context.Context, _ []byte) (net.Conn, error) {
			entered <- ctx
			<-ctx.Done()
			return nil, ctx.Err()
		})
		reader, writer := make(chan error, 1), make(chan error, 1)
		go func() { _, err := c.Read(make([]byte, 1)); reader <- err }()
		go func() { _, err := c.Write([]byte("x")); writer <- err }()
		synctest.Wait()
		ctx := <-entered
		if err := c.SetDeadline(time.Now().Add(time.Second)); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Second)
		synctest.Wait()
		if len(reader) != 1 || len(writer) != 1 {
			t.Fatal("combined deadline did not unblock both directions")
		}
		proximaTimeout(t, <-reader)
		proximaTimeout(t, <-writer)
		if !errors.Is(context.Cause(ctx), os.ErrDeadlineExceeded) {
			t.Fatalf("establishment cause=%v", context.Cause(ctx))
		}
	})
}

func TestProximaTFOReadDeadlineExtensionAndClearing(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := proximaDeferred(t, context.Background(), func(context.Context, []byte) (net.Conn, error) {
			t.Error("Read unexpectedly initiated a dial")
			return nil, errors.New("unexpected dial")
		})
		if err := c.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
			t.Fatal(err)
		}
		result := make(chan error, 1)
		go func() { _, err := c.Read(make([]byte, 1)); result <- err }()
		synctest.Wait()
		if err := c.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
			t.Fatal(err)
		}
		time.Sleep(2 * time.Second)
		synctest.Wait()
		if len(result) != 0 {
			t.Fatal("old deadline terminated the read after extension")
		}
		if err := c.SetReadDeadline(time.Time{}); err != nil {
			t.Fatal(err)
		}
		time.Sleep(2 * time.Second)
		synctest.Wait()
		if len(result) != 0 {
			t.Fatal("cleared deadline terminated the read")
		}
		if err := c.Close(); err != nil {
			t.Fatal(err)
		}
		synctest.Wait()
		if err := <-result; !errors.Is(err, net.ErrClosed) {
			t.Fatalf("read: %v", err)
		}
	})
}

func TestProximaTFOIODeadlineAtEstablishmentBudget(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := proximaDeferred(t, context.Background(), func(ctx context.Context, _ []byte) (net.Conn, error) {
			<-ctx.Done()
			return nil, ctx.Err()
		})
		if err := c.SetWriteDeadline(time.Now().Add(DefaultTCPTimeout)); err != nil {
			t.Fatal(err)
		}
		result := make(chan error, 1)
		go func() { _, err := c.Write([]byte("x")); result <- err }()
		synctest.Wait()
		time.Sleep(DefaultTCPTimeout)
		synctest.Wait()
		proximaTimeout(t, <-result)
	})
}
