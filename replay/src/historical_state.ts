// historical_state.ts — L2: THE STATE A SETTLED TRANSACTION SAW, AND THE THREE ROUTES TO IT OF
// WHICH ONLY THE THIRD EXISTS.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE MILESTONE OFFERED TWO ROUTES AND SAID "DO NOT CHOOSE BY ARGUMENT. MEASURE BOTH." THE
// MEASUREMENT IS THAT NEITHER OF THEM IS IMPLEMENTABLE AGAINST TODAY'S ARTEFACT, AND THAT IS THE
// ANSWER RATHER THAN A DEFERRAL.
//
//   ROUTE 1 — "per-read membership witnesses from the node".
//     THERE IS NO SEAM AT WHICH THE AVM ASKS TYPESCRIPT FOR A WORLD-STATE READ. The AVM reads
//     through a `MemoryMerkleDB` that lives INSIDE `avm.wasm`, named by an integer handle
//     (`avm_merkle_db_create`); TypeScript can only WRITE into it. A witness fetched from a node has
//     nowhere to be delivered mid-execution. There is exactly one entry point that takes hints
//     instead of a database — `avm_simulate_with_hinted_dbs` — and it cannot be used, because
//     upstream constructs its configuration internally:
//
//         // barretenberg/cpp/src/barretenberg/vm2/avm_sim_api.cpp:45-47, at anchors.cpp
//         // Placeholder for future use of config from inputs.
//         const PublicSimulatorConfig config = {};
//
//     so `collect_execution_steps` cannot be switched on through it, so it produces NO STEP STREAM,
//     so it cannot produce a `.ct`. A route that cannot record is not a route for this campaign.
//
//   ROUTE 2 — "seed the resident trees from the block's state reference".
//     `MemoryMerkleDB` (barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp,
//     class at :213) has a constructor taking two PREFILL COUNTS and nothing else. No root setter,
//     no bulk import, no construction from a `StateReference`, no revision parameter. Its whole
//     mutating surface is `insert_indexed_leaves_*`, `append_leaves` and `pad_tree`. The only way to
//     a given root is to append every leaf that produces it, and at testnet block 62639 that is
//     1,106,368 note hashes, 1,106,496 nullifiers and 33,808 public-data leaves — whose VALUES no
//     node method serves in bulk. Reconstructing them is a block-ingestion engine, which is the one
//     thing this campaign was told not to build first.
//
//     WORLD-STATE.md predicted this exactly, in M14's Gap B: "the reference holds exactly one view…
//     it cannot be asked for a genesis-anchored read", disposition NOT NEEDED, with the flag
//     "what would change this is a consumer that needs to simulate a transaction against a
//     historical state." L2 is that consumer, and the disposition it names is now reopened — as a
//     COSTED item below rather than as work this milestone did.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// ROUTE 3, AND IT IS THE ONE THE ARTEFACT ADMITS: LET THE AVM NAME ITS OWN READS.
//
// `PublicSimulatorConfig.collectHints` makes the module report EVERY world-state query it made —
// `getPreviousValueIndexHints` carries `(treeId, value, alreadyPresent)` for each. So:
//
//   1. run with an empty tree and `collectHints: true`;
//   2. read out the queries the run made;
//   3. answer each one FROM THE NODE, at the SETTLING BLOCK'S PARENT, through methods already on
//      L0's permitted fourteen (`getPublicDataWitness`, `getNullifierMembershipWitness`);
//   4. seed the answers and run again;
//   5. stop when a round asks for nothing new.
//
// Nothing here guesses which slots a transaction reads. The AVM says. That is the property that
// makes this different from "seed what the TxEffect published", which was the obvious first idea and
// is WRONG in a way that would not have shown: a `TxEffect` lists what a transaction WROTE, and a
// transaction that READS a slot it does not write — this campaign's own demo subject reads four —
// would replay against a zero and produce a confident wrong trace.
//
// THE PARENT BLOCK, NOT THE SETTLING BLOCK. `getPublicDataWitness(n, slot)` answers with the state
// at the END of block n. The state a transaction SAW is the state before its own block, so the read
// is at `settlingBlock - 1`. Asking at the settling block would return the value the transaction
// ITSELF wrote, and the replay would then "reproduce" its own inputs — green, and measuring nothing.
// This is only sound for a transaction at index 0 of its block; `assertReplayableInBlock` refuses
// the rest by name rather than answering them wrongly.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// AND THE TWO THINGS A REPLAY MUST NOT SEED, WHICH ARE THE SHARP EDGES.
//
//   * ITS OWN NULLIFIERS. They are in the `TxEffect` because the transaction EMITTED them. Seeding
//     one makes the AVM's duplicate check find it and revert — a replay failing precisely because
//     the transaction succeeded. `EXCLUDED_BECAUSE_EMITTED`.
//   * ITS OWN WRITES' POST-VALUES. What a transaction wrote is not what it saw. The slots are
//     seeded, from the PARENT, with their pre-images; the published values are the YARDSTICK and
//     never an input. Feeding them in is how a comparison comes to compare a value with itself.

