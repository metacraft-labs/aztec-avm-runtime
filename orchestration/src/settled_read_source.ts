// settled_read_source.ts — M21, OQ-1: the whole `AztecNode` surface Form B needs.
//
// OQ-1 ASKED WHICH `AztecNode` METHODS `generateSimulatedProvingResult` CALLS. The answer is ONE,
// and upstream has already written it down in the type system:
//
//     async function verifyReadRequests(
//       node: Pick<AztecNode, 'findLeavesIndexes'>,          // contract_function_simulator.ts:799
//
// `generateSimulatedProvingResult` (`yarn-project/pxe/src/contract_function_simulator/
// contract_function_simulator.ts:472`, anchor `cpp` 233d8e0993) declares `node: AztecNode` but
// does exactly one thing with it: forwards it to `verifyReadRequests` at :603. That function's
// parameter is the `Pick<>` above, and its body calls `node.findLeavesIndexes(...)` twice — once
// for `MerkleTreeId.NOTE_HASH_TREE` (:835) and once for `MerkleTreeId.NULLIFIER_TREE` (:842) —
// and only when there is at least one read request classified `READ_AS_SETTLED`.
//
// So the deliverable's "so the adapter surface is a known quantity rather than a growing one" is
// satisfied by upstream's own narrowing, and what is worth pinning is that it STAYS one:
// `verify_oq1_aztec_node_methods_enumerated` re-derives the set from the anchor rather than
// reading it back from here.
//
// §8.4: THE PACKAGE EXPORTS NO TYPE NAMED `AztecNode` AND THIS IS NOT SHAPED LIKE ONE.
// `AztecNode` at the anchor is 60-odd methods — blocks, logs, contract data, tx submission, chain
// tips, prover coordination. A consumer who received something called an `AztecNode`, or something
// structurally assignable to one, could reasonably believe this runtime is a node. It is not, it
// proves nothing and it produces no blocks anyone else can verify. So the type below is named for
// the QUESTION it answers — has this leaf settled, and where — and has exactly one method.
//
// WHAT THE RESIDENT WORLD STATE CAN AND CANNOT ANSWER, MEASURED AGAINST REACTOR-ABI.md's
// `LowLevelMerkleDBInterface` (fourteen exports):
//
//   * NULLIFIER_TREE is INDEXED. `avm_merkle_db_get_low_indexed_leaf([treeId, value])` answers
//     with the index of the greatest leaf <= the value asked for, plus `is_already_present`. That
//     is exactly "is this value settled, and at what index", so the nullifier arm is answered by
//     the module itself, the way `resident_db.ts`'s public-data read-back is.
//   * NOTE_HASH_TREE is APPEND-ONLY. The exported surface has `avm_merkle_db_get_leaf_value(tree,
//     index)` — index to value — and NOTHING that goes the other way. There is no
//     `find_leaf_index` among the fourteen. A value-to-index answer would be a linear scan of the
//     whole tree per read request.
//
//     This is not a gap that needs a new export, because THIS RUNTIME OWNS THE APPENDS: every note
//     hash in a block it produced went in through `avm_merkle_db_append_leaves`, in order, from
//     here. So the note-hash arm is answered from an index kept on this side of the boundary as
//     the appends happen. That is recorded as a DEPARTURE rather than left implicit: the index is
//     authoritative only for leaves this runtime appended, and `noteHashesAppended` reports how
//     many it has seen so a caller can tell an empty index from an index that was never fed.
//
// A `findLeavesIndexes` that answered `undefined` for a note hash that HAS settled would make
// `verifyReadRequests` throw "reading an unknown note hash" — a transaction rejected for a reason
// that is about this adapter and not about the transaction. That failure direction is why the
// index is fed rather than approximated.

import { serializeWithMessagePack } from '@aztec/stdlib/avm';
import { MerkleTreeId } from '@aztec/stdlib/trees';
import type { Fr } from '@aztec/foundation/curves/bn254';

import type { BlobCallable } from './resident_db.ts';

/**
 * The ONE method, with upstream's own name and argument order.
 *
 * The name is upstream's on purpose: this is the seam `generateSimulatedProvingResult` reaches
 * through, and spelling it differently would mean an adapter object between two things that agree.
 * What is NOT upstream's is the type's name, and that is §8.4.
 *
 * `blockParameter` is accepted and IGNORED, and that is a stated limitation rather than an
 * oversight: this runtime holds one resident world state at its current revision and cannot answer
 * "was this leaf settled as of block N" for any N but the latest. Upstream passes the transaction's
 * anchor block hash. A caller that needs historical settlement wants M22's block store, and the
 * argument is kept in the signature so the day it is honoured no call site moves.
 */
export interface SettledLeafIndexSource {
  findLeavesIndexes(
    blockParameter: unknown,
    treeId: MerkleTreeId,
    values: Fr[],
  ): Promise<(bigint | undefined)[]>;
}

/** The trees `verifyReadRequests` asks about, in the order its two calls appear. */
export const SETTLED_READ_TREES: readonly MerkleTreeId[] = [
  MerkleTreeId.NOTE_HASH_TREE,
  MerkleTreeId.NULLIFIER_TREE,
];

/** Thrown when something reaches for a method this adapter deliberately does not have. */
export class SettledReadSourceSurfaceExceeded extends Error {
  readonly kind = 'settled-read-source-surface-exceeded' as const;
  readonly property: string;

  constructor(property: string) {
    super(
      `the settled-read source was asked for '${property}', which is not one of the `
        + `${ALLOWED_SURFACE.length} member(s) it has. OQ-1 enumerated the AztecNode surface `
        + `Form B needs and it is 'findLeavesIndexes' alone; anything else is a dependency `
        + `surface growing by accident, which is the thing that enumeration exists to prevent. `
        + `§8.4: this is NOT an AztecNode and must not be made to look like one.`,
    );
    this.property = property;
  }
}

