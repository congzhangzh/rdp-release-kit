// Records a demo of the web client, as a user sees it: headless Chrome plays a
// visit (with a visible pointer and short captions laid over the page),
// Chrome's screencast captures it and ffmpeg makes an MP4. Run it through
// wasm-session.sh with DEMO_VIDEO=<file.mp4>, which provides the throwaway
// server; everything shown is synthetic.
//
//   node wasm-demo.mjs <page url> <gateway host:port> <user> <password> <out dir> <video.mp4>
//
// The visit: the page and its safety notice, the one-line SSH command, the
// form, the session settings, Connect, typing in a terminal on the remote
// desktop, then, in Firefox there, web video with sound (Big Buck Bunny) next
// to a WebGL scene (the WebGL Aquarium), started by typing "webdemo", the Info
// panel, Disconnect. On GNOME, the terminal is started from the search, as a
// user would. DEMO_LABEL names the remote desktop in a corner label.
//
// Sound: the page plays the session's sound with Web Audio; for the recording
// only, everything it sends to the speakers is also copied to a MediaRecorder,
// and that track joins the video at its measured offset. No clipboard
// permission is granted, so the page never touches a real clipboard.
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const [url, gateway, user, password, out, video] = process.argv.slice(2);
const W = 1920, H = 1080;
// wasm-session.sh's server: xrdp (Xfce), gnome (gnome-remote-desktop) or xrdp-gnome
// (GNOME through the xrdp preview, in AV1); both GNOMEs start in the overview
const XRDP_GNOME = process.env.SERVER === "xrdp-gnome";
const XRDP_KDE = process.env.SERVER === "xrdp-kde";   // KDE Plasma through the xrdp preview, in AV1
const GNOME = process.env.SERVER === "gnome" || XRDP_GNOME;
// windows: the Windows host (FreeRDP's shadow server) on a Windows runner, the
// gateway websockify on the same PC (test/windows-host.ps1); CHROME=<binary>
const WINDOWS = process.env.SERVER === "windows";
const LABEL = process.env.DEMO_LABEL ||
  (WINDOWS ? "FreeRDP shadow server on Windows, AV1"
    : XRDP_GNOME ? "xrdp preview + GNOME 51 Wayland, AV1"
    : XRDP_KDE ? "xrdp preview + KDE Plasma 6 Wayland, AV1"
    : GNOME ? "gnome-remote-desktop + GNOME Wayland" : "xrdp + Xfce");
const sleep = ms => new Promise(r => setTimeout(r, ms));
// What the server says it encodes (DEMO_CODEC_CMD, from wasm-session.sh): the
// last line of xrdp's AV1 encoder, e.g. "encoder for 1896x1056 (… 4:4:4,
// cpu-used 10 …)", as a caption's tail; empty without one
const serverCodec = () => {
  if (!process.env.DEMO_CODEC_CMD) return "";
  const r = spawnSync("sh", ["-c", process.env.DEMO_CODEC_CMD], { encoding: "utf8" });
  const m = /encoder for (\d+)x(\d+) \(.*?(4:[24]:[04])/.exec((r.stdout || "").trim().split("\n").pop() || "");
  return m ? ` (xrdp's encoder: ${m[1]} × ${m[2]}, ${m[3]})` : "";
};
const profile = mkdtempSync(join(tmpdir(), "wasm-demo-"));
const frames = join(out, "demo-frames");
rmSync(frames, { recursive: true, force: true }); mkdirSync(frames, { recursive: true });
const chrome = spawn(process.env.CHROME || "google-chrome", ["--headless=new", "--remote-debugging-port=9348",
  `--user-data-dir=${profile}`, "--no-first-run", `--window-size=${W},${H}`, "--hide-scrollbars",
  "--mute-audio",   // the session's sound stays in the recording, off this computer's speakers
  "--enable-unsafe-swiftshader", "about:blank"], { stdio: "ignore" });
const done = code => {
  chrome.once("exit", () => { rmSync(profile, { recursive: true, force: true }); process.exit(code); });
  chrome.kill();
};

let target;
for (let i = 0; i < 150 && !target; i++) {
  await sleep(200);
  try { target = (await (await fetch("http://127.0.0.1:9348/json")).json()).find(t => t.type === "page"); } catch {}
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener("open", r));
let id = 0; const pending = new Map(); const shots = [];
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const logs = [];   // the page's console, for page.log (as wasm-session.mjs writes it)
ws.addEventListener("message", e => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); }
  if (m.method === "Runtime.consoleAPICalled") logs.push(m.params.args.map(a => a.value).join(" "));
  if (m.method === "Page.screencastFrame") {   // keep each frame with the time it was shown
    const file = join(frames, String(shots.length).padStart(5, "0") + ".jpg");
    writeFileSync(file, Buffer.from(m.params.data, "base64"));
    shots.push({ file, t: m.params.metadata.timestamp });
    send("Page.screencastFrameAck", { sessionId: m.params.sessionId });
  }
});
const ev = async expression => (await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true, userGesture: true }))?.result?.value;