import type { BlockNumber } from '@aztec/foundation/branded-types';
import { Fr } from '@aztec/foundation/curves/bn254';
import { MerkleTreeId } from '@aztec/stdlib/trees';

import type { MembershipWitnessSource } from './membership_witness_source.ts';

// ---------------------------------------------------------------------------------------------
// What route 3 measured, recorded here so it is a citation and not a memory
// ---------------------------------------------------------------------------------------------

/**
 * Why each of the milestone's two routes is closed, in one place, with the source that closes it.
 *
 * A check reads these rather than restating them, so a build in which either sentence stopped being
 * true — upstream threading `config` through `simulate_with_hinted_dbs`, or `MemoryMerkleDB` growing
 * an import — makes the check go red instead of leaving this comment quietly wrong.
 */
export const ROUTE_DISPOSITIONS = Object.freeze({
  'per-read-witnesses': Object.freeze({
    verdict: 'closed' as const,
    because:
      'the AVM reads through a MemoryMerkleDB resident inside avm.wasm and never calls out to '
      + 'TypeScript, so a witness fetched from a node has no delivery point; and the one hint-taking '
      + 'entry point, avm_simulate_with_hinted_dbs, builds `const PublicSimulatorConfig config = {}` '
      + 'internally, so it cannot collect execution steps and therefore cannot produce a .ct.',
    source: 'barretenberg/cpp/src/barretenberg/vm2/avm_sim_api.cpp:45-47',
  }),
  'seed-from-state-reference': Object.freeze({
    verdict: 'closed' as const,
    because:
      'MemoryMerkleDB takes two prefill counts and nothing else — no root setter, no bulk import, no '
      + 'construction from a StateReference. Reaching a published root means appending every leaf '
      + 'that produces it, which for a recent testnet block is over a million leaves whose values no '
      + 'node method serves in bulk. That is a block-ingestion engine.',
    source: 'barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp:213-260',
  }),
  'avm-named-reads': Object.freeze({
    verdict: 'implemented' as const,
    because:
      'PublicSimulatorConfig.collectHints makes the module report every world-state query it made, '
      + 'so the reads can be discovered from the execution itself and answered from the node at the '
      + 'settling block\'s parent. Bounded to one transaction by construction.',
    source: 'PublicSimulatorConfig.collectHints; result.hints.getPreviousValueIndexHints',
  }),
});

// ---------------------------------------------------------------------------------------------
// The refusals
// ---------------------------------------------------------------------------------------------

/**
 * The transaction is not the first in its block, so its pre-state is not the parent block's.
 *
 * A REFUSAL AND NOT A BEST EFFORT. For transaction k>0, the state seen is the parent block's state
 * plus the effects of transactions 0..k-1, and no node method serves that intermediate view — it
 * exists only inside the sequencer. Replaying it against the parent block's state would silently
 * use stale values for every slot an earlier transaction in the same block touched, and the failure
 * mode is a confident wrong trace rather than an error.
 */
