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

## 2026-11-06

- **`freerdp`, `freerdp_host`, `freerdp_mac_host`, `freerdp_linux_host` `20261106.3`** (`2911e694a`, freerdp-f7, 聪哥's go): a headless GNOME started through sesman takes the size of its first client. The size goes to the virtual monitor before activation; a reconnect at a new size gets that size, a second client beside the first leaves it, and sizes are rounded to what Mutter takes (1001x701 becomes 1000x700). Headless sessions only. Tested by freerdp-f7 on its build through sesman, 9/9 on 3 runs, and with freerdp-34's clipboard and sound test 15/15 in 3 fresh sessions; on the kit's static package locally GNOME 35/35, Xorg 9/9. Not covered: a resize while connected (no Display Control, so changing the window later does nothing), real desktop sessions, mstsc, ASan.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host`, `freerdp_linux_host` `20261106.2`** (`65c6db4af`, freerdp-f7, 聪哥's go): a wrong password now ends the connection. The shadow server closed the connection without a word, so a client with auto-reconnect took it for a network failure and tried the same password again, for as long as it was left. `397d0e323` sends the disconnect sequence first. FreeRDP clients show a generic disconnect reason, not a password error: they do not announce `RNS_UD_CS_SUPPORT_ERRINFO_PDU`, so they see the ultimatum and read it as `ERRINFO_RPC_INITIATED_DISCONNECT`. `test/linux-host.sh` covers it through sesman with `/auto-reconnect` (the kit's client has it off by default, and then ends either way). On the static package through sesman: without the fix 15 tries, 14 failures at the server and the client still running at 40 s; with it 1 try and the client ends. mstsc untested.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host`, `freerdp_linux_host` `20261106.1`** (`514d05c56`, freerdp-34, 聪哥's go): the Linux host shares the session's clipboard and takes a client's microphone. A clipboard core for all subsystems (`server/shadow/shadow_cliprdr.c`) with its Mutter hooks: text, HTML and images both ways. A new PipeWire unit (`server/shadow/PipeWire`) moves the Mutter sound code out and serves both subsystems: what the default sink plays goes to the client, a client's microphone appears as a source of the session, no sound card needed. FreeRDP's sound log tag moved from `shadow.mutter` to `shadow.pipewire`; the kit's check reads the text. Tested by freerdp-34 on its shared Debug build: clipboard 23/23 under ASan, sound and microphone 9/9 on Mutter and X11; through sesman on a headless GNOME 15/15 in 3 fresh sessions, the first copy included, once the test's window had the focus (Mutter ignores a selection set without focus; the first copy failed 4 of 6 before the test waited for it). `d37678502` installs the new unit with the static subsystems: the kit's host, fully static, did not generate without it. Limits: no file copy; mstsc untested; a selection made before the server starts shows up with the next copy; clipboard on Mutter only, other subsystems need their hooks; the X11 client fails at 1 MiB client to server (about 800 KB works) and shows a clipboard held before it connected only with the next copy; the clipboard's data through sesman was tested on the shared build, not on this static package.
- **Linux host: PNG in the clipboard** (`build/build-sdl3-client.sh`, `sources.lock`, `libpng` `1.6.59`, new): `-DWINPR_UTILS_IMAGE_PNG=ON` with libpng built static, as `build/check-portable.sh` allows no libpng from the system, and the build stops if FreeRDP finds another. `-DWITH_SHADOW_PIPEWIRE=ON` gives X11 desktops sound and a microphone. `test/linux-host.sh`: the clipboard channel opens, directly and through sesman (Monitor Ready reaches the client). That proves the channel, not the data. Local run of the static package before the pick: GNOME 34/34, Xorg 9/9.

## 2026-11-05

