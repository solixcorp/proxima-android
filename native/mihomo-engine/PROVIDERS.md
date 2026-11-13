# Phase 1.3 provider and shutdown contract

## Trusted capabilities and admission

Go callers use `StartWithOptions(bytes, fd, protector, Options{ProviderRoot: root})`.
Java's standalone `NativeEngine.start` has an overload accepting `providerRoot`.
`root` is an **existing absolute app-private directory**, selected by application
code, not a profile. The application excludes hostile same-UID writers and keeps
the directory stable until Stop. The original `Start` remains valid without
providers. Provider profiles without a root fail before semantic parsing.
Root binding is process-once; final teardown closes the metadata database and
revokes the root. This does not enable restarting a retired engine process.

Both `proxy-providers` and `rule-providers` accept `http`, `file`, and `inline`.
Allowed common keys: `type`, `path`, `url`, `interval`, `size-limit`, `header`,
`payload`. Proxy providers additionally accept `health-check` with `enable`,
`url`, `interval`, `timeout`, `lazy`, `expected-status`. Rule providers additionally
accept `behavior` (`domain`/`ipcidr`) and `format` (`yaml`/`text`/`mrs`). Unknown
keys, negative/oversized intervals, raw absolute paths, traversal, custom proxy
selection, overrides and certificate-verification bypasses are rejected.
Classical rule providers remain rejected: their nested geodata/resource graph
has no reviewed resource capability.

Phase 1.4 adds option-limited top-level `proxies`, select/url-test/fallback/
load-balance groups, group `use` references and RULE-SET routing (including MRS).
Provider proxies are selected through group `use`, not inserted as standalone
names into the engine's top-level proxy map or implicit GLOBAL group.
See [DIALERS.md](DIALERS.md) for the exact routing and protocol subset.

**Unused does not mean safe to construct:** some upstream proxy constructors
create autonomous networking workers. The real upstream provider parser therefore
calls a process-once adapter policy immediately before each outbound constructor,
after decryption/conversion/overrides, including every refresh. Phase 1.4 applies
the same `admitProxy` policy to payloads and top-level proxies; it admits only
reviewed options for the protocols listed in DIALERS.md. Constructors are lazy
with respect to networking (AnyTLS does start an idle-cleanup timer); adapter
Close and partial-parse cleanup now own these resources. TLS verification cannot
be disabled; imported custom dialers, file certificates/private keys (SSH permits
inline PEM), smux, discovery/realm and unaudited protocol workers remain rejected.
Health checks use real proxies and protected native sockets. Broader acceptance
is never inferred from non-use.

## Actual upstream I/O

The composed `mihomo-provider` overlay remains the implementation: real provider
factories, resource fetchers/vehicles, parser, MRS decoder, metadata/ETag cache,
HTTP transport, and subscriptions. Both kinds of provider are initialized exactly
once by the error-returning executor, before TUN admission; every Initial error
fails Start and joins/rolls back already initialized siblings. Parser failures
also close providers constructed before the failure, including partially built
provider maps. Metadata database initialization failure is a startup error.

Resource URLs require HTTPS, a host, and no userinfo at preflight, initial fetch,
and **every redirect**, including when a valid local cache exists. A valid HTTPS
redirect is supported. Provider HTTP deliberately bypasses the pre-running
internal tunnel and uses the permanent protected native direct dialer for each
socket. A per-fetch socket/dial gate restores the original fetch cancellation
context even if net/http detaches a dial from Request.Context. Body completion
closes its transport/sockets and joins admitted dials; late transport attempts
are denied before opening a socket. TLS verification is unchanged. Health-check
URLs also require HTTPS and retain upstream's no-follow redirect behavior.

All cached reads, writes, timestamps, archive/bundle operations and file polling
use the descriptor-relative boundary. The raw adapter path check is not the I/O
confinement mechanism; `cmfa`'s unconditional IsSafePath does not bypass it.
File auto-reload is a joined one-second confined read/poll loop, not fsnotify
following an untrusted pathname. `mihomo-provider/boundary.WriteFile` already
publishes successfully parsed data using a pinned parent, mode 0600, file sync
and same-directory atomic rename. The foundation Store's non-atomic Write is not
used for provider cache publication. Directory-entry power-loss durability is
not guaranteed. Neither boundary protects against malicious same-UID hardlinks,
device nodes, bind mounts, or moving already-open directories out of the root.

## Update failures

Startup is fail-closed, including MRS parse/cache errors. During a running session,
**keep the last-good core and provider/cache, log the failure, and retain an
observable error**. Explicit Update/SideUpdate returns the actual error; periodic
updates use the same serialized path. `Session.ProviderErrors()` reports the
latest failed update under `proxy/name` or `rule/name`. A successful subsequent
update clears it. Failed parses/writes do not publish a new provider version.
This is not a successful refresh, a disconnected core, or an implicit insecure
fallback. The read can wait for an admitted update to finish. No management API
or Kotlin integration is added in this phase.

## Shutdown groups and ordering

There is no timeout that releases a lease and falsely reports completion.
Caller deadlines in tests are failure detectors, not production join deadlines.

1. Close packet admission and the real raw stack; join its packet loops and
   admitted handlers. Close the transfer fd only afterward. Suspend routing,
   drain scoped packet initialization, tracked connections and UDP pumps.
2. Close DNS admission and cancel its resolver lifetime. Close/join admitted
   DNS dials and their UDP/TCP/DoQ socket transports. Join resolver calls,
   bootstrap/A+AAAA/fallback branches, stale refreshes, retries and singleflight
   jobs. Explicitly close native DoH HTTP/2/HTTP3, QUIC and DoT pools, rather
   than relying on finalizers. The UDP client joins its wire worker on return;
   DoT wire workers and old-connection closes are joined too.
3. Cancel provider admission/fetch context, cancel and join health-check loops
   and their actual URLTest calls, then join fetch operations, update timers and
   file polling. Fetcher owner-driven operations are serialized with polling;
   queued admitted updates are drained. Health checks cannot restart after Close.
   Close current/replaced admitted proxies and group failure/health tasks, then
   clear routing maps. Updater, NTP,
   platform watchers and arbitrary unaudited protocol workers are **not started** by this
   admitted executor path; their configuration remains rejected.
4. Close metadata database/root, then release the foundation lease and attached
   JNI callback. Callback-release failure retains the cleanup handle for retry.

Resource, health-check and DNS worker counters are checked at the protector's
Close callback, not merely later. They return to the zero pre-start baseline on
success, failed initialization, active refresh cancellation and active health
checks. These counters cover owned jobs and joins; they are **not a proof that
every library-internal HTTP/QUIC actor or mipstack actor has exited synchronously**.
Pools/sockets are explicitly closed and all late DNS/provider socket admission is
permanently denied. Process-global non-session statistics/queues may remain alive.
The process remains permanently retired before semantic parsing; terminate/reap
it before replacement. No supervisor, in-process reuse, whole-process goroutine
leak proof, successful DoQ/HTTP3 round-trip proof, or Android device claim is made.
