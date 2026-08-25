// form_a.ts — execute the public half of a transaction whose private half ran elsewhere.
//
// THE MILESTONE SAYS TWO OUTCOMES AND THERE ARE THREE, which is the single most load-bearing
// correction in M20 and is why this file has an enum rather than a boolean.
//
// M20's deliverable reads: "checked execution errors become reverted results consuming all gas;
// any other error type is rethrown unchanged and surfaced as a runtime bug". That is true of the
// AVM's INSTRUCTION-level errors and false of its TRANSACTION-level ones. Read out of
// `barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/`, at the fork's own anchor:
//
//   LANDED   `Execution::handle_exceptional_halt` (execution.cpp:1950-1963) sets
//            `gas_used = gas_limit` — all allocated gas — halts with
//            `HaltingMode::EXCEPTIONAL_HALT`, and the transaction CONTINUES. Six checked
//            exception types reach it (bytecode retrieval, instruction fetching, addressing,
//            register read, gas, opcode execution); the seventh catch, `std::exception`, prints
//            "This is a coding error, we should not get here" and RETHROWS. So a checked
//            execution error is not even an error at the boundary: the call returns status 0 and
//            a `TxOutcome` whose `revertCode` is non-zero.
//
//   REJECTED `TxExecution::simulate` (tx_execution.cpp) lets `NullifierCollisionException` and
//            the unrecoverable `TxExecutionException`s escape. The transaction is UNPROVABLE and
//            is thrown out: it does not land, it does not revert, it does not pay a fee. The C++
//            side never lets an exception unwind out of a wasm export — REACTOR-ABI.md's calling
//            convention — so this arrives as status 1 and M17's `AvmHostError`.
//
//   BUG      anything else. Rethrown UNCHANGED, with its stack, because the one confusion that
//            makes a debugger lie to its user is a bug in our host reported as a contract that
//            reverted.
//
// Collapsing REJECTED into BUG would make an ordinary consequence of an ordinary race — two
// transactions carrying the same private nullifier — read as a defect in this runtime. Collapsing
// it into LANDED would put a transaction in a block that no prover could ever prove. Neither is
// recoverable downstream, so the classification is made here, once.
//
// THE DEFAULT IS `BUG`, AND THAT DIRECTION IS DELIBERATE. `classifyBoundaryError` matches
// rejection against needles taken from the C++ sources; anything it does not recognise is
// rethrown. A rejection misclassified as a bug is loud and gets fixed; a bug misclassified as a
// rejection is silent and gets shipped. `test_nonrevertible_nullifier_collision_throws_tx_out`
// pins every needle against the C++ source line that emits it, so a string upstream renames is a
// red check rather than a transaction quietly reclassified.
//
// WHAT THIS FILE DOES NOT DO. It does not orchestrate phases, meter gas, account for teardown
// separately, or debit the fee payer. All of that is inside `avm.wasm` — `TxExecution::simulate`
// runs non-revertible insertions, SETUP, revertible insertions, APP_LOGIC, TEARDOWN, COLLECT_GAS_FEES,
// tree padding and cleanup, and `TxExecution::pay_fee` does the fee-juice read-modify-write. This
// runtime supplies the transaction and the world state and reads the result. See M20's status
// entry for what that means about the deliverables naming `PublicTxContext`, which no longer
// exists.

import type { PublicTxResult } from '@aztec/stdlib/avm';
import type { Tx } from '@aztec/stdlib/tx';

import { ProvenanceConsultedDuringExecution, sealProvenance } from './submitted_tx.ts';
import type { SubmittedTx } from './submitted_tx.ts';

