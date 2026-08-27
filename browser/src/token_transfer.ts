// A token transfer, in a browser, end to end.
//
// THE BLOCKER THIS SITS ON TOP OF WAS REMOVED IN M26 AND NOT HERE. Every milestone from M22
// onwards recorded the same gap: "a transaction that calls a REGISTERED CONTRACT needs a builder,
// and upstream's only one constructs a `NativeWorldStateService`" — the package DD-9 forbids. M26
// vendored it (RI-72, 880 lines, `PROVENANCE.md` F20–F24) with the world-state dependency replaced
// by a tripwire proxy that throws on any access, and proved the builder never touches it. So this
// file composes what is already there rather than building anything:
//
//   `createContractClassAndInstance` + `SimpleContractDataSource` + `PublicTxSimulationTester`
//        — vendored upstream, M26's RI-72, used exactly as `join_e2e_driver.ts` uses them
//   `AvmRuntime.registerContract` / `fundFeeJuice` / `submitExternal` / `produceBlock`
//        — M23's facade, unchanged
//
// WHAT IS NEW HERE IS THE EXECUTION. M26 BUILT the transaction and did not run it: `run_join_arms`
// takes the artifact's first N mapped program counters rather than the ones an execution visited,
// and says so. This runs it — through `avm.wasm`, in a page, against a resident world state — and
// reports what the AVM did with it rather than asserting in advance what that will be.
//
// THE REPORT IS DESCRIPTIVE ON PURPOSE. `outcome` is whatever the block recorded. A driver that
// threw unless the transfer succeeded would be a driver that hides the interesting cases, and this
// campaign has a recorded defect for exactly that shape — a probe that read a reader-refused
// container green. What the smoke test asserts is that the transaction reached the AVM, dispatched
// by an ABI-derived selector to the function named in the artifact, and was placed in a block.

import { Fr } from '@aztec/foundation/curves/bn254';
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { loadContractArtifact } from '@aztec/stdlib/abi';

import { PublicKeys } from '@aztec/stdlib/keys';
import { computeInitializationHash } from '@aztec/stdlib/contract';
import { makeContractClassPublic, makeContractInstanceFromClassId } from '@aztec/stdlib/testing';

import {
  PUBLIC_DISPATCH_FN_NAME,
  getContractFunctionAbi,
  getContractFunctionArtifact,
  getFunctionSelector,
} from '../../orchestration/src/vendor/avm_fixtures_utils.ts';
import { PublicTxSimulationTester } from '../../orchestration/src/vendor/public_tx_simulation_tester.ts';
import { SimpleContractDataSource } from '../../orchestration/src/vendor/simple_contract_data_source.ts';

import type { OpenedRuntime } from './runtime.ts';

/** The public function the demo calls. Real calldata, real ABI-derived selector. */
export const TRANSFER_FUNCTION = 'transfer_in_public';
/** The second enqueued call — a READ, so the transaction exercises two functions and not one. */
export const BALANCE_FUNCTION = 'balance_of_public';

/** Fee juice credited to the sender before the transaction. M20's shortcut, DD-2. */
export const DEMO_FUNDING = new Fr(10n ** 12n);

export interface TokenTransferReport {
  readonly artifactName: string;
  readonly contractAddress: string;
  readonly contractClassId: string;
  readonly registeredClasses: number;
  readonly registeredInstances: number;
  /** `transfer_in_public`'s selector, derived from the artifact's ABI and not typed in. */
  readonly transferSelector: string;
  readonly balanceSelector: string;
  /** The selector the AVM actually receives, i.e. calldata field 0 of each enqueued call. */
  readonly calldataSelectors: readonly string[];
  readonly calldataFields: readonly number[];
  /** Upstream's own `<Artifact>.<fn>`, from `SimpleContractDataSource.getDebugFunctionName`. */
  readonly debugFunctionNames: readonly (string | undefined)[];
  readonly txHash: string;
  readonly feePayer: string;
  readonly fundedLeafSlot: string;
  readonly enqueuedPublicCalls: number;
  /** What the block did with it: `processed`, `failed` or `queued`. Descriptive, never asserted here. */
  readonly outcome: string;
  /** The whole outcome record, so a check can read a reason rather than a word. */
  readonly outcomeRecord: unknown;
  readonly blockNumber: number | null;
  readonly blockTxHashes: readonly string[];
  /** §8.4, off the receipt the caller would show somebody else. */
  readonly simulated: boolean;
  readonly protocolVersion: string;
  readonly proving: string;
  /** Calls into `avm.wasm` this transaction cost, as a difference of two readings. */
  readonly moduleCalls: number;
  /** Calls into the module's poseidon2 during submission and block production. */
  readonly poseidonCalls: number;
  /**
   * Calls into the module's poseidon2 for the WHOLE run, building the transaction included.
   *
   * The delta above is small because most of the hashing happens BEFORE submission — deriving the
   * contract class id, the contract address, the function selectors and the transaction hash. A
   * check that read only the delta would be reading a number that says almost nothing about
   * whether the page hashed with `avm.wasm` or with bb.js, which is the question DD-11 asks.
   */
  readonly poseidonCallsTotal: number;
  /** Calls into the module's grumpkin. Address derivation is two of them. */
  readonly grumpkinCallsTotal: number;
}

