// M35 — private execution: one ACIR circuit, upstream's simulator, upstream's oracle wire, our handler.
//
// WHAT RUNS HERE. `WASMSimulator.executeUserCircuit` (vendored, RI-64, V10) drives
// `@aztec/noir-acvm_js` — the ACVM — over a function's ACIR bytecode, calling back into the
// `ACIRCallback` that `buildACIRCallback` (vendored, RI-97, V11) builds from `ORACLE_REGISTRY` and
// the handler in `private_oracles.ts`. Every byte of the executor and every byte of the wire format
// is upstream's; what is ours is the handler and the frame this file assembles around it.
//
// WHAT THE FRAME IS. A private function's parameters are `PrivateContextInputs` followed by the
// function's own declared arguments, laid into the witness map from index 0 by upstream's
// `toACVMWitness`. That is the whole input: **the witness must carry the parameters and nothing
// else.** Padding it with zeros beyond the parameters FORCES witnesses the solver has to compute and
// the ACVM reports `Cannot satisfy constraint` — which reads as a defect in the circuit and is a
// defect in the harness. That cost an hour, so it is written down here rather than remembered.
//
// NESTED CALLS. `aztec_prv_callPrivateFunction` is served when — and only when — the request carries
// a `contracts` directory. With one, a transaction is a TREE of frames: this function recurses into
// itself through the oracle, every frame shares the transaction's execution cache, note cache,
// capsule store, transient arrays, revertible-phase state and public-calldata accumulator, and each
// frame keeps its own oracle ledger, its own tape and its own ephemeral-array service. Without one,
// the oracle refuses by name and this executes ONE frame — which is what every caller written before
// tier 4 gets, by construction rather than by remembering.

import { Fr } from '@aztec/foundation/curves/bn254';
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { FunctionSelector, countArgumentsSize } from '@aztec/stdlib/abi';
import { PrivateCircuitPublicInputs, PrivateContextInputs } from '@aztec/stdlib/kernel';
import { BlockHeader, CallContext, TxContext } from '@aztec/stdlib/tx';
import { PRIVATE_CIRCUIT_PUBLIC_INPUTS_LENGTH, PRIVATE_CONTEXT_INPUTS_LENGTH } from '@aztec/constants';

import initACVM from '@aztec/noir-acvm_js';
import initNoircAbi from '@aztec/noir-noirc_abi';

import { WASMSimulator } from '../vendor/simulator/private/acvm_wasm.ts';
import { toACVMWitness } from '../vendor/simulator/private/acvm/serialize.ts';
import { buildACIRCallback } from '../vendor/pxe/contract_function_simulator/oracle/acir_callback.ts';
import {
  type HeldAccountKeys,
  type HeldContractArtifact,
  type HeldContractInstance,
  type NestedFrameRequest,
  type NestedFrameResult,
  type NoteDiscoverySource,
  type OracleCall,
  type PrivateFrameState,
  ORACLE_ENVIRONMENT_VERSION,
  assertHeldAccountKeysAreSelfConsistent,
  assertHeldInstancesAreSelfConsistent,
  createPrivateFrameState,
  createPrivateOracleHandler,
} from './private_oracles.ts';

/**
 * THE TWO WASM MODULES PRIVATE EXECUTION NEEDS, AND WHY THE PAGE HAS TO NAME THEM.
 *
 * `WASMSimulator.init()` — vendored, unedited — does `wasmInitPromise ??= Promise.all([initAbi(),
 * initACVM()])` with NO argument, and wasm-bindgen's argument-less init resolves its module as
 * `new URL('acvm_js_bg.wasm', import.meta.url)`. After esbuild that `import.meta.url` is a chunk
 * under `dist/chunks/`, so the fetch is for a file that has never been there and the whole execution
 * fails with `TypeError: fetch failed` — measured, in Node, over the built bundle, before anything
 * asserted on it.
 *
 * wasm-bindgen's `__wbg_init` opens with `if (wasm !== undefined) return wasm;`, so **pre-initialising
 * with an explicit URL makes the vendored file's argument-less call a no-op**. That is what this
 * does, and it is why the vendored copy needs no edit: the two modules are the same module instances
 * the simulator will reach, because esbuild puts our import and its import in one chunk.
 *
 * IT IS ALSO WHERE THE COST IS DECLARED. `acvm_js_bg.wasm` is 3,601,516 bytes and
 * `noirc_abi_wasm_bg.wasm` is 789,053 — 4.4 MB, fetched by URL at the moment a page asks for a
 * private execution and NEVER before. A page that does no private execution fetches neither, which
 * is DD-11's own rule and is asserted on the browser's network log rather than argued from a config.
 */
export type PrivateExecutionAsset =
  | string
  | URL
  | Response
  | WebAssembly.Module
  | ArrayBuffer
  | ArrayBufferView;

export interface PrivateExecutionAssets {
  /**
   * `@aztec/noir-acvm_js`'s `web/acvm_js_bg.wasm`: a URL a page fetches, or the module itself.
   *
   * The wider type is not laxness — it is exactly what wasm-bindgen's own `__wbg_init` accepts, and
   * it is what lets a Node process feed the bytes off disk. Node's `fetch` refuses `file://` with
   * `not implemented... yet...`, so a URL-only signature would make this surface browser-only and put
   * every check that wants to read it behind a headless browser. Measured, on the built bundle.
   */
  readonly acvmWasmUrl: PrivateExecutionAsset;
  /** `@aztec/noir-noirc_abi`'s `web/noirc_abi_wasm_bg.wasm`, on the same terms. */
  readonly noircAbiWasmUrl: PrivateExecutionAsset;
}

let acvmReady: Promise<unknown> | undefined;
let acvmAssets: PrivateExecutionAssets | undefined;

/** Raised when a private execution is asked for before the ACVM has been pointed at its modules. */
export class PrivateExecutionNotInitialised extends Error {
  constructor() {
    super(
      'PrivateExecutionNotInitialised: call initPrivateExecution({acvmWasmUrl, noircAbiWasmUrl}) before ' +
        'executePrivateFunction. There is deliberately no default URL: wasm-bindgen would resolve one ' +
        'against the bundle chunk it was inlined into, fetch a path that has never existed, and fail ' +
        'four layers down with `fetch failed` instead of here with a name.',
    );
    this.name = 'PrivateExecutionNotInitialised';
  }
}

/** Point the ACVM and the ABI decoder at their wasm modules. Idempotent; the first call wins. */
export async function initPrivateExecution(assets: PrivateExecutionAssets): Promise<void> {
  acvmAssets ??= assets;
  acvmReady ??= Promise.all([
    initNoircAbi(assets.noircAbiWasmUrl as never),
    initACVM(assets.acvmWasmUrl as never),
  ]);
  await acvmReady;
}

