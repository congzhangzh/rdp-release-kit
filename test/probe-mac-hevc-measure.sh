#!/bin/bash
# probe-mac-hevc-measure: a record, not a kit test. On GitHub's macOS runner, the Mac host
# (FreeRDP-Shadow.app) encodes the same screen content for the kit's own macOS client as AV1
# and as HEVC 4:2:0, and this measures what each costs the server, so the product owner can
# decide whether the Mac host should prefer HEVC when a client offers it.
#   test/probe-mac-hevc-measure.sh <host dir (holds FreeRDP-Shadow.app)> <client dir (holds bin/sdl-freerdp)> <out dir>
# Environment (all optional):
#   DURATION=40            seconds measured per session, from the client's first GFX frame
#   ROUNDS=2               rounds; each round runs every kind once, interleaved (A B C A B C)
#   KINDS="av1 hevc av1-i420"
#                          av1      = A: what a default client gets (AV1, 4:4:4), client /gfx:AV2:off
#                          hevc     = B: HEVC 4:2:0 at A's bits: client /gfx:AV2:off,AV1:off,HEVC:i420
#                                     (mac-host.sh's form), server /codec:hevc:bitrate:<the kbit/s the
#                                     same round's A put on the wire>; needs av1 before it in KINDS
#                          av1-i420 = C: AV1 4:2:0 (/gfx:AV2:off,AV1:i420), the same chroma as B;
#                                     a record next to the rule (INFO), not part of it
#   HEVC_DEFAULT=1         and once per content after the rounds, B0 = hevc-default: HEVC at the
#                          server's default 500 kbit/s, what users get today (INFO)
#   CONTENTS="apps anim"   apps = mac-host.sh's motion (Calculator and System Settings opening and
#                          closing), looped over the whole window; anim = a canvas animation in
#                          Firefox, changing every frame (a sustained load the app motion is not)
#   SERVER_WLOG_LEVEL=DEBUG  the server's log level (DEBUG as mac-host.sh: the codec lines need it)
# The decision rule (the product owner's), at equal bits: HEVC at AV1's measured rate must give
# >= AV1's encoder frame rate at LOWER server CPU, with 0 failed frames and the codec it was asked
# for. The defaults are not equal bits (FreeRDP 74d0beb8 shadow_server.c: AV1 constrained quality
# cq-level 16 with a 12000 kbit/s cap, HEVC VBR 500 kbit/s), hence B at A's rate; VBR may miss its
# target, so B's bytes/s is printed next to it and flagged outside 80-120 %.
# Every session gets a fresh server with the same arguments (the LaunchAgent's, plus
# /gfx-hevc:i420 and a 1 s stats period; B adds /codec:hevc:bitrate:N, a command-line switch in
# 74d0beb8: server/shadow/cli/shadow.c:151, shadow_server.c:898), so only the client's offer and
# HEVC's target differ between kinds.
# Bash 3.2 (macOS's own) is enough here.
set -u
HOSTDIR=$1; CLIENTDIR=$2; OUT=$3
DURATION=${DURATION:-40}; ROUNDS=${ROUNDS:-2}
KINDS=${KINDS:-av1 hevc av1-i420}; CONTENTS=${CONTENTS:-apps anim}; HEVC_DEFAULT=${HEVC_DEFAULT:-1}
SERVER_WLOG_LEVEL=${SERVER_WLOG_LEVEL:-DEBUG}
KIT_TEST=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT/sessions" "$OUT/content"
OUT=$(cd "$OUT" && pwd)
SERVER="$HOSTDIR/FreeRDP-Shadow.app/Contents/MacOS/freerdp-shadow-cli"
CLIENT="$CLIENTDIR/bin/sdl-freerdp"
FIREFOX=/Applications/Firefox.app/Contents/MacOS/firefox
# build/macos/org.freerdp.shadow.plist's codec arguments, plus HEVC and the stats line every second
# ("gfx 1.0 s: captured N (x/s), sent N (x/s), held N, ..., encode avg X ms max Y ms, ...",
# FreeRDP server/shadow/shadow_gfx_stats.c); -auth on 127.0.0.1 as in mac-host.sh
SERVER_ARGS="/sec:tls /gfx-av1 /gfx-av2 -gfx-avc444 /gfx-hevc:i420 /gfx-stats-period:1 -auth"
export PYTHONUTF8=1
TOOL="$OUT/content/measure.py"

