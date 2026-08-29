// node_surface.ts — L0's first deliverable: WHICH `AztecNode` METHODS A REPLAY ACTUALLY CALLS.
//
// The milestone says to enumerate first and report the number before writing code, because the
// absence of that step cost the sibling campaign four milestones of deferral. This module is the
// enumeration, and `verify_node_client_surface_narrow` re-derives the universe it partitions from
// UPSTREAM AT THE PINNED ANCHOR on every run rather than reading it back out of here.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE NUMBER, AND THE NUMBER THE CAMPAIGN FILE STATES ARE NOT THE SAME NUMBER.
//
// `Aztec-Live-Chain-Replay.milestones.org` says `AztecNode` "declares fifty-one methods", twice.
// Measured at `anchors.cpp` (233d8e0993), by two independent derivations that agree exactly, it
// declares **fifty-five**:
//
//   * `yarn-project/stdlib/src/interfaces/aztec-node.ts`, the `export interface AztecNode` body —
//     55 members, with a residue of 15 lines PRINTED by the scanner and every one of them a
//     `): Promise<…>;` continuation of a multi-line signature.
//   * the same file's `export const AztecNodeApiSchema: ApiSchemaFor<AztecNode>` — 55 keys, with
//     a residue of 27 `}),` lines. `ApiSchemaFor<T>` makes the compiler require one key per
//     method, so the two are the same set BY CONSTRUCTION and the point of taking both is that a
//     scanner error in either shows up as a disagreement rather than as a plausible number.
//
// The interface set and the schema set are IDENTICAL — no member of one is absent from the other.
// A THIRD derivation, `Object.keys(AztecNodeApiSchema)` evaluated at run time out of the published
// `@aztec/stdlib@5.3.0-nightly.20260819` (`npm.current`, which pins.json declares
// `corresponds_to_anchor: cpp`), also gives 55, and differs from the anchor's set in exactly ONE
// name: the nightly spells it `getL1ToL2MessageCheckpoint` where the anchor spells it
// `getL1ToL2MessageIndex`. That single difference is declared below as
// `ANCHOR_ONLY` / `PACKAGE_ONLY` and asserted, because "the published nightly IS the anchor" is a
// claim this repository has never measured and it is false by one method.
//
// Fifty-one is not fifty-five, and the campaign file is not wrong so much as UNRE-DERIVED — the
// exact family CAMPAIGN-BRIEF.md calls "a figure nobody re-derives rots". It is corrected here by
// measurement rather than by argument, and the checks take it again on every run.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE ANSWER: FOURTEEN OF FIFTY-FIVE.
//
// Every one of the fourteen is here because something a replay must do needs the datum it returns,
// and the reason names that thing. Every one of the forty-one refusals is in a group with a reason
// that is `does-not-exist`-shaped, `does-not-cover`-shaped or `cannot-reach-target`-shaped, the way
// REUSE-INVENTORY.md requires — "we didn't find a use for it" is not a reason.
//
// THE LINE, stated once so a later milestone widens it deliberately rather than by drift: this
// campaign fetches A HANDFUL OF THINGS ABOUT ONE SETTLED TRANSACTION, on demand. It does not
// follow a tip, it does not walk a range, it does not hold a cursor and it never writes. Anything
// that only makes sense for a continuous ingestion pipeline is refused, and the refusal group
// `CONTINUOUS_FOLLOWING` names that set exactly, so the day someone builds ingestion the widening
// is one edit with a reason rather than a surface that grew while nobody was counting.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// TWO REFUSALS THAT DISAGREE WITH THE MILESTONE FILE, AND THE MEASUREMENT BEHIND EACH.
//
// 1. `getBlockHashMembershipWitness` IS REFUSED, though L2's "route 1" names it. The AVM never
//    reads the archive. Measured two ways at the anchor: `barretenberg/cpp/src/barretenberg/vm2/
//    common/opcodes.hpp`'s world-state opcodes are SLOAD, SSTORE, NOTEHASHEXISTS, EMITNOTEHASH,
//    NULLIFIEREXISTS, EMITNULLIFIER, L1TOL2MSGEXISTS and GETCONTRACTINSTANCE — there is no
//    archive or block-hash read among them — and this repository's own `REACTOR-ABI.md` already
//    records that `MerkleTreeId::ARCHIVE` occurs in `vm2/` exactly once outside tests, in a
//    tree-NAME switch, and that the AVM's `TreeSnapshots` has four members and could not carry a
//    fifth without a circuit change. A witness with no reader is a dependency, not a citation.
//
// 2. `getL1ToL2MessageMembershipWitness` IS PERMITTED, though L2's route-1 list does not name it.
//    `L1TOL2MSGEXISTS` is in that same opcode list, so public execution CAN read the L1-to-L2
//    message tree, and a route-1 replay that could not answer it would fail on a real transaction
//    that used the opcode. This is the enumeration earning its keep in the other direction: the
//    campaign's list was one short and one long, and neither error was visible without going to
//    the opcodes.
//
// Both are recorded rather than silently applied, and `verify_node_client_surface_narrow` asserts
// the classification of both by name so that reversing either is a red line and not an edit.

