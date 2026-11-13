# Mihomo engine adapter and configuration building blocks

This module now contains the standalone Phase 1.2 Go/JNI Start/Stop/Version
adapter. **Read [ENGINE.md](ENGINE.md) for its executable capability subset,
descriptor ownership, one-session process boundary and verification.** It is not
integrated into the Android application and never publishes connected state.

The independent snapshot/provider-stage APIs documented below are still only
building blocks. A successful raw decode is **syntactic/typed decoding with
upstream defaults**, not semantic validation or a started engine.

## Exact supported operations

`Decode(ctx, effectiveYAML, expectedRevision)` copies the exact already-effective
plaintext YAML, verifies its SHA-256 revision, rejects empty/non-mapping/multiple
documents, and calls the actual `config.UnmarshalRawConfig` from Mihomo v1.19.33.
It preserves comments, unknown fields, anchors, spelling, and bytes in `Bytes()`.
`Raw(ctx)` returns a fresh decoded object, so mutating it cannot change the stored
configuration. No YAML rewriting, proxy filtering, option substitution, provider
creation, network fetch, geodata load, listener creation, or executor application
occurs. Unknown fields remain in the source but are not validated by this API.
Age-encrypted input is unsupported here: decrypt before supplying effective YAML.

Raw decoding can reject malformed YAML and invalid strongly typed fields such as
mode and port; it cannot reject every invalid proxy, rule, DNS server, provider,
or listener configuration. The tests intentionally decode unavailable geodata,
provider paths and URLs without initializing them. **Do not advertise this as a
working configuration or as a replacement for `config.Parse`.**

`NewProviderStage(revision, parsedConfig)` copies the provider map entries from an
already semantically parsed configuration. The caller must bind that configuration
to the supplied revision; this function cannot prove that association.
`Initialize(ctx, expectedRevision)` admits one attempt, processes proxy providers
then rule providers in stable name order, and calls each admitted provider's real
`Initial()` exactly once. It returns the original first error wrapped with the
provider kind/name; `errors.Is` and `errors.As` remain usable. Providers after a
failure are not attempted. A stale revision or pre-cancelled context performs no
initialization. Concurrent/repeated calls cannot initialize providers twice.

A nil `Initialize` result proves only that those provider `Initial()` calls
returned nil. It does not mean their remote endpoints are reachable, their
refresh/health workers are healthy, routing is applied, DNS works, listeners
started, or the VPN is connected. Upstream provider behavior such as using an
available cached payload is preserved, not treated as a new network success.

Each provider has its own admission point: observing a nil stage-context error
while holding the mutex shared with `Stop`. Stop closes admission by setting
the stopped state under that same mutex. If Stop wins, the next provider cannot
be admitted. If admission wins, that already-admitted call may enter `Initial`
after Stop begins; Stop waits for it and the initialization attempt to return.
Parent cancellation observed at admission rejects that call. Cancellation racing
after the nil observation cannot revoke the admitted call; its result is checked
again for cancellation, so a cancelled completion does not report success.

`Stop()` permanently prevents further admission, cancels the stage, and drains
the admitted `Initial()`. Upstream `Initial()` has no context parameter: a blocked call
cannot be interrupted by this wrapper. Stop does not close providers, join their
refresh/health workers, stop a core, release a lease, or claim full shutdown.
The owner must terminate and reap a stuck session process. No detached initializer
goroutine, synthetic timeout success, retry, or in-process session replacement is
used. On a failed attempt the owner still owns every constructed provider,
including the failing one; close them under their real teardown contracts or
reap the process before revoking the filesystem/socket capabilities.

## Full-profile integration requirements (outside Start's admitted subset)

Use a **fresh operating-system worker process per session**. The engine module
does not create/supervise that process or pass the TUN fd across IPC. The
supervisor must observe process exit before installing a replacement session.
Never call semantic validation against the singleton running a live session.
Run raw decoding in that isolated process too: upstream defaults read process
globals, and the snapshot API does not freeze or reset those globals.

Before `config.Parse`, provider factories, or provider initialization:

1. Establish an app-owned private directory independently of YAML.
2. Configure `mihomo-provider/boundary.ConfigureRoot(root)`, then
   `constant.SetHomeDir(root)` and an app-selected config path. Do not call
   `config.Init`, which creates a default configuration.
3. Install the permanent fail-closed socket boundary and prepare its active
   protection lease. This module imports `proxima.local/mihomo` to install the
   fail-closed hook, but does not prepare a lease or claim Android protection.
4. Compose all reviewed filesystem/URL/network overlays against the same verified
   staged module. Keep their capabilities alive through worker exit.
