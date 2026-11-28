// web-camera.mjs <page url> <gateway host:port> <out dir> <done file>: FreeRDP Web's camera, as a
// user turns it on, in headless Chrome (or Edge) with Chrome's fake camera (CI only).
//
// Opens the page, waits for the client, reads what the page says about the camera (the checkbox,
// its reason line, the browser's H.264 encoder), ticks Camera (the browser's permission prompt is
// answered by --use-fake-ui-for-media-stream), connects with a synthetic user, then records the
// camera's counters (Module.freerdpCameraStats) every second until <done file> exists (the server
// side's reader finished) and 6 s more (the client releases the camera after 2 s without sample
// requests). Writes <out dir>/page.log, stats.jsonl, camera.json, page.png.
//
// CHROME=<binary> (default google-chrome); CHROME_FLAGS=<more flags>; CDP_PORT (default 9348);
// WEB_USER, WEB_PASS: the account (default camera/camera, a server without authentication); the
// password comes through the environment only, never a command line or a log.
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync, appendFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const [url, gateway, out, doneFile] = process.argv.slice(2);
const port = process.env.CDP_PORT || "9348";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const profile = mkdtempSync(join(tmpdir(), "web-camera-"));
const chrome = spawn(process.env.CHROME || "google-chrome", ["--headless=new", `--remote-debugging-port=${port}`,
  `--user-data-dir=${profile}`, "--no-first-run", "--window-size=1280,900", "--mute-audio",
  "--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream", "--enable-unsafe-swiftshader",
  ...(process.env.CHROME_FLAGS ? process.env.CHROME_FLAGS.split(" ") : []), "about:blank"], { stdio: "ignore" });
const result = { url };
const finish = (code) => {
  writeFileSync(join(out, "camera.json"), JSON.stringify(result, null, 1) + "\n");
  console.log(JSON.stringify(result));
  chrome.once("exit", () => { rmSync(profile, { recursive: true, force: true }); process.exit(code); });
  chrome.kill();
};

let target;
for (let i = 0; i < 150 && !target; i++) {
  await sleep(200);
  try { target = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((t) => t.type === "page"); } catch {}
}
if (!target) { result.error = "no browser"; finish(1); }
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r));
let id = 0; const pending = new Map(); const logs = [];
ws.addEventListener("message", (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); }
  if (m.method === "Runtime.consoleAPICalled") logs.push(m.params.args.map((a) => a.value).join(" "));
  if (m.method === "Log.entryAdded") logs.push(`[browser ${m.params.entry.source}] ${m.params.entry.text}`);
});
const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expression, awaitPromise = false) =>
  (await send("Runtime.evaluate", { expression, returnByValue: true, userGesture: true, awaitPromise }))?.result?.value;
const pageLog = async () => (await ev("document.getElementById('log')?.textContent ?? ''")) || "";
const save = async () => writeFileSync(join(out, "page.log"), (await pageLog()) + "\n--- console ---\n" + logs.join("\n"));
// a real click: the page's own user activation
const click = async (elementId) => {
  const at = JSON.parse(await ev(`(() => { const b = document.getElementById(${JSON.stringify(elementId)}); b.scrollIntoView({ block: "center" });
    const r = b.getBoundingClientRect(); return JSON.stringify({ x: r.left + r.width / 2, y: r.top + r.height / 2 }); })()`));
  for (const type of ["mouseMoved", "mousePressed", "mouseReleased"])
    await send("Input.dispatchMouseEvent", { type, x: at.x, y: at.y, button: type === "mouseMoved" ? "none" : "left", clickCount: 1 });
};

