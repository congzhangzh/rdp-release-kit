// FreeRDP Web decodes AV1 4:2:0 in Chrome, Firefox and Safari (backlog row C, 2026-11-22): one
// session per browser, each through the browser's own WebDriver (safaridriver, chromedriver,
// geckodriver; no packages), against a FreeRDP server whose log this script reads.
//
//   SERVER_LOG=<the server's wlog> node test/web-av1-i420.mjs <page url> <gateway host:port> <browser>
//
// <browser> is safari, chrome or firefox. The page asks for AV1 4:2:0 as the kit's host tests do
// (round B): extra=/gfx:AV2:off,AV1:i420, so the client offers FRDP_1 with AV1_I444_DISABLED.
// Checks, for this browser's session only (its own slice of the server's log):
//  - the server confirms 4:4:4 off ("selected GFX caps RDPGFX_CAPVERSION_FRDP_1 ... AV1_I444_DISABLED",
//    shadow_client.c, INFO) and encodes I420 ("AV1 WxH I420: N frames", av1.c, DEBUG: the server
//    must run with WLOG_LEVEL=DEBUG, as test/mac-host.sh starts it), never I444
//  - the page: AV1 pictures decoded (RDPGFX_CODECID_AV1_PICTURES), the decoder's own reading of the
//    stream's chroma is 4:2:0 (RDPGFX_CODECID_AV1_CHROMA = 420), the confirmed caps are FRDP_1
//  - which decoder did it, from the page: Info's "AV1 decoder" row (FreeRDP's "AV1 decoder: ..."
//    line, or "dav1d (fallback)" after its "WebCodecs AV1 decode failed ..., using dav1d" warning),
//    checked against the WebCodecs glue's own state (Module.freerdpAv1: a configured VideoDecoder
//    with profile 0 while WebCodecs decodes; none once FreeRDP fell back to dav1d)
// Env: CHROME / FIREFOX (the browsers' binaries), CHROMEDRIVER / GECKODRIVER (else the runner
// image's $CHROMEWEBDRIVER / $GECKOWEBDRIVER, else PATH), SECONDS (session length, default 25),
// OUT (a directory for the page's log and Info), PASSWORD (default probe; the server may ignore it).
// Safari needs `safaridriver --enable` once (sudo) and allows one WebDriver session at a time;
// it cannot run headless, the others do.
// RECORD=<file.mp4> (off by default; a record, it changes no check): a video of the session in
// this browser, from macOS's own screen recorder (screencapture -V, as test/mac-host.sh records
// its client), from the session's start to Info open at its "AV1 decoder" row, with <file>.jpg
// (70 %), <file>-mid.jpg and <file>-late.jpg beside it. The browser runs windowed (Chrome and
// Firefox too) on half the screen, over the media page, and the video is cropped to that window;
// a strip at the page's bottom edge names the browser, the codec and the decoder as Info gives
// them (the decoder up to its first comma: the page's hardware/software word is unproven on the
// runner), and DEMO_KIT (e.g. "rdp-release-kit 20261126.5"). No motion step (the media page moves
// the screen). Prints the video's rates, the session's own (Info's "Video codecs" N/s) and a
// RECORD-VERDICT line: Chrome's and Firefox's clip counts when the cropped video has at least 15
// distinct pictures/s or at least the session's rate; Safari's is a record only.
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, openSync, readSync, fstatSync, closeSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";

