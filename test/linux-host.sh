#!/bin/bash
# The Linux host (build.sh HOST=1) on a desktop, in a throwaway container, with
# the kit's own Linux client:
#
#   test/linux-host.sh gnome|xorg <host archive> <client archive> [out dir]
#
# gnome: GNOME Shell 50 headless on Wayland, systemd as PID 1 (podman
#   --systemd=always). The server runs as the package's systemd user unit,
#   installed as its README says: Mutter is the default subsystem, /subsystem
#   lists Mutter first, a PAM login of the session's owner gets AV1 frames once
#   the screen changes (an idle GNOME sends no full frame for a while), the
#   server's idle CPU with one client stays under 20 %, typed keys arrive through
#   libei, AV2 frames, another account is refused, and stopping the sharing in
#   GNOME (org.gnome.Shell.Eval, --unsafe-mode) ends the unit with 0, not
#   restarted. The server's lines are read as its user would, from the unit's
#   journal (journalctl --user -u freerdp-shadow: WinPR's journald appender).
# xorg: Xfce on Xvfb, the unit's arguments with /subsystem:x11: /subsystem picks
#   X11 there, a login gets AV1 frames, another account is refused.
#
# The archives default to the newest in dist/. Logs and screenshots go to
# dist/test/linux-host-<mode>/. PODMAN=<command> runs another podman (CI: a
# rootful one), RUN_OPTS=<options> adds options to the container.
set -uo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
MODE=${1:-}
case $MODE in gnome | xorg) ;; *) echo "usage: $0 gnome|xorg <host archive> <client archive> [out dir]" >&2; exit 2 ;; esac
ARCH=$(uname -m)
HOST_ARCHIVE=${2:-$(find "$KIT/dist" -maxdepth 1 -name "freerdp-host-*-linux-$ARCH*.tar.xz" | sort -V | tail -1)}
CLIENT_ARCHIVE=${3:-$(find "$KIT/dist" -maxdepth 1 -name "sdl3-freerdp-*-linux-$ARCH*.tar.xz" | sort -V | tail -1)}
OUT=${4:-$KIT/dist/test/linux-host-$MODE}
for f in "$HOST_ARCHIVE" "$CLIENT_ARCHIVE"; do
    [ -f "$f" ] || { echo "no archive: '$f'" >&2; exit 2; }
done
HOST_ARCHIVE=$(realpath "$HOST_ARCHIVE")
CLIENT_ARCHIVE=$(realpath "$CLIENT_ARCHIVE")
rm -rf "$OUT"
mkdir -p "$OUT"
OUT=$(realpath "$OUT")
PODMAN=${PODMAN:-podman}
read -r -a RUN_OPTS <<< "${RUN_OPTS:-}"
IMAGE=kit-linux-host-test
NAME=kit-linux-host-$MODE-$$

"$KIT/build/cpu-line.sh"   # which AV2 kernels the host's libavm runs here
echo "== test bed (test/linux-host/Dockerfile)"
$PODMAN build -q -t "$IMAGE" "$KIT/test/linux-host" > "$OUT/image-build.log" 2>&1 ||
    { tail -20 "$OUT/image-build.log"; exit 1; }
MOUNTS=(-v "$HOST_ARCHIVE":/host.tar.xz:ro -v "$CLIENT_ARCHIVE":/client.tar.xz:ro -v "$OUT":/out
        -v "$KIT/test/linux-host":/t:ro)
echo "== $MODE: $(basename "$HOST_ARCHIVE"), client $(basename "$CLIENT_ARCHIVE")"
if [ "$MODE" = gnome ]; then
    $PODMAN run -d --name "$NAME" --hostname linux-host-test --systemd=always "${RUN_OPTS[@]}" \
        "${MOUNTS[@]}" "$IMAGE" > /dev/null || exit 1
    $PODMAN exec "$NAME" bash /t/inside.sh gnome
    status=$?
    $PODMAN rm -f "$NAME" > /dev/null 2>&1
else
    $PODMAN run --rm --name "$NAME" --hostname linux-host-test "${RUN_OPTS[@]}" "${MOUNTS[@]}" \
        "$IMAGE" bash /t/inside.sh xorg
    status=$?
fi
echo "(logs and screenshots in $OUT)"
exit $status
