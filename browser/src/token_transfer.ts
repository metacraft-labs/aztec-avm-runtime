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
import { computePublicDataTreeLeafSlot, deriveStorageSlotInMap, siloNullifier } from '@aztec/stdlib/hash';
import { poseidon2HashWithSeparator } from '@aztec/foundation/crypto/poseidon';
import { CONTRACT_INSTANCE_REGISTRY_CONTRACT_ADDRESS, DomainSeparator } from '@aztec/constants';

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

/** Public token balance credited to the sender. Fee juice is not tokens; see below. */
export const DEMO_TOKEN_BALANCE = 1_000n;

/** How many tokens the demo transfers. Less than {@link DEMO_TOKEN_BALANCE}, deliberately. */
export const DEMO_TRANSFER_AMOUNT = 5n;

/**
 * THE NAMES THIS DRIVER USES, AS A PARAMETER RATHER THAN AS CONSTANTS.
 *
 * Everything below defaults to the demo Token's vocabulary, so `runTokenTransfer(opened, raw)`
 * behaves exactly as it did. The parameter exists because the vocabulary turned out to be a
 * property of ONE contract rather than of tokens: the `SimpleToken` in
 * `aztec-packages/noir-projects/labs/noir-contracts` — the contract the browser compile gate
 * compiles — names the same functions
 *
 *   transfer_in_public  ->  __aztec_nr_internals__public_transfer
 *   balance_of_public   ->  __aztec_nr_internals__public_balance_of
 *   constructor         ->  __aztec_nr_internals__constructor   (3 args, not 4)
 *   public_balances     ->  balances
 *
 * because it is built against a later `aztec-nr`, whose macros prefix generated entry points.
 * With the names inlined, this driver could only ever run the one artifact it was written for,
 * and "the contract the tab compiled executes" would have been unreachable without a second
 * copy of these 300 lines — which is the "two instruments" shape this campaign refuses
 * elsewhere.
 *
 * THE ARGUMENT SHAPES ARE NOT PARAMETERS, deliberately. `transfer(from, to, amount, nonce)` and
 * `balance_of(owner)` are asserted against the ABI by `createTx`, and a contract whose transfer
 * took different arguments is not a different NAME for this transaction — it is a different
 * transaction, and it should need a different driver rather than a wider option bag.
 */
export interface TokenVocabulary {
  /** The public state-changing call. */
  readonly transferFunction?: string;
  /** The `#[view]` read enqueued second. */
  readonly balanceFunction?: string;
  /** The initializer, whose ABI and arguments fix the initialization hash. */
  readonly constructorFunction?: string;
  /** The initializer's arguments, in ABI order. */
  readonly constructorArgs?: readonly unknown[];
  /** The `Storage` member holding the public balance map. */
  readonly balancesStorageMember?: string;
}

const DEFAULT_VOCABULARY = {
  transferFunction: TRANSFER_FUNCTION,
  balanceFunction: BALANCE_FUNCTION,
  constructorFunction: 'constructor',
  balancesStorageMember: 'public_balances',
} as const;

/**
 * A named storage slot, read out of the ARTIFACT rather than typed in.
 *
 * `outputs.globals.storage` is Noir's own comptime rendering of the contract's `Storage` struct:
 * a list of `{ name, value: { fields: [{ name: 'slot', value: { kind: 'integer', value: <hex> } }] } }`.
 * It is not `storage_layout` — that key does not exist in this artifact, which is why the first
 * draft of this function found `null` and would have needed a constant.
 *
 * It THROWS when the name is absent. A slot that silently defaulted to zero would put the balance
 * in the wrong leaf and produce a transaction that reverts for a reason nobody could see, which is
 * the failure this whole milestone is about.
 */
