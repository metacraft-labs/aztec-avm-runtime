// `aztec-avm-runtime/worker` — the dev node, hosted in a Web Worker.
//
// ===========================================================================================
// WHY THIS IS SHORT, AND WHAT THAT SAYS ABOUT THE MILESTONES UNDER IT
// ===========================================================================================
//
// DD-4 forbids ambient clocks and timers — no `Date.now()`, no `setInterval()`; the clock is an
// argument all the way down and `test_no_ambient_clock_or_timer` asserts it structurally over the
// shipped sources. DD-9 forbids the native addon, so there is no `@aztec/world-state` and no
// `@aztec/native` in the graph. And nothing in `orchestration/src`, `node-host/src` or `ct-host/src`
// touches the DOM: the ONLY `document.` in the whole browser package is `offerDownload`'s four lines
// in `ct_download.ts`, which is a page's way of handing a file to a user and not a capability of the
// runtime.
//
// A Worker has no `document` and its timers are throttled on a schedule of their own. Those two
// facts are exactly what the two decisions above already accounted for, which is why this file
// composes rather than adapts: `openAvmRuntime` runs here unchanged, `AvmChain` ticks here on
// upstream's own `RunningPromise` unchanged, and the one thing that could not cross — the download
// — stays on the page, with the container reaching it as a TRANSFERABLE.
//
// ===========================================================================================
// THE TRANSPORT IS COMLINK, AND IT IS UPSTREAM'S OWN BROWSER-WORKER MECHANISM
// ===========================================================================================
//
// `barretenberg/ts/bb.js/src/barretenberg_wasm/barretenberg_wasm_main/factory/browser/` is
// upstream's browser worker: `main.worker.ts` is `expose(new BarretenbergWasmMain()); postMessage(Ready)`
// and `helpers/browser/index.ts` is `wrap<T>(worker)` plus a `readinessListener`. `comlink` is a
// runtime `dependencies` entry of `@aztec/bb.js`, one of the four packages
// `orchestration/package.json` depends on, so it is already in this tree. (This comment said "of
// BOTH `@aztec/bb.js` and `@aztec/foundation`". `@aztec/foundation` lists comlink under
// `devDependencies`, which a consumer does not install; corrected by M32's review.)
//
// `@aztec/foundation/transport` — `TransportClient`, `TransportServer`, `Socket`, `Transfer` — is
// the richer prior art and its own `Socket` docstring says "implementations could use e.g.
// MessagePorts for communication between browser workers". **It is rejected, cannot-reach-target,
// and the reason is a measurement rather than an opinion.** Only the NODE sockets exist
// (`node/node_connector.ts`, `node/node_listener.ts`, over `worker_threads`); the package exposes
// `./transport` as a barrel and has no wildcard subpath, so the browser-safe half cannot be imported
// on its own; and built for the browser with this build's four existing shims applied, it leaves
// **four unresolved Node builtins — `events` three times and `worker_threads` once**. Reaching it
// would mean adding an `events` shim and neutralising a node-only submodule inside the artefact
// whose entire CI gate (M28) is "no Node builtins", to obtain 787 lines of which we would use two.
//
// What IS reused from it is the part that is not code: its `ApiSchema` protocol discipline, which
// upstream's own worker-hosted wallet drives — see `worker_protocol.ts`.
//
// ===========================================================================================
// THE EXPOSED SURFACE IS THREE METHODS, AND TWO OF THEM ARE DECLARED EXCEPTIONS
// ===========================================================================================
//
//   call(fn, argsJson)          the schema channel. `wallet_worker_script.ts`'s handler, exactly:
//                               `schemaHasMethod` -> `JSON.parse` -> `parseWithOptionals` over
//                               `getSchemaParameters` -> dispatch -> `jsonStringify`.
//   subscribe(kind, proxyCb)    `block` / `tx` / `trace`, each event `jsonStringify`d.
//   takeContainer(transfer)     the `.ct` bytes. With `transfer` the buffer is TRANSFERRED and the
//                               worker's own copy is detached; without it, structured-cloned. The
//                               difference is measured by `containerBufferState` on this side.
//
// `WORKER_OFF_SCHEMA_OPS` declares the second and third by name with their reasons, so a fourth
// cannot appear without the declaration failing.

