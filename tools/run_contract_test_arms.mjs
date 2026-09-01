// run_contract_test_arms.mjs — a JavaScript contract test suite, executed in a real browser tab.
//
//   AVM_WASM_PATH=… CT_CHROMIUM=… node tools/run_contract_test_arms.mjs <work-dir>
//
// The convention this follows is M20's, kept by M22..M32: the arms are measured ONCE and shared, so
// several checks deriving the same number from their own browser launch cannot come to disagree
// about it — and it is one browser rather than six.
//
// ===========================================================================================
// FIVE ARMS. THE FIRST IS THE SUBJECT; THE OTHER FOUR ARE WHAT MAKE ITS GREEN MEAN SOMETHING.
// ===========================================================================================
//
//   pass        The subject. `browser/testkit/token.suite.js` against the SHIPPED `testing.js`, in
//               a tab. Every test must pass, and the counts must be non-zero.
//   mutated     THE FAIL DEMONSTRATION, and it is a mutation of the suite's own source rather than
//               a planted `expect(false)`. One constant — the expected transferred amount — is
//               changed from 5 to 6 in a COPY, served from the same site. The runner must report
//               `status: 'failed'` with exactly the balance test red and every other test still
//               green. A runner that cannot report failure has not been shown to work; a runner
//               that reports failure by turning everything red has not been shown to be
//               discriminating.
//   loadError   A suite URL that 404s. Must be `error` / `load-failed`, never an empty pass. This
//               is the arm that says a suite which fails to load is a HARD FAILURE.
//   emptySuite  A suite that registers nothing. Must be `error` / `no-tests`.
//   noExpect    A suite with one asserting test and one asserting nothing. The second must be
//               failed by name with `no-expectations`; the first must still pass.
//
// A FRESH PAGE PER ARM. The runtime accumulates world state across a `run()`, and two arms sharing
// a page would have the second one's transfer land on the first one's tree — a difference that
// looks like a test failure and is a fixture defect. The browser process is shared; nothing else.
//
// THIS PROGRAM ASSERTS NOTHING. It reports facts, and
// `verification/e2e_contract_tests_run_in_browser.sh` counts assertions over them. That split is
// `run_browser_arms.mjs`'s and it exists so the control arm and every mutation arm read the same
// instrument.

import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import process from 'node:process';

import { CdpConnection, launchChromium, openPage, serveDirectory } from './browser_cdp.mjs';

const REPO = path.resolve(import.meta.dirname, '..');
const WORK = process.argv[2] ?? path.join(process.env.HOME, '.cache', 'aztec-contract-tests');
mkdirSync(WORK, { recursive: true });

function fail(message) {
  process.stderr.write(`run_contract_test_arms: ${message}\n`);
  process.exit(2);
}

const sha = (b) => createHash('sha256').update(b).digest('hex');

const AVM_WASM = process.env.AVM_WASM_PATH;
if (!AVM_WASM || !existsSync(AVM_WASM)) {
  fail(`AVM_WASM_PATH is not set to an existing module (${AVM_WASM})`);
}
const CHROMIUM = process.env.CT_CHROMIUM ?? process.env.M27_CHROMIUM ?? '/usr/bin/chromium';
if (!existsSync(CHROMIUM)) fail(`no chromium at ${CHROMIUM}`);

const DIST = path.join(REPO, 'browser/dist');
if (!existsSync(path.join(DIST, 'testing.js'))) {
  fail(`no built bundle at ${DIST}. Remedy: node browser/build.mjs`);
}
const TESTKIT = path.join(REPO, 'browser/testkit');

// The Token artifact, searched across the roots that carry one WITH THE RESIDUE REPORTED, because
// this tree has two @aztec nightly lines installed at once and they are not interchangeable.
const ARTIFACT_REL = 'node_modules/@aztec/noir-contracts.js/artifacts/token_contract-Token.json';
const ARTIFACT_ROOTS = ['diffsim', 'spike', 'drift', 'probe-mt', 'orchestration'];
const artifactSearch = ARTIFACT_ROOTS.map((r) => ({
  root: r,
  file: path.join(REPO, r, ARTIFACT_REL),
  found: existsSync(path.join(REPO, r, ARTIFACT_REL)),
}));
const artifactHit = artifactSearch.find((a) => a.found);
if (!artifactHit) fail(`no ${ARTIFACT_REL} under any of: ${ARTIFACT_ROOTS.join(', ')}`);

// ---------------------------------------------------------------------------------------------
// The served site: the built bundle, the testkit beside it, and the two assets a page fetches.
// COPIED, NOT SYMLINKED, so the sha256 this run reports is of the bytes the browser received.
// ---------------------------------------------------------------------------------------------
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
copyTree(TESTKIT, path.join(SITE, 'testkit'));
copyFileSync(AVM_WASM, path.join(SITE, 'assets/avm.wasm'));
copyFileSync(artifactHit.file, path.join(SITE, 'assets/token_contract-Token.json'));
// The page lives at the site ROOT, because its `./testing.js` import must resolve to the shipped
// entry beside it. The HTML moves with it.
copyFileSync(path.join(TESTKIT, 'page.js'), path.join(SITE, 'tests_page.js'));
copyFileSync(path.join(TESTKIT, 'tests.html'), path.join(SITE, 'tests.html'));
rmSync(path.join(SITE, 'testkit/page.js'), { force: true });
rmSync(path.join(SITE, 'testkit/tests.html'), { force: true });

