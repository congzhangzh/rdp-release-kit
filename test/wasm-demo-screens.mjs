// Records the All screens demo of the web client: two screens side by side,
// as the user sees them. Headless Chrome has no second screen, so the page is
// told of two (?screens=, each 960 x 1080, the page on the left one); the
// page's window and the window All screens opens for the second screen are
// each captured by Chrome's screencast, and ffmpeg puts them next to each
// other in one 1920 x 1080 video, the second screen dark until its window
// opens. Run it through wasm-session.sh with DEMO_VIDEO=<file.mp4> and
// DEMO_SCREENS=1, which provides the throwaway server (SERVER=xrdp-gnome:
// GNOME on Wayland through the xrdp preview); everything shown is synthetic.
//
//   node wasm-demo-screens.mjs <page url> <gateway host:port> <user> <password> <out dir> <video.mp4>
//
// The visit: the form, Connect, a terminal on GNOME, All screens -> Separate
// screens (GNOME gets a monitor per screen, this window's the primary, and
// the terminal stays there), Super+Shift+Right moves the terminal to the
// second screen, the overview, closing the second window (one screen
// again), Disconnect. No sound: the web video is the other demos' part.
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const [url, gateway, user, password, out, video] = process.argv.slice(2);
const W = 960, H = 1080;   // each screen; the video is both, 1920 x 1080
const LABEL = process.env.DEMO_LABEL || "xrdp preview + GNOME Wayland, All screens";
const sleep = ms => new Promise(r => setTimeout(r, ms));
const marks = [];   // what happened when (epoch s, as the screencast's timestamps), for the log
const mark = what => marks.push([Date.now() / 1000, what]);
const profile = mkdtempSync(join(tmpdir(), "wasm-demo-"));
const frames = join(out, "demo-frames");
rmSync(frames, { recursive: true, force: true }); mkdirSync(frames, { recursive: true });
const chrome = spawn("google-chrome", ["--headless=new", "--remote-debugging-port=9348",
  `--user-data-dir=${profile}`, "--no-first-run", `--window-size=${W},${H}`, "--hide-scrollbars",
  "--mute-audio", "--enable-unsafe-swiftshader", "about:blank"], { stdio: "ignore" });
const done = code => {
  chrome.once("exit", () => { rmSync(profile, { recursive: true, force: true }); process.exit(code); });
  chrome.kill();
};
const targets = async () => (await (await fetch("http://127.0.0.1:9348/json")).json()).filter(t => t.type === "page");

// one window over the DevTools protocol; its screencast frames go to frames/<name>-NNNNN.jpg
// with the time each was shown
async function attach(wsUrl, name) {
  const ws = new WebSocket(wsUrl);
  await new Promise(r => ws.addEventListener("open", r));
  let id = 0; const pending = new Map(); const shots = []; const logs = [];
  const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  ws.addEventListener("message", e => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); }
    if (m.method === "Runtime.consoleAPICalled") logs.push(m.params.args.map(a => a.value).join(" "));
    if (m.method === "Page.screencastFrame") {
      const file = join(frames, `${name}-${String(shots.length).padStart(5, "0")}.jpg`);
      writeFileSync(file, Buffer.from(m.params.data, "base64"));
      shots.push({ file, t: m.params.metadata.timestamp });
      send("Page.screencastFrameAck", { sessionId: m.params.sessionId });
    }
  });
  const ev = async expression => (await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true, userGesture: true }))?.result?.value;
  await send("Runtime.enable"); await send("Page.enable");
  await send("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: 1, mobile: false });
  const record = () => send("Page.startScreencast", { format: "jpeg", quality: 88, maxWidth: W, maxHeight: H, everyNthFrame: 1 });
  return { ws, send, ev, shots, logs, record };
}

let target;
for (let i = 0; i < 150 && !target; i++) { await sleep(200); try { target = (await targets())[0]; } catch {} }
const main = await attach(target.webSocketDebuggerUrl, "a");
const { send, ev } = main;

