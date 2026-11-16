#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

mode="${1:-test}"
case "$mode" in
    test|host|android) ;;
    *) printf 'Usage: bash build.sh [test|host|android]\n' >&2; exit 2 ;;
esac

export GOTOOLCHAIN=local
expected_go=
expected_ndk=
api=
while IFS='=' read -r key value; do
    case "$key" in
        go) expected_go="$value" ;;
        ndk) expected_ndk="$value" ;;
        android_api) api="$value" ;;
    esac
done < upstream.lock
actual_go="$(go env GOVERSION)"
if [[ "$actual_go" != "$expected_go" ]]; then
    printf 'Pinned Go toolchain required: %s (found %s)\n' "$expected_go" "$actual_go" >&2
    exit 1
fi

mkdir -p build
export GOCACHE="${GOCACHE:-$PWD/build/go-cache}"
export GOMODCACHE="${GOMODCACHE:-$PWD/build/go-mod}"
export CGO_ENABLED=1

if [[ "$mode" == android ]]; then
    sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
    ndk="${ANDROID_NDK_HOME:-$sdk/ndk/$expected_ndk}"
    if ! grep -q "^Pkg.Revision = $expected_ndk\$" "$ndk/source.properties"; then
        printf 'Pinned Android NDK required: %s\n' "$expected_ndk" >&2
        exit 1
    fi
    case "$(uname -s)" in
        Darwin) host=darwin-x86_64 ;;
        Linux) host=linux-x86_64 ;;
        *) printf 'Unsupported build host\n' >&2; exit 1 ;;
    esac
    bin="$ndk/toolchains/llvm/prebuilt/$host/bin"
    for spec in \
        arm64-v8a:arm64:aarch64-linux-android \
        armeabi-v7a:arm:armv7a-linux-androideabi \
        x86:x86:i686-linux-android \
        x86_64:amd64:x86_64-linux-android; do
        IFS=: read -r abi arch target <<< "$spec"
        [[ "$arch" != x86 ]] || arch=386
        mkdir -p "build/android/$abi"
        printf 'Building Android %s\n' "$abi"
        if GOOS=android GOARCH="$arch" GOARM=7 \
            CC="$bin/$target$api-clang" \
            CGO_CFLAGS="-Werror=incompatible-pointer-types" \
            CGO_LDFLAGS="-Wl,-z,max-page-size=16384" \
            go build -mod=readonly -trimpath -buildmode=c-shared \
            -o "build/android/$abi/libproxima_mihomo_session.so" ./cmd/sessionbridge; then
            printf 'Android %s build exit=0\n' "$abi"
        else
            status=$?
            printf 'Android %s build exit=%s\n' "$abi" "$status" >&2
            exit "$status"
        fi
    done
    printf 'Built all four ABIs under native/mihomo/build/android; not packaged into app.\n'
    exit 0
fi

case "$(uname -s)" in
    Darwin)
        java_home="${JAVA_HOME:-$(/usr/libexec/java_home)}"
        jni_platform=darwin
        extension=dylib
        ;;
    Linux)
        : "${JAVA_HOME:?Set JAVA_HOME to a JDK 17 or newer}"
        java_home="$JAVA_HOME"
        jni_platform=linux
        extension=so
        ;;
    *) printf 'Unsupported host\n' >&2; exit 1 ;;
esac
export CGO_CFLAGS="-I$java_home/include -I$java_home/include/$jni_platform -Werror=incompatible-pointer-types"
mkdir -p build/host build/classes
"$java_home/bin/javac" --release 17 -d build/classes \
    java/kr/kimrasng/proxima/mihomo/NativeSession.java
go build -mod=readonly -trimpath -buildmode=c-shared \
    -o "build/host/libproxima_mihomo_session.$extension" ./cmd/sessionbridge
printf 'Host JNI build exit=0\n'
"$java_home/bin/jar" --create --file build/native-session.jar -C build/classes .

if [[ "$mode" == test ]]; then
    mkdir -p build/native-test
    cp build/host/libproxima_mihomo_session.h build/native-test/_cgo_export.h
    cc -std=c11 -Wall -Wextra -Werror \
        -I"$java_home/include" -I"$java_home/include/$jni_platform" \
        -Icmd/sessionbridge -Ibuild/native-test \
        tests/release_test.c -o build/native-test/release-test
    build/native-test/release-test
    printf 'JNI release fault tests exit=0\n'
    go vet -mod=readonly ./...
    printf 'Go vet exit=0\n'
    go test -mod=readonly -race -shuffle=on -count=1 -timeout=60s ./...
    printf 'Go race tests exit=0\n'
    mkdir -p build/test-classes
    "$java_home/bin/javac" --release 17 -cp build/classes -d build/test-classes \
        tests/NativeSessionTest.java
    "$java_home/bin/java" --enable-native-access=ALL-UNNAMED \
        --add-opens=java.base/java.io=ALL-UNNAMED \
        -Djava.library.path="$PWD/build/host" \
        -cp build/classes:build/test-classes NativeSessionTest
    printf 'JVM JNI tests exit=0\n'
fi
