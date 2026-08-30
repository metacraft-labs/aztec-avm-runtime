// M36 — the wallet's note database, fed by the dev node's OWN block stream.
//
// ===========================================================================================
// WHY THIS IS OURS, MEASURED RATHER THAN ASSUMED (RI-99)
// ===========================================================================================
//
// Upstream HAS all of this — `NoteStore` (457 lines), `NoteService` (237), `LogService` (294),
// `SenderTaggingStore` (549), `RecipientTaggingStore`, `TaggingSecretSourcesStore`,
// `syncTaggedPrivateLogs` (356) — and **every one of them is a concrete class whose constructor is
// `constructor(store: AztecAsyncKVStore)`, with no interface this runtime could implement**. They
// are not typed against an abstraction; they are typed against `@aztec/kv-store`'s own map and
// multimap types. The kv backends published at the pin are LMDB (native — DD-9 forbids it),
// `sqlite-opfs`, and a `deprecated/indexeddb` one whose own export carries an `@deprecated` marker
// and is imported by nothing but two READMEs. There is **no in-memory note or tagging provider
// anywhere in `yarn-project/` at the anchor**: `MemoryNoteDataProvider`, `NoteDataProvider`,
// `TaggingDataProvider` and `PXEOracleInterface` return zero hits. So the rejection reason is
// `cannot-reach-target` and not "we didn't find one".
//
// WHAT IS REUSED IS EVERYTHING ABOVE THE STORE, and that is most of the difficulty:
//
//   * `pickNotes` — upstream's twelve-parameter note QUERY language (RI-98, vendored). A
//     `selectByOffsets` is counted from the LEAST significant byte and a `sortOrder` of 0 means no
//     sort at all; a second implementation of a query a CONTRACT is compiled against is the shape
//     this campaign refuses.
//   * `siloNoteHash` / `siloNullifier` / `computeUniqueNoteHash` — `@aztec/stdlib/hash`, which is
//     what makes note validation a CHECK rather than a formality (below).
//   * The `noir-structs` codecs and `resolved_tagging_strategy.ts` — already vendored by M35.
//
// ===========================================================================================
// THE VALIDATION IS UPSTREAM'S, AND IT IS THE WHOLE POINT
// ===========================================================================================
//
// `NoteService.validateAndStoreNotes` does four things a permissive version would not, and every
// one of them is the difference between a note database and a place to put whatever a contract
// says. Read out of upstream's own body and reproduced here against OUR block history:
//
//   1. **The siloed and unique note hashes are computed HERE, from the contract address**, never
//      taken from the request — upstream's own comment: *"By computing siloed and unique note hashes
//      ourselves we prevent contracts from interfering with the note storage of other contracts,
//      which would constitute a security breach."*
//   2. **The tx must be one this node produced.** Upstream errors rather than skipping, because a
//      missing tx effect means the node is buggy. Here it is `LocalHistoryOnly`, which says the same
//      thing about a different cause.
//   3. **The tx's block must not be newer than the anchor block.**
//   4. **The unique note hash must actually be in that tx's note hashes.** THIS IS THE
//      FABRICATED-NOTE REFUSAL: a contract that hands over a note the chain never recorded gets a
//      named error, not a row in the database. Without it every claim M36 makes about note
//      discovery would be a claim about a value the contract supplied.
//
// ===========================================================================================
// THE BOUNDARY
// ===========================================================================================
//
// See `local_history.ts`. This serves a chain we produced, not a chain we synced.

import { Fr } from '@aztec/foundation/curves/bn254';
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import {
  computeNoteHashNonce,
  computeSiloedPrivateLogFirstField,
  computeUniqueNoteHash,
  siloNoteHash,
  siloNullifier,
} from '@aztec/stdlib/hash';
import { Note, NoteStatus } from '@aztec/stdlib/note';

import { pickNotes } from '../vendor/pxe_notes/contract_function_simulator/pick_notes.ts';
import type { NoteData } from '../vendor/pxe/contract_function_simulator/noir-structs/note_data.ts';
import { LocalHistoryOnly } from './local_history.ts';

/** One transaction as the dev node sealed it. Everything the eight oracles need, and nothing else. */
export interface SyncedTx {
  /** Upstream's `TxHash` rendered as a `0x…` string — the key `validateAndStore…` joins on. */
  readonly txHash: string;
  /** Its position in the block, which is part of a note's ordering key. */
  readonly txIndexInBlock: number;
  /** The UNIQUE note hashes this transaction wrote to the note-hash tree, in order. */
  readonly noteHashes: readonly Fr[];
  /** The SILOED nullifiers it emitted, in order. `nullifiers[0]` is the tx's first nullifier. */
  readonly nullifiers: readonly Fr[];
  /** Its private logs, each a flat field array whose FIRST field is the siloed tag. */
  readonly privateLogs: readonly { readonly contractAddress: string; readonly fields: readonly Fr[] }[];
}

