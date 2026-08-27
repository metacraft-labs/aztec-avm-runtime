// Poseidon2, from the module the page has ALREADY downloaded.
//
// ===========================================================================================
// THIS FILE IS DD-11. IT IS NOT AN OPTIMISATION AND IT IS NOT A SHIM AROUND A MISSING FEATURE.
// ===========================================================================================
//
// DD-11: "a page which only executes a public transaction never fetches the barretenberg wasm at
// all". Before this existed that was unsatisfiable, and the reason was measured rather than
// guessed. Instrumenting `Barretenberg.initSingleton` around one Form A run — the public-only
// path, nothing private, no proving — gives **82 calls**, from exactly four sites, all four inside
// `@aztec/foundation/dest/crypto/poseidon/index.js`:
//
//     26  feeJuiceBalanceLeafSlot -> @aztec/protocol-contracts/fee-juice -> hash/map_slot.js
//     26  feeJuiceBalanceLeafSlot -> @aztec/stdlib/hash/hash.js:151
//     16  HashedValues.fromValues  -> @aztec/stdlib/hash/hash.js:172
//     14  Tx.getTxHash             -> private_to_public_kernel_circuit_public_inputs.js:67
//
// In a browser those four become `BarretenbergSync.initSingleton()`, whose `fetchCode` does
// `await import('./barretenberg.js')` and then `fetch(url)` — **7.9 MB of proving stack, to
// compute a hash**. So the page would pay sixty times the AVM's own size for a poseidon.
//
// `avm.wasm` IS A BARRETENBERG BUILD. `vm2_sim` links `crypto_poseidon2` already — the AVM has a
// Poseidon2 gadget and every tree in `world_state_reference` hashes with it — so the function is
// in the module the page has just downloaded whether or not anybody exports it. M27's thirteenth
// overlay (`verification/m27/0001-*.patch`) exports it, and this file is the host side.
//
// ===========================================================================================
// IT MUST AGREE WITH BB.JS, AND THAT IS ASSERTED RATHER THAN ARGUED.
// ===========================================================================================
//
// A poseidon that is wrong by one round constant produces a fee-juice leaf slot nobody reads: the
// funding "succeeds", the transaction then fails for insufficient funds, and the cause is four
// layers away. `test_browser_crypto_matches_bb_js` runs BOTH implementations over a corpus —
// the empty input, singletons, the four lengths the measured call sites use, and random vectors —
// and requires equality on every one, with a NEGATIVE CONTROL that a perturbed input disagrees, so
// "they matched" is not "the comparison compared nothing".
//
// ===========================================================================================
// WHAT THIS IS NOT.
// ===========================================================================================
//
// It is not a reimplementation of poseidon2. There is no round constant in this file and no field
// arithmetic. Enumerated first, across the fork, `upstream/tsavm`, the vendored `spike/`,
// `drift/`, `diffsim/` copies and all five `node_modules` roots: there is **no JavaScript or
// TypeScript poseidon2 anywhere** — every hit is either C++, a circuit relation generator, or a
// caller of `bb.js`. Writing one would have been writing cryptography, which this campaign's reuse
// discipline forbids for a much weaker reason than the one that applies here.

import { Fr } from '@aztec/foundation/curves/bn254';

import { Reactor } from '../../node-host/src/reactor.ts';

