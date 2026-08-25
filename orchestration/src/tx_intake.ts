// tx_intake.ts — Form A's front door: a serialized transaction whose private half ran elsewhere.
//
// WHAT IS UPSTREAM'S HERE, WHICH IS NEARLY ALL OF IT. `Tx.fromBuffer` is upstream's
// (`@aztec/stdlib/tx`, published, already installed). So is `Tx.schema` for the JSON spelling.
// This module adds no decoder, no field layout and no version tag; it adds the SHAPE CHECKS that
// `Tx` deliberately does not make, and it names why each one exists.
//
// "SHAPE VALIDATION ONLY AND NOTHING CRYPTOGRAPHIC" — what that rules in and out.
//
// Ruled OUT: verifying the chonk proof, verifying the private kernel's public inputs, and
// recomputing the tx hash. `Tx.validateTxHash()` exists upstream and is the right call for an
// untrusted mempool; it is a HASH, so it is out of scope here by the deliverable's own wording,
// and this module documents rather than performs it. A dev chain that accepted a transaction and
// then discovered the hash did not match would be a different milestone's problem.
//
// Ruled IN: the structural facts the execution path will dereference without checking. Each of
// the four below is a specific silent-wrong-answer, not a tidiness check:
//
//   1. `forPublic` present when there are public calls. `AvmTxHint.fromTx` reads
//      `tx.data.forPublic!` — a non-null assertion, so a transaction with public call requests
//      and no `forPublic` becomes a `TypeError` from inside the encoder, one frame away from
//      anything that names the transaction.
//
//   2. Every call request's calldata is actually present. `Tx.#combinePublicCallRequestWithCallData`
//      says so itself: "Assume empty calldata if nothing is given for the hash. The verification
//      of calldata vs hash should be handled outside of this class." A request whose
//      `calldataHash` is missing from the map therefore executes WITH EMPTY CALLDATA — a
//      different function, silently, with a plausible result. This is the check that most earns
//      its place, and it is `has`-on-the-map rather than a re-hash, so it stays non-cryptographic.
//
//   3. No duplicate calldata hash with differing values. `getCalldataMap` is built with `.set` in
//      array order, so a duplicate key silently keeps the LAST entry.
//
//   4. The three phase buckets partition the public calls. If they ever did not, one phase's
//      calls would be executed twice or not at all, and the AVM would report a consistent result
//      for a transaction nobody submitted.
//
// WHY THE PHASE COUNT IS CHECKED AGAINST UPSTREAM'S OWN SPLITTER RATHER THAN AGAINST A CONSTANT.
// `getCallRequestsWithCalldataByPhase` (`@aztec/simulator/server`, `simulator/src/public/utils.ts`)
// is a switch over exactly three `Tx` accessors, and `AvmTxHint.fromTx` — which is what actually
// runs — calls those same three accessors directly.
//
// THE HELPER IS OFF THE EXECUTION PATH, WHICH IS THE REASON NOT TO CALL IT. At the anchor its only
// callers are the two p2p transaction validators (`fee_payer_balance.ts`, `phases_validator.ts`);
// nothing in the public execution path goes through it. An earlier revision of this comment gave
// a second reason — that `@aztec/simulator` is not published — and that reason is FALSE, measured:
// the package is on npm, and `@aztec/simulator@5.0.0-nightly.20260626`, the exact tag this
// orchestration already pins for `@aztec/stdlib`, `@aztec/foundation`, `@aztec/constants` and
// `@aztec/protocol-contracts`, exports `./server` and ships the function in both
// `dest/public/utils.js` and `src/public/utils.ts`. Importing it would be possible and would buy
// nothing: it would add a dependency on a package this runtime otherwise does not need, in order
// to reach a helper that upstream's own encoder does not use.
//
// So `phaseCallRequests` below calls the same three accessors in the same order, and there is one
// phase split in this runtime and it is upstream's. `e2e_form_a_external_tx_roundtrip` Part 6 pins
// the equivalence: our switch body is compared line for line against upstream's at the anchor, and
// each of the three accessors is asserted to be called by `AvmTxHint.fromTx` too. The day upstream
// changes the switch, that check goes red rather than this file drifting.

import { Tx, TxExecutionPhase } from '@aztec/stdlib/tx';

/** A transaction rejected at intake. Never a revert: nothing has executed. */
export class TxIntakeError extends Error {
  readonly kind = 'tx-intake-error' as const;
  /** Which check rejected it, so a caller can discriminate without parsing prose. */
  readonly check: string;
  constructor(check: string, message: string) {
    super(`${check}: ${message}`);
    this.check = check;
  }
}

/**
 * The three phases, each read from the `Tx` accessor upstream's own splitter dispatches to.
 *
 * SETUP      <- getNonRevertiblePublicCallRequestsWithCalldata()
 * APP_LOGIC  <- getRevertiblePublicCallRequestsWithCalldata()
 * TEARDOWN   <- getTeardownPublicCallRequestWithCalldata()   (0 or 1)
 */