/** One block as the dev node sealed it. */
export interface SyncedBlock {
  readonly number: number;
  readonly timestamp: bigint;
  /** The block hash, as a field. */
  readonly hash: Fr;
  readonly txs: readonly SyncedTx[];
}

/** A row in the note table. Ours; upstream's `NoteDao` is a kv-store record and this is not one. */
export interface StoredNote {
  readonly contractAddress: AztecAddress;
  readonly owner: AztecAddress;
  readonly storageSlot: Fr;
  readonly randomness: Fr;
  readonly noteNonce: Fr;
  readonly content: readonly Fr[];
  /** The note hash as the CONTRACT emitted it, before siloing. */
  readonly noteHash: Fr;
  /** `computeUniqueNoteHash(noteNonce, siloNoteHash(contract, noteHash))`, computed HERE. */
  readonly uniqueNoteHash: Fr;
  /** `siloNullifier(contract, nullifier)`, computed HERE. */
  readonly siloedNullifier: Fr;
  readonly txHash: string;
  /**
   * The scopes that have OBSERVED this note — upstream's `StoredNote.scopes`, a SET.
   *
   * A note is keyed by its siloed nullifier and a second validation under a different scope UNIONS
   * the scope into this set rather than adding a second row. A list of rows would return the same
   * note twice from `getNotes`, and a contract would try to spend it twice.
   */
  readonly scopes: ReadonlySet<string>;
  readonly blockNumber: number;
  readonly txIndexInBlock: number;
  readonly noteIndexInTx: number;
}

/** A log the tag index found, with the on-chain context the oracles hand back with it. */
export interface RetrievedTaggedLog {
  readonly fields: readonly Fr[];
  readonly txHash: string;
  readonly blockNumber: number;
  readonly blockTimestamp: bigint;
  readonly blockHash: Fr;
  readonly noteHashes: readonly Fr[];
  readonly nullifiers: readonly Fr[];
  readonly txIndexInBlock: number;
}

/** What the note table was asked and what it answered — the "every decision explicable" half. */
export interface NoteDbEvent {
  readonly seq: number;
  readonly what: string;
  readonly detail: string;
}

/**
 * The wallet's note database.
 *
 * One instance per wallet, fed by `ingestBlock`. It holds four things and no more: a note table, a
 * tag-to-log index, the set of siloed nullifiers the chain has seen, and a per-contract sync-cache
 * validity flag. Everything else the eight oracles need is derived.
 */
export class DevNoteDatabase {
  /** Blocks in the order the node produced them. The ONLY source; there is no archiver client. */
  readonly #blocks: SyncedBlock[] = [];
  /** Every tx, by hash, so a validation request can be joined against the chain's own record. */
  readonly #txs = new Map<string, { tx: SyncedTx; block: SyncedBlock }>();
  /** Siloed tag (as a string) -> the logs carrying it, in block order. */
  readonly #logsByTag = new Map<string, RetrievedTaggedLog[]>();
  /** Every siloed nullifier the chain has emitted, with the block it landed in. */
  readonly #nullifiers = new Map<string, number>();
  /**
   * The note table, KEYED BY SILOED NULLIFIER — which is upstream's own key and is a deduplication
   * rather than an index.
   *
   * `NoteStore.addNotes` reads the existing note by its siloed nullifier and calls `addScope` on it;
   * `NoteStore.getNotes` collects into a `Map` keyed by the same value. **A list would return the
   * same note twice** for a note validated under two scopes — and a contract that got two copies of
   * one note would try to spend it twice, which is the double-count this milestone's own tagging
   * control is about, arriving from the storage side.
   */
  readonly #notes = new Map<string, StoredNote>();
  /** Contracts whose sync cache `setContractSyncCacheInvalid` has invalidated, by `contract:scope`. */
  readonly #invalidSyncCache = new Set<string>();
  /** Offchain effects delivered by `emitOffchainEffect`, in order. */
  readonly #offchainEffects: { readonly contractAddress: string; readonly fields: readonly string[] }[] = [];
  readonly #events: NoteDbEvent[] = [];
  #seq = 0;

