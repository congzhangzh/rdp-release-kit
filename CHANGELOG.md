# Changelog

What changed in the kit, and why: the sources it pins (FreeRDP, SDL, dav1d,
xrdp…), how they are built, and how the results are tested. Newest first,
one section per day. Each pre-release (`web-…`, `xrdp-preview-…`,
`pipewire-module-xrdp-…`, `demo-…`) names the kit commit it was built from;
the section of that day says what it holds. What every product is built
from right now, and what our own changes to a source fix:
[README, "The pins at a glance"](README.md#the-pins-at-a-glance).

Every change that alters what is built (a pin, a build option, a patch, a
toolchain) gets an entry here in the same commit.

## 2026-10-31

- **`avm` `20261031.2`** (`b132a0a6`, avm-6e's): two encoder thread races fixed (tile-packing
  counters, TMVP bands); bit-exact with `20261031.1` at 1 and 4 threads. The first race is why
  `20261031.1`'s ARM bench stream differed from x86. avm-release-kit's new thread-safety gate
  (TSan): 14/14 on this pick, 12/14 failing on `20261031.1`.
- **Upstream, TLS 1.3 to Windows' own Remote Desktop**: FreeRDP#13944 (the retry with TLS
  1.2) is closed, since the cause is LibreSSL's ClientHello; it is reported to LibreSSL as
  libressl/portable#1452 (a bug report, no code). `freerdp` `20261031.3` keeps the retry
  commit; the kit's LibreSSL patch is the fix for the Windows and web clients until LibreSSL
  decides.
- **`freerdp_host` `20261031.6`** (`c4a445237`, freerdp-59's, from integration-shadow-win):
  uninstall puts back the Ctrl+Alt+Del policy as install found it (`SoftwareSASGeneration`;
  install keeps the old state in the service's key and changes it only when services could
  not send Ctrl+Alt+Del; tested from not set, 2 and 3), so README.txt drops its `reg delete`.
  It is `20261031.5` plus that, and `20261031.5` (`d2136687d`) made the Windows host's sound
  work. It offered Opus with a block alignment of 4, so rdpsnd padded every packet and the
  client's decoder gave up after the first one; now 1 (FreeRDP#13954; the generic fix in
  rdpsnd's server is freerdp-d0's #13952). Measured on a Windows 11 PC: a 1 kHz tone at
  -12 dBFS captured by the shadow server came out at -12.0 dBFS on the client, 321 packets
  in 16 s (before: 1, then silence). The runner has no sound card, so the kit's test still
  says SKIP there. Rebuilt on master dae0390a4; the 1601 x 901 fix is FreeRDP#13956.
- **LibreSSL patched: NLA over TLS 1.3 to Windows' own Remote Desktop** (聪哥: "patch
  libressl"). LibreSSL's TLS 1.3 client sends `psk_key_exchange_modes` only when it means to
  resume, so a first connection has none; Windows' Schannel then fails issuing its session
  ticket and ends the connection with internal_error, right on the first CredSSP message.
  OpenSSL always sends it, so the kit's Linux and macOS clients (OpenSSL) connected and the
  Windows and web clients (LibreSSL) did not (freerdp-59, on a Windows 11 host: a minimal
  LibreSSL client 0/3, patched 3/3). `build/patches/libressl/0001-tls13-send-psk-kex-modes.patch`
  sends it always, as OpenSSL does; LibreSSL's master still has the old condition
  (2026-10-31). The kit applies a source's patches after unpacking (`build/lib.sh`,
  `build/patches/<name>/*.patch`), and their hash joins its build stamp. The Windows run's
  TLS probe (native client, no `/tls` option) tells whether it works; the demos keep
  `/tls:enforce:1.2` until it does.
- **Correction, `freerdp` `20261031.3`**: its TLS 1.2 retry (FreeRDP#13944) never fires with
  LibreSSL, where the failure shows on the first write, not as the alert it waits for; it
  needs rework (freerdp-59). The entry below said every client reconnects with TLS 1.2.
- **libavm `20261031.1`** (`02733e96a`, avm-6e's): speed 10's time budget (opt-in), the
  per-frame mode-info clear from 3.3 to 0.3 ms, SIMD avg 8x8; bit-exact.

## 2026-10-30

- **AV2, in every client and the Windows host** (聪哥: "go ahead", with AV2 opt-in next to
  AV1). A new pin, **`avm` `20261030.1`** (`dc33252c9`): libavm, AV2's reference, from
  the AVM work's own release (its release kit gates it: 56/56 decode vectors on x86_64,
  aarch64 and wasm), built here with the same options (its two ML encoder experiments
  off, so no TensorFlow Lite and nothing downloaded during the build). **`freerdp`
  `20261030.3`** (`57d847e65`): integration-latest-av2, the clients' FreeRDP plus the AV2
  extension, FreeRDP#13925 (5 commits); the Linux, Windows and macOS clients now
  decode AV2 with libavm and offer it, and servers keep picking AV1 unless told to use
  AV2. The web client too since **`freerdp` `20261030.5`** (`83e58241c`): our
  `av2-decoder-only` commit lets av2.c link a decoder-only libavm (`WITH_AVM_ENCODER=OFF`,
  libavm with `CONFIG_AV2_ENCODER=0`, as the AVM release kit builds it for wasm): its
  WebAssembly grows 10.6 -> 12.6 MB (+19 %; the whole library, encoder included, made it
  15.9 MB, so 20261030.4's kit left AV2 out of the page). **freerdp-web `20261030.5`**:
  About names the AV2 decoder (libavm, in the page). `test/windows-host.ps1` also logs
  the web client in to the AV2 server: the server must confirm AV2 (FRDP_2) for it.
  On ARM64 Windows libavm is built with `CONFIG_RUNTIME_CPU_DETECT=0`: its
  `arm_cpudetect.c` knows MSVC's way to ask the CPU, not mingw clang's, and NEON is in
  every ARM64 CPU (run 41116070345's windows (aarch64) job failed there).
  **`freerdp_host` `20261030.4`** (`7ee083d79`): the Windows host's FreeRDP plus the
  same extension, so its shadow server encodes AV2 when started with `/gfx-av2` (the
  service's install line keeps AV1). `test/windows-host.ps1` adds an AV2 session with the
  run's own client: the frames must come in as `RDPGFX_CODECID_AV2` (a scratch run of the
  same build: 136 of them, run 41110824436).
- **AV2 in the web client, fixed; libavm `20261030.2`** (`faad89dfe`). Run 41117771521
  built every native client with AV2 but not the web client: a decoder-only libavm
  installs no `avm_encoder.h`, and the earlier local build had passed only on headers a
  full build had left in its cache. Our FreeRDP commit `av2-decoder-only` now leaves the
  encoder's headers, fields and code out when libavm has no encoder (`#if` guards instead
  of stubs); **`freerdp` `20261030.6`** carries it (integration-latest-av2). libavm
  20261030.2 (the AVM release: NEON high-bit-depth loop filter, SIMD128 for WebAssembly)
  is built for the browser with `AVM_TARGET_CPU=x86`, its SSE kernels compiled to
  SIMD128, 1.3-1.5x faster decoding; checked with a build from an empty work tree.
- **libavm `20261030.3`** (`45f70cd11`). The encoder's realtime speed 10 (camera-like
  content) decides blocks without the full RD search: 1440p on 4 threads goes from 25 to
  about 35 fps in the AVM release's own measure, at +11.6 % BD-rate, on speed 10 only;
  speed 9, which the Windows host uses for screens, is unchanged. Two per-block clears are
  trimmed, bit-exact, in the decoder too. libavm now asks an ARM64 Windows CPU what it has
  when built with mingw, so the Windows ARM64 client gets its run-time CPU check back.
- **freerdp-web `20261030.6`** (`dd551139d`): Session settings' Video is a list of codecs
  in an order (聪哥's idea): *Least data*, *Least CPU* and *Custom* (drag and drop, or a
  row's arrows) next to Automatic, which still sends a bare `/gfx`. RDP cannot send an
  order (the server confirms the best capability set it knows), so the page keeps the
  list's order by leaving out a codec the server would take before one placed above it.
- **`freerdp_host` `20261031.2`** (`39bc96a1`, freerdp-59's): `20261030.7` plus
  shadow-win-monitor-bounds. Windows gives a monitor's right and bottom as exclusive bounds,
  the shadow core read them as inclusive: a 1600 x 900 screen became a 1601 x 901 surface, the
  copy rounded to 16 rows and clipped to it read one row past the 1600 x 900 capture, and the
  server died on the first frame (run 41166695002, the first with a 1600 x 900 screen; at
  1024 x 768 the rounding happened to fit, and clients were told 1025 x 769 since 2014).
- **freerdp-web `20261030.7`**: only its page test changes, which still chose the AV1 4:2:0
  that 20261030.6 replaced and so stopped `site.yml` before 20261030.6 went live (site run
  41164816290; the live site stayed on 20261031.1). It chooses Least data now.
- **libavm `20261030.4`** (`caea56916`): the encoder's realtime speed 10 at the middle
  point 聪哥 chose between speed and quality: against the full RD search +4.8 % BD-rate
  (was +11.6 %) for about 11 % more encoding time (1440p in the AVM release's CI: x86
  17.4 -> 16.1 fps, ARM 23.8 -> 21.4 fps); the decoder and screen content are unchanged.
- **The Windows host's demo, as the others** (聪哥: Start's search was slow, and what was
  typed landed in it; a dialog about the paging file sat on the desktop; the desktop
  filled half the picture). `test/wasm-demo.mjs` starts Notepad from Win+R's Run box (a
  new `chordRemote`: a key with the Windows key held), then `webdemo` from it: Firefox on
  the Windows PC with Big Buck Bunny next to the WebGL Aquarium, the same page and
  settings as on the Linux servers (`test/demo/media.html`, `user.js`); the captions
  claim no sound, which the Windows shadow server does not send yet.
  `test/windows-host.ps1` sets the runner's screen to 1600 x 900 before any server starts
  (1024 x 768 before; the shadow server shares the screen as it is), closes the "System
  Properties" dialog, serves the page on 127.0.0.1:8000 and puts `webdemo.cmd` where Run
  finds it. `windows-host.yml` hands it the media from `demo.yml`'s cache. The video also
  joins the intro (demo.json's `videos`, address `#windows-host`).
- **freerdp-tk on Windows, a video** (聪哥: Windows' own Remote Desktop as the server,
  and the same video and fish as the other demos). `test/client-demo/windows.ps1` on the
  Windows runner: the kit's Windows client unpacked from its zip in a PowerShell window,
  freerdp-tk started from it, a connection to Windows' own Remote Desktop on the same PC
  (127.0.0.2, a session of its own for the test user, whose profile is made first),
  Notepad and then `webdemo` from Win+R (the client holds the keyboard), disconnect,
  freerdp-tk again and the saved connection, its password from Credential Manager.
  `hook/drive.py` keeps its steps; its pointer and keys now go through a small layer,
  xdotool on Linux as before, Windows' SendInput with scan codes on Windows
  (`hook/wininput.py`). ffmpeg records the screen (gdigrab), `winrec.py` the speakers
  (WASAPI loopback; a runner without a sound device gives a silent video), muxed at the
  measured offset. It joins Get a client's freerdp-tk videos (demo.json's `clients`).
- **freerdp-web `20261031.1`**: Get a server shows Windows' own Remote Desktop (nothing to
  install) before the shadow server, and install.json's `av2` (written when the xrdp
  packages have AV2) as an AV2 part with its line.
