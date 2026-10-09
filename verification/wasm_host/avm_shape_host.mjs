// M15's boundary-shape host: the SAME `avm.wasm` driven in both candidate shapes, on V8.
//
// THE TWO SHAPES, AS THE MILESTONE DEFINES THEM.
//
//   resident   `avm_simulate(inputs, contractDbHandle, merkleDbHandle)` — the DBs live in the
//              module and the boundary carries a transaction in and a result plus a step stream
//              out. Input 1,951 bytes.
//   chatty     the DBs are the HOST's: the module holds no world state and every answer the AVM
//              needs comes from outside. `avm_simulate_with_hinted_dbs(inputs)` is that shape with
//              the answers BATCHED into one payload (187 KB), and driving the twenty-two exported
//              interface methods one at a time is that shape with the answers fetched
//              INTERACTIVELY. Both are measured, because they are the two ends of the same
//              spectrum and the milestone's question is where on it to sit.
//
// HOW MANY CROSSINGS THE INTERACTIVE FORM COSTS IS UPSTREAM'S OWN NUMBER, NOT AN ESTIMATE.
// `AvmProvingInputs.hints` is a per-METHOD record of every DB call the AVM made during the
// simulation the hints were captured from — that is what makes replay possible — and eighteen of
// its categories map one-to-one onto the two host interfaces' methods. So the crossing count is a
// COUNT, read out of a blob upstream's own driver emits. See `_hint_crossings.mjs`, which owns
// that mapping so the host and the checks cannot disagree about it.
//
// THE HOST STILL DOES NOT ENCODE ANYTHING. Every blob crossing into the module was produced by
// `avm_differential`, that is by upstream's own msgpack packers in C++, and arrives as hex. The one
// exception is `simsnapshot`, which replaces fixed-width payload bytes (a field element, a fixint)
// inside such a blob and decodes every result back before using it; it writes no structure. The
// interactive drive issues real crossings of the real interface methods with those real payloads;
// what it cannot do is re-issue the AVM's own internal writes, because their arguments exist only
// inside the module. That limit is stated in BOUNDARY-SHAPE.md rather than papered over: the
// interactive drive measures the COST of a crossing of each kind, and the hint record supplies HOW
// MANY of each kind a transaction makes.
//
// Modes:
//   shapes <p>        one transaction through both shapes; the fields they must agree on
//   crossings         the per-op crossing table for every corpus program, from the hints
//   cost <p> <n>      both shapes timed, interleaved, plus the interactive drive
//   msgpack <p> <rounds> <n> [decodeRounds]
//                     the encode/decode half separated from execution, the module's own decode included
//   block             the seven corpus programs as one block against one world state
//   snapshot          the host's own setup journal exported and replayed into a fresh handle
//   simsnapshot <nh> <nf>  the state a SIMULATION wrote, exported and replayed into a second
//                     module instance (nh/nf: MAX_NOTE_HASHES_PER_TX / MAX_NULLIFIERS_PER_TX)
//
// Exit status is 0 on success and non-zero on any failure. Nothing here can turn a failing run
// into a passing one: every unexpected status throws.

import { readFile } from 'node:fs/promises';
import process from 'node:process';

import { blobFrom, hexOf, instantiateReactor, parseInputs, unpack } from './reactor_lib.mjs';
import { OPS, crossingsFromHints } from './_hint_crossings.mjs';

const out = [];
function line(key, value) { out.push(`${key} ${value}`); }
function flush() { if (out.length) process.stdout.write(out.join('\n') + '\n'); }

const [wasmPath, inputsPath, mode, ...rest] = process.argv.slice(2);
if (!wasmPath || !inputsPath || !mode) {
  console.error('usage: avm_shape_host.mjs <avm.wasm> <inputs.txt> <mode> [args...]');
  process.exit(2);
}

const R = await instantiateReactor(wasmPath);
const kv = parseInputs(await readFile(inputsPath, 'utf8'));
const blob = (key) => blobFrom(kv, key);

function programs() {
  const names = [];
  for (const k of kv.keys()) {
    const m = /^reactorInputs\.([a-z0-9]+)\.address$/.exec(k);
    if (m) names.push(m[1]);
  }
  const n = Number(kv.get('reactorInputs.programs.count'));
  if (!Number.isInteger(n) || n <= 0) throw new Error('the inputs file declares no programs');
  if (names.length !== n) throw new Error(`declared ${n} programs, carries ${names.length}`);
  return names.sort();
}

// --- handles and seeding ----------------------------------------------------
function seed(name) {
  const cdb = R.e.avm_contract_db_create();
  const mdb = R.e.avm_merkle_db_create();
  if (cdb === 0 || mdb === 0) throw new Error('a DB handle came back 0');
  R.callWithArgs(R.e.avm_contract_db_register_class, 'register_class', cdb, blob(`reactorInputs.${name}.setup.class`));
  R.callWithArgs(R.e.avm_contract_db_register_instance, 'register_instance', cdb, blob(`reactorInputs.${name}.setup.instance`));
  R.callWithArgs(R.e.avm_merkle_db_insert_indexed_leaves_nullifier_tree, 'insert_nullifier', mdb, blob(`reactorInputs.${name}.setup.nullifier`));
  R.callWithArgs(R.e.avm_merkle_db_insert_indexed_leaves_public_data_tree, 'insert_public_data', mdb, blob(`reactorInputs.${name}.setup.publicdata`));
  return { cdb, mdb };
}
function destroy({ cdb, mdb }) {
  R.e.avm_contract_db_destroy(cdb);
  R.e.avm_merkle_db_destroy(mdb);
}

// --- the two shapes ---------------------------------------------------------
function simulateResident(name, h) {
  const b = blob(`reactorInputs.${name}.fast`);
  const ptr = R.put(b);
  let status;
  const t0 = process.hrtime.bigint();
  try { status = R.e.avm_simulate(ptr, b.length, h.cdb, h.mdb); } finally { R.free(ptr); }
  const t1 = process.hrtime.bigint();
  R.check(status, `avm_simulate(${name})`);
  return { raw: R.result(), us: Number((t1 - t0) / 1000n), inputBytes: b.length, entry: 'avm_simulate' };
}

