// recording.ts — L3: A SETTLED TRANSACTION BECOMES A `.ct` CONTAINER THAT STEPS.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// L5 CHANGED THE HEADLINE OF THIS FILE, AND THE PARAGRAPH IT REPLACED WAS NOT WRONG.
//
// This header used to open: *"A RECORDING OF A CHAIN-FETCHED CONTRACT CAN ONLY EVER REACH RUNG
// 3."* Everything under that sentence is still true — an Aztec node serves
// `{ id, privateFunctionsRoot, version, artifactHash, packedBytecode }` and no debug symbols, no
// file map and no source text, and that is protocol design rather than omission. What the sentence
// left implicit is the word **FROM THE NODE**, and the version of it that travelled to two other
// repositories dropped even that: `blocktracer`'s `chain/ingest.nim` and `tools/chain/
// capture-chain.mjs` each restated it as *"the ceiling a chain contract can reach"*, unqualified.
// L5 corrected both, because an unqualified ceiling is a claim about the product and this one was
// a claim about one interface.
//
// **THE RUNG IS NOW MEASURED PER CONTRACT, PER TRANSACTION, AND IT IS 1 WHEN — AND ONLY WHEN — AN
// OFF-CHAIN ARTIFACT HAS BEEN PROVED TO BE THE ONE THE CLASS COMMITS TO AND EVERY EXECUTED STEP OF
// THAT CONTRACT RESOLVED TO A `(path, line, column)`.** The proof is `artifact_resolution.ts`'s:
// `computeArtifactHash` equality, byte-equality of the public bytecode, and recomputation of the
// class id. A contract with no proved artifact is still rung 3, still carries
// {@link CHAIN_CONTRACT_RUNG_CEILING_REASON} verbatim, and still writes not one positioned step —
// which is the half of this change that matters most, because a partial rollout that made
// unresolved transactions LOOK source-level would be strictly worse than the honest ceiling it
// replaced.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// WHAT THE ORIGINAL PARAGRAPH SAID, KEPT BECAUSE IT IS THE ARGUMENT THE UNRESOLVED CASE STILL
// RESTS ON: **A RECORDING OF A CHAIN-FETCHED CONTRACT CANNOT REACH RUNG 1 OR 2 FROM THE NODE.**
//
// M25's ladder (`SOURCE-MAPPING.md`, and `ct-host/src/abi.ts`'s three constants):
//
//   rung 1  SOURCE    — `(path, line, column)` per instruction. Needs the artifact's
//                       `debug_symbols` (brillig_locations keyed by AVM byte offset) AND its
//                       `file_map` WITH SOURCE TEXT.
//   rung 2  FUNCTION  — a position per frame. Needs `debug_symbols` and no source text.
//   rung 3  BYTECODE  — `Line(pc)`. Needs nothing beyond the bytecode.
//
// **AN AZTEC NODE SERVES NONE OF THE INPUTS FOR RUNG 1 OR RUNG 2, AND THAT IS PROTOCOL DESIGN
// RATHER THAN AN OMISSION.** Read at the pinned nightly, in upstream's own declarations:
//
//   `@aztec/stdlib/contract/interfaces/contract_class.d.ts`
//     export type ContractClassPublic =
//       Pick<ContractClassCommitments, 'id' | 'privateFunctionsRoot'>
//       & Omit<ContractClass, 'privateFunctions'>;
//
//   …and `ContractClass` declares exactly FOUR fields: `version`, `artifactHash`,
//   `privateFunctions`, `packedBytecode`. So everything a node can give us about a contract's code
//   is `{ id, privateFunctionsRoot, version, artifactHash, packedBytecode }`. **There is no
//   `debug_symbols`, no `file_map`, no function table and no source text anywhere in it**, and
//   `getContractClass` returns exactly this type.
//
//   Upstream says so itself, in `artifactHash`'s own doc comment: "Intended to be used by clients
//   to verify that an OFFCHAIN FETCHED ARTIFACT matches a registered class." The artifact is
//   expected to come from somewhere else. The chain holds a COMMITMENT to it and not the thing.
//
//   And it is not hiding on another method: `AztecNode`'s whole interface declaration contains ZERO
//   occurrences of `Artifact`, `debug`, `DebugInfo` or `file_map`. L0 enumerated all fifty-five
//   methods; none of them serves one.
//
// **SO THE RUNG IS DECLARED AS 3, LOUDLY, WITH THAT REASON, AND IT IS NEVER SILENTLY DEGRADED.**
// The milestone's own words are "rung declared per contract, never silently degraded", and this is
// the case that phrase was written for: a recording that declared rung 1 and quietly shipped
// unpositioned steps would be a debugger that says it has your source and does not. The writer
// enforces it from the other side too — a rung-1 declaration whose steps arrive unpositioned is
// counted as a violation and `CtWriter.close()` throws `MappingRungDegraded`.
//
// WHAT LIFTS IT, and **L5 BUILT IT**: obtaining the compiled artifact OFF-CHAIN — from the npm
// package or a published artifact registry — and verifying it against `artifactHash`, which is
// exactly what upstream says that field is for. `artifact_resolution.ts` is that resolution and
// `artifact_providers.ts` is where the artifacts come from. **This paragraph read "Nothing in this
// repository does that resolution today" until L5, and that sentence is what two other
// repositories quoted as a ceiling on the product.**
//
// The lift is real and it is NARROW, which the recording says rather than glosses. Measured
// 2026-09-01 over this campaign's frozen captures: **one of six testnet containers** resolves —
// FeeJuice at `0x…03`, class `0x1f85d8b9…`, served by `@aztec/protocol-contracts` — and **none of
// two mainnet containers** does, because neither of their third-party classes has a published or
// explorer-verified artifact anywhere. So this is a capability change and not a
// visible-everywhere one, and every transaction that does not resolve says rung 3 exactly as it
// did before.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE STEP STREAM IS THE AVM'S OWN, AND THERE IS NO OTHER PATH ON PURPOSE.
//
// The milestone: "the executed step stream from M9's hook — NOT a walk of the artifact's debug map.
// The sibling campaign shipped mapped pcs with a synthesised opcode field once and its own review
// caught it; the fabricating path was deleted rather than kept as a fallback."
//
// Here the fabricating path is not merely deleted, it is unavailable: there is no debug map to walk.
// What this module refuses is the three ways the real stream can be absent or wrong, each named:
//
//   * `null` — collection was OFF. A DIFFERENT STATEMENT from "there were none", which is why
//     `stepsFromOutcome` returns null rather than `[]` and why this module does not collapse them.
//   * empty — the transaction executed nothing. A container over zero steps is a well-formed
//     artefact of a subject that did not run: this campaign's founding defect, exactly.
//   * a COUNT DISAGREEMENT — the AVM's own `total_instructions_executed` and the number of records
//     decoded must be equal. They are two readings of one thing, and a disagreement means records
//     were lost on the way out. A container written over a partial stream reads as a shorter
//     program rather than as a failed drain.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// AND THE RECORDING CARRIES THE ROOT DIVERGENCE, WHICH IS THE POINT L2 HANDED L3.
//
// L2: "a recording carrying the chain's state reference beside an execution that ran against a
// genesis-anchored tree would be exactly the wrong root that everything downstream believes. L3
// must render this, not hide it."
//
// So `ct.merkle-root-divergence` is written into the container, with all four pairs and the reason,
// and it is NOT optional — `buildSettledRecording` writes it unconditionally from the outcome's own
// declaration. A recording that carried block coordinates and omitted this would be strictly more
// misleading than one that carried neither, because the coordinates invite the reader to believe
// the state matched.

