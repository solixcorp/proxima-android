// Package integration anchors the actual packages covered by the overlay.
package integration

import (
	_ "github.com/metacubex/mihomo/adapter/inbound"
	_ "github.com/metacubex/mihomo/listener/redir"
	_ "github.com/metacubex/mihomo/listener/tproxy"
	_ "proxima.local/mihomo"
)