- **`freerdp` `20261031.3`** (`99a0bd94c`, freerdp-59's): `20261031.1` plus
  tls13-nla-fallback, with 聪哥's go. Windows Server 2025's own Remote Desktop accepts a TLS
  1.3 handshake, then answers the first CredSSP message with a fatal internal_error alert
  (TLS 1.2 works; run 41176456545's probe). When 1.3 was negotiated, no maximum was set
  and that authenticated alert comes, the client connects once more with TLS 1.2 and says
  so in its log. `/tls:enforce:1.3` still fails, as asked. The Windows run's no-`/tls`
  probe proves it; the demos keep `/tls:enforce:1.2` until it does.
- **`freerdp` `20261031.1`** (`b646cb806`, freerdp-59's pick): `20261030.6` plus one
  commit, update-bitmap-padded-width: a legacy bitmap wider than its rectangle is accepted
  again; only a rectangle wider than its bitmap (memory) is refused. With 20261030.6, every
  client of the kit lost xrdp sessions that use legacy bitmap updates (freerdp-59 found it
  through avm-6e's sway e2e: "Invalid BITMAP_DATA: width=12 != right - left=8", then the
  session dropped). Its proof: xrdp's sway-systemd e2e 57/57 with this client (the
  microphone records again), FreeRDP's new TestUpdateBitmap; here, the login test below.
- **The native login test types, without GFX** (`test/xrdp-session.sh`): freerdp-59 found
  that FreeRDP master 343f23134 (#13884) refuses xrdp's legacy bitmap updates, whose bitmap
  is padded to a multiple of 4 pixels while the rectangle keeps its width, and drops the
  session; the kit's clients since `freerdp` `20261030.6` have it. The tests missed it: with
  GFX nothing is legacy, and the sway login (`/bpp:24`, legacy) never changed the screen. Now
  the Xorg session is joined again with `/bpp:24` and typed in, and so is sway: the client
  must stay connected with no "Invalid BITMAP_DATA". It fails on the 20261030.6 client and is
  meant to pass on the fixed one (freerdp-59's update-bitmap-padded-width).
- **`xrdp` `20261030.1`** (`4986f5c7`, avm-6e's pick of integration-wlup-all): the kit's
  xrdp (release-20261028.1's stack) plus the AV2 encoder (libavm), so the packages are built
  with `--enable-av2`. In avm-6e's runs: make check 295/295, AV2 end to end 17/17 (4:2:0 and
  4:4:4, every frame acknowledged, AV1 and H.264 still for the others), the wlup suites green
  (sway 42/42 and 57/57, GNOME 46/46, KDE 39/39, with FreeRDP 1ba0aa521 as the client). The
  kit's web test logs in a third time with `XRDP_AV2=1`: AV2 first in `gfx.toml` (the release
  notes' line), and xrdp's log must say it started an AV2 session.
- **xrdp packages are built with AV2 when the pinned xrdp has it** (聪哥: xrdp with AV2,
  on this machine too): `build/build-xrdp-pkg.sh` builds libavm from `sources.lock`
  (static, the AVM release kit's options, the encoder only) and passes `--enable-av2` when
  xrdp's `configure.ac` offers it (avm-6e's encoder, FreeRDP's FRDP_2 / AV2 codec id), then
  checks configure's summary; `NO_AV2=1` (a release marked `no-av2`) leaves it out.
  Fedora's build image gets `gcc-c++` (libavm's CMake project declares C++). Today's xrdp
  pin has no `--enable-av2`, so its packages are as before until the pin moves. Even then
  AV2 is the server's to turn on, as everywhere: the package's `gfx.toml` keeps
  `order = [ "AV1", "H.264", "RFX" ]`, and `"AV2"` put first there (as its comment says)
  makes xrdp offer it; every FreeRDP client of the kit, the page's included, takes it.
- **The demos' Firefox skips its terms-of-use dialog** (`test/demo/user.js`): newer Firefox,
  the Windows runner's, opened on "Welcome to Firefox" in front of the video and the Aquarium.
- **Windows' own Remote Desktop takes TLS 1.2 from our clients, not 1.3** (run 41176456545:
  the native client's `/auth-only` against Windows Server 2025's own server failed by default
  and with `/tls:enforce:1.3`, and passed with `/tls:enforce:1.2`; the page got "tlsv1 alert
  internal error" from Windows). Until a client release fixes it (freerdp-59 is on it), the
  two demos to it pass `/tls:enforce:1.2` as a user would, in the page's Extra options and in
  freerdp-tk's extra arguments, and their checks ask for a session, not a file: the page's
  data in, freerdp-tk's both visits. Win+D before `webdemo`, so Firefox opens in front of
  Notepad (it opened behind it).
- **FreeRDP Web to Windows' own Remote Desktop, a video** (聪哥: "freerdp-tk and
  freerdp-web to the Windows server"). `test/windows-host.ps1` opens Windows Server's own
  Remote Desktop to the test user (Remote Desktop Users, its profile made first), and the
  web client reaches it through a websockify of its own (127.0.0.1:3391 to 127.0.0.2:3389):
  a session of its own, Notepad and `webdemo` from Win+R, its sound through the session
  (the last 30 s' peak reported). `wasm-demo.mjs`: `SERVER=windows-rdp`. It joins the
  Windows section of Get a server and the intro (`#windows-rdp`). Nothing installed on
  Windows: Windows' own server, FreeRDP Web in the browser.
- **`freerdp_host` `20261030.7`** (`f21401f50`, freerdp-59's): the Windows shadow server
  sends sound, what the PC plays (WASAPI loopback of the default playback device, Opus or
  PCM to the client); integration-shadow-win rebuilt on master 2a508c725, where #13931 and
  #13932 are merged. `test/windows-host.ps1` checks the server's word that it captures, and
  that the web client hears the Windows PC (the shadow host video's last 30 s above
  -50 dB); the native client asks for `/sound` too.
- **Sound on the Windows runner: none.** It has no sound card, and none installs unattended:
  the virtual Scream card (github.com/duncanthrax/scream 4.0) waited on Windows' driver prompt
  with devcon and with pnputil, its signer trusted as a publisher and as a root (runs
  41164824167, 41166695002, 41169262905). So `test/windows-host.ps1` checks the shadow
  server's sound only where there is a playback device and says SKIP otherwise, and the shadow
  host video's captions claim sound only then. Windows' own Remote Desktop sessions have their
  own playback device (Remote Audio), so the browser's video to it has sound; the freerdp-tk
  video plays it on the runner, which has nowhere to play it.
- **The Linux freerdp-tk videos play the web video and WebGL too, with sound**: in GNOME a
  terminal, a line, then `webdemo` (Firefox with Big Buck Bunny next to the WebGL
  Aquarium), as the page's demos do. `test/client-demo/run.sh` records the client's sound
  with the display (PulseAudio's null sink monitor; the picture alone if there is none);
  `record-demos.sh` reports its peak.

- **A new product: the Windows host** (聪哥: a Windows backend, "go ahead to do them all").
  `freerdp-host-<version>-windows-x86_64.zip`: FreeRDP's shadow server
  (`freerdp-shadow-cli`), `freerdp-shadow-service`, which runs it as SYSTEM on the
  console session, and `winpr-hash`, with a README. It shares a Windows PC's own screen,
  the logon and lock screens, UAC prompts and Ctrl+Alt+Del included, in AV1 (libaom
  3.15.2, a new pin), with Windows-account logins (WinPR on Windows uses Windows' own
  SSPI). Built by `build-windows.sh` with `HOST=1` from a pin of its own,
  **`freerdp_host` `20261030.2`** (`3df368ba5`): our release picked from the fork's
  integration-shadow-win, FreeRDP master 472f1901f plus our pull requests #13931 and
  #13932 (build fixes), #13933 (DXGI capture that follows the secure desktop), #13934
  (the service, Ctrl+Alt+Del) and #13935 (a Unix-socket listener on Windows), and a fix
  found by the web test, added to #13933 and #13934: DXGI reports changes only and the
  Windows subsystem left refresh requests unanswered, so a client of a desktop that did
  not change got a black screen until something moved; the
  clients keep `freerdp` `20261028.1`. `windows-host.yml` builds it and tests it on a
  Windows Server 2025 runner with `test/windows-host.ps1`: a SAM-file login and a Unix
  socket by hand; through the service, SYSTEM on the console session, Windows-account
  logins, the web client through websockify decoding AV1, the native client's AV1
  frames, Ctrl+Alt+Del and the lock screen followed. It also records FreeRDP Web on the
  host (`wasm-demo.mjs`, `SERVER=windows`), which the release adds to `demo.json` as
  `windows`. kit.yml calls it with the run's own clients; the release lists the archive
  and gives `install.json` a `windows` entry (the PowerShell line that installs it).
  Found on the way and filed with the PRs: upstream's default Desktop Sharing capture
  sends no frame on Server 2025; Windows' own sshd (OpenSSH 9.5p2) cannot forward to a
  Unix socket. The experiment's history: branch `win-shadow`.
- **freerdp-web `20261030.4`** (`24892e5`): Get a server shows the Windows host
  (`install.json`'s `windows`, 20261030.3) and its video (`demo.json`'s `windows`).

- **freerdp-web `20261030.2`** (`e78f230`): a new page, **Get a client** (聪哥: Get a server
  also held the client and its demo, and Install as app confused): the three ways to connect
  side by side (this browser, the Chrome app, a native client with freerdp-tk and its demo
  videos, moved from Get a server). Get a server keeps the servers; the header's Install as
  app becomes Get a client, and the install page starts with "You probably don't need
  this." `install.json` and `demo.json` are unchanged; comments in `build/site.sh`,
  `test/record-demos.sh`, `demo.yml` and `kit.yml` now name the page that shows them.
- **freerdp-web `20261030.1`** (`f2df14f`): Get a server shows plain `uvx freerdp-tk`.
- **freerdp-tk `0.3.2`** (`2f90588`, on PyPI; 0.3.1 + one fix), the three findings of 10-28
  fixed there (聪哥: "fix the three freerdp-tk issues and release"), shipped with the native
  clients:
  - "(auto)" follows `PATH` order: each folder in turn, the names only order the clients
    within one. The release's launcher puts its own `bin/` first, so it takes its own
    `sdl-freerdp`, not Debian's `sdl-freerdp3`. Each program is listed once (0.3.2): on
    merged-/usr systems `/bin` and `/usr/bin` are one folder, and 0.3.1 listed it twice,
    as the release demo's log showed.
  - Started by uvx on a Python without Tk (`$UV` set), freerdp-tk starts again with uv's
    own Python (`uv tool run --from freerdp-tk==<version>`, `UV_PYTHON_PREFERENCE=only-managed`),
    once; elsewhere it says what to install. Plain `uvx freerdp-tk` works on a Debian desktop.
  - Where Tk draws with X core fonts (`::tk::pkgconfig get fontsystem` is `x11`: the Tk of
    python-build-standalone, in uv's Pythons and the kit's releases), `...`, `*` and `->`
    instead of `…`, `•` and `→`, which came out as other characters.
- **The freerdp-tk demos prove the fixes instead of working around them**: Debian's client
  stays installed for the release video, and a check reads that "(auto)" lists the release's
  own client first; the uvx video runs plain `uvx freerdp-tk`, and a check reads that both
  visits ran on uv's own Python (`sys.base_prefix`: under uvx `sys.executable` is the tool
  environment's); both check the ASCII glyphs (`hook/drive.py` logs the Python, the clients
  and the glyphs). The hook loads only where `tkinter` exists, so the first, Tk-less Python
  prints no error into the video's terminal, only freerdp-tk's own line.

## 2026-10-28

- **freerdp-web `20261028.11`** (`3576fe9`): Get a server shows freerdp-tk under the native
  clients, `uvx --managed-python freerdp-tk`, and its two demo videos (demo.json's `clients`).
- **Demo videos of freerdp-tk, the native clients' connection window** (聪哥: one OS is
  enough; one for the release, one for uvx): `client-release` and `client-uvx` in
  `test/record-demos.sh`, recorded by `wasm-session.sh`'s new `CLIENT_DEMO` against the
  xrdp-gnome server. Linux only: a computer of its own in a container (`test/client-demo/`:
  Debian 13, Xvfb, Openbox, GNOME Keyring, recorded by ffmpeg) on the server's network, so
  no runner of Windows or macOS has to reach a Linux server or record its screen. The user
  unpacks the kit's Linux client (the kit run's own build) or runs
  `uvx --managed-python freerdp-tk` (with Debian's FreeRDP 3 client, which has no AV1:
  xrdp sends H.264), fills in a connection,
  saves it with its password in the keyring, works in GNOME, disconnects, starts freerdp-tk
  again and double-clicks the saved connection, which logs in with the password from the
  keyring. The pointer and the keys are real X input (xdotool); `hook/drive.py` runs inside
  freerdp-tk's process only to find where Tk drew each field. demo.json lists them under
  `clients`, apart from the splash's `videos`; `build/site.sh` copies them; the page's Get a
  server shows them under the native clients. New in the matrix, so `continue-on-error` like
  KDE's until they have recorded on CI.
- Found while recording: freerdp-tk's "(auto)" client takes the first name of its list found
  anywhere on `PATH` (`sdl-freerdp3` before `sdl-freerdp`), not the first directory on
  `PATH`: on a computer with Debian's `freerdp3-sdl`, the release's freerdp-tk starts Debian's
  client, not the one beside it. The demo takes Debian's away for the release video; the fix
  belongs to freerdp-tk.
- Found too: plain `uvx freerdp-tk` takes the system's Python when there is one, and
  Debian's has no Tk unless `python3-tk` is installed (Openbox alone brings `python3`):
  "No module named 'tkinter'". `--managed-python` makes uv use its own Python, which has Tk;
  the page and the demo say so. And the Tk of python-build-standalone (the clients' bundled
  Python and uv's) is built without Xft: it draws with X's core fonts, where "…" (List…)
  comes out as other glyphs.
- **A run started by hand from main releases like a push** (`kit.yml`, the demo and release
  jobs): a push that only moves the freerdp_web pin builds only the web client (`changes.sh`:
  "web"), so freerdp-web `20261028.10` got no rolling release and the site had nothing new to
  publish; a run by hand builds everything ("all") but skipped the demos and the release. Now
  `gh workflow run kit.yml --ref main` makes the release that publishes a page-only change.
- **freerdp-web `20261028.10`** (`9f3ede1`): English and Simplified Chinese, following the
  browser's language (English the default; the 🌐 Language switch overrides it), and About with
  a row per decoder.
- **The install table's sessions, a line per kind** (聪哥: Wayland and Xorg on one line
  confused): "Wayland: GNOME, KDE Plasma, sway; Xorg: the default session" (Debian, Ubuntu) and
  "Wayland: GNOME (the default), KDE Plasma, sway; Xorg: with xorgxrdp, below" (Fedora), in
  the notes and `install.json`; the site's page (freerdp-web `20261028.9`) shows each part on its
  own line. "KDE" is "KDE Plasma"; sway keeps the lowercase its project writes.
- **freerdp-web `20261028.9`** (`20261028.6` to `.8` before it): the slogan "You here, you in
  the cloud: one desktop.", 蛮蛮 and the twins take turns beside the tagline, like a marquee,
  without caption or buttons; each plays to its end and holds 3 s; the mascot videos play for
  everyone. Get a server shows the Wayland and Xorg sessions a line each.
- **Demo titles in one pattern** (聪哥): `<server> + <desktop> <Wayland|Xorg>[, <tag>]...`, the
  tags comma-separated (the codec first, only where the server's log names it: xrdp's AV1
  encoder, the two-screen demo's too; then Two monitors; new tags at the end): "xrdp + GNOME
  Wayland, AV1, Two monitors" (was "…, two screens") and
  "upstream xrdp + Xfce Xorg" (was "upstream xrdp + Xfce"); the others already fit.
- **The browser login test reloads a page that is not cross-origin isolated after 15 s**
  (`test/wasm-session.mjs`): served without COOP/COEP, the page is isolated only after
  coi-serviceworker's reload, which a cold Chrome sometimes lost; the screens ladder's rung 1
  then failed before the login began (runs 40717903650 and 40722131197, a different Xorg server
  each time; rung 2 passed against the same server).
- **freerdp-web `20261028.5`** (`1f38b97`; `20261028.4` before it): a second mascot, 蛮蛮, the
  paired bird of the Classic of Mountains and Seas (one wing and one eye each, they fly only
  together), with a Twins / 蛮蛮 switch under the card, and its still picture for reduced
  motion.
- **freerdp-web `20261028.3`** (`fb688e9`): a mascot beside the tagline, entangled twins (you
  here, you in the cloud), a muted 10 s loop (66 KB) made with Google Gemini (Veo); still for
  reduced motion, gone during a session.
- **freerdp-web `20261028.2`** (`cda3ab24`): a "Get a server" page, which shows this
  release's `install.json`, and the toolbar's Info is the session only, with the build's facts
  in a panel of their own, About. Its `kit-release.sh` reads the page commit from the new key
  line (`967423b`).
- **The demo recordings find this commit's pre-releases by their tag**: `test/record-demos.sh`
  looked for "(kit <commit>)" at the end of a title, which the new titles (`e68c530`) no
  longer have, so run 40717903650 recorded nothing and published no rolling release. The tag
  ends with the commit (`<kind>-<YYYYMMDD>.<N>-<commit>`); older releases are still found by
  their title.
- **GNOME's Mutter for Fedora 45, an opt-in** (聪哥's go): Fedora's own `mutter-51.0-1.fc45`
  source package (from Koji, pinned by SHA-256; the same files as the signed one on the
  mirrors) with our fix for a Wayland window that lands on the wrong monitor when the monitor
  layout moves its monitor (`patches/mutter/`, GNOME/mutter#5162, merge request !5438),
  rebuilt as `51.0-1.0kit1.fc45` by `build/build-mutter.sh`, which then installs it with
  Fedora's gnome-shell in a fresh container (gnome-shell keeps it and starts). The release
  sorts after Fedora's own and before its next update, which replaces it. CI job `mutter`
  (x86_64 and ARM64) builds it only when its inputs change (about 40 minutes), otherwise takes
  the packages of the `mutter-…` pre-release that has them; the rolling release carries
  them, and its Install xrdp notes and `install.json` offer the command for Fedora 45.
- **`install.json` for the site's "Get a server" page**: the rolling release carries the
  install table as data (`build/xrdp-install-notes.sh --json`: one entry per distribution
  release with its sessions, its command and Fedora's xorgxrdp command, plus the start
  command), with the client archives and their links; `build/site.sh` puts it next to the
  page. Its checksum is in `SHA256SUMS`; it is not attested, being made after the tag. A
  release without it (before today) still makes a site; the page then links to the releases.
- **Release titles end with their tag** (聪哥's wish): the rolling release is "RDP All in
  One (browser, clients, server) `<YYYYMMDD>.<N>`", the pre-releases "Web client
  `web-…`", "xrdp packages `xrdp-…`", "pipewire-module-xrdp for Fedora … `pipewire-module-xrdp-…`"
  and "Demo videos `demo-…`". The title was also the key that names a build's inputs and
  keeps a second run of one commit from publishing again; the key is now a line
  `<!-- kit-key: … -->` in the notes, and `build/prerelease-tag.sh` matches either, so
  releases published before keep theirs. freerdp-web's `kit-release.sh` (967423b) reads the
  page commit from the key too. "preview" leaves the rolling release's notes as well.
  `test/publish.sh` 34/34.
- **FreeRDP `release-20261028.1`** (`b53133ba`): integration-latest rebuilt on master
  `670e10b29`. Upstream merged four of our pull requests today, which drop out of the
  integration: the Web Audio microphone (#13811), no connection dialog window (#13860), SDL3
  clipboard events with every field set (#13872) and hotkeys from the key event's own modifiers
  (#13852). Master also brings upstream's hardening (invalid order bounds, messages and
  fastpath input before activation, the brush cache, H.264 reset bounds, smartcard strings)
  and 39 other commits. Still carried: the browser clipboard (#13733), the MessageChannel yield
  (#13864), the page's monitors (#13865) and the physical monitor size (#13805). Tested before
  the pick: Linux and Windows clients built from it, xrdp logins on Fedora 45 (19/19) and
  Debian 13 (12/12), browser logins with Asyncify and JSPI (5/5 each).
- **freerdp-web `20261028.1`** (`cb551db5`): no change to the page itself; its screens tests.
  `test-screens-wlup.mjs` waited for a dark canvas before Separate screens, and GNOME's overview
  right after login is dark too: on a slow server foot opened only after the layout change (12
  of 30 runs with the GNOME server held to one CPU), and the windows-stay check failed for
  another reason than the Mutter race it tests. foot now has a background of its own and the
  test waits for it (9 of 9 in time). Both screens tests closing the second window could hang
  on a `window.close()` that never answers (3 times in 60 runs); they wait 5 s at most. Local
  ladder with them: Xorg (Debian's xrdp and ours) and GNOME passed; KDE runs in CI only (it
  needs `/dev/udmabuf`).
- **`test/wasm-session.sh`**: `EXTRA_RPMS=<dir>` installs more Fedora 45 packages into the
  GNOME image (used to test a patched Mutter), and the image's `pkgs/` is fresh each run: it
  kept every earlier run's packages.

## 2026-10-27

- **The GNOME All screens check is a known failure**: `test/screens.sh` keeps a list of
  known failures (server, check, why). A rung whose only failed checks are known is
  KNOWN, not FAIL, and the `screens` job stays green; any other failure still fails it.
  The one entry: `xrdp-gnome`'s window check, which loses a race in Mutter about half
  the time (the window's pending Wayland move takes the monitor under its old position
  when the layout moves its monitor).
- **Fedora is Wayland first**: Fedora's desktops have no Xorg session any
  more, so its packages list the Wayland sessions first in `xrdp.ini` (GNOME, KDE, sway,
  then Xorg). With no `autorun=`, xrdp starts the first session for a client that sends a
  password, so GNOME is now Fedora's default. Its `xrdp` only *suggests* `xorgxrdp`
  (it recommended it): dnf installs recommended packages, and could take Fedora's own
  xorgxrdp, built for xrdp 0.10. The release notes' Fedora command installs `xrdp` and
  `pipewire-module-xrdp`; xorgxrdp has its own line under the table. Debian and Ubuntu
  are unchanged (Xorg first, xorgxrdp recommended). `test/xrdp-session.sh` checks the
  default per family and picks the Xorg session with `autorun=Xorg`.
- **FreeRDP release-20261027.1** (`1ba0aa521`): integration-latest rebuilt on the same
  master (b2403bb99) with two more of our open pull requests, both for every client:
  hotkeys read the key event's own modifiers (#13852; `SDL_GetModState()` is the state
  after every queued event, so in the browser, where the main loop takes a batch of key
  events between two yields, a quick Right Shift + D was missed and a `d` typed just
  before Shift disconnected the session), and the physical monitor size goes out in
  millimetres (#13805; SDL3 sent pixels, so a 2880-pixel window was announced as a
  2.88 m monitor; it sends 0, "not given", as SDL3 has no physical size). #13733 and
  #13811 were rebased onto that master upstream; their patches did not change. Tested
  before the pick: the web client built from it, a browser login with Asyncify and with
  JSPI (5 of 5 each), the native Linux client built.
- **freerdp-tk 0.3.0**: the connection window keeps passwords in the system's own store
  (Credential Manager, Keychain, Secret Service or KWallet; asks again when the server
  rejects one), runs before/after commands around a session, picks the monitors to use,
  and starts only the FreeRDP 3 SDL client. It needs `keyring`, which the bundled Python
  lacks: `build/launcher.sh` now installs what freerdp-tk's own `uv.lock` (at the pinned
  tag) lists for the target OS, each wheel checked against the lock's SHA-256 by pip
  (`--require-hashes`): keyring and jaraco's helpers everywhere, pywin32-ctypes on
  Windows, SecretStorage with jeepney and cryptography on Linux. Their licences go to
  `licenses/freerdp_tk/needs/`, their versions into the MANIFEST; the build imports
  keyring and its backend's libraries with the bundled Python (Linux, macOS). Without
  them 0.3.0 still runs, but cannot remember a password.
- The upstream check watches SDL's stable line (3.4) for the web client too, as it
  builds 3.4 since 2026-10-25; it still watched 3.2.

- **The kit publishes the site** (聪哥's decision; same address,
  congzhangzh.github.io/freerdp-web/). freerdp-web published it, pulling the kit's
  pre-releases back (its client, `web-*`, and the demo set, `demo-*`), with the videos'
  addresses in its own `media.json` at the tag being published: a cycle, which every
  renamed demo video had to cross twice. Now one direction: freerdp-web holds the page's
  source and tags, the kit pins a tag, builds, tests, records, and publishes. The new
  `site` workflow (by hand, never on its own) takes one kit release (default the latest):
  `build/site.sh` assembles its web client and page, its demos with their addresses
  (`build/site-anchors.json`, moved here from `media.json`; an unknown video stops it) and
  `RELEASE`; then freerdp-web's page test (`test-page.mjs` at the page's commit) and a
  browser login from exactly those files (Asyncify, JSPI) to the release's xrdp; with
  **publish**, a commit to freerdp-web's branch `gh-pages` (a deploy key for that
  repository, secret `FREERDP_WEB_PAGES_KEY`), which its Pages serve, then a login from the
  live site. Locally, from release `20261027.2`: the site assembled (5 videos), the page
  test passed, the login from its files 5 of 5.

- **The demo videos lose "preview" too** (聪哥's decision): `xrdp-gnome`,
  `xrdp-gnome-screens` and `xrdp-kde` (the kit's xrdp), formerly `xrdp-preview-*`;
  `xrdp-original-xfce` and `grd-gnome` keep theirs. freerdp-web's `media.json` knows
  both names (the old ones stay as aliases), so its splash finds every demo set.

- **One xrdp: ours, with Xorg and Wayland sessions, in the rolling release** (聪哥's
  decision). The kit built two xrdp lines: xrdp's release 0.10.6.1 (Xorg only, no
  `libwlup.so`), which the rolling release carried, and our release as a preview, in
  pre-releases only, without PipeWire's xrdp module. So "Latest" installed on Fedora
  offered no Wayland session ("Unrecognised session code 31" for `[GNOME]`), and GNOME
  with sound took two releases. Now:
  - one `xrdp` pin, our fork's `release-20261027.1` (`8ef7574a`), and `xorgxrdp` its
    development commit (`20261018.1`); `xrdp_preview`, `xorgxrdp_preview`, xrdp 0.10.6.1,
    xorgxrdp 0.10.5 and their signatures (`signed.lock`, `keys/`) go;
  - the rolling release carries these packages, with `pipewire-module-xrdp` for Fedora,
    and a table to install them, release by release, with direct links
    (`build/xrdp-install-notes.sh`);
  - no "preview" in new names: the pre-release is `xrdp-<YYYYMMDD>.<N>-<kit commit>`,
    the version `0.10.80+<pin's version>.<commit>` (`0.10.80+20261027.1.8ef7574a`), which
    sorts after the earlier preview packages (`~preview`) and upgrades them; old
    `xrdp-preview-*` pre-releases keep their names; `build-xrdp.sh`, `check-deps.sh`
    and `test/xrdp-session.sh` have no `--preview` any more;
  - KDE Plasma too: the KWin backend is built and `[KDE]` (code 32) is on the login
    screen where the release's plasma-wayland-protocols has the output device registry
    (1.21 and newer): Debian testing, Ubuntu 26.10, Fedora 43 to 45. Debian 13 (1.17),
    Ubuntu 26.04 (1.20) and 24.04 (1.10) are marked `no-kde`;
  - the releases are the preview's (`distros.list`, with its marks): Debian 12 is no
    longer built, since GNOME's backend needs GNOME 46 or newer;
  - the ladder's and the demo's "original" is xrdp's upstream release as Debian 13
    ships it (`wasm-session.sh` with the packages dir `debian`); the ladder's servers
    are `xrdp-original-xorg`, `xrdp-xorg`, `xrdp-gnome`, `xrdp-kde`; the demo videos keep
    their names (`xrdp-preview-*`), which freerdp-web's `media.json` links.
  Locally: `build-xrdp.sh` and `test/xrdp-session.sh` on
  fedora:45 (18 of 18: Xorg, sway, the login screen lists GNOME and KDE after Xorg,
  PipeWire's module) and debian:testing (17 of 17); browser logins
  (`wasm-session.sh`) to GNOME from those Fedora 45 packages, to KDE compiled from the
  pin (root podman), and to Debian 13's own xrdp (0.10.1), 5 of 5 each; the All screens
  rung against Debian's xrdp, 19 and 18 checks; `test/publish.sh` 31 of 31,
  `test/overrides.sh` 31 of 31; the install table from placeholder files for every
  release.

- **xrdp preview: the Wayland sessions are on the login screen.** The preview packages
  (rpm and deb) list `[GNOME]` (code 31, backend `mutter`) when the GNOME backend was
  built, and `[Wayland]` (sway, code 30) unless the release is marked `no-sway`; xrdp's
  own `xrdp.ini` only has them commented out, so after installing a package the login
  screen offered Xorg and Xvnc only, and a Wayland session took an edit by hand. They come
  after `[Xorg]`, which stays the default: with no `autorun=`, xrdp starts the first
  session for a client that sends a password. `build-xrdp.sh` passes the `no-sway` mark
  to the build as `NO_SWAY`. The tests add the sections only when an older package lacks
  them, and `xrdp-session.sh --preview` checks that the package lists sway.
- **freerdp-web `20261027.2`** (`77fc7eb3`): a logoff is the end of the session, not a lost
  connection. xrdp's development branch (the preview's base) ends a session the server
  ends as Windows does, with Set Error Info `ERRINFO_LOGOFF_BY_USER` and the Disconnect
  Provider Ultimatum, and FreeRDP's SDL3 client then exits with its code 2, `LOGOFF`
  (`client/SDL/SDL3/sdl_utils.hpp`); the page took every exit for a lost connection and
  reconnected, starting a new session. It now maps the client's codes: logoff, idle and
  logon timeouts, a connection replaced or denied, missing privileges, licensing and the
  like end the session ("The session ended: logged off."), with Reconnect offered; only a
  lost connection retries on its own. xrdp 0.10.6.1 sends no error info, so its client never
  exits and the page's own watchdog ended the session there. On the kit's servers (page as
  `bb26d25`; the tag adds only the version and release notes): reconnect 11 of 11 on the
  preview ("The session ended: logged off.") and on 0.10.6.1; capture 15 of 15 on the
  preview; All screens on Xorg green.
- **freerdp-web `20261027.1`** (`f18a3428`): a session the server ends (a log out) now ends in
  the page too, with the end bar, and Reconnect logs in again (the browser's FreeRDP never
  exits after a clean end, so the page waited for it); the mouse and the keys are released
  by themselves when the session is over; Info names each codec with its colour and says
  whether the browser decodes it in hardware. Its tests: All screens on KWin 6.8 (outputs
  kscreen-doctor lists without `enabled`), a retry while the X session's authority is not
  ready, and the client's log when a logoff shows no end bar. On the kit's servers, page as
  `7a30440` (the tag only adds the version and release notes): capture 15 of 15 on xrdp
  0.10.6.1 and on the preview; reconnect 11 of 11 on 0.10.6.1, 10 of 11 on the preview (a
  server logoff reached the page as a lost connection; first put down here as xrdp's
  side, it was the page's: see `20261027.2`);
  All screens on Xorg and KDE green, GNOME as before (a Mutter race).
- **xrdp preview `release-20261027.1`** (`8ef7574a`): `release-20261026.4` plus KDE's
  multi-monitor layout on KWin 6.8: xrdp bound `kde_output_management_v2` version 18, and
  KWin 6.8 takes custom modes only from version 22, so it refused every resize ("too old
  kde-output-management-v2 protocol versions"); after a Reconnect the output stayed as wide
  as the whole desktop. xrdp now binds the newest version both sides know. The kit's KDE
  server (Arch, KWin 6.8.1): freerdp-web's test-screens-wlup 5 of 5 (0 refusals, against 3
  and a 1280-wide output with `.4`). Also: the fork's wlup end-to-end CI runs again (the
  backpressure suite never built the client image its GNOME image needs), an end-to-end
  check that GNOME's primary is the client's and is Meta-0, and two lines astyle wanted.
  On that commit the fork's CI passed build-and-test and the wlup suites: sway 42 of 42
  and 57 of 57, GNOME 46 of 46, backpressure on Xorg, sway and GNOME; its runner has no
  vgem, so xrdp's own KDE suite was skipped there (KDE: the kit's test above).
- **FreeRDP `release-20261026.4`** (`c12c6df85`): `release-20261026.3` plus our pull request
  #13872, for every client: the SDL3 client's clipboard events start from `{}` and set
  every field. A brace initializer only set the event union's first member, so the event
  for a new server format list carried `num_mime_types` from the stack; a negative value
  aborted the client on the server's next copy (7 of 10 runs of a gcc 16 Debug build
  against xrdp), and 1 would have read a stray pointer. The kit's optimised build happened
  not to abort before the change either. Locally, from the rebuilt tree (`SRC_freerdp`):
  `xrdp-session.sh debian:13` 8 of 8, `wasm-session.sh` 5 of 5 on Asyncify and on JSPI;
  the clipboard against xrdp, the same as with `release-20261026.3`: native server → local
  text 6 of 6, local → server 3 of 3, freerdp-web's `test-clip.mjs` (text and images both
  ways) 2 of 2.

## 2026-10-26

**Several monitors: tests as a ladder, and a demo**

- **`test/screens.sh`, the multi-monitor ladder** (CI job `screens`): for each server, rung 1
  is the one-monitor browser login (`wasm-session.sh`, unchanged); on a fresh server of the
  same kind, the rung above it runs freerdp-web's own All screens tests
  (`SCREENS=<tests> wasm-session.sh`, the pinned page's `test-screens*.mjs`, which wasm-build
  now hands on in `dist/wasm/tests/`). Rung 2, Xorg: `xrdp-original-xorg` (xrdp's release)
  and `xrdp-preview-xorg`, a monitor per screen and one wide desktop. Rung 3, Wayland
  through the preview's wlup: `xrdp-preview-gnome`, `xrdp-preview-kde`, a desktop monitor
  per screen with this window's the primary, its windows kept there. The summary says
  whether a failure is basic (rung 1 fails already) or one of several monitors only.
  Nothing waits for the job: a red rung shows, the products are published all the same.
  Local run with freerdp-web 20261026.6's tests, client web-20261026.9 (FreeRDP
  release-20261026.3), xrdp preview 6b3df599: xrdp 0.10.6.1 rung 1 5/0, separate 19/0
  (one NOTE: its Reconnect keeps one monitor, fixed in devel 5376e6de), span 18/0;
  the preview with Xorg 5/0, 20/0, 18/0; GNOME 5/0, 5/0. KDE runs in CI only (here
  `/dev/udmabuf` is not open to the user). The GNOME and KDE images carry foot, the
  terminal the wlup test opens.
- **Demo `xrdp-preview-gnome-screens`**: All screens on two screens side by side
  (`test/wasm-demo-screens.mjs`, `DEMO_SCREENS=1`): the page on the left of two 960 × 1080
  screens, Separate screens, the terminal staying on GNOME's primary, Super+Shift+Right
  moving it to the other screen, the overview over both, one screen again. Both windows
  are recorded by Chrome's screencast and composed by ffmpeg; a pixel that changes ten
  times a second keeps each window sending frames (a screencast sends one only when the
  window is composited, so a still window held a frame from the middle of an animation).
  The second window is not clicked to fill its screen: headless Chrome gives that full
  screen at the origin of its emulated screens.
- **Demo names say which xrdp**: `xrdp-original-xfce` (xrdp's release),
  `xrdp-preview-gnome`, `xrdp-preview-kde` (the preview), `grd-gnome`
  (gnome-remote-desktop), instead of `demo-<server>`; freerdp-web 20261026.6's
  `media.json` maps them to the same lasting addresses.
- **freerdp-web `20261026.6`** (`95c836b4`): the page of `.5`, with the All screens tests
  the kit runs (`ENGINE` for podman, `PASSWORD`, a short temporary profile, a white xterm,
  xrdp 0.10.6's Reconnect as a NOTE, a wait for the terminal before Separate screens)
  and the new demo names.

**Releases: rolling, by date**

- **xrdp preview `release-20261026.4`** (`6b3df599`): `release-20261026.3` plus: a session's
  windows stay on the client's primary screen when the client goes from one monitor to
  several (freerdp-web's All screens). The output that held them used to go to the leftmost
  screen, so every window moved to the other screen, also at each reconnect; GNOME and KDE.
  freerdp-web's test-screens-wlup checks it (fails with `.3` on both desktops, passes 5 of 5
  with `.4`). Every wlup suite passed on that commit, all four together: sway 42 of 42 and
  57 of 57, GNOME 44 of 44, KDE 39 of 39.
- **xrdp preview `release-20261026.3`** (`5f77b058`): `release-20261026.2` plus two fixes found
  on a real pair of screens (2560x1440 and 1706x1067, AV1): GNOME took no layout with a
  pixel's gap between monitors ("Logical monitors not adjacent"), so the client's primary
  was lost; gaps and overlaps of up to 4 pixels are now closed. And `max_fps` (xrdp.ini,
  the GNOME or KDE session): without a GPU GNOME composites in software, and two monitors
  under a scrolling load took gnome-shell to 134 % of a CPU at the default 60 frames a
  second, 91 % at 30. Every wlup suite passed on that commit, one at a time: sway 42 of
  42 and 57 of 57, GNOME 44 of 44, KDE 39 of 39.
- **xrdp preview `release-20261026.2`** (`a1c78563`): `release-20261026.1` plus the same for
  KDE Plasma (wlup's KWin backend): the output that is cast for the first monitor, a KWin
  virtual output for each other one, at the client's positions with its primary monitor
  first (Plasma's panel). Every wlup suite passed on that commit, all four together: sway
  42 of 42 and 57 of 57, GNOME 44 of 44, KDE 39 of 39 (with its new two-monitor checks); and
  freerdp-web's test-screens-wlup 4 of 4 on GNOME and on KDE, the mid-session layout of All
  screens -> Separate screens. (Pinned by 77f18a7; this entry came one commit late.)
- **xrdp preview `release-20261026.1`** (`816daad4`), picked from integration-wlup-all on
  the fork: GNOME sessions (wlup's Mutter backend) get a virtual monitor per RDP monitor
  instead of one as wide as all of them, with the client's primary monitor as GNOME's (the
  top bar), also when the client changes its layout mid-session (freerdp-web's All screens
  -> Separate screens). The chansrv Opus parts now sit on a newer xrdp devel, which brings 3
  of its commits (#3927). Every wlup suite passed on that commit: sway 42 of 42 and 57 of 57,
  KDE 35 of 35, GNOME 44 of 44 (with its new two-monitor checks; run alone after a run of
  all four together lost GNOME's first login to load), and freerdp-web's
  test-screens-gnome, which fails without the change.
- Web client: the freerdp-web page 20261026.5 (`5788b71`): under capture (Pointer Lock) the
  remote pointer now shows on every screen of All screens, not only in the page's window.
  The client is unchanged (FreeRDP `release-20261026.3`).
- **FreeRDP `release-20261026.3`** (`cef3ddb47`): `release-20261026.2` plus our pull request
  #13860: no connection dialog window in a browser. Its SDL window took the session's one
  canvas, so after FreeRDP's auto-reconnect the canvas was 0 x 0 (no picture) and no window
  had the keyboard focus (no keys; the mouse still worked). freerdp-web's suite passed 22 of
  22 with it, and its new checks (the canvas and the keys after a reconnect) fail with
  `release-20261026.2`.
- Web client: the freerdp-web page 20261026.4 (`0c27b25`): that client, and All screens ▾
  asking for the mode.
- **FreeRDP `release-20261026.2`** (`dbba4a4ce`): `release-20261026.1` plus our pull request
  #13865: in a browser the page may split the client's one canvas into monitors
  (`Module.freerdpMonitors`), and the display layout then carries a monitor per screen, also
  at the first activation after a connect or reconnect. Emscripten only. freerdp-web's suite
  passed 22 of 22 with it, test-screens 5 of 5 in both of its modes (the session's RandR
  monitors: two 640x480 or one 1280x480).
- Web client: the freerdp-web page 20261026.3 (`bf7d6fd`): All screens as separate monitors
  (the default) or one wide desktop.
- **FreeRDP `release-20261026.1`** (`0cae530ae`): `release-20261025.1` plus our pull request
  #13864, the MessageChannel yield: `pollset_poll`'s yield waits on a MessageChannel task
  instead of `emscripten_sleep(0)`, whose `setTimeout(0)` the browser clamps to 4 ms. Emscripten
  only (native clients compile the same code as before). Forced on every empty poll, an
  xterm scrolling random text received 53–57 kB/s with `setTimeout` and 1913–2291 kB/s with
  the MessageChannel, JSPI and Asyncify alike; as shipped the yield does not fire in our
  pthread client, so sessions measure the same. freerdp-web's suite passed 22 of 22 (11
  tests, both engines) with this client. pins.notes watches #13864 too.
- Web client: the freerdp-web page 20261026.2 (`0b12d92`), the release that names this client.
- Web client: the freerdp-web page 20261026.1 (`b6fce61`): **All screens**, the remote
  desktop spread over every screen through the Window Management API (one large monitor for
  the server), and the JSPI measurements in its README and notes. Same client pins.

## 2026-10-25

**Releases: rolling, by date**

- **A new freerdp-web release costs one web build, not the whole kit**: a push that only
  moves the `freerdp_web` pin ran all 52 jobs (native clients on six platforms, xrdp on
  every distribution, demos, the rolling release), about 30 minutes, although only the web
  client reads the page. `build/changes.sh` now compares the push with its base (comments,
  docs and the pins tables aside): only the pin changed → scope `web`, and only `wasm-build`
  and `wasm` run, the login test taking its xrdp packages from the newest `web-*`
  pre-release. Anything else, a pull request and a run by hand → `all`, as before.
  `test/changes.sh` checks it on a throwaway repository (8 cases).
- Web client: the freerdp-web page 20261025.2 (`c1982be`). The page's code is the same
  as 20261025.1's; the release is the first one published the new way (its tag publishes
  nothing; the site goes out by hand with this kit's client of that page, after a login
  from the files going live).
- **FreeRDP `release-20261025.1`** (`d708a57aa`), the first release picked
  under the fork's new branch rule: integration-latest rebuilt on FreeRDP
  master `b2403bb99` (2026-10-23, 96 commits past the 20261021.1 base),
  tested, then picked as `release-<YYYYMMDD>.<N>`. Four of the pull
  requests the preview carried are in master now (sound #13732, H.264
  through WebCodecs #13812, #13838, #13839), so it carries two: the browser
  clipboard (#13733) and the Web Audio microphone (#13811). Older picks keep
  their `wasm-preview-…` names. Locally, every client built from it: web
  (Asyncify and JSPI, each logged in to xrdp: 5 of 5), Linux (stable xrdp
  debian:13: 8 of 8; the xrdp preview on debian:testing: 12 of 12),
  Windows x86_64 (check-windows ok).
- **Every client builds our FreeRDP preview** (`freerdp` 20261021.1,
  `79f10e8ae`, fork branch `wasm-preview-20261021.1-79f10e8`): the Linux,
  Windows and macOS clients leave FreeRDP 3.32.2 for the commit the web
  client already built, FreeRDP master 29cb8ef1b plus four open pull
  requests whose code compiles under Emscripten only. The release follows
  our own preview, not FreeRDP's release schedule. What the native clients
  gain: the Opus microphone fix (#13810). 3.32.2 handed `opus_encode()`
  whatever the capture device delivered, and Opus takes whole packets only
  (2.5 to 60 ms), so audin dropped the connection with
  `ERROR_INTERNAL_ERROR` once a server picked Opus for the microphone (the
  xrdp preview with `MicrophoneOpus=true`). One pin, `freerdp`, for all four
  clients: `freerdp_preview` goes, `SRC_freerdp` now overrides the web
  build too, and `check-upstream.sh` no longer compares FreeRDP with its
  releases. Archives are named `sdl3-freerdp-20261021.1-<os>-<arch>`.
- Web client: the freerdp-web page 20261025.1 (`1167155`), which loads the
  JSPI build where `WebAssembly.Suspending` exists and sends pointer events
  under Capture, so the pointer moves with SDL 3.4.
- **Web client, two builds**: the same objects linked twice, with Asyncify
  (`web/`, 10.6 MB, every browser with WebAssembly) and with JSPI
  (`web/jspi/`, 6.9 MB, Chrome 137+: the browser suspends the code, so
  nothing is rewritten for it). Both are link options, so the second link
  compiles nothing. freerdp-web's page picks one (`web/engine.js`, from its
  release after 20261024.1); CI logs in with each (`WASM_ENGINE=jspi
  test/wasm-session.sh`, output in `dist/test/wasm-jspi/`).
- Web client: SDL `3.4.18+timer` (`1d615c14f`, fork branch
  `emscripten-timer-3.4`), upstream's newest release plus the timer fix
  (the same change as on 3.2.30); 3.4.18 has the `/tmp/filedrop` guard
  already, so that backport goes. SDL 3.4 reads the mouse from pointer
  events, and the page under Capture sent only mouse events: Capture needs
  the freerdp-web release after 20261024.1 (its pointer-event fix), which
  the kit pins next. Until then this web client's pointer does not move
  under Capture.
- LibreSSL 4.4.0 (Windows and web clients; issue #12): it removes the weak
  `emSign ECC Root CA - G3` from its `cert.pem`, fixes the build with
  llvm-mingw's own `endian.h`, and fixes Windows' `poll()`, `connect()` and
  `struct timeval` (DTLS timeouts). Hash from OpenBSD's `SHA256`, the same
  as the GitHub release asset's. FreeRDP's `scripts/mingw.sh` still pins
  4.3.3, so the kit no longer follows it here.
- **The GNOME demo records again** (failed since 9e3f5e3): unloading
  AppArmor took docker's `docker-default` profile with it, and dockerd loads
  it only when it starts, so runc refused the RUN steps of the GNOME
  image's build (`apt-get … exit code: 1`, no apt output). The demo job
  restarts docker after the teardown.

- **Every release carries its demo videos**: the kit's run records them
  (`demo.yml`, now a workflow the kit calls) once its web client and xrdp
  preview are published, and the release waits for them. The `demo-*`
  pre-release stays, for freerdp-web's splash. A recording that fails now
  stops the release.
- **Demos record again** (broken since 2026-10-24): every login to the
  Fedora servers was refused by sshd's PAM account check ("could not obtain
  user info" from `unix_chkpwd`). The runner's AppArmor profile
  `unix-chkpwd` attaches by path to that program inside the containers too,
  and denies the `CAP_DAC_OVERRIDE` Fedora's setuid `unix_chkpwd` needs for
  its mode-0000 `/etc/shadow`. Found with a throwaway workflow: a minimal
  Fedora 45 + sshd server failed the same way on the runner (root and
  rootless podman alike) and logged in on another host; `strace` showed the
  helper's `/etc/shadow` open failing with `EACCES`, and the kernel logged
  the denial. The demo jobs now unload AppArmor on their throwaway runner,
  and the server log shows the account as each side sees it.
- **macOS client**, arm64 and x86_64 (`build-macos.sh`), with freerdp-tk
  and a standalone CPython 3.13.17 per architecture, like Linux and Windows:
  built natively with Apple clang for macOS 12 and newer, every library
  static, only macOS's own libraries and frameworks linked
  (`build/check-macos.sh`), ad-hoc signed. CI builds arm64 on `macos-15` and
  x86_64 on `macos-15-intel`; the release waits for both. Two fixes the
  build needed: FreeType 2.15 found macOS 26's HVF library, which has no
  plain arm64 slice, and the static link failed (`FT_DISABLE_HVF=ON`); and
  macOS's own `sha256sum -c` accepts a malformed line, so the hash checks
  use `shasum`. Not notarized: a browser download needs
  `xattr -dr com.apple.quarantine` once.
- Every push to main that changes a build and passes every test publishes
  the release `<YYYYMMDD>.<N>`, made GitHub's latest: the Linux and
  Windows clients, the xrdp packages and the web client, with
  `SHA256SUMS` and build provenance. The never-used `v<YYYY>.<MM>.<N>` tag
  release is gone: the kit is rolling, and the date is the version. Until
  now the native clients were only CI artifacts; this makes them a download.
- The clients come ready to use: with freerdp-tk 0.1.1 (a Tkinter window
  to save and open connections, pinned by its release's commit) and a
  standalone CPython 3.13.17 with Tk (python-build-standalone 20261021,
  pinned per platform by GitHub's digest), started by `freerdp-tk`
  (Windows: `freerdp-tk.cmd`), which puts the archive's own `sdl-freerdp`
  first. No Python or Tk needed on the machine. The smoke test loads the
  bundled Python, Tk and freerdp-tk on every distribution it runs on.
- No prefix on any release tag, ours included: freerdp-web and freerdp-tk
  tag their next releases `<YYYYMMDD>.<N>` / `0.2.0`, not `v…`.
  `check-release-pins.sh` takes the bare tag or the older `v` one, and
  checks freerdp-tk's pin too; `check-upstream.sh` watches both repos
  either way.
- xrdp preview 20261025.1 (`94f7cf46`): the previous one plus a fix that
  builds it on ARM64. xrdp's development branch builds with `-Werror`, and
  `libxrdp/xrdp_caps.c:655` (from 2014) tested `jpeg_prop[0] < 0` on a
  `char`, which is unsigned on ARM64 (`-Wtype-limits`); it now compares the
  byte as unsigned (fork branch `caps-jpeg-quality-unsigned`, on devel, for
  upstream). Checked on x86_64 with `-funsigned-char`: the old commit fails
  with exactly the ARM64 error, the new one builds. The stable xrdp 0.10.6.1
  never had the problem (a release builds without `-Werror`).
- xrdp packages and the xrdp preview for ARM64 too (`ubuntu-24.04-arm`
  runners, each logged in to with the ARM64 client); the x86_64 artifacts
  keep their names.
- Web client: SDL `3.2.30+timer+filedrop` (`3beaaf641`, fork branch
  `emscripten-timer-threads-filedrop`), the previous pin plus upstream's
  267e681a0 backported: SDL's Emscripten windows run
  `FS.mkdir("/tmp/filedrop")`, which threw `EEXIST` when a window was made
  while another was open. At a network drop FreeRDP's retry dialog made
  one: the exception unwound the main thread while it held the dialog's
  mutex, the Asyncify client then exited (the page's retry brought the
  session back by luck), and a JSPI build hung for good. With the guard,
  freerdp-web's `test-reconnect.mjs` on a JSPI build passes 3 of 3 (0 of 4
  before); the session comes back through FreeRDP's own retry, in the same
  client. SDL 3.4 has the guard but was not taken: with it, the remote
  pointer stopped following relative motion under pointer capture
  (`test-capture.mjs`, both engines).

**Docs and releases**

- Our changes upstream: every `change` line in `pins.notes` names the pull
  requests and issues that carry it upstream (the README's tables link
  them). `check-upstream.sh` reports their state, and the daily `upstream`
  job opens an issue once all of a pin's are merged or fixed, so the pin
  goes back to an upstream release. On 2026-10-25: FreeRDP #13732 and
  #13812 are merged, #13733 and #13811 open; SDL #16587 open; the seven xrdp
  pull requests of the preview open.
- A change to the notes, the tables or their scripts alone builds nothing
  and makes no pre-release: the `pins` workflow checks it instead.

## 2026-10-24

**Web client**

- **SDL for the Emscripten build: 3.2.30 plus a fix of its timers**
  (`sdl3_wasm 3.2.30+timer`, a commit on a fork branch). With threads,
  SDL 3.2.30 uses the Emscripten timer code, which was written for a single
  thread: a JavaScript timeout belongs to the thread that set it, so a
  timer removed from another thread stayed armed and then called through
  its freed entry ("table index is out of bounds" in
  `SDL_Emscripten_TimerHelper`). FreeRDP's client removes and adds its
  display timer from both its RDP thread and the main thread, so about one
  first session in three threw the error. The fix keeps the timer list and
  every timeout on the main runtime thread (`emscripten_proxy_sync` from
  other threads), looks the timer up again after its callback, and clears
  pending timeouts on quit. Tested by a first login repeated against both
  builds (unpatched 9 of 28 sessions with the error, patched 0 of 16),
  freerdp-web's reconnect test (18 of 18 checks, clients quitting and
  starting again), and a `-Werror` compile with and without threads. The
  pin goes back to a plain SDL release once upstream has the fix.
- Linked with `-sMODULARIZE=1 -sEXPORT_NAME=createFreeRDP`: every
  connection gets a new runtime, so freerdp-web reconnects in the same page.
- freerdp-web 20261024.1: several passkeys and a recovery code for one
  vault; reconnect without a passkey prompt or a typed password.

**Docs and releases**

- The pins at a glance: `pins.notes` says what each product is built from
  and how it is tested, and for every pin that is not a plain upstream
  release, its base, what it changes and how that is tested.
  `build/pins-table.sh` joins it with `sources.lock` into the README's
  tables (CI fails when they are stale or the two files disagree), and
  `build/release-notes.sh` puts them in the notes of every release.
- This changelog.

## 2026-10-21

**Upstream updates**: SDL 3.2.30 for the web client, freetype 2.15.0,
Opus 1.6.1, llvm-mingw 20261020.

**Web client**: FreeRDP preview 20261021.1 (master of 2026-10-21 plus the
four Emscripten pull requests; AV1 #13731 and the Opus microphone fix #13810
are in master now). freerdp-web is taken by its releases only (20261021.1,
20261021.2). Pre-releases are named by date: `web-<YYYYMMDD>.<N>-<kit commit>`.

**xrdp preview**: 20261021.1 (`bfba3d7f`); AV1 is offered first
(`gfx.toml`: AV1, H.264, RFX).

**xrdp packages**: Fedora ships PipeWire's xrdp module (pipewire-module-xrdp
0.2), as its own pre-release, published only when its inputs change.

**Demos**: GNOME 51 and KDE Plasma on Wayland through the xrdp preview, in
AV1, recorded in CI as `demo-*` pre-releases, with the sound at the time it
was played. Getting systemd containers to run on GitHub's runners took the
seccomp, AppArmor and user-namespace changes in `wasm-session.sh` and the
demo workflow.

**Build and CI**: the Linux ccache keyed by architecture, not runner name;
three tries at the Linux client image's packages.

**Licence**: Apache-2.0, with a NOTICE.

## 2026-10-20

- Builder images (the tools installed once per image), ccache and local
  sources for Windows and xrdp too; local sources with submodules, and LTO
  back on.
- Release policy: frozen releases (one name per build, published once,
  never replaced) and a two-week limit on pending upstream updates.
- Web client: FreeRDP preview 20261020.1 (microphone and H.264);
  freerdp-web 0.4.12.

## 2026-10-19

- Web client: Emscripten 6.0.12, as FreeRDP's own CI (#13728); dependency
  stamps name the compiler, so a new one rebuilds everything.
- Quick rebuilds: ccache, and local source checkouts for the development
  loop (`SRC_<name>=<dir>`, `sources.local`).
- xrdp preview: a `no-av1` mark for releases without libaom 3.0.
- Release checksums under the names the assets are downloaded as.
- freerdp-web 0.4.6 and 0.4.7 (`/scale-desktop` for high-DPI screens).

## 2026-10-18

- xrdp preview: xrdp's development commit with Wayland sessions and AV1,
  built and tested in CI (an Xorg and a Wayland login), published as
  `xrdp-preview-*`.
- Web client: FreeRDP preview `fdf8d54` (master plus the four Emscripten
  pull requests); the page moves to freerdp-web's own site, which takes the
  tested client from the kit's `web-*` pre-release.
- `check-upstream.sh` and a daily job that opens one issue per upstream
  update.
- docs/RELEASE.md: channels, inputs, gates, flow.

## 2026-10-17

- Windows client: FreeRDP's SDL3 client cross-compiled with llvm-mingw.
- Web client preview: FreeRDP in the browser, tested by a browser login.
- Every download and hash check stops the build on failure; git fetches
  are retried.

## 2026-10-16

- The portable SDL3 FreeRDP client for Linux, built from pinned sources,
  runs on glibc 2.34 and newer.
- xrdp and xorgxrdp packages for Debian, Ubuntu and Fedora, each tested by
  an RDP login in a fresh container of its release.
