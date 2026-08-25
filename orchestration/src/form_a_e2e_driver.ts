// form_a_e2e_driver.ts — the Form A intake path, driven end to end against the real `avm.wasm`.
//
// It is a DRIVER rather than a test: it prints one JSON object per arm and exits 0. The
// assertions live in `verification/e2e_form_a_external_tx_roundtrip.sh` and
// `verification/test_fee_juice_debited_and_insufficiency_throws.sh`, which read this output. That
// split is the campaign's: a driver that asserted would have to be trusted about its own count.
//
// WHAT EACH ARM PROVES, and why these particular transactions.
//
// The transactions call contracts that were never registered in the resident contract DB. That is
// deliberate and it is not a shortcut: a call to an unknown contract fails bytecode retrieval,
// which is one of the six CHECKED exception types `Execution::handle_exceptional_halt` converts
// into an exceptional halt that consumes all allocated gas. So it is the cheapest way to reach the
// exact instruction-level outcome M20's last deliverable is about, without a compiled Noir
// artifact — and the PHASE the call sits in is then the only variable, which is what makes the
// asymmetry visible:
//
//   appLogicOnlyFunded          APP_LOGIC call fails -> soft revert -> LANDS, revertCode non-zero,
//                               fee still paid. The recoverable arm.
//   appLogicOnlyUnfunded        the same transaction with no balance -> pay_fee throws ->
//                               REJECTED, `feePayerInsufficientBalance`. The transaction does not
//                               land at all, which is the difference between "reverted" and
//                               "thrown out".
//   setupCallFails              the same call moved to SETUP -> REJECTED, `setupCallFailed`.
//                               Nothing about the call changed except its phase.
//   nonRevertibleNullifierClash a private nullifier already in the tree, in the NON-revertible
//                               bucket -> REJECTED, `nonRevertibleNullifierCollision`.
//   revertibleNullifierClash    THE SAME COLLISION IN THE REVERTIBLE BUCKET -> still REJECTED,
//                               `revertibleNullifierCollision`. This is the arm that catches a
//                               wrong implementation: everything else about revertible insertion
//                               soft-reverts, so an engine that treated this one as recoverable
//                               would look right until a real collision happened.
//
// PROVENANCE IS VARIED ACROSS ARMS ON PURPOSE. Each arm runs twice, once `external` and once
// `local`, and the driver reports both outcomes. `test_provenance_not_consulted_during_execution`
// asserts they are equal — through the REAL module, not a stub, which is the only place the claim
// means anything.

import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { Fr } from '@aztec/foundation/curves/bn254';
import { GlobalVariables } from '@aztec/stdlib/tx';
import { GasFees } from '@aztec/stdlib/gas';
import { mockTx } from '@aztec/stdlib/testing';

import { defaultPublicSimulatorConfig, feeJuiceBalanceLeafSlot, fundFeeJuice } from './fee_juice.ts';
import { decodePublicTxResult, residentWorldStateRevision } from './avm_inputs.ts';
import { encodeForShippedModuleOnly } from './shipped_module_config.ts';
import { executeExternallySettledTx } from './form_a.ts';
import { externalTx, locallyOriginatedTx } from './submitted_tx.ts';
import { ResidentMerkleDb } from './resident_db.ts';
import { txFromBuffer } from './tx_intake.ts';
import { WasmAvmPublicTxSimulator } from './wasm_avm_public_tx_simulator.ts';

interface ReactorLike {
  createContractDb(): number;
  createMerkleDb(): number;
  destroyContractDb(handle: number): void;
  destroyMerkleDb(handle: number): void;
  callWithBlob(exportName: string, handle: number, blob: Uint8Array): unknown;
  simulate(input: Uint8Array, contractDb: number, merkleDb: number): { revertCode: number; result: unknown };
  /** A copy of the module's raw result buffer. See the note on `decodeResult` below. */
  result(): Uint8Array | null;
  readonly moduleCalls: number;
}

const FUNDING = new Fr(10n ** 12n);

/** One arm's inputs. `seed` keeps the mock transactions distinct. */
interface ArmSpec {
  readonly name: string;
  readonly seed: number;
  readonly fund: boolean;
  readonly setupCalls: number;
  readonly appLogicCalls: number;
  readonly teardownCall: boolean;
  /** Seed the nullifier tree with the transaction's own private nullifier before running. */
  readonly clash: 'none' | 'nonRevertible' | 'revertible';
}