/**
 * How the first `initPrivateExecution` was pointed at its modules, as a pair of STRINGS a check can
 * read back. A `Response` or a `WebAssembly.Module` renders as its constructor name rather than as
 * itself, so the answer says which KIND of asset was supplied without pretending to be a URL.
 */
export function privateExecutionAssets(): { acvm: string; noircAbi: string } | undefined {
  if (!acvmAssets) {
    return undefined;
  }
  const describe = (a: PrivateExecutionAsset) =>
    typeof a === 'string' ? a : a instanceof URL ? a.href : `[${(a as object)?.constructor?.name ?? typeof a}]`;
  return { acvm: describe(acvmAssets.acvmWasmUrl), noircAbi: describe(acvmAssets.noircAbiWasmUrl) };
}

/**
 * A field this module will normalise. Accepting the wire spelling as well as the class is not
 * laxness — it is what makes the entry point callable from a page, from a `Runtime.evaluate` string
 * and from a second module instance without the caller having to own the same `Fr` CONSTRUCTOR this
 * bundle does. Measured: a probe that passed an `Fr` built from `orchestration/node_modules` into the
 * BUNDLE's `TxContext.empty` got `Type 'object' with value '0x…7a69' passed to BaseField ctor`,
 * because `instanceof` is per-realm. A caller that hands over a decimal string or a hex string cannot
 * hit that, and the normalisation is one function with its own refusal.
 */
export type FieldLike = Fr | bigint | number | string;
/** An address in any of the spellings a caller might hold one in. */
export type AddressLike = AztecAddress | Fr | bigint | number | string;

/** Normalise to THIS bundle's `Fr`, refusing anything that is not a field. */
export function toFieldValue(value: FieldLike, what: string): Fr {
  if (typeof value === 'bigint' || typeof value === 'number') {
    return new Fr(BigInt(value));
  }
  if (typeof value === 'string') {
    return value.startsWith('0x') ? Fr.fromString(value) : new Fr(BigInt(value));
  }
  const asString = (value as { toString?: () => string })?.toString?.();
  if (typeof asString === 'string' && /^0x[0-9a-fA-F]+$/.test(asString)) {
    return Fr.fromString(asString);
  }
  throw new Error(`${what}: expected a field, got ${typeof value} ${String(value)}`);
}

/** Normalise to THIS bundle's `AztecAddress`. */
export function toAddressValue(value: AddressLike, what: string): AztecAddress {
  return AztecAddress.fromField(toFieldValue(value as FieldLike, what));
}

/** What the caller must supply. Nothing is defaulted from the ambient environment. */
export interface PrivateExecutionRequest {
  /** The already-parsed contract artifact JSON, as `token_transfer.ts` takes it, for the same reason. */
  readonly artifact: unknown;
  /** The function to execute, by name. Its `custom_attributes` must contain `abi_private`. */
  readonly functionName: string;
  /** The contract this frame belongs to. */
  readonly contractAddress: AddressLike;
  /** The caller. */
  readonly msgSender: AddressLike;
  /** The chain's own id and version, so the frame is this chain's rather than a fabricated one. */
  readonly chainId: FieldLike;
  readonly version: FieldLike;
  /** The function's declared arguments, already flattened to fields. */
  readonly args: readonly FieldLike[];
  /** The entropy seed — an argument, never generated. See `private_oracles.ts`. */
  readonly entropySeed: FieldLike;
  /** The anchor block header. `BlockHeader.empty()` when the caller has no chain to read one from. */
  readonly anchorBlockHeader?: BlockHeader;
  readonly startSideEffectCounter?: number;
  readonly isStaticCall?: boolean;
  readonly writeLine?: (line: string) => void;
  /**
   * The contract instances the wallet holds, for tier 2's first rung. Omitted means the wallet
   * holds none and every `getContractInstance` refuses — which is what M35 shipped and is still
   * the default, so a caller that supplies nothing gets the old behaviour by construction rather
   * than by remembering to.
   */
  readonly contractInstances?: readonly HeldContractInstance[];
  /**
   * The accounts whose keys the wallet holds, for tier 2's second rung. Omitted means it holds
   * none and every address answers "not registered" — which is what M35 shipped.
   */
  readonly accountKeys?: readonly HeldAccountKeys[];
  /**
   * M36's note-discovery source. **Absent by default**, and its absence is nine named refusals
   * rather than nine empty answers — see `private_oracles.ts`.
   */
  readonly discovery?: NoteDiscoverySource;
  /**
   * Record every oracle call's WIRE VALUES — the fields the ACVM handed in and the fields the
   * handler handed back — into `PrivateExecutionReport.tape`.
   *
   * **Why the ledger is not enough, and why this is not the ledger with more fields.**
   * `OracleCall.detail` is a human sentence written by the handler about what it did
   * (`counter=1 revertible=false`). The tape is what crossed the wire. A consumer that has to
   * REPRODUCE this execution — M38's Noir tracer, which drives the same ACIR through a
   * synchronous Rust foreign-call executor and cannot call a TypeScript handler at all — needs the
   * second and would have to interpret the first. Deriving `[0]` from the words
   * `revertible=false` is a guess that happens to be right, and this repository's rule is that a
   * value nobody measured is a value nobody may use.
   *
   * Off by default: the tape is the raw field arrays and is much larger than the ledger.
   */
  readonly recordTape?: boolean;
  /**
   * TIER 4's source: the contracts this wallet can EXECUTE, by address.
   *
   * **Absent by default, and its absence is one named refusal rather than a frame this runtime
   * invented** — the same shape, and for the same reason, as `discovery`. Supplying it is what
   * makes `aztec_prv_callPrivateFunction` served: a handler with no artifact directory cannot find
   * a callee's bytecode, and one that answered anyway would have to fabricate the child's result.
   *
   * It is a DIFFERENT directory from `contractInstances`. An instance is the six-field preimage a
   * circuit constrains against an address and carries no bytecode; registering an address for the
   * instance oracle does not make it callable.
   */
  readonly contracts?: readonly HeldContractArtifact[];
  /** The bound on nested-call depth. `DEFAULT_NESTED_CALL_MAX_DEPTH` when omitted. */
  readonly nestedMaxDepth?: number;
  /**
   * Whether to regroup `aztec_prv_callPrivateFunction`'s return for a contract compiled against an
   * older minor of this major. `'auto'` (the default) applies it on that condition and on no other;
   * `'off'` disables it entirely, which is what makes the gap it closes a measurement rather than a
   * paragraph. See `wireCompatCallback`.
   */
  readonly nestedCallWireCompat?: 'auto' | 'off';
  /**
   * The TRANSACTION's shared state and this frame's depth. **Set by the nested-call oracle and by
   * nothing else** — a caller that supplies them is claiming to be a frame inside a transaction
   * somebody else started, which is a claim only that oracle can make truthfully.
   */
  readonly shared?: PrivateFrameState;
  readonly depth?: number;
}

