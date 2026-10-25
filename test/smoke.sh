#!/bin/bash
# Runs a client archive in clean containers of the distributions it claims
# to support: it must start, report its version and build options, and
# find every library it needs; its connection window's Python and Tk must
# load.
#
#   test/smoke.sh <sdl3-freerdp-*.tar.xz> [image ...]
set -uo pipefail

ARCHIVE=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
shift
IMAGES=("$@")
if [ ${#IMAGES[@]} = 0 ]; then
    IMAGES=(almalinux:9 rockylinux/rockylinux:10 debian:12 debian:13 ubuntu:22.04
            ubuntu:24.04 fedora:43 opensuse/tumbleweed)
    # Arch Linux publishes x86_64 images only
    if [ "$(uname -m)" = x86_64 ]; then
        IMAGES+=(archlinux:latest)
    fi
fi
# docker first: the builds are tested with it (podman: see README)
ENGINE=${ENGINE:-$(command -v docker || command -v podman)}
NAME=$(basename "$ARCHIVE" .tar.xz)

# The one host library the client needs, as each family names it
INSIDE=$(mktemp)
cat > "$INSIDE" << 'EOF'
set -e
if command -v apt-get > /dev/null; then
    apt-get update -qq && apt-get install -y -qq libpulse0 xz-utils > /dev/null
elif command -v dnf > /dev/null; then
    dnf -y -q install pulseaudio-libs xz > /dev/null
elif command -v zypper > /dev/null; then
    zypper -q -n install libpulse0 xz > /dev/null
elif command -v pacman > /dev/null; then
    pacman -Sy --noconfirm --needed libpulse xz > /dev/null
fi
tar -xJf /archive -C /tmp
bin=$(ls /tmp/*/bin/sdl-freerdp)
if ldd "$bin" | grep -q "not found"; then
    ldd "$bin" | grep "not found"
    exit 1
fi
"$bin" /version | head -1
"$bin" /buildconfig | tr ' ' '\n' | grep -c '^WITH_' | sed 's/$/ build options/'
# the connection window's Python, with Tk, and freerdp-tk (build/launcher.sh)
pkg=$(dirname "$(dirname "$bin")")
PYTHONPATH=$pkg/freerdp-tk "$pkg/python/bin/python3" -s -c \
    'import _tkinter, tkinter, freerdp_tk.app; print("launcher: Tk", _tkinter.TK_VERSION)'
EOF

fail=0
for image in "${IMAGES[@]}"; do
    "$ENGINE" pull -q "$image" > /dev/null 2>&1 || true
    if out=$("$ENGINE" run --rm -v "$ARCHIVE":/archive:ro -v "$INSIDE":/smoke.sh:ro \
             "$image" bash /smoke.sh 2>&1); then
        printf 'ok    %-26s %s\n' "$image" "$(tail -2 <<< "$out" | tr '\n' ' ')"
    else
        printf 'FAIL  %-26s %s\n' "$image" "$(tail -3 <<< "$out" | tr '\n' ' ')"
        fail=1
    fi
done
rm -f "$INSIDE"
echo "$NAME: $([ $fail = 0 ] && echo all passed || echo failures)"
exit $fail
