package session

import (
	"os"
	"testing"

	"github.com/stretchr/testify/require"
	"golang.org/x/sys/unix"
)

type fdProtector struct{}

func (fdProtector) Protect(int) bool { return true }
func (fdProtector) Close() error    { return nil }

func TestCloseReleasesTheBridgeOwnedDescriptor(t *testing.T) {
	caller, err := os.Open(os.DevNull)
	require.NoError(t, err)
	defer func() { require.NoError(t, caller.Close()) }()
	var registry Registry
	token, err := registry.Prepare(int(caller.Fd()), fdProtector{})
	require.NoError(t, err)
	// Capture the owned fd only to check its actual kernel lifetime. No test-only
	// export exposes the descriptor to a production caller.
	owned := registry.current.tun

	require.NoError(t, registry.Close(token))

	_, err = unix.FcntlInt(uintptr(owned), unix.F_GETFD, 0)
	require.ErrorIs(t, err, unix.EBADF)
}