// THE SEEDS ARE ALL >= 1000 AND THAT IS LOad-BEARING. `mockTx(seed, ...)` derives its private
// nullifiers as `seed + 1` and `seed + 2`, and the resident nullifier tree is PREFILLED with the
// protocol's own genesis nullifiers — measured against the real module, every value up to at
// least 102 is already in the tree and every value from 1001 up is insertable. So a seed under a
// hundred makes EVERY arm collide, including the ones that are supposed to land, and the suite
// would report "the transaction was thrown out" for the recoverable case and look like a correct
// asymmetry test.
//
// WHAT ACTUALLY GUARDS IT, named precisely because an earlier revision of this comment named a
// `verify_form_a_arms_are_distinguishable` that does not exist. Three things, none of which a
// suite in which every arm collided could satisfy at once:
//   * `merkle.insertNullifier` below throws "Leaf is not updateable" if the value is already in
//     the tree, so a seed that collided with genesis fails the arm loudly rather than quietly;
//   * `test_nonrevertible_nullifier_collision_throws_tx_out` asserts `appLogicOnlyFunded` LANDS
//     and that the two non-collision arms seeded nothing at all;
//   * the same check asserts `setupCallFails` is rejected as `setupCallFailed` rather than as a
//     collision, so an arm that collided by accident reads as the wrong reason, not as a pass.
const ARMS: readonly ArmSpec[] = [
  { name: 'appLogicOnlyFunded', seed: 1011, fund: true, setupCalls: 0, appLogicCalls: 1, teardownCall: false, clash: 'none' },
  { name: 'appLogicOnlyUnfunded', seed: 1011, fund: false, setupCalls: 0, appLogicCalls: 1, teardownCall: false, clash: 'none' },
  { name: 'setupCallFails', seed: 1021, fund: true, setupCalls: 1, appLogicCalls: 0, teardownCall: false, clash: 'none' },
  { name: 'nonRevertibleNullifierClash', seed: 1031, fund: true, setupCalls: 0, appLogicCalls: 1, teardownCall: false, clash: 'nonRevertible' },
  { name: 'revertibleNullifierClash', seed: 1041, fund: true, setupCalls: 0, appLogicCalls: 1, teardownCall: false, clash: 'revertible' },
  // THE TEARDOWN PAIR, and both halves carry an APP_LOGIC call for a measured reason. `pay_fee`
  // is called AFTER simulate()'s teardown catch and outside every try, so a teardown that reverts
  // rolls the state back to post-setup and STILL PAYS. But teardown gas is accounted SEPARATELY
  // and is not billed: with no APP_LOGIC call, a transaction whose only work is a failing teardown
  // reports `totalGas 0` and `transactionFee 0x0` — measured — and "it still pays its fee" would
  // be vacuously true of a fee of nothing. With one APP_LOGIC call in both halves the pair differs
  // in exactly the teardown request, both pay a non-zero fee, and the revert code is free to move.
  { name: 'teardownReverts', seed: 1051, fund: true, setupCalls: 0, appLogicCalls: 1, teardownCall: true, clash: 'none' },
  { name: 'noTeardown', seed: 1051, fund: true, setupCalls: 0, appLogicCalls: 1, teardownCall: false, clash: 'none' },
];

async function buildTx(spec: ArmSpec, feePayer: AztecAddress) {
  return await mockTx(spec.seed, {
    numberOfNonRevertiblePublicCallRequests: spec.setupCalls,
    numberOfRevertiblePublicCallRequests: spec.appLogicCalls,
    numberOfRevertibleNullifiers: spec.clash === 'revertible' ? 1 : 0,
    hasPublicTeardownCallRequest: spec.teardownCall,
    feePayer,
  });
}

/** The nullifier this transaction will insert in the named bucket, or undefined. */
function clashingNullifier(tx: any, clash: ArmSpec['clash']): Fr | undefined {
  if (clash === 'none') {
    return undefined;
  }
  const data = clash === 'revertible'
    ? tx.data.forPublic.revertibleAccumulatedData
    : tx.data.forPublic.nonRevertibleAccumulatedData;
  const candidates = data.nullifiers.filter((n: Fr) => !n.isZero());
  return candidates.length > 0 ? candidates[0] : undefined;
}

