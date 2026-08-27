// The M27 browser arms, measured ONCE and shared.
//
//   AVM_WASM_PATH=… M27_CHROMIUM=… node tools/run_browser_arms.mjs <work-dir>
//
// M20's convention, kept by M22, M23, M24, M25 and M26: several checks each deriving "how many
// requests the public-only page made" from their own browser launch is how two checks come to
// disagree about a number nothing changed — and it is also six browsers.
//
// ===========================================================================================
// FIVE ARMS, EACH IN ITS OWN PAGE, AND THE ISOLATION IS LOAD-BEARING.
// ===========================================================================================
//
//   publicOnly       the reference arm. A token transfer, executed. Its network log is what
//                    `verify_public_only_page_never_fetches_barretenberg` reads.
//   provingControl   THE NEGATIVE CONTROL. A page that deliberately initialises bb.js, so the
//                    absence above is measured by an instrument shown to be capable of seeing one.
//   timer            blocks on a real timer, across a page FREEZE — which is what a backgrounded
//                    tab does to timers.
//   download         the product claim: the container the page offers, written to disk by the
//                    browser's own download machinery, then read by `ct-print`.
//   modules          what the page's own JavaScript can see of the module: the twelve imports, the
//                    fifty-three exports, and which poseidon it is using.
//
// A FRESH PAGE PER ARM, because a network log is per page and an arm that inherited another arm's
// requests could not distinguish "this page fetched barretenberg" from "some page did". The
// browser process is shared; nothing else is.

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

import {
  CdpConnection,
  launchChromium,
  openPage,
  requestsMatching,
  serveDirectory,
} from './browser_cdp.mjs';

const REPO = path.resolve(import.meta.dirname, '..');
const WORK = process.argv[2] ?? path.join(process.env.HOME, '.cache', 'aztec-m27-browser');
mkdirSync(WORK, { recursive: true });

function fail(message) {
  process.stderr.write(`run_browser_arms: ${message}\n`);
  process.exit(2);
}

const AVM_WASM = process.env.AVM_WASM_PATH;
if (!AVM_WASM || !existsSync(AVM_WASM)) fail(`AVM_WASM_PATH is not set to an existing module (${AVM_WASM})`);

const CHROMIUM = process.env.M27_CHROMIUM ?? '/usr/bin/chromium';
if (!existsSync(CHROMIUM)) fail(`no chromium at ${CHROMIUM}`);

const DIST = path.join(REPO, 'browser/dist');
if (!existsSync(path.join(DIST, 'demo.js'))) fail(`no built bundle at ${DIST}. Remedy: node browser/build.mjs`);

const CT_WRITER = path.join(REPO, 'ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm');
if (!existsSync(CT_WRITER)) {
  fail(`no ct_writer.wasm at ${CT_WRITER}. Remedy: verification/build_ct_writer_wasm.sh`);
}

// ---------------------------------------------------------------------------------------------
// The Token artifact. Searched across the roots that carry one, with the RESIDUE REPORTED, because
// this tree has two @aztec nightly lines installed at once and they are not interchangeable.
// `tools/run_join_arms.mjs` does the same, for the same reason.
// ---------------------------------------------------------------------------------------------
const ARTIFACT_REL = 'node_modules/@aztec/noir-contracts.js/artifacts/token_contract-Token.json';
const ARTIFACT_ROOTS = ['diffsim', 'spike', 'drift', 'probe-mt', 'orchestration'];
const artifactSearch = ARTIFACT_ROOTS.map((r) => ({
  root: r,
  file: path.join(REPO, r, ARTIFACT_REL),
  found: existsSync(path.join(REPO, r, ARTIFACT_REL)),
}));
const artifactHit = artifactSearch.find((a) => a.found);
if (!artifactHit) fail(`no ${ARTIFACT_REL} under any of: ${ARTIFACT_ROOTS.join(', ')}`);

