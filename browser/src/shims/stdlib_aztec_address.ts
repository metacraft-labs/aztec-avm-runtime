// `@aztec/stdlib/aztec-address` AS THE ANCHOR'S CODE SPELLS IT, over the pin this bundle installs.
//
// The third of the anchor-versus-pin gaps M35 met, and the first that is a RUN-TIME failure rather
// than a build one — which makes it the dangerous kind. `foundation_promise.ts` carries the family's
// whole account; this file carries what is specific to it.
//
// WHAT WENT WRONG, AND WHERE IT SURFACED. `oracle_type_mappings.ts:286` — the `AZTEC_ADDRESS`
// deserialiser, which is one param of thirty-odd oracles including every capsule call — is
// `AztecAddress.fromFieldUnsafe(reader.readField())`. That static does not exist at the
// `deletion_era` pin, so esbuild is happy (a missing STATIC is not a missing export) and the failure
// arrives from inside the ACVM as `Error awaiting \`foreign_call_handler\``, eleven words that name
// nothing. The real one — `TypeError: U.fromFieldUnsafe is not a function` — was on `err.cause`, and
// reading it is why `private_execution.ts` walks the whole chain now.
//
// WHAT THE GAP ACTUALLY IS: A RENAME, MEASURED ON BOTH SIDES. Four statics were renamed between the
// two pins and their BODIES are identical, which is what makes this a bridge rather than a
// reimplementation:
//
//   | deletion_era 5.0.0-nightly.20260626 | cpp anchor / current 5.3.0-nightly.20260819 | body |
//   |---|---|---|
//   | `fromField(fr)`     | `fromFieldUnsafe(fr)`     | `new AztecAddress(fr)`               |
//   | `fromString(s)`     | `fromStringUnsafe(s)`     | `new AztecAddress(hexToBuffer(s))`   |
//   | `fromBigInt(n)`     | `fromBigIntUnsafe(n)`     | via `new Fr(n)`                      |
//   | `fromNumber(n)`     | `fromNumberUnsafe(n)`     | via `new Fr(n)`                      |
//
// The `Unsafe` suffix is upstream saying out loud what the old names did silently — construct an
// address WITHOUT checking it is a point on the Grumpkin curve. Nothing about the check changed;
// only what it is called.
//
// WHY A PROXY AND NOT A MONKEYPATCH. Assigning the four statics onto the installed class would work
// and would be global: every importer in the bundle would see a class with methods its own pin does
// not have, and a later reader would find them and not know where they came from. A `Proxy` over the
// class is scoped to the importers the build points here — `browser/src/vendor/pxe/` and nothing else
// — and it preserves the two properties that matter. `new Proxy(C, …)` is constructible, so
// `new AztecAddress(...)` still builds a real one; and the prototype is untouched, so
// `x instanceof AztecAddress` is the same question it was, for values built on either side of the
// proxy.
//
// WHAT MEASURES THIS FILE, and it is a real execution rather than a unit test of the shim. The
// `AZTEC_ADDRESS` deserialiser is on the path of every oracle that takes an address, and
// `aztec_utl_getContractInstance` is the first oracle a real contract reaches after the version
// check. So the `private` arm's `Token.transfer` frame — 76,875 bytes of real ACIR, in Chromium —
// deserialises an address through this proxy on its way to that oracle's refusal, and that is
// exactly the step that failed with `TypeError: U.fromFieldUnsafe is not a function` before this
// file existed. `test_unimplemented_oracle_refuses_by_name` asserts the frame REACHES the refusal
// and that no `fromFieldUnsafe` appears anywhere in its error chain — the pair that says the
// deserialisation ran rather than being skipped.

import * as real from '../../../orchestration/node_modules/@aztec/stdlib/dest/aztec-address/index.js';

export * from '../../../orchestration/node_modules/@aztec/stdlib/dest/aztec-address/index.js';

type AnyStatic = Record<string, unknown>;

/** The four renames, newest name first. Each value is the name the installed pin uses. */
const RENAMED: Readonly<Record<string, string>> = Object.freeze({
  fromFieldUnsafe: 'fromField',
  fromStringUnsafe: 'fromString',
  fromBigIntUnsafe: 'fromBigInt',
  fromNumberUnsafe: 'fromNumber',
});

const RealAztecAddress = (real as AnyStatic).AztecAddress as unknown as new (...a: never[]) => unknown;

/**
 * `AztecAddress`, answering the anchor's spellings as well as the pin's.
 *
 * A name the pin already carries is passed straight through, so this cannot mask a real absence: if
 * upstream renames something back, the proxy stops standing in and the failure is the honest one.
 */
export const AztecAddress: typeof RealAztecAddress = new Proxy(RealAztecAddress, {
  get(target, prop, receiver) {
    if (typeof prop === 'string' && Reflect.get(target, prop) === undefined && RENAMED[prop]) {
      const fallback = Reflect.get(target, RENAMED[prop]);
      if (typeof fallback === 'function') {
        return (fallback as (...a: unknown[]) => unknown).bind(target);
      }
    }
    return Reflect.get(target, prop, receiver);
  },
}) as typeof RealAztecAddress;

/** The renames this shim bridges, so a check can read the list rather than re-derive the intent. */
export const ANCHOR_PIN_RENAMED_STATICS: Readonly<Record<string, string>> = RENAMED;