await send("Runtime.enable"); await send("Page.enable"); await send("Log.enable");
await send("Page.navigate", { url });
let isolated = false;
for (let i = 0; i < 100 && !isolated; i++) {
  await sleep(300);
  isolated = await ev("self.crossOriginIsolated === true");
  if (!isolated && i === 49) await send("Page.reload");
}
result.isolated = isolated;
let ready = false;
for (let i = 0; i < 200 && isolated && !ready; i++) {
  await sleep(300);
  ready = await ev("document.getElementById('status')?.textContent === 'ready' && !document.getElementById('go')?.disabled");
}
result.ready = ready;
if (!ready) { await save(); finish(1); }

// the page's camera state, once it knows the browser's H.264 encoder
for (let i = 0; i < 50; i++) {
  if (/H\.264 encoding for the camera: /.test(await pageLog())) break;
  await sleep(200);
}
result.browser = await ev("navigator.userAgent");
result.secureContext = await ev("window.isSecureContext");
result.h264Line = ((await pageLog()).match(/\[page\] H\.264 encoding for the camera: \w+/) || [""])[0];
result.encoderSupport = await ev(`(async () => { try { return (await VideoEncoder.isConfigSupported({ codec: "avc1.42E01E",
  width: 640, height: 480, bitrate: 1000000, framerate: 30, latencyMode: "realtime", avc: { format: "avc" } })).supported; }
  catch (e) { return "error: " + e; } })()`, true);
result.checkboxDisabled = await ev("document.getElementById('optCamera').disabled");
result.checkboxTitle = await ev("document.getElementById('optCamera').parentElement.title");
result.reasonLine = await ev("document.getElementById('cameraReason').hidden ? '' : document.getElementById('cameraReason').textContent");
if (result.checkboxDisabled) { await save(); finish(1); }

// Camera: the settings panel open, the box ticked, the browser asked once
await ev("document.getElementById('sessionPanel').open = true; true");
await click("optCamera");
for (let i = 0; i < 50; i++) {
  if (/\[page\] camera (allowed|refused)/.test(await pageLog())) break;
  await sleep(200);
}
result.permission = ((await pageLog()).match(/\[page\] camera (allowed|refused[^\n]*)/) || ["", "no answer"])[1];
result.ticked = await ev("document.getElementById('optCamera').checked");
result.preview = await ev("document.getElementById('preview')?.textContent ?? ''");
if (!result.ticked) { await save(); finish(1); }

const account = { user: process.env.WEB_USER || "camera", pass: process.env.WEB_PASS || "camera" };
const fill = `document.getElementById('host').value = ${JSON.stringify(gateway)};
              document.getElementById('user').value = ${JSON.stringify(account.user)};
              document.getElementById('pass').value = ${JSON.stringify(account.pass)}; true`;
const held = `document.getElementById('host').value === ${JSON.stringify(gateway)} &&
              document.getElementById('pass').value === ${JSON.stringify(account.pass)}`;
for (let i = 0; i < 5; i++) { await ev(fill); await sleep(1000); if (await ev(held)) break; }
await click("go");
const t0 = Date.now();
result.connectAt = new Date(t0).toISOString();

// the counters, every second, until the reader is done (at most 4 minutes)
let after = 0;
while (Date.now() - t0 < 240000) {
  await sleep(1000);
  const s = await ev("JSON.stringify(globalThis.Module?.freerdpCameraStats ?? {})");
  appendFileSync(join(out, "stats.jsonl"), JSON.stringify({ t: Date.now() - t0, stats: JSON.parse(s || "{}") }) + "\n");
  // the page's log so far, for the server side's script (the client's stop lines)
  writeFileSync(join(out, "page-live.log"), await pageLog());
  if (existsSync(doneFile) && ++after >= 6) break;
}
result.stats = JSON.parse((await ev("JSON.stringify(globalThis.Module?.freerdpCameraStats ?? {})")) || "{}");
result.cameras = await ev("JSON.stringify(globalThis.Module?.freerdpCameras ?? null)");
const shot = await send("Page.captureScreenshot", { format: "png" });
writeFileSync(join(out, "page.png"), Buffer.from(shot.data, "base64"));
await save();
finish(0);
