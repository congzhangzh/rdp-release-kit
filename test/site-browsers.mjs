// The site in the browsers people open it with, before it goes live: Firefox, WebKit as an iPhone
// and as the desktop's Safari, and Chromium each get the page to "Connect" with no page error, from
// exactly the files to be published, served as GitHub Pages serves them (no COOP/COEP: the page's
// service worker makes it cross-origin isolated, with the reload that takes). A login stays Chrome's
// (wasm-session.sh); this only shows the page and its client start in each browser.
// Why: 2026-11-13 (freerdp-web #368) an iPhone never got past "Loading…" for weeks, and Firefox
// showed its "Paste" box all the time, because only Chrome ran the site before it went live.
//
//   node test/site-browsers.mjs <site dir>
//
// Needs Playwright with its browsers (PLAYWRIGHT=<its package dir> when it is not installed here):
// site.yml runs it in Playwright's image, which has them and the libraries they need. Screenshots
// and the page's console go to dist/test/browsers/.
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";

const site = resolve(process.argv[2] || "site"), port = 8197, out = resolve("dist/test/browsers");
mkdirSync(out, { recursive: true });
const require = createRequire(import.meta.url);
const pw = require(process.env.PLAYWRIGHT || "playwright");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fails = 0;
const check = (name, ok, detail = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  (" + detail + ")" : ""}`); if (!ok) fails++; };

// a plain static server, as GitHub Pages: no COOP/COEP
const server = spawn("python3", ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", site], { stdio: "ignore" });
const url = `http://127.0.0.1:${port}/index.html`;
for (let i = 0; i < 50; i++) { await sleep(100); try { await fetch(url); break; } catch {} }

const BROWSERS = [
  ["Firefox", "firefox", {}],
  ["iPhone (WebKit)", "webkit", pw.devices["iPhone 14"]],
  ["Safari (WebKit)", "webkit", {}],
  ["Chromium", "chromium", {}],
];
for (const [name, type, profile] of BROWSERS) {
  const browser = await pw[type].launch();
  const ctx = await browser.newContext({ ...profile, locale: "en-US" });
  const page = await ctx.newPage(), log = [];
  // the errors of the page that stays: the first load, before the service worker makes the page
  // isolated, is thrown away by its reload, and errors there (a client that cannot share its memory
  // with its threads yet, a download cut short) are noted, not failed
  let errors = [], before = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("framenavigated", (f) => { if (f === page.mainFrame()) { before = before.concat(errors); errors = []; } });
  page.on("console", (m) => log.push(`${m.type()}: ${m.text()}`));
  await page.goto(url);
  // the Connect button, once it is no longer "Loading…" (the service worker reloads the page once)
  let go = null;
  for (let i = 0; i < 90; i++) {
    go = await page.evaluate(() => ({ text: document.getElementById("go")?.textContent, disabled: document.getElementById("go")?.disabled,
      status: document.getElementById("status")?.textContent, isolated: self.crossOriginIsolated })).catch(() => null);
    if (go && go.text !== "Loading…" && go.text !== undefined) break;
    await sleep(500);
  }
  const file = name.replace(/\W+/g, "-").toLowerCase();
  await page.screenshot({ path: `${out}/${file}.png` }).catch(() => {});
  writeFileSync(`${out}/${file}.log`, log.concat(errors.map((e) => "pageerror: " + e)).join("\n") + "\n");
  check(`${name}: the page gets to Connect`, go?.text === "Connect" && !go.disabled && go.isolated, JSON.stringify(go));
  check(`${name}: no page error`, !errors.length, errors.join("; "));
  if (before.length) console.log(`NOTE  ${name}: before the reload: ${before.join("; ")}`);
  await browser.close();
}
server.kill();
console.log(fails ? "FAILED" : "PASSED");
process.exit(fails ? 1 : 0);
