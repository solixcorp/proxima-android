// Package diagnostic records bounded DNS path diagnostics without query data.
package diagnostic

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"sync"
	"syscall"
)

var seen sync.Map

// Event emits each fixed, caller-supplied stage at most once per process.
func Event(stage string) {
	if _, loaded := seen.LoadOrStore(stage, struct{}{}); !loaded {
		writeLog("DNS " + stage)
	}
}

// Failure deliberately logs only a classification, never err.Error(), which
// may contain a queried domain, URL, credentials, or other private data.
func Failure(stage string, err error) {
	if err == nil {
		return
	}
	Event(stage + ": " + classify(err))
}

func classify(err error) string {
	var unknown x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	var roots x509.SystemRootsError
	var verification *tls.CertificateVerificationError
	var netErr net.Error
	switch {
	case errors.As(err, &unknown), errors.As(err, &hostname), errors.As(err, &invalid), errors.As(err, &roots), errors.As(err, &verification):
		return "tls-certificate"
	case errors.Is(err, context.DeadlineExceeded):
		return "deadline"
	case errors.Is(err, context.Canceled):
		return "canceled"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "connection-refused"
	case errors.Is(err, syscall.ENETUNREACH), errors.Is(err, syscall.EHOSTUNREACH):
		return "network-unreachable"
	case errors.Is(err, syscall.ECONNRESET):
		return "connection-reset"
	case errors.Is(err, syscall.EACCES), errors.Is(err, syscall.EPERM):
		return "permission-denied"
	case errors.As(err, &netErr) && netErr.Timeout():
		return "network-timeout"
	default:
		return "other"
	}
}