const [PAGE, GATEWAY, BROWSER] = process.argv.slice(2);
const { SERVER_LOG } = process.env;
if (!PAGE || !GATEWAY || !/^(safari|chrome|firefox)$/.test(BROWSER || "") || !SERVER_LOG) {
  console.error("usage: SERVER_LOG=<wlog> node web-av1-i420.mjs <page url> <gateway host:port> safari|chrome|firefox");
  process.exit(2);
}
const SECONDS = Number(process.env.SECONDS || 25), USER = process.env.USER_NAME || "probe", PASSWORD = process.env.PASSWORD || "probe";
const OUT = process.env.OUT || ""; if (OUT) mkdirSync(OUT, { recursive: true });
const PORT = { safari: 4471, chrome: 4472, firefox: 4473 }[BROWSER];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fails = 0;
const check = (name, ok, detail = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${BROWSER}: ${name}${detail ? "  (" + detail + ")" : ""}`); if (!ok) fails++; };
const info = (s) => console.log(`INFO  ${BROWSER}: ${s}`);
const RECORD = process.env.RECORD || "", KIT = process.env.DEMO_KIT || "";
const NAME = { safari: "Safari", chrome: "Chrome", firefox: "Firefox" }[BROWSER];

// the driver: the runner image's (macOS images set CHROMEWEBDRIVER / GECKOWEBDRIVER to its folder)
const which = (name, env, dir) => process.env[env] || (process.env[dir] && existsSync(join(process.env[dir], name)) ? join(process.env[dir], name) : name);
const driverCmd = {
  safari: ["safaridriver", ["-p", String(PORT)]],
  chrome: [which("chromedriver", "CHROMEDRIVER", "CHROMEWEBDRIVER"), [`--port=${PORT}`]],
  firefox: [which("geckodriver", "GECKODRIVER", "GECKOWEBDRIVER"), ["--port", String(PORT)]],
}[BROWSER];
const capabilities = {
  safari: { browserName: "safari" },
  chrome: { browserName: "chrome", "goog:chromeOptions": { args: ["--headless=new", "--no-first-run", "--no-default-browser-check", "--window-size=1280,800"],
    ...(process.env.CHROME ? { binary: process.env.CHROME } : {}) } },
  firefox: { browserName: "firefox", "moz:firefoxOptions": { args: ["-headless", "-width", "1280", "-height", "800"],
    ...(process.env.FIREFOX ? { binary: process.env.FIREFOX } : {}) } },
}[BROWSER];
// RECORD: windowed, so the Mac's screen shows it (geckodriver's Firefox beside the media page's, each its own profile)
for (const o of RECORD ? [capabilities["goog:chromeOptions"], capabilities["moz:firefoxOptions"]] : [])
  if (o) o.args = [...o.args.filter((a) => !/^-+headless/.test(a)), ...(BROWSER === "firefox" ? ["-no-remote"] : [])];
// RECORD: nothing over the page but the page (probe v2's Chrome showed its clipboard prompt and the
// "controlled by automated test software" bar): the page's origin may use the clipboard
if (RECORD && BROWSER === "chrome") Object.assign(capabilities["goog:chromeOptions"], { excludeSwitches: ["enable-automation"],
  prefs: { "profile.content_settings.exceptions.clipboard": { [`${new URL(PAGE).origin},*`]: { setting: 1 } } } });
if (RECORD && BROWSER === "firefox") capabilities["moz:firefoxOptions"].prefs = { "dom.events.asyncClipboard.readText": true,
  "dom.events.asyncClipboard.clipboardItem": true, "dom.events.testing.asyncClipboard": true };

// the server's log from a byte offset on (WLog's file appender flushes every line)
const logSize = () => { try { return fstatSync(openSync(SERVER_LOG, "r")).size; } catch { return 0; } };
const logFrom = (offset) => {
  const fd = openSync(SERVER_LOG, "r"), size = fstatSync(fd).size, buf = Buffer.alloc(Math.max(0, size - offset));
  readSync(fd, buf, 0, buf.length, offset); closeSync(fd);
  return buf.toString("utf8");
};

const driver = spawn(driverCmd[0], driverCmd[1], { stdio: ["ignore", "ignore", "pipe"] });
const driverLog = []; driver.stderr.on("data", (d) => driverLog.push(...d.toString().split("\n").filter(Boolean)));
let driverGone = null; driver.on("error", (e) => { driverGone = e.message; }); driver.on("exit", (c, s) => { driverGone ??= `exited (code ${c}, signal ${s})`; });
let sid = null;
const motionProcs = [];
let rec = null, win = null, screenW = 0;
const done = async (code) => {
  if (rec) await rec.finish();
  if (sid) await fetch(`http://127.0.0.1:${PORT}/session/${sid}`, { method: "DELETE" }).catch(() => {});
  for (const p of motionProcs) p.kill();
  driver.kill();
  console.log(`${BROWSER}: ${code ? "FAILED" : "PASSED"}`); process.exit(code);
};

