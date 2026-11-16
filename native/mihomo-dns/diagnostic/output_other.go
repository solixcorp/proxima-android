//go:build !android || !cgo

package diagnostic

import "github.com/metacubex/mihomo/log"

func writeLog(message string) { log.Warnln("%s", message) }
