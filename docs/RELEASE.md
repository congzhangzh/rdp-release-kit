# Release process

How the kit turns pinned upstream sources into tested, published builds,
and what other projects may rely on. The kit is the one place that builds:
consumers (for example the freerdp-web site) download its releases and
verify them; they never compile.

## Products and channels

| Product | Source | Channel | Release name |
|---|---|---|---|
| `sdl-freerdp`, Linux x86_64 / aarch64 | FreeRDP release tag | stable | `v<YYYY>.<MM>.<N>` |
| `sdl-freerdp.exe`, Windows x86_64 / ARM64 | FreeRDP release tag | stable | `v<YYYY>.<MM>.<N>` |
| xrdp + xorgxrdp, `.deb` / `.rpm` for every release in `distros.list` | xrdp, xorgxrdp signed release tags | stable | `v<YYYY>.<MM>.<N>` |
| Web client (WebAssembly) + the freerdp-web page | FreeRDP master + open pull requests, frozen on a fork branch; the page by a freerdp-web release (`vYYYYMMDD.N`, earlier `vX.Y.Z`) | preview | `web-<YYYYMMDD>.<N>-<kit commit, 12>` on every push to main that changes a build; also inside `v*` |
| xrdp preview packages: Wayland sessions, AV1, pacing | a frozen xrdp development commit + xorgxrdp devel | preview | `xrdp-preview-<YYYYMMDD>.<N>-<kit commit, 12>` |
| Demo videos (planned) | recorded by `test/wasm-session.sh` | with the web client | `web-<YYYYMMDD>.<N>-<kit commit, 12>` |

**Stable** means: upstream release tags only, hashes (and signatures where
upstream signs) checked, no patches. **Preview** means: a fixed commit of
a public branch that is never rewritten, labelled preview everywhere it
appears, never mixed into a stable package's name or version.

