// The event sequence both writers are driven through, and the drive itself.
//
// ONE DRIVER, BOTH PATHS, AND BOTH HOSTS. M41's container-equivalence deliverable is "the same
// input through both writers, compared stream by stream". If each path had its own driver the
// comparison would be between two scripts as much as between two writers, and a difference could
// be either. This module is the only thing that drives either module, and it is imported unchanged
// by `verification/ct_writer_drive.mjs` (node) and by `tools/m41_browser_writer.mjs` (a real page
// over CDP) -- so the browser arm is not a second driver that might drift.
//
// IT IMPORTS NOTHING. Not `node:fs`, not `node:path`, nothing: a module that imported a node
// builtin could not be loaded by a page, and discovering that at the end of the browser work is
// how a "shared" driver becomes two.
//
// THE RECORDING ID IS FIXED and is not minted here. A driver that minted one would make two runs
// differ in a field neither writer chose, and `meta.dat`'s recording id is one of the streams the
// equivalence check compares. It also has to be supplied at all: Path B REFUSES an empty one,
// because its target has no CSPRNG and a writer left to mint its own would mint the same identity
// in every session.

const RECORD_SIZE = 64;
const POSITION_SIZE = 16;
const CT_OK = 0;

/** The fixed input. Small enough to reason about, wide enough to touch every stream. */
const PROGRAM = 'aztec-avm-runtime';
const RECORDING_ID = '01890a5d-ac96-774b-bcce-b302099a8057';
const SOURCE = '/aztec/contract.nr';
const WORKDIR = '/aztec';
const INTERNED_PATH = '/aztec/token.nr';
const LINE_LENGTHS = [0, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50];
const ADDRESS = new Uint8Array(32).fill(0);
ADDRESS[31] = 0x2a;


/**
 * The step positions this driver ASKS FOR, in the order it asks, with the position the container
 * is expected to carry beside each.
 *
 * Declared here rather than recomputed by a check, because a check that derived the expectation
 * from the same loop that produced the calls would be comparing the driver with itself.
 *
 * `column: 0` on the way in means "line only". A column-aware container records such a step at its
 * line's START, which is column 1 -- so the expectation says 1 and not 0. That is not a fudge: it
 * is the difference between "the host supplied no column" and "the step is at no column", and only
 * the first of those is a thing a host can say.
 */
export const EXPECTED_STEPS = [
  // The start step, which Path B emits and Path A does not. Both writers place it at the SOURCE
  // path's entry line; a check comparing per-step positions must therefore compare the tail.
  { path: SOURCE, line: 1, column: null, from: 'start' },
  { path: INTERNED_PATH, line: 2, column: 3, from: 'ct_ingest' },
  { path: INTERNED_PATH, line: 3, column: 4, from: 'ct_ingest' },
  { path: INTERNED_PATH, line: 4, column: 5, from: 'ct_ingest' },
  { path: INTERNED_PATH, line: 5, column: 1, from: 'ct_ingest (line only)' },
  { path: SOURCE, line: 200, column: null, from: 'ct_step, no position: the rung-3 fallback' },
  { path: INTERNED_PATH, line: 5, column: 9, from: 'ct_source_step' },
  { path: INTERNED_PATH, line: 6, column: 1, from: 'ct_source_step (line only)' },
];

/** Steps this driver causes to be WRITTEN, excluding any the writer emits on its own. */
export const DRIVEN_STEP_COUNT = 7;

/**
 * Drive one instantiated module. `x` is its exports object.
 *
 * Returns `{ report, container }`. Throws on any refusal, with the module's own error text, so a
 * caller never has to decide whether an empty container means "nothing happened" or "something
 * failed".
 */
