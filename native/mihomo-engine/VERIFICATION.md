# Phase 2b Android integration verification on November 13, 2026

Implementation/limitations: [Android runtime integration](../../android/MIHOMO_RUNTIME.md).
No native Go/JNI/Java semantic changes, branch switch or commit in this phase.

Completed host gates:

- `JAVA_HOME=/Users/kimrasng/Library/Java/JavaVirtualMachines/jbr-21.0.11/Contents/Home python3 -m unittest discover -s android/app/src/test -v`:
  four Python-discovered tests; 26 existing Kotlin boundary cases, settings
  persistence/defaults, 11 new Kotlin runtime cases, source-wiring assertions.
  New cases cover exact dispatch/no fallback, TCP+REALITY, gRPC, WS,
  HTTPUpgrade, explicit XHTTP/unsafe-option rejection, mode/MTU/IPv6/DNS
  projection, selected-node projection, Binder-death fence scenarios and
  join-before-original-FD-close ordering. Emitted proxy/transport keys are
  cross-checked against `protocol_admission.go`; this is not native Start proof.
- `/Users/kimrasng/flutter/bin/flutter analyze`: no issues.
- `/Users/kimrasng/flutter/bin/flutter test`: 275 passed, 4 existing skipped;
  engine-flag persistence/default and no-immediate-reconnect tests unchanged.
- From `android/`, `JAVA_HOME=/Users/kimrasng/Library/Java/JavaVirtualMachines/jbr-21.0.11/Contents/Home ./gradlew :app:assembleDebug`:
  exit 0; all default APK-supported ABIs, no debug ABI override. Native output
  was up-to-date in the first run. Log: ignored `build/phase2b-assemble.log`.
- Repository-root `JAVA_HOME=/Users/kimrasng/Library/Java/JavaVirtualMachines/jbr-21.0.11/Contents/Home bash build.sh test`:
  exit 0; all seven native modules, race/shuffle/vet and JNI/JVM suites remain
  passing without native semantic changes. Log: ignored `build/phase2b-native-test.log`.

Required device checks (NOT established by Kotlin host tests or APK assembly):

- Install/load the APK on supported Android ABIs; verify Java/JNI resolution,
  native-library alignment, and only the worker loading the Mihomo Go runtime.
- Actual Android TUN IPv4/IPv6 TCP/UDP traffic, protected egress sockets and
  synthetic UDP/TCP DNS `172.19.0.2:53`; MTUs, LAN exclusions, underlying-network
  changes and VPN revoke behavior. Authenticated successful VLESS TCP+REALITY,
  gRPC, WS/HTTPUpgrade interoperability needs real configured peers.
- Force worker PID death during bind, handshake, Start, traffic/probes/snapshot
  and Stop; verify the original service FD closes exactly once, state becomes
  disconnected, and no auto-restart/fallback occurs. Explicit reconnect must
  have a different worker PID and old callbacks must never protect new sockets.
- Race explicit reconnect/mode change/stop/service destroy against Binder death;
  verify native Stop -> worker copies close -> process death -> original TUN
  close, and no retained VPN indicator/FD. Verify main-owner process death also
  terminates the worker and cancels/join native management calls.
- Reject binding/null binding/handshake/native library/admission failures and
  verify precise Mihomo error states without Xray startup. Verify Xray remains
  unchanged on-device and always-on remains disabled.
- Exercise simultaneous delay tests, one-second traffic EventChannel updates,
  zero/failing polls, >1 MiB connections snapshots through FD transport, and
  retired-session management errors while disconnecting.

## Historical Phase 1.5 verification on November 13, 2026

Repository-root final gates completed with exit 0:

- `bash build.sh test`: all seven native modules, vet/race/shuffle, prior
  socket/provider/DNS/protocol regressions, package-local upstream regressions,
  existing JNI/JVM tests and new management JNI tests. Engine suite: 59.928 s.
