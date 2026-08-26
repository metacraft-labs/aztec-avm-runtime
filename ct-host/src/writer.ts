// The host side of the event ABI.
//
// Both OQ-6 arms are here, because the decision is a measurement and a host that could only do
// the winning one could not re-measure. `push`/`flush` is the shipped path; `writeStepPerCall` is
// the rejected arm, kept and exercised, which is M15's convention for a decision made on numbers.
//
// ---------------------------------------------------------------------------
// THE ARRAYBUFFER DETACHES, AND THAT IS THE ONE THING A HOST OVER LINEAR MEMORY MUST GET RIGHT.
//
// `WebAssembly.Memory.grow` REPLACES `memory.buffer` with a new `ArrayBuffer` and DETACHES the
// old one. Every `DataView` and every `Uint8Array` over the old buffer becomes unusable — reads
// throw `TypeError: Cannot perform DataView.prototype.getUint32 on a detached ArrayBuffer`, which
// is at least loud, but a view cached across a growth and written through is the quiet half.
//
// The writer allocates as it goes, so growth happens DURING a recording and not at a convenient
// boundary. `refresh()` compares the current `memory.buffer` against the one the cached views
// were made over and remakes them when it has moved. `test_trace_writer_backpressure` drives
// enough events to force at least one growth and asserts the growth COUNT is non-zero, so this
// path is exercised rather than merely present.
// ---------------------------------------------------------------------------

import {
  ADDRESS_LEN,
  CT_OK,
  RECORD_SIZE,
  REQUIRED_EXPORTS,
  decodeStep,
  encodeStep,
  statusText,
  type CtWriterExports,
  type StepEvent,
} from './abi.ts';
import {
  ColumnAwarenessDropped,
  UnresolvedTracingConfig,
  WRITER_KIND_OF,
  isResolvedTracingConfig,
  type ResolvedTracingConfig,
  type WriterPath,
} from './config.ts';

/** Records per batch on the buffered path. 4,096 records is 256 KiB, which is M12's largest arm. */
export const DEFAULT_BATCH_RECORDS = 4096;

export interface CtWriterOptions {
  /** Records per batch. Bounds host-side buffering; see {@link CtWriter.bufferBytes}. */
  batchRecords?: number;
  /**
   * Which export the batched path calls. `ct_ingest` ships; `ct_ingest_control` is its
   * byte-for-byte duplicate and exists so a measurement can be shown to report no difference
   * where there is none.
   */
  ingestExport?: 'ct_ingest' | 'ct_ingest_control' | 'ct_nop_ingest';
  /** Which export the per-call path calls. `ct_nop_step` prices the crossing with no writer work. */
  stepExport?: 'ct_step' | 'ct_nop_step';
}

export interface CtRecording {
  /** The finished `.ct` container. A copy, so it survives the next `memory.grow`. */
  readonly container: Uint8Array;
  /** Events the module accepted. */
  readonly events: number;
  /** `ct_writer_kind()`, read from the module. DD-7: record which writer path produced this. */
  readonly writerKind: number;
  /** The writer path the configuration named. */
  readonly writerPath: WriterPath;
  /** Whether the configuration asked for columns. */
  readonly columnsRequested: boolean;
  /** The writer's own `dropped_column_awareness()` signal. */
  readonly droppedColumnAwareness: boolean;
  /** Calls made into the module for events. `1` per batch on the buffered path. */
  readonly crossings: number;
  /** Times `memory.grow` moved the buffer under us. */
  readonly memoryGrowths: number;
}

export class CtWriterError extends Error {
  readonly status: number;
  constructor(what: string, status: number, detail: string) {
    super(`${what}: ${statusText(status)}${detail ? ` — ${detail}` : ''}`);
    this.name = 'CtWriterError';
    this.status = status;
  }
}

/** Instantiate the module. No imports: `{}` is the whole import object, and that is DD-7's point. */
export async function instantiateCtWriter(bytes: Uint8Array): Promise<WebAssembly.Instance> {
  const { instance } = await WebAssembly.instantiate(bytes as BufferSource, {});
  return instance;
}

