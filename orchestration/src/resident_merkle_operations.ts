// resident_merkle_operations.ts — `MerkleTreeWriteOperations` over the world state that lives
// inside `avm.wasm`.
//
// THIS IS THE ONE PIECE OF M22 THAT IS OURS, AND THE ENUMERATION THAT ESTABLISHED THAT IS THE
// REASON THE FILE IS ALLOWED TO EXIST. `implements MerkleTreeWriteOperations` over the whole fork
// at three revisions — the `ts` anchor 3a68d68ac2, the `cpp` anchor 233d8e0993 and upstream HEAD —
// finds exactly three classes:
//
//   * `MerkleTreesForkFacade`   world-state/src/native/merkle_trees_facade.ts:180 — the real one,
//                               over the LMDB native addon. RI-27 replaces that package and DD-9
//                               forbids its import graph, so it is not available to us.
//   * `GuardedMerkleTreeOperations`  a WRAPPER. It forwards every method to a `target` and has no
//                               store of its own, so it needs one of these underneath it.
//   * `HintingMerkleWriteOperations` (ts anchor only) a DECORATOR that records hints. Also needs a
//                               target underneath it.
//
// So the interface has exactly one implementation upstream and it is the forbidden one. That is a
// `does-not-cover` for reuse purposes rather than a `does-not-exist` — see REUSE-INVENTORY RI-66.
//
// WHAT IT ANSWERS, AND WHAT IT REFUSES. `LowLevelMerkleDBInterface` is fourteen methods
// (REACTOR-ABI.md, and that count is upstream's own C++ declaration). `MerkleTreeWriteOperations`
// is larger — `test_guarded_merkle_tree_blocks_post_seal_access` extracts the names off upstream's
// own `GuardedMerkleTreeOperations`, which forwards the whole interface, and MEASURES twenty-five,
// two of which (`getUnderlyingFork`, `stop`) are the wrapper's own rather than the interface's.
// The two sets are of similar size and are NOT THE SAME SET, which is the only thing that matters
// here and is why no number below is load-bearing:
//
//   ANSWERED, each by one named export of the module
//     getStateReference        avm_merkle_db_get_tree_roots
//     getTreeInfo              avm_merkle_db_get_tree_roots (root + size; depth is a constant)
//     getSiblingPath           avm_merkle_db_get_sibling_path
//     getPreviousValueIndex    avm_merkle_db_get_low_indexed_leaf
//     getLeafPreimage          avm_merkle_db_get_leaf_preimage_{public_data,nullifier}_tree
//     getLeafValue             avm_merkle_db_get_leaf_value
//     appendLeaves             avm_merkle_db_append_leaves
//     sequentialInsert         avm_merkle_db_insert_indexed_leaves_{public_data,nullifier}_tree
//     createCheckpoint / commitCheckpoint / revertCheckpoint / commitAllCheckpointsTo /
//     revertAllCheckpointsTo   avm_merkle_db_{create,commit,revert}_checkpoint
//     getRevision              the resident revision — there is one view and it is current
//
//   REFUSED BY NAME, each with the reason it cannot be answered
//     updateArchive            THE ARCHIVE IS NOT IN THIS MODULE. See below.
//     getTreeInfo(ARCHIVE)     the same fact, at the read end.
//     batchInsert              the module exports no subtree insertion, and emulating one with
//                              sequential inserts plus `pad_tree` DOES NOT PRODUCE THE SAME TREE.
//     findLeafIndices, findLeafIndicesAfter, findSiblingPaths
//                              value -> index. M21 measured that none of the fourteen exported
//                              methods goes that way for an APPEND-ONLY tree; only
//                              `get_leaf_value(tree, index)`, which is the other direction.
//     getBlockNumbersForLeafIndices, getInitialHeader
//                              there is no block store on this side of the boundary yet.
//     getIpcPath               there is no IPC. The world state is RESIDENT; `getIpcPath` is
//                              upstream's way of telling the NAPI addon where the out-of-process
//                              world state lives, and answering '' would be answering a question
//                              about a different architecture.
//
// A REFUSAL IS A THROW AND NEVER A PLAUSIBLE VALUE, and that direction is the whole design.
// M21's `strictSurface` learned it on the read side: a duck-typed caller that gets `undefined`
// takes another path and nothing records that it asked. `verifyReadRequests` reading `undefined`
// as "not settled" is the same shape. Here the dangerous direction is a merkle root: an
// `updateArchive` that returned without doing anything would put a block header in a chain with
// an archive root that certifies nothing, and every consumer downstream would believe it.
//
// THE ARCHIVE, AND WHY IT IS A REFUSAL RATHER THAN A GAP.
// M14 asked this question and answered it: WORLD-STATE.md §3 Gap A, RI-53, DECISION: extend — one
// more `MemoryAppendOnlyTree<aztec::AztecMerkleHashPolicy>` at `ARCHIVE_HEIGHT` inside
// `world_state_reference`'s checkpointed `State`, with `update_archive(state_ref, header_hash)`
// beside it. That patch is written, tested against upstream's own fidelity gate, and lives at
// `verification/m14/0001-feat-world_state_reference-archive-tree-so-the-in-me.patch`. IT IS NOT
// CARRIED: `git grep update_archive` under `barretenberg/.../world_state_reference/` is empty at
// the `cpp` anchor and empty at the fork's own branch head, and the shipped module's
// `LowLevelMerkleDBInterface` export group is fourteen names with no `avm_merkle_db_update_archive`
// among them. `residentModuleHasArchive()` below asks the MODULE that question rather than
// restating this paragraph.
//
// And M14 also closed the obvious escape: putting the archive on the TypeScript side was
// MEASURED and rejected, because upstream's only TypeScript tree
// (`foundation/src/trees/merkle_tree.ts`) enforces `2 ** (height + 1) - 1` nodes in its
// constructor, which at `ARCHIVE_HEIGHT` 30 is 2,147,483,647. Writing a frontier tree of our own
// here would be re-deciding a disposition M14 settled on evidence, in the milestone whose brief
// says M22 is the first place that conclusion is used FOR REAL. So M22 uses it: it names the
// consequence and refuses, and the remaining work is three named things — apply M14's patch on
// the AVM_WASM overlay stack, add one reactor export, add one line to the export list — rather
// than an unknown.
//
// CHECKPOINT DEPTH IS TRACKED HERE, AND IT IS NOT THE MODULE'S CHECKPOINT ID.
// `ForkCheckpoint.new` reads the value `createCheckpoint()` returns and later calls
// `revertAllCheckpointsTo(depth - 1)`, so the number has to be a DEPTH. The module exports
// `avm_merkle_db_get_checkpoint_id`, whose own C++ comment says "a unique id for the lifetime of
// the db" — a monotonically increasing identity, not a stack position. Using it as a depth would
// make `revertAllCheckpointsTo` unwind an arbitrary number of levels. The depth is therefore
// counted on this side; `checkpointId()` is exposed beside it so a check can assert that the two
// move together without conflating them.

