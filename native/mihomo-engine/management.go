package engine

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"proxima.local/mihomo/providerpolicy"
)

var ErrNotRunning = errors.New("engine session is not running or has retired")
var ErrSnapshotTooLarge = errors.New("connections snapshot exceeds safety limit")

const MaxSnapshotBytes = 8 << 20
const MaxSnapshotConnections = 10000

type management struct {
	mu         sync.Mutex
	running    bool
	retired    bool
	ctx        context.Context
	cancel     context.CancelFunc
	calls      sync.WaitGroup
	stats      *statistic.Manager
	proxies    map[string]C.Proxy
	snapshotMu sync.Mutex
}

func newManagement(stats *statistic.Manager) *management {
	ctx, cancel := context.WithCancel(context.Background())
	return &management{stats: stats, ctx: ctx, cancel: cancel}
}

func (m *management) retire() {
	m.mu.Lock()
	m.retired = true
	m.running = false
	m.cancel()
	m.mu.Unlock()
}

func (s *Session) beginManagement() (*management, error) {
	if s == nil || s.management == nil {
		return nil, ErrNotRunning
	}
	m := s.management
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.running || m.retired {
		return nil, ErrNotRunning
	}
	m.calls.Add(1)
	return m, nil
}

// TrafficStats reads the session-owned upstream atomic payload-byte totals.
// It does not enumerate connections, measure rates, or read DefaultManager.
func (s *Session) TrafficStats() (upBytes, downBytes int64, err error) {
	m, err := s.beginManagement()
	if err != nil {
		return 0, 0, err
	}
	defer m.calls.Done()
	upBytes, downBytes = m.stats.Total()
	return
}

// DelayTest allows concurrent calls, including the same proxy. Each call has
// private URLTest history, so arbitrary URLs cannot grow the session's history.
// It uses the named top-level proxy/group (or built-in DIRECT), not rule routing.
// Stop cancels and joins all admitted calls before closing proxies/the lease.
func (s *Session) DelayTest(name, url string, timeoutMs int) (delayMs int, err error) {
	m, err := s.beginManagement()
	if err != nil {
		return 0, err
	}
	defer m.calls.Done()
	if timeoutMs < 1 || timeoutMs > 60000 {
		return 0, errors.New("delay timeoutMs must be 1..60000")
	}
	if len(name) > 8192 || len(url) > 8192 {
		return 0, errors.New("delay name/URL exceeds 8192 bytes")
	}
	if _, err := providerpolicy.URL(url); err != nil {
		return 0, fmt.Errorf("delay URL: %w", err)
	}
	p, ok := m.proxies[name]
	if !ok {
		return 0, fmt.Errorf("unknown proxy/group %q", name)
	}
	ctx, cancel := context.WithTimeout(m.ctx, time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	delay, err := adapter.NewProxy(p.Adapter()).URLTest(ctx, url, nil)
	if err != nil {
		return 0, err
	}
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	return int(delay), nil
}

// Connection is an immutable projection of an actual upstream TrackerInfo.
// Start is RFC3339Nano; counters are payload bytes, not wire/IP overhead.
type Connection struct {
	ID          string    `json:"id"`
	Host        string    `json:"host"`
	Network     string    `json:"network"`
	Chains      C.Chain   `json:"chains"`
	Rule        string    `json:"rule"`
	RulePayload string    `json:"rulePayload"`
	Upload      int64     `json:"upload"`
	Download    int64     `json:"download"`
	Start       time.Time `json:"start"`
}

// ConnectionsSnapshot returns a bounded UTF-8 JSON array, never Go pointers or
// a borrowed native buffer. Range is weakly consistent with connection churn;
// individual byte counters are atomic, not a cross-connection transaction.
func (s *Session) ConnectionsSnapshot() ([]byte, error) {
	m, err := s.beginManagement()
	if err != nil {
		return nil, err
	}
	defer m.calls.Done()
	// Only one large encoder per session, even with concurrent Java callers.
	m.snapshotMu.Lock()
	defer m.snapshotMu.Unlock()
	if err := m.ctx.Err(); err != nil {
		return nil, ErrNotRunning
	}
	var out bytes.Buffer
	out.WriteByte('[')
	count := 0
	m.stats.Range(func(tracker statistic.Tracker) bool {
		if m.ctx.Err() != nil {
			err = ErrNotRunning
			return false
		}
		info := tracker.Info()
		host, network := "", ""
		if info.Metadata != nil {
			host, network = info.Metadata.Host, info.Metadata.NetWork.String()
		}
		// Bound a single encoding too; json.Marshal must not allocate a giant
		// intermediate record before the aggregate output limit is checked.
		if count >= MaxSnapshotConnections || len(host)+len(info.Rule)+len(info.RulePayload) > 65536 || len(info.Chain) > 256 {
			err = ErrSnapshotTooLarge
			return false
		}
		size := 0
		for _, name := range info.Chain {
			size += len(name)
			if size > 65536 {
				err = ErrSnapshotTooLarge
				return false
			}
		}
		row, encodeErr := json.Marshal(Connection{ID: info.UUID.String(), Host: host, Network: network, Chains: info.Chain,
			Rule: info.Rule, RulePayload: info.RulePayload, Upload: info.UploadTotal.Load(), Download: info.DownloadTotal.Load(), Start: info.Start})
		if encodeErr != nil {
			err = encodeErr
			return false
		}
		if out.Len()+len(row)+2 > MaxSnapshotBytes {
			err = ErrSnapshotTooLarge
			return false
		}
		if count > 0 {
			out.WriteByte(',')
		}
		out.Write(row)
		count++
		return true
	})
	if err != nil {
		return nil, err
	}
	out.WriteByte(']')
	return out.Bytes(), nil
}
