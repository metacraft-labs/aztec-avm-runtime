// run_execute_arms.mjs — drive the in-tab register/execute/trace page.
//
//     node tools/run_execute_arms.mjs <work-dir>
//
// <work-dir> must hold `browser-transpiled.json` (stage 1's output) and the built bundle is
// taken from JOIN_DIST. The container the page produces is written out so `ct-print` reads the
// PAGE'S bytes rather than a re-run's.
import { copyFileSync, mkdirSync, readFileSync, writeFileSync, cpSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { CdpConnection, launchChromium, openPage, serveDirectory } from './browser_cdp.mjs';

const workDir = process.argv[2];
const dist = process.env.JOIN_DIST;
const avm = process.env.AVM_WASM_PATH;
const writer = process.env.CT_WRITER_WASM;
if (!workDir || !dist || !avm || !writer) {
  console.error('usage: JOIN_DIST=<dist> AVM_WASM_PATH=<..> CT_WRITER_WASM=<..> run_execute_arms.mjs <work-dir>');
  process.exit(2);
}
const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const pageDir = path.join(repoRoot, 'verification', 'join-page');
const serveDir = path.join(workDir, 'serve-execute');
mkdirSync(path.join(serveDir, 'assets'), { recursive: true });
// The whole built bundle, because `testing.js` imports its shared chunks by relative path.
cpSync(dist, serveDir, { recursive: true });
copyFileSync(path.join(pageDir, 'execute.html'), path.join(serveDir, 'index.html'));
copyFileSync(path.join(pageDir, 'execute_page.mjs'), path.join(serveDir, 'execute_page.mjs'));
copyFileSync(avm, path.join(serveDir, 'assets', 'avm.wasm'));
copyFileSync(writer, path.join(serveDir, 'assets', 'ct_writer.wasm'));
copyFileSync(path.join(workDir, 'browser-transpiled.json'),
  path.join(serveDir, 'assets', 'browser-transpiled.json'));

const chromium = process.env.M27_CHROMIUM;
if (!chromium) { console.error('M27_CHROMIUM is not set'); process.exit(2); }

const server = await serveDirectory(serveDir);
const { child, endpoint, stderrChunks } = await launchChromium(chromium, {
  userDataDir: path.join(workDir, 'chrome-profile-execute'),
});
const conn = await CdpConnection.connect(endpoint, 900_000);
let report;
try {
  const page = await openPage(conn, `${server.origin}/index.html`, { loadTimeoutMs: 60_000 });
  await page.eval('window.__RUN__.then(() => "ok")', 600_000);
  const result = await page.eval('JSON.stringify(window.__RESULT__)', 180_000);
  const version = await conn.send('Browser.getVersion');
  report = {
    page: JSON.parse(result),
    chromium: version.product,
    browserRequests: page.requests.map((r) => ({ url: r.url, type: r.type,
      encodedDataLength: r.encodedDataLength ?? null })),
    consoleErrors: page.errors,
  };
} finally {
  try { conn.close(); } catch { /* already gone */ }
  try { child.kill('SIGKILL'); } catch { /* idem */ }
  await server.close().catch(() => {});
}
if (!report) { console.error(stderrChunks.join('')); process.exit(1); }

if (report.page && report.page.containerBase64) {
  const bytes = Buffer.from(report.page.containerBase64, 'base64');
  const out = path.join(workDir, 'browser-execution.ct');
  writeFileSync(out, bytes);
  report.page.containerBytesWritten = bytes.length;
  delete report.page.containerBase64;
  console.error(`run_execute_arms: wrote ${out} (${bytes.length} bytes)`);
}
writeFileSync(path.join(workDir, 'execute-arms.json'), JSON.stringify(report, null, 2) + '\n');
console.error(`run_execute_arms: wrote ${path.join(workDir, 'execute-arms.json')}`);
