// replay_execution.ts — L2: THE AVM EXECUTING A SETTLED TRANSACTION, AND THE COMPARISON THAT SAYS
// WHETHER IT SAW WHAT THAT TRANSACTION SAW.
//
// `historical_state.ts` establishes WHERE the state comes from and why the milestone's two routes
// are closed. This module is the loop that uses it, the declaration of what the roots are NOT, and
// the comparison against the chain's own published answer.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE ROOT CHECK EXISTS AND ITS ANSWER IS "NO", WHICH IS THE DELIVERABLE AND NOT A FAILURE.
//
// The milestone asks for "a root check: after hydration, the tree roots equal the block's state
// reference", with the reason "a wrong merkle root is worse than a missing one, because everything
// downstream believes it."
//
// THE ROOTS DO NOT MATCH AND THEY CANNOT. Route 3 seeds the leaves ONE TRANSACTION READS into a tree
// that starts at genesis with 128 prefilled leaves; the chain's tree at the same block holds over a
// million. A root is a function of every leaf, so a tree holding fifteen of them has a different
// root by construction, not by error.
//
// So the check is built, run, and REPORTS THE DIVERGENCE — and `declareTreeRoots` makes that
// statement a VALUE that travels with the outcome, because the milestone's own reason applies with
// the sign flipped: a recording that carried the chain's state reference in its metadata while its
// execution ran against a genesis-anchored tree would be a wrong root that everything downstream
// believes. L3 must render this, not hide it.
//
// WHAT IS ACTUALLY FAITHFUL, STATED PRECISELY SO NOBODY HAS TO INFER IT: the VALUES the transaction
// read are the chain's, at the settling block's parent, fetched per-slot; the MEMBERSHIP PROOFS
// around them are the resident tree's. Every AVM opcode this campaign's subjects use — SLOAD,
// SSTORE, NULLIFIEREXISTS, EMITNULLIFIER — is a question about a VALUE, and the AVM checks its
// proofs against its OWN tree's roots rather than against a root the transaction carries. That is
// why the execution is faithful and the roots are not, and it is a property to be measured per
// transaction rather than assumed: `compareToPublishedEffects` is the measurement.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// A FRESH MODULE PER ROUND, AND THE REASON IS NOT TIDINESS.
//
// The resident DB has no reset. A round that reused the previous round's tree would execute against
// the UNION of two seedings, so "the loop converged" would mean "the accumulated tree eventually
// answered everything" rather than "this seed is sufficient" — and the final run, the one whose
// outcome is reported, would be the only one that had ever had the whole seed. Instantiating a new
// module each round makes the reported run a run against exactly the reported seed.

import type { Fr } from '@aztec/foundation/curves/bn254';
import { BlockNumber } from '@aztec/foundation/branded-types';

import type { ExecutionStep } from '../../node-host/src/steps.ts';

import {
  HydrationDidNotConverge,
  IntraBlockPredecessorsUnavailable,
  ModuleRefusedReplay,
  answerQueries,
  emptySeed,
  seedSize,
  type HistoricalStateSource,
  type HydrationRound,
  type ResidentSeed,
  type WorldStateQuery,
} from './historical_state.ts';
import type { SettledTransaction } from './settled_transaction.ts';

// ---------------------------------------------------------------------------------------------
// The module, structurally
// ---------------------------------------------------------------------------------------------

/**
 * The narrow view of an AVM module a replay needs.
 *
 * STRUCTURAL, for the reason `AvmBoundary` and `ResidentPublicDataTree` are structural in the
 * sibling campaign: L4's browser host is a DIFFERENT IMPLEMENTATION over the same wasm, not a
 * subclass, and a nominal type would make the browser path a rewrite rather than an argument.
 *
 * `freshInstance` is a factory rather than an instance because of the per-round rule above: this
 * module must be able to get a module that has never been seeded, and only the host knows how.
 */
export interface ReplayAvmHost {
  /** A module with empty resident databases. Called once per hydration round. */
  freshInstance(): Promise<ReplayAvmInstance>;
}

