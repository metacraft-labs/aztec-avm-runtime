// run_wallet_transfer_arms.mjs — M34's arms. The dev wallet, RUN IN A BROWSER.
//
//   AVM_WASM_PATH=… M27_CHROMIUM=… node tools/run_wallet_transfer_arms.mjs <work-dir>
//
// ===========================================================================================
// WHY THIS IS A BROWSER RUN AND NOT A NODE ONE, WHICH IS THE OPPOSITE OF M33'S CHOICE.
// ===========================================================================================
//
// M33's arms ran in Node and said so: its subject was a `MessagePort` and WebCrypto, and Node 24
// implements both to the same specifications a browser does. That was right for M33 and it is not
// right for M34, for a reason M33's own review measured rather than argued:
//
//   *A metafile records IMPORTS, and a free identifier is not one.* With
//   `const _nodeOnlyProbe = setImmediate;` planted at the top of `port_wallet_provider.ts`, the
//   rebuilt bundle imported cleanly in Node, died in Chromium with `ReferenceError`, and
//   `just verify-m33` reported 224 assertions, 4/4, exit 0 with all three browser checks green —
//   because nothing in the repository had ever loaded `wallet.js` in a page.
//
// M33's review closed that with a probe that IMPORTS the bundle in a page. M34 owes more, because
// M34 ships a wallet rather than a protocol: **the wallet must be loaded and EXERCISED in a
// browser, not asserted to be browser-shaped.** So every arm below runs in Chromium, against the
// built `wallet-demo.js`, and the handshake, the ECDH, the AES-256-GCM session, the deterministic
// key derivation through `avm.wasm`'s own grumpkin, the vendored transaction builder, the AVM and
// the `.ct` writer all execute there.
//
// ===========================================================================================
// SIX ARMS, EACH IN ITS OWN PAGE, AND THE ISOLATION IS LOAD-BEARING.
// ===========================================================================================
//
//   transfer     THE SUBJECT. Handshake, registration through the wallet, a transaction the wallet
//                builds, a settled block. Its network log is read too, because a wallet that
//                derived keys through bb.js would show up there and nowhere else.
//   declined     THE CONTROL FOR THE SUBJECT. The same page, the same wallet, configured to decline
//                authorization: the milestone requires a NAMED failure and not a silent no-op.
//   refusals     every method the wallet does not serve, called across the encrypted session, each
//                naming itself — with a SERVED method on the same object as the positive control.
//   keys         the deterministic derivation, three times in one page: same seed twice, and a
//                different seed once.
//   record       the `.ct` container, with the wallet's decisions in it as `TraceLogEvent`s.
//   suppressed   THE CONTROL FOR THE LEDGER. The same run with one decision KIND suppressed at the
//                wallet, so the container is missing exactly those records and nothing else.
//   shortcut     the direct store write, still working and still labelled.
//
// A FRESH PAGE PER ARM, because a network log is per page and a wallet's state is per page; an arm
// that inherited another's could not distinguish "this wallet declined" from "some wallet did".

import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { CdpConnection, launchChromium, openPage, requestsMatching, serveDirectory } from './browser_cdp.mjs';

const REPO = path.resolve(import.meta.dirname, '..');
const WORK = process.argv[2] ?? path.join(process.env.HOME, '.cache', 'aztec-m34-wallet');
mkdirSync(WORK, { recursive: true });