A stable release is named by date, `v2026.10.0`, because it bundles
several upstream versions; each archive's `MANIFEST` and the release notes
list them. Packages keep the upstream version with a `0kit<N>` suffix, N
the number of kit commits. Every pre-release and release is published
once and never replaced ([Frozen releases](#frozen-releases)).

## Inputs

- [`sources.lock`](../sources.lock): `name version url sha256`, or
  `name short-commit git+url full-commit` for a git source. Every build
  reads its sources from here and nowhere else.
- freerdp-web is pinned only by its GitHub point releases, as a whole:
  the version column is the release (`0.4.12`), the commit is the one its
  tag `v0.4.12` points to (`build/check-release-pins.sh`, in CI), and
  `check-upstream.sh` watches its tags like any upstream. Its GitHub
  Pages are freerdp-web's own: it publishes them over the kit's newest
  tested client whenever it likes, and never waits for the kit.
- [`signed.lock`](../signed.lock) and [`keys/`](../keys): the release key
  each signed tarball must verify against.
- [`distros.list`](../distros.list): the distribution releases to package
  for (testing, stable and old stable of Debian, Ubuntu and Fedora).
- Container images are pinned by digest where the toolchain matters
  (Emscripten).

A change to an input is one commit, whose message names what moved and
why (`xrdp 0.10.6.1 → 0.10.7`). A preview pin's version column is a preview
number (`20261018.1`), raised with every new pin: package versions are
ordered by it, never by a commit hash or date. A preview source moves only to a new frozen
commit; the old one stays reachable, so every old build can be rebuilt.
That includes our own repositories the kit pins (freerdp-web, the fork
branches): never rewrite their history. A rewrite orphans every pin of
them; freerdp-web's of October 2026 left the kit's older pins and its
`web-*` pre-releases before `web-ea48a1f73d0b` pointing at commits no
branch holds.

## Gates

Nothing is uploaded unless every gate of its product passes in CI.

| Product | Gate | Script |
|---|---|---|
| Linux client | only glibc, libgcc_s, libpulse needed; glibc ≤ 2.34; no exported symbols | `build/check-portable.sh` |
| | starts on every supported distribution | `test/smoke.sh` |
| Windows client | only Windows' own DLLs and the UCRT | `build/check-windows.sh` |
| xrdp packages | every build and run-time dependency available on the release | `check-deps.sh` |
| | install in a fresh container, log in over RDP with the kit's client, an Xorg session and its xterm run | `test/xrdp-session.sh` |
| xrdp preview | the same, then a Wayland login: sway starts for the user, wlup captures it at the client's size | `test/xrdp-session.sh --preview` |
| Web client | page served without COOP/COEP, gateway over SSH, browser login starts a session | `test/wasm-session.sh` |
| Published page | the same login from the live site | freerdp-web's `check` job |
| Every push | no private details in the history | `privacy-scan` (pre-push hook) |

Sources failing their SHA-256 or signature stop the build; each guard has
a negative test (a wrong hash, a wrong key, a tampered tarball).

## Flow

```
upstream tag / frozen branch
  → bump commit in sources.lock (a pull request: build + all gates)
  → main: CI again; the web client goes to pre-release web-<YYYYMMDD>.<N>-<kit>
  → tag v<YYYY>.<MM>.<N> on a green main commit
  → release: every artifact, SHA256SUMS, build provenance attestations
  → consumers download and verify (freerdp-web publishes on purpose)
```

- **Watching upstream**: [`check-upstream.sh`](../check-upstream.sh)
  compares each `sources.lock` entry with the newest upstream release of
  the series the kit follows (`git ls-remote`, no token); the daily
  `upstream` workflow opens one issue per update found. A person decides;
  nothing bumps itself, and nothing waits longer than two weeks (see
  [Keeping pins fresh](#keeping-pins-fresh)).
- **The web client**: two projects, each at its own speed. freerdp-web
  makes point releases (`v20261021.1`; before that `v0.4.12`) and publishes its Pages itself: its
  page over the kit's newest tested client (its `kit-release.sh` finds
  it), at any time. The kit pins a freerdp-web release when one comes out
  (the upstream check opens the issue), tests the client with it, and
  makes `web-<YYYYMMDD>.<N>-<kit commit>`; a kit `v*` release carries the
  client and that freerdp-web release as one whole.
- **Pages**: only freerdp-web has them; the kit publishes none (its old
  address kept the redirect GitHub last deployed).
- **Releases are never automatic**: a push builds and tests; publishing
  needs a tag or a manual run.

## Frozen releases

**A published name always means the same files.** Once a release or
pre-release is published, nothing replaces, adds or deletes its assets,
and its tag never moves. A different build gets a different name; the old
one stays, so anything that downloaded it, pinned it or recorded its
checksum keeps being right.

### Why

The pre-releases have been overwritten: each one is named by its source
commit only, and every push to main rebuilds it and uploads with
`--clobber`.

- `web-2cf615b88ecc` was published by the kit's 0ea7f94 at 14:58 on
  2026-10-19. The next push, a2afe67, changed only xrdp's packaging, yet
  it rebuilt the web client and replaced all five assets at 15:12. The
  `KIT_COMMIT` asset names a2afe67 now.
- `xrdp-preview-53af799d2548` was published at 11:12 the same day. Its
  packages were replaced at 15:11, and they kept their version
  (`…-0kit1`).

Whoever downloaded before 15:12 holds a `KIT_COMMIT` that names 0ea7f94,
under the same name. Whether the client and the packages changed as well
can no longer be checked, because their old checksums were overwritten
with them. That loss is the harm in itself.

The consumers make it worse:
- freerdp-web's `site.sh` keeps one downloaded client per tag and checks
  it against the checksum saved with it. A machine that fetched the tag
  early keeps the old client while CI fetches the new one.
- apt takes two packages with one version for the same package, so it
  never installs the second. A repository that served both would give
  its users a hash mismatch.

### What other projects do

| Project | Rule |
|---|---|
| Python | A release's files are never replaced. PyPI refuses a file name that has ever been used, even after it is deleted. A fix is a new version (3.13.0 → 3.13.1). |
| Chromium | Every build has its own number (major.minor.build.patch), never reused. The channels (stable, beta, dev, canary) are pointers that move from one number to the next. |
| Debian | The archive never takes a different file under a version it already has. A rebuild without a source change is a new version (`+b1`), and snapshot.debian.org keeps every one. |

The kit takes the same three ideas: one name per build, pointers that
move while builds don't, and versions that only go up.

### Rules

1. **Each pre-release records every input.** Its title names the source
   commit and the kit commit; its name, the date, the build number and
   the kit commit. The kit commit fixes everything else
   through `sources.lock`: FreeRDP, Emscripten, every dependency, the
   build scripts.

   The name records how a build was made, not every byte: the
   distributions' packages in the build images are not pinned (only
   Emscripten's image is pinned, by digest), so the same kit commit built
   a month later can differ. That is why a name is built and published
   once, and never again.

   | Product | Name |
   |---|---|
   | Web client | `web-<YYYYMMDD>.<N>-<kit commit, 12>`, titled "Web client for freerdp-web <page commit, 12> (kit <kit commit, 12>)" |
   | xrdp preview | `xrdp-preview-<YYYYMMDD>.<N>-<kit commit, 12>`, titled "xrdp preview <xrdp commit, 12> (kit <kit commit, 12>)" |
   | Stable | `v<YYYY>.<MM>.<N>`, a tag on one kit commit (already the case) |

   Pre-releases are made continuously, so they are named by date (since
   21 October 2026): the UTC date of the build and N, that day's build
   number of that kind (`build/prerelease-tag.sh`). The name sorts and
   says how new a build is; the title names its inputs, and a second run
   of one kit commit finds its title and keeps the name, so it publishes
   nothing new. N counts drafts and tags without a release too, so a name
   is never used twice. Two kit commits published at the same moment can
   get the same N; their kit commits still keep the names apart. Names
   from before keep them.

   A push that cannot change a build (documentation only) should not
   make a new one; see [Speed](#speed).
2. **Publish once, complete.** A publish step:
   - stops if the tag already exists;
   - otherwise creates a draft, uploads every asset with `SHA256SUMS`,
     then publishes it.

   No `--clobber`, and no `gh release edit` of assets. A draft can be
   deleted and made again, because nobody can download one. Two runs of
   one commit (a push and a manual run) must not publish at once: the
   publish jobs share a `concurrency` group per tag.
3. **Pointers move; releases don't.** "The newest tested web client" is a
   query: the newest published `web-*`, as `site.sh` reads it now. "The
   client for page P" is the newest web pre-release titled for P. A moving git tag such
   as `web-latest` is not used, because a moving tag is exactly what rule
   2 forbids.
4. **A version is one set of bytes.** A package keeps the upstream
   version plus `0kit<N>`. N goes up whenever the kit's build of the same
   upstream source changes, like Debian's `+b1`. N is the number of kit
   commits (`git rev-list --count HEAD`, in `build-xrdp.sh`), so it goes
   up by itself; CI fetches the whole history for it, and a shallow clone
   is refused. A tree without git (`git archive`) builds `0kit0`, below
   every published one.
5. **Withdraw, don't delete.** A bad release stays, with release notes
   that start `WITHDRAWN: <why>; use <tag>`. Queries for the newest
   release skip withdrawn ones.
   - A release is deleted only when it exposes something private
     (see `privacy-scan`).
   - Its name is never used again.
6. **GitHub enforces it.** GitHub's immutable releases (repository
   settings) lock a published release's assets and its tag. Release notes
   can still change, so rule 5 still works. GitHub recommends the same
   order as rule 2: a draft first, then publish. It applies only to
   releases published after it is turned on.
   - Its documentation does not say whether it covers pre-releases. Try
     it once on a throwaway repository before relying on it.

### How it is done

| Where | What |
|---|---|
| [`build/publish-prerelease.sh`](../build/publish-prerelease.sh) | rules 1 and 2 for both pre-releases: a published tag is left as it is; a tag without a release is refused; a draft an earlier run left is deleted; a new draft gets every file, is published, and must then list exactly those files. Only an HTTP 404 counts as "not there": any other error stops it. Tested with a fake `gh` ([`test/publish.sh`](../test/publish.sh)) |
| kit `wasm` job, "Hand the tested page to freerdp-web" | `web-<YYYYMMDD>.<N>-<kit, 12>` (`build/prerelease-tag.sh`): the client, `KIT_COMMIT`, the debian-13 xrdp packages, `SHA256SUMS` of them all |
| kit `xrdp-preview-release` job | `xrdp-preview-<YYYYMMDD>.<N>-<kit, 12>` |
| both jobs | a `concurrency` group per kit commit: two runs of one commit publish one after the other, and the second finds the release there |
| kit `release` job (`v*`) | unchanged: it creates the release with every file in one call, and a second run fails because the release exists |
| kit pushes | a push that changes only documentation (or only the upstream check) runs no build, so it makes no new pre-release |
| package revisions | `0kit<N>`, rule 4 |
| freerdp-web [`kit-release.sh`](https://github.com/congzhangzh/freerdp-web/blob/main/kit-release.sh) | rule 3: the newest published `web-*`, or the newest build of a page commit; withdrawn ones and drafts skipped; the older names `web-<page, 12>-<kit, 12>` and `web-<page, 12>` are still found. `site.sh` and `pages.yml` use it |

The order of the pushes: freerdp-web first (it finds both names), then the
kit, then immutable releases turned on (rule 6, after a trial).

The three pre-releases made before this (`web-ea48a1f73d0b`,
`web-2cf615b88ecc`, `xrdp-preview-53af799d2548`) keep their names, since
their links are in use, and their notes say they were made before the
freeze and may have been replaced.

## Keeping pins fresh

A pin that falls behind upstream costs more the longer it waits: the jump
grows, and so do the fixes it misses. Each update gets a decision within
two weeks.

- **Every day**, the `upstream` workflow:
  - opens one issue per new upstream release
    (`Update available: <name> <pinned> → <newest>`);
  - closes the issues whose pin has moved since.
- **After 14 days**, an update must be bumped (a pull request that changes
  `sources.lock`) or deferred. To defer, give the issue the `deferred`
  label and say why in it, for example "opus 1.6 changes the API, after
  the FreeRDP 3.33 bump". The label is made once, with
  `gh label create deferred`. Until one of those happens, the workflow
  fails every day, and GitHub notifies whoever last changed the
  workflow's schedule.
- **Closing an issue by hand** means "not this version". It is not opened
  again, but the next upstream release opens a new one.
- **A security fix** does not wait for the two weeks: bump it the same
  day, outside the cycle.
- **Kept updates:**
  - The clock starts when the issue opens and stops only when the pin
    moves. A newer upstream release opens another issue, while the older
    one keeps counting.
  - A deferred issue stays open, and its label can come off at any time.
- **Not covered:**
  - Preview sources and our own repositories, which move when a new commit
    is frozen.
  - Builder images, which pick up distribution updates every 7 days on
    their own (`build/builder.sh`).
- **Quiet repositories:** GitHub turns off scheduled workflows in a public
  repository after 60 days without activity. The check then stops
  silently, and has to be turned on again in the Actions tab.

## Consuming a release

```sh
gh release download v2026.10.0 -R congzhangzh/rdp-release-kit -p SHA256SUMS -p '*.deb'
sha256sum -c --ignore-missing SHA256SUMS
gh attestation verify <file> -R congzhangzh/rdp-release-kit
```

`test/fetch-release.sh <tag>` (planned) does the same for the tests, so
they and the demo recordings can run on released builds as easily as on
local ones.

## Speed

A run took about 19 minutes while the web client's 8 minute build waited
for the xrdp packages, which only its login test needs. Now the build
(`wasm-build`) starts at once and only the test (`wasm`) waits. A push
that changes only documentation runs no build at all.

Every build keeps compiled objects between runs (ccache, in the CI cache
for pushes to main; a pull request's own cache is never restored on
main) and starts from a builder image with its tools installed
(`build/builder.sh`: made once per build and distribution, again after
7 days or when `build/tools.sh` or `deps/` change). A release builds
without ccache. A build from the cache is byte for byte the build
without it, checked for each kind:

| Build | Checked | How it stays identical |
|---|---|---|
| Linux client | `sdl-freerdp` | ccache's `base_dir` stays empty (it would change `__FILE__`) |
| web client | `sdl-freerdp.wasm` | as above |
| Windows client | `sdl-freerdp.exe`, but for its link time | lld writes the link time into every PE file (twice: COFF header, debug directory), with ccache or without |
| xrdp packages | every staged file (debian:13) | ccache through its gcc wrapper in `PATH`, not `CC="ccache gcc"`: xrdp records its configure options and `CC` in its binaries |

Local work on a source goes through `SRC_<name>` or `sources.local`
(see the README), which CI and `v*` tags refuse: the build tree is kept,
so an edit to one file rebuilds the Linux client in about 6 s with
`LTO=off` (21 s before), the Windows client in 5 s (ThinLTO, cached), the
xrdp preview in 7 s and the web client in about 46 s (55 s), where
Binaryen's post-link passes (22 s) remain.
