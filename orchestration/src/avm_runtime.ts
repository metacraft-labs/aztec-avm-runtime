// avm_runtime.ts — the facade. One object in front of the chain, the world state and the AVM.
//
// ITS SHAPE IS UPSTREAM'S AND THE MAPPING IS RECORDED. RI-41's verdict is that
// `AztecNodeDebug` — `yarn-project/stdlib/src/interfaces/aztec-node-debug.ts`, an anvil-style
// JavaScript facade exposed over JSON-RPC behind `--node-debug` — fixes the shape unless a
// divergence is written down, and TXE's `TXEOracleTopLevelContext` (1,024 lines) is the fuller
// prior art. `CHAIN-LOOP.md` maps every method below to its TXE and `AztecNodeDebug` counterpart
// or marks it as having none, and `verify_facade_surface_compared_against_txe` re-derives that
// mapping from the fork rather than reading it here.
//
// TWO FACTS ABOUT THOSE TWO SURFACES ARE MEASURED RATHER THAN QUOTED, and both matter:
//
//   * `AztecNodeDebug` has FIVE methods at the `cpp` anchor and THREE in the `@aztec/stdlib` this
//     package actually installs. `warpL2TimeAtLeastTo` and `warpL2TimeAtLeastBy` were added in
//     `c6a6dbd8bb00` (2026-07-08), after the `deletion_era` pin this package is on. So "follow
//     `AztecNodeDebug`" names different surfaces depending on which artefact is meant.
//   * TXE's `registerContractAndAddAccount` is `private`. The milestone's table lists it beside
//     four public ones.
//
// §8.4 IS THE HONESTY SURFACE AND IT IS NOT SUPPRESSIBLE. Somebody will eventually point this
// runtime at something that matters. Every receipt carries `simulated: true`, the pinned protocol
// version and `proving: 'none'`; `AvmRuntime.create` emits one disclosure line naming the version
// and stating that no proofs are produced, through a sink that cannot be set to nothing —
// `disclose()` writes to the caller's sink AND records the disclosure on the runtime, so a caller
// who discards the sink still cannot produce a runtime that never disclosed.
// `test_receipt_declares_no_proving` asserts both halves, including that passing a no-op sink does
// not stop the record.
//
// WHAT IS NOT HERE. No prover. No L1. No P2P. No node: `settled_read_source.ts` established in
// M21 that what this needs from an `AztecNode` is ONE method out of sixty-two, and §8.4 forbids
// exporting a type named `AztecNode`. `test_no_aztec_node_type_exported` still asserts that and
// this file adds nothing that would break it.

import type { AztecAddress } from '@aztec/stdlib/aztec-address';
import type { Fr } from '@aztec/foundation/curves/bn254';
import type { StateReference, Tx } from '@aztec/stdlib/tx';
import type { AppendOnlyTreeSnapshot } from '@aztec/stdlib/trees';
import type { ContractClassPublic, ContractInstanceWithAddress } from '@aztec/stdlib/contract';

import {
  AvmChain,
  type BlockProductionConfig,
  type ChainBlock,
  type ChainDeps,
  type TraceEvent,
  type TxEvent,
  type ProduceBlockOptions,
  type TxOutcomeRecord,
} from './chain.ts';
import { executeExternallySettledTx, type FormAOutcome, type PublicTxSimulatorLike } from './form_a.ts';
import { fundFeeJuice, type ResidentPublicDataTree } from './fee_juice.ts';
import { externalTx } from './submitted_tx.ts';
import type { SubmittedTx } from './submitted_tx.ts';
import { PINNED_PROTOCOL_VERSION, DISCLOSURE_LINE, type Disclosure } from './disclosure.ts';

/**
 * The receipt every submission returns.
 *
 * THE THREE §8.4 FIELDS ARE ON THE RECEIPT AND NOT IN A HEADER COMMENT, because a receipt is what
 * travels: it is what a caller logs, stores and shows somebody else. A disclosure that lives only
 * at construction time is a disclosure the second reader never sees.
 */