import * as Comlink from 'comlink';

import { jsonStringify } from '@aztec/foundation/json-rpc';
import { getSchemaParameters, parseWithOptionals, schemaHasMethod } from '@aztec/foundation/schemas';
import type { ApiSchema } from '@aztec/foundation/schemas';
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { Fr } from '@aztec/foundation/curves/bn254';
import { Tx } from '@aztec/stdlib/tx';

import { openAvmRuntime, type OpenedRuntime } from './runtime.ts';
// DateProvider comes through the orchestration barrel, which is where `entry_browser.ts` gets it:
// two import paths to one class is two module instances waiting to happen.
import { DateProvider, locallyOriginatedTx } from '../../orchestration/src/index.ts';
import type { ChainBlock, TraceEvent, TxEvent } from '../../orchestration/src/index.ts';
import { fetchCtWriter, recordAndDownload } from './ct_download.ts';
import { runTokenTransfer, type TokenTransferReport } from './token_transfer.ts';
import {
  AvmWorkerNodeSchema,
  WORKER_OFF_SCHEMA_OPS,
  WORKER_PROTOCOL,
  WORKER_PROTOCOL_BACKING,
  WORKER_SUBSCRIPTIONS,
  WORKER_TESTING_OPS,
} from './worker_protocol.ts';

// The protocol declarations are RE-EXPORTED from the built worker bundle so that a check can read
// them out of the ARTEFACT rather than out of this source — M27's rule for `NODE_CONVENIENCES`,
// which exists because a comment cannot be compared with a bundle.
export {
  AvmWorkerNodeSchema,
  WORKER_OFF_SCHEMA_OPS,
  WORKER_PROTOCOL,
  WORKER_PROTOCOL_BACKING,
  WORKER_SUBSCRIPTIONS,
  WORKER_TESTING_OPS,
};

/** The readiness message. bb.js's `Ready` constant, same shape, same reason. */
export const WORKER_READY = { ready: true } as const;

/** Thrown when an operation needs an open runtime and there is none. A refusal, never a default. */
export class WorkerNodeNotOpen extends Error {
  constructor(fn: string) {
    super(`the worker node has no open runtime; '${fn}' was called before 'open'`);
    this.name = 'WorkerNodeNotOpen';
  }
}

/** Thrown when the container is asked for after it has already been transferred away. */
export class ContainerAlreadyTransferred extends Error {
  constructor() {
    super(
      'the recorded container was already transferred to the page and this worker\'s buffer is '
        + 'detached. A transfer moves ownership; a second take would have to invent bytes.',
    );
    this.name = 'ContainerAlreadyTransferred';
  }
}

// ---------------------------------------------------------------------------------------------
// The node's state. One runtime at a time, which is what "a long-lived dev node" means.
// ---------------------------------------------------------------------------------------------

interface WorkerState {
  opened: OpenedRuntime | null;
  /** Every block this worker's chain sealed, with the worker's own clock reading beside it. */
  blocks: BlockRow[];
  container: Uint8Array | null;
  containerBuffer: ArrayBuffer | null;
  takes: number;
  transfers: number;
  artifact: unknown;
  tokenTransfer: { report: TokenTransferReport } | null;
  unsubscribes: (() => void)[];
}

interface BlockRow {
  number: number;
  timestamp: bigint;
  wallClockSeconds: bigint;
  wallClockDeviationSeconds: bigint;
  empty: boolean;
  txHashes: string[];
  failedTxHashes: string[];
  l1ToL2Messages: string[];
  archiveAfter: { root: string; nextAvailableLeafIndex: number };
  producedAtMs: number;
}

const state: WorkerState = {
  opened: null,
  blocks: [],
  container: null,
  containerBuffer: null,
  takes: 0,
  transfers: 0,
  artifact: null,
  tokenTransfer: null,
  unsubscribes: [],
};