import type { ExecutionStep } from '../../node-host/src/steps.ts';
import type { ContractSourceMap } from '../../ct-host/src/source_map.ts';
import type { StepPosition } from '../../ct-host/src/abi.ts';

import type { SourceCorroboration } from './artifact_resolution.ts';
import { PINNED_PROTOCOL_VERSION } from './pinned_protocol_version.ts';
import type { SettledTransaction } from './settled_transaction.ts';
import type { ReplayOutcome } from './replay_execution.ts';

// ---------------------------------------------------------------------------------------------
// The metadata keys, declared once
// ---------------------------------------------------------------------------------------------

/**
 * Every `TraceLogEvent` key this module writes.
 *
 * DECLARED AS A SET so a check can assert the container holds exactly these and not "at least"
 * these — M29's `ct.step-producer` is the precedent. A key added without being declared here is a
 * record no reader knows to look for, and a key declared and not written is a promise the
 * container does not keep; the check asserts both directions.
 */
export const RECORDING_METADATA_KEYS = {
  /** Which producer wrote the stream, and how many records it carried. M29's key, reused. */
  stepProducer: 'ct.step-producer',
  /** Block number, transaction hash, node URL, protocol version. The milestone's own list. */
  chainProvenance: 'ct.chain-provenance',
  /** THE ROOTS ARE NOT THE CHAIN'S. L2's handoff, rendered rather than hidden. */
  rootDivergence: 'ct.merkle-root-divergence',
  /** The private half is unavailable IN PRINCIPLE. L1's declaration, in the artefact. */
  privateHalf: 'ct.private-half',
  /** Why the rung is 3 and cannot be higher for a chain-fetched contract WITHOUT A PROVED ARTIFACT. */
  sourceMapping: 'ct.source-mapping-ceiling',
  /**
   * L5's key: where each contract's source came from, and what the chain does and does not commit
   * to about it.
   *
   * **WRITTEN UNCONDITIONALLY, INCLUDING WHEN NOTHING RESOLVED.** A key that appeared only on
   * source-level recordings would make its own absence ambiguous — a reader could not tell a
   * transaction whose artifacts were never looked for from one whose artifacts were looked for and
   * not found, and those are the two states this whole milestone is about telling apart.
   */
  sourceProvenance: 'ct.source-provenance',
} as const;