export function driveWriter(x) {
  const mem = () => new Uint8Array(x.memory.buffer);
  const view = () => new DataView(x.memory.buffer);

  const enc = new TextEncoder();
  function push(s) {
    const b = enc.encode(s);
    const p = x.ct_alloc(b.length || 1);
    mem().set(b, p);
    return [p, b.length];
  }

  function lastError() {
    const p = x.ct_last_error_ptr();
    const n = x.ct_last_error_len();
    if (!p || !n) return '(the module set no error)';
    return new TextDecoder().decode(mem().slice(p, p + n));
  }

  function must(status, what) {
    if (status !== CT_OK) {
      console.error(`${what} failed with status ${status}: ${lastError()}`);
      throw new Error(msg);
    }
  }

  // -- the module's own answers about its layout, read from the module ---------------------------
  if (x.ct_record_size() !== RECORD_SIZE) {
    console.error(`ct_record_size() is ${x.ct_record_size()}, this driver encodes ${RECORD_SIZE}`);
    throw new Error(msg);
  }
  if (x.ct_position_size() !== POSITION_SIZE) {
    console.error(`ct_position_size() is ${x.ct_position_size()}, this driver encodes ${POSITION_SIZE}`);
    throw new Error(msg);
  }

  const [pProgram, nProgram] = push(PROGRAM);
  const [pRec, nRec] = push(RECORDING_ID);
  const [pSource, nSource] = push(SOURCE);
  const [pWork, nWork] = push(WORKDIR);
  must(
    x.ct_writer_open(pProgram, nProgram, pRec, nRec, pSource, nSource, pWork, nWork, 1),
    'ct_writer_open',
  );

  // -- an interned path with line lengths ---------------------------------------------------------
  const [pPath, nPath] = push(INTERNED_PATH);
  const pLens = x.ct_alloc(LINE_LENGTHS.length * 4);
  {
    const v = view();
    LINE_LENGTHS.forEach((l, i) => v.setUint32(pLens + i * 4, l, true));
  }
  const pathId = x.ct_intern_path(pPath, nPath, pLens, LINE_LENGTHS.length);
  if (pathId < 0) {
    console.error(`ct_intern_path failed with ${pathId}: ${lastError()}`);
    throw new Error(msg);
  }

  // -- a rung declaration -------------------------------------------------------------------------
  const pAddr = x.ct_alloc(32);
  mem().set(ADDRESS, pAddr);
  const [pReason, nReason] = push('the transpiler re-keys brillig_locations by AVM pc');
  must(x.ct_declare_rung(pAddr, 1, pReason, nReason), 'ct_declare_rung');

  // -- a join record ------------------------------------------------------------------------------
  const [pMeta, nMeta] = push('ct.join');
  const [pContent, nContent] = push('tx=0xfeed half=public');
  must(x.ct_log_event(pMeta, nMeta, pContent, nContent), 'ct_log_event');

  // -- a frame ------------------------------------------------------------------------------------
  const [pName, nName] = push('token::transfer');
  must(x.ct_call(pName, nName, pathId, 7, pAddr), 'ct_call');

  // -- four positioned steps through the batched arm ---------------------------------------------
  const STEPS = 4;
  const pPos = x.ct_alloc(STEPS * POSITION_SIZE);
  const pRecs = x.ct_alloc(STEPS * RECORD_SIZE);
  {
    const v = view();
    const m = mem();
    for (let i = 0; i < STEPS; i++) {
      const o = pPos + i * POSITION_SIZE;
      v.setUint32(o + 0, pathId, true);
      v.setUint32(o + 4, 2 + i, true);
      // The last one is deliberately line-only: `column === 0` is a distinct state from "no
      // position", and a driver that never produced it would leave that branch unexercised in both
      // writers and therefore uncompared.
      v.setUint32(o + 8, i === STEPS - 1 ? 0 : 3 + i, true);
      v.setUint32(o + 12, 0, true);

      const r = pRecs + i * RECORD_SIZE;
      v.setUint32(r + 0, 1, true);
      v.setUint32(r + 4, 100 + i, true);
      v.setUint32(r + 8, 0x10 + i, true);
      v.setUint32(r + 12, 0, true);
      v.setBigUint64(r + 16, BigInt(1000 - i * 7), true);
      v.setBigUint64(r + 24, BigInt(500 - i * 3), true);
      m.set(ADDRESS, r + 32);
    }
  }
  // `ct_positions` answers with the COUNT it staged, not with `CT_OK`. Asserting the count rather
  // than "not an error" is the stronger reading: a module that accepted the buffer and staged three
  // of its four records would pass a `>= 0` check and fail this one.
  const staged = x.ct_positions(pPos, STEPS * POSITION_SIZE);
  if (staged !== STEPS) {
    console.error(`ct_positions staged ${staged} of ${STEPS} records: ${lastError()}`);
    throw new Error(msg);
  }
  // `ct_ingest` answers with the count it wrote, for `ct_positions`' reason.
  const ingested = x.ct_ingest(pRecs, STEPS * RECORD_SIZE);
  if (ingested !== STEPS) {
    console.error(`ct_ingest wrote ${ingested} of ${STEPS} records: ${lastError()}`);
    throw new Error(msg);
  }

  // -- one step through the per-event arm, with NO position, so the fallback is exercised --------
  must(x.ct_step(1, 200, 0x20, 900n, 400n, pAddr), 'ct_step');

  // -- two source steps ---------------------------------------------------------------------------
  must(x.ct_source_step(pathId, 5, 9), 'ct_source_step');
  must(x.ct_source_step(pathId, 6, 0), 'ct_source_step (line only)');

  // -- close the frame and the writer -------------------------------------------------------------
  must(x.ct_return(), 'ct_return');

  const report = {
    writerKind: x.ct_writer_kind(),
    recordSize: x.ct_record_size(),
    positionSize: x.ct_position_size(),
    pathCount: x.ct_path_count(),
    rungCount: x.ct_rung_count(),
    logEvents: x.ct_log_event_count(),
    callsOpened: x.ct_calls_opened(),
    callDepth: x.ct_call_depth(),
    positionsPending: x.ct_positions_pending(),
    nopCalls: String(x.ct_nop_calls()),
    nopChecksum: String(x.ct_nop_checksum()),
    // READ BEFORE THE CLOSE, and that is not an ordering preference.
    //
    // `ct_events_written` and `ct_source_steps_written` answer FROM THE SESSION, and
    // `ct_writer_close` takes the session apart — so a report that read them afterwards would
    // record 0 for every run of every module. It did, and the number went unnoticed for exactly as
    // long as nothing compared it to anything: two arms both reporting 0 AGREE, so the equivalence
    // check's "the two containers agree on eventsWritten" passed while measuring nothing at all.
    // The counters that DO survive the close are the ones backed by module statics
    // (`ct_steps_positioned`, `ct_dropped_column_awareness`, the rung tallies), and those are read
    // after it, below, because they are only set there.
    eventsWritten: String(x.ct_events_written()),
    sourceStepsWritten: String(x.ct_source_steps_written()),
  };

  const ptr = x.ct_writer_close();
  if (!ptr) {
    console.error(`ct_writer_close returned null: ${lastError()}`);
    throw new Error(msg);
  }
  const len = x.ct_container_len();
  const container = mem().slice(ptr, ptr + len);

  report.containerBytes = len;
  report.stepsPositioned = String(x.ct_steps_positioned());
  report.stepsUnpositioned = String(x.ct_steps_unpositioned());
  report.columnsRequested = x.ct_columns_requested();
  report.droppedColumnAwareness = x.ct_dropped_column_awareness();
  report.rungViolations = x.ct_rung_violations();
  report.rungViolationPc = x.ct_rung_violation_pc();
  report.moduleExports = Object.keys(x).sort();

  // The two arms that exist only to be measured. Driven AFTER the close so they cannot contribute
  // to the container, which is what makes them a measurement of the crossing rather than of the
  // writer — and driven at all, so a module that stopped exporting them fails here.
  x.ct_nop_step(0, 0, 0, 0n, 0n, pAddr);
  x.ct_nop_ingest(pRecs, RECORD_SIZE);
  report.nopCallsAfter = String(x.ct_nop_calls());
  report.nopChecksumAfter = String(x.ct_nop_checksum());
  // `ct_ingest_control` is `ct_ingest`'s byte-for-byte duplicate under a second name. With no
  // session open it must refuse exactly as `ct_ingest` does; asserting the two AGREE is what makes
  // it a calibrated control rather than a second name for the same code nobody ever compared.
  report.ingestAfterClose = x.ct_ingest(pRecs, RECORD_SIZE);
  report.ingestControlAfterClose = x.ct_ingest_control(pRecs, RECORD_SIZE);
  // `ct_free` has no return value, so the only thing that can be asserted about it is that calling
  // it does not trap. Calling it is therefore the assertion.
  x.ct_free(pRecs, STEPS * RECORD_SIZE);
  report.freeReturned = true;

  return { report, container };
}
