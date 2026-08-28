// The worker-node demo page — M32's demo, and M32's harness.
//
// M27's rule, kept: everything the headless checks drive is a BUTTON on this page. There is no
// test-only path into the runtime, so "the demo works" and "the checks pass" cannot come apart.
//
// ===========================================================================================
// THE ARM THAT NEEDS A CONTROL, AND WHY THE CONTROL IS ON THIS PAGE RATHER THAN IN A CHECK
// ===========================================================================================
//
// `smoke_worker_chain_survives_main_thread_block` asserts that a busy main thread does not stall
// block production. On its own that assertion is worth nothing: a chain that produced no blocks at
// all would satisfy "the busy window did not stop it" just as well as one that kept going, and a
// chain that produced blocks would satisfy it whether or not the main thread was ever busy.
//
// So the page runs the SAME LOAD twice — the same interval, the same minimum spacing, the same busy
// duration, the same measurement — once with the runtime in a worker and once with the runtime on
// the main thread, and each arm measures TWO windows: a warm window in which the page is idle, and
// a busy window in which it is not. The four numbers are what discriminate:
//
//                     warm window        busy window
//   worker             blocks            blocks          <- production survives
//   main thread        blocks            ZERO            <- production stalls
//
// A worker arm that produced nothing in the warm window would not be evidence of anything, and a
// main-thread arm that produced nothing in EITHER window would be a broken chain rather than a
// stalled one. Both are assertions in the check.

import { jsonStringify } from '@aztec/foundation/json-rpc';

import {
  DateProvider,
  openAvmRuntime,
  offerDownload,
  runTokenTransfer,
  type ChainBlock,
  type OpenedRuntime,
} from '../src/entry_testing.ts';
import { openWorkerNode, WorkerNodeClient } from '../src/worker_client.ts';
import {
  WORKER_OFF_SCHEMA_OPS,
  WORKER_PROTOCOL,
  WORKER_PROTOCOL_BACKING,
  WORKER_SUBSCRIPTIONS,
  WORKER_TESTING_OPS,
} from '../src/worker_protocol.ts';

const WORKER_URL = './worker.js';
const MODULE_URL = './assets/avm.wasm';
const CT_WRITER_URL = './assets/ct_writer.wasm';
const ARTIFACT_URL = './assets/token_contract-Token.json';
const RECORDING_ID = '01949fcc-7d92-7e9c-8000-000000003201';

/**
 * Everything an arm returns goes through here, and the reason is the CDP boundary rather than
 * tidiness.
 *
 * The protocol's replies are parsed against `worker_protocol.ts`'s schemas, and `schemas.BigInt`
 * produces a real `bigint` — which is right, because a block timestamp IS one. But `Runtime.evaluate`
 * with `returnByValue` serialises through JSON, and `JSON.stringify` of a bigint THROWS. The first
 * run of these arms died on exactly that, in `say()`, four layers from anything to do with workers.
 * `jsonStringify` is upstream's own JSON helper and already in this graph; it renders a bigint as
 * the decimal string the schemas accept back.
 */
function plain(value: unknown): unknown {
  return JSON.parse(jsonStringify(value));
}

const log: string[] = [];
function say(line: string): void {
  log.push(line);
  const el = document.getElementById('log');
  if (el) el.textContent = log.join('\n');
}

let client: WorkerNodeClient | null = null;
/** Every event the worker pushed to this page, through the `Comlink.proxy` subscription. */
const events: { kind: string; event: unknown; atMs: number }[] = [];

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Block this thread. Not a sleep — a `setTimeout` yields, which is the opposite of the point.
 *
 * The accumulator is returned so the loop is OBSERVABLE: a busy loop whose result nothing reads is
 * a busy loop an optimiser is entitled to remove, and an arm that measured a main thread which was
 * never actually blocked would report the worker's advantage over nothing at all.
 */
function blockMainThread(ms: number): { spun: number; actualMs: number } {
  const started = performance.now();
  let spun = 0;
  while (performance.now() - started < ms) {
    spun += 1;
  }
  return { spun, actualMs: performance.now() - started };
}

async function boot(production: Record<string, unknown> = {}): Promise<WorkerNodeClient> {
  if (client) return client;
  client = await openWorkerNode({ workerUrl: WORKER_URL });
  const state = await client.open({ moduleUrl: MODULE_URL, collectExecutionSteps: true, ...production });
  say(`worker node open: ${jsonStringify(state)}`);
  for (const kind of WORKER_SUBSCRIPTIONS) {
    await client.subscribe(kind, event => events.push({ kind, event, atMs: performance.now() }));
  }
  say(`subscribed to ${WORKER_SUBSCRIPTIONS.join(', ')}`);
  return client;
}

