FreeRDP shadow server for Windows: share this PC's screen over RDP
=====================================================================

The programs in this folder let an RDP client (FreeRDP Web in a browser,
FreeRDP's own client, or Windows' Remote Desktop Connection) see and use
this PC's own screen: the desktop of whoever is logged in, and, through the
service, the logon and lock screens, UAC prompts and Ctrl+Alt+Del too. It
shares the one console desktop, like Remote Assistance or VNC; it does not
start sessions of its own. The picture is encoded in AV1.

  freerdp-shadow-service.exe   runs the shadow server as a Windows service
  freerdp-shadow-cli.exe       the shadow server itself
  winpr-hash.exe               a line of a SAM file (only for passwords that
                               are not Windows accounts, see below)

Install the service (in an administrator's PowerShell, in this folder)
-----------------------------------------------------------------------

  .\freerdp-shadow-service.exe install --allow-sas -- /bind-address:127.0.0.1 /gfx-av1

AV2 too, for the clients that offer it (the kit's FreeRDP clients and FreeRDP
Web; the others still get AV1): add /gfx-av2 after /gfx-av1. Smaller frames for
the same picture, for more processor time on both sides: this PC encodes with
libavm, and FreeRDP Web decodes in the page, in software.

It starts at once and with Windows, on port 3389. If Windows' own Remote
Desktop is turned on, it holds 3389 already: add /port:<another>, e.g. 3388. --allow-sas lets the service send
Ctrl+Alt+Del (it sets the policy SoftwareSASGeneration = 1); leave it out
if you do not want that. --log <folder> writes logs there. Remove it with

  .\freerdp-shadow-service.exe uninstall

It also puts back the Ctrl+Alt+Del policy as install found it (--allow-sas changes
it only when services could not send Ctrl+Alt+Del before).

Or, without a service, for the logged-on user's desktop only:

  .\freerdp-shadow-cli.exe /bind-address:127.0.0.1 /gfx-av1

Connect
-------

Logins are Windows accounts (Network Level Authentication, through
Windows' own security packages). Keep the server on 127.0.0.1 as above and
reach it through SSH (Windows' optional feature "OpenSSH Server"):

  ssh -L 13389:127.0.0.1:3389 <user>@<this PC>

then connect to 127.0.0.1:13389. FreeRDP Web: start a WebSocket gateway on this PC
(pip install websockify, then websockify 127.0.0.1:3390 127.0.0.1:3389) and
forward 3390 instead.

A Unix socket instead of TCP: /ipc-socket:<path> (Windows 10 1803 or later;
who may connect is the socket file's ACL). Windows' own sshd cannot forward
to a socket file; a small relay on this PC can.

Passwords that are not Windows accounts: set WINPR_NATIVE_SSPI=0 for the
server and give it /sam-file:<file>, one line per user from
winpr-hash -u <user> -p <password> -f sam. An NT hash works like the
password itself: keep the file's ACL strict.

What is in it: MANIFEST (the sources and their versions), licenses\.
More: https://github.com/congzhangzh/rdp-release-kit
