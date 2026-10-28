#!/bin/bash
# The multi-monitor ladder of the web client: for each server, rung 1, the
# one-monitor login (wasm-session.sh), then the rung above it on the same
# kind of server, freerdp-web's All screens test (wasm-session.sh with
# SCREENS=): rung 2 against xrdp with Xorg, rung 3 against GNOME or KDE on
# Wayland through the kit's xrdp and its wlup module. Each rung gets a fresh
# server, and a failing rung does not stop the ones above it, so the
# summary says at once whether a problem is basic (rung 1 fails already) or
# one of several monitors (rung 1 passes, the rung above fails).
#
#   test/screens.sh <page dir> <rdp-gateway.sh> <tests dir> [server ...]
#
# <tests dir> holds the page's tests (freerdp-web's test-screens*.mjs,
# test-connect.mjs, test-keymap.py; the CI's wasm-build puts the pinned
# page's into dist/wasm/tests/). The servers, default all four:
#
#   xrdp-original-xorg   xrdp's upstream release as Debian 13 ships it, Xorg
#   xrdp-xorg            the kit's xrdp, Debian 13, Xorg
#   xrdp-gnome           the kit's xrdp, Fedora 45, GNOME on Wayland
#   xrdp-kde             the kit's xrdp compiled on Arch, KDE Plasma on Wayland
#
# The kit's packages: XRDP_DEBS (default dist/xrdp/debian-13), XRDP_RPMS
# (dist/xrdp/fedora-45, with pipewire-module-xrdp). Anything else wasm-session.sh takes passes
# through (LOCAL_WS_PORT, PODMAN, SERVER_RUN_OPTS ...). Output: every
# rung's log and test output in dist/test/screens/, the summary there as
# summary.md too (and in the CI run's summary).
set -uo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 3 ] || { sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
PAGE=$(cd "$1" && pwd)
GATEWAY=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
TESTS=$(cd "$3" && pwd)
shift 3
LADDER=("$@")
[ ${#LADDER[@]} -gt 0 ] || LADDER=(xrdp-original-xorg xrdp-xorg xrdp-gnome xrdp-kde)
abs() { (cd "$1" 2> /dev/null && pwd) || echo "$1"; }
XRDP_DEBS=$(abs "${XRDP_DEBS:-$KIT/dist/xrdp/debian-13}")
XRDP_RPMS=$(abs "${XRDP_RPMS:-$KIT/dist/xrdp/fedora-45}")
OUT=$KIT/dist/test/screens
rm -rf "$OUT"; mkdir -p "$OUT"

# Known failures: "<server>|<check, as the log names it>|<why>". A rung
# above 1 whose failed checks are all known for its server is KNOWN, not
# FAIL: the summary says so and the job stays green. Every other check of
# that rung still counts, and a known check that passes is a plain pass.
KNOWN=(
    "xrdp-gnome|the session's windows stay on this window's screen|a race in Mutter: when the layout moves the window's monitor, a pending Wayland move takes the monitor under the window's old position, about half the time"
)
# known <server> <log>: the reasons, one per line, when every failed check
# of the log is known for that server; nothing (and status 1) otherwise
known() {
    local server=$1 log=$2 check entry why found reasons=
    local -a fails
    mapfile -t fails < <(sed -n 's/^FAIL \([^ ].*\)/\1/p' "$log")
    [ ${#fails[@]} -gt 0 ] || return 1
    for check in "${fails[@]}"; do
        found=
        for entry in "${KNOWN[@]}"; do
            [ "${entry%%|*}" = "$server" ] || continue
            why=${entry#*|}
            case $check in "${why%%|*}"*) found=${why#*|} ;; esac
        done
        [ -n "$found" ] || return 1
        reasons+="$found"$'\n'
    done
    printf '%s' "$reasons" | sort -u
}

# rung <name> <n> <wasm-session.sh's output dir> <env>...: one rung on a
# fresh server; its log and output kept as <name>-rung<n>, and one line of
# results, "PASS|FAIL|SKIP|KNOWN <what>", printed for the summary
rung() {
    local name=$1 n=$2 dir=$3 log=$OUT/$1-rung$2.log
    shift 3
    echo "== $name, rung $n" >&2
    env "$@" "$KIT/test/wasm-session.sh" "$PAGE" "$GATEWAY" "$PKGS" > "$log" 2>&1
    local status=$?
    cp -r "$dir" "$OUT/$name-rung$n" 2> /dev/null
    grep -E '^(PASS|FAIL|SKIP|NOTE) ' "$log" | sed 's/^/   /' >&2
    if [ "$n" = 1 ]; then
        local counts
        counts=$(sed -n 's/^passed \([0-9]*\), failed \([0-9]*\).*/\1 passed, \2 failed/p' "$log")
        echo "$([ $status = 0 ] && echo PASS || echo FAIL) ${counts:-did not run, see $name-rung$n.log}"
    elif grep -q '^SKIP  ' "$log"; then
        echo "SKIP $(sed -n 's/^SKIP  //p' "$log" | paste -sd ';' - | sed 's/;/; /g')"
    else
        # one entry per test: "screens-separate: 20 checks", "...: 2 of 20 checks failed"
        local tests
        local tests why
        tests=$(sed -n 's/^\(PASS\|FAIL\)  \(screens-[a-z]*: .*\)/\2/p' "$log" | sed 's/^screens-//' | paste -sd ';' - | sed 's/;/; /g')
        if [ $status != 0 ] && [ -n "$tests" ] && why=$(known "$name" "$log"); then
            echo "KNOWN $tests (known failure: $(paste -sd ';' <<< "$why"))"
        else
            echo "$([ $status = 0 ] && echo PASS || echo FAIL) ${tests:-did not run, see $name-rung$n.log}"
        fi
    fi
}

summary=$OUT/summary.md
{
    echo "| server | rung 1: one monitor | All screens | verdict |"
    echo "|---|---|---|---|"
} > "$summary"
status=0
for name in "${LADDER[@]}"; do
    case $name in
    xrdp-original-xorg) server=xrdp PKGS=debian up=2 ;;
    xrdp-xorg) server=xrdp PKGS=$XRDP_DEBS up=2 ;;
    xrdp-gnome) server=xrdp-gnome PKGS=$XRDP_RPMS up=3 ;;
    xrdp-kde) server=xrdp-kde PKGS=$XRDP_RPMS up=3 ;;
    *) echo "screens.sh: no server $name" >&2; exit 2 ;;
    esac
    one=$(rung "$name" 1 "$KIT/dist/test/wasm" SERVER="$server")
    many=$(rung "$name" "$up" "$KIT/dist/test/wasm-screens" SERVER="$server" SCREENS="$TESTS")
    case ${one%% *}/${many%% *} in
    PASS/PASS) verdict="passed" ;;
    PASS/SKIP) verdict="one monitor passed; this page has no All screens test for it" ;;
    PASS/KNOWN) verdict="known failure only, see the All screens column" ;;
    PASS/FAIL) verdict="**several monitors only**: one monitor passes"; status=1 ;;
    FAIL/*) verdict="**basic**: one monitor fails already"; status=1 ;;
    esac
    echo "| $name | ${one#* } | rung $up: ${many#* } | $verdict |" >> "$summary"
done
echo
cat "$summary"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || { echo "### The multi-monitor ladder"; echo; cat "$summary"; } >> "$GITHUB_STEP_SUMMARY"
echo "(logs and screenshots: $OUT)"
exit $status
