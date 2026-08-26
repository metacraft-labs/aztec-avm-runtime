// The ABI binding: one place where a call crosses into `avm.wasm`, and one place where what comes
// back is classified.
//
// OWNERSHIP, AND WHY IT DOES NOT LEAK ON AN ERROR PATH.
//
// Two directions, and they have different rules, both of them REACTOR-ABI.md's:
//
//   * HOST -> MODULE. An input blob is `avm_alloc`ed, written, passed, and freed. The free is in a
//     `finally`, so a status of 1, an exception thrown by the decoder, and a trap all reach it. The
//     pointer is recorded in `owned` when it is allocated and removed when it is freed, so a leak
//     is a NUMBER this host can report rather than an impression — `ownedAllocations` is asserted
//     to be zero at the end of every transcript run.
//   * MODULE -> HOST. Results are NOT allocated per call. Every call that produces bytes leaves
//     them in one module-owned buffer and returns a status; the host reads `avm_result_ptr()` /
//     `avm_result_len()` and COPIES them out before the next call. That is upstream's design and
//     it is the reason the error path cannot leak at all in this direction: there is nothing for
//     the host to own.
//
// AND ONE CASE THAT IS NOT A LEAK EVEN THOUGH IT LOOKS LIKE ONE. After a trap, the instance is
// dead: its linear memory is in an undefined state and calling `avm_free` on it would trap again.
// So the `finally` does NOT free into a poisoned instance. The allocations are recorded as
// `leakedAtTrap` and the instance is discarded whole, which reclaims the memory in one step. A
// host that tried to tidy up after a trap would be a host that trusts a dead instance's allocator.

import { AvmHostError, AvmInstancePoisoned, AvmTrap, isTrapLike, outcomeOf, type TxOutcome } from './errors.ts';
import { unpack, type MsgpackValue } from './msgpack.ts';
import { PAGE_BYTES, type MemoryImport } from './memory.ts';

/** The exports this binding uses. Named individually so a missing one is a type error. */
export interface ReactorExports {
  readonly avm_abi_version: () => number;
  readonly avm_alloc: (size: number) => number;
  readonly avm_free: (ptr: number, size: number) => void;
  readonly avm_result_ptr: () => number;
  readonly avm_result_len: () => number;
  readonly avm_simulate: (ptr: number, len: number, cdb: number, mdb: number) => number;
  readonly avm_simulate_with_hinted_dbs: (ptr: number, len: number) => number;
  readonly avm_steps_count: () => number;
  readonly avm_steps_batch: (from: number, count: number) => number;
  readonly avm_contract_db_create: () => number;
  readonly avm_contract_db_destroy: (handle: number) => void;
  readonly avm_contract_db_register_class: (handle: number, ptr: number, len: number) => number;
  readonly avm_contract_db_register_instance: (handle: number, ptr: number, len: number) => number;
  readonly avm_merkle_db_create: () => number;
  readonly avm_merkle_db_destroy: (handle: number) => void;
  readonly avm_merkle_db_get_tree_roots: (handle: number) => number;
  readonly avm_merkle_db_insert_indexed_leaves_nullifier_tree: (h: number, ptr: number, len: number) => number;
  readonly avm_merkle_db_insert_indexed_leaves_public_data_tree: (h: number, ptr: number, len: number) => number;
  readonly [name: string]: unknown;
}

/** REACTOR-ABI.md's status table. 0 is the only success. */
export const AVM_STATUS_OK = 0;

export class Reactor {
  readonly exports: ReactorExports;
  readonly memory: WebAssembly.Memory;
  readonly memoryImport: MemoryImport;

  /** ptr -> size, so a leak is a fact rather than an impression. */
  private readonly owned = new Map<number, number>();
  private poisonedBy: AvmTrap | null = null;
  private leaked = 0;
  /** Calls made INTO the module, counted at the boundary itself so "zero crossings" is measured. */
  private calls = 0;

  constructor(exports: ReactorExports, memory: WebAssembly.Memory, memoryImport: MemoryImport) {
    this.exports = exports;
    this.memory = memory;
    this.memoryImport = memoryImport;
  }

  /** The instance trapped and must never be used again. */
  get poisoned(): boolean {
    return this.poisonedBy !== null;
  }

  /** The trap that poisoned it, for a caller that wants to report the original cause. */
  get poisonCause(): AvmTrap | null {
    return this.poisonedBy;
  }

  /** Host allocations still outstanding. Zero at the end of a well-behaved run. */
  get ownedAllocations(): number {
    return this.owned.size;
  }

  /** Allocations abandoned because the instance trapped while they were live. */
  get leakedAtTrap(): number {
    return this.leaked;
  }

