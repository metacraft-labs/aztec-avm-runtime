// The M32 worker arms, measured ONCE and shared.
//
//   AVM_WASM_PATH=… M32_CHROMIUM=… node tools/run_worker_arms.mjs <work-dir>
//
// M20's convention, kept by every milestone since: four checks each launching a browser is four
// browsers and four chances to disagree about a number nothing changed.
//
// ===========================================================================================
// SIX ARMS, EACH IN ITS OWN PAGE, AND TWO OF THEM ARE A PAIR
// ===========================================================================================
//
//   boot            the node is in a worker at all: the protocol, the three subscriptions, and a
//                   real token transfer executed on the other thread.
//   workerBlocked   a busy main thread, with the chain IN THE WORKER. Warm window, then a four
//                   second synchronous spin.
//   mainBlocked     THE CONTROL, and without it `workerBlocked` measures nothing: the same load,
//                   the same windows, the same spin, with the runtime ON the main thread. It is a
//                   SEPARATE PAGE for the same reason every M27 arm is — a page that had already
//                   spawned a worker would have a second thread in it, which is the variable.
//   throttled       blocks on a real timer in the worker, across a page freeze AND a CPU throttle
//                   applied to the worker's own target. Whether either reaches the worker is not
//                   assumed: the worker timestamps its own blocks and the gap is the evidence.
//   transferable    the `.ct` container crossing as a transferable, with the copy beside it, and
//                   the worker's own reading of its buffer after each.
//   restart         terminate mid-chain, open a second worker, replay the snapshot.
//
// ===========================================================================================
// THE THROTTLE IS APPLIED TO THE WORKER'S OWN CDP TARGET, NOT ONLY TO THE PAGE
// ===========================================================================================
//
// M27 verified monotonic timestamps under throttling on the MAIN THREAD. A worker's timers throttle
// differently, so inheriting that result would be inheriting a measurement of a different thing.
// `Page.setWebLifecycleState('frozen')` is a document-level operation and a dedicated worker is
// frozen with its document — but "is" there is a claim about Chromium, so this runner ALSO attaches
// to the worker target through `Target.setAutoAttach` and sends `Emulation.setCPUThrottlingRate` to
// the worker's own session. What each mechanism did is RECORDED (`throttle.applied`, with any error
// text), and the check requires the WORKER's own clock to show the gap — so a run in which neither
// mechanism reached the worker is red rather than quietly green.

import { execFileSync } from 'node:child_process';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import process from 'node:process';

import { CdpConnection, launchChromium, openPage, requestsMatching, serveDirectory } from './browser_cdp.mjs';

const REPO = path.resolve(import.meta.dirname, '..');
const WORK = process.argv[2] ?? path.join(process.env.HOME, '.cache', 'aztec-m32-worker');
mkdirSync(WORK, { recursive: true });

function fail(message) {
  process.stderr.write(`run_worker_arms: ${message}\n`);
  process.exit(2);
}

const AVM_WASM = process.env.AVM_WASM_PATH;
if (!AVM_WASM || !existsSync(AVM_WASM)) fail(`AVM_WASM_PATH is not set to an existing module (${AVM_WASM})`);

const CHROMIUM = process.env.M32_CHROMIUM ?? '/usr/bin/chromium';
if (!existsSync(CHROMIUM)) fail(`no chromium at ${CHROMIUM}`);

const DIST = path.join(REPO, 'browser/dist');
for (const required of ['worker.js', 'worker-demo.js', 'worker.html']) {
  if (!existsSync(path.join(DIST, required))) {
    fail(`no ${required} at ${DIST}. Remedy: node browser/build.mjs`);
  }
}

const CT_WRITER = path.join(REPO, 'ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm');
if (!existsSync(CT_WRITER)) {
  fail(`no ct_writer.wasm at ${CT_WRITER}. Remedy: verification/build_ct_writer_wasm.sh`);
}

const ARTIFACT_REL = 'node_modules/@aztec/noir-contracts.js/artifacts/token_contract-Token.json';
const ARTIFACT_ROOTS = ['diffsim', 'spike', 'drift', 'probe-mt', 'orchestration'];
const artifactSearch = ARTIFACT_ROOTS.map((r) => ({
  root: r,
  file: path.join(REPO, r, ARTIFACT_REL),
  found: existsSync(path.join(REPO, r, ARTIFACT_REL)),
}));
const artifactHit = artifactSearch.find((a) => a.found);
if (!artifactHit) fail(`no ${ARTIFACT_REL} under any of: ${ARTIFACT_ROOTS.join(', ')}`);

