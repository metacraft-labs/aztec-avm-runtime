// block_e2e_driver.ts — M22's block arms, driven end to end against the real `avm.wasm`.
//
// A DRIVER AND NOT A TEST: it prints one JSON object and exits 0. The assertions live in
// `verification/test_failed_tx_leaves_no_state.sh`, `verification/test_block_limits_respected.sh`
// and `verification/test_guarded_merkle_tree_blocks_post_seal_access.sh`, which read this output.
// The split is the campaign's: a driver that asserted would have to be trusted about its own count.
//
// WHAT EVERY ARM SHARES. A fresh pair of module handles, a `ResidentMerkleWriteOperations` and a
// `ResidentContractsDB` over them, `WasmAvmPublicTxSimulator` over the same pair, and upstream's
// `PublicProcessor` constructed around all of it by `createBlockProcessor`. Nothing below reaches
// past the processor: every checkpoint, every dispatch and every revert is upstream's loop.
//
// THE STATE REFERENCE BEFORE EACH TRANSACTION IS RECORDED THROUGH UPSTREAM'S OWN HOOK.
// `PublicProcessor.process` takes a `PublicProcessorValidator` whose `preprocessValidator
// .validateTx(tx)` it awaits immediately before processing each transaction. That is the only
// point inside the loop a caller can observe, and it is upstream's, so recording the state
// reference there costs no edit to a vendored file. The recorded sequence is what makes
// `test_failed_tx_leaves_no_state` a test of what the NEXT transaction saw, rather than of
// whether an error was thrown.
//
// THE SEEDS ARE ALL >= 2000 AND DISTINCT, FOR M20'S MEASURED REASON. `mockTx(seed, …)` derives its
// private nullifiers as `seed + 1` / `seed + 2` and the resident nullifier tree is prefilled with
// the protocol's genesis nullifiers — every value up to at least 102 is already there. A seed
// under a hundred makes every arm collide and the suite reports "thrown out" for the case that is
// supposed to land. Two transactions in one block sharing a seed would collide with EACH OTHER,
// which is a different way to get the same wrong answer, so the seeds are distinct per block as
// well as high.

import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { DateProvider } from '@aztec/foundation/timer';
import { Fr } from '@aztec/foundation/curves/bn254';
import { GasFees } from '@aztec/stdlib/gas';
import { MerkleTreeId } from '@aztec/stdlib/trees';
import { GlobalVariables, type Tx } from '@aztec/stdlib/tx';
import { mockTx } from '@aztec/stdlib/testing';

import { assembleBlock, createBlockProcessor, sealBlock } from './block_assembly.ts';
import { decodePublicTxResult, residentWorldStateRevision } from './avm_inputs.ts';
import { defaultPublicSimulatorConfig, feeJuiceBalanceLeafSlot, fundFeeJuice } from './fee_juice.ts';
import { encodeForShippedModuleOnly } from './shipped_module_config.ts';
import { ResidentContractsDB } from './resident_contracts_db.ts';
import { ResidentMerkleDb } from './resident_db.ts';
import { ResidentMerkleWriteOperations, residentModuleHasArchive } from './resident_merkle_operations.ts';
import { WasmAvmPublicTxSimulator } from './wasm_avm_public_tx_simulator.ts';

interface ReactorLike {
  createContractDb(): number;
  createMerkleDb(): number;
  destroyContractDb(handle: number): void;
  destroyMerkleDb(handle: number): void;
  callWithBlob(exportName: string, handle: number, blob: Uint8Array): unknown;
  callWithHandle(exportName: string, handle: number): unknown;
  simulate(input: Uint8Array, contractDb: number, merkleDb: number): { revertCode: number; result: unknown };
  result(): Uint8Array | null;
  readonly moduleCalls: number;
}

const FUNDING = new Fr(10n ** 12n);

