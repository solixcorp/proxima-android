package diagnostic

import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"syscall"
	"testing"
)

func TestClassificationDoesNotExposeErrorText(t *testing.T) {
	for _, test := range []struct {
		err  error
		want string
	}{
		{fmt.Errorf("secret.example: %w", context.DeadlineExceeded), "deadline"},
		{fmt.Errorf("secret.example: %w", x509.UnknownAuthorityError{}), "tls-certificate"},
		{fmt.Errorf("secret.example: %w", syscall.ECONNREFUSED), "connection-refused"},
		{errors.New("secret.example token=value"), "other"},
	} {
		if got := classify(test.err); got != test.want {
			t.Errorf("classify = %q, want %q", got, test.want)
		}
	}
}
