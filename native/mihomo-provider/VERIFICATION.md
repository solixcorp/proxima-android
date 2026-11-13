# Provider integration verification

Verified on November 9, 2026, on Darwin arm64 with Go 1.27.1. All work and
generated artifacts are confined to `native/mihomo-provider/`.

## Reproducible host gate

```sh
SSL_CERT_FILE=/etc/ssl/cert.pem bash build.sh
```

The CA variable selects the host's installed certificate bundle. Certificate
verification remains enabled. The command completed with exit code 0:

```text
all modules verified
Verified 8 Mihomo v1.19.33 source checksums; generated .../build/overlay/overlay.json
ok  proxima.local/mihomo-provider/boundary
ok  proxima.local/mihomo-provider/cmd/overlay
ok  proxima.local/mihomo-provider/integration
Provider safety integration: vet and race tests exit=0
```

The gate uses `go vet` and `go test -race -shuffle=on -count=1 -timeout=90s`.
No test is skipped, and no protocol-removal build tag is used.

The same integration suite also passed with `-tags=cmfa`, proving confinement
survives upstream's disabled lexical safe-path check. The pinned
`mvdan.cc/gofumpt@v0.8.0 -l boundary cmd integration` formatter check returned
no unformatted files. Both checks completed with exit code 0:

```text
ok  proxima.local/mihomo-provider/integration
CMFA confinement and format checks exit=0
```

## Behavior exercised

- Real upstream `HTTPVehicle.Read` rejects initial HTTP, userinfo, empty-host,
  and non-HTTP-scheme URLs before sending; rejects HTTPS downgrade and userinfo
  redirects; retains HTTPS redirects, configured headers, response size limits,
  persistent ETags and 304 responses; rejects an untrusted TLS certificate;
  stops redirect loops after ten requests.
- Both native provider parsers reject an unsafe resource URL even when a valid
  cache exists, and reject raw traversal and outside-root paths.
- Real `FileVehicle` reads reject absolute escapes and final/parent symlink
  escapes. Writes cannot follow an escaping parent and atomically replace a
  final symlink without overwriting its target.
- Real fetcher initialization reads its confined cache; parse failure leaves
  the previous cache intact; timestamp refresh cannot modify an outside file;
  file-provider automatic reload produces the updated contents.
- Reads and writes race against repeated symlink replacement without exposing
  outside bytes or creating an outside cache file.
- Real sevenzip bundle extraction publishes the expected archive member into
  the provider cache, rejects an escaping archive, and supports split volumes.
- The actual upstream cache singleton rejects an escaping database path. Its
  initialization is tested in a separate process because upstream uses
  `sync.Once`; no reset method was added to production code.
- Root operations fail before configuration and after close. Rebinding is
  refused. Overlay generation rejects modified source bytes and ambiguous
  replacement anchors.

## Negative controls

Temporary changes were made only to generated overlay output, then removed by
regenerating from the checksum-verified source. Both negative-control commands
exited 1 for the intended assertions:

1. Bypassing the HTTP policy and using `os.ReadFile` in the upstream vehicle
   caused the initial URL, redirect, and escaping-read tests to fail. The
   redirect with userinfo reached the local target; an outside fixture's
   `"private"` bytes became observable.
2. Bypassing confined writes, timestamp changes, bbolt opening, and raw URL
   preflight caused the parent-symlink write, final-symlink target preservation,
   timestamp, cache, and cached-provider URL tests to fail. Both native parsers
   incorrectly accepted the cached unsafe URL under that mutation.

The successful host gate above regenerated all eight overlay files after those
negative controls. No mutation remains in shipped source or generated output.

## Review boundaries

Production additions separate root capabilities, atomic cache publication,
archive descriptor ownership, and source transformation. No test-only API,
fake provider, TLS bypass, successful engine-start stub, or protocol-pruning
tag was added. Every handwritten Go source file is under 200 nonblank,
noncomment lines.

`golangci-lint` and `nilaway` were not installed and were not run. The observed
static diagnostic gate is `go vet`; the observed dynamic gate is Go's race
detector and the integration suite.

These host results do not verify Android packaging, devices, four ABIs,
VpnService socket protection, full-engine lifecycle, provider health-check
shutdown, or arbitrary concurrent use of upstream provider state. The precise
owner/lifetime requirements and remaining upstream limitations are in README.md.

## Review follow-up: leading `./` paths

The independent review's HIGH compatibility finding was reproduced before the
fix: all eight native parser cases failed with `ErrPath` (proxy/rule providers,
file/HTTP vehicles, and single/repeated `./` prefixes).

The boundary now strips only leading `./` prefixes after checking the raw path
for forbidden `..` components and backslashes. It does not clean away traversal.
Actual I/O continues through the same `os.Root` operations.

The new positive cases parse real upstream providers and use their returned
vehicles to write to the expected confined cache. Additional parser cases reject
dot-prefixed traversal and escaping symlinks for both file and HTTP vehicles.

After the fix, formatting, `bash build.sh` (module/source verification, vet,
shuffled race tests), and the integration suite with `-tags=cmfa -race` all
completed with exit code 0:

```text
Provider safety integration: vet and race tests exit=0
ok  proxima.local/mihomo-provider/integration
Dot-prefix compatibility and CMFA confinement exit=0
```

Only `boundary/root.go`, `integration/parsers_test.go`, README.md, and this
verification record changed for the review fix, plus ignored build outputs.
The source checksum pins and upstream transformations did not change.