/**
 * One oracle call as it crossed the ACIR foreign-call wire.
 *
 * `inputs` and `outputs` are the ACVM's own `ForeignCallInput` / `ForeignCallOutput` shapes,
 * normalised to arrays of hex strings so a non-JavaScript consumer can read them: a single field
 * becomes a one-element array, so every entry has the same shape and a reader never has to ask
 * which it is holding.
 */
export interface OracleTapeEntry {
  readonly seq: number;
  readonly oracle: string;
  readonly inputs: readonly (readonly string[])[];
  readonly outputs: readonly (readonly string[])[];
  /**
   * Whether each input slot crossed the wire as a SINGLE field or as an ARRAY of fields.
   *
   * ===========================================================================================
   * A ONE-ELEMENT ARRAY AND A SINGLE FIELD ARE THE SAME THING ON A NORMALISED TAPE, AND THEY ARE
   * NOT THE SAME THING TO THE ACVM
   * ===========================================================================================
   *
   * `ForeignCallParam` is `Single(f) | Array(fs)`, and Brillig's destination for an array return is
   * a HEAP ARRAY of a declared width. A replaying executor handed a normalised slot of length one
   * has to choose, and choosing by length is right for every SINGLE and wrong for every
   * one-element ARRAY.
   *
   * **Measured, and it cost a real halt.** `aztec_prv_getHashPreimage` returns `[Field; N]` — the
   * oracle behind `execution_cache::load` — and for a function returning one `Field` that is an
   * array of ONE. Replaying it as a `Single` made `Parent.entry_point` fail inside Brillig with a
   * bare `Failed assertion` (an out-of-bounds read of a one-slot array that had received a scalar),
   * 167 opcodes into 903, five of its seven recorded oracle calls in. Every oracle M38's four arms
   * exercised happened to be a genuine `Single` or a multi-field array, so the guess was right
   * every time it had been tried.
   *
   * The kinds are recorded rather than inferred for exactly the reason the tape exists at all:
   * *a value nobody measured is a value nobody may use.*
   */
  readonly inputKinds: readonly ('single' | 'array')[];
  /** The same, for the fields the handler handed back. */
  readonly outputKinds: readonly ('single' | 'array')[];
}

export interface PrivateExecutionReport {
  readonly contractName: string;
  readonly functionName: string;
  readonly functionType: string;
  readonly selector: string;
  /** Decoded ACIR bytecode size, so "it executed" is separable from "it was a stub". */
  readonly bytecodeBytes: number;
  readonly contextInputFields: number;
  readonly argFields: number;
  readonly initialWitnessSize: number;
  /** Present only when the circuit solved. */
  readonly solvedWitnessSize?: number;
  readonly returnWitnessSize?: number;
  /**
   * The frame's own declared return values, ascending by witness index. Present when it solved.
   *
   * **This is what makes a nested call's RESULT checkable rather than only its shape.**
   * `Parent.entry_point` returns whatever `Child.value` returned, and `Child.value` is
   * `input + chain_id + version` — so a child that was handed the wrong chain fields, or whose
   * return preimage came back from the wrong frame, produces a different field here while every
   * count in the report stays identical. A step count and an oracle ledger cannot see that.
   */
  readonly returnFields?: readonly string[];
  /** The oracle version the BYTECODE declared, against the environment's own. */
  readonly contractOracleVersion?: { major: number; minor: number };
  readonly environmentOracleVersion: { major: number; minor: number };
  /** Every oracle the bytecode asked for, in order, served and refused alike. */
  readonly oracleCalls: readonly OracleCall[];
  /**
   * The same calls as WIRE VALUES, present only when the request asked for them. See
   * `PrivateExecutionRequest.recordTape` for why this is not `oracleCalls` with more fields.
   */
  readonly tape?: readonly OracleTapeEntry[];
  /** `[witnessIndex, hexField]` pairs, ascending by index. Present with `tape`. */
  readonly initialWitnessEntries?: readonly (readonly [number, string])[];
  /** The solved witness, same shape. Present with `tape` when the circuit solved. */
  readonly solvedWitnessEntries?: readonly (readonly [number, string])[];
  readonly oraclesServed: number;
  /** Calls to oracles this wallet does not serve at all — `OracleUnimplemented`. */
  readonly oraclesRefused: number;
  /** Calls to a SERVED oracle that had no answer for that argument — `ContractInstanceNotHeld`. */
  readonly oraclesUnavailable?: number;
  /** Whether a discovery source was attached — so a report says which partition was in force. */
  readonly hasDiscovery: boolean;
  /** How many oracles that partition serves. Read from the handle, never counted at the call site. */
  readonly servedSetSize: number;
  /** The oracle that stopped the execution, if one did. */
  readonly stoppedAtOracle: string | null;
  readonly error?: string;
  readonly errorName?: string;
  /** The whole `cause` chain, outermost first. The ACVM's wrapper is never the useful one. */
  readonly errorChain?: readonly string[];
  readonly outcome: 'executed' | 'refused' | 'failed';
  /** 0 for the transaction's entry frame; one more per nesting level. */
  readonly depth: number;
  /** Whether a nested-call source was in force, so a report says which partition it ran under. */
  readonly hasNested: boolean;
  /**
   * How many times the call-private wire regrouping fired in THIS frame.
   *
   * Reported rather than inferred, because "the transaction completed" is equally true of a run in
   * which the shim was never needed. A zero here on the `deletion_era` line would mean the
   * predicate stopped firing, and a non-zero on the anchor line would mean it fires where it must
   * not.
   */
  readonly wireCompatApplied: number;
  /**
   * The frames THIS frame called, in order, each a whole report of its own.
   *
   * **A TREE AND NOT A FLATTENED LIST, because the tape is per frame and so is the circuit.** The
   * Noir tracer steps one circuit at a time; a transaction of N frames is N traces, and which tape
   * belongs to which circuit is exactly what a flattened list throws away. Upstream keeps the same
   * shape (`nestedExecutionResults`) for the same reason one layer up, where the private kernel
   * consumes it.
   */
  readonly nested: readonly PrivateExecutionReport[];
  readonly effects: ReturnType<ReturnType<typeof createPrivateOracleHandler>['effects']>;
  /** A handful of the circuit's own public inputs, when it solved. */
  readonly publicInputs?: {
    readonly contractAddress: string;
    readonly argsHash: string;
    readonly returnsHash: string;
    readonly startSideEffectCounter: number;
    readonly endSideEffectCounter: number;
    /**
     * M36 — THE SIDE EFFECTS THE CIRCUIT ITSELF CLAIMED, so a note the wallet later discovers came
     * out of an execution rather than out of a handler's bookkeeping.
     *
     * `notifyCreatedNote` is the PXE's own record and `effects.createdNotes` carries it; these are
     * the CIRCUIT's public inputs, which is a different producer — and `mint_to_private` is measured
     * to emit its note through these and to call `notifyCreatedNote` not at all. A note database fed
     * from the handler alone would therefore hold nothing for the one contract that creates one.
     */
    readonly noteHashes: readonly string[];
    readonly nullifiers: readonly string[];
    readonly privateLogs: readonly { readonly fields: readonly string[]; readonly length: number }[];
    /**
     * The two remaining claimed lengths upstream's `#checkValidStaticCall` reads, as COUNTS.
     *
     * They are counts and not contents deliberately. The static-call rule is a count — *"a static
     * call cannot update the state, emit L2->L1 messages or generate logs"* — and rendering
     * `CountedL2ToL1Message` or `CountedLogHash` would be the `String(entry)` mistake this file
     * already records for `NoteHash`, whose `toString()` is `value=0x… counter=1`. A count needs no
     * field accessor and cannot render a struct as a field.
     */
    readonly l2ToL1MsgCount: number;
    readonly contractClassLogHashCount: number;
  };
}

