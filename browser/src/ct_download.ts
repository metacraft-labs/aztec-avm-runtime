// The product claim: a `.ct` container, produced in the page, offered for download.
//
// ===========================================================================================
// THIS IS THE FILE `e2e_browser_downloads_ct_container_and_ct_print_parses` IS ABOUT.
// ===========================================================================================
//
// The milestone calls that check "the only test that proves the actual product claim". What it
// proves is a chain of five things, and every link had to already exist:
//
//   1. `ct_writer.wasm` declares ZERO wasm imports (M24, `verify_ct_writer_wasm_zero_imports`), so
//      `WebAssembly.instantiate(bytes, {})` is the whole instantiation — in Node and in a page.
//   2. `ct-host` has NO dependencies and imports no Node builtin, which `ct-host/package.json`
//      records as the reason DD-7 chose a raw C ABI over wasm-bindgen: "the same host code runs in
//      Node and in a browser, which is what M27 needs".
//   3. `ContractSourceMap` (M25) turns the artifact's own byte-offset-keyed `brillig_locations`
//      into source positions, so the container is rung-1 rather than program-counter-shaped.
//   4. The reference reader (`ct-print`) reads what this writer produces — established by the
//      writer-parity work and the anchor move, on both native and wasm.
//   5. **M29: the steps are the ones the AVM EXECUTED.** M9's `ExecutionObserverInterface`, inside
//      `avm.wasm`, drained through M12's `avm_steps_batch(from, count)` by
//      `ExecutedStepCollector`, and ingested through M24's `ct_ingest(ptr, len)`.
//
// So this file adds no format and no writer. What it adds is one browser API — `Blob` + an object
// URL — and one browser-shaped decompression.
//
// ===========================================================================================
// `debug_symbols` IS RAW-DEFLATE, AND A BROWSER DECOMPRESSES IT DIFFERENTLY.
// ===========================================================================================
//
// `tools/run_join_arms.mjs` uses `inflateRawSync` from `node:zlib`. A page uses
// `DecompressionStream('deflate-raw')`, which is a platform API rather than a polyfill and is the
// reason this needs no `pako`. It is async where Node's is sync, which is why `recordAndDownload`
// is async and the Node driver's equivalent is not.
//
// ===========================================================================================
// WHAT THE STEPS ARE. THIS PARAGRAPH USED TO BE A DISCLOSURE AND IS NOW A DESCRIPTION.
// ===========================================================================================
//
// Until M29 the program counters here were the artifact's OWN FIRST N MAPPED pcs — a walk of the
// debug map, not of the execution — with `opcode: (pc % 200) + 1` and gas linear in the index.
// M27 disclosed that rather than letting it pass. **That path is DELETED, and it is not kept as a
// fallback**: a producer that quietly substitutes fabricated data when the real stream is missing
// is worse than one that refuses, and this campaign has the scars. `recordAndDownload` throws
// `ExecutedStepsUnavailable` when there is no executed stream, naming the option that would have
// produced one.
//
// The one thing a caller must do, therefore, is open the runtime with `collectExecutionSteps: true`.
//
// ===========================================================================================
// THE RUNG IS DECLARED FROM THE EXECUTION, NOT FROM THE ARTIFACT, AND THAT IS A REAL CHANGE.
// ===========================================================================================
//
// While the steps WERE the mapped pcs, every step had a position by construction and declaring the
// contract at the artifact's rung was safe. Under real execution it is not: `SOURCE-MAPPING.md`
// §2.4 records, as residual hole 2, that **compiled procedures are appended after the main body**
// (`transpile.rs:489`, `:505`) and have no `brillig_locations` entry at all, so an executed stream
// walks through regions the map does not key. `ContractSourceMap.positionFor` answers `null` there
// and deliberately does not round to the nearest lower line.
//
// M25's ladder then does exactly what it was built to do: a contract declared at rung 1 that
// produces an unpositioned step is a `rungViolation`, and `CtWriter.close()` throws
// `MappingRungDegraded`. So the declaration is MEASURED over the executed stream first — rung 1
// when every step of that contract resolved, rung 2 otherwise — and the reason carries the split.
// "Never rounded up" is M25's rule and this is the first place it has ever had to bite.
//
// The SESSION's rung stays `RUNG_SOURCE` and columns stay on, and those are different questions:
// the session rung is what the positions this recording writes are SHAPED like, and this recording
// really does resolve `(path, line, column)` — with a real column — for every step it positions.

