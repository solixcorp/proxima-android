package engine

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sync"

	provider "github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"golang.org/x/sys/unix"
	foundation "proxima.local/mihomo"
	"proxima.local/mihomo-provider/boundary"
	"proxima.local/mihomo/session"
)

const coreVersion = "v1.19.33"

// Version identifies the checksum-verified core, independent of upstream's
// release linker variables (which default to "unknown" in source builds).
func Version() string { return coreVersion + " (3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8)" }

var engineProcess struct {
	sync.Mutex
	used bool
}

var ErrProcessUsed = errors.New("Mihomo core process already used; terminate and reap before restarting")

// Session owns one core lifetime. Local TUN shutdown is joined; upstream global
// workers still require process exit. No app connected state is published.
type Session struct {
	mu             sync.Mutex
	token          session.Token
	transfer       int
	cfg            *config.Config
	packets        *sing_tun.Listener
	done           chan struct{}
	stop           chan struct{}
	stopOnce       sync.Once
	result         error
	released       bool
	unleased       session.Protector
	root           bool
	providerStatus map[string]interface{ ProximaLastError() error }
	management     *management
}

// Start borrows the fd and takes ownership of protector on entry, even when it
// fails. The original fd is never closed or changed. A non-nil Session with an
// error means callback release failed: call Stop on that session to retry.
// Semantic parsing consumes this OS process permanently, even on failure.
func Start(configBytes []byte, borrowedTunFd int, protector session.Protector) (*Session, error) {
	return StartWithOptions(configBytes, borrowedTunFd, protector, Options{})
}

// Options are trusted application capabilities, never imported YAML values.
type Options struct{ ProviderRoot string }

// StartWithOptions requires an existing app-private directory for providers.
// The caller must exclude hostile same-UID writers and keep it stable until Stop.
func StartWithOptions(configBytes []byte, borrowedTunFd int, protector session.Protector, options Options) (*Session, error) {
	engineProcess.Lock()
	defer engineProcess.Unlock()
	if engineProcess.used {
		return failUnleased(ErrProcessUsed, protector)
	}
	s := &Session{transfer: -1, done: make(chan struct{}), stop: make(chan struct{})}
	token, err := foundation.Sessions.Prepare(borrowedTunFd, protector)
	if err != nil {
		return failUnleased(err, protector)
	}
	s.token = token
	rollback := func(cause error) (*Session, error) {
		s.result = errors.Join(cause, s.shutdown())
		close(s.done)
		if release := foundation.Sessions.Close(s.token); release != nil {
			return s, errors.Join(s.result, release)
		}
		s.released = true
		return nil, s.result
	}
	// The adapter, not the registry, owns this transfer until TUN has stopped.
	s.transfer, err = foundation.Sessions.DuplicateTun(token)
	if err != nil {
		return rollback(err)
	}
	source := bytes.Clone(configBytes)
	snapshot, err := Decode(context.Background(), source, RevisionOf(source))
	if err != nil {
		return rollback(err)
	}
	raw, err := snapshot.Raw(context.Background())
	if err != nil {
		return rollback(err)
	}
	if err := admit(snapshot.Bytes(), raw); err != nil {
		return rollback(err)
	}
	if len(raw.ProxyProvider)+len(raw.RuleProvider) > 0 && options.ProviderRoot == "" {
		return rollback(errors.New("trusted application ProviderRoot required"))
	}
	if options.ProviderRoot != "" && !filepath.IsAbs(options.ProviderRoot) {
		return rollback(errors.New("ProviderRoot must be an absolute application-owned directory"))
	}
	// Fence ALL registry clients, including direct NativeSession.prepare callers.
	// Closing a lease alone cannot prevent delayed old core workers from using a
	// replacement process-wide protection hook.
	if err := foundation.Sessions.Retire(token); err != nil {
		return rollback(err)
	}
	engineProcess.used = true
	s.management = newManagement(new(statistic.Manager))
	if err := tunnel.ProximaBindStatistics(s.management.stats); err != nil {
		return rollback(err)
	}
	if options.ProviderRoot != "" {
		if err := boundary.ConfigureRoot(options.ProviderRoot); err != nil {
			return rollback(fmt.Errorf("provider root: %w", err))
		}
		s.root = true
		C.SetHomeDir(options.ProviderRoot)
		if cachefile.Cache().DB == nil {
			return rollback(errors.New("initialize confined provider metadata cache"))
		}
	}
	provider.ProximaProxyPolicy = passiveProviderProxy
	s.cfg, err = config.ParseRawConfigWithError(raw)
	if err != nil {
		return rollback(fmt.Errorf("Mihomo semantic configuration: %w", err))
	}
	s.providerStatus = make(map[string]interface{ ProximaLastError() error })
	for name, p := range s.cfg.Providers {
		if status, ok := p.(interface{ ProximaLastError() error }); ok {
			s.providerStatus["proxy/"+name] = status
		}
	}
	for name, p := range s.cfg.RuleProviders {
		if status, ok := p.(interface{ ProximaLastError() error }); ok {
			s.providerStatus["rule/"+name] = status
		}
	}
	s.cfg.General.Tun.FileDescriptor = s.transfer
	s.cfg.General.Tun.ProximaRawFD = true
	s.packets, err = executor.ApplyConfigWithError(s.cfg)
	if err != nil {
		return rollback(err)
	}
	select {
	case <-s.packets.ProximaReadDone():
		return rollback(fmt.Errorf("TUN input exited during startup: %w", s.packets.ProximaReadError()))
	default:
	}
	s.management.mu.Lock()
	s.management.proxies = s.cfg.Proxies
	s.management.running = true
	s.management.mu.Unlock()
	go s.run()
	return s, nil
}