/**
 * Everything a caller may touch. `findLeavesIndexes` is the deliverable; the other three are this
 * adapter's own bookkeeping and are named here so the guard below cannot be defeated by adding a
 * field and forgetting to declare it.
 */
export const ALLOWED_SURFACE: readonly string[] = [
  'findLeavesIndexes',
  'noteHashAppended',
  'noteHashesAppended',
  'constructor',
];

/**
 * A settled-read source over the world state resident in `avm.wasm`.
 *
 * `module`/`handle` are the same pair `ResidentMerkleDb` takes, deliberately: two objects reading
 * one world state through one boundary, rather than a second boundary with its own idea of the
 * revision.
 */
export class ResidentSettledReadSource implements SettledLeafIndexSource {
  private readonly module: BlobCallable;
  private readonly handle: number;
  /** value (as decimal) -> index, for note hashes THIS runtime appended. See the header. */
  private readonly noteHashIndex = new Map<string, bigint>();

  constructor(module: BlobCallable, handle: number) {
    this.module = module;
    this.handle = handle;
  }

  /** Record a note hash this runtime appended, at the index the append put it. */
  noteHashAppended(value: Fr, index: bigint): void {
    this.noteHashIndex.set(value.toBigInt().toString(), index);
  }

  /** How many appends this index has been told about. Zero is a fact, not an absence. */
  get noteHashesAppended(): number {
    return this.noteHashIndex.size;
  }

  async findLeavesIndexes(
    _blockParameter: unknown,
    treeId: MerkleTreeId,
    values: Fr[],
  ): Promise<(bigint | undefined)[]> {
    if (treeId === MerkleTreeId.NOTE_HASH_TREE) {
      return values.map((v) => this.noteHashIndex.get(v.toBigInt().toString()));
    }
    if (treeId === MerkleTreeId.NULLIFIER_TREE) {
      return values.map((v) => this.lowIndexedLeafIndex(treeId, v));
    }
    // NOT a silent `undefined` per value. `verifyReadRequests` reads an `undefined` as "this leaf
    // has not settled" and rejects the transaction, so answering it for a tree we simply cannot
    // search would report an adapter limitation as a bad transaction.
    throw new SettledReadSourceSurfaceExceeded(`findLeavesIndexes on tree ${String(treeId)}`);
  }

  private lowIndexedLeafIndex(treeId: MerkleTreeId, value: Fr): bigint | undefined {
    const low = this.module.callWithBlob(
      'avm_merkle_db_get_low_indexed_leaf',
      this.handle,
      serializeWithMessagePack([treeId, value]),
    ) as { is_already_present?: boolean; index?: unknown } | null;
    // `is_already_present` is checked rather than assumed, for the reason `resident_db.ts` records:
    // the low leaf of an ABSENT value is its predecessor, so skipping the flag returns a real
    // index for a leaf that is not there.
    if (!low || low.is_already_present !== true || low.index === undefined) {
      return undefined;
    }
    return BigInt(Number(low.index));
  }
}

/**
 * Wrap a source so that reaching for anything outside `ALLOWED_SURFACE` THROWS.
 *
 * WHY A PROXY AND NOT JUST A NARROW TYPE. A narrow type is erased: `node as any`,
 * `Reflect.get(node, 'getBlockHeader')`, a duck-typed helper that probes for a method before
 * calling it — all of them walk straight past it, and each is how a "narrow adapter" grows a
 * surface without anyone editing its declaration. The proxy makes the growth a runtime failure at
 * the site of the reach.
 *
 * The trap list is `get` plus `has`, because `'getBlockHeader' in node` is how a probe asks, and a
 * probe that gets `false` silently takes a different path instead of failing. `ownKeys` is
 * deliberately NOT trapped: enumerating an object is not reaching for a method, and
 * `util.inspect`/`console.log` of the adapter has to stay possible — this is a debugging aid, not
 * a secret. That is the opposite call from `submitted_tx.ts`'s seal, and for the opposite reason:
 * there, disclosure WAS the hazard.
 */
export function strictSurface<T extends object>(source: T): T {
  return new Proxy(source, {
    get(target, property, receiver) {
      if (typeof property === 'symbol') {
        // Symbols are the language's own protocol keys (`Symbol.toStringTag`,
        // `Symbol.asyncIterator`, the inspect hook). Refusing them breaks `console.log` and
        // `await`, and none of them is an AztecNode method.
        return Reflect.get(target, property, receiver);
      }
      if (!ALLOWED_SURFACE.includes(property)) {
        throw new SettledReadSourceSurfaceExceeded(property);
      }
      // THE RECEIVER IS THE TARGET AND NOT THE PROXY, and that is not a detail. A getter reached
      // through `Reflect.get(target, property, proxy)` runs with `this` bound to the PROXY, so its
      // own `this.noteHashIndex` re-enters this trap and throws — the guard refusing the object's
      // own internals. Found by running it: `noteHashesAppended`, a permitted member, threw
      // `SettledReadSourceSurfaceExceeded: … asked for 'noteHashIndex'`. The guard is about the
      // EXTERNAL surface; an object's own fields are not a dependency surface.
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
    has(target, property) {
      if (typeof property === 'symbol') {
        return Reflect.has(target, property);
      }
      if (!ALLOWED_SURFACE.includes(property)) {
        throw new SettledReadSourceSurfaceExceeded(property);
      }
      return Reflect.has(target, property);
    },
  });
}
