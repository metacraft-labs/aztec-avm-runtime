// The PRIVATE half of a transaction, stepped and written into a `.ct` container, IN A PAGE.
//
// =============================================================================================
// WHAT THIS CLOSES
// =============================================================================================
//
// M38 and M39 step a private Aztec frame with the real Noir tracer, and both do it in a NATIVE
// binary: the probe reads its artifacts with `std::fs` and writes its container with the Nim FFI
// writer, and neither of those can target wasm. So the half that a page EXECUTES was, until now,
// stepped somewhere else.
//
// Two modules and no third writer:
//
//   `m40_private_trace.wasm`  — `noir_tracer` built for `wasm32-unknown-unknown` from the
//                               PUBLISHED `noir`, with M38's executor seam and a tape-replaying
//                               foreign-call executor. It stops at the CodeTracer low-level event
//                               stream and emits it as an ordered op list.
//   `ct_writer.wasm`          — the page's own Path A writer, already here, already used by the
//                               public half. It gains one export for this: `ct_source_step`.
//
// **The Noir tracer links no container writer on this path at all**, which is why `JOIN-SHAPE.md`
// §2's facts 6 and 7 are untouched: this is a different answer to the same need rather than the
// answer OQ-7 ruled out, and `wasm/webpage` stays unpublished.
//
// =============================================================================================
// WHY THE STEPS DO NOT GO THROUGH `recordAndDownload`
// =============================================================================================
//
// `ct_download.ts` writes an AVM recording: every step carries `opcode`, `contextId`, `l2Gas`,
// `daGas` and a contract address, because those are what upstream's `ExecutionStep` is. A Noir
// private frame's step is a `(path, line, column)` and has none of them. Pushing one through
// `CtWriter.push` would mean this file inventing four counters per step — the exact shape M29
// found in M27's synthesised opcodes, and the reason `recordAndDownload` refuses to fabricate a
// step stream rather than falling back to one.

import {
  CtWriter,
  RUNG_SOURCE,
  WRITER_PATH_A_PURE_RUST,
  instantiateCtWriter,
  resolveTracingConfig,
  type CtRecording,
} from '../../ct-host/src/index.ts';
import { offerDownload } from './ct_download.ts';

/** One instruction for the container writer, as `m40_private_trace.wasm` emits it. */
export type TraceOp =
  | { readonly k: 'path'; readonly path: string; readonly lineLengths: readonly number[] }
  | { readonly k: 'step'; readonly path: number; readonly line: number; readonly column: number }
  | { readonly k: 'call'; readonly name: string; readonly path: number; readonly line: number; readonly address: string }
  | { readonly k: 'ret' }
  | { readonly k: 'event'; readonly metadata: string; readonly content: string };

/** What the tracer module reports about the transaction it stepped. */
export interface TracerReport {
  readonly program: string;
  readonly frameCount: number;
  readonly maxDepth: number;
  readonly steps: number;
  readonly stepsWithColumn: number;
  readonly distinctPositions: number;
  readonly distinctLines: number;
  readonly stepPaths: readonly string[];
  readonly registeredPaths: number;
  readonly finish: string;
  readonly traceResults: readonly string[];
  readonly traceErrors: readonly string[];
  readonly refusedOracles: readonly string[];
  readonly encode: {
    readonly ops: readonly TraceOp[];
    readonly steps: number;
    readonly stepsWithColumn: number;
    readonly calls: number;
    readonly returns: number;
  };
  readonly [key: string]: unknown;
}

export class PrivateTraceRefused extends Error {
  constructor(detail: string) {
    super(`the private-half tracer refused this transaction: ${detail}`);
    this.name = 'PrivateTraceRefused';
  }
}

/**
 * Instantiate an import-free wasm module and count the imports it REACHES.
 *
 * A near-copy of `verification/m30/page/wasm_host.mjs`'s `instantiateBare`, and the duplication is
 * deliberate: M28's `verify_verification_code_unreachable_from_browser` asserts that nothing under
 * `verification/` is reachable from the shipped browser graph, so importing that file here would
 * make the shipped bundle depend on a check's own scaffolding. The property both copies exist for
 * is the same and is a MEASUREMENT rather than a build flag: every declared import is satisfied
 * with a function that records the call and then throws, so `reachedImports` being empty is
 * something the run says rather than something the manifest promises.
 */
