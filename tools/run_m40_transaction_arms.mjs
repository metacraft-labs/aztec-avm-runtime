// M40's arms — BOTH HALVES of one transaction, executed, IN CHROMIUM.
//
//   node tools/run_m40_transaction_arms.mjs <work-dir>            (or: just m40-arms)
//
// ===========================================================================================
// WHAT THIS ADDS TO M39's DRIVER, AND WHY IT IS A SEPARATE ONE
// ===========================================================================================
//
// M39's `bothHalves` arm executes the PRIVATE half of
// `Parent.enqueue_calls_to_child_with_nested_first` and reports the two public calls it enqueued.
// `NESTED-CALLS.md` §6 records, in as many words, that those calls are not run. This driver runs
// them — through the AVM, in the same page, against a resident world state — and downloads the
// container the public half writes.
//
// It is a separate driver for the reason M39's own header gives one level up: M39's report shape is
// read by two checks and its figures are compared against a document, and adding fields to it moves
// numbers those checks re-derive. `~/.cache/aztec-m39-nested/nested.json` is untouched.
//
// ===========================================================================================
// THE ARMS — ONE SUBJECT AND TWO CONTROLS, AND BOTH CONTROLS ARE PRODUCED RATHER THAN DECLARED
// ===========================================================================================
//
//   bothHalves         the subject. The private half executes (two frames), its enqueued calls are
//                      collected off the CIRCUIT's public inputs with their calldata preimages, the
//                      public half runs them, and the container is written with a
//                      `half=public halves=2 arm=split` join record under the private half's own
//                      `argsHash`. The browser's own download machinery writes the file.
//
//   corruptCalldata    ONE FIELD of ONE enqueued call's calldata is changed and nothing else. The
//                      whole path rests on "the preimage hashes to what the circuit committed to",
//                      and an identity nobody has seen fail is an identity nobody has calibrated.
//                      The public half must REFUSE, naming both hashes.
//
//   noDeploymentNullifier
//                      the callee's deployment nullifier is not seeded. M29 measured that the AVM
//                      then answers the address with no bytecode and executes exactly ONE
//                      instruction while the block still reports the transaction `processed` —
//                      which is precisely the state "the public half executed" has to be able to
//                      distinguish itself from. Without this arm the executed-step floor is a
//                      number nobody has watched fail.
//
// Every arm gets its OWN PAGE, which is M34's rule.

import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { CdpConnection, launchChromium, openPage, requestsMatching, serveDirectory } from './browser_cdp.mjs';

const REPO = path.resolve(import.meta.dirname, '..');
const WORK = process.argv[2] ?? path.join(process.env.HOME, '.cache', 'aztec-m40-transaction');
mkdirSync(WORK, { recursive: true });