export class IntraBlockPredecessorsUnavailable extends Error {
  readonly kind = 'replay-intra-block-predecessors-unavailable' as const;
  readonly txHash: string;
  readonly l2BlockNumber: number;
  readonly txIndexInBlock: number;

  constructor(txHash: string, l2BlockNumber: number, txIndexInBlock: number) {
    super(
      `transaction ${txHash} is at index ${txIndexInBlock} of block ${l2BlockNumber}, and the state `
        + `it saw is block ${l2BlockNumber - 1}'s state PLUS the effects of the ${txIndexInBlock} `
        + `transaction(s) before it in the same block. No node method serves that intermediate view; `
        + `it exists only inside the sequencer that built the block. REFUSING rather than replaying `
        + `against block ${l2BlockNumber - 1}: every slot an earlier transaction in this block `
        + `touched would be read at a stale value, nothing would fail, and the trace would be `
        + `confidently wrong — which is the class of defect this campaign exists to prevent.`,
    );
    this.name = 'IntraBlockPredecessorsUnavailable';
    this.txHash = txHash;
    this.l2BlockNumber = l2BlockNumber;
    this.txIndexInBlock = txIndexInBlock;
  }
}

/**
 * The seed has settled and the module still will not run this transaction.
 *
 * DISTINCT FROM `HydrationDidNotConverge` ON PURPOSE, and the distinction was paid for: the first
 * version of the loop reported non-convergence here, so a run whose module had said
 * "Not enough balance for fee payer to pay for transaction" twelve times in a row was diagnosed as
 * a loop that kept discovering new state. Non-convergence means the query set is still growing.
 * THIS means the query set stopped growing and the answer is still no — which is a statement about
 * the transaction, or about route 3's reach, and the module's own words are the whole of it.
 */
export class ModuleRefusedReplay extends Error {
  readonly kind = 'replay-module-refused' as const;
  readonly txHash: string;
  readonly refusal: string;
  readonly rounds: number;
  readonly seeded: { nullifiers: number; publicData: number };

  constructor(txHash: string, refusal: string, rounds: number,
              seeded: { nullifiers: number; publicData: number }) {
    super(
      `the AVM refused to replay ${txHash} after ${rounds} hydration round(s), with `
        + `${seeded.nullifiers} nullifier(s) and ${seeded.publicData} public-data leaf/leaves seeded `
        + `and the query set no longer growing. The module said: ${refusal}. This is NOT a loop that `
        + `failed to converge — it converged, and the answer is still no. Either this transaction `
        + `reads state route 3 cannot reach (see UNANSWERABLE_TREES) or the seed is right and the `
        + `refusal is about something else; the module's own sentence is the place to start.`,
    );
    this.name = 'ModuleRefusedReplay';
    this.txHash = txHash;
    this.refusal = refusal;
    this.rounds = rounds;
    this.seeded = seeded;
  }
}

/** The discovery loop did not settle. Named so it cannot be mistaken for a replay that ran. */
export class HydrationDidNotConverge extends Error {
  readonly kind = 'replay-hydration-did-not-converge' as const;
  readonly rounds: number;
  readonly lastAdded: number;

  constructor(rounds: number, lastAdded: number) {
    super(
      `the hydration loop ran ${rounds} round(s) and the AVM was still asking for state it had not `
        + `been given (${lastAdded} new leaf/leaves in the last round). A replay is NOT reported from `
        + `a loop that did not settle: the last round's outcome is an execution against a partially `
        + `hydrated tree, which is exactly a well-formed answer to a question nobody asked.`,
    );
    this.name = 'HydrationDidNotConverge';
    this.rounds = rounds;
    this.lastAdded = lastAdded;
  }
}

// ---------------------------------------------------------------------------------------------
// The queries, and what a round did with them
// ---------------------------------------------------------------------------------------------

/** One world-state question the AVM reported having asked. Upstream's own hint fields. */
export type WorldStateQuery = {
  readonly treeId: number;
  /** A nullifier for the nullifier tree; a SILOED leaf slot for the public-data tree. */
  readonly value: string;
  /** What the AVM found in the tree it was given — not what the chain holds. */
  readonly alreadyPresent: boolean;
};

