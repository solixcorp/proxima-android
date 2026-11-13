# Upstream Mihomo provider safety integration

This standalone Go module patches actual Mihomo v1.19.33 provider I/O. It is a
building block for an Android runtime, not an app integration or a VPN engine.
It contains no JNI entry point, TUN implementation, controller, or startup stub.
No existing native module or Android app file is changed.

## Build and source verification

```sh
cd native/mihomo-provider
bash build.sh
```

Use Go 1.27.1. Downloads use normal certificate verification. On the verification
host, Go needed `SSL_CERT_FILE=/etc/ssl/cert.pem`, the installed system CA bundle;
this does not disable TLS verification.

`upstream.lock` identifies the same commit and module checksum as
`native/mihomo/upstream.lock`. The build checks that module checksum, runs
`go mod verify`, makes a fresh source copy under ignored `build/`, and verifies
the SHA-256 of all eight patched upstream files before producing an overlay.
Go 1.27 forbids overlays inside `GOMODCACHE`, so `build/provider.mod` replaces
Mihomo with that verified copy. The original module cache is never patched.
Every dependency version and checksum is recorded in `go.mod` and `go.sum`.

`build/overlay/overlay.json` is the actual compiler overlay. Every command that
uses this integration must supply that overlay and the generated module file:

```sh
GOFLAGS="-mod=readonly -modfile=$PWD/build/provider.mod -overlay=$PWD/build/overlay/overlay.json" \
  go test -race -shuffle=on -count=1 -timeout=90s ./...
```

An ordinary build without the overlay is **not** this integration. Changing a
source pin requires reviewing the entire corresponding upstream file and its
callers. `cmd/overlay` rejects changed bytes and ambiguous patch anchors.
No protocol-removal build tags are used. This test graph compiles the native
proxy-provider and rule-provider packages, including their protocol dependencies.
Upstream Mihomo is GPL-3.0; its distribution obligations still apply.

## Runtime integration contract

1. At process initialization, call
   `boundary.ConfigureRoot(trustedAppPrivateDirectory)` and check its error.
   The directory must already exist and be chosen by the Android application,
   never by imported configuration. Then call
   `constant.SetHomeDir(trustedAppPrivateDirectory)` with the same path.
   Both steps precede `config.ParseRawConfig` or any provider construction.
2. Build with this overlay. Both `adapter/provider.ParseProxyProvider` and
   `rules/provider.ParseRuleProvider` now preflight raw resource URLs and paths
   before a valid cached provider can bypass network loading. Actual operations
   still use `os.Root`; preflight is not the confinement mechanism.
3. Initialize each resulting provider exactly once and check its `Initial`
   error. Check explicit `Update`/`SideUpdate` errors as well. Do not call
   `executor.ApplyConfig` after initializing providers yourself unless its
   provider-loading path has separately been changed to avoid a second
   initialization. Upstream executor error logging is not a successful start.
4. Stop new calls, close providers, and drain their other workers before
   releasing runtime resources. The patched resource fetcher joins its own
   polling goroutine on `Close`; that does not join health checks or the engine.
   Close the real `cachefile.Cache().DB` if non-nil before final root teardown.
5. `boundary.CloseRoot()` permanently revokes future path opens for this
   process. It cannot revoke descriptors already handed to a database or
   archive. `ConfigureRoot` refuses rebinding even after close. Keep this
   process-wide root open across normal VPN stop/start cycles; close it only
   after all users finish at final teardown.

The boundary package's public integration APIs are `ConfigureRoot` and
`CloseRoot`. `URL`, `CheckPath`, `Open`, `OpenFile`, `ReadFile`, `ReadDir`,
`Stat`, `Chtimes`, `Remove`, `WriteFile`, and `OpenArchive` are the concrete I/O
hooks called by the generated upstream code. `OpenFile` matches
`bbolt.Options.OpenFile`; `OpenArchive` retains sequential multi-volume archive
loading through confined descriptors. The added native HTTP option is
`component/http.WithURLPolicy(func(string) error)`.

## What the overlay changes

- HTTP provider resource requests require HTTPS, a nonempty host, and no URL
  userinfo, both initially and before every redirect. Redirect loops remain
  limited to ten requests. Mihomo's real HTTP transport, certificate validation,
  proxy selection, dialer, request headers, response callbacks, size limit,
  subscription metadata, and ETag/304 handling remain in use.
- File vehicles, HTTP cache writes, initial cached reads, timestamp refreshes,
  bundle directory discovery, archive opening, and each numbered archive volume
  use descriptor-relative `os.Root` operations. Raw traversal and paths outside
  the configured root are rejected even under `cmfa` or `SKIP_SAFE_PATH_CHECK`.
  Relative paths may begin with `./` (including repeated `./` prefixes); raw
  `..` components are rejected before those harmless prefixes are removed.
- The shared native bbolt cache, including ETags and subscription metadata,
  opens through the same root. Corrupt-cache removal is confined too. This also
  confines other users of that shared cache database.
- Provider cache updates parse before writing and publish by same-directory
  atomic rename, using a pinned parent directory and mode `0600`. A final
  symlink is replaced rather than followed; a symlink in a parent directory
  cannot redirect operations outside the root. Files are synced before rename;
  this is not a promise of directory-entry durability across sudden power loss.
- File-provider auto reload uses a one-second confined read/poll loop in place
  of pathname-based fsnotify. This preserves automatic updates, with up to a
  one-second delay and extra reads; transient intermediate versions can be
  coalesced. No external directories are opened for watching. Fetcher `Close`
  cancels and joins that loop. Initial/Close and caller-driven updates still
  need owner serialization. Call `Close` from the owner, never reentrantly from
  that fetcher's `onUpdate` callback.
- Archive parsing stays in the real sevenzip implementation, including split
  `.001`, `.002`, ... archives; archive members are read into the provider
  parser and published through the same cache writer.

The resource vehicle is also used by Mihomo's geodata updater, so that vehicle
inherits the HTTPS and confined-write policy. Other geodata file discovery and
updater lifecycle operations are outside this component.

## Limits

This is not a filesystem sandbox against malicious same-UID code, hard links,
device nodes, bind mounts, or moving an already-open directory out of the root.
The caller must control the app-private directory and serialize configuration
changes. Absolute symlinks are rejected by `os.Root`, including absolute
symlinks pointing back inside the root; ordinary relative in-root links work.

HTTPS policy applies to provider **resource URLs**, not proxy health-check
targets, proxy-server endpoints, DNS, or every HTTP client in the engine.
Socket protection and underlying Android network selection require their own
integration. This module does not install a socket protection hook.

Upstream provider periodic update failures are still logged; the executor still
does not propagate initialization failures. The shared cache still has its
upstream `sync.Once` lifetime and logs initialization failures. Existing fetcher
state access, provider callbacks, health checks, the global tunnel, and arbitrary
concurrent caller-driven updates are not made race-free by joining one loop.
No Android/device, four-ABI, full-engine startup, or complete-engine shutdown
claim is made by these host tests.

The standalone MRS conversion CLI accepts its own input/output paths and is
outside provider runtime loading. It is not a confined file API.
