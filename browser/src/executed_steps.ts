// The executed step stream, drained at the one boundary a transaction crosses.
//
// ===========================================================================================
// THIS FILE IS PLUMBING BETWEEN THREE THINGS THAT ALREADY EXISTED. IT ADDS NO FORMAT.
// ===========================================================================================
//
//   * M9's `ExecutionObserverInterface` — the C++ AVM's per-instruction hook, already inside
//     `avm.wasm`, measured at 39,086 records across eight programs and byte-identical native
//     versus wasm. It is switched on by `PublicSimulatorConfig::collect_execution_steps`, which
//     until M29 nothing in this repository could set (`shipped_module_config.ts` spread a
//     hard-coded `false` over every caller's config).
//   * M12's `avm_steps_count()` / `avm_steps_batch(from, count)` — the batched drain, `ceil(N/B)`
//     crossings, the window clamped BY SUBTRACTION inside the module.
//   * `node-host/src/steps.ts` — `drainSteps`, `stepCount`, `ExecutionStep`. **Reused, not
//     re-implemented.** Every import in that file is an `import type`, so it carries no runtime
//     dependency and is browser-safe exactly as written; `loader.ts` already imports `Reactor`
//     from `node-host` at value level, so this is not a new coupling either.
//
// ===========================================================================================
// WHY THE DRAIN IS HERE AND NOT AT THE CALL SITE THAT WANTS THE STREAM.
// ===========================================================================================
//
// `g_steps` inside the module is REPLACED by every `avm_simulate` — the reactor assigns it from
// `result.execution_steps` on each call (`avm_reactor.cpp`, M12's patch). A page that ran a
// transaction, produced a block, and only then asked for the steps would get the steps of whatever
// the block processor simulated last, which for a one-transaction block is the same records and for
// a two-transaction block is silently the wrong ones. So the drain happens in the same turn as the
// simulation that produced it, at the boundary, and the result is keyed by the order it arrived in.
//
// ===========================================================================================
// THE BATCHED PATH IS THE ONE THAT SHIPS, AND THE ZERO-CROSSING ONE IS RECORDED BESIDE IT.
// ===========================================================================================
//
// The whole stream is ALSO inside the `avm_simulate` result, under upstream's own `executionSteps`,
// at a cost of zero further crossings — `stepsFromOutcome` is that path and it is what `inResult`
// reports. The drain is still done through `avm_steps_batch`, because M29's deliverable names M12's
// batching and because a host that streams into a writer as it goes is the shape M12 built the
// export for. The two are compared: `drainedMatchesResult` is a per-record comparison, not a count,
// and a count agreeing while the records did not is a shape this campaign has met.

import { drainSteps, stepCount, stepsFromOutcome, type ExecutionStep } from '../../node-host/src/steps.ts';
import type { Reactor } from '../../node-host/src/reactor.ts';
import type { MsgpackValue } from '../../node-host/src/msgpack.ts';
import type { TxOutcome } from '../../node-host/src/errors.ts';

/** Records per `avm_steps_batch` call. M12's largest measured arm; `ceil(N/B)` crossings. */
export const DEFAULT_STEP_BATCH = 4096;

/** The AVM's own executed-instruction statistic, under upstream's own key. */
export const INSTRUCTIONS_EXECUTED_STAT = 'total_instructions_executed';

/** One transaction's executed stream, as it came out of the module. */
export interface ExecutedTransaction {
  /** The records, in execution order. `(contextId, contractAddress, pc, opcode, gasUsed)`. */
  readonly steps: readonly ExecutionStep[];
  /** `avm_steps_count()` — the module's own count, before anything decoded a record. */
  readonly count: number;
  /** Crossings the drain cost. Exactly `ceil(count / batchRecords)`. */
  readonly crossings: number;
  readonly batchRecords: number;
  /**
   * `stats["total_instructions_executed"]`, or `null` when statistics were not collected.
   *
   * `null` rather than `0`: "nobody asked for it" and "the AVM executed nothing" are different
   * facts and only one of them is a finding.
   */
  readonly instructionsExecuted: number | null;
  /** How many records arrived inside the result itself, or `null` when the field was absent. */
  readonly inResult: number | null;
  /** Whether the drained records equal the in-result ones PER RECORD. `null` when there were none. */
  readonly drainedMatchesResult: boolean | null;
}

