# Mihomo native session foundation

This is a standalone, source-built JNI session and protected-socket component.
It is **not a Mihomo VPN runtime** and is not integrated into the Android app.
The existing service, Gradle dependencies, UI, and engine selection are unchanged.
Loading this library or preparing a session must never set the app to connected.

The separate `native/mihomo-engine` now provides the Phase 1.1 standalone
Start/Stop/Version adapter. Do not load both c-shared libraries into one process:
their independent Go runtimes do not share registries. Engine startup retires
its registry before semantic parsing: its current lease remains usable, but no
replacement Prepare is permitted even after close until the OS process exits.
Ordinary foundation-only leases retain existing close/reprepare behavior. See
`../mihomo-engine/ENGINE.md` for executable limits and the worker-process contract.

The library contains the real upstream Mihomo dialer, with its
`DefaultSocketHook` permanently bound to the app-owned session registry. It does
not contain a fake executor, placeholder TUN implementation, or successful
`start` method. No native binary is checked in.

## Source and build provenance

`upstream.lock` pins Mihomo v1.19.33 to Git commit
`3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8` from
`https://github.com/MetaCubeX/mihomo`. Go module download metadata was checked
against that commit. `go.sum` pins the downloaded module contents; builds use
`-mod=readonly`. The pinned module checksum is
`h1:hwqYMItk3Jaeq8Sw2PBAtyHQh157ccUtWS7rXrBOMCU=`.

The build uses Go 1.27.1, Android NDK 28.2.13676358, and Android API 23. The
Mihomo protobuf replacement is carried into this module because dependency
`replace` directives are not inherited. There are no protocol-removal build tags.
Only the dialer dependency graph is linked, so successfully building this
component does not establish that all full-core protocols support all four ABIs.
Upstream Mihomo is GPL-3.0 licensed; a runtime distribution must comply with its
license and the licenses of its linked dependencies.

Run from this directory:

```sh
bash build.sh test
bash build.sh android
```

`test` builds the host shared library and Java class, runs Go tests with the race
detector and shuffled test order, and exercises JNI in a real JVM. `android`
builds arm64-v8a, armeabi-v7a, x86, and x86_64 separately, failing the command if
any ABI fails. The linker requests 16 KiB ELF segment alignment. Android loading,
APK packaging/alignment, and actual TUN traffic still need device verification.

All outputs and Go build/module caches used by these scripts are confined to
the ignored `native/mihomo/build/` directory. They do not copy libraries into
the app or alter app Gradle configuration. Set `ANDROID_NDK_HOME` to the pinned
NDK when its location differs. Host tests need JDK 17 or newer; Linux needs
`JAVA_HOME`. Source/module downloads require normally verified HTTPS.

## Lifecycle contract

The Java entry point is `kr.kimrasng.proxima.mihomo.NativeSession`. It has no
running or connected property.

1. `prepare(borrowedTunFd, protector)` borrows the application's descriptor for
   the duration of the call and uses native `F_DUPFD_CLOEXEC` to create its own
   duplicate. The caller keeps ownership of the original and must prevent its
   concurrent close/reuse until `prepare` returns. A valid fd 0 is supported.
   A lease does not verify that this descriptor is a TUN.
2. There is at most one prepared lease per process. Preparation, duplication,
   and release are serialized in Go, independently of Java caller threads.
   The protector's JNI global reference stays alive until release.
3. `protectSocket(fd)` returns the actual callback boolean. A Java exception or
   failed JVM attachment returns false. The callback must be exactly the
   Android socket protection operation and must not reenter session methods.
   The corresponding Go hook returns an error if protection fails, if the raw
   socket cannot be accessed, or if no lease is active.
4. `duplicateTun()` transfers another close-on-exec descriptor to its caller.
   A future native engine adapter must close that descriptor on *all* TUN
   startup failures and after TUN shutdown. The bridge deliberately cannot
   close a descriptor whose ownership it transferred. Android callers can
   adopt a transferred descriptor with `ParcelFileDescriptor.adoptFd`.