// the pointer and the caption: page overlays, only in this recording
const OVERLAY = `(() => {
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
    "max-width:80vw;padding:10px 18px;border-radius:8px;background:rgba(15,22,30,.88);color:#fff;" +
    "font:500 24px/1.35 system-ui,sans-serif;text-align:center;transition:opacity .25s;opacity:0";
  document.body.append(cap);
  const tag = document.createElement("div"); tag.id = "demoLabel";
  tag.style.cssText = "position:fixed;right:18px;bottom:18px;z-index:2147483646;pointer-events:none;padding:6px 12px;" +
    "border-radius:6px;background:rgba(47,111,222,.92);color:#fff;font:600 16px/1.3 system-ui,sans-serif";
  tag.textContent = ${JSON.stringify(LABEL)};
  document.body.append(tag);
  const xy = window.__demoXY ||= { x: innerWidth * 0.62, y: innerHeight * 0.55 };
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
// the recording's sound: a copy of everything the page plays (installed before the page's
// scripts run); __demoRecord starts it once the session's AudioContext exists
const AUDIO_TAP = `(() => {
  const AC = window.AudioContext; if (!AC) return;
  const connect = AudioNode.prototype.connect;
  window.AudioContext = class extends AC {
    constructor(...a) {
      super(...a); this.__demoTap = this.createMediaStreamDestination(); window.__demoCtx = this;
      // a source that always plays (silence) into the tap: without one the stream carries
      // nothing while the session is quiet, and the recording leaves those stretches out,
      // so later sound lands too early (the bunny's soundtrack over the login)
      const hold = this.createConstantSource(); hold.offset.value = 0;
      connect.call(hold, this.__demoTap); hold.start();
    }
  };
  AudioNode.prototype.connect = function (dest, ...rest) {
    const r = connect.call(this, dest, ...rest);
    if (dest instanceof AudioDestinationNode && dest.context.__demoTap) connect.call(this, dest.context.__demoTap, ...rest);
    return r;
  };
  window.__demoRecord = () => {
    const ctx = window.__demoCtx; if (!ctx) return 0;
    const rec = new MediaRecorder(ctx.__demoTap.stream, { mimeType: "audio/webm;codecs=opus", audioBitsPerSecond: 128000 });
    const chunks = []; rec.ondataavailable = e => chunks.push(e.data); rec.start(1000);
    window.__demoStop = () => new Promise(done => {
      rec.onstop = async () => {
        const b = new Uint8Array(await new Blob(chunks).arrayBuffer()); let s = "";
        for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
        done(btoa(s));
      };
      rec.stop();
    });
    return Date.now();
  };
})()`;
const caption = text => ev(`window.__demoCaption(${JSON.stringify(text)})`);
const center = async sel => ev(`(() => { const r = document.querySelector(${JSON.stringify(sel)}).getBoundingClientRect();
  return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) }; })()`);
const moveTo = (x, y, ms = 700) => ev(`window.__demoMove(${x}, ${y}, ${ms})`);
async function click(x, y) {
  await moveTo(x, y);
  await send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
  await send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 });
  await sleep(90);
  await send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 });
}
const clickOn = async sel => { const c = await center(sel); await click(c.x, c.y); };
async function typeInPage(text, ms = 85) {   // into the focused form field
  for (const ch of text) { await send("Input.insertText", { text: ch }); await sleep(ms); }
}
// into the remote desktop: real key events, which the client reads by their code
function key(ch) {
  if (ch === "\u2318") return { key: "Meta", code: "MetaLeft", vk: 91 };   // Super: GNOME's overview
  if (ch === "\n") return { key: "Enter", code: "Enter", vk: 13, text: "\r" };
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
async function load() {   // (re)loaded page: wait for isolation and the client, then lay the overlays on it
  let isolated = false;
  for (let i = 0; i < 100 && !isolated; i++) { await sleep(300); isolated = await ev("self.crossOriginIsolated === true"); }
  let ready = false;
  for (let i = 0; i < 200 && !ready; i++) { await sleep(300); ready = await ev("document.getElementById('status')?.textContent === 'ready'"); }
  await ev(OVERLAY);
  return isolated && ready;
}
const record = () => send("Page.startScreencast", { format: "jpeg", quality: 88, maxWidth: W, maxHeight: H, everyNthFrame: 1 });

await send("Runtime.enable"); await send("Page.enable");
await send("Page.addScriptToEvaluateOnNewDocument", { source: AUDIO_TAP });
await send("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: 1, mobile: false });
await send("Page.navigate", { url });
if (!await load()) { console.log("the page did not get ready"); done(1); }
await ev(`document.getElementById('host').value = ${JSON.stringify(gateway)}; true`);
await record();
await sleep(600);

// 1. the page, and the route it explains
await caption("FreeRDP Web: an RDP client that runs in the browser");
await sleep(2600);
await moveTo(...Object.values(await center("#route .hops")), 900);
await caption(WINDOWS ? "Your RDP server stays on 127.0.0.1. The page reaches it through a gateway."
  : "Your RDP server stays on 127.0.0.1. The page reaches it through SSH.");
await sleep(3200);
await moveTo(...Object.values(await center("#copyCmd")), 800);
await caption("One SSH line starts the tunnel and the gateway. Here it already runs.");
await sleep(3400);

// 2. the form
await caption("Enter your user name and password");
await clickOn("#user"); await typeInPage(user);
await clickOn("#pass"); await typeInPage(password, 70);
await sleep(700);
await caption("Your browser's password manager can keep the password");
await sleep(2400);

// 3. the session settings
await clickOn("#sessionPanel > summary");
await caption("Session settings: sound, clipboard, video codec, and a priority");
await sleep(1200);
await moveTo(...Object.values(await center('input[name=strategy][value="bandwidth"]')), 800);
await sleep(2200);
await clickOn("#sessionPanel > summary");
await sleep(600);

// 4. connect
await caption("Connect");
await clickOn("#go");
const audioStart = await ev("window.__demoRecord ? window.__demoRecord() : 0");   // epoch ms, 0: no sound
let rx = 0;
for (let i = 0; i < 80 && rx < 300000; i++) { await sleep(500); rx = await ev("window.freerdpNet?.rx ?? 0"); }
await caption(WINDOWS ? "This Windows PC's own screen, shared by FreeRDP's shadow server, in AV1"
  : "The remote Linux desktop, over WebSocket and SSH");
await sleep(7000);   // the desktop starts, then its terminal
// newer pages offer, a few seconds after the login, to keep the password in
// the passkey vault: answered as a user would, so it does not cover the desktop
for (let i = 0; i < 30; i++) {
  if (await ev("(b => !!b && b.offsetParent !== null)(document.getElementById('saveLater'))")) {
    await caption("The page offers to keep the password with a passkey: not now");
    await sleep(1800);
    await clickOn("#saveLater");
    await sleep(800);
    break;
  }
  await sleep(500);
}

// 5. use it
const canvas = await ev(`(() => { const r = document.getElementById('canvas').getBoundingClientRect(); return { x: r.left, y: r.top }; })()`);
if (GNOME) {   // GNOME starts in the overview: typing searches, Enter starts the app
  await ev("document.getElementById('canvas').focus(), true");
  await caption(XRDP_GNOME ? `GNOME 51 on Wayland through xrdp, in AV1${serverCodec()}`
    : "GNOME on Wayland: type to search, Enter to start");
  await sleep(XRDP_GNOME ? 3500 : 1500);
  if (XRDP_GNOME) {
    await caption("GNOME on Wayland: type to search, Enter to start");
    await sleep(1500);
  }
  // typing goes to the overview's search; Fedora's terminal is Ptyxis, Debian's Console
  await typeRemote(XRDP_GNOME ? "terminal\n" : "console\n");
  await sleep(4000);
} else if (WINDOWS) {   // the Windows key opens Start, typing searches it, Enter starts
  await ev("document.getElementById('canvas').focus(), true");
  await caption("Windows: the Start menu searches as you type, Enter starts");
  await sleep(1200);
  await typeRemote("\u2318");
  await sleep(1800);
  await typeRemote("notepad\n");
  await sleep(4000);
} else if (XRDP_KDE) {   // Plasma starts on its desktop: Meta opens the launcher, typing searches it
  await ev("document.getElementById('canvas').focus(), true");
  await caption(`KDE Plasma on Wayland through xrdp, in AV1${serverCodec()}`);
  await sleep(3500);
  await caption("KDE Plasma: the launcher searches as you type, Enter starts");
  await typeRemote("\u2318");
  await sleep(1500);
  await typeRemote("konsole\n");
  await sleep(4000);
} else {
  await click(Math.round(canvas.x + 300), Math.round(canvas.y + 200));
}
await caption("Keyboard and mouse go to the remote desktop");
await sleep(600);
if (WINDOWS) {
  await typeRemote("Hello from the browser, through FreeRDP Web\n");
  await sleep(2400);
} else {
  await typeRemote("echo hello from the browser\n");
  await sleep(900);
  // only what belongs to the throwaway server: a container shares the host's kernel, so
  // nothing like uname (it would show the machine running the demo)
  await typeRemote("hostname\n");
  await sleep(2400);
}
const shot = await send("Page.captureScreenshot", { format: "png" });   // for wasm-session.sh's check
writeFileSync(join(out, "wasm-session.png"), Buffer.from(shot.data, "base64"));
// where the remote desktop is in that screenshot, in its pixels: wasm-session.sh checks it shows detail
// and how much the session has sent by then (a picture that never arrived has next to nothing)
writeFileSync(join(out, "canvas.json"), JSON.stringify(await ev(`(() => {
  const r = document.getElementById('canvas').getBoundingClientRect(), d = window.devicePixelRatio || 1;
  return { x: Math.round(r.left * d), y: Math.round(r.top * d), w: Math.round(r.width * d), h: Math.round(r.height * d),
           rx: window.freerdpNet?.rx ?? 0 }; })()`)));
// the page's log and console, for wasm-session.sh's checks
writeFileSync(join(out, "page.log"),
  (await ev("document.getElementById('log')?.textContent ?? ''")) + "\n--- console ---\n" + logs.join("\n"));

// 6. web video with sound and WebGL, in Firefox on the server, started by typing "webdemo"
if (WINDOWS) {
  await caption("Drawn on the Windows PC, streamed to this browser in AV1");
  await sleep(4000);
} else {
  await caption("Web video with sound, and WebGL: Firefox on the server");
  await typeRemote("webdemo\n");
  await sleep(14000);
  await caption("Big Buck Bunny, © Blender Foundation, CC BY 3.0 · WebGL Aquarium, © Google, BSD");
  await sleep(8000);
  await caption("Drawn on the server, streamed to this browser, sound included");
  await sleep(6000);
}

// 7. info, then disconnect
await clickOn("#tbInfo");
await caption("Info: codecs, frame rate, bandwidth, sound");
await sleep(4500);
const infoText = await ev("document.getElementById('infoTable').innerText");
console.log("info at the end:\n" + infoText.split("\n").filter(l => /Video|Audio|AV1 frames|AV1 decoder|Network in/.test(l)).join("\n"));
await clickOn("#tbInfo");
const audio = audioStart ? await ev("window.__demoStop ? window.__demoStop() : ''") : "";
await caption("Disconnect ends the session. Then stop the gateway with Ctrl-C.");
await sleep(1600);
await clickOn("#tbQuit");
await sleep(1500);
await load();
await caption("FreeRDP Web: github.com/congzhangzh/freerdp-web");
await sleep(3500);
await send("Page.stopScreencast");

// the frames, each as long as it was on screen, into an MP4
const list = shots.map((s, i) => `file '${s.file}'\nduration ${((shots[i + 1]?.t ?? s.t + 1) - s.t).toFixed(3)}`).join("\n")
  + `\nfile '${shots.at(-1).file}'\n`;
writeFileSync(join(frames, "list.txt"), list);
// the sound joins at the time it started, relative to the first frame
const sound = [];
if (audio) {
  writeFileSync(join(frames, "sound.webm"), Buffer.from(audio, "base64"));
  sound.push("-itsoffset", (audioStart / 1000 - shots[0].t).toFixed(3), "-i", join(frames, "sound.webm"));
}
const ff = spawnSync("ffmpeg", ["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", join(frames, "list.txt"),
  ...sound, "-map", "0:v", ...(audio ? ["-map", "1:a", "-c:a", "aac", "-b:a", "160k"] : []),
  "-vf", `fps=30,scale=${W}:${H}:flags=lanczos,format=yuv420p`, "-c:v", "libx264", "-crf", "22", "-preset", "slow",
  "-movflags", "+faststart", video], { stdio: "inherit" });
console.log(`demo: ${shots.length} frames, ${(shots.at(-1).t - shots[0].t).toFixed(1)} s, ` +
  `sound ${audio ? Math.round(audio.length * 0.75 / 1024) + " KB" : "none"} -> ${video} (ffmpeg ${ff.status})`);
rmSync(frames, { recursive: true, force: true });
done(ff.status === 0 ? 0 : 1);
