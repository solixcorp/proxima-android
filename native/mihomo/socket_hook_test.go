package mihomo_test

import (
	"context"
	"net"
	"net/netip"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/stretchr/testify/require"
	"golang.org/x/sys/unix"
	bridge "proxima.local/mihomo"
	"proxima.local/mihomo/session"
)

type socketProtector struct {
	allow       bool
	validSocket atomic.Bool
}

func (p *socketProtector) Protect(fd int) bool {
	_, err := unix.GetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_TYPE)
	p.validSocket.Store(err == nil)
	return p.allow
}

func (*socketProtector) Close() error { return nil }

func TestMihomoTCPPropagatesProtectionAndBlocksOutsideLease(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	require.NoError(t, err)
	defer func() { require.NoError(t, listener.Close()) }()
	tun, err := os.Open(os.DevNull)
	require.NoError(t, err)
	defer func() { require.NoError(t, tun.Close()) }()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()

	for _, tc := range []struct {
		name     string
		prepared bool
		allow    bool
		wantErr  error
	}{
		{"before session", false, false, session.ErrInactive},
		{"protection refused", true, false, session.ErrProtection},
		{"protection accepted", true, true, nil},
		{"after session", false, false, session.ErrInactive},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := &socketProtector{allow: tc.allow}
			if tc.prepared {
				token, err := bridge.Sessions.Prepare(int(tun.Fd()), p)
				require.NoError(t, err)
				defer func() { require.NoError(t, bridge.Sessions.Close(token)) }()
			}

			conn, err := dialer.DialContext(ctx, "tcp4", listener.Addr().String())

			if tc.wantErr != nil {
				require.ErrorIs(t, err, tc.wantErr)
				require.Nil(t, conn)
			} else {
				require.NoError(t, err)
				require.NoError(t, conn.Close())
				accepted, err := listener.Accept()
				require.NoError(t, err)
				require.NoError(t, accepted.Close())
			}
			require.Equal(t, tc.prepared, p.validSocket.Load())
		})
	}
}

func TestMihomoUDPPropagatesProtectionRefusal(t *testing.T) {
	tun, err := os.Open(os.DevNull)
	require.NoError(t, err)
	defer func() { require.NoError(t, tun.Close()) }()
	p := &socketProtector{}
	token, err := bridge.Sessions.Prepare(int(tun.Fd()), p)
	require.NoError(t, err)
	defer func() { require.NoError(t, bridge.Sessions.Close(token)) }()

	conn, err := dialer.ListenPacket(t.Context(), "udp4", "127.0.0.1:0", netip.AddrPort{})

	require.ErrorIs(t, err, session.ErrProtection)
	require.Nil(t, conn)
	require.True(t, p.validSocket.Load())
}
