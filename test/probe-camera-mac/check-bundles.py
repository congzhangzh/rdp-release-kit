#!/usr/bin/env python3
# The probe's checks of the signed (or ad hoc) Mac bundles, on macOS:
#
#   check-bundles.py adhoc  <host package dir> <client package dir>
#   check-bundles.py signed <host package dir> <client package dir> <team id>
#
# - the ids: one prefix (KIT_MAC_ID_PREFIX): host <p>.freerdp-shadow, its agent .agent, its
#   camera .camera, the client <p>.freerdp; each signature's identifier is its bundle's id
# - the camera extension's Info.plist: SYSX, its executable, CMIOExtensionMachServiceName, and
#   the rule macOS enforces: the Mach service starts with one of the extension's app groups
#   and a dot (signed: exactly <team>.<host id>.camera)
# - the entitlements of every signed program, exactly (nothing more, nothing less), written
#   out here, independently of build/macos/*.entitlements*
# - signed only: the hardened runtime on every Mach-O, the embedded provisioning profiles
# Prints ok/FAIL per check, exit 1 if any failed.
import plistlib
import re
import subprocess
import sys
from pathlib import Path

failed = 0


def report(ok, what, detail=""):
    global failed
    print(f"{'ok  ' if ok else 'FAIL'}  {what}{('  (' + detail + ')') if detail else ''}")
    if not ok:
        failed = 1


def run(*args):
    r = subprocess.run(args, capture_output=True, encoding="utf-8", errors="replace")
    return r.returncode, r.stdout, r.stderr


def entitlements(path):
    rc, out, err = run("codesign", "-d", "--entitlements", "-", "--xml", str(path))
    if rc != 0:
        report(False, f"codesign -d --entitlements {path}", err.strip())
        return None
    out = out.strip()
    return plistlib.loads(out.encode("utf-8")) if out else {}


def signature(path):
    """codesign -d -v: Identifier, flags, TeamIdentifier"""
    rc, out, err = run("codesign", "-d", "-v", str(path))
    text = out + err  # codesign -d prints to stderr
    info = {}
    for key in ("Identifier", "TeamIdentifier", "Signature", "CDHash"):
        m = re.search(rf"^{key}=(.*)$", text, re.M)
        info[key] = m.group(1).strip() if m else None
    m = re.search(r"flags=0x[0-9a-f]+\(([^)]*)\)", text)
    info["flags"] = m.group(1) if m else ""
    return info


def macho_files(root):
    for f in sorted(Path(root).rglob("*")):
        if f.is_file() and not f.is_symlink():
            rc, out, _ = run("file", "-b", str(f))
            if rc == 0 and out.startswith("Mach-O"):
                yield f


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in ("adhoc", "signed"):
        sys.exit("usage: check-bundles.py adhoc|signed <host package dir> <client package dir> [team id]")
    mode = sys.argv[1]
    host_pkg, client_pkg = Path(sys.argv[2]), Path(sys.argv[3])
    signed = mode == "signed"
    app = host_pkg / "FreeRDP-Shadow.app"
    client = client_pkg / "FreeRDP.app"
    host_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    client_info = plistlib.loads((client / "Contents/Info.plist").read_bytes())
    host_id = host_info["CFBundleIdentifier"]
    client_id = client_info["CFBundleIdentifier"]
    camera_id = host_id + ".camera"
    ext = app / f"Contents/Library/SystemExtensions/{camera_id}.systemextension"

    # the ids: one prefix
    report(host_id.endswith(".freerdp-shadow"), f"host id {host_id} is <prefix>.freerdp-shadow")
    prefix = host_id[: -len(".freerdp-shadow")]
    report(client_id == prefix + ".freerdp", f"client id {client_id} is {prefix}.freerdp")
    report(not host_id.startswith("org.freerdp") and not client_id.startswith("org.freerdp"),
           "no org.freerdp.* id (the FreeRDP project's)")

    # the extension's Info.plist and the Mach service rule
    report(ext.is_dir(), f"the camera extension is at {ext.relative_to(host_pkg)}")
    if not ext.is_dir():
        return 1
    ext_info = plistlib.loads((ext / "Contents/Info.plist").read_bytes())
    report(ext_info.get("CFBundleIdentifier") == camera_id, f"extension id {ext_info.get('CFBundleIdentifier')}")
    report(ext_info.get("CFBundlePackageType") == "SYSX", "extension CFBundlePackageType SYSX")
    exe = ext / "Contents/MacOS" / ext_info.get("CFBundleExecutable", "?")
    report(exe.is_file(), f"extension executable {exe.name}")
    service = (ext_info.get("CMIOExtension") or {}).get("CMIOExtensionMachServiceName", "")
    report(bool(service), f"CMIOExtension/CMIOExtensionMachServiceName = {service}")
    team = sys.argv[4] if signed else service.split(".", 1)[0]
    group = f"{team}.{host_id}"
    if signed:
        report(service == f"{team}.{host_id}.camera", f"Mach service is <team>.<host id>.camera ({team})")

    # the entitlements, exactly
    want = {
        "camera extension": (ext, {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.application-groups": [group],
            **({"com.apple.application-identifier": f"{team}.{camera_id}",
                "com.apple.developer.team-identifier": team} if signed else {}),
        }),
        "host app (freerdp-shadow-cli)": (app, {
            "com.apple.developer.system-extension.install": True,
            "com.apple.security.application-groups": [group],
            "com.apple.application-identifier": f"{team}.{host_id}",
            "com.apple.developer.team-identifier": team,
        } if signed else {}),
        "agent": (app / "Contents/MacOS/freerdp-shadow-agent", {}),
        "client app (sdl-freerdp)": (client, {
            "com.apple.security.device.camera": True,
            "com.apple.security.device.audio-input": True,
        }),
    }
    got = {}
    for what, (path, expected) in want.items():
        ent = entitlements(path)
        got[what] = ent or {}
        report(ent == expected, f"entitlements of the {what}",
               f"got {ent}" if ent != expected else f"{len(expected)} key(s)")
    groups = got["camera extension"].get("com.apple.security.application-groups", [])
    report(any(service.startswith(g + ".") for g in groups),
           f"the Mach service {service} starts with an app group of the extension and a dot", f"groups {groups}")
    report(not any(k.startswith("com.apple.security.cs.") for k in got["camera extension"]),
           "no hardened runtime exception in the extension (macOS refuses to load it)")

    # each signature's identifier
    for path, ident in ((app, host_id), (app / "Contents/MacOS/freerdp-shadow-agent", host_id + ".agent"),
                        (ext, camera_id), (client, client_id)):
        sig = signature(path)
        report(sig["Identifier"] == ident, f"identifier of {path.name}: {sig['Identifier']}")
        if signed:
            report(sig["TeamIdentifier"] == team, f"team of {path.name}: {sig['TeamIdentifier']}")

    # Developer ID: the hardened runtime everywhere, the profiles embedded
    for bundle, root in (("host", host_pkg), ("client", client_pkg)):
        files = list(macho_files(root))
        if signed:
            plain = [str(f.relative_to(root)) for f in files if "runtime" not in signature(f)["flags"]]
            report(not plain, f"{bundle}: the hardened runtime on all {len(files)} Mach-O file(s)",
                   ", ".join(plain[:5]))
        else:
            print(f"info  {bundle}: {len(files)} Mach-O file(s)")
    for bundle in (app, ext):
        has = (bundle / "Contents/embedded.provisionprofile").is_file()
        report(has == signed, f"{bundle.name}: embedded.provisionprofile {'present' if has else 'absent'}")
    return failed


if __name__ == "__main__":
    sys.exit(main())
