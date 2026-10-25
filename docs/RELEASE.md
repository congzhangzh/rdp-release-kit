# Release process

How the kit turns pinned upstream sources into tested, published builds,
and what other projects may rely on. The kit is the one place that builds:
consumers (for example the freerdp-web site) download its releases and
verify them; they never compile.

## Products and channels

| Product | Source | Channel | Release name |
|---|---|---|---|
| `sdl-freerdp`, Linux x86_64 / aarch64, with freerdp-tk and its Python | our FreeRDP preview, the web client's (FreeRDP master + open pull requests, frozen on a fork branch); freerdp-tk by its release; python-build-standalone release | preview | `<YYYYMMDD>.<N>` |
| `sdl-freerdp.exe`, Windows x86_64 / ARM64, with freerdp-tk and its Python | the same | preview | `<YYYYMMDD>.<N>` |
| xrdp + xorgxrdp, `.deb` / `.rpm` for every release in `distros.list`, x86_64 and ARM64 | xrdp, xorgxrdp signed release tags | stable | `<YYYYMMDD>.<N>` |
| Web client (WebAssembly) + the freerdp-web page | FreeRDP master + open pull requests, frozen on a fork branch; the page by a freerdp-web release (`YYYYMMDD.N`, earlier `vYYYYMMDD.N`, `vX.Y.Z`) | preview | `web-<YYYYMMDD>.<N>-<kit commit, 12>` on every push to main that changes a build; also inside every release |
| xrdp preview packages: Wayland sessions, AV1, pacing | a frozen xrdp development commit + xorgxrdp devel | preview | `xrdp-preview-<YYYYMMDD>.<N>-<kit commit, 12>` |
| Demo videos: Xfce, GNOME, and GNOME and KDE through the xrdp preview | recorded by `test/record-demos.sh` with that build's web client and xrdp preview (the `demo` workflow, called by the kit's run; every release carries the videos and waits for them) | preview | `demo-<YYYYMMDD>.<N>-<kit commit, 12>`; freerdp-web's splash takes the newest |

**Stable** means: upstream release tags only, hashes (and signatures where
upstream signs) checked, no patches. **Preview** means: a fixed commit of
a public branch that is never rewritten, labelled preview everywhere it
appears, never mixed into a stable package's name or version.