export interface TxReceipt {
  readonly txHash: string;
  /**
   * What the block did with it. `queued` until a block has been produced — which is immediate
   * under `automine` and at the next tick otherwise. It is a distinct value rather than `null` so
   * that "no block yet" and "the block dropped it" cannot be confused.
   */
  readonly outcome: TxOutcomeRecord;
  /** The block this transaction landed in, once one has been produced. */
  readonly blockNumber: number | null;
  /** §8.4. Always `true`. There is no arrangement of arguments that makes it false. */
  readonly simulated: true;
  /** §8.4. The pinned protocol version, from `pins.json` by way of `disclosure.ts`. */
  readonly protocolVersion: string;
  /** §8.4. Always `'none'`. This runtime contains no prover. */
  readonly proving: 'none';
}

/** What a dry run returns. Same execution path, no queue, no block. */
export interface SimulationResult {
  readonly outcome: FormAOutcome;
  readonly simulated: true;
  readonly protocolVersion: string;
  readonly proving: 'none';
}

/**
 * A chain snapshot.
 *
 * IT IS A REPLAY LOG AND NOT A STATE DUMP, and that is a decision with a measured reason rather
 * than a convenience. The milestone asks that the existing pieces be checked before a format is
 * defined. They were, and the answer is in two parts:
 *
 *   * `world_state_reference`'s `get_snapshot()` returns `{root, next_available_leaf_index}` — the
 *     protocol's `AppendOnlyTreeSnapshot` shape. It is the right vocabulary for a state REFERENCE
 *     and it is used as such below (`stateReference`, `archive`), unchanged and not redeclared.
 *     It cannot carry an export: it is a commitment to a state, not the state.
 *   * The only whole-state carrier upstream has is `NativeWorldStateService.backupTo()`, which
 *     calls `copyStores()` and copies LMDB files, with `stdlib/src/snapshots/`'s
 *     `SnapshotDataKeys` as its transport vocabulary. Both are behind `@aztec/world-state` and
 *     `@aztec/native`, which DD-9 forbids, and neither has a wasm counterpart: the module exports
 *     no whole-tree serialisation, and nothing in `crypto/merkle_tree/` or
 *     `foundation/src/trees/` serialises a tree's leaves to a portable blob at all.
 *
 * So there is no state format to reuse and inventing one would mean defining a serialisation for
 * somebody else's merkle trees — the parallel-type mistake, one level up from the one the
 * `TreeSnapshot` deliverable names. What IS reusable is upstream's transaction and block
 * serialisation, so the export carries what PRODUCED the state and the import re-derives it by
 * replaying: the transactions in their blocks, the L1-to-L2 messages at their boundaries, in
 * order. `e2e_chain_snapshot_export_import_roundtrip` asserts that a fresh runtime reloaded from
 * one reaches an identical state reference, block number and archive root.
 */
export interface ChainSnapshot {
  readonly format: 'avm-runtime-replay-log';
  readonly version: 1;
  readonly protocolVersion: string;
  readonly config: BlockProductionConfig;
  /** One entry per produced block, in order. */
  readonly blocks: readonly {
    readonly number: number;
    readonly timestamp: string;
    readonly empty: boolean;
    /** Upstream's own `Tx.toBuffer()`, hex-encoded. Not a format of ours. */
    readonly txs: readonly string[];
    readonly l1ToL2Messages: readonly string[];
    readonly archiveAfter: { readonly root: string; readonly nextAvailableLeafIndex: number };
  }[];
  /** Fee-juice funding applied before the first block, so a replay funds the same payers. */
  readonly funding: readonly { readonly feePayer: string; readonly amount: string }[];
}

export interface AvmRuntimeOptions {
  readonly production?: Partial<BlockProductionConfig>;
  /**
   * Where the §8.4 disclosure is written.
   *
   * Optional, and supplying a no-op does NOT suppress the disclosure — it only redirects it. The
   * record is kept on the runtime either way and `disclosure` is a public getter.
   */
  readonly disclosureSink?: (line: string) => void;
}

/** What the facade needs underneath it. Structural; M28's browser host supplies the same shape. */
export interface AvmRuntimeDeps extends ChainDeps {
  readonly simulator: PublicTxSimulatorLike;
  /** The public-data tree view `fundFeeJuice` writes through. */
  readonly publicDataTree: ResidentPublicDataTree;
}

/**
 * The runtime.
 *
 * `create` is a static async factory rather than a constructor because the disclosure has to
 * happen before anything else can, and a constructor that logs is a constructor with a side
 * effect a caller can skip by using the class differently.
 */
