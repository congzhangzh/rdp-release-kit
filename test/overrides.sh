#!/bin/bash
# the checks are strings that check() evaluates, $out included
# shellcheck disable=SC2016,SC2034
# Tests the local source overrides (build/overrides.sh) without building:
# what they mount, which files they take from a checkout, and that CI and
# a v* tag refuse them.
#
#   test/overrides.sh
set -uo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
check() {
    if eval "$2"; then
        echo "PASS  $1"; pass=$((pass + 1))
    else
        echo "FAIL  $1"; fail=$((fail + 1))
    fi
}

# a kit of its own: sources.local is read next to sources.lock
mkdir -p "$TMP/kit/build" "$TMP/work"
cp "$KIT/sources.lock" "$TMP/kit/"
cp "$KIT/build/overrides.sh" "$TMP/kit/build/"
# a checkout with a tracked file, a new one and an ignored build tree
src=$TMP/FreeRDP
git init -q "$src"
mkdir -p "$src/libfreerdp" "$src/build"
echo 'int a;' > "$src/libfreerdp/a.c"
echo build/ > "$src/.gitignore"
git -C "$src" add -A
git -C "$src" -c user.name=t -c user.email=t@example.com commit -q -m one
echo 'int b;' > "$src/libfreerdp/b.c"
echo junk > "$src/build/CMakeCache.txt"

# run <environment...>: overrides() in a clean shell; its options on stdout
run() {
    env -i PATH="$PATH" HOME="$HOME" KIT="$TMP/kit" "$@" bash -c \
        '. "$KIT/build/overrides.sh"; overrides "$1" && printf "%s\n" "${OVERRIDE[@]}"' \
        _ "$TMP/work"
}

out=$(run 2>&1)
check "no override: no options" '[ -z "$out" ]'

out=$(run SRC_freerdp="$src" 2>&1)
check "SRC_freerdp mounts the checkout read-only" \
    'grep -qx -- "$src:/override/freerdp:ro" <<< "$out"'
check "the MANIFEST label is the folder name and commit, not the path" \
    'grep -qE "^OVERRIDE_freerdp=FreeRDP \([0-9a-f]{12}-dirty\)$" <<< "$out"'
check "the file list has the tracked and the new file" \
    '[ "$(sort "$TMP/work/override/freerdp.list" | tr "\n" " ")" = ".gitignore libfreerdp/a.c libfreerdp/b.c " ]'
check "the file list leaves out the ignored build tree" \
    '! grep -q "^build/" "$TMP/work/override/freerdp.list"'

echo "freerdp dir $src" > "$TMP/kit/sources.local"
out=$(run 2>&1)
check "sources.local works like SRC_<name>" 'grep -qx -- "OVERRIDES=freerdp" <<< "$out"'
out=$(run SRC_freerdp="$TMP" 2>&1)
check "SRC_<name> wins over sources.local" 'grep -qx -- "$TMP:/override/freerdp:ro" <<< "$out"'
echo "freerdp git $src" > "$TMP/kit/sources.local"
check "sources.local: a kind other than dir is refused" '! run > /dev/null 2>&1'
rm "$TMP/kit/sources.local"

# the guards: an override must never reach CI or a release
check "CI=true refuses an override" '! run CI=true SRC_freerdp="$src" > /dev/null 2>&1'
check "a v* tag refuses an override" \
    '! run GITHUB_REF=refs/tags/v2026.10.0 SRC_freerdp="$src" > /dev/null 2>&1'
check "CI=true without an override still builds" 'run CI=true > /dev/null 2>&1'
check "a missing directory is refused (docker -v would create it)" \
    '! run SRC_freerdp="$TMP/nowhere" > /dev/null 2>&1 && [ ! -e "$TMP/nowhere" ]'
check "a name not in sources.lock is refused" '! run SRC_freerpd="$src" > /dev/null 2>&1'

# LTO=off, checked by build.sh itself before any container runs (ENGINE=true
# makes the container steps no-ops)
lto() {
    env -i PATH="$PATH" HOME="$HOME" ENGINE=true WORK="$TMP/work" CCACHE=off "$@" \
        "$KIT/build.sh" "$TMP/out" > /dev/null 2>&1
}
check "build.sh: LTO=off with a local FreeRDP is accepted" 'lto LTO=off SRC_freerdp="$src"'
check "build.sh: LTO=off without a local FreeRDP is refused" '! lto LTO=off'
check "build.sh: LTO=off with only a local freerdp_preview is refused" \
    '! lto LTO=off SRC_freerdp_preview="$src"'
check "build.sh: LTO=on is refused (off is the only setting)" '! lto LTO=on SRC_freerdp="$src"'
check "build.sh: CI=true refuses an override" '! lto CI=true SRC_freerdp="$src"'

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