/**
 * Register the Token contract, fund a sender, submit a transaction calling it, seal a block.
 *
 * `rawArtifact` is already-parsed JSON, for `buildJoinTransaction`'s reason: the SEARCH for it
 * crosses `node_modules` roots on two different `@aztec` nightly lines in Node and is a `fetch` in
 * a browser, and neither belongs in here.
 */
export async function runTokenTransfer(
  opened: OpenedRuntime,
  rawArtifact: unknown,
): Promise<TokenTransferReport> {
  const artifact = loadContractArtifact(rawArtifact as never);
  const deployer = await AztecAddress.fromNumber(4242);
  const sender = await AztecAddress.fromNumber(1001);

  // ===========================================================================================
  // THE FIXTURE INSTANCE IS BUILT WITH `PublicKeys.default()`, AND THAT IS DD-11 AGAIN.
  // ===========================================================================================
  //
  // The vendored `createContractClassAndInstance` (RI-72) is upstream's, and its second line is
  // `deriveKeys(new Fr(seed))`. Measured on this path before the redirect table was tightened:
  // `deriveKeys` reaches `@aztec/foundation/crypto/grumpkin`, which calls
  // `BarretenbergSync.initSingleton()` — and the public-only page fetched
  // `chunks/barretenberg-*.js` and its 7.9 MB data: URL, in the browser's own network log, for a
  // key derivation. Poseidon was not the only route to the proving stack; GRUMPKIN is the other,
  // and nothing had looked for it because the Form A measurement that found poseidon never built a
  // contract instance.
  //
  // The composition below is upstream's own factories — `makeContractClassPublic`,
  // `computeInitializationHash`, `makeContractInstanceFromClassId`, all from `@aztec/stdlib` —
  // with ONE argument supplied that the vendored wrapper computes instead: `publicKeys`.
  // `PublicKeys.default()` is upstream's constant for an account with no keys, precomputed in
  // `constants.gen.ts` and self-tested against the underlying points in `public_keys.nr`. It is
  // the honest value here: this instance is a PUBLIC contract in a page with no private half, and
  // `JOIN-SHAPE.md` §6 records that a private half that actually executes is not something this
  // runtime has.
  //
  // The vendored wrapper is NOT edited — `check-drift` compares it against the `ts` anchor on every
  // run and M22's classifier pins its diff line by line. What changed is which of its two jobs this
  // caller wants: the transaction is still built by the vendored `PublicTxSimulationTester` below,
  // which is the half M26 vendored it for.
  const dispatch = getContractFunctionArtifact(PUBLIC_DISPATCH_FN_NAME, artifact);
  if (dispatch === undefined) throw new Error(`${artifact.name} has no ${PUBLIC_DISPATCH_FN_NAME}`);
  const contractClass = await makeContractClassPublic(27, dispatch.bytecode);
  const constructorAbi = getContractFunctionAbi('constructor', artifact);
  const initializationHash = await computeInitializationHash(constructorAbi, [deployer, 'Tok', 'TOK', 18]);
  const contractInstance = await makeContractInstanceFromClassId(contractClass.id, 27, {
    deployer,
    initializationHash,
    immutablesHash: new Fr(28),
    publicKeys: PublicKeys.default(),
  });

  const dataSource = new SimpleContractDataSource();
  await dataSource.addNewContract(artifact, contractClass, contractInstance);

  // THE SAME TRIPWIRE M26 USED, AND FOR THE SAME REASON. The vendored builder's one removed
  // dependency is `MerkleTreeWriteOperations`; the proxy throws on every access, so "the builder
  // never touches a world state" fails loudly here rather than being a claim in a document.
  const merkleTouches: string[] = [];
  const merkleTripwire = new Proxy(
    {},
    {
      get(_t, p) {
        merkleTouches.push(`get:${String(p)}`);
        throw new Error(`the vendored transaction builder read merkleTree.${String(p)}`);
      },
      has(_t, p) {
        merkleTouches.push(`has:${String(p)}`);
        throw new Error(`the vendored transaction builder asked '${String(p)}' in merkleTree`);
      },
      ownKeys() {
        merkleTouches.push('ownKeys');
        throw new Error('the vendored transaction builder enumerated merkleTree');
      },
    },
  );

  const tester = new PublicTxSimulationTester(merkleTripwire as never, dataSource);
  const tx = await tester.createTx(sender, [], [
    {
      address: contractInstance.address,
      fnName: TRANSFER_FUNCTION,
      args: [sender, deployer, 5n, new Fr(0)],
    },
    { address: contractInstance.address, fnName: BALANCE_FUNCTION, args: [sender] },
  ]);

  const transferSelector = await getFunctionSelector(TRANSFER_FUNCTION, artifact);
  const balanceSelector = await getFunctionSelector(BALANCE_FUNCTION, artifact);
  const transferAbi = getContractFunctionAbi(TRANSFER_FUNCTION, artifact);
  if (transferAbi === undefined) {
    throw new Error(`${artifact.name} has no ${TRANSFER_FUNCTION} in its ABI`);
  }

  const registered = await opened.runtime.registerContract(contractClass, contractInstance);

  // The fee payer is the transaction's own, read off the transaction rather than assumed: funding
  // a different address is how a transaction comes to fail for insufficient funds with the funding
  // "done", which `fee_juice.ts` warns about at length.
  const feePayer = (tx as never as { data: { feePayer: AztecAddress } }).data.feePayer;
  const fundedLeafSlot = await opened.runtime.fundFeeJuice(feePayer, DEMO_FUNDING);

  const calldataAll = (tx as never as { publicFunctionCalldata: { values: Fr[] }[] })
    .publicFunctionCalldata;

  const callsBefore = opened.reactor.moduleCalls;
  const poseidonBefore = opened.poseidon.calls;
  // `submitExternal` takes a bare `Tx` and wraps it in `externalTx` itself — DD-1: nothing that
  // executes accepts provenance, so there is no provenance for a caller to hand it.
  const receipt = await opened.runtime.submitExternal(tx as never);
  const block = await opened.runtime.produceBlock();
  const settled = opened.runtime.receiptFor(receipt.txHash);

  return {
    artifactName: artifact.name,
    contractAddress: contractInstance.address.toString(),
    contractClassId: contractClass.id.toString(),
    registeredClasses: registered.classes,
    registeredInstances: registered.instances,
    transferSelector: transferSelector.toString(),
    balanceSelector: balanceSelector.toString(),
    calldataSelectors: calldataAll.map(c => c.values[0]!.toString()),
    calldataFields: calldataAll.map(c => c.values.length),
    debugFunctionNames: [
      await dataSource.getDebugFunctionName(contractInstance.address, transferSelector),
      await dataSource.getDebugFunctionName(contractInstance.address, balanceSelector),
    ],
    txHash: receipt.txHash,
    feePayer: feePayer.toString(),
    fundedLeafSlot: fundedLeafSlot.toString(),
    enqueuedPublicCalls: calldataAll.length,
    // The word, and the record beside it. `String(record)` is `[object Object]`, which is what the
    // first version of this reported: a field that looked like a measurement and carried nothing.
    outcome:
      typeof settled.outcome === 'string'
        ? settled.outcome
        : String((settled.outcome as { kind?: string } | null)?.kind ?? JSON.stringify(settled.outcome)),
    outcomeRecord: settled.outcome,
    blockNumber: settled.blockNumber,
    blockTxHashes: block ? [...block.txHashes] : [],
    simulated: settled.simulated,
    protocolVersion: settled.protocolVersion,
    proving: settled.proving,
    moduleCalls: opened.reactor.moduleCalls - callsBefore,
    poseidonCalls: opened.poseidon.calls - poseidonBefore,
    poseidonCallsTotal: opened.poseidon.calls,
    grumpkinCallsTotal: opened.grumpkin.calls,
  };
}
