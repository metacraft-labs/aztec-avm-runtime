// wasm_avm_public_tx_simulator.ts — the seam where the two tracks become one runtime.
//
// WHAT IS OURS HERE IS THE TRANSPORT AND NOTHING ELSE, and that is worth stating precisely
// because the deliverable's shape depends on it.
//
// CORRECTED IN M18's REVIEW, TWICE — the enumeration below used to have six steps and a wrong
// first one, and "differs in one step out of six" was doing argumentative work it had not earned.
//
// Upstream's `CppPublicTxSimulator.simulate(tx)`
// (yarn-project/simulator/src/public/public_tx_simulator/cpp_public_tx_simulator.ts:56-127 at
// 3a68d68ac2) does, in order:
//
//   1. `computeTxHash(tx)` and a debug log
//   2. `merkleTree.getRevision()` — a PLAIN `WorldStateRevision`, no handle in it — and
//      `merkleTree.getIpcPath()`, a string passed beside the payload rather than inside it
//   3. `AvmTxHint.fromTx(tx, gasFees)`
//   4. `new AvmFastSimulationInputs(wsRevision, config, txHint, globals, protocolContracts)`
//   5. `new ContractProviderForCpp(contractsDB, globals, bindings)` — the callback object the
//      addon calls BACK into TypeScript through
//   6. `fastSimInputs.serializeWithMessagePack()`
//   7. `createCancellationToken()`
//   8. `avmSimulate(inputBuffer, contractProvider, wsdbIpcPath, log.level, undefined, token)`
//   9. await, and translate a failure into a `SimulationError`, with a cancellation branch and a
//      `finally` that clears the token
//  10. `deserializeFromMessagePack(resultBuffer)` and `PublicTxResult.fromPlainObject(...)`
//  11. log and return
//
// STEPS 3, 4, 6 AND 10 ARE UPSTREAM'S OWN CODE ON UPSTREAM'S OWN SCHEMA AND ARE REUSED VERBATIM
// — that is the reuse finding, and it is the durable part of the sentence this replaces. They
// are not in this method: they are the two callbacks in `avm_inputs.ts` that the constructor
// takes, so that a browser boundary (M28) can supply the same pair.
//
// The rest is not "one step". Step 8 is the transport and it is the one that CHANGED: the
// encoded blob goes to `avm.wasm` through @aztec-avm-runtime/node-host instead of to the NAPI
// addon. Steps 2 (partly), 5, 7 and 9 are ABSENT, each for a reason the RESIDENT shape gives:
// there is no IPC path because the world state is inside the module, no `contractProvider`
// because the contract DB is too, no cancellation token because a wasm instance runs to
// completion on the caller's stack (see `cancel` below), and no `SimulationError` translation
// because M17's host already distinguishes a trap from a revert and throws for the first.
// Step 1 is absent too and is a gap rather than a decision: this simulator does not compute a
// tx hash and does not log.
//
// AND THE ENCODER WAS ALREADY INSTALLED, WHICH THE CAMPAIGN HAD BEEN BEHAVING AS IF IT WAS NOT.
// `serializeWithMessagePack` is exported from `@aztec/stdlib/avm` in the published package, it
// is what upstream itself calls on `AvmFastSimulationInputs`, and `AvmTxHint.fromTx` builds the
// argument. RI-60 records it.
//
// THE ATTRIBUTION IS CORRECTED IN M18's REVIEW and is worth getting right, because the first
// version of this paragraph quoted NODE-HOST.md as saying "there is no TypeScript encoder for
// the AVM's input schemas" and called that M17's load-bearing constraint. NO REVISION OF
// NODE-HOST.md EVER CONTAINED THAT SENTENCE — `git log -S` over the whole repository finds no
// commit that added or removed it — and M17's own "Out of scope: Encoding" entry says something
// milder and TRUE: "this package decodes and never encodes… a JavaScript encoder of ours would
// be a second implementation of upstream's schemas."
//
// What is real is the BEHAVIOUR rather than a sentence. That milder rule was applied as though
// it forbade any TypeScript encoder anywhere: M12 grew a whole `reactorinputs` mode in C++ to
// emit per-program msgpack blobs as hex, and every host since has read its inputs from that file
// rather than encoding. Upstream's encoder would not have been a second implementation, so the
// rule never applied to it. That is the finding; a fabricated quotation is not needed to carry
// it and is removed.
//
// WHAT THE RESIDENT SHAPE CHANGES ABOUT STEP 5. M15 chose RESIDENT: the contract DB and the
// merkle DB live inside the module and the boundary carries a transaction in and a result out,
// against ~1,951 bytes per transaction instead of the ~187 KB the hinted arm carries. So there
// is no `contractProvider` callback object and no native world-state handle; there are two
// module-side handles, and — per M13 — they are driven by a `CheckpointCoordinator` rather than
// separately, because two stacks moved by hand desynchronise silently: the measured failure
// unwound the contract DB and left the trees at the injected level, with no call returning an
// error and no root malformed.
//
// `wsRevision` still has to be supplied, because it is a field of upstream's input schema, and
// what crosses is the plain `WorldStateRevision` upstream serialises — the same struct, because
// upstream's is already plain. See `residentWorldStateRevision` in avm_inputs.ts, whose comment
// carried the same mistake this one did.

