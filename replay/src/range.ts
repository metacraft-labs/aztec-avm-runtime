// range.ts — L4: EVERY REPLAYABLE TRANSACTION, WITH A PER-TRANSACTION OUTCOME TABLE.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// WHAT "A RANGE" CAN MEAN HERE IS DECIDED BY MEASUREMENT, AND THE MEASUREMENT IS NARROW.
//
// The milestone asks for "a block, or a range of blocks, replayed unattended", and already knows
// the bound: "'every public transaction in a block' is only possible for blocks above
// `getBlockNumber('finalized')`, and a range over older ones meets `SettledTransactionNotFound` for
// transactions the block body still lists. That is the refusal behaving correctly, it is a
// PRECONDITION L4 CAN READ IN ONE PERMITTED CALL rather than discover per transaction, and it needs
// its own row in the outcome table."
//
// So the range is not a parameter to be chosen. **THE RANGE IS THE REPLAYABLE WINDOW**, and its two
// ends are read in two calls that are already among L0's permitted fourteen:
// `getBlockNumber('finalized') + 1` and `getBlockNumber()`. Anything older is unreplayable by
// construction, and offering a caller a `--from` that reaches below it would be offering a
// parameter whose only effect is to fill the table with one row repeated.
//
// MEASURED ON 2026-08-30, both chains, at the same minute:
//
//   testnet  tip 62830, finalized 62798 → window 32 blocks → 3 transactions, ALL at index 0,
//            one per active block, gaps of exactly 11 blocks
//   mainnet  tip 66477, finalized 66436 → window 41 blocks → 1 transaction, at index 0
//
// **A DEMO-SHAPED RANGE IS THEREFORE THE WINDOW ITSELF: tens of blocks and a handful of
// transactions.** That is not a limitation of this module, it is what the chain contains. A range
// over a thousand blocks would be a block-ingestion engine whose extra nine hundred and sixty
// blocks are all `below-finalized`.
//
// AND `IntraBlockPredecessorsUnavailable` COSTS NOTHING TODAY, WHICH IS WORTH SAYING PRECISELY
// BECAUSE IT SOUNDS LIKE IT SHOULD COST A LOT. L2 refuses every transaction after the first in its
// block. In the windows measured above, **every active block held exactly one transaction**, so the
// refusal excluded zero of four. It is still a row in the table, and it must be, because the day a
// block holds two the second one has to be named rather than silently absent.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// FAILURES ARE ISOLATED, AND "ISOLATED" MEANS THE TABLE HAS A ROW, NOT THAT THE ERROR WAS SWALLOWED.
//
// Every outcome carries a discriminant from `OUTCOME_KINDS` and, when it is a refusal, the refusal's
// own `kind` and message. A range that met three failures and completed reports three rows saying
// what happened; it never reports two rows and a shorter range, which is the shape this campaign
// calls "a count that drops".

import type { BlockNumber } from '@aztec/foundation/branded-types';
import { TxHash } from '@aztec/stdlib/tx/tx-hash';

import type { ReplayNodeClient } from './node_client.ts';
import { fetchSettledTransaction, type SettledTransaction } from './settled_transaction.ts';
import {
  replaySettledTransaction,
  type ReplayAvmHost,
  type ReplayOutcome,
} from './replay_execution.ts';
import type { HistoricalStateSource } from './historical_state.ts';

// ---------------------------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------------------------

/** The two node methods the window is read with. Both already on L0's permitted fourteen. */
export const WINDOW_METHODS = ['getBlockNumber'] as const;

export type ReplayableWindow = {
  /** The moving tip. */
  readonly tip: number;
  /** The finalized tip. Everything at or below it has had its transaction bodies pruned. */
  readonly finalized: number;
  /** `finalized + 1`. The oldest block whose transactions can still be fetched. */
  readonly from: number;
  /** The tip. */
  readonly to: number;
  readonly blocks: number;
};

