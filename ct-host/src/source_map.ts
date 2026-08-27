// OQ-5's answer, as code: an AVM program counter to an Aztec.nr source position.
//
// ---------------------------------------------------------------------------
// THE MAPPING IS ALREADY KEYED BY AVM PC, AND THAT IS THE WHOLE FINDING.
//
// The path everybody expects is `pc -> Brillig opcode index -> ACIR debug info -> source`, with a
// missing first arrow. It does not exist, because `avm-transpiler` REWRITES the debug info on the
// way through rather than passing it along:
//
//   avm-transpiler/src/transpile.rs:53      brillig_to_avm(...) -> (Vec<u8>, Vec<usize>)
//   avm-transpiler/src/transpile.rs:475     current_avm_pc += <bytes of the emitted instructions>
//   avm-transpiler/src/transpile.rs:1803    patch_debug_info_pcs(debug_infos, brillig_pcs_to_avm_pcs)
//   avm-transpiler/src/transpile_contract.rs:116  the call site, before debug_symbols is stored
//
// so `debug_symbols.debug_infos[0].brillig_locations["0"]` in a shipped artifact is keyed by AVM
// **byte offset** — the same number `execution.cpp:1765` advances the pc by, and the same number
// M9's observation hook reports. There is nothing to reconstruct and nothing to ask upstream for.
//
// The type is still called `BrilligOpcodeLocation` after the rewrite, which is why this is easy to
// miss by grepping. `rungFor` measures the artifact rather than trusting the name.
// ---------------------------------------------------------------------------
//
// WHAT THIS FILE DOES NOT DO, said here so nobody looks for it: it does not decode the artifact's
// `debug_symbols` string. That is `parseDebugSymbols` in `@aztec/stdlib/abi` — deflate-raw plus
// base64 plus JSON — and re-implementing it here would be a second spelling of upstream's own
// encoding, which is the mistake `avm_inputs.ts` records having avoided. A caller passes the
// decoded `DebugInfo` in.

import { RUNG_BYTECODE, RUNG_FUNCTION, RUNG_SOURCE, type MappingRung, type StepPosition } from './abi.ts';

/** Noir's `Location`: a byte span inside one file of the artifact's `file_map`. */
export interface NoirLocation {
  readonly span: { readonly start: number; readonly end: number };
  readonly file: number;
}

/**
 * The subset of Noir's `DebugInfo` this resolver reads, named so a caller can see what is
 * required. Everything else in the struct — `variables`, `types`, `functions`,
 * `brillig_procedure_locs` — is deliberately untouched.
 */
export interface DebugInfoLike {
  /** `{ "<brillig function id>": { "<AVM pc>": <CallStackId> } }`. JSON keys, so strings. */
  readonly brillig_locations: Record<string, Record<string, number>>;
  /**
   * `CallStackId -> { parent, children, locations }` or upstream's array spelling. Read through
   * {@link locationsOf} so both shapes work; a shape neither matches is reported, not guessed at.
   */
  readonly location_tree?: unknown;
}

/** One file of the artifact's `file_map`. */
export interface SourceFile {
  readonly path: string;
  readonly source: string;
}

/** Why a contract is on the rung it is on. Never a bare number — see `declareRung`'s doc. */
export interface RungVerdict {
  readonly rung: MappingRung;
  readonly reason: string;
  /** How many `(pc -> location)` entries were found. `0` at rung 3. */
  readonly mappedPcs: number;
  /** The pc range the map covers, or `null` when it covers nothing. */
  readonly pcRange: { readonly min: number; readonly max: number } | null;
}

/**
 * A file's source text turned into the `line_lengths` table the column-aware step encoder needs.
 *
 * `lineLengths[i]` is the number of addressable columns on line `i + 1`, and it is
 * `characters + 1` rather than `characters`: the position one past the end of a line is a real
 * place a cursor can be, and the spec's Layout A says implementations may address it. A table that
 * stopped at the last character would make a column on the final position of a line unaddressable,
 * which shows up as a step silently clamped to the column before it.
 */
export function lineLengths(source: string): number[] {
  const lines = source.split('\n');
  return lines.map(l => l.length + 1);
}

/**
 * A byte offset in a source file, as a 1-based `(line, column)`.
 *
 * **THE OFFSET IS A BYTE OFFSET AND `String` IS UTF-16, AND THIS FUNCTION SAYS SO RATHER THAN
 * PRETENDING OTHERWISE.** Noir's `Span` is a byte range (`noirc_span/src/position.rs`), while a
 * JavaScript string is indexed in UTF-16 code units; the two agree exactly on ASCII and diverge on
 * anything else. Upstream's own TypeScript resolver (`simulator/src/common/errors.ts:120-127`) uses
 * `substring` and has the same divergence, and Noir's Rust reporter iterates `chars()` against a
 * byte offset and has a third. Rather than inherit a bug from either, the offset is converted
 * through the file's UTF-8 bytes, so the answer is right for non-ASCII source and identical to
 * both of them for ASCII.
 */
