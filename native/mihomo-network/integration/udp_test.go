package integration

import (
	"context"
	"errors"
	"net"
	"syscall"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"proxima.local/mihomo/session"
)

func TestUDPWithTFORetainsEagerProtectionAndPacketBehavior(t *testing.T) {
	oldIPv6 := resolver.DisableIPv6
	resolver.DisableIPv6 = false
	t.Cleanup(func() { resolver.DisableIPv6 = oldIPv6 })
	for _, network := range []string{"udp", "udp4", "udp6"} {
		t.Run(network, func(t *testing.T) {
			host := "127.0.0.1"
			if network == "udp6" {
				host = "::1"
			}
			server, err := net.ListenPacket(network, net.JoinHostPort(host, "0"))
			if err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			p := lease(t, true)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			c, err := dialer.DialContext(ctx, network, server.LocalAddr().String(), dialer.WithTFO(true))
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			if p.calls != 1 {
				t.Fatalf("protection was deferred: %d calls at return", p.calls)
			}
			if _, ok := c.(*net.UDPConn); !ok {
				t.Fatalf("UDP connection wrapped as %T", c)
			}
			pc, ok := c.(net.PacketConn)
			if !ok {
				t.Fatalf("%T lost net.PacketConn", c)
			}
			sc, ok := c.(syscall.Conn)
			if !ok {
				t.Fatalf("%T lost syscall.Conn", c)
			}
			raw, err := sc.SyscallConn()
			if err != nil {
				t.Fatal(err)
			}
			if err := raw.Control(func(fd uintptr) {
				if _, err := syscall.Getpeername(int(fd)); err != nil {
					t.Errorf("UDP socket not connected at return: %v", err)
				}
			}); err != nil {
				t.Fatal(err)
			}
			local, ok := c.LocalAddr().(*net.UDPAddr)
			if !ok || local.Port == 0 || !local.IP.IsLoopback() {
				t.Fatalf("UDP local address unavailable at return: %v", c.LocalAddr())
			}
			if c.RemoteAddr().String() != server.LocalAddr().String() {
				t.Fatalf("remote=%v server=%v", c.RemoteAddr(), server.LocalAddr())
			}
			// An eager UDP connection survives normal post-DialContext cleanup.
			cancel()
			if _, err := c.Write([]byte("request")); err != nil {
				t.Fatal(err)
			}
			server.SetReadDeadline(time.Now().Add(time.Second))
			buf := make([]byte, 32)
			n, from, err := server.ReadFrom(buf)
			if err != nil || string(buf[:n]) != "request" || from.String() != local.String() {
				t.Fatalf("request=%q from=%v err=%v", buf[:n], from, err)
			}
			if _, err := server.WriteTo([]byte("reply"), from); err != nil {
				t.Fatal(err)
			}
			pc.SetReadDeadline(time.Now().Add(time.Second))
			n, from, err = pc.ReadFrom(buf)
			if err != nil || string(buf[:n]) != "reply" || from.String() != server.LocalAddr().String() {
				t.Fatalf("reply=%q from=%v err=%v", buf[:n], from, err)
			}
			if p.calls != 1 {
				t.Fatalf("extra UDP socket protection attempts: %d", p.calls)
			}
		})
	}
}

func TestUDPWithTFORefusesBeforeReturningConnection(t *testing.T) {
	oldIPv6 := resolver.DisableIPv6
	resolver.DisableIPv6 = false
	t.Cleanup(func() { resolver.DisableIPv6 = oldIPv6 })
	for _, network := range []string{"udp", "udp4", "udp6"} {
		t.Run(network, func(t *testing.T) {
			host := "127.0.0.1"
			if network == "udp6" {
				host = "::1"
			}
			p := lease(t, false)
			c, err := dialer.DialContext(context.Background(), network, net.JoinHostPort(host, "9"), dialer.WithTFO(true))
			if c != nil {
				c.Close()
				t.Fatalf("refusal deferred until Write: returned %T", c)
			}
			if !errors.Is(err, session.ErrProtection) || p.calls != 1 {
				t.Fatalf("protection calls=%d error=%v", p.calls, err)
			}
		})
	}
}
