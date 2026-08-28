// The M30 VFS arms, measured ONCE in a real browser and shared by four checks.
//
//   M30_NOIR_WASM=… M30_TRACER_WASM=… M30_CHROMIUM=… node tools/run_vfs_arms.mjs <work-dir>
//
// M20's convention, kept by M22 through M29: several checks each launching their own browser
// to derive the same numbers is how two checks come to disagree about something nothing
// changed — and it is also four browsers.
//
// ==========================================================================================
// THREE ARMS, AND THE ISOLATION IS DELIBERATE.
// ==========================================================================================
//
//   modules    what the page's own JavaScript can see of the two modules: their bytes, their
//              sha256, how many imports each DECLARES, and — after every other arm has run —
//              how many either has actually CALLED. Declaring is not reaching.
//   compile    eleven trees compiled in one page: the multi-file tree with a local
//              dependency, its two edits, and the eight controls. One page, because the
//              subject is a module and not a network log, and because a second page load
//              would re-instantiate the module and cost 30 MB of wasm compilation.
//   trace      EDIT, RECOMPILE, RE-TRACE — six passes in ONE page load with ONE
//              instantiation, which is the deliverable's "without reload" clause and is why
//              this arm cannot be split.
//
// ==========================================================================================
// WHAT THE PAGE IS GIVEN, AND WHAT IT IS NOT.
// ==========================================================================================
//
// The site is `verification/m30/page/` plus `tools/m30_vfs_trees.mjs` copied in beside it and
// the two `.wasm` modules under `assets/`. The trees are COPIED rather than symlinked, and
// the copy's sha256 is reported beside the source's, so "the page compiled the tree this
// check is talking about" is a comparison rather than an assumption — a symlink into a tree
// that a later edit changes is a fixture that moves under a measurement, which this campaign
// has a recorded defect for.
//
// There is no bundler anywhere in this path. The page fetches two `.wasm` files and talks to
// them through their C ABIs; if a check finds a compiled Noir program at the end of it, no
// JavaScript compiled it.

import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import process from 'node:process';

import { CdpConnection, launchChromium, openPage, serveDirectory } from './browser_cdp.mjs';

const REPO = path.resolve(import.meta.dirname, '..');
const WORK = process.argv[2] ?? path.join(process.env.HOME, '.cache', 'aztec-m30-vfs');
mkdirSync(WORK, { recursive: true });

function fail(message) {
  process.stderr.write(`run_vfs_arms: ${message}\n`);
  process.exit(2);
}

function sha(file) {
  return createHash('sha256').update(readFileSync(file)).digest('hex');
}

const NOIR_WASM = process.env.M30_NOIR_WASM;
if (!NOIR_WASM || !existsSync(NOIR_WASM)) {
  fail(`M30_NOIR_WASM is not set to an existing module (${NOIR_WASM}). Remedy: verification/build_noir_vfs_wasm.sh`);
}
const TRACER_WASM = process.env.M30_TRACER_WASM;
if (!TRACER_WASM || !existsSync(TRACER_WASM)) {
  fail(`M30_TRACER_WASM is not set to an existing module (${TRACER_WASM}). Remedy: verification/build_noir_tracer_wasm.sh`);
}

const CHROMIUM = process.env.M30_CHROMIUM ?? '/usr/bin/chromium';
if (!existsSync(CHROMIUM)) fail(`no chromium at ${CHROMIUM}`);

const PAGE_DIR = path.join(REPO, 'verification/m30/page');
if (!existsSync(path.join(PAGE_DIR, 'index.html'))) fail(`no page at ${PAGE_DIR}`);
const TREES_SRC = path.join(REPO, 'tools/m30_vfs_trees.mjs');
if (!existsSync(TREES_SRC)) fail(`no trees module at ${TREES_SRC}`);

// ------------------------------------------------------------------------------------------
// The served site.
// ------------------------------------------------------------------------------------------
const SITE = path.join(WORK, 'site');
rmSync(SITE, { recursive: true, force: true });
mkdirSync(path.join(SITE, 'assets'), { recursive: true });
for (const name of readdirSync(PAGE_DIR)) {
  if (name.startsWith('.')) continue;
  const src = path.join(PAGE_DIR, name);
  if (statSync(src).isDirectory()) continue;
  copyFileSync(src, path.join(SITE, name));
}
copyFileSync(TREES_SRC, path.join(SITE, 'm30_vfs_trees.mjs'));
copyFileSync(NOIR_WASM, path.join(SITE, 'assets/noir_wasm.wasm'));
copyFileSync(TRACER_WASM, path.join(SITE, 'assets/noir_tracer_wasm.wasm'));

