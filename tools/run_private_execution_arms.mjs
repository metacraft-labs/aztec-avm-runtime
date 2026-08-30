// M35's arms — private execution, IN CHROMIUM, over the built wallet bundle.
//
//   node tools/run_private_execution_arms.mjs <work-dir>            (or: just m35-arms)
//
// ===========================================================================================
// WHY THIS RUNS IN A BROWSER, AND WHY THAT IS NOT A FORMALITY
// ===========================================================================================
//
// `CAMPAIGN-BRIEF.md`'s ladder is *asserted browser-shaped* -> *observed to evaluate* -> *observed
// to do the thing*, and a milestone owes the rung its deliverable is on. M33 shipped a protocol and
// a probe page was the right size. M34 shipped a wallet and every arm ran in Chromium. **M35 ships
// an EXECUTOR**: a second wasm module (the ACVM) fetched at run time, a third (the ABI decoder), a
// vendored simulator driving them, and upstream's oracle wire dispatching into a handler of ours. A
// Node-resolved measurement could say none of that loads in a page.
//
// It is also where the DD-11 claim lives. `acvm_js_bg.wasm` is 3.6 MB and `noirc_abi_wasm_bg.wasm`
// is 0.8 MB, and the deliverable is that **a page that does not ask for a private execution fetches
// neither**. That is a statement about a network log, and only a browser has one — which is exactly
// the shape of the defect this file's ancestors record twice: an absence asked of a tree that
// excludes its subject by construction. So there is a control arm that opens the SAME page, runs the
// SAME wallet transfer M34 measures, and never calls a private-execution arm; its log must carry
// neither module, while the subject's carries both.
//
// ===========================================================================================
// THE ARMS
// ===========================================================================================
//
//   private      REAL ACIR, twice. `OracleVersionCheck.private_function` runs to completion on the
//                oracles this milestone serves; Token's private `transfer` — 76,875 bytes of ACIR —
//                is REFUSED BY NAME at the first oracle it needs that M35 does not serve. Plus the
//                deterministic-entropy triple: the same seed twice, and a different seed once.
//   surface      Every served oracle exercised through the handler and every refused one required
//                to refuse naming itself, plus the construction-time guard exercised in both
//                directions. "Implemented" has to mean "observed to answer".
//   lazy         THE CONTROL. The same page, a wallet transfer, and no private execution: neither
//                wasm module may appear in the network log, while `avm.wasm` must.
//
// Each arm gets its OWN PAGE, so one arm's network log cannot be read as another's — M34's rule,
// and the `lazy` arm is the reason it matters here.

import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { CdpConnection, launchChromium, openPage, requestsMatching, serveDirectory } from './browser_cdp.mjs';

const REPO = path.resolve(import.meta.dirname, '..');
const WORK = process.argv[2] ?? path.join(process.env.HOME, '.cache', 'aztec-m35-private');
mkdirSync(WORK, { recursive: true });

function fail(message) {
  process.stderr.write(`run_private_execution_arms: ${message}\n`);
  process.exit(2);
}

const AVM_WASM = process.env.AVM_WASM_PATH;
if (!AVM_WASM || !existsSync(AVM_WASM)) fail(`AVM_WASM_PATH is not set to an existing module (${AVM_WASM})`);
const CHROMIUM = process.env.M27_CHROMIUM;
if (!CHROMIUM || !existsSync(CHROMIUM)) fail(`M27_CHROMIUM is not set to an existing binary (${CHROMIUM})`);

const DIST = process.env.BROWSER_DIST ?? path.join(REPO, 'browser/dist');
for (const needed of ['wallet-demo.js', 'wallet.html', 'wallet.js']) {
  if (!existsSync(path.join(DIST, needed))) {
    fail(`no ${needed} in ${DIST}. Remedy: node browser/build.mjs`);
  }
}

const CT_WRITER = path.join(REPO, 'ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm');
if (!existsSync(CT_WRITER)) fail(`no ct_writer.wasm at ${CT_WRITER}. Remedy: verification/build_ct_writer_wasm.sh`);

// EVERY ASSET IS SEARCHED ACROSS THE ROOTS THAT CARRY ONE, WITH THE RESIDUE REPORTED, because this
// tree has two @aztec nightly lines installed at once and they are not interchangeable — M27's own
// search, extended to the three files M35 adds. The chosen ROOT is reported, so a check can see which
// line an artefact came from instead of assuming.
const SEARCH_ROOTS = ['orchestration', 'diffsim', 'spike', 'drift', 'probe-mt'];
function findUnder(rel, roots = SEARCH_ROOTS) {
  const tried = roots.map((r) => ({ root: r, file: path.join(REPO, r, rel) }));
  const hit = tried.find((t) => existsSync(t.file));
  if (!hit) fail(`no ${rel} under any of: ${roots.join(', ')}`);
  return hit;
}

