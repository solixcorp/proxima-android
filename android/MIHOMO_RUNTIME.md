# Phase 3.3 Android runtime contract

Mihomo executable YAML is now produced **only in Dart**. The old Kotlin
single-VLESS projection has been removed, not retained as a fallback. Xray's
configuration, native adapters and start path are unchanged.

```text
subscription YAML / share links / legacy comment-based profile
  │
  ├─ import admission preview ──> ProfileRepository metadata (counts/reasons)
  └─ immutable source ──────────> ProfileRepository profile file
                                  │ every explicit start/restart
                                  ▼
AppController → MihomoConfigAssembly → final MihomoProxyAdmission recheck
  │  mode + MTU + IPv6 + saved node; missing selection cleared persistently
  ▼
MethodChannelVpnBridge (UTF-8, <= 8 MiB, sequential <= 64 KiB chunks)
  ▼
MainActivity → app-private MihomoConfigSidecar (.part → ready .yaml)
  │ source SHA-256 + settings fingerprint + random one-use capability
  │ startVpn(profileId); Intent carries capability, never YAML
  ▼
ProximaVpnService consumes/deletes sidecar, checks source/settings identity
  │ MihomoProfileAssembler.verify: MTU / fixed mips stack / IPv6 consistency
  │ VpnService.Builder owns all TUN addresses/routes
  ▼
MihomoVpnSession → MihomoConfiguration immutable byte snapshot
  ▼
MihomoBinderTransport: app-private file → read-only PFD → unlink
  │ Binder v3 carries PFD + length/SHA-256, never configuration bytes
  ▼
:mihomo worker → verify/duplicate FD → unchanged NativeEngine.start
  └─ native Go admission + constructors are authoritative
```

An import preview is not execution approval. Assembly/final admission failures
refuse start in Dart with an error snapshot. Missing/incomplete/stale/oversized
sidecars, Builder mismatch, worker/native errors also refuse start, without an
Xray retry. A ready capability is removed from MainActivity before launch and
the service destroys the file on consumption, including failure. Each Flutter
start, profile refresh/reselection, connected node change and mode change builds
a fresh document. Native `updateConfig`/`changeProxy` cannot trigger an old
Kotlin rebuild. Cancellation/start rejection discards a prepared capability;
Activity destruction also discards its pending uploads. Process-crash orphans
have no capability in the new Activity and are never used by a later start.

Tile/widget/service starts without Dart preparation deliberately fail with
“Mihomo 설정 사이드카가 없습니다. 앱에서 다시 연결해 주세요.” They do not
read a last-successful config. Adding headless Flutter preparation for these
entry points is future work; their existing Xray behavior is unchanged.

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

## Immutable storage and Dart assembly

- In Mihomo mode, subscriptions retain their original YAML bytes (including
  comments, unsupported items and provider definitions). Admission is a separate
  metadata record: valid proxy count and skipped type/reason rows. Import/refresh
  feedback and profile tiles show counts and up to three distinct reasons.
- Supported share links use the generic Dart parser. A local legacy single
  VLESS link still uses the compatible `# proxima-vless-reality-link:` format.
  Existing legacy files are not migrated or rewritten; their links, source URL,
  inline rules and routing metadata remain intact, including on edit/export.
- All admitted static nodes and groups are instantiated. The app adds a `PROXY`
  select group, ordering the saved GLOBAL/PROXY node first. A disappeared node
  clears the saved selection, updates the offline UI to the first node and asks
  for reselection; it never persists that fallback as a user choice.
- Global: `MATCH,PROXY`. Direct: `MATCH,DIRECT`. Rule: admitted subscription rules
  plus trailing `MATCH,PROXY`. Native provider definitions pass through, subject
  to HTTPS/no-userinfo, relative path and native option/behavior policies. Missing
  provider references fail before the channel transfer. Unknown protocols/options,
  invalid references and unsupported rules remain in the source and are reported
  as skipped by the import preview, not silently destroyed in storage.
- Legacy expanded domain/IP rule metadata is reconstructed with its candidate
  policies. Original group types were not stored by the old converter, so
  multi-candidate legacy policies use a select group (first candidate). Compound
  and geodata legacy conditions cannot be safely widened: rule-mode startup
  explicitly requests refresh rather than silently replacing them with MATCH.
- JSON is the unambiguous YAML subset sent to Kotlin. `MihomoProfileAssembler`
  retains its historical name but **only verifies** extracted envelope fields;
  it contains no protocol parser, node selector or YAML builder.
- `tun` contains required enable plus MTU/stack only. IPv4/IPv6 addresses and
  routes belong exclusively to Android Builder. The stack is fixed `mips`, not
  the Xray-only system/gvisor/mixed preference. MTU and top-level IPv6 must match
  Builder values, otherwise start fails. DNS is omitted: the unchanged engine
  injects its defaults and `172.19.0.2:53` interception (see `DNS.md`).

Final Dart admission rechecks executable nodes/groups/provider references/rules;
native Go admission and constructors still decide upstream value validity.
Public-IP probing, connection closing and provider inventory/refresh remain
unsupported by the current JNI surface; no Xray substitute is invoked.

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
off-main. All instantiated static nodes are advertised while connected; selected
node changes restart through fresh Dart assembly, not a native selector API.
Provider-backed dynamic nodes/group selection are not exposed by this JNI API.
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

Phase 3.3 host run (2026-11-13): Flutter tests **304 passed, 4 capture-only
tests skipped**; Kotlin discovery **4/4 passed** (26 boundary + 10 runtime
cases, settings suite and source-wiring assertions); JDK 21 `:app:assembleDebug`
**successful**, 215 actionable tasks; root `bash build.sh test` **7/7 native
module gates successful**. No `native/` source changes are part of this phase.

See [`../native/mihomo-engine/VERIFICATION.md`](../native/mihomo-engine/VERIFICATION.md)
for gate commands/results and the required device checklist. Host tests execute
the production pure Kotlin dispatch, sidecar, consistency checker, lease, handshake and retirement
fence. Wiring assertions inspect the Android source; they do **not** emulate
Binder, real PFD duplication, actual process death, or Android TUN traffic.
Successful native host gates and APK assembly cannot replace those checks.

Remaining risks: native library actors still require whole-process exit; native
Stop/handshake RPC hangs are not falsely bypassed by a timeout; actual Android
process scheduling/binding race behavior remains unverified. LAN exclusions on
pre-33 devices have the existing Builder platform limitation; the app adds no
separate LAN-direct policy beyond the subscription rules.
