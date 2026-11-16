# Verification on November 9, 2026

This evidence covers the standalone session/dialer JNI foundation only.
No Android device was attached. No TUN was started, no VPN traffic was tested,
and no provider policy was integrated into the upstream executor.

Host: Darwin arm64, Go 1.27.1, OpenJDK 26.0.2.1. Android compiler: NDK
28.2.13676358, API 23. Commands below ran from `native/mihomo/`.

## Source resolution

The first `go mod tidy` exited 1 because the tool shell inherited
`SSL_CERT_FILE` and `SSL_CERT_DIR` pointing at empty trust stores. The retry used
the system CA bundle, kept TLS certificate verification enabled, and exited 0:

```sh
SSL_CERT_FILE=/etc/ssl/cert.pem SSL_CERT_DIR=/etc/ssl/certs \
GOMODCACHE="$PWD/build/go-mod" GOCACHE="$PWD/build/go-cache" \
go mod tidy
```

`go mod download -json github.com/metacubex/mihomo@v1.19.33` exited 0 and reported:

```text
Sum: h1:hwqYMItk3Jaeq8Sw2PBAtyHQh157ccUtWS7rXrBOMCU=
GoModSum: h1:bzTZ70b83bz4enuwxrjHYg1Iqze8XqTP72OHmulMhYA=
Origin.URL: https://github.com/metacubex/mihomo
Origin.Hash: 3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8
Origin.Ref: refs/tags/v1.19.33
```

## Host build and tests

```sh
set -o pipefail
SSL_CERT_FILE=/etc/ssl/cert.pem SSL_CERT_DIR=/etc/ssl/certs \
bash build.sh test 2>&1 | tee build/host-test-final.log
```

Exit code: 0. Complete final output:

```text
Host JNI build exit=0
Go vet exit=0
ok  	proxima.local/mihomo	1.352s
?   	proxima.local/mihomo/cmd/sessionbridge	[no test files]
ok  	proxima.local/mihomo/providerpolicy	1.354s
ok  	proxima.local/mihomo/session	1.362s
Go race tests exit=0
JNI session ownership, refusal, exception, and stale-token tests passed
JVM JNI tests exit=0
```

The script runs `go vet -mod=readonly ./...` and
`go test -mod=readonly -race -shuffle=on -count=1 -timeout=60s ./...`.
The JVM test loads the actual host shared library and checks callback booleans,
Java exceptions failing closed, rejected concurrent preparation, descriptor
ownership, and stale lease isolation.

The Go tests drive the actual pinned Mihomo TCP/UDP dialer and real host sockets.
Provider tests cover the separate policy helpers, including existing-file and
directory symlink escape attempts. They do not exercise upstream provider I/O.

The pinned `gofumpt v0.8.0` formatter ran successfully on the initial Go sources.
`golangci-lint` and `nilaway` were not installed and were not run; the static
analysis evidence here is `go vet`, not those tools.

## Android ABIs

```sh
set -o pipefail
SSL_CERT_FILE=/etc/ssl/cert.pem SSL_CERT_DIR=/etc/ssl/certs \
GOMAXPROCS=4 bash build.sh android 2>&1 | tee build/android-build-final.log
```

Exit code: 0. Complete final output:

```text
Building Android arm64-v8a
Android arm64-v8a build exit=0
Building Android armeabi-v7a
Android armeabi-v7a build exit=0
Building Android x86
Android x86 build exit=0
Building Android x86_64
Android x86_64 build exit=0
Built all four ABIs under native/mihomo/build/android; not packaged into app.
```

Each ABI runs this command, with the mappings immediately below:

```sh
GOOS=android GOARCH="$arch" GOARM=7 \
CC="$bin/$target$api-clang" \
CGO_CFLAGS="-Werror=incompatible-pointer-types" \
CGO_LDFLAGS="-Wl,-z,max-page-size=16384" \
go build -mod=readonly -trimpath -buildmode=c-shared \
-o "build/android/$abi/libproxima_mihomo_session.so" ./cmd/sessionbridge
```