/**
 * What became of a submitted transaction, IN THE CHAIN'S OWN VOCABULARY.
 *
 * THE TWO NAMES ARE UPSTREAM'S, NOT OURS, and that is the point — this is what a block explorer
 * has to display. `stdlib/src/tx/processed_tx.ts` declares `ProcessedTx`, which carries a
 * `revertCode` and may well have reverted, and `FailedTx = { tx, error }`, documented there as
 * "a tx that failed to be processed by the sequencer public processor". `PublicProcessor.process`
 * returns the two as separate arrays and logs "Processed N successful txs and M failed txs". So a
 * transaction the AVM threw out is a FAILED transaction in Aztec's terminology, and one that ran
 * and reverted is a PROCESSED one. An earlier revision of this file called them `landed` and
 * `rejected`, which are words this protocol does not use anywhere.
 *
 * TWO MEMBERS, THREE OUTCOMES. `processed` and `failed` are the two a caller RECEIVES; the third,
 * `bug`, is not a value because it is a throw — an error this runtime does not recognise is
 * rethrown unchanged rather than described. Anything that reads this union as "there are two
 * outcomes" is reading it wrong, and the header above says why the direction is deliberate.
 */
export type FormAOutcomeKind = 'processed' | 'failed';

/**
 * Which phase reverted, from the module's own four-valued code.
 *
 * This exists because upstream's published `RevertCode` cannot express it — see `revertCode`
 * below and DRIFT.md D18.
 */
export type TxRevertPhase = 'none' | 'appLogic' | 'teardown' | 'both';

/** The module's `RevertCode`, in the C++'s own order. Index is the raw value. */
export const RAW_REVERT_PHASES: readonly TxRevertPhase[] = ['none', 'appLogic', 'teardown', 'both'];

export interface FormAProcessed {
  readonly kind: 'processed';
  /**
   * THE RUNTIME'S OWN OUTCOME: the module's four-valued revert code, 0..3.
   *
   * `undefined` only when the boundary did not keep it, which no shipped boundary does — the
   * field is optional rather than defaulted because 0 means OK and a defaulted 0 would report a
   * transaction that reverted as one that did not.
   *
   * DRIFT.md D18, AND THIS IS A DELIBERATE DEPARTURE FROM UPSTREAM'S PUBLISHED TYPE. The C++
   * distinguishes OK / APP_LOGIC_REVERTED / TEARDOWN_REVERTED / BOTH_REVERTED, and
   * `TxExecution::simulate` picks the third or fourth depending on whether app logic had already
   * reverted. The published `RevertCodeEnum` declares only OK and REVERTED, and
   * `toRevertCodeEnum` is `value >= 1 ? 1 : 0`. M20's deliverable is that the asymmetric revert
   * model is "preserved exactly"; a two-valued code cannot express which phase reverted, so
   * honouring upstream's type as this runtime's outcome would destroy the property the milestone
   * exists to preserve. So the four-valued code is what this runtime reports, and upstream's
   * collapsed one is carried on `result` for consumers that demand that type.
   */
  readonly revertCode: number | undefined;
  /** The same value, named. `undefined` when `revertCode` is, or when it is outside 0..3. */
  readonly revertedIn: TxRevertPhase | undefined;
  /**
   * Upstream's result, unmodified. INTEROP ONLY where the four-valued code is concerned:
   * `result.revertCode.getCode()` reads 1 for every non-zero value, so a caller that needs the
   * phase must read `revertCode` above. Everything else on it — gas, the public tx effect, the
   * transaction fee — is the authority.
   */
  readonly result: PublicTxResult;
}

export interface FormAFailed {
  readonly kind: 'failed';
  /** Which unrecoverable condition, as classified from the module's own message. */
  readonly reason: FailureReason;
  /** The module's message, verbatim. */
  readonly message: string;
  /** The error the boundary threw, kept so nothing is lost by classifying it. */
  readonly cause: unknown;
}

export type FormAOutcome = FormAProcessed | FormAFailed;

/**
 * The unrecoverable transaction-level conditions, each named for the C++ site that raises it.
 *
 * `nonRevertibleNullifierCollision` and `revertibleNullifierCollision` are separate members even
 * though both throw the transaction out. They are the asymmetry M20 asks to be preserved exactly:
 * the second is the one an implementation would plausibly get wrong, because everything else
 * about revertible insertion soft-reverts. Keeping them distinct means a test can assert that the
 * REVERTIBLE one rejected rather than merely that something rejected.
 */
