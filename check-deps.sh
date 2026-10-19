#!/bin/bash
# Shows, release by release, whether everything the xrdp packages need is
# there. Run it before adding a release to distros.list, or when a build
# or an install fails:
#
#   ./check-deps.sh [image ...]      default: every image in distros.list
#   ./check-deps.sh --preview [image ...]   the xrdp preview: deps/*-preview.txt
#                                    too, default: every image in distros-preview.list
#
# For each release, two plain lists:
#   build   each package of deps/<deb|rpm>.txt, and the version the release has
#   run     each dependency of the built packages (dist/xrdp/<release>/),
#           and the version a fresh install of the release would use
# A line starts with "ok" or "MISSING" ("masked" for what a release's
# marks in distros-preview.list leave out); the last line of each release
# says whether all is well. A release that is MISSING libaom: mark it
# no-av1 in distros-preview.list.
set -uo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
# docker first: the builds are tested with it (podman: see README)
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
LIST=distros.list SUFFIX=
if [ "${1:-}" = --preview ]; then
    shift
    LIST=distros-preview.list SUFFIX=-preview
fi
IMAGES=("$@")
if [ ${#IMAGES[@]} = 0 ]; then
    mapfile -t IMAGES < <(grep -v -E '^\s*(#|$)' "$KIT/$LIST" | awk '{print $1}')
fi

# Runs inside the release's container: /kit is the kit, /pkgs the packages
INSIDE=$(mktemp)
cat > "$INSIDE" << 'EOF'
. /etc/os-release
missing=0
# report <name> <version or empty>
report() {
    if [ -n "$2" ]; then
        printf '  ok       %-28s %s\n' "$1" "$2"
    else
        printf '  MISSING  %s\n' "$1"
        missing=$((missing + 1))
    fi
}
if command -v apt-get > /dev/null; then
    apt-get update -qq > /dev/null 2>&1
    version() { apt-cache policy "$1" 2> /dev/null | awk '/Candidate:/ { if ($2 != "(none)") print $2 }'; }
    # a virtual package (xorg-video-abi-25) resolves to the one providing it
    provider() {
        local v
        v=$(version "$1")
        if [ -n "$v" ]; then echo "$v"; return; fi
        apt-cache showpkg "$1" 2> /dev/null |
            awk '/^Reverse Provides:/ { f = 1; next } f && NF { print "via " $1 " " $2; exit }'
    }
    run_deps() { dpkg-deb -f "$1" Depends | tr ',' '\n' | sed 's/^ *//; s/ (.*//; s/ |.*//'; }
    kit_provides() { for p in "$@"; do dpkg-deb -f "$p" Package; done; }
    family=deb
else
    version() { dnf -q repoquery --latest-limit 1 --qf '%{version}-%{release}\n' "$1" 2> /dev/null | head -1; }
    provider() { dnf -q repoquery --latest-limit 1 --whatprovides "$1" --qf '%{name}-%{version}\n' 2> /dev/null | head -1; }
    run_deps() { rpm -qpR "$1" 2> /dev/null | grep -v -E '^(rpmlib|/)' | sed 's/ .*//'; }
    kit_provides() { rpm -qp --provides "$@" 2> /dev/null | sed 's/ .*//'; }
    family=rpm
fi

lists=$family.txt
[ -n "$PREVIEW" ] && lists="$lists $family-preview.txt"
echo "build ($lists)"
for pkg in $(cd /kit/deps && grep -h -v -E '^\s*(#|$)' $lists | awk '{print $1}'); do
    case "$NO_AV1:$pkg" in
        1:libaom-*) printf '  masked   %-28s %s\n' "$pkg" "(no-av1)"; continue ;;
    esac
    report "$pkg" "$(version "$pkg")"
done

pkgs=$(ls /pkgs/*.deb /pkgs/*.rpm 2> /dev/null)
if [ -z "$pkgs" ]; then
    echo "run      (no packages built for this release yet)"
else
    # what the kit's packages provide themselves (their own libraries,
    # each other) needs nothing from the release
    own=$(kit_provides $pkgs | sort -u)
    for p in $pkgs; do
        echo "run      ($(basename "$p"))"
        for dep in $(run_deps "$p" | sort -u); do
            if grep -qxF "$dep" <<< "$own"; then
                printf '  ok       %-28s %s\n' "$dep" "(from these packages)"
            else
                report "$dep" "$(provider "$dep")"
            fi
        done
    done
fi
if [ $missing = 0 ]; then
    echo "=> $PRETTY_NAME: everything is there"
else
    echo "=> $PRETTY_NAME: $missing MISSING"
fi
exit $((missing > 0))
EOF

status=0
for image in "${IMAGES[@]}"; do
    # shellcheck disable=SC2016 # expanded by the container shell
    distro=$("$ENGINE" run --rm "$image" sh -c '. /etc/os-release; echo "$ID-${VERSION_ID:-$VERSION_CODENAME}"')
    mkdir -p "$KIT/dist/xrdp$SUFFIX/$distro"
    NO_AV1=
    [ -n "$SUFFIX" ] && awk -v i="$image" \
        '$1 == i { for (k = 2; k <= NF; k++) if ($k == "no-av1") f = 1 } END { exit !f }' \
        "$KIT/$LIST" && NO_AV1=1
    echo "### $image ($distro)${NO_AV1:+ no-av1}"
    "$ENGINE" run --rm -e PREVIEW="$SUFFIX" -e NO_AV1="$NO_AV1" \
        -v "$KIT":/kit:ro -v "$KIT/dist/xrdp$SUFFIX/$distro":/pkgs:ro \
        -v "$INSIDE":/check.sh:ro "$image" bash /check.sh || status=1
    echo
done
rm -f "$INSIDE"
exit $status
