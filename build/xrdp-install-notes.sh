#!/bin/bash
# The "Install xrdp" section of the rolling release's notes, in Markdown:
# one row per release in distros.list, with the sessions its packages have
# (its marks), and a command that downloads and installs them on x86_64
# and ARM64 alike:
#
#   build/xrdp-install-notes.sh <dir> <download URL>
#
# <dir> holds the release's assets (the xrdp, xorgxrdp and, for Fedora,
# pipewire-module-xrdp packages, named as uploaded: '~' and '+' are '.'),
# <download URL> is where they are, e.g.
# https://github.com/<owner>/<repo>/releases/download/<tag>. Each image is
# asked for its name (ID-VERSION_ID, or the codename of Debian testing), as
# build-xrdp-pkg.sh names its packages; ENGINE runs it (docker, podman).
set -euo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
DIR=$1 URL=$2
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}

# one asset, by glob, for the x86_64 build: its name, or nothing
asset() { (cd "$DIR" && find . -maxdepth 1 -name "$1" -printf '%f\n' | head -1); }

cat << 'EOF'
## Install xrdp

The packages hold our release of xrdp (its development branch with Wayland
sessions, AV1 and pacing) and xorgxrdp's development branch, for Xorg and
Wayland sessions. They replace xrdp 0.10.6.1 and the kit's earlier preview
packages (their version sorts higher). Pick the session on xrdp's login
screen; Xorg is the default.

| Release | Sessions | Download and install (x86_64 and ARM64) |
|---|---|---|
EOF
grep -v -E '^\s*(#|$)' "$KIT/distros.list" | while read -r image rest; do
    # shellcheck disable=SC2016 # expanded by the container shell
    distro=$("$ENGINE" run --rm "$image" sh -c '. /etc/os-release; echo "$ID-${VERSION_ID:-$VERSION_CODENAME}"')
    sessions="Xorg, GNOME"
    [[ " $rest " == *" no-kde "* ]] || sessions+=", KDE"
    [[ " $rest " == *" no-sway "* ]] || sessions+=", sway"
    case $distro in
    fedora-*)
        fc=fc${distro#fedora-}
        name="Fedora ${distro#fedora-}"
        cmd="sudo dnf install"
        for p in xrdp xorgxrdp pipewire-module-xrdp; do
            f=$(asset "$p-[0-9]*.$fc.x86_64.rpm")
            [ -n "$f" ] || { echo "xrdp-install-notes.sh: no $p for $distro in $DIR" >&2; exit 1; }
            cmd+=" $URL/${f%.x86_64.rpm}.\$(uname -m).rpm"
        done ;;
    *)
        case $distro in
        debian-[0-9]*) name="Debian ${distro#debian-}" ;;
        debian-*) name="Debian testing (${distro#debian-})" ;;
        ubuntu-*) name="Ubuntu ${distro#ubuntu-}" ;;
        *) name=$distro ;;
        esac
        cmd="cd /tmp"
        for p in xrdp xorgxrdp; do
            f=$(asset "${p}_[0-9]*.${distro}_amd64.deb")
            [ -n "$f" ] || { echo "xrdp-install-notes.sh: no $p for $distro in $DIR" >&2; exit 1; }
            cmd+=" && curl -fLO $URL/${f%_amd64.deb}_\$(dpkg --print-architecture).deb"
        done
        # Debian and Ubuntu package PipeWire's xrdp module themselves
        cmd+=" && sudo apt install ./xrdp_*.deb ./xorgxrdp_*.deb pipewire-module-xrdp" ;;
    esac
    printf '| %s | %s | `%s` |\n' "$name" "$sessions" "$cmd"
done
cat << 'EOF'

Then start it: `sudo systemctl enable --now xrdp`. Whether a package has the
Wayland sessions: `rpm -ql xrdp | grep libwlup` (Fedora) or
`dpkg -L xrdp | grep libwlup` (Debian, Ubuntu) names `libwlup.so`; the login
screen lists them as `[GNOME]`, `[KDE]` and `[Wayland]` (sway) in
`/etc/xrdp/xrdp.ini`. KDE needs KWin's rendering: from KWin 6.8 in software
with `/dev/udmabuf` (the user in its group, often `kvm`), before that a DRM
render node (a GPU, or the `vgem` module).
EOF