export type FailureReason =
  | 'nonRevertibleNullifierCollision'
  | 'revertibleNullifierCollision'
  | 'setupCallFailed'
  | 'sideEffectLimitNonRevertible'
  | 'feePayerInsufficientBalance'
  | 'feePayerIsZero';

/**
 * The needles, each with the C++ file and the format string it comes from.
 *
 * Taken from the artefact rather than invented, and matched as substrings of the module's message
 * because the C++ wraps them in `format(...)` with the offending address or nullifier appended.
 * `test_nonrevertible_nullifier_collision_throws_tx_out` greps each needle out of the named
 * source, so a rename upstream fails the check instead of silently disabling a branch here, and
 * `test_runtime_bug_not_reported_as_revert` asserts each one classifies as its own reason.
 */
export const FAILURE_NEEDLES: ReadonlyArray<readonly [FailureReason, string]> = [
  // emit_nullifier: format("[", revertible ? "R" : "NR", "_NULLIFIER_INSERTION] UNRECOVERABLE …")
  ['nonRevertibleNullifierCollision', '[NR_NULLIFIER_INSERTION] UNRECOVERABLE ERROR! Nullifier collision:'],
  ['revertibleNullifierCollision', '[R_NULLIFIER_INSERTION] UNRECOVERABLE ERROR! Nullifier collision:'],
  // simulate(): the SETUP arm. The [APP_LOGIC] and [TEARDOWN] arms are deliberately absent —
  // both are caught inside simulate() and become soft reverts, so neither can reach a host.
  ['setupCallFailed', '[SETUP] UNRECOVERABLE ERROR! Enqueued call to'],
  // pay_fee(), which is called OUTSIDE every try in simulate(), so both of these escape.
  ['feePayerInsufficientBalance', 'Not enough balance for fee payer to pay for transaction'],
  ['feePayerIsZero', 'Fee payer cannot be 0 unless skipping fee enforcement for simulation'],
  // The three side-effect limits. THE MESSAGE DOES NOT SAY WHICH PHASE, and that is fine rather
  // than a gap: emit_nullifier / emit_note_hash / emit_l2_to_l1_message throw the SAME string in
  // both phases, and the revertible one is caught by simulate()'s `catch (const
  // TxExecutionException&)` and becomes a soft revert. So a limit message that reaches a host has
  // already proved it escaped, which is exactly the non-revertible case. An earlier revision
  // matched on invented `[NR_NOTE_HASH_INSERTION]` prefixes that appear nowhere in the C++ —
  // needles come from the artefact.
  ['sideEffectLimitNonRevertible', 'Maximum number of nullifiers reached'],
  ['sideEffectLimitNonRevertible', 'Maximum number of note hashes reached'],
  ['sideEffectLimitNonRevertible', 'Maximum number of L2 to L1 messages reached'],
];

/**
 * Decide whether a thrown error is a transaction the AVM threw out, or a bug in this runtime.
 *
 * Returns `undefined` for "not a rejection", which the caller turns into a rethrow. That is the
 * safe direction and it is the reason this returns rather than throwing its own error type.
 */
export function classifyBoundaryError(error: unknown): { reason: FailureReason; message: string } | undefined {
  const message = typeof (error as { message?: unknown })?.message === 'string'
    ? (error as { message: string }).message
    : undefined;
  if (message === undefined) {
    return undefined;
  }
  // A trap is never a rejection. M17's `AvmTrap` carries `kind: 'trap'`; the instance is dead
  // after one, so classifying it as a transaction outcome would be a lie about the runtime.
  if ((error as { kind?: unknown })?.kind === 'trap') {
    return undefined;
  }
  for (const [reason, needle] of FAILURE_NEEDLES) {
    if (message.includes(needle)) {
      return { reason, message };
    }
  }
  return undefined;
}

/**
 * The narrow view of a public tx simulator this path needs.
 *
 * `simulate` is upstream's interface verbatim. `rawRevertCode` is OURS and is optional: it is the
 * module's four-valued code from the last `simulate`, which upstream's result type cannot carry
 * (DRIFT.md D18). A simulator that does not keep it — a stub, upstream's own — simply does not
 * declare it, and the outcome then reports `undefined` rather than a plausible zero.
 */
