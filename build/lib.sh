# shellcheck shell=bash
# Shared helpers for the build scripts, sourced inside the build container.
# Expects KIT, SOURCES and WORK to be set.
#
# sources.lock lines: name version url sha256
#   url git+<repo url>  the source is that git commit, and the last column
#                       is the commit id instead of a SHA-256
# A tarball whose name is listed in signed.lock must also carry a valid
# signature (<url>.asc) by the key fingerprint given there, checked against
# the keys in keys/.

# a failure inside $(...) must stop the build too (a failed signature
# check in fetch, for one)
shopt -s inherit_errexit

declare -A VERSION URL SHA SIGNER
while read -r name version url sha; do
    VERSION[$name]=$version
    URL[$name]=$url
    SHA[$name]=$sha
done < <(grep -v -E '^\s*(#|$)' "$KIT/sources.lock")
if [ -f "$KIT/signed.lock" ]; then
    while read -r name fpr; do
        SIGNER[$name]=$fpr
    done < <(grep -v -E '^\s*(#|$)' "$KIT/signed.lock")
fi

# used by the scripts that source this file
# shellcheck disable=SC2034
JOBS=$(nproc)
DEPS=$WORK/deps
mkdir -p "$WORK/log" "$WORK/stamp" "$SOURCES"

# ccache, when the container has it and the host script mounted a cache
# (CCACHE_DIR): CMake gets it as the launcher of both compilers (C++ too,
# FreeRDP's own WITH_CCACHE covers C only), Meson finds it by itself. The
# paths under /work are the same on every run, so a fresh build tree
# still hits. base_dir stays empty, whatever a ccache.conf says: it makes
# the source paths relative but not FreeRDP's -fmacro-prefix-map, so
# __FILE__ and the binary change; without it a build from the cache is
# byte for byte the build without it.
# SDL builds with a precompiled header, which ccache takes only with
# pch_defines,time_macros. The statistics count this build only.
LAUNCHER=()
if [ -n "${CCACHE_DIR:-}" ] && command -v ccache > /dev/null; then
    export CCACHE_BASEDIR='' CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-5G}
    export CCACHE_SLOPPINESS=pch_defines,time_macros
    LAUNCHER=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
    ccache --zero-stats > /dev/null
fi

# ccache_stats: this build's hits, misses and uncached calls, if ccache ran
ccache_stats() {
    [ -n "${CCACHE_DIR:-}" ] && command -v ccache > /dev/null || return 0
    echo "== ccache: $(ccache --print-stats | awk -F'\t' '
        $1 == "direct_cache_hit" || $1 == "preprocessed_cache_hit" { hit += $2 }
        $1 == "cache_miss" { miss = $2 }
        $1 ~ /^(could_not_use_precompiled_header|called_for_link|called_for_preprocessing)$/ { unc += $2 }
        END { printf "%d hits, %d misses, %d not cacheable", hit, miss, unc }')"
}

# fetch <name>: the verified source archive in $SOURCES, path on stdout.
# Every step is checked explicitly: fetch runs as "$(fetch) || return 1",
# and bash ignores set -e inside a function called that way.
fetch() {
    local name=$1 url=${URL[$1]} file tmp try
    if [[ $url == git+* ]]; then
        file=$SOURCES/$name-${SHA[$name]}.tar
        if [ ! -f "$file" ]; then
            tmp=$(mktemp -d) || return 1
            git -C "$tmp" init -q || return 1
            # git has no retry option; servers answer 5xx now and then
            for try in 1 2 3 4 5; do
                git -C "$tmp" fetch -q --depth 1 "${url#git+}" "${SHA[$name]}" && break
                [ $try = 5 ] && { echo "$name: git fetch failed" >&2; return 1; }
                sleep $((try * 10))
            done
            if [ "$(git -C "$tmp" rev-parse FETCH_HEAD)" != "${SHA[$name]}" ]; then
                echo "$name: fetched commit is not ${SHA[$name]}" >&2
                return 1
            fi
            git -C "$tmp" archive --prefix="$name/" -o "$file.part" FETCH_HEAD || return 1
            mv "$file.part" "$file" || return 1
            rm -rf "$tmp"
        fi
    else
        file=$SOURCES/$(basename "$url")
        if [ ! -f "$file" ]; then
            curl -fsSL --retry 5 --retry-all-errors -o "$file.part" "$url" || return 1
            mv "$file.part" "$file" || return 1
        fi
        if ! echo "${SHA[$name]}  $file" | sha256sum -c --quiet - >&2; then
            echo "$name: $(basename "$file") does not match its SHA-256 in sources.lock" >&2
            return 1
        fi
        if [ -n "${SIGNER[$name]:-}" ]; then
            verify_signature "$name" "$file" || return 1
        fi
    fi
    echo "$file"
}

