// token_block_driver.ts — the closeout pass's arms: REAL CONTRACTS, THROUGH REAL BLOCKS.
//
// A DRIVER AND NOT A TEST, the campaign's split since M20: it prints one JSON object and exits 0,
// and every assertion lives in `verification/`. A driver that asserted would have to be trusted
// about its own count.
//
// ---------------------------------------------------------------------------------------------
// WHY THIS FILE EXISTS, AND WHAT IT IS NOT ALLOWED TO BE.
// ---------------------------------------------------------------------------------------------
//
// Seven `pending` verification entries across M18, M22 and M25 carried the same recorded blocker
// for five milestones — "a transaction that calls a REGISTERED CONTRACT needs a builder, and
// upstream's only one constructs a `NativeWorldStateService`". M26 vendored that builder (RI-72,
// `PROVENANCE.md` F20–F23) and the residuals pass of 2026-08-31 measured that the blocker was
// dead. What it deliberately did NOT do is write the checks, and that is what this file feeds.
//
// IT COMPOSES; IT DOES NOT REIMPLEMENT. Every piece below already exists:
//
//   `createContractClassAndInstance`  vendored upstream (RI-72), the class, the instance and the
//                                     contract-address nullifier in one call
//   `PublicTxSimulationTester`        vendored upstream (RI-72), the transaction builder
//   `addNewContractClassToTx` /       vendored upstream (RI-72), the two helpers that put a
//   `addNewContractInstanceToTx`      DEPLOYMENT on a transaction — declared here, called by
//                                     nobody until now, which is what M22's deployment entry said
//   `createBlockProcessor` /          M22's own block assembly, unchanged
//   `assembleBlock` / `sealBlock`
//   `ResidentMerkleWriteOperations` / M14's and M13's resident world state
//   `ResidentContractsDB`
//   `WasmAvmPublicTxSimulator`        M18's simulator over the shipped module
//
// THE RECIPE IS UPSTREAM'S OWN, CALL FOR CALL. `yarn-project/simulator/src/public/fixtures/
// token_test.ts` — vendored into this repository three times over as `diffsim/`, `spike/` and
// `drift/`'s `token_test.ts` (RI-25) — is: deploy, run `constructor`, `mint_to_public`,
// `transfer_in_public`, `burn_public`, and read each balance back through a STATIC
// `balance_of_public` whose return value is compared. This driver runs that sequence through
// `PublicProcessor` and real blocks instead of through the simulator half RI-72 dropped, and it
// reads the balances back the same way upstream does.
//
// NOTHING HERE DERIVES A STORAGE SLOT BY HAND, and that is deliberate. `browser/src/
// token_transfer.ts` has to — it seeds a balance directly because its page never runs the
// contract's `constructor` — and a second copy of that derivation in this file would be a second
// thing to keep in step with the contract. Here the constructor and the mint RUN, so the balances
// are whatever the contract itself wrote, and they are read back through the contract's own
// `balance_of_public`. *A value read out of the subject beats a value derived beside it.*

import { CONTRACT_INSTANCE_REGISTRY_CONTRACT_ADDRESS, DomainSeparator } from '@aztec/constants';
import { DateProvider } from '@aztec/foundation/timer';
import { poseidon2HashWithSeparator } from '@aztec/foundation/crypto/poseidon';
import { Fr } from '@aztec/foundation/curves/bn254';
import { GasFees } from '@aztec/stdlib/gas';
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { loadContractArtifact } from '@aztec/stdlib/abi';
import { PublicKeys } from '@aztec/stdlib/keys';
import { makeContractClassPublic, makeContractInstanceFromClassId } from '@aztec/stdlib/testing';
import { siloNullifier } from '@aztec/stdlib/hash';
import { GlobalVariables, type Tx } from '@aztec/stdlib/tx';

import { assembleBlock, createBlockProcessor, sealBlock } from './block_assembly.ts';
import { decodePublicTxResult, residentWorldStateRevision } from './avm_inputs.ts';
import { defaultPublicSimulatorConfig, fundFeeJuice } from './fee_juice.ts';
import { encodeForShippedModuleOnly } from './shipped_module_config.ts';
import { ResidentContractsDB } from './resident_contracts_db.ts';
import { ResidentMerkleDb } from './resident_db.ts';
import { ResidentMerkleWriteOperations } from './resident_merkle_operations.ts';
import { WasmAvmPublicTxSimulator } from './wasm_avm_public_tx_simulator.ts';
import { createContractClassAndInstance, getFunctionSelector } from './vendor/avm_fixtures_utils.ts';
import {
  addNewContractClassToTx,
  addNewContractInstanceToTx,
  createTxForPrivateOnly,
} from './vendor/public_fixtures_utils.ts';
import { PublicTxSimulationTester, type TestEnqueuedCall } from './vendor/public_tx_simulation_tester.ts';
import { SimpleContractDataSource } from './vendor/simple_contract_data_source.ts';

export interface ReactorLike {
  createContractDb(): number;
  createMerkleDb(): number;
  destroyContractDb(handle: number): void;
  destroyMerkleDb(handle: number): void;
  callWithBlob(exportName: string, handle: number, blob: Uint8Array): unknown;
  callWithHandle(exportName: string, handle: number): unknown;
  simulate(input: Uint8Array, contractDb: number, merkleDb: number): { revertCode: number; result: unknown };
  result(): Uint8Array | null;
  readonly moduleCalls: number;
  readonly exportNames: readonly string[];
  readonly exports?: Record<string, unknown>;
}

/** Fee juice credited to every account that sends a transaction here. M20's shortcut, DD-2. */
const FUNDING = new Fr(10n ** 12n);

/** Upstream's `tokenTest` amounts, kept so the two recipes are comparable line by line. */
export const MINT_AMOUNT = 100n;
export const TRANSFER_AMOUNT = 50n;

function armGlobals(): GlobalVariables {
  // Non-zero gas fees, for M20's measured reason: with `GlobalVariables.empty()` the transaction
  // fee computes to zero, every balance is sufficient including the empty one, and the unfunded
  // case lands — so a suite built on it would assert fee enforcement while never exercising it.
  const empty = GlobalVariables.empty();
  return GlobalVariables.from({ ...empty, gasFees: new GasFees(1n, 1n) });
}

export interface World {
  readonly merkleDb: ResidentMerkleWriteOperations;
  readonly contractsDb: ResidentContractsDB;
  readonly seeding: ResidentMerkleDb;
  readonly simulator: { simulate(tx: Tx): Promise<unknown> };
  readonly globals: GlobalVariables;
  /** One entry per `simulate` the processor made, in the order it made them. */
  readonly simulations: { readonly steps: number | null; readonly rawRevertCode: number | undefined }[];
  readonly release: () => void;
}

/**
 * One world per arm: fresh module handles, fresh trees, fresh contract store.
 *
 * `collectCallMetadata` is ON because upstream's own balance check reads the app-logic RETURN
 * VALUES, and without it `PublicProcessor` has none to hand back — the balances would then be
 * unobservable and every "the final state is right" assertion would be about the tree roots
 * instead of about the numbers.
 *
 * `collectExecutionSteps` is ON for M29's reason: `avm_steps_count()` is 0 without it, and
 * "the transaction executed N instructions" would have no source. A transaction that reverts at
 * its first instruction reports `processed` too — that is the campaign's deepest recorded defect —
 * so every arm here reports its instruction count and its `revertCode` side by side.
 */
export function openWorld(reactor: ReactorLike, opts: { collectDebugLogs?: boolean } = {}): World {
  const contractDbHandle = reactor.createContractDb();
  const merkleDbHandle = reactor.createMerkleDb();
  const merkleDb = new ResidentMerkleWriteOperations(reactor as never, merkleDbHandle);
  const contractsDb = new ResidentContractsDB(reactor as never, contractDbHandle);
  const seeding = new ResidentMerkleDb(reactor as never, merkleDbHandle);
  const globals = armGlobals();
  const config = defaultPublicSimulatorConfig({
    collectCallMetadata: true,
    collectStatistics: true,
    ...(opts.collectDebugLogs === true ? { collectDebugLogs: true } : {}),
  } as never);
  const simulator = new WasmAvmPublicTxSimulator(
    {
      simulate: (input, c, m) => reactor.simulate(input, c, m),
      get moduleCalls() {
        return reactor.moduleCalls;
      },
    },
    { contractDb: contractDbHandle, merkleDb: merkleDbHandle },
    globals,
    (t, g) =>
      encodeForShippedModuleOnly(t, g, config, residentWorldStateRevision(1), {
        collectExecutionSteps: true,
      }),
    () => decodePublicTxResult(reactor.result()!),
  );

  // THE PER-TRANSACTION INSTRUCTION COUNT, TAKEN AT THE ONE PLACE IT IS STILL ATTRIBUTABLE.
  //
  // `avm_steps_count()` reports the LAST simulation, and `PublicProcessor.process` runs one per
  // transaction inside a loop this caller cannot step. Reading it after the block would give the
  // last transaction's count for every one of them — a number that looks per-transaction and is
  // not. So the simulator is wrapped: the wrapper delegates to M18's own simulator unchanged and
  // reads the counter immediately after each crossing. The processor takes it in the same
  // parameter position, so nothing about the loop changes.
  const simulations: { steps: number | null; rawRevertCode: number | undefined }[] = [];
  const instrumented = {
    async simulate(tx: Tx) {
      const result = await simulator.simulate(tx);
      const counter = reactor.exports?.avm_steps_count;
      simulations.push({
        steps: typeof counter === 'function' ? (counter as () => number)() : null,
        rawRevertCode: simulator.rawRevertCode,
      });
      return result;
    },
    get configuration() {
      return simulator.configuration;
    },
    get moduleCalls() {
      return simulator.moduleCalls;
    },
  };

  return {
    merkleDb,
    contractsDb,
    seeding,
    simulator: instrumented,
    globals,
    simulations,
    release: () => {
      reactor.destroyMerkleDb(merkleDbHandle);
      reactor.destroyContractDb(contractDbHandle);
    },
  };
}

