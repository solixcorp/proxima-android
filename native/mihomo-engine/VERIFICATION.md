# Verification on November 9, 2026

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