const wd = async (method, path, body) => {
  const r = await fetch(`http://127.0.0.1:${PORT}${path}`, { method, headers: { "content-type": "application/json" }, body: body && JSON.stringify(body) });
  const j = await r.json();
  if (j.value?.error) throw new Error(`${path}: ${j.value.error}: ${j.value.message}`);
  return j.value;
};
const ELEMENT = "element-6066-11e4-a52e-4f735466cecf";
const js = (script, ...args) => wd("POST", `/session/${sid}/execute/sync`, { script, args });
const el = async (css) => (await wd("POST", `/session/${sid}/element`, { using: "css selector", value: css }))[ELEMENT];
const click = async (css) => wd("POST", `/session/${sid}/element/${await el(css)}/click`, {});
const type = async (css, text) => { const e = await el(css); await wd("POST", `/session/${sid}/element/${e}/clear`, {}); await wd("POST", `/session/${sid}/element/${e}/value`, { text }); };
const waitFor = async (test, ms) => { for (let t = 0; t < ms; t += 500) { if (await test().catch(() => false)) return true; await sleep(500); } return test().catch(() => false); };

// RECORD: Info's rows, the overlay made from them (laid over the page as test/wasm-demo.mjs's caption)
const ROWS = `return JSON.stringify([...document.querySelectorAll("#infoTable tr")].map((tr) => [...tr.cells].map((c) => c.innerText.trim())))`;
const cell = (rows, name) => ((rows || []).find((r) => r[0] === name) || (rows || []).find((r) => (r[0] || "").startsWith(name)) || [])[1] || "";
const OVERLAY = `let d = document.getElementById("recLabel");
  if (!d) { d = document.createElement("div"); d.id = "recLabel";
    d.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:2147483646;pointer-events:none;" +
      "padding:2px 8px;background:rgba(15,22,30,.82);color:#fff;font:500 11px/1.3 system-ui,sans-serif;" +
      "text-align:center;white-space:pre;overflow:hidden;text-overflow:ellipsis";
    document.body.append(d); }
  d.textContent = arguments[0]; return true;`;
