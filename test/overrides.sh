#!/bin/bash
# the checks are strings that check() evaluates, $out included
# shellcheck disable=SC2016,SC2034
# Tests the local source overrides (build/overrides.sh) without building:
# what they mount, which files they take from a checkout, and that CI and
# a v* tag refuse them.
#
#   test/overrides.sh
set -uo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
check() {
    if eval "$2"; then
        echo "PASS  $1"; pass=$((pass + 1))
    else
        echo "FAIL  $1"; fail=$((fail + 1))
    fi
}

# a kit of its own: sources.local is read next to sources.lock
mkdir -p "$TMP/kit/build" "$TMP/work"
cp "$KIT/sources.lock" "$TMP/kit/"
cp "$KIT/build/overrides.sh" "$TMP/kit/build/"
# a checkout with a tracked file, a new one and an ignored build tree
src=$TMP/FreeRDP
git init -q "$src"
mkdir -p "$src/libfreerdp" "$src/build"
echo 'int a;' > "$src/libfreerdp/a.c"
echo build/ > "$src/.gitignore"
git -C "$src" add -A
git -C "$src" -c user.name=t -c user.email=t@example.com commit -q -m one
echo 'int b;' > "$src/libfreerdp/b.c"
echo junk > "$src/build/CMakeCache.txt"

# run <environment...>: overrides() in a clean shell; its options on stdout
run() {
    env -i PATH="$PATH" HOME="$HOME" KIT="$TMP/kit" "$@" bash -c \
        '. "$KIT/build/overrides.sh"; overrides "$1" && printf "%s\n" "${OVERRIDE[@]}"' \
        _ "$TMP/work"
}

out=$(run 2>&1)
check "no override: no options" '[ -z "$out" ]'

out=$(run SRC_freerdp="$src" 2>&1)
check "SRC_freerdp mounts the checkout read-only" \
    'grep -qx -- "$src:/override/freerdp:ro" <<< "$out"'
check "the MANIFEST label is the folder name and commit, not the path" \
    'grep -qE "^OVERRIDE_freerdp=FreeRDP \([0-9a-f]{12}-dirty\)$" <<< "$out"'
check "the file list has the tracked and the new file" \
    '[ "$(sort "$TMP/work/override/freerdp.list" | tr "\n" " ")" = ".gitignore libfreerdp/a.c libfreerdp/b.c " ]'
check "the file list leaves out the ignored build tree" \
    '! grep -q "^build/" "$TMP/work/override/freerdp.list"'

echo "freerdp dir $src" > "$TMP/kit/sources.local"
out=$(run 2>&1)
check "sources.local works like SRC_<name>" 'grep -qx -- "OVERRIDES=freerdp" <<< "$out"'
out=$(run SRC_freerdp="$TMP" 2>&1)
check "SRC_<name> wins over sources.local" 'grep -qx -- "$TMP:/override/freerdp:ro" <<< "$out"'
echo "freerdp git $src" > "$TMP/kit/sources.local"
check "sources.local: a kind other than dir is refused" '! run > /dev/null 2>&1'
rm "$TMP/kit/sources.local"

# a checkout with a submodule: its files are listed, not the submodule entry
sub=$TMP/sub
git init -q "$sub"
echo 'int s;' > "$sub/s.c"
git -C "$sub" add -A
git -C "$sub" -c user.name=t -c user.email=t@example.com commit -q -m sub
git -C "$src" -c protocol.file.allow=always submodule add -q "$sub" librfxcodec 2> /dev/null
out=$(run SRC_freerdp="$src" 2>&1)
check "a submodule's files are listed, the submodule entry is not" \
    'grep -qx librfxcodec/s.c "$TMP/work/override/freerdp.list" &&
     ! grep -qx librfxcodec "$TMP/work/override/freerdp.list"'

# sync_override (build/lib.sh, in the container): run with /override
# replaced by the checkouts' parent folder
sync() {
    env -i PATH="$PATH" KIT="$TMP/kit" SOURCES="$TMP/sources" WORK="$TMP/work" \
        OVERRIDES=freerdp OVERRIDE_ROOT="$TMP/root" bash -c \
        '. "$1"; sync_override freerdp' _ "$KIT/build/lib.sh"
}
mkdir -p "$TMP/root"
ln -s "$src" "$TMP/root/freerdp"
dst=$TMP/work/src/freerdp
sync
check "sync: the checkout's files arrive, its build tree does not" \
    '[ -f "$dst/libfreerdp/b.c" ] && [ -f "$dst/librfxcodec/s.c" ] && [ ! -e "$dst/build" ]'
touch -d '2000-01-01' "$dst/libfreerdp/a.c"
echo built > "$dst/a.o"
rm "$src/libfreerdp/b.c"
run SRC_freerdp="$src" > /dev/null 2>&1
sync
check "sync: an unchanged file keeps its time stamp" \
    '[ "$(stat -c %Y "$dst/libfreerdp/a.c")" = "$(date -d 2000-01-01 +%s)" ]'
check "sync: a file deleted in the checkout goes" '[ ! -e "$dst/libfreerdp/b.c" ]'
check "sync: a file the build made in the tree stays" '[ -f "$dst/a.o" ]'
echo 'int a2;' > "$src/libfreerdp/a.c"
sync
check "sync: a changed file is copied" 'grep -q a2 "$dst/libfreerdp/a.c"'