// ---------------------------------------------------------------------------------------------
// ARM: the node lives in a worker at all. The protocol, the subscriptions, a real transaction.
// ---------------------------------------------------------------------------------------------
async function armWorkerBoot(): Promise<Record<string, unknown>> {
  const c = await boot({ intervalMs: 0, minBlockSpacingSeconds: 1 });
  const transfer = await c.runTokenTransfer(ARTIFACT_URL);
  const state = await c.state();
  say(`token transfer in the worker: ${jsonStringify(transfer)}`);
  return plain({
    protocol: [...WORKER_PROTOCOL],
    offSchema: Object.keys(WORKER_OFF_SCHEMA_OPS).sort(),
    subscriptions: [...WORKER_SUBSCRIPTIONS],
    testingOps: [...WORKER_TESTING_OPS],
    backing: WORKER_PROTOCOL_BACKING,
    transfer,
    state,
    callsMade: [...c.calls],
    events: events.map(e => ({ kind: e.kind, event: e.event })),
    eventKinds: [...new Set(events.map(e => e.kind))].sort(),
    // THE PAGE HAS A DOM AND THE WORKER DOES NOT. Reported so the check can say the runtime ran
    // where there is no `document`, rather than inferring it from the file it was built into.
    pageHasDocument: typeof document !== 'undefined',
  }) as Record<string, unknown>;
}

// ---------------------------------------------------------------------------------------------
// ARM: a busy main thread, with the chain IN THE WORKER.
// ---------------------------------------------------------------------------------------------
async function armWorkerUnderMainThreadBlock(
  options: { busyMs?: number; warmMs?: number; intervalMs?: number } = {},
): Promise<Record<string, unknown>> {
  const busyMs = options.busyMs ?? 4000;
  const warmMs = options.warmMs ?? 4000;
  const intervalMs = options.intervalMs ?? 250;
  const c = await boot({ intervalMs, minBlockSpacingSeconds: 1 });
  await c.start();

  const warmOpen = (await c.state()) as { atMs: number };
  await sleep(warmMs);
  const warmClose = (await c.state()) as { atMs: number };

  // POSTED, NOT AWAITED. Comlink's proxy posts synchronously when the method is called, so this
  // message is on its way before the loop below starts; its reply carries the WORKER's own reading
  // of the moment it handled it, which is the left edge of the busy window.
  const busyOpenPending = c.state() as Promise<{ atMs: number }>;
  const spin = blockMainThread(busyMs);
  const busyClosePending = c.state() as Promise<{ atMs: number }>;
  const busyOpen = await busyOpenPending;
  const busyClose = await busyClosePending;

  await c.stop();
  const blocks = (await c.blocks()) as { number: number; producedAtMs: number; timestamp: string }[];
  const inWindow = (from: number, to: number) => blocks.filter(b => b.producedAtMs > from && b.producedAtMs <= to);
  const report = {
    where: 'worker',
    intervalMs,
    busyMs,
    warmMs,
    spun: spin.spun,
    busyActualMs: spin.actualMs,
    warmOpenAtMs: warmOpen.atMs,
    warmCloseAtMs: warmClose.atMs,
    busyOpenAtMs: busyOpen.atMs,
    busyCloseAtMs: busyClose.atMs,
    warmWindowMs: warmClose.atMs - warmOpen.atMs,
    busyWindowMs: busyClose.atMs - busyOpen.atMs,
    lastBlockAtMs: blocks.length === 0 ? null : blocks[blocks.length - 1]!.producedAtMs,
    warmBlocks: inWindow(warmOpen.atMs, warmClose.atMs).length,
    busyBlocks: inWindow(busyOpen.atMs, busyClose.atMs).length,
    totalBlocks: blocks.length,
    blocks,
  };
  say(`[worker] warm ${report.warmBlocks} block(s), busy ${report.busyBlocks} block(s)`);
  return plain(report) as Record<string, unknown>;
}