  #record(what: string, detail: string): void {
    this.#events.push({ seq: this.#seq++, what, detail });
  }

  /** Everything this database was asked and what it answered, in order. */
  events(): readonly NoteDbEvent[] {
    return this.#events;
  }

  /** The highest block number ingested, or 0 when nothing has been. */
  get syncedToBlock(): number {
    return this.#blocks.length === 0 ? 0 : this.#blocks[this.#blocks.length - 1]!.number;
  }

  /** How many blocks are held. */
  get blockCount(): number {
    return this.#blocks.length;
  }

  /** The notes currently held, as rows. For a check to read; the oracles go through `getNotes`. */
  storedNotes(): readonly StoredNote[] {
    return [...this.#notes.values()];
  }

  /** The offchain effects `emitOffchainEffect` delivered. */
  offchainEffects(): readonly { readonly contractAddress: string; readonly fields: readonly string[] }[] {
    return this.#offchainEffects;
  }

  /** Whether a contract's sync cache is currently marked invalid. */
  isSyncCacheInvalid(contract: AztecAddress, scope: AztecAddress): boolean {
    return this.#invalidSyncCache.has(`${contract.toString()}:${scope.toString()}`);
  }

  /** How many (contract, scope) pairs are currently invalidated. */
  get invalidSyncCacheCount(): number {
    return this.#invalidSyncCache.size;
  }

  /**
   * Ingest one block the dev node produced.
   *
   * **BLOCKS ARRIVE IN ORDER AND A GAP IS AN ERROR.** A note database fed a block stream with a hole
   * in it would answer a tag query with a subset and look exactly like a tag query with no matches —
   * an absence produced by a missing input rather than by the chain, which is the shape this
   * campaign refuses. So the number is checked against the last one rather than trusted.
   */
  ingestBlock(block: SyncedBlock): void {
    const last = this.#blocks[this.#blocks.length - 1];
    if (last !== undefined && block.number <= last.number) {
      throw new Error(
        `DevNoteDatabase.ingestBlock: block ${block.number} arrived after block ${last.number}; ` +
          'the dev node\'s own stream is monotonic and a re-ingested or out-of-order block would ' +
          'double-count its logs and its nullifiers',
      );
    }
    this.#blocks.push(block);
    for (const tx of block.txs) {
      if (this.#txs.has(tx.txHash)) {
        throw new Error(`DevNoteDatabase.ingestBlock: transaction ${tx.txHash} is already in block ${this.#txs.get(tx.txHash)!.block.number}`);
      }
      this.#txs.set(tx.txHash, { tx, block });
      for (const nullifier of tx.nullifiers) {
        this.#nullifiers.set(nullifier.toString(), block.number);
      }
      for (const log of tx.privateLogs) {
        if (log.fields.length === 0) {
          throw new Error(`DevNoteDatabase.ingestBlock: an empty private log in tx ${tx.txHash} has no tag field`);
        }
        // THE TAG IS THE LOG'S FIRST FIELD, which is upstream's own layout — `toLogRetrievalResponse`
        // skips exactly one field (`logData.slice(1, …)`) before handing the payload to the contract.
        const tag = log.fields[0]!.toString();
        const entry: RetrievedTaggedLog = {
          fields: log.fields,
          txHash: tx.txHash,
          blockNumber: block.number,
          blockTimestamp: block.timestamp,
          blockHash: block.hash,
          noteHashes: tx.noteHashes,
          nullifiers: tx.nullifiers,
          txIndexInBlock: tx.txIndexInBlock,
        };
        const bucket = this.#logsByTag.get(tag);
        if (bucket) {
          bucket.push(entry);
        } else {
          this.#logsByTag.set(tag, [entry]);
        }
      }
    }
    this.#record(
      'ingestBlock',
      `block=${block.number} txs=${block.txs.length} logs=${block.txs.reduce((n, t) => n + t.privateLogs.length, 0)}`,
    );
  }

  /**
   * Every log carrying a siloed tag, optionally restricted to a block range.
   *
   * A range that reaches past what this node produced is `LocalHistoryOnly` — refused by name rather
   * than answered with the prefix that happens to exist. See `local_history.ts`.
   */
  logsByTag(tag: Fr, fromBlock?: number, toBlock?: number): readonly RetrievedTaggedLog[] {
    const upper = toBlock;
    if (upper !== undefined && upper > this.syncedToBlock) {
      throw new LocalHistoryOnly(
        'a tagged-log query',
        `blocks up to ${upper}`,
        `blocks 1..${this.syncedToBlock}`,
      );
    }
    const all = this.#logsByTag.get(tag.toString()) ?? [];
    const matched = all.filter(
      l => (fromBlock === undefined || l.blockNumber >= fromBlock) && (upper === undefined || l.blockNumber <= upper),
    );
    this.#record('logsByTag', `tag=${tag.toString()} matched=${matched.length} of ${all.length}`);
    return matched;
  }

  /** Whether a siloed nullifier is on the chain, and in which block. */
  nullifierBlock(siloedNullifier: Fr): number | undefined {
    return this.#nullifiers.get(siloedNullifier.toString());
  }

  /**
   * Upstream's `NoteService.validateAndStoreNotes`, against the history this node produced.
   *
   * Every one of the four refusals in this file's header is here, each with its own message, and
   * none of them is a warning-and-skip: a request that cannot be validated is an error, because the
   * alternative is a note database whose contents a contract chose.
   */
  async validateAndStoreNotes(
    requests: readonly {
      readonly contractAddress: AztecAddress;
      readonly owner: AztecAddress;
      readonly storageSlot: Fr;
      readonly randomness: Fr;
      readonly noteNonce: Fr;
      readonly content: readonly Fr[];
      readonly noteHash: Fr;
      readonly nullifier: Fr;
      readonly txHash: string;
    }[],
    scope: AztecAddress,
    anchorBlockNumber: number,
  ): Promise<number> {
    let stored = 0;
    for (const request of requests) {
      // (1) COMPUTED HERE, FROM THE CONTRACT ADDRESS, never taken from the request.
      const siloedNoteHash = await siloNoteHash(request.contractAddress, request.noteHash);
      const uniqueNoteHash = await computeUniqueNoteHash(request.noteNonce, siloedNoteHash);
      const siloed = await siloNullifier(request.contractAddress, request.nullifier);

      // (2) THE TX MUST BE ONE THIS NODE PRODUCED.
      const found = this.#txs.get(request.txHash);
      if (!found) {
        throw new LocalHistoryOnly(
          'a note validation request',
          `transaction ${request.txHash}`,
          `${this.#txs.size} transaction(s) across blocks 1..${this.syncedToBlock}`,
        );
      }

      // (3) AND IT MUST NOT BE NEWER THAN THE ANCHOR BLOCK.
      if (found.block.number > anchorBlockNumber) {
        throw new Error(
          `validateAndStoreNotes: transaction ${request.txHash} is in block ${found.block.number}, ` +
            `which is newer than the anchor block ${anchorBlockNumber}. A note from a block the ` +
            'execution is not anchored to would be a note from a chain state the circuit never saw.',
        );
      }

      // (4) THE FABRICATED-NOTE REFUSAL.
      const noteIndexInTx = found.tx.noteHashes.findIndex(nh => nh.equals(uniqueNoteHash));
      if (noteIndexInTx === -1) {
        throw new Error(
          `validateAndStoreNotes: note hash ${request.noteHash.toString()} (uniqued as ` +
            `${uniqueNoteHash.toString()}) is not among the ${found.tx.noteHashes.length} note hash(es) ` +
            `transaction ${request.txHash} actually wrote. A note the chain never recorded is refused ` +
            'rather than stored, because a stored one would then be spent.',
        );
      }

      // UPSTREAM'S `addNotes`: read by siloed nullifier, UNION the scope, write back. A note
      // validated a second time under a second scope is one note observed by two scopes, not two
      // notes.
      const key = siloed.toString();
      const existing = this.#notes.get(key);
      if (existing) {
        this.#notes.set(key, { ...existing, scopes: new Set([...existing.scopes, scope.toString()]) });
      } else {
        this.#notes.set(key, {
          contractAddress: request.contractAddress,
          owner: request.owner,
          storageSlot: request.storageSlot,
          randomness: request.randomness,
          noteNonce: request.noteNonce,
          content: [...request.content],
          noteHash: request.noteHash,
          uniqueNoteHash,
          siloedNullifier: siloed,
          txHash: request.txHash,
          scopes: new Set([scope.toString()]),
          blockNumber: found.block.number,
          txIndexInBlock: found.tx.txIndexInBlock,
          noteIndexInTx,
        });
        stored += 1;
      }
    }
    this.#record(
      'validateAndStoreNotes',
      `requests=${requests.length} stored=${stored} rows=${this.#notes.size} scope=${scope.toString()}`,
    );
    return stored;
  }

  /**
   * Upstream's `NoteStore.getNotes` filter, then upstream's `pickNotes` query — the split is
   * upstream's own and it is kept, because the two halves refuse different things.
   *
   * `status` is `NoteStatus.ACTIVE` by default and a nullified note is dropped; a note is nullified
   * when ITS OWN siloed nullifier is on the chain, which is a fact about a block and not a flag this
   * database sets.
   */
  getNotes(options: {
    contractAddress: AztecAddress;
    owner?: AztecAddress | undefined;
    storageSlot: Fr;
    status: number;
    scopes?: readonly AztecAddress[] | undefined;
    selects: { selector: { index: number; offset: number; length: number }; value: Fr; comparator: number }[];
    sorts: { selector: { index: number; offset: number; length: number }; order: number }[];
    limit: number;
    offset: number;
  }): NoteData[] {
    // UPSTREAM'S SET INTERSECTION, over a note's scope SET rather than over one scope. An empty
    // caller scope list intersects nothing and is refused at the ORACLE by `assertAllowedScope`
    // rather than silently answering [] here — measured: `scopes: []` returned zero notes over a
    // note that WAS stored, with every other figure right.
    const scopeSet = options.scopes ? new Set(options.scopes.map(s => s.toString())) : undefined;
    const rows = [...this.#notes.values()]
      .filter(n => n.contractAddress.equals(options.contractAddress))
      .filter(n => n.storageSlot.equals(options.storageSlot))
      .filter(n => (options.owner === undefined ? true : n.owner.equals(options.owner)))
      .filter(n => (scopeSet === undefined ? true : [...n.scopes].some(sc => scopeSet.has(sc))))
      .filter(n => {
        const nullified = this.#nullifiers.has(n.siloedNullifier.toString());
        return options.status === NoteStatus.ACTIVE_OR_NULLIFIED ? true : !nullified;
      })
      // Upstream's own ordering: block, then position in the block, then position in the tx.
      .sort(
        (a, b) =>
          a.blockNumber - b.blockNumber ||
          a.txIndexInBlock - b.txIndexInBlock ||
          a.noteIndexInTx - b.noteIndexInTx,
      );

    const asNoteData: NoteData[] = rows.map(n => ({
      note: new Note([...n.content]),
      contractAddress: n.contractAddress,
      owner: n.owner,
      storageSlot: n.storageSlot,
      randomness: n.randomness,
      noteNonce: n.noteNonce,
      noteHash: n.noteHash,
      // FALSE, AND IT IS A MEASUREMENT RATHER THAN A DEFAULT. Every note in this table came out of
      // a block that was sealed, so none of them is pending; upstream's pending notes live in
      // `ExecutionNoteCache`, which is the in-transaction half and is not what these oracles read.
      isPending: false,
      siloedNullifier: n.siloedNullifier,
    }));

    // UPSTREAM'S QUERY LANGUAGE, VENDORED, NOT REIMPLEMENTED (RI-98).
    const picked = pickNotes<NoteData>(asNoteData as never, {
      selects: options.selects,
      sorts: options.sorts,
      limit: options.limit,
      offset: options.offset,
    });
    this.#record(
      'getNotes',
      `contract=${options.contractAddress.toString()} slot=${options.storageSlot.toString()} ` +
        `status=${options.status} matched=${rows.length} picked=${picked.length}`,
    );
    return picked;
  }

  /** `setContractSyncCacheInvalid` — HONOURED: the pair is marked and the mark is readable. */
  invalidateSyncCache(contract: AztecAddress, scopes: readonly AztecAddress[]): number {
    // A CALL WITH NO SCOPES INVALIDATES NOTHING AND SAYS SO. Upstream's oracle takes a scope array;
    // treating an empty one as "invalidate everything" would be a plausible default over an input
    // whose meaning is "these scopes".
    for (const scope of scopes) {
      this.#invalidSyncCache.add(`${contract.toString()}:${scope.toString()}`);
    }
    this.#record('invalidateSyncCache', `contract=${contract.toString()} scopes=${scopes.length}`);
    return scopes.length;
  }

  /** `emitOffchainEffect` — HONOURED: the effect is DELIVERED here rather than only counted. */
  deliverOffchainEffect(contract: AztecAddress, fields: readonly Fr[]): number {
    this.#offchainEffects.push({
      contractAddress: contract.toString(),
      fields: fields.map(f => f.toString()),
    });
    this.#record('deliverOffchainEffect', `contract=${contract.toString()} fields=${fields.length}`);
    return this.#offchainEffects.length;
  }

  /** The tx a hash names, or `undefined`. Used by the log oracles to build their on-chain context. */
  txByHash(txHash: string): { tx: SyncedTx; block: SyncedBlock } | undefined {
    return this.#txs.get(txHash);
  }
}

