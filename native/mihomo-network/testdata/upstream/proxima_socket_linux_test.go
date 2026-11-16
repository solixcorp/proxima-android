//go:build linux

package tproxy

import (
	"errors"
	"net/netip"
	"os"
	"syscall"
	"testing"

	"github.com/metacubex/mihomo/component/dialer"
)

func TestProximaRawUDPRefusedBeforeBindConnect(t *testing.T) {
	old := dialer.DefaultSocketHook
	defer func() { dialer.DefaultSocketHook = old }()
	refused := errors.New("protection refused")
	var raw syscall.RawConn
	calls := 0
	dialer.DefaultSocketHook = func(_, _ string, c syscall.RawConn) error {
		calls++
		raw = c
		if err := c.Control(func(fd uintptr) {
			sa, err := syscall.Getsockname(int(fd))
			if err != nil {
				t.Fatal(err)
			}
			if sa.(*syscall.SockaddrInet4).Port != 0 {
				t.Fatal("bound before protect")
			}
			if _, err := syscall.Getpeername(int(fd)); !errors.Is(err, syscall.ENOTCONN) {
				t.Fatalf("connected before protect: %v", err)
			}
		}); err != nil {
			t.Fatal(err)
		}
		return refused
	}
	c, err := dialUDP("udp4", netip.MustParseAddrPort("127.0.0.1:0"), netip.MustParseAddrPort("127.0.0.1:9"))
	if c != nil {
		c.Close()
		t.Fatal("refused socket returned")
	}
	if !errors.Is(err, refused) || calls != 1 {
		t.Fatalf("calls=%d err=%v", calls, err)
	}
	// os.File's RawConn returns the poller's closing error directly, unlike
	// File methods that translate it to os.ErrClosed. Compare the same operation
	// on a known-closed File, not an error string or an arbitrary non-nil error.
	closedErr := closedFileRawControlError(t)
	if err := raw.Control(func(uintptr) { t.Fatal("descriptor still owned") }); !errors.Is(err, closedErr) {
		t.Fatalf("original owner not closed: got %T(%v), want %T(%v)", err, err, closedErr, closedErr)
	}
}

func closedFileRawControlError(t *testing.T) error {
	t.Helper()
	f, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	raw, err := f.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	err = raw.Control(func(uintptr) { t.Fatal("closed reference file still owned") })
	if err == nil {
		t.Fatal("closed reference file Control succeeded")
	}
	return err
}
