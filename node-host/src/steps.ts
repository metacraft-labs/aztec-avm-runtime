// Batched step-stream decoding, matching M12's export.
//
// THERE ARE TWO WAYS TO GET THE STREAM AND BOTH ARE UPSTREAM'S, not ours:
//
//   1. `TxSimulationResult.execution_steps` already carries the WHOLE stream. A host that decodes
//      the result has all 38,903 of `burn`'s records after ONE crossing and zero further ones.
//      That is the strongest form of "one call per batch" and `stepsFromOutcome` below is it.
//   2. `avm_steps_batch(from, count)` exists for a host that would rather stream records into a
//      trace writer as it goes — M24 and M25 — without holding the whole result. Drained at batch
//      size B it costs exactly `ceil(count / B)` crossings, and `drainSteps` asserts that identity
//      rather than assuming it.
//
// THE WINDOW IS CLAMPED BY THE MODULE, BY SUBTRACTION, and this host does not re-clamp it. M12
// established why: `size_t` is 32 bits on wasm32 and `count` is a uint32 the HOST chooses, so
// `from + count` wraps for a count near 2^32 - from, and a wrapped end below begin would construct
// a vector from a reversed range — undefined behaviour reachable straight from the boundary that
// `guarded()` cannot catch because it is not an exception. Reading past the end returns an empty
// batch and `count = 2^32 - 1` returns the whole remaining window. `drainSteps` passes the caller's
// numbers through unchanged so that property keeps being exercised from here.

import type { Reactor } from './reactor.ts';
import type { MsgpackValue } from './msgpack.ts';
import type { TxOutcome } from './errors.ts';

/** One `ExecutionStep`, upstream's own msgpack schema: `(context_id, contract_address, pc, opcode, gas_used)`. */
export interface ExecutionStep {
  readonly contextId: number;
  readonly contractAddress: Uint8Array;
  readonly pc: number;
  readonly opcode: number;
  readonly gasUsed: { readonly l2Gas: number; readonly daGas: number };
}

export interface DrainResult {
  readonly steps: ExecutionStep[];
  /** Calls made into the module. Exactly `ceil(count / batch)`. */
  readonly crossings: number;
  /** Records decoded. Equal to `steps.length`; kept separately so a mismatch is visible. */
  readonly decoded: number;
}

function asStep(v: MsgpackValue): ExecutionStep {
  const r = v as unknown as ExecutionStep;
  if (typeof r?.pc !== 'number' || !(r?.contractAddress instanceof Uint8Array)) {
    throw new Error(`not an ExecutionStep: ${JSON.stringify(Object.keys(v as object))}`);
  }
  return r;
}

/**
 * The zero-extra-crossing path: the steps that already arrived inside the simulation result.
 *
 * Returns `null` when the configuration did not ask for them, which is a different statement from
 * "there were none" and is why it is not an empty array.
 */
export function stepsFromOutcome(outcome: TxOutcome<MsgpackValue>): ExecutionStep[] | null {
  const raw = (outcome.result as { executionSteps?: unknown }).executionSteps;
  if (raw === null || raw === undefined) return null;
  if (!Array.isArray(raw)) throw new Error('executionSteps is present but is not an array');
  return raw.map(asStep);
}

/** How many records the last simulation produced. */
export function stepCount(reactor: Reactor): number {
  return reactor.callRaw('avm_steps_count', () => (reactor.exports.avm_steps_count as () => number)());
}

/**
 * Drains the step stream in windows of `batch`.
 *
 * `batch` must be positive: a batch of zero would loop for ever, and the module has no way to say
 * so because a zero-length window is a legitimate answer to a query past the end.
 */
export function drainSteps(reactor: Reactor, batch: number, total = stepCount(reactor)): DrainResult {
  if (!Number.isInteger(batch) || batch <= 0) throw new Error(`batch must be a positive integer, got ${batch}`);
  const steps: ExecutionStep[] = [];
  let crossings = 0;
  for (let from = 0; from < total; from += batch) {
    reactor.callGuarded('avm_steps_batch', () =>
      (reactor.exports.avm_steps_batch as (f: number, c: number) => number)(from, batch),
    );
    const window = reactor.decodedResult();
    if (!Array.isArray(window)) throw new Error('avm_steps_batch did not return an array');
    for (const s of window) steps.push(asStep(s));
    crossings++;
  }
  return { steps, crossings, decoded: steps.length };
}

/** The crossings a drain of `total` records at batch size `batch` must cost. */
export function expectedCrossings(total: number, batch: number): number {
  return Math.ceil(total / batch);
}

/** One record in the shape `avm_differential steps` prints, so the two are comparable per record. */
export function formatStep(s: ExecutionStep, hex: (b: Uint8Array) => string): string {
  return `ctx=${s.contextId} pc=${s.pc} op=${s.opcode} l2=${s.gasUsed.l2Gas} da=${s.gasUsed.daGas} addr=${hex(s.contractAddress)}`;
}