5. `close()` rejects new protection, drains callbacks already in flight, closes
   the bridge-owned duplicate once, and deletes the JNI global reference on
   an already attached JVM thread (normally the Java `close()` caller).
   If the release environment is unavailable, close reports an error and keeps
   an inactive lease. Protection and descriptor duplication remain denied;
   preparation of a replacement remains blocked. Call `close()` again from
   Java to retry release. Native callers must arrange that attached-thread
   cleanup rather than abandon the lease after the error. No fallible detach
   runs after freeing the callback owner. Close is idempotent after success.
   Stale Java tokens cannot protect through or close a newer lease.
   It does not stop a core, revoke previously protected sockets, or close
   descriptors already transferred by `duplicateTun()`.

The upstream socket hook is installed once at Go package initialization and
never reset to nil on stop. This keeps sockets reaching that hook fail closed
before preparation and after release. Upstream itself bypasses interface-name,
routing-mark, and TCP Fast Open handling when this hook is installed. Those
limitations are explicit; the bridge does not pretend those settings still
take effect.

The integration test uses the actual pinned Mihomo TCP and UDP dialer to prove
that a false protection result becomes a dial/listen error. It uses real host
sockets, not an Android VPN. JNI tests prove callback and descriptor ownership
behavior, not the platform implementation of `VpnService.protect`.

## Required work before runtime integration

The inspected upstream has three contracts that must change before it can
be treated as an Android runtime:

- `listener.ReCreateTun` logs initialization errors and returns no error.
  `executor.ApplyConfig` also returns no error and marks the tunnel running
  after loading. A runtime adapter needs an error-returning startup path,
  complete rollback, and verified native descriptor ownership through
   `sing_tun.New`/sing-tun. This foundation has no TUN startup entry point. The
   separate engine now implements a gated error-returning raw-FD subset; it does
   not make the legacy void APIs safe for arbitrary profiles.
- `executor.loadProvider` logs provider initialization failures.
  `executor.Shutdown` cleans listeners and stores fake-IP state, but does not
  establish a joined shutdown of every provider, health check, resolver,
  updater, existing connection, and background worker. Before a replacement
  lease is prepared, the adapter must stop and join the entire old runtime.
  An old worker creating a new socket *after* replacement would otherwise
  reach the process-wide hook for the new session. Token checking alone
  cannot distinguish that old worker.
- Even calls through Mihomo's dialer can bypass the hook: the pinned
  `component/dialer/dialer.go` delegates directly to a custom `NetDialer` that is
  not `*net.Dialer`, before installing `DefaultSocketHook`. Tailscale and
  ShadowQUIC include such callers. Each custom dialer must be audited before
  integration; delegation does not by itself prove an unprotected OS socket.
  Independent networking in protocol implementations, native libraries, system
  resolver paths, and background HTTP clients also needs a full audit. Binding
  to a chosen Android underlying network is separate from `protect(fd)`.

There is no executor or TUN patch in this foundation. There is also no claim of
full protocol, proxy-group, DNS, routing, provider, or management API support.

## Provider policy and path boundary

`providerpolicy.URL` preserves HTTPS, nonempty-host, and no-userinfo policy.
It must be applied before the first provider request **and every redirect**.
It does not fetch a URL, select a network, or install an HTTP redirect hook.
Certificate verification and protection of all provider sockets remain
mandatory at the eventual networking boundary.

`providerpolicy.Store` confines actual reads and writes using Go's
descriptor-relative `os.Root` operations. It rejects absolute paths, dot
traversal, and symlink escapes at I/O time, including writes through an existing
final symlink. Its root must be a trusted app-private directory. It does not
provide a sandbox against same-UID malicious code, device files, or bind mounts.
The current write operation is not an atomic provider-cache replacement.

These helpers are tested, but **upstream provider I/O is not wired to them**.
The separate `../mihomo-provider` overlay implements equivalent confined runtime
I/O and atomic publication; `../mihomo-engine/PROVIDERS.md` documents its Phase
1.3 engine integration, trusted-root parameter, payload restrictions and joins.
The foundation library itself still does not construct or run providers.
The `cmfa` build mode in the pinned source makes `constant.Path.IsSafePath`
unconditionally succeed. The non-CMFA implementation is only a lexical check;
it does not itself confine symlink resolution at read/write time. Adding a
preflight path check would leave a check/use race. A complete adapter must route
provider reads, writes, cache updates, file watching, and bundle extraction
through confined operations, expose initialization/update failures, and
integrate their worker lifetimes into shutdown. Until then, this component must
not be exposed as supporting arbitrary Mihomo providers.