export class AvmRuntime {
  readonly chain: AvmChain;
  readonly disclosure: Disclosure;

  private readonly deps: AvmRuntimeDeps;
  private readonly funding: { feePayer: string; amount: string }[] = [];
  private readonly receiptBlock = new Map<string, number>();
  private readonly provenanceOf = new Map<string, string>();

  /**
   * THE DISCLOSURE IS MADE HERE AND NOT IN `create`, and the reason was MEASURED rather than
   * chosen for style.
   *
   * `private` on a constructor is a TypeScript annotation and nothing else. This package runs its
   * `.ts` sources directly under Node's type stripping, which erases it, and `AvmRuntime` is a
   * public export of `index.ts` — so `new AvmRuntime(deps, options)` is reachable from any caller
   * in the language the runtime actually executes in. With the disclosure in the static factory,
   * M23's review obtained a working runtime by that route with **no line written to any sink** and
   * a **forged `disclosure` record** (`simulated: false`, `proving: 'groth16'`) — and
   * `runtime.disclosure` is the object `test_receipt_declares_no_proving` treats as the evidence
   * that a disclosure was made. "Unsuppressible" was false of the one route the check never took.
   *
   * Disclosing as the constructor's FIRST act closes it: there is no way to obtain an instance of
   * this class without the line being written and the record being the real one, because there is
   * no other way to obtain an instance at all. A sink that throws still propagates, so a caller
   * cannot get a runtime by breaking the disclosure either.
   */
  private constructor(deps: AvmRuntimeDeps, options: AvmRuntimeOptions) {
    this.disclosure = Object.freeze({
      simulated: true,
      protocolVersion: PINNED_PROTOCOL_VERSION,
      proving: 'none',
      line: DISCLOSURE_LINE,
      disclosedAt: 'create',
    });
    const sink = options.disclosureSink ?? ((l: string) => console.warn(l));
    sink(this.disclosure.line);
    this.deps = deps;
    this.chain = new AvmChain(deps, options.production ?? {});
    this.chain.subscribe('block', block => {
      for (const hash of block.txHashes) {
        this.receiptBlock.set(hash, block.number);
      }
    });
  }

  /**
   * Build a runtime, and disclose.
   *
   * ONE LINE, ALWAYS, AND IT NAMES THE VERSION AND THE ABSENCE OF PROOFS. The sink is where it is
   * written; the `disclosure` record is that it was made. A caller who passes `() => {}` has
   * chosen not to display it and has not made it untrue, which is the distinction
   * `test_receipt_declares_no_proving` measures.
   */
  static create(deps: AvmRuntimeDeps, options: AvmRuntimeOptions = {}): AvmRuntime {
    return new AvmRuntime(deps, options);
  }

  // -- lifecycle -----------------------------------------------------------------------------

  start(): void {
    this.chain.start();
  }

  stop(): Promise<void> {
    return this.chain.stop();
  }

  // -- submission ----------------------------------------------------------------------------

  /**
   * Form A — an externally-settled transaction.
   *
   * DD-1 IS SATISFIED STRUCTURALLY HERE AND THAT IS STRONGER THAN THE SEAL. `executeExternally-
   * SettledTx` proves that no frame it reaches OBSERVED the provenance, by sealing the object and
   * tripping a wire on any read. A submission does better: the chain's queue holds `Tx` and
   * nothing else, and the block loop is upstream's `PublicProcessor`, which has never heard of a
   * `SubmittedTx`. So the provenance does not travel to the executing path at all — there is no
   * object for a frame to read. What this method keeps is the RECORD: which provenance a
   * transaction arrived under, on the runtime, keyed by hash, never handed downwards.
   *
   * A TRANSACTION IS EXECUTED EXACTLY ONCE, IN ITS BLOCK. The first version of this method called
   * `executeExternallySettledTx` and THEN queued the transaction, so every submission ran twice —
   * and the second run collided with the nullifiers the first had inserted, which is how it was
   * found rather than shipped. `simulateTx` is where the single-transaction path lives now, and it
   * is a dry run by construction.
   */
  submitExternal(tx: Tx): Promise<TxReceipt> {
    return this.submitSubmitted(externalTx(tx));
  }

