#!/bin/bash
# sweep.sh <client package dir> <out dir> (probe-shim-debug only; macOS): FreeRDP.app's client
# started as freerdp-tk starts it (bin/sdl-freerdp, the shim, execs it) against 192.0.2.1
# (TEST-NET-1: the connect hangs), a SIGTERM after a delay swept across the start-up, as
# test/mac-client-shim.sh sends one after 3 s. com.freerdp.core logs at DEBUG
# (WLOG_FILTER=com.freerdp.core:DEBUG), so freerdp_set_last_error_ex's "resetting error state"
# names the function, file and line that clear a CONNECT_CANCELLED. Per run: exec-<delay>.out and
# one line in sweep.txt (ended within 5 s or not, the lines that matter). STRICT=1: exit 1 when a
# run did not end (with a fix pinned). Bash 3.2 is enough.
set -u
PKG=$(cd "$1" && pwd); OUT=$2
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
SHIM=$PKG/bin/sdl-freerdp
stuck=0
for delay in 1.0 1.25 1.5 1.75 2.0 2.25 2.5 2.75 3.0 3.25 3.5; do
    log=$OUT/exec-$delay.out
    WLOG_FILTER=com.freerdp.core:DEBUG "$SHIM" /v:192.0.2.1 /cert:ignore /timeout:30000 > "$log" 2>&1 &
    pid=$!
    sleep "$delay"
    kill -TERM "$pid" 2> /dev/null
    ended=no
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2> /dev/null || { ended=yes; break; }
        sleep 0.5
    done
    [ "$ended" = yes ] || stuck=$((stuck + 1))
    kill -KILL "$pid" 2> /dev/null; wait "$pid" 2> /dev/null
    {
        echo "delay $delay s: ended within 5 s: $ended"
        grep -E 'Caught signal|running it now|sig_abort_connect|abortConnect|resetting error state|already set|ERRCONNECT_|log_build_warn\]: \*{5}' "$log" | sed -n '1,40p' | sed 's/^/    /'
    } >> "$OUT/sweep.txt"
done
echo "sweep: $stuck of 11 runs did not end within 5 s of the SIGTERM" | tee -a "$OUT/sweep.txt"
grep -h 'resetting error state' "$OUT"/exec-*.out | sed 's/^\[[^]]*\] \[[^]]*\] //' | sort | uniq -c | tee "$OUT/resets.txt"
if [ "${STRICT:-0}" = 1 ] && [ "$stuck" -gt 0 ]; then exit 1; fi
exit 0
