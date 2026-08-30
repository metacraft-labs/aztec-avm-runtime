#!/usr/bin/env node
// open_container_in_engine.mjs — L4: DOES AN L3 CONTAINER OPEN AND STEP IN A BROWSER?
//
// ================================================================================================
// THE ACCEPTANCE CRITERION IS "STEPS TAKEN AND POSITIONS REACHED", NOT "IT LOADED".
// ================================================================================================
//
// This drives the REAL published replay engine — the WebAssembly DAP server BlockTracer serves at
// `/replay-engine/worker.js` — over the Chrome DevTools Protocol, in a real headless browser, and
// reports what the engine actually did. A page that loads a container and cannot step it is a
// finding, not a pass, so every DAP response is recorded and the step count is read out of the
// engine's own replies rather than out of this file's expectations.
//
// ================================================================================================
// WHY THE ENGINE IS MIRRORED LOCALLY, AND IT IS A CONSTRAINT RATHER THAN A CONVENIENCE.
// ================================================================================================
//
// `new Worker(url, { type: 'module' })` throws `SecurityError` on a CROSS-ORIGIN script URL. That is
// why BlockTracer vendors the engine into its own origin instead of fetching it, and the same
// constraint applies here: a local page cannot construct a worker from
// `https://blocktracer.org/replay-engine/worker.js`. So the engine's three files are mirrored and
// served from the SAME local origin as the container.
//
// MEASURED RATHER THAN ASSUMED — the mirror is a fetch of published files and each one's status is
// recorded, because "the engine is at that path" is a claim about somebody else's deployment:
//
//   /replay-engine/            404   ← the directory itself does not serve
//   /replay-engine/worker.js   200   12,180 bytes
//   /replay-engine/pkg/db_backend.js       200   18,675 bytes
//   /replay-engine/pkg/db_backend_bg.wasm  200   18,281,361 bytes
//
// The 404 on the directory is worth recording: a check that probed the path the page NAMES
// (`data-replay-engine="/replay-engine/"`) and concluded the engine was absent would have been
// wrong, and BlockTracer's own error string for that case — "The replay engine never loaded from
// /replay-engine/. Nothing answered at that path" — is about the worker, not the directory.
//
// ================================================================================================
// THE PROTOCOL, READ OUT OF THE ENGINE'S OWN SOURCE.
// ================================================================================================
//
//   worker → { type: 'wasm-loaded' }                      once the wasm-bindgen package is up
//   page   → { type: 'load-trace', files: [{ url, vfsPath }] }
//   worker → { type: 'trace-loaded' | 'trace-load-error' }
//   page   → { type: 'start' }                            hands the worker to the WASM DAP dispatcher
//   then   → DAP requests/responses over postMessage
//
// The canonical VFS path is `<folder>/trace.ct`, because the WASM's launch-time auto-detect looks
// for exactly that name — the engine's own comment says so and mirrors bytes to it when a gateway
// object key differs.
//
// Usage:
//   node tools/open_container_in_engine.mjs --container <path.ct> --engine <dir> [--out <json>]

import { copyFileSync, existsSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { CdpConnection, launchChromium, openPage, serveDirectory } from './browser_cdp.mjs';

const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d; };

const container = arg('container');
const engineDir = arg('engine', '/tmp/l4engine');
const outFile = arg('out');
const stepsWanted = Number(arg('steps', 25));

if (!container || !existsSync(container)) {
  console.error(`open-container: --container <path.ct> is required and must exist (got ${container})`);
  process.exit(2);
}
for (const f of ['worker.js', 'pkg/db_backend.js', 'pkg/db_backend_bg.wasm']) {
  if (!existsSync(path.join(engineDir, f))) {
    console.error(`open-container: the mirrored engine is missing ${f} under ${engineDir}.
  Remedy: just mirror-replay-engine`);
    process.exit(2);
  }
}

const CHROMIUM = process.env.M27_CHROMIUM
  ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// ---- the site: the engine, the container, and one page that drives them ----------------------
const site = mkdtempSync(path.join(tmpdir(), 'l4-engine-site-'));
mkdirSync(path.join(site, 'pkg'), { recursive: true });
copyFileSync(path.join(engineDir, 'worker.js'), path.join(site, 'worker.js'));
copyFileSync(path.join(engineDir, 'pkg/db_backend.js'), path.join(site, 'pkg/db_backend.js'));
copyFileSync(path.join(engineDir, 'pkg/db_backend_bg.wasm'), path.join(site, 'pkg/db_backend_bg.wasm'));
copyFileSync(container, path.join(site, 'trace.ct'));