export type RecordingMetadataKey =
  (typeof RECORDING_METADATA_KEYS)[keyof typeof RECORDING_METADATA_KEYS];

/** The producer name, so a container says which code wrote it rather than only that something did. */
export const REPLAY_STEP_PRODUCER = 'aztec-live-chain-replay/L3';

/**
 * Why a chain-fetched contract WITH NO PROVED OFF-CHAIN ARTIFACT cannot exceed rung 3. Written into
 * the container AND used as the `declareRung` reason for exactly those contracts, so the two cannot
 * drift.
 *
 * **UNCHANGED BY L5 EXCEPT IN ITS LAST SENTENCE, DELIBERATELY.** Every clause about what
 * `ContractClassPublic` carries is still the measurement it was, and it is still the whole reason
 * an unresolved contract stays at instruction level. What changed is that the escape hatch it
 * describes is now built, so the sentence claiming it is not is gone.
 */
export const CHAIN_CONTRACT_RUNG_CEILING_REASON =
  'RUNG 3 (BYTECODE) IS THE CEILING FOR A CHAIN-FETCHED CONTRACT, BY PROTOCOL DESIGN AND NOT BY '
  + 'OMISSION. Rungs 1 and 2 need the compiled artifact\'s debug_symbols, and rung 1 additionally '
  + 'needs its file_map WITH SOURCE TEXT. An Aztec node serves neither: getContractClass returns '
  + 'ContractClassPublic, which is exactly { id, privateFunctionsRoot, version, artifactHash, '
  + 'packedBytecode } — no debug symbols, no file map, no function table, no source. Upstream\'s '
  + 'own doc comment on artifactHash says it is "intended to be used by clients to verify that an '
  + 'OFFCHAIN FETCHED ARTIFACT matches a registered class", i.e. the chain holds a commitment to '
  + 'the artifact and not the artifact. No method on AztecNode serves one either. THAT OFF-CHAIN '
  + 'RESOLUTION IS BUILT (replay/src/artifact_resolution.ts) AND IT WAS RUN FOR THIS CONTRACT AND '
  + 'PROVED NOTHING: no candidate artifact matched this class\'s artifactHash, its packedBytecode '
  + 'and its class id, so there is no debug map to position a program counter with and the rung is '
  + '3. See ct.source-provenance in this container for which sources were asked and what each '
  + 'answered.';

// ---------------------------------------------------------------------------------------------
// The refusals
// ---------------------------------------------------------------------------------------------

/** The three ways the executed stream can be unusable, each named rather than collapsed. */
export const STEP_STREAM_FAULTS = ['collection-off', 'empty', 'count-disagreement'] as const;
export type StepStreamFault = (typeof STEP_STREAM_FAULTS)[number];

/**
 * The executed step stream is not something a container may be written over.
 *
 * A THROW, never a shorter recording. The sibling campaign's own history is the argument: a
 * transaction that reverted at its first instruction passed a milestone, its review, and a second
 * milestone's floors, because every artefact around it was well-formed.
 */
export class ExecutedStepsUnusable extends Error {
  readonly kind = 'replay-executed-steps-unusable' as const;
  readonly fault: StepStreamFault;
  readonly txHash: string;

  constructor(fault: StepStreamFault, txHash: string, detail: string) {
    super(
      `refusing to write a .ct for ${txHash}: ${ExecutedStepsUnusable.explain(fault)} (${detail}) `
        + `A container written here would be well-formed and would read as a program that did `
        + `less than it did, which is indistinguishable from a program that did less than it `
        + `should have.`,
    );
    this.name = 'ExecutedStepsUnusable';
    this.fault = fault;
    this.txHash = txHash;
  }

  static explain(fault: StepStreamFault): string {
    switch (fault) {
      case 'collection-off':
        return 'the result carries no executionSteps at all, which means collection was OFF — a '
          + 'different statement from "there were no steps", and the one that means the '
          + 'configuration is wrong rather than the transaction empty.';
      case 'empty':
        return 'the stream is present and EMPTY, so the transaction executed no instructions.';
      case 'count-disagreement':
        return 'the AVM\'s own instruction count and the number of decoded records disagree, so '
          + 'records were lost between the module and here.';
    }
  }
}

// ---------------------------------------------------------------------------------------------
// The writer, structurally
// ---------------------------------------------------------------------------------------------

/**
 * The narrow view of `ct-host`'s `CtWriter` this module needs.
 *
 * STRUCTURAL, for the reason `ReplayAvmHost` is: `ct-host` has no dependencies and runs identically
 * in Node and in a browser, so L4's browser path supplies the same class through a different
 * loader. A nominal type would make that a rewrite; declaring the five methods used makes the
 * dependency a citation.
 */
