// transpiled_contract_driver.ts — M31: register a contract whose AVM bytecode was produced by the
// BROWSER, and execute a real call against it.
//
// M22's `block_e2e_driver.ts` shape and M26's `join_e2e_driver.ts` reason: `tools/` lives outside
// this package, so a bare `@aztec/stdlib` import THERE does not resolve — node's ESM resolution
// walks up from the importing FILE, not from the cwd. Everything that needs this package's
// `node_modules` lives here and the tool imports it relatively.
//
// ---------------------------------------------------------------------------------------------
// WHAT IS AND IS NOT CLAIMED.
//
// The BYTECODE's provenance is the browser: `tools/run_transpiler_arms.mjs` transpiles in
// Chromium, carries the bytes out base64-encoded, writes them to disk, and hands the file to this
// driver. The EXECUTION host is Node — the same `avm.wasm`, the same `AvmRuntime` facade and the
// same `PublicProcessor` a page would use, but not a page. That boundary is stated in the report
// (`bytecodeProvenance`) rather than left to be inferred, because "in the browser" is the
// milestone's own phrase and it is true of the transpile and not yet of this execution.
//
// ---------------------------------------------------------------------------------------------
// WHY THERE IS A REVERTING ARM, AND WHY IT IS NOT OPTIONAL.
//
// M29's review established the campaign's deepest defect: a demo transaction that REVERTED AT ITS
// FIRST INSTRUCTION passed a milestone, its review, and a second milestone's floors, because every
// assertion was correct and none asked whether the subject had done anything. `revertCode === 0`
// alone is not proof of that either — a `revertCode` that is always 0 reads the same. So this
// driver runs TWO contracts: one that should complete and one whose `public_dispatch` asserts
// something false. If both come back 0, the field is a constant and the check says so.
//
// The executed INSTRUCTION COUNT comes from M9's observer through M12's `avm_steps_count()`, which
// is `stats["total_instructions_executed"]`'s own source, and it is what distinguishes "ran the
// loop" from "reverted at instruction one".

import { Fr } from '@aztec/foundation/curves/bn254';
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { GasFees, } from '@aztec/stdlib/gas';
import { GlobalVariables } from '@aztec/stdlib/tx';
import { PublicKeys } from '@aztec/stdlib/keys';
import { computeInitializationHash } from '@aztec/stdlib/contract';
import { loadContractArtifact } from '@aztec/stdlib/abi';
import { makeContractClassPublic, makeContractInstanceFromClassId } from '@aztec/stdlib/testing';
import { siloNullifier } from '@aztec/stdlib/hash';
import { CONTRACT_INSTANCE_REGISTRY_CONTRACT_ADDRESS } from '@aztec/constants';

import { createBlockProcessor } from './block_assembly.ts';
import { decodePublicTxResult, residentWorldStateRevision } from './avm_inputs.ts';
import { defaultPublicSimulatorConfig } from './fee_juice.ts';
import { encodeForShippedModuleOnly } from './shipped_module_config.ts';
import { ResidentContractsDB } from './resident_contracts_db.ts';
import { ResidentMerkleDb } from './resident_db.ts';
import { ResidentMerkleWriteOperations } from './resident_merkle_operations.ts';
import { WasmAvmPublicTxSimulator } from './wasm_avm_public_tx_simulator.ts';
import { AvmRuntime } from './avm_runtime.ts';
import { DateProvider, ManualDateProvider } from './chain_clock.ts';
import {
  PUBLIC_DISPATCH_FN_NAME,
  getContractFunctionAbi,
  getContractFunctionArtifact,
  getFunctionSelector,
} from './vendor/avm_fixtures_utils.ts';
import { PublicTxSimulationTester } from './vendor/public_tx_simulation_tester.ts';
import { SimpleContractDataSource } from './vendor/simple_contract_data_source.ts';

/** Fee juice credited to the fee payer before the transaction. M20's shortcut, DD-2. */
export const M31_FUNDING = new Fr(10n ** 12n);

interface ReactorLike {
  createContractDb(): number;
  createMerkleDb(): number;
  destroyContractDb(handle: number): void;
  destroyMerkleDb(handle: number): void;
  simulate(input: Uint8Array, contractDb: number, merkleDb: number): { revertCode: number; result: unknown };
  result(): Uint8Array | null;
  readonly moduleCalls: number;
  readonly exportNames: readonly string[];
  readonly exports: Record<string, unknown>;
}