/** One transaction in a block. `setup` moves the failing call into the phase that throws it out. */
interface TxSpec {
  readonly label: string;
  readonly seed: number;
  readonly fund: boolean;
  /** `appLogic` lands as a soft revert; `setup` is thrown out; both call an unregistered contract. */
  readonly phase: 'appLogic' | 'setup';
}

function armGlobals(): GlobalVariables {
  // Non-zero gas fees, for M20's measured reason: with `GlobalVariables.empty()` the transaction
  // fee computes to zero, every balance is sufficient including the empty one, and the unfunded
  // case lands — so a suite built on it would assert fee enforcement while never exercising it.
  const empty = GlobalVariables.empty();
  return GlobalVariables.from({ ...empty, gasFees: new GasFees(1n, 1n) });
}

async function feePayerFor(seed: number): Promise<AztecAddress> {
  return await AztecAddress.fromField(new Fr(BigInt(8_000_000 + seed)));
}

async function buildTx(spec: TxSpec): Promise<{ tx: Tx; feePayer: AztecAddress }> {
  const feePayer = await feePayerFor(spec.seed);
  const tx = await mockTx(spec.seed, {
    numberOfNonRevertiblePublicCallRequests: spec.phase === 'setup' ? 1 : 0,
    numberOfRevertiblePublicCallRequests: spec.phase === 'appLogic' ? 1 : 0,
    hasPublicTeardownCallRequest: false,
    feePayer,
  });
  return { tx, feePayer };
}

/** Everything one block run needs, torn down together. */
interface BlockWorld {
  readonly merkleDb: ResidentMerkleWriteOperations;
  readonly contractsDb: ResidentContractsDB;
  readonly seeding: ResidentMerkleDb;
  readonly simulator: WasmAvmPublicTxSimulator;
  readonly release: () => void;
}

function openWorld(reactor: ReactorLike, globals: GlobalVariables): BlockWorld {
  const contractDbHandle = reactor.createContractDb();
  const merkleDbHandle = reactor.createMerkleDb();
  const merkleDb = new ResidentMerkleWriteOperations(reactor, merkleDbHandle);
  const contractsDb = new ResidentContractsDB(reactor, contractDbHandle);
  const seeding = new ResidentMerkleDb(reactor, merkleDbHandle);
  const config = defaultPublicSimulatorConfig();
  const simulator = new WasmAvmPublicTxSimulator(
    {
      simulate: (input, c, m) => reactor.simulate(input, c, m),
      get moduleCalls() {
        return reactor.moduleCalls;
      },
    },
    { contractDb: contractDbHandle, merkleDb: merkleDbHandle },
    globals,
    (t, g) => encodeForShippedModuleOnly(t, g, config, residentWorldStateRevision(1)),
    () => decodePublicTxResult(reactor.result()!),
  );
  return {
    merkleDb,
    contractsDb,
    seeding,
    simulator,
    release: () => {
      reactor.destroyMerkleDb(merkleDbHandle);
      reactor.destroyContractDb(contractDbHandle);
    },
  };
}

/** The observation hook: upstream's own pre-process validator, used only to record. */
function recordingValidator(sink: Array<{ label: string; stateReference: string }>, world: BlockWorld, labels: Map<string, string>) {
  return {
    preprocessValidator: {
      validateTx: async (tx: Tx) => {
        const ref = await world.merkleDb.getStateReference();
        sink.push({
          label: labels.get(tx.getTxHash().toString()) ?? tx.getTxHash().toString(),
          stateReference: ref.toBuffer().toString('hex'),
        });
        return { result: 'valid' as const };
      },
    },
  };
}

export interface BlockRunReport {
  readonly arm: string;
  readonly submitted: readonly string[];
  readonly processed: readonly string[];
  readonly failed: readonly { label: string; message: string }[];
  readonly unprocessed: readonly string[];
  /** The state reference recorded immediately before each transaction, in order. */
  readonly observedBefore: readonly { label: string; stateReference: string }[];
  /** The four-tree state reference after the block. */
  readonly stateReferenceAfter: string;
  /** Fee-payer balances after the block, by transaction label. */
  readonly balancesAfter: Readonly<Record<string, string | null>>;
  readonly totalL2Gas: number;
  /** Blob fields the block's processed transactions carry. The quantity `maxBlobFields` limits. */
  readonly totalBlobFields: number;
  /** What the deferred contract registrations flushed. Zero here, and asserted to be. */
  readonly registrations: unknown;
  readonly seal: unknown;
}

