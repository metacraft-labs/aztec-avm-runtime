// M39's arms — a nested private call, IN CHROMIUM, over the built wallet bundle.
//
//   node tools/run_m39_nested_arms.mjs <work-dir>            (or: just m39-arms)
//
// ===========================================================================================
// WHY THIS IS A SEPARATE DRIVER RATHER THAN A FOURTH ARM IN `run_private_execution_arms.mjs`
// ===========================================================================================
//
// M35's report shape is read by four checks in two milestones and its figures are compared against
// three documents. Adding a frame to it would move numbers those checks re-derive, and this
// campaign has already paid twice for one track editing another track's expectations. So M39 gets
// its own driver, its own work directory and its own report, and M35's is untouched.
//
// It stages upstream's own nested-call pair — `parent_contract-Parent.json` and
// `child_contract-Child.json` — TWICE, once from each of the two @aztec nightly lines this tree has
// installed, because which line an artefact came from is what the second arm measures.
//
// ===========================================================================================
// THE ARMS
// ===========================================================================================
//
//   nested   `Parent.entry_point(childAddress, childSelector)` on the line that MATCHES the `cpp`
//            anchor this runtime's oracle wire is vendored from — one transaction, two private
//            frames. The parent calls the child through `aztec_prv_callPrivateFunction` and then
//            reads the child's return value back out of the execution cache IN ITS OWN FRAME.
//
//   oldWire  the SAME transaction on the `deletion_era` line, where
//            `call_private_function_oracle` declares `-> [Field; 2]` (one destination slot)
//            against the anchor's `-> (u32, Field)` (two). `assertCompatibleOracleVersion` passes
//            over that pair, so the arm is the only instrument that can see it.
//
// Every arm gets its OWN PAGE, which is M34's rule and the reason M35's `lazy` control works.

import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { CdpConnection, launchChromium, openPage, requestsMatching, serveDirectory } from './browser_cdp.mjs';

const REPO = path.resolve(import.meta.dirname, '..');
const WORK = process.argv[2] ?? path.join(process.env.HOME, '.cache', 'aztec-m39-nested');
mkdirSync(WORK, { recursive: true });

