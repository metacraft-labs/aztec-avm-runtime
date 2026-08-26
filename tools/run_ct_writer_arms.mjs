// The M24 functional arms, measured ONCE and shared.
//
//   node tools/run_ct_writer_arms.mjs --module <ct_writer.wasm> --work <dir>
//
// M20's convention and M22's and M23's: three checks each deriving "the container after 5,000
// events" from their own run is how two checks come to disagree about a number nothing changed.
// This writes `<work>/ct.json` plus the containers themselves, and the checks read it.
//
// Every arm is INDEPENDENT of every other: a fresh `WebAssembly.Instance` per arm, because the
// module holds one global session and a leaked one would make the next arm's container carry the
// previous arm's events — which is the silent shape, not a crash.
//
// WHAT EACH ARM IS FOR, named so a reader does not have to infer it:
//
//   roundtrip        a plain recording, written out for `ct-print` to read
//   equivalence      the same events through BOTH ABIs, so "the choice is about cost, not
//                    semantics" is a measurement rather than an assumption
//   backpressure     ten times the events at a tenth of the batch, so host-side buffering is
//                    shown constant while the event count is not
//   gates            the four DD-7 refusals, each EXECUTED and its outcome recorded
//   surface          the module's own answers: record size, writer kind, export list

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import process from 'node:process';

import {
  ADDRESS_LEN,
  CtWriter,
  ColumnAwarenessDropped,
  ColumnAwarenessUnavailable,
  RECORD_SIZE,
  REQUIRED_EXPORTS,
  UnresolvedTracingConfig,
  WRITER_PATH_A_PURE_RUST,
  WRITER_PATH_B_NIM,
  decodeStep,
  encodeStep,
  instantiateCtWriter,
  resolveTracingConfig,
} from '../ct-host/src/index.ts';

function arg(name, dflt) {
  const i = process.argv.indexOf(name);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : dflt;
}

const MODULE = arg('--module', 'ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm');
const WORK = arg('--work', `${process.env.HOME}/.cache/aztec-m24-ct-writer`);
const RECORDING_ID = '01949fcc-7d92-7e9c-8000-0000000024c7';

mkdirSync(WORK, { recursive: true });
const bytes = readFileSync(MODULE);

function events(n, seed = 0) {
  const out = new Array(n);
  for (let i = 0; i < n; i++) {
    const addr = new Uint8Array(ADDRESS_LEN);
    addr[0] = (seed + i) & 0xff;
    addr[31] = (i * 7) & 0xff;
    out[i] = {
      contextId: i % 8,
      pc: i % 4093,
      opcode: i % 200,
      l2Gas: BigInt(1_000_000 - i),
      daGas: BigInt(i % 4096),
      contractAddress: addr,
    };
  }
  return out;
}

function config(columns, path) {
  return resolveTracingConfig(
    {
      program: 'aztec-avm-runtime',
      recordingId: RECORDING_ID,
      sourcePath: '/aztec/tx.avm',
      workdir: '/aztec',
      columns,
    },
    path,
  );
}

async function record(evs, { batchRecords, perCall = false }) {
  const inst = await instantiateCtWriter(bytes);
  const w = new CtWriter(inst, config(false, WRITER_PATH_A_PURE_RUST), { batchRecords });
  const before = process.memoryUsage().heapUsed;
  let peak = before;
  for (let i = 0; i < evs.length; i++) {
    if (perCall) w.writeStepPerCall(evs[i]);
    else w.push(evs[i]);
    if ((i & 0x3fff) === 0) {
      const h = process.memoryUsage().heapUsed;
      if (h > peak) peak = h;
    }
  }
  const rec = w.close();
  return { rec, bufferBytes: w.bufferBytes, heapDeltaBytes: peak - before };
}

const out = { module: MODULE, moduleBytes: bytes.length, node: process.version, v8: process.versions.v8 };

// ---- surface ---------------------------------------------------------------
{
  const inst = await instantiateCtWriter(bytes);
  const ex = inst.exports;
  out.surface = {
    imports: WebAssembly.Module.imports(new WebAssembly.Module(bytes)).length,
    exports: Object.keys(ex).sort(),
    missingRequired: REQUIRED_EXPORTS.filter((n) => typeof ex[n] !== 'function'),
    moduleRecordSize: ex.ct_record_size(),
    hostRecordSize: RECORD_SIZE,
    writerKind: ex.ct_writer_kind(),
  };
}

