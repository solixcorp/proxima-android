Initial pre-review checks ran on November 9, 2026, with Go 1.27.1 on Darwin
arm64. These results predate the two HIGH findings; correction evidence and
remaining limitations are recorded below.

The following commands completed with exit code 0:

```sh
GOPROXY=off bash build.sh test
GOPROXY=off bash build.sh cross
```

The initial online dependency fetch failed because the workstation could not
verify the Go proxy TLS certificate. Verification used an isolated filesystem
clone of the existing provider module cache under this directory's ignored
`build/go-mod`. No TLS or module checksum validation was disabled.
`go mod verify` reported `all modules verified`.

The generator validated 14 pinned source SHA-256 hashes: seven patched Mihomo
files and seven audited TFO implementation files. Its unit test rejects a
changed checksum, missing anchor, and ambiguous anchor.

Host `go vet ./...` and `go test -race -shuffle=on -count=1 -timeout=60s -v ./...`
passed against the actual staged upstream packages and generated overlay:

- Inactive and refusing sessions reject inbound TCP/UDP, REDIR, TProxy TCP/UDP,
  and dialer UDP listeners, with inbound TFO both enabled and disabled.
- The refusing session's real callback sees unbound and unconnected sockets and
  is called exactly once for each listener attempt.
- TCP and deferred TFO refusal return the session protection error; a real
  loopback TCP listener observes no accepted connection. The test also confirms
  TFO remains deferred and passes the caller's context value to control.
- Cancellation before the first deferred TFO write prevents socket protection
  from being attempted and returns `context.Canceled`.
- A virtual custom dialer remains callable without presenting a fake raw socket.
- An approved inbound UDP socket receives an actual loopback datagram.

Cross checks compiled the upstream TProxy package and its new Linux-only
`TestProximaRawUDPRefusedBeforeBindConnect` test into
`build/tproxy-linux-arm64.test`. They also compiled the affected imported
packages for `GOOS=android GOARCH=arm64 CGO_ENABLED=0`.

The Linux binary was not executed. Docker's daemon socket was absent and the
available Lima VM was stopped; no unrelated VM was started. The Linux test is
wired into `bash build.sh test` on Linux and requires no transparent socket
privilege to exercise rejection. Its descriptor-closure assertions are compiled
but remain unexecuted here.

These checks do not demonstrate Android device behavior, an APK/JNI link, a
working privileged TProxy deployment, Linux TFO network behavior, fakeTCP
capabilities, or complete protection coverage for every upstream outer
transport. The overlay is not yet consumed by existing native/app build scripts.
No application, signing, device, private-profile, or existing component files
were changed.

The two HIGH findings in `.omo/evidence/mihomo-network-code-review.md` were
addressed on November 9, 2026. The TFO wrapper now synchronizes its lifecycle,
permits one dial attempt, broadcasts completion, and closes successful results
that arrive after Close or cancellation without publishing them. Its source
replacement remains gated by the original pinned file hash. TFO selection is
limited to TCP network names; UDP remains an eager `net.UDPConn`.

The first review-fix run used:

```sh
GOPROXY=off bash build.sh test
```

It passed host vet and both overlay-generator tests, then failed the two UDP6
cases with:

```text
udp_test.go:107: protection calls=0 error=dns resolve failed: ipv6 disabled
udp_test.go:32: dns resolve failed: ipv6 disabled
FAIL proxima.local/mihomo-network/integration
```

The pinned resolver defaults `DisableIPv6` to true. Both UDP tests now enable
IPv6 explicitly and restore its previous setting in cleanup. Neither IPv6
assertions nor failing test cases were removed or skipped. The initial log is
retained locally at `build/review-fixes.log`.

After that fixture correction, these exact focused checks completed with exit
code 0 from this directory:

```sh
export GOMODCACHE="$PWD/build/go-mod" GOCACHE="$PWD/build/go-cache" GOPROXY=off
export GOFLAGS="-mod=readonly -modfile=$PWD/build/network.mod -overlay=$PWD/build/overlay/overlay.json"
go vet ./integration
go test -race -shuffle=on -count=1 -timeout=60s -v ./integration
go test -race -shuffle=on -count=1 -timeout=60s -v \
  github.com/metacubex/mihomo/component/dialer -run "^TestProxima"
env -u GOFLAGS bash build.sh cross
```

Relevant completion output, retained locally in `build/review-fixes-final.log`:

```text
ok   proxima.local/mihomo-network/integration  1.456s
--- PASS: TestProximaTFOCloseOwnsLateDial (0.00s)
--- PASS: TestProximaTFODialFailureIsShared (0.00s)
--- PASS: TestProximaTFOConcurrentFirstWritesAndReaders (0.00s)
--- PASS: TestProximaTFOCancellationOwnsLateDial (0.00s)
PASS
ok   github.com/metacubex/mihomo/component/dialer  1.310s
all modules verified
Verified 14 pinned source checksums; generated socket protection overlay
Linux test binary and Android arm64 packages compile exit=0
```

