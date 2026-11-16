# Native Mihomo DNS interception seam

This independent Go module implements selected UDP and TCP DNS interception
using Mihomo v1.19.33. Phase 1.2 now wires it into the standalone engine through
`mihomo-runtime.Options.DNSHijack`, not the Android application. Passing its tests
does not establish VPN connectivity or complete
the Mihomo migration.

The production code calls `resolver.RelayDnsPacket` and `resolver.RelayDnsConn`,
which invoke the core's configured `resolver.DefaultService`. It does not
substitute `DefaultResolver.ExchangeContext`, a public DNS server, system DNS,
or fabricated records for that service. Native hosts handling, fake-IP and its
reverse mapping, nameserver policies, routing choices, caching, EDNS and SERVFAIL
remain in the core. TCP retains its length framing, full responses and multiple
queries per connection.

The UDP wire limit is the smaller of the client's advertised payload size and
2,048 bytes, with a 512-byte minimum as required for EDNS and a 512-byte limit
when EDNS is absent. Native truncation can retain an OPT record that exceeds
this budget. Only when the encoded native reply exceeds the limit, the adapter
re-encodes it with TC set, its native header and question, and a minimal OPT
retaining EDNS flags, version and extended RCODE. Answer records and option data
are omitted so the client can retry over the unchanged native TCP relay.
It never clips DNS wire bytes or transmits the oversized retained option.

No function changes a resolver global, nameserver, enhanced mode, route, socket
hook, or Android setting. `New` requires a configured `DefaultService` and an
installed `dialer.DefaultSocketHook`. The host must supply the actual protected
hook and keep it active; its mere presence cannot prove Android socket
protection. All upstream sockets remain the native resolver's responsibility.

## Integration API

The import is `proxima.local/mihomo-dns`, package name `mihomodns`.

```go
func New(targets []netip.AddrPort) (*Session, error)
func NewHijack(targets []netip.AddrPort) (*Session, error)
func (*Session) Matches(destination netip.AddrPort) bool
func (*Session) HandleTCP(ctx context.Context, conn net.Conn, destination netip.AddrPort) (bool, error)
func (*Session) HandleUDP(ctx context.Context, request *buf.Buffer, destination metadata.Socksaddr, writer network.PacketWriter) (bool, error)
func (*Session) Stop()
func (*Session) Wait()
```

The worker must configure native Mihomo DNS and protection first, then construct
one session with the explicitly approved destinations. For the existing Android
DNS address, the caller can explicitly select `172.19.0.2:53`. The module has no
default destination, wildcard, or silently expanded port-53 route. An empty,
invalid, unspecified-address or zero-port selection is rejected.

`NewHijack` is the explicit engine variant: it also accepts unspecified-address
**port 53 only**, matching pinned sing_tun wildcard semantics for UDP and TCP.
It has no implicit targets; `New` keeps its original concrete-address contract.
The engine supplies the app's synthetic address and validates profile targets.

In the TUN TCP callback, call `HandleTCP` before the ordinary sing handler. A
`false` result leaves the stream untouched for normal routing. A `true` result
always transfers stream ownership, including on shutdown rejection.

In the TUN UDP callback, use `Matches(metadata.Destination.AddrPort())` before
calling `init(nil)` to obtain the detached reply writer. For selected DNS,
transfer the input buffer and writer to `HandleUDP`; dispatch it in a
worker-owned, joined goroutine if the stack callback must return promptly.
Both methods are synchronous. The module does not start detached relay workers.
A `false` result leaves the input buffer and writer untouched. A `true` result
consumes the input buffer on every outcome. The reply uses the intercepted
destination as its source address and preserves writer headroom.

The packet writer must synchronously finish using the reply buffer before
returning. Successful writes consume it. On error the handler releases it as
the native sing_tun relay does; the pinned sing buffer also supports a writer
that already released the buffer on error. In particular, the pinned
`mipsUDPWriter` releases on every outcome, and its detached responder copies
payload before returning.

## Teardown and process ownership

1. Stop TUN callback admission and call DNS `Stop`. It rejects new selected DNS
   calls, cancels active resolver calls and closes active TCP streams through
   their cancellation callbacks. Matching remains stable after stop so a late
   selected packet never falls through into ordinary routing.
2. Interrupt the packet transport and close the stack before waiting for any
   dispatcher that may be inside a packet write. A generic sing `PacketWriter`
   has no `Close` or context method. Its owner must supply this interruption
   guarantee; otherwise a blocked writer can prevent drain indefinitely. The
   pinned MIPStack responder makes an immediate best-effort output attempt and
   rejects later replies after its forwarder closes.
3. Join the TUN loops and all worker-owned callback/relay dispatch goroutines,
   then call DNS `Wait`. It joins all admitted handlers, active packet writes,
   and TCP cancellation callbacks. A write already entering concurrently with
   `Stop` may finish before `Wait`; none survives a successful drain. Calls that
   resolve after cancellation do not emit a UDP SERVFAIL merely because native
   relay cancellation produced one.
4. Terminate and reap the worker process before treating the native session as
   fully stopped or installing another session's globals.

The last step is mandatory. The pinned `dns/resolver.go` starts singleflight
queries with `context.Background`, refreshes stale/canceled queries in the
background and schedules retries. `dns/client.go` also owns exchange
goroutines. There is no exported join API for these workers. DNS `Wait` must not
be advertised as stopping the entire core. The process-per-session worker owns
those lifetimes. This module neither launches nor terminates that process.

`Wait` has no timeout that can falsely certify shutdown. The worker supervisor
may impose a bounded process-stop deadline and terminate/reap the process when
it expires. Runtime integration must verify the concrete writer and dispatcher
teardown order before promising bounded graceful shutdown.

## Verification

Run `bash native/mihomo-dns/build.sh` from the repository root. It checks the
pinned Go toolchain, verifies dependency checksums, runs `go vet`, and runs the
tests with the race detector, shuffled order and a 90-second outer bound.

The tests use the actual core DNS resolver/service and loopback UDP/TCP
authoritative sinks. The installed socket hook rejects every destination except
the test sink and counts the native socket path. Other tests exercise the real
native fake-IP pool without any upstream. Event channels and a `testing/synctest`
scheduler barrier coordinate cancellation and blocked writers; there are no
time-based sleeps. The pending upstream test runs a real resolver in a bounded
child test process. It proves relay drain while the local upstream remains
blocked, then exits and is reaped by the parent. This avoids replacing global
state while native refresh/retry workers can still use it, and exercises the
required process ownership boundary.

Managed-buffer tests wrap the real sing allocator and count allocations and
returns. They check cancellation during resolution, rejection before admission,
and writer errors both when the writer releases its buffer and when it leaves
release to the caller, including the oversized EDNS truncation path. A duplicate
return to the allocator fails immediately. The request is released before the
session decrements its drain counter. The oversized-OPT regression checks
512/1232-byte client limits, the 512-byte EDNS minimum and the 2,048-byte cap,
then retries each query through native TCP and receives the complete answer and
option data.

These tests cover the isolated DNS surface. They do not exercise a real Android
VPN, the TUN-to-DNS wiring, the production protected-socket hook, or supervisor
process termination. Core-global workers also prevent an honest whole-process
goroutine-leak claim from this in-process component suite.