export interface RecordingWriter {
  declareRung(contractAddress: Uint8Array, rung: number, reason: string): void;
  call(name: string, opts: { pathId?: number; line?: number; contractAddress?: Uint8Array }): void;
  returnFrame(): void;
  /**
   * L5 added the second argument, and `ct-host`'s own `push` has taken it since M25.
   *
   * OPTIONAL AT THE CALL SITE AND NOT AT THE SLOT: the writer stages a `line: 0` record for an
   * absent position once any real position has appeared, because the two FIFOs are paired by ORDER
   * and a skipped slot would slide every later step in the batch onto an earlier step's line. So a
   * recording with no resolved contract passes `undefined` for every step and writes byte-for-byte
   * what L3 wrote.
   */
  push(event: Record<string, unknown>, position?: StepPosition): void;
  logEvent(metadata: string, content: string): void;
  close(): {
    container: Uint8Array;
    events: number;
    callsOpened: number;
    logEvents: number;
    stepsPositioned: number;
    stepsUnpositioned: number;
    writerKind: number;
  };
}

/** `ct-host`'s `RUNG_BYTECODE`, restated here so this module does not import for one integer. */
export const RUNG_BYTECODE_VALUE = 3;
/** `ct-host`'s `RUNG_FUNCTION`. L5 needs it for the partially-mapped case. */
export const RUNG_FUNCTION_VALUE = 2;
/** `ct-host`'s `RUNG_SOURCE`. L5 needs it for the case this milestone exists to produce. */
export const RUNG_SOURCE_VALUE = 1;

// ---------------------------------------------------------------------------------------------
// L5: the resolved artifact, as this module needs it
// ---------------------------------------------------------------------------------------------

/**
 * One contract's proved artifact, reduced to what a recording does with it.
 *
 * The proof itself is `artifact_resolution.ts`'s and this module does NOT re-check it — for the
 * reason `settled_transaction.ts` gives about resolution stages: a second, weaker copy of a check
 * is how two answers to one question get shipped. What this module does is measure the rung the
 * EXECUTION reached with it, which is a different question and the one the container declares.
 */
export interface ResolvedContractSource {
  /** `0x…`, as `SettledTransaction.contracts[].address` spells it. */
  readonly address: string;
  /** Built over the artifact's own `debug_symbols` and `file_map`, interning into this writer. */
  readonly map: ContractSourceMap;
  /** `artifact_resolution.ts`'s `reason` — the three checks and what they compared. */
  readonly proof: string;
  /** Whether one distributor attests the source text, or two. See `SOURCE_CORROBORATION`. */
  readonly corroboration: SourceCorroboration;
  /** `npm:@aztec/protocol-contracts@… FeeJuice`, for the provenance record. */
  readonly origin: string;
}

/** What the recording declared for one contract, measured rather than assumed. */
export interface ContractRungDeclaration {
  readonly address: string;
  readonly rung: number;
  readonly reason: string;
  /** Executed steps attributed to this contract. */
  readonly steps: number;
  /** …of which resolved to a `(path, line, column)`. */
  readonly positioned: number;
  /** The first pc of this contract that did not resolve, or `null`. */
  readonly firstUnpositionedPc: number | null;
  readonly resolved: boolean;
}

// ---------------------------------------------------------------------------------------------
// The build
// ---------------------------------------------------------------------------------------------

export type SettledRecording = {
  readonly container: Uint8Array;
  readonly bytes: number;
  readonly events: number;
  readonly callsOpened: number;
  readonly logEvents: number;
  readonly stepsPositioned: number;
  readonly stepsUnpositioned: number;
  readonly writerKind: number;
  /**
   * The recording's OWN rung, and L5 made it a derived figure rather than a constant.
   *
   * It is the WORST rung declared for any contract this transaction executed — so a transaction
   * with one resolved contract and one unresolved one reports 3, not 1. Rounding it up to the best
   * would be the "partial rollout that makes unresolved transactions look source-level" this
   * milestone is forbidden from shipping; the per-contract truth is in
   * {@link SettledRecording.contractRungs} and in the container's own `ct.mapping-rung` events.
   */
  readonly declaredRung: number;
  /**
   * L5: one declaration per contract, measured over that contract's own executed steps.
   *
   * The container carries these too, as `ct.mapping-rung` `TraceLogEvent`s. They are returned as
   * well because a caller — the capture tool, and through it the explorer — needs them without
   * re-reading the container it has just been handed.
   */
  readonly contractRungs: readonly ContractRungDeclaration[];
  /**
   * Whether this transaction may be presented as source-level: EVERY contract it executed reached
   * rung 1.
   *
   * A CONJUNCTION AND NOT A DISJUNCTION. `blocktracer`'s `execution.sourceLevel` puts the
   * debugger's source pane on or off for the whole trace, and a pane that renders source for one
   * frame and invents it for the next is worse than one that renders none.
   */
  readonly sourceLevel: boolean;
  readonly steps: number;
  readonly distinctOpcodes: number;
  readonly contexts: number;
  readonly metadataKeys: readonly string[];
};

