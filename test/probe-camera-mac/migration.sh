#!/bin/bash
# The move from org.freerdp.shadow to KIT_MAC_ID_PREFIX.freerdp-shadow on a GitHub macOS runner
# (an ephemeral machine: sudo, and nothing of a user's at stake):
#
#   migration.sh <old kit dir (origin/main)> <new host package dir> <out dir>
#
# 1. the OLD layout as origin/main's scripts and plists install it (the old ids; the program is
#    this round's, re-signed ad hoc as org.freerdp.shadow): the daemon mode on 3388, plus a
#    user's old no-root LaunchAgent on 3390;
# 2. the NEW install-daemon.sh: it must remove the old jobs and plists itself; then exactly one
#    process listens on 3388 (the new daemon), nothing on 3390, and no org.freerdp.shadow*.plist
#    is left in /Library/LaunchDaemons, /Library/LaunchAgents or ~/Library/LaunchAgents;
# 3. the NEW uninstall-daemon.sh --app --logs (the app's own copy): nothing of either left.
# The daemons get -auth (the runner account has no password to type). Bash 3.2 is enough.
# shellcheck disable=SC2024
set -u
OLDKIT=$(cd "$1" && pwd); NEW=$(cd "$2" && pwd); OUT=$3
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
APP=/Applications/FreeRDP-Shadow.app
LEGACY=org.freerdp.shadow
ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$NEW/FreeRDP-Shadow.app/Contents/Info.plist")
ME=$(id -u)
fails=0
check() { if [ "$2" = 1 ]; then echo "PASS  $1${3:+  ($3)}"; else echo "FAIL  $1${3:+  ($3)}"; fails=$((fails + 1)); fi; }
listeners() { sudo lsof -nP -iTCP:"$1" -sTCP:LISTEN 2> /dev/null | tail -n +2; }
count() { listeners "$1" | grep -c . ; }
wait_listen() { for _ in $(seq 1 "$2"); do [ "$(count "$1")" -ge 1 ] && return 0; sleep 1; done; return 1; }
plists_of() {  # every plist of <id prefix> where launchd looks
    ls /Library/LaunchDaemons/"$1"*.plist /Library/LaunchAgents/"$1"*.plist \
        "$HOME"/Library/LaunchAgents/"$1"*.plist 2> /dev/null
}
loaded() { sudo launchctl print "$1" > /dev/null 2>&1; }
echo "new id: $ID; old id: $LEGACY"

# --- 1. the old layout ----------------------------------------------------------------------
OLD=$OUT/old-package
rm -rf "$OLD"; mkdir -p "$OLD"
ditto "$NEW/FreeRDP-Shadow.app" "$OLD/FreeRDP-Shadow.app"
rm -rf "$OLD/FreeRDP-Shadow.app/Contents/Library" "$OLD/FreeRDP-Shadow.app/Contents/_CodeSignature"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $LEGACY" "$OLD/FreeRDP-Shadow.app/Contents/Info.plist"
codesign --force --sign - --identifier "$LEGACY.agent" "$OLD/FreeRDP-Shadow.app/Contents/MacOS/freerdp-shadow-agent"
codesign --force --sign - --identifier "$LEGACY" "$OLD/FreeRDP-Shadow.app"
for f in "$LEGACY.plist" "$LEGACY.daemon.plist" "$LEGACY.agent.plist" install-daemon.sh uninstall-daemon.sh; do
    cp "$OLDKIT/build/macos/$f" "$OLD/" || { echo "FAIL  origin/main has no build/macos/$f"; exit 1; }
