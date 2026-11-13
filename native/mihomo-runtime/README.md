# Mihomo packet-stack startup component

This is an independently built **mips-only TCP/UDP packet component**, not a
complete Mihomo runtime or an Android VPN. It does not replace the app's engine,
parse/apply configuration, initialize providers, initialize a DNS resolver, or
report connected. It is used by the standalone engine/JNI adapter, not wired into
Dart, Gradle, or Android services.
Other stack selections, including an unspecified stack, fail explicitly.

The production path calls the actual pinned Mihomo
`listener/sing.NewListenerHandler` and sing-tun `NewStack("mips")` and `Start`.
Packets become real Mihomo `constant.Metadata` and `constant.UDPPacket` values.
There is no fake successful executor, constructor, packet parser, or network
transport. The caller supplies the already-configured `constant.Tunnel` boundary.
The packet component cannot prove the safety or completeness of that tunnel.

## Why this seam

Mihomo v1.19.33 `listener/listener.go:498` has a void `ReCreateTun` that logs
constructor errors. `hub/executor/executor.go:84` has a void `ApplyConfig` that
eventually calls `tunnel.OnRunning` even when listener/provider startup failed.
`loadProvider` at line 318 logs initialization failures, while `Shutdown` at
line 532 does not join providers or other global workers.

Calling `listener/sing_tun.New` directly would propagate an error, but its
`server.go` assigns `l.tunStack` only after `tunStack.Start`. A failed Start can
therefore bypass closing the newly constructed stack. Descriptor adoption also
differs between sing-tun platform constructors: Linux adopts a nonzero fd,
while Darwin may fail before adoption or close it during a later DNS failure.
A generic unconditional close after constructor failure could double-close a
reused descriptor. This component avoids that ambiguous transfer entirely.

It owns an `os.File` for a duplicate and passes it as sing-tun's raw `Tun`
read/write interface. Android VpnService TUN packets have the required unframed
IP representation. Darwin utun framing, Linux VNET/GSO headers, and arbitrary
files are not supported by this raw packet interface.

## Descriptor and stop contract

`OpenBorrowed(fd, Options{Stack: "mips", MTU: ...}, tunnel)`:

1. Requires an already-established, nonblocking, pollable raw-IP packet fd.
   The caller keeps it stable until OpenBorrowed returns. This component does
   not determine whether an arbitrary pollable descriptor is an Android TUN.
2. Uses `F_DUPFD_CLOEXEC`, requesting a descriptor at least 3. Borrowed fd 0 is
   supported without invoking upstream's fd-zero "create device" convention.
3. Never changes `O_NONBLOCK`, which would also change the caller's open-file
   description. All aliases must preserve this flag for the session's lifetime.
   Blocking descriptors, non-character/non-socket file types, and unpollable
   descriptors fail explicitly. Pollability alone is insufficient: Darwin's
   kqueue can accept a regular file.
4. Acquires the real handler and stack, owns the stack before calling Start,
   and closes every locally acquired resource on any startup error. Error
   context distinguishes duplication, handler, constructor, and Start failure.
5. Returns a session only after actual stack Start succeeds. This proves local
   initialization only. There is deliberately no `running` or `connected` flag.

`Session.Close` serializes concurrent callers and saves the first close result.
It closes admission into the supplied tunnel, closes admitted TCP connections,
cancels the handler context, closes its duplicate to interrupt packet I/O,
closes the real stack, joins its two packet loops, and drains admitted handler
calls. Repeating Close never closes a subsequently reused fd number. A supplied
TCP handler must obey Mihomo's blocking-until-unused contract and unblock when
its connection is closed. Close cannot be called synchronously from an admitted
handler. There is no timeout that returns a false completed shutdown.

The raw packet read loop treats every surfaced read error as terminal instead of
immediately retrying persistent failures such as EIO. It preserves the error,
logs a non-closure error once, and exits. Go's pollable `os.File` handles ordinary
nonblocking waits; this component does not guess which remaining device errors
are recoverable or add a retry loop.

