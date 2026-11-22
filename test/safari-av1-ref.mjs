// Branch only (web-safari-av1-diag): does Safari's VideoDecoder decode any AV1 key frame on this
// machine, or only not FreeRDP's? Each <name>.obu in DIR (AV1 low-overhead format, one key temporal
// unit) is fetched by a plain page and decoded with VideoDecoder; prints one line per file.
//   node test/safari-av1-ref.mjs <http url of DIR> <file.obu> ...
import { spawn } from "node:child_process";
const [BASE, ...FILES] = process.argv.slice(2), PORT = 4474, sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const driver = spawn("safaridriver", ["-p", String(PORT)], { stdio: "ignore" });
const wd = async (method, path, body) => {
  const j = await (await fetch(`http://127.0.0.1:${PORT}${path}`, { method, headers: { "content-type": "application/json" }, body: body && JSON.stringify(body) })).json();
  if (j.value?.error) throw new Error(`${path}: ${j.value.error}: ${j.value.message}`);
  return j.value;
};
let sid = null, code = 1;
try {
  for (let i = 0; i < 50 && !(await fetch(`http://127.0.0.1:${PORT}/status`).then((r) => r.ok, () => false)); i++) await sleep(200);
  for (let i = 0; i < 5 && !sid; i++) { try { sid = (await wd("POST", "/session", { capabilities: { alwaysMatch: { browserName: "safari" } } })).sessionId; } catch (e) { console.log(`no session yet: ${e.message}`); await sleep(3000); } }
  await wd("POST", `/session/${sid}/timeouts`, { script: 120000 });
  await wd("POST", `/session/${sid}/url`, { url: `${BASE}/blank.html` });
  console.log(`browser ${await wd("POST", `/session/${sid}/execute/sync`, { script: "return navigator.userAgent", args: [] })}`);
  const r = await wd("POST", `/session/${sid}/execute/async`, { args: [BASE, FILES], script: `const [base, files, done] = arguments;
    const fmt = (e) => e && e.name ? e.name + ": " + e.message : String(e);
    (async () => { const out = [];
      for (const f of files) {
        const data = new Uint8Array(await (await fetch(base + "/" + f)).arrayBuffer());
        for (const codec of ["av01.0.08M.08", "av01.0.13M.08"]) {
          const cfg = { codec };
          const sup = await VideoDecoder.isConfigSupported(cfg).then((x) => x.supported, fmt);
          const res = await new Promise((resolve) => { let dec, t;
            const end = (v) => { clearTimeout(t); try { dec.close(); } catch {} resolve(v); };
            try { dec = new VideoDecoder({ output: (fr) => { const v = "frame " + fr.format + " " + fr.codedWidth + "x" + fr.codedHeight; fr.close(); end(v); }, error: (e) => end("error " + fmt(e)) });
              dec.configure(cfg); dec.decode(new EncodedVideoChunk({ type: "key", timestamp: 0, data })); dec.flush().then(() => end("flushed, no frame"), (e) => end("error " + fmt(e)));
            } catch (e) { end("threw " + fmt(e)); }
            t = setTimeout(() => end("timeout"), 5000); });
          out.push(f + " (" + data.length + " bytes) " + codec + ": isConfigSupported " + sup + ", decode " + res);
        } }
      return out; })().then((o) => done(o.join("\\n")), (e) => done("failed " + fmt(e)));` });
  console.log(r);
  code = 0;
} catch (e) { console.log(`FAIL ${e.message}`); }
if (sid) await fetch(`http://127.0.0.1:${PORT}/session/${sid}`, { method: "DELETE" }).catch(() => {});
driver.kill(); process.exit(code);