- **`freerdp_web` `20261105.3`** (tag 45abedc → `2336c552b`, freerdp-web-bb): the release notes page catches up with the nine versions it was missing (20261103.1 to 20261105.2), and a new unit test compares the manifest, CHANGELOG and notes. Notes and a test only, no other page code, no client change. A page-only pin: no Latest of its own.
- **One go for the site, at tag level, and a rollback** (`.github/workflows/kit.yml`, `.github/workflows/site.yml`, `build/site-go.sh`, `build/site-rollback.sh`, `test/site-go.sh`, 聪哥's decision): `gh workflow run kit.yml --ref main -f publish_page=<page tag>` runs the whole round and hands its release to `site.yml` with no second go. It is the owner's command; nothing else publishes, not a tag, a pin or a push. The go must name the pinned page, or the run stops at once. If the login from the published site fails, the site that was live goes back up as a new `gh-pages` commit and the run stays failed; until now a failed check left the site as it was.
- **`freerdp_web` `20261105.2`** (tag f410697 → `5f4f78d52`, freerdp-web-bb), in place of `20261105.1`, which passed the login test (round 42016319964) but goes no further: the Log's Pause and Resume become an Auto-scroll check box, a retry leaves someone reading the Log alone, and the last session's log gets its own tab, so `#log` holds only this page's lines. Page code only, no client change. The kit's tests click `#go` and read `#log`, neither of which changed. A page-only pin: no Latest of its own.
- **A page-only round finds the older pre-releases again** (`.github/workflows/kit.yml`, rdp-release-kit): round 42016319964 failed in all four `screens` jobs at "The xrdp packages". `gh release list -L 100` no longer reached `pipewire-module-xrdp-20261031.1`, number 114 of 213 releases, since that kind is published only when its inputs change. The empty tag then made `gh release download` take the Latest release instead of failing. Both lookups now list up to 1000, and an empty tag stops the step with a message.
- **`freerdp_web` `20261105.1`** (tag 7aae651 → `2fa4eec3d`, freerdp-web-bb): the page's Log can be read while it runs. Pause and Resume; scrolling up or selecting text stops it following, and a line count shows what arrived since; Copy all; Ctrl + A selects the log alone; a saved crash log opens at its start. Page code only, no client change. Lines are now appended as text nodes, so a selection survives; `textContent`, which the kit's tests read, is unchanged, and nothing trims the log. A page-only pin: the web client is built and tested again, no Latest of its own.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host`, `freerdp_linux_host` `20261105.1`** (`ccd119bec`, freerdp-18, 聪哥's go): a session could drop while the client sends input. Upstream's `cfb77bd0a` (in `20261104.6` to `.8`, so in kit `20261105.2`) cleared the TLS BIO's retry flag on the way into every read and write, outside the lock; the reader and the writer share that flag, so a writer could wipe the reader's "try again" and an empty socket read as a broken connection ("BIO_read returned a system error 11", the peer "BIO_read retries exceeded"). The Windows host test lost its native session that way in round 41963557961, twice. FreeRDP#14050 (`c7b7f1718`) keeps that commit's aim, no stale flag after a failure, by clearing the flag only for a failure that cannot be retried, with every change of the flags under `tls->lock`. freerdp-18's A/B on Linux (OpenSSL, 10 rounds with a second thread sending keys): master dropped 10 of 10, master without `cfb77bd0a` 0 of 9, with the fix 0 of 10. This round is its first test on Windows and LibreSSL. With it, two log-text commits that waited for a pick: `000c53aa1` (#14041, 0x80070005 named as `E_ACCESSDENIED`), `875cf922b` (NSC's missing NEON code logged at verbose level). ctest 180/180.
- **`freerdp_web` `20261104.3`** (tag 552dad8 → `5a2bea15f`, with `20261104.2`, freerdp-web-bb, 聪哥's go): the page no longer shows the user's name. The safety notice's ssh line is a fixed `user@server` (it copied the User field, so a saved host's name showed on screen and in any screen share; the published site never held it), the hint says to replace it, in all four languages; the host bar shows the gateway alone; the page log masks the user as `/u:***`, as it does `/p:***` (a log is what people paste into a bug report). The client still gets the real user. `test/wasm-session.sh` and `test/windows-host.ps1` accept both forms in "the page started the client with a user", so they also run against an older page (the first round, 41958432727, failed on the second copy, which the pin had missed); the login checks after it prove the user. Its tests: unit 88/88, test-page 48/48, test-i18n 64/64, the page's CI. Also here, a test only: `test/lock-resume.ps1` starts unlocked (the main Windows test leaves the screen locked, so its run started paused), unlocks with `tsdiscon` + `tscon` (freerdp-54: `tscon` alone did nothing on a VM's console session) and parses times on Windows PowerShell 5.1. On the runner it now records 129 frames before the lock, 1 while locked and 222 after, "capture resumed": CI's first real pause and resume.

## 2026-11-04

- **`freerdp`, `freerdp_host`, `freerdp_mac_host`, `freerdp_linux_host` `20261104.8`** (`f09c851a3`, rdp-release-kit, with freerdp-54's and freerdp-18's fixes): integration-all rebuilt on FreeRDP master `a5d85a31f` (2026-11-04), 130 commits newer than `9f9d97e81`. Master has merged 7 of our pull requests, so their 15 picks drop out: the Windows host's sound (#13954, 4 commits), AVC420 for 10.x capability sets (#13978, 2), the I444 fast path with AVX2 (#13982, 3), the `/monitors` errno fix (#14005), the 8 MiB default thread stack (#14004, 3), the input that races a reactivation (#14020, upstream's `903e1b145` instead of our pick) and the journald define (#14029). The other 42 commits are unchanged (`git range-diff`); one, the DXGI capture pause on a desktop the process may not see, is re-fitted into upstream's new display-mode check (`win_shadow_check_resize`, ab5acfafd) in the capture loop. Master also brings the shadow server's frame pipeline kept alive with unresponsive clients (#13928), notifications registered after the peer's authentication, the SDL3 client's lock fixes and rdpsnd's reset under the play lock. Master `a5d85a31f` itself breaks RemoteFX and Progressive decoding: today's range-check commits (fea1c1e9d, 22abd3935) kept the asserts' conditions, so every in-range tile was rejected (ctest `TestFreeRDPCodecProgressive` and `TestFreeRDPCodecRemoteFX` returned -1; GFX Progressive is what Windows servers send). freerdp-54's `1aa9f8570` rejects only tiles past `UINT16_MAX - 64` (the update rectangle is the tile's 64 pixels in a UINT16); our `release-20261104.6` (`853d3d7d2`, the rebuild without it) is never pinned. A local build (gcc, Ninja, Debug, the shadow server with Mutter and the session manager, SDL3) passes ctest 180/180. And freerdp-18's `97f4d1390` (FreeRDP#14041, found by freerdp-54's review of the re-fit): upstream's resize check returns 1 on a display change, and with no duplication (capture paused on the lock screen, or a failed restart) that 1 reached `win_shadow_dxgi_get_invalid_region()` with a NULL duplication, so a resolution change on the lock screen would crash the capture thread; now there is no frame to read without a duplication. `.5` had no resize check, so this was new in `.6`/`.7`; `release-20261104.7` (`f452085f5`) is never pinned. Built with llvm-mingw by freerdp-18; this round's Windows host test runs it. This round's check for it: every test, since every product builds it.
- **The Linux host for ARM64** (`.github/workflows/kit.yml`, freerdp-ce, b89075b; same sources and pins, a new architecture): `linux-host` now builds on `ubuntu-24.04-arm` beside `ubuntu-24.04`, from the same AlmaLinux 9 image (nothing in the build is tied to x86_64: names take `uname -m`, `check-portable` accepts any `ld-linux`, aom needs no assembler on ARM). `linux-host-test` runs gnome and xorg natively on both runners, each with its own architecture's client (`sdl3-freerdp-<runner>`). The release carries `freerdp-host-<version>-linux-aarch64.tar.xz` beside the x86_64 one (each checked against its `.sha256`), a "Linux host ARM64" row in the download table and an ARM64 entry in `install.json`'s `linux` list; the x86_64 row loses "sound not tested yet", as the GNOME test checks the sound now. The READMEs install with `freerdp-host-*-linux-$(uname -m)`. Not run on ARM before: this round is the first ARM build and test.
- **The Linux host's sound is tested** (`test/linux-host/inside.sh`, freerdp-ce, a49d988; a test only, nothing built changes): the Mutter backend sends what the session plays (FreeRDP `5221ef1a8`, in `20261104.5`), and nothing checked it. Now a 1 kHz tone (-12 dBFS, 4 s) is played with `pw-cat` into the session's sink while a client with `/sound:sys:fake` is connected. The test bed has no sound card, so the sink is WirePlumber's Dummy Output, whose monitor the server records as it would a sound card's. The client must open `WAVE_FORMAT_OPUS` and get at least 60 waves that carry sound: 80 for 4 s at one every 50 ms, a wave of the tone being a few hundred bytes where one of silence is a few. The same runs in the headless GNOME the session manager starts. 3 more checks: GNOME 32, Xorg 9. freerdp-ce's local runs: GNOME 32 passed (82 and 81 waves with sound), Xorg 9.
- **`avm` `20261104.2`** (`e29696055`, avm-release-kit-ea, 聪哥's go), the decoder speed-ups group on top of `20261104.1`, five bit-exact commits: the motion field's first entry copied when a block's entries are all equal (eb480e0e5), `span_submv()` reading its value once and spanning both references in one pass (6c5fd113f), motion field projection skipping a side whose stored references cannot project (9d0519fc4; nothing is skipped with traj on) and reading the frame geometry once per call (e6ec29073), and `avm_calloc()` taking zeroed memory from `calloc()` (e29696055). Its release kit: round 41842876365, 16/16 (avm kit 20261104.8); ARM instruction counts against `20261104.1`: decoder −9.3 % (1440p desktop), −7.8 % (1440p text), −7.9 % (720p desktop), −5.3 % (720p text), −3 to −4 % (motion), encoder −0.05 to −0.4 %; its SIMD gate (EPYC 7763 under Intel SDE) has every path's encodes and decodes equal to pure C, and the AVX-512 kernels still ran (encoder 2675646444 instructions allowed against 2681001010 masked; decoder 277516562 against 278088236). Pictures are unchanged, so this round's check for it is the AV2 sessions as before (the Windows, Mac and Linux host tests, the xrdp-gnome demo's encode and the web client's decode).
- **The headless session manager check sees a changing screen** (`test/linux-host/inside.sh`, freerdp-ce): in kit 20261104.12 the headless GNOME's client got 2 AV1 frames, since its desktop was idle (a virtual monitor sends its first picture and then only what changes). The check now opens the same clock window in that GNOME as the regular session manager check and needs at least 20 AV1 frames with the screen changing (freerdp-ce's run: 468). Still 29 GNOME checks; the test only, nothing built changes.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host`, `freerdp_linux_host` `20261104.5`** (`a0289ef75`, freerdp-ce's two Mutter host commits, 聪哥's go), for the session manager above: the Mutter backend makes a virtual monitor of its own when asked (763052462, from 892a2af67), and `freerdp-shadow-sesman` routes an RDP connection to the GNOME session of the user it names (a0289ef75, from d28ea2b0e). Both are inert by default: the shadow server without the new option behaves as in `.4`, and the session manager runs only when its unit is installed. Only the Linux host builds them; the clients, the web client and the other hosts are unchanged. freerdp-ce's tests: GNOME 29/29 (the session manager on 127.0.0.1:3391, a headless GNOME for the group, frames, the session kept after the client leaves) and Xorg 9/9 with integration-all 600c1b09a (same patches). This round's check for them: the Linux host tests (gnome 29, xorg 9) and every other test as before.
- **The Linux host carries the session manager, optional and off unless installed** (`build/build-sdl3-client.sh`, `build/linux/freerdp-shadow-sesman.service`, `build/linux/host-README.txt`, `test/linux-host/inside.sh`; needs `freerdp_linux_host` with freerdp-ce's `server/shadow/sesman`, release-20261104.5 or newer; a root service, shipped with 聪哥's go): `HOST=1` configures FreeRDP with `WITH_SHADOW_SESMAN=ON` and puts `bin/freerdp-shadow-sesman` (checked by `build/check-portable.sh` like the server) and a system unit `freerdp-shadow-sesman.service` in the archive. The unit **runs as root**, on 127.0.0.1:3391, a port of its own (the user unit keeps 3389), and starts nothing until someone connects: it reads the first packet (the user in `Cookie: mstshash=`), finds that user's GNOME Shell, starts the shadow server in the user's own systemd manager (`freerdp-sesman-shadow`, `/ipc-socket` in `/run/user/<uid>`, `/sec:tls`, `/gfx-av1 /gfx-av2`), drops to the user and relays; TLS and the PAM login stay in the shadow server. A user with no GNOME session gets a headless GNOME Shell if they are in the group `freerdp-headless` (the unit's `--headless-group`, 聪哥: the session manager should start the session; nothing until the admin makes the group, since it starts before the login: on 127.0.0.1 only someone with an account here reaches it), with the shadow server's own virtual monitor (1920x1080), kept after the client leaves; anyone else with no session is refused. It is installed as root in `/opt/freerdp-host`, never from `~/.local` (a root service must not run files a user can change). The archive's README and this README say so, how to install, reach (SSH, port 3391), read the logs and remove it, and, for desktops whose journal is in memory only, that `journalctl --user` may show nothing (read it as root, or `Storage=persistent`). The GNOME test installs it as root as the README says and checks 9 more things: the unit active on 127.0.0.1:3391 only, tester handed to the shadow server of tester's GNOME, logged in (PAM), at least 20 AV1 frames, a user with no GNOME session refused with no frame, then, once in `freerdp-headless`, a headless GNOME started for them (logged in, on the virtual monitor, frames, still running after the client leaves).
- **`freerdp`, `freerdp_host`, `freerdp_mac_host`, `freerdp_linux_host` `20261104.4`** (`1f0f0a87d`, freerdp-d2's b8f6718ae, 聪哥's go): the web client publishes the audio format the server sends, for Info's "Audio codec" row (page `20261104.1`, pinned in the round before, reads it): `_freerdp_web_audio_format`, three numbers, the wire format tag (0 before any sound), the rate and the channels. The web sound device (`channels/rdpsnd/client/emscripten`) is opened with a PCM copy of the wire format when rdpsnd decodes (Opus, AAC, ADPCM through freerdp_dsp), so it keeps the format rdpsnd asked `FormatSupported()` about right before `Open()` and publishes that one when its rate and channels match the opened one, else the opened format. Only the web client builds this device; the native clients and the hosts are unchanged. Tested before: both wasm builds export it; freerdp-web-f8's page check (no audio yet, stand-in formats, test-page.mjs). This round's check for it: every demo's "info at the end" has an "Audio codec" line again, now with the format, e.g. "Opus, 48 kHz, stereo" on xrdp; a PCM line where Opus is expected would mean the FormatSupported-then-Open order did not hold.
- **`avm` `20261104.1`** (`9798cd4d8`, avm-release-kit-ea, 聪哥's go), the AVX-512 group on top of `20261103.3`: CPU detection and AVX-512 SAD, the 64-point forward transform and a fix for its stack frame, the high bit depth convolutions (2-D, x, y); all bit-exact. Its release kit: round 41797312153, 16/16 (avm kit 20261104.7); its simd job, on an EPYC 9V45 with AVX-512, has every path's encodes and decodes equal to pure C natively and under Intel SDE (`-spr`), and the AVX-512 kernels ran (encoder 2775735778 instructions with AVX-512 allowed against 2781090150 masked; decoder 343456961 against 344028659). This round's check for it: the AV2 sessions as before (the Windows, Mac and Linux host tests, the xrdp-gnome demo's encode and the web client's decode).
- **Each AV2 test names its CPU** (`build/cpu-line.sh`, `test/linux-host.sh`, `test/mac-host.sh`, `test/record-demos.sh`, `test/windows-host.ps1`): one line with the CPU model and whether libavm's AVX-512 kernels can run there (all five of F, DQ, CD, BW and VL with the OS's zmm state; `/proc/cpuinfo` on Linux, `hw.optional.avx512*` on macOS, n/a on arm64). Windows has a flag for F only (`IsProcessorFeaturePresent(41)`), so its line says F and that the rest are not checked. GitHub hands out different CPUs, so the line says which kernels a round's AV2 sessions ran; that the kernels are right is the AVM release kit's proof.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host`, `freerdp_linux_host` `20261104.3`** (`c021eee73`, the crash fix alone, freerdp-d2's 94d8a0540, 聪哥's go) **with `freerdp_web` `20261104.1`** (tag 92bbcc2 → `7958df57d`, freerdp-web-f8, 聪哥's go). The web client's codec counters (`20261104.2`) crashed its worker with "Maximum call stack size exceeded" on Debian's xrdp 0.10.1 right after the page asked for two monitors, so the second window stayed blank. screens (xrdp-original-xorg) failed 4 of 18 on both rungs in kit 20261104.7 and .8, green in the 7 rounds before. That xrdp reactivates the session on a monitor layout change, which connects the GFX channel again on the same `RdpgfxClientContext`. gdi then sets its four draw callbacks again but never `CapsConfirm` (`libfreerdp/gdi/gfx.c`), and `web_stats_wrap()` guarded on `SurfaceCommand` only, so the second wrap saved `web_CapsConfirm` as the next `CapsConfirm` and the next Caps Confirm PDU called itself until the stack ran out. Now each callback is hooked on its own and only when it doesn't hold ours yet. freerdp-d2's test: a native A/B of the block (3 connects, each a gdi re-init and a CapsConfirm): the old code overflows the stack 2/2, the fix passes 2/2 with the counts and caps version kept; both wasm builds build and export it. The native clients and the hosts are unchanged (the code is under `__EMSCRIPTEN__`). The page `20261104.1` reads the coming audio format export (`_freerdp_web_audio_format`) for Info's "Audio codec" row and hides the row while the client has none, as with this FreeRDP. This round's checks: screens (xrdp-original-xorg) green again; the demos' "info at the end" keeps its Video codecs rows and has no "Audio codec" line; the rest as before. Latest 20261104.7 and .8 carry the crash: publish the site from this round's Latest or from 20261104.6 (FreeRDP .1, no counters).
- **`avm` `20261103.3`** (`5b965cfa4`, avm-release-kit-ea), the grouped release 聪哥 asked for: `20261103.2` plus seven bit-exact C speed-ups; four of them touch the decoder too (mode-info offsets, motion-field projection, the x86 loop-filter decision, deblocking prefetch). Streams and decoded pictures are unchanged. Its release kit: round 41771647948, 16/16 (every target decodes every vector to the same MD5; its SIMD gate gave AVX2 = SSE2 = C), avm kit 20261104.3. This round's check for it: the AV2 sessions, encoder and decoder both (the Windows, Mac and Linux host tests), and the web client's AV2 decode (the xrdp-gnome demo's Video codecs row shows AV2).
- **The Linux host logs straight to the journal** (`build/build-sdl3-client.sh`, `build/linux/freerdp-shadow.service`, `test/linux-host/inside.sh`): with `freerdp_linux_host` `20261104.1` WinPR's journald appender builds (FreeRDP#14029), so `HOST=1` now configures FreeRDP with `WITH_SYSTEMD=ON` (libsystemd was already one of the host libraries `build/check-portable.sh` allows, for sd-bus; the clients and the other hosts keep it off) and the unit logs with `WLOG_APPENDER=journald WLOG_JOURNALD_ID=freerdp-shadow-cli WLOG_LEVEL=INFO` instead of syslog: each line reaches the journal at once with its level (INFO = priority 6) and the identifier syslog gave it, and `journalctl --user -u freerdp-shadow` shows it. `HOST=1` fails when the binary does not import `sd_journal_stream_fd` (the appender left out, as before #14029; the `20261103.2` binary fails that check). The GNOME test reads the server's lines as the user would, `journalctl --user -u freerdp-shadow` as the session's owner (it read them as root by identifier), and checks that they come from the journald appender: its stream (`_TRANSPORT=stdout`, where syslog's lines say `syslog`), the identifier `freerdp-shadow-cli`, and each line's own level (an INFO line at priority 6, GNOME's stop at WARN, 4; the console appender would give 6 to all). The README and the archive's README say what the log shows.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host`, `freerdp_linux_host` `20261104.2`** (`ecd4af2ba`) **with `freerdp_web` `20261103.4`** (tag cdf2f42 → `2688275c2`), one round as their order needs (the page first or together): the web client counts the GFX commands per codec (freerdp-d2's 736f42cab, 聪哥's go: 105 lines in `client/SDL/SDL3/sdl_channels.cpp`, all under `__EMSCRIPTEN__`, so the native clients and the hosts are unchanged) and exports them as `_freerdp_web_codec_stats` (layout 2: the confirmed caps version, so AV1 and AV2 are told apart, then a count and bytes per codec id, plus SolidFill, SurfaceToSurface and CacheToSurface); the page (freerdp-web-f8, 聪哥's go) shows them in Info's "Video codecs" as a rate and kbit/s per codec, and hides the row with no export or another layout. Tested before: both wasm builds export it, layout 2 at run time, test-page.mjs passes (JSPI); unit 88. This round is the live check: the demos' "info at the end" prints the row per session, AV2 on xrdp-gnome, AV1 4:4:4 on the Mac and Windows hosts, and what Windows' own Remote Desktop really sends.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host`, `freerdp_linux_host` `20261104.1`** (`a320ee5bc`, picked from integration-all): `20261103.2` plus freerdp-ce's three Mutter backend fixes and freerdp-d2's journald fix (聪哥's go for each). The Mutter backend draws the cursor into the picture for now (4a584d783): in Mutter's metadata cursor mode Mutter 50 skipped a fresh stream's full frames as "too early", so the first picture was black in 8 of 15 runs and no later change reached the client in 12 of 12 (GNOME/mutter#5179); embedded, 3 of 3 with nothing skipped, and the clients get a transparent pointer so there is one cursor. It records the monitor again when its layout changes, and keeps the lock keys a Synchronize sets. WinPR's journald appender was never built (`WINPR_HAVE_JOURNALD_H` set in one directory's scope only, since 25f3633dc): a private definition now (FreeRDP#14029). freerdp-ce's tests: e2e 37/37; freerdp-d2's: the A/B into the journal. Only the Linux host builds the Mutter code; the clients and the other hosts get the journald fix, which needs `WITH_SYSTEMD` (off in the kit's builds), so for them nothing changes. This round's check for it: the Linux host tests (gnome, xorg) and every client and host test as before.
- **The freerdp-tk Windows video again: no "pin Firefox to your taskbar" prompt** (`test/demo/user.js`, `test/windows-host.ps1`): the "New notification" that kept PowerShell from the front, and skipped the freerdp-tk Windows video in most rounds since kit 20261103.10, is Firefox's own first-run prompt, "Would you like to pin Firefox to your taskbar? This request is coming from Firefox", over the console's Firefox (seen in 20261104.4's windows-host.mp4). It came with StorSvc stopped too, so that was a separate thing. The demo profile turns off Firefox's onboarding, upgrade and recommendation messages, and on a CI runner the test adds the same as enterprise policy (`distribution\policies.json`, `UserMessaging`); on another machine it leaves Firefox's install alone.
- **The Linux host joins the release (step 2)**: `linux-host` and `linux-host-test` (gnome, xorg) no longer run with `continue-on-error` (green in four rounds) and are in the release job's `needs`, so a round publishes only with the Linux host built and tested on both desktops. The release takes the artifact `freerdp-host-linux-x86_64` from its job's newest attempt (`build/newest-artifact.sh`, as the demo videos), checks the tarball against its `.sha256`, and publishes `freerdp-host-<version>-linux-x86_64.tar.xz` with the other assets (its checksum in `SHA256SUMS`, attested like them), a row in the release notes' download table and the `linux_host` pins table. `install.json` gets a `"linux"` section in the macOS host's shape, one entry per architecture (x86_64 for now): the file and its link, the unit (`freerdp-shadow.service`), the install command from the archive's README, what follows (127.0.0.1 only, reached over SSH; the autostart line for desktops without `graphical-session.target`), `kickstart` (`systemctl --user restart freerdp-shadow`), the log and how to remove it. The site's Get a server doesn't show it yet (a page change in freerdp-web); no demo video yet (step 3), so `build/site-anchors.json` gets no key yet: its keys name demo video files, and `build/site.sh` fails only on a video without one. README: "Installing the Linux host", keep it on 127.0.0.1 and reach it over SSH.
- **`avm` `20261103.2`** (`76a2133c2`, avm-release-kit-ea): `20261103.1` plus 6925ebb78, the nonzero count kept in the cost loop; encoder only, bit-exact. Its release kit: round 41757839809, 15/15 (avm kit release 20261104.1). This round's check for it: the AV2 sessions (the Windows and Mac host tests, the xrdp-gnome demo).
- **`freerdp_web` `20261103.3`** (tag 2bca7ff → `86d70fedd`, freerdp-web-f8, 聪哥's go): Info hides "Video codecs" while the client has no `_freerdp_web_codec_stats` (no current client has), and shows it again with one that has; it said "–" in every run. On top of .2, nothing else. freerdp-web's tests: unit 82, test-page all PASS, a real-client check (the row gone, the others unchanged, no page errors). This round's check for it: the demos' "info at the end" has no "Video codecs" line, the rest as before.
- **The Windows web demos are fast again: StorSvc is off during the Windows host test** (`test/windows-host.ps1`): from kit 20261103.10 to 20261104.2 the host demo took 479 to 922 s in most rounds against ~175 s. It was not the page: freerdp-web-f8's A/B without its frame counter was slow too (922 s), and Defender's real-time protection is off on the runner. In every slow run StorSvc, the Storage Service, burned 81 to 147 s of CPU, and the shadow server, dwm and the browser slowed with it; free disk was ample (27 GB on C:). With StorSvc stopped and disabled before the demos the same test took 182.5 s and 185.7 s (run 41751477744). The "New notification" that kept PowerShell from the front, and skipped the freerdp-tk Windows video in three rounds, came in the slow runs only. A CI runner has no use for the service; the test stops it there only (`GITHUB_ACTIONS`), never on another machine.
- **The Windows host test names the busy svchost** (`test/windows-host.ps1`, `Defender`): the CPU lines give each process's id, and for a `svchost` the services it hosts. The Windows web demos are slow in some rounds only (840 and 922 s against ~170 s), with or without the page's frame counter (freerdp-web-f8's A/B, run 41740460540, without `decode-stats.js`: 922 s), and in every slow run one svchost used ~140 s of CPU while none did in the fast one (41740673857); this says which service: StorSvc, the Storage Service, in run 41746509344 (595 s, 81 s of its CPU), so the lines give each drive's free space too. Defender is not it: its real-time protection is off on the runner. Diagnostics only.
- **The Mac web demo's screen is 16:9**: `test/mac/display-mode.swift` now prefers the largest 16:9 mode up to 1600 wide (1600 x 900 on the runner, as the Windows test's screen), since 1600 x 1200 (kit run 41644958011) is taller than the page's canvas and lost its bottom, the Dock with it.
- **`avm` `20261103.1`** (`55df12d6d`, avm-release-kit-ea): `20261031.2` plus one plain-C change, `av2_avg_cdf_symbols` in one vectorized pass, bit-exact; the encoder spends 1.8 to 4.1 % fewer cycles on inter frames, and the decoder calls it once per frame. Its release kit: round 41739896575, 15/15, every target bit-exact, tsan clean (avm kit release 20261103.2). This round's check for it: the AV2 sessions (the Windows host and the Mac host tests, the xrdp-gnome demo) and the web client's AV2 decoding.

## 2026-11-03

- **`freerdp_web` `20261103.2`** (tag c8015f5 → `ec91cd8b9`, freerdp-web-f8, 聪哥's go): the page shows the demo videos' titles and captions from `demo.json`'s `i18n.<lang>`, field by field with English as the fallback, in the intro, Get a server and Get a client, and follows a language change on the open page. On top of .1, no decode or Info code changed. freerdp-web's tests: unit 82, test-page all PASS, a Chrome check against 20261103.9's demo.json 26/26 in en/zh/ja/fr. This round's check for it: the web login test and the demos with this page.
- **A new product, the Linux host (step 1: build and test; not in the release yet)**: `HOST=1 ./build.sh` builds FreeRDP's shadow server for Linux desktops, `freerdp-host-<version>-linux-x86_64.tar.xz`, from a pin of its own, `freerdp_linux_host` (`20261103.2`, the same commit as the other FreeRDP pins: freerdp-ce's Mutter backend and c6d03209e's subsystems chosen at start). One binary, two subsystems, the first that finds a monitor wins: Mutter (GNOME on Wayland or X11; PipeWire, libei input) and X11. Built in the Linux client's AlmaLinux 9 image plus the host's headers (`build/linux/host.Dockerfile`: PAM, Xdamage, Xinerama, jinja2), with libaom (AV1), libavm (AV2), Opus and libei (new pin `libei` `1.6.0`, its client library, static: AlmaLinux 9 has none) linked in; `build/check-portable.sh` takes a third argument, the host libraries a product may need (here PAM, libsystemd, PipeWire, X11 and five of its extensions). The archive holds a systemd user unit (`build/linux/freerdp-shadow.service`: 127.0.0.1:3389, TLS security with PAM logins, AV1 and AV2, `Restart=on-failure`; its log through syslog, since WinPR's journald appender is never compiled, `WINPR_HAVE_JOURNALD_H` being set after `config.h`) and a README in the other hosts' style. `test/linux-host.sh gnome|xorg` and two non-blocking CI jobs, `linux-host` and `linux-host-test`: GNOME Shell 50 headless under systemd in a podman container (Mutter by default, `/subsystem` lists it first, AV1 and AV2 frames, idle CPU with one client, keys through libei, another account refused, GNOME's Stop ends the unit with 0 and no restart) and Xfce on Xvfb with `/subsystem:x11`.
- **The Windows host test logs Defender and the CPU** (`test/windows-host.ps1`, `Defender`): around each demo it writes Defender's detections and threats and the six processes with the most CPU time to `memory.txt` and the log (`DEFENDER …`). Since `freerdp_web` `20261103.1` (kit 20261103.10 and .11), both web demos on the Windows runner took about 3 times as long (489 s against 159 s; 274 s against 155 s), the Remote Desktop demo's last 30 s had no sound, MsMpEng held 610 MB against 160 MB, and a "New notification" kept the front, so the freerdp-tk Windows demo was skipped twice. The Mac (136 s) and Linux demos kept their times. Diagnostics only.
- **The web demos print what was decoded** (`test/wasm-demo.mjs`, freerdp-web-f8's ask): the "info at the end" keeps the H.264 rows, and a new "decode stats:" line gives the page's `freerdpDecodeStats` and each FreeRDP H.264 decoder's state ("none" = opened, but no H.264 key frame came). The Windows-RDP demo's Info said "H.264 decoder WebCodecs" with no "H.264 frames" row in kit 20261103.10, so whether Windows sent H.264 at all is still open; this answers it. Test output only, no product change.
- **A rerun's videos reach the release** (`build/newest-artifact.sh`, the release job): after `gh run rerun --failed` a run holds one artifact per attempt under the same name, and `actions/download-artifact` by name took the first attempt's. In kit run 41714694578 the xrdp-kde demo failed on a full runner disk, passed on the rerun, and 20261103.11 still shipped the first `demo-release` (21:09, no KDE video) instead of the rerun's (21:39). The release job now takes `windows-host-demo`, `demo-release` and `mac-host-test` from their newest artifacts (it gets `actions: read` for that). Checked against that run: the newest of 2, with `xrdp-kde`.
- **Emscripten 6.0.13** for the web client (`build-wasm.sh`, image pinned by its multi-arch digest), in step with avm-release-kit (聪哥's ask; its round 41655702766 built libavm with it and decoded every AV2 vector bit-exact). 6.0.13 drops FS.filesystems and the .bat/.ps1 launchers, deprecates MEMORY64=2, and wasmExports no longer holds copies of unwrapped exports; avm-release-kit-ea found none of these used in freerdp-web, the FreeRDP client or the kits.
- **`freerdp_web` `20261103.1`** (tag a44abcc → `adaa52f36`, freerdp-web-f8, 聪哥's go): the Info panel counts the video frames again. It read counters only an archived FreeRDP commit ever filled, so it said "AV1 frames 0 total" on every server; the page now wraps the browser's VideoDecoder itself (web/decode-stats.js) and counts chunks, key chunks, bytes, pictures and decode time per codec, AV1 and H.264. freerdp-web's tests: unit 80/80, i18n 64, page 45. This round's check for it: the demos' "info at the end" shows AV1 frames above 0 (Mac, Windows, xrdp). Pinned again after kit run 41663373883: its `xrdp-gnome` demo had no sound on both tries, but GNOME Shell never reached the overview there (a GeoClue D-Bus timeout 25 s in, the video shows only the wallpaper), and that session sends AV2, which the page's new counter never wraps; the job rerun on a fresh runner with the same page passed.
- **demo.json in four languages**: every entry of `videos`, `clients`, `windows` and `mac` gets `i18n` with the title and caption in Chinese (Simplified), Japanese (です/ます) and French (vous, a no-break space before : ; ? ! and inside « »), from `build/demo-i18n.json`, keyed by the English text (freerdp-web-f8's field shape). The release job adds them (`build/demo-i18n.py`); an English text with no entry, such as a caption changed since, stays English, so edit both together. Product names are kept as they are; titles made only of them ("xrdp + GNOME Wayland, AV1") need none.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261103.2`**: `20261103.1` plus freerdp-ce's c6d03209e ("build several subsystems, pick one at start", stacked on FreeRDP#14006; 聪哥's go): the shadow server can be built with X11 and Mutter together and takes, at start, the first that finds a monitor (Mutter, then X11); `/subsystem:<name>` forces one, plain `/subsystem` lists them. Builds with one subsystem, as all the kit's are today, behave as before. It lets the coming Linux host be one binary for GNOME and X11 desktops. Also FreeRDP#14004's review (46961cd04, 79d692b40): the 8 MiB default stack is now the CMake variable `WINPR_THREAD_DEFAULT_STACK_SIZE` (default 8388608, 0 = the platform's), same behaviour.
- **The Mac web demo, second pass**: Firefox starts once, headless, before the video (its first launch on a fresh Mac came ~20 s late in kit run 41630233301), and the Mac's screen goes to the largest mode up to 1600 wide before the demo's server reads it (`test/mac/display-mode.swift`; the modes it found are in `web-display.txt`), so the desktop fills more of the page. Firefox's window follows the screen's size.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261103.1`**: `20261102.4` plus three fixes. 7e8ea8f8e (freerdp-d2, FreeRDP#14020): input that races a reactivation is dropped instead of failing the send; the SDL client sends input from its event thread, so a mouse-enter while the server reactivated (a size change) ended the session (kit run 41630233301, the Windows test's ipc session). 46b359005 (FreeRDP#14004 after review): every default-size WinPR thread gets at least 8 MiB of stack on Unix, in place of the shadow client thread's own (macOS gives 512 KB; libavm's AV2 encoder overflowed it). 9f9a5f5d3 (freerdp-ce, FreeRDP#14006's review): the Mutter backend's style fixes, no behaviour change (it stays off in these builds).
- **The Mac web demo, second try**: the first run (kit run 41627099963) recorded 967 frames and 135 s, and the server sent the page AV1 at 15 to 18 fps, but ffmpeg found no frames (a relative output folder; the Windows test passes an absolute one) and Chrome's profile cleanup raced its exit. Both fixed; the AV1 check now counts the server's encoded frames, since the page's Info panel said 0 while the picture came.
- **The Mac host's demo is made the Windows host's way** (聪哥: "make mac demo works the same as windows host"): `test/mac-host.sh` now runs FreeRDP Web in headless Chrome (`test/wasm-demo.mjs`, `SERVER=mac`) through websockify to a Mac host of its own with AV1 only, and opens Firefox on the Mac with the media page (Big Buck Bunny, the WebGL Aquarium). No browser window is on the Mac's screen, so the video shows its desktop and Firefox, not a client showing itself. Nothing is typed there (the host runs with -auth, and the runner may not let it inject keys). New job `demo-media` hands the media to the Mac job; mac-host-test gets ffmpeg from Homebrew and 35 minutes. The release takes this video as demo.json `mac` when it exists, else the old screen recording.
- **The release page is pruned, and stays pruned**: `build/prune-prereleases.sh` deleted 176 per-round pre-releases (web-, xrdp-, demo-, pipewire-module-xrdp-, mutter-) whose kit commit has a kit release carrying the same files, keeping the newest 3 of each kind (freerdp-web's kit-release.sh and the demo job read the newest) and every one with no kit release. Before any deletion, the notes and the 8.4 MB of files no kit release holds went into `pruned-20261103-080035.tar.gz` on the pre-release `prerelease-archive`; tags stay. The release job now runs it after each publish (non-blocking). The older `xrdp-preview-*` pre-releases aren't a kind it prunes.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261102.4`: the rebuild on master `9f9d97e81` again** (it was `.3`, held back when the Windows test lost Ctrl+Alt+Del; freerdp-d2 showed the code involved was unchanged, and the test's race is fixed since kit 20261103.2). Upstream merged #13934 (the Windows shadow service), #13948 (the macOS backend), #13974 (the AV1 tuning) and more; new in it: #13925's review, #13954 rebased, the DXGI cleanup (b2f2f33ac), and freerdp-ce's Linux GNOME shadow backend (upstream PRs #14005, the /monitors errno fix, and #14006) with two fixes on top: 907e1522d no busy loop while clients are connected (WinPR has no auto-reset events; 101 % CPU idle before, 2 % after) and 59330d93d the server ends with 0 when the user stops the sharing. The Mutter backend stays off in these builds; its own product comes next.
- **Ctrl+Alt+Del in the Windows test: back to back again**: the gaps between the keys (yesterday's change) made it fail both tries (kit run 41559774950: the server's key events went from 1,926 to 89,157, the echo of the injected keys through the console flipping Ctrl and Alt before Delete). The settle check, the second try and the noted key count stay.
## 2026-11-02

- **The Windows test types Ctrl+Alt+Del with care** (kit only): kit run 41549326887 failed it because Delete reached the server before Ctrl and Alt and was typed (freerdp-d2: the code involved was byte-identical to the passing release). The test now checks the client is the foreground window after a settle, leaves 150 ms between the keys, tries once more if the server didn't take it (a product fault fails twice), and notes the server's key events before and after (the echo loop of a typed key through this console).
- **FreeRDP back to `20261102.2` for now**: `20261102.3` (the rebuild on master 9f9d97e81) failed the Windows host test (kit run 41549326887): Ctrl+Alt+Del no longer reached the service, and the server got 85,630 keyboard events in the run (a flood; 1 Delete press in the rounds before). The cause is being looked into in FreeRDP; this release ships the page and the install.json `kickstart` on the last good FreeRDP.
- **`freerdp_web` `20261102.1`** (`220ac9656`, freerdp-web-20, 聪哥's go): the page in four languages (Language menu: Auto, English, 中文, 日本語, Français); Get a server shows the macOS host after Windows, from install.json `mac` (a card per processor: command, the two permissions in the page's own words, restart, removal) with demo.json `mac` as its video; the safety banner opens with "Your security is your own duty": an unofficial community client, as is; its author always keeps RDP behind SSH; every server the kit ships listens on 127.0.0.1 only; never open an RDP port to a network. freerdp-web's own tests: unit 77/77, i18n 64 (Japanese and French browsers added), the server and page tests.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261102.3`: integration-all rebuilt again, on master `9f9d97e81`** (freerdp-d2's integration-all-next2, checked and adopted): upstream merged #13934 (the Windows shadow service), #13948 (the macOS backend), #13974 (the AV1 tuning) and more, so integration-all is master plus 41 commits. New in it: #13925's review (one capability version for AV2, the AV1 I444 flags reused; the test data's AV2 settings), #13954 rebased, the DXGI cleanup (b2f2f33ac: the two access-denied branches of #13949 that our pause made unreachable are gone; #13949's DuplicateOutput retry stays), and freerdp-ce's Linux GNOME shadow backend on Mutter's APIs (600d167a9 also fixes /monitors:N refused when a stale errno was set, in every build; e98a978bd, 5221ef1a8: `-DWITH_SHADOW_MUTTER=ON`, off by default, so no kit product changes yet; its own product comes next). Kit check: every commit of `20261102.2` not in master is in this one; server/shadow/Mac identical. freerdp-d2's Linux build and ctest 179/179 passed, and its WITH_SHADOW_MUTTER build compiles clean.
- **install.json's `mac` entries get `kickstart`**, the restart command alone (freerdp-web asked: the page writes the permissions sentence itself, in four languages).
- **install.json lists the macOS host** (聪哥: the page's server install part gets the Mac shadow server): a `mac` entry per architecture (Apple Silicon, Intel) with the file, its URL, the Terminal command from build/macos/host-README.txt (download, unpack with ditto, copy the app and the LaunchAgent, bootstrap it), what to allow in System Settings (Screen Recording, Accessibility) and the removal commands; like the Windows entry, the server listens on 127.0.0.1 only, for SSH.
- **The release carries the macOS host's demo video**: `mac-host.mp4` and `mac-host.jpg`, made from mac-host-test's recording (the first recording: kit run 41460724255, 13.7 s, the client showing the Mac's own screen as a hall of mirrors, System Settings opening), and `demo.json` lists it under `mac` and among the videos. The release job now waits for mac-host-test (still non-blocking).
- **mac-host-test records a demo video**: 15 s of its first session with macOS's own `screencapture -V` (the runner's screen, where our client shows the Mac's own screen), turned into `mac-host.mp4` and a picture when ffmpeg is there; in the job's artifact for now, into the release once it records well.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261102.2`: integration-all rebuilt on FreeRDP master `c6d2998da`** (聪哥: "all three as you advise"; freerdp-d2 built the candidate integration-all-next, the kit checked and adopted it): master now has FreeRDP 3.33.0, a security fix, and 15 of our pull requests (#13805, #13933, #13935, #13943, #13946, #13956, #13957, #13961, #13971, #13973, #13975, …), so integration-all is master plus 59 commits instead of master `dae0390a4` plus 69. Each part comes from its current branch with the review fixes: #13934 (the service), #13954 (Windows sound), #13958 (held keys, with the deadlock fix), #13948 (the Mac backend), #13970 (Media Foundation H.264, reworked to fail configuration when the encoder refuses a value; not yet run on Windows Server: this round does), #13974, #13978, #13982, #13983, the AVC444 fixes, the Mac login-window work, the 8 MiB stack. Checked by the kit: every commit of the old integration not in master is in the new one, five Mac ones by content (#13948 is a squash; server/CMakeLists.txt identical, mac_shadow.c only added brackets). Our DXGI pause (feature-shadow-win-service) sits on top of caomengxuan666's merged #13949 and checks first, so the behaviour is ours (a lock can last hours; #13949 gives up after 2 minutes); #13949's DuplicateOutput retry stays. freerdp-d2's Linux build and ctest (179/179) passed.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261102.1`** (`9b32d8883`, freerdp-d2's fix on neon-rgb-to-yuv420, FreeRDP#13983): `20261101.20` plus three commits. The x86 SSE4.1 `RGBToYUV420` (BGRX/BGRA: the H.264 AVC420 encode and AVC444's main view) never wrote U and V for an odd last column or an odd last row; those chroma samples kept whatever the buffer held, so at an odd frame size (e.g. 1601x901) the right or bottom edge came out in a wrong colour. The edges now go to the generic routine, as NEON's do. The test now checks the edges of every implementation: on x86 it failed at 1x1 and 15x3 before the fix and passes after; TestPrimitives and the H.264, planar, progressive and RemoteFX codec tests pass (freerdp-d2, Linux). The Windows and Mac host tests run at even sizes (1600x900, 1024x768), so this round doesn't exercise the edge itself.
## 2026-11-01

- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.20`** (`e95e6755d`, freerdp-d2's 63da26ad1 on shadow-client-thread-stack, 聪哥's go): `20261101.19` plus an 8 MiB stack for the shadow server's client thread, which encodes inline. With the platform's default (512 KB on macOS), libavm's AV2 encoder overflowed it: the Mac host died at the start of every AV2 session (SIGBUS in `___chkstk_darwin` ← `av2_pack_bitstream`, two macOS crash reports, kit mac-capture-probe run 41370598608). freerdp-d2 reproduced it on Linux with a 512 KiB thread stack (3 of 3 crashed, fault 524,480 bytes below the stack top in the recursive partition search) and the fix held (3 of 3). On Windows the flag makes it a reservation, committed as used. The Mac host's LaunchAgent takes `/gfx-av2` again, and mac-host-test's AV2-capable client expects AV2.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.19`** (`3d563e528`, freerdp-d2's 72b43140e on shadow-release-held-keys, 聪哥's go): `20261101.18` plus one fix for a deadlock that `.8`'s release of held keys (#13958) brought in. On a client's Synchronize, `shadow_input_release_keys` took the server's client-list lock to see whether another client still held a key, while the capture thread held that lock around `shadow_subsystem_frame_update`, which waits for every client thread to take the frame (`WaitForSubscribers`): each waited for the other, and every later user of the lock stopped too (the next client, the sound thread). It needed a frame right around the Synchronize, so it was intermittent; the Mac host hit it in every mac-host-test run, and `sample` of the frozen server on the macOS runner showed exactly those two threads (kit run 41377533918). `win_shadow.c` has the same lock-and-wait pattern, so the Windows host could freeze the same way. The fix counts each key's holders under the server's own lock and no longer touches the client list; a key another client holds stays down, as before. freerdp-d2's reproduction on Linux (an X11 shadow made to lock like Mac/Windows, the screen changing, repeated connects): hung in 4 of 7 runs before, none in 8 runs (320 connects) after. The cherry-pick's conflict with the AV2 fields in `shadow.h` resolved as freerdp-d2 did (both files byte-identical to its f4e47369c).
- **The macOS host leaves AV2 out for now: an AV2 session crashed it.** mac-host-test and the `mac-capture-probe` branch (run 41370598608) showed the server dying at the start of every AV2 session, twice, with macOS crash reports: `SIGBUS KERN_PROTECTION_FAILURE` in `___chkstk_darwin` called from libavm's `av2_pack_bitstream`, on `shadow_client_thread`, which encodes inline. That is a stack overflow: FreeRDP creates that thread with the platform's default stack (`shadow_client.c:3236`, `CreateThread(nullptr, 0, …)`), 512 KB on macOS against 8 MB on Linux and 1 MB on Windows (whose AV2 check passes). The LaunchAgent drops `/gfx-av2`, so the kit's clients, which offer AV2 by default, get AV1 (339 and 352 AV1 frames in the same probe); the README and release notes say AV1 and H.264. The FreeRDP fix (a larger stack for that thread) is asked of a FreeRDP session; AV2 comes back with its pick. Also seen, not yet understood: sometimes the first session after the server starts hangs before the GFX caps confirm.
- **mac-host-test, round 2**: its first run (kit 41366524328) found that the macOS host goes down at the start of an AV2 session on the runner (its log ends at the AV2 caps confirm, the port closes); the test's "AV1" session had got AV2, since the client offers both and the server takes AV2 first. AV1 now runs with `/gfx:AV2:off`, AV2 runs last, the test checks the host is still alive after each, and it keeps macOS's crash reports of the server.
- **The macOS host is tested on CI, like the Windows one** (聪哥: "a macOS demo like Windows?"): a new job, `mac-host-test`, runs this round's FreeRDP-Shadow.app on a GitHub macOS runner (arm64) sharing the runner's own screen, and this round's macOS client connects twice (`test/mac-host.sh`): an AV1 session and an AV2 session, each needing at least 30 frames in 20 s, with screenshots. It was thought impossible (a CI Mac can't grant Screen Recording), but GitHub's macOS images grant it to `/bin/bash`; the throwaway branch `mac-capture-probe` found the way (run 41366210580: 348 AV1 frames, up to 29 fps, the Mac's hall of mirrors). The host runs with `-auth` there, since the in-session host takes only the screen owner's login and the runner account's password can't be set; and apps open and close during each session, since ScreenCaptureKit hands over a frame only when the screen changes. New, so it doesn't block a release yet; a demo video comes next.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.18`** (`18da48a67`, freerdp-84's 523258ddc, 聪哥's go): `20261101.17` plus NEON `RGBToAVC444YUV` and `RGBToAVC444YUVv2`. arm64 had none, so H.264 AVC444 on the Mac host converted every frame in generic C. Byte-identical in both views (edge columns and an odd last row go to the generic double-row routine, as SSE4.1 does). Unit-tested on an Apple M5: TestPrimitivesYUV 3/3, 80 strict AVC444 cases (v1 and v2, both views whole; two mutants caught); 1080p v1 1.93 → 0.40 ms, v2 2.22 → 0.44 ms. Only arm64 builds change. It shows in a Mac host session that uses AVC444, which the LaunchAgent's `-gfx-avc444` leaves out; not measured in a session.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.17`** (`dc8706adf`, freerdp-84's 72e4a7e96, 聪哥's go): `20261101.16` plus a NEON `RGBToYUV420_8u_P3AC4R`. arm64 had none, so on the Mac host AV1 I420 and the YUV conversion in front of H.264 (`codec/yuv.c`) ran generic C. Byte-identical to the generic routine (the columns past the last 16-pixel block and an odd last row go to it). Unit-tested on an Apple M5: TestPrimitivesYUV 3/3, 32 strict generic-vs-NEON cases (5 formats, odd sizes, padded strides; a wrong-coefficient mutant caught); 1080p 1.13 → 0.20 ms. Only arm64 builds change (the Mac host, the Mac and Linux aarch64 clients); not yet measured in a Mac host session.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.16`** (`c810f068e`, freerdp-84's 6530a9025, 聪哥's go): `20261101.15` plus an AVX2 `RGBToI444_8u` (its own source file built with -mavx2, picked at run time when the CPU has AVX2, as prim_copy_avx2 is). 1080p 1.02 ms (SSE4.1) → 0.54 ms; byte-identical output, so the AV1 stream doesn't change. TestPrimitivesYUV passes on amd64 (widths 31/32/33/63 added; a wrong-permute mutant caught).
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.15`** (`53b98dda2`, freerdp-84's i444-simd 21f9db383, 聪哥's go): `20261101.14` plus one commit. `RGBToI444_8u` had only a per-pixel generic routine (FreeRDPReadColor + FreeRDPSplitColor for each pixel); it now has a fast path for the 32-bit formats, generic, SSE4.1 and NEON, with the same integer math, so the output is byte-identical and the AV1 stream unchanged: 1080p 10.6 ms → 1.0 ms (SSE4.1) / 1.1 ms (generic). freerdp-84's AV1 I444 bench: 1080p text 21.7 → 11.7 ms per frame, video 20.6 → 14.9, idle 8.4 → 7.1; 900p text 17.9 → 10.8, video 15.9 → 11.5; PSNR and bit rate the same. TestPrimitivesYUV passes on amd64 (two mutants caught); NEON passed 56 of 56 cases under qemu-aarch64 and TestPrimitivesYUV natively on an Apple M5 (1080p: NEON 0.37 ms, generic C 0.77 ms); not yet in a Mac host session. The Windows job's `av1-stats.txt` should show lower encode times.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.14`** (`8b613b0a2`, freerdp-bc's dbc167b07, 聪哥's go): `20261101.13` plus one Mac fix. The Mac shadow server ignored the RDP Synchronize event, so the Caps Lock flag on the key events it posted was whatever the last client had left, and a new client with Caps Lock off typed capitals. It now follows the client's Caps Lock. Proven on a Mac in daemon mode: before, abc / Caps / def typed "ABCdef"; after, "abcDEF" in 6 of 6 runs, with "synchronize 0x00000000: caps lock off" at each connect. Not run end to end: a client connecting with Caps Lock on (the test's X server can't set the Lock modifier); the same path with the bit set.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.13`** (`843fb8507`, freerdp-bc's 6ba69fe38, 聪哥's go): `20261101.12` plus one Mac fix. The Mac host never sent its cursor shapes, so clients drew only their default arrow: the shadow server sends shapes only when ShowMouseCursor is set, which only `/server-side-cursor` does (its help text reads the other way round), and otherwise sends SYSPTR_DEFAULT. The Mac's frames never contain the cursor, so the Mac backend now always sets it, in the app as packaged today and in daemon mode. Proven with xfreerdp3 3.32.2: before, 5-6 xf_Pointer_SetDefault and no xf_Pointer_New; after, xf_Pointer_New x5 and Set x10 as the Mac's cursor changed (text 23x22 ↔ arrow 28x40).
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.12`** (`f1f151455`, freerdp-bc's feature-shadow-mac-loginwindow, three more commits, 聪哥's go): `20261101.11` plus the display following. The Mac shadow surface follows a display change (a ResetGraphics to the client at the new size), at the login-window handover too; the displays are checked once a second, since the reconfiguration callback never reaches a CLI process without an NSApplication; and when ScreenCaptureKit names a display differently from Quartz (as root at the login window Quartz gives IDs 26/28/30 where ScreenCaptureKit lists 1), the display of the same size is captured, where the login window's capture failed once a second before. Proven on a Mac (macOS 26.7.1, daemon and agent, one client connection never reconnected): 1470x956 → 1280x832 → 1470x956 in the session, each a ResetGraphics; logout at 1280x832 with the login window captured through the fallback; login back to 1470x956. The in-session app gets the follow too.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.11`** (`c40d50851`, freerdp-bc's feature-shadow-mac-loginwindow, stages 1-3, 聪哥's go): `20261101.10` plus four Mac commits. The Mac shadow server can run as a root daemon with an agent in each session (the login window included), over XPC: input goes to the HID system as root at the login window, and any local user but root may log in there. Proven on a Mac (macOS 26.7.1): the login window over RDP, typing into its password field, and one client connection kept from the login window through the login to the user's desktop, the agent switching at logout and login. It is opt-in (`FREERDP_SHADOW_MAC_AGENT_SERVICE` and a new `freerdp-shadow-agent`); the kit's package still runs the app in the user's session as before, and packaging the daemon mode (a root LaunchDaemon with `HOME=/var/root`, a LaunchAgent for LoginWindow and Aqua) is a release of its own. Not handled yet: a different display size at the handover.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.10`** (`17a07c355`, freerdp-bc's shadow-avc420-v10, FreeRDP#13978, 聪哥's go): `20261101.9` plus one fix. The shadow server enabled AVC420 only for clients whose caps carry `RDPGFX_CAPS_FLAG_AVC420_ENABLED`, an RDP 8.1 flag, so an RDP 10 client (Windows' own Remote Desktop client, xfreerdp3) never got plain AVC420, and with `-gfx-avc444` fell back to RemoteFX. Now 8.1 sets keep their flag and 10.0+ sets get AVC420 unless they say AVC_DISABLED; the server's `-gfx-avc420` still applies. freerdp-bc's A/B on the Mac (server `-gfx-avc444`, xfreerdp3 3.32.2): RemoteFX x836 with the first frame after 24 s before, AVC420 with the first frame after 8 s after. So `-gfx-avc444` now means AVC420 for every modern client: the Windows host keeps it (its README says so), and the Mac host's LaunchAgent takes it again (AVC420 measured 15-18 times less traffic than AVC444 there).
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.9`** (`08b240301`, freerdp-71's h264-diff-tile-chroma-rows, 聪哥's go): `20261101.8` plus one fix. `diff_tile` read a tile's U and V at row y instead of y/2: a 256x256 grey frame whose lower half changed colour reported 12 changed tiles, 4 of them falsely in the upper half; now exactly the 8 lower ones. AVC444v1 with changed regions 33.5 → 34.2 dB with 3% fewer bits, AVC420 unchanged. The whole stack `.5` to `.9` against master (freerdp-71, OpenH264, changed regions): AVC444v2 12.2 dB at 22.5 Mbit/s → 35.1 dB at 12.2 Mbit/s, AVC420 2.85 → 0.39 Mbit/s (-86%) at the same quality; h264.c and yuv.c blob-identical to its measured integration-shadow-win 72c9249f1.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.8`** (`c310adbb6`, freerdp-71's h264-encode-keep-last-frame, 聪哥's go): `20261101.7` plus one fix. The H.264 encoder alternates between two sets of planes and converts only the changed region, so outside it the encoder saw the frame before last, or black (the second set starts zeroed): a "change" on every frame. It now copies the last frame's planes first, unless the region is the whole frame (up to 4.3 MB of memcpy per frame at 1600x900). Measured alone on master: AVC420 with changed regions 2.85 → 0.61 Mbit/s at the same quality. The trade-off, measured: with OpenH264's all-keyframe AVC444, bits go up 13% (12.0 → 13.5 Mbit/s for v1), since those keyframes were cheap while half black; Media Foundation's AVC444 predicts from the last frame and should gain instead (not measured; the Windows job's AVC444 record shows it). Picked with the conflict against `.6` resolved as freerdp-71 did (both helpers, `.6`'s first).
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.7`** (`4ee6e9c3c`, freerdp-71's avc444v2-aux-change-detect, 聪哥's go): `20261101.6` plus one fix. The change detection compared AVC444v2's auxiliary (chroma) view at screen columns, but v2 lays that view out by the frame's width. Measured alone on master: AVC444v2 full frame 33.9 → 35.1 dB (+5% bits); AVC420 and v1 byte-identical. With `.5` and `.6`, AVC444v2 with changed regions goes from 12.2 dB at 22.5 Mbit/s to 34.9 dB at 12.1 Mbit/s, the same as a full frame. Picked on integration-all with the conflict against `.6` in h264.c's detect_changes calls resolved as freerdp-71 did (h264.c and yuv.c blob-identical to its measured integration-shadow-win e35bc1171).
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.6`** (`eb2147f27`, freerdp-71's h264-encode-aligned-regions, 聪哥's go): `20261101.5` plus one fix. Clients rebuild AVC444's chroma relative to each region's corner (odd columns and rows, quarter samples), and the shadow server's changed regions started at any pixel. `avc420_compress`/`avc444_compress` now round a region out to the 16-pixel macroblock grid, inside the frame. Measured alone on master (freerdp-71, Linux): AVC420 with changed regions 2.85 → 1.86 Mbit/s at the same quality, AVC444v1 33.5 → 35.0 dB with 19% fewer bits, full frames byte-identical. The Windows job's AVC444 record (`avc444.png`) is the release test.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.5`** (`aa5bb29a8`, freerdp-71's avc444v2-encode-region, 聪哥's go): `20261101.4` plus one fix, the cause of the blocky AVC444 picture, and not the Media Foundation encoder (the reference-frame idea was ruled out on the runner: mf-scratch run 41277334615, 1, 2 and 4 references made the same stream size). The shadow server encodes only the changed rectangle, and for AVC444v2 `RGBToAVC444YUVv2` put the V half at the region's width/2 from the U half, where the layout needs the frame's width/2 (MS-RDPEGFX 3.3.8.3.3): every region narrower than the screen wrote its chroma detail into the wrong columns, and it built up frame after frame, with OpenH264 too. `yuv.c` now converts whole rows for the auxiliary view (what is sent is still decided by change detection, so no extra bits): AVC444v2 with dirty rectangles went from 12.2 dB at 22.5 Mbit/s to 30.7 dB at 12.6 Mbit/s in freerdp-71's harness; full-frame v2, v1 and AVC420 are byte-identical. The release test is the Windows job's AVC444 record: `avc444.png` against `.13`'s. The Windows host keeps `-gfx-avc444` until that is seen; turning AVC444 on there is its own later release.
- **Correction: the Windows host's `-gfx-avc444` gives modern clients RemoteFX, not AVC420** (found by freerdp-bc): FreeRDP's shadow server turns AVC420 on only for clients whose caps carry `RDPGFX_CAPS_FLAG_AVC420_ENABLED`, which RDP 10 caps never do, so Windows' own Remote Desktop client falls back to RemoteFX (correct pictures, more bytes). The Windows host keeps the flag until the AVC444 fixes (FreeRDP 20261101.5-.9) are in, since AVC444 is blocky before them; the README now says so. The test's AVC420 check passed because its client asks for AVC420 alone.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.4`** (`b5a9a3314`, freerdp-bc's FreeRDP#13975, 聪哥's go): `20261101.3` plus a VideoToolbox H.264 encoder. The Mac host had no H.264 encoder (VideoToolbox only decoded, the Mac build has no OpenH264 or FFmpeg), so clients without AV1 got RemoteFX: an idle screen cost about 65 KB/s, now about 1.4 KB/s, and keys arrive within seconds over a ~60 KB/s link where RemoteFX queued them for minutes. Its LaunchAgent keeps the default, AVC444: an RDP 10 client gets no plain AVC420 from FreeRDP's shadow server (`shadow_client.c:1876` reads `RDPGFX_CAPS_FLAG_AVC420_ENABLED`, a flag only RDP 8.1 caps carry), so with `-gfx-avc444` it would get RemoteFX, which starved a ~60 KB/s link (freerdp-bc, 2026-11-01). Forced AVC420 from the client side measured 15-18 times less traffic than AVC444 (median frame about 60 times smaller), which a FreeRDP fix for that flag is to bring to RDP 10 clients. VideoToolbox on the Mac offers H.264 and HEVC encoders in hardware and no AV1 or AV2 one (VTCopyVideoEncoderList), so AV1 and AV2 stay software encodes there. Proven on the Mac by freerdp-bc (TestFreeRDPCodecH264 256 round trips on the hardware encoder; the shadow host with xfreerdp3 3.32.2, a correct picture; and integration-all's b5a9a3314 itself, built on an Apple M5 with macOS 26.7.1: TestFreeRDPCodecH264 passed, 256 encoder sessions on the hardware encoder, the merged test's VideoToolbox branch run); CI only builds and packages it. Cherry-picking it onto integration-all met the Media Foundation encoder's change to TestFreeRDPCodecH264.c: both kept (the MF probe, and VideoToolbox among the builds that can encode).
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.3`** (`87e14738c`, freerdp-7a's AV1 round 2, 聪哥's go: "2 or 3 Mbit/s is OK, even 4"): `20261101.2` plus four commits. The shadow server's AV1 target goes from 500 to 3000 kbit/s (video +1.5 dB against 2 Mbit/s, the same encode time; text and an idle desktop stay under 750 kbit/s at any target). The encoder converts only the damaged rectangle to YUV and is told which rectangle that is (I444 idle -58%, video -18 to -22% encode time, the same PSNR); on Windows the damage comes from DXGI's dirty rectangles. AV1 also joins the full-frame codec list it was missing from. And the X11 shadow backend compared captures including the alpha byte, so every capture looked like a whole new screen (new TestShadowCaptureCompare): the kit builds no X11 shadow, but integration-all carries all of our FreeRDP. freerdp-7a's numbers are from Linux (8 cores); the Windows job's `av1-stats.txt` has the runner's.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.2`** (`9d88f4d2a`, freerdp-71's DXGI fix, 聪哥's go): `20261101.1` plus one commit. A shadow server in the user's own session (not the service) kept a dead desktop duplication when the screen locked, so each capture pass, up to 120 a second, failed again and logged an error for as long as the screen stayed locked. Now it logs one "capture paused", tries again every 250 ms (at once on a desktop change, so the service still follows to Winlogon) and logs "capture resumed". The Windows job runs freerdp-71's `test/lock-resume.ps1` after its main test, as a record (its VERDICT in `lock-resume/after-summary.txt`); no A/B (聪哥: no A/B that day), so the bug on `.1` rests on reading the code.
- **The Windows host leaves AVC444 out** (freerdp-71's finding, kit only): its install command (README, release notes) and the test's service now pass `-gfx-avc444`. The shadow server offers AVC444v2 to every RDP 10 client that doesn't refuse H.264 (`shadow_client.c:1001-1013`), so Windows' own Remote Desktop client got AVC444 from the Media Foundation encoder, and the `.13` round's `avc444.png` is blocky in the deeper levels where `h264.png` (AVC420) is sharp. FreeRDP's AVC444 sends luma and chroma pictures in turn, from one encoder: it needs one that predicts from two pictures back (as GNOME Remote Desktop's x264 does); OpenH264 makes every picture a keyframe there (11.6 Mbit/s against 0.42 for AVC420, freerdp-71's measurement). FreeRDP clients still get AV2 or AV1 first. The test's AVC444 pass stays a record.
- **`freerdp`, `freerdp_host`, `freerdp_mac_host` `20261101.1`** (`d49eb0322`, freerdp-bc's FreeRDP#13971, 聪哥's go): integration-all `20261031.13` plus one WinPR fix. Its Apple key table mapped the right Control key (`kVK_RightControl`) to the right Windows key, so the Mac host dropped it ("no key for scancode 0x011d"); now it is VK_RCONTROL. Verified on the Mac (right Ctrl+A/E typed as expected, 0 dropped keys) and by `TestScancode` (fails without the fix, passes with it). It touches only WinPR's input tables, which every product carries.

## 2026-10-31

- **AV1 encodes in realtime: `freerdp`, `freerdp_host`, `freerdp_mac_host` `20261031.13`** (`1411e7524`, freerdp-7a's av1-encoder-tune, 聪哥's plan): `.12` plus two commits. FreeRDP's av1.c made no `aom_codec_control` calls, so libaom ran at cpu-used 0 (its slowest), on one thread, without its screen-content tools. It now runs at cpu-used 10 with `AOM_CONTENT_SCREEN`, row-mt and up to 4 threads: freerdp-7a's bench on Linux (8 cores) 2.4-2.7x faster at 1080p and 5.5-10.5x at 900p/720p, text +12 dB at fewer bits; a 20 s X11 shadow session at 1600x900 I444 made 642 frames (the 32 fps cap) where master made 240, on less CPU. The shadow server logs the encoder's numbers every 5 s per client; `test/windows-host.ps1` keeps them in `av1-stats.txt`. Only the hosts encode AV1 (libaom); the clients decode with dav1d, unchanged.
- **The H.264 check, fixed** (round 41265999593 failed only there): `freerdp-shadow-cli` allows AV1, AVC420 and AVC444 by default and tries AV1 first, and the test client offers AV1, so the session was AV1 and Media Foundation never encoded. The test's H.264 server now runs with `/gfx-av1:off -gfx-avc444`. An AVC444 session (what Windows' own client asks for) runs as well and is recorded in `notes.txt`, not checked yet. The host README said to add `/gfx-avc420`; it is on by default, and the README now says so.
- **The Windows host encodes H.264 with Media Foundation: `freerdp`, `freerdp_host`, `freerdp_mac_host` `20261031.12`** (`2b9e65a99`, freerdp-71's FreeRDP#13970, 聪哥's go): integration-all `.11` plus the encoder (`libfreerdp/codec/h264_mf.c`, Windows' own H.264 MFT: low latency, Constrained Baseline, no B-frames, one GOP) and its test. The host builds with `-DWITH_MEDIA_FOUNDATION=ON`, so `freerdp-shadow-cli /gfx-avc420` serves clients that only decode H.264 (Windows' own Remote Desktop client among them), with no OpenH264. The installed service keeps `/gfx-av1 /gfx-av2`. The host build also makes a test-only SDL3 client that decodes H.264 through Media Foundation (`h264-test-client-windows-x86_64.exe`, its own artifact, never released): `test/windows-host.ps1` checks AVC420 frames and the server's encoder line with it. The kit's Windows client keeps H.264 off: with it, FreeRDP asks Windows' own Remote Desktop for AVC444 by default. Proven before the pick on Windows Server 2025 (kit branch mf-scratch, run 41262537989: the round trip test passes, output from frame 0, 4.7 ms per 720p frame).
- **One FreeRDP: `freerdp`, `freerdp_host` and `freerdp_mac_host` `20261031.11`** (`be0506d8f`, 聪哥: "integration all"): the fork's new `integration-all` is integration-latest (the clients' `.9`) plus every commit of integration-shadow-win (the Windows host's `.8`) and integration-shadow-mac (the Mac host's `.10`) not in it already, 24 cherry-picks with no conflict, all on master dae0390a4. The three products now build the same commit, so a fix in the shadow server or the clients reaches all of them in one pick. The clients gain only server-side code (the shadow server is not in their builds); the hosts gain the clients' fixes in the shared libraries (the padded-bitmap fix #13946, the decoder-only libavm build, the rdpsnd client's dropped wave).
- **AV2 on by default** (聪哥, 2026-10-31): where both ends have it, sessions use AV2.
  The xrdp packages built with AV2 ship `gfx.toml` with `order = [ "AV2", "AV1", "H.264",
  "RFX" ]`, and the install notes now give the command that puts AV1 first again. The Windows
  host's install command and the Mac host's LaunchAgent add `/gfx-av2` next to `/gfx-av1`.
  Clients that don't offer AV2 still get AV1 (or H.264). The web tests expect AV2 from xrdp
  where its packages have it. The Windows test keeps its own AV1 sessions, and the page's
  presets are unchanged (a freerdp-web change).
  The GNOME and KDE test images now set the same order (AV2 first where their xrdp has it):
  the GNOME image still checked for AV1 first and did not build (kit run 41254428284).
- **`freerdp` `20261031.9`** (`76b4c2e1f`, freerdp-59's, from integration-latest): `.7` plus
  two fixes. The SDL3 clients' connection dialog and clipboard read a freed queue item for
  every message (FreeRDP#13961; master d5d230ddd turned a copy into `auto&` before `pop()`), so
  the page log read "����ection is being established": valgrind on sdl-freerdp 165 errors with
  `.7`, 0 with `.9`. And a sound wave that does not decode is dropped, sound plays on
  (FreeRDP#13957). The web test now fails on a garbled page log.
- **`freerdp` `20261031.7`** (`d7f066be3`, freerdp-59's, from integration-latest): the clients
  move to FreeRDP master dae0390a4, where our Emscripten and SDL pull requests are now merged;
  on top only the AV2 extension (#13925), the physical monitor size (#13805) and xrdp's padded
  bitmaps (#13946). The TLS 1.2 retry (#13944, closed) is gone: the kit's LibreSSL patch fixes
  the cause. Tested before the pick: ctest 211/211, kit round 41199723802, xrdp sway e2e 57/57.
- **`freerdp_host` `20261031.8`** (`be82c8dc0`, freerdp-59's, from integration-shadow-win):
  `.6` plus FreeRDP#13958, the keys a client leaves held are let go when it leaves or sends a
  Synchronize (a client dropped mid-shortcut left Win or Alt down on the console; shown on the
  X11 shadow server, before and after, and on Windows 11: a client pressed Win+Alt and was
  killed without a disconnect; with the old host LWin and Alt stayed down, with `.8` none, as
  Windows' own GetAsyncKeyState reads it). The host README drops its known-issue paragraph.
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
- **The macOS host joins the release** (聪哥: "do not do real build, just as it should works,
  go on"): kit.yml builds it on both architectures (job `mac-host`, as mac-host.yml does on its
  branch), and the release carries `freerdp-host-<version>-macos-arm64.zip` and `-x86_64.zip`
  with a line each in the release notes. It is built and packaged, not tested: a CI Mac cannot
  grant a new app Screen Recording. The site's Get a server doesn't show it yet (a page change).
- **`freerdp_mac_host` `20261031.10`** (`fc2c32540`, freerdp-d0's, from integration-shadow-mac,
  in place of `20261031.4`): the extended keys reach the Mac: both Command keys (so ⌘C and ⌘V),
  the arrows, Home/End, PgUp/PgDn, Forward Delete, keypad Enter and right Option/Ctrl
  (`mac_shadow.c` looked up the Apple key code without KBDEXT; the X11 shadow ORs it in).
  Also rdpsnd's server no longer pads Opus waves (#13952), and `-sec-nla` turns EXT off too
  (#13953). Tested on the Mac: it builds with no warnings, and a client connected and saw the
  screen; the full key run and the sound run are still to do (the Mac's ssh timed out).
- **A new product: the macOS host** (聪哥: "make it possible", freerdp-d0's work).
  `freerdp-host-<version>-macos-<arch>.zip`: FreeRDP's shadow server as FreeRDP-Shadow.app
  (bundle id org.freerdp.shadow; signed ad hoc, so each update asks for Screen & System
  Audio Recording and Accessibility again, as freerdp-d0 measured: an ad hoc signature's
  designated requirement is the build's own hash, a stable one needs a signing identity), a LaunchAgent that starts it in your session at
  login (`/sec:tls`: logins are the Mac's own), and a README. **`freerdp_mac_host`
  `20261031.4`** (`920d496f4`): ScreenCaptureKit capture of every display and of the sound
  the Mac plays, Quartz input, the cursor drawn by the client, capture again after the
  display sleeps; confirmed by 聪哥 on his Mac. `build-macos-client.sh` builds it with
  `HOST=1` (macOS 13 at least, libaom for AV1, libavm for AV2), and
  `.github/workflows/mac-host.yml` builds and packages it on both architectures; CI cannot
  grant a new app Screen Recording, so the capture itself is tested by hand on a Mac.
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
