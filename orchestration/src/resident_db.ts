// resident_db.ts — seeding the world state that lives inside `avm.wasm`.
//
// WHAT THIS IS AND IS NOT, because M18 left a gap here and M19 filled part of it somewhere else.
//
// M18's outstanding task "seed the resident DBs from TypeScript" is still open in the sense that
// matters for M21+: there is no encoder here for `ContractClassPublic` or
// `ContractInstanceWithAddress`. M19 wrote one — `registerClass` / `registerInstance` in
// `diffsim/src/public/public_tx_simulator/differential/resident_avm.ts` — and it is correct, but
// it lives inside a three-way differential harness whose whole purpose is to hold two other AVM
// implementations beside this one. `orchestration/` must not depend on that, and copying 500
// lines to get two methods would be the sixth copy of a file this repository already has five of.
//
// So this module covers exactly what M20 needs and says so: the two MERKLE-tree seeding writes.
// The contract-DB registration pair stays M18's outstanding task, now with a named prior
// implementation to lift rather than an unknown.
//
// THE BLOB SHAPES ARE THE C++ STRUCTS' MSGPACK, and they are two of the forty-two REACTOR-ABI.md
// enumerates. Both are `{field: Fr}` maps rather than tuples, which is worth stating because the
// contract-DB pair beside them is a tuple and a map, respectively — there is no house rule to
// fall back on:
//
//   avm_merkle_db_insert_indexed_leaves_nullifier_tree    <- { nullifier }
//   avm_merkle_db_insert_indexed_leaves_public_data_tree  <- { slot, value }
//
// `serializeWithMessagePack` is upstream's — `@aztec/stdlib/avm`, the same call `avm_inputs.ts`
// makes — so an `Fr` goes out as the 32-byte big-endian `bin` the C++ reads and no layout is
// decided here.
//
// ONE CLASS OF `Fr` PER PROCESS. Five `node_modules` roots in this repository each carry their own
// `@aztec/stdlib`, and `serializeWithMessagePack` recognises an `Fr` by the extension registered
// against ITS OWN class object. An `Fr` built from a different install serialises as a plain
// object and the C++ side rejects the blob — or worse, reads a field that happens to decode. Every
// value handed to this module must come from the same install as this module. The hazard is
// documented at
// `diffsim/src/public/public_tx_simulator/differential/encode_inputs.ts:22-42`.

import { serializeWithMessagePack } from '@aztec/stdlib/avm';
import { MerkleTreeId } from '@aztec/stdlib/trees';
import type { Fr } from '@aztec/foundation/curves/bn254';

import type { ResidentPublicDataTree } from './fee_juice.ts';

/**
 * The narrow view of a module this file needs: hand a msgpack blob to a named export against a
 * handle. Structural for the same reason `AvmBoundary` is — M28's browser host is a different
 * implementation, not a subclass.
 */
export interface BlobCallable {
  callWithBlob(exportName: string, handle: number, blob: Uint8Array): unknown;
}

/**
 * The resident merkle DB, seeded.
 *
 * Deliberately NOT a `MerkleTreeWriteOperations`. Upstream's interface has four mutating methods
 * and a caller who saw one implemented would reasonably assume the rest; M19's review found
 * exactly that defect in a mirror that claimed to be total and intercepted two of the four. Two
 * methods, named for what they do, is the honest surface.
 */
export class ResidentMerkleDb implements ResidentPublicDataTree {
  private readonly module: BlobCallable;
  private readonly handle: number;

  constructor(module: BlobCallable, handle: number) {
    this.module = module;
    this.handle = handle;
  }

  /** Insert a nullifier into the indexed nullifier tree. A duplicate is a collision downstream. */
  insertNullifier(nullifier: Fr): void {
    this.module.callWithBlob(
      'avm_merkle_db_insert_indexed_leaves_nullifier_tree',
      this.handle,
      serializeWithMessagePack({ nullifier }),
    );
  }

  /** Insert a public-data leaf. `leafSlot` is the SILOED slot, not the contract's storage slot. */
  insertPublicDataLeaf(leafSlot: Fr, value: Fr): void {
    this.module.callWithBlob(
      'avm_merkle_db_insert_indexed_leaves_public_data_tree',
      this.handle,
      serializeWithMessagePack({ slot: leafSlot, value }),
    );
  }