/** The two trees route 3 can answer. The other three are enumerated below with reasons. */
export const ANSWERABLE_TREES: readonly number[] = Object.freeze([
  MerkleTreeId.NULLIFIER_TREE,
  MerkleTreeId.PUBLIC_DATA_TREE,
]);

/**
 * The trees route 3 does NOT answer, each with the reason, so an unanswered query is a named gap
 * rather than a silent one.
 *
 * `NOTE_HASH_TREE` and `L1_TO_L2_MESSAGE_TREE` are append-only: the AVM's `NOTEHASHEXISTS` and
 * `L1TOL2MSGEXISTS` opcodes ask for membership at an INDEX, and seeding a leaf at an index in an
 * append-only tree means appending every leaf before it. `ARCHIVE` is not read by the AVM at all —
 * L0 measured that from the opcode set and it is asserted by name in
 * `verify_node_client_surface_narrow`.
 */
export const UNANSWERABLE_TREES: Readonly<Record<number, string>> = Object.freeze({
  [MerkleTreeId.NOTE_HASH_TREE]:
    'append-only: a leaf at index i cannot be placed without the i leaves before it, and no node '
    + 'method serves them in bulk. A transaction that reads a note hash is out of scope for this '
    + 'route and is refused by name rather than replayed against an absent leaf.',
  [MerkleTreeId.L1_TO_L2_MESSAGE_TREE]:
    'append-only, for the same reason as the note hash tree. L1TOL2MSGEXISTS is a real opcode, so '
    + 'this is a real limit and not a theoretical one.',
  [MerkleTreeId.ARCHIVE]:
    'the AVM never reads the archive — L0 established this from the opcode set at anchors.cpp and '
    + 'verify_node_client_surface_narrow asserts it by name. A query here would mean that '
    + 'measurement is wrong.',
});

/** Why a value the AVM asked about was not seeded. Never absent; a skip always has a reason. */
export const SEED_SKIP_REASONS = [
  'emitted-by-this-transaction',
  'absent-on-chain-at-parent',
  'tree-not-answerable',
  'already-seeded',
] as const;
export type SeedSkipReason = (typeof SEED_SKIP_REASONS)[number];

/** One value seeded into the resident tree, and where it came from. */
export type SeededLeaf =
  | { readonly tree: 'nullifier'; readonly nullifier: Fr; readonly fromBlock: BlockNumber }
  | { readonly tree: 'public-data'; readonly slot: Fr; readonly value: Fr; readonly fromBlock: BlockNumber };

/** One value the AVM asked about and this module did not seed, with the reason it did not. */
export type SkippedQuery = {
  readonly treeId: number;
  readonly value: string;
  readonly reason: SeedSkipReason;
  readonly detail: string;
};

/**
 * The accumulated seed. A MAP KEYED BY VALUE, so a round can say what it ADDED rather than what it
 * holds — a loop whose termination condition is "the set stopped growing" needs the difference and
 * not the total.
 *
 * An entry whose payload is `null` is REMEMBERED-AS-ABSENT rather than missing. Without that the
 * loop asks the node the same unanswerable question every round and never terminates, and the
 * failure would read as "the AVM keeps asking for new state" rather than as a loop that cannot stop.
 */
export type ResidentSeed = {
  readonly nullifiers: Map<string, Fr | null>;
  readonly publicData: Map<string, { slot: Fr; value: Fr } | null>;
  readonly seeded: SeededLeaf[];
  readonly skipped: SkippedQuery[];
};

export function emptySeed(): ResidentSeed {
  return { nullifiers: new Map(), publicData: new Map(), seeded: [], skipped: [] };
}

/** How many leaves are actually IN the tree, as opposed to how many questions have been answered. */
export function seedSize(seed: ResidentSeed): { nullifiers: number; publicData: number } {
  let nullifiers = 0;
  let publicData = 0;
  for (const v of seed.nullifiers.values()) if (v !== null) nullifiers += 1;
  for (const v of seed.publicData.values()) if (v !== null) publicData += 1;
  return { nullifiers, publicData };
}

