#!/usr/bin/env bash
# Standalone native gates; deliberately does not build/package the Android app.
set -euo pipefail
cd "$(dirname "$0")"
mode="${1:-test}"
case "$mode" in
    test)
        for module in mihomo mihomo-runtime mihomo-dns mihomo-provider mihomo-network mihomo-engine mihomo-app; do
            bash "native/$module/build.sh" test
        done
        ;;
    android)
        # These shared libraries together compile every native module for each
        # ABI. The engine includes the provider/network/runtime overlays.
        for module in mihomo mihomo-engine mihomo-app; do
            bash "native/$module/build.sh" android
        done
        ;;
    *) printf 'Usage: bash build.sh [test|android]\n' >&2; exit 2 ;;
esac