/** One instantiated module, with its two resident database handles already made. */
export interface ReplayAvmInstance {
  registerContractClass(fields: {
    id: Fr; artifactHash: Fr; privateFunctionsRoot: Fr;
    packedBytecode: Buffer | Uint8Array; publicBytecodeCommitment: Fr;
  }): void;
  registerContractInstance(address: Fr, fields: Record<string, unknown>): void;
  insertNullifier(nullifier: Fr): void;
  insertPublicDataLeaf(slot: Fr, value: Fr): void;
  /** The four resident tree roots, as the module has them AFTER seeding. */
  treeRoots(): Record<string, unknown>;
  /** Upstream's msgpack input in, upstream's decoded result out. Throws on a module refusal. */
  simulate(input: Uint8Array): { revertCode: number; result: Record<string, unknown> };
  /**
   * The executed step stream of the LAST simulation, or `null` when collection was off.
   *
   * `null` RATHER THAN `[]`, and the distinction is upstream's own: `stepsFromOutcome` returns null
   * for "you did not ask" and an array for "this is what ran". Collapsing them would make a
   * misconfigured run indistinguishable from a transaction that executed nothing, which is exactly
   * the pair `ExecutedStepsUnusable` names separately.
   */
  executedSteps(): readonly ExecutionStep[] | null;
}

// ---------------------------------------------------------------------------------------------
// The roots, declared rather than compared away
// ---------------------------------------------------------------------------------------------

/** The four trees a `StateReference` names, in the order this module reports them. */
export const STATE_REFERENCE_TREES = [
  'noteHashTree', 'nullifierTree', 'publicDataTree', 'l1ToL2MessageTree',
] as const;

/**
 * What the resident tree's roots are, what the chain's were, and the statement that they differ.
 *
 * `agrees` is expected to be FALSE for every tree, and a check asserts that rather than tolerating
 * it — because the interesting failure is the other direction. A root that suddenly AGREED would
 * mean either that the module had grown a bulk import (in which case route 2 has reopened and the
 * milestone should say so) or, far more likely, that the comparison had degenerated into comparing
 * something with itself.
 */
export type TreeRootDeclaration = {
  readonly tree: string;
  readonly resident: string;
  readonly chain: string;
  readonly agrees: boolean;
};

export const TREE_ROOTS_DIVERGE_REASON =
  'The resident merkle DB starts at genesis with 128 prefilled indexed leaves and is seeded with '
  + 'ONLY the leaves this one transaction reads. The chain\'s trees at the same block hold over a '
  + 'million. A root is a function of every leaf, so these roots differ BY CONSTRUCTION. The VALUES '
  + 'the transaction read are the chain\'s, fetched per-slot at the settling block\'s parent; the '
  + 'MEMBERSHIP PROOFS around them are the resident tree\'s. Any consumer that renders this '
  + 'recording must say so: a trace carrying the chain\'s state reference beside an execution that '
  + 'ran against a genesis-anchored tree is a wrong root that everything downstream believes, which '
  + 'is the failure this campaign exists to prevent.';

/** Read both sets of roots and state the relationship. Never returns "matched" by omission. */
export function declareTreeRoots(
  instance: ReplayAvmInstance,
  settled: SettledTransaction,
): { readonly declarations: readonly TreeRootDeclaration[]; readonly anyAgrees: boolean; readonly reason: string } {
  const resident = instance.treeRoots();
  const state = settled.blockData.header.state;
  const chain: Record<string, string> = {
    noteHashTree: state.partial.noteHashTree.root.toString(),
    nullifierTree: state.partial.nullifierTree.root.toString(),
    publicDataTree: state.partial.publicDataTree.root.toString(),
    l1ToL2MessageTree: state.l1ToL2MessageTree.root.toString(),
  };
  const declarations = STATE_REFERENCE_TREES.map((tree) => {
    const residentRoot = normaliseRoot((resident as Record<string, unknown>)[tree]);
    const chainRoot = chain[tree]!.toLowerCase();
    return { tree, resident: residentRoot, chain: chainRoot, agrees: residentRoot === chainRoot };
  });
  return {
    declarations,
    anyAgrees: declarations.some((d) => d.agrees),
    reason: TREE_ROOTS_DIVERGE_REASON,
  };
}

function normaliseRoot(value: unknown): string {
  const root = (value as { root?: unknown })?.root ?? value;
  if (root instanceof Uint8Array) return `0x${Buffer.from(root).toString('hex')}`;
  return String(root).toLowerCase();
}

// ---------------------------------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------------------------------

/** One field the chain published and the replay reproduced, or did not. */
export type EffectComparison = {
  readonly field: string;
  readonly published: string;
  readonly replayed: string;
  readonly matches: boolean;
};

