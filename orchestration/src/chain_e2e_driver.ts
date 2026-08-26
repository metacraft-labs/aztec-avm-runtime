// chain_e2e_driver.ts — M23's chain arms, driven end to end against the real `avm.wasm`.
//
// A DRIVER AND NOT A TEST, the campaign's split: it prints one JSON object and exits 0, and the
// assertions live in `verification/`. A driver that asserted would have to be trusted about its
// own count.
//
// ONE MODULE INSTANTIATION, EVERY ARM, for M20's and M22's reason: two checks each deriving "the
// archive root after three blocks" from their own run is how two checks come to disagree about a
// number nothing changed.
//
// IT NEEDS A MODULE WITH THE ARCHIVE. Every arm here seals blocks, and a seal reads and writes the
// archive tree, so the arms require a module built from M23's overlay stack
// (`verification/m23/0001-*.patch` over M14's over M13's). `lib_m23_chain.sh` refuses a module
// without the two archive exports rather than reporting a chain that never chained.
//
// THE SEEDS ARE >= 2000 AND DISTINCT, for M20's measured reason, restated because it is easy to
// undo: `mockTx(seed, …)` derives its private nullifiers as `seed + 1` / `seed + 2`, and the
// resident nullifier tree is prefilled with the protocol's genesis nullifiers up to at least 102.
// A low seed makes every arm collide and every case report "thrown out", including the ones that
// are supposed to land.

import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { Fr } from '@aztec/foundation/curves/bn254';
import { GasFees } from '@aztec/stdlib/gas';
import { AppendOnlyTreeSnapshot, MerkleTreeId } from '@aztec/stdlib/trees';
import { BlockHeader, PartialStateReference, StateReference } from '@aztec/stdlib/tx';
import { GlobalVariables, Tx } from '@aztec/stdlib/tx';
import { mockTx } from '@aztec/stdlib/testing';

import { createBlockProcessor } from './block_assembly.ts';
import { decodePublicTxResult, residentWorldStateRevision } from './avm_inputs.ts';
import { defaultPublicSimulatorConfig, fundFeeJuice } from './fee_juice.ts';
import { encodeForShippedModuleOnly } from './shipped_module_config.ts';
import { ResidentContractsDB } from './resident_contracts_db.ts';
import { ResidentMerkleDb } from './resident_db.ts';
import { ResidentMerkleWriteOperations } from './resident_merkle_operations.ts';
import { WasmAvmPublicTxSimulator } from './wasm_avm_public_tx_simulator.ts';
import { AvmChain, type ChainBlock } from './chain.ts';
import { AvmRuntime } from './avm_runtime.ts';
import { DateProvider, ManualDateProvider, ManualTicker, RunningPromiseTicker } from './chain_clock.ts';

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
  readonly exportNames: readonly string[];
}

const FUNDING = new Fr(10n ** 12n);

function armGlobals(): GlobalVariables {
  const empty = GlobalVariables.empty();
  return GlobalVariables.from({ ...empty, gasFees: new GasFees(1n, 1n) });
}

interface World {
  readonly merkleDb: ResidentMerkleWriteOperations;
  readonly contractsDb: ResidentContractsDB;
  readonly seeding: ResidentMerkleDb;
  readonly simulator: WasmAvmPublicTxSimulator;
  readonly release: () => void;
}