function requireOpen(fn: string): OpenedRuntime {
  if (state.opened === null) throw new WorkerNodeNotOpen(fn);
  return state.opened;
}

function blockRow(b: ChainBlock): BlockRow {
  return {
    number: b.number,
    timestamp: b.timestamp,
    wallClockSeconds: b.wallClockSeconds,
    wallClockDeviationSeconds: b.wallClockDeviationSeconds,
    empty: b.empty,
    txHashes: [...b.txHashes],
    failedTxHashes: [...b.failedTxHashes],
    l1ToL2Messages: [...b.l1ToL2Messages],
    archiveAfter: {
      root: b.archiveAfter.root.toString(),
      nextAvailableLeafIndex: Number(b.archiveAfter.nextAvailableLeafIndex),
    },
    // `performance.now()` and not a wall clock: this is a DURATION instrument, on the worker's own
    // monotonic clock, and DD-4's rule is about the clock the CHAIN reads. The chain's is injected
    // and is `DateProvider`, three lines below in `open`.
    producedAtMs: performance.now(),
  };
}

async function nodeState(): Promise<Record<string, unknown>> {
  const o = state.opened;
  if (o === null) {
    // A closed node still answers, because "is it open" is a question the page is entitled to ask
    // before it has opened one. Everything else is zero and `opened` says so.
    return {
      opened: false,
      blockNumber: 0,
      nextBlockNumber: 1,
      lastBlockTimestamp: 0n,
      nextBlockTimestamp: 0n,
      blocks: 0,
      archive: { root: '0x00', nextAvailableLeafIndex: 0 },
      stateReferenceHex: '',
      running: false,
      ticks: 0,
      atMs: performance.now(),
      disclosure: {
        simulated: true as const,
        protocolVersion: '',
        proving: 'none' as const,
        line: '',
      },
    };
  }
  const archive = o.runtime.archive();
  const ref = await o.runtime.stateReference();
  return {
    opened: true,
    blockNumber: o.runtime.blockNumber,
    nextBlockNumber: o.runtime.nextBlockNumber,
    lastBlockTimestamp: o.runtime.lastBlockTimestamp,
    nextBlockTimestamp: o.runtime.nextBlockTimestamp,
    blocks: o.runtime.blocks.length,
    archive: {
      root: archive.root.toString(),
      nextAvailableLeafIndex: Number(archive.nextAvailableLeafIndex),
    },
    stateReferenceHex: Buffer.from(ref.toBuffer()).toString('hex'),
    running: o.chain.ticker.running,
    ticks: o.chain.ticker.ticks,
    // TAKEN LAST, so it is the moment the answer was ready rather than the moment it was begun.
    atMs: performance.now(),
    disclosure: {
      simulated: true as const,
      protocolVersion: o.runtime.disclosure.protocolVersion,
      proving: 'none' as const,
      line: o.runtime.disclosure.line,
    },
  };
}

function receiptOf(r: {
  txHash: string;
  outcome: { kind: string; blockNumber?: number; error?: string };
  blockNumber: number | null;
  protocolVersion: string;
}): Record<string, unknown> {
  return {
    txHash: r.txHash,
    outcome: r.outcome,
    blockNumber: r.blockNumber,
    simulated: true as const,
    protocolVersion: r.protocolVersion,
    proving: 'none' as const,
  };
}

// ---------------------------------------------------------------------------------------------
// The operations. One function per protocol entry; the dispatcher below is upstream's.
// ---------------------------------------------------------------------------------------------