import {
  ARCHIVE_HEIGHT,
  L1_TO_L2_MSG_TREE_HEIGHT,
  NOTE_HASH_TREE_HEIGHT,
  NULLIFIER_TREE_HEIGHT,
  PUBLIC_DATA_TREE_HEIGHT,
} from '@aztec/constants';
import { Fr } from '@aztec/foundation/curves/bn254';
import { serializeWithMessagePack } from '@aztec/stdlib/avm';
import { SiblingPath } from '@aztec/foundation/trees';
import {
  AppendOnlyTreeSnapshot,
  MerkleTreeId,
  NullifierLeaf,
  NullifierLeafPreimage,
  PublicDataTreeLeaf,
  PublicDataTreeLeafPreimage,
} from '@aztec/stdlib/trees';
import { PartialStateReference, StateReference } from '@aztec/stdlib/tx';

import type { BlobCallable } from './resident_db.ts';
import { residentWorldStateRevision } from './avm_inputs.ts';

/**
 * The narrow view of a module this file needs. `BlobCallable` supplies the blob half;
 * `callWithHandle` is the no-argument half (`get_tree_roots`, the three checkpoint calls).
 * Structural, for the same reason `AvmBoundary` is: M28's browser host is a second implementation
 * rather than a subclass.
 */
export interface ResidentMerkleModule extends BlobCallable {
  callWithHandle(exportName: string, handle: number): unknown;
}