  /**
   * Whether a nullifier is in the indexed nullifier tree.
   *
   * M34. It is the same two-call shape as {@link readPublicDataLeaf} with the OTHER tree id, and
   * `is_already_present` is again the field that decides it — the AVM's own answer to "does this
   * leaf exist", rather than an inference from a predecessor's value. M29 established why this
   * question matters at all: the AVM decides a contract EXISTS by looking for its address nullifier
   * here, so "is this contract published" and "is this contract initialized" are both nullifier
   * lookups and neither is a fact the caller can be trusted to supply.
   *
   * The preimage is read back and its `nullifier` field compared against the one asked for, for
   * `readPublicDataLeaf`'s reason: `is_already_present` alone would make a misspelled msgpack key
   * read as "absent" for every input, which is the direction that looks like a clean tree.
   *
   * @param nullifier - the siloed nullifier
   * @returns whether the tree holds it
   */
  nullifierExists(nullifier: Fr): boolean {
    const low = this.module.callWithBlob(
      'avm_merkle_db_get_low_indexed_leaf',
      this.handle,
      serializeWithMessagePack([MerkleTreeId.NULLIFIER_TREE, nullifier]),
    ) as { is_already_present?: boolean; index?: unknown } | null;
    if (!low || low.is_already_present !== true) {
      return false;
    }
    const preimage = this.module.callWithBlob(
      'avm_merkle_db_get_leaf_preimage_nullifier_tree',
      this.handle,
      serializeWithMessagePack(Number(low.index)),
    ) as { leaf?: { nullifier?: unknown } } | null;
    const leaf = preimage?.leaf;
    if (!leaf) {
      return false;
    }
    return bigintOf(leaf.nullifier) === nullifier.toBigInt();
  }

  /**
   * Read a public-data leaf back, as a decimal string, or `null` when the slot has no leaf.
   *
   * TWO CALLS, BECAUSE THE INDEXED TREE IS ADDRESSED BY INDEX AND NOT BY SLOT.
   * `avm_merkle_db_get_low_indexed_leaf([treeId, slot])` answers with the index of the greatest
   * leaf whose slot is <= the one asked for, plus whether that leaf IS the one asked for;
   * `avm_merkle_db_get_leaf_preimage_public_data_tree(index)` then yields `{slot, value}`.
   *
   * `is_already_present` is checked rather than assumed. Skipping it returns the PREDECESSOR's
   * value for an absent slot — a plausible number for the wrong slot, which is exactly the shape
   * of wrong answer a balance assertion must not be able to produce. The decoded `slot` is
   * compared against the requested one as well, so the check does not depend on one field.
   *
   * THE FIELD IS `is_already_present`, snake_case, because it is the C++ struct's own member name
   * and msgpack carries member names verbatim. A first version of this read `alreadyPresent` and
   * every lookup returned `null` — including the one that had just been written — which reads as
   * "the slot is empty" rather than as "the key is misspelled". The slot comparison beside it is
   * what turns that from a silent `null` into a caught disagreement.
   */
  readPublicDataLeaf(leafSlot: Fr): string | null {
    const low = this.module.callWithBlob(
      'avm_merkle_db_get_low_indexed_leaf',
      this.handle,
      serializeWithMessagePack([MerkleTreeId.PUBLIC_DATA_TREE, leafSlot]),
    ) as { is_already_present?: boolean; index?: unknown } | null;
    if (!low || low.is_already_present !== true) {
      return null;
    }
    const preimage = this.module.callWithBlob(
      'avm_merkle_db_get_leaf_preimage_public_data_tree',
      this.handle,
      serializeWithMessagePack(Number(low.index)),
    ) as { leaf?: { slot?: unknown; value?: unknown } } | null;
    const leaf = preimage?.leaf;
    if (!leaf) {
      return null;
    }
    if (bigintOf(leaf.slot) !== leafSlot.toBigInt()) {
      return null;
    }
    const value = bigintOf(leaf.value);
    return value === undefined ? null : value.toString();
  }
}

/**
 * A field element as node-host's dependency-free decoder leaves it: a big-endian `Uint8Array`.
 *
 * This module reads through `Reactor.callWithBlob`, which uses that decoder rather than the one
 * with upstream's extensions registered, so a 32-byte `bin` arrives as bytes and never as an `Fr`.
 * Converting here rather than importing a second decoder keeps this file's only @aztec dependency
 * the encoder.
 */
function bigintOf(value: unknown): bigint | undefined {
  if (typeof value === 'bigint') return value;
  if (typeof value === 'number') return BigInt(value);
  if (value instanceof Uint8Array) {
    let acc = 0n;
    for (const byte of value) acc = (acc << 8n) | BigInt(byte);
    return acc;
  }
  return undefined;
}