export interface ArmReport {
  readonly arm: string;
  /** Whether the tx carried a public call in each phase, read off the DESERIALIZED transaction. */
  readonly shape: unknown;
  /** `landed` / `rejected` / `threw`, once per provenance. */
  readonly external: unknown;
  readonly local: unknown;
  /** True when the two provenances produced the same JSON. The DD-1 claim, through the module. */
  readonly provenanceAgnostic: boolean;
  /** The clashing nullifier that was seeded, if any. */
  readonly seededNullifier: string | null;
  /** The fee-juice leaf slot funded, if any. */
  readonly fundedLeafSlot: string | null;
  /** The fee payer's balance read back out of the resident tree, before and after. */
  readonly balanceBefore: string | null;
  readonly balanceAfter: string | null;
}

async function runOne(
  reactor: ReactorLike,
  spec: ArmSpec,
  globals: GlobalVariables,
  provenance: 'external' | 'local',
): Promise<{
  report: unknown;
  seededNullifier: string | null;
  fundedLeafSlot: string | null;
  balanceBefore: string | null;
  balanceAfter: string | null;
  shape: unknown;
}> {
  const contractDb = reactor.createContractDb();
  const merkleDb = reactor.createMerkleDb();
  try {
    const feePayer = await AztecAddress.fromField(new Fr(BigInt(7_000_000 + spec.seed)));
    const merkle = new ResidentMerkleDb(reactor, merkleDb);

    const leafSlot = await feeJuiceBalanceLeafSlot(feePayer);
    let fundedLeafSlot: string | null = null;
    if (spec.fund) {
      fundedLeafSlot = (await fundFeeJuice(merkle, feePayer, FUNDING)).toString();
    }
    const balanceBefore = merkle.readPublicDataLeaf(leafSlot);

    const built = await buildTx(spec, feePayer);

    // THE ROUND TRIP. Everything below reads the DESERIALIZED transaction, never `built`.
    const wire = built.toBuffer();
    const tx = txFromBuffer(wire);

    // The seed is a PRECONDITION of the arm, so its success is asserted here rather than assumed:
    // if the value were already in the genesis tree, the insert throws "Leaf is not updateable"
    // and the arm would go on to observe a collision it did not cause.
    let seededNullifier: string | null = null;
    const clash = clashingNullifier(tx, spec.clash);
    if (clash !== undefined) {
      merkle.insertNullifier(clash);
      seededNullifier = clash.toString();
    }

    const config = defaultPublicSimulatorConfig();
    // THE MODULE'S OWN REVERT CODE IS THE RUNTIME'S OUTCOME, AND UPSTREAM'S IS CARRIED BESIDE IT.
    //
    // The C++ `RevertCode` has four values — OK, APP_LOGIC_REVERTED, TEARDOWN_REVERTED,
    // BOTH_REVERTED — and the module returns them. The PUBLISHED `@aztec/stdlib` collapses them:
    // `RevertCodeEnum` declares only `OK = 0` and `REVERTED = 1`, and `toRevertCodeEnum` coerces
    // "any value >= 1" to 1, so `PublicTxResult.fromPlainObject` turns a 3 into a 1. Measured
    // directly: the raw msgpack field reads 3, `TxOutcome.revertCode` reads 3, and
    // `result.revertCode.getCode()` reads 1 for the same call. So WHICH PHASE reverted does not
    // survive upstream's own TypeScript type, and a check that read only the typed value could
    // not tell a teardown revert from an app-logic one. Both are reported.
    const simulator = new WasmAvmPublicTxSimulator(
      {
        simulate: (input, c, m) => reactor.simulate(input, c, m),
        get moduleCalls() {
          return reactor.moduleCalls;
        },
      },
      { contractDb, merkleDb },
      globals,
      (t, g) => encodeForShippedModuleOnly(t, g, config, residentWorldStateRevision(1)),
      // THE BOUNDARY HANDS BACK A DECODED VALUE AND `PublicTxResult` NEEDS THE BYTES. M17's
      // `Reactor.simulate` decodes with node-host's own dependency-free decoder, which is right
      // for a transcript — it yields `Uint8Array` for a msgpack `bin` and never an `Fr`. Upstream's
      // `PublicTxResult.fromPlainObject` needs the decode to have gone THROUGH the registered
      // extensions, so the raw buffer is re-read here and decoded by `decodePublicTxResult`. Two
      // decoders, and `avm_inputs.ts` says why they are not interchangeable; handing the first
      // one's output to the second is a `TypeError`, which is how this was found.
      () => decodePublicTxResult(reactor.result()!),
    );

    const submitted = provenance === 'external' ? externalTx(tx) : locallyOriginatedTx(tx);
    let report: unknown;
    try {
      const outcome = await executeExternallySettledTx(submitted, simulator);
      report = outcome.kind === 'processed'
        ? {
            kind: 'processed',
            // THE RUNTIME'S OWN OUTCOME, off the outcome object rather than off a closure this
            // driver used to hang on the boundary. `form_a.ts` reports the module's four-valued
            // code because upstream's published type cannot carry it (DRIFT.md D18), and a driver
            // that scraped it separately would have made that a property of the driver rather
            // than of the runtime.
            rawRevertCode: outcome.revertCode ?? null,
            revertedIn: outcome.revertedIn ?? null,
            // Upstream's collapsed code, kept beside it so both are visible and the narrowing is
            // asserted in both directions rather than assumed.
            revertCode: outcome.result.revertCode.getCode(),
            reverted: !outcome.result.revertCode.isOK(),
            totalGas: outcome.result.gasUsed.totalGas.l2Gas,
            transactionFee: outcome.result.publicTxEffect?.transactionFee?.toString() ?? null,
          }
        : { kind: 'failed', reason: outcome.reason };
    } catch (error) {
      report = { kind: 'threw', name: (error as Error).name, message: (error as Error).message.slice(0, 200) };
    }

    return {
      report,
      seededNullifier,
      fundedLeafSlot,
      balanceBefore,
      balanceAfter: merkle.readPublicDataLeaf(leafSlot),
      shape: {
        setup: tx.getNonRevertiblePublicCallRequestsWithCalldata().length,
        appLogic: tx.getRevertiblePublicCallRequestsWithCalldata().length,
        teardown: tx.getTeardownPublicCallRequestWithCalldata() ? 1 : 0,
        wireBytes: wire.length,
        // THE ALLOCATION, READ OFF THE TRANSACTION. "An exceptional halt consumes all allocated
        // L2 gas" was asserted against a hand-typed 6540000. The value is right — `mockTx`
        // defaults `gasLimits` to `new Gas(MAX_TX_DA_GAS, MAX_PROCESSABLE_L2_GAS)` and
        // `@aztec/constants` declares that as 6540000 — but the assertion's NAME claimed a
        // relationship its body never tested, so an upstream bump would have read as the AVM
        // ceasing to consume all its gas. `@aztec/constants` also carries
        // `AVM_MAX_PROCESSABLE_L2_GAS = 6000000` right beside it, which is the neighbour a typed
        // constant gets confused with. Reported here so the check can compare the two measured
        // numbers instead.
        gasLimitL2: Number(tx.data.constants.txContext.gasSettings.gasLimits.l2Gas),
      },
    };
  } finally {
    reactor.destroyMerkleDb(merkleDb);
    reactor.destroyContractDb(contractDb);
  }
}

