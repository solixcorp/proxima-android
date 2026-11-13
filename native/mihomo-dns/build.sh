#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export GOTOOLCHAIN=local
if [[ "$(go env GOVERSION)" != go1.27.1 ]]; then
    printf 'Go 1.27.1 is required\n' >&2
    exit 1
fi
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}"
export GOMODCACHE="$PWD/build/go-mod"
export GOCACHE="$PWD/build/go-cache"
go mod download
go mod verify
go vet -mod=readonly ./...
printf 'DNS Go vet exit=0\n'
go test -mod=readonly -race -shuffle=on -count=1 -timeout=90s -v ./...
printf 'DNS actual-core race tests exit=0\n'