import type { AztecNode } from '@aztec/stdlib/interfaces/client';

/**
 * THE PERMITTED SURFACE. Fourteen of `AztecNode`'s fifty-five, each with the datum it supplies and
 * the milestone that consumes it.
 *
 * The order is the order a replay uses them in, which is also roughly L0 → L1 → L2, so a reader
 * following the campaign meets them in the order the campaign meets them.
 */
export const REPLAY_NODE_SURFACE = [
  // ---- L0: is this the chain we think it is -----------------------------------------------
  /**
   * The node's own account of itself: `nodeVersion`, `l1ChainId`, `rollupVersion`,
   * `l1ContractAddresses`, `protocolContractAddresses`. This is the ONE place the client asks a
   * node what it is, and `getChainId` / `getVersion` / `getNodeVersion` /
   * `getProtocolContractAddresses` are refused precisely because they are four more ways to ask a
   * question this already answers — four more things to keep in step, and the campaign has paid
   * for a figure stated in five places more than once.
   *
   * L3 also needs it: "chain coordinates — block number, transaction hash, node URL, protocol
   * version — carried in the trace metadata, so a recording says what it is a recording OF".
   */
  'getNodeInfo',
  // ---- the demo's entry point: what "recent" is --------------------------------------------
  /**
   * The tip. Permitted DELIBERATELY and not by inheritance: the product goal is a demo over
   * RECENT settled blocks and transactions, and without this the client cannot find out what
   * recent is — it could only replay a hash somebody typed. `getChainTips` is refused because it
   * answers the same question with four numbers where this answers it with one, and
   * `getBlockNumber(tag)` takes the tag as an argument anyway.
   */
  'getBlockNumber',
  /**
   * ONE block, with `{ includeTransactions: true }`, to learn which transactions a recent block
   * contains. This is the singular fetch; `getBlocks` — the RANGE — is refused, and that is where
   * the line between "a demo of recent transactions" and "an ingestion engine" is drawn.
   */
  'getBlock',
  // ---- L1: a transaction hash becomes a Tx and its block coordinates ------------------------
  /** `Tx` — the transaction as the chain carries it. The seam `AvmTxHint.fromTx` consumes. */
  'getTxByHash',
  /** The batch form of the same call. L1's deliverable names both; it is not a stream. */
  'getTxsByHash',
  /**
   * `IndexedTxEffect` — `l2BlockNumber`, `l2BlockHash`, `txIndexInBlock`, `slotNumber` and the
   * `TxEffect` the chain published. It is both L1's "the settling block" and L2's yardstick:
   * "re-execution reproducing the transaction's own recorded outcome — revertCode, gas consumed,
   * and the side effects in the TxEffect the chain published".
   */
  'getTxEffect',
  /**
   * `BlockData` — `header`, `archive`, `blockHash`. `header.globalVariables` is the
   * `GlobalVariables` argument `encodeFastSimulationInputs` takes and the `gasFees` inside
   * `AvmTxHint.fromTx`; `header.state` is the `StateReference` L2's root check compares hydrated
   * trees against. This is the narrow one: it transfers no block body.
   */
  'getBlockData',
  /** `ContractInstanceWithAddress` — what `GETCONTRACTINSTANCE` and address resolution need. */
  'getContract',
  /** `ContractClassPublic` — the packed bytecode. Without it there is nothing to execute. */
  'getContractClass',
  // ---- L2 route 1: one membership witness per world-state READ the AVM can perform ----------
  /** `SLOAD`. A witness rather than a value, which is why `getPublicStorageAt` is refused. */
  'getPublicDataWitness',
  /** `NOTEHASHEXISTS`. */
  'getNoteHashMembershipWitness',
  /** `NULLIFIEREXISTS`, the present case. */
  'getNullifierMembershipWitness',
  /** `NULLIFIEREXISTS`, the ABSENT case: non-membership needs the low leaf. */
  'getLowNullifierMembershipWitness',
  /**
   * `L1TOL2MSGEXISTS`. Returns `[index, SiblingPath]`, so it subsumes `getL1ToL2MessageIndex`,
   * which is refused. See the header: the milestone file's route-1 list does not name this and the
   * opcode list says it must.
   */
  'getL1ToL2MessageMembershipWitness',
] as const;

