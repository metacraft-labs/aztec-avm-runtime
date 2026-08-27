// `@aztec/protocol-contracts/fee-juice`, over UPSTREAM'S OWN LAZY ARTIFACT LOADER.
//
// DD-11: "avm.wasm and CONTRACT ARTIFACTS load lazily". Measured before this existed: the eager
// barrel put **1,965 KB** of protocol-contract artifact JSON into the shared chunk —
// `ContractClassRegistry.json` 998 KB, `FeeJuice.json` 534 KB, `ContractInstanceRegistry.json`
// 427 KB — for three symbols totalling a few hundred bytes of code.
//
// THE LAZY LOADER IS UPSTREAM'S AND NOT OURS. `@aztec/protocol-contracts` ships
// `<name>/lazy.js` beside every `<name>/index.js`, doing exactly the `await import()` this needs,
// with upstream's own comment about why the import assertion is omitted for bundlers. It is what
// the deployed Playground uses (`./providers/lazy`). Two of the three barrels are redirected
// straight at it, because `class-registry/lazy.js` and `instance-registry/lazy.js` re-export the
// same event modules their eager siblings do, so the redirect is API-identical.
//
// THE THIRD ONE NEEDS SIX LINES, AND THIS FILE IS THEM. `fee-juice/lazy.js` exports
// `getFeeJuiceArtifact` and `getCanonicalFeeJuice` and NOT the two slot helpers, which are the only
// things this runtime uses. Both are already promise-returning in the eager barrel — `deriveStorageSlotInMap`
// is async — so awaiting the artifact changes no caller's signature. The bodies below are
// upstream's, line for line, with `FeeJuiceArtifact` replaced by `await getFeeJuiceArtifact()`;
// `verify_browser_artifacts_lazy` pins them against the barrel they replace.
//
// WHAT IS DELIBERATELY NOT EXPORTED: `FeeJuiceArtifact`, the eager constant. It cannot exist
// without the eager import, and nothing in this runtime's graph names it — measured, across
// `orchestration/src`, `browser/src` and `ct-host/src`, before the redirect was written. A caller
// who wants it calls `getFeeJuiceArtifact()`.

import { computePublicDataTreeLeafSlot, deriveStorageSlotInMap } from '@aztec/stdlib/hash';
import type { AztecAddress } from '@aztec/stdlib/aztec-address';
import type { Fr } from '@aztec/foundation/curves/bn254';

// Upstream's lazy module, whole. `getFeeJuiceArtifact` and `getCanonicalFeeJuice` come from here.
export * from '@aztec/protocol-contracts/fee-juice/lazy';

import { getFeeJuiceArtifact } from '@aztec/protocol-contracts/fee-juice/lazy';
import { ProtocolContractAddress } from '@aztec/protocol-contracts';

/**
 * Computes the storage slot within the Fee Juice contract for the balance of the fee payer.
 *
 * Upstream's body, with the eager `FeeJuiceArtifact` replaced by the lazy loader.
 */
export async function computeFeePayerBalanceStorageSlot(feePayer: AztecAddress): Promise<Fr> {
  const artifact = await getFeeJuiceArtifact();
  return deriveStorageSlotInMap(artifact.storageLayout.balances.slot, feePayer);
}

/**
 * Computes the leaf slot in the public data tree for the balance of the fee payer in the Fee Juice.
 *
 * Upstream's body, unchanged except that the storage slot above is awaited rather than called.
 */
export async function computeFeePayerBalanceLeafSlot(feePayer: AztecAddress): Promise<Fr> {
  const balanceSlot = await computeFeePayerBalanceStorageSlot(feePayer);
  return computePublicDataTreeLeafSlot(ProtocolContractAddress.FeeJuice, balanceSlot);
}