async function runBlock(
  reactor: ReactorLike,
  arm: string,
  specs: readonly TxSpec[],
  limits: Record<string, unknown>,
  opts: { seal?: boolean; requeue?: boolean } = {},
): Promise<BlockRunReport & { requeued?: BlockRunReport }> {
  const globals = armGlobals();
  const world = openWorld(reactor, globals);
  try {
    const labels = new Map<string, string>();
    const built: { spec: TxSpec; tx: Tx; feePayer: AztecAddress }[] = [];
    for (const spec of specs) {
      const { tx, feePayer } = await buildTx(spec);
      labels.set(tx.getTxHash().toString(), spec.label);
      if (spec.fund) {
        await fundFeeJuice(world.seeding, feePayer, FUNDING);
      }
      built.push({ spec, tx, feePayer });
    }

    const observed: Array<{ label: string; stateReference: string }> = [];
    const { processor, guarded } = createBlockProcessor(
      globals,
      world.merkleDb,
      world.contractsDb,
      world.simulator,
      new DateProvider(),
    );

    const block = await assembleBlock(
      processor,
      built.map(b => b.tx),
      world.contractsDb,
      world.merkleDb,
      { limits: limits as never, validator: recordingValidator(observed, world, labels) as never },
    );

    const balances: Record<string, string | null> = {};
    for (const b of built) {
      balances[b.spec.label] = world.seeding.readPublicDataLeaf(await feeJuiceBalanceLeafSlot(b.feePayer));
    }

    let seal: unknown = null;
    if (opts.seal !== false) {
      seal = await sealBlock(guarded, globals);
    } else {
      await guarded.stop();
    }

    const labelOf = (tx: Tx) => labels.get(tx.getTxHash().toString()) ?? '?';
    const report: BlockRunReport = {
      arm,
      submitted: built.map(b => b.spec.label),
      processed: block.processed.map(p => labels.get(p.hash.toString()) ?? p.hash.toString()),
      failed: block.failed.map(f => ({ label: labelOf(f.tx), message: f.error.message.slice(0, 240) })),
      unprocessed: block.unprocessed.map(labelOf),
      observedBefore: observed,
      stateReferenceAfter: block.stateReference.toBuffer().toString('hex'),
      balancesAfter: balances,
      totalL2Gas: block.processed.reduce((acc, p) => acc + Number(p.gasUsed.totalGas.l2Gas), 0),
      totalBlobFields: block.processed.reduce((acc, p) => acc + Number(p.txEffect.getNumBlobFields()), 0),
      registrations: { classes: block.registrations.classes, instances: block.registrations.instances },
      seal: seal === null ? null : JSON.parse(JSON.stringify(seal, (_k, v) => (typeof v === 'bigint' ? v.toString() : v))),
    };
    return report;
  } finally {
    world.release();
  }
}

/**
 * The guard arm, which needs its own shape because it asserts what happens AFTER the seal.
 *
 * THE UNGUARDED CONTROL IS THE POINT. A check that only observed the refusal would be measuring
 * an absence — it could not tell "the guard stopped this" from "this database answers nothing".
 * So the same call is made three times: through the guard before the seal (answers), through the
 * guard after the seal (refused, with upstream's own message), and directly on the resident
 * database after the seal (answers, because the guard is a gate and not a demolition).
 */
