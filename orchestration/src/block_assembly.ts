// block_assembly.ts — a block, out of upstream's own block orchestration.
//
// THE LOOP IS NOT HERE, AND THAT IS THE DELIVERABLE. M22's first line reads: "`PublicProcessor.
// process` driving a block: a fork checkpoint per transaction, dispatch on `tx.hasPublicCalls()`,
// then commit or revert. *This class is upstream's, imported at HEAD by four production
// consumers*, and is reused rather than reimplemented." So what is in this file is a
// CONSTRUCTOR CALL and a seal, and every one of the following is upstream's code running
// unmodified inside `vendor/public_processor/public_processor.ts`:
//
//   * `await ForkCheckpoint.new(this.guardedMerkleTree.getUnderlyingFork())` per transaction,
//     with `this.contractsDB.createCheckpoint()` beside it;
//   * the dispatch — `tx.hasPublicCalls() ? processTxWithPublicCalls : processPrivateOnlyTx`;
//   * `checkpoint.commit()` in a `finally`, and `checkpoint.revertToCheckpoint()` on the error
//     path, with `ForkCheckpoint`'s own once-only lifecycle making the pair safe;
//   * `checkWorldStateUnchanged(startStateReference, …)` after every failure, which is the
//     mechanism behind `test_failed_tx_leaves_no_state` and is upstream's, not ours;
//   * all five limits — `maxTransactions`, `deadline`, `maxBlockGas`, `maxBlobFields`, `signal` —
//     including the two-sided gas rule (declared limits while building a proposal, actual gas
//     while re-executing) that a reimplementation would have collapsed into one;
//   * the interrupt path: cancel the simulator, `stop()` the guarded fork, revert to the
//     checkpoint's depth, and break.
//
// If you are reading this file looking for that loop, it is not missing. It is forty lines up the
// import graph, in a file whose provenance header names the commit it came from.
//
// WHAT IS OURS HERE IS THE WIRING AND THE SEAL:
//
//   * the two resident databases (`resident_merkle_operations.ts`, `resident_contracts_db.ts`),
//     because the interface has exactly one implementation upstream and it is `@aztec/world-state`'s;
//   * the `GuardedMerkleTreeOperations` wrapper around the first of them — kept, DD-3, see below;
//   * the unprocessed-transaction set, which upstream's `process` does not return and which M22
//     asks to be shown REQUEUEABLE;
//   * `sealBlock`, which is upstream's TXE block-creation helper plus the guard stop.
//
// DD-3 — `GuardedMerkleTreeOperations` IS KEPT, AND HERE IS WHAT IT STILL DOES.
// Its header says it exists because "if transaction execution goes past the deadline, the
// simulator will continue to execute and update the world state" — a NAPI worker thread the
// sequencer cannot join. There is no worker thread here: `avm.wasm` runs to completion on the
// caller's stack, which is why `WasmAvmPublicTxSimulator` deliberately does not implement the
// optional `cancel`. So the class's ORIGINAL reason has evaporated, exactly as the deliverable
// says, and it is VESTIGIAL in that specific sense and in no other.
//
// It is kept for three reasons, and none of them is inertia:
//
//   1. IT STILL ENFORCES THE PROPERTY THE BLOCK NEEDS. `stop()` makes every subsequent call
//      throw `Merkle tree access has been stopped`, which is "no world-state access after the
//      block is sealed" — a rule that has nothing to do with threads. `sealBlock` calls it, and
//      `test_guarded_merkle_tree_blocks_post_seal_access` runs the SAME operation against a
//      stopped guard and against the unguarded database underneath it, because a check that only
//      ever saw the refusal would be measuring an absence rather than a guard.
//   2. DELETING IT MEANS DIVERGING FROM UPSTREAM FOR NO GAIN. `PublicProcessor` takes a
//      `GuardedMerkleTreeOperations` by type, calls `getUnderlyingFork()` in two places and
//      `stop()` in one. Removing it is an edit to a vendored file that buys nothing and that
//      `check-drift` would then have to carry forever.
//   3. THE SERIAL QUEUE IS NOT VESTIGIAL EVEN IF THE THREAD IS. Every forwarded call goes through
//      `SerialQueue.put`, so world-state operations from concurrently-awaited frames cannot
//      interleave. A wasm instance runs to completion, but the TypeScript above it is `async` and
//      two overlapping `process()` calls on one fork are a caller error the queue turns into an
//      ordering rather than a corruption.
//
// THE ARCHIVE IS WHERE THIS STOPS SHORT, AND IT IS SAID HERE RATHER THAN DISCOVERED IN A LOG.
// `sealBlock` is upstream's `makeTXEBlockHeader` — `getStateReference()`, `getTreeInfo(ARCHIVE)`,
// then `updateArchive(header)`. The middle call is the one the shipped module cannot serve, for
// the reason `resident_merkle_operations.ts` sets out at length: M14 decided to EXTEND
// `world_state_reference` with the archive tree (RI-53), the patch exists at `verification/m14/`,
// and it is not carried into the AVM_WASM overlay stack. So `sealBlock` reports
// `{ sealed: false, refusal }` naming the method and the reason, rather than producing a header
// with an invented `lastArchive`. The block's four-tree `StateReference` IS produced and IS
// correct — it comes from `avm_merkle_db_get_tree_roots` — so everything a block carries except
// its chain coordinate is available today.

