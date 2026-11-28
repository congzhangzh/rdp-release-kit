// FreeRDP Web decodes HEVC 4:2:0 through WebCodecs, from FreeRDP's shadow server on macOS
// encoding it with VideoToolbox (WITH_GFX_AZURE; freerdp-comp-hevc-g1, 2026-11-25): one session per
// browser through the browser's own WebDriver, against a server whose log this script reads.
// The plumbing is test/web-av1-i420.mjs's.
//
//   SERVER_LOG=<the server's wlog> node test/web-hevc.mjs <page url> <gateway host:port> <browser>
//
// <browser> is safari or chrome. The server runs with /gfx-hevc:i420. The page asks for HEVC as a
// user does, in Extra options: extra=/gfx:HEVC:i420,AVC420. That turns AV1, AV2 and H.264
// 4:4:4 off, so the client offers HEVC_ENABLE in the 11.x caps with AVC on: AVC420 stays as the
// fallback (AVC_DISABLED would say the page decodes no AVC at all), and the server's codec order
// puts HEVC first.
// Checks, for this browser's session only (its own slice of the server's log):
//  - the server confirms caps 11.2 or later with HEVC_ENABLE ("selected GFX caps ...",
//    shadow_client.c, INFO; the log names the flags without RDPGFX_CAPS_FLAG_)
//  - the server's frames kept going: no 5 s period with frames held and none sent ("gfx 5.0 s:
//    ... sent 0 ... held N", shadow_gfx_stats.c), which is the client acknowledging nothing
//  - the server's HEVC encoder ran ("VideoToolbox HEVC encoder: WxH ...", h264_videotoolbox.m, DEBUG:
//    the server must run with WLOG_LEVEL=DEBUG, as test/mac-host.sh starts it) and never failed
//    ("freerdp_hevc_compress failed")
//  - the page: HEVC 4:2:0 pictures decoded (RDPGFX_CODECID_HEVC420_PICTURES > 0) and none refused
//    (RDPGFX_CODECID_HEVC420_FAILED = 0)
// Env as test/web-av1-i420.mjs: CHROME, CHROMEDRIVER, SECONDS (default 25), OUT, PASSWORD.
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, openSync, readSync, fstatSync, closeSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [PAGE, GATEWAY, BROWSER] = process.argv.slice(2);
const { SERVER_LOG } = process.env;
if (!PAGE || !GATEWAY || !/^(safari|chrome)$/.test(BROWSER || "") || !SERVER_LOG) {
  console.error("usage: SERVER_LOG=<wlog> node web-hevc.mjs <page url> <gateway host:port> safari|chrome");
  process.exit(2);
}
const SECONDS = Number(process.env.SECONDS || 25), USER = process.env.USER_NAME || "probe", PASSWORD = process.env.PASSWORD || "probe";
const OUT = process.env.OUT || ""; if (OUT) mkdirSync(OUT, { recursive: true });
const PORT = { safari: 4474, chrome: 4475 }[BROWSER];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fails = 0;
const check = (name, ok, detail = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${BROWSER}: ${name}${detail ? "  (" + detail + ")" : ""}`); if (!ok) fails++; };
const info = (s) => console.log(`INFO  ${BROWSER}: ${s}`);

// the driver: the runner image's (macOS images set CHROMEWEBDRIVER to its folder)
const which = (name, env, dir) => process.env[env] || (process.env[dir] && existsSync(join(process.env[dir], name)) ? join(process.env[dir], name) : name);
const driverCmd = {
  safari: ["safaridriver", ["-p", String(PORT)]],
  chrome: [which("chromedriver", "CHROMEDRIVER", "CHROMEWEBDRIVER"), [`--port=${PORT}`]],
}[BROWSER];
const capabilities = {
  safari: { browserName: "safari" },
  chrome: { browserName: "chrome", "goog:chromeOptions": { args: ["--headless=new", "--no-first-run", "--no-default-browser-check", "--window-size=1280,800"],
    ...(process.env.CHROME ? { binary: process.env.CHROME } : {}) } },
}[BROWSER];

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
const done = async (code) => {
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

  const offset = logSize();
  const url = `${PAGE}?v=${GATEWAY}&u=${encodeURIComponent(USER)}&extra=${encodeURIComponent("/gfx:HEVC:i420,AVC420")}&fs=0`;
  await wd("POST", `/session/${sid}/url`, { url });
  const ready = await waitFor(async () => (await js("const s = document.getElementById('status'); return s ? s.textContent : null")) === "ready", 45000);
  const env = JSON.parse(await js("return JSON.stringify({ isolated: self.crossOriginIsolated, webcodecs: typeof VideoDecoder })"));
  // the browser's own answer for the configuration FreeRDP probes (h264_webcodecs.c: HEVC Main 3.1)
  const support = await wd("POST", `/session/${sid}/execute/async`, { args: [], script: `const done = arguments[arguments.length - 1];
    if (typeof VideoDecoder !== "function") return done("no VideoDecoder");
    Promise.all(["no-preference", "prefer-hardware", "prefer-software"].map((h) => VideoDecoder.isConfigSupported({ codec: "hvc1.1.6.L93.B0", hardwareAcceleration: h })
      .then((r) => h + " " + r.supported, (e) => h + " " + e.name))).then((a) => done(a.join(", ")));` }).catch((e) => e.message);
  info(`VideoDecoder.isConfigSupported(hvc1.1.6.L93.B0): ${support}`);
  check("the page is ready, cross-origin isolated", ready && env.isolated, JSON.stringify(env));
  if (!ready) await done(1);
  await type("#pass", PASSWORD);
  await click("#go");
  const session = await waitFor(async () => js("return document.body.classList.contains('session') && !!document.getElementById('canvas').width"), 45000);
  check("a session started", session);
  if (!session) { info(`the page's log: ${(await js("const l = document.getElementById('log'); return l ? l.textContent.slice(-1500) : ''")).replace(/\n/g, " | ")}`); await done(1); }
  motion();
  await sleep(SECONDS * 1000);
  // Info by a script click (Safari's WebDriver click on the edge toolbar opened nothing, probe run
  // 44986405343), then its rows
  await js("document.getElementById('tbInfo').click(); return true").catch((e) => info(`Info: ${e.message}`));
  if (!(await waitFor(async () => (await js("return document.querySelectorAll('#infoTable tr').length")) > 3, 10000))) info("Info shows no rows");
  await sleep(1500);
  const page = JSON.parse(await js(`
    const s = window.clientStats();
    const rows = [...document.querySelectorAll("#infoTable tr")].map((tr) => [...tr.cells].map((c) => c.innerText.trim()));
    const log = document.getElementById("log") ? document.getElementById("log").textContent : "";
    return JSON.stringify({ stats: s, rows,
      decoderLines: log.split("\\n").filter((l) => /HEVC|hvc1|WebCodecs/.test(l)).slice(-8), log: log.slice(-20000) });`));
  // the session ends; the server's last lines land in its log
  await wd("POST", `/session/${sid}/url`, { url: "about:blank" }).catch(() => {});
  for (const p of motionProcs) p.kill();
  await sleep(4000);
  if (OUT) {
    writeFileSync(join(OUT, `${BROWSER}-page.log`), page.log);
    writeFileSync(join(OUT, `${BROWSER}-info.txt`), page.rows.map((r) => r.join("\t")).join("\n") + "\n");
    writeFileSync(join(OUT, `${BROWSER}-stats.json`), JSON.stringify({ stats: page.stats }, null, 1));
  }
  const server = logFrom(offset);
  if (OUT) writeFileSync(join(OUT, `${BROWSER}-server.wlog`), server);

  // the server's side, this session only
  const confirm = server.match(/selected GFX caps \S+ \[0x[0-9a-f]+\] flags=.*/g) || [];
  // 11.2 (0x000b0200) or later, HEVC_ENABLE among the flags ({SCALEDMAP_DISABLE|HEVC_ENABLE})
  const hevcConfirm = (l) => {
    const v = /\[0x([0-9a-f]+)\]/.exec(l);
    return v && parseInt(v[1], 16) >= 0x000b0200 && /[{|]HEVC_ENABLE[|}]/.test(l);
  };
  check("the server confirms HEVC (caps 11.2 or later with HEVC_ENABLE)",
    confirm.length > 0 && confirm.every(hevcConfirm), confirm.at(-1)?.slice(0, 200) || "no caps confirm in its log");
  // a stalled session: a whole period with frames held and none sent
  const periods = server.match(/gfx \d+\.\d s: captured \d+[^\n]*/g) || [];
  const stalled = periods.filter((l) => /, sent 0 /.test(l) && /, held [1-9]/.test(l));
  check("the server's frames kept going (no period with frames held and none sent)", periods.length > 0 && stalled.length === 0,
    `${stalled.length} of ${periods.length} periods stalled${stalled.length ? ": " + stalled[0].slice(0, 160) : ""}`);
  // a session for the screen's size: the 256x256 one is FreeRDP's probe whether an encoder exists
  // (freerdp_codec_supported, at every connection), not this session's encoder
  const enc = (server.match(/VideoToolbox HEVC encoder: \d+x\d+[^\n]*/g) || []).filter((l) => !/: 256x256 /.test(l));
  check("the server's HEVC encoder ran for the screen (its log: VideoToolbox HEVC encoder: WxH ...)", enc.length > 0,
    enc.at(-1) || "no HEVC encoder line (WLOG_LEVEL=DEBUG?)");
  const encFailed = (server.match(/freerdp_hevc_compress failed|VideoToolbox HEVC encoder: frame failed/g) || []).length;
  check("the server's HEVC encoder never failed", encFailed === 0, `${encFailed} failures`);

  // the page's side
  const st = page.stats || {};
  const pictures = st.RDPGFX_CODECID_HEVC420_PICTURES || 0, failed = st.RDPGFX_CODECID_HEVC420_FAILED;
  check("the page decoded HEVC 4:2:0 pictures", pictures > 0,
    `pictures ${pictures}, failed ${failed}, no picture ${st.RDPGFX_CODECID_HEVC420_NO_PICTURE}, commands ${st.RDPGFX_CODECID_HEVC420}`);
  check("the page refused no HEVC picture (RDPGFX_CODECID_HEVC420_FAILED 0)", failed === 0, `failed ${failed}`);
  if (page.decoderLines.length) info(`the page's log: ${page.decoderLines.join(" / ")}`);
  console.log(`RESULT  ${BROWSER}: HEVC 4:2:0 pictures ${pictures}, failed ${failed} (WebCodecs HEVC: ${support})`);
} catch (e) { check("the run", false, e.message); }
await done(fails ? 1 : 0);