async function runGuardArm(reactor: ReactorLike): Promise<Record<string, unknown>> {
  const globals = armGlobals();
  const world = openWorld(reactor, globals);
  try {
    const { processor, guarded } = createBlockProcessor(
      globals,
      world.merkleDb,
      world.contractsDb,
      world.simulator,
      new DateProvider(),
    );
    const { tx } = await buildTx({ label: 'g1', seed: 2601, fund: true, phase: 'appLogic' });
    await fundFeeJuice(world.seeding, await feePayerFor(2601), FUNDING);
    await assembleBlock(processor, [tx], world.contractsDb, world.merkleDb, {});

    const beforeSeal = await attempt(() => guarded.getStateReference());
    const seal = await sealBlock(guarded, globals);
    const afterSealGuarded = await attempt(() => guarded.getStateReference());
    const afterSealUnguarded = await attempt(() => world.merkleDb.getStateReference());
    // THE TREE ID IS THE ENUM AND NOT A LITERAL, and this line is why the rule exists: the first
    // revision wrote `3 /* NOTE_HASH_TREE */`, and 3 is `L1_TO_L2_MESSAGE_TREE`. The assertion
    // passed anyway, because the guard refuses before any tree dispatch — so a wrong tree id was
    // invisible to the check that used it, which is the shape of every magic number this campaign
    // has been bitten by.
    const afterSealWriteGuarded = await attempt(() =>
      guarded.appendLeaves(MerkleTreeId.NOTE_HASH_TREE as never, [new Fr(7n)] as never),
    );

    const exportNames = moduleExportNames(reactor);
    return {
      beforeSeal,
      seal: JSON.parse(JSON.stringify(seal)),
      afterSealGuarded,
      afterSealUnguarded,
      afterSealWriteGuarded,
      archiveExportPresent: residentModuleHasArchive(exportNames),
      // The control for that absence: a name that IS in the export list, found by the same lookup.
      knownExportPresent: exportNames.includes('avm_merkle_db_get_tree_roots'),
      exportCount: exportNames.length,
    };
  } finally {
    world.release();
  }
}

/** Every export the module declares. Read off the instance the reactor already holds. */
function moduleExportNames(reactor: ReactorLike): string[] {
  const anyReactor = reactor as unknown as { exports?: Record<string, unknown>; instance?: { exports?: Record<string, unknown> } };
  const exports = anyReactor.exports ?? anyReactor.instance?.exports;
  return exports ? Object.keys(exports) : [];
}

async function attempt(fn: () => unknown | Promise<unknown>): Promise<{ ok: boolean; value?: string; error?: string; name?: string }> {
  try {
    const v = await fn();
    return { ok: true, value: v === undefined ? 'undefined' : String((v as { toString(): string }).toString()).slice(0, 80) };
  } catch (error) {
    return { ok: false, error: (error as Error).message.slice(0, 200), name: (error as Error).name };
  }
}

/**
 * Every arm.
 *
 * EACH LIMIT HAS ITS OWN DISCRIMINATOR — a block that STOPS at the limit and one that does NOT
 * REACH it — because a limit arm on its own passes against a processor that stops after two
 * transactions for any reason at all.
 */
