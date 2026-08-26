// The event record, and the module's exported surface.
//
// THE RECORD LAYOUT IS DECLARED IN THE MODULE AND CHECKED HERE, NOT DECLARED HERE.
// `ct_record_size()` is an export for exactly this reason: a host that hardcodes 64 and a module
// that grows to 72 disagree silently and produce a container full of misaligned garbage — every
// field shifted, nothing thrown, a `.ct` that opens. `CtWriter.open` reads the module's answer
// and refuses on disagreement. This campaign's rule, stated in its own brief: if a check needs a
// number that also exists in the thing under test, take it FROM the thing under test.
//
// LITTLE-ENDIAN EVERYWHERE. wasm linear memory is little-endian by specification, so
// `DataView.setUint32(off, v, true)` here and `u32::from_le_bytes` there agree on every engine.
// The `true` argument is not optional and is not a default: `DataView` defaults to BIG-endian,
// which is the one place in this file where forgetting an argument produces a silently wrong
// container rather than an error.

/** Bytes per event record. Asserted against the module's own `ct_record_size()`. */
export const RECORD_SIZE = 64;

/** Field offsets within a record. Mirrors `ct-writer/src/lib.rs`'s `OFF_*` constants. */
export const OFF_CONTEXT_ID = 0;
export const OFF_PC = 4;
export const OFF_OPCODE = 8;
export const OFF_RESERVED = 12;
export const OFF_L2_GAS = 16;
export const OFF_DA_GAS = 24;
export const OFF_ADDRESS = 32;
export const ADDRESS_LEN = 32;

/** Status codes. Mirrors `CT_OK` and the `CT_ERR_*` family. */
export const CT_OK = 0;
export const CT_ERR_NO_SESSION = -1;
export const CT_ERR_WRITER = -2;
export const CT_ERR_BAD_UTF8 = -3;
export const CT_ERR_BAD_LENGTH = -4;
export const CT_ERR_NULL = -5;
export const CT_ERR_RESERVED_NOT_ZERO = -6;
export const CT_ERR_ALREADY_OPEN = -7;

/** `ct_writer_kind()` values. `1` is DD-7's Path A, the pure-Rust `CtfsTraceWriter`. */
export const WRITER_KIND_PATH_A_PURE_RUST = 1;

/** One AVM execution step: upstream's `ExecutionStep`, unchanged. M15 chose this shape. */
export interface StepEvent {
  readonly contextId: number;
  readonly pc: number;
  readonly opcode: number;
  readonly l2Gas: bigint;
  readonly daGas: bigint;
  /** Exactly 32 bytes. A shorter address is a caller error and is refused, not zero-padded. */
  readonly contractAddress: Uint8Array;
}

/** The module's exports. Every one of these is asserted present by `CtWriter.open`. */
export interface CtWriterExports {
  readonly memory: WebAssembly.Memory;
  ct_alloc(len: number): number;
  ct_free(ptr: number, len: number): void;
  ct_record_size(): number;
  ct_writer_kind(): number;
  ct_writer_open(
    programPtr: number,
    programLen: number,
    recordingIdPtr: number,
    recordingIdLen: number,
    sourcePtr: number,
    sourceLen: number,
    workdirPtr: number,
    workdirLen: number,
    wantColumns: number,
  ): number;
  ct_step(
    contextId: number,
    pc: number,
    opcode: number,
    l2Gas: bigint,
    daGas: bigint,
    addressPtr: number,
  ): number;
  ct_ingest(ptr: number, len: number): number;
  ct_ingest_control(ptr: number, len: number): number;
  ct_nop_step(
    contextId: number,
    pc: number,
    opcode: number,
    l2Gas: bigint,
    daGas: bigint,
    addressPtr: number,
  ): number;
  ct_nop_ingest(ptr: number, len: number): number;
  ct_nop_calls(): bigint;
  ct_nop_checksum(): bigint;
  ct_writer_close(): number;
  ct_container_len(): number;
  ct_events_written(): bigint;
  ct_columns_requested(): number;
  ct_dropped_column_awareness(): number;
  ct_last_error_ptr(): number;
  ct_last_error_len(): number;
}

/** Every export name the host requires, so a missing one is one named failure and not a `TypeError`. */
export const REQUIRED_EXPORTS: readonly string[] = [
  'ct_alloc',
  'ct_free',
  'ct_record_size',
  'ct_writer_kind',
  'ct_writer_open',
  'ct_step',
  'ct_ingest',
  'ct_ingest_control',
  'ct_nop_step',
  'ct_nop_ingest',
  'ct_nop_calls',
  'ct_nop_checksum',
  'ct_writer_close',
  'ct_container_len',
  'ct_events_written',
  'ct_columns_requested',
  'ct_dropped_column_awareness',
  'ct_last_error_ptr',
  'ct_last_error_len',
];

/**
 * Write one event into `view` at `offset`.
 *
 * The reserved word is written as an explicit zero rather than left alone, because the buffer is
 * REUSED across batches — that is the whole point of the batched arm — and a stale non-zero word
 * from a previous batch would be refused by the module with `CT_ERR_RESERVED_NOT_ZERO`, which is
 * a confusing failure a long way from its cause.
 */
export function encodeStep(view: DataView, bytes: Uint8Array, offset: number, e: StepEvent): void {
  if (e.contractAddress.length !== ADDRESS_LEN) {
    throw new RangeError(
      `contractAddress must be exactly ${ADDRESS_LEN} bytes, got ${e.contractAddress.length}`,
    );
  }
  view.setUint32(offset + OFF_CONTEXT_ID, e.contextId, true);
  view.setUint32(offset + OFF_PC, e.pc, true);
  view.setUint32(offset + OFF_OPCODE, e.opcode, true);
  view.setUint32(offset + OFF_RESERVED, 0, true);
  view.setBigUint64(offset + OFF_L2_GAS, e.l2Gas, true);
  view.setBigUint64(offset + OFF_DA_GAS, e.daGas, true);
  bytes.set(e.contractAddress, offset + OFF_ADDRESS);
}

/** Read a record back out. Used by the checks, so the encoder has an inverse to be tested against. */
export function decodeStep(view: DataView, bytes: Uint8Array, offset: number): StepEvent {
  return {
    contextId: view.getUint32(offset + OFF_CONTEXT_ID, true),
    pc: view.getUint32(offset + OFF_PC, true),
    opcode: view.getUint32(offset + OFF_OPCODE, true),
    l2Gas: view.getBigUint64(offset + OFF_L2_GAS, true),
    daGas: view.getBigUint64(offset + OFF_DA_GAS, true),
    contractAddress: bytes.slice(offset + OFF_ADDRESS, offset + OFF_ADDRESS + ADDRESS_LEN),
  };
}

/** A status code turned into the sentence it stands for. Unknown codes say so rather than guess. */
export function statusText(status: number): string {
  switch (status) {
    case CT_OK:
      return 'ok';
    case CT_ERR_NO_SESSION:
      return 'no writer is open';
    case CT_ERR_WRITER:
      return 'the writer refused';
    case CT_ERR_BAD_UTF8:
      return 'a string argument is not valid UTF-8';
    case CT_ERR_BAD_LENGTH:
      return 'the buffer length is not a whole number of records';
    case CT_ERR_NULL:
      return 'a required pointer was null';
    case CT_ERR_RESERVED_NOT_ZERO:
      return "a record's reserved word is not zero";
    case CT_ERR_ALREADY_OPEN:
      return 'a writer is already open';
    default:
      return `unrecognised status ${status}`;
  }
}