export type ReplayVerdict = {
  readonly comparisons: readonly EffectComparison[];
  readonly matched: number;
  readonly mismatched: number;
  /** True only when EVERY comparison matched and there was at least one. Never true vacuously. */
  readonly reproduced: boolean;
};

/**
 * Compare the replay against the transaction's own published `TxEffect`.
 *
 * THE COMPARISON IS THE CHECK THAT SEEDING WAS RIGHT, and it is the only one there can be. Route 3
 * cannot prove it seeded the correct state directly — the roots are its own, so a root comparison
 * says nothing. What it CAN do is re-derive the chain's published answer: if the replay writes the
 * same nine slots with the same nine values, burns the same fee and emits the same nullifier, then
 * every value it read on the way was the value the transaction read, or the arithmetic would have
 * diverged.
 *
 * `reproduced` requires `comparisons.length > 0`. A transaction with no public half produces no
 * comparisons, and "zero mismatches" over zero comparisons is the vacuous green this campaign has
 * shipped twice.
 */
export function compareToPublishedEffects(
  settled: SettledTransaction,
  outcome: { revertCode: number; result: Record<string, unknown> },
): ReplayVerdict {
  const published = settled.txEffect.data;
  const replayed = (outcome.result['publicTxEffect'] ?? {}) as Record<string, unknown>;
  const comparisons: EffectComparison[] = [];

  const add = (field: string, a: unknown, b: unknown) => {
    const pa = hexish(a);
    const pb = hexish(b);
    comparisons.push({ field, published: pa, replayed: pb, matches: pa === pb });
  };

  add('revertCode', settled.revertCode, outcome.revertCode);
  add('transactionFee', published.transactionFee, replayed['transactionFee']);

  const publishedWrites = published.publicDataWrites;
  const replayedWrites = (replayed['publicDataWrites'] ?? []) as { leafSlot?: unknown; value?: unknown }[];
  add('publicDataWrites.length', publishedWrites.length, replayedWrites.length);
  for (let i = 0; i < Math.max(publishedWrites.length, replayedWrites.length); i += 1) {
    add(`publicDataWrites[${i}].leafSlot`, publishedWrites[i]?.leafSlot, replayedWrites[i]?.leafSlot);
    add(`publicDataWrites[${i}].value`, publishedWrites[i]?.value, replayedWrites[i]?.value);
  }

  const publishedNullifiers = published.nullifiers;
  const replayedNullifiers = (replayed['nullifiers'] ?? []) as unknown[];
  add('nullifiers.length', publishedNullifiers.length, replayedNullifiers.length);
  for (let i = 0; i < Math.max(publishedNullifiers.length, replayedNullifiers.length); i += 1) {
    add(`nullifiers[${i}]`, publishedNullifiers[i], replayedNullifiers[i]);
  }

  const matched = comparisons.filter((c) => c.matches).length;
  return {
    comparisons,
    matched,
    mismatched: comparisons.length - matched,
    // `comparisons.length > 0` IS UNREACHABLE TODAY AND IS KEPT ANYWAY, WHICH IS A STATEMENT AND
    // NOT AN OVERSIGHT. `revertCode`, `transactionFee` and the two length comparisons are pushed
    // unconditionally above, so the array is never empty for any input this function can be given —
    // not even a transaction with no public half, which still yields eighteen comparisons. L2's
    // mutation arm M5 removes this clause and NO CHECK CAN SEE IT; that is recorded as a surviving
    // mutation rather than papered over. It stays because the day the comparison set becomes
    // conditional on the public half being present, the guard becomes live and what it prevents is
    // "zero mismatches over zero comparisons" — the vacuous green this campaign has shipped twice.
    reproduced: comparisons.length > 0 && matched === comparisons.length,
  };
}

function hexish(value: unknown): string {
  if (value === undefined || value === null) return '(absent)';
  if (typeof value === 'number' || typeof value === 'bigint') return String(value);
  if (value instanceof Uint8Array) return `0x${Buffer.from(value).toString('hex')}`;
  return String(value).toLowerCase();
}

// ---------------------------------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------------------------------

/** Upstream's own hint field, read out of the result. The AVM's report of its own reads. */
export function queriesFrom(result: Record<string, unknown>): WorldStateQuery[] {
  const hints = (result['hints'] ?? {}) as Record<string, unknown>;
  const raw = (hints['getPreviousValueIndexHints'] ?? []) as {
    treeId?: unknown; value?: unknown; alreadyPresent?: unknown;
  }[];
  return raw.map((h) => ({
    treeId: Number(h.treeId),
    value: hexish(h.value),
    alreadyPresent: h.alreadyPresent === true,
  }));
}

