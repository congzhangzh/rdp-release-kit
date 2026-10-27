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
    add_tk_deps "$pkg" "$os" "$arch" "$tk" "$src" || return 1

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
        if [ "$os" = macos ]; then
            # Finder opens a .command file in Terminal on a double-click (the $ are
            # the script's own, written as they are)
            # shellcheck disable=SC2016
            printf '#!/bin/sh\nexec "$(dirname "$0")/freerdp-tk" "$@"\n' > "$pkg/freerdp-tk.command"
            chmod +x "$pkg/freerdp-tk.command"
            cat >> "$pkg/README.txt" << 'EOF'

In Finder, double-click freerdp-tk.command. The programs are not notarized:
if the folder came through a browser, macOS quarantines it and refuses to
start them. Clear that once, in Terminal:
    xattr -dr com.apple.quarantine <this folder>
EOF
        fi
    fi
    # read by the scripts that source this file
    # shellcheck disable=SC2034
    LAUNCHER_MANIFEST=$(printf '  %-9s %-8s %s\n' freerdp_tk "${VERSION[freerdp_tk]}" "${SHA[freerdp_tk]}"
        printf '  %-9s %-8s %s\n' python "${VERSION[$py]}" "${SHA[$py]}"
        [ -z "$TK_DEPS" ] || printf '  freerdp_tk needs (its uv.lock): %s\n' "$TK_DEPS")
}

# add_tk_deps <package dir> <os> <arch> <freerdp-tk source> <its Python source>:
# what freerdp-tk needs besides Python (since 0.3.0 keyring, to keep
# passwords in the system's own store: Credential Manager, Keychain, Secret
# Service or KWallet), for that OS, into lib/freerdp-tk/ next to it. The
# versions and SHA-256 of every wheel come from freerdp-tk's own uv.lock at
# the pinned tag; its markers are evaluated for the target (Windows needs
# pywin32-ctypes, Linux SecretStorage with jeepney and cryptography, macOS
# keyring alone), and pip refuses any file whose hash the lock does not
# list. Linux and macOS install with the bundled Python itself (native);
# Windows, built on Linux, with the Linux one for this machine, for the
# Windows platform: its packages are all pure Python. Sets TK_DEPS
# ("name version, ..."); a freerdp-tk without uv.lock (0.1.x) needs nothing.
add_tk_deps() {
    local pkg=$1 os=$2 arch=$3 tk=$4 src=$5 python req plat=()
    TK_DEPS=
    [ -f "$tk/uv.lock" ] || return 0
    if [ "$os" = windows ]; then
        python=$(unpack "python_linux_$(uname -m)")/bin/python3 || return 1
        case $arch in x86_64) plat=(--platform win_amd64) ;; aarch64) plat=(--platform win_arm64) ;; esac
        plat+=(--python-version 3.13 --implementation cp)
    else
        python=$src/bin/python3
    fi
    req=$(mktemp) || return 1
    "$python" -s - "$tk/uv.lock" "$os" "$arch" "${VERSION[python_${os}_$arch]%%+*}" > "$req" << 'PY' || return 1
import sys, tomllib
from pip._vendor.packaging.markers import Marker
lock, os_, arch, pyver = sys.argv[1:5]
env = {
    "sys_platform": {"linux": "linux", "windows": "win32", "macos": "darwin"}[os_],
    "platform_system": {"linux": "Linux", "windows": "Windows", "macos": "Darwin"}[os_],
    "os_name": "nt" if os_ == "windows" else "posix",
    "platform_machine": {("windows", "x86_64"): "AMD64", ("windows", "aarch64"): "ARM64"}.get((os_, arch), arch),
    "python_version": ".".join(pyver.split(".")[:2]), "python_full_version": pyver,
    "implementation_name": "cpython", "platform_python_implementation": "CPython",
}
pkgs = tomllib.load(open(lock, "rb"))["package"]
want, todo = {}, [d for p in pkgs if p["name"] == "freerdp-tk" for d in p.get("dependencies", [])]
while todo:
    d = todo.pop()
    if "marker" in d and not Marker(d["marker"]).evaluate(env):
        continue
    found = [p for p in pkgs if p["name"] == d["name"] and d.get("version", p["version"]) == p["version"]]
    if len(found) != 1:
        sys.exit(f"freerdp-tk's uv.lock: {len(found)} packages match {d}")
    p = found[0]
    if p["name"] not in want:
        want[p["name"]] = p
        todo += p.get("dependencies", [])
for name, p in sorted(want.items()):
    hashes = " ".join(f"--hash={w['hash']}" for w in p.get("wheels", []))
    if not hashes:
        sys.exit(f"freerdp-tk's uv.lock: {name} {p['version']} has no wheel")
    print(f"{name}=={p['version']} {hashes}")
PY
    "$python" -s -m pip install --quiet --disable-pip-version-check --no-input --no-compile --root-user-action=ignore \
        --no-deps --only-binary=:all: --require-hashes "${plat[@]}" \
        --target "$pkg/lib/freerdp-tk" -r "$req" || { rm -f "$req"; return 1; }
    # their licences beside the others; their dist-info stays (importlib.metadata finds keyring's backends by it)
    local info name
    for info in "$pkg"/lib/freerdp-tk/*.dist-info; do
        name=$(basename "$info" .dist-info)
        mkdir -p "$pkg/licenses/freerdp_tk/needs/$name"
        find "$info" \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -type f \
            -exec cp {} "$pkg/licenses/freerdp_tk/needs/$name/" \;
    done
    rm -rf "$pkg/lib/freerdp-tk/bin"
    TK_DEPS=$(awk '{ sub("==", " ", $1); printf "%s%s", sep, $1; sep = ", " }' "$req")
    rm -f "$req"
    echo "launcher: freerdp-tk needs $TK_DEPS ($os $arch)"
}

# check_launcher <package dir>: the bundled Python runs here (Linux, macOS)
# and has what freerdp-tk needs: Tk, freerdp-tk itself importable, and,
# when freerdp-tk needs it, keyring with this OS's own backend
check_launcher() {
    local pkg=$1
    PYTHONPATH=$pkg/lib/freerdp-tk "$pkg/python/bin/python3" -s -c '
import importlib.util, sys, _tkinter, tkinter, freerdp_tk.app
print("launcher: Python", sys.version.split()[0], "with Tk", _tkinter.TK_VERSION)
if importlib.util.find_spec("freerdp_tk.credentials"):
    # the backend modules swallow a missing library, so import what they need too
    import keyring
    need = {"linux": ["keyring.backends.SecretService", "secretstorage", "jeepney", "cryptography"],
            "darwin": ["keyring.backends.macOS"]}[sys.platform]
    for m in need:
        importlib.import_module(m)
    print("launcher: keyring with", ", ".join(need))
'
}
