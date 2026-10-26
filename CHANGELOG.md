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

## 2026-10-26

**Releases: rolling, by date**

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