const tokenArtifact = findUnder('node_modules/@aztec/noir-contracts.js/artifacts/token_contract-Token.json', [
  'diffsim',
  'spike',
  'drift',
  'probe-mt',
  'orchestration',
]);
const oracleCheckArtifact = findUnder(
  'node_modules/@aztec/noir-test-contracts.js/artifacts/oracle_version_check_contract-OracleVersionCheck.json',
  ['diffsim', 'spike', 'drift', 'probe-mt', 'orchestration'],
);
// THE TWO WASM MODULES COME FROM `orchestration/` FIRST, deliberately: that is the tree the browser
// bundle is built against, so the module the page fetches and the JS glue esbuild inlined are the
// same version. Taking `@aztec/noir-acvm_js` from `drift/` would pair a 5.3.0 wasm with a 5.0.0
// glue, which wasm-bindgen would accept and then fail on inside the ACVM.
const acvmWasm = findUnder('node_modules/@aztec/noir-acvm_js/web/acvm_js_bg.wasm');
const noircAbiWasm = findUnder('node_modules/@aztec/noir-noirc_abi/web/noirc_abi_wasm_bg.wasm');

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
copyFileSync(tokenArtifact.file, path.join(SITE, 'assets/token_contract-Token.json'));
copyFileSync(oracleCheckArtifact.file, path.join(SITE, 'assets/oracle_version_check_contract-OracleVersionCheck.json'));
copyFileSync(acvmWasm.file, path.join(SITE, 'assets/acvm_js_bg.wasm'));
copyFileSync(noircAbiWasm.file, path.join(SITE, 'assets/noirc_abi_wasm_bg.wasm'));

const sha = (f) => createHash('sha256').update(readFileSync(f)).digest('hex');

const server = await serveDirectory(SITE);
const { child, endpoint } = await launchChromium(CHROMIUM, { userDataDir: path.join(WORK, 'chrome-profile') });
const conn = await CdpConnection.connect(endpoint);

const arms = {};
let exitCode = 0;

function pageFacts(page) {
  return {
    requestCount: page.requests.length,
    requests: page.requests.map((r) => ({ url: r.url.replace(server.origin, ''), type: r.type })),
    barretenbergRequests: requestsMatching(page.requests, 'barretenberg').map((r) => r.url.replace(server.origin, '')),
    avmWasmRequests: requestsMatching(page.requests, 'avm.wasm').map((r) => r.url.replace(server.origin, '')),
    acvmWasmRequests: requestsMatching(page.requests, 'acvm_js_bg.wasm').map((r) => r.url.replace(server.origin, '')),
    noircAbiRequests: requestsMatching(page.requests, 'noirc_abi_wasm_bg.wasm').map((r) =>
      r.url.replace(server.origin, ''),
    ),
    consoleErrors: page.console.filter((c) => c.level === 'error').map((c) => c.text),
    pageErrors: [...page.errors],
  };
}

async function walletPage() {
  const page = await openPage(conn, `${server.origin}/wallet.html`, { loadTimeoutMs: 120_000 });
  const ready = await page.eval('globalThis.walletDemoReady === true', 120_000);
  if (ready !== true) {
    throw new Error(`the wallet demo page did not become ready; page errors: ${JSON.stringify(page.errors)}`);
  }
  return page;
}

try {
  // ---- ARM 1: REAL ACIR, twice --------------------------------------------------------------
  {
    const page = await walletPage();
    const report = await page.eval('window.walletDemo.armPrivateExecution()', 600_000);
    arms.private = { ...pageFacts(page), report };
    await page.close();
  }

  // ---- ARM 2: the whole oracle surface, exercised and refused ----------------------------------
  {
    const page = await walletPage();
    const report = await page.eval('window.walletDemo.armOracleSurface()', 600_000);
    arms.surface = { ...pageFacts(page), report };
    await page.close();
  }

  // ---- ARM 3: THE CONTROL — the same page doing M34's work and no private execution -------------
  //
  // Its network log is the evidence for the lazy half of DD-11. `avm.wasm` must be in it (so the
  // absence is measured over a log that CAN carry a wasm fetch) and the ACVM's two must not.
  {
    const page = await walletPage();
    const report = await page.eval('window.walletDemo.armWalletTransfer()', 600_000);
    // Only the two fields this control needs, and they are read from the SAME report M34's own
    // check reads — `outcome` is upstream's `ProcessedTx` verdict and `executedSteps` is the AVM's.
    // Carrying the whole 30-field report here would make this arm's JSON a second copy of M34's,
    // which is a thing to keep in step rather than a measurement.
    arms.lazy = {
      ...pageFacts(page),
      report: { outcome: report?.outcome ?? null, executedSteps: report?.executedSteps ?? null },
    };
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

const out = {
  measuredAt: new Date().toISOString(),
  chromium: process.env.M27_CHROMIUM_VERSION ?? null,
  dist: path.relative(REPO, DIST),
  module: { path: AVM_WASM, sha256: sha(AVM_WASM), bytes: statSync(AVM_WASM).size },
  assets: {
    token: { root: tokenArtifact.root, sha256: sha(tokenArtifact.file), bytes: statSync(tokenArtifact.file).size },
    oracleCheck: {
      root: oracleCheckArtifact.root,
      sha256: sha(oracleCheckArtifact.file),
      bytes: statSync(oracleCheckArtifact.file).size,
    },
    acvm: { root: acvmWasm.root, sha256: sha(acvmWasm.file), bytes: statSync(acvmWasm.file).size },
    noircAbi: { root: noircAbiWasm.root, sha256: sha(noircAbiWasm.file), bytes: statSync(noircAbiWasm.file).size },
  },
  arms,
};
writeFileSync(path.join(WORK, 'private-execution.raw.json'), JSON.stringify(out, null, 2) + '\n');
process.stdout.write(JSON.stringify(out, null, 2) + '\n');
process.exit(exitCode);