/** What one block did, in the shape every assertion reads. */
export interface BlockRecord {
  readonly label: string;
  readonly submitted: readonly string[];
  readonly processed: readonly string[];
  readonly failed: readonly { label: string; message: string }[];
  readonly unprocessed: readonly string[];
  /** Upstream's `ProcessedTx.revertCode.getCode()` per processed transaction, by label. */
  readonly revertCodes: Readonly<Record<string, number>>;
  readonly revertReasons: Readonly<Record<string, string | null>>;
  /** Per-transaction L2 gas, off upstream's `ProcessedTx.gasUsed.totalGas`. */
  readonly l2GasByTx: Readonly<Record<string, number>>;
  readonly daGasByTx: Readonly<Record<string, number>>;
  /**
   * The fee each processed transaction PAID, off upstream's `TxEffect.transactionFee`.
   *
   * "The transaction still pays its fee" is one of the three sentences M18's phase entry makes,
   * and a gas figure is not that sentence: gas is what was spent, a fee is what was charged. This
   * is the charge.
   */
  readonly feeByTx: Readonly<Record<string, string>>;
  /**
   * The nullifiers each processed transaction's own `TxEffect` carries, by label.
   *
   * THIS IS THE TRANSACTION'S RECORD OF WHAT IT DID, not a probe of the tree afterwards, and the
   * two are different claims. M25's "a reverted nested call contributes no side effects" is about
   * what the transaction EMITTED: a frame that wrote a nullifier and then reverted must leave that
   * nullifier out of this list while the outer frame's stays in it. A later transaction that
   * re-emits the value answers the same question from the tree's side, and the two together are
   * what distinguish "the effect was rolled back" from "nothing ever emitted anything".
   */
  readonly nullifiersByTx: Readonly<Record<string, readonly string[]>>;
  /** Every app-logic return value the block produced, flattened, as decimal strings. */
  readonly returnValues: readonly (readonly string[])[];
  /** What the deferred contract registrations flushed into the module for THIS block. */
  readonly registrations: { readonly classes: number; readonly instances: number };
  /**
   * What the processor and the flush ASKED the contract store to do, counted at the store.
   *
   * `addNewContracts` is the extraction; `registerClass` / `registerInstance` are the module
   * writes the flush performs. Without these, "the deployment was registered" cannot be told from
   * "the processor never looked" — and the two have different remedies.
   */
  readonly contractStoreCalls: { readonly addNewContracts: number; readonly registerClass: number; readonly registerInstance: number };
  readonly stateReferenceAfter: string;
  readonly sealed: boolean;
  /** When the seal was refused, upstream's own refusal, by method name. */
  readonly sealRefusal: string | null;
  /**
   * Instructions the AVM executed per simulation this block made, in the processor's own order.
   *
   * A transaction that reverted at its FIRST instruction reports `processed` — the campaign's
   * deepest recorded defect — so every arm here carries this beside its `revertCode`, and a check
   * that asserts a revert code without asserting a floor here has not asked whether the subject
   * did anything.
   */
  readonly instructionsPerSimulation: readonly (number | null)[];
  /** The module's own four-valued revert code per simulation, before upstream's type narrows it. */
  readonly rawRevertCodes: readonly (number | null)[];
  /**
   * The checkpoint depth after the block — which is a CONSEQUENCE and not the claim.
   *
   * A store that never forked reads zero here too, so the depth on its own is satisfied by the
   * absence of the thing it is about. `checkpoints` below is the conservation law that makes it a
   * measurement: some were created, and every one was closed exactly once.
   */
  readonly checkpointDepthAfter: { readonly contracts: number };
  /** Every checkpoint call the block made on the contract store, counted at the store. */
  readonly checkpoints: { readonly created: number; readonly committed: number; readonly reverted: number };
  /** Upstream's `DebugLog[]`, rendered. Empty unless the arm asked for them. */
  readonly debugLogs: readonly { readonly message: string; readonly fields: readonly string[] }[];
}

export interface TxPlan {
  readonly label: string;
  readonly sender: AztecAddress;
  readonly setupCalls?: TestEnqueuedCall[];
  readonly appCalls?: TestEnqueuedCall[];
  readonly teardownCall?: TestEnqueuedCall;
  /** Deployments to attach to the transaction, through the two vendored helpers. */
  readonly deploy?: { classes?: unknown[]; instances?: unknown[] };
  /**
   * Build the carrier with upstream's `createTxForPrivateOnly` instead of the enqueued-call
   * builder — WHICH THIS RUNTIME CANNOT PROCESS, and the reason is measured rather than assumed.
   *
   * `deployments.test.ts` carries its deployment on a private-only transaction, and that is the
   * obvious shape to copy. It does not work here: `PublicProcessor.doTreeInsertionsForPrivateOnlyTx`
   * calls `guardedMerkleTree.batchInsert(NULLIFIER_TREE, …)`, and
   * `ResidentMerkleWriteOperations.batchInsert` REFUSES by design — "the module exports no subtree
   * insertion. Emulating one with sequential inserts plus pad_tree yields a different indexed tree,
   * and a merkle root that is wrong is worse than one that is missing." Measured: the transaction
   * lands in `failed` with *"failed with duplicate nullifiers"*, which is the processor's wrapper
   * around that refusal and names the wrong cause.
   *
   * The option is kept, and it is kept EXERCISED as an arm of its own, because a limitation stated
   * with no evidence is the shape this campaign refuses. The deployment arm proper carries its
   * deployment on a transaction with a public call to a SECOND, already-registered contract.
   */
  readonly privateOnly?: boolean;
}