import type { DateProvider } from '@aztec/foundation/timer';
import type { PublicProcessorLimits, PublicProcessorValidator } from '@aztec/stdlib/interfaces/server';
import type { DebugLog } from '@aztec/stdlib/logs';
import type { GlobalVariables, NestedProcessReturnValues, ProcessedTx, StateReference, Tx } from '@aztec/stdlib/tx';

import { GuardedMerkleTreeOperations } from './vendor/public_processor/guarded_merkle_tree.ts';
import { PublicProcessor } from './vendor/public_processor/public_processor.ts';
import { makeTXEBlockHeader } from './vendor/txe_block_creation.ts';
import { ResidentContractsDbCannotAnswer } from './resident_contracts_db.ts';
import type { ResidentContractsDB } from './resident_contracts_db.ts';
import { ResidentMerkleDbCannotAnswer } from './resident_merkle_operations.ts';
import type { ResidentMerkleWriteOperations } from './resident_merkle_operations.ts';
import type { PublicTxSimulatorLike } from './form_a.ts';

/** `FailedTx` in upstream's own shape: the transaction and the error that threw it out. */
export interface FailedTxRecord {
  readonly tx: Tx;
  readonly error: Error;
}

export interface BlockAssemblyOptions {
  /** Upstream's own limits type. Every field is optional there and every field is honoured. */
  readonly limits?: PublicProcessorLimits;
  readonly validator?: PublicProcessorValidator;
  readonly dateProvider?: DateProvider;
}

export interface AssembledBlock {
  /** Transactions that ran, in block order. Upstream's `ProcessedTx`. */
  readonly processed: readonly ProcessedTx[];
  /** Transactions the processor threw out, each with the error. Upstream's `FailedTx`. */
  readonly failed: readonly FailedTxRecord[];
  /**
   * Transactions that were never reached, in submission order.
   *
   * NOT a field upstream's `process` returns — it returns the ones it USED — and it is here
   * because M22 asks for the unprocessed set to be shown requeueable. It is derived by removing
   * the used and the failed from the input, so a transaction cannot be in two of the three sets;
   * `assembleBlock` asserts that partition rather than assuming it.
   */
  readonly unprocessed: readonly Tx[];
  readonly returns: readonly NestedProcessReturnValues[];
  readonly debugLogs: readonly DebugLog[];
  /** The four-tree state reference after the block's transactions, off the resident world state. */
  readonly stateReference: StateReference;
  /** What the deferred contract registrations flushed into the module, if anything. */
  readonly registrations: { readonly classes: number; readonly instances: number };
}

export interface SealRefusal {
  readonly method: string;
  readonly reason: string;
}

export type SealOutcome =
  | { readonly sealed: true; readonly header: Awaited<ReturnType<typeof makeTXEBlockHeader>> }
  | { readonly sealed: false; readonly refusal: SealRefusal };

/** Thrown when the input transactions and the processor's three output sets do not partition. */
export class BlockPartitionViolated extends Error {
  readonly kind = 'block-partition-violated' as const;
  constructor(message: string) {
    super(message);
    this.name = 'BlockPartitionViolated';
  }
}

/**
 * Build the `PublicProcessor` this runtime uses.
 *
 * Exported separately from `assembleBlock` so that a caller who wants upstream's loop with its own
 * transaction source gets it without going through ours — and so that
 * `test_public_processor_never_defaults_to_cpp`'s claim stays exact: the constructor is reached
 * through a function of ours that takes the simulator as an argument, never through a factory
 * that picks one.
 */
export function createBlockProcessor(
  globalVariables: GlobalVariables,
  merkleDb: ResidentMerkleWriteOperations,
  contractsDb: ResidentContractsDB,
  simulator: PublicTxSimulatorLike,
  dateProvider: DateProvider,
): { processor: PublicProcessor; guarded: GuardedMerkleTreeOperations } {
  // The guard wraps the resident database; upstream's own factory does exactly this, and the
  // processor then takes the guarded object and reaches the raw one through `getUnderlyingFork()`
  // for its per-transaction checkpoint — deliberately, so that `stop()` cannot strand a
  // checkpoint the loop still has to close.
  // `as never` HERE MEANS ONE THING AND IT IS WRITTEN DOWN. `GuardedMerkleTreeOperations` is typed
  // to a `MerkleTreeWriteOperations`, and `ResidentMerkleWriteOperations` deliberately is not one —
  // eight of its methods refuse, so declaring `implements` would be a claim of totality and M19's
  // review found exactly that defect in a mirror that claimed to be total and intercepted two of
  // four. The cast is the declaration of that substitution. It is `as never` rather than
  // `as unknown as MerkleTreeWriteOperations` only because the latter needs the type imported from
  // a package this file otherwise has no reason to name; both silence the same check, and neither
  // is a claim that the surfaces match.
  const guarded = new GuardedMerkleTreeOperations(merkleDb as never);
  const processor = new PublicProcessor(
    globalVariables,
    guarded,
    // `contractsDb as never`: the vendored processor narrows this parameter to
    // `ProcessorContractsDB`, which `ResidentContractsDB` satisfies except that its four READS
    // return `Promise<never>` rather than the declared value types — because they refuse. See
    // `resident_contracts_db.ts` for why refusing is the point.
    contractsDb as never,
    // `simulator as never`: `PublicTxSimulatorInterface` verbatim, minus the optional `cancel`
    // `WasmAvmPublicTxSimulator` deliberately does not implement (there is nothing to cancel).
    simulator as never,
    dateProvider,
  );
  return { processor, guarded };
}