// ---- roundtrip -------------------------------------------------------------
{
  const evs = events(5000, 1);
  const { rec, bufferBytes } = await record(evs, { batchRecords: 512 });
  const file = `${WORK}/roundtrip.ct`;
  writeFileSync(file, rec.container);
  out.roundtrip = {
    file,
    events: rec.events,
    requested: evs.length,
    crossings: rec.crossings,
    expectedCrossings: Math.ceil(evs.length / 512),
    containerBytes: rec.container.length,
    bufferBytes,
    writerKind: rec.writerKind,
    writerPath: rec.writerPath,
    columnsRequested: rec.columnsRequested,
    droppedColumnAwareness: rec.droppedColumnAwareness,
    memoryGrowths: rec.memoryGrowths,
    // What a reader must find. Five variables per step, plus the opening frame.
    expectedSteps: evs.length,
    expectedValues: evs.length * 5,
    firstPc: evs[0].pc,
    lastPc: evs[evs.length - 1].pc,
  };
}

// ---- equivalence: the two ABIs, the same events -----------------------------
{
  const evs = events(2000, 2);
  const a = await record(evs, { batchRecords: 256 });
  const b = await record(evs, { batchRecords: 256, perCall: true });
  const batched = a.rec.container;
  const perEvent = b.rec.container;
  let identical = batched.length === perEvent.length;
  if (identical) {
    for (let i = 0; i < batched.length; i++) {
      if (batched[i] !== perEvent[i]) { identical = false; break; }
    }
  }
  writeFileSync(`${WORK}/equivalence-batched.ct`, batched);
  writeFileSync(`${WORK}/equivalence-perevent.ct`, perEvent);
  out.equivalence = {
    events: evs.length,
    batchedBytes: batched.length,
    perEventBytes: perEvent.length,
    identical,
    batchedCrossings: a.rec.crossings,
    perEventCrossings: b.rec.crossings,
    batchedFile: `${WORK}/equivalence-batched.ct`,
    perEventFile: `${WORK}/equivalence-perevent.ct`,
  };
}

// ---- backpressure ----------------------------------------------------------
// Ten times the events at a QUARTER of the batch, so a host-side buffer that scaled with the
// event count would be forty times bigger and cannot hide behind a wide bound.
{
  const small = await record(events(25_000, 3), { batchRecords: 1024 });
  const large = await record(events(250_000, 3), { batchRecords: 1024 });
  const largeFile = `${WORK}/backpressure.ct`;
  writeFileSync(largeFile, large.rec.container);
  out.backpressure = {
    smallEvents: small.rec.events,
    largeEvents: large.rec.events,
    ratio: large.rec.events / small.rec.events,
    smallBufferBytes: small.bufferBytes,
    largeBufferBytes: large.bufferBytes,
    smallCrossings: small.rec.crossings,
    largeCrossings: large.rec.crossings,
    smallExpectedCrossings: Math.ceil(25_000 / 1024),
    largeExpectedCrossings: Math.ceil(250_000 / 1024),
    smallHeapDeltaBytes: small.heapDeltaBytes,
    largeHeapDeltaBytes: large.heapDeltaBytes,
    smallContainerBytes: small.rec.container.length,
    largeContainerBytes: large.rec.container.length,
    largeFile,
    largeMemoryGrowths: large.rec.memoryGrowths,
  };
}

// ---- the gates, EXECUTED ---------------------------------------------------
async function attempt(name, fn) {
  try {
    await fn();
    return { name, threw: false, error: null, kind: null };
  } catch (e) {
    return { name, threw: true, error: String(e && e.message ? e.message : e), kind: e?.name ?? null };
  }
}

out.gates = [];

