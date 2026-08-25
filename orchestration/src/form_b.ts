// form_b.ts — M21: Form B is a PRODUCER OF `Tx`, not a fork of the execution path.
//
// THE ONE SENTENCE THAT SHAPES THIS FILE. §5.4's pipeline is four steps:
//
//   1. execute the private functions with `WASMSimulator`      -> `PrivateExecutionResult`
//   2. `generateSimulatedProvingResult(...)`                   -> `PrivateKernelTailCircuitPublicInputs`
//   3. `new PrivateSimulationResult(...).toSimulatedTx()`      -> a real `Tx`
//   4. wrap as `{ tx, provenance: { kind: 'local', privateExecution } }`
//
// and then the SAME public path M20 built runs it. There is no second execution window in this
// package, and `e2e_form_b_local_tx_roundtrip` section 5 asserts that BY EXECUTION: what Form B hands to
// `executeExternallySettledTx` is a `SubmittedTx<Tx>` exactly like M20's, and the outcome type it
// gets back is M20's `FormAOutcome` — `processed` / `failed`, the chain's own words, with no
// second vocabulary invented for locally-originated transactions.
//
// WHAT IS HERE TODAY AND WHAT IS NOT, stated as a boundary rather than left to be discovered.
//
//   * Steps 3 and 4 are HERE and they cost NO NEW DEPENDENCY. `PrivateSimulationResult`,
//     `PrivateExecutionResult`, `PrivateCallExecutionResult` and `Tx.create` are all
//     `@aztec/stdlib/tx`, which this package already depends on. Measured, not assumed:
//     `yarn-project/stdlib/package.json:36` maps `"./tx"`, `src/tx/index.ts:12,19` re-export both
//     result classes, and `orchestration/node_modules/@aztec/stdlib/dest/tx/` carries them.
//   * Steps 1 and 2 are NOT here, and the reason is a dependency fact rather than a difficulty.
//     `WASMSimulator` lives in `@aztec/simulator/client` and `generateSimulatedProvingResult` in
//     `@aztec/pxe`; `npm view @aztec/simulator@<this package's pin> dependencies` lists
//     `@aztec/native` AND `@aztec/world-state` as HARD dependencies, and `@aztec/pxe` hard-depends
//     on `@aztec/simulator`. Installing either puts the NAPI AVM and the LMDB world-state addon in
//     the shipped tree, which DD-9 forbids and `verify_differential_containment` asserts against in
//     three places. See REUSE-INVENTORY RI-64/RI-65 for the enumeration and the vendoring route.
//
// SO THE FILE'S JOB IS THE SEAM. Given a tail — however it was produced — turn it into the `Tx`
// upstream's own PXE would have produced, and label it with what ran the private half.
//
// THE EMPTY ENTRYPOINT IS UPSTREAM'S OWN SHORTCUT, NOT AN INVENTION OF OURS. `wallet-sdk`'s
// `simulatePublicOnly` (`yarn-project/wallet-sdk/src/base-wallet/utils.ts:118-132` at anchor `cpp`)
// builds exactly this: a `PrivateCallExecutionResult` with empty ACIR, empty witness, empty maps
// and a `PrivateCircuitPublicInputs` carrying only the public call requests, wrapped in a
// `PrivateExecutionResult` with a random first nullifier. It is how upstream expresses "there was
// no private execution, only enqueued public calls", and reusing it is what stops this file from
// growing a second answer to a question upstream has already answered.

import type { Fr } from '@aztec/foundation/curves/bn254';
import {
  PrivateCallExecutionResult,
  PrivateExecutionResult,
  PrivateSimulationResult,
} from '@aztec/stdlib/tx';
import type { HashedValues, Tx } from '@aztec/stdlib/tx';
import type {
  PrivateCircuitPublicInputs,
  PrivateKernelTailCircuitPublicInputs,
} from '@aztec/stdlib/kernel';

