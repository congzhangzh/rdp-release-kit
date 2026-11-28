// browser-h264.mjs <webdriver url> <browser name> <page url> <out file>: does this browser
// encode H.264 the way FreeRDP Web's camera asks (WebCodecs VideoEncoder, the client's 640x480
// configuration)? Through the browser's own WebDriver (geckodriver, safaridriver), no other
// dependency. Prints and writes one JSON line; the page is any page of the site, on localhost.
import { writeFileSync } from "node:fs";

const [driver, browserName, page, outFile] = process.argv.slice(2);
const call = async (method, path, body) => {
  const r = await fetch(driver + path, { method, headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body) });
  const j = await r.json();
  if (!r.ok) throw new Error(`${method} ${path}: ${JSON.stringify(j.value ?? j)}`);
  return j.value;
};
const caps = { browserName };
if (browserName === "firefox") caps["moz:firefoxOptions"] = { args: ["-headless"] };
const result = { browser: browserName };
let session;
try {
  session = (await call("POST", "/session", { capabilities: { alwaysMatch: caps } })).sessionId;
  await call("POST", `/session/${session}/url`, { url: page });
  const v = await call("POST", `/session/${session}/execute/async`, { args: [], script: `
    const done = arguments[arguments.length - 1];
    const config = { codec: "avc1.42E01E", width: 640, height: 480, bitrate: 1000000, framerate: 30,
      latencyMode: "realtime", avc: { format: "avc" } };
    (async () => {
      const r = { userAgent: navigator.userAgent, secureContext: window.isSecureContext,
        videoEncoder: typeof VideoEncoder === "function",
        trackProcessor: typeof MediaStreamTrackProcessor === "function",
        videoFrame: typeof VideoFrame === "function",
        frameCallback: typeof HTMLVideoElement !== "undefined" && "requestVideoFrameCallback" in HTMLVideoElement.prototype };
      if (r.videoEncoder) {
        try { r.h264 = (await VideoEncoder.isConfigSupported(config)).supported === true; }
        catch (e) { r.h264 = false; r.error = String(e); }
        try { const q = { ...config }; delete q.latencyMode;
          r.h264WithoutRealtime = (await VideoEncoder.isConfigSupported(q)).supported === true; }
        catch (e) { r.h264WithoutRealtime = false; }
      } else r.h264 = false;
      done(r);
    })();` });
  Object.assign(result, v);
} catch (e) {
  result.error = String(e.message || e);
} finally {
  if (session) await call("DELETE", `/session/${session}`).catch(() => {});
}
console.log(JSON.stringify(result));
writeFileSync(outFile, JSON.stringify(result) + "\n");
