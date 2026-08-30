// replay_in_page.ts — L4's last piece: a settled transaction becomes a `.ct` IN THE BROWSER.
//
// ================================================================================================
// WHAT THIS MAKES TRUE THAT WAS NOT TRUE BEFORE.
// ================================================================================================
//
// L4 already showed a container PRODUCED IN NODE being OPENED AND STEPPED IN A BROWSER. That is
// browser-*replayable*. This entry closes the other half: the fetch, the hydration loop, the AVM,
// the comparison and the container are all in the page, so the demo is browser-*resident*.
//
// Everything it does is the same code the Node path runs — `fetchSettledTransaction`,
// `replaySettledTransaction`, `recordingPass`, `buildSettledRecording`, all from `replay/src` —
// with two substitutions and no third:
//
//   the AVM host      `createBrowserAvmHost`  instead of `createNodeAvmHost`
//   the writer bytes  `fetch()`               instead of `readFileSync`
//
// `ReplayAvmHost` and `RecordingWriter` are both STRUCTURAL for exactly this, and this file is what
// says the two declarations were worth making. If a third substitution had been needed, one of them
// was wrong.
//
// ================================================================================================
// IT RUNS OFF THE COMMITTED FIXTURE, WHICH IS A CHOICE AND NOT A LIMITATION.
// ================================================================================================
//
// The page plays back `testnet_replay_tx.json` through upstream's own `createAztecNodeClient` —
// the same recording, the same zod, the same client the Node path uses. So the smoke is
// DETERMINISTIC and OFFLINE: it measures the browser, not somebody else's node.
//
// A page pointed at a live RPC is one argument away — `createReplayNodeClient({ url })` with no
// `fetchImpl` — and is deliberately not what the check drives, for `verify-l1`'s reason: a check
// that needs a live testnet goes red on somebody else's schedule.

import { TxHash } from '@aztec/stdlib/tx/tx-hash';

import {
  RUNG_BYTECODE_VALUE,
  buildSettledRecording,
  createReplayNodeClient,
  encodeRecordingInputs,
  encodeReplayInputs,
  fetchSettledTransaction,
  recordingIdFor,
  recordingPass,
  replaySettledTransaction,
} from '../src/index.ts';
import { fixtureFetch, loadSettledFixture } from '../tools/settled_fixture.ts';
import { createBrowserAvmHost } from '../tools/browser_avm_host.ts';
import {
  CtWriter,
  WRITER_PATH_A_PURE_RUST,
  instantiateCtWriter,
  resolveTracingConfig,
} from '../../ct-host/src/index.ts';

export type ReplayInPageOptions = {
  readonly fixtureUrl: string;
  readonly avmWasmUrl: string;
  readonly ctWriterWasmUrl: string;
  readonly onProgress?: (phase: string, detail?: string) => void;
};

export type ReplayInPageResult = {
  readonly txHash: string;
  readonly l2BlockNumber: number;
  readonly preStateBlock: number;
  readonly hydrationRounds: number;
  readonly seededNullifiers: number;
  readonly seededPublicData: number;
  readonly publishedRevertCode: number;
  readonly replayedRevertCode: number;
  readonly reproduced: boolean;
  readonly comparisonsMatched: number;
  readonly comparisonsTotal: number;
  readonly instructionsExecuted: number;
  readonly steps: number;
  readonly declaredRung: number;
  readonly rootsAgree: boolean;
  readonly containerBytes: number;
  /** The container itself, base64 so it can cross `Runtime.evaluate` by value. */
  readonly containerBase64: string;
  readonly logEvents: number;
  readonly metadataKeys: readonly string[];
};