| ABI | GOARCH | NDK compiler target | Exit |
| --- | --- | --- | --- |
| arm64-v8a | arm64 | aarch64-linux-android23-clang | 0 |
| armeabi-v7a | arm | armv7a-linux-androideabi23-clang | 0 |
| x86 | 386 | i686-linux-android23-clang | 0 |
| x86_64 | amd64 | x86_64-linux-android23-clang | 0 |

The initial four builds also exited 0, but each emitted this unsuppressed warning:

```text
bridge.c:28:46: warning: incompatible pointer types passing 'void **' to parameter of type 'JNIEnv **' (aka 'const struct JNINativeInterface ***') [-Wincompatible-pointer-types]
```

That original output remains in ignored `build/android-build.log`.
The code now uses Android's `JNIEnv **` signature and the desktop JDK's
`void **` signature in their respective compiler branches. The final builds
have no warnings, and incompatible pointer warnings are now errors.

NDK `llvm-readelf --program-headers --wide` and
`llvm-readelf --dyn-syms --wide` were run on each final library; all eight
commands exited 0. Every `LOAD` segment has alignment `0x4000` (16 KiB).
Every ABI exports `JNI_OnLoad` and the four Java methods `prepareNative`,
`closeNative`, `duplicateTunNative`, and `protectNative`.
This does not establish Android loading, APK ZIP alignment, or VPN operation.

## Regression proof

The original production sources were never overwritten. Ignored Go overlays
under `build/_mutations/` intentionally:

- Skipped closing the bridge-owned descriptor.
- Accepted stale protection tokens.
- Returned success after the protector refused a socket.
- Allowed userinfo in provider URLs.
- Replaced confined writes with ordinary pathname writes.

```sh
set -o pipefail
GOMODCACHE="$PWD/build/go-mod" GOCACHE="$PWD/build/go-cache" \
go test -mod=readonly -race -shuffle=on -count=1 -timeout=60s \
-overlay=build/_mutations/overlay.json ./session ./providerpolicy . \
2>&1 | tee build/mutation-tests.log
```

Exit code: 1, expected. The tests failed for the intended behaviors:
`TestCloseReleasesTheBridgeOwnedDescriptor`,
`TestStaleLeaseCannotProtectOrCloseReplacement`,
`TestProviderURLPreservesHTTPSPolicy`,
`TestProviderStoreConfinesActualReadsAndWrites`,
`TestMihomoUDPPropagatesProtectionRefusal`, and
`TestMihomoTCPPropagatesProtectionAndBlocksOutsideLease`.
The complete failures remain in `build/mutation-tests.log`. The final normal
test command above passed without overlays.

## Source-change boundary

`bash -n native/mihomo/build.sh` exited 0 from the repository root.
`git ls-files --others --exclude-standard native/mihomo` listed only source,
tests, module checksums, scripts, and documentation. It listed no generated
library, JAR, class, log, or cache file.

`git check-ignore -v` confirmed all these paths are excluded by
`native/mihomo/.gitignore:1:/build/`:

```text
native/mihomo/build/android/arm64-v8a/libproxima_mihomo_session.so
native/mihomo/build/go-mod
native/mihomo/build/go-cache
native/mihomo/build/native-session.jar
```

No app build configuration, service, activity, UI, credentials, or signing file
was changed by this work. No commit was created. Runtime startup error handling,
complete provider/background-worker shutdown, actual provider policy wiring,
and Android VPN traffic remain unimplemented here, as documented in `README.md`.

## Review follow-up on November 9, 2026

The following runs cover the source after addressing all three findings in
`.omo/evidence/mihomo-standalone-code-review.md`. Earlier results above are
retained as the initial implementation's evidence.

Callback admission now increments an explicit in-flight counter under the
lease mutex; the callback itself runs without holding that mutex. Close first
disables admission and then waits for the admitted callbacks. The deterministic
Go test uses callback-entered and callback-release channels with `synctest.Wait`
to establish that close is waiting. It asserts both that close has not completed
and that the protector has not been released before unblocking the callback.
It uses no sleep or scheduling-dependent grace period.

