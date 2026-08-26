// chain.ts — the chain loop: blocks on a timer, empty blocks by default, one archive.
//
// WHAT IS OURS HERE IS SMALL AND THE ENUMERATION THAT ESTABLISHED THAT IS IN `CHAIN-LOOP.md`.
// Everything below either calls upstream's code or holds a list:
//
//   * the per-block transaction loop is upstream's `PublicProcessor.process`, reached through
//     M22's `assembleBlock` — not one line of it is here;
//   * the header and the archive chaining are upstream's `makeTXEBlockHeader`, vendored
//     byte-identically (RI-66), reached through M22's `sealBlock`;
//   * the clock is upstream's `DateProvider` / `ManualDateProvider` (`@aztec/foundation/timer`);
//   * the real-time ticker is upstream's `RunningPromise` (`@aztec/foundation/running-promise`),
//     which is what `Sequencer` and `AutomineSequencer` both tick on;
//   * `GlobalVariables`, `BlockHeader`, `AppendOnlyTreeSnapshot`, `StateReference`, `Tx` are all
//     `@aztec/stdlib`'s.
//
// What is left is this file: a block number, a timestamp rule, a queue, an archive cursor and a
// list of blocks. That is the shape the milestone predicted and it is recorded rather than
// asserted — `verify_sequencer_reuse_enumeration_recorded` re-derives the enumeration from the
// fork on every run.
//
// WHY NOT `AutomineSequencer`. RI-41 reserved the verdict for a MEASUREMENT rather than an
// argument, and the measurement is decisive: six of its seven public entry points reach anvil
// cheat codes or the rollup publisher — `buildIfPending` and `buildEmptyBlock` go through
// `runBuild`, which calls `ethCheatCodes.setNextBlockTimestamp` and `publisher.sendRequests`;
// `warpTo`/`warpBy` call `setNextBlockTimestamp` and then `runBuild`; `prove` calls
// `RollupCheatCodes.markAsProven` and `evmMine`; `revertToCheckpoint` calls `ethCheatCodes.reorg`
// and `anvil_dropAllTransactions`. The seventh, `syncPoint()`, drains a `SerialQueue` and performs
// no chain operation at all. Its own README states the requirement in terms: "the deployed rollup
// must have `aztecTargetCommitteeSize == 0`". So the rejection is `cannot-reach-target`, the
// target is a runtime with no L1 and no anvil, and the blocker is named per operation rather than
// per package. Its SHAPE is taken: a serialised queue, an explicit empty-block entry point, an
// injected date provider reconciled to an external time source, and a poller with a `trigger()`.
//
// THE ARCHIVE IS THE CHAIN. A chain is not a list of blocks, it is a list of blocks each of which
// commits to the one before. That commitment is the archive tree: block N's header carries
// `lastArchive`, the archive's snapshot BEFORE the block, and sealing appends the header's hash.
// M22 could not do this and said so; M23 carries M14's extension into the module
// (`verification/m23/`) and `sealBlock` succeeds. A chain whose seal refuses is not a chain, which
// is why the archive was on this milestone's critical path rather than on M22's.

import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { Fr } from '@aztec/foundation/curves/bn254';
import { GasFees } from '@aztec/stdlib/gas';
import { MerkleTreeId } from '@aztec/stdlib/trees';
import type { AppendOnlyTreeSnapshot } from '@aztec/stdlib/trees';
import { BlockNumber } from '@aztec/foundation/branded-types';
import { GlobalVariables } from '@aztec/stdlib/tx';
import type { BlockHeader, ProcessedTx, StateReference, Tx } from '@aztec/stdlib/tx';

import { assembleBlock, sealBlock, type SealRefusal } from './block_assembly.ts';
import type { PublicProcessor } from './vendor/public_processor/public_processor.ts';
import type { GuardedMerkleTreeOperations } from './vendor/public_processor/guarded_merkle_tree.ts';
import type { ResidentContractsDB } from './resident_contracts_db.ts';
import type { ResidentMerkleWriteOperations } from './resident_merkle_operations.ts';
import {
  DateProvider,
  DisabledTicker,
  RunningPromiseTicker,
  nextBlockTimestamp,
  type BlockTicker,
} from './chain_clock.ts';

/**
 * How blocks are produced. The milestone's four fields, plus the spacing the timestamp rule needs.
 */
