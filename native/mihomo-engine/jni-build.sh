# Sourced by build.sh after all checksum-gated overlays have been composed.
export CGO_ENABLED=1
if [[ "$mode" == android ]]; then
    sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
    ndk="${ANDROID_NDK_HOME:-$sdk/ndk/28.2.13676358}"
    grep -q '^Pkg.Revision = 28.2.13676358$' "$ndk/source.properties" || { echo 'Pinned NDK required' >&2; exit 1; }
    case "$(uname -s)" in Darwin) host=darwin-x86_64 ;; Linux) host=linux-x86_64 ;; *) exit 2 ;; esac
    bin="$ndk/toolchains/llvm/prebuilt/$host/bin"
    for spec in arm64-v8a:arm64:aarch64-linux-android armeabi-v7a:arm:armv7a-linux-androideabi x86:386:i686-linux-android x86_64:amd64:x86_64-linux-android; do
        IFS=: read -r abi arch target <<< "$spec"
        mkdir -p "build/android/$abi"
        GOOS=android GOARCH="$arch" GOARM=7 CC="$bin/${target}23-clang" \
            CGO_CFLAGS="-Werror=incompatible-pointer-types" \
            CGO_LDFLAGS="-Wl,-z,max-page-size=16384" \
            go build -trimpath -buildmode=c-shared -o "build/android/$abi/libproxima_mihomo_engine.so" ./cmd/enginebridge
        printf 'Engine Android %s c-shared build exit=0\n' "$abi"
    done
else
    case "$(uname -s)" in
        Darwin) java_home="${JAVA_HOME:-$(/usr/libexec/java_home)}"; platform=darwin; ext=dylib ;;
        Linux) java_home="${JAVA_HOME:?Set JAVA_HOME}"; platform=linux; ext=so ;;
        *) exit 2 ;;
    esac
    export CGO_CFLAGS="-I$java_home/include -I$java_home/include/$platform -Werror=incompatible-pointer-types"
    mkdir -p build/host build/classes build/test-classes
    go build -trimpath -buildmode=c-shared -o "build/host/libproxima_mihomo_engine.$ext" ./cmd/enginebridge
    "$java_home/bin/javac" --release 17 -d build/classes java/kr/kimrasng/proxima/mihomo/NativeEngine.java
    "$java_home/bin/jar" --create --file build/native-engine.jar -C build/classes .
    if [[ "$mode" == test ]]; then
        "$java_home/bin/javac" --release 17 -cp build/classes -d build/test-classes tests/NativeEngineTest.java tests/NativeManagementTest.java
        case "$platform" in darwin) shared=-dynamiclib ;; linux) shared=-shared ;; esac
        "${CC:-cc}" "$shared" -fPIC -I"$java_home/include" -I"$java_home/include/$platform" \
            -o "build/host/libproxima_mihomo_engine_fixture.$ext" tests/packet_fixture.c
        "$java_home/bin/java" --enable-native-access=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED \
             -Djava.library.path="$PWD/build/host" -cp build/classes:build/test-classes NativeEngineTest
        "$java_home/bin/java" --enable-native-access=ALL-UNNAMED \
            -Djava.library.path="$PWD/build/host" -cp build/classes:build/test-classes NativeManagementTest
        printf 'Engine JVM JNI tests exit=0\n'
    fi
fi