// The served site. Copied, not symlinked: the sha256 reported is of the bytes the browser received.
const SITE = path.join(WORK, 'site');
rmSync(SITE, { recursive: true, force: true });
mkdirSync(path.join(SITE, 'assets'), { recursive: true });
function copyTree(from, to) {
  mkdirSync(to, { recursive: true });
  for (const name of readdirSync(from)) {
    if (name.startsWith('.')) continue;
    const src = path.join(from, name);
    const dst = path.join(to, name);
    if (statSync(src).isDirectory()) copyTree(src, dst);
    else copyFileSync(src, dst);
  }
}
copyTree(DIST, SITE);
copyFileSync(AVM_WASM, path.join(SITE, 'assets/avm.wasm'));
copyFileSync(CT_WRITER, path.join(SITE, 'assets/ct_writer.wasm'));
copyFileSync(artifactHit.file, path.join(SITE, 'assets/token_contract-Token.json'));

const sha = (f) => createHash('sha256').update(readFileSync(f)).digest('hex');

const DOWNLOADS = path.join(WORK, 'downloads');
rmSync(DOWNLOADS, { recursive: true, force: true });
mkdirSync(DOWNLOADS, { recursive: true });

const PAGE = 'worker.html';
const BUSY_MS = Number(process.env.M32_BUSY_MS ?? 4000);
const WARM_MS = Number(process.env.M32_WARM_MS ?? 4000);
const TICK_MS = Number(process.env.M32_TICK_MS ?? 250);

// ---------------------------------------------------------------------------------------------
const server = await serveDirectory(SITE);
const { child, endpoint, stderrChunks } = await launchChromium(CHROMIUM, {
  userDataDir: path.join(WORK, 'chrome-profile'),
});
const conn = await CdpConnection.connect(endpoint);

const arms = {};
let exitCode = 0;

function pageFacts(page) {
  return {
    requests: page.requests.map((r) => ({ url: r.url.replace(server.origin, ''), type: r.type, initiator: r.initiator })),
    requestCount: page.requests.length,
    /** DD-11 travels with the worker: the worker must not fetch the proving stack either. */
    barretenbergRequests: requestsMatching(page.requests, 'barretenberg').map((r) => r.url.replace(server.origin, '')),
    workerRequests: requestsMatching(page.requests, '/worker.js').map((r) => r.url.replace(server.origin, '')),
    avmWasmRequests: requestsMatching(page.requests, 'avm.wasm').map((r) => r.url.replace(server.origin, '')),
    ctWriterRequests: requestsMatching(page.requests, 'ct_writer.wasm').map((r) => r.url.replace(server.origin, '')),
    artifactRequests: requestsMatching(page.requests, 'Token.json').map((r) => r.url.replace(server.origin, '')),
    consoleErrors: page.console.filter((c) => c.level === 'error').map((c) => c.text),
    pageErrors: [...page.errors],
  };
}

/**
 * Attach to every worker target this page spawns, and record what the WORKER itself fetched.
 *
 * `Target.setAutoAttach` on the page's session delivers `Target.attachedToTarget` for dedicated
 * workers. Two things are done with each session and both are load-bearing:
 *
 *   * `Network.enable`, because A WORKER'S FETCHES ARE NOT IN THE PAGE'S NETWORK LOG. Measured on
 *     the first run of these arms: the boot arm's page log carries `/worker.js` and NOT
 *     `/assets/avm.wasm`, because the worker fetched the module. So asking DD-11's question —
 *     "no request contained 'barretenberg'" — of the PAGE's log would be an absence asked of a log
 *     that excludes the subject by construction, which `CAMPAIGN-BRIEF.md` lists twice as a defect
 *     that shipped. The worker's own log is where that question can be answered, and `avm.wasm`
 *     appearing in it is the positive control that the log is not empty for the wrong reason.
 *   * `Emulation.setCPUThrottlingRate` in the throttle arm, whose refusal is itself a measurement.
 */