5. Provide real context/routing dependencies for providers using `proxy` or
   `dialer-proxy` and for health checks. This module does not install those routes.
   Rule-provider factories also require the real tunnel update callback
   registration normally performed by `config.parseRuleProviders`; the test
   harness registers `ruleprovider.SetTunnel(tunnel.Tunnel)` explicitly because
   it exercises factories without semantic parsing.

Full semantic parsing remains deliberately unimplemented here:
`config.ParseRawConfig` temporarily changes general globals and can load/download
geodata while constructing rules/DNS. The provider overlay confines provider
files, cache operations and bundle archives; it does **not** by itself establish
complete filesystem/URL policy for all geodata, certificate, protocol asset,
external UI, resolver, or listener paths. A general parser wrapper would cross
those unproven paths before executor startup. This module does not silently
disable those options or pass them to unsafe initialization.

The upstream void `ApplyConfig` logs failures and continues to `OnRunning`, while
`Shutdown` does not join all global workers. The new adapter does not call that
void API: a separately named, checksum-gated error path reuses only admitted
helpers and returns actual raw-TUN startup errors. Extending it to full profiles
still needs error propagation/rollback for every additional listener, DNS, NTP,
controller and update path, plus a supervised process lifetime.

Unsupported full-profile paths include arbitrary proxy/group/provider execution,
geodata, advanced DNS policies/fake-IP, additional listeners/controllers/NTP/updaters, Android
worker/IPC supervision and device/live external verification. Snapshot decoding
retains these raw fields; executable Start rejects them explicitly rather than
running unproven initialization paths. Raw TUN startup and JNI are now implemented
for the bounded subset in ENGINE.md.

Packet/DNS integration now includes `native/mihomo-dns`, rather than forwarding
the Android synthetic DNS address as ordinary upstream traffic. Its
actual resolver relay contract requires configured `resolver.DefaultService`,
explicit interception destinations, stopped TUN admission, DNS `Stop`,
interrupted packet transport, joined worker dispatchers, then DNS `Wait`.
Resolver refresh/exchange workers still require process termination and reaping.
See that component's README for packet-buffer ownership and writer interruption;
the engine's raw-TUN host tests validate that path. See [DNS.md](DNS.md) for
admission, defaults, upstream policy, scoped sockets and remaining device gaps.

## Source pin and overlay composition

Mihomo v1.19.33, commit
`3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8`, module sum
`h1:hwqYMItk3Jaeq8Sw2PBAtyHQh157ccUtWS7rXrBOMCU=`, Go 1.27.1.
The dependency graph is pinned in `go.mod`/`go.sum`, including the upstream
protobuf replacement. Local dependencies are `../mihomo` for the permanent
socket hook, `../mihomo-provider` for its path capability, and `../mihomo-runtime`
for joined packet ownership and `../mihomo-dns` for DNS relay ownership.
The build reuses the provider/network/packet overlay
generators without modifying their own generated outputs or module caches.

`build.sh` verifies downloaded modules, copies the core to one fresh staged
directory under this module's ignored `build/`, and gives that identical path to
both overlay generators. Their original source checksums are verified before
composition. `cmd/compose` additionally pins `config/config.go` and
`hub/executor/executor.go`, rejects duplicate mappings even when their replacement
is identical, rejects duplicate JSON keys inside each input before map insertion
(including escaped equivalent keys and repeated `Replace` members), rejects keys
targeting a different staged module, and rejects
missing/non-file/deletion replacements. It never resolves a conflict by choosing
whichever overlay came last. Each input must contain exactly one `Replace` object
whose values are strings. A combined `build/engine.mod` and
`build/overlay.json` are required; direct `go test` without provider overlays will
fail the safety regression test.

This module makes no independent claim that another component's overlay review
has passed. Do not deploy or integrate a combined build while any prerequisite
review remains blocked.

```sh
bash build.sh test   # source verification, vet, actual-core race tests
bash build.sh cross  # Android arm64 package compilation only
bash build.sh android # four-ABI c-shared engine libraries, 16 KiB alignment
```

TLS certificate verification remains enabled. `SSL_CERT_FILE` defaults to
`/etc/ssl/cert.pem`. Generated caches remain beneath `build/` unless the caller
explicitly supplies `GOMODCACHE`/`GOCACHE`.

Building-block tests use actual provider parsers, file payloads and errors. Their
timing wrapper verifies admission, not provider shutdown. Separate isolated core
tests now prepare real leases, instantiate sing_tun.New/mipstack and exercise raw
IPv4/UDP against a local host-interface sink, without a privileged TUN or external
server. Real JVM JNI tests cover error propagation and descriptor ownership.