const server = await serveDirectory(SITE);
const { child, endpoint, stderrChunks } = await launchChromium(CHROMIUM, {
  userDataDir: path.join(WORK, 'chrome-profile'),
});
// THE ROUND-TRIP BOUND IS RAISED, AND THE REASON IS MEASURED.
//
// `browser_cdp.mjs`'s `DEFAULT_TIMEOUT_MS` is 60 s, and every `page.eval` goes through
// `send()` which wraps the whole round trip in it — so the per-call `ms` argument is only
// ever the SMALLER of the two. The compile arm runs eleven Noir compilations inside a
// 14 MB wasm module in one evaluate, which is about ten seconds on this host and is a
// function of the box. Raising the connection's bound to `M30_EVAL_MS` keeps the hang state
// reportable (the mutation harness's M10 arm proves it: a module that spins forever produced
// `Runtime.evaluate did not complete within … ms. That is the HANG state reported as a
// failure.` and the arms run exited non-zero) while leaving room for a slow machine.
const conn = await CdpConnection.connect(endpoint, Number(process.env.M30_EVAL_MS ?? 600_000));

const arms = {};
let exitCode = 0;

// Compiling 30 MB of wasm and then a Noir program inside it is not a 60-second job on a
// loaded box, so the two heavy arms carry their own bound. Exceeding it is a named failure
// upstream (`m30_require_arms` reports the timeout) rather than a hang.
const EVAL_MS = Number(process.env.M30_EVAL_MS ?? 600_000);
const LOAD_MS = Number(process.env.M30_LOAD_MS ?? 180_000);

function pageFacts(page) {
  return {
    requests: page.requests.map((r) => r.url.replace(server.origin, '')),
    requestCount: page.requests.length,
    consoleErrors: page.console.filter((c) => c.level === 'error').map((c) => c.text),
    pageErrors: [...page.errors],
  };
}

async function readyPage() {
  const page = await openPage(conn, `${server.origin}/index.html`, { loadTimeoutMs: LOAD_MS });
  const ready = await page.eval(
    'new Promise((resolve) => { const t = setInterval(() => {' +
      ' if (globalThis.vfsDemoReady === true) { clearInterval(t); resolve("ready"); }' +
      ' if (globalThis.vfsDemoError) { clearInterval(t); resolve("error: " + globalThis.vfsDemoError); }' +
      ' }, 50); })',
    LOAD_MS,
  );
  if (ready !== 'ready') {
    throw new Error(`the page did not become ready: ${ready}`);
  }
  return page;
}

try {
  // ----------------------------------------------------------------------------------------
  // ARM 1 — the modules, as the page sees them, and the compile arms.
  // ----------------------------------------------------------------------------------------
  {
    const page = await readyPage();
    const modules = await page.eval('window.vfsDemo.modules', EVAL_MS);
    const expectations = await page.eval('window.vfsDemo.expectations', EVAL_MS);
    const compile = await page.eval('window.vfsDemo.compileArms()', EVAL_MS);
    // Read AFTER the compiles, so an import reached during a compile is in the list.
    const reached = await page.eval('window.vfsDemo.reachedImports()', EVAL_MS);
    arms.modules = { ...pageFacts(page), modules, expectations, reached };
    arms.compile = compile;
    await page.close();
  }

  // ----------------------------------------------------------------------------------------
  // ARM 2 — edit, recompile, re-trace, in ONE page load.
  //
  // Six passes without a navigation and without a second `WebAssembly.instantiate`. The
  // instantiation count comes back with the arm so that "without reload" is a number rather
  // than a description of what the code does.
  // ----------------------------------------------------------------------------------------
  {
    const page = await readyPage();
    const navigationsBefore = page.requests.filter((r) => r.url.endsWith('/index.html')).length;
    const trace = await page.eval('window.vfsDemo.traceArms()', EVAL_MS);
    const navigationsAfter = page.requests.filter((r) => r.url.endsWith('/index.html')).length;
    arms.trace = {
      ...pageFacts(page),
      ...trace,
      navigationsBefore,
      navigationsAfter,
      wasmRequests: page.requests.filter((r) => r.url.endsWith('.wasm')).length,
    };
    await page.close();
  }
} catch (err) {
  exitCode = 1;
  arms.error = { message: String(err && err.message ? err.message : err), stack: String(err && err.stack) };
} finally {
  conn.close();
  child.kill('SIGTERM');
  setTimeout(() => child.kill('SIGKILL'), 2000).unref?.();
  await server.close();
}

const out = {
  measuredAt: new Date().toISOString(),
  chromium: execFileSync(CHROMIUM, ['--version'], { encoding: 'utf8' }).trim(),
  node: process.version,
  compilerModule: { path: NOIR_WASM, bytes: statSync(NOIR_WASM).size, sha256: sha(NOIR_WASM) },
  tracerModule: { path: TRACER_WASM, bytes: statSync(TRACER_WASM).size, sha256: sha(TRACER_WASM) },
  trees: {
    source: TREES_SRC,
    sha256: sha(TREES_SRC),
    servedSha256: sha(path.join(SITE, 'm30_vfs_trees.mjs')),
  },
  site: SITE,
  serverRequests: server.requests,
  browserStderrLines: stderrChunks.join('').split('\n').filter(Boolean).length,
  arms,
};
process.stdout.write(JSON.stringify(out, null, 2) + '\n');
writeFileSync(path.join(WORK, 'vfs-last.json'), JSON.stringify(out, null, 2) + '\n');
process.exit(exitCode);
