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
