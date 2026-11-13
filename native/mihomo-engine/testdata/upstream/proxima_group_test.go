package outboundgroup

import (
	"errors"
	"sync"
	"testing"
	"testing/synctest"

	C "github.com/metacubex/mihomo/constant"
)

func TestProximaGroupCloseDrainsAndDeniesFailureWorkers(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		gb := &GroupBase{}
		entered, release, stopped := make(chan struct{}), make(chan struct{}), make(chan struct{})
		gb.proximaGo(func() { close(entered); <-release })
		<-entered
		go func() { _ = gb.Close(); close(stopped) }()
		synctest.Wait()
		select {
		case <-stopped:
			t.Fatal("Close did not join owned task")
		default:
		}
		gb.proximaGo(func() { t.Error("late task admitted") })
		if n := ProximaGroupWorkers(); n != 1 {
			t.Fatalf("active workers=%d", n)
		}
		close(release)
		<-stopped
		if n := ProximaGroupWorkers(); n != 0 {
			t.Fatalf("unjoined workers=%d", n)
		}
	})
}

func TestProximaGroupFailureCounterConcurrentSuccess(t *testing.T) {
	gb := NewGroupBase(GroupBaseOption{Name: "counter-test", MaxFailedTimes: 10000})
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); gb.onDialFailed(C.Shadowsocks, errors.New("timeout"), func() {}) }()
		go func() { defer wg.Done(); gb.onDialSuccess() }()
	}
	wg.Wait()
	_ = gb.Close()
	if ProximaGroupWorkers() != 0 {
		t.Fatal("failure worker escaped Close")
	}
}
