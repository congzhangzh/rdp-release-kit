#!/bin/bash
# The server of the demo: one X screen, 2560x720 (two screens' worth, side by side), a clock
# that ticks every tenth of a second on each half, and the kit's FreeRDP shadow server
# (/subsystem:x11) from its Linux host archive, as released: AV1 4:2:0, no AV2 or AVC444.
# The shadow shares one X screen as one desktop: with two Xinerama heads it would share only
# one of them (/monitors:N).
#   server.sh <host archive>      logs in /out
set -euo pipefail
mkdir -p /opt/host && tar -xJf "$1" -C /opt/host --strip-components=1
Xvfb :1 -screen 0 2560x720x24 -nolisten tcp > /out/server-xvfb.log 2>&1 &
for _ in $(seq 50); do DISPLAY=:1 xdpyinfo > /dev/null 2>&1 && break; sleep 0.2; done
export DISPLAY=:1
clock='while :; do date +%H:%M:%S.%1N; sleep 0.1; done'
for x in 0 1280; do
    xterm -geometry 30x5+$((x + 240))+330 -fa "DejaVu Sans Mono" -fs 36 -bg "#14324a" -fg white \
        -title "screen at +$x" -e sh -c "echo screen $((x / 1280 + 1)); $clock" > /dev/null 2>&1 &
done
sleep 1
# its own session bus: nothing outside the container
exec env WLOG_LEVEL=INFO WLOG_FILTER='com.freerdp.codec.av1:DEBUG' dbus-run-session -- \
    /opt/host/bin/freerdp-shadow-cli /subsystem:x11 /bind-address:0.0.0.0 /port:3389 /sec:tls -auth \
    /gfx-av1 /gfx-av2:off -gfx-avc444 > /out/server.log 2>&1