/**
 * A settled transaction, its replay, and its executed steps become a `.ct`.
 *
 * `writer` is already open — this module does not decide the session configuration, because the
 * mapping rung is part of it and the rung is this module's own statement. `declareRung` below says
 * it again per contract, which is the milestone's "per contract" and is what the module counts
 * violations against.
 *
 * **L5's `sources` IS OPTIONAL AND ITS ABSENCE IS THE L3 BEHAVIOUR EXACTLY.** With no entry for a
 * contract, that contract is declared at `RUNG_BYTECODE_VALUE` with
 * {@link CHAIN_CONTRACT_RUNG_CEILING_REASON}, no step of it is pushed with a position, and the
 * bytes this function writes are the bytes L3 wrote. That is not a courtesy to old callers: it is
 * the property that lets the arms run hold a resolved recording and an unresolved one side by side
 * and attribute every difference between them to the resolution.
 *
 * **THE CALLER MUST OPEN THE WRITER AT THE RIGHT SESSION RUNG, AND THIS FUNCTION CANNOT DO IT FOR
 * THEM.** `resolveTracingConfig` refuses `columns: true` below rung 1 (`ColumnAwarenessUnavailable`)
 * and the session's rung is fixed when the writer is constructed, which is before this function is
 * called. So the caller resolves artifacts FIRST, opens the writer at rung 1 only if something
 * resolved, and hands the maps in — which is what `replay_settled_transaction.mjs` does, in that
 * order, with the order commented.
 */
