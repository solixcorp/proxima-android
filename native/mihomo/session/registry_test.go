package session_test

import (
	"net"
	"os"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/sys/unix"
	"proxima.local/mihomo/session"
)

type protector struct {
	allow  bool
	closed atomic.Bool
}

func (p *protector) Protect(int) bool { return p.allow && !p.closed.Load() }
func (p *protector) Close() error {
	p.closed.Store(true)
	return nil
}

func tunFile(t *testing.T) *os.File {
	t.Helper()
	f, err := os.Open(os.DevNull)
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, f.Close()) })
	return f
}

func TestPrepareDoesNotTakeCallerDescriptor(t *testing.T) {
	f := tunFile(t)
	var registry session.Registry
	token, err := registry.Prepare(int(f.Fd()), &protector{allow: true})
	require.NoError(t, err)
	transferred, err := registry.DuplicateTun(token)
	require.NoError(t, err)

	require.NoError(t, registry.Close(token))

	// Both descriptors belong to callers, independently of the bridge lease.
	_, err = unix.FcntlInt(f.Fd(), unix.F_GETFD, 0)
	require.NoError(t, err)
	flags, err := unix.FcntlInt(uintptr(transferred), unix.F_GETFD, 0)
	require.NoError(t, err)
	require.Equal(t, unix.FD_CLOEXEC, flags&unix.FD_CLOEXEC)
	require.NoError(t, unix.Close(transferred))
	_, err = registry.DuplicateTun(token)
	require.ErrorIs(t, err, session.ErrInactive)
}

func TestFailedPrepareDoesNotConsumeProtector(t *testing.T) {
	var registry session.Registry
	p := &protector{allow: true}

	_, err := registry.Prepare(-1, p)

	require.ErrorIs(t, err, session.ErrInvalidFD)
	require.False(t, p.closed.Load())
	f := tunFile(t)
	token, err := registry.Prepare(int(f.Fd()), p)
	require.NoError(t, err)
	require.NoError(t, registry.Close(token))
	require.True(t, p.closed.Load())
}

func TestStaleLeaseCannotProtectOrCloseReplacement(t *testing.T) {
	var registry session.Registry
	f := tunFile(t)
	old, err := registry.Prepare(int(f.Fd()), &protector{allow: true})
	require.NoError(t, err)
	require.NoError(t, registry.Close(old))
	current, err := registry.Prepare(int(f.Fd()), &protector{allow: true})
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, registry.Close(current)) })

	require.NoError(t, registry.Close(old))

	require.ErrorIs(t, registry.Protect(old, 1), session.ErrInactive)
	require.NoError(t, registry.Protect(current, 1))
}

func TestConcurrentPrepareHasOneOwner(t *testing.T) {
	var registry session.Registry
	f := tunFile(t)
	type result struct {
		token session.Token
		err   error
	}
	results := make(chan result, 8)
	start := make(chan struct{})
	var workers sync.WaitGroup
	for range 8 {
		workers.Go(func() {
			<-start
			token, err := registry.Prepare(int(f.Fd()), &protector{allow: true})
			results <- result{token, err}
		})
	}

	close(start)
	workers.Wait()
	close(results)

	var owner session.Token
	successes := 0
	for result := range results {
		if result.err == nil {
			successes++
			owner = result.token
		} else {
			require.ErrorIs(t, result.err, session.ErrBusy)
		}
	}
	require.Equal(t, 1, successes)
	require.NoError(t, registry.Close(owner))
}

func TestControlPropagatesClosedSocketError(t *testing.T) {
	var registry session.Registry
	f := tunFile(t)
	token, err := registry.Prepare(int(f.Fd()), &protector{allow: true})
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, registry.Close(token)) })
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	raw, err := conn.SyscallConn()
	require.NoError(t, err)
	require.NoError(t, conn.Close())

	err = registry.Control("udp4", "", raw)

	require.ErrorIs(t, err, net.ErrClosed)
}

func TestProtectionDuringCloseIsSafe(t *testing.T) {
	var registry session.Registry
	f := tunFile(t)
	p := &protector{allow: true}
	token, err := registry.Prepare(int(f.Fd()), p)
	require.NoError(t, err)
	var workers sync.WaitGroup
	start := make(chan struct{})
	for range 8 {
		workers.Go(func() {
			<-start
			for range 100 {
				err := registry.Protect(token, 1)
				if err != nil {
					assert.ErrorIs(t, err, session.ErrInactive)
				}
			}
		})
	}

	close(start)
	require.NoError(t, registry.Close(token))
	workers.Wait()

	require.True(t, p.closed.Load())
	require.ErrorIs(t, registry.Protect(token, 1), session.ErrInactive)
}