const operations: Record<string, (...args: never[]) => Promise<unknown>> = {
  async open(request: {
    moduleUrl: string;
    intervalMs?: number;
    minBlockSpacingSeconds?: number;
    produceEmptyBlocks?: boolean;
    automine?: boolean;
    collectExecutionSteps?: boolean;
  }) {
    if (state.opened !== null) {
      throw new Error('the worker node is already open; terminate the worker to start a new one');
    }
    const production: Record<string, unknown> = {};
    if (request.intervalMs !== undefined) production.intervalMs = request.intervalMs;
    if (request.minBlockSpacingSeconds !== undefined) {
      production.minBlockSpacingSeconds = request.minBlockSpacingSeconds;
    }
    if (request.produceEmptyBlocks !== undefined) production.produceEmptyBlocks = request.produceEmptyBlocks;
    if (request.automine !== undefined) production.automine = request.automine;
    state.opened = await openAvmRuntime({
      moduleUrl: request.moduleUrl,
      // DD-4. Upstream's `DateProvider`, injected — the same object the page would inject, and the
      // reason a worker's different throttling schedule is not a different code path.
      clock: new DateProvider(),
      collectExecutionSteps: request.collectExecutionSteps === true,
      production: production as never,
      // A worker has no console the page can see. The disclosure crosses on `state()` instead, and
      // §8.4's record is on the runtime either way — `AvmRuntime`'s constructor makes it.
      disclosureSink: () => {},
      writeLine: () => {},
    });
    state.opened.runtime.subscribe('block', (b: ChainBlock) => {
      state.blocks.push(blockRow(b));
    });
    return nodeState();
  },

  async close() {
    const o = state.opened;
    if (o !== null) {
      for (const off of state.unsubscribes) off();
      state.unsubscribes = [];
      await o.close();
      state.opened = null;
    }
  },

  async start() {
    requireOpen('start').runtime.start();
  },

  async stop() {
    await requireOpen('stop').runtime.stop();
  },

  async submitExternal(tx: Tx) {
    const o = requireOpen('submitExternal');
    return receiptOf(await o.runtime.submitExternal(tx) as never);
  },

  async submitLocal(tx: Tx) {
    const o = requireOpen('submitLocal');
    // FORM B'S OWN CONSTRUCTOR, not a provenance string the page chose. `locallyOriginatedTx` is
    // what makes the receipt's provenance `local`, and DD-1's seal is on the object it builds.
    return receiptOf(await o.runtime.submitLocal(locallyOriginatedTx(tx)) as never);
  },

  async registerContract(contractClass: unknown, instance: unknown) {
    const o = requireOpen('registerContract');
    return o.runtime.registerContract(contractClass as never, instance as never);
  },

  async fundFeeJuice(feePayer: AztecAddress, amount: Fr) {
    const o = requireOpen('fundFeeJuice');
    return o.runtime.fundFeeJuice(feePayer, amount);
  },

  async injectL1ToL2Message(leaf: Fr) {
    requireOpen('injectL1ToL2Message').runtime.injectL1ToL2Message(leaf);
  },

  async state() {
    return nodeState();
  },

  async blocks() {
    return state.blocks;
  },

  async receiptFor(txHash: string) {
    return receiptOf(requireOpen('receiptFor').runtime.receiptFor(txHash) as never);
  },

  async produceBlock() {
    const block = await requireOpen('produceBlock').runtime.produceBlock();
    return block === null ? null : blockRow(block);
  },

  async advanceBlocksBy(n: number) {
    const blocks = await requireOpen('advanceBlocksBy').runtime.advanceBlocksBy(n);
    return blocks.map(blockRow);
  },

  async exportSnapshot() {
    return requireOpen('exportSnapshot').runtime.exportSnapshot();
  },

  async importSnapshot(snapshot: unknown) {
    const o = requireOpen('importSnapshot');
    // UPSTREAM'S OWN DECODERS, handed in as the facade asks for them. `importSnapshot` takes them as
    // arguments precisely so that the replay does not have to import a codec of its own.
    await o.runtime.importSnapshot(
      snapshot as never,
      async (bytes: Buffer) => Tx.fromBuffer(bytes),
      async (s: string) => AztecAddress.fromString(s),
      (s: string) => Fr.fromString(s),
    );
    return nodeState();
  },

  async recordContainer(request: { writerUrl: string; artifactUrl: string; recordingId: string }) {
    const o = requireOpen('recordContainer');
    const writerBytes = await fetchCtWriter(request.writerUrl);
    const raw = await loadArtifact(request.artifactUrl);
    const report = state.tokenTransfer?.report;
    if (report === undefined) {
      throw new Error('recordContainer needs a transaction to record; call runTokenTransfer first');
    }
    const addressHex = report.contractAddress.replace(/^0x/, '').padStart(64, '0');
    const address = new Uint8Array(32);
    for (let i = 0; i < 32; i++) address[i] = parseInt(addressHex.slice(i * 2, i * 2 + 2), 16);
    const recording = await recordAndDownload({
      writerBytes,
      rawArtifact: raw,
      contractAddress: address,
      frameNames: report.debugFunctionNames,
      recordingId: request.recordingId,
      executed: o.steps.last,
      // THE DOWNLOAD IS THE PAGE'S. A worker has no `document`; `offerDownload` is four lines of DOM
      // and is the ONE thing in this package that cannot cross. That is DD-5 pointing the other way
      // for once: the CAPABILITY is the container, and handing it to a user is the page's job.
      download: false,
    });
    state.container = recording.container;
    state.containerBuffer = recording.container.buffer as ArrayBuffer;
    state.takes = 0;
    state.transfers = 0;
    const { container: _bytes, rungReason: _r, declaredRungReason: _d, stepCrossings: _c, stepBatchRecords: _b,
      logEvents: _l, ...meta } = recording;
    return meta;
  },

  async containerBufferState() {
    const buffer = state.containerBuffer;
    // ===========================================================================================
    // ONE READER FOR BOTH, AND THAT IS THE WHOLE POINT OF THE CONTROL.
    // ===========================================================================================
    //
    // `detached` is `ArrayBuffer.prototype.detached` — the platform's own answer, not an inference
    // from a zero length. That sentence is in this file, in `WORKER-NODE.md` §4 and in the check,
    // and it was FALSE for one line: this function read `buffer.byteLength === 0` while the
    // zero-length control beside it read `empty.detached`. Nothing could see the difference,
    // because the only zero-length buffer the container path ever produces IS the transferred one —
    // so the inference agreed with the platform at every point the check looks, and the arm written
    // to catch it (`m32-mutations.sh` M2) could not apply its own first substitution and was
    // recorded as having behaved. Found by M32's review.
    //
    // The remedy is not a corrected line: it is that the container's reading and the control's
    // reading now go through the SAME expression, so the control controls the mechanism the
    // container is measured with rather than a second copy of it. One edit to `read` moves both,
    // and `{byteLength: 0, detached: false}` is the combination an inference cannot produce.
    const read = (b: ArrayBuffer) => ({ byteLength: b.byteLength, detached: b.detached === true });
    const own = buffer === null ? { byteLength: 0, detached: false } : read(buffer);
    return {
      present: buffer !== null,
      byteLength: own.byteLength,
      detached: own.detached,
      takes: state.takes,
      transfers: state.transfers,
      // See `BufferStateSchema.zeroLengthControl`. Allocated here rather than kept on `state`, so it
      // cannot have been transferred by anything, and read by `read` so it is the same instrument.
      zeroLengthControl: read(new ArrayBuffer(0)),
    };
  },

  async runTokenTransfer(artifactUrl: string) {
    const o = requireOpen('runTokenTransfer');
    const raw = await loadArtifact(artifactUrl);
    const report = await runTokenTransfer(o, raw);
    state.tokenTransfer = { report };
    const executed = o.steps.last;
    return {
      artifactName: report.artifactName,
      contractAddress: report.contractAddress,
      outcome: report.outcome,
      blockNumber: report.blockNumber,
      revertCode: report.revertCode ?? null,
      debugFunctionNames: report.debugFunctionNames,
      executedSteps: executed === null ? null : executed.steps.length,
      instructionsExecuted: executed === null ? null : executed.instructionsExecuted,
    };
  },
};

