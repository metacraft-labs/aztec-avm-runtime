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
// WHAT IS NOT HERE. Nested calls. `aztec_prv_callPrivateFunction` is the milestone's fourth tier and
// it refuses by name, so this executes ONE frame. A contract that makes a nested private call fails
// at the oracle that would have made it, naming itself — which is the correct failure and not a
// silent single-frame result.

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
  type HeldContractInstance,
  type OracleCall,
  ORACLE_ENVIRONMENT_VERSION,
  assertHeldAccountKeysAreSelfConsistent,
  assertHeldInstancesAreSelfConsistent,
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
  /** The oracle version the BYTECODE declared, against the environment's own. */
  readonly contractOracleVersion?: { major: number; minor: number };
  readonly environmentOracleVersion: { major: number; minor: number };
  /** Every oracle the bytecode asked for, in order, served and refused alike. */
  readonly oracleCalls: readonly OracleCall[];
  readonly oraclesServed: number;
  /** Calls to oracles this wallet does not serve at all — `OracleUnimplemented`. */
  readonly oraclesRefused: number;
  /** Calls to a SERVED oracle that had no answer for that argument — `ContractInstanceNotHeld`. */
  readonly oraclesUnavailable?: number;
  /** The oracle that stopped the execution, if one did. */
  readonly stoppedAtOracle: string | null;
  readonly error?: string;
  readonly errorName?: string;
  /** The whole `cause` chain, outermost first. The ACVM's wrapper is never the useful one. */
  readonly errorChain?: readonly string[];
  readonly outcome: 'executed' | 'refused' | 'failed';
  readonly effects: ReturnType<ReturnType<typeof createPrivateOracleHandler>['effects']>;
  /** A handful of the circuit's own public inputs, when it solved. */
  readonly publicInputs?: {
    readonly contractAddress: string;
    readonly argsHash: string;
    readonly returnsHash: string;
    readonly startSideEffectCounter: number;
    readonly endSideEffectCounter: number;
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

  const selector = await FunctionSelector.fromNameAndParameters({
    name: request.functionName,
    parameters: ((fn.abi as { parameters?: unknown[] } | undefined)?.parameters ?? []) as never,
  });

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

  const oracles = createPrivateOracleHandler({
    contractAddress,
    entropySeed: toFieldValue(request.entropySeed, 'entropySeed'),
    writeLine: request.writeLine,
    contractInstances,
    accountKeys,
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
  };

  const simulator = new WASMSimulator();
  try {
    const result = await simulator.executeUserCircuit(
      initialWitness,
      { ...(fn as object), bytecode } as never,
      buildACIRCallback(oracles.handler as never) as never,
    );
    const publicInputs = extractPublicInputs(fields.length, result.partialWitness as Map<number, string>);
    const ledger = oracles.calls();
    return {
      ...base,
      solvedWitnessSize: (result.partialWitness as Map<number, string>).size,
      returnWitnessSize: (result.returnWitness as Map<number, string>).size,
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
      },
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
    };
  }
}
