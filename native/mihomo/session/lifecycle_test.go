package session_test

import (
	"errors"
	"os"
	"testing"
	"testing/synctest"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"proxima.local/mihomo/session"
)

type blockingProtector struct {
	entered  chan struct{}
	proceed  chan struct{}
	released chan struct{}
}

func (p *blockingProtector) Protect(int) bool {
	close(p.entered)
	<-p.proceed
	return true
}

func (p *blockingProtector) Close() error {
	close(p.released)
	return nil
}

func TestCloseDrainsEnteredCallbackBeforeRelease(t *testing.T) {
	f := tunFile(t)
	synctest.Test(t, func(t *testing.T) {
		var registry session.Registry
		p := &blockingProtector{
			entered: make(chan struct{}), proceed: make(chan struct{}),
			released: make(chan struct{}),
		}
		token, err := registry.Prepare(int(f.Fd()), p)
		require.NoError(t, err)
		protectDone := make(chan error, 1)
		go func() { protectDone <- registry.Protect(token, 1) }()
		<-p.entered
		closeDone := make(chan struct{})
		var closeErr error

		go func() {
			closeErr = registry.Close(token)
			close(closeDone)
		}()
		synctest.Wait()

		// Wait proves Close has reached its drain wait, rather than depending on
		// which goroutine the scheduler happens to run first. Always unblock the
		// callback after these checks, including when a regression is detected.
		select {
		case <-closeDone:
			assert.Fail(t, "Close completed while the callback was blocked")
		default:
		}
		select {
		case <-p.released:
			assert.Fail(t, "protector released while its callback was blocked")
		default:
		}
		close(p.proceed)
		require.NoError(t, <-protectDone)
		<-closeDone
		require.NoError(t, closeErr)
		select {
		case <-p.released:
		default:
			t.Fatal("Close returned without releasing the protector")
		}
	})
}

var errUnavailable = errors.New("release environment unavailable")

type retryingProtector struct {
	resource *os.File
	failure  error
}

func (p *retryingProtector) Protect(int) bool {
	_, err := p.resource.Stat()
	return err == nil
}

func (p *retryingProtector) Close() error {
	if p.failure != nil {
		return p.failure
	}
	return p.resource.Close()
}

func retryProtector(t *testing.T) *retryingProtector {
	t.Helper()
	resource, err := os.Open(os.DevNull)
	require.NoError(t, err)
	t.Cleanup(func() {
		if err := resource.Close(); err != nil && !errors.Is(err, os.ErrClosed) {
			t.Error(err)
		}
	})
	return &retryingProtector{resource: resource, failure: errUnavailable}
}

func TestReleaseFailureKeepsLeaseInactiveAndReserved(t *testing.T) {
	var registry session.Registry
	f := tunFile(t)
	p := retryProtector(t)
	token, err := registry.Prepare(int(f.Fd()), p)
	require.NoError(t, err)
	t.Cleanup(func() {
		p.failure = nil
		require.NoError(t, registry.Close(token))
	})

	require.ErrorIs(t, registry.Close(token), errUnavailable)

	require.ErrorIs(t, registry.Protect(token, 1), session.ErrInactive)
	_, err = registry.DuplicateTun(token)
	require.ErrorIs(t, err, session.ErrInactive)
	replacement, err := registry.Prepare(int(f.Fd()), &protector{allow: true})
	if err == nil {
		require.NoError(t, registry.Close(replacement))
	}
	require.ErrorIs(t, err, session.ErrBusy)
}

func TestCloseRetriesFailedProtectorRelease(t *testing.T) {
	var registry session.Registry
	f := tunFile(t)
	p := retryProtector(t)
	token, err := registry.Prepare(int(f.Fd()), p)
	require.NoError(t, err)
	require.ErrorIs(t, registry.Close(token), errUnavailable)
	p.failure = nil

	require.NoError(t, registry.Close(token))

	_, err = p.resource.Stat()
	require.ErrorIs(t, err, os.ErrClosed)
	require.NoError(t, registry.Close(token))
	replacement, err := registry.Prepare(int(f.Fd()), &protector{allow: true})
	require.NoError(t, err)
	require.NoError(t, registry.Close(replacement))
}