done
chmod 755 "$OLD"/*.sh
sudo "$OLD/install-daemon.sh" -- -auth > "$OUT/old-install.log" 2>&1 && ok=1 || ok=0
check "the OLD install-daemon.sh (origin/main)" $ok "$(grep -m1 '^Installed' "$OUT/old-install.log")"
loaded "system/$LEGACY.daemon" && ok=1 || ok=0
check "the old daemon $LEGACY.daemon is loaded" $ok
wait_listen 3388 60 && ok=1 || ok=0
check "the old daemon listens on 3388" $ok "$(listeners 3388 | awk '{print $1, $2}' | head -1)"
# a user's old no-root LaunchAgent too, on another port (the old installer refuses it on 3388)
mkdir -p "$HOME/Library/LaunchAgents"
cp "$OLD/$LEGACY.plist" "$HOME/Library/LaunchAgents/"
P=$HOME/Library/LaunchAgents/$LEGACY.plist
i=0
while arg=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:$i" "$P" 2> /dev/null); do
    case $arg in /port:*) /usr/libexec/PlistBuddy -c "Set :ProgramArguments:$i /port:3390" "$P" ;; esac
    i=$((i + 1))
done
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:$i string -auth" "$P"
launchctl bootstrap "gui/$ME" "$P" 2> "$OUT/old-user-agent.log" && ok=1 || ok=0
check "the old no-root LaunchAgent $LEGACY is loaded (gui/$ME, port 3390)" $ok
wait_listen 3390 20 && echo "INFO  the old no-root server listens on 3390" ||
    echo "INFO  the old no-root server does not listen on 3390 (no capture grant here): its job is what counts"
plists_of "$LEGACY" | tee "$OUT/old-plists.txt"

# --- 2. the new install over it ---------------------------------------------------------------
sudo "$NEW/install-daemon.sh" -- -auth > "$OUT/new-install.log" 2>&1 && ok=1 || ok=0
check "the NEW install-daemon.sh over the old layout" $ok "$(grep -m1 '^== removed the old layout' "$OUT/new-install.log")"
wait_listen 3388 60
n=$(count 3388)
[ "$n" = 1 ] && ok=1 || ok=0
check "exactly one process listens on 3388" $ok "$n: $(listeners 3388 | awk '{print $1, $2, $3}' | tr '\n' ';')"
pid=$(listeners 3388 | awk 'NR == 1 {print $2}')
daemon_pid=$(sudo launchctl print "system/$ID.daemon" 2> /dev/null | awk '$1 == "pid" {print $3; exit}')
[ -n "$pid" ] && [ "$pid" = "$daemon_pid" ] && ok=1 || ok=0
check "it is the new daemon $ID.daemon" $ok "listener $pid, daemon $daemon_pid"
[ "$(count 3390)" = 0 ] && ok=1 || ok=0
check "nothing listens on 3390 (the old no-root server is gone)" $ok
left=$(plists_of "$LEGACY" | tr '\n' ' ')
[ -z "$left" ] && ok=1 || ok=0
check "no $LEGACY*.plist left in the three launchd folders" $ok "$left"
gone=1
for job in "system/$LEGACY.daemon" "gui/$ME/$LEGACY.agent" "gui/$ME/$LEGACY"; do
    if loaded "$job"; then gone=0; echo "      still loaded: $job"; fi
done
check "no old job is loaded" $gone

# --- 3. uninstall: nothing of either -------------------------------------------------------------
sudo bash "$APP/Contents/Resources/uninstall-daemon.sh" --app --logs > "$OUT/uninstall.log" 2>&1 && ok=1 || ok=0
check "uninstall-daemon.sh --app --logs (the app's own copy)" $ok "$(tail -1 "$OUT/uninstall.log")"
sleep 5
nothing() {
    left=""
    [ "$(count 3388)" = 0 ] || left="$left port-3388"
    [ "$(count 3390)" = 0 ] || left="$left port-3390"
    left="$left$(plists_of "$LEGACY" | tr '\n' ' ')$(plists_of "$ID" | tr '\n' ' ')"
    pgrep -f "^$APP/Contents/MacOS/" > /dev/null 2>&1 && left="$left process"
    for job in "system/$ID.daemon" "gui/$ME/$ID.agent" "system/$LEGACY.daemon" "gui/$ME/$LEGACY.agent" "gui/$ME/$LEGACY"; do
        loaded "$job" && left="$left $job"
    done
    [ -e "$APP" ] && left="$left app"
    left=$(echo $left)
    [ -z "$left" ]
}
nothing && ok=1 || ok=0
check "after uninstall nothing of the old or the new layout is left" $ok "$left"
sleep 15
nothing && ok=1 || ok=0
check "15 s later still nothing (nothing restarts)" $ok "$left"
echo "migration: $fails failure(s)"
exit $((fails > 0))