import type { PublicTxResult } from '@aztec/stdlib/avm';
import type { GlobalVariables, Tx } from '@aztec/stdlib/tx';

import type { AvmConfiguration } from './simulator_selection.ts';
import { WASM_AVM, reachesNativeAddon } from './simulator_selection.ts';

/**
 * The narrow view of a `Reactor` this file needs. Structural, so that
 * @aztec-avm-runtime/node-host is a peer of this package rather than a dependency of it — the
 * browser (M28) supplies a different one, over `WebAssembly.instantiate` and no `node:wasi`, and
 * a nominal type here would have made that a rewrite instead of a second implementation.
 */
export interface AvmBoundary {
  /** Hand an encoded `AvmFastSimulationInputs` to the module against two resident DB handles. */
  simulate(input: Uint8Array, contractDb: number, merkleDb: number): { revertCode: number; result: unknown };
  /** How many times this instance has crossed the boundary. Differenced to count crossings. */
  readonly moduleCalls: number;
}

/** The resident DB pair, opened and closed by whoever owns the world state. */
export interface ResidentDbHandles {
  readonly contractDb: number;
  readonly merkleDb: number;
}

export interface WasmAvmPublicTxSimulatorOptions {
  /** Defaults to `WASM_AVM`. Any configuration that can reach the native addon is REFUSED. */
  readonly configuration?: AvmConfiguration;
}

/**
 * Thrown when a caller asks this simulator to run under a configuration that can reach the
 * native NAPI AVM. DD-9 as a runtime refusal, beside the export-surface property that
 * `test_public_processor_never_defaults_to_cpp` asserts: the two fail differently and both are
 * worth having, because an export surface says what is reachable by import and this says what is
 * reachable by argument.
 */
export class NativeAvmPathRefused extends Error {
  readonly kind = 'native-avm-path-refused' as const;
  readonly configurationName: string;
  constructor(configurationName: string) {
    super(
      `configuration '${configurationName}' can reach the native C++ AVM over NAPI, and this `
        + `runtime does not ship that path (DD-9). Use it from differential/ instead.`,
    );
    this.configurationName = configurationName;
  }
}

/**
 * Aztec's public transaction simulator interface, over the wasm AVM.
 *
 * The interface is upstream's, verbatim
 * (yarn-project/simulator/src/public/public_tx_simulator/public_tx_simulator_interface.ts):
 *
 *   export interface PublicTxSimulatorInterface {
 *     simulate(tx: Tx): Promise<PublicTxResult>;
 *     cancel?(waitTimeoutMs?: number): Promise<void>;
 *   }
 *
 * `cancel` is optional there and is deliberately NOT implemented here. Upstream's C++ path
 * implements it with a cancellation token the NAPI addon polls between opcodes; `avm.wasm` has
 * no such token and no second thread to signal from — a wasm instance runs to completion on the
 * caller's stack. Declaring a `cancel` that returned without cancelling would be worse than not
 * declaring one, because the interface's optionality is exactly how a caller finds out.
 */
export class WasmAvmPublicTxSimulator {
  readonly configuration: AvmConfiguration;

  // Field declarations and assignments rather than parameter properties: Node's type stripper
  // refuses the latter with ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX, and this package is run from its
  // .ts sources.
  private readonly boundary: AvmBoundary;
  private readonly dbs: ResidentDbHandles;
  private readonly globalVariables: GlobalVariables;
  private readonly encodeInputs: (tx: Tx, globals: GlobalVariables) => Uint8Array;
  private readonly decodeResult: (result: unknown) => PublicTxResult;

  constructor(
    boundary: AvmBoundary,
    dbs: ResidentDbHandles,
    globalVariables: GlobalVariables,
    encodeInputs: (tx: Tx, globals: GlobalVariables) => Uint8Array,
    decodeResult: (result: unknown) => PublicTxResult,
    options: WasmAvmPublicTxSimulatorOptions = {},
  ) {
    this.boundary = boundary;
    this.dbs = dbs;
    this.globalVariables = globalVariables;
    this.encodeInputs = encodeInputs;
    this.decodeResult = decodeResult;
    this.configuration = options.configuration ?? WASM_AVM;
    if (reachesNativeAddon(this.configuration)) {
      throw new NativeAvmPathRefused(this.configuration.name);
    }
  }

  /**
   * Simulate a transaction's public portion.
   *
   * A REVERT IS NOT AN ERROR and this is the one place that distinction has to survive the
   * boundary. `avm.wasm` answers status 0 with a `TxSimulationResult` whose `revertCode` is
   * non-zero; the host maps that to a `TxOutcome`, and it reaches upstream's `PublicTxResult`
   * with its `revertCode` intact. A trap, a host error and a poisoned instance are all thrown,
   * and none of them is a transaction that reverted.
   */
  async simulate(tx: Tx): Promise<PublicTxResult> {
    const input = this.encodeInputs(tx, this.globalVariables);
    const outcome = this.boundary.simulate(input, this.dbs.contractDb, this.dbs.merkleDb);
    return await Promise.resolve(this.decodeResult(outcome.result));
  }

  /** Boundary crossings since construction. Differenced by callers that assert a budget. */
  get moduleCalls(): number {
    return this.boundary.moduleCalls;
  }
}