function watchWorkerTargets(page) {
  const workers = [];
  const workerRequests = [];
  // FILTERED BY THE PARENT SESSION, because the arms share one browser and one connection: an
  // unfiltered listener would let arm 6's workers be counted by arm 4's list, and
  // `workerTargetCount` is an assertion.
  const off = conn.on((msg) => {
    if (msg.method === 'Network.requestWillBeSent') {
      const w = workers.find((x) => x.sessionId === msg.sessionId);
      if (w) workerRequests.push({ worker: w.url, url: msg.params.request.url, type: msg.params.type });
      return;
    }
    if (msg.method !== 'Target.attachedToTarget') return;
    if (msg.sessionId !== page.sessionId) return;
    const info = msg.params.targetInfo ?? {};
    if (info.type !== 'worker' && info.type !== 'dedicated_worker') return;
    const entry = { sessionId: msg.params.sessionId, url: info.url, type: info.type, network: 'pending' };
    workers.push(entry);
    conn
      .send('Network.enable', {}, entry.sessionId)
      .then(() => { entry.network = 'enabled'; })
      .catch((e) => { entry.network = `refused: ${String(e.message ?? e)}`; });
  });
  workers.off = off;
  workers.requests = workerRequests;
  return workers;
}

/**
 * Ask the WORKER's own global scope what it is.
 *
 * The measurement `test_worker_transferable_container_not_copied` needs: the runtime ran where there
 * is no `document`. Inferring that from the file it was built into would be inferring it from the
 * build; this asks the thread. `Runtime.evaluate` on the worker's session runs in the worker's
 * global scope, so `typeof document` there is the worker's answer and not the page's.
 */
async function probeWorkerGlobals(workers) {
  const out = [];
  for (const w of workers) {
    try {
      await conn.send('Runtime.enable', {}, w.sessionId);
      const r = await conn.send(
        'Runtime.evaluate',
        {
          expression:
            '({ hasDocument: typeof document !== "undefined",'
            + ' hasWindow: typeof window !== "undefined",'
            + ' isDedicatedWorker: typeof DedicatedWorkerGlobalScope !== "undefined" && self instanceof DedicatedWorkerGlobalScope,'
            + ' hasPostMessage: typeof postMessage === "function",'
            + ' href: String(location.href) })',
          returnByValue: true,
        },
        w.sessionId,
      );
      out.push({ url: w.url, ...(r.result?.value ?? {}), error: r.exceptionDetails ? String(r.exceptionDetails.text) : null });
    } catch (e) {
      out.push({ url: w.url, error: String(e.message ?? e) });
    }
  }
  return out;
}

/** What a worker session saw, in the shape the page facts use. */
function workerFacts(workers) {
  const requests = (workers.requests ?? []).map((r) => ({
    worker: r.worker.replace(/^https?:\/\/[^/]+/, ''),
    url: r.url.replace(/^https?:\/\/[^/]+/, ''),
    type: r.type,
  }));
  return {
    workerTargets: workers.map((w) => ({ url: w.url, type: w.type, network: w.network })),
    workerTargetCount: workers.length,
    workerRequestLog: requests,
    workerRequestCount: requests.length,
    workerBarretenbergRequests: requests.filter((r) => r.url.includes('barretenberg')).map((r) => r.url),
    workerAvmWasmRequests: requests.filter((r) => r.url.includes('avm.wasm')).map((r) => r.url),
    workerCtWriterRequests: requests.filter((r) => r.url.includes('ct_writer.wasm')).map((r) => r.url),
  };
}

