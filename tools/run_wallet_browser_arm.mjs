// run_wallet_browser_arm.mjs — the one thing Node cannot say about `browser/dist/wallet.js`:
// that a PAGE can evaluate it.
//
//   node tools/run_wallet_browser_arm.mjs <work-dir>   > <work-dir>/browser.json
//
// ===========================================================================================
// WHY THIS EXISTS, AND IT IS A MEASUREMENT RATHER THAN A PRECAUTION
// ===========================================================================================
//
// M33 shipped with its handshake measured in Node — correctly, because a `MessagePort` and
// WebCrypto are the same thing in both engines — and with the BROWSER half asserted on the esbuild
// metafile instead: no `@aztec/native`, no `@aztec/world-state`, no `@aztec/pxe`, no Node builtin
// IMPORT, over a control build where those packages are planted and resolvable. `CAMPAIGN-BRIEF.md`
// records M27's lesson that a config-level assertion is weaker than an observed one, and M33's
// review measured exactly how much weaker.
//
// **A FREE IDENTIFIER IS NOT AN IMPORT, AND A METAFILE ONLY RECORDS IMPORTS.** Planted at the top
// of `port_wallet_provider.ts`:
//
//     const _nodeOnlyProbe = setImmediate;      // Node has it as a global; a page does not
//
// It is not `Buffer` and not `process`, so `browser/src/globals.js`'s injection does not supply it
// and `verify_browser_bundle_builds`'s free-identifier scan does not name it. It is not an import,
// so nothing appears in `meta.json`. Measured over the rebuilt bundle:
//
//   * `just verify-m33`                             224 assertions, 4/4, exit 0
//   * `verify_browser_bundle_no_node_builtins`       64 assertions, 0 failures
//   * `verify_browser_bundle_no_native_deps`         44 assertions, 0 failures
//   * `verify_verification_code_unreachable_from_browser`  37, 0
//   * `smoke_browser_headless_full_flow`             50, 0   (it drives Chromium — over `browser.js`)
//   * `node -e "await import('./wallet.js')"`        OK, 19 exports
//   * **the same file, in Chromium**                 `ReferenceError: setImmediate is not defined`
//
// Every browser-shape assertion in the repository was green over a bundle that dies on the first
// line a page evaluates. Nothing loaded `wallet.js` in a browser, because no page referenced it —
// grepped, and the answer was zero.
//
// So this arm loads it. It is deliberately the SMALLEST browser claim that closes that gap: the
// module evaluates in a page and exports what it declares. It does NOT run the handshake in
// Chromium, because the handshake's substance is a `MessagePort` and WebCrypto, both of which Node
// implements to the same specifications — that boundary is still stated in `WALLET-BOUNDARY.md` §5
// and is still the right one.
//
// THE CONTROL IS THE PLANT ABOVE, KEPT. A second site carries a copy of `wallet.js` with one
// Node-only free identifier prepended, and the page is required to REPORT the `ReferenceError`. So
// "the module evaluated" is an answer this instrument has been seen to give both ways — otherwise
// it is an absence measured by a probe nobody has watched fail, which is the defect
// `CAMPAIGN-BRIEF.md` records three times.

import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { CdpConnection, launchChromium, openPage, serveDirectory } from './browser_cdp.mjs';

const WORK = process.argv[2];
if (!WORK) {
  process.stderr.write('usage: run_wallet_browser_arm.mjs <work-dir>\n');
  process.exit(2);
}

const REPO = path.resolve(import.meta.dirname, '..');
const DIST = process.env.BROWSER_DIST ?? path.join(REPO, 'browser/dist');
const CHROMIUM = process.env.M27_CHROMIUM;
if (!CHROMIUM) {
  process.stderr.write('run_wallet_browser_arm.mjs: M27_CHROMIUM is not set\n');
  process.exit(2);
}
if (!existsSync(path.join(DIST, 'wallet.js'))) {
  process.stderr.write(`run_wallet_browser_arm.mjs: no built wallet entry at ${DIST}/wallet.js\n`);
  process.exit(2);
}

// The page's own script. `import()` rather than a static import, so a module that throws while
// EVALUATING is caught here and reported as data instead of ending the page.
const PROBE_HTML = `<!doctype html><meta charset="utf-8"><title>wallet entry probe</title>
<body><div id="r">pending</div><script type="module">
globalThis.__probe = (async () => {
  try {
    const m = await import('./wallet.js');
    return {
      evaluated: true,
      exports: Object.keys(m).sort(),
      ops: [...(m.WALLET_ENTRY_OPS ?? [])],
      messageTypeCount: Object.keys(m.WalletMessageType ?? {}).length,
      // What the page is, asked of the page rather than inferred from the file it was built into.
      hasDocument: typeof document !== 'undefined',
      hasSubtleCrypto: !!(globalThis.crypto && globalThis.crypto.subtle),
      hasMessageChannel: typeof MessageChannel === 'function',
      // The two Node globals the build shims. A page that had the REAL ones would not be a page.
      processIsShim: typeof process !== 'undefined' && process.platform === 'browser',
    };
  } catch (e) {
    return { evaluated: false, name: String(e && e.name), message: String(e && e.message) };
  }
})();
</script></body>`;

/** Build one served site: a copy of `dist`, the probe page, and an optional edit to `wallet.js`. */
function makeSite(name, mutate) {
  const root = path.join(WORK, 'sites', name);
  rmSync(root, { recursive: true, force: true });
  mkdirSync(root, { recursive: true });
  cpSync(DIST, root, { recursive: true });
  writeFileSync(path.join(root, 'wallet_probe.html'), PROBE_HTML);
  if (mutate) {
    const p = path.join(root, 'wallet.js');
    writeFileSync(p, mutate(readFileSync(p, 'utf8')));
  }
  return root;
}

const subject = makeSite('subject', null);
// THE CONTROL: exactly the plant that measured the gap — a Node global, read at module-evaluation
// time. Not an import, so no metafile would record it; not `Buffer` or `process`, so no shim
// supplies it.
const control = makeSite('control', (js) => `const _nodeOnlyProbe = setImmediate;\nvoid _nodeOnlyProbe;\n${js}`);

const arms = {};
const { child, endpoint } = await launchChromium(CHROMIUM, {
  userDataDir: path.join(WORK, 'chrome-wallet'),
});
const conn = await CdpConnection.connect(endpoint);
try {
  for (const [name, root] of [['subject', subject], ['control', control]]) {
    const server = await serveDirectory(root);
    try {
      const page = await openPage(conn, `${server.origin}/wallet_probe.html`, {
        loadTimeoutMs: 60_000,
      });
      const result = await page.eval('__probe', 60_000);
      arms[name] = {
        ...result,
        origin: server.origin,
        // A page-level exception is a second, independent record of the same event: the control's
        // throw happens inside the `import()` and is caught, so this list says whether anything
        // ELSE went wrong.
        pageErrors: page.errors,
        requestedWalletJs: page.requests.filter((r) => r.url.endsWith('/wallet.js')).length,
      };
      await page.close();
    } finally {
      await server.close();
    }
  }
} finally {
  conn.close();
  child.kill('SIGTERM');
  setTimeout(() => child.kill('SIGKILL'), 2000).unref?.();
}

process.stdout.write(
  JSON.stringify(
    { measuredAt: new Date().toISOString(), chromium: process.env.M27_CHROMIUM_VERSION ?? null, dist: path.relative(REPO, DIST), arms },
    null,
    2,
  ) + '\n',
);
process.exit(0);