// THE DRIVER IS DELIBERATELY SMALL AND RECORDS EVERYTHING. Every message in both directions is
// pushed onto `window.__log`, so a run that fails is diagnosable from the transcript rather than
// from a boolean. `__done` resolves on the first terminal condition; nothing here waits forever.
writeFileSync(path.join(site, 'index.html'), `<!doctype html>
<meta charset="utf-8">
<title>L4 — open an L3 container in the replay engine</title>
<body>
<pre id="out">starting…</pre>
<script type="module">
const log = [];
window.__log = log;
const say = (dir, m) => { log.push({ dir, t: Date.now(), m: JSON.parse(JSON.stringify(m)) }); };

const worker = new Worker('./worker.js', { type: 'module' });
let seq = 1;
const pending = new Map();
const events = [];

worker.onerror = (e) => { say('error', { message: e.message, filename: e.filename, lineno: e.lineno }); };
worker.onmessage = (ev) => {
  // THE TWO HALVES OF THIS WORKER SPEAK DIFFERENT SHAPES, AND THE FIRST RUN OF THIS TOOL DIED ON IT.
  // Before \`start\`, the JS half posts OBJECTS (\`wasm-loaded\`, \`trace-loaded\`). After
  // \`wasm_start()\` hands the port to the WASM DAP dispatcher, the Rust half posts JSON STRINGS —
  // so a handler that only ever read \`m.type\` saw a string, matched nothing, and reported
  // "DAP timeout: initialize" over an engine that had in fact answered \`success: true\` and gone on
  // to emit \`initialized\`. The transcript is what showed it; a boolean would not have.
  const raw = ev.data;
  let m = raw;
  if (typeof raw === 'string') {
    try { m = JSON.parse(raw); } catch { m = { type: 'raw-string', text: raw }; }
  }
  say('in', m);
  if (m && m.type === 'response' && pending.has(m.request_seq)) {
    pending.get(m.request_seq)(m); pending.delete(m.request_seq);
  } else if (m && m.seq !== undefined && m.request_seq !== undefined && pending.has(m.request_seq)) {
    pending.get(m.request_seq)(m); pending.delete(m.request_seq);
  } else if (m && m.type === 'event') {
    events.push(m);
  }
  const h = window.__waiters?.find((w) => w.pred(m));
  if (h) { window.__waiters = window.__waiters.filter((w) => w !== h); h.resolve(m); }
};

window.__waiters = [];
const waitFor = (pred, label, ms = 120000) => new Promise((resolve, reject) => {
  const w = { pred, resolve };
  window.__waiters.push(w);
  setTimeout(() => {
    window.__waiters = window.__waiters.filter((x) => x !== w);
    reject(new Error('timed out waiting for ' + label));
  }, ms);
});

const post = (m) => { say('out', m); worker.postMessage(m); };
const dap = (command, args) => {
  const s = seq++;
  const req = { seq: s, type: 'request', command, arguments: args ?? {} };
  const p = new Promise((resolve, reject) => {
    pending.set(s, resolve);
    setTimeout(() => { if (pending.has(s)) { pending.delete(s); reject(new Error('DAP timeout: ' + command)); } }, 120000);
  });
  say('out', req);
  worker.postMessage(req);
  return p;
};
window.__dap = dap;
window.__post = post;
window.__events = () => events;

window.__result = null;
window.__run = (async () => {
  const result = { phases: {} };
  try {
    await waitFor((m) => m && m.type === 'wasm-loaded', 'wasm-loaded');
    result.phases.wasmLoaded = true;

    post({ type: 'load-trace', files: [{ url: './trace.ct', vfsPath: 'aztec/trace.ct' }] });
    const loaded = await waitFor(
      (m) => m && (m.type === 'trace-loaded' || m.type === 'trace-load-error'), 'trace-loaded');
    result.phases.traceLoaded = loaded.type === 'trace-loaded';
    result.traceLoadReply = loaded;
    if (loaded.type !== 'trace-loaded') { result.error = loaded.error; return result; }

    post({ type: 'start' });
    await new Promise((r) => setTimeout(r, 300));
    result.phases.started = true;

    result.initialize = await dap('initialize', {
      clientID: 'l4-smoke', adapterID: 'codetracer', linesStartAt1: true, columnsStartAt1: true,
      pathFormat: 'path', supportsVariableType: true,
    });
    // \`traceFolder\`, NOT \`program\` — and the engine is the one that said so. With
    // \`{ program }\` every request still answered \`success: true\` and only \`next\` failed,
    // with: "no trace is open: next arrived before the launch handshake completed (received
    // launch=true, configurationDone=true). Send launch with a traceFolder …". A launch that
    // reports success while opening nothing is exactly the shape this campaign distrusts, and the
    // reason this tool asserts STEPS TAKEN rather than a chain of \`success\` flags.
    result.launch = await dap('launch', { traceFolder: 'aztec', noDebug: false });
    result.configurationDone = await dap('configurationDone', {});
    result.threads = await dap('threads', {});

    const tid = result.threads?.body?.threads?.[0]?.id ?? 1;
    result.stackTraceInitial = await dap('stackTrace', { threadId: tid, startFrame: 0, levels: 20 });

    // ---- THE ACCEPTANCE CRITERION: STEP, AND RECORD WHERE IT LANDS ----
    const positions = [];
    const readPos = async () => {
      const st = await dap('stackTrace', { threadId: tid, startFrame: 0, levels: 1 });
      const f = st?.body?.stackFrames?.[0];
      return f ? { line: f.line, column: f.column, name: f.name, source: f.source?.path ?? f.source?.name } : null;
    };
    const p0 = await readPos();
    if (p0) positions.push(p0);
    for (let i = 0; i < ${stepsWanted}; i++) {
      const r = await dap('next', { threadId: tid });
      if (r && r.success === false) { result.stepStoppedBecause = r.message ?? 'next returned success:false'; break; }
      const p = await readPos();
      if (p) positions.push(p); else { result.stepStoppedBecause = 'no stack frame after next'; break; }
    }
    result.positions = positions;
    result.stepsTaken = Math.max(0, positions.length - 1);
    result.distinctLines = [...new Set(positions.map((p) => p.line))].length;
  } catch (e) {
    result.error = String(e && e.message ? e.message : e);
  }
  result.log = log;
  document.getElementById('out').textContent = 'done';
  window.__result = result;
  return result;
})();
</script>
</body>`);

