#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export GOTOOLCHAIN=local
if [[ "$(go env GOVERSION)" != go1.27.1 ]]; then
    printf 'Go 1.27.1 is required\n' >&2
    exit 1
fi
mkdir -p build
if [[ ! -f build/go.mod ]]; then
    (cd build && go mod init proxima.local/mihomo-provider-build)
fi
export GOCACHE="$PWD/build/go-cache"
export GOMODCACHE="$PWD/build/go-mod"
go mod download github.com/metacubex/mihomo
source="$(go list -m -f '{{.Dir}}' github.com/metacubex/mihomo)"
if [[ "$(go list -m -f '{{.Sum}}' github.com/metacubex/mihomo)" != 'h1:hwqYMItk3Jaeq8Sw2PBAtyHQh157ccUtWS7rXrBOMCU=' ]]; then
    printf 'Mihomo v1.19.33 module checksum mismatch\n' >&2
    exit 1
fi
# Go 1.27 refuses overlays in GOMODCACHE. Stage the verified module without
# editing the module cache, then use a separate generated module file.
go mod verify
stage="$(mktemp -d "$PWD/build/upstream.XXXXXX")"
cp -R "$source/." "$stage/"
cp go.mod build/provider.mod
cp go.sum build/provider.sum
go mod edit -modfile=build/provider.mod -replace="github.com/metacubex/mihomo=$stage"
go run -mod=readonly ./cmd/overlay "$stage" "$PWD/build/overlay"
export GOFLAGS="-mod=readonly -modfile=$PWD/build/provider.mod -overlay=$PWD/build/overlay/overlay.json"
go vet ./...
go test -race -shuffle=on -count=1 -timeout=90s ./...
printf 'Provider safety integration: vet and race tests exit=0\n'