function openWorld(reactor: ReactorLike): World {
  const contractDbHandle = reactor.createContractDb();
  const merkleDbHandle = reactor.createMerkleDb();
  const merkleDb = new ResidentMerkleWriteOperations(reactor, merkleDbHandle);
  const contractsDb = new ResidentContractsDB(reactor, contractDbHandle);
  const seeding = new ResidentMerkleDb(reactor, merkleDbHandle);
  const config = defaultPublicSimulatorConfig();
  const globals = armGlobals();
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

function chainDeps(world: World, clock: DateProvider, ticker?: unknown) {
  return {
    merkleDb: world.merkleDb,
    contractsDb: world.contractsDb,
    makeProcessor: (globals: GlobalVariables) =>
      createBlockProcessor(globals, world.merkleDb, world.contractsDb, world.simulator, new DateProvider()),
    clock,
    ticker: ticker as never,
    simulator: world.simulator,
    publicDataTree: world.seeding,
  };
}

/** What every arm reports about a block, in a shape a shell check can compare as strings. */
function blockRow(b: ChainBlock) {
  return {
    number: b.number,
    timestamp: b.timestamp.toString(),
    wallClockSeconds: b.wallClockSeconds.toString(),
    wallClockDeviationSeconds: b.wallClockDeviationSeconds.toString(),
    empty: b.empty,
    archiveBefore: { root: b.archiveBefore.root.toString(), size: Number(b.archiveBefore.nextAvailableLeafIndex) },
    archiveAfter: { root: b.archiveAfter.root.toString(), size: Number(b.archiveAfter.nextAvailableLeafIndex) },
    lastArchive: {
      root: b.header.lastArchive.root.toString(),
      size: Number(b.header.lastArchive.nextAvailableLeafIndex),
    },
    stateReference: b.stateReference.toBuffer().toString('hex'),
    txHashes: [...b.txHashes],
    l1ToL2Messages: [...b.l1ToL2Messages],
    blockNumberInGlobals: Number(b.globalVariables.blockNumber),
  };
}

async function fundedTx(world: World, seed: number): Promise<Tx> {
  const feePayer = await AztecAddress.fromField(new Fr(BigInt(8_000_000 + seed)));
  const tx = await mockTx(seed, {
    numberOfNonRevertiblePublicCallRequests: 0,
    numberOfRevertiblePublicCallRequests: 1,
    hasPublicTeardownCallRequest: false,
    feePayer,
  });
  await fundFeeJuice(world.seeding, feePayer, FUNDING);
  return tx;
}

// ---------------------------------------------------------------------------------------------
// The arms.
// ---------------------------------------------------------------------------------------------

/** THREE EMPTY BLOCKS. Numbers advance, timestamps advance, the archive advances every time. */
async function armEmptyBlocks(reactor: ReactorLike) {
  const world = openWorld(reactor);
  try {
    const clock = new ManualDateProvider(0);
    const chain = new AvmChain(chainDeps(world, clock), { intervalMs: 0, produceEmptyBlocks: true });
    const genesisArchive = chain.archive();
    const blocks: ChainBlock[] = [];
    for (let i = 0; i < 3; i++) {
      clock.advanceTime(1);
      const b = await chain.produceBlock();
      blocks.push(b!);
    }
    return {
      genesisArchive: { root: genesisArchive.root.toString(), size: Number(genesisArchive.nextAvailableLeafIndex) },
      blocks: blocks.map(blockRow),
      headerHashes: await Promise.all(blocks.map(async b => (await b.header.hash()).toString())),
      finalBlockNumber: chain.blockNumber,
    };
  } finally {
    world.release();
  }
}

/**
 * SUB-SECOND INTERVAL AND A THROTTLED TIMER, on a manual clock so the two are the same experiment.
 *
 * A sub-second interval means the wall clock does not move between blocks; a throttled tab means
 * it moves in a jump and then not at all. Both are produced here by controlling the clock rather
 * than by waiting, which is the only way to make "the tab was throttled" reproducible.
 */
async function armSubSecondTimestamps(reactor: ReactorLike) {
  const world = openWorld(reactor);
  try {
    const clock = new ManualDateProvider(1_000_000_000_000);
    const chain = new AvmChain(chainDeps(world, clock), { intervalMs: 0, minBlockSpacingSeconds: 1 });
    // `dev` IS THE DECLARED DEVIATION AND IT IS RECORDED HERE BECAUSE THIS IS THE ONLY ARM WHERE IT
    // IS NON-ZERO. M23's review measured that the identity `timestamp - wallClockSeconds ==
    // wallClockDeviationSeconds` was asserted only over `emptyBlocks`, where a clock advanced one
    // second per block makes every term zero — so replacing the field with a constant `0n` passed
    // the WHOLE milestone green, 491 assertions and zero failures. Both sides were read and both
    // were zero, which is the vacuous-comparison shape by data rather than by key.
    const rows: { advancedMs: number; timestamp: string; wall: string; dev: string }[] = [];
    const row = (advancedMs: number, b: ChainBlock) => ({
      advancedMs,
      timestamp: b.timestamp.toString(),
      wall: b.wallClockSeconds.toString(),
      dev: b.wallClockDeviationSeconds.toString(),
    });
    // Ten blocks at 100 ms: the wall clock's SECOND changes only every tenth block.
    for (let i = 0; i < 10; i++) {
      clock.advanceTimeMs(100);
      rows.push(row(100, (await chain.produceBlock())!));
    }
    // Then a throttle: the clock jumps 30 s at once and then stalls for five blocks.
    clock.advanceTime(30);
    for (let i = 0; i < 5; i++) {
      rows.push(row(0, (await chain.produceBlock())!));
    }
    const ts = rows.map(r => BigInt(r.timestamp));
    let strictlyIncreasing = true;
    for (let i = 1; i < ts.length; i++) {
      if (ts[i] <= ts[i - 1]) {
        strictlyIncreasing = false;
      }
    }
    const repeats = new Set(rows.map(r => r.timestamp)).size !== rows.length;
    return { rows, strictlyIncreasing, repeats, count: rows.length };
  } finally {
    world.release();
  }
}

/**
 * A HUNDRED BLOCKS ON A FAKE CLOCK, and the same hundred on a real timer.
 *
 * The comparison is the assertion: identical block numbers, identical timestamps and an identical
 * archive root at the end. The real-timer arm uses a 1 ms interval so the wall-clock cost is
 * bounded; it still goes through `RunningPromise`, so what is compared is a fake ticker against
 * upstream's real one and not against a second fake.
 */
async function armHundredBlocks(reactor: ReactorLike) {
  const fake = openWorld(reactor);
  let fakeOut: { blocks: number; lastTimestamp: string; archive: string; elapsedMs: number };
  try {
    const clock = new ManualDateProvider(0);
    const ticker = new ManualTicker();
    const chain = new AvmChain(chainDeps(fake, clock, ticker), { intervalMs: 0, minBlockSpacingSeconds: 1 });
    chain.start();
    const t0 = performance.now();
    for (let i = 0; i < 100; i++) {
      clock.advanceTime(1);
      await ticker.tick();
    }
    const a = chain.archive();
    fakeOut = {
      blocks: chain.blockNumber,
      lastTimestamp: chain.lastBlockTimestamp.toString(),
      archive: a.root.toString(),
      elapsedMs: Math.round(performance.now() - t0),
    };
    await chain.stop();
  } finally {
    fake.release();
  }

  const real = openWorld(reactor);
  try {
    // The same clock discipline, driven by upstream's `RunningPromise` at 1 ms. The CLOCK is still
    // manual: what this arm varies is the TICKER, so a difference is attributable to it.
    const clock = new ManualDateProvider(0);
    const ticker = new RunningPromiseTicker(1);
    const chain = new AvmChain(chainDeps(real, clock, ticker), { intervalMs: 1, minBlockSpacingSeconds: 1 });
    const seen: number[] = [];
    chain.subscribe('block', b => seen.push(b.number));
    const done = new Promise<void>(resolve => {
      const off = chain.subscribe('block', b => {
        if (b.number >= 100) {
          off();
          resolve();
        }
      });
    });
    const t0 = performance.now();
    chain.start();
    // The clock has to move for the timestamps to match the fake arm; it is advanced from the
    // block subscription so the two arms see exactly the same sequence.
    chain.subscribe('block', () => clock.advanceTime(1));
    clock.advanceTime(1);
    await done;
    await chain.stop();
    const a = chain.archive();
    return {
      fake: fakeOut,
      real: {
        blocks: chain.blockNumber,
        lastTimestamp: chain.lastBlockTimestamp.toString(),
        archive: a.root.toString(),
        elapsedMs: Math.round(performance.now() - t0),
        ticks: ticker.ticks,
      },
      identical:
        fakeOut.blocks === chain.blockNumber
        && fakeOut.lastTimestamp === chain.lastBlockTimestamp.toString()
        && fakeOut.archive === a.root.toString(),
    };
  } finally {
    real.release();
  }
}

/** AUTOMINE ON AND OFF, the discriminator: with it on, submitting seals; with it off, it does not. */
async function armAutomine(reactor: ReactorLike) {
  const on = openWorld(reactor);
  let onRow: unknown;
  try {
    const clock = new ManualDateProvider(0);
    const chain = new AvmChain(chainDeps(on, clock), { intervalMs: 0, automine: true });
    const tx = await fundedTx(on, 2401);
    const before = chain.blockNumber;
    await chain.submit(tx);
    onRow = {
      before,
      after: chain.blockNumber,
      pending: chain.pending.length,
      lastBlockTxs: chain.blocks[chain.blocks.length - 1]?.txHashes.length ?? -1,
      lastBlockEmpty: chain.blocks[chain.blocks.length - 1]?.empty ?? null,
    };
  } finally {
    on.release();
  }

  const off = openWorld(reactor);
  try {
    const clock = new ManualDateProvider(0);
    const chain = new AvmChain(chainDeps(off, clock), { intervalMs: 0, automine: false });
    const tx = await fundedTx(off, 2501);
    const before = chain.blockNumber;
    await chain.submit(tx);
    const afterSubmit = chain.blockNumber;
    const pendingAfterSubmit = chain.pending.length;
    const b = await chain.produceBlock();
    return {
      automineOn: onRow,
      automineOff: {
        before,
        afterSubmit,
        pendingAfterSubmit,
        afterTick: chain.blockNumber,
        tickBlockTxs: b?.txHashes.length ?? -1,
      },
    };
  } finally {
    off.release();
  }
}

/**
 * AN L1-TO-L2 MESSAGE, injected and then visible at the next boundary.
 *
 * Two things are measured and they are different claims: the message is NOT in the tree while it
 * is only injected, and it IS a leaf of the L1→L2 message tree after the next block. The leaf is
 * read back BY INDEX out of the module — `avm_merkle_db_get_leaf_value` — rather than inferred
 * from the root moving, because a root moving says something changed and not what.
 */
async function armL1ToL2(reactor: ReactorLike) {
  const world = openWorld(reactor);
  try {
    const clock = new ManualDateProvider(0);
    const chain = new AvmChain(chainDeps(world, clock), { intervalMs: 0 });
    // THE TREE ID COMES FROM THE ENUM. M22's seventh defect was a magic number whose comment was
    // wrong — `3 /* NOTE_HASH_TREE */` where NOTE_HASH_TREE is 1 and 3 is L1_TO_L2_MESSAGE_TREE —
    // and it passed, because the call refused before any tree dispatch. Nothing here refuses, so
    // the same mistake would silently measure the public-data tree instead.
    const tree = MerkleTreeId.L1_TO_L2_MESSAGE_TREE;
    const leaf = new Fr(0x51n * 0x100000001n);
    const before = await world.merkleDb.getTreeInfo(tree);
    chain.injectL1ToL2Message(leaf);
    const afterInject = await world.merkleDb.getTreeInfo(tree);
    const block = (await chain.produceBlock())!;
    const afterBlock = await world.merkleDb.getTreeInfo(tree);
    const readBack = await world.merkleDb.getLeafValue(tree, before.size);
    return {
      leaf: leaf.toString(),
      sizeBefore: Number(before.size),
      sizeAfterInject: Number(afterInject.size),
      sizeAfterBlock: Number(afterBlock.size),
      rootBefore: '0x' + before.root.toString('hex'),
      rootAfterInject: '0x' + afterInject.root.toString('hex'),
      rootAfterBlock: '0x' + afterBlock.root.toString('hex'),
      treeId: tree,
      treeIdName: MerkleTreeId[tree],
      leafReadBack: readBack === undefined || readBack === null ? 'MISSING' : String(readBack),
      blockMessages: [...block.l1ToL2Messages],
      // The message is a leaf of the block AFTER injection, not of the state the injection saw.
      blockNumber: block.number,
    };
  } finally {
    world.release();
  }
}

/** THE §8.4 DISCLOSURE, including that a discarding sink does not stop the record. */
async function armDisclosure(reactor: ReactorLike) {
  const world = openWorld(reactor);
  try {
    const spoken: string[] = [];
    const runtime = AvmRuntime.create(chainDeps(world, new ManualDateProvider(0)) as never, {
      production: { intervalMs: 0 },
      disclosureSink: line => spoken.push(line),
    });
    const tx = await fundedTx(world, 2601);
    const receipt = await runtime.submitExternal(tx);
    const block = await runtime.produceBlock();
    // Re-read after the block: a receipt is a value taken at a moment, and with automine off that
    // moment is before any block exists. Both are reported so `queued` -> `processed` is visible.
    const settled = runtime.receiptFor(receipt.txHash);
    const sim = await runtime.simulateTx(await fundedTx(world, 2701));

    // The control: a sink that discards. The record must still be there.
    const silent = AvmRuntime.create(chainDeps(world, new ManualDateProvider(0)) as never, {
      production: { intervalMs: 0 },
      disclosureSink: () => {},
    });

    return {
      spoken,
      disclosure: { ...runtime.disclosure },
      silentDisclosure: { ...silent.disclosure },
      receipt: {
        simulated: receipt.simulated,
        protocolVersion: receipt.protocolVersion,
        proving: receipt.proving,
        outcomeKind: receipt.outcome.kind,
      },
      settledReceipt: {
        simulated: settled.simulated,
        protocolVersion: settled.protocolVersion,
        proving: settled.proving,
        outcomeKind: settled.outcome.kind,
        blockNumber: settled.blockNumber,
      },
      simulation: { simulated: sim.simulated, protocolVersion: sim.protocolVersion, proving: sim.proving },
      blockNumber: block?.number ?? -1,
    };
  } finally {
    world.release();
  }
}

/**
 * EXPORT AND IMPORT, into a SECOND world state that shares nothing with the first.
 *
 * The two runtimes hold different module handles, so the second one's trees start at genesis and
 * everything it reaches is produced by the replay. What is compared is the state reference, the
 * block number and the archive root — the three things that make one chain the same chain as
 * another.
 */
async function armSnapshotRoundtrip(reactor: ReactorLike) {
  const first = openWorld(reactor);
  let snapshot: unknown;
  let source: { blocks: number; archive: string; stateReference: string; timestamps: string[] };
  try {
    const clock = new ManualDateProvider(0);
    const runtime = AvmRuntime.create(chainDeps(first, clock) as never, {
      production: { intervalMs: 0 },
      disclosureSink: () => {},
    });
    // THE FUNDING GOES THROUGH THE RUNTIME, not through `world.seeding`, because the snapshot
    // records what the RUNTIME did. Funding the fee payer behind the facade's back is what made
    // the first version of this arm come back non-identical: the replay's transaction was thrown
    // out for an insufficient balance and the state diverged by a whole block's worth of effects.
    const feePayer = await AztecAddress.fromField(new Fr(BigInt(8_000_000 + 2801)));
    await runtime.fundFeeJuice(feePayer, FUNDING);
    const tx = await mockTx(2801, {
      numberOfNonRevertiblePublicCallRequests: 0,
      numberOfRevertiblePublicCallRequests: 1,
      hasPublicTeardownCallRequest: false,
      feePayer,
    });
    clock.advanceTime(1);
    await runtime.submitExternal(tx);
    clock.advanceTime(1);
    await runtime.produceBlock();
    runtime.injectL1ToL2Message(new Fr(777n));
    clock.advanceTime(1);
    await runtime.produceBlock();
    clock.advanceTime(1);
    await runtime.produceBlock();
    snapshot = runtime.exportSnapshot();
    const a = runtime.archive();
    source = {
      blocks: runtime.blockNumber,
      archive: a.root.toString(),
      stateReference: (await runtime.stateReference()).toBuffer().toString('hex'),
      timestamps: runtime.blocks.map(b => b.timestamp.toString()),
    };
  } finally {
    first.release();
  }

  const second = openWorld(reactor);
  try {
    const clock = new ManualDateProvider(0);
    const runtime = AvmRuntime.create(chainDeps(second, clock) as never, {
      production: { intervalMs: 0 },
      disclosureSink: () => {},
    });
    await runtime.importSnapshot(
      snapshot as never,
      async bytes => await Tx.fromBuffer(bytes),
      async s => await AztecAddress.fromString(s),
      s => Fr.fromString(s),
    );
    const a = runtime.archive();
    const reloaded = {
      blocks: runtime.blockNumber,
      archive: a.root.toString(),
      stateReference: (await runtime.stateReference()).toBuffer().toString('hex'),
      timestamps: runtime.blocks.map(b => b.timestamp.toString()),
    };
    return {
      snapshot,
      source,
      reloaded,
      identical:
        source.blocks === reloaded.blocks
        && source.archive === reloaded.archive
        && source.stateReference === reloaded.stateReference,
    };
  } finally {
    second.release();
  }
}

/**
 * THE ARCHIVE'S OWN PROPERTIES, measured against upstream's published genesis constants.
 *
 * This is the arm that makes "the archive is carried" a measurement rather than a build log: the
 * archive's first leaf is computed in C++ by `compute_initial_block_header_hash` and compared with
 * `GENESIS_BLOCK_HEADER_HASH`, which upstream publishes in TypeScript, and the archive's root at
 * size one is compared with `GENESIS_ARCHIVE_ROOT` from `@aztec/constants`.
 *
 * The refusal arm is here too: a header whose four-tree state reference is NOT the world state's
 * current one must be rejected by the module, with upstream's own message.
 */
async function armArchiveIdentity(reactor: ReactorLike) {
  const world = openWorld(reactor);
  try {
    const clock = new ManualDateProvider(0);
    const chain = new AvmChain(chainDeps(world, clock), { intervalMs: 0 });
    const genesis = chain.archive();
    // THE TREE ID COMES FROM THE ENUM HERE TOO. `4` with a comment beside it is the exact shape of
    // M22's seventh defect and of this milestone's own second one — and this file carried the fix
    // (`MerkleTreeId.L1_TO_L2_MESSAGE_TREE`, below) and the unfixed instance at the same time.
    const leaf0 = await world.merkleDb.getLeafValue(MerkleTreeId.ARCHIVE as never, 0n);
    const b1 = (await chain.produceBlock())!;
    const b2 = (await chain.produceBlock())!;

    // THE REFUSAL, AND ITS CONTROL. `update_archive` compares the header's four-tree state
    // reference against the trees' current one and refuses if they differ; the check is worthless
    // unless a header that AGREES is accepted by the same call. So the same header is offered
    // twice: once with one tree's root perturbed, once unchanged.
    //
    // A block that carried no transactions does not move the four trees, so re-offering `b2`'s own
    // header is legitimately accepted — which is why the negative arm perturbs the reference
    // rather than relying on time passing.
    const good = b2.header;
    const badState = new StateReference(
      new AppendOnlyTreeSnapshot(new Fr(1234n), Number(good.state.l1ToL2MessageTree.nextAvailableLeafIndex)),
      new PartialStateReference(
        good.state.partial.noteHashTree,
        good.state.partial.nullifierTree,
        good.state.partial.publicDataTree,
      ),
    );
    const badHeader = BlockHeader.from({ ...good, state: badState });
    let refusal = 'NOT-REFUSED';
    try {
      await world.merkleDb.updateArchive(badHeader);
    } catch (e) {
      refusal = (e as Error).message;
    }
    const sizeAfterRefusal = Number(world.merkleDb.archiveSnapshot().nextAvailableLeafIndex);
    let acceptedControl = 'THREW';
    try {
      await world.merkleDb.updateArchive(good);
      acceptedControl = 'ACCEPTED';
    } catch (e) {
      acceptedControl = 'THREW: ' + (e as Error).message;
    }
    const sizeAfterControl = Number(world.merkleDb.archiveSnapshot().nextAvailableLeafIndex);

    return {
      genesisRoot: genesis.root.toString(),
      genesisSize: Number(genesis.nextAvailableLeafIndex),
      genesisLeaf: leaf0 === undefined || leaf0 === null ? 'MISSING' : String(leaf0),
      block1: { lastArchive: b1.header.lastArchive.root.toString(), after: b1.archiveAfter.root.toString() },
      block2: { lastArchive: b2.header.lastArchive.root.toString(), after: b2.archiveAfter.root.toString() },
      // The chain property: block 2's `lastArchive` IS block 1's archive-after.
      chained: b2.header.lastArchive.root.toString() === b1.archiveAfter.root.toString(),
      staleHeaderRefusal: refusal,
      sizeBeforeRefusal: Number(b2.archiveAfter.nextAvailableLeafIndex),
      sizeAfterRefusal,
      acceptedControl,
      sizeAfterControl,
      hasArchive: world.merkleDb.hasArchive,
    };
  } finally {
    world.release();
  }
}

/** `produceEmptyBlocks: false` — the timer fires and produces nothing. The empty-block control. */
async function armNoEmptyBlocks(reactor: ReactorLike) {
  const world = openWorld(reactor);
  try {
    const clock = new ManualDateProvider(0);
    const ticker = new ManualTicker();
    const chain = new AvmChain(chainDeps(world, clock, ticker), {
      intervalMs: 0,
      produceEmptyBlocks: false,
    });
    chain.start();
    await ticker.tickTimes(5);
    const afterEmptyTicks = chain.blockNumber;
    const tx = await fundedTx(world, 2901);
    await chain.submit(tx);
    await ticker.tick();
    const afterTx = chain.blockNumber;
    await chain.stop();
    return { ticks: ticker.ticks, afterEmptyTicks, afterTx };
  } finally {
    world.release();
  }
}

export async function runChainArms(reactor: ReactorLike): Promise<Record<string, unknown>> {
  return {
    archiveIdentity: await armArchiveIdentity(reactor),
    emptyBlocks: await armEmptyBlocks(reactor),
    noEmptyBlocks: await armNoEmptyBlocks(reactor),
    subSecondTimestamps: await armSubSecondTimestamps(reactor),
    hundredBlocks: await armHundredBlocks(reactor),
    automine: await armAutomine(reactor),
    l1ToL2: await armL1ToL2(reactor),
    disclosure: await armDisclosure(reactor),
    snapshotRoundtrip: await armSnapshotRoundtrip(reactor),
  };
}