try {
  // -------------------------------------------------------------------------------------------
  // ARM 1 — the node is in a worker, and a real transaction ran on it.
  // -------------------------------------------------------------------------------------------
  {
    const page = await openPage(conn, `${server.origin}/${PAGE}`);
    const workers = watchWorkerTargets(page);
    await page.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
    await page.eval('globalThis.avmWorkerDemoReady === true');
    const boot = await page.eval('window.avmWorkerDemo.armWorkerBoot()');
    const workerGlobals = await probeWorkerGlobals(workers);
    arms.boot = { ...pageFacts(page), ...boot, ...workerFacts(workers), workerGlobals };
    workers.off();
    await page.close();
  }

  // -------------------------------------------------------------------------------------------
  // ARM 2 — the chain in the WORKER, with this page's main thread deliberately blocked.
  // -------------------------------------------------------------------------------------------
  {
    const page = await openPage(conn, `${server.origin}/${PAGE}`);
    await page.eval('globalThis.avmWorkerDemoReady === true');
    const report = await page.eval(
      `window.avmWorkerDemo.armWorkerUnderMainThreadBlock(${JSON.stringify({ busyMs: BUSY_MS, warmMs: WARM_MS, intervalMs: TICK_MS })})`,
      180_000,
    );
    arms.workerBlocked = { ...pageFacts(page), ...report };
    await page.close();
  }

  // -------------------------------------------------------------------------------------------
  // ARM 3 — THE CONTROL. The same load with the runtime on the main thread.
  // -------------------------------------------------------------------------------------------
  {
    const page = await openPage(conn, `${server.origin}/${PAGE}`);
    await page.eval('globalThis.avmWorkerDemoReady === true');
    const report = await page.eval(
      `window.avmWorkerDemo.armMainThreadControl(${JSON.stringify({ busyMs: BUSY_MS, warmMs: WARM_MS, intervalMs: TICK_MS })})`,
      180_000,
    );
    arms.mainBlocked = { ...pageFacts(page), ...report };
    await page.close();
  }

  // -------------------------------------------------------------------------------------------
  // ARM 4 — blocks on a real timer in the worker, THROTTLED.
  // -------------------------------------------------------------------------------------------
  {
    const page = await openPage(conn, `${server.origin}/${PAGE}`);
    const workers = watchWorkerTargets(page);
    await page.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
    await page.eval('globalThis.avmWorkerDemoReady === true');
    const started = await page.eval(`window.avmWorkerDemo.startTicking(${TICK_MS})`, 180_000);
    // Let the chain settle into its cadence before anything is done to it, so "before the freeze"
    // is a measured stretch of ordinary production rather than the first tick.
    await new Promise((r) => setTimeout(r, 4000));

    const applied = [];
    // (a) the WORKER's own target. Emulation is not guaranteed to be supported on a worker session;
    //     whether it answered is recorded rather than assumed.
    for (const w of workers) {
      try {
        await conn.send('Emulation.setCPUThrottlingRate', { rate: 20 }, w.sessionId);
        applied.push({ mechanism: 'worker.Emulation.setCPUThrottlingRate', rate: 20, url: w.url, ok: true });
      } catch (e) {
        applied.push({ mechanism: 'worker.Emulation.setCPUThrottlingRate', url: w.url, ok: false, error: String(e.message ?? e) });
      }
    }
    // (b) the document. A dedicated worker is frozen with its document.
    try {
      await page.send('Emulation.setCPUThrottlingRate', { rate: 20 });
      applied.push({ mechanism: 'page.Emulation.setCPUThrottlingRate', rate: 20, ok: true });
    } catch (e) {
      applied.push({ mechanism: 'page.Emulation.setCPUThrottlingRate', ok: false, error: String(e.message ?? e) });
    }
    try {
      await page.send('Page.setWebLifecycleState', { state: 'frozen' });
      applied.push({ mechanism: 'Page.setWebLifecycleState frozen', ok: true });
    } catch (e) {
      applied.push({ mechanism: 'Page.setWebLifecycleState frozen', ok: false, error: String(e.message ?? e) });
    }

    const frozenFor = Number(process.env.M32_FREEZE_MS ?? 4000);
    await new Promise((r) => setTimeout(r, frozenFor));

    try {
      await page.send('Page.setWebLifecycleState', { state: 'active' });
    } catch { /* thawing a page that was never frozen is not an error worth failing the arm for */ }
    await new Promise((r) => setTimeout(r, 3000));
    for (const w of workers) {
      try {
        await conn.send('Emulation.setCPUThrottlingRate', { rate: 1 }, w.sessionId);
      } catch { /* it was recorded above whether this ever worked */ }
    }
    try {
      await page.send('Emulation.setCPUThrottlingRate', { rate: 1 });
    } catch { /* as above */ }
    await new Promise((r) => setTimeout(r, 3000));

    const stopped = await page.eval('window.avmWorkerDemo.stopTicking()', 180_000);
    arms.throttled = {
      ...pageFacts(page),
      intervalMs: started.intervalMs,
      started,
      frozenForMs: frozenFor,
      cpuThrottlingRate: 20,
      throttle: { applied, workerTargets: workers.map((w) => ({ url: w.url, type: w.type })) },
      ...workerFacts(workers),
      ...stopped,
    };
    workers.off();
    await page.close();
  }

  // -------------------------------------------------------------------------------------------
  // ARM 5 — the container as a transferable, with the copy as its control.
  // -------------------------------------------------------------------------------------------
  {
    const page = await openPage(conn, `${server.origin}/${PAGE}`, { downloadPath: DOWNLOADS });
    const workers = watchWorkerTargets(page);
    await page.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
    await page.eval('globalThis.avmWorkerDemoReady === true');
    const report = await page.eval('window.avmWorkerDemo.armTransferable()', 300_000);
    const workerGlobals = await probeWorkerGlobals(workers);
    const deadline = Date.now() + 30_000;
    let files = [];
    while (Date.now() < deadline) {
      files = readdirSync(DOWNLOADS).filter((f) => f.endsWith('.ct'));
      if (files.length) break;
      await new Promise((r) => setTimeout(r, 200));
    }
    arms.transferable = {
      ...pageFacts(page),
      ...workerFacts(workers),
      workerGlobals,
      ...report,
      downloaded: files.map((f) => ({
        name: f,
        path: path.join(DOWNLOADS, f),
        bytes: statSync(path.join(DOWNLOADS, f)).size,
        sha256: sha(path.join(DOWNLOADS, f)),
      })),
      downloadDir: DOWNLOADS,
    };
    workers.off();
    await page.close();
  }

  // -------------------------------------------------------------------------------------------
  // ARM 6 — terminate and restart from a snapshot.
  // -------------------------------------------------------------------------------------------
  {
    const page = await openPage(conn, `${server.origin}/${PAGE}`);
    const workers = watchWorkerTargets(page);
    await page.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
    await page.eval('globalThis.avmWorkerDemoReady === true');
    const report = await page.eval('window.avmWorkerDemo.armRestart({"blocks":3})', 300_000);
    arms.restart = {
      ...pageFacts(page),
      ...report,
      // FOUR worker targets is the measurement that a second, third and fourth worker really were
      // created: a restart that reused the first thread would show one.
      ...workerFacts(workers),
    };
    workers.off();
    await page.close();
  }
} catch (e) {
  exitCode = 1;
  arms.error = { message: String(e && e.message ? e.message : e), stack: String(e && e.stack) };
} finally {
  conn.close();
  child.kill('SIGTERM');
  setTimeout(() => child.kill('SIGKILL'), 2000).unref?.();
  await server.close();
}

