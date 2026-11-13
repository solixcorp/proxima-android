# Phase 1.4 executable engine contract

DNS admission, defaults, upstream security and lifetime: see [DNS.md](DNS.md).
Provider admission, trusted root, update errors and joined ownership:
see [PROVIDERS.md](PROVIDERS.md).
Protocol socket evidence, option limits, rejected transports and overlays:
see [DIALERS.md](DIALERS.md).

## Public API

```go
func Start(configBytes []byte, borrowedTunFd int, protector session.Protector) (*Session, error)
func StartWithOptions(configBytes []byte, borrowedTunFd int, protector session.Protector, options Options) (*Session, error)
type Options struct { ProviderRoot string }
func (*Session) Stop() error
func (*Session) Done() <-chan struct{}
func (*Session) Wait() error
func (*Session) ProviderErrors() map[string]error
func Version() string
```

Java: `kr.kimrasng.proxima.mihomo.NativeEngine`, with the separate
`proxima_mihomo_engine` library. Construct an object, call its `start(byte[], fd,
Protector)`, then `stop()`/`close()`. Keep the object if start/stop throws: native
code retains a cleanup handle when attached-thread callback release needs retry.
Do not load this together with the foundation/diagnostic Go shared libraries:
separately linked Go runtimes have independent session registries.

Start takes ownership of the Go protector even on failure. A non-nil Session
with a non-nil error means cleanup needs retry through that Session's Stop. The
borrowed original fd always remains the caller's. It must already be
nonblocking, pollable and carry complete unframed raw IP. The adapter does not
establish VpnService, change flags shared by aliases or certify that an arbitrary
socket/character device is an Android TUN. fd 0 remains valid.

## Explicit initial capability subset

```yaml
find-process-mode: off
profile: {store-selected: false}
tun:
  enable: true
  stack: mips
  mtu: 1500
  auto-route: false
  auto-detect-interface: false
  dns-hijack: []
  inet6-address: []
rules: ['MATCH,DIRECT']
```

Mode, IPv6 and log level are also configurable. Rules additionally support
DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, DOMAIN-REGEX, DOMAIN-WILDCARD and RULE-SET
(declared domain/ipcidr providers, including MRS), alongside MATCH, IP-CIDR,
IP-CIDR6, SRC-IP-CIDR, DST-PORT, SRC-PORT and NETWORK. Native semantic validation
and actual proxy/group or built-in DIRECT/REJECT targets are retained.
Imported fd numbers, unaudited proxy/group types/options, geodata, custom hosts,
advanced DNS policies, persistence,
extra listeners/controllers, NTP, updater and platform routing options fail
explicitly **before semantic parsing**. Unknown top-level fields are rejected,
not silently ignored. Snapshot Decode still preserves arbitrary raw YAML.

Top-level proxies and provider payloads now share an audited option-limited
policy: direct, reject, http, socks5, ss, ssr, vmess, vless (including REALITY),
trojan, snell (no reuse/v2), hysteria (UDP), hysteria2, tuic, wireguard (single
endpoint/mips), ssh (host-key pins), anytls and mieru. Groups admit select,
url-test, fallback and load-balance with explicit proxies/use references and
HTTPS health URLs. See DIALERS.md and protocol_admission.go for exact limits;
this is not arbitrary profile support. Inert upstream batch/gvisor defaults are accepted but never applied to
the raw os.File mips path; non-default requests are rejected. Redir-host DNS now
works through the synthetic address in the host gate. This is still not an
integrated replacement for the existing Android engine/service.

## State machine and descriptor ownership

1. Serialize Start; prepare the foundation lease using F_DUPFD_CLOEXEC; obtain
   a separate adapter-owned DuplicateTun transfer descriptor.
2. Decode exact YAML and admit capabilities. Failures up to here close owned
   duplicates and the protector and leave the process reusable.
3. Permanently retire the process's foundation registry **before** semantic
   parsing. Once core globals may have been used, both successful and failed
   attempts require worker-process termination/reaping before another session.
   This also fences direct foundation Prepare callers, not just engine Start.
