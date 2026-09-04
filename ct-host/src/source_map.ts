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

/**
 * One entry of a `file_map` file's `function_locations`.
 *
 * **THERE IS NO `end`, AND THAT IS UPSTREAM'S SHAPE, NOT AN OMISSION HERE.** Noir writes
 * `{ name, start }` and nothing else — measured over `FeeJuice.json`, 726 entries across 32 files,
 * every one of them two-keyed. So "which function contains this offset" can only be answered as
 * "the last function that BEGAN at or before it", and {@link ContractSourceMap.framesFor} says so
 * rather than inventing a span. An offset before the first function of a file has no name at all
 * and is reported as such instead of being attributed to a neighbour.
 */
export interface FunctionLocation {
  readonly name: string;
  readonly start: number;
}

/** One file of the artifact's `file_map`. */
export interface SourceFile {
  readonly path: string;
  readonly source: string;
  /**
   * `file_map[i].function_locations`, when the caller passes it. Optional because every existing
   * caller predates it and `positionFor` does not need it; supplying it is what turns
   * {@link ContractSourceMap.framesFor}'s frames from anonymous into NAMED.
   */
  readonly functionLocations?: readonly FunctionLocation[];
}

/**
 * One frame of the Noir inline call stack a pc sits in — what a reader sees as a stack entry.
 *
 * `key` IS THE FRAME'S IDENTITY AND IT IS THE CONTAINING FUNCTION, NOT THE LOCATION. This is the
 * distinction the whole frame loop turns on. A chain element is a call SITE, and its offset moves
 * with every statement executed in that function; diffing on the location would therefore close and
 * reopen the innermost frame on every single step and produce a call tree with one frame per
 * instruction. Diffing on `(file, start-of-containing-function)` is stable across the statements of
 * a function and changes exactly when execution enters or leaves one, which is what a frame is.
 */
export interface NoirFrame {
  /** `(file id, containing function start)`, or `(file id, -1)` where no function contains it. */
  readonly key: string;
  /** The Noir function name, e.g. `FeeJuice::_increase_public_balance`. */
  readonly name: string;
  /** Interned path id for the file this frame's code is in. */
  readonly pathId: number;
  /** 1-based line of this frame's CURRENT position — the call site, or the statement if innermost. */
  readonly line: number;
  readonly column: number;
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
/**
 * Noir's `Location::dummy()` — file 0, empty span at offset 0 — which is what a `location_tree`
 * arena's root holds. It is a sentinel and not a position in any file.
 *
 * `locationsOf` returns it, deliberately: this predicate is a judgement about what a chain MEANS,
 * and `locationsOf`'s job is to report the tree's shape faithfully so that a caller that wants the
 * raw walk still gets it. {@link ContractSourceMap.framesFor} is the caller that drops it.
 */
export function isDummyLocation(loc: NoirLocation): boolean {
  return loc.file === 0 && loc.span.start === 0 && loc.span.end === 0;
}

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
  /** Per-file `function_locations`, sorted by `start`, built on first use. */
  private readonly fnTables = new Map<number, readonly FunctionLocation[]>();
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

