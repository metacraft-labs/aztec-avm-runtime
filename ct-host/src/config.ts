// DD-7, in the one place a caller can reach it.
//
// ---------------------------------------------------------------------------
// A TYPESCRIPT-ONLY GUARANTEE IS NOT A GUARANTEE, AND THIS FILE IS WRITTEN AROUND THAT.
//
// M23 shipped an honesty disclosure whose only protection was `private constructor`. Node 24 runs
// these sources by STRIPPING types: `private` is erased, the constructor is public at run time,
// and the disclosure was bypassable through the package's own public export until a check tried
// it. Nothing in this file relies on a modifier, a `readonly`, a branded type or a literal type —
// every one of those is gone before the code runs.
//
// What survives type stripping is a value check and object identity. So:
//
//   * `resolveTracingConfig` performs the DD-7 refusal on the VALUE `columns === true`, not on a
//     type. A caller who reaches it through `as any` gets the same throw.
//   * The result is registered in a module-private `WeakSet`. `CtWriter`'s constructor asks the
//     WeakSet, so an object that merely has the right shape is refused. A `WeakSet` is not a
//     type: `RESOLVED.has(x)` runs.
//
// `test_dropped_column_awareness_asserted` executes both bypasses rather than reading the code.
// ---------------------------------------------------------------------------

import { WRITER_KIND_PATH_A_PURE_RUST } from './abi.ts';

/** DD-7's Path A: the pure-Rust `CtfsTraceWriter`. Cannot carry columns. */
export const WRITER_PATH_A_PURE_RUST = 'path-a-pure-rust';
/** DD-7's Path B: the column-aware Nim writer. Declared, and not available on wasm today. */
export const WRITER_PATH_B_NIM = 'path-b-nim';

export type WriterPath = typeof WRITER_PATH_A_PURE_RUST | typeof WRITER_PATH_B_NIM;

/** Which `ct_writer_kind()` value each declared path corresponds to. */
export const WRITER_KIND_OF: Readonly<Record<WriterPath, number>> = {
  [WRITER_PATH_A_PURE_RUST]: WRITER_KIND_PATH_A_PURE_RUST,
  [WRITER_PATH_B_NIM]: 2,
};

/**
 * Which writer paths can carry column-aware steps.
 *
 * A DATA TABLE RATHER THAN A CONDITIONAL, so adding Path B is a row and not an edit to the gate.
 * Path A's `false` is the structural fact §9.3 records: no column-bearing step encoder, no
 * `paths.dat` Layout A line-length table, no `sekDeltaColumn` opcode, and `meta.dat` capability
 * bits 4/6/7 deliberately unset.
 */
export const CARRIES_COLUMNS: Readonly<Record<WriterPath, boolean>> = {
  [WRITER_PATH_A_PURE_RUST]: false,
  [WRITER_PATH_B_NIM]: true,
};

/** What a caller asks for. Plain data; nothing here is enforced by its type. */
export interface TracingConfig {
  /** The program name stamped into the container's metadata. */
  program: string;
  /**
   * A UUIDv7. `wasm32-unknown-unknown` has neither a wall clock nor a CSPRNG and cannot mint one,
   * so the host must. An empty string leaves the writer's deterministic placeholder in place,
   * which is well-formed and collides with every other recording in a trace store.
   */
  recordingId: string;
  /** The source path steps are attributed to. */
  sourcePath: string;
  /** The working directory recorded in the container. */
  workdir: string;
  /** Whether this recording needs column-aware steps. DD-7's question. */
  columns: boolean;
}

export interface ResolvedTracingConfig extends TracingConfig {
  /** The writer path this configuration was resolved against. Carried into the result. */
  writerPath: WriterPath;
}

/** The DD-7 refusal: columns were asked of a writer that structurally cannot carry them. */
export class ColumnAwarenessUnavailable extends Error {
  readonly writerPath: WriterPath;
  constructor(writerPath: WriterPath) {
    super(
      `the tracing configuration asked for column-aware steps and the '${writerPath}' writer ` +
        'cannot carry them (DD-7). This writer has no column-bearing step encoder, no paths.dat ' +
        'Layout A line-length table and no delta-column opcode, and it does not set meta.dat ' +
        'capability bits 4/6/7. Refusing here rather than producing a container that reads back ' +
        'with every step present and every column silently gone. Set columns: false, or use a ' +
        'writer path that carries them.',
    );
    this.name = 'ColumnAwarenessUnavailable';
    this.writerPath = writerPath;
  }
}

/** A configuration reached the writer without going through `resolveTracingConfig`. */
export class UnresolvedTracingConfig extends Error {
  constructor() {
    super(
      'this tracing configuration was not produced by resolveTracingConfig(). The DD-7 ' +
        'column gate lives there, and a configuration that did not pass through it has not ' +
        'been gated. Object identity is checked rather than shape, because a shape check is a ' +
        'type check and types are erased at run time.',
    );
    this.name = 'UnresolvedTracingConfig';
  }
}

/**
 * A column-aware request reached the module and the module reports it was dropped.
 *
 * DD-7's second half, and it fires ONLY when columns were requested — asserting on
 * `dropped_column_awareness()` unconditionally would fail every ordinary recording, since the
 * signal is `false` precisely because nobody asked.
 */
export class ColumnAwarenessDropped extends Error {
  constructor(writerPath: WriterPath, kind: number) {
    super(
      `column-aware steps were requested against the '${writerPath}' writer path, but the module ` +
        `that ran (ct_writer_kind() = ${kind}) reports dropped_column_awareness(). The container ` +
        'would read back complete and be silently column-free. This is the signal the writer ' +
        'exposes so a consumer can assert rather than discover the loss downstream.',
    );
    this.name = 'ColumnAwarenessDropped';
  }
}

// A `WeakSet` and not a `Set`: a configuration is per-recording and holding them all forever is a
// leak in a process that traces a chain.
const RESOLVED = new WeakSet<object>();

/**
 * Apply DD-7 and hand back a configuration the writer will accept.
 *
 * Throws {@link ColumnAwarenessUnavailable} **at configuration time** when the requested writer
 * path cannot carry columns — which is the whole point: the alternative is a container that
 * reads back with every step present and every column gone, and nothing to distinguish it from
 * one that never had columns to lose.
 */
export function resolveTracingConfig(
  config: TracingConfig,
  writerPath: WriterPath,
): ResolvedTracingConfig {
  if (config === null || typeof config !== 'object') {
    throw new TypeError('resolveTracingConfig: config must be an object');
  }
  if (!(writerPath in CARRIES_COLUMNS)) {
    throw new RangeError(`resolveTracingConfig: unknown writer path '${String(writerPath)}'`);
  }
  // `=== true` rather than truthiness: a caller passing the string "false" through a JSON round
  // trip must not turn the gate off, and a caller passing 1 must not turn it on by accident.
  // The refusal is on the value, so `as any` does not route around it.
  if (config.columns === true && CARRIES_COLUMNS[writerPath] !== true) {
    throw new ColumnAwarenessUnavailable(writerPath);
  }
  const resolved: ResolvedTracingConfig = {
    program: config.program,
    recordingId: config.recordingId,
    sourcePath: config.sourcePath,
    workdir: config.workdir,
    columns: config.columns === true,
    writerPath,
  };
  RESOLVED.add(resolved);
  return resolved;
}

/** Whether an object came out of {@link resolveTracingConfig}. Identity, not shape. */
export function isResolvedTracingConfig(x: unknown): x is ResolvedTracingConfig {
  return typeof x === 'object' && x !== null && RESOLVED.has(x);
}