/**
 * Thrown by every method this database cannot answer.
 *
 * It carries the METHOD and the REASON separately so a caller — or a check — can discriminate on
 * the method without matching prose, which is this campaign's needle rule applied to its own
 * error type.
 */
export class ResidentMerkleDbCannotAnswer extends Error {
  readonly kind = 'resident-merkle-db-cannot-answer' as const;
  readonly method: string;
  readonly reason: string;
  constructor(method: string, reason: string) {
    super(`${method} cannot be answered by the resident world state: ${reason}`);
    this.name = 'ResidentMerkleDbCannotAnswer';
    this.method = method;
    this.reason = reason;
  }
}

/** The reasons, given once so a check can pin them by name rather than by substring. */
export const REFUSAL_REASONS: Readonly<Record<string, string>> = Object.freeze({
  updateArchive:
    'the archive tree is not in this module. M14 decided to extend world_state_reference with it '
    + '(RI-53, WORLD-STATE.md Gap A) and the patch at verification/m14/ is not carried, so no '
    + 'avm_merkle_db_update_archive export exists',
  archiveTree:
    'the archive tree is not in this module; MerkleTreeId.ARCHIVE has no counterpart among the '
    + 'fourteen exported LowLevelMerkleDBInterface methods',
  batchInsert:
    'the module exports no subtree insertion. Emulating one with sequential inserts plus pad_tree '
    + 'yields a different indexed tree, and a merkle root that is wrong is worse than one that is '
    + 'missing',
  valueToIndex:
    'no exported method goes from a leaf VALUE to its index in an append-only tree; '
    + 'avm_merkle_db_get_leaf_value goes the other way',
  noBlockStore: 'there is no block store on this side of the boundary',
  noIpc: 'the world state is resident in the module; there is no IPC path to name',
  insertionWitness:
    'the insertion witness is not decoded here. The insert itself happened; only the witness data '
    + 'is unavailable, and no caller in this runtime reads it',
});

/** The `MerkleTreeId` values the module's own exports cover. `ARCHIVE` is deliberately absent. */
export const RESIDENT_TREES: readonly MerkleTreeId[] = Object.freeze([
  MerkleTreeId.NULLIFIER_TREE,
  MerkleTreeId.NOTE_HASH_TREE,
  MerkleTreeId.PUBLIC_DATA_TREE,
  MerkleTreeId.L1_TO_L2_MESSAGE_TREE,
]) as readonly MerkleTreeId[];

/**
 * Does this module carry the archive extension?
 *
 * Asked of the MODULE'S OWN EXPORT LIST rather than of a constant here, so that the day M14's
 * patch is carried and the reactor gains the export, this answers `true` without an edit — and so
 * that the refusal above is a statement about an artefact rather than about a sentence.
 */
export function residentModuleHasArchive(exportNames: readonly string[]): boolean {
  return exportNames.includes('avm_merkle_db_update_archive');
}

/** The empty append-only snapshot, used only to name the shape; never returned as an answer. */
function snapshotOf(raw: unknown): AppendOnlyTreeSnapshot {
  const s = raw as { root?: unknown; nextAvailableLeafIndex?: unknown };
  return new AppendOnlyTreeSnapshot(frOf(s.root), Number(s.nextAvailableLeafIndex));
}

/**
 * A field element as the module's decoder leaves it.
 *
 * `Reactor.callWithBlob` decodes with node-host's dependency-free decoder, which yields a
 * big-endian `Uint8Array` for a msgpack `bin` and never an `Fr` — the same hazard `resident_db.ts`
 * documents. Converting here rather than importing a second decoder keeps this file's only
 * @aztec/stdlib dependency the encoder and the value types.
 */
