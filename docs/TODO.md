# What waits after the safe point (2026-10-31)

Too many things were moving at once, so release 2026-10-31's safe point ships only what
has already passed its rounds:

- the Windows host `freerdp_host 20261031.6`: sound through WASAPI loopback, and uninstall
  restores the Ctrl+Alt+Del policy as install found it;
- the client `freerdp 20261031.3`, libavm `20261031.1`, xrdp `20261030.1`, and the page
  `freerdp_web 20261031.1`, as on main before;
- the Windows test fixes (memory log, a 5-minute unzip wait, held modifiers released), and
  the notes (CHANGELOG, pins.notes, host README).

Everything below waits. Take one item per round and keep one kit run at a time. Each item
says who owns it, what it waits on, and where it lives.

## Next pins: one per round, in this order

| # | What | Owner | Waits on | Where |
|---|------|-------|----------|-------|
| 1 | AVM `20261031.2` (`b132a0a6`): two encoder thread races fixed, bit-exact with `.1` | avm-6e | done: avm-release-kit run 41203636198 green (15/15, TSan included) | the second safe point, kit branch `safepoint-2` |
| 2 | Client `release-20261031.7` = `d7f066be3` from `integration-latest` (master dae0390a4 + the bitmap fix + AV2, no TLS retry) | freerdp-59 picked it | done: xrdp sway e2e 57/57, kit round 41199723802 | the second safe point (`safepoint-2`) |
| 3 | Mac host, a new pick replacing `20261031.4`: the extended keys (both ⌘, arrows, Home/End, PgUp/PgDn, Forward Delete, keypad Enter) reach the Mac | freerdp-d0 | its KBDEXT fix verified on the Mac | kit branch `mac-host` (local, not pushed); then the CI compile, then the release wiring (asset, install notes, Get a server) |
| 4 | Windows host with the stuck-keys fix: FreeRDP#13958, `integration-shadow-win` `be82c8dc0` (tested on X11 under Xvfb) | freerdp-59 picked it as `release-20261031.8` | the second safe point's Windows test: the check "keys: none still held" (if it fails, go back to host `.6` and the known-issue paragraph) | the second safe point (`safepoint-2`) |

## Bugs known, not fixed yet

- **Shadow server keeps a dropped client's keys held** (fixed in host `.8`, if its Windows check passes) (all hosts). No subsystem sets
  `ClientDisconnect` (`shadow_client.c:3137`), and `win_shadow_input_synchronize_event`
  (`win_shadow.c:115`) is a stub. Fixed as FreeRDP#13958 (each client's held keys are
  released when it leaves and at a Synchronize, unless another client holds them); waits for
  its Windows test (pin 4). Owner: freerdp-59. The kit's test works around it (`wininput.py release`),
  and the host README says how to clear it by hand.
- **A Windows reproduction of the stuck keys is still owed** (FreeRDP#13958 rests on the
  code and the X11 A/B). freerdp-59 has scripts on the UTM VM. On the kit's runner it would
  be: a client presses Win+Alt, then its process is killed (no disconnect PDU), then
  GetAsyncKeyState(VK_LWIN) in the console session is read, with host `.6` against `.8`.
- **TLS 1.3 to Windows' own Remote Desktop with LibreSSL**: its ClientHello leaves out
  `psk_key_exchange_modes`, and Schannel aborts. Reported as libressl/portable#1452 (a
  report, no code). The kit patches LibreSSL (`build/patches/libressl/`); drop the patch
  once LibreSSL ships a fix. FreeRDP#13944 (the TLS 1.2 retry) is closed.
- **The Windows demos still pass `/tls:enforce:1.2`** to Windows' own Remote Desktop. With
  the patch proven (TLS 1.3 SUCCESS against Server 2025), drop it from both demos
  (`test/wasm-demo.mjs`, `test/client-demo/hook/drive.py`).
- **The freerdp-tk demo on Windows** failed twice when nothing typed reached its PowerShell
  window (runs 41196854812, 41199723802), likely the held keys above. `b15ea10` lets go of
  them and logs which were held: read `tk-demo/run.log` in the next round to confirm.
- **Sound on the Windows runner** can't be tested (no playback device; Scream's driver
  won't install unattended). It's proven by hand on a Windows 11 PC (−12.0 dBFS, 321
  packets in 16 s) and by 聪哥's own test.