/** The artifact's function record, found by name, with the two-place lookup upstream uses. */
function findFunction(artifact: unknown, name: string) {
  const doc = artifact as {
    name?: string;
    functions?: { name: string; bytecode: string; custom_attributes?: string[]; abi?: unknown }[];
  };
  const fn = (doc.functions ?? []).find(f => f.name === name);
  if (!fn) {
    throw new Error(
      `the artifact '${doc.name ?? '?'}' has no function '${name}'; it declares ` +
        `[${(doc.functions ?? []).map(f => f.name).join(', ')}]`,
    );
  }
  return fn;
}

/**
 * The selector a function of a RAW artifact derives, by upstream's own
 * `FunctionSelector.fromNameAndParameters` over the ABI the artifact declares.
 *
 * **It is exported because a nested call has two consumers of this one value and they must not
 * derive it twice.** The caller of `Parent.entry_point` passes the callee's selector IN as an
 * argument field; the nested-call oracle then looks the callee up BY that selector. Two
 * derivations of one value is how a lookup silently misses — and the campaign's own rule is that
 * a number a check needs which also exists in the subject is taken FROM the subject.
 */
export async function privateFunctionSelector(artifact: unknown, functionName: string): Promise<FunctionSelector> {
  const fn = findFunction(artifact, functionName);
  return FunctionSelector.fromNameAndParameters({
    name: functionName,
    parameters: ((fn.abi as { parameters?: unknown[] } | undefined)?.parameters ?? []) as never,
  });
}

/** `abi_private` / `abi_public` / `abi_utility` — read from the artifact, never assumed. */
export function functionTypeOf(fn: { custom_attributes?: string[] }): string {
  const attrs = fn.custom_attributes ?? [];
  for (const known of ['abi_private', 'abi_public', 'abi_utility']) {
    if (attrs.includes(known)) {
      return known;
    }
  }
  return attrs.length > 0 ? attrs.join(',') : 'none';
}

/**
 * Upstream's `extractPrivateCircuitPublicInputs`, in fourteen lines, and it is one of exactly two
 * things in this milestone that are re-expressed rather than vendored.
 *
 * The reason is a type edge, not a preference: upstream's copy lives in
 * `pxe/src/contract_function_simulator/oracle/private_execution.ts`, whose other import is
 * `import type { PrivateExecutionOracle } from './private_execution_oracle.js'` — the 812-line
 * handler M35 REPLACES. Vendoring the file to get this function would vendor a type reference to the
 * class the milestone exists not to use, and `_m35_closure.py`'s `privhandler` group prices that at
 * 502 files. The layout it depends on is upstream's and is asserted rather than assumed: the return
 * data begins immediately after the parameters and is `PRIVATE_CIRCUIT_PUBLIC_INPUTS_LENGTH` fields
 * long, and a missing witness in that range is an error rather than a zero.
 */
function extractPublicInputs(parametersSize: number, partialWitness: Map<number, string>) {
  const returnData: Fr[] = [];
  for (let i = parametersSize; i < parametersSize + PRIVATE_CIRCUIT_PUBLIC_INPUTS_LENGTH; i++) {
    const field = partialWitness.get(i);
    if (field === undefined) {
      throw new Error(`missing return value at witness index ${i}`);
    }
    returnData.push(Fr.fromString(field));
  }
  return PrivateCircuitPublicInputs.fromFields(returnData);
}

/**
 * The entries a `ClaimedLengthArray` says are real.
 *
 * A CIRCUIT'S SIDE-EFFECT ARRAYS ARE FIXED-WIDTH AND MOSTLY EMPTY. `MAX_NOTE_HASHES_PER_CALL` is
 * sixteen and a call that creates one note fills one slot; the other fifteen are zero. Reading the
 * whole array would put fifteen zero note hashes into the note database, and a zero note hash is a
 * value that hashes and stores exactly like a real one. The claimed length is upstream's own answer
 * to that, and it is read rather than inferred from a zero test — a legitimately zero field would be
 * dropped by the inference and nothing would say so.
 */
function claimed(a: unknown): unknown[] {
  const cla = a as { array?: unknown[]; claimedLength?: number };
  if (!Array.isArray(cla?.array) || typeof cla?.claimedLength !== 'number') {
    throw new Error(
      `expected a ClaimedLengthArray with an \`array\` and a \`claimedLength\`, got ` +
        `${JSON.stringify(Object.keys((a as object) ?? {}))}`,
    );
  }
  return cla.array.slice(0, cla.claimedLength);
}

/** The `value` field of a `NoteHash` / `Nullifier`, refusing by name rather than stringifying. */
function fieldOf(entry: unknown, what: string): string {
  const value = (entry as { value?: { toString(): string } })?.value;
  if (value === undefined) {
    throw new Error(
      `a ${what} in the circuit's public inputs has no \`value\` field; it carries ` +
        `${JSON.stringify(Object.keys((entry as object) ?? {}))}`,
    );
  }
  return value.toString();
}

/**
 * Wrap every entry of upstream's `ACIRCallback` so the fields crossing it are recorded.
 *
 * The wrapper is built from the callback's OWN keys rather than from a list of oracle names: the
 * callback is what the ACVM dispatches on, so an oracle upstream adds is taped on the day the
 * registry gains it, and an oracle this table did not know about cannot be silently untaped.
 *
 * A throwing entry — every refusal is one — records the call it was making with NO outputs and
 * rethrows unchanged. A tape whose last entry has an empty `outputs` is a call that was made and
 * not answered, which is exactly the shape a replaying consumer must not mistake for an answer of
 * length zero; `PrivateExecutionReport.stoppedAtOracle` names it, and `oracleCalls` says whether it
 * was refused or unavailable.
 */