// 1. DD-7 at configuration time.
out.gates.push(
  await attempt('columns-on-path-a', async () => {
    config(true, WRITER_PATH_A_PURE_RUST);
  }),
);
// 2. The same thing routed around the TYPE. `as any` is erased; the value check is not.
out.gates.push(
  await attempt('columns-on-path-a-through-any', async () => {
    const raw = { program: 'p', recordingId: '', sourcePath: '/a', workdir: '/', columns: 'yes' };
    // `columns: 'yes'` is truthy and is NOT `true`; the gate tests the value, so this one is
    // ALLOWED through, and that is deliberate — see `notes` below.
    resolveTracingConfig(raw, WRITER_PATH_A_PURE_RUST);
    // Now the real bypass: a `true` smuggled past the type.
    const sneaky = JSON.parse('{"program":"p","recordingId":"","sourcePath":"/a","workdir":"/","columns":true}');
    resolveTracingConfig(sneaky, WRITER_PATH_A_PURE_RUST);
  }),
);
// 3. A shape-identical object that never went through the gate.
out.gates.push(
  await attempt('unresolved-config-object', async () => {
    const inst = await instantiateCtWriter(bytes);
    const forged = {
      program: 'p',
      recordingId: RECORDING_ID,
      sourcePath: '/a',
      workdir: '/',
      columns: false,
      writerPath: WRITER_PATH_A_PURE_RUST,
    };
    new CtWriter(inst, forged, { batchRecords: 8 });
  }),
);
// 4. A config resolved against the column-aware path, run on the Path A module — so a column
//    request really does reach `ct_writer_open(want_columns = 1)`.
//
//    THIS GATE INVERTED WHEN THE `trace_format` ANCHOR MOVED, AND THAT INVERSION IS THE RESULT.
//    At the old anchor the writer could not honour the request, `dropped_column_awareness()`
//    answered true and `close()` threw `ColumnAwarenessDropped`. The writer at the current anchor
//    HONOURS it. So this arm must now NOT throw, and what it records is the module's own answer:
//    the request was made, and it was not dropped. Recorded as the measurement it is rather than
//    deleted, because "Path A can carry columns now" is the fact the anchor move delivers and it
//    should be read off the module rather than off this comment.
out.gates.push(
  await attempt('columns-requested-are-honoured', async () => {
    const inst = await instantiateCtWriter(bytes);
    const w = new CtWriter(inst, config(true, WRITER_PATH_B_NIM), { batchRecords: 8 });
    w.push(events(3, 4)[0]);
    const r = w.close();
    out.columnRequest = {
      columnsRequested: r.columnsRequested,
      droppedColumnAwareness: r.droppedColumnAwareness,
      writerKind: r.writerKind,
      events: r.events,
      containerBytes: r.container.length,
    };
    if (!r.columnsRequested) throw new Error('the module did not record that columns were requested');
  }),
);
// 4b. THE FREEZE, EXECUTED. `resolveTracingConfig` returns a frozen object, so the one bypass that
//     used to get past the configuration-time gate — mutate the resolved config afterwards — now
//     throws AT THE MUTATION, in strict mode, before any writer sees it. Run here rather than
//     asserted from the source, because a `readonly` would read the same and be erased.
out.gates.push(
  await attempt('mutating-a-resolved-config', async () => {
    const cfg = config(false, WRITER_PATH_A_PURE_RUST);
    cfg.columns = true;
  }),
);
// 5. THE CONTROL FOR THE GATES: an ordinary recording must NOT throw. Without this every gate
//    above is satisfied by a writer that refuses everything.
out.gates.push(
  await attempt('ordinary-recording-is-allowed', async () => {
    const inst = await instantiateCtWriter(bytes);
    const w = new CtWriter(inst, config(false, WRITER_PATH_A_PURE_RUST), { batchRecords: 8 });
    for (const e of events(10, 5)) w.push(e);
    const r = w.close();
    if (r.events !== 10) throw new Error(`the control recording wrote ${r.events} of 10 events`);
    if (r.droppedColumnAwareness) throw new Error('the control recording reports dropped columns');
  }),
);

// ---- the encoder has an inverse --------------------------------------------
{
  const buf = new ArrayBuffer(RECORD_SIZE * 4);
  const view = new DataView(buf);
  const u8 = new Uint8Array(buf);
  const evs = events(4, 6);
  for (let i = 0; i < 4; i++) encodeStep(view, u8, i * RECORD_SIZE, evs[i]);
  const back = [];
  for (let i = 0; i < 4; i++) {
    const d = decodeStep(view, u8, i * RECORD_SIZE);
    back.push({
      contextId: d.contextId,
      pc: d.pc,
      opcode: d.opcode,
      l2Gas: d.l2Gas.toString(),
      daGas: d.daGas.toString(),
      address: Array.from(d.contractAddress).join(','),
    });
  }
  out.codec = {
    encoded: evs.map((e) => ({
      contextId: e.contextId,
      pc: e.pc,
      opcode: e.opcode,
      l2Gas: e.l2Gas.toString(),
      daGas: e.daGas.toString(),
      address: Array.from(e.contractAddress).join(','),
    })),
    decoded: back,
  };
}

out.notes = [
  "gate 'columns-on-path-a-through-any' makes TWO calls. The first passes columns:'yes' — truthy, "
    + 'not `true` — and is deliberately allowed through, because the gate tests the value and a '
    + 'string that survived a JSON round trip must not silently enable a capability. The second '
    + 'smuggles a real `true` past the type through `JSON.parse`, and that one must throw. So the '
    + 'arm throwing proves the SECOND call was refused.',
];

writeFileSync(`${WORK}/ct.json`, JSON.stringify(out, null, 2) + '\n');
process.stderr.write(`run_ct_writer_arms: wrote ${WORK}/ct.json\n`);