// ===========================================================================================
// THE ENCODER IS AN ARGUMENT, AND THE REASON IS A CYCLE THAT WAS MEASURED RATHER THAN FORESEEN.
// ===========================================================================================
//
// The obvious spelling is `import { serializeWithMessagePack } from '@aztec/stdlib/avm'` here.
// It builds, and the page then dies at module-evaluation time with
// `TypeError: Cannot read properties of undefined (reading 'UInt64')` inside `@aztec/stdlib`'s
// schema table — a temporal-dead-zone error four packages away from anything this file does.
//
// The cause is that this module is REACHED FROM `@aztec/foundation`'s own initialisation: the
// build redirects `@aztec/foundation/crypto/poseidon` at `foundation_poseidon.ts`, which imports
// this file. Importing `@aztec/stdlib` from here therefore inserts the whole of `@aztec/stdlib`
// into the middle of `@aztec/foundation`'s evaluation order, and `@aztec/stdlib` imports
// `@aztec/foundation` back. The original module imported `field.js` and `serialize.js` and nothing
// else, and the substitute has to keep that property.
//
// So the encoder is passed in by whoever builds the backend — `runtime.ts`, which is nowhere near
// foundation's init graph — and this file's import list stays inside the one package it replaces
// a module of. A SUBSTITUTED MODULE INHERITS ITS PREDECESSOR'S DEPENDENCY BUDGET, and that is the
// general rule the incident taught.

/** Encodes a field vector as msgpack `std::vector<FF>`. Upstream's `serializeWithMessagePack`. */
export type FieldVectorEncoder = (fields: Fr[]) => Uint8Array;

/** The two primitives every `@aztec/foundation` poseidon export reduces to. */
export interface Poseidon2Backend {
  /** `bb::crypto::Poseidon2<Poseidon2Bn254ScalarFieldParams>::hash`. Any length, including zero. */
  hash(inputs: readonly Fr[]): Fr;
  /** `Poseidon2Permutation<...>::permutation`. Exactly four in, four out. */
  permutation(state: readonly Fr[]): Fr[];
  /** Calls made into the module for hashing, so "the page used the AVM's poseidon" is a number. */
  readonly calls: number;
}

/** The permutation's state width. `Params::t` on the C++ side; the module refuses any other. */
export const POSEIDON2_STATE_WIDTH = 4;

/** The module answered something that is not a 32-byte field element. */
export class Poseidon2ResultUnreadable extends Error {
  constructor(what: string, got: string) {
    super(`avm.wasm's ${what} returned something this host cannot read as a field element: ${got}`);
    this.name = 'Poseidon2ResultUnreadable';
  }
}

/** The module does not export poseidon2 — i.e. it is not built from M27's overlay stack. */
export class Poseidon2NotExported extends Error {
  constructor(missing: readonly string[]) {
    super(
      `this avm.wasm does not export ${missing.join(' or ')}. A browser page needs the module's own ` +
        'poseidon2, because the alternative is downloading 7.9 MB of proving stack for a hash ' +
        '(DD-11). Build one from M27\'s overlay stack: just avm-wasm-build-m27.',
    );
    this.name = 'Poseidon2NotExported';
  }
}

export const POSEIDON2_EXPORTS: readonly string[] = Object.freeze([
  'avm_poseidon2_hash',
  'avm_poseidon2_permutation',
]);

/** True when this module carries M27's thirteenth overlay. Asked of the ARTEFACT, never of a flag. */
export function moduleHasPoseidon2(reactor: Reactor): boolean {
  const names = reactor.exportNames;
  return POSEIDON2_EXPORTS.every((n) => names.includes(n));
}

// A field element comes back as a msgpack `bin` of 32 bytes, big-endian, which is how barretenberg
// serialises `fr` everywhere on this boundary. `node-host`'s decoder yields a `Uint8Array` for a
// `bin`; anything else is a real disagreement and is thrown rather than coerced, because the
// coercion of a wrong shape to a field element is a wrong hash.
function fieldFrom(what: string, raw: unknown): Fr {
  if (!(raw instanceof Uint8Array)) {
    throw new Poseidon2ResultUnreadable(what, `${Object.prototype.toString.call(raw)}`);
  }
  if (raw.length !== 32) {
    throw new Poseidon2ResultUnreadable(what, `a ${raw.length}-byte binary, expected 32`);
  }
  return Fr.fromBuffer(Buffer.from(raw));
}

