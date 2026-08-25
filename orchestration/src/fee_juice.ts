// fee_juice.ts — DD-2: fee enforcement is ON, and funding is the declared shortcut.
//
// TWO SLOTS, AND CONFUSING THEM PRODUCES A PLAUSIBLE WRONG ANSWER. The AVM reads a fee payer's
// balance at a STORAGE slot inside the FeeJuice contract; the public data TREE stores it at a
// LEAF slot that additionally silos by contract address. Writing a balance at the storage slot
// instead of the leaf slot puts a number in the tree that nothing reads, and the transaction then
// fails for insufficient funds with the funding "done". Both are named below and both come from
// upstream.
//
// THE DERIVATION IS UPSTREAM'S ON BOTH SIDES OF THE BOUNDARY, and the two agree by construction
// rather than by our arithmetic:
//
//   C++, TxExecution::pay_fee  (vm2/simulation/gadgets/tx_execution.cpp:637-653)
//     fee_juice_balance_slot = poseidon2({ DOM_SEP__PUBLIC_STORAGE_MAP_SLOT,
//                                          FEE_JUICE_BALANCES_SLOT, fee_payer })
//     merkle_db.storage_read (FEE_JUICE_ADDRESS, fee_juice_balance_slot)
//
//   C++, FuzzerWorldStateManager::write_fee_payer_balance
//        (avm_fuzzer/common/interfaces/dbs.cpp:195-204) — upstream's own genesis-style funder
//     leaf_slot = poseidon2({ DOM_SEP__PUBLIC_LEAF_SLOT, FEE_JUICE_ADDRESS,
//                             fee_juice_balance_slot })
//     insert_indexed_leaves_public_data_tree(PublicDataLeafValue(leaf_slot, balance))
//
//   TypeScript, both published and both already installed here
//     computeFeePayerBalanceStorageSlot(feePayer)          @aztec/protocol-contracts/fee-juice
//     computePublicDataTreeLeafSlot(FeeJuice, storageSlot) @aztec/stdlib/hash
//     computeFeePayerBalanceLeafSlot(feePayer)             the two above, composed, ALSO published
//
// `test_fee_juice_debited_and_insufficiency_throws` runs the TypeScript pair and asserts the composite
// equals `computeFeePayerBalanceLeafSlot`, and pins both C++ derivations by reading them out of
// the sources, so a change on either side is a red check rather than a wrong balance.
//
// WHY `fundFeeJuice` IS OURS AND WHAT IT IS MODELLED ON. Enumerated across the fork, the second
// checkout at `upstream/tsavm`, the three vendored copies and five `node_modules` roots: at both
// anchors `fundFeeJuice`, `fund_fee_juice` and `bridgeFeeJuice` have zero hits anywhere, and the
// only `mintFeeJuice` is a private method of `end-to-end/src/fixtures/e2e_prover_test.ts` that
// BRIDGES FROM L1 — which is the thing a genesis shortcut exists to avoid. The does-not-exist
// reason is therefore established rather than assumed. What DOES exist is
// `BaseAvmSimulationTester.setFeePayerBalance` (fork HEAD:
// `simulator/src/public/avm/testing/base_avm_simulation_tester.ts:40`; note the directory rename
// from `avm/fixtures/` at the older anchor, which defeats path-based greps), and it is the same
// two lines: compute the storage slot with upstream's helper, then write the balance at the leaf
// slot. It is not reusable as-is because it writes through a `MerkleTreeWriteOperations` — the
// LMDB-backed native world state — and this runtime's world state is resident inside `avm.wasm`.
// So the DERIVATION is upstream's and only the WRITE is ours, which is the same division as
// `avm_inputs.ts`.
//
// DD-2, MEASURED RATHER THAN ASSERTED IN PROSE: `PublicSimulatorConfig.from({}).skipFeeEnforcement`
// is `false` (stdlib/src/avm/avm.ts:1466 `obj.skipFeeEnforcement ?? false`; C++ mirror
// `vm2/common/avm_io.hpp:449 bool skip_fee_enforcement = false`). `defaultPublicSimulatorConfig()`
// below goes through `PublicSimulatorConfig.from` rather than restating the default, so it cannot
// disagree with upstream, and `test_fee_juice_debited_and_insufficiency_throws` reads the value
// off the constructed object rather than off this comment.