/**
 * Read the replayable window. TWO CALLS, and it is a PRECONDITION rather than a discovery.
 *
 * The milestone's own point: meeting `SettledTransactionNotFound` per transaction is the refusal
 * behaving correctly and is also a waste of a round trip per transaction, when one call bounds the
 * whole range. A table row for `below-finalized` is produced from this, not from a failed fetch.
 */
export async function readReplayableWindow(client: ReplayNodeClient): Promise<ReplayableWindow> {
  const tip = Number(await client.getBlockNumber());
  const finalized = Number(await client.getBlockNumber('finalized'));
  const from = finalized + 1;
  return { tip, finalized, from, to: tip, blocks: Math.max(0, tip - from + 1) };
}

// ---------------------------------------------------------------------------------------------
// The outcome table
// ---------------------------------------------------------------------------------------------

/**
 * Every way a transaction in the range can end up, enumerated.
 *
 * A CLOSED SET, so an outcome this module did not anticipate cannot be written as a blank. The last
 * entry is the escape hatch and it is named `failed` rather than `other`: a row that says "failed"
 * with the refusal's own class and message in it is a finding, and a row that says "other" is a
 * shrug.
 */
export const OUTCOME_KINDS = [
  'replayed',
  'below-finalized',
  'not-first-in-block',
  'no-public-half',
  'failed',
] as const;
export type OutcomeKind = (typeof OUTCOME_KINDS)[number];

export type TransactionOutcome = {
  readonly kind: OutcomeKind;
  readonly txHash: string;
  readonly blockNumber: number;
  readonly txIndexInBlock: number;
  /** The chain's own published revert code, when the effect was readable. */
  readonly publishedRevertCode: number | undefined;
  /** Present only for `replayed`. */
  readonly replayedRevertCode: number | undefined;
  readonly reproduced: boolean | undefined;
  readonly instructionsExecuted: number | undefined;
  /** The refusal's own discriminant, when this row is one. NEVER a message alone. */
  readonly refusalKind: string | undefined;
  readonly detail: string;
  readonly elapsedMs: number;
};

export type RangeReport = {
  readonly window: ReplayableWindow;
  readonly blocksScanned: number;
  readonly blocksWithTransactions: number;
  readonly transactions: number;
  readonly outcomes: readonly TransactionOutcome[];
  readonly byKind: Readonly<Record<OutcomeKind, number>>;
  /** THE RATE THE MILESTONE ASKS FOR, and where the time went. */
  readonly elapsedMs: number;
  readonly transactionsPerMinute: number;
  readonly timing: {
    readonly enumerateMs: number;
    readonly replayMs: number;
    readonly slowestTransactionMs: number;
  };
};

// ---------------------------------------------------------------------------------------------
// The run
// ---------------------------------------------------------------------------------------------

export type RangeOptions = {
  /** Called per row, so a caller can show progress without this module printing. */
  readonly onOutcome?: (outcome: TransactionOutcome) => void;
  /** Called once the window is known. */
  readonly onWindow?: (window: ReplayableWindow) => void;
  /**
   * Stop after this many transactions. A BOUND FOR A DEMO, not a filter: the rows it does not
   * reach are simply not in the table, and `transactions` counts what was enumerated rather than
   * what was replayed, so a truncated run is visible as a difference between the two.
   */
  readonly maxTransactions?: number;
  /**
   * REACH BELOW THE FINALIZED TIP. EXPORTED FOR THE CONTROL AND FOR NOTHING ELSE.
   *
   * "Failures isolated: one transaction that cannot be replayed does not abort the range" is a
   * claim about behaviour, and on a healthy chain the window contains no failures at all — the
   * measured run had three rows and all three were `replayed`. So "isolation works" would be a
   * sentence about code nothing had exercised.
   *
   * This widens the range by `blocks` BELOW the finalized tip, where the node has pruned every
   * transaction body. Those rows come back `below-finalized`, THE RANGE STILL COMPLETES, and the
   * replayable rows above the tip still replay — which is the deliverable, demonstrated rather than
   * asserted. It is a MODE OF THE SUBJECT: one option, one enumeration, one table.
   *
   * It is not a feature. A caller who wanted a genuinely older range would be asking for a block
   * ingestion engine, and would get a table of one row repeated.
   */
  readonly reachBelowFinalizedForControls?: number;
};