export function storageSlotOf(rawArtifact: unknown, name: string): Fr {
  const globals = (rawArtifact as { outputs?: { globals?: { storage?: unknown[] } } }).outputs?.globals?.storage;
  const entries = Array.isArray(globals) && globals.length > 0
    ? ((globals[0] as { fields?: { name: string; value: unknown }[] }).fields ?? [])
    : [];
  const fieldsEntry = entries.find(e => e.name === 'fields');
  const members = ((fieldsEntry?.value as { fields?: { name: string; value: unknown }[] } | undefined)?.fields) ?? [];
  const member = members.find(m => m.name === name);
  if (member === undefined) {
    throw new Error(
      `the artifact's outputs.globals.storage declares no member named '${name}'; it declares `
        + `[${members.map(m => m.name).join(', ')}]`,
    );
  }
  const slotField = ((member.value as { fields?: { name: string; value: { value?: string } }[] }).fields ?? [])
    .find(f => f.name === 'slot');
  const hex = slotField?.value?.value;
  if (typeof hex !== 'string') {
    throw new Error(`the artifact's storage member '${name}' carries no integer slot value`);
  }
  return new Fr(BigInt(`0x${hex}`));
}

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
  /**
   * The two public balance leaves this transfer moves, read off the page's own world state.
   *
   * `before` is taken after the seeding and before the transaction; `after` once the block has been
   * produced. Both ends are reported because a single after-reading is satisfied by a seeding
   * nobody spent, and the recipient's absence before is what says the amount ARRIVED. See the
   * derivation at the read site.
   */
  readonly balances: {
    readonly senderLeaf: string;
    readonly receiverLeaf: string;
    readonly seeded: string;
    readonly transferred: string;
    /** `EMPTY` when the leaf is not in the tree; never `null` — see the read site. */
    readonly before: { readonly sender: string; readonly receiver: string };
    readonly after: { readonly sender: string; readonly receiver: string };
  };
  /** The contract-address nullifier that makes the instance CALLABLE. M29; see below. */
  readonly deploymentNullifier: string;
  readonly enqueuedPublicCalls: number;
  /** What the block did with it: `processed`, `failed` or `queued`. Descriptive, never asserted here. */
  readonly outcome: string;
  /** The whole outcome record, so a check can read a reason rather than a word. */
  readonly outcomeRecord: unknown;
  /**
   * UPSTREAM'S OWN `ProcessedTx.revertCode`. 0 is `RevertCodeEnum.OK`; 1 is `REVERTED`.
   *
   * ===========================================================================================
   * ADDED BY M29's REVIEW, AND THE REASON IS THE MILESTONE'S OWN HEADLINE ONE STEP FURTHER ON.
   * ===========================================================================================
   *
   * M29 found that M27's demo transaction reverted at its first instruction and that nothing could
   * see it. Four seeding gaps were closed — and no assertion was added that would notice a FIFTH.
   * Measured by this review: remove `isStaticCall` from the `#[view]` call, which is seeding gap 4
   * exactly, and the transaction runs 471 instructions across two contexts, ends on `REVERT_8` and
   * reports `processed` — while `just verify-m29` is **105 of 105 green**, and so are
   * `smoke_browser_token_transfer` and the product-claim check. Every floor M29 added (>= 100
   * steps, >= 2 contexts, no sentinel opcode, >= 1 positioned) is satisfied by a transaction that
   * runs and then reverts.
   *
   * `outcome` cannot answer this and is not wrong to be unable to: `processed` is UPSTREAM's
   * vocabulary for "the public processor turned it into a `TxEffect`", and a reverted transaction
   * is still processed and still pays its fee — `@aztec/stdlib`'s `ProcessedTx` carries
   * `revertCode` and `revertReason` precisely because the two facts are different.
   * `TxOutcomeRecord` in `orchestration/src/chain.ts` has no revert dimension, so this is read off
   * upstream's `ProcessedTx` in the sealed block, matched by transaction hash.
   *
   * `null` means the block carries no `ProcessedTx` for this hash — which is a failure to measure
   * and is asserted against, not an absence that reads as a pass.
   */
  readonly revertCode: number | null;
  /** `RevertCode.getDescription()`, so a red assertion carries a sentence. */
  readonly revertDescription: string | null;
  /** `ProcessedTx.revertReason`'s message, when the AVM supplied one. */
  readonly revertReason: string | null;
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
  vocabulary: TokenVocabulary = {},
): Promise<TokenTransferReport> {
  const artifact = loadContractArtifact(rawArtifact as never);
  const deployer = await AztecAddress.fromNumber(4242);
  const sender = await AztecAddress.fromNumber(1001);

  const transferFunction = vocabulary.transferFunction ?? DEFAULT_VOCABULARY.transferFunction;
  const balanceFunction = vocabulary.balanceFunction ?? DEFAULT_VOCABULARY.balanceFunction;
  const constructorFunction =
    vocabulary.constructorFunction ?? DEFAULT_VOCABULARY.constructorFunction;
  const balancesStorageMember =
    vocabulary.balancesStorageMember ?? DEFAULT_VOCABULARY.balancesStorageMember;
  // The demo Token's initializer takes (deployer, name, symbol, decimals); this default is what
  // it always passed. A caller with a different initializer supplies its own, and the ABI it is
  // hashed against is looked up under `constructorFunction`, so the two cannot disagree.
  const constructorArgs = vocabulary.constructorArgs ?? [deployer, 'Tok', 'TOK', 18];

  // REFUSED BY NAME, HERE, rather than at the point of use. A missing function surfaces later as
  // a selector computed over `undefined` or a transaction that reverts for a reason that looks
  // like the contract's fault; this says which name was not found, in a contract that lists what
  // it does have.
  for (const [role, name] of [['transfer', transferFunction], ['balance', balanceFunction]]) {
    if (getContractFunctionAbi(name, artifact) === undefined) {
      const available = artifact.functions.map(f => f.name).join(', ');
      throw new Error(
        `${artifact.name} has no ${role} function named \`${name}\`. It has: ${available}`);
    }
  }

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
  const constructorAbi = getContractFunctionAbi(constructorFunction, artifact);
  const initializationHash = await computeInitializationHash(constructorAbi, constructorArgs as never[]);
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
      fnName: transferFunction,
      args: [sender, deployer, DEMO_TRANSFER_AMOUNT, new Fr(0)],
    },
    // STATIC, AND THE STREAM IS WHY. `balance_of_public` is `#[view]`, and aztec-nr's generated
    // dispatch for a view function asserts the call is static — the executed stream ended on
    // `GETENVVAR_16`, `JUMPI_32`, `INTERNALCALL`, `REVERT_8` inside context 2 until this flag was
    // set. Another thing that could not be seen while the steps were the artifact's debug map.
    { address: contractInstance.address, fnName: balanceFunction, args: [sender], isStaticCall: true },
  ]);

  const transferSelector = await getFunctionSelector(transferFunction, artifact);
  const balanceSelector = await getFunctionSelector(balanceFunction, artifact);
  const transferAbi = getContractFunctionAbi(transferFunction, artifact);
  if (transferAbi === undefined) {
    throw new Error(`${artifact.name} has no ${transferFunction} in its ABI`);
  }

  const registered = await opened.runtime.registerContract(contractClass, contractInstance);

  // ===========================================================================================
  // THE DEPLOYMENT NULLIFIER, AND WITHOUT IT THE AVM EXECUTES EXACTLY ONE INSTRUCTION.
  // ===========================================================================================
  //
  // FOUND BY M29, BY LOOKING AT THE EXECUTED STEP STREAM FOR THE FIRST TIME. Registering the class
  // and the instance puts the bytecode in the module's resident contract DB, and that is not what
  // makes an address CALLABLE: the AVM decides a contract exists by looking for its address
  // nullifier — `siloNullifier(CONTRACT_INSTANCE_REGISTRY_CONTRACT_ADDRESS, address)` — in the
  // nullifier tree, and answers an undeployed address with no bytecode at all. The symptom is
  // silent in every field M27 asserted: the block still reports the transaction `processed`,
  // because "processed" is the BLOCK's verdict and a revert is a legitimate outcome inside it.
  // What it actually did, measured through M9's hook, was ONE step — `pc=0`, opcode 68, which is
  // M9's `LAST_OPCODE_SENTINEL` for "read_instruction threw before the opcode was known" — a
  // `revertCode` of 1, and `stats["total_instructions_executed"] == 1`.
  //
  // This is exactly the gap M29 exists to close, one level further back than expected: M27's
  // container did not merely FABRICATE its opcodes, it fabricated them over a transaction that had
  // not run. Nothing could see it while the steps were synthesised from the artifact's debug map,
  // because that map is a property of the artifact and not of the execution.
  //
  // The derivation is upstream's own, and it is the same one the vendored
  // `createContractClassAndInstance` performs at `orchestration/src/vendor/avm_fixtures_utils.ts:111`
  // — which this file deliberately does not call, for the `deriveKeys`/DD-11 reason above. It is
  // spelled out here rather than reached through that helper so the two crypto calls a page makes
  // stay visible; `verify_public_only_page_never_fetches_barretenberg` is what would notice if
  // either of them reached the proving stack.
  const deploymentNullifier = await siloNullifier(
    await AztecAddress.fromNumber(CONTRACT_INSTANCE_REGISTRY_CONTRACT_ADDRESS),
    contractInstance.address.toField(),
  );
  opened.publicDataTree.insertNullifier(deploymentNullifier);

  // ===========================================================================================
  // AND THE PUBLIC INITIALIZATION NULLIFIER, WITHOUT WHICH THE DISPATCH REVERTS AFTER 175 STEPS.
  // ===========================================================================================
  //
  // The second thing the executed stream showed, and it is a different fact from the first. With
  // the deployment nullifier alone the AVM runs `Token.public_dispatch` properly — 175 instructions,
  // nineteen distinct opcodes — and then ends on `NULLIFIEREXISTS`, `JUMPI_32`, `INTERNALCALL`,
  // `REVERT_8`. That tail is `assert_is_initialized_public`, which every `#[public]` function of a
  // contract with an initializer calls unless it is `#[noinitcheck]`:
  //
  //     aztec-nr/aztec/src/macros/functions/initialization_utils.nr
  //       assert(context.nullifier_exists_unsafe(init_nullifier, context.this_address()),
  //              "Not initialized");
  //       fn compute_public_initialization_nullifier(address) =
  //           poseidon2_hash_with_separator([address], DOM_SEP__PUBLIC_INITIALIZATION_NULLIFIER)
  //
  // and the nullifier that ends up in the tree is that value SILOED by the contract that emitted
  // it, because `push_nullifier_unsafe` silos with `this_address`. Both halves are upstream's own
  // functions and upstream's own constant; nothing here re-derives a hash by hand.
  //
  // WHY UPSTREAM'S OWN TESTER DOES NOT DO THIS AND STILL WORKS: `PublicTxSimulationTester` inserts
  // the contract-address nullifier only (`base_avm_simulation_tester.ts:160`), and its corpus is
  // `AvmTest`, which has no initializer, so no dispatch of it asserts initialization. Token does.
  // The demo would have kept reverting for as long as nobody looked at the step stream — which is
  // the whole argument of this milestone.
  //
  // The poseidon2 is the MODULE's (DD-11): `installPoseidon2` ran in `openAvmRuntime`, so this
  // costs a page no barretenberg download, and `verify_public_only_page_never_fetches_barretenberg`
  // is what would notice if it did.
  const publicInitNullifier = await poseidon2HashWithSeparator(
    [contractInstance.address.toField()],
    DomainSeparator.PUBLIC_INITIALIZATION_NULLIFIER,
  );
  const initializationNullifier = await siloNullifier(contractInstance.address, publicInitNullifier);
  opened.publicDataTree.insertNullifier(initializationNullifier);

  // ===========================================================================================
  // AND A TOKEN BALANCE, BECAUSE THE THIRD THING THE STREAM SHOWED WAS AN EMPTY WALLET.
  // ===========================================================================================
  //
  // With both nullifiers seeded the dispatch runs the FUNCTION — 222 instructions, twenty-four
  // distinct opcodes — and ends on `LT_16`, `JUMPI_32`, `INTERNALCALL`, `REVERT_8`: the
  // `assert(balance >= amount)` inside `transfer_in_public`. The sender was funded with FEE JUICE
  // and never with tokens, which is a different tree and a different slot.
  //
  // The slot derivation is upstream's, twice: `deriveStorageSlotInMap(public_balances, sender)`
  // for the map entry and `computePublicDataTreeLeafSlot(contract, slot)` for the siloed leaf. The
  // map's slot — 5 — is read out of the ARTIFACT's own `outputs.globals.storage` rather than typed
  // in, because a slot typed in here is a constant that drifts away from the contract silently and
  // this campaign has a rule about exactly that.
  const publicBalancesSlot = storageSlotOf(rawArtifact, balancesStorageMember);
  const senderBalanceSlot = await deriveStorageSlotInMap(publicBalancesSlot, sender);
  const senderBalanceLeaf = await computePublicDataTreeLeafSlot(contractInstance.address, senderBalanceSlot);
  opened.publicDataTree.insertPublicDataLeaf(senderBalanceLeaf, new Fr(DEMO_TOKEN_BALANCE));
  // AND THE RECIPIENT'S LEAF, WHICH IS NOT SEEDED. It is derived by the same two upstream
  // functions so that the read-back below has both ends of the transfer, and it is deliberately
  // left EMPTY before the transaction: a recipient balance that existed beforehand would make
  // "the receiver holds the transferred amount" satisfiable by the seeding.
  const receiverBalanceSlot = await deriveStorageSlotInMap(publicBalancesSlot, deployer);
  const receiverBalanceLeaf = await computePublicDataTreeLeafSlot(contractInstance.address, receiverBalanceSlot);
  // `EMPTY` RATHER THAN `null`, AND THE REASON IS THE ACCESSOR. `m27_arm` prints `MISSING` for a
  // JSON `null`, which is the same word it prints for a field that is not in the report at all —
  // so a leaf that is genuinely absent from the tree would be indistinguishable from a driver that
  // forgot to report it. That is `CAMPAIGN-BRIEF.md`'s "two missing keys agreeing", and the remedy
  // is a value the tree can produce and the reporter cannot.
  const leaf = (slot: Fr) => opened.publicDataTree.readPublicDataLeaf(slot) ?? 'EMPTY';
  const balancesBefore = { sender: leaf(senderBalanceLeaf), receiver: leaf(receiverBalanceLeaf) };

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

  // WHETHER IT REVERTED, from upstream's own `ProcessedTx` in the sealed block. See the field
  // documentation on `TokenTransferReport.revertCode`: `outcome` is the BLOCK's verdict and says
  // nothing about this, by upstream's design, and a transaction that reverts after 471 real
  // instructions passes every floor this milestone added.
  const processedTx = (
    (block as never as { processed?: readonly {
      hash: { toString(): string };
      revertCode: { getCode(): number; getDescription(): string };
      revertReason?: { message?: string } | undefined;
    }[] } | null)?.processed ?? []
  ).find(p => p.hash.toString() === receipt.txHash);

  // ===========================================================================================
  // THE BALANCE LEAVES, READ BACK OFF THIS TRANSFER'S OWN WORLD STATE.
  // ===========================================================================================
  //
  // M25's `e2e_trace_token_transfer_steppable` names two missing pieces, and this is the second:
  // "the sender's balance leaf read back after the transfer". A Node-side read-back through the
  // contract's own `balance_of_public` exists (`e2e_ts_wasm_token_transfer`) and does NOT answer
  // it — that is a different world state, in a different process, over a different transaction.
  // This one is the tree the page's own block wrote into.
  //
  // It is the LEAF and not a view call, deliberately. `balance_of_public` would be a second
  // enqueued call and therefore a second thing that can fail; the leaf is what the transfer
  // actually moved, addressed by upstream's own `computePublicDataTreeLeafSlot` over upstream's
  // own `deriveStorageSlotInMap`, and read through M34's `readPublicDataLeaf`, which compares the
  // decoded slot against the requested one so that a misspelled msgpack key cannot read as
  // "the slot is empty".
  //
  // BEFORE and AFTER are both reported. A single after-reading is satisfied by a seeding nobody
  // spent, and the recipient's absence BEFORE is what says the amount arrived rather than having
  // been there all along.
  const balancesAfter = { sender: leaf(senderBalanceLeaf), receiver: leaf(receiverBalanceLeaf) };

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
    balances: {
      senderLeaf: senderBalanceLeaf.toString(),
      receiverLeaf: receiverBalanceLeaf.toString(),
      seeded: DEMO_TOKEN_BALANCE.toString(),
      transferred: DEMO_TRANSFER_AMOUNT.toString(),
      before: balancesBefore,
      after: balancesAfter,
    },
    deploymentNullifier: deploymentNullifier.toString(),
    enqueuedPublicCalls: calldataAll.length,
    // The word, and the record beside it. `String(record)` is `[object Object]`, which is what the
    // first version of this reported: a field that looked like a measurement and carried nothing.
    outcome:
      typeof settled.outcome === 'string'
        ? settled.outcome
        : String((settled.outcome as { kind?: string } | null)?.kind ?? JSON.stringify(settled.outcome)),
    outcomeRecord: settled.outcome,
    revertCode: processedTx === undefined ? null : processedTx.revertCode.getCode(),
    revertDescription: processedTx === undefined ? null : processedTx.revertCode.getDescription(),
    revertReason: processedTx?.revertReason?.message ?? null,
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
