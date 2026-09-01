// The PUBLIC half of a transaction whose private half has already run, in a browser.
//
// =============================================================================================
// WHAT THIS IS FOR, AND WHY IT IS NOT `token_transfer.ts` WITH DIFFERENT ARGUMENTS
// =============================================================================================
//
// `token_transfer.ts` DECLARES a public transaction: it names two functions and their arguments,
// encodes them through the ABI, and runs the result. That is the right shape for a demo whose
// transaction has no private half — nothing upstream of it committed to anything.
//
// A transaction with a private half is a different problem. The private circuit ENQUEUES its
// public calls and commits to each one's calldata by HASH in its public inputs; the sequencer runs
// them afterwards. So "run the calls this transaction enqueued" means running exactly what the
// circuit committed to — and a runner that re-encoded them from a function name and an argument
// list would be a SECOND producer of a value the circuit already produced, free to disagree with
// it. `NESTED-CALLS.md` §3's two enqueued calls differ by their ARGUMENT (10 against 20) and not
// by their function, which is precisely the disagreement a re-declaration hides.
//
// So this file takes the calls as data — `msgSender`, `contractAddress`, `isStaticCall`,
// `calldataHash`, `counter`, and the CALLDATA PREIMAGE out of the transaction's own execution
// cache — and rebuilds each `PublicCallRequest` from the calldata with upstream's own
// `PublicCallRequest.fromCalldata`. The hash that comes back is compared against the one the
// circuit committed to, per call, and a disagreement is a refusal. That comparison is the whole
// reason the preimage is carried rather than the arguments: it is the only thing that can say the
// public half ran THIS transaction's calls rather than calls that resemble them.
//
// =============================================================================================
// WHAT IT REUSES, AND FROM WHERE
// =============================================================================================
//
//   `createTxForPublicCalls`            — vendored upstream (RI-21), `PublicCallRequestWithCalldata`
//                                         in, `Tx` out. The tester's `createTx` is the layer ABOVE
//                                         it that encodes from a function name; this file goes
//                                         under that layer deliberately.
//   `AvmRuntime.registerContract` / `fundFeeJuice` / `submitExternal` / `produceBlock`
//                                       — M23's facade, unchanged.
//   the two seeding nullifiers          — M29's findings, and `token_transfer.ts` records what each
//                                         one costs when it is missing. The initialization one is
//                                         seeded only when the ARTIFACT declares an initializer,
//                                         and which way that went is reported.
//   `ExecutedStepCollector`             — M29's real executed step stream, through `OpenedRuntime`.
//
// Nothing here is a second copy of anything: no ABI encoding, no selector derivation, no hash
// recomputed by hand.

import { Fr } from '@aztec/foundation/curves/bn254';
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { loadContractArtifact } from '@aztec/stdlib/abi';
import { Gas } from '@aztec/stdlib/gas';
import { PublicCallRequest } from '@aztec/stdlib/kernel';
import { PublicCallRequestWithCalldata } from '@aztec/stdlib/tx';
import { makeContractClassPublic } from '@aztec/stdlib/testing';
import { siloNullifier } from '@aztec/stdlib/hash';
import { poseidon2HashWithSeparator } from '@aztec/foundation/crypto/poseidon';
import {
  CONTRACT_INSTANCE_REGISTRY_CONTRACT_ADDRESS,
  DomainSeparator,
  PUBLIC_TX_L2_GAS_OVERHEAD,
  TX_DA_GAS_OVERHEAD,
} from '@aztec/constants';

import {
  PUBLIC_DISPATCH_FN_NAME,
  getFunctionSelector,
} from '../../orchestration/src/vendor/avm_fixtures_utils.ts';
import {
  createTxForPublicCalls,
  type TestPrivateInsertions,
} from '../../orchestration/src/vendor/public_fixtures_utils.ts';
import { defaultGlobals } from '../../orchestration/src/vendor/public_tx_simulation_tester.ts';

import { base64ToBytes } from './ct_download.ts';
import type { OpenedRuntime } from './runtime.ts';

/** Fee juice credited to the fee payer before the transaction. M20's shortcut, DD-2. */
export const PUBLIC_HALF_FUNDING = new Fr(10n ** 12n);

