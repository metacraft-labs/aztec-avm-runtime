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

import {
  RUNG_BYTECODE,
  RUNG_FUNCTION,
  RUNG_NAME,
  RUNG_SOURCE,
  WRITER_KIND_PATH_A_PURE_RUST,
  type MappingRung,
} from './abi.ts';

/** A recording claimed rung 1 and then produced steps with no source position. */
export class MappingRungDegraded extends Error {
  readonly violations: number;
  readonly firstViolationPc: number;
  readonly stepsPositioned: number;
  readonly stepsUnpositioned: number;
  constructor(violations: number, firstViolationPc: number, positioned: number, unpositioned: number) {
    super(
      `${violations} contract(s) in this recording declared source-mapping rung ${RUNG_SOURCE} ` +
        `and then produced steps with no resolved source position — the first at pc ` +
        `${firstViolationPc}. ${positioned} step(s) were positioned and ${unpositioned} were not. ` +
        'The container would read back complete, with every step present and some of them ' +
        'addressing a program counter while the metadata says they address Aztec.nr source. ' +
        'That is the SILENT DEGRADATION the ladder exists to refuse, so it is refused here ' +
        'rather than discovered by someone stepping through the recording. Declare the rung the ' +
        'contract actually achieved, or supply a position for every step of the ones you claim.',
    );
    this.name = 'MappingRungDegraded';
    this.violations = violations;
    this.firstViolationPc = firstViolationPc;
    this.stepsPositioned = positioned;
    this.stepsUnpositioned = unpositioned;
  }
}

/** DD-7's Path A: the pure-Rust `CtfsTraceWriter`. */
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
 * Which writer paths can produce column-aware steps **as wired into this runtime**.
 *
 * A DATA TABLE RATHER THAN A CONDITIONAL, so adding Path B is a row and not an edit to the gate.
 *
 * ---------------------------------------------------------------------------
 * PATH A'S `false` USED TO BE A FACT ABOUT THE WRITER. IT IS NOT ANY MORE, AND THE ROW STAYS.
 *
 * When DD-7 was taken, Path A's limitation was structural and §9.3 enumerated it: no
 * column-bearing step encoder, no `paths.dat` Layout A line-length table, no `sekDeltaColumn`
 * opcode, `meta.dat` capability bits 4/6/7 unset. **All three now exist** — `pins.json`'s
 * `trace_format` anchor moved onto the column-capable writer, and `ct_writer_open(want_columns=1)`
 * is honoured rather than dropped.
 *
 * What is still missing is on THIS side, and it is not a flag either: there is no source column
 * to record. `emit()` is on §9.2's rung 3 and writes a program counter as `Line(pc)`; there is no
 * source mapping, so a "column" here would be a number with nothing behind it. Turning column
 * mode on would set the `meta.dat` bits that tell a reader this recording's columns are
 * breakpoint-sharp, over positions that are program counters — which is the silent degradation
 * DD-7 exists to refuse, arriving from the other direction.
 *
 * So the row is `false` and its SUBJECT has moved from the writer to the event source. M25 is
 * what changes it, by settling OQ-5 and giving `emit()` a real source position; when it does,
 * this is a one-line edit and `CARRIES_COLUMNS` is still a table.
 * ---------------------------------------------------------------------------
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
  /**
   * Which rung of §9.2's source-fidelity ladder this recording claims.
   *
   * **Optional, and it defaults to {@link RUNG_BYTECODE} — deliberately the pessimistic end.** A
   * caller that says nothing gets rung 3, which is what M24 shipped and what a program counter
   * honestly is. Claiming rung 1 is an act, and it is the act the column gate below turns on.
   */
  mappingRung?: MappingRung;
}

export interface ResolvedTracingConfig extends TracingConfig {
  /** The writer path this configuration was resolved against. Carried into the result. */
  writerPath: WriterPath;
  /** The rung, resolved. Never `undefined` here — that is the point of resolving. */
  mappingRung: MappingRung;
}