/**
 * Run one block's worth of transactions through upstream's processor.
 *
 * The transactions are taken as an ARRAY rather than as the `Iterable`/`AsyncIterable` upstream
 * accepts, and that is load-bearing: the unprocessed set is only meaningful if the source can be
 * re-read after the loop stops, and an iterator that has been broken out of cannot be. A caller
 * with a stream can drain it first; the requeue property is about transactions, not about
 * plumbing.
 */
export async function assembleBlock(
  processor: PublicProcessor,
  txs: readonly Tx[],
  contractsDb: ResidentContractsDB,
  merkleDb: ResidentMerkleWriteOperations,
  options: BlockAssemblyOptions = {},
): Promise<AssembledBlock> {
  const [processed, failed, usedTxs, returns, debugLogs] = await processor.process(
    txs as Tx[],
    options.limits ?? {},
    options.validator ?? {},
  );

  // The partition, computed by transaction hash and CHECKED. A transaction that appeared in two
  // of the three sets, or in none, would make "the unprocessed ones are requeueable" a claim
  // about a set nobody had defined.
  const usedHashes = new Set(usedTxs.map(tx => tx.getTxHash().toString()));
  const failedHashes = new Set(failed.map(f => f.tx.getTxHash().toString()));
  const both = [...usedHashes].filter(h => failedHashes.has(h));
  if (both.length > 0) {
    throw new BlockPartitionViolated(`${both.length} transaction(s) are both used and failed: ${both.join(', ')}`);
  }
  const unprocessed = txs.filter(tx => {
    const h = tx.getTxHash().toString();
    return !usedHashes.has(h) && !failedHashes.has(h);
  });
  if (usedTxs.length + failed.length + unprocessed.length !== txs.length) {
    throw new BlockPartitionViolated(
      `used ${usedTxs.length} + failed ${failed.length} + unprocessed ${unprocessed.length} `
        + `!= ${txs.length} submitted`,
    );
  }

  // The deferred registrations. See the header: `addNewContracts` is synchronous by upstream's own
  // interface and the module's class registration needs an async bytecode commitment, so the queue
  // is drained here — after the block's transactions, which is why a contract published in this
  // block is callable in the NEXT one.
  const registrations = await contractsDb.flush();

  const stateReference = await merkleDb.getStateReference();

  return { processed, failed, unprocessed, returns, debugLogs, stateReference, registrations };
}

/**
 * Seal the block: build its header, chain it onto the archive, and stop the guard.
 *
 * The header construction is upstream's `makeTXEBlockHeader`, vendored unmodified — it reads the
 * state reference and the archive's own `TreeInfo` and assembles a `BlockHeader`. The archive read
 * is the one the shipped module refuses, so this function reports the refusal by name instead of
 * throwing it away or working around it.
 *
 * THE GUARD IS STOPPED EITHER WAY, and that is deliberate rather than an oversight in the failure
 * path. "No world-state access after the block is sealed" is a property of the ATTEMPT to seal:
 * once the sealer has read the state reference it intends to certify, a later write would
 * invalidate it whether or not the certificate was produced. `stopped` is reported so a caller can
 * see which happened.
 */
export async function sealBlock(
  guarded: GuardedMerkleTreeOperations,
  globalVariables: GlobalVariables,
): Promise<SealOutcome & { readonly stopped: true }> {
  let outcome: SealOutcome;
  try {
    // `guarded as never`: `makeTXEBlockHeader` takes a `MerkleTreeWriteOperations` and the guard IS
    // one — the cast is here because the guard wraps a target that is not, so the wrapper's own
    // declared type does not survive our substitution. Same substitution, one level up.
    const header = await makeTXEBlockHeader(guarded as never, globalVariables);
    await guarded.updateArchive(header);
    outcome = { sealed: true, header };
  } catch (error) {
    if (error instanceof ResidentMerkleDbCannotAnswer || error instanceof ResidentContractsDbCannotAnswer) {
      outcome = {
        sealed: false,
        refusal: {
          method: (error as { method: string }).method,
          reason: (error as { reason?: string }).reason ?? error.message,
        },
      };
    } else {
      // Anything this runtime does not recognise is rethrown unchanged, with its stack. Form A's
      // rule, for Form A's reason: a bug reported as a refusal is silent and gets shipped.
      await guarded.stop();
      throw error;
    }
  }
  await guarded.stop();
  return { ...outcome, stopped: true };
}