kind_opts() {
    case $1 in
        av1) echo "/gfx:AV2:off" ;;
        av1-i420) echo "/gfx:AV2:off,AV1:i420" ;;
        hevc | hevc-default) echo "/gfx:AV2:off,AV1:off,HEVC:i420" ;;
        *) echo "unknown kind $1" >&2; return 1 ;;
    esac
}
listening() { nc -z 127.0.0.1 "$1" 2> /dev/null; }
now() { python3 -c 'import time; print("%.3f" % time.time())'; }
lines() { [ -f "$1" ] && awk 'END { print NR }' "$1" || echo 0; }
# lo0's sent bytes (netstat -ib, the <Link#1> row: Obytes is the next to last column; lo0 has no
# Address, so the columns are counted from the end)
lo0_bytes() { netstat -ib -I lo0 2> /dev/null | awk '$3 ~ /^<Link/ { print $(NF - 1); exit }'; }
quit_apps() {
    osascript -e 'quit app "Calculator"' -e 'quit app "System Settings"' > /dev/null 2>&1
    pkill -x Calculator 2> /dev/null; pkill -x "System Settings" 2> /dev/null; true
}
# mac-host.sh's motion() (the same apps, the same gaps), looped until killed: about 15 s a turn
motion_loop() {
    while :; do
        open -a Calculator; sleep 3; open -a "System Settings"; sleep 3
        osascript -e 'quit app "Calculator"'; sleep 2; open -a Calculator; sleep 3
        osascript -e 'quit app "System Settings"'; sleep 2
        osascript -e 'quit app "Calculator"'; sleep 2
    done > /dev/null 2>&1
}

# the helpers: the CPU sampler and the numbers of a session and of the run (python3: the runner's)
cat > "$TOOL" << 'PY'
import csv, os, re, subprocess, sys, time

def cputime(s):
    """ps's TIME ([dd-][hh:]mm:ss.ss) in seconds"""
    s = s.strip()
    days = 0
    if "-" in s:
        d, s = s.split("-", 1)
        days = int(d)
    v = 0.0
    for p in s.split(":"):
        v = v * 60 + float(p)
    return days * 86400 + v

def sample(out, stop, pids):
    """every second: each process's CPU time so far (ps TIME) and ps's own %cpu (a decaying average)"""
    nxt = time.time()
    with open(out, "a", encoding="utf-8") as f:
        while not os.path.exists(stop):
            t = time.time()
            for pid in pids:
                r = subprocess.run(["ps", "-o", "time=", "-o", "%cpu=", "-p", pid],
                                   capture_output=True, encoding="utf-8", errors="replace")
                part = r.stdout.split()
                if len(part) >= 2:
                    f.write("%.3f %s %.3f %s\n" % (t, pid, cputime(part[0]), part[1]))
            f.flush()
            nxt += 1.0
            time.sleep(max(0.0, nxt - time.time()))

def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []

def cpu_stats(samples, pid, t0, t1):
    pts = [(t, c) for (t, p, c, _) in samples if p == pid and t0 - 0.5 <= t <= t1 + 0.5]
    if len(pts) < 2:
        return None, None
    mean = (pts[-1][1] - pts[0][1]) / (pts[-1][0] - pts[0][0]) * 100.0
    rates = sorted((b[1] - a[1]) / (b[0] - a[0]) * 100.0 for a, b in zip(pts, pts[1:]) if b[0] > a[0])
    p95 = rates[min(len(rates) - 1, max(0, -(-95 * len(rates) // 100) - 1))]
    return mean, p95

GFX = re.compile(r"gfx ([\d.]+) s: captured (\d+) \([^)]*\), sent (\d+) \([^)]*\), held (\d+), "
                 r"merged (\d+), acks (\d+)[^,]*, ack delay (?:avg \d+ ms max \d+ ms|-), "
                 r"encode (?:avg ([\d.]+) ms max ([\d.]+) ms|-)")
GOT = re.compile(r"Got GFX (RDPGFX_CODECID_[A-Z0-9_]+)")
CONFIRM = re.compile(r"RecvCapsConfirmPdu: version: (RDPGFX_CAPVERSION_[A-Z0-9_]+)(.*)")
FAILED = re.compile(r"_decompress failure|decode failed|requires a key picture|rdpgfx_decode failed|"
                    r"not allowed with|not valid with caps|no HEVC .* decoder available")
VT = re.compile(r"VideoToolbox HEVC encoder: (\d+x\d+) at \d+ fps, ([^,]+), hardware (\w+)")
AV1 = re.compile(r"AV1 (\d+x\d+) (I4[24][04]): (\d+) frames in ([\d.]+) s \([\d.]+ fps\), "
                 r"encode avg [\d.]+ ms max [\d.]+ ms, (\d+) kbit/s")
WIRE = re.compile(r"^(\d+\.\d+) .* tcp (\d+)$")
EXPECT = {"av1": "RDPGFX_CODECID_AV1", "av1-i420": "RDPGFX_CODECID_AV1", "hevc": "RDPGFX_CODECID_HEVC420",
          "hevc-default": "RDPGFX_CODECID_HEVC420"}
COLUMNS = ["content", "kind", "round", "valid", "invalid_reason", "codec_seen", "caps", "chroma",
           "window_s", "server_fps", "captured_fps", "sent_frames", "held", "encode_avg_ms",
           "cpu_mean", "cpu_p95", "ps_pcpu_mean", "client_cpu_mean", "bytes_per_s", "bytes_method",
           "lo0_bytes_per_s", "client_frames", "client_failed", "server_log_lines_per_s",
           "encoder", "av1_kbit_s", "target_kbit", "achieved_kbit", "rate_note"]

def f1(v):
    return "" if v is None else "%.1f" % v

def session(d, results):
    meta = dict(l.split("=", 1) for l in read_lines(os.path.join(d, "meta.txt")) if "=" in l)
    kind = meta["kind"]
    row = {k: "" for k in COLUMNS}
    row.update(content=meta["content"], kind=kind, round=meta["round"])
    why = [meta["invalid"]] if meta.get("invalid") else []
    srv = read_lines(os.path.join(d, "server.wlog"))
    cli = read_lines(os.path.join(d, "client.wlog"))
    if "t0" in meta and "t1" in meta:
        t0, t1 = float(meta["t0"]), float(meta["t1"])
        win = t1 - t0
        row["window_s"] = f1(win)
        swin = srv[int(meta["srv_lines0"]):int(meta["srv_lines1"])]
        cwin = cli[int(meta["cli_lines0"]):int(meta["cli_lines1"])]
        row["server_log_lines_per_s"] = f1(len(swin) / win)
        secs = cap = sent = held = 0.0
        enc = 0.0
        for l in swin:
            m = GFX.search(l)
            if m:
                secs += float(m.group(1)); cap += int(m.group(2)); sent += int(m.group(3))
                held += int(m.group(4))
                if m.group(7):
                    enc += float(m.group(7)) * int(m.group(3))
        if secs > 0:
            row.update(server_fps=f1(sent / secs), captured_fps=f1(cap / secs), sent_frames=int(sent),
                       held=int(held), encode_avg_ms=f1(enc / sent) if sent else "")
        else:
            why.append("no gfx stats line in the window")
        if sent == 0:
            why.append("the server sent no frame in the window")
        kb = [(int(m.group(5)), float(m.group(4))) for m in (AV1.search(l) for l in swin) if m]
        if kb:
            row["av1_kbit_s"] = f1(sum(k * s for k, s in kb) / sum(s for _, s in kb))
        codecs = {}
        for l in cwin:
            m = GOT.search(l)
            if m:
                codecs[m.group(1)] = codecs.get(m.group(1), 0) + 1
        total = sum(codecs.values())
        seen = max(codecs, key=codecs.get) if codecs else "none"
        row["codec_seen"] = " ".join("%s:%d" % (k.replace("RDPGFX_CODECID_", ""), v)
                                     for k, v in sorted(codecs.items(), key=lambda kv: -kv[1])) or "none"
        row["client_frames"] = codecs.get(EXPECT[kind], 0)
        if seen != EXPECT[kind] or codecs.get(seen, 0) < 0.9 * total:
            why.append("the client got %s, not %s (90 %% or more)" % (row["codec_seen"], EXPECT[kind]))
        samples = []
        for l in read_lines(os.path.join(d, "cpu.txt")):
            p = l.split()
            if len(p) == 4:
                samples.append((float(p[0]), p[1], float(p[2]), float(p[3])))
        mean, p95 = cpu_stats(samples, meta["server_pid"], t0, t1)
        row.update(cpu_mean=f1(mean), cpu_p95=f1(p95))
        if mean is None:
            why.append("no CPU samples")
        pc = [s[3] for s in samples if s[1] == meta["server_pid"] and t0 <= s[0] <= t1]
        row["ps_pcpu_mean"] = f1(sum(pc) / len(pc)) if pc else ""
        row["client_cpu_mean"] = f1(cpu_stats(samples, meta["client_pid"], t0, t1)[0])
        if meta.get("lo0_0") and meta.get("lo0_1"):
            row["lo0_bytes_per_s"] = "%.0f" % ((int(meta["lo0_1"]) - int(meta["lo0_0"])) / win)
        wire = read_lines(os.path.join(d, "wire.txt"))
        if meta.get("tcpdump") == "1" and wire:
            n = 0
            for l in wire:
                m = WIRE.match(l)
                if m and t0 <= float(m.group(1)) < t1:
                    n += int(m.group(2))
            row.update(bytes_per_s="%.0f" % (n / win), bytes_method="tcpdump")
        elif row["lo0_bytes_per_s"]:
            row.update(bytes_per_s=row["lo0_bytes_per_s"], bytes_method="lo0")
        else:
            why.append("no byte count")
    m = None
    for l in cli:
        m = CONFIRM.search(l)
        if m:
            break
    caps, flags = (m.group(1).replace("RDPGFX_CAPVERSION_", ""), m.group(2)) if m else ("none", "")
    row["caps"] = caps
    if kind.startswith("av1"):
        row["chroma"] = "I420" if "AV1_I444_DISABLED" in flags else "I444"
        if caps != "FRDP_1":
            why.append("caps %s, not FRDP_1 (AV1)" % caps)
        elif (kind == "av1-i420") != (row["chroma"] == "I420"):
            why.append("AV1 %s, not the chroma asked for" % row["chroma"])
    else:
        row["chroma"] = "I420"
        if not (caps.startswith("11") and re.search(r"[{|]HEVC_ENABLE[|}]", flags)):
            why.append("caps %s without HEVC_ENABLE" % caps)
    row["client_failed"] = sum(1 for l in cli if FAILED.search(l))
    vt = [m for m in (VT.search(l) for l in srv) if m and m.group(1) != "256x256"]
    if vt:
        row["encoder"] = "VT HEVC %s %s hw=%s" % (vt[-1].group(1), vt[-1].group(2), vt[-1].group(3))
    else:
        a = [m for m in (AV1.search(l) for l in srv) if m]
        if a:
            row["encoder"] = "libaom AV1 %s %s" % (a[-1].group(1), a[-1].group(2))
    if meta.get("client_held") != "1":
        why.append("the client did not hold the session")
    row["target_kbit"] = meta.get("target_kbit", "")
    if row["bytes_per_s"]:
        row["achieved_kbit"] = "%.0f" % (float(row["bytes_per_s"]) * 8 / 1000)
        if row["target_kbit"]:
            ratio = float(row["achieved_kbit"]) / float(row["target_kbit"])
            row["rate_note"] = "%.0f %% of the target%s" % (
                100 * ratio, "" if 0.8 <= ratio <= 1.2 else ", rate not reached")
    row["valid"] = "no" if why else "yes"
    row["invalid_reason"] = "; ".join(why)
    new = not os.path.exists(results)
    with open(results, "a", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        if new:
            w.writeheader()
        w.writerow(row)
    print("%-6s %-12s r%s  %s  fps %s  cpu %s/%s  %s B/s (%s)%s  frames %s  failed %s  %s%s" % (
        row["content"], kind, row["round"], "VALID  " if not why else "INVALID", row["server_fps"],
        row["cpu_mean"], row["cpu_p95"], row["bytes_per_s"], row["bytes_method"],
        ("  target %s kbit/s: %s" % (row["target_kbit"], row["rate_note"])) if row["target_kbit"] else "",
        row["client_frames"], row["client_failed"], row["codec_seen"],
        (": " + row["invalid_reason"]) if why else ""))

def kbit(results, content, kind, rnd):
    """the kbit/s a valid session put on the wire (B's target), or nothing"""
    try:
        with open(results, encoding="utf-8", newline="") as f:
            rows = list(csv.DictReader(f))
    except OSError:
        return
    for r in rows:
        if (r["content"], r["kind"], r["round"]) == (content, kind, rnd) and r["valid"] == "yes" \
                and r["achieved_kbit"]:
            print(min(1000000, max(1, int(float(r["achieved_kbit"])))))

def num(r, k):
    try:
        return float(r[k])
    except (KeyError, ValueError):
        return None

def mean(v):
    v = [x for x in v if x is not None]
    return sum(v) / len(v) if v else None

def decide(out, rows, a, b, label, rule, matched):
    """kind b (HEVC) against kind a; every round of both must be valid. matched: b ran at a's bits,
    the rule (fps, CPU, failed); else bytes/s <= 2x a's as one more line"""
    ra = [r for r in rows if r["kind"] == a]
    rb = [r for r in rows if r["kind"] == b]
    tag = "" if rule else "INFO "
    if not ra or not rb:
        return None
    bad = [r for r in ra + rb if r["valid"] != "yes"]
    if bad:
        out.append("%sNO RESULT  %s: %d of %d sessions invalid (see invalid_reason)" % (
            tag, label, len(bad), len(ra + rb)))
        return False
    def spread(rs, k):
        v = [num(r, k) for r in rs]
        return max(v) - min(v)
    fa, fb = mean(num(r, "server_fps") for r in ra), mean(num(r, "server_fps") for r in rb)
    ca, cb = mean(num(r, "cpu_mean") for r in ra), mean(num(r, "cpu_mean") for r in rb)
    ba, bb = mean(num(r, "bytes_per_s") for r in ra), mean(num(r, "bytes_per_s") for r in rb)
    failed = sum(int(r["client_failed"]) for r in rb)
    noise = max(spread(ra, "server_fps"), spread(rb, "server_fps"))
    cnoise = max(spread(ra, "cpu_mean"), spread(rb, "cpu_mean"))
    note = lambda d, n: "  (within the rounds' spread %.1f)" % n if abs(d) <= n else ""
    checks = [
        (fb >= fa, "frame rate: %s %.1f fps >= %s %.1f fps%s" % (b, fb, a, fa, note(fb - fa, noise))),
        (cb < ca, "server CPU: %s %.1f %% < %s %.1f %%%s" % (b, cb, a, ca, note(cb - ca, cnoise))),
        (failed == 0, "failed frames: %s %d == 0" % (b, failed)),
        (True, "codec: every session negotiated the codec asked for"),
    ]
    if not matched:
        checks.insert(2, (bb <= 2 * ba, "bytes/s: %s %.0f <= 2 x %s %.0f = %.0f (ratio %.2f)" % (
            b, bb, a, ba, 2 * ba, bb / ba if ba else 0)))
    for ok, text in checks:
        out.append("%s%s  %s: %s" % (tag, "PASS" if ok else "FAIL", label, text))
    if matched:
        for r in sorted(rb, key=lambda r: r["round"]):
            flag = "FLAG " if "not reached" in r["rate_note"] else "     "
            out.append("%s%s %s: round %s: %s achieved %s kbit/s for a target of %s (%s); %s %s kbit/s" % (
                tag, flag, label, r["round"], b, r["achieved_kbit"], r["target_kbit"], r["rate_note"], a,
                next((x["achieved_kbit"] for x in ra if x["round"] == r["round"]), "?")))
    ok = all(c[0] for c in checks)
    out.append("%s%s  %s: %s" % (tag, "PASS" if ok else "FAIL", label,
                                 "every criterion" if ok else "not every criterion holds"))
    return ok

def summary(results, out_txt):
    with open(results, encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))
    out = []
    cols = [("content", 7), ("kind", 12), ("round", 5), ("valid", 5), ("codec_seen", 22),
            ("server_fps", 10), ("captured_fps", 12), ("encode_avg_ms", 13), ("held", 5), ("cpu_mean", 8),
            ("cpu_p95", 7), ("client_cpu_mean", 15), ("bytes_per_s", 11), ("bytes_method", 12),
            ("target_kbit", 11), ("achieved_kbit", 13), ("rate_note", 30),
            ("sent_frames", 11), ("client_frames", 13), ("client_failed", 13), ("encoder", 44)]
    out.append(" ".join(c.ljust(w) for c, w in cols))
    for r in rows:
        out.append(" ".join(str(r.get(c, ""))[:w].ljust(w) for c, w in cols))
    out.append("")
    out.append("cpu = the server process, 100 = one core (from its CPU time, ps TIME, over the window); "
               "fps = the server's frames sent (its gfx stats lines); bytes/s = server to client")
    out.append("rate control: AV1 its default (constrained quality cq-level 16, cap 12000 kbit/s, FreeRDP "
               "74d0beb8); hevc = HEVC VBR at the kbit/s the round's AV1 put on the wire "
               "(/codec:hevc:bitrate); hevc-default = HEVC's default VBR 500 kbit/s. Equal bits, not "
               "measured equal picture quality")
    verdict, decided = True, 0
    for content in sorted(set(r["content"] for r in rows)):
        rs = [r for r in rows if r["content"] == content]
        out.append("")
        out.append("== %s ==" % content)
        v = decide(out, rs, "av1", "hevc", "%s HEVC vs AV1, equal bits" % content, True, True)
        if v is not None:
            verdict, decided = verdict and v, decided + 1
        decide(out, rs, "av1", "hevc-default", "%s HEVC 500 kbit/s (today) vs AV1" % content, False, False)
        decide(out, rs, "av1-i420", "hevc", "%s HEVC at AV1's bits vs AV1 4:2:0" % content, False, False)
    out.append("")
    flagged = [r for r in rows if "not reached" in r["rate_note"] and r["kind"] == "hevc"]
    out.append("VERDICT  %s%s" % ("PASS: at equal bits HEVC meets the rule in every content" if verdict and decided
                                  else "FAIL or NO RESULT: see the lines above",
                                  "  (FLAG: %d HEVC session(s) missed the target rate by more than 20 %%)" %
                                  len(flagged) if flagged else ""))
    text = "\n".join(out) + "\n"
    with open(out_txt, "w", encoding="utf-8") as f:
        f.write(text)
    print(text, end="")
    invalid = [r for r in rows if r["valid"] != "yes"]
    return 1 if invalid else 0

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "sample":
        sample(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif cmd == "session":
        session(sys.argv[2], sys.argv[3])
    elif cmd == "kbit":
        kbit(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif cmd == "summary":
        sys.exit(summary(sys.argv[2], sys.argv[3]))
PY

{ sw_vers; uname -m; sysctl -n machdep.cpu.brand_string hw.ncpu 2> /dev/null; } > "$OUT/system.txt" 2>&1
cat "$OUT/system.txt"
fails=0
hevc_ok=1
for b in "$SERVER" "$CLIENT"; do
    "$b" /buildconfig 2> /dev/null | tr " " "\n" | grep -qx "WITH_GFX_AZURE=ON" || hevc_ok=0
done
if [ $hevc_ok != 1 ]; then
    echo "FAIL  the host or the client is built without WITH_GFX_AZURE: no HEVC to measure"
    exit 1
fi
# the wire: tcpdump on lo0 (the runner's sudo has no password); else lo0's counters
TCPDUMP=0
if sudo -n true 2> /dev/null && command -v tcpdump > /dev/null; then TCPDUMP=1; fi
echo "bytes on the wire: $([ $TCPDUMP = 1 ] && echo "tcpdump on lo0, server to client" || echo "lo0's counters (netstat -ib), both directions")"

# anim: a canvas that changes every frame (moving blocks, a gradient, a clock, scrolling text),
# in Firefox (the runner image's, as mac-host.sh's web demo); the same page every session
cat > "$OUT/content/anim.html" << 'HTML'
<!doctype html>
<meta charset="utf-8">
<title>probe motion</title>
<style>html, body { margin: 0; height: 100%; overflow: hidden; background: #000 } canvas { display: block }</style>
<canvas id="c"></canvas>
<script>
const c = document.getElementById("c"), g = c.getContext("2d");
function size() { c.width = innerWidth; c.height = innerHeight; }
addEventListener("resize", size); size();
const start = performance.now();
function frame(now) {
  const t = (now - start) / 1000, w = c.width, h = c.height;
  const grd = g.createLinearGradient(0, 0, w, h);
  grd.addColorStop(0, `hsl(${(t * 40) % 360}, 70%, 45%)`);
  grd.addColorStop(1, `hsl(${(t * 40 + 180) % 360}, 70%, 30%)`);
  g.fillStyle = grd; g.fillRect(0, 0, w, h);
  for (let i = 0; i < 48; i++) {
    const x = (Math.sin(t * (0.5 + i * 0.037) + i) * 0.5 + 0.5) * (w - 80);
    const y = (Math.cos(t * (0.4 + i * 0.029) + i * 1.7) * 0.5 + 0.5) * (h - 60);
    g.fillStyle = `hsl(${(i * 47 + t * 90) % 360}, 80%, 60%)`;
    g.fillRect(x, y, 80, 60);
  }
  g.fillStyle = "#fff"; g.font = "20px Menlo, monospace";
  for (let k = 0; k < 20; k++)
    g.fillText("The quick brown fox jumps over the lazy dog " + ((k + Math.floor(t * 10)) % 97),
               ((t * 120 + k * 37) % w) - w / 2, 40 + k * 26);
  g.font = "48px Menlo, monospace"; g.fillText(t.toFixed(3) + " s", 40, h - 40);
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
</script>
HTML
FFPROF=""
start_anim() {
    [ -x "$FIREFOX" ] || return 1
    FFPROF=$(mktemp -d); cp "$KIT_TEST/demo/user.js" "$FFPROF/"
    # the first start out of the measurement: macOS checks a new app, the profile is made
    "$FIREFOX" --headless -no-remote -profile "$FFPROF" about:blank > "$OUT/content/firefox-warm.log" 2>&1 &
    fw=$!; sleep 15; kill $fw 2> /dev/null; sleep 2; pkill -x firefox 2> /dev/null
    "$FIREFOX" -no-remote -profile "$FFPROF" -width 1000 -height 660 "file://$OUT/content/anim.html" \
        > "$OUT/content/firefox.log" 2>&1 &
    sleep 10
    pgrep -x firefox > /dev/null
}
stop_anim() { pkill -x firefox 2> /dev/null; sleep 2; [ -n "$FFPROF" ] && rm -rf "$FFPROF"; FFPROF=""; }

session() {  # session <content> <kind> <round> <port> [<HEVC target kbit/s>]
    local content=$1 kind=$2 round=$3 port=$4 target=${5:-} d meta opts srv tcpd cli kick first mot smp _
    local args=$SERVER_ARGS
    d="$OUT/sessions/$content-$kind-r$round"; mkdir -p "$d"
    meta="$d/meta.txt"
    opts=$(kind_opts "$kind") || return 1
    { echo "content=$content"; echo "kind=$kind"; echo "round=$round"; echo "port=$port"
      echo "client_opts=$opts"; echo "tcpdump=$TCPDUMP"; } > "$meta"
    if [ "$kind" = hevc ]; then
        if [ -z "$target" ]; then
            { echo "server_args=$args"; echo "invalid=no AV1 rate from this round to match (av1 invalid or not run)"; } >> "$meta"
            python3 "$TOOL" session "$d" "$OUT/results.csv"; return
        fi
        args="$args /codec:hevc:bitrate:$target"
        echo "target_kbit=$target" >> "$meta"
    fi
    echo "server_args=$args" >> "$meta"
    [ "$content" = apps ] && quit_apps
    sleep 2
    # shellcheck disable=SC2086  # args: one word per argument
    WLOG_LEVEL=$SERVER_WLOG_LEVEL WLOG_APPENDER=FILE WLOG_FILEAPPENDER_OUTPUT_FILE_PATH="$d" \
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME=server.wlog "$SERVER" /bind-address:127.0.0.1 /port:"$port" \
        $args > "$d/server.out" 2>&1 &
    srv=$!
    echo "server_pid=$srv" >> "$meta"
    for _ in $(seq 1 30); do listening "$port" && break; sleep 1; done
    if ! listening "$port"; then
        echo "invalid=the server did not listen" >> "$meta"
        kill $srv 2> /dev/null; python3 "$TOOL" session "$d" "$OUT/results.csv"; return
    fi
    tcpd=""
    if [ $TCPDUMP = 1 ]; then
        # shellcheck disable=SC2024  # the log is ours, not root's
        sudo -n tcpdump -i lo0 -nn -U -s 96 -w "$d/wire.pcap" "tcp src port $port" > "$d/tcpdump.log" 2>&1 &
        tcpd=$!; sleep 1
    fi
    # shellcheck disable=SC2086  # opts: one word per argument
    WLOG_LEVEL=DEBUG WLOG_APPENDER=FILE WLOG_FILEAPPENDER_OUTPUT_FILE_PATH="$d" \
    WLOG_FILEAPPENDER_OUTPUT_FILE_NAME=client.wlog "$CLIENT" /v:127.0.0.1:"$port" /u:probe /p:probe \
        /cert:ignore /sec:tls /size:1280x720 $opts > "$d/client.out" 2>&1 &
    cli=$!
    echo "client_pid=$cli" >> "$meta"
    # ScreenCaptureKit hands over a frame only when the screen changes: one change for the first
    kick=""
    [ "$content" = apps ] && { ( sleep 2; open -a Calculator ) > /dev/null 2>&1 & kick=$!; }
    first=0
    for _ in $(seq 1 45); do
        grep -q "Got GFX RDPGFX_CODECID_" "$d/client.wlog" 2> /dev/null && { first=1; break; }
        kill -0 $cli 2> /dev/null || break
        sleep 1
    done
    [ -n "$kick" ] && kill $kick 2> /dev/null   # not inside the window, out of the loop's sequence
    mot=""
    if [ $first = 1 ]; then
        # the content's clock starts at the first frame, so every session sees the same sequence
        [ "$content" = apps ] && { quit_apps; motion_loop & mot=$!; }
        { echo "t0=$(now)"; echo "srv_lines0=$(lines "$d/server.wlog")"; echo "cli_lines0=$(lines "$d/client.wlog")"
          echo "lo0_0=$(lo0_bytes)"; } >> "$meta"
        rm -f "$d/stop"
        python3 "$TOOL" sample "$d/cpu.txt" "$d/stop" "$srv" "$cli" &
        smp=$!
        sleep "$DURATION"
        { echo "t1=$(now)"; echo "srv_lines1=$(lines "$d/server.wlog")"; echo "cli_lines1=$(lines "$d/client.wlog")"
          echo "lo0_1=$(lo0_bytes)"; } >> "$meta"
        touch "$d/stop"; wait $smp 2> /dev/null
    else
        echo "invalid=no GFX frame on the client within 45 s" >> "$meta"
    fi
    [ -n "$mot" ] && kill $mot 2> /dev/null
    kill -0 $cli 2> /dev/null && echo "client_held=1" >> "$meta" || echo "client_held=0" >> "$meta"
    kill $cli 2> /dev/null; sleep 2
    kill $srv 2> /dev/null; sleep 2
    kill -0 $srv 2> /dev/null && { kill -9 $srv 2> /dev/null; echo "note=the server needed SIGKILL" >> "$meta"; }
    if [ -n "$tcpd" ]; then
        sudo -n pkill -INT -f "tcp src port $port\$" 2> /dev/null; wait $tcpd 2> /dev/null
        sudo -n chmod a+r "$d/wire.pcap" 2> /dev/null
        tcpdump -nn -tt -q -r "$d/wire.pcap" > "$d/wire.txt" 2>> "$d/tcpdump.log" && rm -f "$d/wire.pcap"
    fi
    [ "$content" = apps ] && quit_apps
    python3 "$TOOL" session "$d" "$OUT/results.csv"
}

port=4500
for content in $CONTENTS; do
    case $content in
        apps) ;;
        anim)
            if ! start_anim; then
                echo "SKIP  anim: no Firefox window ($(ls -d "$FIREFOX" 2>&1))"; stop_anim; continue
            fi ;;
        *) echo "unknown content $content"; fails=$((fails + 1)); continue ;;
    esac
    for round in $(seq 1 "$ROUNDS"); do
        for kind in $KINDS; do
            port=$((port + 1))
            # B at the bits the round's A put on the wire (server to client, kbit/s)
            target=""
            [ "$kind" = hevc ] && target=$(python3 "$TOOL" kbit "$OUT/results.csv" "$content" av1 "$round")
            session "$content" "$kind" "$round" "$port" "$target"
        done
    done
    if [ "$HEVC_DEFAULT" = 1 ]; then
        port=$((port + 1))
        session "$content" hevc-default 1 "$port"
    fi
    [ "$content" = anim ] && stop_anim
done
mkdir -p "$OUT/crash"
cp "$HOME"/Library/Logs/DiagnosticReports/freerdp-shadow-cli* "$HOME"/Library/Logs/DiagnosticReports/sdl-freerdp* \
    "$OUT/crash/" 2> /dev/null || true
echo
[ -s "$OUT/results.csv" ] || { echo "FAIL  no session measured"; exit 1; }
python3 "$TOOL" summary "$OUT/results.csv" "$OUT/summary.txt" || fails=$((fails + 1))
# a FAIL of the rule is a result; an invalid session or a broken run is not, and fails the job
[ $fails = 0 ]
