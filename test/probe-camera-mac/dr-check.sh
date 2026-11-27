#!/bin/bash
# Will an update keep Screen Recording and Accessibility? TCC keys a grant to the program's
# designated requirement (DR), so the proxy is: two different builds, signed the same way, must
# have the same DR, and it must not name the build (a cdhash) but the identity:
#
#   dr-check.sh signed <package A> <package B> <team id>
#   dr-check.sh adhoc  <package A> <package B>
#
# A and B are two host packages signed by sign-mac.sh whose code differs (the probe changes a
# byte of B's Info.plist before signing, which changes every cdhash of the app). Checked for
# the app (the no-root mode's grant) and the agent (the daemon mode's grant).
#  signed: A's and B's DRs are identical, contain identifier "<id>" and
#          certificate leaf[subject.OU] = <team>, and no cdhash; the cdhashes differ (so the
#          two really are different code)
#  adhoc:  prints both DRs: each is cdhash H"..." and they differ, i.e. an ad hoc build is a
#          new program to TCC every time (why each kit update asked again)
set -uo pipefail
MODE=$1; A=$2; B=$3; TEAM=${4:-}
fails=0
check() { if [ "$2" = 1 ]; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi; }
# an ad hoc signature has no explicit requirement: codesign prints the implicit one as a
# comment ("# designated => cdhash H\"...\""), a signed one without the "# "
dr() { codesign -d -r- "$1" 2>&1 | sed -n 's/^#\{0,1\} *designated => //p'; }
# CDHash= only at verbosity 3 (-dvvv)
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1; }
ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$A/FreeRDP-Shadow.app/Contents/Info.plist")

for part in "FreeRDP-Shadow.app:$ID" "FreeRDP-Shadow.app/Contents/MacOS/freerdp-shadow-agent:$ID.agent"; do
    path=${part%%:*}; ident=${part#*:}
    da=$(dr "$A/$path"); db=$(dr "$B/$path")
    ca=$(cdhash "$A/$path"); cb=$(cdhash "$B/$path")
    echo "-- $path"
    [ -n "$da" ] && [ -n "$ca" ] && ok=1 || ok=0
    check "$path: codesign shows a cdhash and a designated requirement" $ok
    echo "   A: cdhash $ca"
    echo "      DR $da"
    echo "   B: cdhash $cb"
    echo "      DR $db"
    [ -n "$ca" ] && [ "$ca" != "$cb" ] && ok=1 || ok=0
    check "$path: A and B are different code (cdhash)" $ok
    if [ "$MODE" = signed ]; then
        [ -n "$da" ] && [ "$da" = "$db" ] && ok=1 || ok=0
        check "$path: the same designated requirement for both builds" $ok
        case $da in *"identifier \"$ident\""*) ok=1 ;; *) ok=0 ;; esac
        check "$path: it names identifier \"$ident\"" $ok
        case $da in *"certificate leaf[subject.OU] = $TEAM"* | *"certificate leaf[subject.OU] = \"$TEAM\""*) ok=1 ;; *) ok=0 ;; esac
        check "$path: it names certificate leaf[subject.OU] = $TEAM" $ok
        case $da in *cdhash*) ok=0 ;; *) ok=1 ;; esac
        check "$path: it names no cdhash" $ok
    else
        case $da in *cdhash*) ok=1 ;; *) ok=0 ;; esac
        check "$path: ad hoc DR is a cdhash (the build itself)" $ok
        [ "$da" != "$db" ] && ok=1 || ok=0
        check "$path: ad hoc DRs differ between builds (TCC asks again)" $ok
    fi
done
exit $((fails > 0))