function fail(message) {
  process.stderr.write(`run_m39_nested_arms: ${message}\n`);
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

// M35's search, unchanged and for its reason: this tree has two @aztec nightly lines installed at
// once and they are not interchangeable. The CHOSEN root is reported per asset, so a check can see
// which line an artefact came from instead of assuming.
const SEARCH_ROOTS = ['orchestration', 'diffsim', 'spike', 'drift', 'probe-mt'];
function findUnder(rel, roots = SEARCH_ROOTS) {
  const tried = roots.map((r) => ({ root: r, file: path.join(REPO, r, rel) }));
  const hit = tried.find((t) => existsSync(t.file));
  if (!hit) fail(`no ${rel} under any of: ${roots.join(', ')}`);
  return hit;
}

// TWO LINES OF THE SAME TWO CONTRACTS, AND WHICH ROOT CARRIES WHICH IS A MEASUREMENT.
//
// `drift/` carries `aztec_version 5.3.0-nightly.20260819` — the `current` pin that matches the
// `cpp` anchor this runtime's oracle wire is vendored from. `diffsim/`, `spike/` and `probe-mt/`
// carry `5.0.0-nightly.20260626`, the `deletion_era` line, whose
// `call_private_function_oracle` declares `-> [Field; 2]` (ONE destination slot) where the
// anchor's declares `-> (u32, Field)` (TWO). `assertCompatibleOracleVersion` passes over the pair
// — same major, environment minor >= contract minor — so only a RUN can tell them apart, and both
// are run.
//
// The per-root order is NOT the shared `SEARCH_ROOTS` order, deliberately: this is the one place
// in the repository where which nightly line an artefact came from decides the answer, so the two
// are named rather than searched for.
const ANCHOR_LINE = ['drift'];
const DELETION_ERA_LINE = ['diffsim', 'spike', 'probe-mt'];
const REL_PARENT = 'node_modules/@aztec/noir-test-contracts.js/artifacts/parent_contract-Parent.json';
const REL_CHILD = 'node_modules/@aztec/noir-test-contracts.js/artifacts/child_contract-Child.json';
// THE `deletion_era` PAIR IS THE ONE THAT RUNS, because the installed `@aztec/constants` declares
// `PRIVATE_CONTEXT_INPUTS_LENGTH = 37` and that is the width those artifacts were compiled for.
const parentArtifact = findUnder(REL_PARENT, DELETION_ERA_LINE);
const childArtifact = findUnder(REL_CHILD, DELETION_ERA_LINE);
const parentAnchorLine = findUnder(REL_PARENT, ANCHOR_LINE);
const childAnchorLine = findUnder(REL_CHILD, ANCHOR_LINE);

// THE TWO LINES MUST BE DIFFERENT ARTEFACTS, ASSERTED HERE RATHER THAN ASSUMED. If a future
// install made both roots carry the same nightly, the two arms would measure one thing twice and
// the "the version check cannot see this" claim would rest on a pair that is not a pair.
const versionOf = (f) => JSON.parse(readFileSync(f, 'utf8')).aztec_version ?? '?';
const deletionEraVersion = versionOf(parentArtifact.file);
const anchorVersion = versionOf(parentAnchorLine.file);
if (anchorVersion === deletionEraVersion) {
  fail(
    `both roots carry aztec_version ${anchorVersion}; the two-line comparison needs two lines. ` +
      `deletionEra=${parentArtifact.root} anchor=${parentAnchorLine.root}`,
  );
}
// The two wasm modules come from `orchestration/` first, for M35's stated reason: that is the tree
// the browser bundle is built against, so the module the page fetches and the JS glue esbuild
// inlined are the same version.
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
copyFileSync(parentArtifact.file, path.join(SITE, 'assets/parent_contract-Parent.json'));
copyFileSync(childArtifact.file, path.join(SITE, 'assets/child_contract-Child.json'));
copyFileSync(parentAnchorLine.file, path.join(SITE, 'assets/anchorline-parent_contract-Parent.json'));
copyFileSync(childAnchorLine.file, path.join(SITE, 'assets/anchorline-child_contract-Child.json'));
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
  // ---- ARM 1: the nested call, on the line that matches the anchor the wire is vendored from ----
  {
    const page = await walletPage();
    const report = await page.eval('window.walletDemo.armNestedPrivateCall()', 600_000);
    arms.nested = { ...pageFacts(page), report };
    await page.close();
  }

  // ---- ARM 2: THE SAME TRANSACTION WITH THE WIRE REGROUPING TURNED OFF -------------------------
  //
  // The shim's own negative control, and it is what makes its necessity a measurement rather than a
  // paragraph. Same artifacts, same handler, same directory — the only difference is one option —
  // so a difference in the outcome is the shim and nothing else. `PRIVATE-EXECUTION.md` section 3b
  // measured this shape once on `getPublicKeysAndPartialAddress` and closed with the prediction
  // that any refused oracle whose shape had moved carried the same latent gap; this is that
  // prediction, on the next one served.
  {
    const page = await walletPage();
    const report = await page.eval('window.walletDemo.armNestedPrivateCallNoCompat()', 600_000);
    arms.noCompat = { ...pageFacts(page), report };
    await page.close();
  }

  // ---- ARM 3: THE ANCHOR LINE, WHICH THIS RUNTIME CANNOT ASSEMBLE A FRAME FOR --------------------
  //
  // A claim that a corpus cannot run here is a claim. This runs it: the artifact's own `inputs`
  // parameter is 38 fields wide, the installed `@aztec/constants` declares 37, and the frame is
  // refused before a single opcode. Reported rather than thrown, so the fact lands in the report
  // beside the two runs it explains.
  {
    const page = await walletPage();
    const report = await page.eval('window.walletDemo.armNestedPrivateCallAnchorLine()', 600_000);
    arms.anchorLine = { ...pageFacts(page), report };
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
    parent: {
      root: parentArtifact.root,
      aztecVersion: deletionEraVersion,
      sha256: sha(parentArtifact.file),
      bytes: statSync(parentArtifact.file).size,
    },
    child: { root: childArtifact.root, sha256: sha(childArtifact.file), bytes: statSync(childArtifact.file).size },
    parentAnchorLine: {
      root: parentAnchorLine.root,
      aztecVersion: anchorVersion,
      sha256: sha(parentAnchorLine.file),
      bytes: statSync(parentAnchorLine.file).size,
    },
    childAnchorLine: {
      root: childAnchorLine.root,
      sha256: sha(childAnchorLine.file),
      bytes: statSync(childAnchorLine.file).size,
    },
    acvm: { root: acvmWasm.root, sha256: sha(acvmWasm.file), bytes: statSync(acvmWasm.file).size },
    noircAbi: { root: noircAbiWasm.root, sha256: sha(noircAbiWasm.file), bytes: statSync(noircAbiWasm.file).size },
  },
  arms,
};
writeFileSync(path.join(WORK, 'nested-private-call.raw.json'), JSON.stringify(out, null, 2) + '\n');
process.stdout.write(JSON.stringify(out, null, 2) + '\n');
process.exit(exitCode);