export function lineColumnOf(source: string, byteOffset: number): { line: number; column: number } {
  const bytes = new TextEncoder().encode(source);
  const clamped = Math.max(0, Math.min(byteOffset, bytes.length));
  let line = 1;
  let lineStart = 0;
  for (let i = 0; i < clamped; i++) {
    if (bytes[i] === 0x0a) {
      line += 1;
      lineStart = i + 1;
    }
  }
  // Decode only the prefix of the current line, so the column counts CHARACTERS on that line and
  // matches what `lineLengths` measured over the same text.
  const prefix = new TextDecoder().decode(bytes.subarray(lineStart, clamped));
  return { line, column: prefix.length + 1 };
}

/**
 * The `NoirLocation[]` a `CallStackId` names, **outermost first, innermost last**.
 *
 * THE SHAPE IS A PARENT-LINKED ARENA, NOT A LIST PER ID, AND THAT WAS ESTABLISHED BY LOOKING AT AN
 * ARTIFACT RATHER THAN BY READING THE TYPE NAME. `location_tree` is
 * `{ locations: [ { parent: number | null, value: Location }, … ] }`, indexed by `CallStackId`, and
 * an inlined frame is recovered by walking `parent` to the root. A resolver that took
 * `locations[id]` and stopped would still produce a plausible line for every pc — the innermost
 * one — while silently discarding the inlining chain that says which Aztec.nr function the step is
 * really in. That is the difference between rung 1 and something that looks like it.
 *
 * A flat `Location[]` indexed by id is accepted too, because that spelling exists. **Anything
 * else is REPORTED rather than treated as "no locations"**, because an unrecognised tree and an
 * empty one are the same value and only one of them is a fact about the contract. This is the
 * "print the residue" rule: a scanner that cannot place its input must say so.
 *
 * A cycle in `parent` — which cannot happen in a well-formed arena and would hang this walk —
 * terminates at the node count rather than spinning.
 */
export function locationsOf(tree: unknown, id: number): NoirLocation[] | 'unrecognised-tree' {
  if (tree === null || tree === undefined) return [];
  const nodes = Array.isArray(tree)
    ? (tree as unknown[])
    : Array.isArray((tree as Record<string, unknown>).locations)
      ? ((tree as Record<string, unknown>).locations as unknown[])
      : null;
  if (nodes === null) return 'unrecognised-tree';
  if (!Number.isInteger(id) || id < 0 || id >= nodes.length) return [];
  const chain: NoirLocation[] = [];
  let cursor: number | null = id;
  for (let guard = 0; cursor !== null && guard <= nodes.length; guard++) {
    const node = nodes[cursor] as Record<string, unknown> | undefined;
    if (node === undefined) break;
    const value = (node.value ?? node) as NoirLocation;
    if (value === null || typeof value !== 'object' || typeof (value as NoirLocation).file !== 'number') {
      return 'unrecognised-tree';
    }
    chain.push(value);
    const parent = node.parent;
    cursor = typeof parent === 'number' ? parent : null;
  }
  // Collected innermost-first while walking up; the caller wants innermost LAST.
  return chain.reverse();
}

/**
 * Which rung a contract's artifact supports, measured from the artifact.
 *
 * The measurement, and the reason each one is here rather than a `!!debugInfo` test:
 *
 *  - **no debug info at all** -> rung 3. Nothing to resolve from.
 *  - **an EMPTY `brillig_locations`** -> rung 3, and separately, because "the artifact has debug
 *    symbols" and "the debug symbols map anything" are different claims and only the second one
 *    lets a step find a line. An artifact stripped by a release build satisfies the first.
 *  - **a map whose maximum key exceeds the bytecode length** -> rung 3 with a NAMED reason, because
 *    that is what a map still keyed by Brillig opcode INDEX would NOT look like and what a map
 *    keyed by AVM byte offset must satisfy. It is the cheap version of the transpiler check, run
 *    per artifact, and it is the assertion that would go red the day upstream stops re-keying.
 *  - **no source text for the files it points at** -> rung 2. The pcs map to spans; without the
 *    file's text a span cannot become a line and a column, so what survives is attribution and not
 *    stepping. This is the rung that exists precisely so a partial answer is not rounded up.
 *  - otherwise -> rung 1.
 */