export interface BlockProductionConfig {
  /** Milliseconds between timer-driven blocks. **0 disables the timer** — manual mode. */
  readonly intervalMs: number;
  /** Produce a block even when nothing is queued. Default TRUE; this is the point of the timer. */
  readonly produceEmptyBlocks: boolean;
  /** Seal a block immediately on submission rather than waiting for the tick. */
  readonly automine: boolean;
  /** Upper bound on transactions per block. Handed to upstream's `maxTransactions` limit. */
  readonly maxTxsPerBlock: number;
  /**
   * The minimum number of seconds between two block timestamps.
   *
   * 1 by default, which makes `nextBlockTimestamp` strictly increasing whatever the host clock
   * does — see `chain_clock.ts`. Zero is accepted and is not silently corrected.
   */
  readonly minBlockSpacingSeconds: number;
}

export const DEFAULT_BLOCK_PRODUCTION: BlockProductionConfig = Object.freeze({
  intervalMs: 1000,
  produceEmptyBlocks: true,
  automine: false,
  maxTxsPerBlock: 64,
  minBlockSpacingSeconds: 1,
});

/**
 * One produced block.
 *
 * The header, the archive either side of it and the four-tree state reference are upstream's own
 * types. `wallClockSeconds` and `wallClockDeviationSeconds` are ours, and they exist because the
 * milestone requires the deviation from the wall clock to be **declared rather than hidden**: when
 * the timer runs faster than a second, or a browser tab throttles it, `timestamp` is not
 * `floor(now/1000)` and a reader of the chain should be able to see by how much without
 * recomputing it.
 */
export interface ChainBlock {
  readonly number: number;
  readonly timestamp: bigint;
  readonly wallClockSeconds: bigint;
  readonly wallClockDeviationSeconds: bigint;
  readonly globalVariables: GlobalVariables;
  readonly header: BlockHeader;
  /** The archive BEFORE this block — the header's `lastArchive`. */
  readonly archiveBefore: AppendOnlyTreeSnapshot;
  /** The archive AFTER this block's header was appended. */
  readonly archiveAfter: AppendOnlyTreeSnapshot;
  readonly stateReference: StateReference;
  readonly txHashes: readonly string[];
  /**
   * The transactions this block PROCESSED, as upstream's own `Tx` objects.
   *
   * Kept beside `processed` because `ProcessedTx` is the loop's OUTPUT and does not carry the
   * transaction: a snapshot has to re-serialise what was submitted, and `ProcessedTx.hash` is a
   * hash. Found by hash out of the block's own input rather than reconstructed.
   */
  readonly txs: readonly Tx[];
  readonly failedTxHashes: readonly string[];
  /** True when the block carried no transactions at all. */
  readonly empty: boolean;
  /** L1-to-L2 messages appended at this block's boundary. */
  readonly l1ToL2Messages: readonly string[];
  readonly processed: readonly ProcessedTx[];
}

/**
 * What a block did with a transaction.
 *
 * `queued` is a VALUE and not an absence, so a receipt read before any block has been produced
 * cannot be mistaken for one whose transaction the block dropped. `unprocessed` means the block
 * reached its limits before this transaction; it is back in the queue and will be tried again.
 */
export type TxOutcomeRecord =
  | { readonly kind: 'queued' }
  | { readonly kind: 'processed'; readonly blockNumber: number }
  | { readonly kind: 'failed'; readonly blockNumber: number; readonly error: string }
  | { readonly kind: 'unprocessed'; readonly blockNumber: number };

/** Emitted per transaction, after the block it landed in was sealed. */
export interface TxEvent {
  readonly txHash: string;
  readonly blockNumber: number;
  readonly outcome: 'processed' | 'failed' | 'unprocessed';
  readonly error?: string;
}

/**
 * Emitted per transaction, carrying what the module recorded about its execution.
 *
 * NOT A PLACEHOLDER AND NOT THE `.ct` WRITER. M24 and M25 own the trace format and the step-level
 * binding; what this carries today is one number the module itself produced —
 * `avm_steps_count` — so the subscription delivers a MEASUREMENT rather than an empty envelope.
 * `steps` is `null` when the runtime was given no step-count source, which is the browser case
 * until M27, and that is distinguishable from zero.
 */
export interface TraceEvent {
  readonly txHash: string;
  readonly blockNumber: number;
  readonly steps: number | null;
}

export type ChainSubscription = 'block' | 'tx' | 'trace';

/**
 * Options for one block.
 *
 * `timestamp` is the REPLAY path and nothing else uses it: a snapshot records the timestamps its
 * blocks had, and a replay that recomputed them from a fresh clock would produce different headers
 * and therefore a different archive — a chain that is not the same chain. TXE has the same need
 * and meets it with `advanceTimestampBy`; this is the same thing said once per block instead of as
 * a delta, because a delta needs the previous value to be right as well.
 *
 * Monotonicity is still enforced: an override that does not advance the chain is refused.
 */