/** Run one block of transactions through upstream's processor and seal it. */
export async function runOneBlock(
  reactor: ReactorLike,
  world: World,
  tester: PublicTxSimulationTester,
  label: string,
  plans: readonly TxPlan[],
): Promise<BlockRecord> {
  const labels = new Map<string, string>();
  const txs: Tx[] = [];
  for (const plan of plans) {
    await fundFeeJuice(world.seeding, plan.sender, FUNDING);
    const tx = plan.privateOnly === true
      ? await createTxForPrivateOnly(plan.sender)
      : await tester.createTx(
          plan.sender,
          plan.setupCalls ?? [],
          plan.appCalls ?? [],
          plan.teardownCall,
          plan.sender,
        );
    // THE DEPLOYMENT HALF, and it is the whole of M22's deployment entry. These two vendored
    // helpers write the contract-class log and the contract-instance private log onto the
    // transaction's accumulated data, exactly as upstream's own deployment corpus does; the
    // processor's `addNewContracts` then extracts them with `AllContractDeploymentData.fromTx`.
    // Before this file they were declared and called by nobody.
    for (const contractClass of plan.deploy?.classes ?? []) {
      await addNewContractClassToTx(tx as never, contractClass as never);
    }
    for (const instance of plan.deploy?.instances ?? []) {
      await addNewContractInstanceToTx(tx as never, instance as never);
    }
    labels.set((await tx.getTxHash()).toString(), plan.label);
    txs.push(tx);
  }

  const { processor, guarded } = createBlockProcessor(
    world.globals,
    world.merkleDb,
    world.contractsDb,
    // `as never` HERE MEANS ONE THING AND IT IS WRITTEN DOWN, which is this repository's rule for
    // the spelling. `world.simulator` is the instrumented WRAPPER around M18's own simulator: it
    // has `simulate`, `configuration` and `moduleCalls`, delegates all three, and adds only a
    // per-crossing reading of `avm_steps_count()`. What it does not carry is the delegate's
    // `PublicTxResult` return TYPE — it is declared `Promise<unknown>` so that this file does not
    // import a type it has no other use for. The cast is the declaration of that substitution, and
    // it is not a claim that the two surfaces match.
    world.simulator as never,
    new DateProvider(),
  );

  // WHAT THE PROCESSOR ASKED THE CONTRACT STORE, COUNTED RATHER THAN ASSUMED.
  //
  // `PublicProcessor` calls `addNewContracts(tx)` in exactly one place, and a check that asserted
  // "the deployment was registered" without this could not tell a processor that extracted a
  // deployment from one that never looked. The three counters are observation only: each
  // delegates to the method it replaces and is restored when the block is over.
  const asked = { addNewContracts: 0, registerClass: 0, registerInstance: 0 };
  // AND THE CHECKPOINTS, COUNTED, BECAUSE A DEPTH OF ZERO IS NOT A MERGE.
  //
  // "The fork merged" was asserted as `checkpointDepth == 0` after the block — and a store that
  // never forked reads zero too, so the assertion was satisfied by the absence of the thing it was
  // about. Found by self-review inside the sweep's own window, which is this pass's third such
  // finding and its second sweep abort. Counting the three calls turns it into a CONSERVATION LAW:
  // some checkpoints were created, and every one of them was closed exactly once, by a commit or a
  // revert. A depth of zero is then the consequence rather than the claim.
  const checkpoints = { created: 0, committed: 0, reverted: 0 };
  const db = world.contractsDb as unknown as Record<string, (...a: never[]) => unknown>;
  const originals = {
    addNewContracts: db.addNewContracts,
    registerClass: db.registerClass,
    registerInstance: db.registerInstance,
    createCheckpoint: db.createCheckpoint,
    commitCheckpoint: db.commitCheckpoint,
    revertCheckpoint: db.revertCheckpoint,
  };
  db.addNewContracts = (...a: never[]) => {
    asked.addNewContracts += 1;
    return originals.addNewContracts.apply(world.contractsDb, a);
  };
  db.registerClass = (...a: never[]) => {
    asked.registerClass += 1;
    return originals.registerClass.apply(world.contractsDb, a);
  };
  db.registerInstance = (...a: never[]) => {
    asked.registerInstance += 1;
    return originals.registerInstance.apply(world.contractsDb, a);
  };
  db.createCheckpoint = (...a: never[]) => {
    checkpoints.created += 1;
    return originals.createCheckpoint.apply(world.contractsDb, a);
  };
  db.commitCheckpoint = (...a: never[]) => {
    checkpoints.committed += 1;
    return originals.commitCheckpoint.apply(world.contractsDb, a);
  };
  db.revertCheckpoint = (...a: never[]) => {
    checkpoints.reverted += 1;
    return originals.revertCheckpoint.apply(world.contractsDb, a);
  };

  const simulationsBefore = world.simulations.length;
  let block;
  try {
    block = await assembleBlock(processor, txs, world.contractsDb, world.merkleDb, {});
  } finally {
    db.addNewContracts = originals.addNewContracts;
    db.registerClass = originals.registerClass;
    db.registerInstance = originals.registerInstance;
    db.createCheckpoint = originals.createCheckpoint;
    db.commitCheckpoint = originals.commitCheckpoint;
    db.revertCheckpoint = originals.revertCheckpoint;
  }
  const madeThisBlock = world.simulations.slice(simulationsBefore);

  const labelOf = (tx: Tx) => labels.get(tx.getTxHash().toString()) ?? '?';
  const revertCodes: Record<string, number> = {};
  const revertReasons: Record<string, string | null> = {};
  const l2GasByTx: Record<string, number> = {};
  const daGasByTx: Record<string, number> = {};
  const feeByTx: Record<string, string> = {};
  const nullifiersByTx: Record<string, string[]> = {};
  for (const p of block.processed as readonly {
    hash: { toString(): string };
    revertCode: { getCode(): number };
    revertReason?: { message?: string };
    gasUsed: { totalGas: { l2Gas: bigint | number; daGas: bigint | number } };
    txEffect: {
      transactionFee: { toBigInt?(): bigint; toString(): string };
      nullifiers?: readonly { toString(): string }[];
    };
  }[]) {
    const l = labels.get(p.hash.toString()) ?? p.hash.toString();
    revertCodes[l] = p.revertCode.getCode();
    revertReasons[l] = p.revertReason?.message ?? null;
    l2GasByTx[l] = Number(p.gasUsed.totalGas.l2Gas);
    daGasByTx[l] = Number(p.gasUsed.totalGas.daGas);
    const fee = p.txEffect.transactionFee;
    feeByTx[l] = typeof fee.toBigInt === 'function' ? fee.toBigInt().toString() : String(fee);
    nullifiersByTx[l] = (p.txEffect.nullifiers ?? []).map(n => n.toString());
  }

  const seal = (await sealBlock(guarded, world.globals)) as {
    sealed: boolean;
    refusal?: { method: string; reason: string };
  };

  return {
    label,
    submitted: plans.map(p => p.label),
    processed: block.processed.map(p => labels.get(p.hash.toString()) ?? p.hash.toString()),
    failed: block.failed.map(f => ({ label: labelOf(f.tx), message: f.error.message.slice(0, 240) })),
    unprocessed: block.unprocessed.map(labelOf),
    revertCodes,
    revertReasons,
    l2GasByTx,
    daGasByTx,
    feeByTx,
    nullifiersByTx,
    returnValues: block.returns.map(r => (r.values ?? []).map((v: { toBigInt(): bigint }) => v.toBigInt().toString())),
    registrations: block.registrations,
    contractStoreCalls: asked,
    stateReferenceAfter: block.stateReference.toBuffer().toString('hex'),
    sealed: seal.sealed === true,
    sealRefusal: seal.refusal === undefined ? null : seal.refusal.method,
    instructionsPerSimulation: madeThisBlock.map(s => s.steps),
    rawRevertCodes: madeThisBlock.map(s => (s.rawRevertCode === undefined ? null : s.rawRevertCode)),
    checkpointDepthAfter: { contracts: world.contractsDb.checkpointDepth },
    checkpoints,
    debugLogs: (block.debugLogs as readonly { message?: string; fields?: { toString(): string }[] }[]).map(d => ({
      message: String(d.message ?? ''),
      fields: (d.fields ?? []).map(f => f.toString()),
    })),
  };
}

/** Register the contract in the module directly — the route the deployment arm deliberately avoids. */
export async function registerDirectly(
  world: World,
  contractClass: unknown,
  contractInstance: { address: { toField(): Fr } },
): Promise<{ classes: number; instances: number; nullifier: string }> {
  const classes = (await world.contractsDb.registerClass(contractClass as never)) ? 1 : 0;
  const instances = world.contractsDb.registerInstance(contractInstance as never) ? 1 : 0;
  const nullifier = await siloNullifier(
    await AztecAddress.fromNumber(CONTRACT_INSTANCE_REGISTRY_CONTRACT_ADDRESS),
    contractInstance.address.toField(),
  );
  world.seeding.insertNullifier(nullifier);
  return { classes, instances, nullifier: nullifier.toString() };
}

/**
 * THE TRIPWIRE'S CONTROL, AND WITHOUT IT THE TRIPWIRE'S ZERO MEANS NOTHING.
 *
 * Every trap on the merkle proxy THROWS, so an observation aborts the arm and no report is produced
 * at all — which means `merkleTouches` is necessarily empty in every report a check can read, and an
 * assertion that it is empty is satisfied by a tripwire wired to nothing. `CAMPAIGN-BRIEF.md`
 * records this as the 26th and 27th instances of "an assertion must be capable of failing"; M26
 * answered it in `join_e2e_driver.ts` and the first version of THIS file did not carry the answer
 * over. Found by self-review while a sweep was running, which is the one thing that window is for.
 *
 * `tester.merkleTree` is the field the vendored constructor assigned
 * (`vendor/public_tx_simulation_tester.ts:61`), so touching it touches the reference the builder was
 * handed rather than a second proxy made beside it. `NOT-THROWN` means the tripwire is not armed.
 */
function tripwireControl(tester: PublicTxSimulationTester): string {
  try {
    void (tester as never as { merkleTree: Record<string, unknown> }).merkleTree['getTreeInfo'];
  } catch (e) {
    return `threw:${e instanceof Error ? e.message : String(e)}`;
  }
  return 'NOT-THROWN';
}

const ADMIN = 42;
const SENDER = 111;
const RECEIVER = 222;

/**
 * THE TOKEN ARM: upstream's `tokenTest` sequence, over three real blocks.
 *
 * Block 1 is the constructor alone, because the contract's `mark_as_initialized_public` has to have
 * landed before any other `#[public]` function of it will dispatch — `assert_is_initialized_public`
 * is what every one of them calls. Block 2 carries the MINT AND THE TRANSFER TOGETHER, which is
 * M22's entry in one line: two Token transactions before one seal. Block 3 burns.
 *
 * `expectMint` is the arm's one variable. With it false the mint transaction is simply not
 * submitted, so the transfer meets an empty balance and the contract's own
 * `assert(balance >= amount)` fires. That is the discriminator for every "the final state is
 * right" assertion in the check: without it, a balance reader that returned a constant would
 * satisfy the whole arm.
 */