// ---------------------------------------------------------------------------------------------
// Answering a round's queries from the node
// ---------------------------------------------------------------------------------------------

/**
 * The node methods this module reaches. Both are already on L0's permitted fourteen and both are
 * members of `MembershipWitnessSource` — the seam L0 declared for exactly this, so L2 needs no
 * widening of the surface and no adapter.
 */
export const HYDRATION_METHODS = ['getPublicDataWitness', 'getNullifierMembershipWitness'] as const;

/** The witness source plus the block parameter shape both of its methods take. */
export type HistoricalStateSource = Pick<MembershipWitnessSource, (typeof HYDRATION_METHODS)[number]>;

/** What one round of answering did. `added` is the loop's termination signal and nothing else is. */
export type HydrationRound = {
  readonly round: number;
  readonly queries: number;
  readonly added: number;
  readonly seeded: readonly SeededLeaf[];
  readonly skipped: readonly SkippedQuery[];
  /**
   * The module's own sentence, when this round's simulate threw. PRESENT RATHER THAN SWALLOWED:
   * a round that refuses and says nothing reads as a smaller round instead of a red one, which is
   * this campaign's most-repeated defect and was live in this very loop until a live run spent
   * twelve rounds reporting "0 queries, 0 seeded" over a module that had been naming the problem
   * every time.
   */
  readonly refusal?: string;
  /** Round 1 only: what the opening position seeded before any query had been reported. */
  readonly openingSeed?: { nullifiers: number; publicData: number };
};

/**
 * Answer every query a round made that has not been answered before, at `parentBlock`.
 *
 * `excludedNullifiers` and `excludedSlots` are the transaction's OWN emissions — see the module
 * header. They are passed in rather than derived here so that the exclusion is visible at the call
 * site: a caller that forgot them would get a replay that reverts on its own nullifier, and "the
 * replay reverted" is a much less informative failure than "this module was not told what the
 * transaction emitted".
 */
