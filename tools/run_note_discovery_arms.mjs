// M36's arms — NOTE DISCOVERY ACROSS BLOCKS, IN CHROMIUM, over the built wallet bundle.
//
//   node tools/run_note_discovery_arms.mjs <work-dir>            (or: just m36-arms)
//
// ===========================================================================================
// WHY THIS RUNS IN A BROWSER
// ===========================================================================================
//
// `CAMPAIGN-BRIEF.md`'s ladder is *asserted browser-shaped* -> *observed to evaluate* -> *observed
// to do the thing*, and a milestone owes the rung its deliverable is on. M36 ships a note DATABASE
// and a tagging half that a compiled Noir circuit reaches through upstream's oracle wire, so the
// third rung is the only honest one: the ACVM loads, `NoteGetter.insert_note` solves a 3,588-entry
// witness, and its own tagging oracles are answered by this wallet, in a page.
//
// Derived from `run_private_execution_arms.mjs` (M35) with the arms replaced; the page harness, the
// asset search with its reported ROOT, the per-arm page isolation and the network-log facts are all
// M35's and M27's, unchanged.

import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { CdpConnection, launchChromium, openPage, requestsMatching, serveDirectory } from './browser_cdp.mjs';

const REPO = path.resolve(import.meta.dirname, '..');
const WORK = process.argv[2] ?? path.join(process.env.HOME, '.cache', 'aztec-m35-private');
mkdirSync(WORK, { recursive: true });

function fail(message) {
  process.stderr.write(`run_note_discovery_arms: ${message}\n`);
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
// THE LADDER'S THIRD PROGRAM. `Token.transfer` and `Token.mint_to_private` share the artifact above;
// `PrivateVoting.cast_vote` is a different CONTRACT, which is the point — three programs stopping at
// one oracle is a statement about the oracle and two of them from one artifact would be weaker.
const votingArtifact = findUnder('node_modules/@aztec/noir-contracts.js/artifacts/private_voting_contract-PrivateVoting.json', [
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
// M36's fixture. Chosen by measurement — see `wallet_main.ts`'s comment on NOTE_GETTER_ARTIFACT_URL.
const noteGetterArtifact = findUnder(
  'node_modules/@aztec/noir-test-contracts.js/artifacts/note_getter_contract-NoteGetter.json',
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
copyFileSync(votingArtifact.file, path.join(SITE, 'assets/private_voting_contract-PrivateVoting.json'));
copyFileSync(oracleCheckArtifact.file, path.join(SITE, 'assets/oracle_version_check_contract-OracleVersionCheck.json'));
copyFileSync(noteGetterArtifact.file, path.join(SITE, 'assets/note_getter_contract-NoteGetter.json'));
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
  // ---- ARM 1: NOTE DISCOVERY ACROSS BLOCKS, IN CHROMIUM ---------------------------------------
  //
  // The whole claim runs in a page: two real `NoteGetter.insert_note` circuits, a block sealed from
  // their own public inputs, a discovery by an independently computed siloed tag, a validation
  // against the block's own note hashes, and a spend two blocks later.
  {
    const page = await walletPage();
    const report = await page.eval('window.walletDemo.armNoteDiscovery()', 600_000);
    arms.discovery = { ...pageFacts(page), report };
    await page.close();
  }

  // ---- ARM 2: THE CONTROL — the same page doing M34's work and no note discovery ----------------
  //
  // Its network log is what makes the ACVM's absence from a page that asks for nothing a
  // MEASUREMENT rather than an empty set. Same shape as M35's `lazy` arm and for the same reason.
  {
    const page = await walletPage();
    const report = await page.eval('window.walletDemo.armWalletTransfer()', 600_000);
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
    noteGetter: {
      root: noteGetterArtifact.root,
      sha256: sha(noteGetterArtifact.file),
      bytes: statSync(noteGetterArtifact.file).size,
    },
    voting: { root: votingArtifact.root, sha256: sha(votingArtifact.file), bytes: statSync(votingArtifact.file).size },
    acvm: { root: acvmWasm.root, sha256: sha(acvmWasm.file), bytes: statSync(acvmWasm.file).size },
    noircAbi: { root: noircAbiWasm.root, sha256: sha(noircAbiWasm.file), bytes: statSync(noircAbiWasm.file).size },
  },
  arms,
};
writeFileSync(path.join(WORK, 'note-discovery.raw.json'), JSON.stringify(out, null, 2) + '\n');
process.stdout.write(JSON.stringify(out, null, 2) + '\n');
process.exit(exitCode);
