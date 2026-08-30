// `@aztec/stdlib/messaging` AS THE ANCHOR'S CODE EXPECTS IT, over the pin this bundle installs.
//
// The second of the two symbols the `cpp` anchor's oracle wire layer imports and the `deletion_era`
// pin does not export. `foundation_promise.ts` beside this file carries the whole account of the
// family, the measurement and why this is a shim rather than an edit to a vendored file.
//
// WHAT REACHES IT. `legacy_oracle_registry.ts` — the three retired oracle names already-deployed
// bytecode still calls — uses it in one place, the param mapping of `aztec_utl_getL1ToL2MembershipWitness`,
// to derive the fee-juice message nullifier for contracts compiled before that oracle took the
// nullifier directly. Its MODERN oracle, `aztec_utl_getL1ToL2MembershipWitnessV2`, is refused by name
// in M35 (tier 2, adapters), so nothing this milestone serves reaches this function. It is reproduced
// rather than made to refuse anyway, because it is ONE LINE of upstream's own source and a refusal
// here would be a refusal in a code path the caller cannot see, which is worse than one it can.
//
// IT IS UPSTREAM'S DERIVATION AND NOT A GUESS AT IT.
// `yarn-project/stdlib/src/messaging/l1_to_l2_message.ts:94` at the `cpp` anchor is exactly:
//
//     export function computeFeeJuiceMessageNullifier(messageHash: Fr, secret: Fr): Promise<Fr> {
//       return poseidon2HashWithSeparator([messageHash, secret], DomainSeparator.MESSAGE_NULLIFIER);
//     }
//
// `DomainSeparator.MESSAGE_NULLIFIER` is READ from `@aztec/constants` rather than typed here, and it
// does exist at the installed pin (3754509616) — so the one thing that could have made this a
// fabricated hash is a value taken from the same generated table upstream takes it from.

import type { Fr } from '@aztec/foundation/curves/bn254';
import { poseidon2HashWithSeparator } from '@aztec/foundation/crypto/poseidon';
import { DomainSeparator } from '@aztec/constants';

export * from '../../../orchestration/node_modules/@aztec/stdlib/dest/messaging/index.js';

/**
 * The fee-juice message nullifier, `poseidon2([messageHash, secret], MESSAGE_NULLIFIER)`.
 *
 * Reproduced from `yarn-project/stdlib/src/messaging/l1_to_l2_message.ts` at the `cpp` anchor; see
 * this file's header for why it is here rather than imported.
 */
export function computeFeeJuiceMessageNullifier(messageHash: Fr, secret: Fr): Promise<Fr> {
  return poseidon2HashWithSeparator([messageHash, secret], DomainSeparator.MESSAGE_NULLIFIER);
}
