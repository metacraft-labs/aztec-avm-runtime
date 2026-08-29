// dev_keys.ts — deterministic key derivation for a DEBUGGING wallet.
//
// ===========================================================================================
// THE DESIGN GOAL, STATED HERE SO NOBODY LATER "HARDENS" IT INTO USELESSNESS.
// ===========================================================================================
//
// A production wallet guards keys and hides its reasoning. **A debugging wallet must do the
// opposite**: every decision visible, every derivation explicable, and keys DETERMINISTIC so that
// a recording replays identically. Those are properties a real wallet CANNOT have and a CodeTracer
// wallet SHOULD. `DEV-WALLET.md` §1 says the same thing where a reader will find it.
//
// The concrete consequence is the rule below, and it is DD-4's discipline applied to entropy
// instead of to time:
//
//   **NO AMBIENT RANDOMNESS.** The seed is an argument. It is recorded in the trace metadata. A
//   run with the same seed derives the same addresses; a run with a different seed derives
//   different ones. `Fr.random()`, `crypto.getRandomValues` and `Math.random` appear nowhere in
//   this file or in `dev_wallet.ts`, and `test_wallet_keys_deterministic` §4 asserts that over the
//   BUILT bundle's own module graph with a control that can see one.
//
// DD-4 is the precedent and the reason is the same: a clock read from the ambient environment makes
// a recording that cannot be replayed, and so does a key. Upstream's own wallets call `Fr.random()`
// for an account secret (`AccountManager`, and upstream's own end-to-end `TestWallet`), which is
// right for a wallet holding somebody's money and wrong for one whose whole purpose is that the
// recording comes out the same twice.
//
// ===========================================================================================
// THE DERIVATION IS UPSTREAM'S, AND THAT IS A MEASUREMENT RATHER THAN A PREFERENCE.
// ===========================================================================================
//
// `deriveKeys(secret)` and `computeAddress(publicKeys, partialAddress)` are `@aztec/stdlib/keys`'
// own functions — the same two an Aztec account uses — so a dev account's address is a real Aztec
// address derived by upstream's rule and not a number this repository invented. What M34 supplies
// is only the SEED-TO-SECRET step, which upstream leaves to the wallet because upstream's wallets
// take that from a random source.
//
// THAT ROUTE IS DD-11-CLEAN, AND IT WAS NOT OBVIOUS. `browser/src/foundation_grumpkin.ts` records
// that address derivation is the SECOND route from a public-only page to the 7.9 MB proving stack,
// found in the browser's own network log. Under this build's redirect table:
//
//   * `deriveKeys`  -> `sha512ToGrumpkinScalar` (hash.js, pure JS) for the six master secrets, then
//                      `derivePublicKeyFromSecretKey` -> `Grumpkin.mul` -> **`avm.wasm`'s
//                      `avm_grumpkin_mul`**;
//   * `publicKeys.hash()` and the preaddress -> `poseidon2HashWithSeparator` -> **`avm.wasm`'s
//     poseidon2**;
//   * `computeAddress` -> one more `Grumpkin.mul` and one `Grumpkin.add`, both the module's.
//
// So a page deriving dev accounts fetches nothing it did not already have.
// `verify_public_only_page_never_fetches_barretenberg`'s instrument is what would notice otherwise,
// and M34's own browser arm reads the same network log.
//
// (`foundation_grumpkin.ts`'s header says `reduce512BufferToFr` "has exactly one caller in this
// graph: `deriveKeys`". Measured against the anchor by M34: `git grep reduce512BufferToFr` over
// `yarn-project/` finds the two DECLARATIONS — grumpkin's and secp256k1's — and **no caller at
// all**; `deriveKeys` goes through `@aztec/foundation/crypto/sha512`'s `sha512ToGrumpkinScalar`,
// which is `hash.js` plus `GrumpkinScalar.fromBufferReduce`. The throw is still right — an
// unimplemented reduction must refuse rather than answer — but the sentence naming its caller is
// not, and it is corrected here rather than left, because it is the sentence that would stop
// somebody trying this route.)
//
// ===========================================================================================
// THE SEPARATOR IS DERIVED, NOT TYPED, AND IT IS ASSERTED NOT TO COLLIDE.
// ===========================================================================================
//
// `poseidon2HashWithSeparator` takes a u32 domain separator, and upstream's are in
// `@aztec/constants`' `DomainSeparator`. There is no upstream separator for "a dev wallet's account
// secret", because upstream has no such concept — so M34 derives one, the same way a constant
// should be produced rather than chosen: the first four bytes of `sha256` of a label, big-endian.
//
// `CAMPAIGN-BRIEF.md`: *"a constant you have just typed into a check looks like a measurement to
// the person typing it"*. So the value is not written down anywhere; it is computed from the label
// at module load, `test_wallet_keys_deterministic` §3 recomputes it independently from the label it
// reads out of the bundle, and it is asserted to collide with NONE of `DomainSeparator`'s members —
// an assertion with a control, because a separator that silently equalled `NOTE_HASH` would make a
// dev account secret and a note hash the same function of their inputs.

