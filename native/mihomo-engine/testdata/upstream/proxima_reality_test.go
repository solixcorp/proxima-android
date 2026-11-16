package tls

import (
	"net"
	"syscall"
	"testing"

	"github.com/metacubex/mihomo/component/dialer"
	utls "github.com/metacubex/utls"
)

func TestProximaRealityFailureClosesWithoutBackgroundHTTP(t *testing.T) {
	previous := dialer.DefaultSocketHook
	dialer.DefaultSocketHook = func(string, string, syscall.RawConn) error { t.Fatal("fallback tried to create a socket"); return nil }
	defer func() { dialer.DefaultSocketHook = previous }()
	conn, peer := net.Pipe()
	defer peer.Close()
	proximaRealityClientFallback(conn, "example.invalid", utls.HelloChrome_Auto)
	if _, err := peer.Write([]byte("must already be closed")); err == nil {
		t.Fatal("authentication-failed connection retained")
	}
}