import {
  ContractSourceMap,
  CtWriter,
  RUNG_FUNCTION,
  RUNG_SOURCE,
  WRITER_PATH_A_PURE_RUST,
  NoirFrameTracker,
  instantiateCtWriter,
  lineLengths,
  resolveTracingConfig,
  type CtRecording,
  type MappingRung,
  type SourceFile,
  type StepPosition,
} from '../../ct-host/src/index.ts';
import type { ExecutedTransaction, ExecutionStep } from './executed_steps.ts';

/** The `TraceLogEvent` metadata key under which the container names its step producer. */
export const STEP_PRODUCER_METADATA = 'ct.step-producer';

/** The producer this file writes. There is exactly one, and it is the AVM's own hook. */
export const STEP_PRODUCER = 'avm-execution-observer';

/** Thrown rather than synthesising anything. See the header. */
export class ExecutedStepsUnavailable extends Error {
  constructor(detail: string) {
    super(
      `this page has no executed step stream to record: ${detail}. Open the runtime with `
        + 'openAvmRuntime({ collectExecutionSteps: true }) and run a transaction before recording. '
        + 'There is deliberately no fallback: the synthesised-opcode path M27 shipped was deleted '
        + 'in M29, because a container carrying fabricated opcodes is worse than no container.',
    );
    this.name = 'ExecutedStepsUnavailable';
  }
}

export interface BrowserRecording {
  /** The finished container. */
  readonly container: Uint8Array;
  readonly bytes: number;
  readonly events: number;
  readonly callsOpened: number;
  readonly pathsInterned: number;
  readonly stepsPositioned: number;
  readonly stepsUnpositioned: number;
  readonly logEvents: number;
  readonly writerKind: number;
  readonly recordingId: string;
  /** The rung the artifact's own debug info earned, and why. Never asserted in advance. */
  readonly rung: number;
  readonly rungReason: string;
  /** The rung DECLARED for the traced contract, measured over the executed stream. */
  readonly declaredRung: number;
  /** Why that rung, with the positioned/unpositioned split in it. */
  readonly declaredRungReason: string;
  /** M29. Which producer wrote the step stream. */
  readonly stepProducer: string;
  /** Records the AVM's observation hook produced for this transaction. */
  readonly executedSteps: number;
  /** `stats["total_instructions_executed"]` for the same transaction, or `null`. */
  readonly instructionsExecuted: number | null;
  /** `avm_steps_batch` crossings the drain cost, and the batch size it used. */
  readonly stepCrossings: number;
  readonly stepBatchRecords: number;
  /** Distinct opcodes in the stream. One is what a constant produces; see the check. */
  readonly distinctOpcodes: number;
  /** Distinct AVM context ids, i.e. how many EXTERNAL calls the execution really made. */
  readonly contexts: number;
  /**
   * Noir function frames opened from the artifact's inline call-stack chains. Zero means the tree
   * collapsed back to one frame per AVM context, which is the defect this replaced.
   */
  readonly noirFramesOpened: number;
  /** Deepest Noir inline stack reached inside a single AVM context. */
  readonly noirMaxDepth: number;
  /** Distinct Noir function names the tree contains. */
  readonly noirFunctions: number;
  /** The filename the download was offered under. */
  readonly filename: string;
}

/** Fetch `ct_writer.wasm`. A separate asset, fetched only when a page decides to record. */
export async function fetchCtWriter(
  url: string,
  options: { readonly fetch?: typeof globalThis.fetch } = {},
): Promise<Uint8Array> {
  const f = options.fetch ?? globalThis.fetch;
  const response = await f(url);
  if (!response.ok) {
    throw new Error(`fetching ${url} answered ${response.status} ${response.statusText}`);
  }
  return new Uint8Array(await response.arrayBuffer());
}

/** base64 -> bytes, without `Buffer`. `atob` is the platform's and needs no polyfill. */
export function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

