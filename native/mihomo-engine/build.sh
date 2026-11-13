#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mode="${1:-test}"
case "$mode" in prepare|test|cross|host|android) ;; *) exit 2 ;; esac
export GOTOOLCHAIN=local
[[ "$(go env GOVERSION)" == go1.27.1 ]] || { echo 'Go 1.27.1 required' >&2; exit 1; }
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}"
export GOMODCACHE="${GOMODCACHE:-$PWD/build/go-mod}"
export GOCACHE="${GOCACHE:-$PWD/build/go-cache}"
mkdir -p build
if [[ ! -f build/go.mod ]]; then
    (cd build && go mod init proxima.local/mihomo-engine-build)
fi
go mod download
go mod verify
source="$(go list -m -f '{{.Dir}}' github.com/metacubex/mihomo)"
[[ "$(go list -m -f '{{.Sum}}' github.com/metacubex/mihomo)" == 'h1:hwqYMItk3Jaeq8Sw2PBAtyHQh157ccUtWS7rXrBOMCU=' ]] || exit 1
tfo="$(go list -m -f '{{.Dir}}' github.com/metacubex/tfo-go)"
# Both independent generators see this exact immutable, checksum-verified copy.
stage="$(mktemp -d "$PWD/build/upstream.XXXXXX")"
cp -R "$source/." "$stage/"
cp go.mod build/engine.mod
cp go.sum build/engine.sum
go mod edit -modfile=build/engine.mod -replace="github.com/metacubex/mihomo=$stage"
# Run generators from their own modules, without changing their sources/builds.
root="$PWD"
(cd ../mihomo-provider && go run -mod=readonly ./cmd/overlay "$stage" "$root/build/provider")
(cd ../mihomo-network && go run -mod=readonly ./cmd/overlay "$stage" "$tfo" "$root/build/network")
sing="$(go list -m -f '{{.Dir}}' github.com/metacubex/sing-tun)"
(cd ../mihomo-runtime && go run -mod=readonly ./cmd/overlay "$sing" "$root/build/packet")
go mod edit -modfile=build/engine.mod -replace="github.com/metacubex/sing-tun=$root/build/packet/sing-tun"
go run -mod=readonly ./cmd/overlay "$stage" "$root/build/engine"
MIHOMO_ENGINE_PACKET_OVERLAY="$root/build/packet/overlay.json" go run -mod=readonly ./cmd/compose "$stage" "$PWD/build/overlay.json" "$PWD/build/provider/overlay.json" "$PWD/build/network/overlay.json" "$PWD/build/engine/overlay.json"
export GOFLAGS="-mod=readonly -modfile=$PWD/build/engine.mod -overlay=$PWD/build/overlay.json"
export MIHOMO_ENGINE_TEST_SOURCE="$stage"
if [[ "$mode" == test ]]; then
    # Package-local regressions execute the actual checksum-gated seams, without
    # exporting test entry points from the production core.
    chmod u+w "$stage/component/tls" "$stage/adapter/outboundgroup"
    cp testdata/upstream/proxima_reality_test.go "$stage/component/tls/"
    cp testdata/upstream/proxima_group_test.go "$stage/adapter/outboundgroup/"
    case "$(uname -s)" in
        Darwin) java_home="${JAVA_HOME:-$(/usr/libexec/java_home)}"; platform=darwin ;;
        Linux) java_home="${JAVA_HOME:?Set JAVA_HOME}"; platform=linux ;;
        *) exit 2 ;;
    esac
    export CGO_CFLAGS="-I$java_home/include -I$java_home/include/$platform -Werror=incompatible-pointer-types"
    go vet ./...
    go test -race -shuffle=on -count=1 -timeout=90s -v ./...
    go test -race -shuffle=on -count=1 -timeout=60s -v github.com/metacubex/mihomo/component/tls github.com/metacubex/mihomo/adapter/outboundgroup -run '^TestProxima'
    printf 'Engine raw decoder and real provider stages: vet and race tests exit=0\n'
elif [[ "$mode" == cross ]]; then
    GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build .
    printf 'Engine Android arm64 package compilation exit=0\n'
fi
if [[ "$mode" == test || "$mode" == host || "$mode" == android ]]; then
    source ./jni-build.sh
fi