- `bash build.sh android`: foundation, engine and diagnostic shared libraries
  for **arm64-v8a, armeabi-v7a, x86, x86_64**, all exit 0.
- `git diff --check` and `bash -n native/mihomo-engine/jni-build.sh`: exit 0.
  Branch remains `mihomo-migration`; no commit, branch switch, application edit,
  dependency/pin change, packaged binary or checked-in build artifact.

New executable evidence:

- `TestManagementBeforeStart`: nil/zero sessions reject all three operations.
- `TestManagementProcess`: six isolated/reaped children, all run under `-race`.
  Actual trusted local HTTPS URLTest success for DIRECT, a node and a select group,
  with 24 simultaneous calls (including the same node), protected socket callback
  counts, actual HEAD requests and delays >= 1 ms. Invalid URLs, userinfo, unknown
  names and invalid timeouts cannot reach the server. The real raw-TUN UDP
  ping/pong produces exactly **4 upload / 4 download payload bytes**; actual tracker
  rows include network, chains, rule, counters and start. Artificial writes to
  `DefaultManager` do not contaminate these session totals, and probes do not add
  user payload bytes. Separate children cover actual request timeout, false
  protection (requires `session.ErrProtection` and an invoked callback), untrusted
  TLS certificate, and HTTPS-to-HTTP redirect not followed. Stop cancels an active
  60-second probe; concurrent getters/snapshots vs Stop remain race-free in every
  child, and every API rejects the retired session afterward.
- `TestManagementScopeAndBounds`: two independent managers cannot contaminate
  each other; getter allocation count is zero; >10000 rows and an oversized
  individual row fail explicitly without returning a partial buffer. Synthetic
  trackers are used only for serialization bounds, not networking evidence.
- `NativeManagementTest` in a separate JVM: before-start/retired rejection,
  successful real engine startup, actual raw-packet UDP round trip, 4/4 byte
  totals, owned JSON `byte[]` snapshots that survive Stop, unsafe URL/unknown name
  rejection, and actual false-protector DelayTest failure. An emoji/Korean proxy
  name verifies ordinary UTF-8 across JNI, not Modified UTF-8. The reused host-only
  packet fixture is never linked into Android/production libraries.
- `BenchmarkTrafficStats` (darwin/arm64, Apple M3, non-race): **10.19 ns/op,
  0 B/op, 0 allocs/op**. This measures the Go getter, not JNI or Android-device
  latency. The implementation is O(1), two upstream atomic total loads plus
  admission/WaitGroup operations; no per-poll HTTP, connection scan or rate job.

The first development check failed at compilation because `providerpolicy.URL`
returns both parsed URL and error. Correcting the call to `_, err := ...` fixed
that mismatch; no test was suppressed. The corrected engine-only gate and the
subsequent complete repository gates passed.

Logs (ignored): `build/phase15-all-test.log`, `build/phase15-android.log`,
`native/mihomo-engine/build/phase15-stats-benchmark.log`,
`native/mihomo-engine/build/phase15-engine-test-fixed.log`; initial failed check:
`native/mihomo-engine/build/phase15-engine-test.log`.

See [MANAGEMENT.md](MANAGEMENT.md) for final signatures, accounting exclusions,
concurrency, weak snapshot consistency and bounded-buffer errors. This is not
Android device/VpnService verification, successful interop for every proxy type,
or a join proof for all transport-library actors. Existing one-core-per-process
retirement and mandatory terminate/reap remain unchanged. No HTTP controller,
Reload or application integration was added.

## Historical Phase 1.4 verification on November 13, 2026

Repository-root gates completed with exit 0:

- `bash build.sh test`: all seven native modules, vet/race/shuffle, existing
  JNI/JVM and diagnostic regressions, plus actual upstream package-local tests.
- `bash build.sh android`: foundation, engine and diagnostic shared libraries
  for arm64-v8a, armeabi-v7a, x86 and x86_64 (no application packaging).