// ---------------------------------------------------------------------------------------------
// ARM: THE CONTROL. The same load, the same windows, the runtime ON THE MAIN THREAD.
// ---------------------------------------------------------------------------------------------
async function armMainThreadControl(
  options: { busyMs?: number; warmMs?: number; intervalMs?: number } = {},
): Promise<Record<string, unknown>> {
  const busyMs = options.busyMs ?? 4000;
  const warmMs = options.warmMs ?? 4000;
  const intervalMs = options.intervalMs ?? 250;
  const seen: { number: number; producedAtMs: number; timestamp: string }[] = [];
  const opened: OpenedRuntime = await openAvmRuntime({
    moduleUrl: MODULE_URL,
    clock: new DateProvider(),
    production: { intervalMs, minBlockSpacingSeconds: 1 } as never,
    disclosureSink: () => {},
    writeLine: () => {},
  });
  opened.runtime.subscribe('block', (b: ChainBlock) => {
    seen.push({ number: b.number, producedAtMs: performance.now(), timestamp: b.timestamp.toString() });
  });
  opened.runtime.start();

  const warmOpen = performance.now();
  await sleep(warmMs);
  const warmClose = performance.now();

  const busyOpen = performance.now();
  const spin = blockMainThread(busyMs);
  const busyClose = performance.now();

  await opened.runtime.stop();
  const inWindow = (from: number, to: number) => seen.filter(b => b.producedAtMs > from && b.producedAtMs <= to);
  const report = {
    where: 'main-thread',
    intervalMs,
    busyMs,
    warmMs,
    spun: spin.spun,
    busyActualMs: spin.actualMs,
    warmOpenAtMs: warmOpen,
    warmCloseAtMs: warmClose,
    busyOpenAtMs: busyOpen,
    busyCloseAtMs: busyClose,
    warmWindowMs: warmClose - warmOpen,
    busyWindowMs: busyClose - busyOpen,
    lastBlockAtMs: seen.length === 0 ? null : seen[seen.length - 1]!.producedAtMs,
    warmBlocks: inWindow(warmOpen, warmClose).length,
    busyBlocks: inWindow(busyOpen, busyClose).length,
    totalBlocks: seen.length,
    blocks: seen,
  };
  say(`[main thread] warm ${report.warmBlocks} block(s), busy ${report.busyBlocks} block(s)`);
  await opened.close();
  return plain(report) as Record<string, unknown>;
}

// ---------------------------------------------------------------------------------------------
// ARM: blocks on a real timer IN THE WORKER, across whatever the harness does to this tab.
//
// The harness freezes the page and throttles the CPU. Whether either reaches the WORKER is not
// assumed: `producedAtMs` is the worker's own monotonic clock, so a gap in it is the worker saying
// its own timers stopped, and the check requires that gap rather than inferring it from what the
// harness asked for.
// ---------------------------------------------------------------------------------------------
async function startTicking(intervalMs: number): Promise<Record<string, unknown>> {
  const c = await boot({ intervalMs, minBlockSpacingSeconds: 1 });
  await c.start();
  return { intervalMs, started: true, visibility: document.visibilityState };
}

async function stopTicking(): Promise<Record<string, unknown>> {
  const c = await boot();
  await c.stop();
  const blocks = await c.blocks();
  return plain({
    blocks,
    visibility: document.visibilityState,
    events: events.filter(e => e.kind === 'block').length,
  }) as Record<string, unknown>;
}

// ---------------------------------------------------------------------------------------------
// ARM: the container as a TRANSFERABLE, and the copy beside it as the control.
//
// The sequence is one buffer and three readings of it, in this order, because that is what makes
// the pair a measurement rather than two claims:
//
//   1. before any take        present, byteLength N, detached false
//   2. after a COPY           present, byteLength N, detached false   <- a clone does not detach
//   3. after a TRANSFER       present, byteLength 0, detached TRUE    <- ownership moved
//   4. a second TRANSFER      refused by name, because the bytes are gone
//
// Every reading is taken by the WORKER of its own memory and crosses on the schema channel. The
// page reports the byte counts it received in both cases, so "the page got the same bytes either
// way" is measured too — a transfer that lost data would be a faster wrong answer.
// ---------------------------------------------------------------------------------------------
async function armTransferable(): Promise<Record<string, unknown>> {
  const c = await boot({ intervalMs: 0, minBlockSpacingSeconds: 1 });
  const transfer = await c.runTokenTransfer(ARTIFACT_URL);
  const meta = await c.recordContainer({
    writerUrl: CT_WRITER_URL,
    artifactUrl: ARTIFACT_URL,
    recordingId: RECORDING_ID,
  });
  const before = await c.containerBufferState();
  const copied = await c.takeContainer(false);
  const afterCopy = await c.containerBufferState();
  const moved = await c.takeContainer(true);
  const afterTransfer = await c.containerBufferState();

  let secondTransfer: string | null = null;
  try {
    await c.takeContainer(true);
    secondTransfer = 'ACCEPTED';
  } catch (e) {
    secondTransfer = String((e as Error).message ?? e);
  }

  // THE PAGE'S HALF OF THE PRODUCT CLAIM. The worker cannot do this — it has no `document` — and
  // that asymmetry is the whole reason the container had to cross.
  offerDownload(moved.container, `aztec-avm-worker-${RECORDING_ID}.ct`);

  const digest = async (bytes: Uint8Array) =>
    Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as BufferSource)))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

  const report = {
    meta,
    transfer,
    before,
    afterCopy,
    afterTransfer,
    secondTransfer,
    copiedBytes: copied.bytes,
    copiedLength: copied.container.byteLength,
    copiedSha256: await digest(copied.container),
    movedBytes: moved.bytes,
    movedLength: moved.container.byteLength,
    movedSha256: await digest(moved.container),
    copyElapsedMs: copied.elapsedMs,
    transferElapsedMs: moved.elapsedMs,
    callsMade: [...c.calls],
  };
  say(`[transferable] ${report.movedBytes} bytes; after transfer the worker's buffer is ${jsonStringify(report.afterTransfer)}`);
  return plain(report) as Record<string, unknown>;
}