/**
 * Turn ONE private frame's circuit public inputs into the transaction the dev node seals.
 *
 * ===========================================================================================
 * WHAT THIS IS, AND — MORE IMPORTANTLY — WHAT IT IS NOT
 * ===========================================================================================
 *
 * On a real network the PRIVATE KERNEL does this: it takes a private call's claimed side effects,
 * silos each note hash with the contract, computes each note's nonce from the transaction's first
 * nullifier, uniques the note hash, silos each nullifier and each private log's first field, and
 * proves that it did. **There is no kernel here and there is no proof** — §8.4's disclosure has said
 * so since M2 and it still crosses this seam.
 *
 * What IS real is everything on either side of it. The note hashes, the nullifiers and the private
 * logs are the CIRCUIT's own claimed public inputs, produced by upstream's `WASMSimulator` over real
 * ACIR; and every derivation below is upstream's own function from `@aztec/stdlib/hash`, not a
 * re-expression. So this is a labelled DEV SHORTCUT across one layer, with a real execution below it
 * and a real block above it — the same shape, and the same labelling, as the four
 * `[DEV SHORTCUT]` writes `DEV-WALLET.md` §7 records for the node side.
 *
 * IT IS ALSO WHY NOTE DISCOVERY IS MEASURABLE AT ALL. `validateAndStoreNotes` refuses a note whose
 * unique hash is not among the ones its transaction actually wrote — so the discovery path is only
 * exercised if a real note hash reaches a real block, and this is the one step between them.
 *
 * @param contract - the contract the frame executed as
 * @param publicInputs - the frame's own claimed side effects
 * @param txHash - the transaction hash; also the transaction's FIRST NULLIFIER, which is upstream's
 *   own protocol rule (`computeProtocolNullifier`) and is what every note nonce is derived from
 * @param txIndexInBlock - its position in the block
 */