export function buildSettledRecording(
  writer: RecordingWriter,
  settled: SettledTransaction,
  outcome: ReplayOutcome,
  steps: readonly ExecutionStep[] | null,
  sources: readonly ResolvedContractSource[] = [],
): SettledRecording {
  // ---- the three refusals, before anything is written --------------------------------------
  if (steps === null) {
    throw new ExecutedStepsUnusable('collection-off', settled.txHash,
      'stepsFromOutcome returned null');
  }
  if (steps.length === 0) {
    throw new ExecutedStepsUnusable('empty', settled.txHash,
      `the AVM reports ${outcome.instructionsExecuted} instruction(s) executed`);
  }
  if (outcome.instructionsExecuted !== steps.length) {
    throw new ExecutedStepsUnusable('count-disagreement', settled.txHash,
      `the AVM counted ${outcome.instructionsExecuted} and ${steps.length} record(s) were decoded`);
  }

  // ---- L5 PASS ONE: RESOLVE EVERY STEP'S POSITION, AND MEASURE WHAT THE DECLARATION WILL CLAIM --
  //
  // It is a pass of its own for the reason `ct_declare_rung` forces: the module tallies violations
  // per record against the declaration that exists AT THE TIME, so every declaration has to be on
  // its list before the first step of that contract crosses — and the rung being declared is a fact
  // about the whole stream. Interning happens here too, so `pathsInterned` is already right by the
  // time the first step is pushed.
  //
  // **THE RUNG IS DECLARED FROM THE EXECUTION AND NOT FROM THE ARTIFACT, WHICH IS M29's RULE AND
  // ITS REASON IS MEASURED.** `SOURCE-MAPPING.md` §2.4 hole 2: compiled procedures are appended
  // after the main body (`avm-transpiler` `transpile.rs:489,505`), past the end of
  // `brillig_pcs_to_avm_pcs`, so a real execution walks pcs the map does not key — 127 of 516 on
  // the browser demo's token transfer, 24.6%. A contract declared rung 1 on the strength of its
  // artifact and then executing one unkeyed pc is a `rungViolation`, and `CtWriter.close()` refuses
  // the container. So: rung 1 when every executed step of that contract resolved, rung 2 when some
  // did, rung 3 when none did — each with the split in the reason.
  const sourceByAddress = new Map(sources.map(s => [normaliseAddress(s.address), s]));
  const positions: (StepPosition | undefined)[] = steps.map((step) => {
    const source = sourceByAddress.get(normaliseAddress(hexOfAddress(step.contractAddress)));
    if (source === undefined) return undefined;
    return source.map.positionFor(step.pc) ?? undefined;
  });

  const tally = new Map<string, { steps: number; positioned: number; firstUnpositionedPc: number | null }>();
  for (let i = 0; i < steps.length; i++) {
    const key = normaliseAddress(hexOfAddress(steps[i]!.contractAddress));
    let row = tally.get(key);
    if (row === undefined) {
      row = { steps: 0, positioned: 0, firstUnpositionedPc: null };
      tally.set(key, row);
    }
    row.steps += 1;
    if (positions[i] !== undefined) row.positioned += 1;
    else if (row.firstUnpositionedPc === null) row.firstUnpositionedPc = steps[i]!.pc;
  }

  // ---- the rung, per contract, declared BEFORE the first step of that contract crosses -------
  //
  // **EVERY CONTRACT `settled.contracts` NAMES IS DECLARED, INCLUDING ONE THAT EXECUTED NOTHING.**
  // Declaring only the contracts that appear in the step stream would make a contract the
  // transaction resolved and never entered indistinguishable from one it never had — and the
  // enumeration is `settled.contracts`, whose membership L1 refuses to leave to chance.
  const contractRungs: ContractRungDeclaration[] = [];
  for (const contract of settled.contracts) {
    const key = normaliseAddress(contract.address);
    const source = sourceByAddress.get(key);
    const row = tally.get(key) ?? { steps: 0, positioned: 0, firstUnpositionedPc: null };

    let rung: number;
    let reason: string;
    if (source === undefined) {
      rung = RUNG_BYTECODE_VALUE;
      reason = CHAIN_CONTRACT_RUNG_CEILING_REASON;
    } else if (row.steps > 0 && row.positioned === row.steps) {
      rung = RUNG_SOURCE_VALUE;
      reason =
        `all ${row.steps} executed step(s) of this contract resolved to a (path, line, column). `
        + `The artifact was PROVED off-chain: ${source.proof}. Its own verdict: `
        + `${source.map.verdict.reason}. Source text attested by: ${source.corroboration}.`;
    } else if (row.positioned > 0) {
      rung = RUNG_FUNCTION_VALUE;
      reason =
        `${row.positioned} of ${row.steps} executed step(s) of this contract resolve to a source `
        + `position; the remaining ${row.steps - row.positioned} are in regions the artifact's `
        + 'brillig_locations does not key — compiled procedures are appended after the main body '
        + '(avm-transpiler transpile.rs:489,505), SOURCE-MAPPING.md section 2.4 hole 2 — first at '
        + `pc ${row.firstUnpositionedPc ?? -1}. The artifact itself is rung `
        + `${source.map.verdict.rung}: ${source.map.verdict.reason}`;
    } else {
      rung = RUNG_BYTECODE_VALUE;
      reason =
        `an artifact WAS proved for this contract (${source.proof}) and NONE of its `
        + `${row.steps} executed step(s) resolved to a source position, so the recording is at `
        + 'instruction level for it. The artifact\'s own verdict is rung '
        + `${source.map.verdict.rung}: ${source.map.verdict.reason}. A proof is not a mapping, and `
        + 'this is the case where the difference shows.';
    }
    writer.declareRung(addressBytes(contract.address), rung, reason);
    contractRungs.push({
      address: contract.address,
      rung,
      reason,
      steps: row.steps,
      positioned: row.positioned,
      firstUnpositionedPc: row.firstUnpositionedPc,
      resolved: source !== undefined,
    });
  }

  // ---- the frames, from the AVM's OWN context ids ---------------------------------------------
  // A context id is the AVM's identity for an execution frame; a new one is a call and returning to
  // an id already on the stack is a return. It is the only honest source available: the alternative
  // the sibling campaign used once was to deal mapped pcs round-robin across enqueued call names,
  // which produced the right NUMBER of frames and put arbitrary steps in them.
  //
  // L5: A STEP CARRIES A POSITION EXACTLY WHEN ITS CONTRACT HAS A PROVED ARTIFACT THAT KEYS ITS PC.
  // With no proved artifact, `positions[i]` is `undefined` for every i, `push` is called with one
  // argument for every step, and this loop writes what L3 wrote — see `buildSettledRecording`'s
  // doc. Where positions DO exist, they are passed for every step including the ones that resolved
  // to nothing: `CtWriter.push` stages a `line: 0` slot for an absent position rather than skipping
  // it, because the two FIFOs are paired by order and a skipped slot slides every later step in the
  // batch onto an earlier step's line. That hazard is in the writer's own header and this is the
  // call site it was written for.
  const stack: number[] = [];
  const written = new Set<number>();
  let topLevelSeen = 0;

  for (let i = 0; i < steps.length; i++) {
    const step = steps[i]!;
    const at = positions[i];
    if (stack.length === 0 || stack[stack.length - 1] !== step.contextId) {
      const known = stack.lastIndexOf(step.contextId);
      if (known >= 0) {
        while (stack.length - 1 > known) {
          writer.returnFrame();
          stack.pop();
        }
      } else {
        const name = stack.length === 0
          ? `enqueued-call-${topLevelSeen}`
          : `context${step.contextId}`;
        if (stack.length === 0) topLevelSeen += 1;
        // THE FRAME TAKES THE FIRST STEP'S POSITION WHEN THERE IS ONE. Without a `pathId` the frame
        // lands on the session's own source path, which at rung 1 is `/aztec/<tx>.avm` — a file the
        // viewer cannot display, sitting above frames whose steps point at real Noir. The `line: 1`
        // fallback is L3's and is kept for the unresolved case, where there is nothing better.
        writer.call(name, {
          ...(at?.pathId !== undefined ? { pathId: at.pathId } : {}),
          line: at?.line ?? 1,
          contractAddress: step.contractAddress,
        });
        stack.push(step.contextId);
      }
    }
    written.add(step.opcode);
    writer.push({
      contextId: step.contextId,
      pc: step.pc,
      opcode: step.opcode,
      l2Gas: BigInt(step.gasUsed.l2Gas),
      daGas: BigInt(step.gasUsed.daGas),
      contractAddress: step.contractAddress,
    }, at);
  }
  while (stack.length > 0) {
    writer.returnFrame();
    stack.pop();
  }

  const distinctOpcodes = written.size;
  const contexts = new Set(steps.map((s) => s.contextId)).size;

  // ---- the records that make this a recording OF something ------------------------------------
  // COUNTED FROM WHAT WAS PUSHED, not from what was drained — M29's correction, and its reason
  // applies here unchanged: a figure derived from the input is a figure the producer reports about
  // itself, upstream of the one thing it could get wrong.
  writer.logEvent(RECORDING_METADATA_KEYS.stepProducer,
    `${REPLAY_STEP_PRODUCER} steps=${steps.length} `
      + `instructionsExecuted=${outcome.instructionsExecuted} `
      + `distinctOpcodes=${distinctOpcodes} contexts=${contexts}`);

  // THE MILESTONE'S OWN LIST: block number, transaction hash, node URL, protocol version. Plus the
  // two coordinates that say WHICH state this was run against, because a replay's provenance is not
  // only where the transaction came from but what it was executed over.
  writer.logEvent(RECORDING_METADATA_KEYS.chainProvenance,
    [
      `txHash=${settled.txHash}`,
      `l2BlockNumber=${settled.l2BlockNumber}`,
      `l2BlockHash=${settled.l2BlockHash}`,
      `txIndexInBlock=${settled.txIndexInBlock}`,
      `nodeUrl=${settled.source.url}`,
      // THE PROTOCOL VERSION IS THE PIN, AND IT IS THE PARTIAL ONE, WHICH THE RECORD SAYS.
      // L0 established that both reachable endpoints are proxies that strip the `x-aztec-*` headers
      // on the batch POST upstream always sends, so the client never OBSERVES a version and
      // `pins.json` keeps `network: UNESTABLISHED`. Writing an observed value here would be writing
      // a field nobody read; writing the pin without saying it is the pin would let a reader take it
      // for what the node said. So it is labelled.
      ...Object.entries(PINNED_PROTOCOL_VERSION).map(([k, v]) => `protocolVersion.${k}=${v}`),
      'protocolVersionSource=pins.json (this repository\'s PIN, not a value observed from the node '
        + '— the reachable endpoints are proxies that strip the version headers on a batch POST)',
      `preStateReadAtBlock=${outcome.preStateBlock}`,
      `contractsResolvedAsOf=${settled.contracts[0]?.resolvedAsOf ?? 'none'}`,
      `publishedRevertCode=${settled.revertCode}`,
      `replayedRevertCode=${outcome.revertCode}`,
      `publishedEffectsReproduced=${outcome.verdict.reproduced}`,
    ].join(' '));

  // L2'S HANDOFF, AND IT IS NOT OPTIONAL. Written unconditionally, from the outcome's own
  // declaration rather than from a literal, so a run whose roots DID agree would say that instead.
  writer.logEvent(RECORDING_METADATA_KEYS.rootDivergence,
    outcome.roots.declarations
      .map((d) => `${d.tree}:${d.agrees ? 'AGREES' : 'DIFFERS'} resident=${d.resident} chain=${d.chain}`)
      .join(' ')
    + ` || ${outcome.roots.reason}`);

  // L1'S DECLARATION, IN THE ARTEFACT AND NOT ONLY IN A LOG — which is the milestone's own wording,
  // "the private half's absence visible IN THE RECORDING, not only in a log".
  writer.logEvent(RECORDING_METADATA_KEYS.privateHalf,
    `status=${settled.privateHalf.status} origin=${settled.privateHalf.origin} `
    + `|| ${settled.privateHalf.reason}`);

  writer.logEvent(RECORDING_METADATA_KEYS.sourceMapping, CHAIN_CONTRACT_RUNG_CEILING_REASON);

  // ---- L5'S RECORD: WHERE THE SOURCE CAME FROM, AND WHAT THE CHAIN DOES NOT COMMIT TO ----------
  //
  // Written for every recording, resolved or not — see the key's own doc. The sentence about
  // `artifactHash` is here rather than only in a source file because a container travels: it is
  // published, downloaded and opened by a debugger that has never seen this repository, and a
  // source-level claim whose caveat lives in a comment is a source-level claim with no caveat.
  const sourceLevel = contractRungs.length > 0
    && contractRungs.every(c => c.rung === RUNG_SOURCE_VALUE);
  writer.logEvent(RECORDING_METADATA_KEYS.sourceProvenance,
    [
      `sourceLevel=${sourceLevel}`,
      `contracts=${contractRungs.length}`,
      `resolved=${contractRungs.filter(c => c.resolved).length}`,
      ...contractRungs.map((c) => {
        const source = sourceByAddress.get(normaliseAddress(c.address));
        return source === undefined
          ? `${c.address} rung=${c.rung} artifact=NONE-PROVED`
          : `${c.address} rung=${c.rung} artifact=${source.origin} `
            + `corroboration=${source.corroboration} `
            + `steps=${c.positioned}/${c.steps}`;
      }),
      'NOTE: artifactHash commits to the contract\'s function trees and metadata — the preimage is '
        + 'private_functions_artifact_tree_root, utility_functions_artifact_tree_root and '
        + 'artifact_metadata — and it does NOT commit to debug_symbols or file_map. So the '
        + 'BYTECODE above is proved byte-equal to the class\'s packedBytecode and the class id '
        + 'recomputes, while the SOURCE TEXT is attested only by the named distributor(s). '
        + 'corroboration=corroborated means two independent distributors served the same '
        + 'debug_symbols and file_map; corroboration=single-distributor means one did.',
    ].join(' || '));

  const closed = writer.close();
  return {
    container: closed.container,
    bytes: closed.container.byteLength,
    events: closed.events,
    callsOpened: closed.callsOpened,
    logEvents: closed.logEvents,
    stepsPositioned: closed.stepsPositioned,
    stepsUnpositioned: closed.stepsUnpositioned,
    writerKind: closed.writerKind,
    // THE WORST RUNG ANY CONTRACT REACHED, NOT A CONSTANT AND NOT THE BEST. See the field's doc.
    // `Math.max` over the rungs is the worst because the ladder counts DOWN toward better.
    declaredRung: contractRungs.length === 0
      ? RUNG_BYTECODE_VALUE
      : Math.max(...contractRungs.map(c => c.rung)),
    contractRungs,
    sourceLevel,
    steps: steps.length,
    distinctOpcodes,
    contexts,
    metadataKeys: Object.values(RECORDING_METADATA_KEYS),
  };
}