/**
 * The seed every contract CLASS in this runtime is derived with.
 *
 * `wallet_main.ts`'s `classIdOf` uses it and `token_transfer.ts` uses it, so a callee's class id
 * derived here agrees with the one its instance was derived from. It is checked against that
 * instance below rather than trusted.
 */
export const CONTRACT_CLASS_SEED = 27;

/**
 * One enqueued public call, exactly as `PrivateExecutionReport.publicInputs.publicCallRequests`
 * reports it.
 *
 * The type is restated here rather than imported so this module does not depend on the private
 * executor: the public half runs from DATA, and a consumer with a differently-produced list of
 * enqueued calls is a legitimate caller. The field names are the circuit's.
 */
export interface EnqueuedPublicCall {
  readonly contractAddress: string;
  readonly calldataHash: string;
  readonly msgSender: string;
  readonly isStaticCall: boolean;
  readonly counter: number;
  readonly calldata: readonly string[];
}

/** What one enqueued call turned into, reported per call rather than as a total. */
export interface ExecutedEnqueuedCall {
  readonly counter: number;
  readonly contractAddress: string;
  readonly msgSender: string;
  readonly isStaticCall: boolean;
  /** The hash the CIRCUIT committed to. */
  readonly committedCalldataHash: string;
  /** The hash `PublicCallRequest.fromCalldata` derives from the preimage. */
  readonly rebuiltCalldataHash: string;
  /** The two above, compared. Asserted true here; reported so a check reads it rather than infers it. */
  readonly calldataHashMatches: boolean;
  /** `calldata[0]` — the selector the AVM's `public_dispatch` will switch on. */
  readonly selector: string;
  /**
   * The callee's function whose ABI-derived selector equals {@link selector}, or `null`.
   *
   * Resolved by deriving every public function's selector from the artifact and comparing, so it
   * is a MATCH rather than a label: a selector the artifact derives for nothing is `null` and says
   * so, which is the shape `NestedCallRefused`'s `unknown-selector` ground has one level up.
   * Used for the recording's frame names, where a wrong name would be a fiction a reader trusts.
   */
  readonly functionName: string | null;
  readonly calldataFields: number;
}

export interface PublicHalfReport {
  /** The callee contract, as registered. */
  readonly contract: { readonly name: string; readonly address: string; readonly classId: string };
  /**
   * Whether the callee's artifact declares an initializer, and therefore whether the public
   * initialization nullifier was seeded.
   *
   * Read off the artifact rather than assumed. `token_transfer.ts` records what a missing one
   * costs — 175 instructions and then `REVERT_8` out of `assert_is_initialized_public` — and
   * seeding one a contract never asserts on would be a nullifier in the tree that nothing put
   * there.
   */
  readonly declaresInitializer: boolean;
  readonly seededNullifiers: readonly string[];
  /** The first nullifier the carrier transaction declares, and where it came from. */
  readonly firstNullifier: string;
  readonly firstNullifierSource: string;
  readonly calls: readonly ExecutedEnqueuedCall[];
  readonly txHash: string;
  readonly feePayer: string;
  readonly outcome: string;
  /** The whole outcome record, so a check can read a reason rather than a word. */
  readonly outcomeRecord: unknown;
  readonly blockNumber: number | null;
  /**
   * Upstream's own `ProcessedTx.revertCode`, matched by transaction hash in the sealed block.
   *
   * `outcome` cannot answer whether the transaction reverted — `processed` is the BLOCK's verdict
   * and a reverted transaction is still processed. `null` means the block carries no `ProcessedTx`
   * for this hash, which is a failure to measure rather than a pass.
   */
  readonly revertCode: number | null;
  readonly revertDescription: string | null;
  readonly revertReason: string | null;
  /** M29's stream, as the collector drained it. `null` when collection was not asked for. */
  readonly executed: {
    readonly count: number;
    readonly crossings: number;
    readonly batchRecords: number;
    readonly instructionsExecuted: number | null;
    readonly inResult: number | null;
    readonly drainedMatchesResult: boolean | null;
    readonly contexts: number;
    readonly distinctOpcodes: number;
    readonly firstOpcodes: readonly number[];
  } | null;
  readonly moduleCalls: number;
}

