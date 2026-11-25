#!/bin/bash
# The daemon mode of FreeRDP's shadow server for macOS (README.txt, "The daemon mode"):
#
#   sudo ./install-daemon.sh [--port <port>] [-- <more server options>]
#
# run from the unpacked archive. It installs FreeRDP-Shadow.app to /Applications, the root
# LaunchDaemon org.freerdp.shadow.daemon (the server: clients, TLS, PAM login, encoder; on
# 127.0.0.1:3388 by default) and the LaunchAgent org.freerdp.shadow.agent (the capture and the
# input, at the login window and in each user's session), and starts both. Run it again to
# update or to change the port: it stops what it installed before. It refuses to run while the
# no-root LaunchAgent org.freerdp.shadow (the same server in a user's session) listens on the
# same port: remove that one first, or pass --port.
# Bash 3.2 (macOS's own) is enough.
set -eu

APP=/Applications/FreeRDP-Shadow.app
DAEMON=org.freerdp.shadow.daemon
AGENT=org.freerdp.shadow.agent
DAEMON_PLIST=/Library/LaunchDaemons/$DAEMON.plist
AGENT_PLIST=/Library/LaunchAgents/$AGENT.plist
LOGS=/var/log/freerdp-shadow
PB=/usr/libexec/PlistBuddy

die() { echo "install-daemon.sh: $*" >&2; exit 1; }

PORT=3388
EXTRA=()
while [ $# -gt 0 ]; do
    case $1 in
        --port) [ $# -ge 2 ] || die "--port needs a number"; PORT=$2; shift 2 ;;
        --port=*) PORT=${1#--port=}; shift ;;
        --) shift; EXTRA=("$@"); break ;;
        -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $1 (--help)" ;;
    esac
done
case $PORT in '' | *[!0-9]*) die "--port: not a number: $PORT" ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port: out of range: $PORT"
[ "$(id -u)" = 0 ] || die "run it with sudo"

HERE=$(cd "$(dirname "$0")" && pwd)
for f in FreeRDP-Shadow.app/Contents/MacOS/freerdp-shadow-cli \
    FreeRDP-Shadow.app/Contents/MacOS/freerdp-shadow-agent "$DAEMON.plist" "$AGENT.plist"; do
    [ -e "$HERE/$f" ] || die "no $f next to this script (run it from the unpacked archive)"
done

# the uids that have a GUI session now (the user on the console and any others logged in)
gui_uids() {
    { stat -f %u /dev/console; ps -axo uid=; } 2> /dev/null | awk '$1 > 0' | sort -un |
        while read -r uid; do
            if launchctl print "gui/$uid" > /dev/null 2>&1; then echo "$uid"; fi
        done
}

# 1. the no-root LaunchAgent org.freerdp.shadow on the same port: refuse
for uid in $(gui_uids); do
    info=$(launchctl print "gui/$uid/org.freerdp.shadow" 2> /dev/null) || continue
    # its /port: argument, or the server's own default (3389)
    app_port=$(printf '%s\n' "$info" | grep -oE '/port:[0-9]+' | head -1 | cut -d: -f2)
    app_port=${app_port:-3389}
    if [ "$app_port" = "$PORT" ]; then
        user=$(id -un "$uid" 2> /dev/null || echo "uid $uid")
        die "the LaunchAgent org.freerdp.shadow (the server in $user's session) listens on" \
            "port $PORT. Remove it first, as $user (README.txt):" \
            "launchctl bootout gui/$uid/org.freerdp.shadow;" \
            "rm ~/Library/LaunchAgents/org.freerdp.shadow.plist; or pass --port <another port>"
    fi
done

# 2. what this script installed before: stopped (an update, another port)
for uid in $(gui_uids); do
    launchctl bootout "gui/$uid/$AGENT" > /dev/null 2>&1 || true
done
launchctl bootout "loginwindow/$AGENT" > /dev/null 2>&1 || true
launchctl bootout "system/$DAEMON" > /dev/null 2>&1 || true
pkill -f "^$APP/Contents/MacOS/freerdp-shadow-agent" 2> /dev/null || true

# 3. the port must be free now
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN > /dev/null 2>&1; then
    die "something else listens on port $PORT: $(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | sed -n 2p);" \
        "stop it or pass --port <another port>"
fi

# 4. the app, root's: a root daemon must not run a program its users can change
echo "== $APP"
rm -rf "$APP"
ditto "$HERE/FreeRDP-Shadow.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2> /dev/null || true
chown -R root:wheel "$APP"
chmod -R go-w "$APP"
codesign --verify --strict "$APP" || die "the app's signature does not verify in $APP"

