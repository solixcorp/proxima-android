package session

import (
	"errors"
	"os"
	"testing"
)

type retiredProtector struct{ closed int }

func (*retiredProtector) Protect(int) bool { return true }
func (p *retiredProtector) Close() error   { p.closed++; return nil }

func TestRetirementCannotRebindOldGlobalWorkers(t *testing.T) {
	file, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	var registry Registry
	p := &retiredProtector{}
	token, err := registry.Prepare(int(file.Fd()), p)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.Retire(token + 1); !errors.Is(err, ErrInactive) {
		t.Fatal(err)
	}
	if err := registry.Retire(token); err != nil {
		t.Fatal(err)
	}
	if err := registry.Protect(token, int(file.Fd())); err != nil {
		t.Fatal("retirement revoked active lease", err)
	}
	if err := registry.Close(token); err != nil {
		t.Fatal(err)
	}
	if err := registry.Close(token); err != nil || p.closed != 1 {
		t.Fatal("close not idempotent", err)
	}
	if _, err := registry.Prepare(int(file.Fd()), &retiredProtector{}); !errors.Is(err, ErrRetired) {
		t.Fatal("retired process rebound", err)
	}
}