export type ReplayOptions = {
  /** How many rounds the loop may take before refusing. A bound, not a target. */
  readonly maxRounds?: number;
  /** Called after each round, so a caller can show progress without this module printing. */
  readonly onRound?: (round: HydrationRound) => void;
  /**
   * WHICH BLOCK THE PRE-STATE IS READ AT. Correct is the settling block's PARENT, which is the
   * default and the only value any real replay uses.
   *
   * EXPORTED FOR THE CONTROL AND FOR NOTHING ELSE, and named so that is impossible to miss —
   * `createUnguardedNodeClientForControls` and `resolvePublicContractsUnguardedForControls` are the
   * precedents and the reason is theirs: "re-execution reproduces the published effects" is worth
   * nothing unless something demonstrates what a replay against the WRONG state does. Set it to the
   * SETTLING block and every read returns the value the transaction ITSELF wrote, so a
   * read-modify-write increments an already-incremented counter and the comparison must fail.
   *
   * It is a MODE OF THE SUBJECT, not a second function: one loop, one seeding path, one comparison.
   * A control that ran different code would constrain the control's code and not the replay's.
   */
  readonly preStateBlockForControls?: 'parent' | 'settling-block';
};

export type ReplayOutcome = {
  /** The block every pre-state read was taken at. CARRIED, so a caller cannot mistake a control
   * run for a real one — see `ReplayOptions.preStateBlockForControls`. */
  readonly preStateBlock: number;
  readonly revertCode: number;
  readonly result: Record<string, unknown>;
  readonly rounds: readonly HydrationRound[];
  readonly seed: ResidentSeed;
  readonly seedSize: { nullifiers: number; publicData: number };
  readonly roots: ReturnType<typeof declareTreeRoots>;
  readonly verdict: ReplayVerdict;
  /** The AVM's own count, not a length this module measured. */
  readonly instructionsExecuted: number;
  /**
   * The executed step stream, carried so L3 does not have to re-run to get it.
   *
   * It is the FINAL round's, which is the run every other field describes — a stream from an
   * earlier round would be an execution against a partially hydrated tree, and the recording would
   * step through a program that never happened.
   */
  readonly steps: readonly ExecutionStep[] | null;
};

export const DEFAULT_MAX_ROUNDS = 12;

/**
 * Re-execute a settled transaction against the state it saw.
 *
 * Refuses rather than approximates in two places, and both are the campaign's own rule that a
 * refusal is a throw and never a plausible value:
 *
 *   * a transaction that is NOT first in its block — `IntraBlockPredecessorsUnavailable`;
 *   * a loop that did not settle — `HydrationDidNotConverge`. The last round's outcome IS an
 *     execution and it IS well-formed, which is precisely why it must not be returned.
 */