export async function runBlockArms(reactor: ReactorLike): Promise<Record<string, unknown>> {
  const four: readonly TxSpec[] = [
    { label: 't1', seed: 2011, fund: true, phase: 'appLogic' },
    { label: 't2', seed: 2021, fund: true, phase: 'appLogic' },
    { label: 't3', seed: 2031, fund: true, phase: 'appLogic' },
    { label: 't4', seed: 2041, fund: true, phase: 'appLogic' },
  ];

  // The failure arm and its control differ in ONE thing: t2's failing call sits in SETUP (thrown
  // out) or in APP_LOGIC (soft revert, lands, pays its fee). Everything else — seeds, funding,
  // order — is identical, so a difference in what t3 saw is attributable to that and to nothing
  // else.
  const failing: readonly TxSpec[] = [
    { label: 'f1', seed: 2111, fund: true, phase: 'appLogic' },
    { label: 'f2', seed: 2121, fund: true, phase: 'setup' },
    { label: 'f3', seed: 2131, fund: true, phase: 'appLogic' },
  ];
  const control: readonly TxSpec[] = [
    { label: 'f1', seed: 2111, fund: true, phase: 'appLogic' },
    { label: 'f2', seed: 2121, fund: true, phase: 'appLogic' },
    { label: 'f3', seed: 2131, fund: true, phase: 'appLogic' },
  ];

  const noLimits = await runBlock(reactor, 'noLimits', four, {});
  const maxTwo = await runBlock(reactor, 'maxTransactionsTwo', four, { maxTransactions: 2 });
  const maxTen = await runBlock(reactor, 'maxTransactionsTen', four, { maxTransactions: 10 });

  // The gas limit is set from what the unlimited block actually used, so the arm cannot be
  // satisfied by a number that happens to be small. `perTx` is the mean of the block that ran.
  const perTx = noLimits.totalL2Gas > 0 ? Math.floor(noLimits.totalL2Gas / Math.max(1, noLimits.processed.length)) : 0;
  const gasStops = await runBlock(reactor, 'maxBlockGasStops', four, {
    maxBlockGas: { daGas: 1_000_000_000, l2Gas: Math.max(1, perTx * 2 + Math.floor(perTx / 2)) },
  });
  const gasRoomy = await runBlock(reactor, 'maxBlockGasRoomy', four, {
    maxBlockGas: { daGas: 1_000_000_000, l2Gas: Math.max(1, noLimits.totalL2Gas * 4) },
  });

  // maxBlobFields, derived the same way the gas limit is. The post-processing arm of upstream's
  // check fires on `maxBlobFields !== undefined` WITHOUT `isBuildingProposal`, reverting the
  // transaction's checkpoint and continuing — upstream calls that "silently skipped" — so a skipped
  // transaction is neither processed nor failed and lands in the unprocessed set, requeueable in a
  // larger block. A hand-typed limit would eventually stop the block for the wrong reason; this one
  // is two and a half transactions' worth of what the unlimited block actually carried.
  const perTxBlob = noLimits.totalBlobFields > 0
    ? Math.floor(noLimits.totalBlobFields / Math.max(1, noLimits.processed.length))
    : 0;
  const blobStops = await runBlock(reactor, 'maxBlobFieldsStops', four, {
    maxBlobFields: Math.max(1, perTxBlob * 2 + Math.floor(perTxBlob / 2)),
  });
  const blobRoomy = await runBlock(reactor, 'maxBlobFieldsRoomy', four, {
    maxBlobFields: Math.max(1, noLimits.totalBlobFields * 4),
  });

  const abortedController = new AbortController();
  abortedController.abort();
  const aborted = await runBlock(reactor, 'signalAborted', four, { signal: abortedController.signal });
  const notAborted = await runBlock(reactor, 'signalOpen', four, { signal: new AbortController().signal });

  const pastDeadline = await runBlock(reactor, 'deadlinePast', four, { deadline: new Date(Date.now() - 60_000) });
  const futureDeadline = await runBlock(reactor, 'deadlineFuture', four, { deadline: new Date(Date.now() + 3_600_000) });

  // REQUEUEABLE IS A POSITIVE CLAIM AND IS MADE POSITIVELY: the two transactions the
  // maxTransactions arm did not reach are submitted again, in a fresh block, and must process.
  const requeued = await runBlock(
    reactor,
    'requeuedFromMaxTransactionsTwo',
    four.filter(s => maxTwo.unprocessed.includes(s.label)),
    {},
  );

  const failedArm = await runBlock(reactor, 'failedTxIsolated', failing, {});
  const controlArm = await runBlock(reactor, 'failedTxControl', control, {});

  const guard = await runGuardArm(reactor);

  return {
    noLimits,
    maxTwo,
    maxTen,
    gasStops,
    gasRoomy,
    blobStops,
    blobRoomy,
    aborted,
    notAborted,
    pastDeadline,
    futureDeadline,
    requeued,
    failedArm,
    controlArm,
    guard,
    perTxL2Gas: perTx,
    perTxBlobFields: perTxBlob,
  };
}
