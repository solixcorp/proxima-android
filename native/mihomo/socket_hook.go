// Package mihomo provides the process-wide protected dialer boundary.
// Importing it installs a permanent, fail-closed hook in the pinned upstream
// dialer. It intentionally does not import or start the upstream executor.
package mihomo

import (
	"github.com/metacubex/mihomo/component/dialer"
	"proxima.local/mihomo/session"
)

var Sessions session.Registry

func init() {
	dialer.DefaultSocketHook = Sessions.Control
}