// ---------------------------------------------------------------------------------------------
// THE MUTANT. One constant in a COPY of the suite, and the mutation is asserted to have APPLIED —
// a `replace` that matched nothing would serve the original and produce a green "fail arm", which
// is the vacuous-mutation-arm defect this campaign names: an arm whose premise has moved reports
// "could not be measured" forever while looking like coverage.
// ---------------------------------------------------------------------------------------------
const SUITE_SRC = path.join(TESTKIT, 'token.suite.js');
const suiteText = readFileSync(SUITE_SRC, 'utf8');
const MUTATION_FROM = "const EXPECTED_TRANSFERRED = '5';";
const MUTATION_TO = "const EXPECTED_TRANSFERRED = '6';";
const mutationApplied = suiteText.includes(MUTATION_FROM);
const mutantText = suiteText.replace(MUTATION_FROM, MUTATION_TO);
writeFileSync(path.join(SITE, 'testkit/token.mutant.suite.js'), mutantText);

const out = {
  chromium: CHROMIUM,
  site: SITE,
  avmWasm: { path: AVM_WASM, bytes: statSync(AVM_WASM).size, sha256: sha(readFileSync(AVM_WASM)) },
  artifact: {
    root: artifactHit.root,
    bytes: statSync(artifactHit.file).size,
    search: artifactSearch.map((a) => `${a.root}:${a.found}`).join(','),
  },
  shipped: {
    // The suite runs against THESE BYTES. Reported so a reader can tell that the module under test
    // is the built artefact rather than a source tree the driver happened to bundle.
    testingJsSha256: sha(readFileSync(path.join(DIST, 'testing.js'))),
    testingJsBytes: statSync(path.join(DIST, 'testing.js')).size,
  },
  mutation: {
    applied: mutationApplied,
    from: MUTATION_FROM,
    to: MUTATION_TO,
    // A mutant identical to its source is a mutation that did not happen.
    changed: mutantText !== suiteText,
  },
  runnerSha256: sha(readFileSync(path.join(TESTKIT, 'runner.js'))),
  suiteSha256: sha(Buffer.from(suiteText)),
  arms: {},
};

const server = await serveDirectory(SITE);
// A FRESH PROFILE DIRECTORY. A `SingletonLock` left behind by a run that was killed makes
// chromium exit 21 before it announces a DevTools endpoint — which arrives as "the browser never
// started" and reads like a broken check rather than a stale file. Measured, on this machine.
const PROFILE = path.join(WORK, 'chrome-profile');
rmSync(PROFILE, { recursive: true, force: true });
const chrome = await launchChromium(CHROMIUM, { userDataDir: PROFILE });
const conn = await CdpConnection.connect(chrome.endpoint);

const ARM_TIMEOUT_MS = Number(process.env.CT_ARM_TIMEOUT_MS ?? 300_000);

async function arm(name, suiteUrl) {
  const page = await openPage(conn, `${server.origin}/tests.html`);
  const record = { suiteUrl };
  try {
    const expression = `avmTestkit.run(${JSON.stringify({ suiteUrl })})`;
    record.report = await page.eval(expression, ARM_TIMEOUT_MS);
  } catch (err) {
    // A THROWN ARM IS RECORDED, NOT DISCARDED. The check requires each arm to be present; an arm
    // that vanished would make the milestone silently smaller instead of red.
    record.error = String(err && err.message ? err.message : err);
    record.stack = String(err && err.stack).slice(0, 1200);
  }
  record.pageErrors = page.errors.slice(0, 8);
  record.consoleErrors = page.console.filter((c) => c.level === 'error').map((c) => c.text).slice(0, 8);
  // Which module the tab actually fetched. A gate that assumed the URL would go green over a page
  // that silently fell back to something else.
  record.fetchedTesting = page.requests.filter((r) => r.url.endsWith('/testing.js')).length;
  record.fetchedAvmWasm = page.requests.filter((r) => r.url.endsWith('/avm.wasm')).length;
  await page.close();
  out.arms[name] = record;
}

try {
  await arm('pass', './testkit/token.suite.js');
  await arm('mutated', './testkit/token.mutant.suite.js');
  await arm('loadError', './testkit/no_such_suite.js');
  await arm('emptySuite', './testkit/controls/empty.suite.js');
  await arm('noExpect', './testkit/controls/noexpect.suite.js');
} catch (err) {
  out.armsError = { message: String(err && err.message ? err.message : err), stack: String(err && err.stack).slice(0, 1600) };
} finally {
  // TEARDOWN MUST NOT BE ABLE TO DESTROY THE REPORT. A throw in here — `conn.close()` returning
  // undefined was one — propagates out of the `finally` and the process exits with the arms run
  // complete and NOTHING WRITTEN, which reads as "the browser produced no output" after a browser
  // run that had just succeeded. That is a recorded defect of `m27_require_arms`, one level down.
  try { conn.close(); } catch { /* the report matters more than a tidy socket */ }
  try { chrome.child.kill('SIGKILL'); } catch { /* already gone */ }
  try { await server.close(); } catch { /* already closed */ }
}

process.stdout.write(`${JSON.stringify(out, null, 2)}\n`);
if (out.armsError) process.exit(1);