function recordingCallback(
  callback: Record<string, (...inputs: string[][]) => Promise<string[][]>>,
  tape: OracleTapeEntry[],
): Record<string, (...inputs: string[][]) => Promise<string[][]>> {
  const wrapped: Record<string, (...inputs: string[][]) => Promise<string[][]>> = {};
  for (const [oracle, fn] of Object.entries(callback)) {
    if (typeof fn !== 'function') {
      // Not every property of the callback object is an oracle — `assertHandlerSupportsScope`'s
      // markers are not — and copying a non-function through unchanged is the only safe thing.
      wrapped[oracle] = fn;
      continue;
    }
    wrapped[oracle] = async (...inputs: string[][]) => {
      const seq = tape.length;
      const raw = inputs as unknown as (string | string[])[];
      const entry = {
        seq,
        oracle,
        inputs: raw.map(slots),
        inputKinds: raw.map(slotKind),
        outputs: [] as string[][],
        outputKinds: [] as ('single' | 'array')[],
      };
      tape.push(entry);
      const outputs = await fn(...inputs);
      const rawOut = (outputs ?? []) as unknown as (string | string[])[];
      entry.outputs = rawOut.map(slots);
      entry.outputKinds = rawOut.map(slotKind);
      return outputs;
    };
  }
  return wrapped;
}

/**
 * Normalise one wire slot to an array of fields.
 *
 * **A slot is a field OR an array of fields, and JavaScript will happily destructure the first
 * one into characters.** The ACVM's `ForeignCallParam` is `ACVMField | ACVMField[]`, and
 * `serializeReturn` produces a mixture: `isExecutionInRevertiblePhase` returns a single field and
 * `getContractInstance` returns twelve. The first draft of this function was `[...slot]`, which
 * turned the single field `0x0000…0000` into sixty-six one-character strings — a tape that is not
 * merely wrong but wrong in a shape a reader skims past, because it is still an array of strings
 * of the right total length. Found by reading the first tape rather than by reasoning about it.
 */
function slots(slot: string | string[]): string[] {
  return typeof slot === 'string' ? [slot] : [...slot];
}

/**
 * Which of the ACVM's two slot shapes this one is — the half `slots` normalises away.
 *
 * `slots` exists so a reader never has to ask whether it is holding a field or an array; this
 * exists so a REPLAYER does not have to guess. They are two answers to the same normalisation and
 * both are needed: without the first the tape is not machine-readable, without the second a
 * one-element array replays as a scalar. See `OracleTapeEntry.inputKinds`.
 */
function slotKind(slot: string | string[]): 'single' | 'array' {
  return typeof slot === 'string' ? 'single' : 'array';
}

/**
 * THE ONE WIRE REGROUPING THIS RUNTIME CARRIES, AND IT IS A SHIM FOR A GAP M37 OWNS.
 *
 * ===========================================================================================
 * WHAT MOVED, READ FROM SOURCE AT BOTH ENDS
 * ===========================================================================================
 *
 * `aztec_prv_callPrivateFunction` hands back an end-side-effect counter and a returns hash. The
 * two FIELD VALUES are the same on both nightly lines this tree has installed; how many
 * destination slots they arrive in is not:
 *
 * | line | `call_private_function_oracle`'s declared return | slots |
 * |---|---|---|
 * | `deletion_era` (`upstream/tsavm/.../oracle/call_private_function.nr`) | `-> [Field; 2]` | **1** |
 * | the `cpp` anchor (`aztec-packages/.../labs/aztec-nr/.../call_private_function.nr`) | `-> (u32, Field)` | **2** |
 *
 * The vendored registry is the anchor's — `CALL_PRIVATE_RESULT = STRUCT([{endSideEffectCounter:
 * FIELD}, {returnsHash: FIELD}])` — so `serializeReturn` produces two slots, and a `deletion_era`
 * artifact halts with `Assertion failed: 2 output values were provided as a foreign call result for
 * 1 destination slots`.
 *
 * **`assertCompatibleOracleVersion` PASSES over that pair.** The artifact declares 30.0, this
 * environment implements 30.8; same MAJOR and environment minor >= contract minor, which is
 * upstream's own rule for "not breaking". `PRIVATE-EXECUTION.md` §3b measured the identical shape
 * on `aztec_utl_getPublicKeysAndPartialAddress` and closed by predicting that any refused oracle
 * whose shape had moved carried the same latent gap. This is that prediction met on the next one
 * served.
 *
 * ===========================================================================================
 * UPSTREAM HAS A MECHANISM FOR EXACTLY THIS, AND IT CANNOT EXPRESS THIS CASE
 * ===========================================================================================
 *
 * **This shim is not an invention.** `legacy_oracle_registry.ts` — vendored here, RI-97 — exists
 * for precisely this problem, and says so in its own words: *"Wire shapes that already-deployed
 * contracts still call by their original oracle name … so versioning an oracle's wire (e.g. adding
 * return fields) stops being a breaking change."* `buildACIRCallback` installs those entries beside
 * the live ones and each *"reuses the current handler of its `modernOracle` and reshapes the wire
 * (params and/or return) back to what the old bytecode expects"* — which is, to the word, what
 * happens below.
 *
 * **But every entry in it is keyed by a RETIRED NAME, and there are three:**
 * `aztec_utl_getL1ToL2MembershipWitness`, `aztec_utl_getLogsByTag` and
 * `aztec_utl_getPendingTaggedLogs`, each superseded by a `…V2`. Upstream's own rule for changing a
 * wire is therefore to change the NAME and serve the old name from that table.
 *
 * `aztec_prv_callPrivateFunction` changed shape and **kept its name**, so no legacy entry can be
 * written for it: the key would collide with the live oracle, and `buildACIRCallback` throws on
 * exactly that (*"Legacy oracle X collides with a live oracle of the same name"*). The same is true
 * of `aztec_utl_getPublicKeysAndPartialAddress`, which `PRIVATE-EXECUTION.md` §3b measured. **So
 * there are two same-name wire changes and upstream's compatibility table can hold neither.** That
 * is the finding; this function is what a legacy entry would have been, keyed on the contract's
 * declared VERSION because the name it would otherwise key on was never retired.
 *
 * ===========================================================================================
 * WHY NOT A CORPUS CHANGE, AND WHY IT IS THIS NARROW
 * ===========================================================================================
 *
 * The corpus change is the durable fix and it is M37's: running the anchor-line artifacts needs a
 * 38-field `PrivateContextInputs` and the installed `@aztec/constants` declares **37**, so it is a
 * whole-runtime reconciliation rather than an artifact swap. §3b assigned exactly that pairing to
 * M37 and this does not take it.
 *
 * What this does is regroup two field values that are already correct, for ONE oracle, and only
 * when the executing bytecode has said it was compiled against an older minor of the same major.
 * It fabricates nothing: both fields come from a child frame that really executed. The wider class
 * is `PRIVATE-EXECUTION.md` §2's anchor-versus-pin gap, which cost three shims in
 * `browser/src/shims/` — an installed pin that is not the anchor the wire was read from.
 *
 * **It is measured in both directions on every run.** With it off, the same transaction halts at
 * the slot count and names 2-against-1; with it on, the transaction completes. A shim nobody has
 * seen the absence of is a shim whose necessity is a paragraph.
 *
 * **AND THE PREDICATE IS THE CONTRACT'S OWN DECLARATION, NOT A FILE PATH OR A ROOT NAME.** It reads
 * the version the BYTECODE passed to `assertCompatibleOracleVersion` — call zero of every
 * `#[aztec]` contract — through the handler that recorded it. An artifact compiled against this
 * environment's own minor is untouched, which is the case that must not be shimmed.
 */
