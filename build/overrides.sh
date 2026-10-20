# shellcheck shell=bash
# Local source overrides for the development loop, sourced by the host
# build scripts. Three layers, the later one wins:
#
#   sources.lock       committed; the only input of CI and of releases
#   sources.local      this machine, never committed: "<name> dir <path>"
#   SRC_<name>=<path>  one run, e.g. SRC_freerdp=$HOME/src/FreeRDP ./build.sh
#
# An overridden source is the directory as it is, edits included: no
# commit, no push. Its files are copied into the work tree by content, so
# an unchanged file keeps its time stamp and Ninja recompiles only what
# changed; its build tree is kept. The result is marked: an OVERRIDE line
# in the MANIFEST and "-local" in the archive name. CI and v* tags refuse
# any override.

# git_files <checkout>: the files git knows there, tracked or new, and
# those of its submodules (git lists a submodule as one entry, its folder)
git_files() {
    local links
    links=$(git -C "$1" ls-files --stage | awk '$1 == 160000 { print $4 }')
    git -C "$1" -c core.quotepath=off ls-files --cached --others --exclude-standard |
        grep -v -x -F -e "$links" || true
    # shellcheck disable=SC2016
    git -C "$1" submodule --quiet foreach --recursive \
        'git -c core.quotepath=off ls-files --cached --others --exclude-standard |
             sed "s|^|$displaypath/|"'
}

# overrides <work dir>: sets OVERRIDE to the container options (mounts and
# environment) for every overridden source and OVERRIDDEN to their names
# (" a b "), and writes each one's file list to
# <work dir>/override/<name>.list; exits on misuse
overrides() {
    local work=$1 name kind path desc
    local -A dir=()
    OVERRIDE=()
    # used by the scripts that source this file
    # shellcheck disable=SC2034
    OVERRIDDEN=" "
    if [ -f "$KIT/sources.local" ]; then
        while read -r name kind path; do
            if [ "$kind" != dir ] || [ -z "$path" ]; then
                echo "sources.local: \"$name $kind $path\": expected <name> dir <path>" >&2
                exit 1
            fi
            dir[$name]=${path/#\~/$HOME}
        done < <(grep -v -E '^\s*(#|$)' "$KIT/sources.local")
    fi
    while IFS='=' read -r name path; do
        dir[${name#SRC_}]=$path
    done < <(env | grep -E '^SRC_[a-z0-9_]+=')
    [ ${#dir[@]} = 0 ] && return 0

    if [ -n "${CI:-}" ] || [[ ${GITHUB_REF:-} == refs/tags/v* ]]; then
        echo "source overrides are for local builds only, not for CI or a release:" \
            "${!dir[*]}" >&2
        exit 1
    fi
    rm -rf "${work:?}/override"
    mkdir -p "$work/override"
    for name in "${!dir[@]}"; do
        path=${dir[$name]}
        if ! grep -q -E "^$name\s" "$KIT/sources.lock"; then
            echo "override $name: no source of that name in sources.lock" >&2
            exit 1
        fi
        # docker -v creates a missing directory (empty, owned by root)
        if [ ! -d "$path" ]; then
            echo "override $name: $path is not a directory" >&2
            exit 1
        fi
        path=$(cd "$path" && pwd)
        # a git checkout: the files git knows, tracked or new (build trees
        # and other ignored files stay out); otherwise every file
        # dirty: changed or new files (describe --dirty misses new ones)
        if desc=$(git -C "$path" rev-parse --short=12 HEAD 2> /dev/null); then
            [ -z "$(git -C "$path" status --porcelain)" ] || desc+=-dirty
            git_files "$path" > "$work/override/$name.list"
        else
            desc="not a git checkout"
            (cd "$path" && find . \( -type f -o -type l \) ! -path './.git/*' | sed 's|^\./||') \
                > "$work/override/$name.list"
        fi
        echo "== $name: local $path ($desc)" >&2
        OVERRIDE+=(-v "$path:/override/$name:ro" -e "OVERRIDE_$name=$(basename "$path") ($desc)")
    done
    OVERRIDE+=(-e "OVERRIDES=${!dir[*]}")
    # shellcheck disable=SC2034
    OVERRIDDEN=" ${!dir[*]} "
}
