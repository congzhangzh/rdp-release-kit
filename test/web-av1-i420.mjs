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
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, openSync, readSync, fstatSync, closeSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";

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
  // branch only (web-safari-av1-diag): record the WebCodecs glue's decoders in the page's own world
  const DIAG = readFileSync(new URL("./av1-diag.js", import.meta.url), "utf8");
  info(`diagnosis injected: ${await js("const s = document.createElement('script'); s.textContent = arguments[0]; document.head.appendChild(s); return !!window.__av1diag", DIAG).catch((e) => e.message)}`);
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
    const M = window.Module, cs = window.freerdpCodecStats, s = window.clientStats(), reg = M?.freerdpAv1;
    const r = cs && M && typeof M._freerdp_web_codec_stats === "function" ? cs.read(M.HEAPU8, M._freerdp_web_codec_stats()) : null;
    const rows = [...document.querySelectorAll("#infoTable tr")].map((tr) => [...tr.cells].map((c) => c.innerText.trim()));
    const log = document.getElementById("log") ? document.getElementById("log").textContent : "";
    return JSON.stringify({ stats: s, caps: r ? r[1] : null, rows,
      webcodecs: reg ? [...reg.decoders.values()].map((d) => ({ state: d.decoder ? d.decoder.state : null, profile: d.profile })) : null,
      decoderLines: log.split("\\n").filter((l) => /AV1 decoder:|using dav1d|needs dav1d|av1-webcodecs/.test(l)).slice(-6),
      log: log.slice(-20000) });`));
  // branch only: the diagnosis, then the first key chunk again in other configurations
  const diag = JSON.parse(await js("const D = window.__av1diag; return JSON.stringify(D ? { console: D.console, uncaught: D.uncaught, decoders: D.decoders, firstKey: D.firstKey } : null)").catch((e) => JSON.stringify({ failed: e.message })));
  await wd("POST", `/session/${sid}/timeouts`, { script: 180000 }).catch(() => {});
  const base = { codec: "av01.0.13M.08" };
  const replayConfigs = [
    { ...base, optimizeForLatency: true, hardwareAcceleration: "no-preference" }, // FreeRDP's own
    { ...base },
    { ...base, hardwareAcceleration: "prefer-software" },
    { ...base, hardwareAcceleration: "prefer-hardware" },
    { ...base, optimizeForLatency: false },
    { ...base, codedWidth: 1600, codedHeight: 900 },
    { codec: "av01.0.08M.08" }, { codec: "av01.0.12M.08" }, { codec: "av01.0.13H.08" },
  ];
  const replay = await wd("POST", `/session/${sid}/execute/async`, { args: [replayConfigs], script: `const done = arguments[arguments.length - 1];
    if (!window.__av1diagReplay) return done("no replay");
    window.__av1diagReplay(arguments[0]).then((r) => done(JSON.stringify(r)), (e) => done("replay failed: " + e));` }).catch((e) => e.message);
  if (diag && diag.decoders) {
    for (const d of diag.decoders)
      info(`diag decoder ${d.id}: configs ${JSON.stringify(d.configs)}; chunks ${d.chunks}, outputs ${d.outputs}; errors ${JSON.stringify(d.errors)}; first chunks ${JSON.stringify(d.firstChunks.map(({ head, ...c }) => c))}; frames ${JSON.stringify(d.frames.slice(0, 1))}`);
    for (const l of diag.console.filter((l) => /av1|webcodecs|VideoDecoder|decod/i.test(l)).slice(0, 12)) info(`diag console: ${l}`);
    for (const l of diag.uncaught.slice(0, 6)) info(`diag uncaught: ${l}`);
  } else info(`diag: ${JSON.stringify(diag)}`);
  info(`diag replay of the first key chunk (${diag?.firstKey?.bytes ?? 0} bytes): ${replay}`);
  if (OUT) {
    writeFileSync(join(OUT, `${BROWSER}-av1diag.json`), JSON.stringify({ ...diag, firstKey: diag?.firstKey ? { bytes: diag.firstKey.bytes } : null, replay }, null, 1));
    if (diag?.firstKey) writeFileSync(join(OUT, `${BROWSER}-firstkey.obu`), Buffer.from(diag.firstKey.b64, "base64"));
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
