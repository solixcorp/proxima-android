# Phase 2b Android runtime integration

Phase 3.3 is not integrated: `lib/core/mihomo_config_assembly.dart` is an
offline prototype and is not a source of configuration for this service. The
existing Kotlin projection and execution contract below remain authoritative.
TUN addresses continue to belong to Android's Builder; native admission rejects
address fields in the executable YAML. A Dart-to-worker FD path, settings
consistency validation, and non-Flutter start/restart entry points still need
to be implemented before replacing the projection.

## Engine boundary

`ProximaVpnService` captures `NativeVpnSettings.engine` per connection. Both
engines use the existing Builder unchanged: `172.19.0.1/30`, DNS `172.19.0.2`,
MTU setting, optional `fdfe:dcba:9876::1/126`, and the existing API-33 route
exclusions. The branch is immediately after TUN establishment, before any Xray
configuration, ports, SOCKS probes or log setup. Xray's four core adapters are
unchanged. Switching the saved engine does not hot-swap the running session.

Mihomo is explicit opt-in, never an Xray fallback. Bind rejection, null binding,
handshake errors, ten-second attachment timeout, native load/start/admission
errors all reach the existing `error` snapshot with a Mihomo-specific message.
An unexpectedly lost running worker publishes `disconnected` after retirement;
there is no automatic reconnect. Both services remain `START_NOT_STICKY`, the
worker remains bound-only, and always-on remains false.

## Temporary profile projection (move to Dart in Phase 3)

`MihomoProfileAssembler` is Android/native-independent Kotlin. It reads the
base64url `# proxima-vless-reality-link:` comments, chooses one node using saved
PROXY/GLOBAL selections (otherwise the first usable link), and emits flow-style
YAML (the JSON subset accepted by Go yaml.v3). It never executes the YAML stored
beside the metadata. Strings are quoted/escaped; unknown/duplicate URI options
are errors, not ignored transport requests. The original profile is not changed.

- One VLESS proxy, one `PROXY` select group referencing it.
- TCP/raw; gRPC service name; WS path/Host; HTTPUpgrade via the admitted
  `ws-opts.v2ray-http-upgrade` flag. TLS SNI, ALPN and client fingerprint; REALITY
  public key/short ID and optional `xtls-rprx-vision` flow.
- XHTTP/splitHTTP and REALITY-over-WS/HTTPUpgrade are rejected. This reflects the
  existing native admission contract; no Go capability is widened. HTTPUpgrade
  projection is tested, but the unchanged Dart import parser still restricts
  the transports users can newly import in this phase.
- `global` and `rule` -> `MATCH,PROXY`; `direct` -> `MATCH,DIRECT`.
  **Subscription rules/providers, automatic fastest-node selection and multiple
  live nodes are NOT translated in Phase 2b.** Saved rule-list UI can still show
  stored metadata; it is not evidence that Mihomo executes those rules. Settings
  explicitly warn that rule mode currently sends everything through the proxy.
- DNS is omitted: the native engine supplies its documented protected-direct
  DoH defaults. This differs from Xray's proxy-routed DNS; see `DNS.md`.
- `tun.stack` is always `mips`; existing system/gvisor/mixed preference does not
  select another native stack. MTU and top-level IPv6 match the Builder settings.
  Native admission forbids `tun.inet4-address` and nonempty `inet6-address`.
  Accordingly the app-owned addresses/routes stay solely in Android Builder;
  the YAML records them as comments, not unsupported device-creation fields.
  `172.19.0.2:53` is explicitly retained in `dns-hijack`.

Projection-time validation checks the Kotlin-supported link subset, not a
second native session. `NativeEngine.start` is the authoritative admission and
semantic validator. Only the selected link is projected/validated. A saved
subscription's other links are not all instantiated or certified.

Phase 3 should move metadata/link parsing, stable names and selected-node
projection, YAML encoding, full group/provider/rule translation, DNS/stack
policy and the single-node UI limitations into the Dart config pipeline.
Android retains only Builder/socket-protection/IPC/process lifetime ownership.
Public-IP probing and connection closing are explicitly unsupported by the
current Mihomo JNI surface; they never invoke `XrayProbe` as a substitute.

## Runtime bridge