export async function replaySettledTransaction(
  host: ReplayAvmHost,
  source: HistoricalStateSource,
  settled: SettledTransaction,
  encodeInputs: (settled: SettledTransaction) => Uint8Array,
  options: ReplayOptions = {},
): Promise<ReplayOutcome> {
  if (settled.txIndexInBlock !== 0) {
    throw new IntraBlockPredecessorsUnavailable(
      settled.txHash, settled.l2BlockNumber, settled.txIndexInBlock);
  }
  // `parent` keeps its name because that is what it is in every real call. The control's value is
  // the settling block itself, and the variable is still the thing every read is taken at, so a
  // reader of the loop below does not have to hold two names for one idea.
  const parent = options.preStateBlockForControls === 'settling-block'
    ? BlockNumber(settled.l2BlockNumber)
    : BlockNumber(settled.l2BlockNumber - 1);
  const maxRounds = options.maxRounds ?? DEFAULT_MAX_ROUNDS;
  const inputBytes = encodeInputs(settled);

  const excluded = {
    nullifiers: new Set(settled.txEffect.data.nullifiers.map((n) => n.toString().toLowerCase())),
    slots: new Set(settled.txEffect.data.publicDataWrites.map((w) => w.leafSlot.toString().toLowerCase())),
  };

  const seed = emptySeed();
  const rounds: HydrationRound[] = [];
  let lastInstance: ReplayAvmInstance | undefined;
  let lastOutcome: { revertCode: number; result: Record<string, unknown> } | undefined;

  for (let round = 1; round <= maxRounds; round += 1) {
    const instance = await host.freshInstance();
    await applySeed(instance, settled, seed);

    let outcome: { revertCode: number; result: Record<string, unknown> } | undefined;
    let queries: WorldStateQuery[] = [];
    let refusal: string | undefined;
    try {
      outcome = instance.simulate(inputBytes);
      queries = queriesFrom(outcome.result);
    } catch (err) {
      // A ROUND THAT THREW IS NOT NECESSARILY A ROUND THAT FAILED. The first round runs against an
      // empty tree and the module refuses it — "Not enough balance for fee payer" is the usual
      // shape — and that refusal carries no hints, which is why round one is seeded from the write
      // set below rather than from queries the module never got far enough to report.
      //
      // BUT THE REASON IS KEPT, and that is this campaign's own rule turned on this file. The first
      // version of this loop wrote `catch { queries = [] }`, and a live run then spent twelve rounds
      // reporting "0 queries, 0 seeded" and died with `HydrationDidNotConverge` — a diagnosis that
      // was true and useless, over a module that had been saying exactly what was wrong every time.
      // A swallowed refusal reads as a smaller round rather than a red one.
      refusal = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
      queries = [];
    }

    if (round === 1) {
      // THE WRITE SET'S PRE-IMAGES AND THE DEPLOYMENT NULLIFIER, seeded once so the loop has
      // somewhere to start. Neither is a guess about what the transaction reads: a slot in the
      // write set was necessarily reachable, and M29 established that the AVM decides a contract
      // EXISTS by looking for its address nullifier.
      await seedOpeningPosition(source, parent, settled, seed);
    }

    const answered = await answerQueries(source, parent, queries, seed, excluded);
    const record: HydrationRound = {
      round, queries: queries.length, added: answered.added,
      seeded: answered.seeded, skipped: answered.skipped,
      ...(refusal === undefined ? {} : { refusal }),
      ...(round === 1 ? { openingSeed: seedSize(seed) } : {}),
    };
    rounds.push(record);
    options.onRound?.(record);

    // THE OPENING SEED COUNTS TOWARDS PROGRESS. Round 1's `answered.added` is over the queries the
    // module reported, and a module that refused before reporting any has none — so without this a
    // seeded opening position reads as no progress at all.
    const progress = answered.added + (round === 1 ? seedSize(seed).nullifiers + seedSize(seed).publicData : 0);

    if (round > 1 && progress === 0 && outcome !== undefined) {
      return finish(instance, outcome, settled, rounds, seed, parent);
    }
    if (round > 1 && progress === 0 && outcome === undefined) {
      // THE LOOP HAS SETTLED AND THE MODULE STILL REFUSES. That is not "did not converge" — it is a
      // replay this route cannot perform, and the module's own sentence is the whole diagnosis. The
      // first version of this function reported the convergence error here and threw away the
      // refusal, which named the wrong thing in the one place a reader would look.
      throw new ModuleRefusedReplay(settled.txHash, refusal ?? '(the module threw without a message)',
        rounds.length, seedSize(seed));
    }

    lastInstance = instance;
    lastOutcome = outcome;
  }

  throw new HydrationDidNotConverge(rounds.length, rounds[rounds.length - 1]?.added ?? -1);
  // `lastInstance`/`lastOutcome` are deliberately NOT returned on the failure path. They are a
  // well-formed execution against a partially hydrated tree, which is the artefact this campaign
  // ships by accident when it ships one.
  void lastInstance; void lastOutcome;
}

function finish(
  instance: ReplayAvmInstance,
  outcome: { revertCode: number; result: Record<string, unknown> },
  settled: SettledTransaction,
  rounds: HydrationRound[],
  seed: ResidentSeed,
  preStateBlock: number,
): ReplayOutcome {
  const stats = (outcome.result['stats'] ?? {}) as Record<string, unknown>;
  return {
    steps: instance.executedSteps(),
    preStateBlock,
    revertCode: outcome.revertCode,
    result: outcome.result,
    rounds,
    seed,
    seedSize: seedSize(seed),
    roots: declareTreeRoots(instance, settled),
    verdict: compareToPublishedEffects(settled, outcome),
    instructionsExecuted: Number(stats['total_instructions_executed'] ?? -1),
  };
}