/** The permitted surface as a type, so `Pick<AztecNode, …>` below is derived and not retyped. */
export type ReplayNodeMethod = (typeof REPLAY_NODE_SURFACE)[number];

/**
 * A REFUSAL GROUP. Each carries a reason that says what a caller who wanted this is actually
 * after, and where they should go instead.
 *
 * The groups PARTITION the forty-one refusals exactly — no method in two groups, no method in
 * none. `verify_node_client_surface_narrow` asserts the partition against upstream's own set, so
 * the day upstream adds a fifty-sixth method the check goes red naming it, and somebody has to
 * decide which side of the line it is on. That is the whole mechanism: an unclassified method is a
 * failure, not a default.
 */
export type RefusalGroup = {
  readonly id: string;
  readonly reason: string;
  readonly methods: readonly string[];
};

export const REFUSAL_GROUPS: readonly RefusalGroup[] = [
  {
    id: 'SUBMISSION_AND_MEMPOOL',
    reason:
      'A replay never writes and never estimates. The transaction it replays settled before the '
      + 'client existed; its fees are already in the block it settled in '
      + '(`BlockData.header.globalVariables.gasFees`), and a fee ORACLE answers a question about a '
      + 'transaction somebody is about to build. `getTxReceipt` is here rather than beside '
      + '`getTxEffect` because a receipt is the submission-side poll — it answers "has it landed '
      + 'yet" — while `getTxEffect` answers "what did it do", which is the only half a settled '
      + 'transaction has left. cannot-reach-target: permitting any of these would make a read-only '
      + 'client able to write.',
    methods: [
      'sendTx',
      'isValidTx',
      'getPendingTxs',
      'getPendingTxCount',
      'getTxReceipt',
      'getCurrentMinFees',
      'getMaxPriorityFees',
      'getPredictedMinFees',
      'getAllowedPublicSetup',
    ],
  },
  {
    id: 'CONTINUOUS_FOLLOWING',
    reason:
      'THIS IS THE LINE. Every one of these exists to follow a chain: a range of blocks, a walk of '
      + 'checkpoints, a sync cursor, a tip that moves. That is an ingestion pipeline — BlockTracer\'s '
      + 'own M6, a separate and larger milestone — and this campaign is one settled transaction at a '
      + 'time, on demand. does-not-cover, in the direction that matters: a client that can stream is '
      + 'a client that can be left running, and the surface stops being a citation. `getBlockNumber` '
      + 'and the singular `getBlock` ARE permitted, so "find a recent block and read its '
      + 'transactions" is answerable without any of these; the widening a real ingestion engine '
      + 'needs is exactly this list, and it should be taken deliberately.',
    methods: [
      'getBlocks',
      'getCheckpoint',
      'getCheckpoints',
      'getCheckpointsData',
      'getCheckpointNumber',
      'getChainTips',
      'getWorldStateSyncStatus',
      'getSyncedL1Timestamp',
      'getSyncedL2EpochNumber',
      'getSyncedL2SlotNumber',
    ],
  },
  {
    id: 'CONSENSUS_AND_P2P',
    reason:
      'Validator, proposal and peer-to-peer operation. does-not-cover: none of it is a fact about a '
      + 'transaction that has already settled — a replay is downstream of every question these ask, '
      + 'and the answers change while the transaction it is replaying does not.',
    methods: [
      'getPeers',
      'getEncodedEnr',
      'getProposalsForSlot',
      'getCheckpointAttestationsForSlot',
      'getValidatorStats',
      'getValidatorsStats',
    ],
  },
  {
    id: 'PRIVATE_DISCOVERY',
    reason:
      'Tag-indexed log search: the surface a PXE uses to discover its own notes. does-not-exist, in '
      + 'the strongest sense this campaign has — THE PRIVATE HALF OF A SETTLED TRANSACTION IS '
      + 'UNRECOVERABLE IN PRINCIPLE. Private execution happens client-side and is never published; '
      + 'the chain carries its effects, not its execution. Reaching for these would be a client '
      + 'trying to reconstruct something that is not there, and an empty answer is '
      + 'indistinguishable from a private half that failed to load. L1 declares that absence '
      + 'explicitly instead.',
    methods: ['getPrivateLogsByTags', 'getPublicLogsByTags'],
  },
  {
    id: 'L1_PLUMBING',
    reason:
      'L1 contract addresses, rollup constants, and the L2-to-L1 direction. `getL1ContractAddresses` '
      + 'and the rollup constants are already inside `getNodeInfo`, which is permitted, so these are '
      + 'a second way to ask. The L2-to-L1 half is outbound — `SENDL2TOL1MSG` WRITES a message and '
      + 'the AVM never reads one back — so there is no read for a witness to serve. '
      + '`getL1ToL2MessageIndex` is subsumed: `getL1ToL2MessageMembershipWitness` returns the index '
      + 'AND the sibling path in one answer, and the sibling path is the half a replay needs.',
    methods: [
      'getL1Constants',
      'getL1ContractAddresses',
      'getL1ToL2MessageIndex',
      'getL2ToL1MembershipWitness',
      'getL2ToL1Messages',
    ],
  },
  {
    id: 'NEARER_SOURCE',
    reason:
      'Each of these is answerable, and this campaign has a nearer or a stricter source for it. '
      + '`getChainId`, `getVersion`, `getNodeVersion` and `getProtocolContractAddresses` are fields '
      + 'of the `NodeInfo` the client already fetches. `getPublicStorageAt` returns a VALUE WITH NO '
      + 'WITNESS, and L2 has to compare hydrated tree roots against the block\'s state reference — a '
      + 'wrong merkle root is worse than a missing one — so the witness form is the one that can be '
      + 'checked. `getBlockHashMembershipWitness` has no reader: the AVM never reads the archive '
      + '(see this module\'s header for the two measurements). `findLeavesIndexes` is M21\'s seam and '
      + 'PXE\'s: `verifyReadRequests` uses it to check a PRIVATE half\'s settled read requests, and a '
      + 'replayed transaction has no private half. `simulatePublicCalls` is the node executing the '
      + 'transaction FOR us, which is the one thing this campaign exists not to do — its answer '
      + 'would be a result with no step stream, and a recording of it would be a recording of '
      + 'nothing. `isReady` is a health check, and this client already has a stricter one: a node '
      + 'that is not there produces `NodeUnreachable` from the very call that wanted something, '
      + 'and `assertProtocolVersion` forces a real round trip and checks the protocol while it is '
      + 'there — where `isReady` answering `false` is still an answer, and answering `true` says '
      + 'nothing about which protocol it speaks.',
    methods: [
      'isReady',
      'getChainId',
      'getVersion',
      'getNodeVersion',
      'getProtocolContractAddresses',
      'getPublicStorageAt',
      'getBlockHashMembershipWitness',
      'findLeavesIndexes',
      'simulatePublicCalls',
    ],
  },
] as const;

