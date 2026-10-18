// Drives headless Chrome through the DevTools protocol: opens the page,
// waits for cross-origin isolation (the service worker reloads the page once
// on hosts without COOP/COEP), logs in with a synthetic password and saves a
// screenshot.
//
//   node wasm-session.mjs <page url> <gateway host:port> <user> <password> <out dir>
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const [url, gateway, user, password, out] = process.argv.slice(2);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const profile = mkdtempSync(join(tmpdir(), "wasm-session-"));
const chrome = spawn("google-chrome", ["--headless=new", "--remote-debugging-port=9347",
  `--user-data-dir=${profile}`, "--no-first-run", "--window-size=1280,900",
  "--enable-unsafe-swiftshader", ...(process.env.CHROME_FLAGS ? process.env.CHROME_FLAGS.split(" ") : []),
  "about:blank"], { stdio: "ignore" });
// Chrome must be gone before its profile can be removed
const done = code => {
  chrome.once("exit", () => { rmSync(profile, { recursive: true, force: true }); process.exit(code); });
  chrome.kill();
};

let target;
for (let i = 0; i < 150 && !target; i++) {
  await sleep(200);
  try { target = (await (await fetch("http://127.0.0.1:9347/json")).json()).find(t => t.type === "page"); } catch {}
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener("open", r));
let id = 0; const pending = new Map(); const logs = [];
ws.addEventListener("message", e => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); }
  if (m.method === "Runtime.consoleAPICalled") logs.push(m.params.args.map(a => a.value).join(" "));
  // the browser's own messages (blocked requests, security checks)
  if (m.method === "Log.entryAdded") logs.push(`[browser ${m.params.entry.source}] ${m.params.entry.text}`);
});
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async expression => (await send("Runtime.evaluate", { expression, returnByValue: true, userGesture: true }))?.result?.value;

// A public page needs the user's permission to reach 127.0.0.1 (Chrome's
// Local Network Access); grant it as a user clicking "Allow" would. The
// permission's name changed between Chrome versions: grant all of them.
if (!/^http:\/\/(127\.0\.0\.1|localhost)[:/]/.test(url)) {
  const v = await (await fetch("http://127.0.0.1:9347/json/version")).json();
  const bws = new WebSocket(v.webSocketDebuggerUrl);
  await new Promise(r => bws.addEventListener("open", r));
  let bid = 0;
  const bsend = (method, params) => new Promise(r => {
    const i = ++bid;
    bws.addEventListener("message", e => { const m = JSON.parse(e.data); if (m.id === i) r(m); });
    bws.send(JSON.stringify({ id: i, method, params }));
  });
  // for both schemes: a site may redirect http:// to https://
  const host = new URL(url).host;
  for (const origin of [`https://${host}`, `http://${host}`])
    for (const name of ["local-network-access", "loopback-network", "local-network"])
      await bsend("Browser.setPermission", { permission: { name }, setting: "granted", origin });
  console.log(`granted local network access to ${host}`);
}

await send("Runtime.enable"); await send("Page.enable"); await send("Log.enable");
await send("Page.navigate", { url });
let isolated = false;
for (let i = 0; i < 100 && !isolated; i++) { await sleep(300); isolated = await ev("self.crossOriginIsolated === true"); }
console.log(`cross-origin isolated: ${isolated}`);
if (!isolated) done(1);

// fill the form, wait until the WASM runtime is ready, then connect
await ev(`document.getElementById('host').value = ${JSON.stringify(gateway)};
          document.getElementById('user').value = ${JSON.stringify(user)}; true`);
let ready = false;
for (let i = 0; i < 200 && !ready; i++) {
  await sleep(300);
  ready = await ev("document.getElementById('status')?.textContent === 'ready' && !document.getElementById('go')?.disabled");
}
console.log(`client ready: ${ready}`);
if (!ready) done(1);
await ev(`document.getElementById('pass').value = ${JSON.stringify(password)}; document.getElementById('go').click(); true`);
await sleep(25000);
const shot = await send("Page.captureScreenshot", { format: "png" });
writeFileSync(join(out, "wasm-session.png"), Buffer.from(shot.data, "base64"));
const pageLog = await ev("document.getElementById('log')?.textContent ?? ''");
writeFileSync(join(out, "page.log"), pageLog + "\n--- console ---\n" + logs.join("\n"));
console.log(`page status: ${await ev("document.getElementById('status')?.textContent")}`);
done(0);