# the guards: an override must never reach CI or a release
check "CI=true refuses an override" '! run CI=true SRC_freerdp="$src" > /dev/null 2>&1'
check "a v* tag refuses an override" \
    '! run GITHUB_REF=refs/tags/v2026.10.0 SRC_freerdp="$src" > /dev/null 2>&1'
check "CI=true without an override still builds" 'run CI=true > /dev/null 2>&1'
check "a missing directory is refused (docker -v would create it)" \
    '! run SRC_freerdp="$TMP/nowhere" > /dev/null 2>&1 && [ ! -e "$TMP/nowhere" ]'
check "a name not in sources.lock is refused" '! run SRC_freerpd="$src" > /dev/null 2>&1'

# LTO=off, checked by build.sh itself before any container runs (ENGINE=true
# makes the container steps no-ops)
lto() {
    env -i PATH="$PATH" HOME="$HOME" ENGINE=true WORK="$TMP/work" CCACHE=off "$@" \
        "$KIT/build.sh" "$TMP/out" > /dev/null 2>&1
}
check "build.sh: LTO=off with a local FreeRDP is accepted" 'lto LTO=off SRC_freerdp="$src"'
check "build.sh: LTO=off without a local FreeRDP is refused" '! lto LTO=off'
check "build.sh: LTO=off with only another local source (sdl3) is refused" \
    '! lto LTO=off SRC_sdl3="$src"'
check "build.sh: LTO=on is refused (off is the only setting)" '! lto LTO=on SRC_freerdp="$src"'
check "build.sh: CI=true refuses an override" '! lto CI=true SRC_freerdp="$src"'

check "build-windows.sh: LTO=off without a local FreeRDP is refused" \
    '! env -i PATH="$PATH" HOME="$HOME" ENGINE=true KIT_CACHE="$TMP/cache" LTO=off \
         "$KIT/build-windows.sh" x86_64 > /dev/null 2>&1'

# builder images (build/builder.sh) against a fake engine that keeps the
# labels of the one image it "builds" in a file
cat > "$TMP/engine" << 'EOF2'
#!/bin/bash
# one file of labels per image name
dir=$(dirname "$0")
case "$1 $2" in
    "image inspect")
        name=${*: -1}
        db=$dir/image-${name//[:\/]/-}
        [ -f "$db" ] || exit 1
        case "$*" in *.Id*) echo "sha256:$name" ;; *) cat "$db" ;; esac ;;
    "build "*)
        while [ "$1" != -t ]; do shift; done
        db=$dir/image-${2//[:\/]/-}
        ctx=${*: -1}
        echo "$(sed -n 's/^ENV KIT_TOOLS=//p' "$ctx/Dockerfile") \
$(sed -n 's/.*rdp-release-kit.made=//p' "$ctx/Dockerfile")" > "$db"
        echo "build $2" >> "$dir/images.log" ;;
    "rmi "*) echo "rmi $2" >> "$dir/images.log" ;;
esac
EOF2
chmod +x "$TMP/engine"
mkdir -p "$TMP/kit/deps"
cp "$KIT/build/tools.sh" "$TMP/kit/build/"
cp "$KIT/build/builder.sh" "$TMP/kit/build/"
cp "$KIT"/deps/*.txt "$TMP/kit/deps/"
image() {
    env -i PATH="$PATH" KIT="$TMP/kit" ENGINE="$TMP/engine" "$@" bash -c \
        '. "$KIT/build/builder.sh"; builder debian:13 xrdp'
}
out=$(image BUILDER=off)
check "builder: BUILDER=off runs the stock image" '[ "$out" = debian:13 ]'
out=$(image 2> /dev/null)
check "builder: the image is named after its kind and stock image" \
    '[ "$out" = rdp-release-kit-xrdp:debian-13 ] && [ "$(grep -c build "$TMP/images.log")" = 1 ]'
image > /dev/null 2>&1
check "builder: a second build reuses the image" '[ "$(grep -c build "$TMP/images.log")" = 1 ]'
image NO_AV1=1 > /dev/null 2>&1
image > /dev/null 2>&1
check "builder: NO_AV1 makes another image, and keeps the first" \
    '[ "$(grep -c build "$TMP/images.log")" = 2 ] &&
     grep -qx "build rdp-release-kit-xrdp-noav1:debian-13" "$TMP/images.log"'
echo "extra-package  for the test" >> "$TMP/kit/deps/deb.txt"
image > /dev/null 2>&1
check "builder: a changed dependency list makes it again, and removes the old one" \
    '[ "$(grep -c build "$TMP/images.log")" = 3 ] && grep -qx "rmi sha256:rdp-release-kit-xrdp:debian-13" "$TMP/images.log"'
sed -i "s/ [0-9]*\$/ $(($(date +%s) - 8 * 86400))/" "$TMP/image-rdp-release-kit-xrdp-debian-13"
image > /dev/null 2>&1
check "builder: an image older than BUILDER_DAYS is made again" \
    '[ "$(grep -c build "$TMP/images.log")" = 4 ]'

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