function frOf(value: unknown): Fr {
  if (value instanceof Fr) {
    return value;
  }
  if (value instanceof Uint8Array) {
    return Fr.fromBuffer(Buffer.from(value));
  }
  if (typeof value === 'bigint') {
    return new Fr(value);
  }
  if (typeof value === 'number') {
    return new Fr(BigInt(value));
  }
  throw new Error(`resident_merkle_operations: expected a field element, got ${typeof value}`);
}

function bigintOf(value: unknown): bigint {
  if (typeof value === 'bigint') {
    return value;
  }
  if (typeof value === 'number') {
    return BigInt(value);
  }
  if (value instanceof Uint8Array) {
    let acc = 0n;
    for (const byte of value) {
      acc = (acc << 8n) | BigInt(byte);
    }
    return acc;
  }
  throw new Error(`resident_merkle_operations: expected an index, got ${typeof value}`);
}

/**
 * The result `sequentialInsert` returns.
 *
 * THE INSERT HAPPENED; THE WITNESS DID NOT COME BACK. Upstream's `SequentialInsertionResult`
 * carries `lowLeavesWitnessData` and `insertionWitnessData`, each a per-leaf record with a sibling
 * path — data the rollup circuits need and this runtime does not. Rather than fabricate them, or
 * omit the method and lose the write, the two members are GETTERS THAT THROW. A caller that
 * discards the result — which is every caller in this runtime, `PublicTreesDB.storageWrite` and
 * `.writeNullifier` included — is unaffected; a caller that reads one gets a named refusal at its
 * own call site instead of an empty array it would treat as "no low leaves were updated".
 */
export class ResidentSequentialInsertionResult {
  get lowLeavesWitnessData(): never {
    throw new ResidentMerkleDbCannotAnswer('sequentialInsert.lowLeavesWitnessData', REFUSAL_REASONS.insertionWitness);
  }
  get insertionWitnessData(): never {
    throw new ResidentMerkleDbCannotAnswer('sequentialInsert.insertionWitnessData', REFUSAL_REASONS.insertionWitness);
  }
}

/**
 * `MerkleTreeWriteOperations` over the module's resident merkle DB.
 *
 * Structurally compatible with upstream's interface where it can be, and loudly incompatible
 * where it cannot. It is deliberately NOT declared `implements MerkleTreeWriteOperations`: the
 * declaration would be a claim of totality, and M19's review found exactly that defect in a mirror
 * that claimed to be total and intercepted two of four methods. What it is instead is a class
 * whose refusals are enumerated above and asserted by
 * `test_block_limits_respected` and `test_guarded_merkle_tree_blocks_post_seal_access`.
 */
export class ResidentMerkleWriteOperations {
  private readonly module: ResidentMerkleModule;
  private readonly handle: number;
  private depth = 0;
  private closed = false;

  constructor(module: ResidentMerkleModule, handle: number) {
    this.module = module;
    this.handle = handle;
  }

  // -- reads ------------------------------------------------------------------------------------

  private treeRoots(): {
    l1ToL2MessageTree: AppendOnlyTreeSnapshot;
    noteHashTree: AppendOnlyTreeSnapshot;
    nullifierTree: AppendOnlyTreeSnapshot;
    publicDataTree: AppendOnlyTreeSnapshot;
  } {
    const raw = this.module.callWithHandle('avm_merkle_db_get_tree_roots', this.handle) as Record<string, unknown>;
    if (!raw) {
      throw new Error('avm_merkle_db_get_tree_roots returned nothing');
    }
    return {
      l1ToL2MessageTree: snapshotOf(raw.l1ToL2MessageTree),
      noteHashTree: snapshotOf(raw.noteHashTree),
      nullifierTree: snapshotOf(raw.nullifierTree),
      publicDataTree: snapshotOf(raw.publicDataTree),
    };
  }

  getStateReference(): Promise<StateReference> {
    const r = this.treeRoots();
    return Promise.resolve(
      new StateReference(
        r.l1ToL2MessageTree,
        new PartialStateReference(r.noteHashTree, r.nullifierTree, r.publicDataTree),
      ),
    );
  }