  /**
   * Calls made into the module so far.
   *
   * Counted here, at the one boundary, rather than by the callers, so a claim of the form "this
   * route costs no further crossings" is a DIFFERENCE OF TWO READINGS rather than a constant a
   * probe printed. `test_node_step_stream_batching` asserts exactly that about the step stream that
   * arrives inside `TxSimulationResult`, and a zero that nothing measured could not have failed.
   */
  get moduleCalls(): number {
    return this.calls;
  }

  /**
   * The names this module exports.
   *
   * Here so that a consumer can ask the ARTEFACT what it can do rather than being told by a
   * constant or a constructor flag. `residentModuleHasArchive` is the first caller: M14's archive
   * extension reaches some builds of `avm.wasm` and not others, and a database that decided which
   * by a flag its caller passed would eventually be handed the wrong one — the direction that
   * matters, because the wrong answer there is a merkle root that certifies nothing.
   *
   * It is a getter over `this.exports` rather than a list captured at construction so that it
   * cannot drift from the object the calls actually go through.
   */
  get exportNames(): readonly string[] {
    return Object.keys(this.exports);
  }

  get pages(): number {
    return this.memory.buffer.byteLength / PAGE_BYTES;
  }

  get memoryBytes(): number {
    return this.memory.buffer.byteLength;
  }

  view(): Uint8Array {
    return new Uint8Array(this.memory.buffer);
  }

  // -------------------------------------------------------------------------------------------
  // THE ONE BOUNDARY. Everything below goes through this, so "a trap is reported as a trap" is a
  // property of one function.
  // -------------------------------------------------------------------------------------------
  private enter(exportName: string): void {
    if (this.poisonedBy) throw new AvmInstancePoisoned(exportName);
  }

  /**
   * Calls an export and classifies the result.
   *
   * A trap POISONS the instance and is rethrown as `AvmTrap`. A non-zero status is `AvmHostError`
   * carrying the module's own `AvmReactorError.message`. A status of 0 returns normally. Nothing
   * here can turn a trap into a status or a status into an outcome.
   */
  callGuarded(exportName: string, call: () => number): number {
    this.enter(exportName);
    this.calls++;
    let status: number;
    try {
      status = call();
    } catch (e) {
      if (isTrapLike(e)) throw this.poison(exportName, e);
      throw e;
    }
    if (status !== AVM_STATUS_OK) {
      throw new AvmHostError(exportName, status, this.errorMessage() ?? '(no error payload)');
    }
    return status;
  }

  /** A void export (no status): `avm_contract_db_destroy`, `avm_steps_count`, `avm_abi_version`. */
  callRaw<T>(exportName: string, call: () => T): T {
    this.enter(exportName);
    this.calls++;
    try {
      return call();
    } catch (e) {
      if (isTrapLike(e)) throw this.poison(exportName, e);
      throw e;
    }
  }

  private poison(exportName: string, cause: unknown): AvmTrap {
    const trap = new AvmTrap(exportName, cause);
    this.poisonedBy = trap;
    // Deliberately NOT freed: the allocator lives in the memory that is now undefined.
    this.leaked += this.owned.size;
    this.owned.clear();
    return trap;
  }

  // -------------------------------------------------------------------------------------------
  // Linear memory
  // -------------------------------------------------------------------------------------------
  alloc(size: number): number {
    const ptr = this.callRaw('avm_alloc', () => this.exports.avm_alloc(size));
    if (ptr === 0) throw new AvmHostError('avm_alloc', 0, `avm_alloc(${size}) returned null`);
    this.owned.set(ptr, size);
    return ptr;
  }

  free(ptr: number): void {
    const size = this.owned.get(ptr);
    if (size === undefined) {
      throw new AvmHostError('avm_free', 0, `avm_free of a pointer this host does not own: ${ptr}`);
    }
    this.callRaw('avm_free', () => this.exports.avm_free(ptr, size));
    this.owned.delete(ptr);
  }

  /** Copies bytes into a fresh module allocation. The caller owns the pointer. */
  put(bytes: Uint8Array): number {
    const ptr = this.alloc(bytes.length);
    this.view().set(bytes, ptr);
    return ptr;
  }

  /**
   * Runs `body` with `bytes` resident in linear memory and frees the allocation whatever happens —
   * except after a trap, where freeing into a dead allocator is the wrong thing to do.
   */
  withBlob<T>(bytes: Uint8Array, body: (ptr: number, len: number) => T): T {
    const ptr = this.put(bytes);
    try {
      return body(ptr, bytes.length);
    } finally {
      if (!this.poisoned) this.free(ptr);
    }
  }

