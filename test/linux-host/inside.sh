#!/bin/bash
# The Linux host's checks, inside its test bed (test/linux-host/Dockerfile), as root:
#
#   inside.sh gnome     GNOME Shell headless (systemd is PID 1), the server as the
#                       user unit the package ships, installed as its README says
#   inside.sh xorg      Xfce on Xvfb (no systemd), the server with the unit's
#                       arguments and /subsystem:x11
#
# Mounted by test/linux-host.sh: /host.tar.xz (the host), /client.tar.xz (the kit's
# Linux client), /out (logs, screenshots). The client runs as root on an Xvfb of its
# own; the desktop and the server as the user tester, whose password is set here.
# check() evaluates its condition itself: single quotes, variables read only there
# shellcheck disable=SC2016,SC2034
set -u
MODE=$1
OUT=/out
PW=kit-test-pw
T_HOME=/home/tester
RUN=/run/user/1000
chmod 777 "$OUT"
pass=0
fail=0
check() {  # check <name> <condition> [detail]
    if eval "$2"; then
        echo "PASS  $1${3:+  ($3)}"; pass=$((pass + 1))
    else
        echo "FAIL  $1${3:+  ($3)}"; fail=$((fail + 1))
    fi
}
echo "tester:$PW" | chpasswd
useradd -m other 2> /dev/null; echo "other:other-pw" | chpasswd

# runs a command as tester: in the user manager's session (gnome), or with the
# Xfce display (xorg)
as() {
    if [ "$MODE" = gnome ]; then
        su tester -s /bin/bash -c "export XDG_RUNTIME_DIR=$RUN DBUS_SESSION_BUS_ADDRESS=unix:path=$RUN/bus \
            WAYLAND_DISPLAY=wayland-0 HOME=$T_HOME; cd; $*"
    else
        su tester -s /bin/bash -c "export DISPLAY=:1 HOME=$T_HOME XDG_RUNTIME_DIR=/tmp/runtime-tester; cd; $*"
    fi
}