// ---------------------------------------------------------------------------------------------
// The served site: the built bundle, plus the three assets a page fetches at run time.
//
// THE ASSETS ARE COPIED RATHER THAN SYMLINKED, so the sha256 this run reports is of the bytes the
// browser actually received. A symlink into a build tree that a later build replaces is a fixture
// that changes under a measurement, which this campaign has a recorded defect for.
// ---------------------------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------------------------
const server = await serveDirectory(SITE);
const { child, endpoint, stderrChunks } = await launchChromium(CHROMIUM, {
  userDataDir: path.join(WORK, 'chrome-profile'),
});
const conn = await CdpConnection.connect(endpoint);

const arms = {};
let exitCode = 0;

/** Everything a page saw, in the shape every assertion reads. */
function pageFacts(page) {
  return {
    requests: page.requests.map((r) => ({ url: r.url.replace(server.origin, ''), type: r.type, initiator: r.initiator })),
    requestCount: page.requests.length,
    barretenbergRequests: requestsMatching(page.requests, 'barretenberg').map((r) => r.url.replace(server.origin, '')),
    avmWasmRequests: requestsMatching(page.requests, 'avm.wasm').map((r) => r.url.replace(server.origin, '')),
    artifactRequests: requestsMatching(page.requests, 'Token.json').map((r) => r.url.replace(server.origin, '')),
    ctWriterRequests: requestsMatching(page.requests, 'ct_writer.wasm').map((r) => r.url.replace(server.origin, '')),
    consoleErrors: page.console.filter((c) => c.level === 'error').map((c) => c.text),
    pageErrors: [...page.errors],
  };
}

