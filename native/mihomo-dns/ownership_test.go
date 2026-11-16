package mihomodns

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/metacubex/sing/common/buf"
	M "github.com/metacubex/sing/common/metadata"
	D "github.com/miekg/dns"
)

// Observe the real allocator boundary, including scratch buffers never handed
// to a writer. This adds no production test hook and still uses sing's allocator.
type allocationTracker struct {
	base buf.Allocator
	mu   sync.Mutex
	live map[*byte]struct{}
	gets int
	puts int
}

func trackAllocations(t *testing.T) *allocationTracker {
	t.Helper()
	tracker := &allocationTracker{base: buf.DefaultAllocator, live: make(map[*byte]struct{})}
	buf.DefaultAllocator = tracker
	t.Cleanup(func() { buf.DefaultAllocator = tracker.base })
	return tracker
}

func (a *allocationTracker) Get(size int) []byte {
	data := a.base.Get(size)
	a.mu.Lock()
	defer a.mu.Unlock()
	a.gets++
	a.live[&data[0]] = struct{}{}
	return data
}

func (a *allocationTracker) Put(data []byte) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if _, ok := a.live[&data[0]]; !ok {
		return errors.New("buffer returned to allocator more than once")
	}
	delete(a.live, &data[0])
	a.puts++
	return a.base.Put(data)
}

func (a *allocationTracker) assertReleased(t *testing.T, expected int) {
	t.Helper()
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.gets != expected || a.puts != expected || len(a.live) != 0 {
		t.Fatalf("buffer ownership: gets=%d puts=%d live=%d; expected %d balanced allocations",
			a.gets, a.puts, len(a.live), expected)
	}
}

var errPacketWriter = errors.New("test packet writer interrupted")

type failingPacketWriter struct {
	release bool
}

func (w failingPacketWriter) WritePacket(buffer *buf.Buffer, _ M.Socksaddr) error {
	if w.release {
		buffer.Release() // Matches the actual mipsUDPWriter's error behavior.
	}
	return errPacketWriter
}

func TestUDPWriterFailureReleasesEveryManagedBufferOnce(t *testing.T) {
	for _, tc := range []struct {
		name    string
		release bool
		large   bool
	}{
		{"caller-releases", false, false},
		{"writer-releases", true, false},
		{"truncated/caller-releases", false, true},
		{"truncated/writer-releases", true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			newFakeIPFixture(t)
			allocations := trackAllocations(t)
			s := newSession(t)
			m := query("ownership.example.", D.TypeA)
			if tc.large {
				m.SetEdns0(512, false)
				m.IsEdns0().Option = append(m.IsEdns0().Option, &D.EDNS0_PADDING{Padding: make([]byte, 3000)})
			}
			input := packet(t, m)

			handled, err := s.HandleUDP(testContext(t), input, M.SocksaddrFromNetIP(testDestination), failingPacketWriter{release: tc.release})

			if !handled || !errors.Is(err, errPacketWriter) {
				t.Fatalf("writer error not returned: handled=%v err=%v", handled, err)
			}
			s.Wait()
			allocations.assertReleased(t, 2) // Owned request and bounded reply buffer.
		})
	}
}

func TestUDPRejectsCanceledAndStoppedRequestsWithoutRetainingInput(t *testing.T) {
	for _, stopped := range []bool{false, true} {
		name := "canceled"
		if stopped {
			name = "stopped"
		}
		t.Run(name, func(t *testing.T) {
			newFakeIPFixture(t)
			allocations := trackAllocations(t)
			s := newSession(t)
			ctx, cancel := context.WithCancel(testContext(t))
			defer cancel()
			want := context.Canceled
			if stopped {
				s.Stop()
				want = ErrStopped
			} else {
				cancel()
			}
			input := packet(t, query("rejected.example.", D.TypeA))

			handled, err := s.HandleUDP(ctx, input, M.SocksaddrFromNetIP(testDestination), failingPacketWriter{})

			if !handled || !errors.Is(err, want) {
				t.Fatalf("rejected request: handled=%v err=%v want=%v", handled, err, want)
			}
			allocations.assertReleased(t, 1)
		})
	}
}