function simulateChattyBatched(name) {
  const b = blob(`reactorInputs.${name}.proving`);
  const ptr = R.put(b);
  let status;
  const t0 = process.hrtime.bigint();
  try { status = R.e.avm_simulate_with_hinted_dbs(ptr, b.length); } finally { R.free(ptr); }
  const t1 = process.hrtime.bigint();
  R.check(status, `avm_simulate_with_hinted_dbs(${name})`);
  return { raw: R.result(), us: Number((t1 - t0) / 1000n), inputBytes: b.length, entry: 'avm_simulate_with_hinted_dbs' };
}

// The INTERACTIVE form: issue, one at a time, exactly the multiset of DB operations the hint
// record says the AVM made — through the very exports that implement the two interfaces, with
// real msgpack payloads that upstream's own packers produced. Each call is one boundary crossing
// in and one result read back out, which is what a chatty shape pays per DB operation.
//
// It is not a fused execution and it does not pretend to be: it measures what N crossings of these
// KINDS cost, and the hint record supplies N. The one thing it cannot issue is the AVM's own
// internal write arguments, which exist only inside the module; those are issued with the corpus's
// own pre-packed argument blobs of the same type, so the payload sizes are real.
function driveInteractive(name, h, table) {
  const argFor = {
    'contract.get_contract_instance': () => blob(`reactorInputs.${name}.args.address`),
    'contract.get_contract_class': () => blob(`reactorInputs.${name}.args.classId`),
    'contract.get_bytecode_commitment': () => blob(`reactorInputs.${name}.args.classId`),
    'contract.get_debug_function_name': () => blob(`reactorInputs.${name}.args.debugName`),
    'contract.add_contracts': () => blob('reactorInputs.args.emptyDeployment'),
    'merkle.get_sibling_path': () => blob('reactorInputs.args.treeIndex'),
    'merkle.get_low_indexed_leaf': () => blob('reactorInputs.args.treeValue'),
    'merkle.get_leaf_value': () => blob('reactorInputs.args.treeIndex'),
    'merkle.get_leaf_preimage_public_data_tree': () => blob('reactorInputs.args.leafIndex'),
    'merkle.get_leaf_preimage_nullifier_tree': () => blob('reactorInputs.args.leafIndex'),
    'merkle.insert_indexed_leaves_public_data_tree': () => blob('reactorInputs.args.publicDataLeaf'),
    'merkle.insert_indexed_leaves_nullifier_tree': () => blob('reactorInputs.args.nullifierLeaf'),
    'merkle.append_leaves': () => blob('reactorInputs.args.appendLeaves'),
    'merkle.pad_tree': () => blob('reactorInputs.args.padTree'),
  };
  let crossings = 0;
  let requestBytes = 0;
  let replyBytes = 0;
  const t0 = process.hrtime.bigint();
  for (const op of OPS) {
    const n = table.byOp[op.name] ?? 0;
    for (let i = 0; i < n; i++) {
      const handle = op.db === 'contract' ? h.cdb : h.mdb;
      const fn = R.e[op.exp];
      if (typeof fn !== 'function') throw new Error(`the module does not export ${op.exp}`);
      if (op.args) {
        const make = argFor[op.name];
        if (!make) throw new Error(`no argument blob is declared for ${op.name}`);
        const b = make();
        const ptr = R.put(b);
        let st;
        try { st = fn(handle, ptr, b.length); } finally { R.free(ptr); }
        R.check(st, op.name);
        requestBytes += b.length;
      } else {
        R.check(fn(handle), op.name);
      }
      replyBytes += R.e.avm_result_len();
      crossings++;
    }
  }
  const t1 = process.hrtime.bigint();
  return { us: Number((t1 - t0) / 1000n), crossings, requestBytes, replyBytes };
}

// The comparable half of a TxSimulationResult: what the two shapes must agree on. The hinted
// entry point produces neither public inputs nor statistics — upstream's own
// `simulate_with_hinted_dbs` builds `PublicSimulatorConfig config = {}` for it — so those are not
// compared and their absence is REPORTED rather than skipped.
function dump(prefix, raw) {
  const r = unpack(raw);
  line(`${prefix}.revertCode`, r.revertCode);
  line(`${prefix}.totalGas`, `${r.gasUsed.totalGas.l2Gas}/${r.gasUsed.totalGas.daGas}`);
  line(`${prefix}.publicGas`, `${r.gasUsed.publicGas.l2Gas}/${r.gasUsed.publicGas.daGas}`);
  line(`${prefix}.billedGas`, `${r.gasUsed.billedGas.l2Gas}/${r.gasUsed.billedGas.daGas}`);
  line(`${prefix}.txFee`, hexOf(r.publicTxEffect.transactionFee));
  line(`${prefix}.nullifiers.count`, r.publicTxEffect.nullifiers.length);
  r.publicTxEffect.nullifiers.forEach((n, i) => line(`${prefix}.nullifiers.${i}`, hexOf(n)));
  line(`${prefix}.noteHashes.count`, r.publicTxEffect.noteHashes.length);
  r.publicTxEffect.noteHashes.forEach((n, i) => line(`${prefix}.noteHashes.${i}`, hexOf(n)));
  line(`${prefix}.dataWrites.count`, r.publicTxEffect.publicDataWrites.length);
  // The CONTENTS, not only the count: a world-state read that answers wrongly changes what a
  // program writes and leaves how many writes it makes, its gas and its fee exactly as they were.
  r.publicTxEffect.publicDataWrites.forEach((w, i) =>
    line(`${prefix}.dataWrites.${i}`, `${hexOf(w.leafSlot)} ${hexOf(w.value)}`));
  line(`${prefix}.publicLogs.count`, r.publicTxEffect.publicLogs.length);
  r.publicTxEffect.publicLogs.forEach((l, i) =>
    line(`${prefix}.publicLogs.${i}`, `${hexOf(l.contractAddress)} ${l.fields.map((f) => hexOf(f)).join(',')}`));
  line(`${prefix}.l2ToL1Msgs.count`, r.publicTxEffect.l2ToL1Msgs.length);
  line(`${prefix}.publicInputsPresent`, r.publicInputs ? 1 : 0);
  line(`${prefix}.resultBytes`, raw.length);
  return r;
}

