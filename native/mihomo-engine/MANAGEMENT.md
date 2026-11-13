# Phase 1.5: session-scoped management (no HTTP controller)

## API

```go
func (*Session) TrafficStats() (upBytes, downBytes int64, err error)
func (*Session) DelayTest(name, url string, timeoutMs int) (delayMs int, err error)
func (*Session) ConnectionsSnapshot() ([]byte, error)
```

```java
// kr.kimrasng.proxima.mihomo.NativeEngine
long[] trafficStats();             // [upload, download], payload bytes
int delayTest(String name, String url, int timeoutMs);
byte[] connectionsSnapshot();      // owned UTF-8 JSON array
```

These methods require a successfully started, still-running session. Nil/zero,
unknown/stale JNI handles, failed-start cleanup handles, Stop admission and
unexpected TUN exit all reject management calls with Go `ErrNotRunning` / Java
`IllegalStateException`. Input null/NUL/oversize Java arguments can instead throw
`IllegalArgumentException`. No empty/zero success disguises an inactive session.
Stop remains idempotent; it does not authorize another Start in the same process.
The foundation registry's **permanent process retirement before parsing** still
allows the one current lease during execution; it is not management retirement.

## Traffic accounting source and polling cost

Each engine constructs its own **zero-valued upstream `statistic.Manager`**.
The pinned `xsync.Map` and upstream atomic wrappers explicitly support zero-value
initialization. Before parsing, `tunnel.ProximaBindStatistics` binds that manager
exactly once. Checksum-gated replacements of the two tunnel and three DNS tracker
construction sites route actual upstream trackers to that manager. A concurrent
atomic pointer publishes this once-only routing dependency; **neither the global
`statistic.DefaultManager` pointer nor its counters are reset/replaced/read** by
the management API. A detached old manager can never become a replacement
session's totals. The process still must exit before any replacement session.

Actual source path in v1.19.33:

* `tunnel/tunnel.go` → `statistic.NewTCPTracker` / `NewUDPTracker`.
* `tunnel/statistic/tracker.go`: Read/Write, ReadBuffer/WriteBuffer,
  UnwrapReader/UnwrapWriter counting callbacks, UDP ReadFrom/WaitReadFrom/WriteTo
  → owning manager's `PushUploaded` / `PushDownloaded`.
* `tunnel/statistic/manager.go`: `uploadTotal.Add` / `downloadTotal.Add` and
  `Total()` → two `common/atomic.Int64.Load` (`sync/atomic.Int64`) operations.

Totals count routed user payload, including tracker-accounted TCP peek bytes,
not IP/TLS/proxy framing, provider downloads, delay probes, or direct resolver
traffic. DNS trackers retain upstream `pushToManager=false` (they can still
appear in snapshots). Totals persist after individual connections leave. A
fresh manager starts at zero; retired sessions return an error, not old totals.
The session manager runs **no rate ticker/memory sampler**. A stats call has a
short admission mutex/WaitGroup pair and two atomic loads: O(1), no enumeration,
HTTP, socket, JNI callback or Go heap allocation. One-second app polling is
appropriate. The pair is not a transactional cross-counter snapshot.

## Delay tests and concurrency

`name` must be a key in the session's top-level proxy/group map, including built-in
`DIRECT`; provider-only nodes are selected through an admitted group. This is
the selected proxy's native `adapter.Proxy.URLTest`, **not** an ad-hoc SOCKS
inbound or a request routed through MATCH rules. It sends HTTPS HEAD, preserves
normal certificate verification, never follows redirects (including downgrade),
and returns upstream's integer millisecond delay (minimum 1). As upstream does,
any received HTTP status, including a redirect, is a completed probe; this is
not a configurable expected-status/content/connectivity assertion.

The foundation's `providerpolicy.URL` is reused before networking: HTTPS,
nonempty host, no userinfo/opaque URL. Name/URL are limited to 8192 UTF-8 bytes;
timeout is 1..60000 ms, including dialing/TLS/request. Upstream's HTTP client
also retains its own 30-second request cap (a larger caller timeout does not
extend that cap). Local/private addresses remain allowed: this is not an SSRF
sandbox. DNS uses the admitted resolver.
All actual outer sockets still traverse the session's permanent protected dialer;
a false protection callback fails the probe rather than falling back.

Concurrent calls, **including the same name**, are allowed without a global
probe queue. Each wraps the selected `ProxyAdapter` in a private upstream Proxy
for URLTest, isolating its mutable history from simultaneous calls/periodic
health checks. The tested adapter/group itself is shared and retains ordinary
upstream concurrent dial behavior. Probe histories are discarded; arbitrary
URLs cannot grow `extra` histories on the session's persistent Proxy. This API
does not trigger a provider/group-wide health check or manually change group
selection. Java encodes normal UTF-8, not JNI Modified UTF-8, so emoji names work.

## Snapshots, bounds and ownership

The result is a JSON array of objects:

```json
[{"id":"UUID","host":"example.com","network":"tcp","chains":["node","group"],"rule":"Domain","rulePayload":"example.com","upload":42,"download":84,"start":"2026-11-13T00:00:00Z"}]
```

These are immutable projections of upstream `TrackerInfo` from the session
manager's concurrent `Range`, not log parsing or copies of atomic structs.
`host` may be empty for IP-only flows. `start` uses RFC3339Nano. Connection
churn can add/remove rows during enumeration; individual byte loads are atomic,
but rows/traffic totals are not a single instant-in-time transaction. Ordering
is unspecified. No upstream `Manager.Snapshot()` call reads its unrelated
non-atomic `memory` field or allocates an unbounded full connection slice.

One encoder per session emits at most **10000 connections / 8 MiB**; exceeding
either returns `ErrSnapshotTooLarge` / `IllegalStateException`, never a silently
truncated list. Individual textual fields together and chain names together are
bounded at 64 KiB each, chain depth at 256, before per-record JSON encoding.
The byte-buffer allocation is bounded (Go buffer growth may reserve up to the
next capacity), not proportional to all live connections. Waiting encoders
observe retirement and exit. Callers should avoid unbounded concurrent polling
or retaining unlimited returned arrays, as with any owned-buffer API.

JNI follows the existing byte-buffer pattern: Go serialization → temporary
`C.CBytes` → Java `NewByteArray`/`SetByteArrayRegion`, then C storage freed even
on a Java allocation/copy exception. No Go pointer crosses JNI or outlives a
call, no per-row Java objects/local references, no `NewStringUTF` size/encoding
hazard, and returned arrays remain valid after Stop.

## Admission, Stop and scope

All three calls acquire the same management admission mutex as retirement and
increment an owned WaitGroup under it. Stop closes admission and cancels the
management context immediately; unexpected input exit does the same. Admitted
getters can finish while Stop starts; later calls fail. An already admitted
snapshot may instead fail `ErrNotRunning` as cancellation is observed. Delay
tests receive cancellation. Shutdown joins all admitted calls **before** packet,
DNS, provider/proxy and lease/callback teardown. Java management calls deliberately
do not hold the synchronized lifecycle monitor over a network request; a volatile
handle plus native lookup retains the old Go session safely while Stop removes
the handle. Retired pointers cannot target a new lease.

No Reload, external-controller, HTTP management listener, app/service integration
or Android connected-state publication is added. The earlier audited protocol
subset, callback non-reentrancy and single-process/one-core fence remain in force.
Cancellation/join owns the API calls, not a proof of synchronous exit of every
transport library actor. Terminate/reap the worker remains the final fence;
host tests/cross-compilation do not establish Android device behavior.