- **The Windows test's recorder sometimes runs far too long**: in kit run 41208207833 (first
  attempt) the web demo against the Windows host recorded for 2088 s instead of minutes, and
  the job hit its 45-minute limit; FreeRDP was fine (the page showed the demo, then a normal
  Disconnect). The rerun passed that demo. My earlier reading ("client `.3` stalls") was
  wrong: I had read the first attempt's artifact twice, and "AV1 frames 0" in the page's
  info panel shows in passing runs too (that counter looks broken). To do: cap the
  recording's length, and have the demo stop after a minute with no frame.
- **The SDL3 clients read freed memory for each connection dialog message** (garbled
  "����ection is being established" in client `.7`'s page log; upstream master d5d230ddd's
  `auto&` on a popped queue item; `sdlClip::ClipDataCb()` too). Fixed by freerdp-59 as
  FreeRDP#13961 (ASan: 4/4 use-after-free before, 0/4 after), in integration-latest's parts:
  the next client pick carries it.
- **The Windows test's flaky parts** (run 41208207833, second attempt): the page against
  Windows' own Remote Desktop came up without cross-origin isolation (the service worker's
  reload); the Ctrl+Alt+Del checks failed once ("the service sent the secure attention
  sequence"), after passing in every earlier round. Watch whether they come back.
- **The ARM builder image** sometimes fails on the Rocky/EPEL mirror (`dnf`, 3 tries), and
  then xrdp and the screens tests skip. Rerun the failed jobs.
- **This machine** is short of memory (about 2 GB free), and Claude Code stops background
  watchers. Check rounds by hand.

## Decisions waiting for 聪哥

- **Signing the Mac app.** It is ad hoc, so each update asks for Screen Recording and
  Accessibility again (freerdp-d0 measured it). The choices are a Developer ID (paid, and
  Gatekeeper stays silent), a fixed self-signed certificate kept as a CI secret (free, and
  keeps the permissions), or staying ad hoc.
- **FreeRDP#13925 (AV2):** a FreeRDP maintainer requested changes on 10-30 (a new caps
  version or new flags, not both). The av2-decoder-only commit (`f164292ac`) belongs in
  that PR. Its owner session isn't reachable.
- **The site:** a page release only when the page code changed. The site is published with
  `site.yml` from a kit release.

## Upstream, open (fork branches stay; see ~/.claude/upstream-ledger.md)

- FreeRDP: #13924 (/gfx:AV1), #13925 (AV2), #13931–#13935 (the Windows host),
  #13943 (rdpsnd), #13946 (padded bitmaps), #13952 (rdpsnd padding), #13954 (Windows
  sound), #13956 (monitor bounds 1601×901).
- freerdp-tk: congzhangzh/freerdp-tk#5 (the client version check: an unknown version is
  tried, not refused).
- LibreSSL: libressl/portable#1452.
- Mutter: mutter#5162 (the screens race).

## Work in progress elsewhere (other sessions own it)

- freerdp-d0: a Mac login-window service (stage 1, 聪哥 said go). Input there works only
  through `IOHIDPostEvent` (deprecated since macOS 11, it needs the console session's
  privilege). Then a second LaunchAgent plist in the kit's Mac host.
- avm-6e: AVM upstream submissions (its own ask to 聪哥), and the AV2 encoder in xrdp.

## This host

- Install the xrdp package with AV2 from the next kit release (Debian forky deb). Before
  restarting xrdp, check for live sessions and tell 聪哥. Then put AV2 first:
  `sudo sed -i 's/^order = \[ "AV1"/order = [ "AV2", "AV1"/' /etc/xrdp/gfx.toml`.

## Kit branches

| Branch | State |
|--------|-------|
| `safepoint` | the first safe point (main a2d77ac) |
| `safepoint-2` | the second safe point: the first plus AVM `20261031.2`, client `20261031.7`, host `20261031.8` |
| `host-sound` | PR #18: the safe point plus AVM `.2` and the client candidate; rebase onto main after the safe point, then use it for pins 1 and 2 |
| `mac-host` | local only; waits for pin 3 |
| `windows-host`, `xrdp-av2`, `libressl-psk`, `demo-ready` | merged; safe to delete with 聪哥's word |