/** The DD-7 refusal: columns were asked of a path that has no source column to record. */
export class ColumnAwarenessUnavailable extends Error {
  readonly writerPath: WriterPath;
  readonly mappingRung: MappingRung;
  constructor(writerPath: WriterPath, mappingRung: MappingRung = RUNG_BYTECODE) {
    super(
      `this recording declares mapping rung ${mappingRung} — ${RUNG_NAME[mappingRung]} — and ` +
        `columns are only recordable at rung ${RUNG_SOURCE}. ` +
        `the tracing configuration asked for column-aware steps and the '${writerPath}' path ` +
        'cannot record them (DD-7). The writer at the pinned trace_format anchor CAN carry ' +
        'columns -- it has a delta-column opcode, a paths.dat Layout A line-length table and ' +
        'meta.dat capability bits 4/6/7 -- and this runtime has no source column to put in ' +
        'them: emit() is on rung 3 of the source-fidelity ladder and records a program counter ' +
        'as Line(pc). Enabling column mode would advertise breakpoint-sharp columns over ' +
        'positions that are program counters. Refusing here rather than producing a container ' +
        'whose columns are a number with nothing behind it. Set columns: false, or wait for the ' +
        'source mapping that gives this runtime a column to record.',
    );
    this.name = 'ColumnAwarenessUnavailable';
    this.writerPath = writerPath;
    this.mappingRung = mappingRung;
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
 *
 * **NOT REACHABLE THROUGH THE MODULE AT THE CURRENT `trace_format` ANCHOR, AND KEPT ANYWAY.**
 * The writer honours a column request now, so `dropped_column_awareness()` answers `false`; the
 * one reachable `true` left in the writer is a request arriving after `begin_writing_trace_events`
 * and `ct_writer_open` makes the call before. This class was M24's backstop for the one bypass
 * that got past the configuration-time gate — a resolved configuration mutated afterwards — and
 * that bypass is closed at configuration time now, by freezing (see `resolveTracingConfig`).
 * It is kept because the signal is still read on every recording and a future module or writer
 * path can still report the loss; what has changed is that it is corroboration rather than
 * enforcement, and nothing may be left resting on it.
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
  // The rung, resolved BEFORE the column gate, because the gate now reads it. Anything that is
  // not exactly 1 or 2 — including `undefined`, a string "1" through a JSON round trip, and a 4 —
  // resolves to rung 3, the pessimistic end. A value comparison, not a type: types are erased.
  const mappingRung: MappingRung =
    config.mappingRung === RUNG_SOURCE || config.mappingRung === RUNG_FUNCTION
      ? config.mappingRung
      : RUNG_BYTECODE;

  // `=== true` rather than truthiness: a caller passing the string "false" through a JSON round
  // trip must not turn the gate off, and a caller passing 1 must not turn it on by accident.
  // The refusal is on the value, so `as any` does not route around it.
  //
  // M25 ADDED THE SECOND CONJUNCT AND IT IS THE ONE THAT MOVES. `CARRIES_COLUMNS` is a fact about
  // the WRITER and it is still `false` for Path A as a default posture; what makes columns
  // recordable is a source position to put in them, and that arrives exactly at rung 1. So the
  // condition a caller must satisfy is "the writer can carry them OR this recording resolves to
  // rung 1" — and both halves need a negative case, which is why
  // `test_trace_metadata_declares_mapping_rung` exercises rung 1 + Path A (allowed), rung 3 +
  // Path A (refused) and a rung-1 claim with no positions supplied (refused at CLOSE, by the
  // module's own tally, which is a different gate in a different place on purpose).
  const recordable = CARRIES_COLUMNS[writerPath] === true || mappingRung === RUNG_SOURCE;
  if (config.columns === true && !recordable) {
    throw new ColumnAwarenessUnavailable(writerPath, mappingRung);
  }
  const resolved: ResolvedTracingConfig = {
    program: config.program,
    recordingId: config.recordingId,
    sourcePath: config.sourcePath,
    workdir: config.workdir,
    columns: config.columns === true,
    writerPath,
    mappingRung,
  };
  RESOLVED.add(resolved);
  // FROZEN, AND THAT IS NOW THE ONLY THING STANDING BEHIND THE GATE.
  //
  // The gate cannot be re-run, so `cfg.columns = true` after the fact used to get a column
  // request all the way into the module — and M24 caught it at CLOSE instead, on the writer's
  // `dropped_column_awareness()`. The `trace_format` anchor moved onto a writer that HONOURS a
  // column request, so that signal answers `false` now and the close-time catch is gone. Leaving
  // it there would be an assertion that cannot fail guarding a bypass that works.
  //
  // `Object.freeze` is not a type and is not erased: these sources run under ESM, which is strict
  // mode, so the assignment throws a `TypeError` at the point of mutation rather than silently
  // doing nothing. That is strictly better than the close-time catch it replaces — the refusal is
  // back at configuration time, where DD-7 says it belongs.
  return Object.freeze(resolved);
}

/** Whether an object came out of {@link resolveTracingConfig}. Identity, not shape. */
export function isResolvedTracingConfig(x: unknown): x is ResolvedTracingConfig {
  return typeof x === 'object' && x !== null && RESOLVED.has(x);
}