/** Every refused method, flattened. Derived, so it cannot drift from the groups. */
export const REFUSED_METHODS: readonly string[] = REFUSAL_GROUPS.flatMap((g) => g.methods);

/**
 * The one name the pinned NIGHTLY declares that the pinned ANCHOR does not, and vice versa.
 *
 * Declared rather than papered over. `verify_client_uses_upstream_schema` compares the anchor's
 * set with the installed package's set AS A SET and expects exactly this difference — so if a
 * future bump makes them agree, or makes them differ by something else, the check goes red instead
 * of quietly widening a tolerance.
 */
export const ANCHOR_ONLY_METHODS: readonly string[] = ['getL1ToL2MessageIndex'];
export const PACKAGE_ONLY_METHODS: readonly string[] = ['getL1ToL2MessageCheckpoint'];

/**
 * The number `AztecNode` declares at the anchor. Stated so a check can compare against it and so
 * the correction of the milestone file's "fifty-one" is a value something reads, not a sentence.
 */
export const AZTEC_NODE_METHOD_COUNT = 55;

/**
 * THE REPLAY SURFACE AS A TYPE, and every member of it is upstream's.
 *
 * `Pick<AztecNode, ReplayNodeMethod>` is the same idiom upstream uses for its own narrowings —
 * `Pick<AztecNode, 'findLeavesIndexes'>` in `contract_function_simulator.ts`,
 * `Pick<AztecNode, 'getBlockData' | 'getL1ToL2MessageIndex'>` in `aztec.js/src/utils/cross_chain.ts`
 * — measured at the anchor, so this is a citation of upstream's practice and not an invention.
 *
 * WHAT A NARROW TYPE CANNOT DO is stop anything: it is erased, and `node as any`,
 * `Reflect.get(node, 'sendTx')` and a duck-typed `'sendTx' in node` all walk past it. That is why
 * `strictSurface` exists beside it, and why the guard traps `has` as well as `get`.
 */
export type ReplayNodeSurface = Pick<AztecNode, ReplayNodeMethod>;