`MihomoVpnSession` coordinates lifecycle off main; only service binding/unbinding
runs on main. `MihomoWorkerBoundary` keeps its generation/identity/PID handshake,
lease gate and socket-FD protection checks. Binder worker protocol v3 adds:

- STAGE now starts `NativeEngine`, returning a bounded native error string or
  success only after `start` returns. `ProximaVpnService` alone then publishes
  `VpnRuntime.connected` and starts one-second traffic updates.
- `trafficStats`: two longs. Speeds are differences of native payload totals;
  reconnect offsets and EventChannel snapshots follow the Xray polling pattern.
- `delayTest`: named native proxy/group HTTPS test; normal timeout validation and
  errors come from native management. No SOCKS port or external controller.
- `connectionsSnapshot`: up to 8 MiB, transferred using an unlinked, read-only
  snapshot FD plus length/SHA-256, just like startup configuration. Native JSON
  rows become the existing Dart connection-envelope shape; no access-log parsing
  or invented destination IP/port/process fields. Native only exports active
  rows and those limited metadata fields.

`VpnRuntime` retains the *running* session/engine independently of saved settings.
`MainActivity` branches core actions against that captured engine. Management is
off-main, and only the single instantiated node is advertised while connected.
No native engine is instantiated/loaded in the main process for Mihomo.
`coreInfo` names the pinned bundled version and only reports loaded when a
session is published; it is not a native version query or packaging proof.

The Java engine API does not export Go Done/Wait. The worker independently polls
`trafficStats` every second; native unexpected packet exit closes management
admission, causing that watch to Stop and terminate the worker. This detects a
retired native session, not upstream availability or stalled packet progress.

## Descriptor and process lifetime

Startup:

1. VPN service owns the detached original TUN descriptor.
2. `fromFd`/Binder transfer duplicate descriptors. The worker verifies the config
   snapshot, retains its own TUN/config duplicates, and links owner Binder death.
3. `NativeEngine.start` borrows the worker TUN. Go owns its separate foundation,
   transfer and raw-device duplicates, as specified by `ENGINE.md`.
4. JNI's socket callback borrows a worker-local socket; `fromFd` and Binder
   duplicate that socket for `VpnService.protect`. Every transferred copy closes
   within its callback. The engine's original socket is never adopted/closed.

Normal stop/reconnect/failure:

1. Remove the runtime management capability, revoke the protector gate and send
   one-way RETIRE; unbind the service (never auto-rebind).
2. Worker serializes Start/Stop, calls native Stop (which cancels/joins probes,
   management and packets), then closes worker-owned TUN/config duplicates and
   terminates its own dedicated PID. Cleanup objects remain retained after a
   Start error until retirement. Native release errors still end in PID exit;
   there is no false "native joined successfully" acknowledgment.
3. The registered Binder DeathRecipient frees only that exact lease and signals
   `MihomoRetirementFence`. The owner waits off-main, without a timeout that could
   masquerade as successful release, then closes the service's original TUN.
4. Only an explicit new start may bind a **new process**. Neither Stop response,
   `DeadObjectException` nor service-disconnect notification authorizes PID reuse.

Unexpected worker/owner death closes that process's descriptors through the
kernel. Running-worker death triggers the same final original-FD cleanup and a
disconnected snapshot. Generation checks ignore old death callbacks during
explicit reconnect. `onDestroy` enqueues Mihomo cleanup and gracefully shuts the
lifecycle executor instead of interrupting its retirement wait; main stays free
to process unbinding/death callbacks. Failed/unjoined retirement retains the
original descriptor rather than falsely declaring it safe to close/reuse.

## Host gates and device limitations

See [`../native/mihomo-engine/VERIFICATION.md`](../native/mihomo-engine/VERIFICATION.md)
for gate commands/results and the required device checklist. Host tests execute
the production pure Kotlin dispatch, assembler, lease, handshake and retirement
fence. Wiring assertions inspect the Android source; they do **not** emulate
Binder, real PFD duplication, actual process death, or Android TUN traffic.
Successful native host gates and APK assembly cannot replace those checks.

Remaining risks: native library actors still require whole-process exit; native
Stop/handshake RPC hangs are not falsely bypassed by a timeout; actual Android
process scheduling/binding race behavior remains unverified. LAN exclusions on
pre-33 devices have the existing Builder platform limitation; this temporary
MATCH-only Mihomo projection adds no separate LAN-direct routing policy.
