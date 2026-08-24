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
// `avm_differential`, that is by upstream's own msgpack packers in C++, and arrives as hex. The
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
//   msgpack <p> <n>   the encode/decode half separated from execution
//   block             the seven corpus programs as one block against one world state
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
  return { raw: R.result(), us: Number((t1 - t0) / 1000n), inputBytes: b.length };
}

function simulateChattyBatched(name) {
  const b = blob(`reactorInputs.${name}.proving`);
  const ptr = R.put(b);
  let status;
  const t0 = process.hrtime.bigint();
  try { status = R.e.avm_simulate_with_hinted_dbs(ptr, b.length); } finally { R.free(ptr); }
  const t1 = process.hrtime.bigint();
  R.check(status, `avm_simulate_with_hinted_dbs(${name})`);
  return { raw: R.result(), us: Number((t1 - t0) / 1000n), inputBytes: b.length };
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
    const h = seed(name);
    const res = simulateResident(name, h);
    dump('resident', res.raw);
    line('resident.inputBytes', res.inputBytes);
    line('resident.steps', R.e.avm_steps_count());
    roots(h.mdb, 'resident.roots');
    destroy(h);

    const cha = simulateChattyBatched(name);
    dump('chatty', cha.raw);
    line('chatty.inputBytes', cha.inputBytes);
    line('chatty.steps', R.e.avm_steps_count());
    // The chatty arm holds no world state in the module, so there are no resident roots to read.
    // That is the shape's defining property and it is stated as a value rather than by omission.
    line('chatty.residentTreesPresent', 0);
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
    R.e.avm_merkle_db_destroy(mdb);
    line('snapshot.done', '1');
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