  /**
   * The NOIR CALL STACK a pc sits in, outermost first — or `null` when this pc has none.
   *
   * ---------------------------------------------------------------------------------------------
   * THIS IS THE CHAIN `positionFor` THROWS AWAY, AND THROWING IT AWAY WAS THE WHOLE DEFECT.
   *
   * `positionFor` calls the same {@link locationsOf} and then keeps `locs[locs.length - 1]` — the
   * innermost location, which is the right answer for "what line is this step on" and is a
   * catastrophic answer for "what function is this step in". Everything needed to open a real frame
   * was already parsed and discarded on that one line. `framesFor` keeps it.
   *
   * ---------------------------------------------------------------------------------------------
   * EVERY ELEMENT OF THE CHAIN IS A FRAME, EXCEPT THE SENTINEL AT THE BOTTOM.
   *
   * A `location_tree` chain is `[outermost call site, …, innermost statement]`. Element `k` is the
   * position CURRENTLY EXECUTING in frame `k`: for `k < n-1` that is the call site at which frame
   * `k+1` was inlined, and for `k = n-1` it is the statement itself. So the locations are the
   * frames, named by the function each one falls inside.
   *
   * **EXCEPT THE ROOT, WHICH IS NOIR'S DUMMY LOCATION AND IS NOT A PLACE IN ANY PROGRAM.** Measured
   * on `@aztec/protocol-contracts@5.3.0-nightly.20260819`'s FeeJuice: `location_tree` has 155 nodes
   * and exactly ONE of them has `parent: null` — node 0, whose value is
   * `{ file: 0, span: { start: 0, end: 0 } }` — and all 314 keyed pcs bottom out at it. That is
   * `Location::dummy()`, the arena's root, not a call site. File 0 in that artifact happens to be
   * `std/aes128.nr`, so keeping it puts a frame named for the AES implementation underneath every
   * stack in a fee-juice transfer — which is how this was caught, because the tree printed with a
   * root nobody could explain.
   *
   * So a leading dummy is dropped, by VALUE and not by position: `file 0` with an empty span at
   * offset 0. A chain that is nothing but the sentinel yields `null` — no frames, rather than one
   * meaningless one.
   * ---------------------------------------------------------------------------------------------
   */
  framesFor(pc: number): NoirFrame[] | null {
    const callStackId = this.byPc.get(pc);
    if (callStackId === undefined) return null;
    const locs = locationsOf(this.tree, callStackId);
    if (locs === 'unrecognised-tree') {
      this.unrecognisedTree += 1;
      return null;
    }
    if (locs.length === 0) return null;
    // Drop the arena's dummy root. See the doc above for the measurement this rests on.
    const chain = isDummyLocation(locs[0]!) ? locs.slice(1) : locs;
    if (chain.length === 0) return null;
    const frames: NoirFrame[] = [];
    for (const loc of chain) {
      const file = this.files.get(loc.file);
      if (file === undefined) {
        this.missingFile += 1;
        return null;
      }
      const pathId = this.pathIdFor(loc.file, file);
      const { line, column } = lineColumnOf(file.source, loc.span.start);
      const fn = this.functionAt(loc.file, file, loc.span.start);
      frames.push({
        key: `${loc.file}:${fn.start}`,
        name: fn.name,
        pathId,
        line,
        column,
      });
    }
    return frames;
  }

  /**
   * The function containing a byte offset: the last one that BEGAN at or before it.
   *
   * See {@link FunctionLocation} for why that is the only question `function_locations` can answer.
   * An offset before the file's first function — or a file whose `function_locations` the caller did
   * not supply — yields `start: -1` and the file's basename as the name, so the frame is still a
   * frame and is still distinguishable, rather than being silently merged into a neighbour.
   */
  private functionAt(fileId: number, file: SourceFile, offset: number): { name: string; start: number } {
    let table = this.fnTables.get(fileId);
    if (table === undefined) {
      table = [...(file.functionLocations ?? [])].sort((a, b) => a.start - b.start);
      this.fnTables.set(fileId, table);
    }
    // Greatest `start <= offset`, by binary search.
    let lo = 0;
    let hi = table.length - 1;
    let found = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (table[mid]!.start <= offset) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (found < 0) {
      const base = file.path.slice(file.path.lastIndexOf('/') + 1);
      return { name: base, start: -1 };
    }
    return { name: table[found]!.name, start: table[found]!.start };
  }

  private pathIdFor(fileId: number, file: SourceFile): number {
    const known = this.pathIds.get(fileId);
    if (known !== undefined) return known;
    const id = this.internPath(file.path, lineLengths(file.source));
    this.pathIds.set(fileId, id);
    return id;
  }
}
