# shellcheck shell=bash
# The connection window shipped with a client: freerdp-tk (sources.lock
# freerdp_tk), the standalone CPython with Tk that runs it
# (python_<os>_<arch>), and a start script, so the archive is ready to use
# on a machine with no Python or no Tk. Sourced by the client build scripts
# after lib.sh:
#
#   add_launcher <package dir> <os> <arch>      os: linux, windows, macos
#
# The start script puts the package's own sdl-freerdp first on PATH, where
# freerdp-tk looks for its clients, and runs freerdp-tk with the package's
# Python (-s: no user site-packages, so nothing installed for another
# Python leaks in). Adds the MANIFEST lines in LAUNCHER_MANIFEST.

add_launcher() {
    local pkg=$1 os=$2 arch=$3 py=python_$2_$3 src tk label
    case $os in linux) label=Linux ;; windows) label=Windows ;; macos) label=macOS ;; esac
    src=$(unpack "$py")
    tk=$(unpack freerdp_tk)
    cp -a "$src" "$pkg/python"
    # what a launcher never runs: the test suite (a third of the size),
    # IDLE, the turtle demos, pip and its bootstrap, the headers and man
    # pages for building extensions (lib/python3.N/ and bin/ on Linux and
    # macOS, Lib/ and Scripts/ on Windows); Tcl and Tk stay, freerdp-tk is Tk
    rm -rf "$pkg"/python/lib/python3.*/{test,idlelib,turtledemo,ensurepip,config-*} \
        "$pkg"/python/lib/python3.*/site-packages/pip* "$pkg"/python/bin/{pip,idle,pydoc}* \
        "$pkg"/python/Lib/{test,idlelib,turtledemo,ensurepip} "$pkg"/python/Lib/site-packages/pip* \
        "$pkg"/python/Scripts "$pkg"/python/include "$pkg"/python/share
    # lib/, not next to the start script: on Linux and macOS that is named freerdp-tk too
    mkdir -p "$pkg/lib/freerdp-tk" "$pkg/licenses/$py" "$pkg/licenses/freerdp_tk"
    cp -a "$tk/src/freerdp_tk" "$pkg/lib/freerdp-tk/"
    find "$pkg/lib/freerdp-tk" -name __pycache__ -prune -exec rm -rf {} +
    cp "$tk/LICENSE" "$pkg/licenses/freerdp_tk/"
    find "$src" -maxdepth 3 -name LICENSE.txt -exec cp {} "$pkg/licenses/$py/" \;

    if [ "$os" = windows ]; then
        printf '%s\r\n' \
            '@echo off' \
            'rem Opens freerdp-tk, the connection window, with this folder'"'"'s FreeRDP' \
            'rem client and Python.' \
            'set "PATH=%~dp0;%PATH%"' \
            'set "PYTHONPATH=%~dp0lib\freerdp-tk"' \
            'start "" "%~dp0python\pythonw.exe" -s -m freerdp_tk %*' > "$pkg/freerdp-tk.cmd"
        printf '%s\r\n' \
            "FreeRDP ${VERSION[freerdp]} for $label $arch, from rdp-release-kit" \
            '' \
            'Double-click freerdp-tk.cmd: a window to save and open connections.' \
            'Or run the client yourself:  sdl-freerdp.exe /v:server /u:user' \
            '' \
            'Everything it needs is in this folder (Python with Tk included).' \
            'MANIFEST lists what it was built from; licenses\ has every licence.' > "$pkg/README.txt"
    else
        cat > "$pkg/freerdp-tk" << 'EOF'
#!/bin/sh
# Opens freerdp-tk, the connection window, with this folder's FreeRDP client
# and Python.
here=$(cd "$(dirname "$0")" && pwd)
PATH=$here/bin:$PATH PYTHONPATH=$here/lib/freerdp-tk exec "$here/python/bin/python3" -s -m freerdp_tk "$@"
EOF
        chmod +x "$pkg/freerdp-tk"
        cat > "$pkg/README.txt" << EOF
FreeRDP ${VERSION[freerdp]} for $label $arch, from rdp-release-kit

Run ./freerdp-tk: a window to save and open connections.
Or run the client yourself:  bin/sdl-freerdp /v:server /u:user

Everything it needs is in this folder (Python with Tk included).
MANIFEST lists what it was built from; licenses/ has every licence.
EOF
    fi
    # read by the scripts that source this file
    # shellcheck disable=SC2034
    LAUNCHER_MANIFEST=$(printf '  %-9s %-8s %s\n' freerdp_tk "${VERSION[freerdp_tk]}" "${SHA[freerdp_tk]}"
        printf '  %-9s %-8s %s\n' python "${VERSION[$py]}" "${SHA[$py]}")
}

# check_launcher <package dir>: the bundled Python runs here (Linux, macOS)
# and has what freerdp-tk needs: Tk, and freerdp-tk itself importable
check_launcher() {
    local pkg=$1
    PYTHONPATH=$pkg/lib/freerdp-tk "$pkg/python/bin/python3" -s -c \
        'import _tkinter, tkinter, freerdp_tk.app; print("launcher: Python", __import__("sys").version.split()[0], "with Tk", _tkinter.TK_VERSION)'
}
