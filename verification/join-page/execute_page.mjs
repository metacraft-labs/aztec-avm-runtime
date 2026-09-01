// execute_page.mjs — REGISTER, EXECUTE and TRACE, inside the tab.
//
// The correction this file exists for. `join_execute_probe.mjs` runs the same three stages in
// NODE, against bytes a tab produced, and says so in its own header. That is a real join and it
// is not the milestone's claim: "in the browser" is the milestone's phrase, and it was true of
// the compile and the transpile and not of the execution.
//
// Nothing here is new capability. The runtime already registers, executes and records in a page —
// that is `browser/demo/main.ts`, and it has done so since M27. What it had never done is run a
// contract the TAB ITSELF COMPILED: the demo fetches `token_contract-Token.json`, a fixture built
// by a native `nargo`. So this is the demo's sequence over stage 1's artifact, and the only
// reason it needed writing at all is that the demo hardcodes its artifact URL and its function
// names.
//
// Everything is imported from the SHIPPED `testing.js` bundle — the same entry point
// `verify_browser_entry_points_are_dd5_shaped` measures — so what runs here is what the product
// ships, not a page-local reimplementation.

import {
  DateProvider,
  openAvmRuntime,
  runTokenTransfer,
  recordAndDownload,
  fetchCtWriter,
} from './testing.js';

const MODULE_URL = './assets/avm.wasm';
const CT_WRITER_URL = './assets/ct_writer.wasm';
const ARTIFACT_URL = './assets/browser-transpiled.json';

/** @see join_execute_probe.mjs — the same two adapters, for the same two version skews. */
function adaptStorageGlobals(input) {
  const storage = input?.outputs?.globals?.storage;
  let lifted = 0;
  if (Array.isArray(storage)) {
    for (let i = 0; i < storage.length; i += 1) {
      const entry = storage[i];
      if (entry && entry.kind === undefined && entry.value && entry.value.kind !== undefined) {
        storage[i] = entry.value;
        lifted += 1;
      }
    }
  }
  return lifted;
}

function stripInternalsPrefix(input) {
  const PREFIX = '__aztec_nr_internals__';
  let renamed = 0;
  for (const fn of input.functions ?? []) {
    if (typeof fn.name === 'string' && fn.name.startsWith(PREFIX)) {
      fn.name = fn.name.slice(PREFIX.length);
      renamed += 1;
    }
  }
  return renamed;
}

function uuidV7() {
  const b = crypto.getRandomValues(new Uint8Array(16));
  const ms = BigInt(Date.now());
  for (let i = 0; i < 6; i += 1) b[i] = Number((ms >> BigInt(8 * (5 - i))) & 0xffn);
  b[6] = (b[6] & 0x0f) | 0x70;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = Array.from(b).map((x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

async function run() {
  const status = document.getElementById('status');
  const say = (m) => { status.textContent = m; };

  say('fetching the artifact the tab compiled…');
  const response = await fetch(ARTIFACT_URL);
  if (!response.ok) throw new Error(`${ARTIFACT_URL}: ${response.status}`);
  const artifactBytes = new Uint8Array(await response.arrayBuffer());
  const artifactSha = Array.from(new Uint8Array(
    await crypto.subtle.digest('SHA-256', artifactBytes)))
    .map((x) => x.toString(16).padStart(2, '0')).join('');
  const artifact = JSON.parse(new TextDecoder().decode(artifactBytes));

  const lifted = adaptStorageGlobals(artifact);
  const renamed = stripInternalsPrefix(artifact);

  say('opening the AVM…');
  const opened = await openAvmRuntime({
    moduleUrl: MODULE_URL,
    clock: new DateProvider(),
    collectExecutionSteps: true,
  });

  const result = {
    where: 'browser',
    artifact: {
      name: artifact.name,
      functions: artifact.functions.length,
      bytes: artifactBytes.length,
      sha256: artifactSha,
    },
    adapters: { storageGlobalsLifted: lifted, internalsPrefixRenamed: renamed },
    module: {
      bytes: opened.compiled.byteLength,
      declaredImports: opened.compiled.declaredImports.length,
    },
  };

  say('registering and executing…');
  const report = await runTokenTransfer(opened, artifact, {
    transferFunction: 'public_transfer',
    balanceFunction: 'public_balance_of',
    constructorFunction: 'constructor',
    constructorArgs: ['Tok', 'TOK', 18],
    balancesStorageMember: 'public_balances',
  });

  result.execute = {
    outcome: report.outcome,
    revertCode: report.revertCode,
    revertDescription: report.revertDescription,
    blockNumber: report.blockNumber,
    enqueuedPublicCalls: report.enqueuedPublicCalls,
    registeredClasses: report.registeredClasses,
    registeredInstances: report.registeredInstances,
    balances: report.balances,
    contractAddress: String(report.contractAddress),
    debugFunctionName: report.debugFunctionName,
  };

  const executed = opened.steps.last;
  result.steps = executed
    ? { count: executed.count, decoded: executed.steps.length, crossings: executed.crossings }
    : null;

  say('recording…');
  const writerBytes = await fetchCtWriter(CT_WRITER_URL);
  const recording = await recordAndDownload({
    writerBytes,
    rawArtifact: artifact,
    contractAddress: Uint8Array.from(
      String(report.contractAddress).replace(/^0x/, '').match(/../g).map((h) => parseInt(h, 16))),
    frameNames: [report.debugFunctionName, undefined],
    recordingId: uuidV7(),
    executed,
    // FALSE, so the harness reads the bytes instead of the browser saving a file. The container
    // is identical either way; `offerDownload` is four lines of DOM on top of it.
    download: false,
    extraLogEvents: [{
      metadata: 'ct.bytecode-provenance',
      content: 'compiled by noir_wasm.wasm and transpiled by avm_transpiler_wasm.wasm in this '
        + `browser; registered and executed in this browser; artifact sha256 ${artifactSha}`,
    }],
  });

  result.trace = {
    bytes: recording.bytes,
    events: recording.events,
    executedSteps: recording.executedSteps,
    rung: recording.rung,
    declaredRung: recording.declaredRung,
    stepsPositioned: recording.stepsPositioned,
    stepsUnpositioned: recording.stepsUnpositioned,
    distinctOpcodes: recording.distinctOpcodes,
    pathsInterned: recording.pathsInterned,
    callsOpened: recording.callsOpened,
    recordingId: recording.recordingId,
  };

  // The container travels out as base64 so the harness can hand THESE BYTES to `ct-print`.
  let binary = '';
  for (let i = 0; i < recording.container.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, recording.container.subarray(i, i + 0x8000));
  }
  result.containerBase64 = btoa(binary);

  await opened.close();
  say(`done: revertCode ${report.revertCode}, ${recording.executedSteps} steps`);
  document.getElementById('out').textContent =
    JSON.stringify({ ...result, containerBase64: `<${recording.bytes} bytes>` }, null, 2);
  return result;
}

window.__RUN__ = run().then((r) => { window.__RESULT__ = r; return 'ok'; })
  .catch((e) => {
    window.__RESULT__ = { fatal: String((e && e.stack) || e) };
    document.getElementById('out').textContent = String((e && e.stack) || e);
    throw e;
  });
