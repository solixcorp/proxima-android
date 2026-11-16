# Verification evidence

Recorded November 9, 2026 on Darwin arm64 with Go 1.27.1.

Command, from `native/mihomo-runtime/`:

```sh
bash build.sh test
```

The review-fix run exited **0**. The terminal merged stdout and stderr; no
compiler/vet diagnostics or data-race warnings appeared. The single error-level
line below is the deliberate EIO injection and is expected.

```text
all modules verified
Checksum verified; generated joined-packet-loop overlay
Runtime Go vet exit=0
-test.shuffle 1794205658959302000
=== RUN   TestBorrowedFDZero
--- PASS: TestBorrowedFDZero (1.02s)
=== RUN   TestRejectUnsupportedStackAndUnsafeDescriptors
--- PASS: TestRejectUnsupportedStackAndUnsafeDescriptors (0.00s)
=== RUN   TestPersistentPacketReadErrorTerminatesActualCoreLoop
time="2026-11-09T15:27:39.980733000+09:00" level=error msg="read packet: input/output error"
--- PASS: TestPersistentPacketReadErrorTerminatesActualCoreLoop (0.00s)
=== RUN   TestActualMihomoPacketRoundTrip
--- PASS: TestActualMihomoPacketRoundTrip (0.00s)
=== RUN   TestStopDrainsAdmittedTCPAndRejectsLateCalls
--- PASS: TestStopDrainsAdmittedTCPAndRejectsLateCalls (0.00s)
=== RUN   TestActualCoreStartupFailuresRollback
=== RUN   TestActualCoreStartupFailuresRollback/construct_mips_stack1500
=== RUN   TestActualCoreStartupFailuresRollback/start_mips_stack1
=== RUN   TestActualCoreStartupFailuresRollback/start_mips_stack65536
--- PASS: TestActualCoreStartupFailuresRollback (0.00s)
    --- PASS: TestActualCoreStartupFailuresRollback/construct_mips_stack1500 (0.00s)
    --- PASS: TestActualCoreStartupFailuresRollback/start_mips_stack1 (0.00s)
    --- PASS: TestActualCoreStartupFailuresRollback/start_mips_stack65536 (0.00s)
=== RUN   TestConcurrentStopPreservesBorrowedAndReusedFD
--- PASS: TestConcurrentStopPreservesBorrowedAndReusedFD (0.00s)
=== RUN   TestCallerCanCloseBorrowedAliasAfterStartup
--- PASS: TestCallerCanCloseBorrowedAliasAfterStartup (0.00s)
=== RUN   TestCloseWhileActualPacketHandlerIsActive
--- PASS: TestCloseWhileActualPacketHandlerIsActive (0.00s)
PASS
ok  	proxima.local/mihomo-runtime	2.997s
-test.shuffle 1794205658263618000
=== RUN   TestRejectDifferentSource
--- PASS: TestRejectDifferentSource (0.00s)
PASS
ok  	proxima.local/mihomo-runtime/cmd/overlay	1.271s
Runtime actual-core race tests exit=0
```

The initial run also checked `bash -n build.sh` and `gofmt -l` on its four Go
source/test files, with no output. The review-fix source and two new test files
were formatted with gofmt before the successful run above.

The packet test uses a nonprivileged local datagram socket pair to carry an
actual IPv4/UDP packet through the pinned mips stack and actual Mihomo handler,
then checks the response emitted by the real stack. The caller tunnel is a
test sink, not an implementation of proxy protocols or a substitute executor.
The TCP stop test exercises the actual Mihomo handler using a local `net.Pipe`;
it does not prove a TCP handshake through an Android TUN.

Actual constructor failure uses an invalid congestion controller. Actual Start
failures use MTU 1 and 65536. Each error is propagated with the failed stage,
returns no session, releases the duplicated fd, and leaves the borrowed fd open.
Stop tests cover a blocked packet read, 32 concurrent Close callers, reused fd
numbers, admitted TCP handler draining, and rejected late TCP/UDP delivery.
The fd-zero case runs in a separate test process. The caller-alias case closes
the borrowed alias after startup and then successfully delivers a packet.

The independent review's two medium findings are now covered:

- `TestPersistentPacketReadErrorTerminatesActualCoreLoop` starts the real
  pinned stack and Mihomo handler with an event-gated failing device. It
  releases one EIO, waits for read-loop completion, checks the retained cause,
  and requires exactly one read. A second read signals failure and blocks
  until cleanup, preventing a regression from flooding the test log. No
  fake stack, timing sleep, or successful recovery path substitutes for the core.
- `TestCloseWhileActualPacketHandlerIsActive` sends a real IPv4/UDP packet
  through OpenBorrowed and holds the actual synchronous callback. An otherwise
  blocked descriptor read reports the Close interruption while that callback
  remains active. The callback attempts real WriteBack during stack teardown,
  accepting only success or the documented closed error. Close must wait for
  callback release, publish read-loop completion, preserve the shutdown read
  cause, and leave the borrowed fd open. All synchronization uses channel events
  and bounded failure deadlines, with no sleeps or scheduler polling.

`Session.ReadDone` is an input-loop event, not a complete runtime-stop event.
The owner must react to unexpected input termination by calling Close and
stopping its external workers. `ReadError` preserves the original input cause;
normal shutdown may report os.ErrClosed. The new policy covers this component's
generic raw-device path only. Specialized batch paths and write-side health
monitoring are not added. This evidence does not prove every possible packet
interleaving or Android device behavior.

Earlier failed verification attempts were resolved, not suppressed:

- Go rejected an overlay directly beneath GOMODCACHE. The generator now stages
  the verified module and uses a generated modfile plus overlay.
- Go's `./...` scan included the generated replacement as a standalone package.
  A generated module boundary now excludes those build artifacts.
- Darwin kqueue accepted a regular file as pollable. The implementation now
  checks descriptor type before checking interruptible I/O. The original
  rejection test remains and passes.

Scope not verified: Android compilation/loading/devices, live VPN networking,
full TCP/IP conformance, other stacks, protocols, configuration/providers,
synthetic VPN DNS, socket protection inside the supplied caller tunnel, or a
joined shutdown of the complete core. This component opens no outbound network
socket; all packet I/O uses the supplied descriptor. No credentials or privileged
devices were accessed, and no Git commit was created.