/**
 * Register the contracts and insert the seed into a fresh instance.
 *
 * ONE SEEDING PATH, SHARED BY THE HYDRATION LOOP AND THE RECORDING PASS. The two-pass design below
 * only means anything if the second pass runs against exactly the tree the first one converged on,
 * and "exactly" is a property of construction here rather than of two code paths agreeing.
 */
export async function applySeed(
  instance: ReplayAvmInstance,
  settled: SettledTransaction,
  seed: ResidentSeed,
): Promise<void> {
  for (const contract of settled.contracts) {
    const cc = contract.contractClass!;
    instance.registerContractClass({
      id: cc.id, artifactHash: cc.artifactHash, privateFunctionsRoot: cc.privateFunctionsRoot,
      packedBytecode: cc.packedBytecode,
      publicBytecodeCommitment: await bytecodeCommitment(cc.packedBytecode),
    });
    const i = contract.instance!;
    instance.registerContractInstance(i.address as unknown as Fr, {
      salt: i.salt, deployer: i.deployer, currentContractClassId: i.currentContractClassId,
      originalContractClassId: i.originalContractClassId,
      initializationHash: i.initializationHash, immutablesHash: i.immutablesHash,
      publicKeys: i.publicKeys,
    });
  }
  for (const value of seed.nullifiers.values()) if (value !== null) instance.insertNullifier(value);
  for (const entry of seed.publicData.values()) {
    if (entry !== null) instance.insertPublicDataLeaf(entry.slot, entry.value);
  }
}

/**
 * THE TWO PASSES DISAGREED. A recording is not written over an execution nobody measured.
 *
 * The step pass runs with `collectHints` OFF (see `RECORDING_PASS_REASON`), so it is a genuinely
 * separate execution and not a re-read of the first one's result. That is exactly why it has to be
 * compared: two runs over one seed SHOULD be identical, and "should" is the word this campaign has
 * been burned by. Every field compared here is one a divergence would move.
 */
export class RecordingPassDiverged extends Error {
  readonly kind = 'replay-recording-pass-diverged' as const;
  readonly differences: readonly string[];

  constructor(txHash: string, differences: readonly string[]) {
    super(
      `the hydration pass and the step-collection pass of ${txHash} do not describe the same `
        + `execution: ${differences.join('; ')}. The two run over ONE seed and differ only in which `
        + `collection flags are set, so they must agree; a container written from the second pass `
        + `while the verdict came from the first would be a recording of one execution labelled `
        + `with another's outcome.`,
    );
    this.name = 'RecordingPassDiverged';
    this.differences = differences;
  }
}

/**
 * WHY THERE ARE TWO PASSES AT ALL, MEASURED IN THIS MILESTONE AND NOT EXPLAINED.
 *
 * The shipped module will not produce hints and an execution step stream in the same run. Measured
 * over the demo subject, four configurations, everything else held constant:
 *
 *   flags                         executionSteps   instructions   effects reproduced
 *   (none)                        array[181]       181            no
 *   statistics + publicInputs     array[181]       181            no
 *   hints                         NULL             345            YES
 *   hints + statistics + inputs   NULL             345            YES
 *
 * The 181/345 split is route 3 working: without hints the loop discovers nothing, the tree is
 * under-seeded and the transaction reverts early. The NULL is the finding — with `collect_hints`
 * on, `execution_steps` comes back absent rather than empty.
 *
 * THE CAUSE IS NOT ESTABLISHED AND IS NOT GUESSED AT HERE. `execution_steps` is not upstream's
 * field at all: `PublicSimulatorConfig` at `anchors.cpp` declares seven flags and
 * `collect_execution_steps` is not among them — it is M9's carried patch, gated on
 * `AVM_HAS_EXECUTION_OBSERVER`, and that patch's own harness sets the two flags independently
 * without declaring them exclusive. So this is recorded as a MEASUREMENT with the matrix above,
 * in the shape this campaign uses for `avm_steps_count()` answering 0 while the statistic says 345.
 *
 * The design follows the measurement rather than fighting it: pass one hydrates WITH hints, pass
 * two records WITHOUT them over the seed pass one converged on — and the two are compared, because
 * a second execution is a second execution.
 */
export const RECORDING_PASS_REASON =
  'The shipped module does not produce hints and an execution step stream in one run: with '
  + 'collectHints on, executionSteps comes back NULL. Measured over four configurations; cause not '
  + 'established. So hydration and recording are two passes over ONE seed, and their outcomes are '
  + 'compared rather than assumed equal.';

