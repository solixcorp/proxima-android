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
	if err := raw.Control(func(uintptr) { t.Fatal("descriptor still owned") }); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("original owner not closed: %v", err)
	}
}