async function instantiateBare(wasmBytes: BufferSource, label: string) {
  const module = await WebAssembly.compile(wasmBytes);
  const declared = WebAssembly.Module.imports(module).map(({ module: m, name }) => `${m}.${name}`);
  const reached: string[] = [];
  const importObject: Record<string, Record<string, unknown>> = {};
  for (const { module: m, name } of WebAssembly.Module.imports(module)) {
    importObject[m] ??= {};
    importObject[m]![name] = () => {
      reached.push(`${m}.${name}`);
      throw new Error(`${label}: the module reached ${m}.${name}, which this host does not provide`);
    };
  }
  const { exports } = await WebAssembly.instantiate(module, importObject as WebAssembly.Imports);
  return { exports: exports as Record<string, CallableFunction> & { memory: WebAssembly.Memory }, declared, reached };
}

/** sha256 as lowercase hex. `crypto.subtle` is in every page and in Node 24. */
async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes as unknown as BufferSource);
  return Array.from(new Uint8Array(digest))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
}

/** A 32-byte big-endian address from its `0x…` rendering. Left-padded, refusing anything longer. */
function addressBytes(hex: string): Uint8Array {
  const body = (hex.startsWith('0x') ? hex.slice(2) : hex).padStart(64, '0');
  if (body.length !== 64) {
    throw new PrivateTraceRefused(`'${hex}' is ${body.length} hex digits and an address is 64`);
  }
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i += 1) out[i] = Number.parseInt(body.slice(i * 2, i * 2 + 2), 16);
  return out;
}

/** Step the transaction the request describes, inside `tracerBytes`. */
export async function stepPrivateHalf(
  tracerBytes: Uint8Array,
  request: unknown,
): Promise<{ report: TracerReport; declaredImports: readonly string[]; reachedImports: readonly string[] }> {
  const host = await instantiateBare(tracerBytes, 'm40-private-trace');
  const encoder = new TextEncoder();
  const encoded = encoder.encode(JSON.stringify(request));
  // `memory.buffer` is re-read after every call into wasm: the allocator grows linear memory and
  // growing it DETACHES every view taken before, so a cached view produces zero-length reads —
  // which read as an empty answer rather than as an error.
  const view = (ptr: number, len: number) => new Uint8Array(host.exports.memory.buffer, ptr, len);
  const inPtr = Number(host.exports.pt_alloc(encoded.length));
  view(inPtr, encoded.length).set(encoded);
  let bytes: Uint8Array;
  let isError: boolean;
  try {
    const outPtr = Number(host.exports.pt_trace_transaction(inPtr, encoded.length));
    const len = Number(host.exports.pt_result_len());
    isError = Number(host.exports.pt_result_is_error()) !== 0;
    bytes = view(outPtr, len).slice();
    host.exports.pt_free(outPtr, len);
  } finally {
    host.exports.pt_free(inPtr, encoded.length);
  }
  const text = new TextDecoder().decode(bytes);
  if (isError) throw new PrivateTraceRefused(text);
  return {
    report: JSON.parse(text) as TracerReport,
    declaredImports: host.declared,
    reachedImports: host.reached,
  };
}

export interface PrivateHalfRecording {
  readonly report: TracerReport;
  readonly recording: Omit<CtRecording, 'container'>;
  readonly container: Uint8Array;
  readonly bytes: number;
  readonly declaredImports: readonly string[];
  /** Empty is the interesting answer: nothing in the tracer crossed back into JavaScript. */
  readonly reachedImports: readonly string[];
  readonly opsReplayed: number;
  readonly filename: string;
  /** Whether the columns were deliberately dropped. See the option of this name. */
  readonly columnsDropped: boolean;
  /**
   * Steps whose column this host passed to `ct_source_step` as a non-zero value.
   *
   * NOT the tracer's `stepsWithColumn`, which is the module's report about its own event stream: a
   * module that counted columns and emitted none would agree with itself. This is the count at the
   * boundary the container is on the other side of.
   */
  readonly columnsWritten: number;
  /**
   * sha256 of the container, as lowercase hex, taken in the page.
   *
   * It is what the column control is compared ON: two runs of one transaction differing only in
   * whether the column was written must produce two different digests, and a check that read a
   * `stepsWithColumn` field instead would be reading a number the producer set.
   */
  readonly sha256: string;
}

/**
 * Step a private transaction and write its container, in one page, with two wasm modules.
 *
 * `request` is `m40_private_trace.wasm`'s own request shape: `{program, artifacts, frames, join}`.
 * Nothing here interprets it — a caller that got a frame wrong gets the module's refusal by name
 * rather than a container that is quietly a different transaction.
 */
