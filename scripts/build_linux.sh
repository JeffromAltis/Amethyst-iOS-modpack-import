#!/bin/bash
# Build the iOS ipa on Linux (clang + ld64.lld + ldid + JDK 8 + an iPhoneOS SDK).
# Output goes to artifacts/, same as the macOS build.
#
# Needs: clang, lld, ldid, cmake, make, jdk8-openjdk, and an iPhoneOS SDK
# (default: ~/ios-toolchain/sdks/iPhoneOS16.5.sdk from theos/sdks).
set -euo pipefail

SDK="${SDKPATH:-$HOME/ios-toolchain/sdks/iPhoneOS16.5.sdk}"
JDK8="${BOOTJDK:-/usr/lib/jvm/java-8-openjdk/bin}"
[ -d "$SDK" ] || { echo "iPhoneOS SDK not found at $SDK (set SDKPATH)" >&2; exit 1; }

cd "$(dirname "$0")/.."

# CMake caches the compiler on first configure; start clean so these flags always apply.
rm -rf Natives/build artifacts

# - target/isysroot: compile for iOS against the SDK (also in CMake's own test compiles)
# - sys/mman.h, mach/mach.h: newer Apple SDKs pull these in implicitly; 16.5 does not
# - Wno-error=...: newer upstream clang errors where Apple clang only warns
FLAGS="-target arm64-apple-ios14.0 -isysroot $SDK -include sys/mman.h -include mach/mach.h \
  -Wno-error=incompatible-pointer-types -Wno-error=incompatible-function-pointer-types -Wno-error=int-conversion"
export CC="clang $FLAGS" CXX="clang++ $FLAGS" OBJC="clang $FLAGS"
# _UISolariumEnabled is iOS 26 only and weak-imported; let it resolve (or not) at runtime.
export LDFLAGS="-fuse-ld=lld -Wl,-U,__UISolariumEnabled"

# ccache reuses objects for source files that did not change, so rebuilds only recompile
# what was edited. It is optional: without it everything is recompiled each time.
if command -v ccache >/dev/null; then
    export CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
    ccache --zero-stats >/dev/null
fi
export SLIMMED="${SLIMMED:-1}"

make -j"$(nproc)" dsym package PLATFORM=2 BOOTJDK="$JDK8" SDKPATH="$SDK"

if command -v ccache >/dev/null; then
    echo "--- ccache ---"
    ccache --show-stats | grep -E 'Hits|Misses|Cacheable' || true
fi