// the pointer and the caption, as wasm-demo.mjs lays them over the page (only in this recording);
// LABELLED: the corner label too (the page's window only)
const OVERLAY = labelled => `(() => {
  if (document.getElementById("demoCursor")) return true;
  const NS = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(NS, "svg"); svg.id = "demoCursor";
  svg.setAttribute("width", "24"); svg.setAttribute("height", "24"); svg.setAttribute("viewBox", "0 0 24 24");
  svg.style.cssText = "position:fixed;left:0;top:0;z-index:2147483647;pointer-events:none;filter:drop-shadow(0 1px 2px rgba(0,0,0,.5))";
  const p = document.createElementNS(NS, "path");
  p.setAttribute("d", "M3 2 L3 19 L8 14.5 L11.5 22 L14.5 20.7 L11 13.3 L17.5 13.3 Z");
  p.setAttribute("fill", "#fff"); p.setAttribute("stroke", "#111"); p.setAttribute("stroke-width", "1.3");
  svg.append(p); document.body.append(svg);
  const cap = document.createElement("div"); cap.id = "demoCaption";
  cap.style.cssText = "position:fixed;left:50%;bottom:28px;transform:translateX(-50%);z-index:2147483646;pointer-events:none;" +
    "width:86vw;padding:10px 18px;border-radius:8px;background:rgba(15,22,30,.88);color:#fff;box-sizing:border-box;" +
    "font:500 22px/1.35 system-ui,sans-serif;text-align:center;transition:opacity .25s;opacity:0";
  document.body.append(cap);
  if (${labelled}) {
    const tag = document.createElement("div"); tag.id = "demoLabel";
    tag.style.cssText = "position:fixed;right:18px;top:18px;z-index:2147483646;pointer-events:none;padding:6px 12px;" +
      "border-radius:6px;background:rgba(47,111,222,.92);color:#fff;font:600 16px/1.3 system-ui,sans-serif";
    tag.textContent = ${JSON.stringify(LABEL)};
    document.body.append(tag);
  }
  // a screencast gets a frame only when the window is composited again, so a window that
  // stops changing keeps whatever frame came last, often one from the middle of an animation:
  // a pixel nobody sees changes ten times a second, and every window keeps sending frames
  const tick = document.createElement("div");
  tick.style.cssText = "position:fixed;left:0;top:0;width:1px;height:1px;background:#000;opacity:.01;pointer-events:none";
  document.body.append(tick);
  setInterval(() => { tick.style.opacity = tick.style.opacity === "0.01" ? "0.02" : "0.01"; }, 100);
  const xy = window.__demoXY ||= { x: innerWidth * 0.6, y: innerHeight * 0.55 };
  svg.style.transform = "translate(" + xy.x + "px," + xy.y + "px)";
  window.__demoMove = (x, y, ms) => new Promise(done => {
    const from = { ...xy }, t0 = performance.now();
    const step = now => {
      const k = Math.min(1, (now - t0) / ms), e = k < .5 ? 2 * k * k : 1 - (-2 * k + 2) ** 2 / 2;
      xy.x = from.x + (x - from.x) * e; xy.y = from.y + (y - from.y) * e;
      svg.style.transform = "translate(" + xy.x + "px," + xy.y + "px)";
      k < 1 ? requestAnimationFrame(step) : done(true);
    };
    requestAnimationFrame(step);
  });
  window.__demoCaption = text => { cap.textContent = text; cap.style.opacity = text ? "1" : "0"; return true; };
  return true;
})()`;
const caption = text => (mark(text), ev(`window.__demoCaption(${JSON.stringify(text)})`));
const center = async (w, sel) => w.ev(`(() => { const r = document.querySelector(${JSON.stringify(sel)}).getBoundingClientRect();
  return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) }; })()`);