try {
  // -------------------------------------------------------------------------------------------
  // ARM 1 — the public-only page. A token transfer, executed, and every request it made.
  // -------------------------------------------------------------------------------------------
  {
    const page = await openPage(conn, `${server.origin}/index.html`);
    await page.eval('globalThis.avmDemoReady === true');
    const report = await page.eval('window.avmDemo.armTokenTransfer()');
    const status = await page.eval('window.avmDemo.status()');
    arms.publicOnly = { ...pageFacts(page), transfer: report, status };
    await page.close();
  }

  // -------------------------------------------------------------------------------------------
  // ARM 2 — THE NEGATIVE CONTROL. The same page, the same observer, one extra call.
  //
  // Without this, "no request contained 'barretenberg'" is satisfied by a network log that is
  // empty, by an observer attached too late, and by a needle that never matched anything. With it,
  // the SAME predicate over the SAME machinery has to answer the other way.
  // -------------------------------------------------------------------------------------------
  {
    const page = await openPage(conn, `${server.origin}/index.html`);
    await page.eval('globalThis.avmDemoReady === true');
    let control;
    try {
      control = await page.eval('window.avmDemo.loadProvingStack()');
    } catch (e) {
      control = { fetched: false, error: String(e.message ?? e) };
    }
    arms.provingControl = { ...pageFacts(page), control };
    await page.close();
  }

  // -------------------------------------------------------------------------------------------
  // ARM 3 — blocks on a real timer, ACROSS A FREEZE.
  //
  // `Page.setWebLifecycleState('frozen')` is what Chromium does to a backgrounded tab it decides to
  // stop paying for: timers stop entirely. Thawing it is the moment the monotonicity rule has to
  // work — `max(prev + minBlockSpacingSeconds, floor(now/1000))` takes its SECOND branch, having
  // been taking the first while blocks were 250 ms apart. A runtime that assumed even ticks
  // produces a duplicate timestamp here.
  //
  // `Emulation.setCPUThrottlingRate` runs alongside it, because a frozen tab and a slow tab are
  // different failures and the rule has to survive both.
  // -------------------------------------------------------------------------------------------
  {
    const page = await openPage(conn, `${server.origin}/index.html`);
    await page.eval('globalThis.avmDemoReady === true');
    await page.eval('window.avmDemo.armTokenTransfer !== undefined');
    const started = await page.eval('window.avmDemo.startTicking(250)');
    await new Promise((r) => setTimeout(r, 1500));
    const beforeFreeze = await page.eval('window.avmDemo.status()');

    await page.send('Emulation.setCPUThrottlingRate', { rate: 20 });
    await page.send('Page.setWebLifecycleState', { state: 'frozen' });
    const frozenFor = 3000;
    await new Promise((r) => setTimeout(r, frozenFor));
    await page.send('Page.setWebLifecycleState', { state: 'active' });
    await new Promise((r) => setTimeout(r, 1500));
    await page.send('Emulation.setCPUThrottlingRate', { rate: 1 });
    await new Promise((r) => setTimeout(r, 1000));

    const stopped = await page.eval('window.avmDemo.stopTicking()');
    arms.timer = {
      ...pageFacts(page),
      // Hoisted to the top level of the arm rather than left inside `started`: the check reads it
      // to say "this is a REAL timer, not a fake clock", and a field two levels down reads as
      // MISSING when the shape moves — which is what it did on the first run.
      intervalMs: started.intervalMs,
      started,
      frozenForMs: frozenFor,
      cpuThrottlingRate: 20,
      beforeFreezeLog: beforeFreeze.log,
      ...stopped,
    };
    await page.close();
  }

  // -------------------------------------------------------------------------------------------
  // ARM 4 — THE PRODUCT CLAIM. The page offers a `.ct` container; the BROWSER downloads it.
  //
  // `Browser.setDownloadBehavior` with a real directory, and the file is then read off DISK — not
  // out of the page. That is the difference between "the page could have produced a container" and
  // "a container came out of the browser", and it is the difference the milestone's sentence is
  // about.
  // -------------------------------------------------------------------------------------------
  {
    const page = await openPage(conn, `${server.origin}/index.html`, { downloadPath: DOWNLOADS });
    await page.eval('globalThis.avmDemoReady === true');
    const recording = await page.eval('window.avmDemo.armRecord()');
    // The download is asynchronous with respect to the click. Bounded, and exceeding the bound is a
    // failure rather than a silent zero-file directory.
    const deadline = Date.now() + 30_000;
    let files = [];
    while (Date.now() < deadline) {
      files = readdirSync(DOWNLOADS).filter((f) => f.endsWith('.ct'));
      if (files.length) break;
      await new Promise((r) => setTimeout(r, 200));
    }
    const downloaded = files.map((f) => ({
      name: f,
      path: path.join(DOWNLOADS, f),
      bytes: statSync(path.join(DOWNLOADS, f)).size,
      sha256: sha(path.join(DOWNLOADS, f)),
    }));
    const { containerBase64, ...meta } = recording;
    arms.download = {
      ...pageFacts(page),
      recording: meta,
      inPageBytes: Buffer.from(containerBase64, 'base64').length,
      inPageSha256: createHash('sha256').update(Buffer.from(containerBase64, 'base64')).digest('hex'),
      downloaded,
      downloadDir: DOWNLOADS,
    };
    await page.close();
  }

  // -------------------------------------------------------------------------------------------
  // ARM 5 — what the PAGE can see of the module. Read in the page, never from Node.
  // -------------------------------------------------------------------------------------------
  {
    const page = await openPage(conn, `${server.origin}/index.html`);
    await page.eval('globalThis.avmDemoReady === true');
    await page.eval('window.avmDemo.armTokenTransfer()');
    const facts = await page.eval(`(async () => {
      const s = window.avmDemo.status();
      return { status: s };
    })()`);
    arms.modules = { ...pageFacts(page), ...facts };
    await page.close();
  }
} catch (e) {
  exitCode = 1;
  arms.error = { message: String(e && e.message ? e.message : e), stack: String(e && e.stack) };
} finally {
  conn.close();
  child.kill('SIGTERM');
  // The escalation is not decoration: a headless renderer that has wedged does not answer SIGTERM,
  // and a browser left running is what turns the next sweep into a mystery.
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
  artifact: {
    root: artifactHit.root,
    search: artifactSearch.map((a) => `${a.root}:${a.found ? 'yes' : 'no'}`),
    bytes: statSync(artifactHit.file).size,
  },
  site: SITE,
  serverRequests: server.requests,
  chunks: chunks ? { totalGzipBytes: chunks.totalGzipBytes, eager: chunks.eager } : null,
  browserStderrLines: stderrChunks.join('').split('\n').filter(Boolean).length,
  arms,
};
process.stdout.write(JSON.stringify(out, null, 2) + '\n');
writeFileSync(path.join(WORK, 'browser-last.json'), JSON.stringify(out, null, 2) + '\n');
process.exit(exitCode);
