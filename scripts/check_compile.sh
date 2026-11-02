#!/bin/bash
# Syntax-check ONE source file against the iOS SDK. Nothing is linked, run or written.
# Usage: scripts/check_compile.sh Natives/LauncherProfileEditorViewController.m
# Prints "OK" or the compiler errors. This catches wrong selectors, undeclared names, bad types and bracket
# mistakes. It does NOT prove the behaviour is right and it is not a full build (that is the CI workflow).
set -euo pipefail

SDK="${SDKPATH:-$HOME/ios-toolchain/sdks-modern/iPhoneOS26.2.sdk}"
[ -d "$SDK" ] || { echo "iPhoneOS SDK not found at $SDK (set SDKPATH)" >&2; exit 2; }

FILE="${1:?usage: $0 path/to/file.m}"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
[ -f "$FILE" ] || { echo "No such file: $FILE" >&2; exit 2; }
REAL="$(realpath "$FILE")"
case "$REAL" in "$ROOT"/*) ;; *) echo "Refusing to check a file outside the repository" >&2; exit 2;; esac

case "$FILE" in
    *.m)  LANG_FLAG="objective-c" ;;
    *.mm) LANG_FLAG="objective-c++" ;;
    *.c)  LANG_FLAG="c" ;;
    *) echo "Unsupported file type (use .m, .mm or .c): $FILE" >&2; exit 2 ;;
esac

OUT="$(clang -fsyntax-only -x "$LANG_FLAG" -fobjc-arc -target arm64-apple-ios14.0 -isysroot "$SDK" \
    -include sys/mman.h -include mach/mach.h -Wno-everything -I Natives "$FILE" 2>&1 || true)"
ERRORS="$(printf '%s\n' "$OUT" | grep -E "error:|fatal error:" || true)"
if [ -n "$ERRORS" ]; then
    printf '%s\n' "$OUT" | grep -E -A3 "error:|fatal error:" | head -40
    echo "FAILED: $(printf '%s\n' "$ERRORS" | wc -l | tr -d ' ') error(s) in $FILE"
    exit 1
fi
echo "OK: no compile errors in $FILE"