function roots(handle, prefix) {
  const snaps = R.callNoArgs(R.e.avm_merkle_db_get_tree_roots, 'get_tree_roots', handle);
  for (const [k, v] of Object.entries(snaps)) {
    line(`${prefix}.${k}`, `${hexOf(v.root)} size=${v.nextAvailableLeafIndex}`);
  }
  return snaps;
}

function median(xs) { const s = [...xs].sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; }

try {
  if (mode === 'shapes') {
    const name = rest[0] ?? 'add';
    line('shapes.program', name);
    line('shapes.abiVersion', String(R.e.avm_abi_version()));
    // Each arm runs with every entry into a DB export counted: the resident arm must enter them
    // (it seeds its world state through them), and the chatty arm must not, because it holds no
    // world state in the module at all. That is the chatty shape's defining property, so it is
    // observed on the arm that ran rather than printed as a constant. The ARITY of the entry point
    // each arm called is read off the export itself: a DB handle is a parameter, and the chatty
    // entry point has none to take.
    const DB_EXPORTS = /^avm_(contract|merkle)_db_/;
    const resRun = R.countCalls(DB_EXPORTS, () => {
      const h = seed(name);
      const res = simulateResident(name, h);
      dump('resident', res.raw);
      line('resident.inputBytes', res.inputBytes);
      line('resident.steps', R.e.avm_steps_count());
      roots(h.mdb, 'resident.roots');
      destroy(h);
      return res;
    });

    const chaRun = R.countCalls(DB_EXPORTS, () => simulateChattyBatched(name));
    const cha = chaRun.value;
    dump('chatty', cha.raw);
    line('chatty.inputBytes', cha.inputBytes);
    line('chatty.steps', R.e.avm_steps_count());
    line('shapes.residentEntry', resRun.value.entry);
    line('shapes.residentEntryArity', R.e[resRun.value.entry].length);
    line('shapes.residentDbExportCalls', resRun.calls);
    line('shapes.chattyEntry', cha.entry);
    line('shapes.chattyEntryArity', R.e[cha.entry].length);
    line('shapes.chattyDbExportCalls', chaRun.calls);
    line('shapes.done', '1');
  } else if (mode === 'crossings') {
    const names = programs();
    line('crossings.programs.count', names.length);
    line('crossings.opTableSize', OPS.length);
    for (const name of names) {
      const b = blob(`reactorInputs.${name}.proving`);
      const t = crossingsFromHints(unpack(b).hints);
      line(`crossings.${name}.hintedBytes`, b.length);
      line(`crossings.${name}.total`, t.total);
      for (const op of OPS) {
        const n = t.byOp[op.name] ?? 0;
        if (n > 0) line(`crossings.${name}.op.${op.name}`, n);
      }
      line(`crossings.${name}.unmappedHintCategories`, t.unmapped.join(',') || '-');
      // The RESIDENT shape's own crossings for the same transaction, counted at the exports: every
      // entry into the module from handing it the input to holding the decoded result. The hint
      // tally above is upstream's record of the chatty shape; this is what the shape M15 ships
      // actually costs, measured on the module this milestone built.
      const h = seed(name);
      const resident = R.countCalls(/^avm_/, () => simulateResident(name, h));
      destroy(h);
      line(`crossings.${name}.residentBoundaryCalls`, resident.calls);
    }
    line('crossings.done', '1');
  } else if (mode === 'cost') {
    const name = rest[0] ?? 'storage';
    const rounds = Number(rest[1] ?? 5);
    line('cost.program', name);
    line('cost.rounds', rounds);
    const table = crossingsFromHints(unpack(blob(`reactorInputs.${name}.proving`)).hints);
    line('cost.dbOperations', table.total);

    const resident = [];
    const batched = [];
    const interactive = [];
    for (let r = 0; r < rounds; r++) {
      // Interleaved, so a machine that gets slower during the run penalises all three arms.
      const h1 = seed(name); resident.push(simulateResident(name, h1).us); destroy(h1);
      batched.push(simulateChattyBatched(name).us);
      const h3 = seed(name); const d = driveInteractive(name, h3, table); destroy(h3);
      interactive.push(d.us);
      if (r === 0) {
        line('cost.interactive.crossings', d.crossings);
        line('cost.interactive.requestBytes', d.requestBytes);
        line('cost.interactive.replyBytes', d.replyBytes);
      }
    }
    // `crossings` above is the drive's own loop counter over the hint table, so it equals the
    // table's total by construction. What the module actually saw is counted on one further,
    // untimed drive: every entry into a DB export, which is what a chatty shape pays for.
    const hc = seed(name);
    const enteredDrive = R.countCalls(/^avm_(contract|merkle)_db_/, () => driveInteractive(name, hc, table));
    destroy(hc);
    line('cost.interactive.exportsEntered', enteredDrive.calls);
    resident.forEach((v, i) => line(`cost.resident.us.${i}`, v));
    batched.forEach((v, i) => line(`cost.chattyBatched.us.${i}`, v));
    interactive.forEach((v, i) => line(`cost.chattyInteractive.us.${i}`, v));
    line('cost.resident.medianUs', median(resident));
    line('cost.chattyBatched.medianUs', median(batched));
    line('cost.chattyInteractive.medianUs', median(interactive));
    line('cost.done', '1');
  } else if (mode === 'msgpack') {
    // The encode/decode half, separated from execution. Three measurements, none of which is a
    // guess:
    //   * the module decoding a 1,951-byte `AvmFastSimulationInputs` versus a ~187,000-byte
    //     `AvmProvingInputs` — the same simulation, two payload sizes, so the difference is the
    //     decode;
    //   * the host decoding the result blob, timed on its own;
    //   * a null crossing, so the fixed cost of a call is separable from the cost of its payload.
    const name = rest[0] ?? 'storage';
    const rounds = Number(rest[1] ?? 5);
    line('msgpack.program', name);
    const fast = blob(`reactorInputs.${name}.fast`);
    const proving = blob(`reactorInputs.${name}.proving`);
    line('msgpack.fastInputBytes', fast.length);
    line('msgpack.provingInputBytes', proving.length);

    // Host-side decode of the result, on its own.
    const h = seed(name);
    const res = simulateResident(name, h);
    destroy(h);
    line('msgpack.resultBytes', res.raw.length);
    const dec = [];
    for (let r = 0; r < rounds; r++) {
      const t0 = process.hrtime.bigint();
      unpack(res.raw);
      const t1 = process.hrtime.bigint();
      dec.push(Number((t1 - t0) / 1000n));
    }
    dec.forEach((v, i) => line(`msgpack.hostDecode.us.${i}`, v));
    line('msgpack.hostDecode.medianUs', median(dec));

    // The null crossing: the cheapest export there is, a return of a constant. What is left after
    // the loop overhead is the crossing.
    const n = Number(rest[2] ?? 200000);
    line('msgpack.nullCrossing.n', n);
    const nulls = [];
    for (let r = 0; r < 3; r++) {
      const t0 = process.hrtime.bigint();
      for (let i = 0; i < n; i++) R.e.avm_abi_version();
      const t1 = process.hrtime.bigint();
      nulls.push(Number((t1 - t0) / 1000n));
    }
    nulls.forEach((v, i) => line(`msgpack.nullCrossing.us.${i}`, v));
    line('msgpack.nullCrossing.medianUs', median(nulls));
    line('msgpack.nullCrossing.nsPerCrossing', Math.round((median(nulls) * 1000) / n));

    // Round-tripping the two input sizes through alloc/copy/free alone — the transport half of a
    // crossing, without the simulation.
    for (const [label, b] of [['fast', fast], ['proving', proving]]) {
      const ts = [];
      for (let r = 0; r < rounds; r++) {
        const t0 = process.hrtime.bigint();
        for (let i = 0; i < 50; i++) { const p = R.put(b); R.free(p); }
        const t1 = process.hrtime.bigint();
        ts.push(Number((t1 - t0) / 1000n));
      }
      line(`msgpack.transport.${label}.bytes`, b.length);
      line(`msgpack.transport.${label}.us50`, median(ts));
    }

    // THE MODULE'S OWN DECODE of its input, separated from the simulation without a new export.
    //
    // Both entry points decode with upstream's `AvmFastSimulationInputs::from` /
    // `AvmProvingInputs::from`: msgpack-c parses the whole buffer, then the structs are converted
    // field by field in declaration order, which is also the order they were packed in. A field
    // element's conversion REJECTS a non-canonical value (`field::msgpack_unpack`, "value >=
    // modulus") by throwing. So the payload with its LAST field element set to 0xff..ff is parsed
    // in full, converted up to that last field, and then refused before any simulation starts —
    // and the entry point's wall time is the decode, plus an error path that is timed on its own
    // with a one-byte nil payload (refused at the first conversion, nothing to parse).
    //
    // That the refusal came from the field that was corrupted is read back from the module's
    // error message, not assumed; that conversion really progressed through the buffer is shown
    // by corrupting the FIRST field element instead, which must be refused sooner; and the bytes
    // after the last field element, which this does not convert, are reported.
    //
    // The field elements are found without a second reading of the wire format: the decoder
    // returns every `bin` as a VIEW into the buffer it decoded, so a 32-byte bin's `byteOffset` is
    // its position in the payload.
    const ffOffsets = (b) => {
      const offs = [];
      const walk = (v) => {
        if (v instanceof Uint8Array) {
          if (v.buffer !== b.buffer) throw new Error('a decoded bin is not a view into the payload');
          if (v.length === 32) offs.push(v.byteOffset - b.byteOffset);
        } else if (Array.isArray(v)) v.forEach(walk);
        else if (v && typeof v === 'object') Object.values(v).forEach(walk);
      };
      walk(unpack(b));
      return offs.sort((x, y) => x - y);
    };
    const corruptAt = (b, off) => { const c = b.slice(); c.fill(0xff, off, off + 32); return c; };
    const hd = seed(name);
    const entryFor = {
      fast: (p, n) => R.e.avm_simulate(p, n, hd.cdb, hd.mdb),
      proving: (p, n) => R.e.avm_simulate_with_hinted_dbs(p, n),
    };
    const refused = (label, bytes) => {
      const ptr = R.put(bytes);
      let st;
      const t0 = process.hrtime.bigint();
      try { st = entryFor[label](ptr, bytes.length); } finally { R.free(ptr); }
      const t1 = process.hrtime.bigint();
      if (st === 0) throw new Error(`${label}: a payload that must be refused was simulated`);
      return { us: Number(t1 - t0) / 1000, message: R.errorMessage() ?? '' };
    };
    const decodeRounds = Number(rest[3] ?? 25);
    const warm = Math.min(5, Math.floor(decodeRounds / 5));
    line('msgpack.moduleDecode.rounds', decodeRounds);
    line('msgpack.moduleDecode.warmupRounds', warm);
    const payloads = {};
    for (const [label, b] of [['fast', fast], ['proving', proving]]) {
      const offs = ffOffsets(b);
      if (offs.length < 2) throw new Error(`${label}: fewer than two field elements in the payload`);
      payloads[label] = { b, last: corruptAt(b, offs.at(-1)), first: corruptAt(b, offs[0]) };
      line(`msgpack.moduleDecode.${label}.fieldElements`, offs.length);
      line(`msgpack.moduleDecode.${label}.unconvertedTailBytes`, b.length - offs.at(-1) - 32);
    }
    const series = {};
    const push = (k, v) => (series[k] ??= []).push(v);
    const messages = {};
    for (let r = 0; r < decodeRounds; r++) {
      // Interleaved, every arm in every round, so load that comes and goes lands on all of them.
      for (const label of ['fast', 'proving']) {
        const x = payloads[label];
        const last = refused(label, x.last);
        const first = refused(label, x.first);
        const nil = refused(label, new Uint8Array([0xc0]));
        const t0 = process.hrtime.bigint();
        unpack(x.b);
        const host = Number(process.hrtime.bigint() - t0) / 1000;
        if (r === 0) { messages[`${label}.last`] = last.message; messages[`${label}.nil`] = nil.message; }
        if (r >= warm) {
          push(`${label}.last`, last.us); push(`${label}.first`, first.us);
          push(`${label}.nil`, nil.us); push(`${label}.hostDecode`, host);
        }
      }
      // The two simulations the decode is a part of, on the same payloads intact.
      const hs = seed(name);
      const sr = simulateResident(name, hs);
      destroy(hs);
      const sc = simulateChattyBatched(name);
      if (r >= warm) { push('fast.simulate', sr.us); push('proving.simulate', sc.us); }
    }
    destroy(hd);
    for (const [k, v] of Object.entries(messages)) line(`msgpack.moduleDecode.${k}.message`, JSON.stringify(v));
    for (const [k, v] of Object.entries(series)) {
      line(`msgpack.moduleDecode.${k}.samples`, v.length);
      line(`msgpack.moduleDecode.${k}.medianUs`, median(v).toFixed(1));
    }
    line('msgpack.done', '1');
  } else if (mode === 'block') {
    // A BLOCK: the seven corpus programs as seven transactions against ONE world state and ONE
    // contract DB, with a checkpoint opened around each.
    //
    // EVERY TRANSACTION IS REVERTED, AND THE CAUSE IS M12'S DRIVER RATHER THAN THE CORPUS.
    // All seven transactions carry the SAME first nullifier, 0x…deadbeef, so committing any one of
    // them makes the next fail with `[NR_NULLIFIER_INSERTION] UNRECOVERABLE ERROR! Nullifier
    // collision` — upstream's own duplicate check working correctly.
    //
    // But that nullifier is not emitted by the PROGRAMS at all: it is the tx-level non-revertible
    // first nullifier, and upstream's `PublicTxSimulationTester` already makes it unique per
    // transaction — `deadbeef + FF(tx_count); tx_count++`, with `tx_count` a per-instance member
    // (vm2/testing/public_tx_simulation_tester.cpp:216-219, .hpp:109). M12's driver constructs a
    // FRESH tester per program, on purpose, for transcript stability, which resets that counter
    // every time. This comment said "a property of the corpus" for two revisions; it is a property
    // of the harness.
    //
    // So the block here measures seven EXECUTIONS against one world state and one contract DB, each
    // inside its own checkpoint pair, and the state returns to where it started. What that costs is
    // the block's execution cost; what it does not exercise is seven transactions' effects
    // accumulating — and what M20/M22 need for that is ONE LINE in the driver (one tester across
    // the block, or a nullifier offset), not a new corpus.
    const names = programs();
    line('block.transactions', names.length);
    let hintedCrossings = 0;
    let hintedBytes = 0;
    for (const name of names) {
      const t = crossingsFromHints(unpack(blob(`reactorInputs.${name}.proving`)).hints);
      hintedCrossings += t.total;
      hintedBytes += blob(`reactorInputs.${name}.proving`).length;
    }
    line('block.chatty.dbCrossings', hintedCrossings);
    line('block.chatty.hintedBytes', hintedBytes);

    const cdb = R.e.avm_contract_db_create();
    const mdb = R.e.avm_merkle_db_create();
    for (const name of names) {
      R.callWithArgs(R.e.avm_contract_db_register_class, 'register_class', cdb, blob(`reactorInputs.${name}.setup.class`));
      R.callWithArgs(R.e.avm_contract_db_register_instance, 'register_instance', cdb, blob(`reactorInputs.${name}.setup.instance`));
      R.callWithArgs(R.e.avm_merkle_db_insert_indexed_leaves_nullifier_tree, 'insert_nullifier', mdb, blob(`reactorInputs.${name}.setup.nullifier`));
      R.callWithArgs(R.e.avm_merkle_db_insert_indexed_leaves_public_data_tree, 'insert_public_data', mdb, blob(`reactorInputs.${name}.setup.publicdata`));
    }
    const seeded = roots(mdb, 'block.seeded');
    line('block.checkpointIdAtStart', R.callNoArgs(R.e.avm_merkle_db_get_checkpoint_id, 'get_checkpoint_id', mdb));

    let residentInputBytes = 0;
    let midBlock = null;
    const t0 = process.hrtime.bigint();
    for (const name of names) {
      R.callNoArgs(R.e.avm_merkle_db_create_checkpoint, 'merkle create_checkpoint', mdb);
      R.callNoArgs(R.e.avm_contract_db_create_checkpoint, 'contract create_checkpoint', cdb);
      const res = simulateResident(name, { cdb, mdb });
      residentInputBytes += res.inputBytes;
      // Captured ONCE, inside the first transaction's checkpoint and before it is reverted: the
      // proof that the world state really moved, without which "the roots came back" below is
      // satisfied by a block in which nothing happened.
      if (midBlock === null) {
        midBlock = R.callNoArgs(R.e.avm_merkle_db_get_tree_roots, 'get_tree_roots', mdb);
      }
      R.callNoArgs(R.e.avm_contract_db_revert_checkpoint, 'contract revert_checkpoint', cdb);
      R.callNoArgs(R.e.avm_merkle_db_revert_checkpoint, 'merkle revert_checkpoint', mdb);
    }
    const t1 = process.hrtime.bigint();
    line('block.resident.us', Number((t1 - t0) / 1000n));
    line('block.resident.inputBytes', residentInputBytes);
    line('block.resident.pages', R.pages());
    for (const [k, v] of Object.entries(midBlock)) {
      line(`block.midTx.${k}`, `${hexOf(v.root)} size=${v.nextAvailableLeafIndex}`);
    }
    const after = roots(mdb, 'block.resident.roots');
    line('block.checkpointIdAtEnd', R.callNoArgs(R.e.avm_merkle_db_get_checkpoint_id, 'get_checkpoint_id', mdb));
    let moved = 0;
    let restored = 0;
    for (const k of Object.keys(seeded)) {
      if (hexOf(seeded[k].root) !== hexOf(midBlock[k].root)) moved++;
      if (hexOf(seeded[k].root) === hexOf(after[k].root)) restored++;
    }
    line('block.treesMovedDuringATransaction', moved);
    line('block.treesRestoredByRevert', restored);
    line('block.trees', Object.keys(seeded).length);

    R.e.avm_contract_db_destroy(cdb);
    R.e.avm_merkle_db_destroy(mdb);

    // The same block through the chatty-batched arm. It holds no world state, so each transaction's
    // hint blob has to carry the whole starting state — which is the block-level version of the
    // trade this milestone is deciding — and no nullifier can collide, because no state is shared.
    const t2 = process.hrtime.bigint();
    for (const name of names) simulateChattyBatched(name);
    const t3 = process.hrtime.bigint();
    line('block.chatty.us', Number((t3 - t2) / 1000n));
    line('block.chatty.pages', R.pages());
    line('block.done', '1');
  } else if (mode === 'snapshot') {
    // STATE EXPORT AND IMPORT ACROSS THE BOUNDARY, in the shape that can answer it.
    //
    // The module has no serialisation surface — `MemoryMerkleDB::State` is private and
    // `get_tree_roots()` is a SUMMARY — so the resident shape has no carrier at the anchor. The
    // chatty shape does not need one: the host owns the DB, so it already holds every operation
    // that built the state. The export is the ordered journal of those operations and the import
    // is replaying it into a fresh handle. O(changes), and exact, because the bytes replayed are
    // the bytes that were applied.
    //
    // The journal entries are upstream's own msgpack, produced by `avm_differential` — this host
    // still encodes nothing.
    const names = programs();
    line('snapshot.programs.count', names.length);
    const mdb = R.e.avm_merkle_db_create();
    if (mdb === 0) throw new Error('avm_merkle_db_create returned 0');
    const journal = [];
    for (const name of names) {
      for (const [op, key] of [
        ['merkle.insert_indexed_leaves_nullifier_tree', `reactorInputs.${name}.setup.nullifier`],
        ['merkle.insert_indexed_leaves_public_data_tree', `reactorInputs.${name}.setup.publicdata`],
      ]) {
        const b = blob(key);
        const entry = OPS.find((o) => o.name === op);
        R.callWithArgs(R.e[entry.exp], op, mdb, b);
        journal.push({ op, bytes: b });
      }
    }
    // One append and one pad as well, so the journal covers more than the two indexed inserts and
    // the comparison below is not a comparison of one tree.
    for (const [op, key] of [
      ['merkle.append_leaves', 'reactorInputs.args.appendLeaves'],
      ['merkle.pad_tree', 'reactorInputs.args.padTree'],
    ]) {
      const b = blob(key);
      const entry = OPS.find((o) => o.name === op);
      R.callWithArgs(R.e[entry.exp], op, mdb, b);
      journal.push({ op, bytes: b });
    }
    const before = roots(mdb, 'snapshot.before');
    line('snapshot.journal.entries', journal.length);
    line('snapshot.journal.bytes', journal.reduce((a, e) => a + e.bytes.length, 0));
    if (journal.length === 0) throw new Error('the export journal is empty');

    // Import into a FRESH handle: it starts at genesis, which is captured and asserted to DIFFER,
    // so a match afterwards is a statement about the import.
    const fresh = R.e.avm_merkle_db_create();
    const freshBefore = roots(fresh, 'snapshot.fresh.before');
    for (const e of journal) {
      const entry = OPS.find((o) => o.name === e.op);
      if (!entry) throw new Error(`the journal names an op this host does not know: ${e.op}`);
      R.callWithArgs(R.e[entry.exp], e.op, fresh, e.bytes);
    }
    const after = roots(fresh, 'snapshot.after');

    line('snapshot.trees.count', Object.keys(after).length);
    for (const k of Object.keys(before)) {
      line(`snapshot.match.${k}`,
        hexOf(before[k].root) === hexOf(after[k].root)
        && String(before[k].nextAvailableLeafIndex) === String(after[k].nextAvailableLeafIndex) ? 1 : 0);
      line(`snapshot.moved.${k}`, hexOf(freshBefore[k].root) === hexOf(after[k].root) ? 0 : 1);
    }
    R.e.avm_merkle_db_destroy(fresh);

    // TWO CONTROLS on the replay, because a match between two DBs fed the same bytes by the same
    // module is also what a module that ignored its payloads would produce. Replayed with the FIRST
    // entry's payload EXCHANGED with the next same-kind entry's — the same leaves, the same ops, in a
    // different order, so no leaf is inserted twice — and replayed with the first entry DROPPED,
    // the roots must no longer match the export.
    const replayMismatches = (entries) => {
      const h = R.e.avm_merkle_db_create();
      for (const e of entries) {
        const entry = OPS.find((o) => o.name === e.op);
        R.callWithArgs(R.e[entry.exp], e.op, h, e.bytes);
      }
      const t = R.callNoArgs(R.e.avm_merkle_db_get_tree_roots, 'get_tree_roots', h);
      R.e.avm_merkle_db_destroy(h);
      return Object.keys(before).filter((k) => hexOf(before[k].root) !== hexOf(t[k].root)
        || String(before[k].nextAvailableLeafIndex) !== String(t[k].nextAvailableLeafIndex)).length;
    };
    const nextSame = journal.findIndex((e, i) => i > 0 && e.op === journal[0].op);
    if (nextSame < 0) throw new Error('the journal has no second entry of its first entry\'s kind');
    const substituted = journal.map((e, i) => (i === 0 ? { op: e.op, bytes: journal[nextSame].bytes }
      : i === nextSame ? { op: e.op, bytes: journal[0].bytes } : e));
    line('snapshot.control.substituted.mismatchedTrees', replayMismatches(substituted));
    line('snapshot.control.dropped.mismatchedTrees', replayMismatches(journal.slice(1)));
    R.e.avm_merkle_db_destroy(mdb);
    line('snapshot.done', '1');
  } else if (mode === 'simsnapshot') {
    // THE STATE A SIMULATION WROTE, EXPORTED AND IMPORTED INTO A SECOND MODULE INSTANCE.
    //
    // `snapshot` above carries the host's OWN setup operations. This mode carries what the AVM
    // wrote inside `avm_simulate`, which never crosses the boundary as DB calls: the resident DB is
    // in the module and the AVM drives it directly. What DOES cross is the transaction's own
    // record of those writes — `TxSimulationResult.publicTxEffect` — and upstream's `MerkleDB`
    // (vm2/simulation/gadgets/concrete_dbs.cpp) turns each entry of it into exactly one raw-DB call:
    //
    //   every nullifier        -> insert_indexed_leaves_nullifier_tree(NullifierLeafValue)
    //   every note hash        -> append_leaves(NOTE_HASH_TREE, [unique note hash])
    //   every public data write-> insert_indexed_leaves_public_data_tree(PublicDataLeafValue)
    //   and at the end         -> pad_tree(NOTE_HASH_TREE,  MAX_NOTE_HASHES_PER_TX - #note hashes)
    //                             pad_tree(NULLIFIER_TREE, MAX_NULLIFIERS_PER_TX  - #nullifiers)
    //
    // So the export is the setup journal followed by those calls, and the import replays it into a
    // handle in a SECOND, separately instantiated module — separate linear memory, nothing shared
    // with the instance that simulated. The claim checked is that the imported roots equal the
    // simulating instance's END roots, which nothing in this construction reads: the two
    // MAX_*_PER_TX constants come from the caller (read out of upstream's aztec_constants.hpp),
    // never from the end roots' sizes.
    //
    // THE HOST STILL DOES NOT ENCODE A SCHEMA. Each call's argument is an upstream-packed blob from
    // `avm_differential` with its fixed-width payload bytes replaced: a 32-byte field element
    // inside a `bin8(32)`, or a positive-fixint tree id / count. The template's layout is checked
    // byte-for-byte before the splice, and every spliced blob is decoded back and compared with the
    // values that were meant to go in, so a splice that wrote the wrong bytes is an exception here
    // rather than a mismatch the checks would have to interpret.
    const maxNoteHashes = Number(rest[0]);
    const maxNullifiers = Number(rest[1]);
    if (!Number.isInteger(maxNoteHashes) || !Number.isInteger(maxNullifiers)
        || maxNoteHashes <= 0 || maxNullifiers <= 0 || maxNoteHashes > 127 || maxNullifiers > 127) {
      throw new Error(`simsnapshot needs MAX_NOTE_HASHES_PER_TX and MAX_NULLIFIERS_PER_TX (got ${rest[0]} ${rest[1]})`);
    }
    const NULLIFIER_TREE = 0;
    const NOTE_HASH_TREE = 1;
    const expectBytes = (b, at, want, what) => {
      for (let i = 0; i < want.length; i++) {
        if (b[at + i] !== want[i]) throw new Error(`${what}: template byte ${at + i} is ${b[at + i]}, expected ${want[i]}`);
      }
    };
    const ascii = (t) => [...t].map((c) => c.charCodeAt(0));
    const ff = (v, what) => {
      if (!(v instanceof Uint8Array) || v.length !== 32) throw new Error(`${what}: not a 32-byte field element`);
      return v;
    };
    const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
    const tNull = blob('reactorInputs.args.nullifierLeaf');      // {nullifier: bin8(32)}
    const tData = blob('reactorInputs.args.publicDataLeaf');     // {slot: bin8(32), value: bin8(32)}
    const tAppend = blob('reactorInputs.args.appendLeaves');     // [treeId, [bin8(32)]]
    const tPad = blob('reactorInputs.args.padTree');             // [treeId, count]
    expectBytes(tNull, 0, [0x81, 0xa9, ...ascii('nullifier'), 0xc4, 0x20], 'nullifierLeaf');
    if (tNull.length !== 45) throw new Error(`nullifierLeaf template is ${tNull.length} bytes, expected 45`);
    expectBytes(tData, 0, [0x82, 0xa4, ...ascii('slot'), 0xc4, 0x20], 'publicDataLeaf');
    expectBytes(tData, 40, [0xa5, ...ascii('value'), 0xc4, 0x20], 'publicDataLeaf');
    if (tData.length !== 80) throw new Error(`publicDataLeaf template is ${tData.length} bytes, expected 80`);
    expectBytes(tAppend, 0, [0x92, NOTE_HASH_TREE, 0x91, 0xc4, 0x20], 'appendLeaves');
    if (tAppend.length !== 37) throw new Error(`appendLeaves template is ${tAppend.length} bytes, expected 37`);
    expectBytes(tPad, 0, [0x92], 'padTree');
    if (tPad.length !== 3 || tPad[1] > 0x7f || tPad[2] > 0x7f) throw new Error('padTree template is not [fixint, fixint]');

    const nullifierArg = (v) => {
      const b = tNull.slice(); b.set(ff(v, 'nullifier'), 13);
      if (!same(unpack(b).nullifier, v)) throw new Error('nullifier splice did not decode back');
      return { op: 'merkle.insert_indexed_leaves_nullifier_tree', bytes: b };
    };
    const dataArg = (slot, value) => {
      const b = tData.slice(); b.set(ff(slot, 'slot'), 8); b.set(ff(value, 'value'), 48);
      const d = unpack(b);
      if (!same(d.slot, slot) || !same(d.value, value)) throw new Error('public data splice did not decode back');
      return { op: 'merkle.insert_indexed_leaves_public_data_tree', bytes: b };
    };
    const appendArg = (v) => {
      const b = tAppend.slice(); b.set(ff(v, 'note hash'), 5);
      const d = unpack(b);
      if (d[0] !== NOTE_HASH_TREE || d[1].length !== 1 || !same(d[1][0], v)) throw new Error('append splice did not decode back');
      return { op: 'merkle.append_leaves', bytes: b };
    };
    const padArg = (tree, n) => {
      if (!Number.isInteger(n) || n < 0 || n > 0x7f) throw new Error(`pad count ${n} is not a positive fixint`);
      const b = tPad.slice(); b[1] = tree; b[2] = n;
      const d = unpack(b);
      if (d[0] !== tree || Number(d[1]) !== n) throw new Error('pad splice did not decode back');
      return { op: 'merkle.pad_tree', bytes: b };
    };

    // The importing module: a second instance of the same binary. Nothing it holds was produced by
    // the instance that simulated.
    const R2 = await instantiateReactor(wasmPath);
    const replayRoots = (entries) => {
      const h = R2.e.avm_merkle_db_create();
      if (h === 0) throw new Error('avm_merkle_db_create returned 0 in the importing instance');
      for (const e of entries) {
        const entry = OPS.find((o) => o.name === e.op);
        if (!entry) throw new Error(`the journal names an op this host does not know: ${e.op}`);
        R2.callWithArgs(R2.e[entry.exp], e.op, h, e.bytes);
      }
      const t = R2.callNoArgs(R2.e.avm_merkle_db_get_tree_roots, 'get_tree_roots', h);
      R2.e.avm_merkle_db_destroy(h);
      return t;
    };
    const mismatches = (want, got) => Object.keys(want).filter((k) => hexOf(want[k].root) !== hexOf(got[k].root)
      || String(want[k].nextAvailableLeafIndex) !== String(got[k].nextAvailableLeafIndex));
    const fmt = (v) => `${hexOf(v.root)} size=${v.nextAvailableLeafIndex}`;

    const names = programs();
    line('simsnapshot.programs.count', names.length);
    line('simsnapshot.maxNoteHashes', maxNoteHashes);
    line('simsnapshot.maxNullifiers', maxNullifiers);
    for (const name of names) {
      const P = `simsnapshot.${name}`;
      const setup = [
        { op: 'merkle.insert_indexed_leaves_nullifier_tree', bytes: blob(`reactorInputs.${name}.setup.nullifier`) },
        { op: 'merkle.insert_indexed_leaves_public_data_tree', bytes: blob(`reactorInputs.${name}.setup.publicdata`) },
      ];
      const h = seed(name);
      const setupRoots = R.callNoArgs(R.e.avm_merkle_db_get_tree_roots, 'get_tree_roots', h.mdb);
      const res = simulateResident(name, h);
      const endRoots = R.callNoArgs(R.e.avm_merkle_db_get_tree_roots, 'get_tree_roots', h.mdb);
      destroy(h);
      const fx = unpack(res.raw).publicTxEffect;
      line(`${P}.revertCode`, unpack(res.raw).revertCode);
      const sim = [];
      for (const n of fx.nullifiers) sim.push(nullifierArg(n));
      for (const n of fx.noteHashes) sim.push(appendArg(n));
      for (const w of fx.publicDataWrites) sim.push(dataArg(w.leafSlot, w.value));
      sim.push(padArg(NOTE_HASH_TREE, maxNoteHashes - fx.noteHashes.length));
      sim.push(padArg(NULLIFIER_TREE, maxNullifiers - fx.nullifiers.length));
      line(`${P}.effect.nullifiers`, fx.nullifiers.length);
      line(`${P}.effect.noteHashes`, fx.noteHashes.length);
      line(`${P}.effect.publicDataWrites`, fx.publicDataWrites.length);
      line(`${P}.journal.setupEntries`, setup.length);
      line(`${P}.journal.simulationEntries`, sim.length);
      line(`${P}.journal.bytes`, [...setup, ...sim].reduce((a, e) => a + e.bytes.length, 0));
      for (const k of Object.keys(endRoots)) {
        line(`${P}.setup.${k}`, fmt(setupRoots[k]));
        line(`${P}.end.${k}`, fmt(endRoots[k]));
      }
      line(`${P}.treesMovedBySimulation`, mismatches(setupRoots, endRoots).length);

      const imported = replayRoots([...setup, ...sim]);
      for (const k of Object.keys(imported)) line(`${P}.imported.${k}`, fmt(imported[k]));
      line(`${P}.trees`, Object.keys(endRoots).length);
      line(`${P}.imported.mismatchedTrees`, mismatches(endRoots, imported).length);

      // Controls. Each changes the journal in one place and must leave some tree away from the
      // END roots: the setup alone (the simulation's writes not carried at all), the simulation's
      // LAST state-writing entry dropped, and its first state-writing entry's payload perturbed in
      // its lowest byte.
      line(`${P}.control.setupOnly.mismatchedTrees`, mismatches(endRoots, replayRoots(setup)).length);
      const writes = sim.filter((e) => e.op !== 'merkle.pad_tree');
      line(`${P}.simulationWrites`, writes.length);
      if (writes.length > 0) {
        const last = sim.indexOf(writes[writes.length - 1]);
        line(`${P}.control.droppedWrite.mismatchedTrees`,
          mismatches(endRoots, replayRoots([...setup, ...sim.filter((_, i) => i !== last)])).length);
        const first = sim.indexOf(writes[0]);
        const p = sim[first].bytes.slice();
        p[p.length - 1] ^= 0x01;
        line(`${P}.control.perturbedWrite.mismatchedTrees`,
          mismatches(endRoots, replayRoots([...setup, ...sim.map((e, i) => (i === first ? { op: e.op, bytes: p } : e))])).length);
      }
      // And the padding is load-bearing too: without it the two indexed/append trees end short.
      line(`${P}.control.unpadded.mismatchedTrees`,
        mismatches(endRoots, replayRoots([...setup, ...sim.filter((e) => e.op !== 'merkle.pad_tree')])).length);
    }
    line('simsnapshot.importingInstanceOwnedAllocations', R2.owned.size);
    line('simsnapshot.done', '1');
  } else {
    console.error(`unknown mode: ${mode}`);
    process.exit(2);
  }
  line('ownedAllocationsAtExit', R.owned.size);
  flush();
} catch (e) {
  flush();
  console.error(`avm_shape_host.mjs: ${e.stack ?? e.message}`);
  process.exit(5);
}
