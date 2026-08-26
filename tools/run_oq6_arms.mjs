// OQ-6: one crossing per event, or one crossing per batch?
//
//   node tools/run_oq6_arms.mjs --module <ct_writer.wasm> --out <arms.tsv> [options]
//   node tools/run_oq6_arms.mjs --module <...> --session <k>            (one session, to stdout)
//
// ---------------------------------------------------------------------------
// THE MEASUREMENT STANDARD THIS CAMPAIGN HOLDS ITSELF TO, AND WHY EACH PIECE IS HERE.
//
// 1. THE ARMS ARE INTERLEAVED, ABBA, NOT ALL-OF-A-THEN-ALL-OF-B.
//    `lib_m15_shapes.sh:370` records what happens otherwise: measured on this host, the first run
//    of a session read 6,630 us where the same binary's second read 9,384 — the ORDER effect was
//    larger than the quantity the comparison was for. Each arm therefore occupies one early slot
//    and one late slot per block, so the mean launch position is equal for both and the order
//    effect is balanced out rather than assigned to an arm.
//
// 2. THE SESSION IS THE UNIT OF REPLICATION, AND A SESSION IS A SEPARATE PROCESS.
//    `_timing_compare.py` records why: an interval bootstrapped over the samples of ONE session
//    answers "how precisely is THIS session's median known?", which is not the question, and six
//    such intervals over the same subject came out mutually disjoint. Here the between-session
//    nuisance is V8's own state — which tier each loop reached, where the heap landed, what the
//    inline caches learned — and all of it is re-drawn by a fresh process and by nothing less.
//
// 3. THERE IS A NEGATIVE CONTROL AND IT IS A REAL ARM.
//    `ct_ingest_control` is a byte-for-byte duplicate of `ct_ingest` exported under a second name
//    from the SAME module. It runs in the same rotation as the other arms. A difference measured
//    between it and `ct_ingest` is a difference the instrument invented, and a comparison that has
//    never been shown to report "no difference" where there is none is not calibrated.
//
// 4. THE CROSSING IS PRICED ON ITS OWN, TOO.
//    `ct_nop_step` and `ct_nop_ingest` have the two arms' signatures with the writer work removed.
//    They answer the question §9.3 actually asked — what a boundary crossing costs in V8, against
//    its ~33 ns prior — separately from the question of how much writer work sits behind it. Two
//    numbers, because if the ABIs come out within noise the SECOND one says whether that is
//    because crossings are cheap or because the writer swamps them, and those license different
//    decisions.
//
// 5. MIN AND MEDIAN, BOTH, PER ARM PER SESSION.
//    The minimum of "true cost plus non-negative noise" is the better estimate of the true cost;
//    the median says whether the distribution is behaving. Reporting only one of them is how a
//    scheduler hiccup becomes a finding.
//
// WHAT IS TIMED, AND WHAT IS NOT. The event array is built BEFORE the timer, because a real host
// decodes those events out of `TxSimulationResult` whichever ABI it then uses — charging their
// construction to one arm would measure msgpack. `close()` is after the timer, because finishing
// and compressing the container costs the same in both arms and including it only dilutes the
// ratio. Both are reported separately so neither is hidden.
//
// EVERY ARM RUN IS BOUNDED. A session that hangs produces no rows and no failure — M23's chain
// hung a whole milestone on a one-character defect because a trap fires on exit and a process
// that never exits has none. The parent kills a session that exceeds `--session-timeout` and
// writes an explicit `TIMEOUT` row, so a hang is a finding rather than a silence.
// ---------------------------------------------------------------------------

import { readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import process from 'node:process';

import {
  CtWriter,
  instantiateCtWriter,
  resolveTracingConfig,
  WRITER_PATH_A_PURE_RUST,
} from '../ct-host/src/index.ts';

function arg(name, dflt) {
  const i = process.argv.indexOf(name);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : dflt;
}

const MODULE = arg('--module', 'ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm');
const EVENTS = Number(arg('--events', '100000'));
const BATCH = Number(arg('--batch', '4096'));
const REPS = Number(arg('--reps', '6')); // ABBA blocks per arm pair, per session
const SESSIONS = Number(arg('--sessions', '10'));
const SESSION = arg('--session', '');
const OUT = arg('--out', '');
const SESSION_TIMEOUT_MS = Number(arg('--session-timeout', '900000'));

// The five arms. `label` is what lands in the TSV; `mode` says which export a rep drives.
const ARMS = [
  { label: 'batched', kind: 'batch', ingest: 'ct_ingest' },
  { label: 'perEvent', kind: 'perCall', step: 'ct_step' },
  { label: 'control', kind: 'batch', ingest: 'ct_ingest_control' },
  { label: 'nopBatched', kind: 'batch', ingest: 'ct_nop_ingest' },
  { label: 'nopPerEvent', kind: 'perCall', step: 'ct_nop_step' },
];

function makeEvents(n) {
  // One address object reused: a real host reads the same 32 bytes out of one decoded record, and
  // minting 100,000 Uint8Arrays would charge both arms for allocator behaviour that is not the
  // subject. Both arms copy those 32 bytes exactly once per event, which is the fair comparison.
  const addr = new Uint8Array(32);
  for (let i = 0; i < 32; i++) addr[i] = (i * 37) & 0xff;
  const out = new Array(n);
  for (let i = 0; i < n; i++) {
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

async function oneRep(bytes, arm, events) {
  const inst = await instantiateCtWriter(bytes);
  const cfg = resolveTracingConfig(
    {
      program: 'oq6',
      recordingId: '01949fcc-7d92-7e9c-8000-0000000006a6',
      sourcePath: '/aztec/tx.avm',
      workdir: '/aztec',
      columns: false,
    },
    WRITER_PATH_A_PURE_RUST,
  );
  const opts = { batchRecords: BATCH };
  if (arm.ingest) opts.ingestExport = arm.ingest;
  if (arm.step) opts.stepExport = arm.step;
  const w = new CtWriter(inst, cfg, opts);

  const t0 = process.hrtime.bigint();
  if (arm.kind === 'batch') {
    for (let i = 0; i < events.length; i++) w.push(events[i]);
    w.flush();
  } else {
    for (let i = 0; i < events.length; i++) w.writeStepPerCall(events[i]);
  }
  const t1 = process.hrtime.bigint();

  // Outside the timer, and read so the work cannot be proved dead.
  const rec = w.close();
  return {
    us: Number((t1 - t0) / 1000n),
    crossings: rec.crossings,
    events: rec.events,
    containerBytes: rec.container.length,
    growths: rec.memoryGrowths,
  };
}

async function runSession(k) {
  const bytes = readFileSync(MODULE);
  const events = makeEvents(EVENTS);
  const rows = [];
  const meta = new Map();

  // One warmup of every arm before anything is recorded, so the first measured rep is not paying
  // for the tier-up of a loop every later rep runs optimised. Not recorded, deliberately.
  for (const arm of ARMS) await oneRep(bytes, arm, events);

  // ABBA over the arm list: forward, then reversed, then forward, ... Every arm's mean position
  // within a block is the same across a pair of blocks, which is the property that removes the
  // confound between arm and launch order.
  for (let block = 0; block < REPS; block++) {
    const order = block % 2 === 0 ? ARMS : [...ARMS].reverse();
    for (const arm of order) {
      const r = await oneRep(bytes, arm, events);
      rows.push(`${k}\t${arm.label}\t${r.us}`);
      const m = meta.get(arm.label) ?? { crossings: r.crossings, containerBytes: r.containerBytes, events: r.events, growths: r.growths };
      meta.set(arm.label, m);
    }
  }
  for (const [label, m] of meta) {
    rows.push(`#META\t${label}\tcrossings=${m.crossings}\tevents=${m.events}\tcontainerBytes=${m.containerBytes}\tgrowths=${m.growths}`);
  }
  return rows;
}

if (SESSION !== '') {
  const rows = await runSession(SESSION);
  process.stdout.write(rows.join('\n') + '\n');
} else {
  if (!OUT) {
    process.stderr.write('run_oq6_arms: --out is required when running the whole sweep\n');
    process.exit(2);
  }
  writeFileSync(
    OUT,
    `#CONFIG\tevents=${EVENTS}\tbatch=${BATCH}\treps=${REPS}\tsessions=${SESSIONS}\tnode=${process.version}\tv8=${process.versions.v8}\n`,
  );
  for (let k = 1; k <= SESSIONS; k++) {
    const r = spawnSync(
      process.argv[0],
      [
        process.argv[1],
        '--module', MODULE,
        '--events', String(EVENTS),
        '--batch', String(BATCH),
        '--reps', String(REPS),
        '--session', String(k),
      ],
      { encoding: 'utf8', timeout: SESSION_TIMEOUT_MS, maxBuffer: 64 * 1024 * 1024 },
    );
    if (r.error && r.error.code === 'ETIMEDOUT') {
      appendFileSync(OUT, `#TIMEOUT\tsession=${k}\tafter=${SESSION_TIMEOUT_MS}ms\n`);
      process.stderr.write(`run_oq6_arms: session ${k} exceeded ${SESSION_TIMEOUT_MS} ms and was killed\n`);
      continue;
    }
    if (r.status !== 0) {
      appendFileSync(OUT, `#FAILED\tsession=${k}\tstatus=${r.status}\n`);
      process.stderr.write(`run_oq6_arms: session ${k} exited ${r.status}\n${r.stderr}\n`);
      continue;
    }
    appendFileSync(OUT, r.stdout);
    process.stderr.write(`run_oq6_arms: session ${k}/${SESSIONS} done\n`);
  }
  process.stderr.write(`run_oq6_arms: wrote ${OUT}\n`);
}