The four new tests run inside the real patched upstream dialer package.
`testing/synctest` parks competing goroutines before releasing a controlled dial
completion; `net.Pipe` supplies the transport. They assert one dial for eight
concurrent first writes, delivery of every writer's bytes, broadcast to multiple
readers, cancellation/Close ownership of a late result, one underlying Close,
shared terminal errors, concurrent observer safety, and continued stream use
after cancelling a completed dial. This is deterministic lifecycle evidence,
not proof of successful kernel TFO early-data transmission.

The actual socket integration tests passed approved and refused
`udp`, `udp4`, and `udp6` dials with TFO enabled. They assert immediate protection,
connected socket/address availability, concrete UDP and packet/syscall
interfaces, and real loopback request/reply traffic after cancelling the
completed UDP dial context. Cross compilation now includes both
`build/tproxy-linux-arm64.test` and `build/dialer-linux-arm64.test`, plus the
affected Android arm64 packages.

At the completion of the HIGH corrections, the MEDIUM limitations were still open:
pre-first-write cancellation still cancels deferred TFO establishment, so
callers that cancel immediately after a deferred DialContext returns require
contract reconciliation. Cancellation during establishment was retained, and
post-establishment survival is tested. Approved Linux TFO, approved raw TProxy
UDP descriptor transfer, transparent-option failures on Linux, Linux runtime
races, and Android device execution remain untested here. Pre-establishment
deadline setters also retain the pinned no-op behavior. Neither HIGH fix
certifies production integration or grants raw/transparent socket privileges.
The context and deadline limitations in this historical paragraph are
superseded by the later contract corrections below.

## Linux refusal assertion correction — November 14, 2026

The Linux-only `TestProximaRawUDPRefusedBeforeBindConnect` failure from CI run
43576209931 was reproduced before the correction in Docker `golang:1.27.1`
(Linux arm64). `bash build.sh test` failed with
`original owner not closed: use of closed file`.

This was a test error, not a descriptor-ownership or scheduling defect. The
checksum-gated `listener/tproxy/udp_linux.go` edit in `cmd/overlay/patches.go`
creates an `os.File` owner before invoking protection and defers its `Close`.
On refusal, that Close completes before `dialUDP` returns; no bind, connect or
`net.FileConn` duplication is reached. In Go 1.27.1, the later observation is:

```text
os.(*rawConn).Control                 src/os/rawconn.go
  -> internal/poll.(*FD).RawControl  src/internal/poll/fd_posix.go
  -> (*FD).incref / errClosing       src/internal/poll/fd_mutex.go, fd.go
  -> poll.ErrFileClosing            *errors.errorString("use of closed file")
```

There is no wrapper or `Unwrap` successor. `os.(*File).wrapErr` normally
translates that sentinel into `os.ErrClosed`, but `rawConn.Control` does not
call it. A standalone real-socket probe confirmed the same result on both
Linux arm64 and Darwin arm64: `errors.Is(err, os.ErrClosed)` is false for
`Control`, while `File.Stat` returns a `*fs.PathError` wrapping `os.ErrClosed`.
Darwin had hidden the faulty assumption by excluding the Linux-tagged test.

The test now compares against the error produced by the identical RawConn
operation on an explicitly closed reference `os.File`. It still requires that
Control never invoke its callback, and still checks exactly one protection
call, pre-bind/pre-connect timing, refusal-error identity, and no returned UDP
connection. It accepts neither arbitrary errors nor matching error strings.
No production overlay, engine/admission logic, build tags or skips changed.

Linux arm64 and Linux amd64 Docker verification passed (the latter using
`docker run --platform linux/amd64` to match the CI runner's architecture):

```sh
bash build.sh test
GOFLAGS="-mod=readonly -modfile=$PWD/build/network.mod -overlay=$PWD/build/overlay/overlay.json" \
  go test -race -shuffle=on -count=100 -timeout=60s -v \
  github.com/metacubex/mihomo/listener/tproxy \
  -run '^TestProximaRawUDPRefusedBeforeBindConnect$'
```

The container mounted the checkout at `/work`, a separate named volume at this
module's `build`, and named volumes for `GOMODCACHE=/go/pkg/mod` and
`GOCACHE=/root/.cache/go-build`; it used the container CA bundle. Host build
staging was not shared. Two isolated generated-overlay mutations also failed
the corrected test at `descriptor still owned`: removing `defer fdFile.Close()`
entirely, and replacing it with `defer syscall.Close(fd)` (kernel close without
closing the original Go owner). Thus the correction still detects both leaked
ownership and an invalid raw-descriptor-only close. These mutations were not
applied to tracked sources.

The repository-root `bash build.sh test` also completed with exit code 0 on
Darwin arm64 / Go 1.27.1, covering all seven native modules and their existing
JNI/JVM, vet and race gates. This host run does not execute the Linux-tagged
test; the Docker executions above provide its runtime evidence. These checks
do not certify approved privileged TProxy forwarding or Android-device behavior.
