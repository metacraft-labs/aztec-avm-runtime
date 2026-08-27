// The product claim: a `.ct` container, produced in the page, offered for download.
//
// ===========================================================================================
// THIS IS THE FILE `e2e_browser_downloads_ct_container_and_ct_print_parses` IS ABOUT.
// ===========================================================================================
//
// The milestone calls that check "the only test that proves the actual product claim". What it
// proves is a chain of four things, and every link had to already exist:
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
//
// So M27 adds no format and no writer. What it adds is one browser API — `Blob` + an object URL —
// and one browser-shaped decompression.
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
// WHAT THE STEPS ARE, STATED RATHER THAN IMPLIED.
// ===========================================================================================
//
// The program counters are the artifact's OWN FIRST N MAPPED pcs, not the pcs this execution
// visited. That is M25's shape and M26's, and `SOURCE-MAPPING.md` §2.3 says so for `AvmTest`; it
// is repeated here because a reader who sees a container downloaded from a page that just executed
// a transaction will otherwise read the step count as an instruction count. Wiring the AVM's own
// observation hook through to the browser is M25's `test_trace_step_count_matches_instruction_count`
// and it is still `pending`, for the same reason it is pending in Node.

import {
  ContractSourceMap,
  CtWriter,
  RUNG_SOURCE,
  WRITER_PATH_A_PURE_RUST,
  instantiateCtWriter,
  lineLengths,
  resolveTracingConfig,
  type CtRecording,
} from '../../ct-host/src/index.ts';

/** The default number of steps a demo recording carries. Large enough that a frame split shows. */
export const DEMO_STEPS = 64;

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
  readonly steps?: number;
  /** Offer the container as a download. False in a headless probe that reads it another way. */
  readonly download?: boolean;
  readonly filename?: string;
}

/**
 * Write a container for what the page just executed, and offer it for download.
 *
 * The download is a `Blob` and an object URL, revoked after the click. That is the whole browser
 * half; everything above it is the writer M24 shipped and the source map M25 shipped.
 */
export async function recordAndDownload(options: RecordOptions): Promise<BrowserRecording> {
  const raw = options.rawArtifact as {
    file_map?: Record<string, { path: string; source: string }>;
    functions: { name: string; bytecode: string; debug_symbols: string }[];
  };
  const dispatch = raw.functions.find((f) => f.name === 'public_dispatch');
  if (dispatch === undefined) throw new Error('the artifact has no public_dispatch function');

  const bytecode = base64ToBytes(dispatch.bytecode);
  const debugJson = new TextDecoder().decode(await inflateRaw(base64ToBytes(dispatch.debug_symbols)));
  const debugInfo = (JSON.parse(debugJson) as { debug_infos: unknown[] }).debug_infos[0] as never;

  const files = new Map<number, { path: string; source: string }>();
  for (const [id, entry] of Object.entries(raw.file_map ?? {})) {
    files.set(Number(id), { path: entry.path, source: entry.source });
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
  writer.declareRung(options.contractAddress, RUNG_SOURCE, `artifact ${map.verdict.reason}`);

  const mapped = Object.keys(
    (debugInfo as { brillig_locations?: Record<string, Record<string, unknown>> })
      .brillig_locations?.['0'] ?? {},
  )
    .map(Number)
    .filter(Number.isInteger)
    .sort((a, b) => a - b)
    .slice(0, options.steps ?? DEMO_STEPS);

  const names = options.frameNames.length ? options.frameNames : ['public_dispatch'];
  let i = 0;
  for (let frame = 0; frame < names.length; frame++) {
    const mine = mapped.filter((_, k) => k % names.length === frame);
    const first = mine.length > 0 ? map.positionFor(mine[0]!) : null;
    writer.call(names[frame] ?? `frame${frame}`, {
      ...(first?.pathId !== undefined ? { pathId: first.pathId } : {}),
      line: first?.line ?? 1,
      contractAddress: options.contractAddress,
    });
    for (const pc of mine) {
      const at = map.positionFor(pc);
      const step = {
        contextId: frame + 1,
        pc,
        opcode: (pc % 200) + 1,
        l2Gas: BigInt(100_000 - i * 7),
        daGas: BigInt(1_000 - i),
        contractAddress: options.contractAddress,
      } as never;
      // THE POSITION IS THE SECOND ARGUMENT AND NOT A FIELD OF THE EVENT, which is a distinction
      // the first draft of this file got wrong. `push` pairs the step and position FIFOs by order
      // and stages a `line: 0` slot for a step with no position; a `position` key inside the event
      // object is simply ignored by `encodeStep`. The symptom was not silence — the writer refused
      // at `close()` with `MappingRungDegraded: 0 step(s) were positioned and 64 were not`, which
      // is M25's ladder doing exactly what it exists to do.
      if (at === null) writer.push(step);
      else writer.push(step, at);
      i += 1;
    }
    writer.returnFrame();
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