export interface ProduceBlockOptions {
  readonly timestamp?: bigint;
}

/** Thrown when a block cannot be sealed. A chain whose seal refuses is not a chain. */
export class ChainSealRefused extends Error {
  readonly kind = 'chain-seal-refused' as const;
  readonly refusal: SealRefusal;
  constructor(refusal: SealRefusal) {
    super(`the block could not be sealed: ${refusal.method} — ${refusal.reason}`);
    this.name = 'ChainSealRefused';
    this.refusal = refusal;
  }
}

/**
 * Everything the chain needs from the world below it.
 *
 * STRUCTURAL, for M28's reason: the browser host is a second implementation of this and not a
 * subclass. `makeProcessor` is a FACTORY rather than a processor, because upstream's
 * `PublicProcessor` binds its `GlobalVariables` at construction — a processor is per block, not
 * per chain, and pretending otherwise would put block N's timestamp inside block N+1's
 * transactions.
 */
export interface ChainDeps {
  readonly merkleDb: ResidentMerkleWriteOperations;
  readonly contractsDb: ResidentContractsDB;
  makeProcessor(globals: GlobalVariables): { processor: PublicProcessor; guarded: GuardedMerkleTreeOperations };
  /** The module's step counter, if the host exposes one. See `TraceEvent`. */
  readonly stepCount?: () => number;
  /** Injected. Defaults to upstream's real `DateProvider`, never to `Date.now()` written here. */
  readonly clock?: DateProvider;
  /** Injected. Defaults to `RunningPromiseTicker`, or `DisabledTicker` when `intervalMs` is 0. */
  readonly ticker?: BlockTicker;
}

/**
 * The chain.
 *
 * One instance owns one world state and one archive. It is not re-entrant: `produceBlock` takes a
 * lock and a second concurrent call waits, because two blocks built against one set of trees would
 * both read the same `lastArchive` and the second's seal would be refused by the module — which is
 * the right failure but a confusing one to debug.
 */
export class AvmChain {
  readonly config: BlockProductionConfig;
  readonly clock: DateProvider;
  readonly ticker: BlockTicker;

  private readonly deps: ChainDeps;
  private readonly produced: ChainBlock[] = [];
  private readonly queue: Tx[] = [];
  private readonly pendingMessages: Fr[] = [];
  private readonly subscribers: Record<ChainSubscription, ((event: never) => void)[]> = {
    block: [],
    tx: [],
    trace: [],
  };

  private readonly outcomes = new Map<string, TxOutcomeRecord>();
  private lastTimestamp = 0n;
  private producing: Promise<ChainBlock | null> | null = null;
  private stopped = false;

  constructor(deps: ChainDeps, config: Partial<BlockProductionConfig> = {}) {
    this.deps = deps;
    this.config = Object.freeze({ ...DEFAULT_BLOCK_PRODUCTION, ...config });
    this.clock = deps.clock ?? new DateProvider();
    this.ticker =
      deps.ticker ?? (this.config.intervalMs > 0 ? new RunningPromiseTicker(this.config.intervalMs) : new DisabledTicker());
  }

  // -- state queries -------------------------------------------------------------------------

  /** The number of the last produced block. 0 means genesis only — no block has been produced. */
  get blockNumber(): number {
    return this.produced.length === 0 ? 0 : this.produced[this.produced.length - 1].number;
  }

  get blocks(): readonly ChainBlock[] {
    return this.produced;
  }

  get lastBlockTimestamp(): bigint {
    return this.lastTimestamp;
  }

  /** The timestamp the NEXT block would get if it were produced now. TXE's `getNextBlockTimestamp`. */
  get nextBlockTimestamp(): bigint {
    return nextBlockTimestamp(this.lastTimestamp, this.clock, this.config.minBlockSpacingSeconds);
  }

  get nextBlockNumber(): number {
    return this.blockNumber + 1;
  }

  /** Transactions waiting for a block. */
  get pending(): readonly Tx[] {
    return this.queue;
  }

  /** What a block did with a transaction, by hash. `queued` until a block has seen it. */
  outcomeOf(txHash: string): TxOutcomeRecord {
    return this.outcomes.get(txHash) ?? { kind: 'queued' };
  }

  /** L1-to-L2 messages waiting for the next block boundary. */
  get pendingL1ToL2Messages(): readonly Fr[] {
    return this.pendingMessages;
  }

  /** The archive as it stands. This is the chain's identity. */
  archive(): AppendOnlyTreeSnapshot {
    return this.deps.merkleDb.archiveSnapshot();
  }