export function rungFor(
  debugInfo: DebugInfoLike | null | undefined,
  bytecodeLength: number,
  files: ReadonlyMap<number, SourceFile> | null | undefined,
): RungVerdict {
  if (!debugInfo || typeof debugInfo !== 'object' || !debugInfo.brillig_locations) {
    return {
      rung: RUNG_BYTECODE,
      reason: 'the contract artifact carries no debug_symbols, so a pc has no source to map to',
      mappedPcs: 0,
      pcRange: null,
    };
  }
  const fnIds = Object.keys(debugInfo.brillig_locations);
  const entries: number[] = [];
  for (const fnId of fnIds) {
    for (const k of Object.keys(debugInfo.brillig_locations[fnId] ?? {})) {
      const n = Number(k);
      if (Number.isInteger(n)) entries.push(n);
    }
  }
  if (entries.length === 0) {
    return {
      rung: RUNG_BYTECODE,
      reason: 'the debug_symbols are present but brillig_locations is empty, so no pc maps anywhere',
      mappedPcs: 0,
      pcRange: null,
    };
  }
  const min = Math.min(...entries);
  const max = Math.max(...entries);
  if (bytecodeLength > 0 && max >= bytecodeLength) {
    return {
      rung: RUNG_BYTECODE,
      reason:
        `the debug_symbols' highest key is ${max} and the transpiled bytecode is ${bytecodeLength} `
        + 'bytes, so the map is NOT keyed by AVM byte offset — most likely still keyed by Brillig '
        + 'opcode index, which is what avm-transpiler re-keys away from in patch_debug_info_pcs',
      mappedPcs: entries.length,
      pcRange: { min, max },
    };
  }
  if (!files || files.size === 0) {
    return {
      rung: RUNG_FUNCTION,
      reason:
        `${entries.length} pc(s) map to source spans, but no file_map source text was supplied, so `
        + 'a span cannot become a line and a column — attribution without stepping',
      mappedPcs: entries.length,
      pcRange: { min, max },
    };
  }
  return {
    rung: RUNG_SOURCE,
    reason:
      `${entries.length} pc(s) in [${min}, ${max}] map to source spans over ${files.size} file(s), `
      + 'and avm-transpiler re-keys brillig_locations by AVM byte offset (transpile.rs:1803), so '
      + 'each is a real (path, line, column)',
    mappedPcs: entries.length,
    pcRange: { min, max },
  };
}

/**
 * A per-contract resolver: give it a pc, get back the position to stage beside that step.
 *
 * `internPath` is injected rather than imported, so this class does not need a `CtWriter` and can
 * be exercised on its own — which is what lets the check drive it against a real Aztec artifact
 * with no wasm module instantiated at all.
 */
export class ContractSourceMap {
  readonly verdict: RungVerdict;
  private readonly byPc: Map<number, number>;
  private readonly tree: unknown;
  private readonly files: ReadonlyMap<number, SourceFile>;
  private readonly pathIds = new Map<number, number>();
  private readonly internPath: (path: string, lineLengths: readonly number[]) => number;
  private unrecognisedTree = 0;
  private missingFile = 0;

  constructor(
    debugInfo: DebugInfoLike | null | undefined,
    bytecodeLength: number,
    files: ReadonlyMap<number, SourceFile>,
    internPath: (path: string, lineLengths: readonly number[]) => number,
  ) {
    this.verdict = rungFor(debugInfo, bytecodeLength, files);
    this.tree = debugInfo?.location_tree;
    this.files = files;
    this.internPath = internPath;
    this.byPc = new Map();
    for (const fnId of Object.keys(debugInfo?.brillig_locations ?? {})) {
      for (const [k, v] of Object.entries(debugInfo!.brillig_locations[fnId] ?? {})) {
        const pc = Number(k);
        if (Number.isInteger(pc)) this.byPc.set(pc, v);
      }
    }
  }

  /** `(pc -> location)` entries this map holds. */
  get size(): number {
    return this.byPc.size;
  }

  /** Call-stack nodes whose shape neither spelling recognised. Non-zero is a finding. */
  get unrecognisedTreeNodes(): number {
    return this.unrecognisedTree;
  }

  /** Locations naming a file the `file_map` does not contain. Non-zero is a finding. */
  get missingFileReferences(): number {
    return this.missingFile;
  }

  /**
   * The position for one pc, or `null` when this pc has none.
   *
   * `null` is not an error and is not rounded to a neighbouring line. A pc inside a compiled
   * PROCEDURE has no entry at all — procedures are appended after the main body
   * (`transpile.rs:489,505`), past the end of `brillig_pcs_to_avm_pcs` — and answering with the
   * nearest lower line would put a step in a function it is not in. The caller stages a `line: 0`
   * slot for it, which is what makes the difference visible in `stepsUnpositioned`.
   */
  positionFor(pc: number): StepPosition | null {
    const callStackId = this.byPc.get(pc);
    if (callStackId === undefined) return null;
    const locs = locationsOf(this.tree, callStackId);
    if (locs === 'unrecognised-tree') {
      this.unrecognisedTree += 1;
      return null;
    }
    // Innermost last: the frame the pc is physically in, which is where a stepper should stop.
    const loc = locs.length > 0 ? locs[locs.length - 1]! : undefined;
    if (loc === undefined) return null;
    const file = this.files.get(loc.file);
    if (file === undefined) {
      this.missingFile += 1;
      return null;
    }
    const pathId = this.pathIdFor(loc.file, file);
    const { line, column } = lineColumnOf(file.source, loc.span.start);
    return { pathId, line, column };
  }

  private pathIdFor(fileId: number, file: SourceFile): number {
    const known = this.pathIds.get(fileId);
    if (known !== undefined) return known;
    const id = this.internPath(file.path, lineLengths(file.source));
    this.pathIds.set(fileId, id);
    return id;
  }
}