# 5. one log per job, appended to by every start (never one file per start); the agents that
# run as a user write theirs too
echo "== $LOGS"
mkdir -p "$LOGS"
chown root:wheel "$LOGS"
chmod 755 "$LOGS"
touch "$LOGS/daemon.log" "$LOGS/agent.log"
chown root:wheel "$LOGS/daemon.log" "$LOGS/agent.log"
chmod 644 "$LOGS/daemon.log"
chmod 666 "$LOGS/agent.log"

# 6. the two jobs, root:wheel 644; the daemon's port and extra options written into its copy
echo "== $DAEMON_PLIST"
install -m 644 -o root -g wheel "$HERE/$DAEMON.plist" "$DAEMON_PLIST"
i=0
while arg=$("$PB" -c "Print :ProgramArguments:$i" "$DAEMON_PLIST" 2> /dev/null); do
    case $arg in /port:*) "$PB" -c "Set :ProgramArguments:$i /port:$PORT" "$DAEMON_PLIST" ;; esac
    i=$((i + 1))
done
# after the last argument (i is their count now), one by one
for arg in ${EXTRA[@]+"${EXTRA[@]}"}; do
    case $arg in *[[:space:]]*) die "an option with a space is not supported: '$arg'" ;; esac
    "$PB" -c "Add :ProgramArguments:$i string $arg" "$DAEMON_PLIST"
    i=$((i + 1))
done
echo "== $AGENT_PLIST"
install -m 644 -o root -g wheel "$HERE/$AGENT.plist" "$AGENT_PLIST"
plutil -lint "$DAEMON_PLIST" "$AGENT_PLIST" > /dev/null

# 7. start the daemon. It opens its port only once an agent has said hello (it has no screen of its
# own), so it is not waited for here but after the agents start (kit round 45670622530: waiting
# first, before any agent, timed out every time)
echo "== starting $DAEMON (system)"
# a label disabled before (launchctl disable, e.g. to stop an earlier install that looped)
# stays disabled across bootout and reinstall, and launchd refuses to bootstrap it: enable it
launchctl enable "system/$DAEMON"
launchctl bootstrap system "$DAEMON_PLIST"

# 8. the agent: in every GUI session now; launchd starts it by itself at the next login
# window and in each new session (LimitLoadToSessionType LoginWindow, Aqua)
console=$(stat -f %u /dev/console)
started=""
for uid in $(gui_uids); do
    launchctl enable "gui/$uid/$AGENT" 2> /dev/null || true
    if launchctl bootstrap "gui/$uid" "$AGENT_PLIST" 2> /dev/null; then
        started="$started $(id -un "$uid" 2> /dev/null || echo "uid $uid")"
    fi
done
if [ "$console" = 0 ]; then
    # nobody logged in: the login window on the console
    if launchctl bootstrap loginwindow "$AGENT_PLIST" 2> /dev/null; then
        started="$started loginwindow"
    else
        echo "   the agent starts with the next login window (or a restart)"
    fi
fi
echo "== the agent started in:${started:- no session yet}"

# 9. the daemon listens once an agent has said hello: up to 60 s (its own wait for a hello); without
# the grants below an agent may not get that far, so a daemon still waiting is not a failed install
up=0
for _ in $(seq 1 60); do
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN > /dev/null 2>&1; then up=1; break; fi
    sleep 1
done
if [ $up = 1 ]; then
    state="listens on 127.0.0.1:$PORT"
else
    state="waits for its agent: it listens on 127.0.0.1:$PORT once the agent in the console session says hello (allow it as below, then restart it; see $LOGS/daemon.log)"
fi

cat << EOF

Installed: $DAEMON $state (/sec:tls: the Mac's own accounts), with the
agent $AGENT at the login window and in each user's session.

Now allow the agent, once, in a user's session (System Settings > Privacy & Security):
  Screen & System Audio Recording:  freerdp-shadow-agent
  Accessibility:                    freerdp-shadow-agent
(+, then Command-Shift-G: $APP/Contents/MacOS/freerdp-shadow-agent)
then restart it, as that user:  launchctl kickstart -k gui/\$(id -u)/$AGENT
The grants hold at the login window too. The app is signed ad hoc: after each update macOS
asks again (remove the old entries, allow the new one).

Logs: $LOGS/daemon.log and $LOGS/agent.log
Remove: sudo bash $APP/Contents/Resources/uninstall-daemon.sh   (or ./uninstall-daemon.sh here)
EOF