/** How a step is rendered for a per-record comparison. `avm_differential steps`' own shape. */
export function formatExecutedStep(s: ExecutionStep): string {
  const addr = Array.from(s.contractAddress, (b) => b.toString(16).padStart(2, '0')).join('');
  return `ctx=${s.contextId} pc=${s.pc} op=${s.opcode} l2=${s.gasUsed.l2Gas} da=${s.gasUsed.daGas} addr=0x${addr}`;
}

/**
 * Wraps the reactor's `simulate` and drains the stream each simulation produced.
 *
 * `enabled` is not a convenience: with the observer off the module leaves `g_steps` empty and a
 * drain would report an empty stream that looks exactly like a transaction that executed nothing.
 * So a disabled collector records `null` for the transaction rather than an empty
 * `ExecutedTransaction`, and a consumer that wants steps and finds `null` is told which it is.
 */
export class ExecutedStepCollector {
  private readonly reactor: Reactor;
  private readonly batchRecords: number;
  readonly enabled: boolean;
  private lastTransaction: ExecutedTransaction | null = null;
  private lastResult: Uint8Array | null = null;
  private simulations = 0;

  constructor(reactor: Reactor, options: { enabled: boolean; batchRecords?: number }) {
    this.reactor = reactor;
    this.enabled = options.enabled;
    this.batchRecords = options.batchRecords ?? DEFAULT_STEP_BATCH;
    if (!Number.isInteger(this.batchRecords) || this.batchRecords < 1) {
      throw new RangeError(`batchRecords must be a positive integer, got ${String(this.batchRecords)}`);
    }
  }

  /** Simulations this collector has seen. */
  get transactionsSimulated(): number {
    return this.simulations;
  }

  /** The stream of the most recent simulation, or `null` when collection is off. */
  get last(): ExecutedTransaction | null {
    return this.lastTransaction;
  }

  /**
   * A COPY of the module's result buffer for the most recent simulation, taken before the drain.
   *
   * **THE DRAIN OVERWRITES THE RESULT BUFFER, AND THIS IS WHY THIS FIELD EXISTS.** Every call that
   * produces bytes leaves them in the ONE module-owned buffer — that is `REACTOR-ABI.md`'s
   * ownership rule and `Reactor.result()`'s own comment — so `avm_steps_batch` replaces the
   * `TxSimulationResult` with a window of step records. A caller that decoded `reactor.result()`
   * after a drain would be decoding the last batch as a transaction result: not a crash, a
   * plausible wrong object. `Reactor.simulate` already copies the bytes out for its own decode;
   * this takes the same copy, at the same moment, for the caller that needs upstream's types.
   */
  get lastResultBytes(): Uint8Array | null {
    return this.lastResult;
  }

  /**
   * The boundary. Simulate, then drain, in that order and in the same turn.
   *
   * A throw from `simulate` — a trap, a host error, a poisoned instance — propagates unchanged and
   * leaves `last` alone: a stream drained out of a poisoned instance would be read out of undefined
   * linear memory, and a stream left over from the PREVIOUS transaction is worse than none.
   */
  simulate(input: Uint8Array, contractDb: number, merkleDb: number): TxOutcome<MsgpackValue> {
    const outcome = this.reactor.simulate(input, contractDb, merkleDb);
    this.simulations += 1;
    // BEFORE THE DRAIN. See `lastResultBytes`.
    this.lastResult = this.reactor.result();
    if (!this.enabled) {
      this.lastTransaction = null;
      return outcome;
    }
    const inResultSteps = stepsFromOutcome(outcome);
    const count = stepCount(this.reactor);
    const drained = drainSteps(this.reactor, this.batchRecords, count);
    const stats = (outcome.result as { stats?: Record<string, unknown> } | null)?.stats;
    const raw = stats?.[INSTRUCTIONS_EXECUTED_STAT];
    const instructionsExecuted =
      raw === undefined || raw === null ? null : Number(typeof raw === 'string' ? raw : (raw as number));
    this.lastTransaction = {
      steps: drained.steps,
      count,
      crossings: drained.crossings,
      batchRecords: this.batchRecords,
      instructionsExecuted: Number.isFinite(instructionsExecuted as number) ? instructionsExecuted : null,
      inResult: inResultSteps === null ? null : inResultSteps.length,
      drainedMatchesResult:
        inResultSteps === null
          ? null
          : inResultSteps.length === drained.steps.length
            && inResultSteps.every((s, i) => formatExecutedStep(s) === formatExecutedStep(drained.steps[i]!)),
    };
    return outcome;
  }
}

export type { ExecutionStep };