A failed protector release now retains the inactive lease. Protection and
descriptor duplication stay denied, replacement preparation stays blocked,
and another close retries the release without closing the TUN fd again.
Native release requires an already attached JVM thread and retains the owner
otherwise. Once the global reference and owner are freed, no fallible detach
operation remains. The Java API and README document the attached-thread retry.

The README also now records the custom `NetDialer` early return in the pinned
upstream source, including the Tailscale and ShadowQUIC callers. It does not
claim every custom implementation opens an unprotected OS socket.

### Reproducing the original release bug

Before changing the registry, the new release tests ran against its original
implementation:

```sh
set -o pipefail
GOMODCACHE="$PWD/build/go-mod" GOCACHE="$PWD/build/go-cache" \
go test -mod=readonly -race -count=1 -timeout=30s \
-run "TestReleaseFailureKeepsLeaseInactiveAndReserved|TestCloseRetriesFailedProtectorRelease" \
./session 2>&1 | tee build/review-release-before.log
```

Exit code: 1, expected. Both tests failed:

```text
TestReleaseFailureKeepsLeaseInactiveAndReserved:
Expected error with "native session already prepared" in chain but got nil.
TestCloseRetriesFailedProtectorRelease:
Expected error with "file already closed" in chain but got nil.
```

The retry test owns a real file as the protector resource and verifies that the
successful retry actually closes it.

### Final host verification after the review fixes

```sh
set -o pipefail
SSL_CERT_FILE=/etc/ssl/cert.pem SSL_CERT_DIR=/etc/ssl/certs \
bash build.sh test 2>&1 | tee build/review-host.log
```

Exit code: 0. Complete output:

```text
Host JNI build exit=0
JNI release attachment retry tests passed
JNI release fault tests exit=0
Go vet exit=0
ok  	proxima.local/mihomo	1.339s
?   	proxima.local/mihomo/cmd/sessionbridge	[no test files]
ok  	proxima.local/mihomo/providerpolicy	1.335s
ok  	proxima.local/mihomo/session	1.332s
Go race tests exit=0
JNI session ownership, refusal, exception, and stale-token tests passed
JVM JNI tests exit=0
```

The new native fault test compiles the production C release function with
`-std=c11 -Wall -Wextra -Werror`, using a controlled JNI invocation table.
It checks unavailable and detached environments leave the owner intact, then
an attached environment deletes the global reference exactly once. Its unused
Go entry points abort if called rather than simulate a registry. No fault
injection switch or replacement implementation is included in the library.
The separate real-JVM test still loads and exercises the actual shared library;
JVM attachment failures were simulated only in the native fault fixture.

### Deterministic callback-drain regression proof

An ignored overlay removes only `l.callbacks.Wait()` from the current registry.
The production source remains unchanged:

```sh
set -o pipefail
GOMODCACHE="$PWD/build/go-mod" GOCACHE="$PWD/build/go-cache" \
go test -mod=readonly -race -count=1 -timeout=30s \
-overlay=build/_review_mutations/overlay.json \
-run TestCloseDrainsEnteredCallbackBeforeRelease ./session \
2>&1 | tee build/review-drain-mutation.log
```

Exit code: 1, expected. The test failed with both intended assertions:

```text
Close completed while the callback was blocked
protector released while its callback was blocked
```

The same test passed in the normal race-test suite above.

### Android rebuild after the review fixes

```sh
set -o pipefail
SSL_CERT_FILE=/etc/ssl/cert.pem SSL_CERT_DIR=/etc/ssl/certs \
GOMAXPROCS=4 bash build.sh android 2>&1 | tee build/review-android.log
```

Exit code: 0. Complete output, with no compiler warnings:

```text
Building Android arm64-v8a
Android arm64-v8a build exit=0
Building Android armeabi-v7a
Android armeabi-v7a build exit=0
Building Android x86
Android x86 build exit=0
Building Android x86_64
Android x86_64 build exit=0
Built all four ABIs under native/mihomo/build/android; not packaged into app.
```

The source inventory still excludes generated files. `git check-ignore -v`
confirmed the native test executable, review mutation overlay source, and review
logs are covered by `native/mihomo/.gitignore:1:/build/`. These fixes touch only
`native/mihomo/`. They do not integrate provider policies, start a TUN, or
establish Android VPN operation.