import { DomainSeparator } from '@aztec/constants';
import { poseidon2HashWithSeparator } from '@aztec/foundation/crypto/poseidon';
import { sha256 } from '@aztec/foundation/crypto/sha256';
import { Fr } from '@aztec/foundation/curves/bn254';
import type { AztecAddress } from '@aztec/stdlib/aztec-address';
import { type PublicKeys, computeAddress, deriveKeys } from '@aztec/stdlib/keys';

/** The label the account-secret separator is derived from. Read by the check, not re-typed. */
export const DEV_ACCOUNT_SEPARATOR_LABEL = 'codetracer-dev-wallet:account-secret:v1';

/** The label the partial-address separator is derived from. */
export const DEV_PARTIAL_ADDRESS_SEPARATOR_LABEL = 'codetracer-dev-wallet:partial-address:v1';

/**
 * A u32 domain separator, derived from a label rather than chosen.
 *
 * @param label - the ASCII label
 * @returns the first four bytes of its sha256, big-endian
 */
export function separatorFromLabel(label: string): number {
  const digest = sha256(Buffer.from(label, 'utf8'));
  return ((digest[0]! << 24) | (digest[1]! << 16) | (digest[2]! << 8) | digest[3]!) >>> 0;
}

/** The account-secret separator. Computed, never typed. */
export const DEV_ACCOUNT_SEPARATOR = separatorFromLabel(DEV_ACCOUNT_SEPARATOR_LABEL);

/** The partial-address separator. Computed, never typed. */
export const DEV_PARTIAL_ADDRESS_SEPARATOR = separatorFromLabel(DEV_PARTIAL_ADDRESS_SEPARATOR_LABEL);

/** Upstream's own separators, as a set, so a collision is a question a check can ask. */
export const UPSTREAM_SEPARATORS: readonly number[] = Object.freeze(
  Object.values(DomainSeparator).filter((v): v is number => typeof v === 'number'),
);

/**
 * The default seed.
 *
 * A LITERAL ON PURPOSE, and it is the one constant in this file that should be one: the seed is the
 * thing a recording records so that it can be replayed, so it has to be a value somebody can read
 * out of a trace and type back in. It is a number and not a hash of anything, because a derived
 * default would suggest the value carries meaning, and it does not — what carries meaning is that
 * two runs with the same one agree.
 */
export const DEFAULT_DEV_WALLET_SEED = '0x00000000000000000000000000000000000000000000000000000000000c0de7';

/** One deterministically derived dev account. */
export interface DevAccount {
  /** Its index under the seed. */
  readonly index: number;
  /** The account secret, `poseidon2(seed, index)` under the derived separator. */
  readonly secret: Fr;
  /** The partial address, derived from the same seed under a different separator. */
  readonly partialAddress: Fr;
  /** Upstream's `PublicKeys`, from `deriveKeys(secret)`. */
  readonly publicKeys: PublicKeys;
  /** `poseidon2` over the public keys — upstream's `PublicKeys.hash()`. */
  readonly publicKeysHash: Fr;
  /** The address, from upstream's `computeAddress`. */
  readonly address: AztecAddress;
}

/**
 * Parse a seed. Rejects anything that is not a field element, by name.
 *
 * @param seed - a `0x`-prefixed hex string or an `Fr`
 * @returns the seed as an `Fr`
 */
export function parseDevWalletSeed(seed: string | Fr): Fr {
  if (seed instanceof Fr) {
    return seed;
  }
  if (typeof seed !== 'string' || !/^0x[0-9a-fA-F]{1,64}$/.test(seed)) {
    throw new Error(
      `dev wallet seed '${String(seed)}' is not a 0x-prefixed hex field element. The seed is `
      + 'recorded in the trace so a recording replays identically; it is never generated.',
    );
  }
  return new Fr(BigInt(seed));
}

/**
 * Derive `count` dev accounts from a seed, deterministically.
 *
 * Every hash is the module's poseidon2 and every curve operation is the module's grumpkin (DD-11),
 * and nothing in this function reads a clock, a counter or a random source.
 *
 * @param seed - the recorded seed
 * @param count - how many accounts
 * @returns the accounts, in index order
 */
export async function deriveDevAccounts(seed: string | Fr, count: number): Promise<DevAccount[]> {
  const s = parseDevWalletSeed(seed);
  if (!Number.isInteger(count) || count < 1) {
    throw new Error(`deriveDevAccounts: count must be a positive integer, got ${String(count)}`);
  }
  const accounts: DevAccount[] = [];
  for (let index = 0; index < count; index++) {
    const secret = await poseidon2HashWithSeparator([s, new Fr(index)], DEV_ACCOUNT_SEPARATOR);
    const partialAddress = await poseidon2HashWithSeparator(
      [s, new Fr(index)],
      DEV_PARTIAL_ADDRESS_SEPARATOR,
    );
    const derived = await deriveKeys(secret);
    const publicKeysHash = await derived.publicKeys.hash();
    const address = await computeAddress(derived.publicKeys, partialAddress);
    accounts.push({ index, secret, partialAddress, publicKeys: derived.publicKeys, publicKeysHash, address });
  }
  return accounts;
}
