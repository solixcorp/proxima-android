This is an isolated socket coverage overlay for Mihomo v1.19.33, commit
`3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8`. It is a migration building block.
Existing application and native build scripts do not consume it.

`bash build.sh test` verifies module checksums, stages a private upstream copy,
validates seven Mihomo and seven TFO source hashes, generates a Go overlay, then
runs vet and actual upstream socket tests under the race detector, including
the new tests inside the upstream dialer package.
`bash build.sh cross` compiles the Linux TProxy and dialer test binaries and the affected
Android arm64 packages. Go 1.27.1 is required. `GOMODCACHE`, `GOCACHE`, and
`SSL_CERT_FILE` may be supplied by the caller; defaults keep caches under build.

The overlay changes these real socket creation paths:

- The inbound listen factory calls `DefaultSocketHook` before bind, with the same
  hook-over-routing-mark policy as the upstream dialer.
- REDIR uses that inbound factory.
- TProxy TCP and UDP listeners call the hook and transparent socket options in
  `net.ListenConfig.Control`, before bind. TCP still disables MPTCP explicitly.
  A control error lets Go close the socket, including transparent option errors.
- Linux TProxy UDP writeback transfers its raw descriptor to one `os.File`
  immediately after creation. It calls protection before socket options, bind,
  or connect. `net.FileConn` duplicates the descriptor on success; the original
  owner closes exactly once on every path. Creation uses `SOCK_CLOEXEC`.
- The dialer retains TFO for TCP when a hook is installed. UDP, UDP4, and UDP6
  retain eager protected dialing and the concrete `net.UDPConn` interfaces.
- Deferred TFO has one dial attempt, broadcasts its result to all waiting I/O,
  and synchronizes connection publication and every observer. Close cancels
  pending work; the dialer closes a successful result that arrives too late
  instead of publishing it. Only one owner closes the underlying connection.
  Failed handshakes are terminal and do not replay early data.
- Successful deferred return transfers lifetime ownership to the connection.
  Caller values reach socket control, but later caller cancellation or deadline
  expiry cannot invalidate the first write. An already-cancelled dial is
  rejected. The establishment timeout starts with the first write.
- Pending read/write deadlines are stored, wake blocked I/O, support extension
  and clearing, and transfer to the established connection before publication.
  Read deadlines affect reads independently. Write deadlines and Close cancel
  in-flight establishment; a late result remains owned and is closed.

The audited TFO dependency is
`github.com/metacubex/tfo-go v0.0.0-20260623020846-376a77860b8c`.
On Linux its `tfo_linux.go` control wrapper invokes the caller control before
`TCP_FASTOPEN_CONNECT`, `net.Dialer.DialContext`, or early writes. The raw socket
path in `tfo_bsd+linux.go` invokes control before bind and `connect`, which wraps
Linux `MSG_FASTOPEN` or Darwin `connectx`. Those files and their dispatch and
listener implementations are checksum gated; upgrading the dependency requires
another source audit. No TFO fallback is added or promise made that a device
kernel supports TFO.

Tests import the real upstream packages with the overlay, plus the existing
session registry. They check unbound/unconnected descriptors during protection,
reject inactive and refusing sessions, verify no loopback TCP connection after
TCP/TFO refusal, verify deferred TFO context ownership and cancellation, exercise approved
UDP, and preserve a virtual custom dialer. Approved and refused UDP dials with
TFO enabled exercise all three UDP network names, immediate address availability,
`syscall.Conn`, `net.PacketConn`, and actual loopback request/reply delivery.
Upstream-package TFO tests use `testing/synctest` and a controlled transport dial
over `net.Pipe` to deterministically overlap first writes, readers, Close,
cancellation, deadlines, and late dial completion. Fake-clock tests cover
post-return caller cleanup, idle time before first write, deadline expiry
before/during establishment, extension/clearing, and transfer to live I/O.
They execute the patched upstream lifecycle; they do not exercise kernel TFO
data delivery. The Linux-only test invokes the real
unexported TProxy `dialUDP` in its upstream package and checks pre-bind refusal
and original descriptor closure without requiring transparent socket privileges.
It runs automatically with `bash build.sh test` on Linux.

Custom virtual WireGuard/OpenVPN/MASQUE/Tailscale/ZeroTier/TUIC/ShadowQUIC dialers
are not rejected or rewritten. Their real outer transports must use protected
socket creation paths; this patch does not certify every transport's coverage.
Interface-query ioctl descriptors are untouched. fakeTCP raw socket capability
requirements (`CAP_NET_RAW`/`CAP_NET_ADMIN`) remain outside scope. Socket
protection does not grant them or make privileged TProxy available on Android.

Integration must install the existing permanent session hook before core work
and must compose this overlay with any other upstream overlays. Duplicate source
paths require deliberate patch composition, not last-writer-wins JSON merging.
The hook must never be cleared during shutdown. This overlay does not add session
generation binding to deferred operations or close already-existing sockets.

The connection remains deferred to preserve early data. Before establishment,
addresses remain empty and `NeedHandshake` is true. A deadline that expires
before any dial begins can be cleared and I/O retried. Once establishment has
started, a timeout is terminal: early data may already have left, so this wrapper
does not replay it or redial. Established connections retain their underlying
deadline behavior. A single owned worker holds a copy of early data so timed-out
or closed Writes can return without retaining the caller's buffer. Cancellation
still reaches the real dial even when a controlled test transport ignores it.