/**
 * The oracle whose wire this shim regroups, spelled once.
 *
 * A `const` rather than a literal at the use site because the same name has to appear in the lookup
 * and in the diagnostic, and the defect this shim's own first draft shipped was a key that did not
 * match the callback's.
 */
const CALL_PRIVATE_ORACLE = 'aztec_prv_callPrivateFunction';

/**
 * The names in upstream's own legacy-wire table, sorted — read from the table rather than listed.
 *
 * Exported so a check can assert that the two same-name wire changes this runtime has MEASURED are
 * NOT among them, which is the whole reason this shim exists instead of a legacy entry.
 */
export function legacyWireOracleNames(registry: Record<string, unknown>): readonly string[] {
  return Object.freeze(Object.keys(registry).sort());
}

function regroupedCallPrivateResult(outputs: unknown): string[][] {
  const slotted = ((outputs ?? []) as (string | string[])[]).map(slots);
  const fields = slotted.flat();
  if (slotted.length !== 2 || fields.length !== 2) {
    // A REFUSAL RATHER THAN A BEST-EFFORT REGROUPING. If the anchor's mapping ever stops producing
    // exactly two one-field slots, this shim's whole premise is gone and flattening whatever
    // arrived would hand the circuit a plausible answer of the wrong shape — the one failure mode
    // this runtime refuses. The count that surprised it is in the message.
    throw new Error(
      `the call-private wire shim expected two one-field slots from the anchor's ` +
        `CALL_PRIVATE_RESULT and got ${slotted.length} slot(s) holding ${fields.length} field(s). ` +
        `The regrouping this shim performs is only correct for the pair it was measured on.`,
    );
  }
  return [fields];
}

/**
 * Wraps the ACIR callback so `aztec_prv_callPrivateFunction`'s return is regrouped for a contract
 * compiled against an older minor of this major. Every other oracle is passed through unchanged,
 * and so is the same oracle for a contract whose minor matches.
 */
function wireCompatCallback(
  callback: Record<string, (...inputs: string[][]) => Promise<string[][]>>,
  contractVersion: () => { major: number; minor: number } | undefined,
  applied: { count: number },
): Record<string, (...inputs: string[][]) => Promise<string[][]>> {
  // THE KEY IS THE ORACLE NAME AND NOT THE METHOD NAME, AND THE FIRST VERSION OF THIS HAD IT WRONG.
  // `buildACIRCallback` keys its object by `oracleKey` — `aztec_prv_callPrivateFunction` — and
  // resolves the HANDLER method from it by upstream's `aztec_{scope}_{methodName}` convention. A
  // wrapper keyed by `callPrivateFunction` wraps nothing, returns the callback unchanged, and
  // reports `wireCompatApplied: 0` over a run that needed it — which is exactly what the first
  // measurement showed, and it is the shape this repository calls a guard that cannot guard.
  const oracle = CALL_PRIVATE_ORACLE;
  const inner = callback[oracle];
  if (typeof inner !== 'function') {
    // A MISSING KEY IS A FAILURE, NOT A PASS-THROUGH. If the registry ever stops declaring this
    // oracle, silently returning the callback would leave the shim installed, inert and green.
    throw new Error(
      `the call-private wire shim found no '${oracle}' entry in the ACIR callback; the callback ` +
        `declares ${Object.keys(callback).length} oracle(s)`,
    );
  }
  const wrapped: Record<string, (...inputs: string[][]) => Promise<string[][]>> = { ...callback };
  wrapped[oracle] = async (...inputs: string[][]) => {
    const outputs = await inner(...inputs);
    const declared = contractVersion();
    const older =
      declared !== undefined &&
      declared.major === ORACLE_ENVIRONMENT_VERSION.major &&
      declared.minor < ORACLE_ENVIRONMENT_VERSION.minor;
    if (!older) {
      return outputs;
    }
    applied.count += 1;
    return regroupedCallPrivateResult(outputs);
  };
  return wrapped;
}

/** `[index, hex]` pairs, ascending, from an ACVM witness map. */
function witnessEntries(witness: Map<number, string>): (readonly [number, string])[] {
  return [...witness.entries()].map(([k, v]) => [Number(k), String(v)] as const).sort((a, b) => a[0] - b[0]);
}

/**
 * Executes one private function frame and returns a report.
 *
 * **This never throws for a refused oracle.** A refusal is the expected outcome for anything this
 * milestone does not serve, and swallowing it into an exception at the call site would lose which
 * oracle stopped it. The report carries `outcome`, `stoppedAtOracle` and the whole ordered ledger,
 * and the caller decides. It DOES surface the message and the error class, because M34's first
 * browser run showed that a failure which cannot name its subject is the expensive kind.
 */
