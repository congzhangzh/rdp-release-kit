#!/bin/bash
# Checks that a macOS client runs on any Mac with the release's minimum
# macOS or newer:
#
#   check-macos.sh <binary> [max minimum macOS, default 12.0]
#
# - it needs nothing that is not part of macOS itself: only libraries in
#   /usr/lib (libSystem, libc++, ...) and frameworks in /System/Library,
#   no Homebrew or MacPorts dylib and no @rpath library next to it
# - the minimum macOS written into it (LC_BUILD_VERSION) is at most the
#   maximum: the loader refuses to start it on anything older
# - its code signature is valid: Apple Silicon kills an unsigned binary
# Unlike Linux, exported symbols cannot clash: macOS binds each symbol to
# the library it was linked against (two-level namespace), so a shared
# SDL or OpenSSL loaded by something else never resolves to this copy.
set -euo pipefail

BIN=$1
MAX_MINOS=${2:-12.0}
fail=0

# otool -L: the file name, then one "<path> (compatibility ...)" per library
libs=$(otool -L "$BIN" | tail -n +2 | awk '{print $1}')
extra=$(grep -v -E '^(/usr/lib/|/System/Library/)' <<< "$libs" || true)
if [ -n "$extra" ]; then
    echo "FAIL  $BIN needs libraries macOS does not have: ${extra//$'\n'/ }"
    fail=1
else
    echo "ok    needs only macOS's own: ${libs//$'\n'/ }"
fi

# LC_BUILD_VERSION (macOS 10.14+ toolchains), else the older
# LC_VERSION_MIN_MACOSX
minos=$(otool -l "$BIN" | awk '
    /cmd LC_BUILD_VERSION/ { b = 1 } b && $1 == "minos" { print $2; exit }
    /cmd LC_VERSION_MIN_MACOSX/ { v = 1 } v && $1 == "version" { print $2; exit }')
# version_le <a> <b>: a <= b, compared number by number (12.0 < 12.10)
version_le() {
    local IFS=. i
    local -a a b
    read -r -a a <<< "$1"
    read -r -a b <<< "$2"
    for i in 0 1 2; do
        [ "${a[i]:-0}" -lt "${b[i]:-0}" ] && return 0
        [ "${a[i]:-0}" -gt "${b[i]:-0}" ] && return 1
    done
    return 0
}
if [ -z "$minos" ]; then
    echo "FAIL  no minimum macOS in $BIN"
    fail=1
elif ! version_le "$minos" "$MAX_MINOS"; then
    echo "FAIL  needs macOS $minos, more than $MAX_MINOS"
    fail=1
else
    echo "ok    needs macOS $minos at most (limit $MAX_MINOS), $(lipo -archs "$BIN")"
fi

if ! codesign --verify --strict "$BIN" 2> /dev/null; then
    echo "FAIL  no valid code signature (codesign --verify)"
    fail=1
else
    echo "ok    signed ($(codesign -dv "$BIN" 2>&1 | sed -n 's/^Signature=//p'))"
fi
exit $fail
