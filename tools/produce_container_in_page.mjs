#!/usr/bin/env node
// produce_container_in_page.mjs — L4: a settled transaction becomes a `.ct` IN THE BROWSER.
//
// ================================================================================================
// THE ACCEPTANCE CRITERION IS THE CONTAINER, AND IT LEAVES THE PAGE.
// ================================================================================================
//
// Not "the page reported success" — the page's own numbers are reported too, but what this tool
// writes to disk is THE BYTES THE PAGE PRODUCED, so `ct-print` can read them and a check can
// compare them against the Node path's container. A page that ran the whole replay and emitted a
// malformed container would satisfy every progress message and fail that.
//
// Everything is served from ONE local origin: the bundle, `avm.wasm`, `ct_writer.wasm` and the
// fixture. Nothing is fetched from the network — the fixture is L1's recording of a live chain,
// played back through upstream's own client, so the run measures the browser rather than somebody
// else's node.
//
// Usage:
//   node tools/produce_container_in_page.mjs --avm <avm.wasm> --ct-writer <ct_writer.wasm> \
//        [--fixture <path>] [--out <container.ct>] [--report <json>]

import { copyFileSync, existsSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { CdpConnection, launchChromium, openPage, serveDirectory } from './browser_cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d; };

const avm = arg('avm', process.env.AVM_WASM_PATH);
const ctWriter = arg('ct-writer',
  path.join(REPO, 'ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm'));
const fixture = arg('fixture', path.join(REPO, 'replay/fixtures/testnet_replay_tx.json'));
const outFile = arg('out');
const reportFile = arg('report');
const DIST = path.join(REPO, 'replay/dist-browser');

for (const [what, p] of [['avm.wasm', avm], ['ct_writer.wasm', ctWriter], ['the fixture', fixture]]) {
  if (!p || !existsSync(p)) {
    console.error(`produce-container-in-page: ${what} is missing (${p}).`);
    process.exit(2);
  }
}
if (!existsSync(path.join(DIST, 'browser-demo/replay_in_page.js'))) {
  console.error('produce-container-in-page: the browser bundle is not built.\n'
    + '  Remedy: just build-replay-browser-bundle');
  process.exit(2);
}

const CHROMIUM = process.env.M27_CHROMIUM
  ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// ---- the site --------------------------------------------------------------------------------
const site = mkdtempSync(path.join(tmpdir(), 'l4-page-'));
mkdirSync(path.join(site, 'bundle'), { recursive: true });
for (const f of ['browser-demo', 'src']) {
  mkdirSync(path.join(site, 'bundle', f), { recursive: true });
}
// The whole dist tree, flat-copied, because the entry imports its sibling chunks by relative path.
const copyTree = (from, to) => {
  for (const e of require('node:fs').readdirSync(from, { withFileTypes: true })) {
    const s = path.join(from, e.name);
    const d = path.join(to, e.name);
    if (e.isDirectory()) { mkdirSync(d, { recursive: true }); copyTree(s, d); }
    else copyFileSync(s, d);
  }
};
const { createRequire } = await import('node:module');
const require = createRequire(import.meta.url);
copyTree(DIST, path.join(site, 'bundle'));
copyFileSync(avm, path.join(site, 'avm.wasm'));
copyFileSync(ctWriter, path.join(site, 'ct_writer.wasm'));
copyFileSync(fixture, path.join(site, 'fixture.json'));

writeFileSync(path.join(site, 'index.html'), `<!doctype html>
<meta charset="utf-8">
<title>L4 — produce a .ct in the page</title>
<body><pre id="out">starting…</pre>
<script type="module">
import { replayInPage } from './bundle/browser-demo/replay_in_page.js';
const progress = [];
window.__progress = progress;
window.__result = null;
window.__error = null;
(async () => {
  try {
    window.__result = await replayInPage({
      fixtureUrl: './fixture.json',
      avmWasmUrl: './avm.wasm',
      ctWriterWasmUrl: './ct_writer.wasm',
      onProgress: (phase, detail) => {
        progress.push({ phase, detail: detail ?? null, t: Date.now() });
        document.getElementById('out').textContent = phase + (detail ? ' — ' + detail : '');
      },
    });
  } catch (e) {
    window.__error = String((e && e.stack) || e);
    document.getElementById('out').textContent = 'ERROR';
  }
})();
</script></body>`);

// ---- drive it --------------------------------------------------------------------------------
const server = await serveDirectory(site);
const browser = await launchChromium(CHROMIUM);
const conn = await CdpConnection.connect(browser.endpoint, 300000);
let result = null;
let containerBase64 = null;
let pageErr = null;
let progress = [];
let consoleLines = [];
let pageThrows = [];
let requests = [];
try {
  const page = await openPage(conn, `${server.origin}/index.html`, { loadTimeoutMs: 60000 });
  // POLLED, so no single evaluate has to span the whole run and a stall is a NAMED failure rather
  // than a hang. The bound is the tool's, not the CDP layer's.
  const deadline = Date.now() + 300000;
  for (;;) {
    // `undefined` IS NOT `null`, AND THE FIRST VERSION OF THIS LINE CONFLATED THEM. A `<script
    // type="module">` is DEFERRED, so on the first poll — which happens as soon as `load` fires —
    // the module has not run and `window.__result` is `undefined`. `undefined !== null` is TRUE, so
    // the loop reported "done" immediately and every downstream read failed on a result that did
    // not exist yet. Three states, named, with "starting" distinct from "running".
    const state = await page.eval(`(() => {
      if (typeof window.__result === 'undefined') return 'starting';
      if (window.__error !== null && window.__error !== undefined) return 'error';
      return window.__result === null ? 'running' : 'done';
    })()`, 30000);
    if (state === 'done') {
      // FETCHED IN TWO PIECES, AND THE CONTAINER SEPARATELY. `Runtime.evaluate` with
      // `returnByValue` over an object carrying a ~250 KB base64 string came back UNDEFINED with no
      // exception — a silent serialisation failure that read as "the page produced nothing" over a
      // page that had produced a container. The numbers and the bytes cross as two values now.
      result = await page.eval('(() => { const { containerBase64, ...rest } = window.__result; return rest; })()', 60000);
      containerBase64 = await page.eval('window.__result.containerBase64', 120000);
      break;
    }
    if (state === 'error') { pageErr = await page.eval('window.__error', 30000); break; }
    if (Date.now() > deadline) { pageErr = 'the page did not finish within 300 s'; break; }
    await new Promise((r) => setTimeout(r, 1000));
  }
  progress = (await page.eval('window.__progress ?? null', 30000)) ?? [];
  consoleLines = page.console.slice(0, 40);
  pageThrows = page.errors.slice(0, 10);
  requests = page.requests.map((r) => r.url.replace(server.origin, ''));
  await page.close();
} finally {
  try { conn.close?.(); } catch { /* the browser may already be gone */ }
  try { browser.child.kill('SIGKILL'); } catch { /* idem */ }
  await server.close?.();
}

if (!pageErr && (result === undefined || result === null)) {
  pageErr = 'the page reported done and window.__result did not cross the CDP boundary';
}
if (!pageErr && (typeof containerBase64 !== 'string' || containerBase64.length === 0)) {
  pageErr = `the page produced no container bytes (got ${typeof containerBase64})`;
}
if (pageErr) {
  console.error(`produce-container-in-page: the page failed:\n${pageErr}`);
  for (const c of consoleLines) console.error(`  [${c.level}] ${c.text}`);
  console.error(`  progress: ${JSON.stringify((progress ?? []).map((p) => p.phase))}`);
  // A MODULE THAT FAILS TO LOAD LEAVES NO PROGRESS AND NO `__error`, because the catch that would
  // set `__error` is inside the module that did not run. The page's own uncaught exceptions are the
  // only record of it, so they are printed here rather than summarised away.
  for (const e of pageThrows) console.error(`  page threw: ${String(e).slice(0, 400)}`);
  process.exit(1);
}

// THE BYTES LEAVE THE PAGE. That is the deliverable; the numbers below are its description.
const container = Buffer.from(containerBase64, 'base64');
if (outFile) writeFileSync(outFile, container);

const summary = {
  txHash: result.txHash,
  l2BlockNumber: result.l2BlockNumber,
  preStateBlock: result.preStateBlock,
  hydrationRounds: result.hydrationRounds,
  seeded: `${result.seededNullifiers}N/${result.seededPublicData}P`,
  publishedRevertCode: result.publishedRevertCode,
  replayedRevertCode: result.replayedRevertCode,
  reproduced: result.reproduced,
  comparisons: `${result.comparisonsMatched}/${result.comparisonsTotal}`,
  instructionsExecuted: result.instructionsExecuted,
  steps: result.steps,
  declaredRung: result.declaredRung,
  rootsAgree: result.rootsAgree,
  containerBytes: result.containerBytes,
  containerBytesOnDisk: container.length,
  logEvents: result.logEvents,
  metadataKeys: result.metadataKeys,
  progressPhases: progress.map((p) => p.phase),
  requests,
};
if (reportFile) writeFileSync(reportFile, `${JSON.stringify(summary, null, 2)}\n`);
console.log(JSON.stringify(summary, null, 2));

process.exit(result.reproduced && result.containerBytes > 0 ? 0 : 1);
