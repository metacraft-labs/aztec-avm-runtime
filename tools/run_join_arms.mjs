// run_join_arms.mjs — open the compile->transpile join page in a real headless browser.
//
//     node tools/run_join_arms.mjs <work-dir>
//
// <work-dir> must already hold:
//     vfs.json    the vendored tree (tools/vendor_noir_tree.py)
//     fixture.js  the `window.__*__` values the page reads
//
// THE MODULES ARE SERVED LOCALLY HERE, and that is a DIVERGENCE from
// `run_aztec_contract_arms.mjs`, which fetches the compiler cross-origin from
// `ide.codetracer.com` so the browser's network log records that the module under test is the
// one the product serves. Neither module this page needs can be fetched that way:
//
//   * the deployed `noir_wasm.wasm` is built from noir 61960c8eec, which predates the
//     `contract-debug` mode — it can compile a contract but cannot make one steppable;
//   * `avm_transpiler_wasm.wasm` is not deployed anywhere at all.
//
// So this harness serves both from disk and RECORDS THEIR SIZES AND DIGESTS in the report,
// which is the honest instrument for a module that has no published URL yet. The network log is
// still captured, and still shows what the page fetched.

import { copyFileSync, mkdirSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import process from 'node:process';

import { CdpConnection, launchChromium, openPage, serveDirectory } from './browser_cdp.mjs';

const workDir = process.argv[2];
if (!workDir) {
  console.error('usage: run_join_arms.mjs <work-dir>');
  process.exit(2);
}

const compilerPath = process.env.JOIN_COMPILER;
const transpilerPath = process.env.JOIN_TRANSPILER;
if (!compilerPath || !transpilerPath) {
  console.error('JOIN_COMPILER and JOIN_TRANSPILER must both point at a .wasm module');
  process.exit(2);
}

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const pageDir = path.join(repoRoot, 'verification', 'join-page');
const serveDir = path.join(workDir, 'serve-join');
// The m30 subtree is reproduced rather than flattened, so `join_stages.mjs`'s import of
// `../m30/page/wasm_host.mjs` resolves to the ONE import-counting host both milestones use. A
// copy beside the page would be a second instrument.
mkdirSync(path.join(serveDir, 'join-page'), { recursive: true });
mkdirSync(path.join(serveDir, 'm30', 'page'), { recursive: true });

for (const [from, to] of [
  [path.join(pageDir, 'index.html'), 'join-page/index.html'],
  [path.join(pageDir, 'join_page.mjs'), 'join-page/join_page.mjs'],
  [path.join(pageDir, 'join_stages.mjs'), 'join-page/join_stages.mjs'],
  [path.join(repoRoot, 'verification', 'm30', 'page', 'wasm_host.mjs'), 'm30/page/wasm_host.mjs'],
  [path.join(workDir, 'fixture.js'), 'join-page/fixture.js'],
  [path.join(workDir, 'vfs.json'), 'join-page/vfs.json'],
  [compilerPath, 'join-page/noir_wasm.wasm'],
  [transpilerPath, 'join-page/avm_transpiler_wasm.wasm'],
]) {
  copyFileSync(from, path.join(serveDir, to));
}

const digest = (p) => createHash('sha256').update(readFileSync(p)).digest('hex');
const served = {
  compiler: { path: compilerPath, bytes: statSync(compilerPath).size, sha256: digest(compilerPath) },
  transpiler: {
    path: transpilerPath, bytes: statSync(transpilerPath).size, sha256: digest(transpilerPath),
  },
};

const chromium = process.env.M27_CHROMIUM;
if (!chromium) {
  console.error('M27_CHROMIUM is not set');
  process.exit(2);
}

const server = await serveDirectory(serveDir);
const { child, endpoint, stderrChunks } = await launchChromium(chromium, {
  userDataDir: path.join(workDir, 'chrome-profile-join'),
});
// One `Runtime.evaluate` carries a whole Aztec contract compile AND a transpile; the compile
// alone took 21.5 s in Node on this host and a tab is slower.
const conn = await CdpConnection.connect(endpoint, 1_200_000);

let report;
try {
  const page = await openPage(conn, `${server.origin}/join-page/index.html`,
    { loadTimeoutMs: 60_000 });
  await page.eval('window.__RUN__.then(() => "ok")', 900_000);
  // The result carries a base64 artifact of several megabytes, so it is read on its own with a
  // generous bound rather than folded into the line above.
  const result = await page.eval('JSON.stringify(window.__RESULT__)', 180_000);
  const version = await conn.send('Browser.getVersion');
  report = {
    page: JSON.parse(result),
    served,
    chromium: version.product,
    userAgent: version.userAgent,
    browserRequests: page.requests.map((r) => ({
      url: r.url, type: r.type, encodedDataLength: r.encodedDataLength ?? null,
    })),
    localServerRequests: server.requests,
    consoleErrors: page.errors,
  };
} finally {
  try { conn.close(); } catch { /* the socket may already be gone */ }
  try { child.kill('SIGKILL'); } catch { /* idem */ }
  await server.close().catch(() => {});
}
if (!report) {
  console.error(stderrChunks.join(''));
  process.exit(1);
}

// The base64 artifact is written out on its own so a later stage can consume THE PAGE'S BYTES,
// and stripped from arms.json so that file stays readable.
if (report.page && report.page.transpiledBase64) {
  const bytes = Buffer.from(report.page.transpiledBase64, 'base64');
  const out = path.join(workDir, 'browser-transpiled.json');
  writeFileSync(out, bytes);
  report.page.transpiledBytes = bytes.length;
  delete report.page.transpiledBase64;
  console.error(`run_join_arms: wrote ${out} (${bytes.length} bytes)`);
}

writeFileSync(path.join(workDir, 'join-arms.json'), JSON.stringify(report, null, 2) + '\n');
console.error(`run_join_arms: wrote ${path.join(workDir, 'join-arms.json')}`);