function fail(message) {
  process.stderr.write(`run_wallet_transfer_arms: ${message}\n`);
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

// The Token artifact, searched across the roots that carry one with the RESIDUE REPORTED — this
// tree has two @aztec nightly lines installed at once and they are not interchangeable. M27's own
// search, unchanged.
const ARTIFACT_REL = 'node_modules/@aztec/noir-contracts.js/artifacts/token_contract-Token.json';
const ARTIFACT_ROOTS = ['diffsim', 'spike', 'drift', 'probe-mt', 'orchestration'];
const artifactSearch = ARTIFACT_ROOTS.map((r) => ({ root: r, file: path.join(REPO, r, ARTIFACT_REL) }))
  .map((a) => ({ ...a, found: existsSync(a.file) }));
const artifactHit = artifactSearch.find((a) => a.found);
if (!artifactHit) fail(`no ${ARTIFACT_REL} under any of: ${ARTIFACT_ROOTS.join(', ')}`);

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
copyFileSync(artifactHit.file, path.join(SITE, 'assets/token_contract-Token.json'));

const sha = (f) => createHash('sha256').update(readFileSync(f)).digest('hex');

const DOWNLOADS = path.join(WORK, 'downloads');
rmSync(DOWNLOADS, { recursive: true, force: true });
mkdirSync(DOWNLOADS, { recursive: true });

const server = await serveDirectory(SITE);
const { child, endpoint } = await launchChromium(CHROMIUM, { userDataDir: path.join(WORK, 'chrome-profile') });
const conn = await CdpConnection.connect(endpoint);

const arms = {};
let exitCode = 0;

/** Everything a page saw, in the shape every assertion reads. */
function pageFacts(page) {
  return {
    requestCount: page.requests.length,
    requests: page.requests.map((r) => ({ url: r.url.replace(server.origin, ''), type: r.type })),
    barretenbergRequests: requestsMatching(page.requests, 'barretenberg').map((r) => r.url.replace(server.origin, '')),
    avmWasmRequests: requestsMatching(page.requests, 'avm.wasm').map((r) => r.url.replace(server.origin, '')),
    consoleErrors: page.console.filter((c) => c.level === 'error').map((c) => c.text),
    pageErrors: [...page.errors],
  };
}

/** Open the wallet demo page and wait for it to declare itself ready. */
async function walletPage(options = {}) {
  const page = await openPage(conn, `${server.origin}/wallet.html`, {
    loadTimeoutMs: 120_000,
    ...(options.downloadPath ? { downloadPath: options.downloadPath } : {}),
  });
  const ready = await page.eval('globalThis.walletDemoReady === true', 120_000);
  if (ready !== true) {
    throw new Error(`the wallet demo page did not become ready; page errors: ${JSON.stringify(page.errors)}`);
  }
  return page;
}

try {
  // ---- ARM 1: THE SUBJECT --------------------------------------------------------------------
  {
    const page = await walletPage();
    const report = await page.eval('window.walletDemo.armWalletTransfer()', 300_000);
    arms.transfer = { ...pageFacts(page), report };
    await page.close();
  }

  // ---- ARM 2: THE CONTROL — a wallet that declines to authorize -------------------------------
  {
    const page = await walletPage();
    const report = await page.eval(
      "window.walletDemo.armWalletTransfer({ decline: 'the operator declined this transaction' })",
      300_000,
    );
    arms.declined = { ...pageFacts(page), report };
    await page.close();
  }

  // ---- ARM 3: every unserved method refuses by name, and a served one reaches through ---------
  {
    const page = await walletPage();
    const report = await page.eval('window.walletDemo.armRefusals()', 300_000);
    arms.refusals = { ...pageFacts(page), report };
    await page.close();
  }

  // ---- ARM 4: the deterministic keys, in the page ---------------------------------------------
  {
    const page = await walletPage();
    const report = await page.eval('window.walletDemo.armDeterministicKeys()', 300_000);
    arms.keys = { ...pageFacts(page), report };
    await page.close();
  }

  // ---- ARM 5: the container, with the decisions in it ------------------------------------------
  //
  // THE BROWSER'S OWN DOWNLOAD MACHINERY writes the file, which is M27's shape: a container read
  // back off disk is a container the page really handed over, not one a probe read out of a
  // variable.
  {
    const dl = path.join(DOWNLOADS, 'subject');
    mkdirSync(dl, { recursive: true });
    const page = await walletPage({ downloadPath: dl });
    await page.eval('window.walletDemo.armWalletTransfer()', 300_000);
    const report = await page.eval('window.walletDemo.armRecord()', 300_000);
    const file = await waitForDownload(dl, 120_000);
    arms.record = {
      ...pageFacts(page),
      report,
      downloadedFile: file === null ? null : path.relative(WORK, file),
      downloadedBytes: file === null ? null : statSync(file).size,
      downloadedSha256: file === null ? null : sha(file),
    };
    await page.close();
  }

  // ---- ARM 6: THE CONTROL FOR THE LEDGER — one decision kind suppressed -------------------------
  {
    const dl = path.join(DOWNLOADS, 'suppressed');
    mkdirSync(dl, { recursive: true });
    const page = await walletPage({ downloadPath: dl });
    await page.eval("window.walletDemo.armWalletTransfer({ suppress: ['authorized'] })", 300_000);
    const report = await page.eval('window.walletDemo.armRecord()', 300_000);
    const file = await waitForDownload(dl, 120_000);
    arms.suppressed = {
      ...pageFacts(page),
      report,
      downloadedFile: file === null ? null : path.relative(WORK, file),
      downloadedBytes: file === null ? null : statSync(file).size,
      downloadedSha256: file === null ? null : sha(file),
    };
    await page.close();
  }

  // ---- ARM 7: the direct shortcut, still working and still labelled ----------------------------
  {
    const page = await walletPage();
    const report = await page.eval('window.walletDemo.armDirectShortcut()', 300_000);
    arms.shortcut = { ...pageFacts(page), report };
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

const out = {
  measuredAt: new Date().toISOString(),
  chromium: process.env.M27_CHROMIUM_VERSION ?? null,
  dist: path.relative(REPO, DIST),
  module: { path: AVM_WASM, sha256: sha(AVM_WASM), bytes: statSync(AVM_WASM).size },
  artifact: { root: artifactHit.root, sha256: sha(artifactHit.file) },
  arms,
};
writeFileSync(path.join(WORK, 'wallet-transfer.raw.json'), JSON.stringify(out, null, 2) + '\n');
process.stdout.write(JSON.stringify(out, null, 2) + '\n');
process.exit(exitCode);