// ---------------------------------------------------------------------------------------------
// ARM: terminate mid-chain, restart from a snapshot, resume — AND the case that does NOT round-trip.
//
// ===========================================================================================
// FOUR WORKERS, AND THE SECOND PAIR IS WHAT MAKES THE FIRST PAIR A MEASUREMENT
// ===========================================================================================
//
// A snapshot here is M23's REPLAY LOG, not a state dump: it records what the runtime DID through
// its facade — the fee-juice funding, the transactions in their blocks, the L1-to-L2 messages at
// their boundaries — and a fresh runtime re-derives the state by replaying them. `CHAIN-LOOP.md` §5
// states the cost of that choice; this arm measures it.
//
//   path A   funding, an L1-to-L2 message and three blocks, all through the facade. Everything the
//            state depends on is IN the log, so the replay must reach the SAME archive root, the
//            same four-tree state reference and the same block number. Then one more block, to show
//            the restarted chain is a chain and not a reconstruction that cannot move.
//
//   path B   the same, plus a token transfer. `runTokenTransfer` registers a contract class and an
//            instance in the MODULE's contract DB, and seeds a deployment nullifier, an
//            initialisation nullifier and a token balance DIRECTLY into the trees — none of which is
//            a facade call, so none of it is in the replay log. The replay therefore reaches a
//            DIFFERENT root, and this arm records that rather than avoiding it.
//
// Path B is a limitation and it is also the control: without it, "the archive roots are equal" is a
// comparison that has never been seen to come out unequal. With it, the same comparison over the
// same code answers both ways in one run.
// ---------------------------------------------------------------------------------------------

/** A 32-byte field as hex. The protocol's schemas parse these into `Fr`/`AztecAddress` themselves. */
const FEE_PAYER = '0x0000000000000000000000000000000000000000000000000000000000003201';
const FUNDING = '0x000000000000000000000000000000000000000000000000000000e8d4a51000';
const L1_TO_L2_LEAF = '0x0000000000000000000000000000000000000000000000000000000000000309';

async function seedFacadeOnlyChain(c: WorkerNodeClient, blocks: number): Promise<void> {
  await c.fundFeeJuice(FEE_PAYER, FUNDING);
  await c.injectL1ToL2Message(L1_TO_L2_LEAF);
  await c.advanceBlocksBy(blocks);
}

async function restartWorker(): Promise<WorkerNodeClient> {
  client = null;
  events.length = 0;
  return boot({ intervalMs: 0, minBlockSpacingSeconds: 1 });
}

