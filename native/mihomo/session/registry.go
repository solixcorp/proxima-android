// Package session owns the descriptor and socket-protection lease for a future
// Mihomo runtime. Preparing a lease does not start a TUN or a VPN.
package session

import (
	"errors"
	"fmt"
	"math"
	"sync"
	"syscall"

	"golang.org/x/sys/unix"
)

var (
	ErrBusy          = errors.New("native session already prepared")
	ErrInactive      = errors.New("native session is inactive")
	ErrProtection    = errors.New("VPN socket protection refused")
	ErrInvalidFD     = errors.New("invalid file descriptor")
	ErrInvalidOwner  = errors.New("socket protector is required")
	ErrTokenOverflow = errors.New("native session token exhausted")
)

type Token int64

// Protector owns its callback resources. Its methods must not reenter Registry.
// Protect only protects the supplied socket. Close releases callback resources;
// on error it must retain ownership and allow a later Close to retry safely.
type Protector interface {
	Protect(fd int) bool
	Close() error
}

type lease struct {
	mu        sync.Mutex
	callbacks sync.WaitGroup
	active    bool
	tun       int
	protector Protector
	token     Token
}

// Registry serializes preparation and release. Its zero value is ready for use.
// A lease is a resource boundary, not a running-core or connectivity indicator.
type Registry struct {
	mu      sync.Mutex
	current *lease
	next    Token
}

// Prepare borrows tunFD and duplicates it atomically with close-on-exec.
// Protector ownership transfers only on success. The caller retains tunFD.
func (r *Registry) Prepare(tunFD int, protector Protector) (Token, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.current != nil {
		return 0, ErrBusy
	}
	if protector == nil {
		return 0, ErrInvalidOwner
	}
	if r.next == math.MaxInt64 {
		return 0, ErrTokenOverflow
	}
	fd, err := duplicate(tunFD)
	if err != nil {
		return 0, fmt.Errorf("duplicate borrowed TUN: %w", err)
	}
	r.next++
	r.current = &lease{active: true, tun: fd, protector: protector, token: r.next}
	return r.next, nil
}

// DuplicateTun gives the caller a separate owned descriptor. The caller must
// close it on every startup error and after its TUN stops. Closing this lease
// cannot revoke duplicates already transferred to a downstream engine.
func (r *Registry) DuplicateTun(token Token) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.current == nil || r.current.token != token || !r.current.active {
		return -1, ErrInactive
	}
	return duplicate(r.current.tun)
}

// Close rejects subsequent socket protection, waits for callbacks already in
// flight, closes the owned TUN duplicate, and then releases the protector.
// A release error retains an inactive lease and blocks Prepare until Close is
// retried successfully. The TUN descriptor is consumed only once. After success,
// repeated/stale Close calls do nothing and never close a newer lease.
// This does not stop an engine or close descriptors transferred by DuplicateTun.
func (r *Registry) Close(token Token) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.current == nil || r.current.token != token {
		return nil
	}
	l := r.current
	l.mu.Lock()
	l.active = false
	l.mu.Unlock()
	l.callbacks.Wait()
	var fdErr error
	if l.tun >= 0 {
		fdErr = unix.Close(l.tun)
		l.tun = -1
	}
	releaseErr := l.protector.Close()
	if releaseErr == nil {
		r.current = nil
	}
	return errors.Join(fdErr, releaseErr)
}

// Protect is token-bound so an expired Java/native lease cannot use a new VPN.
func (r *Registry) Protect(token Token, fd int) error {
	r.mu.Lock()
	l := r.current
	r.mu.Unlock()
	if l == nil || l.token != token {
		return ErrInactive
	}
	return l.protect(fd)
}

func (l *lease) protect(fd int) error {
	l.mu.Lock()
	if !l.active {
		l.mu.Unlock()
		return ErrInactive
	}
	if fd < 0 {
		l.mu.Unlock()
		return ErrInvalidFD
	}
	l.callbacks.Add(1)
	l.mu.Unlock()
	defer l.callbacks.Done()
	if !l.protector.Protect(fd) {
		return ErrProtection
	}
	return nil
}

// Control has Mihomo's SocketControl signature. Install it once before any core
// work; never set the upstream hook to nil during stop. An absent lease rejects
// sockets. Existing sockets and workers must still be shut down by the engine.
func (r *Registry) Control(_, _ string, conn syscall.RawConn) error {
	r.mu.Lock()
	l := r.current
	r.mu.Unlock()
	if l == nil {
		return ErrInactive
	}
	var protectErr error
	if err := conn.Control(func(fd uintptr) {
		if fd > math.MaxInt32 {
			protectErr = ErrInvalidFD
			return
		}
		protectErr = l.protect(int(fd))
	}); err != nil {
		return fmt.Errorf("access socket descriptor: %w", err)
	}
	return protectErr
}

func duplicate(fd int) (int, error) {
	if fd < 0 {
		return -1, ErrInvalidFD
	}
	// Keep descriptors >= 3: zero is a sentinel in upstream TUN configuration.
	owned, err := unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, 3)
	if err != nil {
		return -1, fmt.Errorf("F_DUPFD_CLOEXEC: %w", err)
	}
	return owned, nil
}