export function phaseCallRequests(tx: Tx, phase: TxExecutionPhase): unknown[] {
  switch (phase) {
    case TxExecutionPhase.SETUP:
      return tx.getNonRevertiblePublicCallRequestsWithCalldata();
    case TxExecutionPhase.APP_LOGIC:
      return tx.getRevertiblePublicCallRequestsWithCalldata();
    case TxExecutionPhase.TEARDOWN: {
      const request = tx.getTeardownPublicCallRequestWithCalldata();
      return request ? [request] : [];
    }
    default:
      throw new TxIntakeError('phase', `unknown phase: ${String(phase)}`);
  }
}

/** What the shape check found, whether or not it rejected. */
export interface TxShape {
  readonly hasPublicCalls: boolean;
  readonly numberOfPublicCalls: number;
  readonly setup: number;
  readonly appLogic: number;
  readonly teardown: number;
  /** Present so a caller can decide about fee enforcement; intake does not judge it. */
  readonly feePayerIsZero: boolean;
}

/**
 * The four structural checks. Throws `TxIntakeError` on the first failure, naming the check.
 *
 * A transaction with NO public calls is valid and returns a shape with every count zero — a
 * private-only transaction is a normal thing for a chain to accept, and rejecting it here would
 * make M22 route around this function.
 */
export function validateTxShape(tx: Tx): TxShape {
  const numberOfPublicCalls = tx.numberOfPublicCalls();
  const hasPublicCalls = numberOfPublicCalls > 0;

  // 1. forPublic
  if (hasPublicCalls && !tx.data.forPublic) {
    throw new TxIntakeError(
      'forPublic',
      `the transaction declares ${numberOfPublicCalls} public call request(s) but carries no `
        + `forPublic accumulated data. AvmTxHint.fromTx dereferences it unconditionally.`,
    );
  }
  if (!hasPublicCalls && tx.data.forPublic) {
    throw new TxIntakeError(
      'forPublic',
      'the transaction carries forPublic accumulated data but declares no public call requests.',
    );
  }

  // 3. duplicate calldata hashes (checked before 2, so 2's diagnosis is never confused by one)
  const seen = new Set<string>();
  for (const hashed of tx.publicFunctionCalldata) {
    const key = hashed.hash.toString();
    if (seen.has(key)) {
      throw new TxIntakeError(
        'calldataDuplicate',
        `calldata hash ${key} appears more than once; getCalldataMap keeps the last entry, so one `
          + `of the two payloads would be executed in place of the other.`,
      );
    }
    seen.add(key);
  }

  // 2. every call request's calldata is present
  const calldataMap = tx.getCalldataMap();
  const requests = tx.data.forPublic
    ? [
        ...tx.data.getNonRevertiblePublicCallRequests(),
        ...tx.data.getRevertiblePublicCallRequests(),
        ...(tx.data.getTeardownPublicCallRequest() ? [tx.data.getTeardownPublicCallRequest()!] : []),
      ]
    : [];
  for (const request of requests) {
    const key = request.calldataHash.toString();
    if (!calldataMap.has(key)) {
      throw new TxIntakeError(
        'calldataMissing',
        `no calldata was supplied for call request with calldataHash ${key}. Tx substitutes EMPTY `
          + `calldata for a missing hash, so this would execute a different function and succeed.`,
      );
    }
  }

  // 4. the three buckets partition the public calls
  const setup = phaseCallRequests(tx, TxExecutionPhase.SETUP).length;
  const appLogic = phaseCallRequests(tx, TxExecutionPhase.APP_LOGIC).length;
  const teardown = phaseCallRequests(tx, TxExecutionPhase.TEARDOWN).length;
  if (setup + appLogic + teardown !== numberOfPublicCalls) {
    throw new TxIntakeError(
      'phasePartition',
      `the three phases carry ${setup} + ${appLogic} + ${teardown} = ${setup + appLogic + teardown} `
        + `public call requests but the transaction declares ${numberOfPublicCalls}.`,
    );
  }

  return {
    hasPublicCalls,
    numberOfPublicCalls,
    setup,
    appLogic,
    teardown,
    feePayerIsZero: tx.data.feePayer.isZero(),
  };
}

/**
 * Decode a serialized transaction and check its shape. Nothing cryptographic; nothing executes.
 *
 * `Tx.fromBuffer` is upstream's. The `try` is here only so that a truncated or foreign buffer
 * fails as a `TxIntakeError` naming `decode` rather than as whatever `BufferReader` happens to
 * throw, which for a short buffer is a `RangeError` about an offset.
 *
 * `TxClass` is injectable and defaults to this package's own `Tx`. That is not a courtesy: five
 * `node_modules` roots in this repository each carry their own copy of `@aztec/stdlib`, so a
 * caller in `diffsim/` holds a DIFFERENT `Tx` constructor from ours and an `instanceof` across
 * that boundary is false. The hazard is documented at
 * `diffsim/src/public/public_tx_simulator/differential/encode_inputs.ts:22-42`; the parameter is
 * how a cross-package caller decodes into ITS `Tx` rather than ours.
 */
export function txFromBuffer(buffer: Buffer, TxClass: typeof Tx = Tx): Tx {
  let tx: Tx;
  try {
    tx = TxClass.fromBuffer(buffer);
  } catch (error) {
    throw new TxIntakeError('decode', `Tx.fromBuffer refused the payload: ${(error as Error).message}`);
  }
  validateTxShape(tx);
  return tx;
}