/**
 * The recording id: a VALID UUIDv7, derived from the block's timestamp and the transaction hash.
 *
 * THE REFERENCE READER ENFORCES BOTH HALVES OF THIS AND CAUGHT BOTH, ONE AT A TIME.
 *   1. `recording_id: expected 36 chars, got 23` — the first version was
 *      `${txHash.slice(2,18)}-b${blockNumber}`, which is neither 36 characters nor a UUID.
 *   2. `expected version nibble '7' at position 14, got '9' (not a UUIDv7)` — the second version
 *      was 36 characters of transaction hash laid out 8-4-4-4-12, which is UUID-SHAPED and is not
 *      a UUID. A shape is not a format.
 * That is `ct-print` refusing a container this milestone would otherwise have called written, and
 * it is why "the writer returned bytes" is not the standard a recording is held to here.
 *
 * DERIVED, NOT RANDOM, AND THE DERIVATION IS THE INTERESTING PART. `crypto.randomUUID()` would
 * satisfy the reader and make two recordings of the SAME transaction carry different ids, so
 * nothing downstream could tell a re-capture from a different subject. A UUIDv7's first 48 bits are
 * a millisecond timestamp — so the timestamp used here is **the settling block's own**, and the
 * remaining bits come from the transaction hash. The result is a legitimate v7 whose time field
 * means something true, and which is a pure function of the thing being recorded.
 *
 * It is NOT where the provenance lives. A UUID says nothing to a reader; `ct.chain-provenance`
 * carries the hash, the block, the node and the rest, which is the milestone's own list.
 */
