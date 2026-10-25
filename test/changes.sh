#!/bin/bash
# the checks are strings that check() evaluates
# shellcheck disable=SC2016,SC2034
# Tests build/changes.sh on a throwaway repository: a push that only moves
# the freerdp_web pin builds the web client alone ("web"); anything else, or
# an unknown base, builds everything ("all").
#
#   test/changes.sh
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

cd "$TMP" || exit 1
git init -q && git config user.email t@example.com && git config user.name t
lock() { # freerdp_web version, freerdp version -> sources.lock
    printf '# pins\nfreerdp     %s git+https://example.com/FreeRDP.git %040d\nfreerdp_web %s git+https://example.com/web.git %040d\n' \
        "$2" 1 "$1" 2 > sources.lock
}
commit() { git add -A && git commit -q -m "$1" && git rev-parse HEAD; }
scope() { "$KIT/build/changes.sh" "$1" "$2"; }

lock 1 1; mkdir -p build docs; echo a > build/x.sh; base=$(commit base)
lock 2 1; web=$(commit "web pin")
check "only the freerdp_web pin: web" '[ "$(scope "$base" "$web")" = web ]'
lock 2 2; fr=$(commit "freerdp pin")
check "the freerdp pin: all" '[ "$(scope "$web" "$fr")" = all ]'
check "both pins in one push: all" '[ "$(scope "$base" "$fr")" = all ]'
lock 3 2; printf '# a comment\n' >> sources.lock; echo n > docs/n.md; echo r > README.md
wd=$(commit "web pin, a comment, docs")
check "the web pin with comments and docs: web" '[ "$(scope "$fr" "$wd")" = web ]'
lock 4 2; echo b > build/x.sh; wb=$(commit "web pin and a build script")
check "the web pin and a build script: all" '[ "$(scope "$wd" "$wb")" = all ]'
check "no base (a new branch): all" '[ "$(scope 0000000000000000000000000000000000000000 "$wb")" = all ]'
check "a base this clone lacks (a force-push): all" '[ "$(scope 1234567890abcdef1234567890abcdef12345678 "$wb")" = all ]'
check "no arguments: all" '[ "$(scope "" "$wb")" = all ]'

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