# verify_signature <name> <file>: <file>.asc is a good signature by SIGNER
verify_signature() {
    local name=$1 file=$2 home status
    [ -f "$file.asc" ] || curl -fsSL --retry 5 --retry-all-errors -o "$file.asc" "${URL[$name]}.asc"
    home=$(mktemp -d)
    gpg --homedir "$home" --batch --quiet --import "$KIT"/keys/*.asc 2> /dev/null
    status=$(gpg --homedir "$home" --batch --status-fd 1 --verify "$file.asc" "$file" 2> /dev/null)
    rm -rf "$home"
    if ! grep -q "^\[GNUPG:\] VALIDSIG ${SIGNER[$name]} " <<< "$status"; then
        echo "$name: no valid signature by ${SIGNER[$name]} on $(basename "$file")" >&2
        return 1
    fi
}

# unpack <name>: a fresh copy of the source in $WORK/src/<name>, path on
# stdout; an overridden source is synced from its local directory instead
unpack() {
    local name=$1 file
    if overridden "$name"; then
        sync_override "$name" || return 1
        echo "$WORK/src/$name"
        return 0
    fi
    file=$(fetch "$name") || return 1
    rm -rf "${WORK:?}/src/$name"
    mkdir -p "$WORK/src/$name"
    tar -xf "$file" --strip-components=1 -C "$WORK/src/$name" || return 1
    echo "$WORK/src/$name"
}

# overridden <name>: the host script mounted a local directory for <name>
# (build/overrides.sh)
overridden() {
    [[ " ${OVERRIDES:-} " == *" $1 "* ]]
}

# sync_override <name>: $WORK/src/<name> becomes the files listed in
# $WORK/override/<name>.list, copied by content: a file whose content did
# not change keeps its time stamp and Ninja leaves it alone. Copying the
# time stamps instead (rsync -t, cp -p) would break that: going back to an
# older commit gives a changed file an older time, and it looks built.
sync_override() {
    local name=$1 dst=$WORK/src/$1 list=$WORK/override/$1.list
    # last unpacked from sources.lock: start over
    if [ ! -f "$dst/.override" ]; then
        rm -rf "${dst:?}"
        mkdir -p "$dst"
        touch "$dst/.override"
    fi
    # a tracked file deleted in the checkout is still listed: skip it
    rsync -rlp --checksum --ignore-missing-args --files-from="$list" "/override/$name/" "$dst/" \
        || return 1
    # files no longer in the checkout
    comm -23 <(cd "$dst" && find . \( -type f -o -type l \) ! -name .override | sed 's|^\./||' | sort) \
        <(sort "$list") | (cd "$dst" && xargs -r -d '\n' rm -f --)
}

# override_manifest: one line per overridden source, for the MANIFEST
override_manifest() {
    local name var
    for name in ${OVERRIDES:-}; do
        var=OVERRIDE_$name
        echo "OVERRIDE $name: local directory ${!var} (not from sources.lock)"
    done
}

# toolchain_id: what compiles the dependencies, the first line of its
# --version (emcc, else $CC or cc); a script whose compiler sits behind a
# CMake toolchain file sets TOOLCHAIN_ID itself
toolchain_id() {
    if [ -n "${TOOLCHAIN_ID:-}" ]; then
        echo "$TOOLCHAIN_ID"
    elif command -v emcc > /dev/null; then
        emcc --version | head -1
    else
        "${CC:-cc}" --version 2> /dev/null | head -1
    fi
}

# built <name>: true if <name> is already in $DEPS from the same source and
# the same compiler; a dependency is rebuilt when either changes (remove
# the work tree to force it)
built() {
    if overridden "$1"; then
        echo "== $1 (local)"
        return 1
    fi
    if [ "$(cat "$WORK/stamp/$1" 2> /dev/null)" = "${SHA[$1]} $(toolchain_id)" ]; then
        echo "== $1 ${VERSION[$1]} (built)"
        return 0
    fi
    echo "== $1 ${VERSION[$1]}"
    return 1
}

# stamp <name>: <name> is in $DEPS; a local build is stamped as such, so
# the next build from sources.lock rebuilds it
stamp() {
    if overridden "$1"; then
        echo "local" > "$WORK/stamp/$1"
    else
        echo "${SHA[$1]} $(toolchain_id)" > "$WORK/stamp/$1"
    fi
}

# configure <build dir> <command...>: runs a CMake configure command, but
# not again for a build tree already configured by the same command (a
# local source keeps its tree; Ninja itself reruns CMake when a CMake file
# of the project changes). Under Emscripten a configure takes 17 s.
configure() {
    local dir=$1 sum
    shift
    sum=$(printf '%s\n' "$@" | sha256sum | cut -d' ' -f1)
    if [ -f "$dir/build.ninja" ] && [ "$(cat "$dir/.configured" 2> /dev/null)" = "$sum" ]; then
        echo "== configuration kept (same options)"
        return 0
    fi
    rm -f "$dir/.configured"
    "$@" || return 1
    echo "$sum" > "$dir/.configured"
}

# cmake_dep <name> [cmake options]: a CMake project, static, into $DEPS
cmake_dep() {
    local name=$1 src
    shift
    built "$name" && return 0
    src=$(unpack "$name")
    # a local source keeps its build tree: Ninja rebuilds what changed
    overridden "$name" || rm -rf "${WORK:?}/build/$name"
    cmake -G Ninja -S "$src" -B "$WORK/build/$name" -DCMAKE_BUILD_TYPE=Release "${LAUNCHER[@]}" \
        -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_PREFIX_PATH="$DEPS" -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON "$@" > "$WORK/log/$name.log" 2>&1
    cmake --build "$WORK/build/$name" >> "$WORK/log/$name.log" 2>&1
    cmake --install "$WORK/build/$name" >> "$WORK/log/$name.log" 2>&1
    stamp "$name"
}

# licenses <dir> <name...>: copies each source's licence files to <dir>/<name>
licenses() {
    local dir=$1 name
    shift
    for name in "$@"; do
        mkdir -p "$dir/$name"
        find "$WORK/src/$name" -maxdepth 2 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \
            -o -iname 'LICENCE*' -o -iname 'FTL.TXT' -o -iname 'GPLv2.TXT' \) \
            -exec cp {} "$dir/$name/" \;
    done
}

# shown once on a failure (the trap also runs in subshells): the end of
# the newest log, which belongs to the step that failed
on_error() {
    local log
    if [ "$BASH_SUBSHELL" = 0 ]; then
        log=$(find "$WORK/log" -name '*.log' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
        echo "failed, the end of $log:" >&2
        tail -30 "$log" >&2
    fi
}
trap on_error ERR
