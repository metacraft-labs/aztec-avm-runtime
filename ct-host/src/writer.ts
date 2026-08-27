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
  ALL_REQUIRED_EXPORTS,
  CT_OK,
  POSITION_SIZE,
  RECORD_SIZE,
  RUNG_SOURCE,
  decodePosition,
  decodeStep,
  encodePosition,
  encodeStep,
  statusText,
  type CtWriterExports,
  type MappingRung,
  type StepEvent,
  type StepPosition,
} from './abi.ts';
import {
  ColumnAwarenessDropped,
  MappingRungDegraded,
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
  /** The rung this recording's configuration declared. */
  readonly mappingRung: MappingRung;
  /** Contracts a rung was declared for, read off the module before it closed. */
  readonly rungsDeclared: number;
  /** Steps recorded at a resolved source position. */
  readonly stepsPositioned: number;
  /** Steps recorded as `Line(pc)` because no position was available. */
  readonly stepsUnpositioned: number;
  /** Rung-1 contracts that produced an unpositioned step. Non-zero throws before you see this. */
  readonly rungViolations: number;
  /** Source paths interned through `ct_intern_path`. */
  readonly pathsInterned: number;
  /** `TraceLogEvent`s written through `ct_log_event`, read off the module before it closed. */
  readonly logEvents: number;
  /** Frames opened through `ct_call`, read off the module before it closed. */
  readonly callsOpened: number;
  /** Frames still open at close. Non-zero is legitimate — an entry frame need not return. */
  readonly callDepthAtClose: number;
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
  /** The position side channel's own staging buffer, sized to match the step batch. */
  private readonly posPtr: number;
  private posFilled = 0;
  private pathsInterned = 0;
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
    // The UNION, not M24's nineteen alone — see `SOURCE_MAPPING_EXPORTS` in abi.ts for why the
    // two lists are separate and why the host must still require both.
    for (const name of ALL_REQUIRED_EXPORTS) {
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
    // The same discipline for the position side channel. A 16-versus-20 disagreement here would
    // shift every field of every position by four bytes and produce a container whose steps point
    // at plausible wrong lines — which is worse than a container that fails to open.
    const modulePositionSize = ex.ct_position_size();
    if (modulePositionSize !== POSITION_SIZE) {
      throw new Error(
        `position size disagreement: the module says ${modulePositionSize}, this host encodes ${POSITION_SIZE}`,
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
    this.posPtr = ex.ct_alloc(this.batchRecords * POSITION_SIZE);
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
  push(e: StepEvent, position?: StepPosition): void {
    this.assertOpen();
    this.refresh();
    encodeStep(this.view, this.bytes, this.bufPtr + this.filled * RECORD_SIZE, e);
    // THE POSITION IS STAGED IN LOCKSTEP WITH THE STEP, NOT SUPPLIED SEPARATELY.
    //
    // The module pairs the two FIFOs by ORDER, so a host that stages a position for some steps
    // and not others must still occupy the slot for the ones it skips — otherwise step N+1 takes
    // step N's position and every later step in the batch is mis-attributed to a real-looking
    // wrong line. Rather than ask callers to remember that, `push` writes a `line: 0` record for
    // an absent position and only starts the side channel once a real one has appeared, so a
    // caller that never passes a position pays nothing and a caller that passes some cannot
    // desynchronise. `posFilled` and `filled` are asserted equal at every flush.
    if (position !== undefined || this.posFilled > 0) {
      while (this.posFilled < this.filled) {
        encodePosition(this.view, this.posPtr + this.posFilled * POSITION_SIZE, {
          pathId: 0,
          line: 0,
          column: 0,
        });
        this.posFilled += 1;
      }
      encodePosition(
        this.view,
        this.posPtr + this.posFilled * POSITION_SIZE,
        position ?? { pathId: 0, line: 0, column: 0 },
      );
      this.posFilled += 1;
    }
    this.filled += 1;
    if (this.filled === this.batchRecords) this.flush();
  }

  /** Hand whatever is buffered to the module. One crossing; a no-op when nothing is pending. */
  flush(): void {
    this.assertOpen();
    if (this.filled === 0) return;
    // POSITIONS FIRST, AND ONLY EVER AS MANY AS THERE ARE STEPS. The module consumes one per step
    // as `ct_ingest` decodes the batch, so handing them over afterwards would leave the whole
    // batch unpositioned and the next one shifted.
    if (this.posFilled > 0) {
      while (this.posFilled < this.filled) {
        encodePosition(this.view, this.posPtr + this.posFilled * POSITION_SIZE, {
          pathId: 0,
          line: 0,
          column: 0,
        });
        this.posFilled += 1;
      }
      if (this.posFilled !== this.filled) {
        throw new Error(
          `position/step desynchronisation: ${this.posFilled} position(s) staged for ${this.filled} step(s)`,
        );
      }
      const pn = this.ex.ct_positions(this.posPtr, this.posFilled * POSITION_SIZE);
      this.crossings += 1;
      if (pn < 0) throw new CtWriterError('ct_positions', pn, this.lastError());
      if (pn !== this.posFilled) {
        throw new Error(`ct_positions accepted ${pn} of ${this.posFilled} records`);
      }
      this.posFilled = 0;
    }
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
   * Intern a source path and return the id a {@link StepPosition} must quote.
   *
   * `lineLengths[i]` is the number of addressable columns on line `i + 1`. The column-aware step
   * encoder builds its `(line, column)` address space from these tables, so a column supplied for
   * a path interned without one has nowhere to land. Passing them is therefore not optional in
   * practice at rung 1, and it is accepted and ignored on a line-only recording — which is
   * upstream's own contract for `register_path_with_line_lengths`.
   */
  internPath(path: string, lineLengths: readonly number[] = []): number {
    this.assertOpen();
    const enc = new TextEncoder().encode(path);
    const pathPtr = this.ex.ct_alloc(enc.length || 1);
    const llPtr = lineLengths.length > 0 ? this.ex.ct_alloc(lineLengths.length * 4) : 0;
    this.refresh();
    this.bytes.set(enc, pathPtr);
    for (let i = 0; i < lineLengths.length; i++) {
      this.view.setUint32(llPtr + i * 4, lineLengths[i]!, true);
    }
    const id = this.ex.ct_intern_path(pathPtr, enc.length, llPtr, lineLengths.length);
    this.ex.ct_free(pathPtr, enc.length || 1);
    if (llPtr !== 0) this.ex.ct_free(llPtr, lineLengths.length * 4);
    if (id < 0) throw new CtWriterError('ct_intern_path', id, this.lastError());
    if (id >= this.pathsInterned) this.pathsInterned = id + 1;
    return id;
  }

  /**
   * Declare the rung this recording achieved for one contract, with the reason it achieved it.
   *
   * Written into the trace as a `TraceLogEvent`, so the rung is a property of the container. The
   * reason is not decoration: a rung-3 contract with the reason "no artifact was supplied" and a
   * rung-3 contract with the reason "the artifact carries no debug symbols" are different facts
   * about the deployment, and a reader that has only the number cannot tell them apart.
   */
  declareRung(contractAddress: Uint8Array, rung: MappingRung, reason: string): void {
    this.assertOpen();
    if (contractAddress.length !== ADDRESS_LEN) {
      throw new RangeError(`contractAddress must be exactly ${ADDRESS_LEN} bytes`);
    }
    const enc = new TextEncoder().encode(reason);
    const reasonPtr = this.ex.ct_alloc(enc.length || 1);
    this.refresh();
    this.bytes.set(contractAddress, this.addrPtr);
    this.bytes.set(enc, reasonPtr);
    const status = this.ex.ct_declare_rung(this.addrPtr, rung, reasonPtr, enc.length);
    this.ex.ct_free(reasonPtr, enc.length || 1);
    if (status !== CT_OK) throw new CtWriterError('ct_declare_rung', status, this.lastError());
  }

  /**
   * Write one `TraceLogEvent` with an arbitrary metadata key. M26's join record goes through here.
   *
   * The key is not validated against a list, for the module's reason: a host that policed keys
   * would make every new record kind a change to this file as well as to its producer. What IS
   * refused is an empty key, by the module, because a `TraceLogEvent` nobody can grep for is not
   * findable by the only mechanism a reader has.
   */
  logEvent(metadata: string, content: string): void {
    this.assertOpen();
    const enc = new TextEncoder();
    const m = enc.encode(metadata);
    const c = enc.encode(content);
    const mPtr = this.ex.ct_alloc(m.length || 1);
    const cPtr = this.ex.ct_alloc(c.length || 1);
    this.refresh();
    this.bytes.set(m, mPtr);
    this.bytes.set(c, cPtr);
    const status = this.ex.ct_log_event(mPtr, m.length, cPtr, c.length);
    this.ex.ct_free(mPtr, m.length || 1);
    this.ex.ct_free(cPtr, c.length || 1);
    if (status !== CT_OK) throw new CtWriterError('ct_log_event', status, this.lastError());
  }

  /** `TraceLogEvent`s this session wrote through {@link logEvent}. The MODULE's count, not ours. */
  get logEventsWritten(): number {
    return this.ex.ct_log_event_count();
  }

  /**
   * Open a frame. M26's frame ABI.
   *
   * `pathId` comes from {@link internPath}; omitting it puts the frame on the session's own source
   * path, which is what a recording that interned nothing has. `contractAddress` is optional and
   * becomes the frame's ONE argument, rendered as OQ-4's hex `String` — which is what makes a
   * public frame attributable to a contract without reading the steps inside it.
   *
   * **THE BUFFER IS FLUSHED FIRST, AND THAT IS NOT AN OPTIMISATION.** Steps are staged host-side
   * and cross the boundary in batches; a `ct_call` that crossed before the pending steps did would
   * put the caller's last steps INSIDE the callee's frame. The flush makes the frame boundary land
   * where the caller put it.
   */
  call(name: string, opts: { pathId?: number; line?: number; contractAddress?: Uint8Array } = {}): void {
    this.assertOpen();
    this.flush();
    const enc = new TextEncoder().encode(name);
    const namePtr = this.ex.ct_alloc(enc.length || 1);
    const addrGiven = opts.contractAddress !== undefined;
    if (addrGiven && opts.contractAddress!.length !== ADDRESS_LEN) {
      throw new RangeError(`contractAddress must be exactly ${ADDRESS_LEN} bytes`);
    }
    this.refresh();
    this.bytes.set(enc, namePtr);
    if (addrGiven) this.bytes.set(opts.contractAddress!, this.addrPtr);
    const status = this.ex.ct_call(
      namePtr,
      enc.length,
      opts.pathId ?? 0xffffffff,
      opts.line ?? 1,
      addrGiven ? this.addrPtr : 0,
    );
    this.ex.ct_free(namePtr, enc.length || 1);
    if (status !== CT_OK) throw new CtWriterError('ct_call', status, this.lastError());
  }

  /** Close the innermost open frame. Flushes first, for {@link call}'s reason. */
  returnFrame(): void {
    this.assertOpen();
    this.flush();
    const status = this.ex.ct_return();
    if (status !== CT_OK) throw new CtWriterError('ct_return', status, this.lastError());
  }

  /** Frames currently open. The MODULE's count, so a host cannot assert its own arithmetic. */
  get callDepth(): number {
    return this.ex.ct_call_depth();
  }

  /** Frames opened over the session. Does not go down, so "no frames" and "all closed" differ. */
  get callsOpened(): number {
    return this.ex.ct_calls_opened();
  }

  /** Contracts a rung has been declared for. Read from the module, not counted here. */
  get rungsDeclared(): number {
    return this.ex.ct_rung_count();
  }

  /** Positions handed over and not yet consumed by a step. Zero except mid-batch. */
  get positionsPending(): number {
    return this.ex.ct_positions_pending();
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
   *
   * **AND IT NO LONGER CATCHES ANYTHING AT THE CURRENT `trace_format` ANCHOR.** The writer there
   * honours a column request, so `ct_dropped_column_awareness()` answers 0 whether or not columns
   * were asked for. The bypass this used to catch — a resolved configuration mutated after the
   * gate ran — is refused at configuration time now, because `resolveTracingConfig` freezes what
   * it returns. The read stays: the signal is the module's own, a future writer path can still
   * report a loss, and reporting it on every recording is what makes it available to a consumer
   * at all. What must not happen is anything being left to rest on it, which is why the freeze
   * is where the guarantee is and this is where the corroboration is.
   */
  close(): CtRecording {
    this.assertOpen();
    this.flush();
    const events = Number(this.ex.ct_events_written());
    const rungsDeclared = this.ex.ct_rung_count();
    const logEvents = this.ex.ct_log_event_count();
    const callsOpened = this.ex.ct_calls_opened();
    const callDepthAtClose = this.ex.ct_call_depth();
    const positionsLeft = this.ex.ct_positions_pending();
    if (positionsLeft !== 0) {
      // More positions than steps. Not a degradation — a desynchronisation, and the steps that
      // DID run took the right positions, so nothing in the container is wrong yet. It is refused
      // anyway, because the only way to get here is a host bug and the next recording would be
      // wrong from its first step.
      throw new Error(
        `${positionsLeft} source position(s) were supplied that no step consumed. The host staged `
          + 'more positions than steps, so the pairing this side channel rests on has already '
          + 'broken; refusing rather than closing a container whose provenance is unclear.',
      );
    }
    const ptr = this.ex.ct_writer_close();
    if (ptr === 0) throw new CtWriterError('ct_writer_close', -2, this.lastError());
    this.refresh();
    const len = this.ex.ct_container_len();
    const container = this.bytes.slice(ptr, ptr + len);
    const writerKind = this.ex.ct_writer_kind();
    const columnsRequested = this.ex.ct_columns_requested() === 1;
    const dropped = this.ex.ct_dropped_column_awareness() === 1;
    const rungViolations = this.ex.ct_rung_violations();
    const violationPc = this.ex.ct_rung_violation_pc();
    const stepsPositioned = Number(this.ex.ct_steps_positioned());
    const stepsUnpositioned = Number(this.ex.ct_steps_unpositioned());
    this.closed = true;
    if (columnsRequested && dropped) {
      throw new ColumnAwarenessDropped(this.config.writerPath, writerKind);
    }
    // THE "NEVER SILENTLY DEGRADES" ENFORCEMENT, AND IT IS A DIFFERENT GATE FROM THE ONE ABOVE.
    //
    // `ColumnAwarenessDropped` asks the WRITER whether it lost something. This asks the MODULE
    // whether the recording is what its own metadata says it is: a contract declared at rung 1
    // that produced a step with no source position. The two fail on different evidence, in
    // different places, and neither can stand in for the other — which is the shape M24's review
    // asked for when it found the first one had stopped being able to fire.
    if (rungViolations > 0) {
      throw new MappingRungDegraded(rungViolations, violationPc, stepsPositioned, stepsUnpositioned);
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
      mappingRung: this.config.mappingRung,
      rungsDeclared,
      stepsPositioned,
      stepsUnpositioned,
      rungViolations,
      pathsInterned: this.pathsInterned,
      logEvents,
      callsOpened,
      callDepthAtClose,
    };
  }
}

/** Whether the module's `ct_writer_kind()` matches the kind the configuration's path declares. */
export function writerKindMatchesPath(kind: number, path: WriterPath): boolean {
  return WRITER_KIND_OF[path] === kind;
}

export { decodePosition, decodeStep, encodePosition, encodeStep, RUNG_SOURCE };
