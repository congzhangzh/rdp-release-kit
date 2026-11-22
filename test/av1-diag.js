// Branch only (web-safari-av1-diag): injected into the page by web-av1-i420.mjs before the session
// starts, in the page's own world (a <script> element). It records what FreeRDP's WebCodecs glue
// (av1_webcodecs.js) does with VideoDecoder and what the browser answers, without changing it:
// the console, each decoder's configure(), the first chunks (type, size, the first bytes), the
// error callback's and decode()'s exceptions (name, message, code), the first frames. The first key
// chunk is kept whole for a replay with other configurations (window.__av1diagReplay).
(() => {
  const D = (window.__av1diag = { console: [], decoders: [], uncaught: [], firstKey: null });
  const t0 = performance.now(), at = () => Math.round(performance.now() - t0);
  const fmt = (x) => {
    if (x && typeof x === "object" && "name" in x && "message" in x)
      return `${x.name}: ${x.message}${x.code !== undefined ? ` (code ${x.code})` : ""}`;
    try { return typeof x === "object" ? JSON.stringify(x) : String(x); } catch { return String(x); }
  };
  for (const k of ["error", "warn", "info", "log"]) {
    const orig = console[k].bind(console);
    console[k] = (...a) => {
      try { if (D.console.length < 400) D.console.push(`${at()} ${k}: ${a.map(fmt).join(" ").slice(0, 600)}`); } catch {}
      orig(...a);
    };
  }
  window.addEventListener("error", (e) => D.uncaught.push(`${at()} error: ${e.message}`));
  window.addEventListener("unhandledrejection", (e) => D.uncaught.push(`${at()} rejection: ${fmt(e.reason)}`));

  const hex = (u8, n) => [...u8.subarray(0, n)].map((b) => b.toString(16).padStart(2, "0")).join("");
  const b64 = (u8) => { let s = ""; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000)); return btoa(s); };
  const VD = (D.VideoDecoder = window.VideoDecoder);
  if (typeof VD !== "function") return;

  window.VideoDecoder = class extends VD {
    constructor(init) {
      const rec = { id: D.decoders.length + 1, created: at(), configs: [], chunks: 0, firstChunks: [], errors: [], outputs: 0, frames: [] };
      D.decoders.push(rec);
      let self = null;
      super({
        output: (f) => {
          rec.outputs++;
          if (rec.frames.length < 3)
            rec.frames.push({ at: at(), format: f.format, coded: `${f.codedWidth}x${f.codedHeight}`, display: `${f.displayWidth}x${f.displayHeight}`,
              colorSpace: f.colorSpace && f.colorSpace.toJSON ? f.colorSpace.toJSON() : null });
          return init.output(f);
        },
        error: (e) => {
          rec.errors.push({ at: at(), where: "error callback", name: e && e.name, message: e && e.message, code: e && e.code,
            state: self && self.state, queue: self && self.decodeQueueSize, afterChunks: rec.chunks, afterOutputs: rec.outputs });
          return init.error(e);
        },
      });
      self = this;
      this.__rec = rec;
    }
    configure(cfg) {
      const rec = this.__rec, c = { at: at(), config: JSON.parse(JSON.stringify(cfg)) };
      rec.configs.push(c);
      VD.isConfigSupported(cfg).then((r) => { c.isConfigSupported = r.supported; c.supportedConfig = r.config; },
        (e) => { c.isConfigSupported = fmt(e); });
      try { super.configure(cfg); c.stateAfter = this.state; }
      catch (e) { c.threw = fmt(e); rec.errors.push({ at: at(), where: "configure() threw", name: e.name, message: e.message }); throw e; }
    }
    decode(chunk) {
      const rec = this.__rec;
      rec.chunks++;
      if (rec.firstChunks.length < 4 || (chunk.type === "key" && !D.firstKey)) {
        const u8 = new Uint8Array(chunk.byteLength);
        chunk.copyTo(u8);
        if (rec.firstChunks.length < 4)
          rec.firstChunks.push({ at: at(), type: chunk.type, bytes: chunk.byteLength, timestamp: chunk.timestamp, state: this.state, queue: this.decodeQueueSize, head: hex(u8, 48) });
        if (chunk.type === "key" && !D.firstKey) D.firstKey = { bytes: u8.length, b64: b64(u8) };
      }
      try { return super.decode(chunk); }
      catch (e) { rec.errors.push({ at: at(), where: "decode() threw", name: e.name, message: e.message, code: e.code, state: this.state, chunk: rec.chunks }); throw e; }
    }
  };

  // The first key chunk again, into a fresh decoder per configuration: which setting decides?
  window.__av1diagReplay = async (configs) => {
    if (!D.firstKey) return "no key chunk";
    const bin = atob(D.firstKey.b64), data = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) data[i] = bin.charCodeAt(i);
    const out = [];
    for (const cfg of configs) {
      const r = { config: cfg };
      try { r.isConfigSupported = (await VD.isConfigSupported(cfg)).supported; } catch (e) { r.isConfigSupported = fmt(e); }
      await new Promise((resolve) => {
        let dec = null;
        const end = (k, v) => { if (r.result) return; r.result = k; if (v) r.detail = v; r.state = dec && dec.state; try { dec.close(); } catch {} resolve(); };
        try {
          dec = new VD({ output: (f) => { const v = { format: f.format, coded: `${f.codedWidth}x${f.codedHeight}` }; f.close(); end("frame", v); },
            error: (e) => end("error", fmt(e)) });
          dec.configure(cfg);
          dec.decode(new EncodedVideoChunk({ type: "key", timestamp: 0, data }));
          dec.flush().then(() => end("flushed, no frame"), (e) => end("error", fmt(e)));
        } catch (e) { end("threw", fmt(e)); }
        setTimeout(() => end("timeout 5 s"), 5000);
      });
      out.push(r);
    }
    return out;
  };
})();