- `git diff --check`: exit 0. Branch stays `mihomo-migration`; no commit, branch
  switch, app source change, upstream lock change or checked-in native binary.

New executable evidence:

- `TestProtocolAdmission`: 18 real constructors (17 admitted types, both Mieru
  outer transports), same policy for providers/top-level definitions, no
  constructor network call, option and independent-stack rejection boundaries.
- `TestProtocolSocketRefusal`: 54 actual adapter TCP/UDP cases. Requires the real
  protection error and a callback count increase, with descriptors observed
  before bind/connect. Includes Hysteria/Hysteria2/TUIC/ShadowQUIC, Mieru TCP/UDP,
  WS/gRPC/TFO, TUIC v4 early/v5 normal, VLESS+REALITY. ShadowQUIC remains rejected
  by engine admission: this proves its inspected UDP edge, not complete lifetime.
- `TestWireGuardOuterSocketRefusal`: real sing-wireguard ClientBind Send with
  connected and packet-listener modes; both fail through the permanent hook.
- `TestRoutingAdmission`: native domain/IP/rule-set subset and fail-closed
  geodata/process/logical rules, group options, unsafe health URLs and names.
- `TestEngineRoutingProcess`: seven isolated/reaped children. Real raw-IP/UDP
  round trips through select/url-test/fallback/load-balance; MRS rule-set to a
  group using a proxy provider with MATCH,REJECT fallback; actual domain matchers;
  pending group HTTPS health Stop; partially constructed AnyTLS parse rollback.
  Group worker counters are checked **inside** protector Close, not only later.
- `TestProximaRealityFailureClosesWithoutBackgroundHTTP`: executes the actual
  patched package-local authentication-failure seam; protected mode closes the
  supplied conn synchronously instead of creating an HTTP fallback worker.
- `TestProximaGroupCloseDrainsAndDeniesFailureWorkers`: deterministic synctest
  for task admission/drain; `TestProximaGroupFailureCounterConcurrentSuccess`
  exercises the upstream counter race with the atomic fix under the race detector.
- `TestEveryPatchRequiresThePinnedCompleteSource`: all 16 engine source pins,
  including REALITY/group patches, reject changed and already-patched source.

Development failures were not suppressed: the first MRS fixture incorrectly put
`payload` on one line (the native line-oriented converter rejected it); after
fixing that fixture the provider-routing child exposed the test harness's
prebound provider root. Routing children now let Start own the root, just like
the existing provider children. The corrected full gates passed; production
root immutability and the MRS parser were not weakened.

Logs (ignored): `build/phase14-all-test-final.log`, `build/phase14-android.log`;
earlier evidence/failures: `build/phase14-all-test.log`,
`native/mihomo-engine/build/phase14-protocol.log`, `phase14-routing.log`.
These are host/socket and compilation results, not authenticated interop for
every admitted transport, Android VpnService/device verification, or a complete
library-actor join proof. Worker termination/reaping remains mandatory.
See [DIALERS.md](DIALERS.md) for per-type code evidence and remaining risks.

## Historical Phase 1.3 verification on November 13, 2026

Final repository-root gates completed with exit 0:

- `bash build.sh test`: all seven modules, vet/race/shuffle, native JNI/JVM and
  diagnostic suites, including all Phase 1.1/1.2 regressions.
- `bash build.sh android`: foundation, engine and diagnostic c-shared libraries
  for arm64-v8a, armeabi-v7a, x86 and x86_64.
- `git diff --check`: exit 0. Branch remains `mihomo-migration`; no commits,
  Kotlin/app changes, lock changes, packaged or checked-in binaries.

New `TestEngineProvidersProcess` passed 18 isolated/reaped child scenarios:
actual protected HTTPS proxy/rule/MRS initialization and cache publication;
HTTP/userinfo rejection; HTTP/userinfo redirect escape denial; allowed HTTPS
redirect; untrusted certificate; false protector; invalid proxy payload;
missing file; symlink escape; raw traversal; raw absolute path; unsafe autonomous
proxy constructor; periodic corrupt-MRS refresh preserving last-good core/cache
and clearing the observable error after recovery; pending HTTP refresh Stop;
confined automatic file reload; pending real proxy health-check Stop.