import {
  locallyExecutedTx,
  type LocallyExecutedTxProvenance,
  type PrivateExecutionSummary,
  type PrivateTraceHandle,
  type SubmittedTx,
} from './submitted_tx.ts';

/**
 * Which circuit simulator ran the private half.
 *
 * A named constant rather than a literal at the call site, because it is a value a consumer reads
 * off provenance and two spellings of it would be two answers to one question. `wasm` is
 * `WASMSimulator` over `@aztec/noir-acvm_js`; `none` is the honest label for a transaction whose
 * private half was not executed at all — the wallet-sdk-shaped public-only shortcut — and it is a
 * DISTINCT value rather than an omission so that "we ran nothing" cannot read as "we forgot to
 * say".
 */
export const PRIVATE_SIMULATORS = {
  /** `WASMSimulator`, `@aztec/noir-acvm_js` + `@aztec/noir-noirc_abi`. Not wired yet; RI-64. */
  wasm: 'wasm-acvm',
  /** No private execution: enqueued public calls only, upstream's `simulatePublicOnly` shape. */
  none: 'none',
} as const;

/**
 * Step 3, verbatim: `new PrivateSimulationResult(...).toSimulatedTx()`.
 *
 * This is a two-line function on purpose. `toSimulatedTx` is
 * `yarn-project/stdlib/src/tx/simulated_tx.ts:81-91` and it does four things — collects the sorted
 * contract-class logs, takes an empty `ChonkProof`, takes the public function calldata off the
 * private result, and calls `Tx.create`. Every one of those is a protocol detail we must not have
 * a second opinion about.
 *
 * NOTE WHAT UPSTREAM ITSELF DOES NOT DO HERE, because it is a live divergence and not a footnote:
 * TWO of the three upstream call sites do NOT go through `PrivateSimulationResult`. PXE does
 * (`pxe.ts:1285-1286`); TXE inlines `Tx.create({ ..., contractClassLogFields: [] })`
 * (`txe_oracle_top_level_context.ts:610-615`) and wallet-sdk inlines it the same way
 * (`utils.ts:143-148`). The difference is real — the inlined form passes an EMPTY
 * `contractClassLogFields` where `toSimulatedTx` passes
 * `collectSortedContractClassLogs(privateExecutionResult)` — so a transaction that published a
 * contract class would come out different. This runtime takes PXE's, because M21's deliverable
 * names PXE's path and because dropping logs is the direction that loses information.
 */
export async function txFromTail(
  privateExecutionResult: PrivateExecutionResult,
  publicInputs: PrivateKernelTailCircuitPublicInputs,
): Promise<Tx> {
  return await new PrivateSimulationResult(privateExecutionResult, publicInputs).toSimulatedTx();
}

/**
 * Summarise what ran, for provenance.
 *
 * Everything here is READ OFF the result rather than passed in beside it, so a summary cannot
 * disagree with the execution it describes. The one exception is `simulator`, which is a fact
 * about the caller and not about the result.
 */
export function summarisePrivateExecution(
  privateExecutionResult: PrivateExecutionResult,
  simulator: string,
): PrivateExecutionSummary {
  const entrypoint = privateExecutionResult.entrypoint;
  const callContext = entrypoint.publicInputs.callContext;
  return {
    contract: callContext.contractAddress.toString(),
    selector: callContext.functionSelector.toString(),
    nestedCalls: countNested(entrypoint),
    publicCalls: privateExecutionResult.publicFunctionCalldata.length,
    simulator,
  };
}

/** The nested private calls, counted by walking rather than by reading a field that may not exist. */
function countNested(entrypoint: { nestedExecutionResults: unknown[] }): number {
  let seen = 0;
  const pending: { nestedExecutionResults: unknown[] }[] = [entrypoint];
  while (pending.length > 0) {
    const next = pending.pop()!;
    for (const child of next.nestedExecutionResults) {
      seen += 1;
      pending.push(child as { nestedExecutionResults: unknown[] });
    }
  }
  return seen;
}