export class CtWriter {
  private readonly ex: CtWriterExports;
  private readonly config: ResolvedTracingConfig;
  private readonly batchRecords: number;
  private readonly ingestName: 'ct_ingest' | 'ct_ingest_control' | 'ct_nop_ingest';
  private readonly stepName: 'ct_step' | 'ct_nop_step';
  private readonly bufPtr: number;
  private readonly addrPtr: number;
  private view: DataView;
  private bytes: Uint8Array;
  private seenBuffer: ArrayBuffer;
  private filled = 0;
  private crossings = 0;
  private growths = 0;
  private closed = false;

  /**
   * @param instance an instantiated `ct_writer.wasm`
   * @param config **must** have come from `resolveTracingConfig`; see `config.ts` for why identity
   *   rather than shape is what is checked.
   */
  constructor(instance: WebAssembly.Instance, config: ResolvedTracingConfig, opts: CtWriterOptions = {}) {
    // THE GATE. Not a type, not a modifier: an object-identity test that runs.
    if (!isResolvedTracingConfig(config)) {
      throw new UnresolvedTracingConfig();
    }
    const ex = instance.exports as unknown as CtWriterExports;
    for (const name of REQUIRED_EXPORTS) {
      if (typeof (ex as unknown as Record<string, unknown>)[name] !== 'function') {
        throw new Error(`ct_writer.wasm does not export ${name}()`);
      }
    }
    if (!(ex.memory instanceof WebAssembly.Memory)) {
      throw new Error('ct_writer.wasm does not export its linear memory');
    }
    // The module's own record size, not this host's constant. A disagreement here is the
    // silently-misaligned-container failure and it is refused before a single byte is written.
    const moduleRecordSize = ex.ct_record_size();
    if (moduleRecordSize !== RECORD_SIZE) {
      throw new Error(
        `record size disagreement: the module says ${moduleRecordSize}, this host encodes ${RECORD_SIZE}`,
      );
    }
    this.ex = ex;
    this.config = config;
    this.batchRecords = opts.batchRecords ?? DEFAULT_BATCH_RECORDS;
    if (!Number.isInteger(this.batchRecords) || this.batchRecords < 1) {
      throw new RangeError(`batchRecords must be a positive integer, got ${String(this.batchRecords)}`);
    }
    this.ingestName = opts.ingestExport ?? 'ct_ingest';
    this.stepName = opts.stepExport ?? 'ct_step';

    this.bufPtr = ex.ct_alloc(this.batchRecords * RECORD_SIZE);
    this.addrPtr = ex.ct_alloc(ADDRESS_LEN);
    this.seenBuffer = ex.memory.buffer;
    this.view = new DataView(this.seenBuffer);
    this.bytes = new Uint8Array(this.seenBuffer);

    const enc = new TextEncoder();
    const strings = [config.program, config.recordingId, config.sourcePath, config.workdir].map((s) =>
      enc.encode(s),
    );
    const ptrs = strings.map((s) => {
      const p = ex.ct_alloc(s.length || 1);
      this.refresh();
      this.bytes.set(s, p);
      return p;
    });
    const status = ex.ct_writer_open(
      ptrs[0]!,
      strings[0]!.length,
      ptrs[1]!,
      strings[1]!.length,
      ptrs[2]!,
      strings[2]!.length,
      ptrs[3]!,
      strings[3]!.length,
      config.columns ? 1 : 0,
    );
    for (let i = 0; i < ptrs.length; i++) ex.ct_free(ptrs[i]!, strings[i]!.length || 1);
    if (status !== CT_OK) {
      throw new CtWriterError('ct_writer_open', status, this.lastError());
    }
  }

  /** Bytes of buffer this writer will ever hold. Constant, whatever the event count. */
  get bufferBytes(): number {
    return this.batchRecords * RECORD_SIZE;
  }

  /** Events waiting in the buffer. */
  get pending(): number {
    return this.filled;
  }

  private refresh(): void {
    const current = this.ex.memory.buffer;
    if (current !== this.seenBuffer) {
      this.seenBuffer = current;
      this.view = new DataView(current);
      this.bytes = new Uint8Array(current);
      this.growths += 1;
    }
  }