const chunks = existsSync(path.join(DIST, 'chunks.json'))
  ? JSON.parse(readFileSync(path.join(DIST, 'chunks.json'), 'utf8'))
  : null;

const out = {
  measuredAt: new Date().toISOString(),
  chromium: execFileSync(CHROMIUM, ['--version'], { encoding: 'utf8' }).trim(),
  node: process.version,
  module: { path: AVM_WASM, bytes: statSync(AVM_WASM).size, sha256: sha(AVM_WASM) },
  ctWriter: { path: CT_WRITER, bytes: statSync(CT_WRITER).size, sha256: sha(CT_WRITER) },
  workerBundle: {
    path: path.join(DIST, 'worker.js'),
    bytes: statSync(path.join(DIST, 'worker.js')).size,
    sha256: sha(path.join(DIST, 'worker.js')),
  },
  artifact: {
    root: artifactHit.root,
    search: artifactSearch.map((a) => `${a.root}:${a.found ? 'yes' : 'no'}`),
    bytes: statSync(artifactHit.file).size,
  },
  parameters: { busyMs: BUSY_MS, warmMs: WARM_MS, tickMs: TICK_MS },
  site: SITE,
  serverRequests: server.requests,
  chunks: chunks ? { totalGzipBytes: chunks.totalGzipBytes, eager: chunks.eager } : null,
  browserStderrLines: stderrChunks.join('').split('\n').filter(Boolean).length,
  arms,
};
process.stdout.write(JSON.stringify(out, null, 2) + '\n');
writeFileSync(path.join(WORK, 'worker-last.json'), JSON.stringify(out, null, 2) + '\n');
process.exit(exitCode);