  stateReference(): Promise<StateReference> {
    return this.deps.merkleDb.getStateReference();
  }

  // -- submission ----------------------------------------------------------------------------

  /**
   * Queue a transaction.
   *
   * With `automine` on it returns only once a block carrying the transaction has been sealed —
   * which is what `e2e_automine_seals_on_submission` measures, by comparing the block number
   * before and after against a run with automine off.
   */
  async submit(tx: Tx): Promise<void> {
    this.requireRunning();
    this.queue.push(tx);
    if (this.config.automine) {
      await this.produceBlock();
    }
  }

  /**
   * Append an L1-to-L2 message at the NEXT block boundary.
   *
   * The declared stand-in for the real L1 inbox. TXE's `sendL1ToL2Message(content, secretHash,
   * sender, recipient)` computes the leaf from four parts; this takes the leaf, because the four
   * parts are an L1 contract's concern and there is no L1 here. The BOUNDARY semantics are TXE's:
   * `mineBlock({l1ToL2Messages})` appends them as part of producing a block, so a message injected
   * during block N is visible to block N+1 and not to the remainder of N.
   */
  injectL1ToL2Message(leaf: Fr): void {
    this.requireRunning();
    this.pendingMessages.push(leaf);
  }

  // -- production ----------------------------------------------------------------------------

  /**
   * Produce one block.
   *
   * Returns `null` when there was nothing to do — no queued transactions and
   * `produceEmptyBlocks: false`. Everything else produces a block, seals it, and advances the
   * archive.
   */
  produceBlock(options: ProduceBlockOptions = {}): Promise<ChainBlock | null> {
    // Serialised, `AutomineSequencer`'s `SerialQueue` property without its queue: two blocks built
    // against one set of trees would read the same `lastArchive` and the module would refuse the
    // second seal.
    const run = (this.producing ?? Promise.resolve(null)).then(() => this.produceBlockInner(options));
    this.producing = run.catch(() => null);
    return run;
  }

  private async produceBlockInner(options: ProduceBlockOptions): Promise<ChainBlock | null> {
    this.requireRunning();
    const txs = this.queue.splice(0, this.config.maxTxsPerBlock);
    if (txs.length === 0 && !this.config.produceEmptyBlocks) {
      return null;
    }

    const wallClockSeconds = BigInt(this.clock.nowInSeconds());
    const timestamp = options.timestamp ?? nextBlockTimestamp(this.lastTimestamp, this.clock, this.config.minBlockSpacingSeconds);
    // MONOTONICITY IS ENFORCED FOR THE OVERRIDE TOO. A replay supplies the timestamps it recorded;
    // if it supplied one that went backwards the chain would accept a header that could not have
    // been produced, which is the one thing a replay must not be able to do.
    if (timestamp <= this.lastTimestamp && this.produced.length > 0) {
      throw new Error(
        `block ${this.nextBlockNumber} would have timestamp ${timestamp}, `
          + `which is not after block ${this.blockNumber}'s ${this.lastTimestamp}`,
      );
    }
    const number = this.nextBlockNumber;
    const globals = this.globalsFor(number, timestamp);

    // The messages, at the boundary and BEFORE the block's transactions, so that a transaction in
    // this block can read a message injected before it. That is the ordering `mineBlock` uses.
    const messages = this.pendingMessages.splice(0, this.pendingMessages.length);
    if (messages.length > 0) {
      await this.deps.merkleDb.appendLeaves(MerkleTreeId.L1_TO_L2_MESSAGE_TREE, messages);
    }

    const { processor, guarded } = this.deps.makeProcessor(globals);
    const assembled = await assembleBlock(processor, txs, this.deps.contractsDb, this.deps.merkleDb, {
      limits: { maxTransactions: this.config.maxTxsPerBlock },
    });

    const archiveBefore = this.deps.merkleDb.archiveSnapshot();
    const outcome = await sealBlock(guarded, globals);
    if (!outcome.sealed) {
      throw new ChainSealRefused(outcome.refusal);
    }
    const archiveAfter = this.deps.merkleDb.archiveSnapshot();
    const processedHashes = assembled.processed.map(p => p.hash.toString());

    const block: ChainBlock = {
      number,
      timestamp,
      wallClockSeconds,
      wallClockDeviationSeconds: timestamp - wallClockSeconds,
      globalVariables: globals,
      header: outcome.header,
      archiveBefore,
      archiveAfter,
      stateReference: assembled.stateReference,
      txHashes: processedHashes,
      txs: txs.filter(t => processedHashes.includes(t.getTxHash().toString())),
      failedTxHashes: assembled.failed.map(f => f.tx.getTxHash().toString()),
      empty: txs.length === 0,
      l1ToL2Messages: messages.map(m => m.toString()),
      processed: assembled.processed,
    };

    this.lastTimestamp = timestamp;
    this.produced.push(block);

    for (const hash of block.txHashes) {
      this.outcomes.set(hash, { kind: 'processed', blockNumber: number });
    }
    for (const f of assembled.failed) {
      this.outcomes.set(f.tx.getTxHash().toString(), {
        kind: 'failed',
        blockNumber: number,
        error: f.error.message,
      });
    }
    for (const t of assembled.unprocessed) {
      this.outcomes.set(t.getTxHash().toString(), { kind: 'unprocessed', blockNumber: number });
    }

    // Transactions the block did not reach go back to the front of the queue, in order. Upstream's
    // own limit loop calls them "unprocessed" and M22 showed them requeueable; this is that,
    // automatically.
    if (assembled.unprocessed.length > 0) {
      this.queue.unshift(...(assembled.unprocessed as Tx[]));
    }

    this.emitBlockEvents(block, assembled.failed.map(f => ({ hash: f.tx.getTxHash().toString(), error: f.error })));
    return block;
  }

