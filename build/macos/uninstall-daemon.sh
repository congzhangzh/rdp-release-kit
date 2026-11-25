#!/bin/bash
# Removes the daemon mode that install-daemon.sh installed (README.txt, "The daemon mode"):
#
#   sudo ./uninstall-daemon.sh [--app] [--logs]
#
# It stops the agent in every session and the daemon, and removes their two plists, so
# launchd starts neither again. --app removes /Applications/FreeRDP-Shadow.app too (kept while
# a user's no-root LaunchAgent org.freerdp.shadow still runs it); --logs removes
# /var/log/freerdp-shadow. Safe to run again, and when nothing is installed.
# Bash 3.2 (macOS's own) is enough.
set -eu

APP=/Applications/FreeRDP-Shadow.app
DAEMON=org.freerdp.shadow.daemon
AGENT=org.freerdp.shadow.agent
DAEMON_PLIST=/Library/LaunchDaemons/$DAEMON.plist
AGENT_PLIST=/Library/LaunchAgents/$AGENT.plist
LOGS=/var/log/freerdp-shadow

die() { echo "uninstall-daemon.sh: $*" >&2; exit 1; }

RM_APP=0
RM_LOGS=0
while [ $# -gt 0 ]; do
    case $1 in
        --app) RM_APP=1 ;;
        --logs) RM_LOGS=1 ;;
        -h | --help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $1 (--help)" ;;
    esac
    shift
done
[ "$(id -u)" = 0 ] || die "run it with sudo"

gui_uids() {
    { stat -f %u /dev/console; ps -axo uid=; } 2> /dev/null | awk '$1 > 0' | sort -un |
        while read -r uid; do
            if launchctl print "gui/$uid" > /dev/null 2>&1; then echo "$uid"; fi
        done
}

# the plists first: a session that starts now no longer loads the agent
rm -f "$AGENT_PLIST" "$DAEMON_PLIST"
# then the agents (each would end and be started again once the daemon is gone), the daemon
for uid in $(gui_uids); do
    if launchctl bootout "gui/$uid/$AGENT" > /dev/null 2>&1; then echo "== stopped $AGENT (uid $uid)"; fi
done
if launchctl bootout "loginwindow/$AGENT" > /dev/null 2>&1; then echo "== stopped $AGENT (login window)"; fi
if launchctl bootout "system/$DAEMON" > /dev/null 2>&1; then echo "== stopped $DAEMON"; fi
# an agent left running without launchd (started by hand)
if pkill -f "^$APP/Contents/MacOS/freerdp-shadow-agent" 2> /dev/null; then echo "== ended a freerdp-shadow-agent"; fi
# a root server from the app left without launchd (the no-root LaunchAgent's runs as its user)
if pkill -U 0 -f "^$APP/Contents/MacOS/freerdp-shadow-cli" 2> /dev/null; then echo "== ended a root freerdp-shadow-cli"; fi

if [ $RM_APP = 1 ]; then
    users=""
    for uid in $(gui_uids); do
        if launchctl print "gui/$uid/org.freerdp.shadow" > /dev/null 2>&1; then
            users="$users $(id -un "$uid" 2> /dev/null || echo "uid $uid")"
        fi
    done
    if [ -n "$users" ]; then
        echo "== kept $APP: the LaunchAgent org.freerdp.shadow still runs it for:$users"
    else
        rm -rf "$APP"
        echo "== removed $APP"
    fi
fi
if [ $RM_LOGS = 1 ]; then
    rm -rf "$LOGS"
    echo "== removed $LOGS"
fi

# nothing of the daemon mode is left loaded or running
left=""
if launchctl print "system/$DAEMON" > /dev/null 2>&1; then left="$left $DAEMON"; fi
for uid in $(gui_uids); do
    if launchctl print "gui/$uid/$AGENT" > /dev/null 2>&1; then left="$left $AGENT(uid $uid)"; fi
done
if pgrep -f "^$APP/Contents/MacOS/freerdp-shadow-agent" > /dev/null 2>&1; then
    left="$left freerdp-shadow-agent"
fi
if pgrep -U 0 -f "^$APP/Contents/MacOS/freerdp-shadow-cli" > /dev/null 2>&1; then
    left="$left freerdp-shadow-cli(root)"
fi
[ -z "$left" ] || die "still loaded or running:$left"
echo "Removed: the daemon mode ($DAEMON, $AGENT) is not loaded and its plists are gone."