/** The step stream, plus the outcome the second pass produced, over an already-converged seed. */
export type RecordingPass = {
  readonly revertCode: number;
  readonly result: Record<string, unknown>;
  readonly steps: readonly ExecutionStep[] | null;
  readonly instructionsExecuted: number;
  readonly verdict: ReplayVerdict;
};

/**
 * Run the step-collection pass over a converged seed, and refuse if it is not the same execution.
 *
 * `encodeForRecording` is passed in for the same reason `encodeInputs` is: the encoder lives in
 * `replay_inputs.ts` and this module decides no field of it.
 */
export async function recordingPass(
  host: ReplayAvmHost,
  settled: SettledTransaction,
  hydrated: ReplayOutcome,
  encodeForRecording: (settled: SettledTransaction) => Uint8Array,
): Promise<RecordingPass> {
  const instance = await host.freshInstance();
  await applySeed(instance, settled, hydrated.seed);
  const outcome = instance.simulate(encodeForRecording(settled));
  const stats = (outcome.result['stats'] ?? {}) as Record<string, unknown>;
  const instructionsExecuted = Number(stats['total_instructions_executed'] ?? -1);
  const verdict = compareToPublishedEffects(settled, outcome);

  const differences: string[] = [];
  if (outcome.revertCode !== hydrated.revertCode) {
    differences.push(`revertCode ${hydrated.revertCode} vs ${outcome.revertCode}`);
  }
  if (instructionsExecuted !== hydrated.instructionsExecuted) {
    differences.push(
      `instructionsExecuted ${hydrated.instructionsExecuted} vs ${instructionsExecuted}`);
  }
  if (verdict.reproduced !== hydrated.verdict.reproduced) {
    differences.push(`reproduced ${hydrated.verdict.reproduced} vs ${verdict.reproduced}`);
  }
  if (verdict.matched !== hydrated.verdict.matched) {
    differences.push(`matched ${hydrated.verdict.matched} vs ${verdict.matched}`);
  }
  if (differences.length > 0) {
    throw new RecordingPassDiverged(settled.txHash, differences);
  }

  return {
    revertCode: outcome.revertCode,
    result: outcome.result,
    steps: instance.executedSteps(),
    instructionsExecuted,
    verdict,
  };
}

/** The opening seed. Kept separate so a check can assert it is not where the answers came from. */
async function seedOpeningPosition(
  source: HistoricalStateSource,
  parent: BlockNumber,
  settled: SettledTransaction,
  seed: ResidentSeed,
): Promise<void> {
  const writeSetQueries: WorldStateQuery[] = settled.txEffect.data.publicDataWrites.map((w) => ({
    treeId: 2, value: w.leafSlot.toString().toLowerCase(), alreadyPresent: false,
  }));
  // The write-set slots go through `answerQueries` with an EMPTY exclusion set, because here they
  // are being read at the PARENT — which is the one place the published slots are legitimate input.
  await answerQueries(source, parent, writeSetQueries, seed,
    { nullifiers: new Set<string>(), slots: new Set<string>() });

  for (const contract of settled.contracts) {
    const nullifier = await deploymentNullifier(contract.address);
    const key = nullifier.toString().toLowerCase();
    if (!seed.nullifiers.has(key)) {
      seed.nullifiers.set(key, nullifier);
      seed.seeded.push({ tree: 'nullifier', nullifier, fromBlock: parent });
    }
  }
}

// The two upstream helpers this module needs, imported at the bottom so the header above reads as
// documentation. Both are upstream's own; nothing here derives a hash.
import { computePublicBytecodeCommitment } from '@aztec/stdlib/contract';
import { siloNullifier } from '@aztec/stdlib/hash';
import { ProtocolContractAddress } from '@aztec/protocol-contracts';
import { Fr as FrValue } from '@aztec/foundation/curves/bn254';

function bytecodeCommitment(packedBytecode: Buffer): Promise<Fr> {
  return computePublicBytecodeCommitment(packedBytecode);
}

/** How the AVM decides a contract exists: its address, siloed by the instance registry. */
function deploymentNullifier(address: string): Promise<Fr> {
  return siloNullifier(ProtocolContractAddress.ContractInstanceRegistry, FrValue.fromHexString(address));
}