export async function recordPrivateHalf(options: {
  readonly tracerBytes: Uint8Array;
  readonly writerBytes: Uint8Array;
  readonly request: unknown;
  readonly recordingId: string;
  /** The container's declared source path. The tracer's own paths are interned beside it. */
  readonly sourcePath?: string;
  readonly workdir?: string;
  readonly program?: string;
  readonly download?: boolean;
  readonly filename?: string;
  /**
   * CONTROL: write every step with column `0` — "line only" — and change nothing else.
   *
   * "The container carries the columns" is the claim this whole path is for, and the pinned
   * reader's Path A rendering does not surface a column, so reading its absence there would be a
   * fact about the READER stated as one about the container. This arm produces the other side of
   * the comparison: the same ops, the same steps, the same paths, one field dropped. Two digests
   * that differ is the column reaching the container; two that agree would mean it never did.
   */
  readonly dropColumns?: boolean;
}): Promise<PrivateHalfRecording> {
  const { report, declaredImports, reachedImports } = await stepPrivateHalf(
    options.tracerBytes,
    options.request,
  );
  if (report.encode.ops.length === 0) {
    throw new PrivateTraceRefused('the tracer produced no ops, so there is nothing to write');
  }

  const writer = new CtWriter(
    await instantiateCtWriter(options.writerBytes),
    resolveTracingConfig(
      {
        program: options.program ?? report.program,
        recordingId: options.recordingId,
        sourcePath: options.sourcePath ?? '/aztec/private.nr',
        workdir: options.workdir ?? '/aztec',
        // RUNG 1, AND IT IS NOT A CLAIM ABOUT AN AVM PROGRAM COUNTER. Every step here carries a
        // real `(path, line, column)` out of the artifact's own debug information — that is what
        // the Noir tracer produces — so `columns: true` is recordable, which is the conjunct
        // `resolveTracingConfig` added in M25.
        mappingRung: RUNG_SOURCE,
        columns: true,
      } as never,
      WRITER_PATH_A_PURE_RUST,
    ),
  );

  // The op list's `path` fields index the TRACER's registration order; the module's ids come back
  // from `ct_intern_path`. They agree today and are mapped rather than assumed, because a writer
  // that interned a path of its own would shift every later id and every step would land in a
  // real-looking wrong file.
  const pathIds: number[] = [];
  let replayed = 0;
  // THE COLUMNS THIS HOST ACTUALLY HANDED THE WRITER, counted here rather than read off the
  // tracer's report.
  //
  // FOUND BY M40's OWN MUTATION MATRIX, ARM P6. That arm makes the module emit `column: 0` in every
  // op while leaving its own `stepsWithColumn` at the real figure — and the check's column identity
  // stayed GREEN, because it was reading the PRODUCER's report about itself rather than what the
  // producer produced. This counter is one boundary closer: it is what crossed into `ct_source_step`
  // and therefore what decides the container, and it is 0 under both P6 and the `dropColumns`
  // control.
  let columnsWritten = 0;
  for (const op of report.encode.ops) {
    switch (op.k) {
      case 'path':
        pathIds.push(writer.internPath(op.path, op.lineLengths));
        break;
      case 'step': {
        const id = pathIds[op.path];
        if (id === undefined) {
          throw new PrivateTraceRefused(
            `a step names path ${op.path} and only ${pathIds.length} have been interned`,
          );
        }
        const column = options.dropColumns === true ? 0 : op.column;
        if (column !== 0) columnsWritten += 1;
        writer.sourceStep(id, op.line, column);
        break;
      }
      case 'call': {
        const id = pathIds[op.path];
        if (id === undefined) {
          throw new PrivateTraceRefused(
            `a call names path ${op.path} and only ${pathIds.length} have been interned`,
          );
        }
        writer.call(op.name, { pathId: id, line: op.line, contractAddress: addressBytes(op.address) });
        break;
      }
      case 'ret':
        writer.returnFrame();
        break;
      case 'event':
        writer.logEvent(op.metadata, op.content);
        break;
    }
    replayed += 1;
  }

  const recording = writer.close();
  // THE TRACER'S COUNT AND THE WRITER'S, COMPARED. Two producers of one number: the module counted
  // the steps it emitted ops for and the writer counted the ones it accepted. A replay that
  // dropped one would otherwise be invisible in a container that still opens.
  if (recording.sourceSteps !== report.encode.steps) {
    throw new PrivateTraceRefused(
      `the tracer emitted ${report.encode.steps} step op(s) and the writer recorded `
        + `${recording.sourceSteps}`,
    );
  }
  const filename = options.filename ?? `aztec-private-${options.recordingId}.ct`;
  if (options.download !== false) offerDownload(recording.container, filename);
  const { container, ...rest } = recording;
  return {
    report,
    recording: rest,
    container,
    bytes: container.length,
    declaredImports,
    reachedImports,
    opsReplayed: replayed,
    filename,
    columnsDropped: options.dropColumns === true,
    columnsWritten,
    sha256: await sha256Hex(container),
  };
}