async function armRestart(options: { blocks?: number } = {}): Promise<Record<string, unknown>> {
  const want = options.blocks ?? 3;

  // -- path A: a chain whose whole history went through the facade ----------------------------
  const first = await boot({ intervalMs: 0, minBlockSpacingSeconds: 1 });
  await seedFacadeOnlyChain(first, want);
  const before = (await first.state()) as Record<string, unknown>;
  const snapshot = await first.exportSnapshot();

  // TERMINATE. Not `close()` — the milestone's word is "terminate", and the difference matters: a
  // close is the runtime shutting down in an orderly way; a terminate is the thread being killed
  // under it with no chance to flush anything, which is what a page does when a user hits reset.
  first.terminate();
  let afterTerminationError: string;
  try {
    await first.state();
    afterTerminationError = 'ACCEPTED';
  } catch (e) {
    afterTerminationError = String((e as Error).message ?? e);
  }

  const second = await restartWorker();
  const freshBefore = (await second.state()) as Record<string, unknown>;
  const after = (await second.importSnapshot(snapshot)) as Record<string, unknown>;
  // …AND IT IS STILL A CHAIN. A replay that reached the right root and could not then produce a
  // block would be a reconstruction rather than a resumption.
  const resumed = (await second.produceBlock()) as Record<string, unknown> | null;
  const afterResume = (await second.state()) as Record<string, unknown>;
  second.terminate();

  // -- path B: the same, with state seeded behind the facade -----------------------------------
  const third = await restartWorker();
  await seedFacadeOnlyChain(third, 1);
  const tokenTransfer = await third.runTokenTransfer(ARTIFACT_URL);
  await third.advanceBlocksBy(1);
  const unreplayableBefore = (await third.state()) as Record<string, unknown>;
  const unreplayableSnapshot = await third.exportSnapshot();
  third.terminate();

  const fourth = await restartWorker();
  let unreplayableAfter: Record<string, unknown> | null = null;
  // 'none' rather than `null`, because a JSON null and an absent key are the same reading to a check
  // that walks a dotted path — which is `CAMPAIGN-BRIEF.md`'s "two missing keys agreeing" waiting to
  // happen. A word that can only be there if this line ran says more than an absence.
  let unreplayableError = 'none';
  try {
    unreplayableAfter = (await fourth.importSnapshot(unreplayableSnapshot)) as Record<string, unknown>;
  } catch (e) {
    unreplayableError = String((e as Error).message ?? e);
  }
  fourth.terminate();
  client = null;

  say(`[restart] resumed at block ${String(afterResume.blockNumber)}`);
  return plain({
    want,
    snapshot,
    before,
    freshBefore,
    after,
    resumed,
    afterResume,
    afterTerminationError,
    // The identity the milestone names, as a pair the check reads side by side.
    archiveBefore: before.archive,
    archiveAfter: after.archive,
    stateReferenceBefore: before.stateReferenceHex,
    stateReferenceAfter: after.stateReferenceHex,
    blockNumberBefore: before.blockNumber,
    blockNumberAfter: after.blockNumber,
    // THE CONTROL. The same comparison, over a chain whose state was not all put there through the
    // facade, must come out UNEQUAL.
    unreplayable: {
      tokenTransfer,
      before: unreplayableBefore,
      after: unreplayableAfter,
      error: unreplayableError,
      archiveBefore: unreplayableBefore.archive,
      archiveAfter: unreplayableAfter === null ? null : unreplayableAfter.archive,
      stateReferenceBefore: unreplayableBefore.stateReferenceHex,
      stateReferenceAfter: unreplayableAfter === null ? null : unreplayableAfter.stateReferenceHex,
      blockNumberBefore: unreplayableBefore.blockNumber,
      blockNumberAfter: unreplayableAfter === null ? null : unreplayableAfter.blockNumber,
      reason:
        'runTokenTransfer registers a contract class and instance in the module contract DB and '
        + 'seeds a deployment nullifier, an initialisation nullifier and a token balance directly '
        + 'into the trees. None of those is a facade call, so none of them is in the replay log '
        + 'ChainSnapshot records — see CHAIN-LOOP.md section 5.',
    },
  }) as Record<string, unknown>;
}

const api = {
  armWorkerBoot,
  armWorkerUnderMainThreadBlock,
  armMainThreadControl,
  armTransferable,
  armRestart,
  startTicking,
  stopTicking,
  status: () => ({
    booted: client !== null,
    log: [...log],
    events: events.length,
    calls: client ? [...client.calls] : [],
    visibility: document.visibilityState,
  }),
};

declare global {
  // eslint-disable-next-line no-var
  var avmWorkerDemo: typeof api;
  // eslint-disable-next-line no-var
  var avmWorkerDemoReady: boolean;
}

globalThis.avmWorkerDemo = api;
globalThis.avmWorkerDemoReady = true;
say('worker demo ready');

for (const [id, fn] of Object.entries({
  'btn-boot': armWorkerBoot,
  'btn-block': () => armWorkerUnderMainThreadBlock(),
  'btn-control': () => armMainThreadControl(),
  'btn-transferable': armTransferable,
  'btn-restart': () => armRestart(),
})) {
  document.getElementById(id)?.addEventListener('click', () => {
    (fn as () => Promise<unknown>)().catch((e: unknown) => say(`ERROR ${String(e)}`));
  });
}