`TestProviderAdmissionBoundary` covers the explicit provider option allowlists,
inline/file/HTTP admission, certificate bypass/custom proxy rejection, negative
intervals, health-check URL policy, classical-rule denial, unchanged top-level
proxy/group denial, passive proxy constructor policy and missing trusted-root
rollback. Existing provider module suites retain descriptor-relative Store,
atomic publication, redirect/ETag, archive and symlink-replacement-race tests.

Resource, health-check and DNS job counters return to the pre-start zero baseline
**inside the protector Close callback**, proving those groups drain before lease
release (including initialization rollback). The Phase 1.2 pending-query and
protected DNS transport tests pass with the new resolver cancellation/join path.
The engine still permanently refuses another core or foundation lease afterward.

Logs: ignored `build/phase13-all-test.log`, `build/phase13-android.log`, and focused
`native/mihomo-engine/build/phase13-engine-test.log`. These are host/compilation
results, not Android runtime/packaging verification. Counters are not a proof of
synchronous termination of every library-internal HTTP/QUIC or mipstack actor;
native pools/sockets are closed and late socket admission is fenced, but process
termination/reaping is still the final boundary. See [PROVIDERS.md](PROVIDERS.md).

## Historical Phase 1.2 verification on November 13, 2026

Final repository-root gates both completed with exit 0:

- `bash build.sh test`: all seven native modules; vet, race+shuffle suites,
  foundation/engine JNI/JVM tests and integrated diagnostic tests.
- `bash build.sh android`: foundation, engine and diagnostic c-shared libraries
  for arm64-v8a, armeabi-v7a, x86 and x86_64. No app packaging or binary check-in.
- `git diff --check`: exit 0.

New `TestEngineDNSProcess` passed 13 reaped child scenarios: UDP, AAAA,
TCP upstream, raw-TUN TCP/TXT, HTTPS DoH, DoH redirect denial, UDP/TCP/DoH/DoQ
protector refusal, pending DNS drain, DNS initialization failure rollback and
explicit wildcard hijack. All use the actual pinned core and mips raw-IP path.
Refusal checks also inspect real DNSDialer DialContext/ListenPacket errors for
`session.ErrProtection`; callbacks verify sockets are not bound before protection.
Post-stop DNS socket admission is denied before reaching the old protector.

`TestDNSAdmissionAndSafeDefaults` verifies omitted/partial DNS injection,
redir-host, supported upstream schemes, unsafe URL/system/custom-dialer rejection,
fake-IP's clear "not supported yet" error, unchanged raw snapshots and rollback
descriptor counts. Existing Phase 1.1 lifecycle/FD/lease tests also passed.

During implementation, actual UDP round trips caught a transport-wrapper error:
net.Conn wrapping hid net.PacketConn, causing miekg/dns to use TCP framing over
UDP. The wrapper now preserves that capability. Policy tests also caught the
upstream's special bare `system` spelling; it is explicitly rejected. A private
helper/test-fixture name collision was renamed. No failing gate was ignored.

Full final output is retained in ignored `build/phase12-all-test.log` and
`build/phase12-android.log`. See [DNS.md](DNS.md) for admitted configuration,
security policy and remaining scope. Successful DoQ/TLS/HTTP3 exchanges and real
Android TUN/VpnService behavior are not established by these host tests; DoQ
configuration and both native UDP socket protection entry points are tested.
Unexported resolver/HTTP/QUIC workers still require process termination/reaping.

## Historical verification on November 9, 2026

Scope: host raw decoder/provider stages with the reviewed provider overlay only.
The blocked network overlay was **not applied**. The combined `build.sh test`
and Android cross-compilation were not run, and no runtime/device/live external
server connectivity was tested.