/**
 * A contract's `public_dispatch` bytecode, decoded, out of the RAW artifact.
 *
 * ===========================================================================================
 * WHY THIS DOES NOT GO THROUGH `loadContractArtifact`, WHICH IS THE OBVIOUS ROUTE
 * ===========================================================================================
 *
 * A raw artifact's `functions[].bytecode` is BASE64 TEXT and `makeContractClassPublic` hashes what
 * it is handed, so the class id has to be taken over the DECODED bytes — `loadContractArtifact` is
 * upstream's own decoder and was the first thing tried.
 *
 * **It cannot load an artifact from the other nightly line at all.** Measured against the two lines
 * this tree has installed: the `deletion_era` Parent loads, and the `cpp`-anchor one fails with
 * `Could not generate contract artifact for Parent: TypeError: Cannot read properties of undefined
 * (reading 'find')`. That is the anchor-versus-pin family again — *read the anchor to understand the
 * design; read the INSTALLED PIN to know what will parse* — and it matters here because M39's
 * `anchorLine` arm derives an instance for an artifact this runtime deliberately cannot execute, in
 * order to measure that it cannot. A derivation that threw would replace that measurement with a
 * page error.
 *
 * `Buffer.from(b64, 'base64')` and this `Uint8Array` produce the SAME class id; measured, both
 * lines, before the route was changed.
 */
export function publicDispatchBytecode(artifact: unknown): Uint8Array {
  const doc = artifact as { name?: string; functions?: { name?: string; bytecode?: unknown }[] };
  const dispatch = (doc.functions ?? []).find(f => f.name === PUBLIC_DISPATCH_FN_NAME);
  const bytecode = dispatch?.bytecode;
  if (bytecode === undefined) {
    throw new Error(
      `${doc.name ?? 'the artifact'} has no ${PUBLIC_DISPATCH_FN_NAME} bytecode, so it has no AVM code`,
    );
  }
  // ===========================================================================================
  // BOTH ARTIFACT SHAPES, AND THAT IS THE WHOLE DEFECT STATED AS A TYPE.
  // ===========================================================================================
  //
  // A RAW artifact's `bytecode` is base64 TEXT; a `loadContractArtifact`ed one's is BYTES. This
  // runtime has callers of both kinds — the wallet demo registers a LOADED Token artifact and
  // `privateContractInstance` derives an address from a RAW one — and a helper that assumed either
  // shape is wrong for half its callers in a way that produces a well-formed answer rather than an
  // error. That is exactly how `classIdOf` came to hash base64 text for one caller and bytecode for
  // the other; the two class ids differ and every address derived from either is self-consistent,
  // so no private frame can tell.
  //
  // So the shape is READ rather than assumed, and a third kind is a named failure rather than a
  // coercion.
  if (typeof bytecode === 'string') return base64ToBytes(bytecode);
  if (bytecode instanceof Uint8Array) return bytecode;
  throw new Error(
    `${doc.name ?? 'the artifact'}'s ${PUBLIC_DISPATCH_FN_NAME} bytecode is a `
      + `${Object.prototype.toString.call(bytecode)}; it must be base64 text (a raw artifact) or `
      + 'bytes (a loaded one)',
  );
}

/**
 * Every public function name the artifact declares, from BOTH places upstream keeps them.
 *
 * A `#[public]` function of a contract with a `public_dispatch` may live in `functions` or in
 * `nonDispatchPublicFunctions` — `wallet_main.ts:callOf` records the run that failed with "the
 * artifact has no transfer_in_public" over an artifact that has it. Looking in one place is this
 * campaign's "an absence claim is only as wide as the places you looked".
 */
function publicFunctionNames(artifact: unknown): string[] {
  const doc = artifact as {
    functions?: { name?: string; functionType?: string }[];
    nonDispatchPublicFunctions?: { name?: string }[];
  };
  const names = new Set<string>();
  for (const f of doc.functions ?? []) {
    if (typeof f.name === 'string' && f.name !== PUBLIC_DISPATCH_FN_NAME) names.add(f.name);
  }
  for (const f of doc.nonDispatchPublicFunctions ?? []) {
    if (typeof f.name === 'string') names.add(f.name);
  }
  return [...names];
}

