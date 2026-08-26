// disclosure.ts — §8.4, in one file, so it cannot be diluted by being spread across several.
//
// "Every receipt carries `simulated: true`, the pinned protocol version and `proving: 'none'`, and
// `AvmRuntime.create` logs one unsuppressible line naming the pinned version and stating that no
// proofs are produced."
//
// WHY THIS IS NOT A COMMENT IN A README. Somebody will eventually point this runtime at something
// that matters — a wallet preview, a testnet dashboard, a demo that outlives its demo. The
// disclosure is what stops that being our fault, and a disclosure that lives only in prose is one
// the second reader never sees. So it travels on the RECEIPT, which is the object a caller logs,
// stores and shows to somebody else.
//
// WHAT "UNSUPPRESSIBLE" MEANS HERE, PRECISELY, because the word invites an overstatement this
// campaign would catch. It does NOT mean a caller cannot silence their own console: nothing in
// TypeScript can promise that, and claiming it would be the kind of sentence that gets quoted back
// with a counter-example. It means:
//
//   * there is no option, flag, environment variable or argument that turns the disclosure OFF —
//     `disclosureSink` REDIRECTS it and the default writes to `console.warn`;
//   * `AvmRuntime.create` records the disclosure on the runtime as a frozen object, so a caller
//     who passes `() => {}` has chosen not to display it and has not made the runtime one that
//     never disclosed; `runtime.disclosure` is a public getter and the record is the evidence;
//   * the three fields on every receipt are LITERAL TYPES — `simulated: true`, `proving: 'none'` —
//     so a receipt that said otherwise would not type-check, rather than being caught at run time
//     by a check somebody remembered to write.
//
// `test_receipt_declares_no_proving` measures all three, and its control is a runtime created with
// a sink that discards: the record is still there.
//
// THE VERSION IS A PIN WITNESS AND NOT A CONSTANT SOMEBODY TYPED. `pins.json` is the single
// authority for every version literal in this tree, and this file is registered in
// `npm_pin_witnesses` as a witness for `deletion_era` — the nightly line
// `orchestration/package.json` is on. So `tools/repin.py --check` and
// `verify_pinned_nightly_single_source` both require the literal below to EQUAL that pin, and a
// disclosure naming a version the package is not built against fails rather than misleads.

/**
 * The pinned protocol version this runtime is built against.
 *
 * This is `pins.json`'s `npm.deletion_era`, which is what `orchestration/package.json` pins every
 * `@aztec/*` dependency to. It is deliberately the TypeScript half's version and not the C++
 * anchor's commit: a version is what a reader can compare against a release, and the module's own
 * identity is separately readable at run time through its `avm_abi_version` export.
 */
export const PINNED_PROTOCOL_VERSION = '5.0.0-nightly.20260626';

/**
 * The one line `AvmRuntime.create` emits.
 *
 * It names the version and states that no proofs are produced, which are the milestone's two
 * required contents. It says "SIMULATED" first because that is the word a reader skimming a log
 * will see.
 */
export const DISCLOSURE_LINE =
  `SIMULATED AVM RUNTIME — protocol ${PINNED_PROTOCOL_VERSION}, proving: none. `
  + 'This runtime executes Aztec public transactions and produces NO PROOFS. '
  + 'Nothing it produces is settled, validated by a network, or verifiable by anyone else.';

/** The record kept on the runtime, so "it disclosed" is a fact about the object. */
export interface Disclosure {
  readonly simulated: true;
  readonly protocolVersion: string;
  readonly proving: 'none';
  readonly line: string;
  readonly disclosedAt: 'create';
}