# the kit's client, on its own X server: -noreset, or it resets when its last
# client leaves and refuses the next one for a moment
tar -xJf /client.tar.xz -C /opt
CLIENT=$(ls /opt/sdl3-freerdp-*/bin/sdl-freerdp)
Xvfb :99 -noreset -screen 0 1600x1000x24 > "$OUT/xvfb-client.log" 2>&1 &
# the host, installed as its README says (as tester)
install_host() {
    as "tar -xJf /host.tar.xz -C /tmp && mkdir -p ~/.local/opt ~/.config/systemd/user \
        && mv /tmp/freerdp-host-*-linux-* ~/.local/opt/freerdp-host \
        && cp ~/.local/opt/freerdp-host/freerdp-shadow.service ~/.config/systemd/user/" \
        > "$OUT/install.log" 2>&1
    SERVER=$T_HOME/.local/opt/freerdp-host/bin/freerdp-shadow-cli
    cp "$T_HOME/.local/opt/freerdp-host/MANIFEST" "$OUT/MANIFEST"
}
# listening sockets on port 3389 (0D3D), or the hex port given, from /proc/net/tcp,
# whose addresses are hex: 0100007F is 127.0.0.1, 00000000 any address
listeners() { awk -v port=":${1:-0D3D}\$" '$4 == "0A" && $2 ~ port { print $2 }' /proc/net/tcp /proc/net/tcp6; }
# connect <name> [client options...]: a client in the background, its log in
# /out/<name>.wlog (DEBUG: it names the codec of each frame)
connect() {
    local name=$1
    shift
    WLOG_LEVEL=DEBUG WLOG_APPENDER=FILE WLOG_FILEAPPENDER_OUTPUT_FILE_PATH="$OUT" \
        WLOG_FILEAPPENDER_OUTPUT_FILE_NAME="$name.wlog" DISPLAY=:99 \
        "$CLIENT" /v:127.0.0.1:"${PORT_:-3389}" /u:"${USER_:-tester}" /p:"${PASS_:-$PW}" /cert:ignore /sec:tls \
        /size:1280x800 "$@" > "$OUT/$name.out" 2>&1 &
    CPID=$!
}
# frames <name> <codec>: how many frames the client got in that codec
# frames <session> <AV1|AV2|…>: the frames of that codec in the client's log. Since FreeRDP's
# AV2 as merged (#13925, aa9940f24) AV2 comes under the AV1 codec ID and the confirmed caps
# version tells them apart: FRDP_2 = AV2, FRDP_1 = AV1 (kit run 42827825178 counted 0 AV2)
frames() {
    local id=$2
    if grep -q "RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_FRDP_2" "$OUT/$1.wlog" 2> /dev/null; then
        case $id in AV2) id=AV1 ;; AV1) echo 0; return ;; esac
    fi
    grep -c "Got GFX RDPGFX_CODECID_$id\b" "$OUT/$1.wlog" 2> /dev/null || true
}
codecs() {
    grep -ohE "Got GFX RDPGFX_CODECID_[A-Z0-9_]+|RecvCapsConfirmPdu: version: RDPGFX_CAPVERSION_[A-Z0-9_]+" \
        "$OUT/$1.wlog" 2> /dev/null | sed 's/RecvCapsConfirmPdu: version: //' | sort | uniq -c | tr '\n' ' '
}
# cpu <pid> <seconds>: the process's CPU use over that time, in % of one core
cpu() {
    local t0 t1
    t0=$(awk '{ print $14 + $15 }' "/proc/$1/stat")
    sleep "$2"
    t1=$(awk '{ print $14 + $15 }' "/proc/$1/stat")
    echo $(((t1 - t0) * 100 / $2 / $(getconf CLK_TCK)))
}
# a window whose content changes 20 times a second: Mutter sends a full frame only
# once the screen changes (an idle GNOME records cursor frames and skips the full
# one as "too early"), and X11's capture sends what changed
CLOCK='while :; do date +%T.%N; sleep 0.05; done'
# a tone for the sound checks, for pw-cat --raw: 1 kHz at -12 dBFS, 48 kHz, 2
# channels, 16 bits, 4 s (one period of 48 frames, 4000 times)
TONE=/tmp/tone.raw
PERIOD=$(awk 'BEGIN { for (i = 0; i < 48; i++) { v = int(8191 * sin(2 * 3.14159265 * i / 48)); if (v < 0) v += 65536
    b = sprintf("\\x%02x\\x%02x", v % 256, int(v / 256)); s = s b b } print s }')
# shellcheck disable=SC2059
for _ in $(seq 4000); do printf "$PERIOD"; done > "$TONE"
chmod 644 "$TONE"
play_tone() { pw-cat --playback --raw --rate 48000 --channels 2 --format s16 "$TONE"; }
# tone_waves <name>: the waves that carry sound: in Opus a wave of silence is a few
# bytes, of the tone a few hundred (one wave every 50 ms)
tone_waves() { grep -oE ' Wave: .*size: [0-9]+' "$OUT/$1.wlog" 2> /dev/null | awk '$NF >= 100' | wc -l; }