  private lastError(): string {
    this.refresh();
    const p = this.ex.ct_last_error_ptr();
    const n = this.ex.ct_last_error_len();
    if (n === 0) return '';
    return new TextDecoder().decode(this.bytes.subarray(p, p + n));
  }

  /**
   * ARM B, buffered. Append an event; cross the boundary only when the batch is full.
   *
   * Host-side buffering is bounded by `bufferBytes` and does not grow with the event count, which
   * is what `test_trace_writer_backpressure` asserts. The buffer lives in the module's linear
   * memory, so the events are written once — there is no host-side array that is then copied in.
   */
  push(e: StepEvent): void {
    this.assertOpen();
    this.refresh();
    encodeStep(this.view, this.bytes, this.bufPtr + this.filled * RECORD_SIZE, e);
    this.filled += 1;
    if (this.filled === this.batchRecords) this.flush();
  }

  /** Hand whatever is buffered to the module. One crossing; a no-op when nothing is pending. */
  flush(): void {
    this.assertOpen();
    if (this.filled === 0) return;
    const len = this.filled * RECORD_SIZE;
    const n = this.ex[this.ingestName](this.bufPtr, len);
    this.crossings += 1;
    if (n < 0) throw new CtWriterError(this.ingestName, n, this.lastError());
    if (n !== this.filled) {
      throw new Error(`${this.ingestName} accepted ${n} of ${this.filled} records`);
    }
    this.filled = 0;
  }

  /**
   * ARM A. One crossing per event, the shape OQ-6 measures the buffered path against.
   *
   * The 32-byte address is written into a scratch slot and passed by pointer, because 32 bytes do
   * not fit in a wasm value type. Arm B pays the identical write inside its record, so the arms
   * are not made unequal by it.
   */
  writeStepPerCall(e: StepEvent): void {
    this.assertOpen();
    this.refresh();
    if (e.contractAddress.length !== ADDRESS_LEN) {
      throw new RangeError(`contractAddress must be exactly ${ADDRESS_LEN} bytes`);
    }
    this.bytes.set(e.contractAddress, this.addrPtr);
    const status = this.ex[this.stepName](e.contextId, e.pc, e.opcode, e.l2Gas, e.daGas, this.addrPtr);
    this.crossings += 1;
    if (status !== CT_OK) throw new CtWriterError(this.stepName, status, this.lastError());
  }

  private assertOpen(): void {
    if (this.closed) throw new Error('this CtWriter is closed');
  }

  /**
   * Finish the container.
   *
   * DD-7's assertion lives here and is CONDITIONAL: `droppedColumnAwareness` is read on every
   * recording and reported on every recording, and it is only ever a FAILURE when the
   * configuration asked for columns. Asserting it unconditionally would fail every ordinary
   * recording, because the signal is false precisely because nobody asked.
   */
  close(): CtRecording {
    this.assertOpen();
    this.flush();
    const events = Number(this.ex.ct_events_written());
    const ptr = this.ex.ct_writer_close();
    if (ptr === 0) throw new CtWriterError('ct_writer_close', -2, this.lastError());
    this.refresh();
    const len = this.ex.ct_container_len();
    const container = this.bytes.slice(ptr, ptr + len);
    const writerKind = this.ex.ct_writer_kind();
    const columnsRequested = this.ex.ct_columns_requested() === 1;
    const dropped = this.ex.ct_dropped_column_awareness() === 1;
    this.closed = true;
    if (columnsRequested && dropped) {
      throw new ColumnAwarenessDropped(this.config.writerPath, writerKind);
    }
    return {
      container,
      events,
      writerKind,
      writerPath: this.config.writerPath,
      columnsRequested,
      droppedColumnAwareness: dropped,
      crossings: this.crossings,
      memoryGrowths: this.growths,
    };
  }
}

/** Whether the module's `ct_writer_kind()` matches the kind the configuration's path declares. */
export function writerKindMatchesPath(kind: number, path: WriterPath): boolean {
  return WRITER_KIND_OF[path] === kind;
}

export { decodeStep, encodeStep };