export interface PublicTxSimulatorLike {
  simulate(tx: Tx): Promise<PublicTxResult>;
  readonly rawRevertCode?: number | undefined;
}

export interface ExecuteOptions {
  /**
   * Called instead of throwing when the provenance is observed during the execution window.
   * Present ONLY so the check that proves the tripwire fires can record the observation without
   * the throw unwinding the arm it is measuring. Production callers leave it unset.
   */
  readonly onProvenanceRead?: (trap: string, property?: string | symbol) => void;
}

/**
 * Execute the public half of an externally-settled transaction.
 *
 * The provenance is sealed for the duration and never read here. Note what that means and what it
 * does not: the seal proves that no frame reached by this call OBSERVED the provenance. It does
 * not prove that this function could not have been written to branch on it — nothing can prove
 * that — which is why the export surface hands the simulator a `Tx` and never a `SubmittedTx`.
 */
export async function executeExternallySettledTx(
  submitted: SubmittedTx<Tx>,
  simulator: PublicTxSimulatorLike,
  options: ExecuteOptions = {},
): Promise<FormAOutcome> {
  const seal = sealProvenance(submitted.provenance, (trap, property) => {
    if (options.onProvenanceRead) {
      options.onProvenanceRead(trap, property);
      return;
    }
    throw new ProvenanceConsultedDuringExecution(trap, property);
  });

  // THE SEAL IS CARRIED THROUGH THE EXECUTION WINDOW, NOT PARKED BESIDE IT. The first version of
  // this function read `submitted.tx` up front and never let the sealed object anywhere near the
  // simulator, which made the tripwire unable to fire for any reason other than a test injecting
  // a read — an assertion that passes by construction, and the defect this campaign has now found
  // twenty times. What the execution path actually holds is the SEALED submission, and it reaches
  // `.tx` off it; so any frame between here and the module returning that reads `.provenance`,
  // in this file or in a future one, trips the wire at its own call site.
  const sealed: SubmittedTx<Tx> = { tx: submitted.tx, provenance: seal.sealed };

  try {
    const result = await runPublicHalf(sealed, simulator);
    // Read AFTER the call and off the simulator, so it is the code for THIS simulation.
    const revertCode = simulator.rawRevertCode;
    const revertedIn = revertCode === undefined ? undefined : RAW_REVERT_PHASES[revertCode];
    return { kind: 'processed', revertCode, revertedIn, result };
  } catch (error) {
    if (error instanceof ProvenanceConsultedDuringExecution) {
      // Never classified, never turned into a rejection: this is a defect in this runtime and it
      // must not be reportable as anything a transaction did.
      throw error;
    }
    const rejection = classifyBoundaryError(error);
    if (rejection === undefined) {
      // Unchanged, with its stack. Not wrapped, not re-typed, not turned into a revert.
      throw error;
    }
    return { kind: 'failed', reason: rejection.reason, message: rejection.message, cause: error };
  } finally {
    seal.release();
  }
}

/**
 * The execution window.
 *
 * It takes the SEALED submission and reads exactly one property off it. Keeping this a separate
 * function is what makes "the execution path never reads provenance" a statement about a frame
 * rather than about a comment: everything the AVM does happens inside this call.
 */
async function runPublicHalf(
  sealed: SubmittedTx<Tx>,
  simulator: PublicTxSimulatorLike,
): Promise<PublicTxResult> {
  return await simulator.simulate(sealed.tx);
}

/** Every observation the last seal recorded. Exposed for the checks; empty is the claim. */
export function provenanceReadsDuring(
  submitted: SubmittedTx<Tx>,
  body: (sealed: SubmittedTx<Tx>) => void,
): readonly string[] {
  const seal = sealProvenance(submitted.provenance, () => {});
  try {
    body({ tx: submitted.tx, provenance: seal.sealed });
  } finally {
    seal.release();
  }
  return seal.reads;
}