The kit is rolling: every push to main that changes a build and passes
every gate publishes a release, named by its UTC date and that day's
number, `20261025.1` (no `v`: the date is the version), made GitHub's
latest, so `releases/latest` always leads to a tested download. It bundles
several upstream versions; each archive's `MANIFEST` and the release notes
list them. Packages keep the upstream version with a `0kit<N>` suffix, N
the number of kit commits. Every pre-release and release is published
once and never replaced ([Frozen releases](#frozen-releases)).

## Inputs

- [`sources.lock`](../sources.lock): `name version url sha256`, or
  `name short-commit git+url full-commit` for a git source. Every build
  reads its sources from here and nowhere else.
- freerdp-web is pinned only by its GitHub point releases, as a whole:
  the version column is the release (`20261025.1`), the commit is the one its
  tag `20261025.1` points to (`build/check-release-pins.sh`, in CI), and
  `check-upstream.sh` watches its tags like any upstream. Its GitHub
  Pages are freerdp-web's own: a tag publishes nothing; freerdp-web publishes
  a tag by hand once the kit has built and tested that page (client "exact"),
  after a login from the very files going live (its `login` job).
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
  → bump commit in sources.lock, pushed to main (the kit takes no pull requests)
  → main: CI again; the previews go to their pre-releases (web-…, xrdp-preview-…)
  → all green: the release <YYYYMMDD>.<N>, made latest: every product,
    SHA256SUMS, build provenance attestations
  → consumers download and verify (freerdp-web publishes on purpose)
```

- **Watching upstream**: [`check-upstream.sh`](../check-upstream.sh)
  compares each `sources.lock` entry with the newest upstream release of
  the series the kit follows (`git ls-remote`, no token); the daily
  `upstream` workflow opens one issue per update found. A person decides;
  nothing bumps itself, and nothing waits longer than two weeks (see
  [Keeping pins fresh](#keeping-pins-fresh)).
- **The web client**: two projects, each at its own speed. freerdp-web
  makes releases (tags `20261025.1`, no prefix; earlier `v20261021.1`, `v0.4.12`). The kit pins
  a release when one comes out (the upstream check opens the issue), tests the client with it,
  and makes `web-<YYYYMMDD>.<N>-<kit commit>`; the kit's release carries the client and that
  freerdp-web release as one whole. freerdp-web then publishes its Pages from the tag, by hand,
  with that very client (`kit-release.sh` finds it), after its own login from the files going
  live. So the site only gets a page and a client the kit tested together, and a kit change
  may break the page: the kit's test fails, nothing reaches the site, and the page is fixed
  and released after (2026-10-25: the live site never breaks; the kit may).
- **Pages**: only freerdp-web has them; the kit publishes none (its old
  address kept the redirect GitHub last deployed).

### Our own releases of an upstream: picked from the fork

Since 2026-10-25 every client (Linux, Windows, macOS, web) builds FreeRDP
from our release, not from an upstream one: the kit ships what we chose, on
our schedule. The branches on our fork have one role each:

```
pull-request branches ─┐  one topic each, on upstream master (the PR targets it)
feature branches ──────┤
                       ▼
integration-latest        rebuilt at will: its base + every open part
                       │  ripe = it passed the kit's tests
                       ▼  pick
release-<YYYYMMDD>.<N>    frozen, on the fork; never committed to, moved or deleted
                       │
                       ▼  pin
sources.lock: freerdp <YYYYMMDD>.<N> <commit>
```

1. **Rebuild the integration** on its base. The base is a choice: upstream
   master (the newest fixes, our merged pull requests) or an upstream
   release tag (steadier ground), whichever the release needs. Parts that
   upstream merged drop out.
2. **Test it here**, from that very tree, before it is picked:
   `SRC_freerdp=<the integration checkout> ./build.sh` (and
   `./build-windows.sh`, `./build-wasm.sh`), then `test/xrdp-session.sh`
   (the stable xrdp and `--preview`) and `test/wasm-session.sh` (once more
   with `WASM_ENGINE=jspi`).
3. **Pick the release**: a branch `release-<YYYYMMDD>.<N>` on that commit,
   pushed to the fork (the integration first, by force-with-lease). `<N>`
   counts that day's picks from 1.
4. **Pin it**: the `freerdp` line names `<YYYYMMDD>.<N>` and the commit;
   `pins.notes` says what it carries and lists the open pull requests,
   which `check-upstream.sh` then watches. CI tests it again on every
   platform.

A fix never goes into a picked release: it goes to its pull-request
branch, the integration is rebuilt, and a new release is picked. Like a
Fedora compose, and unlike a Debian or Ubuntu release, a picked release is
never patched, so every pin stays reproducible. Picks from before this
rule keep their names (`wasm-preview-<YYYYMMDD>.<N>-<commit>`).

### A freerdp-web release, end to end

The kit and the page need each other, so they release in a fixed order.
The site only ever gets a page and a client that the kit tested together:

| Step | Where | What |
|---|---|---|
| 1 | freerdp-web | the page change on main; the site is untouched |
| 2 | freerdp-web | the release: the version in the manifest, CHANGELOG, release notes, the tag `<YYYYMMDD>.<N>`, a GitHub Release. A tag publishes nothing |
| 3 | the kit | pin it (`freerdp_web`), with any kit change it needs; push |
| 4 | the kit | CI builds the client with that page, logs in, and publishes `web-<YYYYMMDD>.<N>-<kit commit>`, titled with the page commit |
| 5 | freerdp-web | `gh workflow run pages.yml --ref <tag> -f publish=true`: the kit's client of that very page ("exact"), a login from exactly the files going live (Asyncify and JSPI), then the deploy, then a login from the live site |

A kit change may break the page: then step 4 fails, nothing new reaches
the site, and the page is fixed and released after it.
- **Releases are automatic, and frozen**: every push to main that changes
  a build and passes publishes one; a pull request only builds and tests.
- **A page-only push builds the web client alone**: when a push only moves
  the `freerdp_web` pin (`build/changes.sh`: comments, docs and the pins
  tables aside), only `wasm-build` and `wasm` run. The login test takes its
  xrdp packages from the newest `web-*` pre-release, and the push publishes
  that one pre-release, with no rolling release and no demos (nothing they
  hold changed). Anything else, a pull request and a run by hand build
  everything.
  What reaches people is still gated: the release holds only what every
  test passed, and freerdp-web's site changes only when it publishes.

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
   | Stable | `<YYYYMMDD>.<N>`, titled "FreeRDP <version> clients, xrdp <version> packages (kit <kit commit, 12>)"; made latest |

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
| kit `release` job | `<YYYYMMDD>.<N>` (`build/prerelease-tag.sh release`), published by `publish-prerelease.sh` with `LATEST=1`: the same rules, but a release, made latest |
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
- **After 14 days**, an update must be bumped (a commit on main that changes
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

### Recording a change

- **`CHANGELOG.md`**: every commit that changes what is built (a pin, a
  build option, a patch, a toolchain) adds its entry in the same commit:
  what changed, why, and how it was tested.
- **`pins.notes`**: every pin that is not a plain upstream release (a fork
  commit carrying our fix, a development commit) has a `change` line with
  its base, what it changes or fixes, how that was tested, and the pull
  requests and issues that carry it upstream (`owner/repo#N`). A pin that
  carries our fix moves back to an upstream release once upstream has it:
  `check-upstream.sh` reports the state of each of them, and the daily
  `upstream` job opens an issue `Upstream has our changes: <name>` when all
  of a pin's are merged or fixed.
- `build/pins-table.sh` joins `pins.notes` with `sources.lock`. CI fails
  when a pin has no product, a commit pin has no `change` line, or the
  README's tables are stale (`build/pins-table.sh --readme README.md`
  rewrites them). `build/release-notes.sh` puts the same tables, and a
  link to the changelog at the release's commit, in every release's notes.

## Consuming a release

```sh
gh release download -R congzhangzh/rdp-release-kit -p SHA256SUMS -p '*.deb'   # the latest; or name one: 20261025.1
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
(see the README), which CI refuses: the build tree is kept,
so an edit to one file rebuilds the Linux client in about 6 s with
`LTO=off` (21 s before), the Windows client in 5 s (ThinLTO, cached), the
xrdp preview in 7 s and the web client in about 46 s (55 s), where
Binaryen's post-link passes (22 s) remain.