async function runTokenArm(
  reactor: ReactorLike,
  rawTokenArtifact: unknown,
  opts: { expectMint: boolean },
): Promise<Record<string, unknown>> {
  const artifact = loadContractArtifact(rawTokenArtifact as never);
  const world = openWorld(reactor);
  try {
    const admin = await AztecAddress.fromNumber(ADMIN);
    const sender = await AztecAddress.fromNumber(SENDER);
    const receiver = await AztecAddress.fromNumber(RECEIVER);
    const constructorArgs = [admin, 'Token', 'TOK', 18];
    const { contractClass, contractInstance } = await createContractClassAndInstance(
      constructorArgs,
      admin,
      artifact,
      /*seed=*/ 27,
    );

    const dataSource = new SimpleContractDataSource();
    await dataSource.addNewContract(artifact, contractClass, contractInstance);
    const registered = await registerDirectly(world, contractClass, contractInstance);

    // The tripwire M26 vendored the builder with and every caller since has kept: the builder's
    // one removed dependency is `MerkleTreeWriteOperations`, and this proxy makes "it never
    // touches a world state" execute rather than be a sentence in a document.
    const merkleTouches: string[] = [];
    const tripwire = new Proxy(
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
    const tester = new PublicTxSimulationTester(tripwire as never, dataSource);
    const at = contractInstance.address;

    const balanceOf = (owner: AztecAddress): TestEnqueuedCall => ({
      address: at,
      fnName: 'balance_of_public',
      args: [owner],
      // STATIC, and it is not decoration: `balance_of_public` is `#[view]`, and aztec-nr's
      // generated dispatch for a view function ASSERTS the call is static. M29 found this by
      // reading an executed step stream that ended on `REVERT_8`.
      isStaticCall: true,
    });

    const blocks: BlockRecord[] = [];
    blocks.push(
      await runOneBlock(reactor, world, tester, 'construct', [
        { label: 'constructor', sender: admin, appCalls: [{ address: at, fnName: 'constructor', args: constructorArgs }] },
      ]),
    );

    // BLOCK 2 — TWO TOKEN TRANSACTIONS, ONE BLOCK. M22's entry, executed.
    const blockTwoPlans: TxPlan[] = [];
    if (opts.expectMint) {
      blockTwoPlans.push({
        label: 'mint',
        sender: admin,
        appCalls: [{ address: at, fnName: 'mint_to_public', args: [sender, MINT_AMOUNT] }],
      });
    }
    blockTwoPlans.push({
      label: 'transfer',
      sender,
      appCalls: [
        { address: at, fnName: 'transfer_in_public', args: [sender, receiver, TRANSFER_AMOUNT, new Fr(0)] },
      ],
    });
    blocks.push(await runOneBlock(reactor, world, tester, 'mintAndTransfer', blockTwoPlans));

    // The balances, read back through the contract's own `#[view]` function, in their own block.
    blocks.push(
      await runOneBlock(reactor, world, tester, 'balancesAfterTransfer', [
        { label: 'balanceSender', sender, appCalls: [balanceOf(sender)] },
        { label: 'balanceReceiver', sender, appCalls: [balanceOf(receiver)] },
      ]),
    );

    blocks.push(
      await runOneBlock(reactor, world, tester, 'burn', [
        {
          label: 'burn',
          sender: receiver,
          appCalls: [{ address: at, fnName: 'burn_public', args: [receiver, TRANSFER_AMOUNT, new Fr(0)] }],
        },
      ]),
    );
    blocks.push(
      await runOneBlock(reactor, world, tester, 'balancesAfterBurn', [
        { label: 'balanceSender', sender, appCalls: [balanceOf(sender)] },
        { label: 'balanceReceiver', sender, appCalls: [balanceOf(receiver)] },
      ]),
    );

    return {
      artifactName: artifact.name,
      contractAddress: at.toString(),
      contractClassId: contractClass.id.toString(),
      registeredDirectly: registered,
      admin: admin.toString(),
      sender: sender.toString(),
      receiver: receiver.toString(),
      mintAmount: MINT_AMOUNT.toString(),
      transferAmount: TRANSFER_AMOUNT.toString(),
      expectMint: opts.expectMint,
      selectors: {
        constructor: (await getFunctionSelector('constructor', artifact)).toString(),
        mint_to_public: (await getFunctionSelector('mint_to_public', artifact)).toString(),
        transfer_in_public: (await getFunctionSelector('transfer_in_public', artifact)).toString(),
        burn_public: (await getFunctionSelector('burn_public', artifact)).toString(),
        balance_of_public: (await getFunctionSelector('balance_of_public', artifact)).toString(),
      },
      // The snapshot taken BEFORE the control's deliberate touch, so the control cannot make this
      // list non-empty and the two facts stay independent.
      merkleTouches: [...merkleTouches],
      merkleTripwireControl: tripwireControl(tester),
      merkleTouchesAfterControl: merkleTouches.length,
      blocks,
    };
  } finally {
    world.release();
  }
}

/**
 * THE DEPLOYMENT ARM: a contract published BY A TRANSACTION, called in a LATER block.
 *
 * `deployInBlockOne` is the arm's one variable, and it is the control for every assertion here.
 * With it false the very same second block runs against a module that was never told about the
 * contract, so the call finds no bytecode. Without that arm, "the contract is callable" is
 * satisfied by any transaction that happens to succeed.
 */
async function runDeploymentArm(
  reactor: ReactorLike,
  raw: { subject: unknown; carrier: unknown },
  opts: { deployInBlockOne: boolean },
): Promise<Record<string, unknown>> {
  const artifact = loadContractArtifact(raw.subject as never);
  const carrierArtifact = loadContractArtifact(raw.carrier as never);
  const world = openWorld(reactor);
  try {
    const deployer = await AztecAddress.fromNumber(4242);
    const caller = await AztecAddress.fromNumber(1001);
    // `[]` constructor args and `AvmTest`, both upstream's own choices in `deployments.test.ts`:
    // AvmTest has no initializer, so `assert_is_initialized_public` is not in the way and the arm
    // measures deployment rather than initialization.
    const { contractClass, contractInstance, contractAddressNullifier } = await createContractClassAndInstance(
      /*constructorArgs=*/ [],
      deployer,
      artifact,
      /*seed=*/ 31,
    );
    // THE CARRIER'S CONTRACT, a second instance of the same artifact at a different seed, so it has
    // a different class id and a different address. It is registered DIRECTLY, which is the route
    // the subject deliberately avoids: the carrier's job is only to make block one's transaction a
    // public one that succeeds, so that the deployment riding on it is not discarded with a
    // reverted phase.
    //
    // THE CARRIER IS A DIFFERENT ARTIFACT FROM THE SUBJECT, AND THAT IS NOT TIDINESS.
    // The first version of this arm used a second instance of the SAME artifact, so the two
    // contract classes carried identical bytecode — and a subject that "became callable" could
    // have been the carrier's own bytecode answering. With two artifacts the block-two call names
    // a function that exists only in the subject's, so executing it is evidence about the subject.
    const helper = await createContractClassAndInstance(
      /*constructorArgs=*/ [],
      deployer,
      carrierArtifact,
      /*seed=*/ 71,
    );
    const dataSource = new SimpleContractDataSource();
    await dataSource.addNewContract(artifact, contractClass, contractInstance);
    await dataSource.addNewContract(carrierArtifact, helper.contractClass, helper.contractInstance);

    const merkleTouches: string[] = [];
    const tripwire = new Proxy(
      {},
      {
        get(_t, p) {
          merkleTouches.push(`get:${String(p)}`);
          throw new Error(`the vendored transaction builder read merkleTree.${String(p)}`);
        },
      },
    );
    const tester = new PublicTxSimulationTester(tripwire as never, dataSource);
    await registerDirectly(world, helper.contractClass, helper.contractInstance);

    // BLOCK 1 — THE DEPLOYMENT, RIDING ON A TRANSACTION THAT CALLS THE HELPER.
    // The control differs in exactly one thing: whether the two vendored helpers are called.
    const blocks: BlockRecord[] = [];
    blocks.push(
      await runOneBlock(reactor, world, tester, 'publish', [
        {
          label: 'deployTx',
          sender: deployer,
          appCalls: [{ address: helper.contractInstance.address, fnName: 'add_args_return', args: [1n, 2n] }],
          ...(opts.deployInBlockOne
            ? { deploy: { classes: [contractClass], instances: [contractInstance] } }
            : {}),
        },
        // A SECOND TRANSACTION IN THE SAME BLOCK, calling the contract the first one publishes.
        // The entry's own words are "callable in a LATER block", and whether the SAME block also
        // works is a fact about this runtime that nothing had measured. It is reported rather than
        // assumed either way.
        {
          label: 'sameBlockCall',
          sender: caller,
          appCalls: [
            {
              address: contractInstance.address,
              fnName: 'pub_get_value',
              args: [new Fr(5)],
              contractArtifact: artifact as never,
            },
          ],
        },
      ]),
    );

    // THE PRIVATE-ONLY CARRIER, RUN AS ITS OWN ARM RATHER THAN CLAIMED ABOUT. Upstream's own shape
    // for this test, and this runtime refuses it at `batchInsert`; see `TxPlan.privateOnly`.
    const privateOnly = await runOneBlock(reactor, world, tester, 'privateOnlyCarrier', [
      {
        label: 'privateOnlyDeployTx',
        sender: deployer,
        privateOnly: true,
        deploy: { classes: [helper.contractClass], instances: [helper.contractInstance] },
      },
    ]);

    // The contract-address nullifier is what makes an address CALLABLE (M29). When the deployment
    // travels on the transaction, upstream's own `addNewContractInstanceToTx` puts it in the
    // transaction's accumulated nullifiers and the processor writes it — so this arm does NOT
    // insert it by hand, which is the difference between "published" and "seeded".
    const nullifierFromHelper = contractAddressNullifier.toString();

    // BLOCK 2 — THE CALL. `read_storage_single` is upstream's own choice in the same test, and it
    // is `#[view]`-free, so no static flag and no initializer is in play: what is being measured is
    // whether the address has bytecode.
    blocks.push(
      await runOneBlock(reactor, world, tester, 'callLater', [
        {
          label: 'call',
          sender: caller,
          appCalls: [
            {
              address: contractInstance.address,
              fnName: 'pub_get_value',
              args: [new Fr(5)],
              contractArtifact: artifact as never,
            },
          ],
        },
      ]),
    );

    // ===========================================================================================
    // THE DELIBERATE EXTRACTION PROBE, AND IT IS THE POSITIVE CONTROL FOR A COUNTER THAT READS ZERO.
    // ===========================================================================================
    //
    // The check's strongest sentence is that `PublicProcessor` NEVER calls
    // `contractsDB.addNewContracts` for a transaction with public calls — asserted as a count of
    // zero. A counter wired to nothing reads zero too, and so does a store that could not extract a
    // deployment even if asked. Both would satisfy that assertion, and the three have different
    // remedies.
    //
    // So the same transaction shape is handed to `addNewContracts` BY HAND, after the blocks, and
    // the flush is drained: the counter goes to one and the flush registers what the transaction
    // carried. That separates "the processor did not ask" from "there was nothing to find", which
    // is the whole content of the finding.
    const probeTx = await tester.createTx(deployer, [], [
      { address: helper.contractInstance.address, fnName: 'add_args_return', args: [1n, 2n] },
    ]);
    const probeClass = await createContractClassAndInstance(
      /*constructorArgs=*/ [],
      deployer,
      artifact,
      /*seed=*/ 97,
    );
    await addNewContractClassToTx(probeTx as never, probeClass.contractClass as never);
    await addNewContractInstanceToTx(probeTx as never, probeClass.contractInstance as never);
    const probeCalls = { addNewContracts: 0 };
    const probeDb = world.contractsDb as unknown as Record<string, (...a: never[]) => unknown>;
    const probeOriginal = probeDb.addNewContracts;
    probeDb.addNewContracts = (...a: never[]) => {
      probeCalls.addNewContracts += 1;
      return probeOriginal.apply(world.contractsDb, a);
    };
    let probe: Record<string, unknown>;
    try {
      world.contractsDb.addNewContracts(probeTx as never);
      const queued = world.contractsDb.pendingRegistrations;
      const flushed = await world.contractsDb.flush();
      probe = {
        calls: probeCalls.addNewContracts,
        queuedBeforeFlush: queued,
        registered: flushed,
        subjectClassId: probeClass.contractClass.id.toString(),
        subjectAddress: probeClass.contractInstance.address.toString(),
      };
    } finally {
      probeDb.addNewContracts = probeOriginal;
    }

    return {
      deployInBlockOne: opts.deployInBlockOne,
      subjectArtifact: artifact.name,
      carrierArtifact: carrierArtifact.name,
      contractAddress: contractInstance.address.toString(),
      contractClassId: contractClass.id.toString(),
      contractAddressNullifier: nullifierFromHelper,
      carrierAddress: helper.contractInstance.address.toString(),
      carrierClassId: helper.contractClass.id.toString(),
      merkleTouches: [...merkleTouches],
      merkleTripwireControl: tripwireControl(tester),
      merkleTouchesAfterControl: merkleTouches.length,
      privateOnlyCarrier: privateOnly,
      extractionProbe: probe,
      blocks,
    };
  } finally {
    world.release();
  }
}

/**
 * THE NESTED-CALL ARM: CALL and STATICCALL, their fork/merge, and the gas a reverted frame gives
 * back.
 *
 * Every function here is `AvmTest`'s own and every one of them is in
 * `fixtures/contracts/artifacts.json`'s pinned `calledPublicFunctions` list, so the arm cannot
 * drift onto a function this repository does not already declare it drives.
 *
 *   `nested_call_to_add(3,5)`             a CALL that returns 8
 *   `nested_static_call_to_add(3,5)`      a STATICCALL that returns 8
 *   `nested_static_call_to_set_storage()` a STATICCALL that tries to WRITE — the static fork is
 *                                         enforced by the AVM, so this must revert
 *   `nested_call_to_nothing_recovers()`   a nested CALL that FAILS inside an outer call that
 *                                         SUCCEEDS, which is the fork that must merge nothing
 *   `nested_call_to_add_with_gas(3,5,G,D)` the same CALL with G allocated to the nested frame; run
 *                                         at two very different G, the transaction's own gas must
 *                                         come out THE SAME, which is "unused gas is refunded"
 *                                         measured rather than asserted
 */
async function runNestedArm(reactor: ReactorLike, rawAvmTestArtifact: unknown): Promise<Record<string, unknown>> {
  const artifact = loadContractArtifact(rawAvmTestArtifact as never);
  const world = openWorld(reactor);
  try {
    const sender = await AztecAddress.fromNumber(777);
    const { contractClass, contractInstance } = await createContractClassAndInstance([], sender, artifact, 53);
    const dataSource = new SimpleContractDataSource();
    await dataSource.addNewContract(artifact, contractClass, contractInstance);
    await registerDirectly(world, contractClass, contractInstance);

    const tripwire = new Proxy({}, { get(_t, p) { throw new Error(`builder read merkleTree.${String(p)}`); } });
    const tester = new PublicTxSimulationTester(tripwire as never, dataSource);
    const at = contractInstance.address;

    const one = (label: string, call: TestEnqueuedCall) =>
      runOneBlock(reactor, world, tester, label, [{ label, sender, appCalls: [call] }]);

    const blocks: BlockRecord[] = [];
    blocks.push(await one('nestedCall', { address: at, fnName: 'nested_call_to_add', args: [3n, 5n] }));
    blocks.push(await one('nestedStaticCall', { address: at, fnName: 'nested_static_call_to_add', args: [3n, 5n] }));
    blocks.push(await one('nestedStaticWrite', { address: at, fnName: 'nested_static_call_to_set_storage', args: [] }));
    blocks.push(await one('nestedRecovers', { address: at, fnName: 'nested_call_to_nothing_recovers', args: [] }));
    // THE TWO ALLOCATIONS ARE ONE PAIR OF CONSTANTS, USED BOTH AT THE CALL SITE AND IN THE REPORT.
    //
    // The first version declared them twice — once in the `args` and once in the returned
    // `gasAllocations` — and the mutation matrix found it: making the two calls allocate the SAME
    // amount left the report still claiming they differed, so the check's non-degeneracy guard
    // ("the two arms allocated genuinely different amounts") stayed GREEN over an equality that had
    // become a tautology. That is `CAMPAIGN-BRIEF.md`'s "a constant you have just typed into a
    // check looks like a measurement to the person typing it", one layer down in the driver. One
    // declaration now, so the report cannot disagree with the call.
    const GAS_SMALL = { l2: 2_000_000, da: 200_000 };
    const GAS_LARGE = { l2: 8_000_000, da: 800_000 };
    blocks.push(
      await one('nestedGasSmall', {
        address: at,
        fnName: 'nested_call_to_add_with_gas',
        args: [3n, 5n, GAS_SMALL.l2, GAS_SMALL.da],
      }),
    );
    blocks.push(
      await one('nestedGasLarge', {
        address: at,
        fnName: 'nested_call_to_add_with_gas',
        args: [3n, 5n, GAS_LARGE.l2, GAS_LARGE.da],
      }),
    );
    // A FLAT call, so "two contexts" is a measurement and not the only shape the arm can produce.
    blocks.push(await one('flatCall', { address: at, fnName: 'add_args_return', args: [3n, 5n] }));

    // ===========================================================================================
    // THE SIDE-EFFECT HALF, AS A PAIR, BECAUSE ONE OF THE TWO ALONE PROVES NOTHING.
    // ===========================================================================================
    //
    // `create_different_nullifier_in_nested_call(addr, N)` pushes N in the OUTER frame and N+1 in
    // the NESTED one; both land. `create_same_nullifier_in_nested_call(addr, N)` pushes N in both,
    // so the nested frame's push is a duplicate, the nested call reverts and takes the transaction
    // with it. The claim "a reverted nested call contributes no side effects" is then not a revert
    // code but a LATER TRANSACTION: `new_nullifier(N)` afterwards must SUCCEED, because the
    // reverted frame's write is not in the tree — while `new_nullifier(N_DIFFERENT)` after the
    // arm that landed must REVERT, because that one is.
    //
    // Two nullifiers, two follow-ups, and the two answers are opposite. Either one on its own is
    // satisfied by a tree that accepts everything or by a tree that accepts nothing.
    // THE TWO VALUES MUST NOT COLLIDE, AND THE FIRST DRAFT'S DID. `LANDED + 1` is the nullifier the
    // NESTED frame of the landing arm pushes, so `DISCARDED` cannot be `LANDED + 1` — with it, the
    // "the discarded one is still free" follow-up reverted against a nullifier that had landed in
    // the OTHER arm, and the arm reported the opposite of its subject while looking correct.
    const LANDED = 700001n;
    const DISCARDED = 700011n;
    blocks.push(
      await one('nullifiersLand', {
        address: at,
        fnName: 'create_different_nullifier_in_nested_call',
        args: [at, LANDED],
      }),
    );
    blocks.push(
      await one('nullifiersDiscarded', {
        address: at,
        fnName: 'create_same_nullifier_in_nested_call',
        args: [at, DISCARDED],
      }),
    );
    blocks.push(await one('reuseLanded', { address: at, fnName: 'new_nullifier', args: [LANDED] }));
    blocks.push(await one('reuseLandedNested', { address: at, fnName: 'new_nullifier', args: [LANDED + 1n] }));
    blocks.push(await one('reuseDiscarded', { address: at, fnName: 'new_nullifier', args: [DISCARDED] }));

    return {
      contractAddress: at.toString(),
      nullifiers: { landed: LANDED.toString(), landedNested: (LANDED + 1n).toString(), discarded: DISCARDED.toString() },
      gasAllocations: { small: GAS_SMALL, large: GAS_LARGE },
      blocks,
    };
  } finally {
    world.release();
  }
}

/**
 * THE DEBUG-LOG ARM. `AvmTest.debug_logging` emits six logs of four kinds through
 * `aztec::oracle::logging`; the module collects them only when `collectDebugLogs` is set, and
 * `PublicProcessor` hands them back as upstream's `DebugLog[]`.
 *
 * The `off` arm is the control that the FLAG is what produces them: the same transaction, the same
 * contract, the same call, with the one config field false. Without it "six logs surfaced" is
 * equally satisfied by a runtime that emits logs for everything.
 */
async function runDebugLogArm(
  reactor: ReactorLike,
  rawAvmTestArtifact: unknown,
  opts: { collect: boolean },
): Promise<Record<string, unknown>> {
  const artifact = loadContractArtifact(rawAvmTestArtifact as never);
  const world = openWorld(reactor, { collectDebugLogs: opts.collect });
  try {
    const sender = await AztecAddress.fromNumber(888);
    const { contractClass, contractInstance } = await createContractClassAndInstance([], sender, artifact, 59);
    const dataSource = new SimpleContractDataSource();
    await dataSource.addNewContract(artifact, contractClass, contractInstance);
    await registerDirectly(world, contractClass, contractInstance);
    const tripwire = new Proxy({}, { get(_t, p) { throw new Error(`builder read merkleTree.${String(p)}`); } });
    const tester = new PublicTxSimulationTester(tripwire as never, dataSource);

    const block = await runOneBlock(reactor, world, tester, 'debugLogging', [
      {
        label: 'debugLogging',
        sender,
        appCalls: [{ address: contractInstance.address, fnName: 'debug_logging', args: [] }],
      },
    ]);
    return { collectDebugLogs: opts.collect, contractAddress: contractInstance.address.toString(), blocks: [block] };
  } finally {
    world.release();
  }
}

/**
 * THE PHASE ARM: a REAL contract's calls in SETUP, APP_LOGIC and TEARDOWN.
 *
 * M18's entry says the asymmetric revert model is already asserted over mockTx-built transactions
 * calling UNREGISTERED contracts, and that what is missing is the same asymmetry over a real
 * contract's calls in more than one phase. Three arms, one variable each:
 *
 *   `allSucceed`      setup, app and teardown all succeed
 *   `appReverts`      the APP-LOGIC call reverts — the transaction still LANDS (soft revert), the
 *                     teardown still runs, and the setup's state survives
 *   `setupReverts`    the SETUP call reverts — the transaction is THROWN OUT of the block entirely
 *   `teardownReverts` the TEARDOWN call reverts — the transaction lands and still pays its fee
 *
 * The state each arm's setup wrote is read back afterwards with `read_storage_map`, so
 * "APP_LOGIC soft-reverts to the POST-SETUP state" is a value comparison and not a revert code.
 */
async function runPhaseArm(
  reactor: ReactorLike,
  rawAvmTestArtifact: unknown,
  which: 'allSucceed' | 'appReverts' | 'setupReverts' | 'teardownReverts',
): Promise<Record<string, unknown>> {
  const artifact = loadContractArtifact(rawAvmTestArtifact as never);
  const world = openWorld(reactor);
  try {
    const sender = await AztecAddress.fromNumber(999);
    const { contractClass, contractInstance } = await createContractClassAndInstance([], sender, artifact, 61);
    const dataSource = new SimpleContractDataSource();
    await dataSource.addNewContract(artifact, contractClass, contractInstance);
    await registerDirectly(world, contractClass, contractInstance);
    const tripwire = new Proxy({}, { get(_t, p) { throw new Error(`builder read merkleTree.${String(p)}`); } });
    const tester = new PublicTxSimulationTester(tripwire as never, dataSource);
    const at = contractInstance.address;

    const SETUP_KEY = 7n;
    const SETUP_VALUE = 4242n;
    const APP_KEY = 8n;
    const APP_VALUE = 5151n;
    const TEARDOWN_KEY = 9n;
    const TEARDOWN_VALUE = 6262n;

    const fail: TestEnqueuedCall = { address: at, fnName: 'assertion_failure', args: [] };
    const setupCalls: TestEnqueuedCall[] = [
      { address: at, fnName: 'set_storage_map', args: [await AztecAddress.fromNumber(Number(SETUP_KEY)), Number(SETUP_VALUE)] },
      ...(which === 'setupReverts' ? [fail] : []),
    ];
    const appCalls: TestEnqueuedCall[] = [
      { address: at, fnName: 'set_storage_map', args: [await AztecAddress.fromNumber(Number(APP_KEY)), Number(APP_VALUE)] },
      ...(which === 'appReverts' ? [fail] : []),
    ];
    const teardownCall: TestEnqueuedCall =
      which === 'teardownReverts'
        ? fail
        : {
            address: at,
            fnName: 'set_storage_map',
            args: [await AztecAddress.fromNumber(Number(TEARDOWN_KEY)), Number(TEARDOWN_VALUE)],
          };

    const blocks: BlockRecord[] = [];
    blocks.push(
      await runOneBlock(reactor, world, tester, 'phases', [
        { label: 'phased', sender, setupCalls, appCalls, teardownCall },
      ]),
    );
    // The read-back, in a later block: what survived each phase, as VALUES.
    const read = (k: bigint): TestEnqueuedCall => ({
      address: at,
      fnName: 'read_storage_map',
      args: [AztecAddress.fromNumber(Number(k))],
      isStaticCall: true,
    });
    blocks.push(
      await runOneBlock(reactor, world, tester, 'readBack', [
        { label: 'readSetup', sender, appCalls: [read(SETUP_KEY)] },
        { label: 'readApp', sender, appCalls: [read(APP_KEY)] },
        { label: 'readTeardown', sender, appCalls: [read(TEARDOWN_KEY)] },
      ]),
    );

    return {
      which,
      contractAddress: at.toString(),
      expected: {
        setup: SETUP_VALUE.toString(),
        app: APP_VALUE.toString(),
        teardown: TEARDOWN_VALUE.toString(),
      },
      blocks,
    };
  } finally {
    world.release();
  }
}

/**
 * THE CUSTOM-BYTECODE ARM: malformed programs, through the combined stack, as REVERTS.
 *
 * ===========================================================================================
 * WHY THIS NEEDS NO ASSEMBLER, WHICH IS THE THING THE ENTRY SAID BLOCKED IT.
 * ===========================================================================================
 *
 * `test_custom_bytecode_unhappy_paths`'s recorded blocker is that upstream's twelve malformed
 * programs are built by the DELETED TypeScript AVM's `encodeToBytecode` and opcode classes, and
 * this repository has no assembler. Re-measured 2026-08-31 and still true: no file under
 * `orchestration/`, `browser/` or `tools/` mentions `encodeToBytecode` or the opcode modules, and
 * `fixtures/avm-programs/programs.json`'s `bytes` field is an integer LENGTH rather than hex.
 *
 * But the four unhappy paths the entry names do not need an assembler, because each of them is
 * defined by what the bytes are NOT. An invalid opcode is a byte no opcode uses; a truncated
 * instruction is a valid opcode with its operands cut off; an invalid tag is a full-length
 * instruction whose TAG byte is outside the tag enum; an out-of-range program counter is a program
 * with nothing at the counter. Every one of those is three bytes or fewer, and every constant in
 * them is DERIVED from the AVM's own headers at the pinned anchor by the tool that calls this
 * function — `WireOpCode` for the opcode indices and `ValueTag` for the tag range — and the check
 * re-derives both independently and compares. Nothing here is a magic number.
 *
 * THE WELL-FORMED CONTROL IS NOT ASSEMBLED EITHER, and it is the assertion the other four rest on.
 * "Malformed bytecode reverts" is equally satisfied by an AVM that refuses ALL custom bytecode, so
 * the fifth program is `AvmTest`'s own real `public_dispatch` bytecode registered as a
 * custom-bytecode contract and called with the function selector as calldata field 0 — which is
 * exactly what the vendored builder's custom path produces, since with no `fnName` it maps the
 * arguments to fields and prepends nothing. If that one executes, the path works and the four
 * reverts are about the bytes.
 *
 * AND "NOT HOST-SIDE CRASHES" IS ASSERTED BY THE ARM'S SHAPE. Every program runs in the SAME
 * process, in order, and the control runs LAST — so a host that died on a malformed program could
 * not report the control at all.
 */
async function runCustomBytecodeArm(
  reactor: ReactorLike,
  rawAvmTestArtifact: unknown,
  opcodes: { setOpcode: number; invalidOpcode: number; invalidTag: number },
): Promise<Record<string, unknown>> {
  const artifact = loadContractArtifact(rawAvmTestArtifact as never);
  const world = openWorld(reactor);
  try {
    const sender = await AztecAddress.fromNumber(1313);
    const dispatch = artifact.functions.find(f => f.name === 'public_dispatch');
    if (dispatch === undefined) {
      throw new Error(`${artifact.name} has no public_dispatch to use as the well-formed control`);
    }
    const selector = await getFunctionSelector('add_args_return', artifact);

    const programs: { label: string; bytes: Uint8Array; args: unknown[] }[] = [
      // A byte no opcode uses: `LAST_OPCODE_SENTINEL` and everything above it.
      { label: 'invalidOpcode', bytes: Uint8Array.from([opcodes.invalidOpcode]), args: [] },
      // A VALID opcode with every one of its four operands missing.
      { label: 'truncatedInstruction', bytes: Uint8Array.from([opcodes.setOpcode]), args: [] },
      // The same instruction at full length, with the TAG byte outside the tag enum.
      {
        label: 'invalidTag',
        bytes: Uint8Array.from([opcodes.setOpcode, 0x00, 0x00, opcodes.invalidTag, 0x00]),
        args: [],
      },
      // Nothing at the program counter at all.
      { label: 'pcOutOfRange', bytes: Uint8Array.from([]), args: [] },
      // THE CONTROL, and it runs last so a host that died on a malformed program cannot report it.
      { label: 'wellFormed', bytes: Buffer.from(dispatch.bytecode), args: [selector.toField(), 3n, 5n] },
    ];

    const dataSource = new SimpleContractDataSource();
    const tripwire = new Proxy({}, { get(_t, p) { throw new Error(`builder read merkleTree.${String(p)}`); } });
    const tester = new PublicTxSimulationTester(tripwire as never, dataSource);

    const blocks: BlockRecord[] = [];
    const registered: Record<string, { classes: number; instances: number; bytes: number }> = {};
    let seed = 101;
    for (const program of programs) {
      seed += 1;
      const contractClass = await makeContractClassPublic(seed, Buffer.from(program.bytes));
      const contractInstance = await makeContractInstanceFromClassId(contractClass.id, seed, {
        deployer: sender,
        initializationHash: new Fr(0),
        immutablesHash: new Fr(seed + 1),
        publicKeys: PublicKeys.default(),
      });
      await dataSource.addNewContract(artifact, contractClass, contractInstance);
      const r = await registerDirectly(world, contractClass, contractInstance);
      registered[program.label] = { classes: r.classes, instances: r.instances, bytes: program.bytes.length };
      blocks.push(
        await runOneBlock(reactor, world, tester, program.label, [
          {
            label: program.label,
            sender,
            // NO `fnName`: the vendored builder's own custom-bytecode path. Its source says in as
            // many words that with no function name it assumes custom bytecode with no
            // `public_dispatch` and does not prepend a selector.
            appCalls: [{ address: contractInstance.address, args: program.args as never[] }],
          },
        ]),
      );
    }

    return { registered, opcodes, blocks };
  } finally {
    world.release();
  }
}

/**
 * =============================================================================================
 * THE AMM ARM: FOUR CONTRACTS, FOUR SELF-SENT INTERNAL CALLS, AND A POOL THAT HOLDS ITS INVARIANT.
 * =============================================================================================
 *
 * M18's `e2e_ts_wasm_amm` entry, and the residue it was left with on 2026-08-31 reads:
 *
 *   "THREE Token instances plus the AMM, each with its own deployment and initialization nullifier
 *    and its own `constructor` and `set_minter` run, balance seeding for each, and each internal
 *    call enqueued with `sender` set to the AMM's own address."
 *
 * That is what this function does. The recipe is upstream's own
 * `yarn-project/simulator/src/public/fixtures/amm_test.ts` at the `cpp` anchor, call for call, with
 * two differences that are both stated rather than implied:
 *
 *   * upstream's `registerAndDeployContract` and `executeTxWithLabel` live in the simulator half
 *     RI-72 deliberately dropped, so the deploy is `createContractClassAndInstance` +
 *     `registerDirectly` (what `registerAndDeployContract` is, minus the world-state service) and
 *     the execute is a real transaction through `PublicProcessor` and a sealed block;
 *   * upstream stops at three of the AMM's four public entry points. **This runs all four.**
 *     `CAMPAIGN-BRIEF.md`'s rule — *"when a sentence names N subjects, count how many the check
 *     runs"* — is why: the entry's sentence is about four `abi_only_self` functions, and a claim
 *     quantified over a set is only as strong as the members the instrument touched.
 *
 * THE PARTIAL NOTES ARE UPSTREAM'S OWN WORKAROUND AND ARE KEPT AS ONE. Each `finalize_*_to_private`
 * consumes a partial-note VALIDITY COMMITMENT that the private half would have emitted; the private
 * half does not run here, so the commitment is computed with upstream's own
 * `poseidon2HashWithSeparator(…, DomainSeparator.PARTIAL_NOTE_VALIDITY_COMMITMENT)` and inserted,
 * siloed by the emitting token, exactly as `amm_test.ts` does. Every one of them is reported, so a
 * check can assert that the seeding happened rather than inferring it from a transaction that
 * worked.
 *
 * TWO CONTROLS, EACH ONE VARIABLE, AND EACH ONE ATTACKS A DIFFERENT HALF:
 *
 *   `selfSend: false`  every `_`-prefixed AMM call is enqueued with the USER as `sender` instead of
 *                      the AMM. `#[only_self]` must refuse all four. Without this arm, "the calls
 *                      were self-sent" is a fact about the driver's own arguments and nothing
 *                      measures whether the contract cares.
 *   `setMinter: false` the same `set_minter` transaction runs with `approve = false`. The AMM then
 *                      cannot mint the liquidity token, so `_add_liquidity` reverts — which makes
 *                      every "the pool has liquidity" assertion falsifiable by something other than
 *                      the sender.
 *
 * Both controls keep the block shape identical to the full arm's, so a check compares two runs of
 * the same sequence rather than a sequence against its absence.
 */
async function runAmmArm(
  reactor: ReactorLike,
  raw: { token: unknown; amm: unknown },
  opts: { selfSend: boolean; setMinter: boolean },
): Promise<Record<string, unknown>> {
  const tokenArtifact = loadContractArtifact(raw.token as never);
  const ammArtifact = loadContractArtifact(raw.amm as never);
  const world = openWorld(reactor);
  try {
    const admin = await AztecAddress.fromNumber(ADMIN);
    const user = await AztecAddress.fromNumber(SENDER);

    // ---- the three tokens and the AMM, each registered and each about to run its constructor ----
    const tokenConstructorArgs = (name: string, symbol: string) => [admin, name, symbol, 18];
    const t0Args = tokenConstructorArgs('Token0', 'TK0');
    const t1Args = tokenConstructorArgs('Token1', 'TK1');
    const lpArgs = tokenConstructorArgs('Liquidity', 'LPT');
    const token0 = await createContractClassAndInstance(t0Args, admin, tokenArtifact, /*seed=*/ 1201);
    const token1 = await createContractClassAndInstance(t1Args, admin, tokenArtifact, /*seed=*/ 1202);
    const lp = await createContractClassAndInstance(lpArgs, admin, tokenArtifact, /*seed=*/ 1203);
    const ammConstructorArgs = [
      token0.contractInstance.address,
      token1.contractInstance.address,
      lp.contractInstance.address,
    ];
    const amm = await createContractClassAndInstance(ammConstructorArgs, admin, ammArtifact, /*seed=*/ 1204);

    const dataSource = new SimpleContractDataSource();
    const deployed: Record<string, { classes: number; instances: number; nullifier: string; address: string }> = {};
    for (const [name, art, made] of [
      ['token0', tokenArtifact, token0],
      ['token1', tokenArtifact, token1],
      ['liquidityToken', tokenArtifact, lp],
      ['amm', ammArtifact, amm],
    ] as const) {
      await dataSource.addNewContract(art, made.contractClass, made.contractInstance);
      const r = await registerDirectly(world, made.contractClass, made.contractInstance);
      deployed[name] = { ...r, address: made.contractInstance.address.toString() };
    }

    const merkleTouches: string[] = [];
    const tripwire = new Proxy(
      {},
      {
        get(_t, p) {
          merkleTouches.push(`get:${String(p)}`);
          throw new Error(`the vendored transaction builder read merkleTree.${String(p)}`);
        },
      },
    );
    const tester = new PublicTxSimulationTester(tripwire as never, dataSource);

    const t0 = token0.contractInstance.address;
    const t1 = token1.contractInstance.address;
    const lpAt = lp.contractInstance.address;
    const ammAt = amm.contractInstance.address;

    /** The `sender` an `#[only_self]` call is enqueued with — the arm's first variable. */
    const selfSender = opts.selfSend ? ammAt : user;

    /**
     * Upstream's own validity-commitment seeding, and the two halves are reported separately.
     *
     * `poseidon2HashWithSeparator([commitment, completer], PARTIAL_NOTE_VALIDITY_COMMITMENT)` is
     * `amm_test.ts`'s `computePartialNoteValidityCommitment` verbatim; `siloNullifier(emitter, …)`
     * is what `BaseAvmSimulationTester.insertNullifier` does before it writes. Both values are
     * returned so a check can assert the seeding is real rather than reading it off a transaction
     * that happened to succeed.
     */
    const seededNotes: {
      note: string;
      emitter: string;
      noteCommitment: string;
      validityCommitment: string;
      siloed: string;
    }[] = [];
    const seedPartialNote = async (label: string, emitter: AztecAddress, commitment: Fr) => {
      // The COMPLETER is the AMM in every one of these, because the AMM is the contract that calls
      // `finalize_*_to_private`. That is upstream's own argument at every one of its seven call
      // sites, and it is what binds the commitment to this pool rather than to a note in general.
      const validity = await poseidon2HashWithSeparator(
        [commitment, ammAt],
        DomainSeparator.PARTIAL_NOTE_VALIDITY_COMMITMENT,
      );
      const siloed = await siloNullifier(emitter, validity);
      world.seeding.insertNullifier(siloed);
      seededNotes.push({
        note: label,
        emitter: emitter.toString(),
        noteCommitment: commitment.toString(),
        validityCommitment: validity.toString(),
        siloed: siloed.toString(),
      });
      return { commitment };
    };

    // Upstream's own note commitments, kept so the two recipes stay comparable line by line, plus
    // two more for the fourth entry point upstream does not exercise.
    const NOTE = {
      refund0: new Fr(42),
      refund1: new Fr(66),
      liquidity: new Fr(99),
      swapOut: new Fr(166),
      removeToken0: new Fr(111),
      removeToken1: new Fr(222),
      exactOutChange: new Fr(333),
      exactOutOut: new Fr(444),
    };

    const INITIAL_TOKEN_BALANCE = 1_000_000_000n;
    const amount0Max = (INITIAL_TOKEN_BALANCE * 6n) / 10n;
    const amount0Min = (INITIAL_TOKEN_BALANCE * 4n) / 10n;
    const amount1Max = (INITIAL_TOKEN_BALANCE * 5n) / 10n;
    const amount1Min = (INITIAL_TOKEN_BALANCE * 4n) / 10n;
    const swapAmountIn = amount0Min / 10n;
    const swapAmountOutMin = amount1Min / 100n;
    const exactOutAmountOut = 1_000_000n;
    const exactOutAmountInMax = 10_000_000n;
    const liquidityToRemove = 100n;

    const config = { token0: t0, token1: t1, liquidity_token: lpAt };
    const increase = (token: AztecAddress, amount: bigint): TestEnqueuedCall => ({
      // INTERNAL FUNCTION: upstream's own comment is "Sender must be 'this'". The token's own
      // `#[only_self]` is a second subject of the same property, and it is deliberately left
      // SELF-SENT in both controls so that the `selfSend` arm isolates the AMM's four.
      sender: token,
      address: token,
      fnName: '_increase_public_balance',
      args: [ammAt, amount],
    });
    const view = (token: AztecAddress, fnName: string, args: unknown[]): TestEnqueuedCall => ({
      address: token,
      fnName,
      args,
      isStaticCall: true,
    });

    const blocks: BlockRecord[] = [];

    // ---- BLOCK 1: four constructors, one block ----------------------------------------------
    blocks.push(
      await runOneBlock(reactor, world, tester, 'constructors', [
        { label: 'token0Ctor', sender: admin, appCalls: [{ address: t0, fnName: 'constructor', args: t0Args }] },
        { label: 'token1Ctor', sender: admin, appCalls: [{ address: t1, fnName: 'constructor', args: t1Args }] },
        { label: 'lpCtor', sender: admin, appCalls: [{ address: lpAt, fnName: 'constructor', args: lpArgs }] },
        { label: 'ammCtor', sender: admin, appCalls: [{ address: ammAt, fnName: 'constructor', args: ammConstructorArgs }] },
      ]),
    );

    // ---- BLOCK 2: the AMM becomes the liquidity token's minter (or, in the control, does not) --
    blocks.push(
      await runOneBlock(reactor, world, tester, 'setMinter', [
        {
          label: 'setMinter',
          sender: admin,
          appCalls: [{ address: lpAt, fnName: 'set_minter', args: [ammAt, opts.setMinter] }],
        },
      ]),
    );
    blocks.push(
      await runOneBlock(reactor, world, tester, 'minterCheck', [
        { label: 'isMinter', sender: admin, appCalls: [view(lpAt, 'is_minter', [ammAt])] },
      ]),
    );

    // ---- BLOCK 3: the pool is empty. A DELTA needs a before. ---------------------------------
    blocks.push(
      await runOneBlock(reactor, world, tester, 'poolBefore', [
        { label: 'poolToken0', sender: user, appCalls: [view(t0, 'balance_of_public', [ammAt])] },
        { label: 'poolToken1', sender: user, appCalls: [view(t1, 'balance_of_public', [ammAt])] },
        { label: 'lpSupply', sender: user, appCalls: [view(lpAt, 'total_supply', [])] },
      ]),
    );

    // ---- BLOCK 4: ADD LIQUIDITY. Two token transfers and the AMM's first self-sent call. ------
    const refund0 = await seedPartialNote('refundToken0', t0, NOTE.refund0);
    const refund1 = await seedPartialNote('refundToken1', t1, NOTE.refund1);
    const liquidityNote = await seedPartialNote('liquidity', lpAt, NOTE.liquidity);
    blocks.push(
      await runOneBlock(reactor, world, tester, 'addLiquidity', [
        {
          label: 'addLiquidity',
          sender: user,
          appCalls: [
            increase(t0, amount0Max),
            increase(t1, amount1Max),
            {
              sender: selfSender,
              address: ammAt,
              fnName: '_add_liquidity',
              args: [config, refund0, refund1, liquidityNote, amount0Max, amount1Max, amount0Min, amount1Min],
            },
          ],
        },
      ]),
    );
    blocks.push(
      await runOneBlock(reactor, world, tester, 'poolAfterAdd', [
        { label: 'poolToken0', sender: user, appCalls: [view(t0, 'balance_of_public', [ammAt])] },
        { label: 'poolToken1', sender: user, appCalls: [view(t1, 'balance_of_public', [ammAt])] },
        { label: 'lpSupply', sender: user, appCalls: [view(lpAt, 'total_supply', [])] },
        {
          label: 'lockedLiquidity',
          sender: user,
          appCalls: [view(lpAt, 'balance_of_public', [await AztecAddress.fromNumber(0)])],
        },
      ]),
    );

    // ---- BLOCK 5: SWAP, exact in. The AMM's second self-sent call. ----------------------------
    const swapOutNote = await seedPartialNote('swapExactInOut', t1, NOTE.swapOut);
    blocks.push(
      await runOneBlock(reactor, world, tester, 'swapExactIn', [
        {
          label: 'swapExactIn',
          sender: user,
          appCalls: [
            increase(t0, swapAmountIn),
            {
              sender: selfSender,
              address: ammAt,
              fnName: '_swap_exact_tokens_for_tokens',
              args: [t0, t1, swapAmountIn, swapAmountOutMin, swapOutNote],
            },
          ],
        },
      ]),
    );
    blocks.push(
      await runOneBlock(reactor, world, tester, 'poolAfterSwapIn', [
        { label: 'poolToken0', sender: user, appCalls: [view(t0, 'balance_of_public', [ammAt])] },
        { label: 'poolToken1', sender: user, appCalls: [view(t1, 'balance_of_public', [ammAt])] },
      ]),
    );

    // ---- BLOCK 6: SWAP, exact out. The AMM's THIRD self-sent call, and upstream does not run it.
    const exactOutChange = await seedPartialNote('swapExactOutChange', t1, NOTE.exactOutChange);
    const exactOutOut = await seedPartialNote('swapExactOutOut', t0, NOTE.exactOutOut);
    blocks.push(
      await runOneBlock(reactor, world, tester, 'swapExactOut', [
        {
          label: 'swapExactOut',
          sender: user,
          appCalls: [
            increase(t1, exactOutAmountInMax),
            {
              sender: selfSender,
              address: ammAt,
              fnName: '_swap_tokens_for_exact_tokens',
              args: [t1, t0, exactOutAmountInMax, exactOutAmountOut, exactOutChange, exactOutOut],
            },
          ],
        },
      ]),
    );
    blocks.push(
      await runOneBlock(reactor, world, tester, 'poolAfterSwapOut', [
        { label: 'poolToken0', sender: user, appCalls: [view(t0, 'balance_of_public', [ammAt])] },
        { label: 'poolToken1', sender: user, appCalls: [view(t1, 'balance_of_public', [ammAt])] },
      ]),
    );

    // ---- BLOCK 7: REMOVE LIQUIDITY. The AMM's fourth self-sent call. --------------------------
    const removeNote0 = await seedPartialNote('removeToken0', t0, NOTE.removeToken0);
    const removeNote1 = await seedPartialNote('removeToken1', t1, NOTE.removeToken1);
    blocks.push(
      await runOneBlock(reactor, world, tester, 'removeLiquidity', [
        {
          label: 'removeLiquidity',
          sender: user,
          appCalls: [
            increase(lpAt, liquidityToRemove),
            {
              sender: selfSender,
              address: ammAt,
              fnName: '_remove_liquidity',
              args: [config, liquidityToRemove, removeNote0, removeNote1, 1n, 1n],
            },
          ],
        },
      ]),
    );
    blocks.push(
      await runOneBlock(reactor, world, tester, 'poolAfterRemove', [
        { label: 'poolToken0', sender: user, appCalls: [view(t0, 'balance_of_public', [ammAt])] },
        { label: 'poolToken1', sender: user, appCalls: [view(t1, 'balance_of_public', [ammAt])] },
        { label: 'lpSupply', sender: user, appCalls: [view(lpAt, 'total_supply', [])] },
      ]),
    );

    return {
      selfSend: opts.selfSend,
      setMinter: opts.setMinter,
      tokenArtifactName: tokenArtifact.name,
      ammArtifactName: ammArtifact.name,
      deployed,
      // The four `abi_only_self` AMM functions this arm drives, named rather than counted, so a
      // check that says "all four" is comparing against the artifact's own attribute scan.
      internalFunctions: ['_add_liquidity', '_swap_exact_tokens_for_tokens', '_swap_tokens_for_exact_tokens', '_remove_liquidity'],
      // Every AMM public function the ARTIFACT declares `abi_only_self`, read off the artifact, so
      // "the four this arm drives are all of them" is a measurement rather than a list.
      //
      // READ OFF THE RAW JSON AND NOT OFF THE LOADED ARTIFACT, and the first version did the
      // latter and came back an EMPTY LIST: `loadContractArtifact` does not carry
      // `custom_attributes` through. An empty list would have made "the four are all of them"
      // vacuously true, so the check asserts the scan found four rather than that it found no
      // fifth — which is the difference between a measurement and an absence nobody looked for.
      artifactOnlySelfPublicFunctions: ((raw.amm as { functions?: { name: string; custom_attributes?: string[] }[] }).functions ?? [])
        .filter(f => (f.custom_attributes ?? []).includes('abi_public') && (f.custom_attributes ?? []).includes('abi_only_self'))
        .map(f => f.name)
        .sort(),
      selfSender: selfSender.toString(),
      ammAddress: ammAt.toString(),
      user: user.toString(),
      amounts: {
        amount0Max: amount0Max.toString(),
        amount1Max: amount1Max.toString(),
        amount0Min: amount0Min.toString(),
        amount1Min: amount1Min.toString(),
        swapAmountIn: swapAmountIn.toString(),
        swapAmountOutMin: swapAmountOutMin.toString(),
        exactOutAmountOut: exactOutAmountOut.toString(),
        exactOutAmountInMax: exactOutAmountInMax.toString(),
        liquidityToRemove: liquidityToRemove.toString(),
      },
      seededNotes,
      merkleTouches: [...merkleTouches],
      merkleTripwireControl: tripwireControl(tester),
      merkleTouchesAfterControl: merkleTouches.length,
      blocks,
    };
  } finally {
    world.release();
  }
}

export async function runTokenBlockArms(
  reactor: ReactorLike,
  artifacts: { token: unknown; avmTest: unknown; child: unknown; amm: unknown },
  opcodes: { setOpcode: number; invalidOpcode: number; invalidTag: number },
): Promise<Record<string, unknown>> {
  return {
    tokenFlows: await runTokenArm(reactor, artifacts.token, { expectMint: true }),
    tokenFlowsNoMint: await runTokenArm(reactor, artifacts.token, { expectMint: false }),
    deployment: await runDeploymentArm(
      reactor,
      { subject: artifacts.child, carrier: artifacts.avmTest },
      { deployInBlockOne: true },
    ),
    deploymentControl: await runDeploymentArm(
      reactor,
      { subject: artifacts.child, carrier: artifacts.avmTest },
      { deployInBlockOne: false },
    ),
    nested: await runNestedArm(reactor, artifacts.avmTest),
    debugLogsOn: await runDebugLogArm(reactor, artifacts.avmTest, { collect: true }),
    debugLogsOff: await runDebugLogArm(reactor, artifacts.avmTest, { collect: false }),
    phasesAllSucceed: await runPhaseArm(reactor, artifacts.avmTest, 'allSucceed'),
    phasesAppReverts: await runPhaseArm(reactor, artifacts.avmTest, 'appReverts'),
    phasesSetupReverts: await runPhaseArm(reactor, artifacts.avmTest, 'setupReverts'),
    phasesTeardownReverts: await runPhaseArm(reactor, artifacts.avmTest, 'teardownReverts'),
    customBytecode: await runCustomBytecodeArm(reactor, artifacts.avmTest, opcodes),
    amm: await runAmmArm(reactor, { token: artifacts.token, amm: artifacts.amm }, { selfSend: true, setMinter: true }),
    ammNotSelfSent: await runAmmArm(
      reactor,
      { token: artifacts.token, amm: artifacts.amm },
      { selfSend: false, setMinter: true },
    ),
    ammNoMinter: await runAmmArm(
      reactor,
      { token: artifacts.token, amm: artifacts.amm },
      { selfSend: true, setMinter: false },
    ),
  };
}
