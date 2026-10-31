FreeRDP's shadow server for macOS
=================================

Share this Mac's own screen with RDP clients: the kit's FreeRDP clients, FreeRDP Web,
mstsc. What the user sees is what the client sees; the sound the Mac plays comes along.

  FreeRDP-Shadow.app         the shadow server (FreeRDP's freerdp-shadow-cli, as an app)
  org.freerdp.shadow.plist   a LaunchAgent: starts it at login, in your session
  winpr-hash                 a line of a SAM file (not needed for macOS accounts)

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

AV2 too, for the clients that offer it (the kit's FreeRDP clients and FreeRDP Web; the
others get AV1): add <string>/gfx-av2</string> after /gfx-av1 in the plist, and restart.

Remove it with

  launchctl bootout gui/$(id -u)/org.freerdp.shadow
  rm ~/Library/LaunchAgents/org.freerdp.shadow.plist
  rm -R /Applications/FreeRDP-Shadow.app

Connect
-------

The login is the macOS account running it (your own), checked by macOS (PAM) over TLS
security (/sec:tls in the plist; keep it there). Keep the server on 127.0.0.1 as
above and reach it through SSH (System Settings > General > Sharing > Remote Login):

  ssh -L 13389:127.0.0.1:3389 <user>@<this Mac>

then connect a client to 127.0.0.1:13389.

What it cannot do
-----------------

It runs in your session, after you have logged in: it cannot show the login window,
or this Mac before anyone logs in (a LaunchAgent has no screen until then).