/** `Fr` from the hex the report carries, with the field named in the failure. */
function fieldFrom(hex: string, what: string): Fr {
  try {
    return Fr.fromString(hex);
  } catch (e) {
    throw new Error(`${what}: '${hex}' is not a field element (${String((e as Error)?.message ?? e)})`);
  }
}

/**
 * Run the public calls a private half enqueued, in the order the CIRCUIT enqueued them.
 *
 * `calls` may arrive in any order — a transaction's enqueued calls are spread across its private
 * frames and a tree walk recovers them in visit order — so they are sorted by the side-effect
 * counter the circuit committed to. Two calls at one counter is a contradiction in the input and
 * is refused rather than tie-broken.
 */
export async function runEnqueuedPublicCalls(
  opened: OpenedRuntime,
  calleeArtifactRaw: unknown,
  calleeInstance: {
    address: AztecAddress;
    salt: Fr;
    deployer: AztecAddress;
    originalContractClassId: Fr;
    initializationHash: Fr;
    immutablesHash: Fr;
    publicKeys: unknown;
  },
  calls: readonly EnqueuedPublicCall[],
  options: {
    /** The transaction identity the private half committed to; see `firstNullifierSource`. */
    readonly firstNullifier: string;
    readonly firstNullifierSource: string;
    readonly funding?: Fr;
    /**
     * CONTROL: do not seed the callee's deployment nullifier.
     *
     * M29 found that without it the AVM answers the address with no bytecode and executes exactly
     * ONE instruction — `pc=0`, the `LAST_OPCODE_SENTINEL` — while the block still reports the
     * transaction `processed`. That is the shape "the public half ran" has to be able to
     * distinguish itself from, and a floor asserted against a number nobody has seen fail is a
     * floor nobody has calibrated. Exercised as an arm rather than described.
     */
    readonly skipDeploymentNullifier?: boolean;
  },
): Promise<PublicHalfReport> {
  if (calls.length === 0) {
    throw new Error(
      'the public half was asked to run zero enqueued calls; `createTxForPublicCalls` refuses a ' +
        'transaction with none, and a run that quietly produced an empty block would report success ' +
        'over a transaction that never reached the AVM',
    );
  }
  const counters = calls.map(c => c.counter);
  if (new Set(counters).size !== counters.length) {
    throw new Error(
      `two enqueued public calls share a side-effect counter (${counters.join(', ')}); the circuit ` +
        'assigns one per side effect, so this is a contradiction in the input rather than a tie to break',
    );
  }
  const ordered = [...calls].sort((a, b) => a.counter - b.counter);

  const artifact = loadContractArtifact(calleeArtifactRaw as never);

  // THE CLASS ID MUST BE THE ONE THE INSTANCE WAS DERIVED FROM, AND THAT IS ASSERTED RATHER THAN
  // ARRANGED. The private half derived the callee's ADDRESS from its class id; deriving a second
  // class here and registering that would put bytecode in the DB under an address nothing enqueued
  // a call to, and the AVM answers such an address with no bytecode at all — M29's
  // one-instruction shape, which still reports the transaction `processed`.
  //
  // `CONTRACT_CLASS_SEED` is `makeContractClassPublic`'s first argument and it is NOT the
  // instance's salt: the class is seeded once per artifact and the instance is salted per
  // deployment, which is why `Child` at salt 33 and `Parent` at salt 31 share a class seed. The
  // equality below is what makes a drift in either loud, so the constant is a starting point for a
  // comparison rather than a value anything trusts.
  const contractClass = await makeContractClassPublic(
    CONTRACT_CLASS_SEED,
    publicDispatchBytecode(calleeArtifactRaw) as never,
  );
  if (!contractClass.id.equals(calleeInstance.originalContractClassId)) {
    throw new Error(
      `the class id derived from ${artifact.name}'s public_dispatch (${contractClass.id.toString()}) is not ` +
        `the one the callee's instance was derived from (${calleeInstance.originalContractClassId.toString()}); ` +
        'registering it would deploy bytecode at an address nothing enqueued a call to',
    );
  }

  await opened.runtime.registerContract(contractClass as never, calleeInstance as never);

  // THE DEPLOYMENT NULLIFIER. Without it the AVM answers the address with no bytecode and executes
  // exactly one instruction while the block still reports the transaction `processed` — M29's
  // finding, recorded at length in `token_transfer.ts`.
  const seeded: string[] = [];
  const deploymentNullifier = await siloNullifier(
    await AztecAddress.fromNumber(CONTRACT_INSTANCE_REGISTRY_CONTRACT_ADDRESS),
    calleeInstance.address.toField(),
  );
  if (options.skipDeploymentNullifier !== true) {
    opened.publicDataTree.insertNullifier(deploymentNullifier);
    seeded.push(deploymentNullifier.toString());
  }

  // AND THE PUBLIC INITIALIZATION NULLIFIER, BUT ONLY IF THE ARTIFACT DECLARES AN INITIALIZER.
  //
  // `assert_is_initialized_public` is emitted into every `#[public]` function of a contract that
  // HAS an initializer, and into none of a contract that does not. Seeding unconditionally would
  // put a nullifier in the tree that no circuit asserts on, and would make "the transaction ran"
  // depend on a value nothing derived — so the decision is read off the artifact and reported.
  const declaresInitializer = (artifact.functions ?? []).some(
    (f: { isInitializer?: boolean }) => f.isInitializer === true,
  );
  if (declaresInitializer) {
    const publicInitNullifier = await poseidon2HashWithSeparator(
      [calleeInstance.address.toField()],
      DomainSeparator.PUBLIC_INITIALIZATION_NULLIFIER,
    );
    const initializationNullifier = await siloNullifier(calleeInstance.address, publicInitNullifier);
    opened.publicDataTree.insertNullifier(initializationNullifier);
    seeded.push(initializationNullifier.toString());
  }

  // ===========================================================================================
  // THE REQUESTS, REBUILT FROM THE CALLDATA AND COMPARED AGAINST THE CIRCUIT'S OWN HASH.
  // ===========================================================================================
  // The selector table, derived once from the ABI so a resolution is a comparison of two
  // independently-derived values rather than a lookup in a table somebody typed.
  const selectorOf = new Map<string, string>();
  for (const name of publicFunctionNames(calleeArtifactRaw)) {
    const selector = await getFunctionSelector(name, artifact);
    selectorOf.set(selector.toField().toString(), name);
  }

  const executedCalls: ExecutedEnqueuedCall[] = [];
  const requests: PublicCallRequestWithCalldata[] = [];
  for (const call of ordered) {
    const calldata = call.calldata.map((f, i) => fieldFrom(f, `calldata field ${i}`));
    if (calldata.length === 0) {
      throw new Error(
        `the enqueued call at counter ${call.counter} carries no calldata; its first field is the ` +
          'selector `public_dispatch` switches on, so an empty preimage cannot dispatch anywhere',
      );
    }
    const request = await PublicCallRequest.fromCalldata(
      AztecAddress.fromString(call.msgSender),
      AztecAddress.fromString(call.contractAddress),
      call.isStaticCall,
      calldata,
    );
    const rebuilt = request.calldataHash.toString();
    // THE IDENTITY THIS WHOLE FILE EXISTS FOR. Two independent derivations of one value: the
    // circuit hashed the calldata inside the proof, and upstream's own `fromCalldata` hashes the
    // preimage the execution cache handed back. A mismatch means the preimage is not the one the
    // circuit committed to, and running it would be running a different transaction.
    if (rebuilt !== call.calldataHash) {
      throw new Error(
        `the calldata preimage for the call enqueued at counter ${call.counter} hashes to ${rebuilt}, ` +
          `and the circuit committed to ${call.calldataHash}. The public half would be running a ` +
          'call this transaction did not enqueue.',
      );
    }
    executedCalls.push({
      counter: call.counter,
      contractAddress: call.contractAddress,
      msgSender: call.msgSender,
      isStaticCall: call.isStaticCall,
      committedCalldataHash: call.calldataHash,
      rebuiltCalldataHash: rebuilt,
      calldataHashMatches: rebuilt === call.calldataHash,
      selector: calldata[0].toString(),
      functionName: selectorOf.get(calldata[0].toString()) ?? null,
      calldataFields: calldata.length,
    });
    requests.push(new PublicCallRequestWithCalldata(request, calldata));
  }

  // THE CARRIER'S FIRST NULLIFIER IS THE TRANSACTION'S OWN IDENTITY, HANDED IN.
  //
  // `createTxForPublicCalls` refuses a transaction with no non-revertible nullifier — upstream's
  // note-nonce derivation needs one — and upstream's own tester supplies `new Fr(420000 + txCount)`,
  // a counter. A counter would make two runs of one transaction produce two different carriers and
  // two different transactions produce the same one. The caller passes a value the PRIVATE half
  // committed to instead, and says which, so the carrier is derived rather than minted.
  const privateInsertions: TestPrivateInsertions = {
    nonRevertible: { nullifiers: [fieldFrom(options.firstNullifier, 'the transaction identity')] },
  };

  const tx = await createTxForPublicCalls(
    privateInsertions,
    /*setupCallRequests=*/ [],
    /*appCallRequests=*/ requests,
    /*teardownCallRequest=*/ undefined,
    /*feePayer=*/ await AztecAddress.fromNumber(1001),
    /*gasUsedByPrivate=*/ new Gas(TX_DA_GAS_OVERHEAD, PUBLIC_TX_L2_GAS_OVERHEAD),
    defaultGlobals(),
  );

  const feePayer = (tx as never as { data: { feePayer: AztecAddress } }).data.feePayer;
  await opened.runtime.fundFeeJuice(feePayer, options.funding ?? PUBLIC_HALF_FUNDING);

  const callsBefore = opened.reactor.moduleCalls;
  const receipt = await opened.runtime.submitExternal(tx as never);
  const block = await opened.runtime.produceBlock();
  const settled = opened.runtime.receiptFor(receipt.txHash);
  const settledOutcome = (settled ?? (receipt as never as { outcome?: unknown }))?.outcome ?? null;

  const processedTx = (
    (block as never as {
      processed?: readonly {
        hash: { toString(): string };
        revertCode: { getCode(): number; getDescription(): string };
        revertReason?: { message?: string } | undefined;
      }[];
    } | null)?.processed ?? []
  ).find(p => p.hash.toString() === receipt.txHash);

  const executed = opened.steps.last;
  const opcodes = executed === null ? [] : executed.steps.map(s => s.opcode);

  return {
    contract: {
      name: artifact.name,
      address: calleeInstance.address.toString(),
      classId: contractClass.id.toString(),
    },
    declaresInitializer,
    seededNullifiers: seeded,
    firstNullifier: options.firstNullifier,
    firstNullifierSource: options.firstNullifierSource,
    calls: executedCalls,
    txHash: receipt.txHash,
    feePayer: feePayer.toString(),
    // `outcome` IS A RECORD, NOT A WORD, AND `String()` OF ONE IS `[object Object]`.
    // `token_transfer.ts` reads it exactly this way and for the same reason: the block's verdict is
    // `{kind, …}` and a report that stringified it would give a check a constant to compare
    // against. The whole record travels beside it so a reader gets the reason rather than the word.
    outcome:
      typeof settledOutcome === 'string'
        ? settledOutcome
        : String((settledOutcome as { kind?: string } | null)?.kind ?? JSON.stringify(settledOutcome)),
    outcomeRecord: settledOutcome,
    blockNumber:
      typeof (block as never as { number?: number })?.number === 'number'
        ? (block as never as { number: number }).number
        : null,
    revertCode: processedTx ? processedTx.revertCode.getCode() : null,
    revertDescription: processedTx ? processedTx.revertCode.getDescription() : null,
    revertReason: processedTx?.revertReason?.message ?? null,
    executed:
      executed === null
        ? null
        : {
            count: executed.count,
            crossings: executed.crossings,
            batchRecords: executed.batchRecords,
            instructionsExecuted: executed.instructionsExecuted,
            inResult: executed.inResult,
            drainedMatchesResult: executed.drainedMatchesResult,
            contexts: new Set(executed.steps.map(s => s.contextId)).size,
            distinctOpcodes: new Set(opcodes).size,
            firstOpcodes: opcodes.slice(0, 8),
          },
    moduleCalls: opened.reactor.moduleCalls - callsBefore,
  };
}
