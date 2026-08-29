// private_half.ts — L1's third deliverable: THE PRIVATE HALF DECLARED ABSENT.
//
// "Not empty, not zero-length — a recorded statement that this transaction's private execution is
// unavailable in principle."
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// WHY A STATEMENT AND NOT AN EMPTY FIELD.
//
// The campaign file says it in one sentence and it is the whole reason this module exists: *an
// empty frame is indistinguishable from a private half that failed to load, and the reader cannot
// tell which they are looking at.* A recording that shows no private execution is telling the
// reader nothing — it could be a private half that is unrecoverable, a fetch that failed, a
// transaction that genuinely had none, or a bug. Four different facts, one rendering.
//
// So the absence is a VALUE with a discriminant, a reason and its own evidence, and it is DERIVED
// from what the source actually is rather than written in as a constant. `declarePrivateHalf` takes
// the source and produces the statement; there is no path that produces the sentence without
// having looked.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// AND THE CONTROL IS BUILT IN, WHICH IS THE POINT OF THE SECOND ARM.
//
// A function that returns "unavailable in principle" for every input is a printed literal — this
// campaign's most-repeated defect, and it would pass a check that only ever asked it about a
// settled transaction. So the same function answers a LOCALLY-ORIGINATED transaction, which HAS a
// private half: upstream's `PrivateExecutionResult` — the ACIR, the partial witnesses, the nested
// call tree that a PXE produced and never published. Given one, the declaration says `available`
// and counts what is there.
//
// That is what `test_private_half_declared_absent`'s control asks for in as many words: "a
// locally-originated transaction with a private half does NOT carry that statement."
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// WHAT THE CHAIN DOES CARRY, AND WHY IT IS IN THE EVIDENCE.
//
// The chain publishes the private half's EFFECTS: note hashes, nullifiers, private logs. It does
// not publish its EXECUTION. Those two facts are easy to conflate — a reader who sees five private
// logs may reasonably think something private was recovered — so the settled declaration carries
// the effect counts explicitly, under a field named `publishedEffects`, beside the statement that
// the execution is not among them. The counts are read off the `TxEffect` the node returned.

import type { TxEffect } from '@aztec/stdlib/tx';
import type { PrivateExecutionResult } from '@aztec/stdlib/tx';

/** The discriminant a recording, a check or a reader matches on. */
export const PRIVATE_HALF_UNAVAILABLE = 'unavailable-in-principle' as const;
export const PRIVATE_HALF_AVAILABLE = 'available' as const;

/** The effects of a private half that the chain DID publish. Counts, read off the `TxEffect`. */
export type PublishedPrivateEffects = {
  readonly noteHashes: number;
  readonly nullifiers: number;
  readonly privateLogs: number;
  readonly contractClassLogs: number;
};

/** What a locally-originated private half actually consists of. Read off the execution result. */
export type LocalPrivateExecution = {
  /** Private calls in the tree, entrypoint included. */
  readonly privateCalls: number;
  /** Total ACIR bytes across those calls — the bytecode a settled transaction does not publish. */
  readonly acirBytes: number;
  /** Total partial-witness entries — the execution a settled transaction does not publish. */
  readonly partialWitnessEntries: number;
};

export type PrivateHalfDeclaration =
  | {
      readonly status: typeof PRIVATE_HALF_UNAVAILABLE;
      readonly origin: 'settled-chain';
      readonly reason: string;
      readonly publishedEffects: PublishedPrivateEffects;
    }
  | {
      readonly status: typeof PRIVATE_HALF_AVAILABLE;
      readonly origin: 'locally-originated';
      readonly reason: string;
      readonly execution: LocalPrivateExecution;
    };

/**
 * The sentence itself, in one place.
 *
 * It is a constant because it is the same sentence every time — but the DECLARATION that carries it
 * is not, and that is the distinction: a check asserting this string is asserting that the right
 * branch was taken, and the branch is decided by the source. The other branch's reason is a
 * different string, so a function that always returned one of them fails the control.
 */
export const PRIVATE_HALF_UNAVAILABLE_REASON =
  'this transaction settled on a chain, and the private half of a settled transaction is '
  + 'unrecoverable IN PRINCIPLE rather than merely unfetched: private execution happens '
  + 'client-side and is never published, so the chain carries its EFFECTS and not its EXECUTION. '
  + 'There is no node call, no archive and no witness that would recover it. This is a statement '
  + 'and not an empty frame, because an empty frame is indistinguishable from a private half that '
  + 'failed to load.';

export const PRIVATE_HALF_AVAILABLE_REASON =
  'this transaction was originated locally and its private execution result is in hand — ACIR, '
  + 'partial witnesses and the nested private call tree. Nothing is unavailable in principle here, '
  + 'and saying so is what makes the settled case a measurement rather than a constant.';

/** Where the transaction came from, which is the only thing that decides the answer. */
export type PrivateHalfSource =
  | { readonly origin: 'settled-chain'; readonly txEffect: TxEffect }
  | { readonly origin: 'locally-originated'; readonly privateExecutionResult: PrivateExecutionResult };

/**
 * Declare what is known about a transaction's private half.
 *
 * ONE function, TWO branches, and the branch is chosen by the source rather than by a flag a caller
 * could get wrong. `test_private_half_declared_absent` drives both.
 */
export function declarePrivateHalf(source: PrivateHalfSource): PrivateHalfDeclaration {
  if (source.origin === 'locally-originated') {
    return {
      status: PRIVATE_HALF_AVAILABLE,
      origin: 'locally-originated',
      reason: PRIVATE_HALF_AVAILABLE_REASON,
      execution: measureLocalPrivateExecution(source.privateExecutionResult),
    };
  }
  const effect = source.txEffect;
  return {
    status: PRIVATE_HALF_UNAVAILABLE,
    origin: 'settled-chain',
    reason: PRIVATE_HALF_UNAVAILABLE_REASON,
    publishedEffects: {
      noteHashes: effect.noteHashes.length,
      nullifiers: effect.nullifiers.length,
      privateLogs: effect.privateLogs.length,
      contractClassLogs: effect.contractClassLogs.length,
    },
  };
}

/**
 * Count what a local private execution actually contains.
 *
 * Walked iteratively over `nestedExecutionResults` — upstream's own field — so the number is the
 * tree's and not the entrypoint's.
 */
export function measureLocalPrivateExecution(result: PrivateExecutionResult): LocalPrivateExecution {
  let privateCalls = 0;
  let acirBytes = 0;
  let partialWitnessEntries = 0;
  const stack = [result.entrypoint];
  while (stack.length > 0) {
    const call = stack.pop();
    if (!call) {
      continue;
    }
    privateCalls += 1;
    acirBytes += call.acir.length;
    partialWitnessEntries += call.partialWitness.size;
    for (const nested of call.nestedExecutionResults) {
      stack.push(nested);
    }
  }
  return { privateCalls, acirBytes, partialWitnessEntries };
}
