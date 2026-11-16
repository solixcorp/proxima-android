#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mode="${1:-test}"
case "$mode" in prepare|test|host|android) ;; *) exit 2 ;; esac
export GOTOOLCHAIN=local
[[ "$(go env GOVERSION)" == go1.27.1 ]] || { echo 'Go 1.27.1 required' >&2; exit 1; }
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}"
export GOMODCACHE="${GOMODCACHE:-$PWD/build/go-mod}"
export GOCACHE="${GOCACHE:-$PWD/build/go-cache}"
mkdir -p build
go mod download
go mod verify
[[ "$(go list -m -f '{{.Sum}}' github.com/metacubex/mihomo)" == 'h1:hwqYMItk3Jaeq8Sw2PBAtyHQh157ccUtWS7rXrBOMCU=' ]] || exit 1
sing="$(go list -m -f '{{.Dir}}' github.com/metacubex/sing-tun)"
# Only the reviewed packet-loop overlay is needed by this DNS-only graph.
# Do not merge provider/network overlays opportunistically: there is no
# executor, arbitrary networking or provider initialization in this diagnostic.
out="$PWD/build/packet"
(cd ../mihomo-runtime && go run -mod=readonly ./cmd/overlay "$sing" "$out")
cp go.mod build/app.mod
cp go.sum build/app.sum
go mod edit -modfile=build/app.mod -replace="github.com/metacubex/sing-tun=$out/sing-tun"
export GOFLAGS="-mod=readonly -modfile=$PWD/build/app.mod -overlay=$out/overlay.json"
if [[ "$mode" == prepare ]]; then exit 0; fi
export CGO_ENABLED=1
if [[ "$mode" == android ]]; then
    sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
    ndk="${ANDROID_NDK_HOME:-$sdk/ndk/28.2.13676358}"
    [[ -f "$ndk/source.properties" ]] || { echo 'Pinned NDK is missing' >&2; exit 1; }
    case "$(uname -s)" in Darwin) host=darwin-x86_64 ;; Linux) host=linux-x86_64 ;; *) exit 2 ;; esac
    bin="$ndk/toolchains/llvm/prebuilt/$host/bin"
    for spec in arm64-v8a:arm64:aarch64-linux-android armeabi-v7a:arm:armv7a-linux-androideabi x86:386:i686-linux-android x86_64:amd64:x86_64-linux-android; do
        IFS=: read -r abi arch target <<< "$spec"
        mkdir -p "build/android/$abi"
        GOOS=android GOARCH="$arch" GOARM=7 CC="$bin/${target}23-clang" \
            CGO_CFLAGS="-Werror=incompatible-pointer-types" \
            CGO_LDFLAGS="-Wl,-z,max-page-size=16384" \
            go build -trimpath -buildmode=c-shared -o "build/android/$abi/libproxima_mihomo_diagnostics.so" ./cmd/diagnostics
        printf 'Diagnostic Android %s c-shared build exit=0\n' "$abi"
    done
    exit 0
fi
case "$(uname -s)" in
    Darwin) java_home="${JAVA_HOME:-$(/usr/libexec/java_home)}"; platform=darwin; ext=dylib ;;
    Linux) java_home="${JAVA_HOME:?Set JAVA_HOME}"; platform=linux; ext=so ;;
    *) exit 2 ;;
esac
export CGO_CFLAGS="-I$java_home/include -I$java_home/include/$platform -Werror=incompatible-pointer-types"
mkdir -p build/host build/classes
go build -trimpath -buildmode=c-shared -o "build/host/libproxima_mihomo_diagnostics.$ext" ./cmd/diagnostics
"$java_home/bin/javac" --release 17 -d build/classes java/kr/kimrasng/proxima/mihomo/NativeDiagnostics.java
printf 'Diagnostic host c-shared and Java builds exit=0\n'
if [[ "$mode" == test ]]; then
    go vet ./...
    go test -race -shuffle=on -count=1 -timeout=90s -v ./...
    printf 'Integrated packet/DNS/protection race tests exit=0\n'
fi