  /**
   * NO FALL-THROUGH. The first revision of this method was a ternary chain ending in
   * `: r.l1ToL2MessageTree`, so an unrecognised tree id got a plausible snapshot for the WRONG
   * TREE — a merkle root that is confidently wrong, in the class whose whole design is that such a
   * value must be impossible to obtain. The dispatch is a lookup over `RESIDENT_TREES` now and
   * anything outside it refuses.
   */
  getTreeInfo(treeId: MerkleTreeId): Promise<{ treeId: MerkleTreeId; root: Buffer; size: bigint; depth: number }> {
    if (treeId === MerkleTreeId.ARCHIVE) {
      throw new ResidentMerkleDbCannotAnswer('getTreeInfo(ARCHIVE)', REFUSAL_REASONS.archiveTree);
    }
    if (!RESIDENT_TREES.includes(treeId)) {
      throw new ResidentMerkleDbCannotAnswer(
        'getTreeInfo',
        `tree ${treeId} is not one of the four this module holds (${RESIDENT_TREES.join(', ')})`,
      );
    }
    const r = this.treeRoots();
    const byTree: Record<number, AppendOnlyTreeSnapshot> = {
      [MerkleTreeId.NULLIFIER_TREE]: r.nullifierTree,
      [MerkleTreeId.NOTE_HASH_TREE]: r.noteHashTree,
      [MerkleTreeId.PUBLIC_DATA_TREE]: r.publicDataTree,
      [MerkleTreeId.L1_TO_L2_MESSAGE_TREE]: r.l1ToL2MessageTree,
    };
    const snapshot = byTree[treeId];
    return Promise.resolve({
      treeId,
      root: snapshot.root.toBuffer(),
      size: BigInt(snapshot.nextAvailableLeafIndex),
      depth: TREE_HEIGHTS[treeId],
    });
  }

  getSiblingPath(treeId: MerkleTreeId, index: bigint): Promise<SiblingPath<number>> {
    const raw = this.module.callWithBlob(
      'avm_merkle_db_get_sibling_path',
      this.handle,
      encodePair(treeId, index),
    ) as unknown[];
    if (!Array.isArray(raw)) {
      throw new Error('avm_merkle_db_get_sibling_path did not answer with a path');
    }
    return Promise.resolve(new SiblingPath(raw.length, raw.map(node => frOf(node).toBuffer())));
  }

  getPreviousValueIndex(
    treeId: MerkleTreeId,
    value: bigint,
  ): Promise<{ index: bigint; alreadyPresent: boolean } | undefined> {
    const raw = this.module.callWithBlob(
      'avm_merkle_db_get_low_indexed_leaf',
      this.handle,
      encodePair(treeId, new Fr(value)),
    ) as { index?: unknown; is_already_present?: unknown } | null;
    if (!raw) {
      return Promise.resolve(undefined);
    }
    // `is_already_present`, snake_case, is the C++ struct's own member name and msgpack carries
    // member names verbatim. `resident_db.ts` records what reading `alreadyPresent` costs: every
    // lookup answers "absent", including one that had just been written.
    return Promise.resolve({ index: bigintOf(raw.index), alreadyPresent: raw.is_already_present === true });
  }