/**
 * The globals every arm runs under.
 *
 * THE GAS FEES ARE NON-ZERO AND THAT IS THE WHOLE POINT OF THIS FUNCTION. `GlobalVariables.empty()`
 * has `gasFees` of zero, so the transaction fee computes to zero, so `pay_fee` finds every balance
 * sufficient — including the empty one — and the unfunded arm LANDS. Measured: with empty globals
 * `appLogicOnlyUnfunded` reported `landed / revertCode 1 / transactionFee 0x0`, indistinguishable
 * from the funded arm, and a suite built on it would have asserted fee enforcement while never
 * exercising it. One below the transaction's own `maxFeesPerGas` of 10, so
 * `computeEffectiveGasFees` clamps to this rather than to the cap.
 */
function armGlobals(): GlobalVariables {
  const empty = GlobalVariables.empty();
  return GlobalVariables.from({ ...empty, gasFees: new GasFees(1n, 1n) });
}

/** Run every arm under both provenances. */
export async function runFormAArms(reactor: ReactorLike): Promise<ArmReport[]> {
  const globals = armGlobals();
  const reports: ArmReport[] = [];
  for (const spec of ARMS) {
    const ext = await runOne(reactor, spec, globals, 'external');
    const loc = await runOne(reactor, spec, globals, 'local');
    reports.push({
      arm: spec.name,
      shape: ext.shape,
      external: ext.report,
      local: loc.report,
      provenanceAgnostic: JSON.stringify(ext.report) === JSON.stringify(loc.report),
      seededNullifier: ext.seededNullifier,
      fundedLeafSlot: ext.fundedLeafSlot,
      balanceBefore: ext.balanceBefore,
      balanceAfter: ext.balanceAfter,
    });
  }
  return reports;
}