  // -- lifecycle -----------------------------------------------------------------------------

  /** Start the timer. With `intervalMs: 0` this arms `trigger()` and nothing else. */
  start(): void {
    this.requireRunning();
    this.ticker.start(async () => {
      await this.produceBlock();
    });
  }

  async stop(): Promise<void> {
    this.stopped = true;
    await this.ticker.stop();
  }

  get running(): boolean {
    return !this.stopped;
  }

  // -- subscriptions -------------------------------------------------------------------------

  subscribe(kind: 'block', fn: (event: ChainBlock) => void): () => void;
  subscribe(kind: 'tx', fn: (event: TxEvent) => void): () => void;
  subscribe(kind: 'trace', fn: (event: TraceEvent) => void): () => void;
  subscribe(kind: ChainSubscription, fn: (event: never) => void): () => void {
    const list = this.subscribers[kind];
    if (!list) {
      throw new Error(`no such subscription: ${kind}`);
    }
    list.push(fn);
    return () => {
      const at = list.indexOf(fn);
      if (at >= 0) {
        list.splice(at, 1);
      }
    };
  }

  private emitBlockEvents(block: ChainBlock, failed: { hash: string; error: Error }[]): void {
    for (const fn of this.subscribers.block) {
      (fn as (e: ChainBlock) => void)(block);
    }
    const steps = this.deps.stepCount ? this.deps.stepCount() : null;
    for (const hash of block.txHashes) {
      for (const fn of this.subscribers.tx) {
        (fn as (e: TxEvent) => void)({ txHash: hash, blockNumber: block.number, outcome: 'processed' });
      }
      for (const fn of this.subscribers.trace) {
        (fn as (e: TraceEvent) => void)({ txHash: hash, blockNumber: block.number, steps });
      }
    }
    for (const f of failed) {
      for (const fn of this.subscribers.tx) {
        (fn as (e: TxEvent) => void)({
          txHash: f.hash,
          blockNumber: block.number,
          outcome: 'failed',
          error: f.error.message,
        });
      }
    }
  }

  // -- internals -----------------------------------------------------------------------------

  private requireRunning(): void {
    if (this.stopped) {
      throw new Error('this chain has been stopped');
    }
  }

  /**
   * The block's `GlobalVariables`.
   *
   * `GlobalVariables.from` over `GlobalVariables.empty()`, so every field this runtime does not
   * decide keeps upstream's own empty value rather than a constant chosen here. The gas fees are
   * non-zero for M20's measured reason: with `GasFees(0, 0)` every transaction fee is zero, every
   * balance is sufficient including an empty one, and a chain built on that would look like it
   * enforced fees while never exercising the path.
   *
   * `slotNumber` is deliberately left at `empty()`'s value. A slot is an L1 concept — upstream
   * derives it with `getTimestampForSlot(slot, {slotDuration, l1GenesisTime})` — and inventing one
   * here would be inventing an L1 genesis time. §8.4's disclosure covers exactly this class of
   * simplification.
   */
  private globalsFor(blockNumber: number, timestamp: bigint): GlobalVariables {
    const empty = GlobalVariables.empty();
    return GlobalVariables.from({
      ...empty,
      blockNumber: BlockNumber(blockNumber),
      timestamp,
      gasFees: new GasFees(1n, 1n),
      coinbase: empty.coinbase,
      feeRecipient: AztecAddress.ZERO,
    });
  }
}