if [ "$MODE" = gnome ]; then
    for _ in $(seq 60); do
        systemctl is-system-running 2> /dev/null | grep -q -E 'running|degraded' && break
        sleep 1
    done
    # tester's user manager without a login: the session bus, PipeWire, WirePlumber
    loginctl enable-linger tester
    for _ in $(seq 60); do [ -S $RUN/bus ] && break; sleep 1; done
    has_name() {
        as "gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
            --method org.freedesktop.DBus.NameHasOwner $1" 2> /dev/null | grep -q true
    }
    as "systemctl --user start pipewire.socket pipewire.service wireplumber.service" > "$OUT/units.log" 2>&1
    # --unsafe-mode: org.gnome.Shell.Eval, with which the test stops the sharing as
    # the indicator's Stop does
    as "systemd-run --user --unit=gnome-shell-test --setenv=XDG_SESSION_TYPE=wayland \
        gnome-shell --headless --unsafe-mode --virtual-monitor 1280x800" >> "$OUT/units.log" 2>&1
    for _ in $(seq 90); do has_name org.gnome.Mutter.RemoteDesktop && break; sleep 1; done
    # the shell's start-up holds the first DisplayConfig call for ~20 s: wait until
    # it answers at once
    for _ in $(seq 60); do
        t0=$(date +%s%N)
        as "gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig \
            --method org.gnome.Mutter.DisplayConfig.GetCurrentState" > /dev/null 2>&1
        t1=$(date +%s%N)
        [ $(((t1 - t0) / 1000000)) -lt 1000 ] && break
    done
    echo "== $(gnome-shell --version), answers DisplayConfig in $(((t1 - t0) / 1000000)) ms"
    check "GNOME Shell is up (org.gnome.Mutter.RemoteDesktop)" 'has_name org.gnome.Mutter.RemoteDesktop'

    install_host
    as "systemctl --user daemon-reload && systemctl --user enable --now freerdp-shadow.service" \
        >> "$OUT/install.log" 2>&1
    # the server's lines as its user reads them: the unit's own journal
    # (WLOG_APPENDER=journald), journalctl --user -u freerdp-shadow
    journal() { as "journalctl --user -u freerdp-shadow -o cat --no-pager" 2> /dev/null; }
    for _ in $(seq 60); do journal | grep -q "Listening on" && break; sleep 1; done
    unit() { as "systemctl --user show freerdp-shadow.service -p $1 --value"; }
    SPID=$(unit MainPID)
    check "the unit runs the server" '[ "$(unit ActiveState)" = active ] && [ "${SPID:-0}" -gt 0 ]' "pid $SPID"
    check "it listens on 127.0.0.1:3389 only" '[ "$(listeners)" = "0100007F:0D3D" ]' "$(listeners | tr '\n' ' ')"
    check "default subsystem: Mutter" 'journal | grep -q "subsystem: Mutter"'
    as "WLOG_LEVEL=INFO $SERVER /subsystem" > "$OUT/subsystem-list.txt" 2>&1
    check "/subsystem lists Mutter first, picked" \
        'grep -E "(\*| ) [A-Za-z0-9]+: [0-9]+ monitor" "$OUT/subsystem-list.txt" | head -1 | grep -q "\* Mutter: [1-9]"' \
        "$(grep -ohE '[* ] [A-Za-z0-9]+: [0-9]+ monitor' "$OUT/subsystem-list.txt" | tr '\n' ',')"

    # AV1: the kit's client offers AV2 and AV1, and the server takes AV2 first: AV2 off
    connect av1 /gfx:AV2:off
    sleep 10
    check "av1: the client is logged in (PAM, the session's owner)" 'journal | grep -q "is activated"'
    check "input through libei (Mutter's ConnectToEIS)" 'journal | grep -q "input through libei"'
    # idle: a client, nothing on the screen moving
    IDLE=$(cpu "$SPID" 5)
    check "idle CPU of the server with one client < 20 %" '[ "$IDLE" -lt 20 ]' "$IDLE %"
    as "nohup foot sh -c '$CLOCK' > /tmp/foot-clock.log 2>&1 &"
    sleep 20
    DISPLAY=:99 import -window root "$OUT/av1.png" 2> /dev/null
    n=$(frames av1 AV1)
    check "av1: the session holds" 'kill -0 $CPID'
    check "av1: at least 30 frames in AV1 with the screen changing" '[ "${n:-0}" -ge 30 ]' "$(codecs av1)"
    check "av1: the client shows more than one colour" \
        '[ "$(convert "$OUT/av1.png" -format "%k" info: 2> /dev/null)" -gt 1 ]'
    # keys: a terminal of its own, a click into it, a line typed
    as "pkill -x foot"
    as "nohup foot > /tmp/foot.log 2>&1 &"
    sleep 3
    WID=$(DISPLAY=:99 xdotool search --pid $CPID | tail -1)
    DISPLAY=:99 xdotool mousemove --window "$WID" 640 400 click 1
    sleep 1
    # and once more, as a user on GNOME 51 must: the session starts in the overview, and
    # gnome-shell 51.0 gives the key focus back to the hidden overview when it is left, so
    # the first window gets no keys until it is clicked again (GNOME/gnome-shell#9441, fix
    # MR !4486; not FreeRDP: freerdp-server-g3's repro, kit runs 42975835360 and PR #29)
    DISPLAY=:99 xdotool mousemove --window "$WID" 640 400 click 1
    sleep 1
    DISPLAY=:99 xdotool type --delay 80 'echo kit-typed-$((6*7)) > /tmp/typed.txt'
    DISPLAY=:99 xdotool key Return
    sleep 2
    check "keys reach GNOME (typed into foot)" 'grep -qx kit-typed-42 /tmp/typed.txt'
    as "pkill -x foot"
    kill $CPID 2> /dev/null; sleep 2

    # AV2: the client as it comes (offers AV2). libavm, AV2's reference encoder: a
    # few frames a second on a runner's cores, so fewer
    as "nohup foot sh -c '$CLOCK' > /tmp/foot-clock.log 2>&1 &"
    connect av2
    sleep 25
    n=$(frames av2 AV2)
    check "av2: the session holds" 'kill -0 $CPID'
    check "av2: at least 10 frames in AV2" '[ "${n:-0}" -ge 10 ]' "$(codecs av2)"
    kill $CPID 2> /dev/null; sleep 2
    as "pkill -x foot"

    # sound: what the session plays (the tone, 4 s) reaches the client in Opus, as it
    # plays. No sound card here: the sink is WirePlumber's Dummy Output, whose
    # monitor the server records, as it would a sound card's
    connect sound /gfx:AV2:off /sound:sys:fake
    sleep 10
    as "$(declare -f play_tone); TONE=$TONE play_tone" > "$OUT/pw-cat.log" 2>&1
    sleep 3
    kill $CPID 2> /dev/null; sleep 2
    check "clipboard: the session's clipboard channel opens (Monitor Ready reaches the client)" \
        'grep -q MonitorReady "$OUT/sound.wlog"'
    check "sound: the server records what the session's sink plays" \
        'journal | grep -q "sound: capturing what the default sink plays"'
    check "sound: the tone reaches the client in Opus, as it plays (4 s, 80 waves)" \
        'grep -q "Opening device with format WAVE_FORMAT_OPUS" "$OUT/sound.wlog" && [ "$(tone_waves sound)" -ge 60 ]' \
        "$(tone_waves sound) waves with sound"

    # sound that plays before anyone connects: the stream the first client makes must
    # join a sink already playing, not stay silent with its links in init
    as "$(declare -f play_tone); TONE=$TONE; for _ in 1 2 3 4; do play_tone; done" > "$OUT/pw-cat-first.log" 2>&1 &
    TPID=$!
    sleep 2
    connect sound-first /gfx:AV2:off /sound:sys:fake
    wait $TPID || true
    kill $CPID 2> /dev/null; sleep 2
    check "sound: a tone already playing reaches the first client" \
        '[ "$(tone_waves sound-first)" -ge 60 ]' "$(tone_waves sound-first) waves with sound"

    # another account: refused, the screen is tester's
    USER_=other PASS_=other-pw connect other
    sleep 8
    kill $CPID 2> /dev/null; sleep 1
    check "another account is refused, and sees nothing" \
        "journal | grep -q \"login as 'other' refused\" && [ \"\$(frames other AV1)\$(frames other AV2)\" = 00 ]"

    # the sharing stopped in GNOME (the indicator's Stop): the server ends with 0 and
    # Restart=on-failure leaves it stopped
    check "the server still runs before the stop" '[ "$(unit ActiveState)" = active ]'
    connect stop
    sleep 8
    as "gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval \
        'global.backend.get_remote_access_controller().inhibit_remote_access()'" > "$OUT/eval.log" 2>&1
    # longer than RestartSec=5: a restart would show
    sleep 12
    kill $CPID 2> /dev/null
    STATE="$(unit ActiveState) $(unit Result) exit=$(unit ExecMainStatus) restarts=$(unit NRestarts)"
    check "stop: the server says why" 'journal | grep -q "stopped the sharing"'
    check "stop: the unit ended with 0 and stayed stopped" '[ "$STATE" = "inactive success exit=0 restarts=0" ]' "$STATE"
    as "gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval \
        'global.backend.get_remote_access_controller().uninhibit_remote_access()'" >> "$OUT/eval.log" 2>&1

    # from WinPR's journald appender: its stream (_TRANSPORT=stdout; syslog's lines
    # say syslog), the identifier the unit gives it, and each line's own level
    # (INFO = priority 6, WARN = 4; the console appender's lines would all be 6)
    jlevel() { as "journalctl --user -t freerdp-shadow-cli _TRANSPORT=stdout -p $1..$1 -o cat --no-pager" 2> /dev/null; }
    check "journald appender: an INFO line at priority info, as freerdp-shadow-cli" 'jlevel info | grep -q "subsystem: Mutter"'
    check "journald appender: a WARN line at priority warning" 'jlevel warning | grep -q "stopped the sharing"'

    # the session manager (optional: a root system unit on 127.0.0.1:3391), installed
    # as the archive's README says: a connection that names tester goes to tester's
    # GNOME, through a shadow server it starts in tester's user manager
    { rm -rf /opt/freerdp-host && tar -xJf /host.tar.xz -C /opt && mv /opt/freerdp-host-*-linux-* /opt/freerdp-host \
        && chown -R root:root /opt/freerdp-host \
        && cp /opt/freerdp-host/freerdp-shadow-sesman.service /etc/systemd/system/ \
        && systemctl daemon-reload && systemctl enable --now freerdp-shadow-sesman.service; } >> "$OUT/install.log" 2>&1
    sesman() { journalctl -u freerdp-shadow-sesman -o cat --no-pager 2> /dev/null; }
    sesman_shadow() { as "journalctl --user -u freerdp-sesman-shadow -o cat --no-pager" 2> /dev/null; }
    for _ in $(seq 30); do sesman | grep -q "listening on" && break; sleep 1; done
    check "sesman: the system unit runs, on 127.0.0.1:3391 only (0D3F)" \
        '[ "$(systemctl show freerdp-shadow-sesman -p ActiveState --value)" = active ] && [ "$(listeners 0D3F)" = "0100007F:0D3F" ]' \
        "$(listeners 0D3F | tr '\n' ' ')"
    as "nohup foot sh -c '$CLOCK' > /tmp/foot-clock.log 2>&1 &"
    # the first connection waits for the shadow server to start
    PORT_=3391 connect sesman /gfx:AV2:off
    sleep 25
    n=$(frames sesman AV1)
    check "sesman: tester is handed to the shadow server of tester's GNOME" \
        'sesman | grep -q "tester -> the shadow server of their GNOME session"'
    check "sesman: the client is logged in (PAM, the session's owner)" 'sesman_shadow | grep -q "is activated"'
    check "sesman: at least 20 frames in AV1 with the screen changing" '[ "${n:-0}" -ge 20 ]' "$(codecs sesman)"
    check "sesman: the session's clipboard channel opens (Monitor Ready reaches the client)" \
        'grep -q MonitorReady "$OUT/sesman.wlog"'
    kill $CPID 2> /dev/null; sleep 2
    as "pkill -x foot"
    # a wrong password: the client is told why and ends, it does not reconnect with it
    PASS_=wrong-pw PORT_=3391 connect sesman-badpw /gfx:AV2:off /auto-reconnect
    for _ in $(seq 40); do kill -0 $CPID 2> /dev/null || break; sleep 1; done
    check "sesman: a wrong password ends the client within 40 s, no reconnecting" \
        '! kill -0 $CPID 2> /dev/null && sesman_shadow | grep -q "client authentication failure"' \
        "$(grep -c -i 'reconnect' "$OUT/sesman-badpw.wlog" 2> /dev/null) lines on reconnecting"
    kill $CPID 2> /dev/null; sleep 2
    # an update, as a package makes one: a new file renamed over the running server.
    # The next connection gets a new server, in the same GNOME
    shadow_pid() { as "systemctl --user show -p MainPID --value freerdp-sesman-shadow.service" 2> /dev/null; }
    shell_pid() { pgrep -u tester -o -x gnome-shell; }
    PORT_=3391 connect sesman-before /gfx:AV2:off
    sleep 8
    kill $CPID 2> /dev/null; sleep 2
    OLD_SHADOW=$(shadow_pid)
    OLD_SHELL=$(shell_pid)
    cp -p /opt/freerdp-host/bin/freerdp-shadow-cli /opt/freerdp-host/bin/freerdp-shadow-cli.new
    mv -f /opt/freerdp-host/bin/freerdp-shadow-cli.new /opt/freerdp-host/bin/freerdp-shadow-cli
    PORT_=3391 connect sesman-update /gfx:AV2:off
    sleep 12
    NEW_SHADOW=$(shadow_pid)
    check "sesman: after an update the next connection gets a new server, in the same GNOME" \
        '[ "$OLD_SHADOW" -gt 0 ] && [ "${NEW_SHADOW:-0}" -gt 0 ] && [ "$NEW_SHADOW" != "$OLD_SHADOW" ] && [ "$(shell_pid)" = "$OLD_SHELL" ] && kill -0 $CPID' \
        "server $OLD_SHADOW -> $NEW_SHADOW, shell $OLD_SHELL -> $(shell_pid)"
    kill $CPID 2> /dev/null; sleep 2
    # other has an account but no GNOME session: refused before any login
    USER_=other PASS_=other-pw PORT_=3391 connect sesman-other
    sleep 8
    kill $CPID 2> /dev/null; sleep 1
    check "sesman: a user with no GNOME session is refused, and sees nothing" \
        'sesman | grep -q "other has no GNOME session: refused" && [ "$(frames sesman-other AV1)$(frames sesman-other AV2)" = 00 ]'

    # headless: other, now in the unit's group freerdp-headless, gets a GNOME of
    # its own. tester's GNOME stops first: a rootless podman counts every
    # container's inotify instances against one host user (128), too few for two
    groupadd -f freerdp-headless && usermod -aG freerdp-headless other
    as "systemctl --user stop freerdp-sesman-shadow.service gnome-shell-test.service" >> "$OUT/units.log" 2>&1
    OTHER_UID=$(id -u other)
    other_shadow() { journalctl _UID="$OTHER_UID" _SYSTEMD_USER_UNIT=freerdp-sesman-shadow.service -o cat --no-pager 2> /dev/null; }
    as_other() { su other -s /bin/bash -c "export XDG_RUNTIME_DIR=/run/user/$OTHER_UID \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$OTHER_UID/bus WAYLAND_DISPLAY=wayland-0; cd; $*"; }
    # the image has no gnome-software: an entry of its name that leaves a mark stands in
    # for it, and a second one proves that autostart ran at all
    autostart() { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=sh -c "touch /tmp/%s"\n' "$1" "$2" > "/etc/xdg/autostart/$1.desktop"; }
    autostart org.gnome.Software software-ran
    autostart other-system other-system-ran
    # GNOME's session target wants gnome-software.service: the same stand-in by that path
    printf '[Service]\nType=oneshot\nExecStart=/usr/bin/touch /tmp/software-unit-ran\n' > /usr/lib/systemd/user/gnome-software.service
    USER_=other PASS_=other-pw PORT_=3391 connect sesman-headless /gfx:AV2:off /sound:sys:fake /dynamic-resolution
    # a whole GNOME session takes longer to start than the shell alone
    for _ in $(seq 150); do other_shadow | grep -q "is activated" && break; sleep 1; done
    # the same clock window, in other's GNOME: it opens on the virtual monitor, the
    # only one there, so the frames count what changes, not only the first picture
    as_other "nohup foot sh -c '$CLOCK' > /tmp/foot-clock-other.log 2>&1 &"
    sleep 25
    check "sesman headless: a whole GNOME session, with its settings daemons" \
        '[ "$(pgrep -u other -c "^gsd-")" -ge 5 ]' \
        "$(pgrep -u other -c '^gsd-') gsd-* running"
    for _ in $(seq 30); do [ -e /tmp/other-system-ran ] && break; sleep 1; done
    sleep 5
    check "sesman headless: GNOME Software stays out of the autostart, the other entries run" \
        '[ -e /tmp/other-system-ran ] && [ ! -e /tmp/software-ran ]' "$(ls /tmp/*-ran 2> /dev/null | tr '\n' ' ')"
    check "sesman headless: gnome-software.service is masked, so the session target does not start it" \
        '[ "$(as_other "systemctl --user show -p LoadState --value gnome-software.service")" = masked ] && [ ! -e /tmp/software-unit-ran ]' \
        "$(as_other "systemctl --user show -p LoadState --value gnome-software.service" 2>&1) $(ls /tmp/software-unit-ran 2> /dev/null)"
    check "sesman headless: other (in freerdp-headless) gets a headless GNOME" \
        'sesman | grep -q "other has no GNOME session: starting a headless one" && sesman | grep -q "headless GNOME of other is up"'
    check "sesman headless: logged in, on the shadow server's own virtual monitor" \
        'other_shadow | grep -q "is activated" && other_shadow | grep -q "sharing a virtual monitor of its own"'
    check "sesman headless: at least 20 frames in AV1 with the screen changing" \
        '[ "$(frames sesman-headless AV1)" -ge 20 ]' "$(codecs sesman-headless)"
    # sound in the headless GNOME too: the session manager starts other's PipeWire
    as_other "$(declare -f play_tone); TONE=$TONE play_tone" > "$OUT/pw-cat-other.log" 2>&1
    sleep 3
    check "sesman headless: the tone played there reaches the client in Opus" \
        'grep -q "Opening device with format WAVE_FORMAT_OPUS" "$OUT/sesman-headless.wlog" && [ "$(tone_waves sesman-headless)" -ge 60 ]' \
        "$(tone_waves sesman-headless) waves with sound"
    # the client resizes its window: the session's virtual monitor follows, on the same
    # connection, and the encoder goes on at the new size
    n=$(frames sesman-headless AV1)
    WID=$(DISPLAY=:99 xdotool search --pid $CPID | tail -1)
    DISPLAY=:99 xdotool windowsize "$WID" 1100 700
    for _ in $(seq 15); do other_shadow | grep -q "stream: 1100x700" && break; sleep 1; done
    sleep 8
    check "sesman headless: a client's window resize reaches the session, same connection, frames go on" \
        'other_shadow | grep -q "stream: 1100x700" && kill -0 $CPID && [ "$(frames sesman-headless AV1)" -gt "$n" ]' \
        "$n -> $(frames sesman-headless AV1) AV1 frames"
    kill $CPID 2> /dev/null; sleep 3
    pkill -u other -x foot
    check "sesman headless: the GNOME keeps running after the client leaves" \
        'systemctl is-active --quiet freerdp-sesman-gnome-other.service'
    sesman > "$OUT/sesman.log"
    sesman_shadow > "$OUT/sesman-shadow.log"
    other_shadow > "$OUT/sesman-shadow-other.log"
    journalctl -u freerdp-sesman-gnome-other -o cat --no-pager > "$OUT/sesman-gnome-other.log" 2>&1

    journal > "$OUT/server.log"
    echo "INFO  the server's lines in the unit's journal (journalctl --user -u): $(wc -l < "$OUT/server.log"), by identifier (-t freerdp-shadow-cli): $(journalctl -t freerdp-shadow-cli -o cat --no-pager 2> /dev/null | wc -l)"
    journalctl --user-unit=gnome-shell-test.service -o cat --no-pager > "$OUT/gnome-shell.log" 2>&1
    journalctl -b --no-pager > "$OUT/journal.log" 2>&1
else
    # Xfce on its own X server, with its own session bus
    mkdir -p /tmp/runtime-tester && chown tester /tmp/runtime-tester && chmod 700 /tmp/runtime-tester
    Xvfb :1 -noreset -screen 0 1280x800x24 > "$OUT/xvfb-desktop.log" 2>&1 &
    sleep 2
    as "nohup dbus-run-session -- xfce4-session > /tmp/xfce.log 2>&1 &"
    sleep 8
    check "Xfce runs" 'pgrep -u tester -x xfwm4 > /dev/null'
    install_host
    # the unit's arguments, as systemd would start it (%h is the home), then
    # /subsystem:x11; its log to a file, there is no journal here
    ARGS=$(sed -n 's/^ExecStart=//p' "$T_HOME/.config/systemd/user/freerdp-shadow.service" | sed "s|%h|$T_HOME|g")
    as "WLOG_LEVEL=INFO $SERVER /subsystem" > "$OUT/subsystem-list.txt" 2>&1
    check "/subsystem picks X11 outside GNOME" \
        'grep -q "\* X11: [1-9]" "$OUT/subsystem-list.txt" && grep -q "  Mutter: 0" "$OUT/subsystem-list.txt"' \
        "$(grep -ohE '[* ] [A-Za-z0-9]+: [0-9]+ monitor' "$OUT/subsystem-list.txt" | tr '\n' ',')"
    as "WLOG_LEVEL=INFO WLOG_APPENDER=FILE WLOG_FILEAPPENDER_OUTPUT_FILE_PATH=$OUT \
        WLOG_FILEAPPENDER_OUTPUT_FILE_NAME=server.log nohup $ARGS /subsystem:x11 > $OUT/server.out 2>&1 &"
    for _ in $(seq 30); do grep -q "Listening on" "$OUT/server.log" 2> /dev/null && break; sleep 1; done
    SPID=$(pgrep -u tester -f "freerdp-shadow-cli /bind-address" | head -1)
    check "it listens on 127.0.0.1:3389 only" '[ "$(listeners)" = "0100007F:0D3D" ]' "$(listeners | tr '\n' ' ')"
    check "/subsystem:x11: subsystem X11" 'grep -q "subsystem: X11" "$OUT/server.log"'
    as "nohup xterm -geometry 60x20+100+100 -e sh -c '$CLOCK' > /tmp/xterm.log 2>&1 &"
    connect av1 /gfx:AV2:off
    sleep 20
    DISPLAY=:99 import -window root "$OUT/av1.png" 2> /dev/null
    n=$(frames av1 AV1)
    check "av1: the client is logged in (PAM, the session's owner)" 'grep -q "is activated" "$OUT/server.log"'
    check "av1: the session holds" 'kill -0 $CPID'
    check "av1: at least 30 frames in AV1 with the screen changing" '[ "${n:-0}" -ge 30 ]' "$(codecs av1)"
    check "av1: the client shows more than one colour" \
        '[ "$(convert "$OUT/av1.png" -format "%k" info: 2> /dev/null)" -gt 1 ]'
    echo "INFO  the server's CPU with one client and a changing xterm: $(cpu "$SPID" 5) %"
    kill $CPID 2> /dev/null; sleep 2
    # (the X11 subsystem checks the login after the activation: what counts is
    # the refusal, and that no frame reached the client)
    before=$(wc -l < "$OUT/server.log")
    USER_=other PASS_=other-pw connect other
    sleep 8
    kill $CPID 2> /dev/null; sleep 1
    check "another account is refused, and sees nothing" \
        'tail -n +$((before + 1)) "$OUT/server.log" | grep -q "client authentication failure" && [ "$(frames other AV1)" = 0 ]'
    cp /tmp/xfce.log "$OUT/" 2> /dev/null
fi

chmod -R a+rX "$OUT"
echo "passed $pass, failed $fail"
[ $fail = 0 ]