The owner must subscribe to `Session.ReadDone()`. That channel closes when the
input loop exits; `Session.ReadError()` then reports the original read cause.
Before termination ReadError returns nil. Normal Close can produce an error
wrapping `os.ErrClosed`. An unexpected input exit must trigger owner-initiated
Close and the surrounding runtime shutdown. **ReadDone is not a complete-stop
event:** it does not close the write side, drain handlers, stop external workers,
or release the lease. Close continues to report teardown errors separately.
There is no automatic restart or new connected-state flag.

This is **not a join of the entire core**. Pinned mipstack `Stack.Close` expressly
does not wait for all socket actors/user forwarder workers. Admission gating
prevents a delayed handler from delivering new work through this component after
Close. Existing UDP packets and work retained/spawned by the supplied tunnel
remain that tunnel's responsibility. ICMP is explicitly dropped; this component
does not open a raw ICMP socket or manufacture successful pings. DNS packets are
ordinary UDP/TCP by default; no global DNS hijacking is installed. An owner may
explicitly supply `Options.DNSHijack` after configuring real protected native DNS.
The runtime then owns a `mihomo-dns.NewHijack` seam: UDP dispatchers are joined,
TCP is synchronous, Stop cancels DNS before interrupting packet writers, and
Close drains every dispatcher/relay. Empty options retain ordinary packet behavior.

## DNS integration ownership

Phase 1.2 of `../mihomo-engine` now initializes native DNS and supplies targets
through the raw `sing_tun.New` path. It scopes/closes DNS sockets before releasing
the lease, but still requires process exit for unexported resolver workers. The
runtime never configures those globals itself. The original constraints below
explain why an ordinary tunnel alone remains insufficient.

The current Android service advertises `172.19.0.2` as VPN DNS
(`ProximaVpnService.kt:120`, `XrayConfig.kt:19`) and forces its /32 route into
the TUN. That address is synthetic. Passing its port 53 packets to an ordinary
tunnel is not a working replacement for the current Xray DNS interception.
**This component cannot replace that service's engine yet.**

Pinned Mihomo `listener/sing_tun/dns.go` intercepts TCP/UDP and calls
`resolver.RelayDnsConn`/`RelayDnsPacket`. Its UDP path starts untracked goroutines.
The relay then calls process-global `resolver.DefaultService`; without a real
initialized service it returns DNS SERVFAIL. Merely swapping the handler class
would therefore add neither proven DNS functionality nor joined shutdown.
`resolver.ResetConnection` itself launches asynchronous resets and is not a join.
The executor's Shutdown does not resolve this ownership problem.

Required integration contract: initialize a real protected DNS service before
packet admission, scope resolver access to that session instead of replacing a
global while requests are in flight, intercept both TCP and UDP port 53 at the
advertised address, track/cancel/drain every relay request, close admitted TCP
connections, and stop/join resolver transports and refresh workers before the
socket-protection lease can change. This requires the configuration/networking
owner and a lifecycle-capable resolver API; `resolver.Service` currently exposes
only `ServeMsg`. No synthetic DNS reply implementation is included here.

The independently owned `native/mihomo-dns/` work can integrate through the
existing `constant.Tunnel` argument: a DNS-aware tunnel wrapper receives actual
Mihomo TCP connections and UDP packets with destination metadata, intercepts the
synthetic address, and delegates other traffic to its downstream tunnel.
Its UDP worker must retain/drop packets correctly and expose its own stop/join
operation. This component's Close drains delivery into that wrapper; it cannot
join work the wrapper retains after HandleUDPPacket returns. The integration
owner must then stop/join DNS before releasing the protected lease.
The optional `Options.DNSHijack` path now imports the seam and implements this
callback/dispatcher ordering; omitted options do not install it.

For the planned process-per-session architecture, this component and the
foundation lease must run in the same child process. Transfer the TUN through
an actual descriptor-passing mechanism, not a numeric fd in an ordinary IPC
message. Process exit can provide the final boundary for unjoined global core
workers; a future supervisor must observe that exit before replacing the
session. This packet component does not create or supervise that process.

## Foundation ownership handoff

For a future adapter using `native/mihomo/NativeSession`:

1. Prepare the protected session lease.
2. Call `duplicateTun()` to get a caller-owned transfer fd.
3. Borrow that transfer fd into OpenBorrowed. Close the transfer fd on both
   success and failure, after OpenBorrowed returns; the component has made its
   own duplicate if it succeeded. Never transfer a numeric fd across processes.
4. Keep the lease/protector alive through component Close and through a separately
   proven stop/join of all caller-owned providers, resolvers, health checks,
   existing connections and other core workers.
5. Only then release the foundation lease or prepare a replacement. This
   component alone does not authorize lease replacement: old external workers
   could otherwise reach the new process-wide socket hook.

Do not install another process-wide dialer hook here. Arbitrary provider
support remains blocked until provider fetches and redirects use protected,
certificate-verified networking, and actual file I/O/cache replacement/watchers/
extraction use the foundation's confined path policy. A parser/preflight check
does not satisfy those requirements.

## Exact source and overlay

- Mihomo: v1.19.33, commit
  `3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8`,
  module sum `h1:hwqYMItk3Jaeq8Sw2PBAtyHQh157ccUtWS7rXrBOMCU=`.
- sing-tun: v0.4.28, with its module content pinned in `go.sum`.
- mipstack: `v0.0.0-20261019124225-9a80a07eaeb9`, as selected by the pinned
  Mihomo/sing-tun graph. The protobuf replacement is carried explicitly.
- Go: 1.27.1 for reproducible local checks. No protocol-removal build tags.

`cmd/overlay` is the complete source-level patch and generation tool. It accepts
only sing-tun's original `stack_mipstack.go` SHA-256:

```text
0bc87ae1a2cf43abbb71353d10ea356a433c65cbd807b065863a54aa6c146267
```

The patch adds a WaitGroup covering the existing readLoop/writeLoop goroutines,
`WaitPacketLoops()`, a read-completion channel, and a published raw read error.
It changes the generic raw read loop to return after any read error. Specialized
Windows/Linux batch/Darwin batch loops are not covered by this policy and are
not used by this component's `os.File` path. The owner must close the packet
device and stack before waiting. No protocol choice or Close ownership changes.
Go 1.27 forbids overlaying files beneath GOMODCACHE. The generator therefore
copies the checksum-verified sing-tun module into `build/overlay/sing-tun`,
creates a generated `runtime.mod` pointing at that copy, and uses Go's `-overlay`
mapping for its modified file. Both the generated modfile and overlay are
required. It does not alter either the Go module cache or `native/mihomo/`.
An unpatched build fails to compile because `WaitPacketLoops` is required.
Module checksum verification runs before overlay generation, and every text
anchor must match exactly once. A source checksum mismatch is a hard failure.
The generated file contains modified upstream source, so distribution must
respect Mihomo's GPL-3.0 and all linked dependency licenses.

## Host verification

```sh
bash build.sh test
```

The script verifies downloaded modules, generates the checksum-gated overlay,
runs `go vet`, and runs actual-core tests with the race detector and shuffled
order. Module/build caches and generated sources stay in this folder's ignored
`build/`. TLS verification remains enabled; the default system CA bundle is
`/etc/ssl/cert.pem`, overridable with `SSL_CERT_FILE`.

Tests use local datagram socket pairs carrying real IPv4/UDP packets; they need
no TUN, credentials, internet destination, or privileged device. They cover
actual packet metadata and replies, actual constructor/Start failures and fd
rollback, unsupported stack rejection, invalid/blocking/unpollable descriptors,
fd 0 in an isolated subprocess, close-on-exec, concurrent/idempotent stop,
descriptor reuse, and admitted/late handler behavior. Separate event-driven
tests inject a persistent EIO into the real stack and hold a real UDP callback
while Close interrupts descriptor I/O and the callback attempts WriteBack.
They use channel events with bounded failure deadlines, not sleeps.

Android compilation, Android loading, real TUN traffic, packet loss behavior,
all protocol implementations, full DNS/routing/configuration, provider policy,
and joined full-core shutdown are not verified by these host checks.