## Initial run and correction

`go mod verify` returned `all modules verified`. The provider generator verified
8 Mihomo v1.19.33 source checksums. `go vet ./...` passed.

The first race run failed, exit 1:

```text
--- FAIL: TestRealRuleProviderInitialLoadsRules (0.01s)
panic: runtime error: invalid memory address or nil pointer dereference
github.com/metacubex/mihomo/rules/provider.NewRuleSetProvider.func1
    rules/provider/provider.go:135
FAIL proxima.local/mihomo-engine 1.031s
ok   proxima.local/mihomo-engine/cmd/compose 1.551s
```

This was an omission in the new test harness, not a pre-existing repository
failure. Actual `config.parseRuleProviders` registers
`ruleprovider.SetTunnel(tunnel.Tunnel)` at pinned `config/config.go:1021`.
The factory-level test intentionally avoids semantic parsing, so it must
register that real callback itself. The harness now does so before tests.
No error/panic suppression or provider stub replaced the failing behavior.

The running first check was allowed to finish. Only after its observed failure
and the correction was a new check started.

## Final corrected provider-only check

Environment/artifacts relative to this module:

```text
GOFLAGS=-mod=readonly -modfile=<module>/build/provider-test.mod -overlay=<module>/build/provider-only-overlay/overlay.json
MIHOMO_ENGINE_TEST_SOURCE=<module>/build/provider-only.vNvouP
GOTOOLCHAIN=local
SSL_CERT_FILE=/etc/ssl/cert.pem
```

Commands:

```sh
go vet ./...
go test -race -shuffle=on -count=1 -timeout=60s -v ./...
```

Final output, exit 0:

```text
PASS
ok   proxima.local/mihomo-engine             1.943s
PASS
ok   proxima.local/mihomo-engine/cmd/compose 1.233s
PROVIDER_ONLY_ENGINE_TESTS_EXIT_0
```

All 15 top-level tests passed (12 engine tests, 3 composer tests), including 12
invalid-YAML subcases. Race detector and vet reported no diagnostics.
The engine shuffle seed was `1794206941077768000`; composer seed was
`1794206940388292000`.

One expected actual-core log appeared in the first-failure test:

```text
level=error msg="[Provider] a-missing pull error: openat first/missing.yaml: no such file or directory"
```

That test asserts the real missing-file error is returned and the subsequent
provider is not initialized. It does not interpret the logged failure as success.
The test harness closes the real providers; stage Stop alone is not provider
teardown.

Full final output is retained in ignored `build/provider-test.log`.
The reviewed provider overlay mapping is
`build/provider-only-overlay/overlay.json`, and the staged module is
`build/provider-only.vNvouP`. `build/provider-test.mod` and
`build/provider-test.sum` select that stage without modifying another component.

`bash -n native/mihomo-engine/build.sh` also exited 0. This verifies script syntax
only, not combined overlay behavior. Composer unit tests verify checksum failure,
same-stage enforcement, duplicate/conflicting mappings, normalized original
paths, missing files, deletion rejection and two-map composition against actual
pinned source. Combining the actual provider/network generator outputs remains
unverified until the network review clears.

## Delivered and deliberately unfinished

Delivered: exact-byte/revision snapshots, actual upstream raw typed decoding,
real provider Initial error propagation, one-shot/stale/cancel/Stop admission
semantics, and a conflict-rejecting shared-stage overlay build recipe.

Dependencies: pinned Mihomo v1.19.33 and its locked graph; local foundation
socket hook and provider path capability. The combined recipe additionally
depends on the network overlay, whose pending review is not represented as
passed by this module.

This is not semantic configuration validation, executor readiness, a supervised
worker, or an Android engine. Geodata and other non-provider I/O policies,
observable full executor startup errors, active Android protection, complete
routing/DNS/TUN wiring and whole-core process teardown remain integration work.
The README records required ordering, snapshot/config association assumptions,
provider ownership and the DNS module's required teardown path.

