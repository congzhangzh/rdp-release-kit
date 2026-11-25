FreeRDP's shadow server for macOS
=================================

Share this Mac's own screen with RDP clients: the kit's FreeRDP clients, FreeRDP Web,
mstsc. What the user sees is what the client sees; the sound the Mac plays comes along.

  FreeRDP-Shadow.app         the shadow server (FreeRDP's freerdp-shadow-cli, as an app),
                             with freerdp-shadow-agent for the daemon mode
  org.freerdp.shadow.plist   a LaunchAgent: starts it at login, in your session (no root)
  org.freerdp.shadow.daemon.plist, org.freerdp.shadow.agent.plist,
  install-daemon.sh, uninstall-daemon.sh
                             the daemon mode (root): from the login window on, see
                             "The daemon mode" below
  winpr-hash                 a line of a SAM file (not needed for macOS accounts)

Install one of the two, the LaunchAgent below or the daemon mode: both listen on
127.0.0.1:3388.

Install
-------

  cp -R FreeRDP-Shadow.app /Applications/
  xattr -dr com.apple.quarantine /Applications/FreeRDP-Shadow.app
  cp org.freerdp.shadow.plist ~/Library/LaunchAgents/
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.freerdp.shadow.plist

The first start asks for two permissions, in System Settings > Privacy & Security:
Screen & System Audio Recording (the picture and the sound) and Accessibility (the
keyboard and mouse). Allow FreeRDP Shadow in both, then restart it:

  launchctl kickstart -k gui/$(id -u)/org.freerdp.shadow

After an update, macOS asks for both permissions again: the app is signed without a
developer certificate (ad hoc), so macOS knows it only by its exact build. Remove
FreeRDP Shadow from both lists (the minus button), then allow the new one.

AV2 is on: the clients that offer it (the kit's FreeRDP clients and FreeRDP Web) get AV2,
the others AV1. AV1 only: change <string>/gfx-av2</string> in the plist to
<string>/gfx-av2:off</string> (AV2 is on by default since FreeRDP 20261110.3), and restart.

H.264 goes to the clients without AV1 or AV2 (Windows' own Remote Desktop client, most
others), encoded by the Mac's own VideoToolbox (in hardware where the Mac has it), as
AVC420: the plist's -gfx-avc444 leaves AVC444 out, which sent 15-18 times the bytes for
the same screen (its median frame about 60 times bigger). Remove that line to allow
AVC444. VideoToolbox has no AV1 or AV2 encoder: those stay software encodes (libaom,
libavm).

Remove it with

  launchctl bootout gui/$(id -u)/org.freerdp.shadow
  rm ~/Library/LaunchAgents/org.freerdp.shadow.plist
  rm -R /Applications/FreeRDP-Shadow.app

The size of the picture
-----------------------

It shares this Mac's own screen as it is: the displays, their resolution and their scale
stay what macOS has set, and a client's window shows that screen, scaled if the window is
smaller. The server cannot take another size (no Display Control), so a client's
/dynamic-resolution, its /multimon layout and its HiDPI scale factors change nothing here,
and the client logs no "HiDPI:" line.
For a session that follows the client's windows and monitors, HiDPI included, use a server
that starts sessions of its own: xrdp, or Windows' own Remote Desktop.

Connect
-------

The login is the macOS account running it (your own), checked by macOS (PAM) over TLS
security (/sec:tls in the plist; keep it there). Keep the server on 127.0.0.1 as
above and reach it through SSH (System Settings > General > Sharing > Remote Login):

  ssh -L 13388:127.0.0.1:3388 <user>@<this Mac>

then connect a client to 127.0.0.1:13388. It listens on 3388, the kit's shadow port on
every OS (3389 is for the system's own RDP servers).

What it cannot do
-----------------

It runs in your session, after you have logged in: it cannot show the login window,
or this Mac before anyone logs in (a LaunchAgent has no screen until then). The daemon
mode can.

The daemon mode
---------------

The server runs as root, started by launchd at boot, and an agent captures the screen
and posts the input in the session on the console: at the login window, and in each
user's session once they log in. One connection lasts from the login window through the
login to the desktop. The login is any local account but root at the login window, the
user on the console after that (PAM, /sec:tls).

  org.freerdp.shadow.daemon  /Library/LaunchDaemons/org.freerdp.shadow.daemon.plist
                             the server, as root, on 127.0.0.1:3388; Mach service
                             org.freerdp.shadow (FREERDP_SHADOW_MAC_AGENT_SERVICE)
  org.freerdp.shadow.agent   /Library/LaunchAgents/org.freerdp.shadow.agent.plist
                             freerdp-shadow-agent, at the login window (as root) and in
                             each user's session (as that user)
  the app                    /Applications/FreeRDP-Shadow.app (owned by root)

First remove the LaunchAgent org.freerdp.shadow above if you installed it (both use
3388; install-daemon.sh refuses while it runs on the same port). Then, in the unpacked
folder:

  sudo ./install-daemon.sh                  (--port <port> for another port)

Then allow freerdp-shadow-agent, once, in your session (System Settings > Privacy &
Security): Screen & System Audio Recording and Accessibility; with +, the program is
/Applications/FreeRDP-Shadow.app/Contents/MacOS/freerdp-shadow-agent. Restart it:

  launchctl kickstart -k gui/$(id -u)/org.freerdp.shadow.agent

The grants hold at the login window too. As with the app, an update asks for both again
(signed ad hoc). Run install-daemon.sh again to update or to change the port.

Logs: one file per job, appended to by every start:

  /var/log/freerdp-shadow/daemon.log
  /var/log/freerdp-shadow/agent.log         (every session's agent)

Clear one while it runs with  sudo sh -c ': > /var/log/freerdp-shadow/daemon.log'
(the same for agent.log); uninstall-daemon.sh --logs removes the folder.

Remove it with

  sudo ./uninstall-daemon.sh                (--app: the app too; --logs: the logs too)

It stops the agents and the daemon and removes both plists, so launchd starts neither
again.