func failUnleased(cause error, p session.Protector) (*Session, error) {
	if p == nil {
		return nil, cause
	}
	if err := p.Close(); err != nil {
		s := &Session{unleased: p, transfer: -1, result: cause, done: make(chan struct{}), stop: make(chan struct{})}
		close(s.done)
		return s, errors.Join(cause, err)
	}
	return nil, cause
}

func (s *Session) shutdown() error {
	if s.management != nil {
		s.management.retire()
		s.management.calls.Wait()
	}
	var packetErr, fdErr error
	if s.packets != nil {
		packetErr = s.packets.Close()
	}
	// Raw runtime borrows and duplicates the transfer. Only this owner may close
	// the transfer, and only after the stack has drained (also on startup error).
	if s.transfer >= 0 {
		fdErr = unix.Close(s.transfer)
		s.transfer = -1
	}
	var coreErr error
	if s.cfg != nil {
		coreErr = executor.StopConfig(s.cfg)
		s.cfg = nil
	}
	if s.root {
		if db := cachefile.Cache().DB; db != nil {
			coreErr = errors.Join(coreErr, db.Close())
		}
		coreErr = errors.Join(coreErr, boundary.CloseRoot())
		s.root = false
	}
	return errors.Join(packetErr, fdErr, coreErr)
}

func (s *Session) run() {
	select {
	case <-s.stop:
	case <-s.packets.ProximaReadDone():
		s.result = fmt.Errorf("TUN input stopped unexpectedly: %w", s.packets.ProximaReadError())
	}
	s.result = errors.Join(s.result, s.shutdown())
	close(s.done)
}

// Done reports local packet/core shutdown, NOT worker-process termination.
// Unexpected input exit initiates shutdown automatically. Stop must still be
// called on an attached JVM thread to release a JNI protector.
func (s *Session) Done() <-chan struct{} { return s.done }
func (s *Session) Wait() error           { <-s.done; return s.result }

// ProviderErrors returns the latest failed update per resource. A subsequent
// successful refresh clears it. Failed refreshes retain the last-good core/cache;
// they are observable errors, never a new successful provider version.
func (s *Session) ProviderErrors() map[string]error {
	result := make(map[string]error)
	for name, status := range s.providerStatus {
		if err := status.ProximaLastError(); err != nil {
			result[name] = err
		}
	}
	return result
}

// Stop is serialized, idempotent and retryable if protector release fails. It
// must not run reentrantly from a socket protection callback. A successful local
// Stop never authorizes in-process reuse: the retired registry stays fail closed.
func (s *Session) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stopOnce.Do(func() {
		if s.management != nil {
			s.management.retire()
		}
		close(s.stop)
	})
	<-s.done
	if !s.released {
		if s.unleased != nil {
			if err := s.unleased.Close(); err != nil {
				return errors.Join(s.result, err)
			}
			s.unleased = nil
		}
		if err := foundation.Sessions.Close(s.token); err != nil {
			return errors.Join(s.result, err)
		}
		s.released = true
	}
	return s.result
}

// Released reports callback cleanup, not worker-process exit. JNI uses it to
// discard cleanup handles even when Stop returns a terminal packet error.
func (s *Session) Released() bool { s.mu.Lock(); defer s.mu.Unlock(); return s.released }