export function recordingIdFor(txHash: string, blockTimestampSeconds: bigint | number): string {
  const hex = (txHash.startsWith('0x') ? txHash.slice(2) : txHash).toLowerCase().padEnd(64, '0');
  const ms = BigInt(blockTimestampSeconds) * 1000n;
  const time = (ms & 0xffffffffffffn).toString(16).padStart(12, '0');
  // The version nibble is 7 and the variant nibble is forced into 8..b, which is what makes this a
  // UUIDv7 rather than something that looks like one.
  const randA = hex.slice(0, 3);
  const variantNibble = '89ab'[Number.parseInt(hex[3]!, 16) & 0b11]!;
  const randB1 = hex.slice(4, 7);
  const randB2 = hex.slice(7, 19);
  return `${time.slice(0, 8)}-${time.slice(8, 12)}-7${randA}-${variantNibble}${randB1}-${randB2}`;
}

/**
 * One spelling for an address, so a `Map` keyed by it cannot miss.
 *
 * `SettledTransaction.contracts[].address` is upstream's `AztecAddress.toString()` — `0x` plus 64
 * lowercase hex, zero-padded. `ExecutionStep.contractAddress` is 32 raw bytes. They are the same
 * value in two encodings and a lookup that compared them unnormalised would find nothing, silently,
 * and report every contract unresolved — which is a green "rung 3" over a resolution that worked.
 */
function normaliseAddress(address: string): string {
  const hex = (address.startsWith('0x') ? address.slice(2) : address).toLowerCase();
  return `0x${hex.padStart(64, '0')}`;
}

/** The 32 big-endian bytes of an `ExecutionStep.contractAddress`, as `0x…`. */
function hexOfAddress(bytes: Uint8Array): string {
  let out = '0x';
  for (const b of bytes) out += b.toString(16).padStart(2, '0');
  return out;
}

/** A `0x…` address as the 32 big-endian bytes the writer takes. */
function addressBytes(address: string): Uint8Array {
  const hex = address.startsWith('0x') ? address.slice(2) : address;
  const padded = hex.padStart(64, '0');
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i += 1) {
    out[i] = Number.parseInt(padded.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}