import { computeFeePayerBalanceLeafSlot, computeFeePayerBalanceStorageSlot } from '@aztec/protocol-contracts/fee-juice';
import { ProtocolContractAddress } from '@aztec/protocol-contracts';
import type { AztecAddress } from '@aztec/stdlib/aztec-address';
import { PublicSimulatorConfig } from '@aztec/stdlib/avm';
import type { Fr } from '@aztec/foundation/curves/bn254';
import { computePublicDataTreeLeafSlot } from '@aztec/stdlib/hash';

/** The storage slot the AVM reads, inside the FeeJuice contract. Upstream's helper, unwrapped. */
export function feeJuiceBalanceStorageSlot(feePayer: AztecAddress): Promise<Fr> {
  return computeFeePayerBalanceStorageSlot(feePayer);
}

/**
 * The public-data-tree leaf slot the balance is STORED at, siloed by the FeeJuice address.
 *
 * Composed here from the two published helpers rather than calling
 * `computeFeePayerBalanceLeafSlot` directly, so that the composition is the thing under test:
 * `test_fee_juice_debited_and_insufficiency_throws` asserts this equals upstream's composite. If they
 * ever disagreed, one of the two is what the AVM reads and the other is what we wrote.
 */
export async function feeJuiceBalanceLeafSlot(feePayer: AztecAddress): Promise<Fr> {
  const storageSlot = await computeFeePayerBalanceStorageSlot(feePayer);
  return await computePublicDataTreeLeafSlot(ProtocolContractAddress.FeeJuice, storageSlot);
}

/** Upstream's own composite, re-exported so a check can compare the two without importing twice. */
export { computeFeePayerBalanceLeafSlot };

/**
 * The narrow view of a resident public data tree that funding needs.
 *
 * Structural rather than nominal, for the same reason `AvmBoundary` is: the browser (M28) supplies
 * a different implementation and a nominal type would make that a rewrite.
 */
export interface ResidentPublicDataTree {
  /** Insert (or overwrite) a public-data leaf at `leafSlot`. */
  insertPublicDataLeaf(leafSlot: Fr, value: Fr): void;
}

/**
 * The genesis-style shortcut DD-2 declares: put a balance in the tree without bridging from L1.
 *
 * This is NOT a fee-payment path and must not be reachable from one. It writes a leaf; it does not
 * mint, does not consult L1, and does not go through the FeeJuice contract's own logic. A dev
 * chain needs it because the alternative is an L1 deposit, and M20's fee tests need a funded payer
 * before any transaction runs.
 *
 * Returns the leaf slot written, so a caller can assert against it rather than re-deriving.
 */
export async function fundFeeJuice(
  tree: ResidentPublicDataTree,
  feePayer: AztecAddress,
  amount: Fr,
): Promise<Fr> {
  if (feePayer.isZero()) {
    throw new Error(
      'fundFeeJuice refuses the zero address. The AVM treats a zero fee payer as "nobody pays" and '
        + 'branches on skipFeeEnforcement before it ever reads a balance (tx_execution.cpp:625-633), '
        + 'so funding it would write a leaf that can never be read.',
    );
  }
  const leafSlot = await feeJuiceBalanceLeafSlot(feePayer);
  tree.insertPublicDataLeaf(leafSlot, amount);
  return leafSlot;
}

/**
 * The configuration Form A runs under. Fee enforcement is ON because upstream's default is, and
 * this goes through `PublicSimulatorConfig.from` so the two cannot drift apart.
 *
 * `skipFeeEnforcement: true` is available to a caller that asks for it by name. Upstream's own
 * split is worth knowing before choosing: production, proving and block-building paths pin
 * `false`; wallet and PXE gas-ESTIMATION paths pin `true`, because an estimate is allowed to run
 * a transaction nobody could afford.
 */
export function defaultPublicSimulatorConfig(
  overrides: Partial<PublicSimulatorConfig> = {},
): PublicSimulatorConfig {
  return PublicSimulatorConfig.from(overrides);
}