export async function answerQueries(
  source: HistoricalStateSource,
  parentBlock: BlockNumber,
  queries: readonly WorldStateQuery[],
  seed: ResidentSeed,
  excluded: { readonly nullifiers: ReadonlySet<string>; readonly slots: ReadonlySet<string> },
): Promise<{ added: number; seeded: SeededLeaf[]; skipped: SkippedQuery[] }> {
  const seeded: SeededLeaf[] = [];
  const skipped: SkippedQuery[] = [];
  let added = 0;

  for (const query of queries) {
    const value = query.value.toLowerCase();

    if (!ANSWERABLE_TREES.includes(query.treeId)) {
      skipped.push({
        treeId: query.treeId,
        value,
        reason: 'tree-not-answerable',
        detail: UNANSWERABLE_TREES[query.treeId] ?? `tree id ${query.treeId} is not a tree this module knows`,
      });
      continue;
    }

    if (query.treeId === MerkleTreeId.NULLIFIER_TREE) {
      if (excluded.nullifiers.has(value)) {
        skipped.push({ treeId: query.treeId, value, reason: 'emitted-by-this-transaction',
          detail: 'this transaction emitted it; seeding it would make the AVM find its own nullifier '
            + 'already present and revert — a replay failing because the transaction succeeded.' });
        continue;
      }
      if (seed.nullifiers.has(value)) { continue; }
      const witness = await source.getNullifierMembershipWitness(parentBlock, valueAsFr(value));
      if (witness === undefined || witness === null) {
        seed.nullifiers.set(value, null);
        skipped.push({ treeId: query.treeId, value, reason: 'absent-on-chain-at-parent',
          detail: `the chain did not hold this nullifier at block ${parentBlock}, so the AVM's own `
            + `"not present" answer is the CORRECT one and there is nothing to seed.` });
        continue;
      }
      seed.nullifiers.set(value, valueAsFr(value));
      const leaf: SeededLeaf = { tree: 'nullifier', nullifier: valueAsFr(value), fromBlock: parentBlock };
      seed.seeded.push(leaf);
      seeded.push(leaf);
      added += 1;
      continue;
    }

    // PUBLIC_DATA_TREE
    if (excluded.slots.has(value)) {
      // NOT a skip in the "nothing to do" sense: the slot IS seeded, from the parent, by
      // `seedWriteSetPreImages`. What is excluded is taking the PUBLISHED value, which is the answer
      // and not the input.
      continue;
    }
    if (seed.publicData.has(value)) { continue; }
    const witness = await source.getPublicDataWitness(parentBlock, valueAsFr(value));
    // UPSTREAM'S TYPES, NOT JSON. Through the client the response has been through upstream's own
    // zod, so `leafPreimage.leaf.slot` is an `Fr` and not a hex string — which is the whole point of
    // going through the client rather than raw `fetch`. A first version of this read
    // `typeof slot !== 'string'` and treated EVERY witness as absent: nine slots silently unseeded,
    // and the failure surfaced four layers away as the module refusing on the fee payer's balance.
    // `hexOf` reads either shape and refuses neither silently.
    const leafPreimage = (witness as { leafPreimage?: { leaf?: { slot?: unknown; value?: unknown } } } | undefined)
      ?.leafPreimage?.leaf;
    const witnessSlot = hexOf(leafPreimage?.slot);
    const witnessValue = hexOf(leafPreimage?.value);
    if (witnessSlot === undefined || witnessValue === undefined) {
      seed.publicData.set(value, null);
      skipped.push({ treeId: query.treeId, value, reason: 'absent-on-chain-at-parent',
        detail: `no public-data witness at block ${parentBlock}` });
      continue;
    }
    if (witnessSlot !== value) {
      // THE INDEXED TREE ANSWERED WITH THE PREDECESSOR, WHICH MEANS THE SLOT WAS EMPTY. Seeding the
      // predecessor's value would put a plausible number at the wrong slot — the exact shape of
      // wrong answer `resident_db.ts` compares the decoded slot to guard against, one layer up.
      seed.publicData.set(value, null);
      skipped.push({ treeId: query.treeId, value, reason: 'absent-on-chain-at-parent',
        detail: `the tree at block ${parentBlock} answered with the predecessor leaf `
          + `${witnessSlot}, so this slot was EMPTY. The AVM's zero is the correct value.` });
      continue;
    }
    const entry = { slot: valueAsFr(witnessSlot), value: valueAsFr(witnessValue) };
    seed.publicData.set(value, entry);
    const leaf: SeededLeaf = { tree: 'public-data', slot: entry.slot, value: entry.value, fromBlock: parentBlock };
    seed.seeded.push(leaf);
    seeded.push(leaf);
    added += 1;
  }

  return { added, seeded, skipped };
}

/**
 * `Fr` from a hex string, through the install this module is in.
 *
 * ONE CLASS OF `Fr` PER PROCESS — `resident_db.ts`'s header records the hazard and it applies here
 * verbatim: `serializeWithMessagePack` recognises an `Fr` by the class object of its OWN install, so
 * a value built anywhere else serialises as a plain object and the C++ side reads a field that is
 * not there. Everything this module hands a caller is built here.
 */
function valueAsFr(hex: string): Fr {
  return Fr.fromHexString(hex);
}

/**
 * A field element as either upstream's `Fr` or a hex string, normalised to lowercase hex.
 *
 * `undefined` for anything that is neither, and the caller turns that into a NAMED skip. It must
 * not answer `'0x0'` for an unreadable value: a zero is a legitimate leaf value on this chain — four
 * of the demo subject's nine writes are zeros — so a coerced zero would be indistinguishable from a
 * real one and would seed the right slot with a plausible wrong number.
 */
function hexOf(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value === 'string') return value.toLowerCase();
  if (typeof value === 'bigint' || typeof value === 'number') {
    return `0x${value.toString(16).padStart(64, '0')}`;
  }
  if (value instanceof Uint8Array) return `0x${Buffer.from(value).toString('hex')}`;
  if (typeof (value as { toString?: unknown }).toString === 'function') {
    const text = String(value).toLowerCase();
    return /^0x[0-9a-f]+$/.test(text) ? text : undefined;
  }
  return undefined;
}