// ---- drive it ---------------------------------------------------------------------------------
const server = await serveDirectory(site);
const browser = await launchChromium(CHROMIUM);
// THE CONNECTION'S OWN BOUND, RAISED DELIBERATELY. `CdpConnection.connect` defaults every `send`
// to 60 s, and `Runtime.evaluate` over an 18 MB wasm engine plus a DAP session exceeds that — the
// first run of this tool died with "Runtime.evaluate did not complete within 60000 ms". Raising it
// is correct here and the POLL below is what keeps it from becoming a hang: the page stores its
// result and this side asks repeatedly, so no single evaluate has to span the whole run.
const conn = await CdpConnection.connect(browser.endpoint, 300000);
let report;
try {
  const page = await openPage(conn, `${server.origin}/index.html`, { loadTimeoutMs: 60000 });
  // POLLED, NOT AWAITED IN ONE CALL. Each probe is short and bounded; the loop's own deadline is
  // what turns "the engine never answered" into a named failure instead of a hang.
  const deadline = Date.now() + 300000;
  for (;;) {
    const done = await page.eval('window.__result !== null', 30000);
    if (done) break;
    if (Date.now() > deadline) {
      report = { error: 'the page did not finish within 300 s', phases: {},
                 log: await page.eval('JSON.stringify(window.__log ?? []).slice(0, 20000)', 30000) };
      break;
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  report ??= await page.eval('window.__result', 60000);
  report.consoleLines = page.console.slice(0, 40);
  report.pageErrors = page.errors;
  report.requests = page.requests.map((r) => ({ url: r.url.replace(server.origin, ''), type: r.type }));
  await page.close();
} finally {
  try { conn.close?.(); } catch { /* the browser may already be gone */ }
  try { browser.child.kill('SIGKILL'); } catch { /* idem */ }
  await server.close?.();
}

const summary = {
  container,
  containerBytes: (await import('node:fs')).statSync(container).size,
  phases: report.phases,
  stepsTaken: report.stepsTaken ?? 0,
  distinctLines: report.distinctLines ?? 0,
  firstPositions: (report.positions ?? []).slice(0, 10),
  lastPosition: (report.positions ?? []).slice(-1)[0] ?? null,
  stepStoppedBecause: report.stepStoppedBecause ?? null,
  error: report.error ?? null,
  initializeOk: report.initialize?.success ?? null,
  launchOk: report.launch?.success ?? null,
  configurationDoneOk: report.configurationDone?.success ?? null,
  threads: report.threads?.body?.threads ?? null,
  stackFramesAtStart: report.stackTraceInitial?.body?.stackFrames?.length ?? null,
  traceLoadReply: report.traceLoadReply ?? null,
  pageErrors: report.pageErrors ?? [],
  consoleLines: report.consoleLines ?? [],
};
if (outFile) writeFileSync(outFile, `${JSON.stringify({ summary, full: report }, null, 2)}\n`);
console.log(JSON.stringify(summary, null, 2));

// A container that loads but cannot step is a FINDING, and the exit status says which.
process.exit(summary.phases?.traceLoaded && summary.stepsTaken > 0 ? 0 : 1);