4. Parse with rollback; apply actual routing/general/hosts/sniffer/provider
   helpers plus real DNS initialization; error-returning listener startup calls
   the actual `sing_tun.New`.
   Its non-YAML app capability selects `mihomo-runtime.OpenBorrowed`, which owns
   another duplicate and starts the real sing-tun stack. No transfer is passed
   into ambiguous platform tun.New adoption. OnRunning is reached only after
   successful TUN startup; this core status is never Android connected state.
5. On failure or Stop, close/join the packet stack, close the adapter transfer,
   suspend routing, drain scoped UDP initialization/pumps, close DNS socket
   admission/transports and real providers/proxies, clear routing maps, then
   release the foundation lease and callback. The transfer stays open until
   after TUN shutdown, even on startup
   errors. The foundation never closes a transferred descriptor.
6. An unexpected packet input exit automatically triggers local shutdown.
   Done/Wait expose its cause. Stop must still release JNI resources from an
   attached JVM thread. Stop is serialized/idempotent and retains an inactive
   lease when callback release fails. No timeout falsely certifies completion.

The raw tunnel avoids upstream's unjoined global UDP queues. Source-gated
instrumentation separately joins UDP initialization and sender/reply pumps,
closes real tracked connections, and joins the TCP peek helper. This is not a
join of every global actor: mipstack socket actors, core statistics and
library-internal transport teardown still require process exit as the final fence.
Provider operations/timers/file polling, health checks and resolver jobs now have
explicit cancel/join groups, with native transport pool closure.
No supervisor is implemented. Permanent registry retirement prevents old workers
from using a new lease in this process after Stop.

## Source/build layout

- `engine.go`: single running-core owner; foundation lease and transfer cleanup.
- `admit.go`, `protocol_admission.go`, `provider_admission.go`, `dns.go`: fail-closed
  capability admission and executable DNS defaults.
- `cmd/overlay`: sixteen complete-source SHA-256 pins and unique patch anchors for
  parser rollback, error-returning executor/listener, raw sing_tun.New and joined
  packet/provider/health-check/resolver worker instrumentation, scoped DNS sockets
   and DoH redirect denial. Phase 1.4 also suppresses REALITY's unauthenticated
   background HTTP fallback, drains group failure/health tasks and closes
   partially parsed top-level/provider proxies.
  Legacy void APIs remain unchanged and unused.
- `cmd/compose`: conflict-free provider/network/engine overlay composition plus
  separately pinned sing-tun packet-loop composition.
- `cmd/enginebridge`, `java/…/NativeEngine.java`: standalone JNI/Java API.
- Foundation `jni/protector.inc`: shared attached-thread callback ownership code;
  foundation-only behavior is unchanged. No module was moved or renamed.
- Root `build.sh`: all-native test and four-ABI Android gates.

Go 1.27.1; Mihomo v1.19.33 / commit
`3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8`; sing-tun v0.4.28; NDK
28.2.13676358; API 23. Pins are unchanged. Builds use `-mod=readonly`, immutable
module staging under ignored native build directories and 16 KiB ELF alignment.
No binaries are checked in or copied to the app. GPL-3.0/license obligations and
device loading/packaging verification remain applicable.

## Verification scope

Root `bash build.sh test` runs every native module's race+shuffle suite and JNI
tests. Engine tests cover repeated invalid YAML/fd, duplicate leases, semantic,
real constructor and stack-Start failures, descriptor counts, stop/release retry,
post-stop process/lease rejection, unexpected input exit, and concurrent stop.
Success instantiates real sing_tun.New/mipstack and sends raw IPv4/UDP through the
protected upstream core to an ephemeral local host-interface UDP sink and back.
Mipstack rejects foreign loopback destinations, so the test requires a local
non-loopback IPv4 interface, not an external server. JVM tests verify Version,
startup exceptions, original-fd ownership and repeated rollback descriptor counts.
These tests do not establish Android TUN/device behavior or a whole-process
goroutine-leak proof. Root `bash build.sh android` builds the three standalone
shared libraries (covering all modules) for all four ABIs.

Remaining work: whole-process supervision/transport-actor exit proof;
additional rejected protocol/transport certification; Phase 1.5
statistics/latency/connection APIs; application integration.