  getLeafPreimage(
    treeId: MerkleTreeId,
    index: bigint,
  ): Promise<PublicDataTreeLeafPreimage | NullifierLeafPreimage | undefined> {
    const exportName =
      treeId === MerkleTreeId.PUBLIC_DATA_TREE
        ? 'avm_merkle_db_get_leaf_preimage_public_data_tree'
        : treeId === MerkleTreeId.NULLIFIER_TREE
          ? 'avm_merkle_db_get_leaf_preimage_nullifier_tree'
          : undefined;
    if (exportName === undefined) {
      throw new ResidentMerkleDbCannotAnswer(
        'getLeafPreimage',
        `tree ${treeId} is not indexed; only the nullifier and public-data trees have preimages`,
      );
    }
    const raw = this.module.callWithBlob(exportName, this.handle, encodeIndex(index)) as
      | { leaf?: Record<string, unknown>; nextIndex?: unknown; nextKey?: unknown; nextValue?: unknown }
      | null;
    if (!raw || !raw.leaf) {
      return Promise.resolve(undefined);
    }
    const nextIndex = bigintOf(raw.nextIndex ?? 0);
    if (treeId === MerkleTreeId.PUBLIC_DATA_TREE) {
      const leaf = new PublicDataTreeLeaf(frOf(raw.leaf.slot), frOf(raw.leaf.value));
      return Promise.resolve(new PublicDataTreeLeafPreimage(leaf, frOf(raw.nextKey ?? raw.nextValue ?? 0), nextIndex));
    }
    const leaf = new NullifierLeaf(frOf(raw.leaf.nullifier ?? raw.leaf.value));
    return Promise.resolve(new NullifierLeafPreimage(leaf, frOf(raw.nextKey ?? raw.nextValue ?? 0), nextIndex));
  }

  getLeafValue(treeId: MerkleTreeId, index: bigint): Promise<Fr | undefined> {
    const raw = this.module.callWithBlob('avm_merkle_db_get_leaf_value', this.handle, encodePair(treeId, index));
    return Promise.resolve(raw === null || raw === undefined ? undefined : frOf(raw));
  }

  /**
   * The one view this world state has, and it is the current one.
   *
   * M14 settled that this runtime does not need block-pinned reads (RI-54, `test_historical_
   * block_zero_read_returns_genesis`): none of the fourteen exported methods takes a
   * `WorldStateRevision`, so the regression the sentinel exists to prevent is not reachable in a
   * database that cannot be asked the question.
   */
  getRevision(): ReturnType<typeof residentWorldStateRevision> {
    return residentWorldStateRevision(1);
  }

  // -- writes -----------------------------------------------------------------------------------

  appendLeaves(treeId: MerkleTreeId, leaves: Fr[]): Promise<void> {
    if (treeId === MerkleTreeId.ARCHIVE) {
      throw new ResidentMerkleDbCannotAnswer('appendLeaves(ARCHIVE)', REFUSAL_REASONS.archiveTree);
    }
    if (!RESIDENT_TREES.includes(treeId)) {
      throw new ResidentMerkleDbCannotAnswer(
        'appendLeaves',
        `tree ${treeId} is not one of the four this module holds (${RESIDENT_TREES.join(', ')})`,
      );
    }
    this.module.callWithBlob('avm_merkle_db_append_leaves', this.handle, encodeAppend(treeId, leaves));
    return Promise.resolve();
  }

  sequentialInsert(treeId: MerkleTreeId, leaves: Buffer[]): Promise<ResidentSequentialInsertionResult> {
    for (const raw of leaves) {
      if (treeId === MerkleTreeId.PUBLIC_DATA_TREE) {
        const leaf = PublicDataTreeLeaf.fromBuffer(raw);
        this.module.callWithBlob(
          'avm_merkle_db_insert_indexed_leaves_public_data_tree',
          this.handle,
          encodePublicDataLeaf(leaf.slot, leaf.value),
        );
      } else if (treeId === MerkleTreeId.NULLIFIER_TREE) {
        const leaf = NullifierLeaf.fromBuffer(raw);
        this.module.callWithBlob(
          'avm_merkle_db_insert_indexed_leaves_nullifier_tree',
          this.handle,
          encodeNullifierLeaf(leaf.nullifier),
        );
      } else {
        throw new ResidentMerkleDbCannotAnswer(
          'sequentialInsert',
          `tree ${treeId} is not indexed; only the nullifier and public-data trees take indexed leaves`,
        );
      }
    }
    return Promise.resolve(new ResidentSequentialInsertionResult());
  }