async function click(w, x, y) {
  await w.ev(`window.__demoMove(${x}, ${y}, 700)`);
  await w.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
  await w.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 });
  await sleep(90);
  await w.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 });
}
const clickOn = async (w, sel) => { const c = await center(w, sel); await click(w, c.x, c.y); };
async function typeInPage(text, ms = 85) {
  for (const ch of text) { await send("Input.insertText", { text: ch }); await sleep(ms); }
}
// into the remote desktop: real key events, which the client reads by their code
const KEYS = {
  Super: { key: "Meta", code: "MetaLeft", vk: 91, mod: 4 }, Shift: { key: "Shift", code: "ShiftLeft", vk: 16, mod: 8 },
  Right: { key: "ArrowRight", code: "ArrowRight", vk: 39 }, Enter: { key: "Enter", code: "Enter", vk: 13, text: "\r" },
};
function key(ch) {
  if (ch === "\n") return KEYS.Enter;
  if (ch === " ") return { key: " ", code: "Space", vk: 32, text: " " };
  if (/[a-z]/.test(ch)) return { key: ch, code: "Key" + ch.toUpperCase(), vk: ch.toUpperCase().charCodeAt(0), text: ch };
  if (/[0-9]/.test(ch)) return { key: ch, code: "Digit" + ch, vk: ch.charCodeAt(0), text: ch };
  return { "-": { key: "-", code: "Minus", vk: 189, text: "-" }, ".": { key: ".", code: "Period", vk: 190, text: "." } }[ch];
}
async function typeRemote(text, ms = 110) {
  for (const ch of text) {
    const k = key(ch);
    await send("Input.dispatchKeyEvent", { type: k.text ? "keyDown" : "rawKeyDown", key: k.key, code: k.code, windowsVirtualKeyCode: k.vk, text: k.text });
    await send("Input.dispatchKeyEvent", { type: "keyUp", key: k.key, code: k.code, windowsVirtualKeyCode: k.vk });
    await sleep(ms);
  }
}
// a chord, e.g. Super+Shift+Right: each key down in turn, then up in reverse
async function chord(...names) {
  let mods = 0;
  for (const n of names) {
    const k = KEYS[n]; mods |= k.mod ?? 0;
    await send("Input.dispatchKeyEvent", { type: "rawKeyDown", key: k.key, code: k.code, windowsVirtualKeyCode: k.vk, modifiers: mods });
    await sleep(80);
  }
  for (const n of [...names].reverse()) {
    const k = KEYS[n]; mods &= ~(k.mod ?? 0);
    await send("Input.dispatchKeyEvent", { type: "keyUp", key: k.key, code: k.code, windowsVirtualKeyCode: k.vk, modifiers: mods });
    await sleep(80);
  }
}
async function load() {   // (re)loaded page: wait for isolation and the client, then lay the overlays on it
  let isolated = false;
  for (let i = 0; i < 100 && !isolated; i++) { await sleep(300); isolated = await ev("self.crossOriginIsolated === true"); }
  let ready = false;
  for (let i = 0; i < 200 && !ready; i++) { await sleep(300); ready = await ev("document.getElementById('status')?.textContent === 'ready'"); }
  await ev(OVERLAY(true));
  return isolated && ready;
}

const page = new URL(url);
page.searchParams.set("screens", `${W}x${H}+0+0,${W}x${H}+${W}+0`);
await send("Page.navigate", { url: page.href });
if (!await load()) { console.log("the page did not get ready"); done(1); }
await ev(`document.getElementById('host').value = ${JSON.stringify(gateway)}; true`);
await main.record();
await sleep(600);

// 1. two screens, the page on the left one
await caption("FreeRDP Web on a computer with two screens: the page on the left one");
await sleep(3200);
await clickOn(main, "#user"); await typeInPage(user);
await clickOn(main, "#pass"); await typeInPage(password, 70);
await sleep(500);
await caption("Connect");
await clickOn(main, "#go");
let rx = 0;
for (let i = 0; i < 80 && rx < 300000; i++) { await sleep(500); rx = await ev("window.freerdpNet?.rx ?? 0"); }
await caption("GNOME on Wayland through the xrdp preview, on one screen");
await sleep(7000);
for (let i = 0; i < 30; i++) {   // the offer to keep the password with a passkey: not now
  if (await ev("(b => !!b && b.offsetParent !== null)(document.getElementById('saveLater'))")) {
    await clickOn(main, "#saveLater");
    await sleep(800);
    break;
  }
  await sleep(500);
}

// 2. a terminal, on the one screen there is (GNOME starts in the overview: typing searches)
await ev("document.getElementById('canvas').focus(), true");
await caption("A terminal, started from GNOME's search");
await typeRemote("terminal\n");
await sleep(4000);
await typeRemote("echo one desktop on two screens\n");
await sleep(1500);
const shot = await send("Page.captureScreenshot", { format: "png" });   // for wasm-session.sh's checks
writeFileSync(join(out, "wasm-session.png"), Buffer.from(shot.data, "base64"));
writeFileSync(join(out, "canvas.json"), JSON.stringify(await ev(`(() => {
  const r = document.getElementById('canvas').getBoundingClientRect(), d = window.devicePixelRatio || 1;
  return { x: Math.round(r.left * d), y: Math.round(r.top * d), w: Math.round(r.width * d), h: Math.round(r.height * d),
           rx: window.freerdpNet?.rx ?? 0 }; })()`)));

// 3. All screens, Separate screens: a window for the right screen
await caption("All screens: the remote desktop on every screen");
await clickOn(main, "#tbScreens");
await sleep(1200);
await caption("Separate screens: GNOME gets a monitor for each, this one the primary");
await sleep(1800);
await clickOn(main, "#screensMenu [data-mode=separate]");
let popup;
for (let i = 0; i < 50 && !popup; i++) { await sleep(200); popup = (await targets()).find(t => t.url.includes("screen.html")); }
if (!popup) { console.log("no window opened for the second screen"); done(1); }
mark("the second window opened");
const second = await attach(popup.webSocketDebuggerUrl, "b");
await second.record();
await second.ev(OVERLAY(false));
// not clicked: its first click asks for full screen, which headless Chrome, with screens
// that are only emulated, gives at the origin, so the window would show the wrong part
await second.ev(`window.__demoMove(${W / 2}, ${H / 2}, 10)`);
await second.ev(`window.__demoCaption("The second screen's window: GNOME's other monitor")`);
await sleep(4000);
await second.ev("window.__demoCaption('')");
await caption("The terminal stays on this screen, GNOME's primary");
await sleep(3500);