/**
 * The backend, over a live reactor.
 *
 * SYNCHRONOUS on purpose. `BarretenbergSync` is the browser's synchronous face of bb.js and the
 * substituted `@aztec/foundation` module's own browser branch uses it; a module call into an
 * already-instantiated wasm instance is synchronous too, so nothing here has to invent an
 * asynchrony that the callers would then have to thread.
 */
export function createAvmPoseidon2(reactor: Reactor, encodeFields: FieldVectorEncoder): Poseidon2Backend {
  const missing = POSEIDON2_EXPORTS.filter((n) => !reactor.exportNames.includes(n));
  if (missing.length) throw new Poseidon2NotExported(missing);

  let calls = 0;
  const callBytes = (exportName: string, blob: Uint8Array): unknown => {
    const fn = reactor.exports[exportName] as (ptr: number, len: number) => number;
    return reactor.withBlob(blob, (ptr, len) => {
      reactor.callGuarded(exportName, () => fn(ptr, len));
      calls += 1;
      return reactor.decodedResult();
    });
  };

  return {
    hash(inputs: readonly Fr[]): Fr {
      const blob = encodeFields([...inputs]);
      return fieldFrom('avm_poseidon2_hash', callBytes('avm_poseidon2_hash', blob));
    },
    permutation(state: readonly Fr[]): Fr[] {
      if (state.length !== POSEIDON2_STATE_WIDTH) {
        throw new RangeError(
          `poseidon2Permutation takes ${POSEIDON2_STATE_WIDTH} field elements, got ${state.length}`,
        );
      }
      const raw = callBytes('avm_poseidon2_permutation', encodeFields([...state]));
      if (!Array.isArray(raw) || raw.length !== POSEIDON2_STATE_WIDTH) {
        throw new Poseidon2ResultUnreadable(
          'avm_poseidon2_permutation',
          `${Array.isArray(raw) ? `an array of ${raw.length}` : Object.prototype.toString.call(raw)}`,
        );
      }
      return raw.map((r) => fieldFrom('avm_poseidon2_permutation', r));
    },
    get calls() {
      return calls;
    },
  };
}

// ---------------------------------------------------------------------------------------------
// THE INSTALLED BACKEND.
//
// The substituted `@aztec/foundation` poseidon module (`foundation_poseidon.ts`) is a MODULE, not
// a class: upstream's callers reach it as `import { poseidon2Hash } from '@aztec/foundation/...'`
// and there is nowhere to thread a constructor argument through. So the backend is registered here
// and read there.
//
// A MISSING REGISTRATION IS A THROW AND NEVER A FALLBACK. The tempting default is "fall back to
// bb.js if nothing is installed", and it is exactly wrong: the fallback would fetch 7.9 MB, the
// page would work, and DD-11 would be violated silently by a page that looked fine. The failure a
// developer wants is the loud one.
// ---------------------------------------------------------------------------------------------
let installed: Poseidon2Backend | null = null;

/** The backend is not installed, and this runtime will not quietly fall back to bb.js. */
export class Poseidon2NotInstalled extends Error {
  constructor() {
    super(
      'no poseidon2 backend is installed. Call installPoseidon2(createAvmPoseidon2(reactor)) after ' +
        'instantiating avm.wasm. There is deliberately no fallback to @aztec/bb.js: a fallback ' +
        'would fetch 7.9 MB of proving stack and violate DD-11 on a page that looked fine.',
    );
    this.name = 'Poseidon2NotInstalled';
  }
}

export function installPoseidon2(backend: Poseidon2Backend): void {
  installed = backend;
}

export function poseidon2Backend(): Poseidon2Backend {
  if (!installed) throw new Poseidon2NotInstalled();
  return installed;
}

/** True when a backend has been installed. For a page that wants to report its own state. */
export function poseidon2Installed(): boolean {
  return installed !== null;
}

/** The five `@aztec/foundation` exports, over whichever backend is installed. */
export function poseidon2HashFields(inputFields: readonly Fr[]): Fr {
  return poseidon2Backend().hash(inputFields);
}