  /**
   * REFUSED. See `REFUSAL_REASONS.batchInsert`.
   *
   * The reason is worth stating precisely, because "insert them one at a time" looks like an
   * obvious substitution. Upstream's `batchInsert` inserts a whole SUBTREE at once, and in an
   * indexed merkle tree the pending-insert chaining that does is not the same computation as N
   * sequential inserts: the low-leaf pointers are resolved against the batch, not against the
   * tree after each step. The roots agree only in the cases where no leaf in the batch is the low
   * leaf of another. Producing a plausible root for the other cases is precisely the failure this
   * class exists to make impossible.
   */
  batchInsert(_treeId: MerkleTreeId, _leaves: Buffer[], _subtreeHeight: number): Promise<never> {
    throw new ResidentMerkleDbCannotAnswer('batchInsert', REFUSAL_REASONS.batchInsert);
  }

  /** REFUSED. The block-sealing call, and the one M14's uncarried patch would answer. */
  updateArchive(_header: unknown): Promise<never> {
    throw new ResidentMerkleDbCannotAnswer('updateArchive', REFUSAL_REASONS.updateArchive);
  }

  // -- checkpoints ------------------------------------------------------------------------------

  createCheckpoint(): Promise<number> {
    this.module.callWithHandle('avm_merkle_db_create_checkpoint', this.handle);
    this.depth += 1;
    return Promise.resolve(this.depth);
  }

  commitCheckpoint(): Promise<void> {
    if (this.depth === 0) {
      throw new ResidentMerkleDbCannotAnswer('commitCheckpoint', 'no checkpoint is open');
    }
    this.module.callWithHandle('avm_merkle_db_commit_checkpoint', this.handle);
    this.depth -= 1;
    return Promise.resolve();
  }

  revertCheckpoint(): Promise<void> {
    if (this.depth === 0) {
      throw new ResidentMerkleDbCannotAnswer('revertCheckpoint', 'no checkpoint is open');
    }
    this.module.callWithHandle('avm_merkle_db_revert_checkpoint', this.handle);
    this.depth -= 1;
    return Promise.resolve();
  }

  async commitAllCheckpointsTo(depth: number): Promise<void> {
    while (this.depth > depth) {
      await this.commitCheckpoint();
    }
  }

  async revertAllCheckpointsTo(depth: number): Promise<void> {
    while (this.depth > depth) {
      await this.revertCheckpoint();
    }
  }

  /** The depth this side is counting. Exposed so a check can assert balance rather than infer it. */
  get checkpointDepth(): number {
    return this.depth;
  }

  /**
   * The module's own checkpoint id. NOT a depth — its C++ comment says "a unique id for the
   * lifetime of the db". Exposed beside `checkpointDepth` so the two can be asserted to move
   * together without being confused for one another.
   */
  checkpointId(): number {
    return Number(this.module.callWithHandle('avm_merkle_db_get_checkpoint_id', this.handle));
  }

  // -- lifecycle and the refusals ---------------------------------------------------------------

  /**
   * A no-op, and DECLARED as one rather than left to look like a close that worked.
   *
   * The two module handles are owned by whoever created them — the driver, or M23's runtime — and
   * a fork's `close()` in upstream releases a fork the world state allocated. There is no such
   * allocation here. `isClosed` records that it was called so a caller can tell; the database goes
   * on answering, which is the honest behaviour and is asserted rather than assumed.
   */
  close(): Promise<void> {
    this.closed = true;
    return Promise.resolve();
  }

  get isClosed(): boolean {
    return this.closed;
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.close();
  }

  getInitialHeader(): never {
    throw new ResidentMerkleDbCannotAnswer('getInitialHeader', REFUSAL_REASONS.noBlockStore);
  }

  getIpcPath(): never {
    throw new ResidentMerkleDbCannotAnswer('getIpcPath', REFUSAL_REASONS.noIpc);
  }

  findLeafIndices(_treeId: MerkleTreeId, _values: unknown[]): Promise<never> {
    throw new ResidentMerkleDbCannotAnswer('findLeafIndices', REFUSAL_REASONS.valueToIndex);
  }

