// Drive the Path B writer module inside a REAL headless browser, and bring the container back.
//
//   node tools/m41_browser_writer.mjs <module.wasm> <out-dir>
//
// Writes `<out-dir>/container.ct` and `<out-dir>/report.json`, in the same shape
// `verification/ct_writer_drive.mjs` writes them, so a check can compare a browser run against a
// node run field by field.
//
// ===========================================================================================
// WHY A BROWSER AND NOT NODE WITH A COMMENT SAYING "AND IT WOULD WORK IN A BROWSER TOO"
// ===========================================================================================
//
// The whole of DD-7's browser argument is about what a PAGE can do. Node and a page differ in the
// two places this module lives: node will happily instantiate a module with imports it can satisfy
// from its own globals, and node has a filesystem. A container built in node proves the writer
// works; it does not prove a page can build one. So the module is fetched over HTTP, compiled by
// the browser's own `WebAssembly.instantiateStreaming`, instantiated against a LITERAL `{}`, and
// driven by the SAME `ct_writer_drive_core.mjs` the node arm imports — served to the page as an ES
// module, not reimplemented in a string.
//
// THE CONTAINER COMES BACK AS BASE64 over the CDP boundary. `Runtime.evaluate` returns JSON, and a
// `Uint8Array` does not survive that: it arrives as an object with numeric keys, silently, and the
// bytes look present until something tries to read the CTFS magic out of `{"0":192,...}`. So the
// page encodes explicitly and this file decodes explicitly, and the length is asserted on both
// sides of the crossing.
//
// EVERY WAIT IS BOUNDED. `browser_cdp.mjs` carries the bounds; nothing here adds an unbounded one.

import { mkdirSync, writeFileSync, copyFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import process from 'node:process';

import { CdpConnection, launchChromium, openPage, serveDirectory } from './browser_cdp.mjs';

const [, , modulePath, outDir] = process.argv;
if (!modulePath || !outDir) {
  console.error('usage: m41_browser_writer.mjs <module.wasm> <out-dir>');
  process.exit(2);
}

const chromium =
  process.env.M27_CHROMIUM ||
  process.env.M41_CHROMIUM ||
  '/usr/bin/chromium';

const here = new URL('.', import.meta.url).pathname;
const repoRoot = join(here, '..');

// A directory the page can be served from, holding exactly three files: the module, the shared
// driver core, and a page that puts them together. Nothing else is reachable, so a request for
// anything else shows up in the server's own log as a 404 and the check can say so.
const serveRoot = mkdtempSync(join(tmpdir(), 'm41-browser-'));
copyFileSync(modulePath, join(serveRoot, 'ct_writer.wasm'));
copyFileSync(join(repoRoot, 'verification', 'ct_writer_drive_core.mjs'), join(serveRoot, 'drive.mjs'));
writeFileSync(
  join(serveRoot, 'index.html'),
  `<!doctype html><meta charset="utf-8"><title>m41 writer</title>
<script type="module">
import { driveWriter, EXPECTED_STEPS, DRIVEN_STEP_COUNT } from './drive.mjs';
window.__m41 = async () => {
  // The literal {} is the assertion, not a convenience: a module with an import fails here with a
  // LinkError rather than being handed something that happens to satisfy it.
  const { instance } = await WebAssembly.instantiateStreaming(fetch('./ct_writer.wasm'), {});
  const { report, container } = driveWriter(instance.exports);
  report.host = 'browser';
  report.userAgent = navigator.userAgent;
  report.expectedSteps = EXPECTED_STEPS;
  report.drivenStepCount = DRIVEN_STEP_COUNT;
  let binary = '';
  for (let i = 0; i < container.length; i++) binary += String.fromCharCode(container[i]);
  return { report, containerLength: container.length, containerB64: btoa(binary) };
};
window.__m41ready = true;
</script>`,
);

const server = await serveDirectory(serveRoot);
const browser = await launchChromium(chromium);
const conn = await CdpConnection.connect(browser.endpoint);
let page;
let failure = null;
try {
  page = await openPage(conn, `${server.origin}/index.html`);
  // The module script has to have run. A page whose script threw would otherwise return
  // `undefined` from the call below, and `undefined.report` reads as a driver bug.
  const ready = await page.eval('window.__m41ready === true');
  if (ready !== true) {
    throw new Error(
      `the page's module script did not run: ${JSON.stringify(page.errors)} ${JSON.stringify(page.console)}`,
    );
  }
  const out = await page.eval('window.__m41()');
  if (!out || !out.report) {
    throw new Error(`the page returned no report: ${JSON.stringify(out)}`);
  }
  const bytes = Buffer.from(out.containerB64, 'base64');
  if (bytes.length !== out.containerLength) {
    throw new Error(
      `the container did not survive the base64 crossing: the page had ${out.containerLength} bytes, ` +
        `${bytes.length} arrived`,
    );
  }
  out.report.module = modulePath;
  out.report.containerBytes = bytes.length;
  out.report.pageRequests = server.requests.map((r) => `${r.path} ${r.status}`);
  out.report.pageErrors = page.errors;
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'container.ct'), bytes);
  writeFileSync(join(outDir, 'report.json'), `${JSON.stringify(out.report, null, 2)}\n`);
  console.log(
    `drove ${modulePath} in ${out.report.userAgent}: kind=${out.report.writerKind}, ${bytes.length} container bytes`,
  );
} catch (e) {
  failure = e;
} finally {
  try {
    if (page) await page.close();
  } catch {
    /* a page that will not close must not mask the real failure */
  }
  // `launchChromium` returns the child rather than a closer, so the kill is explicit — and it
  // escalates, because a renderer that ignores SIGTERM is the hang this whole file is bounded
  // against.
  try {
    browser.child.kill('SIGTERM');
    await new Promise((r) => setTimeout(r, 500));
    if (browser.child.exitCode === null) browser.child.kill('SIGKILL');
  } catch {
    /* likewise */
  }
  await server.close();
}

if (failure) {
  console.error(`m41_browser_writer: ${failure.message}`);
  process.exit(1);
}