/** The whole path, in the page. */
export async function replayInPage(options: ReplayInPageOptions): Promise<ReplayInPageResult> {
  const say = options.onProgress ?? (() => {});

  say('fetching the fixture');
  const raw = await (await fetch(options.fixtureUrl)).json();
  const fixture = loadSettledFixture(raw, options.fixtureUrl);

  // UPSTREAM'S OWN CLIENT OVER UPSTREAM'S OWN SCHEMA, in a browser, driven by the committed
  // recording. L1's fixture format is a recording of `JsonRpcFetch`, so upstream's zod validates
  // the committed bytes here exactly as it does in Node.
  const client = createReplayNodeClient({
    url: fixture.provenance.endpoint,
    fetchImpl: fixtureFetch(fixture),
  });

  // THE AVM COMES FIRST, AND THE ORDER IS LOAD-BEARING RATHER THAN TIDY. Creating the host
  // compiles `avm.wasm` AND installs its poseidon2 as `@aztec/foundation`'s hash backend (DD-11).
  // Fetching first died with `Poseidon2NotInstalled` four frames inside `zod`: upstream's schema
  // computes a transaction hash while PARSING the recorded response, so the run's first poseidon
  // happens before the replay has an AVM instance.
  say('compiling avm.wasm');
  const host = await createBrowserAvmHost({ moduleUrl: options.avmWasmUrl });

  say('fetching the settled transaction');
  const settled = await fetchSettledTransaction(client, TxHash.fromString(fixture.provenance.txHash),
    { pinToSettlingBlock: true });

  say('hydrating');
  const hydrated = await replaySettledTransaction(host, client, settled, encodeReplayInputs, {
    onRound: (r) => say('hydration round', `${r.round}: ${r.queries} queries, ${r.added} seeded`),
  });

  // THE SECOND PASS, for the reason `RECORDING_PASS_REASON` gives: the module will not produce
  // hints and an execution step stream in one run. It refuses if the two passes disagree.
  say('recording pass');
  const pass = await recordingPass(host, settled, hydrated, encodeRecordingInputs);

  say('writing the container');
  const writerBytes = new Uint8Array(await (await fetch(options.ctWriterWasmUrl)).arrayBuffer());
  const writer = new CtWriter(
    await instantiateCtWriter(writerBytes),
    resolveTracingConfig({
      program: 'aztec-live-chain-replay',
      recordingId: recordingIdFor(settled.txHash, settled.blockData.header.globalVariables.timestamp),
      sourcePath: `/aztec/${settled.txHash}.avm`,
      workdir: '/aztec',
      mappingRung: RUNG_BYTECODE_VALUE,
      // Columns OFF at rung 3 — `resolveTracingConfig` refuses them, and it is right to: a program
      // counter has no column. See `recording.ts`.
      columns: false,
    } as never, WRITER_PATH_A_PURE_RUST),
    { batchRecords: 64 },
  );
  const recording = buildSettledRecording(
    writer, settled, { ...hydrated, steps: pass.steps }, pass.steps);

  say('done', `${recording.bytes} bytes`);
  return {
    txHash: settled.txHash,
    l2BlockNumber: settled.l2BlockNumber,
    preStateBlock: hydrated.preStateBlock,
    hydrationRounds: hydrated.rounds.length,
    seededNullifiers: hydrated.seedSize.nullifiers,
    seededPublicData: hydrated.seedSize.publicData,
    publishedRevertCode: settled.revertCode,
    replayedRevertCode: pass.revertCode,
    reproduced: pass.verdict.reproduced,
    comparisonsMatched: pass.verdict.matched,
    comparisonsTotal: pass.verdict.comparisons.length,
    instructionsExecuted: pass.instructionsExecuted,
    steps: recording.steps,
    declaredRung: recording.declaredRung,
    rootsAgree: hydrated.roots.anyAgrees,
    containerBytes: recording.bytes,
    containerBase64: toBase64(recording.container),
    logEvents: recording.logEvents,
    metadataKeys: recording.metadataKeys,
  };
}

/**
 * Base64 without `Buffer`, because this runs in a page.
 *
 * Chunked, because `String.fromCharCode(...bytes)` on a 188 KB array is a spread of 188,000
 * arguments and blows the call stack — which is a crash in the one place a container has already
 * been successfully built, and reads as "the replay failed".
 */
function toBase64(bytes: Uint8Array): string {
  let binary = '';
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

// The page's own entry point. Kept to one global so the CDP driver has one thing to await.
declare global {
  // eslint-disable-next-line no-var
  var __replayInPage: ((o: ReplayInPageOptions) => Promise<ReplayInPageResult>) | undefined;
}
globalThis.__replayInPage = replayInPage;