  findLeafIndicesAfter(_treeId: MerkleTreeId, _values: unknown[], _startIndex: bigint): Promise<never> {
    throw new ResidentMerkleDbCannotAnswer('findLeafIndicesAfter', REFUSAL_REASONS.valueToIndex);
  }

  findSiblingPaths(_treeId: MerkleTreeId, _values: unknown[]): Promise<never> {
    throw new ResidentMerkleDbCannotAnswer('findSiblingPaths', REFUSAL_REASONS.valueToIndex);
  }

  getBlockNumbersForLeafIndices(_treeId: MerkleTreeId, _leafIndices: bigint[]): Promise<never> {
    throw new ResidentMerkleDbCannotAnswer('getBlockNumbersForLeafIndices', REFUSAL_REASONS.noBlockStore);
  }
}

/** Every method that refuses, by name. The census a check pins rather than rediscovers. */
export const REFUSING_METHODS: readonly string[] = Object.freeze([
  'batchInsert',
  'updateArchive',
  'getInitialHeader',
  'getIpcPath',
  'findLeafIndices',
  'findLeafIndicesAfter',
  'findSiblingPaths',
  'getBlockNumbersForLeafIndices',
]);

/** Every method that answers out of the module, by name. */
export const ANSWERING_METHODS: readonly string[] = Object.freeze([
  'getStateReference',
  'getTreeInfo',
  'getSiblingPath',
  'getPreviousValueIndex',
  'getLeafPreimage',
  'getLeafValue',
  'getRevision',
  'appendLeaves',
  'sequentialInsert',
  'createCheckpoint',
  'commitCheckpoint',
  'revertCheckpoint',
  'commitAllCheckpointsTo',
  'revertAllCheckpointsTo',
]);

/**
 * Tree heights, read from `@aztec/constants` and NEVER typed in here.
 *
 * `@aztec/stdlib/trees` exposes `TreeHeights` as a type-level record, so there is no value to
 * import and the mapping has to be built. It is built from the protocol constants rather than
 * from literals, because a `depth` in a `TreeInfo` is exactly the kind of number that goes stale
 * silently: the first draft of this file guessed 40/40/40/39/30 and the protocol says
 * 42/42/40/36/30 — four of the five wrong, and nothing in a block would have failed because of it.
 */
export const TREE_HEIGHTS: Readonly<Record<number, number>> = Object.freeze({
  [MerkleTreeId.NULLIFIER_TREE]: NULLIFIER_TREE_HEIGHT,
  [MerkleTreeId.NOTE_HASH_TREE]: NOTE_HASH_TREE_HEIGHT,
  [MerkleTreeId.PUBLIC_DATA_TREE]: PUBLIC_DATA_TREE_HEIGHT,
  [MerkleTreeId.L1_TO_L2_MESSAGE_TREE]: L1_TO_L2_MSG_TREE_HEIGHT,
  [MerkleTreeId.ARCHIVE]: ARCHIVE_HEIGHT,
});

// --- the four encoders, each the shape the C++ export reads -------------------------------------
//
// Kept as free functions rather than inlined so `test_block_limits_respected` can encode the same
// call and compare bytes, and so the shapes are readable in one place. `serializeWithMessagePack`
// is upstream's — the same call `resident_db.ts` and `avm_inputs.ts` make — so no layout is
// decided here. ONE CLASS OF `Fr` PER PROCESS still applies: see `resident_db.ts`.

function encodePair(treeId: MerkleTreeId, second: Fr | bigint): Uint8Array {
  return serializeWithMessagePack([treeId, typeof second === 'bigint' ? Number(second) : second]);
}

function encodeIndex(index: bigint): Uint8Array {
  return serializeWithMessagePack(Number(index));
}

function encodeAppend(treeId: MerkleTreeId, leaves: Fr[]): Uint8Array {
  return serializeWithMessagePack([treeId, leaves]);
}

function encodePublicDataLeaf(slot: Fr, value: Fr): Uint8Array {
  return serializeWithMessagePack({ slot, value });
}

function encodeNullifierLeaf(nullifier: Fr): Uint8Array {
  return serializeWithMessagePack({ nullifier });
}