// 4. the terminal to the other screen, the overview over both
await caption("Super+Shift+Right moves it to the other screen");
await ev("document.getElementById('canvas').focus(), true");
await sleep(1200);
mark("Super+Shift+Right"); await chord("Super", "Shift", "Right");
await sleep(1200);
await second.ev(`window.__demoCaption("Moved here, the right screen")`);
await sleep(3000);
await second.ev("window.__demoCaption('')");
await caption("The overview: GNOME spans both screens");
await chord("Super");
await sleep(4500);
await chord("Super");
await sleep(1500);

// 5. one screen again, then disconnect
await caption("Closing the second window: one screen again");
await second.send("Page.stopScreencast");
const closed = Date.now() / 1000; mark("the second window closes");
await second.ev("window.close()").catch(() => {});
second.ws.close();
await sleep(5000);
writeFileSync(join(out, "page.log"),
  (await ev("document.getElementById('log')?.textContent ?? ''")) + "\n--- console ---\n" + main.logs.join("\n"));
await caption("Disconnect ends the session");
await sleep(1200);
await clickOn(main, "#tbQuit");
await sleep(1500);
await load();
await caption("FreeRDP Web: github.com/congzhangzh/freerdp-web");
await sleep(3000);
await send("Page.stopScreencast");
const ended = Date.now() / 1000;

// each window's frames, each as long as it was on screen; the second starts when its window
// opened and ended when it closed. A screencast sends a frame only when the window changes, so
// the last one stays until the window's end
const concat = (shots, name, end) => {
  writeFileSync(join(frames, `${name}.txt`), shots.map((s, i) => `file '${s.file}'\nduration ${(Math.max((shots[i + 1]?.t ?? end) - s.t, 0.001)).toFixed(3)}`).join("\n")
    + `\nfile '${shots.at(-1).file}'\n`);
  return ["-f", "concat", "-safe", "0", "-i", join(frames, `${name}.txt`)];
};
const a = main.shots, b = second.shots;
if (!b.length) { console.log("the second screen's window sent no frame"); done(1); }
const offset = (b[0].t - a[0].t).toFixed(3), length = (ended - a[0].t).toFixed(3);
// the log: the events and the frames' times, from the first frame
const rel = t => (t - a[0].t).toFixed(2);
const gaps = (shots, n) => shots.flatMap((s, i) => i && s.t - shots[i - 1].t > 2 ? [`${n} no frame ${rel(shots[i - 1].t)}..${rel(s.t)}`] : []);
console.log(["timeline (s from the first frame):", ...marks.map(([t, w]) => `${rel(t)} ${w}`),
  `a ${rel(a[0].t)}..${rel(a.at(-1).t)}, b ${rel(b[0].t)}..${rel(b.at(-1).t)}`, ...gaps(a, "a"), ...gaps(b, "b")].join("\n  "));
// side by side on a dark desk, a bezel between the screens
const ff = spawnSync("ffmpeg", ["-y", "-loglevel", "error", ...concat(a, "a", ended), ...concat(b, "b", closed),
  "-filter_complex", `color=c=0x101418:s=${2 * W}x${H}:r=30:d=${length}[desk];` +
    `[0:v]fps=30,scale=${W}:${H}:flags=lanczos[s1];` +
    `[1:v]fps=30,scale=${W}:${H}:flags=lanczos,setpts=PTS-STARTPTS+${offset}/TB[s2];` +
    `[desk][s1]overlay=0:0:eof_action=repeat[one];[one][s2]overlay=${W}:0:eof_action=pass,` +
    `drawbox=x=${W - 2}:y=0:w=4:h=${H}:color=0x101418:t=fill,format=yuv420p[v]`,
  "-map", "[v]", "-t", length, "-c:v", "libx264", "-crf", "22", "-preset", "slow", "-movflags", "+faststart", video],
  { stdio: "inherit" });
console.log(`demo: ${a.length} + ${b.length} frames, ${length} s, the second screen from ${offset} s -> ${video} (ffmpeg ${ff.status})`);
rmSync(frames, { recursive: true, force: true });
done(ff.status === 0 ? 0 : 1);
