#!/bin/bash
# bin/sdl-freerdp is a shell script that execs FreeRDP.app's client (build/macos/client-shim.sh):
# old command lines must behave as before. On the macOS runner:
#
#   check-shim.sh <client package dir (unpacked sdl3-freerdp-*-macos-arm64)> <out dir>
#
# - --version, /help and /buildconfig: the same exit code and the same stdout through the shim as
#   from the app's binary itself (run by the very path the shim execs, so argv[0] is the same)
# - a bad option: the client's own non-zero exit code comes through
# - exec, not a child: the pid the caller started is the client's (what freerdp-tk kills)
# - through a symlink to the shim (a PATH folder): the same as above
# - the process that macOS holds responsible (TCC asks for its permission): printed, INFO only;
#   from a shell it is the shell's (Terminal's, for a user), as the README says
# Bash 3.2 is enough.
set -u
PKG=$(cd "$1" && pwd); OUT=$2
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
SHIM=$PKG/bin/sdl-freerdp
REAL=$PKG/bin/../FreeRDP.app/Contents/MacOS/sdl-freerdp
fails=0
check() { if [ "$2" = 1 ]; then echo "PASS  $1${3:+  ($3)}"; else echo "FAIL  $1${3:+  ($3)}"; fails=$((fails + 1)); fi; }

file "$SHIM" | tee "$OUT/shim-file.txt"
head -c 2 "$SHIM" | grep -q '#!' && ok=1 || ok=0
check "bin/sdl-freerdp is a script (the shim), the client is in FreeRDP.app" $ok

same() {  # same <name> <shim> <args...>: exit code and stdout of the shim and of the binary
    local name=$1 shim=$2; shift 2
    "$shim" "$@" > "$OUT/$name.shim.out" 2> "$OUT/$name.shim.err"; local rs=$?
    "$REAL" "$@" > "$OUT/$name.real.out" 2> "$OUT/$name.real.err"; local rr=$?
    [ "$rs" = "$rr" ] && cmp -s "$OUT/$name.shim.out" "$OUT/$name.real.out" && ok=1 || ok=0
    check "$name: exit $rs (binary $rr), stdout $(wc -c < "$OUT/$name.shim.out" | tr -d ' ') bytes, the same" $ok
    LAST_RC=$rs
}
same version "$SHIM" --version
check "--version exits 0" "$([ "$LAST_RC" = 0 ] && echo 1 || echo 0)"
same help "$SHIM" /help
check "/help exits 0" "$([ "$LAST_RC" = 0 ] && echo 1 || echo 0)"
same buildconfig "$SHIM" /buildconfig
grep -q "CHANNEL_RDPECAM_CLIENT=ON\|WITH_CHANNEL_RDPECAM_CLIENT\|RDPECAM" "$OUT/buildconfig.shim.out" &&
    echo "INFO  the client's build has the camera channel: $(tr ' ' '\n' < "$OUT/buildconfig.shim.out" | grep -i rdpecam | tr '\n' ' ')"
same badoption "$SHIM" /no-such-option-at-all
check "a bad option exits non-zero through the shim" "$([ "$LAST_RC" != 0 ] && echo 1 || echo 0)"

# exec: the pid started is the client's own (192.0.2.1 is TEST-NET-1: the connect hangs)
"$SHIM" /v:192.0.2.1 /cert:ignore /timeout:30000 > "$OUT/exec.out" 2>&1 &
pid=$!
sleep 3
comm=$(ps -o comm= -p "$pid" 2> /dev/null)
case $comm in *FreeRDP.app/Contents/MacOS/sdl-freerdp | sdl-freerdp) ok=1 ;; *) ok=0 ;; esac
check "exec: pid $pid is the client itself, not a shell" $ok "$comm"
# the log is this user's file, on purpose
# shellcheck disable=SC2024
sudo launchctl procinfo "$pid" > "$OUT/procinfo.txt" 2>&1 || true
echo "INFO  responsible process (TCC): $(grep -i -m2 'responsible' "$OUT/procinfo.txt" | tr -s ' \t\n' ' ')"
kill -TERM "$pid" 2> /dev/null
for _ in 1 2 3 4 5; do kill -0 "$pid" 2> /dev/null || break; sleep 1; done
kill -0 "$pid" 2> /dev/null && ok=0 || ok=1
check "a SIGTERM to that pid ends the client (what freerdp-tk sends)" $ok
kill -KILL "$pid" 2> /dev/null; wait "$pid" 2> /dev/null

# through a symlink, as a PATH folder may hold it
mkdir -p "$OUT/path-dir"
ln -sf "$SHIM" "$OUT/path-dir/sdl-freerdp"
same symlink-version "$OUT/path-dir/sdl-freerdp" --version
echo "shim: $fails failure(s)"
exit $((fails > 0))