/**
 * Replay every transaction in the replayable window, isolating failures.
 *
 * THE ENUMERATION IS CHEAP-FIRST. `getBlock(n)` WITHOUT `{ includeTransactions: true }` answers a
 * BODY-LESS block — the artefact L0 met live and L1 captured — so a caller that counted
 * `body.txEffects` on it would see zero for every block. This repository has already made that
 * mistake once, on a range that in fact held thirteen transactions. `header.totalManaUsed` is
 * non-zero exactly when a block did work, so it is read first and the body is fetched only then.
 */
export async function replayReplayableWindow(
  client: ReplayNodeClient,
  host: ReplayAvmHost,
  source: HistoricalStateSource,
  encodeInputs: (settled: SettledTransaction) => Uint8Array,
  options: RangeOptions = {},
): Promise<RangeReport> {
  const startedAt = Date.now();
  const measured = await readReplayableWindow(client);
  const reach = options.reachBelowFinalizedForControls ?? 0;
  const window: ReplayableWindow = reach === 0 ? measured : {
    ...measured,
    from: Math.max(1, measured.from - reach),
    blocks: measured.blocks + Math.min(reach, measured.from - 1),
  };
  options.onWindow?.(window);

  // ---- enumerate ----------------------------------------------------------------------------
  const enumerateStart = Date.now();
  const found: { blockNumber: number; txIndexInBlock: number; txHash: string; revertCode: number }[] = [];
  let blocksWithTransactions = 0;
  for (let n = window.from; n <= window.to; n += 1) {
    const head = await client.getBlock(n as unknown as BlockNumber);
    if (head === undefined || head === null) continue;
    // `totalManaUsed` crosses upstream's zod as an `Fr`, not as a number, so it is read through
    // its own `toString()` rather than handed to `BigInt` directly — which is a type error, and was.
    const manaText = String((head as { header?: { totalManaUsed?: unknown } }).header?.totalManaUsed ?? '0');
    if (manaText === '0' || /^0x0*$/.test(manaText)) continue;
    const full = await client.getBlock(n as unknown as BlockNumber, { includeTransactions: true });
    const effects = (full as { body?: { txEffects?: unknown[] } } | undefined)?.body?.txEffects ?? [];
    if (effects.length > 0) blocksWithTransactions += 1;
    effects.forEach((effect, index) => {
      const e = effect as { txHash: { toString(): string }; revertCode?: { getCode?: () => number } };
      found.push({
        blockNumber: n,
        txIndexInBlock: index,
        txHash: e.txHash.toString(),
        revertCode: e.revertCode?.getCode?.() ?? -1,
      });
    });
  }
  const enumerateMs = Date.now() - enumerateStart;

  // ---- replay, one row per transaction, failures isolated -------------------------------------
  const replayStart = Date.now();
  const outcomes: TransactionOutcome[] = [];
  let slowestTransactionMs = 0;
  const limit = options.maxTransactions ?? found.length;

  for (const candidate of found.slice(0, limit)) {
    const at = Date.now();
    const base = {
      txHash: candidate.txHash,
      blockNumber: candidate.blockNumber,
      txIndexInBlock: candidate.txIndexInBlock,
      publishedRevertCode: candidate.revertCode,
    };
    const record = (o: Omit<TransactionOutcome, 'elapsedMs'>): void => {
      const elapsedMs = Date.now() - at;
      slowestTransactionMs = Math.max(slowestTransactionMs, elapsedMs);
      const row = { ...o, elapsedMs };
      outcomes.push(row);
      options.onOutcome?.(row);
    };

    // THE PRECONDITION, READ FROM THE WINDOW RATHER THAN DISCOVERED PER TRANSACTION.
    // Nothing in the enumeration above can produce this today — the loop starts at `from` — and it
    // is here because a caller may pass an older range, and because the row has to exist for the
    // table to be honest about what it covers.
    if (candidate.blockNumber <= window.finalized) {
      record({ ...base, kind: 'below-finalized', replayedRevertCode: undefined, reproduced: undefined,
        instructionsExecuted: undefined, refusalKind: undefined,
        detail: `block ${candidate.blockNumber} is at or below the finalized tip `
          + `${window.finalized}, so the node has pruned this transaction's BODY while still `
          + `serving its effect. It is visible and unreplayable.` });
      continue;
    }
    if (candidate.txIndexInBlock !== 0) {
      record({ ...base, kind: 'not-first-in-block', replayedRevertCode: undefined,
        reproduced: undefined, instructionsExecuted: undefined,
        refusalKind: 'replay-intra-block-predecessors-unavailable',
        detail: `index ${candidate.txIndexInBlock}: the state it saw is the parent block's plus `
          + `the effects of the transactions before it in the same block, and no node method `
          + `serves that intermediate view.` });
      continue;
    }

    let settled: SettledTransaction;
    try {
      settled = await fetchSettledTransaction(client, TxHash.fromString(candidate.txHash),
        { pinToSettlingBlock: true });
    } catch (err) {
      record({ ...base, kind: 'failed', replayedRevertCode: undefined, reproduced: undefined,
        instructionsExecuted: undefined, refusalKind: kindOf(err), detail: messageOf(err) });
      continue;
    }

    if (!settled.publicHalf.present) {
      record({ ...base, kind: 'no-public-half', replayedRevertCode: undefined, reproduced: undefined,
        instructionsExecuted: undefined, refusalKind: undefined,
        detail: settled.publicHalf.reason });
      continue;
    }

    let outcome: ReplayOutcome;
    try {
      outcome = await replaySettledTransaction(host, source, settled, encodeInputs);
    } catch (err) {
      // ISOLATED: the range continues. The row says which transaction and why.
      record({ ...base, kind: 'failed', replayedRevertCode: undefined, reproduced: undefined,
        instructionsExecuted: undefined, refusalKind: kindOf(err), detail: messageOf(err) });
      continue;
    }

    record({ ...base, kind: 'replayed', replayedRevertCode: outcome.revertCode,
      reproduced: outcome.verdict.reproduced, instructionsExecuted: outcome.instructionsExecuted,
      refusalKind: undefined,
      detail: `${outcome.verdict.matched}/${outcome.verdict.comparisons.length} comparisons matched `
        + `over ${outcome.rounds.length} hydration round(s)` });
  }
  const replayMs = Date.now() - replayStart;
  const elapsedMs = Date.now() - startedAt;

  const byKind = Object.fromEntries(OUTCOME_KINDS.map((k) => [k, 0])) as Record<OutcomeKind, number>;
  for (const o of outcomes) byKind[o.kind] += 1;

  return {
    window,
    blocksScanned: window.blocks,
    blocksWithTransactions,
    transactions: found.length,
    outcomes,
    byKind,
    elapsedMs,
    transactionsPerMinute: elapsedMs === 0 ? 0 : (outcomes.length / elapsedMs) * 60000,
    timing: { enumerateMs, replayMs, slowestTransactionMs },
  };
}

/** A thrown value's own discriminant, never a message parsed for one. */
function kindOf(err: unknown): string {
  const k = (err as { kind?: unknown })?.kind;
  if (typeof k === 'string') return k;
  return `foreign:${(err as { constructor?: { name?: string } })?.constructor?.name ?? 'unknown'}`;
}

function messageOf(err: unknown): string {
  const m = err instanceof Error ? err.message : String(err);
  return m.length > 400 ? `${m.slice(0, 400)}…` : m;
}