export interface TranspiledExecutionReport {
  readonly fixture: string;
  /** Where the bytecode came from. Never inferred by a reader; written here. */
  readonly bytecodeProvenance: string;
  readonly artifactName: string;
  readonly artifactSha256: string;
  /** sha256 of the base64 `public_dispatch` bytecode the artifact carries. */
  readonly dispatchBytecodeBytes: number;
  readonly contractClassId: string;
  readonly contractAddress: string;
  readonly registeredClasses: number;
  readonly registeredInstances: number;
  readonly deploymentNullifier: string;
  readonly calledFunction: string;
  readonly calledSelector: string;
  /** Upstream's own `<Artifact>.<fn>`, from `SimpleContractDataSource.getDebugFunctionName`. */
  readonly debugFunctionName: string | undefined;
  readonly calldataFields: number;
  /** Arity taken from the ABI, so a mismatch is a refusal rather than a guess. */
  readonly parameterCount: number;
  readonly calldataSelector: string;
  readonly txHash: string;
  readonly feePayer: string;
  readonly outcome: string;
  readonly blockNumber: number | null;
  /** Upstream's own `ProcessedTx.revertCode`. `0` is "did not revert"; see the header. */
  readonly revertCode: number | null;
  readonly revertDescription: string | null;
  readonly revertReason: string | null;
  /** M12's `avm_steps_count()` after the simulation — M9's observer's own count. */
  readonly instructionsExecuted: number | null;
  readonly moduleCalls: number;
  readonly simulated: boolean;
  readonly proving: string;
}

function armGlobals(): GlobalVariables {
  const empty = GlobalVariables.empty();
  return GlobalVariables.from({ ...empty, gasFees: new GasFees(1n, 1n) });
}

/**
 * Run one browser-transpiled contract: register it, call it, seal a block, report what happened.
 *
 * `rawArtifact` is already-parsed JSON, for `join_e2e_driver`'s reason: the SEARCH for it is the
 * caller's business and does not belong in here.
 */