const overlay = async (rows) => {
  const codec = cell(rows, "Video codecs").replace(/\s+\d+(\.\d+)?\/s\b.*$/, ""), dec = cell(rows, "AV1 decoder").split(",")[0].trim();
  const text = [[`${NAME}: FreeRDP Web, to the kit's macOS host`, codec, dec && `AV1 decoder: ${dec}`].filter(Boolean).join(" · "),
    [KIT, `${NAME} runs on the Mac it shows, so it sees itself`].filter(Boolean).join(" · ")].join("\n");
  await js(OVERLAY, text).catch((e) => info(`overlay: ${e.message}`));
};
const REC_SECONDS = Number(process.env.RECORD_SECONDS || SECONDS + 6);   // the session, then Info
// win: the browser's window, in screen points (WebDriver's rect), screenW: the screen's width in points
function recorder(win, screenW) {
  const dir = mkdtempSync(join(tmpdir(), `web-rec-${BROWSER}-`)), mov = join(dir, "screen.mov"), t0 = Date.now();
  // bash as its parent, as mac-host.sh runs it: the runner grants Screen Recording to /bin/bash
  const cap = spawn("/bin/bash", ["-c", `screencapture -x -V ${REC_SECONDS} '${mov}'`], { stdio: ["ignore", "ignore", "pipe"] });
  let capErr = ""; cap.stderr.on("data", (d) => { capErr += d; });
  const ended = new Promise((r) => cap.on("exit", (c) => r(c)));
  info(`recording the screen for ${REC_SECONDS} s (screencapture -V)`);
  let finished = null;
  // rate: the session's own N/s, from Info; the recording ends when screencapture does
  const finish = (rate = null) => finished ??= (async () => {
    const left = REC_SECONDS * 1000 - (Date.now() - t0);
    if (left < 2000) info(`Info came ${((Date.now() - t0) / 1000).toFixed(1)} s in: ${left < 0 ? "after" : "at"} the recording's end (RECORD_SECONDS)`);
    const code = await ended;
    let result = `no video (screencapture ${code}${capErr ? ": " + capErr.trim().slice(-200) : ""})`, fps = 0, n = 0, len = 0, avg = "";
    if (existsSync(mov)) {
      mkdirSync(dirname(RECORD), { recursive: true });
      // only the browser's window: the screen's points to the .mov's pixels (the display's backing
      // scale), so the clip and its distinct rate are the RDP session's, not the local media page's
      // (probe v2, run 45763573057: the window a small part of the screen)
      const [mw, mh] = String(spawnSync("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", mov],
        { encoding: "utf8" }).stdout || "").trim().split(",").map((v) => Number(v) || 0);
      let crop = "";
      if (win && screenW && mw && mh) {
        const k = mw / screenW, even = (v) => 2 * Math.floor(v / 2);
        const x = even(Math.max(0, win.x * k)), y = even(Math.max(0, win.y * k));
        const w = even(Math.min(win.width * k, mw - x)), h = even(Math.min(win.height * k, mh - y));
        if (w > 0 && h > 0) crop = `crop=${w}:${h}:${x}:${y},`;
        info(`crop: the window ${JSON.stringify(win)} on a ${screenW}-point screen, the .mov ${mw}x${mh} (scale ${k.toFixed(2)}): ${crop || "none"}`);
      } else info(`crop: none (window ${JSON.stringify(win)}, screen ${screenW}, .mov ${mw}x${mh})`);
      const ff = spawnSync("ffmpeg", ["-y", "-loglevel", "error", "-i", mov, "-vf", crop + "scale=1280:720:force_original_aspect_ratio=decrease:flags=lanczos,pad=1280:720:(ow-iw)/2:(oh-ih)/2,format=yuv420p",
        "-c:v", "libx264", "-crf", "28", "-preset", "slow", "-an", "-movflags", "+faststart", RECORD], { stdio: "inherit" });
      // the video's own rate: its average frame rate, and its frames over its length
      const pr = spawnSync("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=avg_frame_rate,nb_frames:format=duration", "-of", "json", RECORD], { encoding: "utf8" });
      try { const j = JSON.parse(pr.stdout); avg = j.streams[0].avg_frame_rate; n = Number(j.streams[0].nb_frames); len = Number(j.format.duration); } catch {}
      const [a, b] = String(avg).split("/").map(Number); const written = len ? n / len : b ? a / b : 0;
      // the rate that counts: DISTINCT pictures per second. screencapture may write frames at a fixed
      // rate, repeats included, which would make a slow screen look smooth (the product owner's rule:
      // the clip must not look faster or slower than the session); mpdecimate drops the repeats
      const md = spawnSync("ffmpeg", ["-loglevel", "error", "-i", mov, "-vf", crop + "mpdecimate", "-fps_mode", "vfr", "-f", "framemd5", "-"], { encoding: "utf8", maxBuffer: 64 << 20 });
      const distinct = String(md.stdout || "").split("\n").filter((l) => l && !l.startsWith("#")).length;
      fps = len ? distinct / len : 0;
      result = `${RECORD} (ffmpeg ${ff.status}): written ${written.toFixed(1)} fps (avg_frame_rate ${avg}, ${n} frames in ${len.toFixed(1)} s), distinct ${distinct} pictures`;
      // a poster from 70 %, a mid and a late frame (Info open)
      const base = RECORD.replace(/\.mp4$/, "");
      for (const [name, t] of [["", len * 0.7], ["-mid", len * 0.5], ["-late", Math.max(0, len - 1)]])
        spawnSync("ffmpeg", ["-y", "-loglevel", "error", "-ss", t.toFixed(2), "-i", RECORD, "-frames:v", "1", "-q:v", "4", `${base}${name}.jpg`], { stdio: "inherit" });
    }
    rmSync(dir, { recursive: true, force: true });
    info(`recorder: ${fps.toFixed(1)} distinct pictures/s, ${result}`);
    const f = fps.toFixed(1);
    console.log(`RECORD-VERDICT  ${BROWSER}: ${BROWSER === "safari" ? `record only (runner's dav1d): recorder ${f} fps, the session's ${rate ?? "unknown"}/s`
      : fps >= 15 ? `counts (recorder ${f} fps >= 15)`
      : rate != null && fps >= rate ? `counts (recorder ${f} fps >= the session's ${rate}/s)`
      : `does not count (recorder ${f} fps < 15, ${rate != null ? `< the session's ${rate}/s` : "the session's rate unknown"})`}`);
  })();
  return { finish };
}

// the macOS screen changes meanwhile: ScreenCaptureKit hands the server a frame only then
function motion() {
  if (process.platform !== "darwin") return;
  motionProcs.push(spawn("sh", ["-c", `for i in 1 2 3; do open -a Calculator; sleep 3; open -a "System Settings"; sleep 3;
    osascript -e 'quit app "Calculator"'; sleep 2; osascript -e 'quit app "System Settings"'; sleep 2; done`], { stdio: "ignore" }));
}

try {
  let up = false;
  for (let i = 0; i < 50 && !driverGone && !(up = await fetch(`http://127.0.0.1:${PORT}/status`).then((r) => r.ok, () => false)); i++) await sleep(200);
  if (!up) { check(`its WebDriver (${driverCmd[0]}) answers`, false, driverGone || driverLog.slice(-4).join(" | ") || "no answer in 10 s"); await done(1); }
  // Safari refuses a session for a while after the last one ended ("already paired"): try again
  for (let i = 0; i < 5 && !sid; i++) {
    try { sid = (await wd("POST", "/session", { capabilities: { alwaysMatch: capabilities } })).sessionId; }
    catch (e) { info(`no session yet: ${e.message.slice(0, 160)}`); await sleep(3000); }
  }
  if (!sid) { check("a WebDriver session", false); await done(1); }
  info(`browser ${await js("return navigator.userAgent")}`);
  // RECORD: the window on half the screen, in its middle, over the media page behind
  if (RECORD) {
    const [w, h] = JSON.parse(await js("return JSON.stringify([screen.availWidth, screen.availHeight])"));
    await wd("POST", `/session/${sid}/window/rect`, { x: Math.round(w / 4), y: Math.round(h / 4), width: Math.round(w / 2), height: Math.round(h / 2) })
      .catch((e) => info(`window rect: ${e.message}`));
    // the rect as the window took it, read back: what the recording is cropped to
    win = await wd("GET", `/session/${sid}/window/rect`).catch(() => null);
    screenW = Number(await js("return screen.width").catch(() => 0));
    info(`window ${JSON.stringify(win)} on a ${w}x${h} screen (${screenW} points wide)`);
  }

  const offset = logSize();
  const url = `${PAGE}?v=${GATEWAY}&u=${encodeURIComponent(USER)}&extra=${encodeURIComponent("/gfx:AV2:off,AV1:i420")}&fs=0`;
  await wd("POST", `/session/${sid}/url`, { url });
  const ready = await waitFor(async () => (await js("const s = document.getElementById('status'); return s ? s.textContent : null")) === "ready", 45000);
  const env = JSON.parse(await js("return JSON.stringify({ isolated: self.crossOriginIsolated, webcodecs: typeof VideoDecoder })"));
  // the browser's own answer for the configuration FreeRDP asks for (av1_webcodecs.js: av01.0.13M.08, 4:2:0)
  const support = await wd("POST", `/session/${sid}/execute/async`, { args: [], script: `const done = arguments[arguments.length - 1];
    if (typeof VideoDecoder !== "function") return done("no VideoDecoder");
    Promise.all(["no-preference", "prefer-hardware", "prefer-software"].map((h) => VideoDecoder.isConfigSupported({ codec: "av01.0.13M.08", hardwareAcceleration: h })
      .then((r) => h + " " + r.supported, (e) => h + " " + e.name))).then((a) => done(a.join(", ")));` }).catch((e) => e.message);
  info(`VideoDecoder.isConfigSupported(av01.0.13M.08): ${support}`);
  check("the page is ready, cross-origin isolated", ready && env.isolated, JSON.stringify(env));
  if (!ready) await done(1);
  await type("#pass", PASSWORD);
  await click("#go");
  const session = await waitFor(async () => js("return document.body.classList.contains('session') && !!document.getElementById('canvas').width"), 45000);
  check("a session started", session);
  if (!session) { info(`the page's log: ${(await js("const l = document.getElementById('log'); return l ? l.textContent.slice(-1500) : ''")).replace(/\n/g, " | ")}`); await done(1); }
  if (RECORD) {
    rec = recorder(win, screenW);
    // the overlay at once, then again from Info's rows every few seconds (whatever it has so far)
    await overlay([]);
    for (let t = 0; t < SECONDS * 1000; t += 3000) { await sleep(Math.min(3000, SECONDS * 1000 - t)); await overlay(JSON.parse(await js(ROWS).catch(() => "[]"))); }
  } else { motion(); await sleep(SECONDS * 1000); }
  // Info by a script click (Safari's WebDriver click on the edge toolbar opened nothing, probe run
  // 44986405343), then its rows
  await js("document.getElementById('tbInfo').click(); return true").catch((e) => info(`Info: ${e.message}`));
  if (!(await waitFor(async () => (await js("return document.querySelectorAll('#infoTable tr').length")) > 3, 10000))) info("Info shows no rows");
  await sleep(1500);
  const page = JSON.parse(await js(`
    const M = window.Module, cs = window.freerdpCodecStats, s = window.clientStats(), reg = M?.freerdpAv1;
    const r = cs && M && typeof M._freerdp_web_codec_stats === "function" ? cs.read(M.HEAPU8, M._freerdp_web_codec_stats()) : null;
    const rows = [...document.querySelectorAll("#infoTable tr")].map((tr) => [...tr.cells].map((c) => c.innerText.trim()));
    const log = document.getElementById("log") ? document.getElementById("log").textContent : "";
    return JSON.stringify({ stats: s, caps: r ? r[1] : null, rows,
      webcodecs: reg ? [...reg.decoders.values()].map((d) => ({ state: d.decoder ? d.decoder.state : null, profile: d.profile })) : null,
      decoderLines: log.split("\\n").filter((l) => /AV1 decoder:|using dav1d|needs dav1d|av1-webcodecs/.test(l)).slice(-6),
      log: log.slice(-20000) });`));
  if (rec) {
    // the clip ends on Info, its "AV1 decoder" row in view, the overlay from what Info said
    await overlay(page.rows);
    await js(`const r = [...document.querySelectorAll("#infoTable tr")].find((tr) => tr.cells[0] && tr.cells[0].innerText.trim() === "AV1 decoder");
      if (r) r.scrollIntoView({ block: "center" }); return !!r;`).catch(() => {});
    const vc = cell(page.rows, "Video codecs"), m = /(\d+(?:\.\d+)?)\/s\b/.exec(vc);
    info(`the session's rate: ${m ? m[1] + "/s" : "unknown"} (Info's Video codecs: "${vc}")`);
    await rec.finish(m ? Number(m[1]) : null);
  }
  // the session ends; the server's last encoder lines land in its log
  await wd("POST", `/session/${sid}/url`, { url: "about:blank" }).catch(() => {});
  for (const p of motionProcs) p.kill();
  await sleep(4000);
  if (OUT) {
    writeFileSync(join(OUT, `${BROWSER}-page.log`), page.log);
    writeFileSync(join(OUT, `${BROWSER}-info.txt`), page.rows.map((r) => r.join("\t")).join("\n") + "\n");
    writeFileSync(join(OUT, `${BROWSER}-stats.json`), JSON.stringify({ stats: page.stats, caps: page.caps, webcodecs: page.webcodecs }, null, 1));
  }
  const server = logFrom(offset);
  if (OUT) writeFileSync(join(OUT, `${BROWSER}-server.wlog`), server);

  // the server's side, this session only
  const confirm = server.match(/selected GFX caps \S+ \[0x[0-9a-f]+\] flags=.*/g) || [];
  check("the server confirms 4:4:4 off (FRDP_1, AV1_I444_DISABLED)",
    confirm.length > 0 && confirm.every((l) => /RDPGFX_CAPVERSION_FRDP_1 .*AV1_I444_DISABLED/.test(l)), confirm.at(-1)?.slice(0, 160) || "no caps confirm in its log");
  const enc = server.match(/AV1 \d+x\d+ I4[24][04]: \d+ frames in [^,]*/g) || [];
  check("the server encodes AV1 4:2:0 (its log: AV1 WxH I420), never I444",
    enc.some((l) => / I420: /.test(l)) && !enc.some((l) => / I444: /.test(l)), enc.at(-1) || "no AV1 encoder line (WLOG_LEVEL=DEBUG?)");

  // the page's side
  const st = page.stats || {};
  check("the page decoded AV1 pictures", (st.RDPGFX_CODECID_AV1_PICTURES || 0) > 0,
    `pictures ${st.RDPGFX_CODECID_AV1_PICTURES}, failed ${st.RDPGFX_CODECID_AV1_FAILED}, no picture ${st.RDPGFX_CODECID_AV1_NO_PICTURE}`);
  check("the decoder reads the stream as 4:2:0 (RDPGFX_CODECID_AV1_CHROMA 420)", st.RDPGFX_CODECID_AV1_CHROMA === 420, `chroma ${st.RDPGFX_CODECID_AV1_CHROMA}`);
  check("the confirmed caps are FRDP_1 (AV1, not AV2)", page.caps === 0x00010000, `caps 0x${(page.caps ?? 0).toString(16)}`);
  const row = (page.rows.find((r) => r[0] === "AV1 decoder") || [])[1] || "";
  const live = (page.webcodecs || []).filter((d) => d.state === "configured");
  const path = /^WebCodecs/.test(row) && live.length ? "WebCodecs" : /dav1d/.test(row) && !live.length ? "dav1d" : null;
  check("the page names its AV1 decoder, and the WebCodecs glue agrees", !!path,
    `Info "${row}", WebCodecs decoders ${JSON.stringify(page.webcodecs)}, FreeRDP: ${page.decoderLines.join(" / ")}`);
  if (path === "WebCodecs") check("WebCodecs is configured for AV1 4:2:0 (profile 0)", live.every((d) => d.profile === 0), JSON.stringify(live));
  console.log(`RESULT  ${BROWSER}: decoder path ${path || "unknown"} (AV1 4:2:0 in WebCodecs: ${support})`);
} catch (e) { check("the run", false, e.message); }
await done(fails ? 1 : 0);
