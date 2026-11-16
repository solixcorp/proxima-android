#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mode="${1:-test}"
case "$mode" in prepare|test|cross) ;; *) exit 2 ;; esac
export GOTOOLCHAIN=local
[[ "$(go env GOVERSION)" == go1.27.1 ]] || { echo 'Go 1.27.1 required' >&2; exit 1; }
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}"
export GOMODCACHE="${GOMODCACHE:-$PWD/build/go-mod}"
export GOCACHE="${GOCACHE:-$PWD/build/go-cache}"
mkdir -p build
if [[ ! -f build/go.mod ]]; then
    (cd build && go mod init proxima.local/mihomo-network-build)
fi
go mod download github.com/metacubex/mihomo github.com/metacubex/tfo-go
go mod verify
source="$(go list -m -f '{{.Dir}}' github.com/metacubex/mihomo)"
tfo="$(go list -m -f '{{.Dir}}' github.com/metacubex/tfo-go)"
# Stage outside the immutable module cache: Go 1.27 rejects cache overlays.
mkdir -p build/upstream
chmod -R u+w build/upstream
cp -R "$source/." build/upstream/
chmod -R u+w build/upstream
cp go.mod build/network.mod
cp go.sum build/network.sum
go mod edit -modfile=build/network.mod -replace="github.com/metacubex/mihomo=$PWD/build/upstream"
go run -mod=readonly ./cmd/overlay "$PWD/build/upstream" "$tfo" "$PWD/build/overlay"
cp testdata/upstream/proxima_socket_linux_test.go build/upstream/listener/tproxy/
cp testdata/upstream/proxima_tfo_test.go build/upstream/component/dialer/
cp testdata/upstream/proxima_tfo_deadline_test.go build/upstream/component/dialer/
export GOFLAGS="-mod=readonly -modfile=$PWD/build/network.mod -overlay=$PWD/build/overlay/overlay.json"
if [[ "$mode" == test ]]; then
    go vet ./...
    go test -race -shuffle=on -count=1 -timeout=60s -v ./...
    go test -race -shuffle=on -count=1 -timeout=60s -v github.com/metacubex/mihomo/component/dialer -run '^TestProxima'
    if [[ "$(go env GOOS)" == linux ]]; then
        go test -race -count=1 -timeout=60s -v github.com/metacubex/mihomo/listener/tproxy -run '^TestProxima'
    fi
    printf 'Network protection vet and actual socket race tests exit=0\n'
elif [[ "$mode" == cross ]]; then
    GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go test -c -o build/tproxy-linux-arm64.test github.com/metacubex/mihomo/listener/tproxy
    GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go test -c -o build/dialer-linux-arm64.test github.com/metacubex/mihomo/component/dialer
    GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build ./integration
    printf 'Linux test binary and Android arm64 packages compile exit=0\n'
fi