  /** Form B — a transaction whose private half this runtime ran. Same queue, same block loop. */
  submitLocal(submitted: SubmittedTx<Tx>): Promise<TxReceipt> {
    return this.submitSubmitted(submitted);
  }

  private async submitSubmitted(submitted: SubmittedTx<Tx>): Promise<TxReceipt> {
    const txHash = submitted.tx.getTxHash().toString();
    this.provenanceOf.set(txHash, submitted.provenance.kind);
    await this.chain.submit(submitted.tx);
    return this.receipt(txHash);
  }

  /** Which provenance a transaction arrived under. A record; never read during execution. */
  provenanceKind(txHash: string): string | null {
    return this.provenanceOf.get(txHash) ?? null;
  }

  /**
   * A DRY RUN: the same execution, no queue, no block, AND NO LASTING STATE.
   *
   * This is where M20's `executeExternallySettledTx` is called, because it is the single-
   * transaction entry point and a dry run is a single transaction. The provenance seal is
   * therefore still exercised on the one path where a `SubmittedTx` exists.
   *
   * THE STATE IS PUT BACK, and both stacks move together. Upstream's own loop pairs
   * `ForkCheckpoint.new(fork)` with `contractsDB.createCheckpoint()` and reverts both; a dry run
   * needs the same pairing for the same reason, and moving only one is M13's two-stacks hazard.
   * The revert is in a `finally`, so a throw from the simulator does not leave a checkpoint open
   * for the next block to inherit.
   */
  async simulateTx(tx: Tx): Promise<SimulationResult> {
    await this.deps.merkleDb.createCheckpoint();
    this.deps.contractsDb.createCheckpoint();
    try {
      const outcome = await executeExternallySettledTx(externalTx(tx), this.deps.simulator);
      return {
        outcome,
        simulated: true,
        protocolVersion: this.disclosure.protocolVersion,
        proving: 'none',
      };
    } finally {
      this.deps.contractsDb.revertCheckpoint();
      await this.deps.merkleDb.revertCheckpoint();
    }
  }

  // -- world -----------------------------------------------------------------------------------

  /** Register a contract class and instance in the module's own resident store. */
  async registerContract(
    contractClass: ContractClassPublic | null,
    instance: ContractInstanceWithAddress | null,
  ): Promise<{ classes: number; instances: number }> {
    let classes = 0;
    let instances = 0;
    if (contractClass && (await this.deps.contractsDb.registerClass(contractClass))) {
      classes += 1;
    }
    if (instance && this.deps.contractsDb.registerInstance(instance)) {
      instances += 1;
    }
    return { classes, instances };
  }

  /** Credit a fee payer's fee-juice balance. Upstream's own leaf-slot derivation, M20's. */
  async fundFeeJuice(feePayer: AztecAddress, amount: Fr): Promise<Fr> {
    const slot = await fundFeeJuice(this.deps.publicDataTree, feePayer, amount);
    this.funding.push({ feePayer: feePayer.toString(), amount: amount.toString() });
    return slot;
  }

  /** Append an L1-to-L2 message at the next block boundary. TXE's `sendL1ToL2Message` semantics. */
  injectL1ToL2Message(leaf: Fr): void {
    this.chain.injectL1ToL2Message(leaf);
  }

  // -- state queries ---------------------------------------------------------------------------

  get blockNumber(): number {
    return this.chain.blockNumber;
  }

  /** TXE's `getNextBlockNumber`. */
  get nextBlockNumber(): number {
    return this.chain.nextBlockNumber;
  }

  /** TXE's `getLastBlockTimestamp`. */
  get lastBlockTimestamp(): bigint {
    return this.chain.lastBlockTimestamp;
  }

  /** TXE's `getNextBlockTimestamp`. */
  get nextBlockTimestamp(): bigint {
    return this.chain.nextBlockTimestamp;
  }

  get blocks(): readonly ChainBlock[] {
    return this.chain.blocks;
  }

  /** Upstream's `AppendOnlyTreeSnapshot`, not a type of ours. */
  archive(): AppendOnlyTreeSnapshot {
    return this.chain.archive();
  }

  stateReference(): Promise<StateReference> {
    return this.chain.stateReference();
  }

  /** `AztecNodeDebug.mineBlock`, and TXE's. Produces one block on demand. */
  produceBlock(options: ProduceBlockOptions = {}): Promise<ChainBlock | null> {
    return this.chain.produceBlock(options);
  }

