// The substitute for `@aztec/foundation/dest/crypto/poseidon/index.js`.
//
// THE ONLY MODULE THIS BUILD REPLACES, AND THE SUBSTITUTION IS ONE-FOR-ONE.
//
// `browser/build.mjs` installs an esbuild `onResolve` that redirects that ONE file here. Nothing
// else in `@aztec/foundation`, `@aztec/stdlib` or `@aztec/protocol-contracts` is touched, and
// `@aztec/bb.js` stays in the module graph and stays resolved from `dest/browser/` — which is what
// keeps `verify_bb_js_browser_condition_honoured` a statement about something rather than a
// statement about an absence.
//
// THE FIVE EXPORTS ARE UPSTREAM'S FIVE, WITH UPSTREAM'S SIGNATURES, INCLUDING THE ASYNCHRONY.
// Upstream's browser branch calls `BarretenbergSync` synchronously and then returns a promise
// anyway, because its node branch is genuinely async. Keeping the promises means every caller —
// and there are dozens across `@aztec/stdlib` — is unchanged. `verify_browser_artifacts_lazy` compares this file's export list
// against the file it replaces, by name, and requires them to be equal as SETS rather than merely
// overlapping: an export we dropped would be
// an `undefined is not a function` in whichever caller happened to reach it first, and an export we
// added would mean the substitution had grown a surface upstream does not have.
//
// `poseidon2HashBytes`'s 31-byte chunking and little-endian reversal are upstream's, copied line
// for line, and the copy is pinned by that same check against the anchor's own source.

import { Fr } from '@aztec/foundation/curves/bn254';
import { serializeToFields } from '@aztec/foundation/serialize';

import { poseidon2Backend } from './poseidon.ts';

function hashFields(inputFields: Fr[]): Fr {
  return poseidon2Backend().hash(inputFields);
}

/**
 * Create a poseidon hash (field) from an array of input fields.
 * @param input - The input fields to hash.
 * @returns The poseidon hash.
 */
export function poseidon2Hash(input: unknown[]): Promise<Fr> {
  return Promise.resolve(hashFields(serializeToFields(input)));
}

/**
 * Create a poseidon hash (field) from an array of input fields and a domain separator.
 * @param input - The input fields to hash.
 * @param separator - The domain separator.
 * @returns The poseidon hash.
 */
export function poseidon2HashWithSeparator(input: unknown[], separator: number): Promise<Fr> {
  const inputFields = serializeToFields(input);
  inputFields.unshift(new Fr(separator));
  return Promise.resolve(hashFields(inputFields));
}

/**
 * Runs a Poseidon2 permutation.
 * @param input the input state. Expected to be of size 4.
 * @returns the output state, size 4.
 */
export function poseidon2Permutation(input: unknown[]): Promise<Fr[]> {
  return Promise.resolve(poseidon2Backend().permutation(serializeToFields(input)));
}

export function poseidon2HashBytes(input: Buffer): Promise<Fr> {
  const inputFields: Fr[] = [];
  for (let i = 0; i < input.length; i += 31) {
    const fieldBytes = Buffer.alloc(32, 0);
    input.subarray(i, i + 31).copy(fieldBytes);
    // Noir builds the bytes as little-endian, so we need to reverse them.
    fieldBytes.reverse();
    inputFields.push(Fr.fromBuffer(fieldBytes));
  }
  return Promise.resolve(hashFields(inputFields));
}
