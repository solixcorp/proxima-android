#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mode="${1:-test}"
case "$mode" in
    test|prepare) ;;
    *) printf 'Usage: bash build.sh [prepare|test]\n' >&2; exit 2 ;;
esac
export GOTOOLCHAIN=local
if [[ "$(go env GOVERSION)" != go1.27.1 ]]; then
    printf 'Go 1.27.1 is required\n' >&2
    exit 1
fi
# Use an existing caller trust override, otherwise the verified system bundle.
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}"
export GOCACHE="$PWD/build/go-cache"
export GOMODCACHE="$PWD/build/go-mod"
mkdir -p build/overlay
go mod download github.com/metacubex/mihomo github.com/metacubex/sing-tun
go mod verify
go run -mod=readonly ./cmd/overlay \
    "$GOMODCACHE/github.com/metacubex/sing-tun@v0.4.28" "$PWD/build/overlay"
if [[ "$mode" == test ]]; then
    go vet -mod=readonly -modfile="$PWD/build/overlay/runtime.mod" \
        -overlay="$PWD/build/overlay/overlay.json" ./...
    printf 'Runtime Go vet exit=0\n'
    go test -mod=readonly -modfile="$PWD/build/overlay/runtime.mod" \
        -overlay="$PWD/build/overlay/overlay.json" \
        -race -shuffle=on -count=1 -timeout=90s -v ./...
    printf 'Runtime actual-core race tests exit=0\n'
fi