/** Raw-DEFLATE, the platform's way. Node's `inflateRawSync` has no place in a page. */
export async function inflateRaw(bytes: Uint8Array): Promise<Uint8Array> {
  const stream = new Response(bytes as BufferSource).body!.pipeThrough(
    new DecompressionStream('deflate-raw'),
  );
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

export interface RecordOptions {
  /** `ct_writer.wasm`'s bytes. */
  readonly writerBytes: Uint8Array;
  /** The Token artifact, as fetched JSON. */
  readonly rawArtifact: unknown;
  /** The contract address the steps belong to, as 32 bytes. */
  readonly contractAddress: Uint8Array;
  /** The frame names, in enqueue order. Upstream's own `<Artifact>.<fn>`. */
  readonly frameNames: readonly (string | undefined)[];
  /** A UUID. `ct-print` refuses a `recording_id` that is not exactly 36 characters. */
  readonly recordingId: string;
  /**
   * M29. What the AVM executed — `OpenedRuntime.steps.last`.
   *
   * REQUIRED, and `null` is refused rather than filled in. See {@link ExecutedStepsUnavailable}.
   */
  readonly executed: ExecutedTransaction | null;
  /** Offer the container as a download. False in a headless probe that reads it another way. */
  readonly download?: boolean;
  readonly filename?: string;
  /**
   * M34. Extra `TraceLogEvent`s to write into the container, after the step-producer record.
   *
   * DEFAULTS TO NONE, and that default is what keeps M27's and M29's `logEvents` figure at 1: a
   * caller that does not pass this gets exactly the container it got before. The wallet demo passes
   * its wallet's decision ledger, which is how "every oracle call and signing decision logged into
   * the trace" becomes a property OF the recording rather than a claim ABOUT it — the same reason
   * `declareRung` and the step producer are log events instead of host variables.
   */
  readonly extraLogEvents?: readonly { readonly metadata: string; readonly content: string }[];
}

/** Bytes to `0x`-less lowercase hex, for comparing a step's address with the traced contract's. */
function hexOf(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += b.toString(16).padStart(2, '0');
  return s;
}

/**
 * Write a container for what the page just executed, and offer it for download.
 *
 * The download is a `Blob` and an object URL, revoked after the click. That is the whole browser
 * half; everything above it is the writer M24 shipped, the source map M25 shipped and the
 * observation hook M9 shipped.
 */
export async function recordAndDownload(options: RecordOptions): Promise<BrowserRecording> {
  const executed = options.executed;
  if (executed === null || executed === undefined) {
    throw new ExecutedStepsUnavailable('the collector reports no transaction (collection was off)');
  }
  if (executed.steps.length === 0) {
    throw new ExecutedStepsUnavailable('the last transaction produced zero step records');
  }
  // The module's own count and the number of records decoded must agree. They are two readings of
  // one thing — `avm_steps_count()` and the length of what `avm_steps_batch` handed back — and a
  // disagreement means the drain lost records, which is precisely the failure a container must not
  // be written over.
  if (executed.count !== executed.steps.length) {
    throw new ExecutedStepsUnavailable(
      `the module counted ${executed.count} step(s) and the drain decoded ${executed.steps.length}`,
    );
  }

  const raw = options.rawArtifact as {
    file_map?: Record<string, {
      path: string;
      source: string;
      // Noir's own per-file function table, `{ name, start }` and no `end`. Read here so the Noir
      // frames the pass below opens can be NAMED; see `FunctionLocation` in source_map.ts.
      function_locations?: { name: string; start: number }[];
    }>;
    functions: { name: string; bytecode: string; debug_symbols: string }[];
  };
  const dispatch = raw.functions.find((f) => f.name === 'public_dispatch');
  if (dispatch === undefined) throw new Error('the artifact has no public_dispatch function');

  const bytecode = base64ToBytes(dispatch.bytecode);
  const debugJson = new TextDecoder().decode(await inflateRaw(base64ToBytes(dispatch.debug_symbols)));
  const debugInfo = (JSON.parse(debugJson) as { debug_infos: unknown[] }).debug_infos[0] as never;

  const files = new Map<number, SourceFile>();
  for (const [id, entry] of Object.entries(raw.file_map ?? {})) {
    files.set(Number(id), {
      path: entry.path,
      source: entry.source,
      functionLocations: entry.function_locations ?? [],
    });
  }

  const writer = new CtWriter(
    await instantiateCtWriter(options.writerBytes),
    resolveTracingConfig(
      {
        program: 'aztec-avm',
        recordingId: options.recordingId,
        sourcePath: '/aztec/tx.avm',
        workdir: '/aztec',
        mappingRung: RUNG_SOURCE,
        columns: true,
      } as never,
      WRITER_PATH_A_PURE_RUST,
    ),
    { batchRecords: 64 },
  );

  const map = new ContractSourceMap(debugInfo, bytecode.length, files, (p, ll) =>
    writer.internPath(p, ll),
  );

  // ---------------------------------------------------------------------------------------------
  // PASS ONE: resolve every step's position, and MEASURE the coverage the declaration will claim.
  //
  // It has to be a pass of its own, because `ct_declare_rung` must be on the module's list BEFORE
  // the first step of that contract is ingested — the violation tally is taken per record, against
  // the declaration that exists at the time — and the rung being declared is a fact about the whole
  // stream. Interning happens here too, which is why `pathsInterned` is already right by the time
  // the first step crosses.
  // ---------------------------------------------------------------------------------------------
  const traced = hexOf(options.contractAddress);
  const positions: (StepPosition | null)[] = executed.steps.map((s) => map.positionFor(s.pc));
  let tracedSteps = 0;
  let tracedResolved = 0;
  let firstUnresolvedPc: number | null = null;
  for (let i = 0; i < executed.steps.length; i++) {
    if (hexOf(executed.steps[i]!.contractAddress) !== traced) continue;
    tracedSteps += 1;
    if (positions[i] !== null) tracedResolved += 1;
    else if (firstUnresolvedPc === null) firstUnresolvedPc = executed.steps[i]!.pc;
  }

  const complete = tracedSteps > 0 && tracedResolved === tracedSteps;
  const declaredRung: MappingRung = complete ? RUNG_SOURCE : RUNG_FUNCTION;
  const declaredRungReason = complete
    ? `artifact ${map.verdict.reason}; and all ${tracedSteps} executed step(s) of this contract `
      + 'resolved to a source position'
    : `${tracedResolved} of ${tracedSteps} executed step(s) of this contract resolve to a source `
      + `position; the remaining ${tracedSteps - tracedResolved} are in regions the artifact's `
      + `brillig_locations does not key — compiled procedures are appended after the main body `
      + `(avm-transpiler transpile.rs:489,505), SOURCE-MAPPING.md section 2.4 hole 2 — first at pc `
      + `${firstUnresolvedPc ?? -1}. The artifact itself is rung ${map.verdict.rung}: `
      + map.verdict.reason;
  writer.declareRung(options.contractAddress, declaredRung, declaredRungReason);

  // ---------------------------------------------------------------------------------------------
  // PASS TWO: the frames — AVM contexts on the outside, NOIR FUNCTIONS on the inside.
  //
  // ---------------------------------------------------------------------------------------------
  // WHY THIS IS TWO SIGNALS AND NOT ONE, AND WHY THE SECOND ONE WAS MISSING.
  //
  // A context id is the AVM's identity for an EXTERNAL call. It changes once per enqueued call and
  // not once per function, so a frame loop driven by it alone opens exactly as many frames as there
  // were external calls — two, for this campaign's snapshot transaction, no matter that the
  // execution ran through thirty-odd Aztec.nr functions on the way. That is not a small
  // under-count; it is a call tree with no calls in it.
  //
  // The other signal was already being parsed and thrown away one line at a time. Every pc the
  // artifact keys resolves to a `CallStackId`, and `location_tree` makes that a PARENT-LINKED CHAIN
  // of locations — the Noir inline call stack. `positionFor` walks the whole chain and keeps
  // `locs[locs.length - 1]`, the innermost, because a step's LINE is the innermost location.
  // `framesFor` keeps the rest of it, and the rest of it is the frames.
  //
  // ---------------------------------------------------------------------------------------------
  // THE DIFFING RULE, AND THE ONE CASE THAT MAKES IT NON-OBVIOUS.
  //
  // Per step: the desired Noir stack is `framesFor(pc)`, outermost first. It is diffed against the
  // open stack by LONGEST COMMON PREFIX of frame KEYS — close the divergent suffix, open the rest.
  // Frame keys are containing-function identities, not locations, so moving between statements of
  // one function opens and closes nothing (see `NoirFrame.key`).
  //
  // A STEP WHOSE pc HAS NO CHAIN INHERITS THE PREVIOUS STEP'S STACK. It does NOT close to depth 0.
  //
  // This is the rule the whole pass turns on and it is not cosmetic. `brillig_locations` is SPARSE
  // over the executed pcs: on the snapshot transaction 22 of 108 steps resolve to nothing, and — the
  // part that matters — 8 of those 22 sit at pcs 192…247, INSIDE the keyed range [130, 1785], with
  // chained steps on both sides. They are holes in the middle of a function body, not a prologue.
  // Closing to depth 0 on a hole would emit a full unwind and an immediate identical re-entry at
  // every one of them: a tree that claims the execution left and re-entered eight nested functions
  // eight times, in the middle of a straight-line body, because a source map had a gap. Inheriting
  // reports what actually happened — nothing — and the gate asserts exactly that by step index.
  //
  // The inheritance is scoped to the AVM context. Crossing a context boundary resets it, because an
  // external call cannot be inside the previous call's inline stack, and a pc from a DIFFERENT
  // contract is not keyed by this artifact's map at all.
  //
  // ---------------------------------------------------------------------------------------------
  // EVERYTHING IS RECORDED. NOTHING IS ELIDED HERE.
  //
  // 28 of the positioned steps are inside poseidon2 hashing, and the default view for this trace
  // should show that subtree FOLDED. That is a fold, not a filter, and it belongs to whatever
  // renders the tree: a container that omitted the frames could never be unfolded, while a complete
  // container with a collapsed default is one interaction away from either. So this pass writes
  // every frame it derives, and the renderer decides which start closed — off the frame's own
  // `pathId`, which `writer.call` already carries.
  // ---------------------------------------------------------------------------------------------
  const stack: number[] = [];
  let topLevelSeen = 0;
  /** The opcodes actually WRITTEN, accumulated in the loop. See `distinctOpcodes` below. */
  const written = new Set<number>();
  // The diffing rule is `ct-host`'s, shared with the settled-transaction recorder so the two cannot
  // drift. `noir_frames.ts` holds the rule and the evidence the inherit case rests on.
  const noir = new NoirFrameTracker(writer);

  const openFrame = (step: ExecutionStep, position: StepPosition | null): void => {
    const name = stack.length === 0
      ? (options.frameNames[topLevelSeen] ?? `context${step.contextId}`)
      : `context${step.contextId}`;
    if (stack.length === 0) topLevelSeen += 1;
    writer.call(name, {
      ...(position?.pathId !== undefined ? { pathId: position.pathId } : {}),
      line: position?.line ?? 1,
      contractAddress: step.contractAddress,
    });
  };

  for (let i = 0; i < executed.steps.length; i++) {
    const step = executed.steps[i]!;
    const at = positions[i]!;
    if (stack.length === 0 || stack[stack.length - 1] !== step.contextId) {
      const known = stack.lastIndexOf(step.contextId);
      if (known >= 0) {
        // A RETURN: unwind to the frame this record belongs to. The Noir frames open inside the
        // contexts being left go first — a frame cannot outlive the frame it is nested in.
        noir.closeAll();
        while (stack.length - 1 > known) {
          writer.returnFrame();
          stack.pop();
        }
      } else {
        noir.closeAll();
        openFrame(step, at);
        stack.push(step.contextId);
      }
    }

    // THE NOIR STACK FOR THIS STEP. `null` means this pc has no chain, and the rule for that is to
    // inherit — `noir` is left exactly as it is and no call or return is written. See above.
    noir.step(map.framesFor(step.pc), step.contractAddress);

    const opcode = step.opcode;
    const event = {
      contextId: step.contextId,
      pc: step.pc,
      opcode,
      l2Gas: BigInt(step.gasUsed.l2Gas),
      daGas: BigInt(step.gasUsed.daGas),
      contractAddress: step.contractAddress,
    } as never;
    // THE POSITION IS THE SECOND ARGUMENT AND NOT A FIELD OF THE EVENT, which is a distinction
    // the first draft of this file got wrong. `push` pairs the step and position FIFOs by order
    // and stages a `line: 0` slot for a step with no position; a `position` key inside the event
    // object is simply ignored by `encodeStep`.
    written.add(opcode);
    if (at === null) writer.push(event);
    else writer.push(event, at);
  }
  // Noir frames first, for the same reason the context-change path closes them first.
  noir.closeAll();
  while (stack.length > 0) {
    writer.returnFrame();
    stack.pop();
  }

  // ---------------------------------------------------------------------------------------------
  // WHICH PRODUCER WROTE THIS STREAM, INTO THE CONTAINER.
  //
  // M29's deliverable: "`ct_writer_kind()` and the trace metadata record which producer wrote the
  // stream". `ct_writer_kind()` is the writer's own answer and is read off the module at close;
  // this is the other half, and it is a `TraceLogEvent` for `declareRung`'s reason — a claim that
  // lived only in a host variable would be a claim ABOUT a recording rather than a property OF one.
  // ---------------------------------------------------------------------------------------------
  // COUNTED FROM WHAT WAS PUSHED, NOT FROM WHAT WAS DRAINED. `written` is filled in the loop above
  // out of each event's own `opcode` field, so a producer that altered the opcode on the way into
  // the writer would move this number. Deriving it from `executed.steps` instead would be the
  // campaign's "a printed literal": a figure the producer reports about itself, upstream of the one
  // thing it could get wrong. Mutation M1 proved that is not hypothetical — it changed the written
  // opcodes and left this number alone, and every behavioural assertion in
  // `test_browser_steps_are_executed_not_mapped` passed. The check reads the CONTAINER now, through
  // the reference reader; this is the host-side half of the same correction.
  const distinctOpcodes = written.size;
  const contexts = new Set(executed.steps.map((s) => s.contextId)).size;
  writer.logEvent(
    STEP_PRODUCER_METADATA,
    `${STEP_PRODUCER} steps=${executed.steps.length} `
      + `instructionsExecuted=${executed.instructionsExecuted ?? -1} `
      + `crossings=${executed.crossings} batch=${executed.batchRecords} `
      + `distinctOpcodes=${distinctOpcodes} contexts=${contexts} `
      // THE NOIR TREE'S OWN NUMBERS, IN THE CONTAINER. Same reason the rung's reason and the step
      // producer are log events: a figure that lived only in the host's return value is a claim
      // ABOUT a recording, and this one has to be a property OF one — it is what makes a silent
      // collapse back to the context-only tree (`noirFrames=0`) visible to a reader of the bytes.
      + `noirFrames=${noir.framesOpened} noirMaxDepth=${noir.deepest} `
      + `noirFunctions=${noir.functionNames.size}`,
  );

  // M34's records, after the producer's and in the order the caller gives them. The module refuses
  // an empty metadata key, so a malformed entry is a loud failure here rather than an unfindable
  // record in the container.
  for (const extra of options.extraLogEvents ?? []) {
    writer.logEvent(extra.metadata, extra.content);
  }

  const recording: CtRecording = writer.close();
  const filename = options.filename ?? `aztec-avm-${options.recordingId}.ct`;

  if (options.download !== false) offerDownload(recording.container, filename);

  return {
    container: recording.container,
    bytes: recording.container.byteLength,
    events: recording.events,
    callsOpened: recording.callsOpened,
    pathsInterned: recording.pathsInterned,
    stepsPositioned: recording.stepsPositioned,
    stepsUnpositioned: recording.stepsUnpositioned,
    logEvents: recording.logEvents,
    writerKind: recording.writerKind,
    recordingId: options.recordingId,
    rung: map.verdict.rung,
    rungReason: map.verdict.reason,
    declaredRung,
    declaredRungReason,
    stepProducer: STEP_PRODUCER,
    executedSteps: executed.steps.length,
    instructionsExecuted: executed.instructionsExecuted,
    stepCrossings: executed.crossings,
    stepBatchRecords: executed.batchRecords,
    distinctOpcodes,
    contexts,
    noirFramesOpened: noir.framesOpened,
    noirMaxDepth: noir.deepest,
    noirFunctions: noir.functionNames.size,
    filename,
  };
}

/**
 * The download itself.
 *
 * A `Blob`, an object URL, a synthetic click, and a revoke. It is four lines and it is the only
 * part of this file that could not run in Node — which is the point of DD-5: the CAPABILITY is the
 * container, and the download is the browser's way of handing it over.
 */
export function offerDownload(container: Uint8Array, filename: string): void {
  const url = URL.createObjectURL(new Blob([container as BufferSource], { type: 'application/octet-stream' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.rel = 'noopener';
  document.body.appendChild(a);
  a.click();
  a.remove();
  // Revoked on the next task, not immediately: revoking synchronously after `click()` races the
  // browser's own read of the URL and produces a download that fails with no error anywhere.
  setTimeout(() => URL.revokeObjectURL(url), 0);
}

export { lineLengths };