## Independent review fixes and deterministic regression evidence

The independent review in `.omo/evidence/mihomo-engine-code-review.md` found a
high-severity per-provider admission race and a medium-severity duplicate JSON-key
gap. Both were fixed locally. A focused independent recheck is still required
before integration; these results do not change another component's review
status.

For the pre-fix regression run, the existing per-provider `ctx.Err()` check was
extracted without changing its behavior into `admit`. The deterministic gate
test then demonstrated that this check neither held Stop's mutex nor rejected
Stop's admission state when supplied an uncancelled context. This is a direct
test of the admission synchronization invariant, not a probabilistic scheduler
race. The duplicate-input test supplied actual duplicate keys in raw JSON,
rather than serializing a Go map that would have already discarded duplicates.

The pre-fix command used the same provider-only environment described above:

```sh
go test -race -count=1 -timeout=30s -v \
  -run 'TestProviderAdmissionSerializesWithStop|TestComposeRejectsDuplicateJSONKeysInOneInput' ./...
```

It exited 1 with these deterministic failures:

```text
provider admission checked context outside Stop mutex
provider admitted after Stop closed admission: <nil>
--- FAIL: TestProviderAdmissionSerializesWithStop (0.00s)
FAIL proxima.local/mihomo-engine 1.202s

duplicate input accepted or wrong rejection: <nil>
--- FAIL: TestComposeRejectsDuplicateJSONKeysInOneInput (0.01s)
FAIL proxima.local/mihomo-engine/cmd/compose 0.643s
```

All five JSON subcases failed before the fix: identical path keys, conflicting
path keys, escaped equivalent path keys, duplicate `Replace`, and escaped
equivalent `Replace`. Full output: `build/review-regressions-before.log`.

The corrected gate observes cancellation while holding the same mutex under
which Stop sets its stopped state. That successful nil observation is the
per-provider admission point. Stop winning that mutex prevents another
admission. If admission wins, the already-admitted call may enter Initial after
Stop begins; Stop still drains it and the attempt. Parent cancellation before
the observation rejects admission; cancellation racing after the observation
cannot revoke the admitted call and is checked again after Initial. The source
and README now state these exact boundaries.

Two additional `testing/synctest` regressions exercise actual stage sequencing
with controlled providers: Stop closes admission and waits for the held first
provider, and parent cancellation prevents the next provider from entering.
They use channel barriers and scheduler quiescence, not sleeps or timing
probabilities. Real provider parsing/loading/error tests remain separate and
continue to pass.

The composer now decodes JSON keys before map insertion at both object levels,
rejecting identical/conflicting/escaped duplicates. Its input schema is exactly
one `Replace` object containing string values. Existing cross-input collision,
source checksum, staged-root and file checks remain active.

After applying the fixes, one final run completed without restart:

```text
COMMAND: go vet ./...
VET_EXIT_0
COMMAND: go test -race -shuffle=on -count=1 -timeout=60s -v ./...
PASS
ok   proxima.local/mihomo-engine             2.867s
PASS
ok   proxima.local/mihomo-engine/cmd/compose 2.050s
REVIEW_FIX_PROVIDER_ONLY_EXIT_0
```

Exit 0: all 19 top-level tests passed (15 engine, 4 composer), including the
12 invalid-YAML and 5 duplicate-JSON subcases. Vet and the race detector reported
no diagnostics. The expected missing-file provider test emitted
`[Provider] missing pull error: openat absent/rules.yaml: no such file or directory`;
that test asserts the same underlying failure is returned rather than treated
as initialization success.

Full output, including commands and vet status, is retained in
`build/review-fixes.log`. Shuffle seeds: engine `1794207796427327000`, composer
`1794207795600346000`. The provider-only overlay/modfile/staged-core paths remain
those recorded above. The network overlay was not applied; combined verification,
Android compilation/device behavior and full semantic/executor startup remain
unverified.