export async function runTranspiledContract(
  reactor: ReactorLike,
  rawArtifact: unknown,
  opts: {
    fixture: string;
    artifactSha256: string;
    bytecodeProvenance: string;
    fnName?: string;
    args?: unknown[];
    seed?: number;
  },
): Promise<TranspiledExecutionReport> {
  const seed = opts.seed ?? 3100;
  const fnName = opts.fnName ?? PUBLIC_DISPATCH_FN_NAME;

  const artifact = loadContractArtifact(rawArtifact as never);
  const deployer = await AztecAddress.fromNumber(seed + 1);
  const sender = await AztecAddress.fromNumber(seed + 2);

  const dispatch = getContractFunctionArtifact(PUBLIC_DISPATCH_FN_NAME, artifact);
  if (dispatch === undefined) throw new Error(`${artifact.name} has no ${PUBLIC_DISPATCH_FN_NAME}`);

  // Upstream's own factories, with `PublicKeys.default()` supplied rather than derived — M29's
  // DD-11 finding: the vendored wrapper's `deriveKeys` reaches grumpkin and, in a page, the whole
  // proving stack. This contract is public-only and has no keys.
  const contractClass = await makeContractClassPublic(seed, dispatch.bytecode);
  const constructorAbi = getContractFunctionAbi('constructor', artifact);
  const initializationHash = await computeInitializationHash(constructorAbi, []);
  const contractInstance = await makeContractInstanceFromClassId(contractClass.id, seed, {
    deployer,
    initializationHash,
    immutablesHash: new Fr(seed + 3),
    publicKeys: PublicKeys.default(),
  });

  const dataSource = new SimpleContractDataSource();
  await dataSource.addNewContract(artifact, contractClass, contractInstance);

  // THE MERKLE TRIPWIRE, M26's, unchanged in intent: the vendored builder's one removed dependency
  // is `MerkleTreeWriteOperations`, and a proxy that throws on every access executes that claim
  // instead of asserting it.
  const merkleTouches: string[] = [];
  const merkleTripwire = new Proxy({}, {
    get(_t, p) { merkleTouches.push(`get:${String(p)}`); throw new Error(`the builder read merkleTree.${String(p)}`); },
    has(_t, p) { merkleTouches.push(`has:${String(p)}`); throw new Error(`the builder asked '${String(p)}' in merkleTree`); },
    ownKeys() { merkleTouches.push('ownKeys'); throw new Error('the builder enumerated merkleTree'); },
  });

  // THE ARGUMENT LIST IS DERIVED FROM THE ARTIFACT'S OWN ABI, never typed in. Upstream's
  // `ArgumentEncoder` refuses an arity mismatch by name — `Function 'public_dispatch' expects 1
  // argument(s) but received 0` — which is the right behaviour and is also how a driver that
  // hard-codes `[]` stops working the moment a fixture's signature changes. One zero Field per
  // declared parameter: `public_dispatch`'s single parameter is the SELECTOR, which the tester
  // itself puts in calldata field 0, so what is passed here is padding the AVM never reads.
  const calledAbi = getContractFunctionAbi(fnName, artifact);
  const parameterCount = calledAbi?.parameters?.length ?? 0;
  const args = opts.args ?? new Array(parameterCount).fill(0);

  const tester = new PublicTxSimulationTester(merkleTripwire as never, dataSource);
  const tx = await tester.createTx(sender, [], [
    { address: contractInstance.address, fnName, args },
  ]);
  const selector = await getFunctionSelector(fnName, artifact);

  // ---- the world -------------------------------------------------------------------------
  const contractDbHandle = reactor.createContractDb();
  const merkleDbHandle = reactor.createMerkleDb();
  try {
    const merkleDb = new ResidentMerkleWriteOperations(reactor as never, merkleDbHandle);
    const contractsDb = new ResidentContractsDB(reactor as never, contractDbHandle);
    const seeding = new ResidentMerkleDb(reactor as never, merkleDbHandle);
    const config = defaultPublicSimulatorConfig();
    const globals = armGlobals();
    const simulator = new WasmAvmPublicTxSimulator(
      {
        simulate: (input, c, m) => reactor.simulate(input, c, m),
        get moduleCalls() { return reactor.moduleCalls; },
      },
      { contractDb: contractDbHandle, merkleDb: merkleDbHandle },
      globals,
      // `collectExecutionSteps: true` — M9's observer, through M29's declared option door. Without
      // it `avm_steps_count()` is 0 and "the transaction executed N instructions" has no source.
      (t, g) => encodeForShippedModuleOnly(t, g, config, residentWorldStateRevision(1), {
        collectExecutionSteps: true,
      }),
      () => decodePublicTxResult(reactor.result()!),
    );

    const runtime = AvmRuntime.create(
      {
        merkleDb,
        contractsDb,
        makeProcessor: (g: GlobalVariables) =>
          createBlockProcessor(g, merkleDb, contractsDb, simulator, new DateProvider()),
        clock: new ManualDateProvider(0),
        publicDataTree: seeding,
      } as never,
      { production: { intervalMs: 0 }, disclosureSink: () => {} },
    );

    const registered = await runtime.registerContract(contractClass, contractInstance);

    // THE DEPLOYMENT NULLIFIER, without which the AVM executes exactly ONE instruction and reports
    // the transaction `processed`. M29's finding; upstream's own derivation.
    const deploymentNullifier = await siloNullifier(
      await AztecAddress.fromNumber(CONTRACT_INSTANCE_REGISTRY_CONTRACT_ADDRESS),
      contractInstance.address.toField(),
    );
    seeding.insertNullifier(deploymentNullifier);

    const feePayer = (tx as never as { data: { feePayer: AztecAddress } }).data.feePayer;
    await runtime.fundFeeJuice(feePayer, M31_FUNDING);

    const calldataAll = (tx as never as { publicFunctionCalldata: { values: Fr[] }[] }).publicFunctionCalldata;
    const callsBefore = reactor.moduleCalls;
    const receipt = await runtime.submitExternal(tx as never);
    const block = await runtime.produceBlock();
    const settled = runtime.receiptFor(receipt.txHash);

    // M12's own export, read after the simulation. `null` when the module does not carry it, which
    // is an honest absence rather than a zero that reads like "it executed nothing".
    let instructionsExecuted: number | null = null;
    if (typeof reactor.exports?.avm_steps_count === 'function') {
      instructionsExecuted = (reactor.exports.avm_steps_count as () => number)();
    }

    const processedTx = (
      (block as never as { processed?: readonly {
        hash: { toString(): string };
        revertCode: { getCode(): number; getDescription(): string };
        revertReason?: { message?: string } | undefined;
      }[] } | null)?.processed ?? []
    ).find(p => p.hash.toString() === receipt.txHash);

    if (merkleTouches.length > 0) {
      throw new Error(`the vendored builder touched merkleTree: ${merkleTouches.join(', ')}`);
    }

    return {
      fixture: opts.fixture,
      bytecodeProvenance: opts.bytecodeProvenance,
      artifactName: artifact.name,
      artifactSha256: opts.artifactSha256,
      dispatchBytecodeBytes: dispatch.bytecode.length,
      contractClassId: contractClass.id.toString(),
      contractAddress: contractInstance.address.toString(),
      registeredClasses: registered.classes,
      registeredInstances: registered.instances,
      deploymentNullifier: deploymentNullifier.toString(),
      calledFunction: fnName,
      calledSelector: selector.toString(),
      debugFunctionName: await dataSource.getDebugFunctionName(contractInstance.address, selector),
      calldataFields: calldataAll[0]?.values.length ?? 0,
      parameterCount,
      calldataSelector: calldataAll[0]?.values[0]?.toString() ?? 'NONE',
      txHash: receipt.txHash,
      feePayer: feePayer.toString(),
      outcome:
        typeof settled.outcome === 'string'
          ? settled.outcome
          : String((settled.outcome as { kind?: string } | null)?.kind ?? JSON.stringify(settled.outcome)),
      blockNumber: block?.number ?? null,
      revertCode: processedTx === undefined ? null : processedTx.revertCode.getCode(),
      revertDescription: processedTx === undefined ? null : processedTx.revertCode.getDescription(),
      revertReason: processedTx?.revertReason?.message ?? null,
      instructionsExecuted,
      moduleCalls: reactor.moduleCalls - callsBefore,
      simulated: settled.simulated,
      proving: settled.proving,
    };
  } finally {
    reactor.destroyMerkleDb(merkleDbHandle);
    reactor.destroyContractDb(contractDbHandle);
  }
}