  /**
   * The receipt for a transaction as it now stands.
   *
   * A receipt returned by `submitExternal` is a value, not a live view: with `automine` off the
   * transaction is `queued` at that moment and lands later. Re-reading is how a caller learns what
   * the block did, and it is a separate call rather than a mutable receipt so that a receipt a
   * caller stored keeps saying what it said.
   */
  receiptFor(txHash: string): TxReceipt {
    return this.receipt(txHash);
  }

  /** TXE's `advanceBlocksBy`. Produces `n` blocks, each awaited before the next. */
  async advanceBlocksBy(n: number): Promise<ChainBlock[]> {
    const out: ChainBlock[] = [];
    for (let i = 0; i < n; i++) {
      const block = await this.chain.produceBlock();
      if (block) {
        out.push(block);
      }
    }
    return out;
  }

  // -- subscriptions ---------------------------------------------------------------------------

  subscribe(kind: 'block', fn: (event: ChainBlock) => void): () => void;
  subscribe(kind: 'tx', fn: (event: TxEvent) => void): () => void;
  subscribe(kind: 'trace', fn: (event: TraceEvent) => void): () => void;
  subscribe(kind: 'block' | 'tx' | 'trace', fn: (event: never) => void): () => void {
    return (this.chain.subscribe as (k: string, f: (e: never) => void) => () => void)(kind, fn);
  }

  // -- snapshot --------------------------------------------------------------------------------

  /** See `ChainSnapshot`: a replay log, not a state dump, for a measured reason. */
  exportSnapshot(): ChainSnapshot {
    return {
      format: 'avm-runtime-replay-log',
      version: 1,
      protocolVersion: this.disclosure.protocolVersion,
      config: this.chain.config,
      blocks: this.chain.blocks.map(b => ({
        number: b.number,
        timestamp: b.timestamp.toString(),
        empty: b.empty,
        txs: b.txs.map(t => Buffer.from(t.toBuffer()).toString('hex')),
        l1ToL2Messages: [...b.l1ToL2Messages],
        archiveAfter: {
          root: b.archiveAfter.root.toString(),
          nextAvailableLeafIndex: Number(b.archiveAfter.nextAvailableLeafIndex),
        },
      })),
      funding: this.funding.map(f => ({ ...f })),
    };
  }

  /**
   * Replay a snapshot into THIS runtime.
   *
   * The runtime must be fresh — block number 0 — because a replay onto a chain that already has
   * blocks would produce a state neither the snapshot nor the target describes. That is checked
   * rather than documented.
   */
  async importSnapshot(
    snapshot: ChainSnapshot,
    decodeTx: (bytes: Buffer) => Promise<Tx>,
    decodeAddress: (s: string) => Promise<AztecAddress>,
    decodeField: (s: string) => Fr,
  ): Promise<void> {
    if (snapshot.format !== 'avm-runtime-replay-log' || snapshot.version !== 1) {
      throw new Error(`unrecognised chain snapshot: ${snapshot.format} v${snapshot.version}`);
    }
    if (this.chain.blockNumber !== 0) {
      throw new Error(
        `importSnapshot needs a fresh chain; this one is at block ${this.chain.blockNumber}`,
      );
    }
    for (const f of snapshot.funding) {
      await this.fundFeeJuice(await decodeAddress(f.feePayer), decodeField(f.amount));
    }
    for (const b of snapshot.blocks) {
      for (const m of b.l1ToL2Messages) {
        this.chain.injectL1ToL2Message(decodeField(m));
      }
      for (const hex of b.txs) {
        const tx = await decodeTx(Buffer.from(hex, 'hex'));
        await executeExternallySettledTx(externalTx(tx), this.deps.simulator);
        await this.chain.submit(tx);
      }
      await this.chain.produceBlock({ timestamp: BigInt(b.timestamp) });
    }
  }

  // -- internals -------------------------------------------------------------------------------

  private receipt(txHash: string): TxReceipt {
    return {
      txHash,
      outcome: this.chain.outcomeOf(txHash),
      blockNumber: this.receiptBlock.get(txHash) ?? null,
      simulated: true,
      protocolVersion: this.disclosure.protocolVersion,
      proving: 'none',
    };
  }
}
