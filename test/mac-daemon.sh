#!/bin/bash
# The macOS host's daemon mode on a GitHub macOS runner, installed as a user installs it
# (install-daemon.sh with sudo: a root LaunchDaemon, the server, and the LaunchAgent
# org.freerdp.shadow.agent, the capture and input), with the kit's own macOS client on
# 127.0.0.1:3388 in AV1; then uninstall-daemon.sh, and nothing of ours may be left loaded,
# listening or running.
#   test/mac-daemon.sh <host dir (the unpacked archive)> <client dir (holds bin/sdl-freerdp)> <out dir>
# What the runner allows (test/mac-host.sh): Screen Recording is granted to /bin/bash, not to
# a program launchd starts. So the agent as launchd starts it may get no picture here: that
# session is INFO. The picture through the daemon is then checked with the same agent started
# by this script (so under the runner's grant, as mac-host.sh starts the server), which
# connects to the installed daemon's Mach service as launchd's agent does. The daemon gets
# -auth (the runner account's password can't be set) and /log-level:INFO (the agents' hellos
# in its log) through install-daemon.sh's "--".
# Bash 3.2 (macOS's own) is enough here.
# the logs of a sudo command go to files of this user, on purpose
# shellcheck disable=SC2024
set -u
HOSTDIR=$1; CLIENTDIR=$2; OUT=$3
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
HOSTDIR=$(cd "$HOSTDIR" && pwd)
CLIENT="$CLIENTDIR/bin/sdl-freerdp"
APP=/Applications/FreeRDP-Shadow.app
AGENT_BIN=$APP/Contents/MacOS/freerdp-shadow-agent
LOGS=/var/log/freerdp-shadow
ME=$(id -u)
fails=0
check() {  # check <name> <0|1> [detail]
    if [ "$2" = 1 ]; then echo "PASS  $1${3:+  ($3)}"; else echo "FAIL  $1${3:+  ($3)}"; fails=$((fails + 1)); fi
}
listening() { nc -z 127.0.0.1 "$1" 2> /dev/null; }
loaded() { sudo launchctl print "$1" > /dev/null 2>&1; }
ours_running() { pgrep -f "^$APP/Contents/MacOS/" > /dev/null 2>&1; }
hellos() { n=$(sudo grep -c "agent: uid $ME," "$LOGS/daemon.log" 2> /dev/null); echo "${n:-0}"; }
motion() {  # something on screen changes during a session (ScreenCaptureKit sends changes only)
    ( sleep 4; open -a Calculator; sleep 3; open -a "System Settings"; sleep 3
      osascript -e 'quit app "Calculator"'; sleep 2; open -a Calculator; sleep 3
      osascript -e 'quit app "System Settings"' ) > /dev/null 2>&1 &
}
frames() {  # frames <session name>: the AV1 frames the client got
    n=$(grep -c "Got GFX RDPGFX_CODECID_AV1\b" "$OUT/$1.wlog" 2> /dev/null); echo "${n:-0}"
}
session() {  # session <name>: 20 s of AV1 (AV2 off on the client) to 127.0.0.1:3388
    motion
    WLOG_LEVEL=DEBUG WLOG_APPENDER=FILE WLOG_FILEAPPENDER_OUTPUT_FILE_PATH="$OUT" \
        WLOG_FILEAPPENDER_OUTPUT_FILE_NAME="$1.wlog" "$CLIENT" /v:127.0.0.1:3388 /u:probe /p:probe \
        /cert:ignore /sec:tls /size:1280x720 /gfx:AV2:off > "$OUT/$1.out" 2>&1 &
    c=$!
    sleep 20
    screencapture -x "$OUT/$1.png" 2> /dev/null || true
    kill -0 $c 2> /dev/null && held=1 || held=0
    kill $c 2> /dev/null; sleep 3
}
save_logs() {
    mkdir -p "$OUT/var-log"
    sudo cp "$LOGS"/*.log "$OUT/var-log/" 2> /dev/null || true
    sudo chown -R "$ME" "$OUT/var-log" 2> /dev/null || true
}

{ sw_vers; uname -m; echo "console: $(stat -f %Su /dev/console) (uid $(stat -f %u /dev/console)), me: uid $ME"; } \
    > "$OUT/system.txt" 2>&1
cat "$OUT/system.txt"
ls -l "$HOSTDIR" "$HOSTDIR/FreeRDP-Shadow.app/Contents/MacOS" > "$OUT/archive.txt" 2>&1
[ -x "$HOSTDIR/FreeRDP-Shadow.app/Contents/MacOS/freerdp-shadow-agent" ] && ok=1 || ok=0
check "the archive has the agent in FreeRDP-Shadow.app" "$ok"
codesign --verify --strict --deep "$HOSTDIR/FreeRDP-Shadow.app" > "$OUT/codesign.txt" 2>&1 && ok=1 || ok=0
check "the app's signature covers both programs (codesign --verify --strict --deep)" "$ok"

# 1. the no-root LaunchAgent on 3388 first: install-daemon.sh must refuse (only loaded here,
# for a moment: its program is not in /Applications yet)
mkdir -p "$HOME/Library/LaunchAgents"
cp "$HOSTDIR/org.freerdp.shadow.plist" "$HOME/Library/LaunchAgents/"
launchctl bootstrap "gui/$ME" "$HOME/Library/LaunchAgents/org.freerdp.shadow.plist" 2> /dev/null
if sudo "$HOSTDIR/install-daemon.sh" > "$OUT/install-refused.log" 2>&1; then ok=0; else ok=1; fi
grep -q "org.freerdp.shadow" "$OUT/install-refused.log" || ok=0
check "install-daemon.sh refuses while the app's LaunchAgent is on 3388" "$ok" "$(tail -1 "$OUT/install-refused.log")"
launchctl bootout "gui/$ME/org.freerdp.shadow" 2> /dev/null
rm -f "$HOME/Library/LaunchAgents/org.freerdp.shadow.plist"

# 2. install, and again (an update): both must succeed
sudo "$HOSTDIR/install-daemon.sh" -- -auth /log-level:INFO > "$OUT/install.log" 2>&1 && ok=1 || ok=0
check "install-daemon.sh" "$ok" "$(grep -m1 '^Installed' "$OUT/install.log")"
sudo "$HOSTDIR/install-daemon.sh" -- -auth /log-level:INFO > "$OUT/install-again.log" 2>&1 && ok=1 || ok=0
check "install-daemon.sh again (idempotent)" "$ok"
loaded system/org.freerdp.shadow.daemon && ok=1 || ok=0
check "the daemon org.freerdp.shadow.daemon is loaded (system)" "$ok"
loaded "gui/$ME/org.freerdp.shadow.agent" && ok=1 || ok=0
check "the agent org.freerdp.shadow.agent is loaded (gui/$ME)" "$ok"
for _ in $(seq 1 20); do listening 3388 && break; sleep 1; done
listening 3388 && ok=1 || ok=0
check "the daemon listens on 127.0.0.1:3388" "$ok"
perm=$(stat -f '%Su:%Sg %Lp' /Library/LaunchDaemons/org.freerdp.shadow.daemon.plist \
    /Library/LaunchAgents/org.freerdp.shadow.agent.plist 2> /dev/null | sort -u | tr '\n' ' ')
[ "$perm" = "root:wheel 644 " ] && ok=1 || ok=0
check "both plists are root:wheel 644" "$ok" "$perm"
sudo plutil -p /Library/LaunchDaemons/org.freerdp.shadow.daemon.plist > "$OUT/daemon-plist.txt" 2>&1
for _ in $(seq 1 20); do [ "$(hellos)" -ge 1 ] && break; sleep 1; done
[ "$(hellos)" -ge 1 ] && ok=1 || ok=0
check "launchd's agent said hello to the daemon (its log: agent: uid $ME)" "$ok" \
    "$(sudo grep -m1 "agent: uid $ME," "$LOGS/daemon.log" 2> /dev/null)"

# 3. AV1 with the agent as launchd starts it: INFO only (no Screen Recording grant here)
session launchd-agent
n=$(frames launchd-agent)
if [ "$n" -ge 30 ]; then
    echo "PASS  launchd's agent: $n AV1 frames in 20 s"
else
    echo "INFO  launchd's agent: $n AV1 frames in 20 s; the runner grants Screen Recording to" \
        "/bin/bash, not to a program launchd starts ($(sudo grep -m1 -i "permission" "$LOGS/agent.log" 2> /dev/null))"
fi

# 4. AV1 through the daemon with the agent under the runner's grant: launchd's agent stopped,
# the same program started here, on the same Mach service
before=$(hellos)
sudo launchctl bootout "gui/$ME/org.freerdp.shadow.agent" 2> /dev/null
WLOG_LEVEL=INFO "$AGENT_BIN" org.freerdp.shadow > "$OUT/agent-from-script.log" 2>&1 &
AG=$!
for _ in $(seq 1 20); do [ "$(hellos)" -gt "$before" ] && break; sleep 1; done
[ "$(hellos)" -gt "$before" ] && ok=1 || ok=0
check "the agent started here said hello to the daemon" "$ok"
session daemon-av1
check "daemon-av1: the session holds 20 s" "$held"
n=$(frames daemon-av1)
[ "$n" -ge 30 ] && ok=1 || ok=0
all=$(grep -ohE "Got GFX RDPGFX_CODECID_[A-Z0-9_]+" "$OUT/daemon-av1.wlog" 2> /dev/null | sort | uniq -c | tr '\n' ' ')
check "daemon-av1: at least 30 frames in AV1 through the daemon" "$ok" "${all:-none}"
loaded system/org.freerdp.shadow.daemon && listening 3388 && ok=1 || ok=0
check "the daemon still runs after the session" "$ok"
kill $AG 2> /dev/null; sleep 1
save_logs
cp "$OUT/var-log/daemon.log" "$OUT/daemon.log" 2> /dev/null || true

# 5. uninstall: nothing of ours loaded, listening or running, also 15 s later (no loop); again
# the remover the app carries (the one the README names), not the archive's copy
REMOVER=/Applications/FreeRDP-Shadow.app/Contents/Resources/uninstall-daemon.sh
[ -x "$REMOVER" ] && ok=1 || ok=0
check "the installed app carries uninstall-daemon.sh (Contents/Resources)" "$ok"
sudo bash "$REMOVER" --app --logs > "$OUT/uninstall.log" 2>&1 && ok=1 || ok=0
check "uninstall-daemon.sh --app --logs, from the installed app" "$ok" "$(tail -1 "$OUT/uninstall.log")"
gone() {
    left=""
    loaded system/org.freerdp.shadow.daemon && left="$left daemon-loaded"
    loaded "gui/$ME/org.freerdp.shadow.agent" && left="$left agent-loaded"
    listening 3388 && left="$left port-3388"
    ours_running && left="$left process"
    [ -e /Library/LaunchDaemons/org.freerdp.shadow.daemon.plist ] && left="$left daemon-plist"
    [ -e /Library/LaunchAgents/org.freerdp.shadow.agent.plist ] && left="$left agent-plist"
    [ -e "$APP" ] && left="$left app"
    [ -e "$LOGS" ] && left="$left logs"
    [ -z "$left" ]
}
gone && ok=1 || ok=0
check "after uninstall nothing of ours is loaded, listening, running or installed" "$ok" "${left:-}"
sleep 15
gone && ok=1 || ok=0
check "15 s later still nothing (nothing restarts)" "$ok" "${left:-}"
sudo "$HOSTDIR/uninstall-daemon.sh" > "$OUT/uninstall-again.log" 2>&1 && ok=1 || ok=0
check "uninstall-daemon.sh again (idempotent)" "$ok"

mkdir -p "$OUT/crash"
cp "$HOME"/Library/Logs/DiagnosticReports/freerdp-shadow-* "$OUT/crash/" 2> /dev/null || true
sudo cp /Library/Logs/DiagnosticReports/freerdp-shadow-* "$OUT/crash/" 2> /dev/null || true
sudo chown -R "$ME" "$OUT/crash" 2> /dev/null || true
ls "$OUT/crash"
echo "$fails failed"
[ $fails = 0 ]