function fail(message) {
  process.stderr.write(`run_m40_transaction_arms: ${message}\n`);
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

const SEARCH_ROOTS = ['orchestration', 'diffsim', 'spike', 'drift', 'probe-mt'];
function findUnder(rel, roots = SEARCH_ROOTS) {
  const hit = roots.map((r) => ({ root: r, file: path.join(REPO, r, rel) })).find((t) => existsSync(t.file));
  if (!hit) fail(`no ${rel} under any of: ${roots.join(', ')}`);
  return hit;
}

// THE `deletion_era` LINE IS THE ONE THAT RUNS, and M39's driver records why: the installed
// `@aztec/constants` declares `PRIVATE_CONTEXT_INPUTS_LENGTH = 37` and those artifacts were
// compiled for that width, while the anchor line's are 38 and cannot assemble a frame here at all.
// The anchor pair is staged too because `wallet.html` fetches all four asset names and a missing
// one is a page error rather than an unused file.
const ANCHOR_LINE = ['drift'];
const DELETION_ERA_LINE = ['diffsim', 'spike', 'probe-mt'];
const REL_PARENT = 'node_modules/@aztec/noir-test-contracts.js/artifacts/parent_contract-Parent.json';
const REL_CHILD = 'node_modules/@aztec/noir-test-contracts.js/artifacts/child_contract-Child.json';
const parentArtifact = findUnder(REL_PARENT, DELETION_ERA_LINE);
const childArtifact = findUnder(REL_CHILD, DELETION_ERA_LINE);
const parentAnchorLine = findUnder(REL_PARENT, ANCHOR_LINE);
const childAnchorLine = findUnder(REL_CHILD, ANCHOR_LINE);
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

const DOWNLOADS = path.join(WORK, 'downloads');
rmSync(DOWNLOADS, { recursive: true, force: true });
mkdirSync(DOWNLOADS, { recursive: true });

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

async function walletPage(options = {}) {
  const page = await openPage(conn, `${server.origin}/wallet.html`, { loadTimeoutMs: 120_000, ...options });
  const ready = await page.eval('globalThis.walletDemoReady === true', 120_000);
  if (ready !== true) {
    throw new Error(`the wallet demo page did not become ready; page errors: ${JSON.stringify(page.errors)}`);
  }
  return page;
}

/** Wait for a `.ct` to appear in a download directory, bounded and named. */
async function waitForDownload(dir, boundMs) {
  const until = Date.now() + boundMs;
  while (Date.now() < until) {
    const hit = readdirSync(dir).filter((n) => n.endsWith('.ct'));
    if (hit.length > 0) {
      const f = path.join(dir, hit[0]);
      // Two identical sizes a beat apart: the file is complete rather than mid-write.
      const a = statSync(f).size;
      await new Promise((r) => setTimeout(r, 250));
      if (a > 0 && statSync(f).size === a) return f;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  return null;
}

try {
  // ---- ARM 1: THE SUBJECT — both halves, and the container the public half wrote ---------------
  {
    const dl = path.join(DOWNLOADS, 'bothHalves');
    mkdirSync(dl, { recursive: true });
    const page = await walletPage({ downloadPath: dl });
    const report = await page.eval('window.walletDemo.armTransactionBothHalvesExecuted()', 900_000);
    const file = await waitForDownload(dl, 120_000);
    arms.bothHalves = {
      ...pageFacts(page),
      report,
      downloadedFile: file === null ? null : path.relative(WORK, file),
      downloadedBytes: file === null ? null : statSync(file).size,
      downloadedSha256: file === null ? null : sha(file),
    };
    await page.close();
  }

  // ---- ARM 2: THE CALLDATA IDENTITY, SHOWN TO BE ABLE TO FAIL ----------------------------------
  {
    const page = await walletPage();
    const report = await page.eval(
      'window.walletDemo.armTransactionBothHalvesExecuted({ corruptCalldata: true, download: false })',
      900_000,
    );
    arms.corruptCalldata = { ...pageFacts(page), report };
    await page.close();
  }

  // ---- ARM 3: M29's ONE-INSTRUCTION SHAPE, REPRODUCED ------------------------------------------
  {
    const page = await walletPage();
    const report = await page.eval(
      'window.walletDemo.armTransactionBothHalvesExecuted({ skipDeploymentNullifier: true, download: false })',
      900_000,
    );
    arms.noDeploymentNullifier = { ...pageFacts(page), report };
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
  ctWriter: { path: path.relative(REPO, CT_WRITER), sha256: sha(CT_WRITER), bytes: statSync(CT_WRITER).size },
  assets: {
    parent: {
      root: parentArtifact.root,
      aztecVersion: JSON.parse(readFileSync(parentArtifact.file, 'utf8')).aztec_version ?? '?',
      sha256: sha(parentArtifact.file),
      bytes: statSync(parentArtifact.file).size,
    },
    child: { root: childArtifact.root, sha256: sha(childArtifact.file), bytes: statSync(childArtifact.file).size },
  },
  arms,
};
writeFileSync(path.join(WORK, 'transaction.raw.json'), JSON.stringify(out, null, 2) + '\n');
process.stdout.write(JSON.stringify(out, null, 2) + '\n');
process.exit(exitCode);
