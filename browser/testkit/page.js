// page.js — the page half of the browser test runner.
//
// It opens the SHIPPED runtime (`./testing.js`, byte for byte as `browser/build.mjs` emitted it —
// this file adds no entry point and does not go through the bundler, so M28's input count and the
// DD-5 entry-point shape are untouched by the existence of a test runner), fetches the contract
// artifact, and hands both to `runner.js` as a suite context.
//
// EVERYTHING IS EXPOSED ON `globalThis.avmTestkit` AND NOTHING RUNS ON LOAD. The arm driver calls
// `run()` over CDP and reads the JSON back. A page that ran its suite on load would give the driver
// no way to tell "still running" from "finished with nothing to say".

import { openAvmRuntime, runTokenTransfer, TestDateProvider } from './testing.js';
import { runSuite } from './testkit/runner.js';

const state = { opened: null, rawArtifact: null };

async function ensureOpen() {
  if (state.opened) return state.opened;
  state.opened = await openAvmRuntime({
    moduleUrl: './assets/avm.wasm',
    clock: new TestDateProvider(),
    // WITHOUT THIS THE STEP STREAM IS `null`, and the suite's step assertions would be asserting
    // over an absence. `collectExecutionSteps` also turns the `total_instructions_executed`
    // statistic on, which is the other side of the comparison the suite makes.
    collectExecutionSteps: true,
    disclosureSink: () => {},
  });
  return state.opened;
}

async function ensureArtifact() {
  if (state.rawArtifact) return state.rawArtifact;
  const response = await fetch('./assets/token_contract-Token.json');
  if (!response.ok) throw new Error(`the Token artifact fetch failed: ${response.status}`);
  state.rawArtifact = await response.json();
  return state.rawArtifact;
}

/**
 * Run one suite and return its report.
 *
 * A failure to open the runtime or fetch the artifact is reported as `status: 'error'` with
 * `reason: 'context-failed'` — NOT as a suite with no tests, which is what a `try` around the whole
 * thing would have produced and which is indistinguishable from a green empty run.
 */
async function run(options = {}) {
  // ABSOLUTISED AGAINST THE DOCUMENT, NOT LEFT RELATIVE. `runner.js` does the `import()`, and a
  // relative specifier there would resolve against the RUNNER's URL rather than the page's — so
  // `./testkit/token.suite.js` would become `testkit/testkit/token.suite.js` and arrive as a
  // `load-failed`. That is a defect that looks exactly like a broken suite.
  const suiteUrl = new URL(options.suiteUrl ?? './testkit/token.suite.js', document.baseURI).href;
  let context;
  try {
    const [opened, rawArtifact] = await Promise.all([ensureOpen(), ensureArtifact()]);
    context = { opened, rawArtifact, runTokenTransfer };
  } catch (err) {
    return {
      status: 'error',
      reason: 'context-failed',
      message: String(err && err.stack ? err.stack : err).slice(0, 1200),
      moduleUrl: suiteUrl,
      total: 0, executed: 0, completed: 0, passed: 0, failed: 0, assertions: 0, tests: [],
    };
  }
  const report = await runSuite(suiteUrl, context);
  render(report);
  return report;
}

function render(report) {
  const el = document.getElementById('report');
  if (!el) return;
  const head = `${report.status.toUpperCase()} — ${report.passed}/${report.total} passed, `
    + `${report.assertions} assertion(s)${report.reason ? `, reason: ${report.reason}` : ''}`;
  const lines = report.tests.map(
    (t) => `${t.status === 'passed' ? 'ok  ' : 'FAIL'} ${t.name}${t.message ? `\n       ${t.message.split('\n')[0]}` : ''}`,
  );
  el.textContent = [head, '', ...lines, ...(report.message ? ['', report.message] : [])].join('\n');
}

globalThis.avmTestkit = { run, state };
document.getElementById('report').textContent = 'ready';