async function loadArtifact(url: string): Promise<unknown> {
  if (state.artifact !== null) return state.artifact;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${response.status} ${response.statusText}`);
  state.artifact = await response.json();
  return state.artifact;
}

// ---------------------------------------------------------------------------------------------
// THE DISPATCHER — `wallet_worker_script.ts`'s handler, over this protocol.
// ---------------------------------------------------------------------------------------------

const schema = AvmWorkerNodeSchema as ApiSchema;

export async function dispatch(fn: string, argsJson: string): Promise<string | undefined> {
  if (!schemaHasMethod(schema, fn)) {
    throw new Error(`unknown worker-node operation: ${fn}`);
  }
  const handler = operations[fn];
  if (handler === undefined) {
    // A NAME ON THE PROTOCOL WITH NO IMPLEMENTATION IS A FAILURE AND NOT A SMALLER PROTOCOL. The
    // schema and the operation table are two lists, and two lists drift; this is where the drift
    // becomes a message instead of `undefined is not a function`.
    throw new Error(`the protocol declares '${fn}' and this worker implements no handler for it`);
  }
  const parsed = JSON.parse(argsJson) as unknown[];
  const args = (await parseWithOptionals(parsed, getSchemaParameters(schema[fn]!))) as never[];
  const result = await handler(...args);
  return result === undefined ? undefined : jsonStringify(result);
}

// ---------------------------------------------------------------------------------------------
// The two off-schema operations.
// ---------------------------------------------------------------------------------------------

export function subscribeTo(kind: string, callback: (payload: string) => void): void {
  const o = requireOpen('subscribe');
  if (!WORKER_SUBSCRIPTIONS.includes(kind)) {
    throw new Error(`unknown subscription '${kind}'; this node offers ${WORKER_SUBSCRIPTIONS.join(', ')}`);
  }
  const off = (o.runtime.subscribe as (k: string, f: (e: unknown) => void) => () => void)(kind, event => {
    callback(jsonStringify(kind === 'block' ? blockRow(event as ChainBlock) : (event as TxEvent | TraceEvent)));
  });
  state.unsubscribes.push(off);
}

/**
 * Hand the recorded container to the page.
 *
 * `transfer: true` moves the buffer's ownership — after this returns, THIS side's `ArrayBuffer` is
 * detached, which `containerBufferState` reports and `test_worker_transferable_container_not_copied`
 * measures. `transfer: false` structured-clones it, which is the control: the same call, the same
 * bytes, the same page-side result, and a source buffer that is still here afterwards.
 */
export function takeContainerBytes(transfer: boolean): unknown {
  const bytes = state.container;
  const buffer = state.containerBuffer;
  if (bytes === null || buffer === null) throw new Error('no container has been recorded');
  if (buffer.detached === true) throw new ContainerAlreadyTransferred();
  state.takes += 1;
  // THE VIEW'S OFFSET TRAVELS WITH THE BUFFER. `recording.container` is a `Uint8Array` and nothing
  // promises it spans its own `ArrayBuffer`; copying it into one that does would be a copy taken to
  // make a no-copy measurement look tidy, which is the wrong way round.
  const payload = { bytes: bytes.byteLength, byteOffset: bytes.byteOffset, buffer };
  if (!transfer) return payload;
  state.transfers += 1;
  return Comlink.transfer(payload, [buffer]);
}

/** The exposed surface. Three methods; `WORKER_OFF_SCHEMA_OPS` declares two of them. */
export const workerNode = {
  call: dispatch,
  subscribe: subscribeTo,
  takeContainer: takeContainerBytes,
};

/**
 * Expose, and announce readiness — bb.js's `expose(...); postMessage(Ready)` exactly.
 *
 * GUARDED, so this module can be IMPORTED by a check running in Node to read the protocol
 * declarations out of the built artefact. `DedicatedWorkerGlobalScope` exists only inside a worker,
 * so the guard is the platform's own answer to "am I a worker" rather than a build-time flag that
 * could be wrong.
 */
export function isWorkerScope(): boolean {
  return (
    typeof DedicatedWorkerGlobalScope !== 'undefined'
    && typeof self !== 'undefined'
    && self instanceof DedicatedWorkerGlobalScope
  );
}

if (isWorkerScope()) {
  Comlink.expose(workerNode);
  (self as unknown as { postMessage: (m: unknown) => void }).postMessage(WORKER_READY);
}
