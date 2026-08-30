// recording.ts — L3: A SETTLED TRANSACTION BECOMES A `.ct` CONTAINER THAT STEPS.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE THING THIS FILE HAS TO SAY BEFORE ANYTHING ELSE, BECAUSE IT BOUNDS THE PRODUCT AND IS NOT A
// PROPERTY OF THIS MILESTONE'S EFFORT: **A RECORDING OF A CHAIN-FETCHED CONTRACT CAN ONLY EVER
// REACH RUNG 3.**
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
// WHAT WOULD LIFT IT, stated so the next reader does not re-derive it: obtaining the compiled
// artifact OFF-CHAIN — from the npm package, a published artifact registry, or the developer's own
// build — and verifying it against `artifactHash`, which is exactly what upstream says that field
// is for. **Nothing in this repository does that resolution today**, and building it is an
// artifact-distribution problem rather than a replay problem. It is L4's or later's, and it is
// recorded here rather than attempted, because the demo does not need it and a lookalike would be
// worse than the honest rung.
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
  /** Why the rung is 3 and cannot be higher for a chain-fetched contract. */
  sourceMapping: 'ct.source-mapping-ceiling',
} as const;

export type RecordingMetadataKey =
  (typeof RECORDING_METADATA_KEYS)[keyof typeof RECORDING_METADATA_KEYS];

/** The producer name, so a container says which code wrote it rather than only that something did. */
export const REPLAY_STEP_PRODUCER = 'aztec-live-chain-replay/L3';

/**
 * Why a chain-fetched contract cannot exceed rung 3. Written into the container AND used as the
 * `declareRung` reason, so the two cannot drift.
 */
export const CHAIN_CONTRACT_RUNG_CEILING_REASON =
  'RUNG 3 (BYTECODE) IS THE CEILING FOR A CHAIN-FETCHED CONTRACT, BY PROTOCOL DESIGN AND NOT BY '
  + 'OMISSION. Rungs 1 and 2 need the compiled artifact\'s debug_symbols, and rung 1 additionally '
  + 'needs its file_map WITH SOURCE TEXT. An Aztec node serves neither: getContractClass returns '
  + 'ContractClassPublic, which is exactly { id, privateFunctionsRoot, version, artifactHash, '
  + 'packedBytecode } — no debug symbols, no file map, no function table, no source. Upstream\'s '
  + 'own doc comment on artifactHash says it is "intended to be used by clients to verify that an '
  + 'OFFCHAIN FETCHED ARTIFACT matches a registered class", i.e. the chain holds a commitment to '
  + 'the artifact and not the artifact. No method on AztecNode serves one either. Lifting this '
  + 'needs off-chain artifact resolution verified against artifactHash, which is an '
  + 'artifact-distribution problem and is not built here.';

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
  push(event: Record<string, unknown>): void;
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
  /** Written by this module, so a check can compare the container against what was intended. */
  readonly declaredRung: number;
  readonly steps: number;
  readonly distinctOpcodes: number;
  readonly contexts: number;
  readonly metadataKeys: readonly string[];
};

/**
 * A settled transaction, its replay, and its executed steps become a `.ct`.
 *
 * `writer` is already open — this module does not decide the session configuration, because the
 * mapping rung is part of it and the rung is this module's own statement. The caller passes a
 * writer opened at `RUNG_BYTECODE_VALUE`; `declareRung` below says so again per contract, which is
 * the milestone's "per contract" and is what the module counts violations against.
 */
export function buildSettledRecording(
  writer: RecordingWriter,
  settled: SettledTransaction,
  outcome: ReplayOutcome,
  steps: readonly ExecutionStep[] | null,
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

  // ---- the rung, per contract, declared BEFORE the first step of that contract crosses -------
  // The order is load-bearing: the module tallies violations per record against the declaration
  // that exists at the time, so a declaration made afterwards would be a claim about a stream that
  // had already been ingested unchecked.
  for (const contract of settled.contracts) {
    writer.declareRung(addressBytes(contract.address), RUNG_BYTECODE_VALUE,
      CHAIN_CONTRACT_RUNG_CEILING_REASON);
  }

  // ---- the frames, from the AVM's OWN context ids ---------------------------------------------
  // A context id is the AVM's identity for an execution frame; a new one is a call and returning to
  // an id already on the stack is a return. It is the only honest source available: the alternative
  // the sibling campaign used once was to deal mapped pcs round-robin across enqueued call names,
  // which produced the right NUMBER of frames and put arbitrary steps in them.
  //
  // NO STEP CARRIES A POSITION, and `push` is called with one argument for every one of them. At
  // rung 3 there is nothing to position with, and staging a position for some steps and not others
  // is how a later step takes an earlier one's line — the writer's own header records that hazard.
  const stack: number[] = [];
  const written = new Set<number>();
  let topLevelSeen = 0;

  for (const step of steps) {
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
        writer.call(name, { line: 1, contractAddress: step.contractAddress });
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
    });
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
    declaredRung: RUNG_BYTECODE_VALUE,
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