  /** A copy of the module's result buffer, or null when the call produced no bytes. */
  result(): Uint8Array | null {
    const ptr = this.exports.avm_result_ptr();
    const len = this.exports.avm_result_len();
    if (len === 0) return null;
    // Copied: the module owns that buffer and the next call overwrites it.
    return this.view().slice(ptr, ptr + len);
  }

  /** The `AvmReactorError.message` left by the last failing call, or null. */
  errorMessage(): string | null {
    const buf = this.result();
    if (!buf) return null;
    try {
      const v = unpack(buf) as { message?: unknown };
      return typeof v.message === 'string' ? v.message : null;
    } catch {
      return null;
    }
  }

  /** Decodes the result buffer, or null for a void method. */
  decodedResult(): MsgpackValue | null {
    const buf = this.result();
    return buf ? unpack(buf) : null;
  }

  // -------------------------------------------------------------------------------------------
  // The two entry points
  // -------------------------------------------------------------------------------------------
  abiVersion(): number {
    return this.callRaw('avm_abi_version', () => this.exports.avm_abi_version());
  }

  /**
   * The resident-DB entry point. Returns a TRANSACTION OUTCOME.
   *
   * A revert is an outcome with a non-zero `revertCode`. It is not thrown, because it is not an
   * error: the transaction ran, it reverted, it lands in a block and it pays its fee.
   */
  simulate(input: Uint8Array, contractDb: number, merkleDb: number): TxOutcome<MsgpackValue> {
    return this.withBlob(input, (ptr, len) => {
      this.callGuarded('avm_simulate', () => this.exports.avm_simulate(ptr, len, contractDb, merkleDb));
      return outcomeOf(this.decodedResult());
    });
  }

  /** The hinted entry point. Same outcome discipline. */
  simulateWithHintedDbs(input: Uint8Array): TxOutcome<MsgpackValue> {
    return this.withBlob(input, (ptr, len) => {
      this.callGuarded('avm_simulate_with_hinted_dbs', () =>
        this.exports.avm_simulate_with_hinted_dbs(ptr, len),
      );
      return outcomeOf(this.decodedResult());
    });
  }

  /**
   * Calls `avm_simulate` with a POINTER THE HOST CHOSE rather than one the module allocated.
   *
   * This is the deliberate trap of `test_wasm_trap_vs_avm_revert_distinguished`, and it is a
   * genuine one on the real module rather than on a toy: a pointer past the end of linear memory
   * makes the module's own msgpack reader load out of bounds, which is a wasm TRAP and therefore
   * something `guarded()` on the C++ side cannot catch, because it is not an exception. It is also
   * exactly the shape of the host bug the deliverable is about — a host that computed a pointer
   * wrongly — which is why it is the induced failure rather than a synthetic `unreachable`.
   */
  simulateAtRawPointer(ptr: number, len: number, contractDb: number, merkleDb: number): TxOutcome<MsgpackValue> {
    this.callGuarded('avm_simulate', () => this.exports.avm_simulate(ptr, len, contractDb, merkleDb));
    return outcomeOf(this.decodedResult());
  }

  // -------------------------------------------------------------------------------------------
  // Handles
  // -------------------------------------------------------------------------------------------
  createContractDb(): number {
    return this.callRaw('avm_contract_db_create', () => this.exports.avm_contract_db_create());
  }

  destroyContractDb(handle: number): void {
    this.callRaw('avm_contract_db_destroy', () => this.exports.avm_contract_db_destroy(handle));
  }

  createMerkleDb(): number {
    return this.callRaw('avm_merkle_db_create', () => this.exports.avm_merkle_db_create());
  }

  destroyMerkleDb(handle: number): void {
    this.callRaw('avm_merkle_db_destroy', () => this.exports.avm_merkle_db_destroy(handle));
  }

  /** A `(handle, blob) -> status` interface method. Decoded result, or null for a void one. */
  callWithBlob(exportName: string, handle: number, blob: Uint8Array): MsgpackValue | null {
    const fn = this.exports[exportName] as (h: number, p: number, l: number) => number;
    if (typeof fn !== 'function') throw new AvmHostError(exportName, 0, 'no such export');
    return this.withBlob(blob, (ptr, len) => {
      this.callGuarded(exportName, () => fn(handle, ptr, len));
      return this.decodedResult();
    });
  }

  /** A `(handle) -> status` interface method. */
  callWithHandle(exportName: string, handle: number): MsgpackValue | null {
    const fn = this.exports[exportName] as (h: number) => number;
    if (typeof fn !== 'function') throw new AvmHostError(exportName, 0, 'no such export');
    this.callGuarded(exportName, () => fn(handle));
    return this.decodedResult();
  }
}