/**
 * Steps 3 and 4 together: the `Tx` and the provenance that says where it came from.
 *
 * The return type is narrowed to `LocallyExecutedTxProvenance`, so this function cannot produce a
 * locally-originated transaction that has forgotten to say what it executed. That is the type-level
 * half; `e2e_form_b_local_tx_roundtrip` section 4 is the executed half, because a type is
 * erased and this campaign has been caught by exactly that twice. `e2e_form_b_local_tx_roundtrip`
 * section 4 runs it, with M20's discriminant-only constructor beside it as the control that the
 * field is not simply there by default.
 */
export async function originateLocalTx(
  privateExecutionResult: PrivateExecutionResult,
  publicInputs: PrivateKernelTailCircuitPublicInputs,
  simulator: string,
  privateTrace?: PrivateTraceHandle,
): Promise<SubmittedTx<Tx> & { readonly provenance: LocallyExecutedTxProvenance }> {
  const tx = await txFromTail(privateExecutionResult, publicInputs);
  return locallyExecutedTx(tx, summarisePrivateExecution(privateExecutionResult, simulator), privateTrace);
}

/**
 * The public-only shortcut, in upstream's own shape.
 *
 * `wallet-sdk/src/base-wallet/utils.ts:118-132` at anchor `cpp` builds exactly this and calls it
 * "Minimal entrypoint structure — no real private execution, just public call requests". Eleven
 * positional arguments, in upstream's order; the twelfth is optional and upstream omits it too.
 *
 * THE CLASSES ARE IMPORTED HERE RATHER THAN INJECTED, and the first draft had that wrong. It took
 * a `ctors` object so the caller supplied `PrivateCallExecutionResult` and friends, which reads like
 * a seam and is a hazard: five `node_modules` roots in this repository each carry their own
 * `@aztec/stdlib`, and a value built from a different install serialises as a plain object that the
 * C++ side either rejects or — worse — decodes into something plausible. The hazard is documented
 * at `diffsim/src/public/public_tx_simulator/differential/encode_inputs.ts:22-42`, and the way to
 * not have it is to have exactly one install in the import graph.
 *
 * `firstNullifier` IS A PARAMETER AND NOT `Fr.random()`. That is where wallet-sdk puts it, and it
 * is the one thing here that is deliberately not copied: DD-4 makes this runtime deterministic, and
 * a transaction whose nonce generator is random cannot be compared byte for byte against anything.
 * `e2e_form_b_local_tx_roundtrip` section 3 depends on it directly — it compares the transaction
 * this builds against the one upstream's own `mockTx` built from the same tail, BY TRANSACTION
 * HASH, and a random nullifier makes that comparison impossible rather than merely noisy. The
 * milestone's `test_form_b_tx_matches_pxe_bytes` entry, which would compare against a transaction
 * PXE itself produced, is `pending` and DOES NOT EXIST — named here as absent rather than as
 * existing, because a comment that points at a check which is not there tells the next reader to
 * stop looking. The protocol requires only that it be a nullifier; it does not require randomness.
 */
export function publicOnlyPrivateExecution(
  circuitPublicInputs: PrivateCircuitPublicInputs,
  firstNullifier: Fr,
  publicFunctionCalldata: HashedValues[] = [],
): PrivateExecutionResult {
  const entrypoint = new PrivateCallExecutionResult(
    new Uint8Array(0), // acir
    new Uint8Array(0), // vk
    new Map(), // partialWitness
    circuitPublicInputs,
    [], // noteHashLeafIndexMap
    new Map(), // newNotes
    [], // noteHashNullifierCounterMap
    [], // returnValues
    [], // nestedExecutionResults
    [], // contractClassLogs
    [], // offchainEffects
  );
  return new PrivateExecutionResult(entrypoint, firstNullifier, publicFunctionCalldata);
}