export async function sealPrivateFrame(
  contract: AztecAddress,
  publicInputs: {
    readonly noteHashes: readonly string[];
    readonly nullifiers: readonly string[];
    readonly privateLogs: readonly { readonly fields: readonly string[]; readonly length: number }[];
  },
  txHash: Fr,
  txIndexInBlock: number,
): Promise<SyncedTx> {
  // THE FIRST NULLIFIER IS THE TRANSACTION'S OWN, AND IT COMES FIRST. Every note nonce is
  // `computeNoteHashNonce(nullifiers[0], index)`, so putting it anywhere but position 0 would give
  // every note in the transaction a nonce derived from the wrong seed — and the notes would still
  // validate against each other, which is what makes the ordering worth stating.
  const nullifiers: Fr[] = [txHash];
  for (const n of publicInputs.nullifiers) {
    nullifiers.push(await siloNullifier(contract, Fr.fromString(n)));
  }

  const noteHashes: Fr[] = [];
  for (let i = 0; i < publicInputs.noteHashes.length; i++) {
    const raw = Fr.fromString(publicInputs.noteHashes[i]!);
    const siloed = await siloNoteHash(contract, raw);
    const nonce = await computeNoteHashNonce(nullifiers[0]!, i);
    noteHashes.push(await computeUniqueNoteHash(nonce, siloed));
  }

  const privateLogs = [];
  for (const log of publicInputs.privateLogs) {
    if (log.fields.length === 0) {
      throw new Error('sealPrivateFrame: a private log with no fields has no tag to silo');
    }
    // The kernel's own siloing of a private log's first field, which is what makes the log
    // findable by the SILOED tag the recipient computes independently.
    const first = await computeSiloedPrivateLogFirstField(contract, Fr.fromString(log.fields[0]!));
    privateLogs.push({
      contractAddress: contract.toString(),
      fields: [first, ...log.fields.slice(1).map(f => Fr.fromString(f))],
    });
  }

  return {
    txHash: txHash.toString(),
    txIndexInBlock,
    noteHashes,
    nullifiers,
    privateLogs,
  };
}

/**
 * The note nonce a note at `index` in a transaction has — upstream's own rule, exposed so a caller
 * that builds a `NoteValidationRequest` uses the same derivation the sealer did rather than a
 * second one.
 */
export async function noteNonceFor(firstNullifier: Fr, index: number): Promise<Fr> {
  return computeNoteHashNonce(firstNullifier, index);
}
