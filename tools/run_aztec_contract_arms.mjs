// run_aztec_contract_arms.mjs — open the Aztec-contract page in a real headless browser and
// write what it produced.
//
//     node tools/run_aztec_contract_arms.mjs <work-dir>
//
// <work-dir> must already hold:
//     vfs.json                 the vendored tree (tools/vendor_noir_tree.py)
//     fixture.js               the four `window.__*__` values the page reads
//
// It assembles a serve directory beside them, launches Chromium through `tools/browser_cdp.mjs`
// (no puppeteer, no playwright — see that file's header), navigates, waits for the page's own
// promise to settle, and writes `arms.json`.
//
// THE MODULE IS NOT SERVED FROM HERE. `fixture.js` points the page at
// `https://ide.codetracer.com/assets/noir_wasm.wasm`, so the browser's own network log — which
// this file captures and writes out — is the record that the compiler under test is the one the
// product serves. A local copy would be a check about a file this machine has.

import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { CdpConnection, launchChromium, openPage, serveDirectory } from './browser_cdp.mjs';

const workDir = process.argv[2];
if (!workDir) {
  console.error('usage: run_aztec_contract_arms.mjs <work-dir>');
  process.exit(2);
}

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const pageDir = path.join(repoRoot, 'verification', 'aztec-contract-page');
const serveDir = path.join(workDir, 'serve');
mkdirSync(serveDir, { recursive: true });

for (const [from, to] of [
  [path.join(pageDir, 'index.html'), 'index.html'],
  [path.join(pageDir, 'page.mjs'), 'page.mjs'],
  // Shared with M30's page, deliberately: the import-counting host is the instrument both
  // milestones' claims rest on, and two copies of it would be two instruments.
  [path.join(repoRoot, 'verification', 'm30', 'page', 'wasm_host.mjs'), 'wasm_host.mjs'],
  [path.join(workDir, 'fixture.js'), 'fixture.js'],
  [path.join(workDir, 'vfs.json'), 'vfs.json'],
]) {
  copyFileSync(from, path.join(serveDir, to));
}

const chromium = process.env.M27_CHROMIUM;
if (!chromium) {
  console.error('M27_CHROMIUM is not set');
  process.exit(2);
}

const server = await serveDirectory(serveDir);
const { child, endpoint, stderrChunks } = await launchChromium(chromium, {
  userDataDir: path.join(workDir, 'chrome-profile'),
});
// The connection's own bound is raised: one `Runtime.evaluate` here carries a whole Aztec
// contract compile, which took 23 s in Node on this host and is slower in a tab.
const conn = await CdpConnection.connect(endpoint, 900_000);

let report;
try {
  const page = await openPage(conn, `${server.origin}/index.html`, { loadTimeoutMs: 60_000 });
  // The page's own promise. `awaitPromise` makes a page-side throw a CdpError here rather than a
  // silent `undefined`, and the bound makes a hang a named failure rather than a stalled sweep.
  await page.eval('window.__RUN__.then(() => "ok")', 600_000);
  const result = await page.eval('JSON.stringify(window.__RESULT__)', 60_000);
  const version = await conn.send('Browser.getVersion');
  report = {
    page: JSON.parse(result),
    chromium: version.product,
    userAgent: version.userAgent,
    // BOTH records, deliberately: the browser's own log and the local server's. A request the
    // page made to a THIRD party appears in the first and not the second.
    browserRequests: page.requests.map((r) => ({
      url: r.url,
      type: r.type,
      encodedDataLength: r.encodedDataLength ?? null,
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
}

writeFileSync(path.join(workDir, 'arms.json'), JSON.stringify(report, null, 2) + '\n');
console.error(`run_aztec_contract_arms: wrote ${path.join(workDir, 'arms.json')}`);