export async function executePrivateFunction(request: PrivateExecutionRequest): Promise<PrivateExecutionReport> {
  if (acvmReady === undefined) {
    throw new PrivateExecutionNotInitialised();
  }
  await acvmReady;
  const doc = request.artifact as { name?: string };
  const fn = findFunction(request.artifact, request.functionName);
  const functionType = functionTypeOf(fn);
  const bytecode = Buffer.from(fn.bytecode, 'base64');

  const selector = await privateFunctionSelector(request.artifact, request.functionName);

  const contractAddress = toAddressValue(request.contractAddress, 'contractAddress');
  const msgSender = toAddressValue(request.msgSender, 'msgSender');
  const args = request.args.map((a, i) => toFieldValue(a, `args[${i}]`));
  const callContext = new CallContext(msgSender, contractAddress, selector, request.isStaticCall === true);
  const header = request.anchorBlockHeader ?? BlockHeader.empty();
  const txContext = TxContext.empty(
    toFieldValue(request.chainId, 'chainId'),
    toFieldValue(request.version, 'version'),
  );
  const contextInputs = new PrivateContextInputs(
    callContext,
    header,
    txContext,
    request.startSideEffectCounter ?? 0,
  );
  const contextFields = contextInputs.toFields();
  if (contextFields.length !== PRIVATE_CONTEXT_INPUTS_LENGTH) {
    throw new Error(
      `PrivateContextInputs serialised to ${contextFields.length} fields, ` +
        `and @aztec/constants declares PRIVATE_CONTEXT_INPUTS_LENGTH = ${PRIVATE_CONTEXT_INPUTS_LENGTH}`,
    );
  }

  // The declared argument width, read out of the ABI rather than counted off the caller's array —
  // upstream's own `countArgumentsSize`, so a caller who supplies the wrong number of fields is told
  // so here instead of producing `Cannot satisfy constraint` four layers down.
  const argumentsSize = countArgumentsSize((fn.abi ?? { parameters: [] }) as never) - PRIVATE_CONTEXT_INPUTS_LENGTH;
  if (args.length !== argumentsSize) {
    throw new Error(
      `${request.functionName} declares ${argumentsSize} argument field(s) beyond its context inputs ` +
        `and ${args.length} were supplied`,
    );
  }

  // THE DIRECTORY IS CHECKED BEFORE THE FRAME STARTS, not when the oracle is reached. An entry
  // whose preimage does not derive to its own key fails the circuit's `assert_eq` as an
  // unsatisfied constraint deep inside the ACVM; this says so as a directory problem, naming both
  // derivations, before a single opcode runs.
  const contractInstances = request.contractInstances ?? [];
  await assertHeldInstancesAreSelfConsistent(contractInstances);
  // AND THE ACCOUNT DIRECTORY, for the reason its own guard records: `try_get_public_keys` does not
  // constrain what this oracle returns, so an incoherent triple would not be caught downstream at
  // all on that path. Checking it here is not a nicety.
  const accountKeys = request.accountKeys ?? [];
  await assertHeldAccountKeysAreSelfConsistent(accountKeys);

  // THE TRANSACTION'S STATE. A top-level call creates it; the nested-call oracle hands its own
  // frame's down. `depth` travels with it because a bound that is not carried is not a bound.
  const shared = request.shared ?? createPrivateFrameState();
  const depth = request.depth ?? 0;

  // TIER 4's SOURCE, ASSEMBLED HERE BECAUSE THIS IS THE ONLY THING THAT CAN BUILD A FRAME.
  // `private_oracles.ts` owns the directory lookup, the five named refusals and the static-call
  // rule; it cannot own the recursion, because it is the module this one imports. So the recursion
  // and the selector derivation are INJECTED, which is also what keeps the oracle's refusals in the
  // file that declares the oracle.
  //
  // The child frames' reports are collected HERE rather than read back off the handle, so a report
  // is a tree even when the parent later throws: a frame that made two nested calls and then failed
  // has two completed children worth having, and losing them would make a failure look like a frame
  // that never called anything.
  const nestedReports: PrivateExecutionReport[] = [];
  const contracts = request.contracts ?? [];
  const nestedSource =
    contracts.length > 0
      ? {
          contracts,
          maxDepth: request.nestedMaxDepth ?? undefined,
          selectorOf: privateFunctionSelector,
          execute: async (child: NestedFrameRequest): Promise<NestedFrameResult> => {
            const report = await executePrivateFunction({
              artifact: child.artifact,
              functionName: child.functionName,
              contractAddress: child.contractAddress,
              msgSender: child.msgSender,
              chainId: request.chainId,
              version: request.version,
              // THE ARGUMENTS ARE ALREADY FIELDS, because they came out of the shared execution
              // cache as the preimage the PARENT stored. Nothing here re-encodes them.
              args: child.args,
              // THE CHILD CARRIES THE PARENT'S SEED, and the entropy INDEX is the transaction's.
              // There is no second source of entropy to give a child — this wallet's third design
              // property forbids drawing one — so the two must not collide, and a shared counter is
              // what makes them not.
              entropySeed: request.entropySeed,
              ...(request.anchorBlockHeader ? { anchorBlockHeader: request.anchorBlockHeader } : {}),
              startSideEffectCounter: child.startSideEffectCounter,
              isStaticCall: child.isStaticCall,
              writeLine: request.writeLine,
              contractInstances,
              accountKeys,
              ...(request.discovery ? { discovery: request.discovery } : {}),
              contracts,
              ...(request.nestedMaxDepth !== undefined ? { nestedMaxDepth: request.nestedMaxDepth } : {}),
              recordTape: request.recordTape === true,
              ...(request.nestedCallWireCompat ? { nestedCallWireCompat: request.nestedCallWireCompat } : {}),
              shared,
              depth: child.depth,
            });
            nestedReports.push(report);
            const pi = report.publicInputs;
            return {
              endSideEffectCounter: pi ? pi.endSideEffectCounter : child.startSideEffectCounter,
              returnsHash: pi ? Fr.fromString(pi.returnsHash) : Fr.ZERO,
              claimed: {
                noteHashes: pi ? pi.noteHashes.length : 0,
                nullifiers: pi ? pi.nullifiers.length : 0,
                l2ToL1Msgs: pi ? pi.l2ToL1MsgCount : 0,
                privateLogs: pi ? pi.privateLogs.length : 0,
                contractClassLogsHashes: pi ? pi.contractClassLogHashCount : 0,
              },
              solved: report.outcome === 'executed',
              report,
            };
          },
        }
      : undefined;

  const oracles = createPrivateOracleHandler({
    contractAddress,
    entropySeed: toFieldValue(request.entropySeed, 'entropySeed'),
    writeLine: request.writeLine,
    contractInstances,
    accountKeys,
    shared,
    depth,
    isStaticCall: request.isStaticCall === true,
    ...(request.discovery ? { discovery: request.discovery } : {}),
    ...(nestedSource ? { nested: nestedSource } : {}),
  });

  const fields = [...contextFields, ...args];
  const initialWitness = toACVMWitness(0, fields);

  const base = {
    contractName: doc.name ?? '?',
    functionName: request.functionName,
    functionType,
    selector: selector.toString(),
    bytecodeBytes: bytecode.length,
    contextInputFields: contextFields.length,
    argFields: args.length,
    initialWitnessSize: initialWitness.size,
    environmentOracleVersion: { ...ORACLE_ENVIRONMENT_VERSION },
    hasDiscovery: oracles.hasDiscovery(),
    hasNested: oracles.hasNested(),
    depth,
    servedSetSize: oracles.servedSet().length,
  };

  // THE TAPE IS TAKEN AT THE WIRE, NOT AT THE HANDLER, and the difference is the whole point.
  // `buildACIRCallback` is upstream's own bridge: it deserialises the ACVM's field arrays into the
  // handler's arguments and serialises the handler's answer back. Wrapping the CALLBACK records
  // what the ACVM actually sent and received; wrapping the HANDLER would record the deserialised
  // JavaScript objects, which is a different thing and not the thing a replaying consumer needs.
  const tape: OracleTapeEntry[] = [];
  const callback = buildACIRCallback(oracles.handler as never) as unknown as Record<
    string,
    (...inputs: string[][]) => Promise<string[][]>
  >;
  // THE SHIM SITS BETWEEN THE HANDLER AND THE TAPE, DELIBERATELY, so the TAPE records what the
  // CIRCUIT received rather than what the handler returned. M38's replaying executor drives the
  // same ACIR through a synchronous Rust executor and has to hand back the same slots the ACVM
  // accepted here; a tape taken on the other side of the shim would be a recording of a wire the
  // circuit never saw.
  const wireCompatApplied = { count: 0 };
  const compatible =
    request.nestedCallWireCompat === 'off'
      ? callback
      : wireCompatCallback(callback, () => oracles.contractVersion(), wireCompatApplied);
  const wired = request.recordTape ? recordingCallback(compatible, tape) : compatible;

  const simulator = new WASMSimulator();
  try {
    const result = await simulator.executeUserCircuit(
      initialWitness,
      { ...(fn as object), bytecode } as never,
      wired as never,
    );
    const publicInputs = extractPublicInputs(fields.length, result.partialWitness as Map<number, string>);
    const ledger = oracles.calls();
    return {
      ...base,
      ...(request.recordTape
        ? {
            tape,
            initialWitnessEntries: witnessEntries(initialWitness as unknown as Map<number, string>),
            solvedWitnessEntries: witnessEntries(result.partialWitness as Map<number, string>),
          }
        : {}),
      solvedWitnessSize: (result.partialWitness as Map<number, string>).size,
      returnWitnessSize: (result.returnWitness as Map<number, string>).size,
      returnFields: [...(result.returnWitness as Map<number, string>).entries()]
        .sort((a, b) => a[0] - b[0])
        .map(([, v]) => v),
      contractOracleVersion: oracles.contractVersion(),
      oracleCalls: ledger,
      oraclesServed: ledger.filter(c => c.outcome === 'served').length,
      oraclesRefused: ledger.filter(c => c.outcome === 'refused').length,
      oraclesUnavailable: ledger.filter(c => c.outcome === 'unavailable').length,
      // EXPLICITLY NULL RATHER THAN ABSENT. An optional field that is simply not written makes the
      // reader print `MISSING`, and a check asserting `MISSING` cannot tell "the frame stopped at
      // nothing" from "the path is misspelled" — the residue M34's review left standing one
      // milestone ago. Written on both paths, so the field's presence is never the answer.
      stoppedAtOracle: null,
      outcome: 'executed',
      effects: oracles.effects(),
      publicInputs: {
        contractAddress: publicInputs.callContext.contractAddress.toString(),
        argsHash: publicInputs.argsHash.toString(),
        returnsHash: publicInputs.returnsHash.toString(),
        startSideEffectCounter: Number(publicInputs.startSideEffectCounter),
        endSideEffectCounter: Number(publicInputs.endSideEffectCounter),
        // THE CLAIMED LENGTH IS WHAT IS READ, NOT THE PADDED CAPACITY. `ClaimedLengthArray` is a
        // fixed-width array plus the number of entries the circuit says are real; taking
        // `.array` wholesale would put sixteen zero note hashes into a note database.
        // `.value` AND NOT `String(entry)`, WHICH IS WHAT A FIRST DRAFT DID. Upstream's `NoteHash`
        // and `Nullifier` are STRUCTS — a field plus a side-effect counter — and their `toString()`
        // is `value=0x… counter=1`. Rendering the struct produced a string `Fr.fromString` then
        // refused, four layers away, in a page; reading the field is the only correct thing and a
        // missing one is a named error rather than a `String(undefined)`.
        noteHashes: claimed(publicInputs.noteHashes).map(n => fieldOf(n, 'noteHash')),
        nullifiers: claimed(publicInputs.nullifiers).map(n => fieldOf(n, 'nullifier')),
        privateLogs: claimed(publicInputs.privateLogs).map(l => {
          const log = (l as { log?: { fields?: unknown[]; length?: number } })?.log;
          const fields = (log?.fields ?? []) as { toString(): string }[];
          const length = typeof log?.length === 'number' ? log.length : fields.length;
          return { fields: fields.map(f => f.toString()), length };
        }),
        l2ToL1MsgCount: claimed(publicInputs.l2ToL1Msgs).length,
        contractClassLogHashCount: claimed(publicInputs.contractClassLogsHashes).length,
      },
      nested: nestedReports,
      wireCompatApplied: wireCompatApplied.count,
    };
  } catch (err) {
    // WALK THE CAUSE CHAIN. The ACVM reports every foreign-call failure as the same eleven words —
    // `Error awaiting \`foreign_call_handler\`` — and puts the real one on `cause`. A report that
    // carried only the wrapper would be a failure that cannot name its subject, which is the
    // expensive kind (M34's first browser run produced three of them). Both are kept: the wrapper is
    // what the ACVM said, `errorChain` is what actually happened.
    const chain: string[] = [];
    for (let e: unknown = err, depth = 0; e && depth < 8; depth++) {
      const node = e as { message?: string; name?: string; cause?: unknown };
      chain.push(`${node?.name ?? typeof e}: ${String(node?.message ?? e)}`);
      e = node?.cause;
    }
    const ledger = oracles.calls();
    const refused = ledger.filter(c => c.outcome === 'refused');
    const unavailable = ledger.filter(c => c.outcome === 'unavailable');
    // A FRAME HALTS ON EITHER KIND, AND `stoppedAtOracle` MUST SEE BOTH. `refused` is "this wallet
    // does not serve that oracle"; `unavailable` is "it does, and had no answer for that argument".
    // Both abort the ACVM at the instruction that needed the value, so both are stops — and a
    // `stoppedAtOracle` that only looked at `refused` would report `null` for a frame that plainly
    // stopped, which is the silent-success shape this campaign refuses.
    const halted = ledger.filter(c => c.outcome !== 'served');
    const e = err as { message?: string; name?: string };
    return {
      ...base,
      // The tape of what DID cross the wire before the halt, on the same terms as the success
      // path. A frame that stopped at its fifth oracle has four answers worth having, and a
      // consumer replaying it has to know it is holding a prefix rather than a whole run — which
      // it does, because `stoppedAtOracle` is beside it.
      ...(request.recordTape
        ? { tape, initialWitnessEntries: witnessEntries(initialWitness as unknown as Map<number, string>) }
        : {}),
      contractOracleVersion: oracles.contractVersion(),
      oracleCalls: ledger,
      oraclesServed: ledger.filter(c => c.outcome === 'served').length,
      oraclesRefused: refused.length,
      oraclesUnavailable: unavailable.length,
      stoppedAtOracle: halted.length > 0 ? halted[halted.length - 1].oracle : null,
      error: String(e?.message ?? err),
      errorName: String(e?.name ?? 'Error'),
      errorChain: chain,
      outcome: halted.length > 0 ? 'refused' : 'failed',
      effects: oracles.effects(),
      // THE CHILDREN A FAILED FRAME ALREADY MADE. A frame that made two nested calls and then
      // failed has two completed children, and dropping them here would make "the transaction is a
      // tree" a property of the success path only — which is the half a reader needs least.
      nested: nestedReports,
      wireCompatApplied: wireCompatApplied.count,
    };
  }
}
