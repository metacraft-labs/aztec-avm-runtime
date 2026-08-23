// A host for `avm.wasm` — M12's standalone AVM reactor — on V8.
//
// The reactor has no `main`. It is a WASI *reactor*: instantiated once, initialised through
// `_initialize`, and then called through its exports. Everything that crosses the boundary is
// msgpack, and every schema on the far side of it is upstream's own — `AvmFastSimulationInputs`,
// `AvmProvingInputs`, `TxSimulationResult`, `ExecutionStep`, `ContractClassWithCommitment`,
// `ContractInstance`, `NullifierLeafValue`, `PublicDataLeafValue`, `TreeSnapshots`, `IndexedLeaf`,
// `SequentialInsertionResult`, `GetLowIndexedLeafResponse`, `MerkleTreeId`.
//
// THIS HOST DECODES ONLY; IT NEVER ENCODES. Every input blob is produced by
// `avm_differential reactorinputs` — that is, by upstream's own msgpack packers in C++ — and is
// handed here as hex. That is deliberate: a JavaScript encoder of ours would be a second,
// independent implementation of the same schemas, and two implementations of an encoding are two
// things that can disagree. The decoder is unavoidable (the results have to be read) and it is
// generic msgpack: it knows the wire format, not the schemas.
//
// The module imports `env.memory` because barretenberg links every wasm artefact with
// `-Wl,--import-memory`; the limits are read out of the module's own import section rather than
// guessed, exactly as `run_wasm_test_binary.mjs` does for the test binaries.
//
// Usage:
//   node avm_reactor_host.mjs <avm.wasm> <inputs.txt> transcript
//   node avm_reactor_host.mjs <avm.wasm> <inputs.txt> hinted
//   node avm_reactor_host.mjs <avm.wasm> <inputs.txt> iface
//   node avm_reactor_host.mjs <avm.wasm> <inputs.txt> alloc
//   node avm_reactor_host.mjs <avm.wasm> <inputs.txt> steps <program> <batch>
//
// Exit status is 0 on success and non-zero on any failure. Nothing here can turn a failing run
// into a passing one.

import { WASI } from 'node:wasi';
import { readFile } from 'node:fs/promises';
import process from 'node:process';

// ---------------------------------------------------------------------------
// msgpack decoding. Generic: the wire format, not the schemas.
//
// `bin` comes back as a Uint8Array because that is what a 32-byte field element is on the wire
// (barretenberg's `field::msgpack_pack` writes `pack_bin(32)` big-endian); the transcript
// formatter below is the only thing that decides a 32-byte bin should be rendered as `0x…`.
// ---------------------------------------------------------------------------
class Decoder {
  constructor(bytes) {
    this.u8 = bytes;
    this.dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this.o = 0;
  }
  u8at() { return this.u8[this.o++]; }
  bytes(n) { const s = this.u8.subarray(this.o, this.o + n); this.o += n; return s; }
  str(n) { return new TextDecoder().decode(this.bytes(n)); }
  arr(n) { const a = new Array(n); for (let i = 0; i < n; i++) a[i] = this.next(); return a; }
  map(n) {
    const m = {};
    for (let i = 0; i < n; i++) { const k = this.next(); m[typeof k === 'string' ? k : String(k)] = this.next(); }
    return m;
  }
  u64() {
    const v = this.dv.getBigUint64(this.o, false); this.o += 8;
    return v <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(v) : v;
  }
  i64() {
    const v = this.dv.getBigInt64(this.o, false); this.o += 8;
    return (v <= BigInt(Number.MAX_SAFE_INTEGER) && v >= BigInt(Number.MIN_SAFE_INTEGER)) ? Number(v) : v;
  }
  next() {
    const b = this.u8at();
    if (b <= 0x7f) return b;
    if (b >= 0xe0) return b - 0x100;
    if (b >= 0x80 && b <= 0x8f) return this.map(b & 0x0f);
    if (b >= 0x90 && b <= 0x9f) return this.arr(b & 0x0f);
    if (b >= 0xa0 && b <= 0xbf) return this.str(b & 0x1f);
    switch (b) {
      case 0xc0: return null;
      case 0xc2: return false;
      case 0xc3: return true;
      case 0xc4: return this.bytes(this.u8at());
      case 0xc5: { const n = this.dv.getUint16(this.o, false); this.o += 2; return this.bytes(n); }
      case 0xc6: { const n = this.dv.getUint32(this.o, false); this.o += 4; return this.bytes(n); }
      case 0xca: { const v = this.dv.getFloat32(this.o, false); this.o += 4; return v; }
      case 0xcb: { const v = this.dv.getFloat64(this.o, false); this.o += 8; return v; }
      case 0xcc: return this.u8at();
      case 0xcd: { const v = this.dv.getUint16(this.o, false); this.o += 2; return v; }
      case 0xce: { const v = this.dv.getUint32(this.o, false); this.o += 4; return v; }
      case 0xcf: return this.u64();
      case 0xd0: { const v = this.dv.getInt8(this.o); this.o += 1; return v; }
      case 0xd1: { const v = this.dv.getInt16(this.o, false); this.o += 2; return v; }
      case 0xd2: { const v = this.dv.getInt32(this.o, false); this.o += 4; return v; }
      case 0xd3: return this.i64();
      case 0xd9: return this.str(this.u8at());
      case 0xda: { const n = this.dv.getUint16(this.o, false); this.o += 2; return this.str(n); }
      case 0xdb: { const n = this.dv.getUint32(this.o, false); this.o += 4; return this.str(n); }
      case 0xdc: { const n = this.dv.getUint16(this.o, false); this.o += 2; return this.arr(n); }
      case 0xdd: { const n = this.dv.getUint32(this.o, false); this.o += 4; return this.arr(n); }
      case 0xde: { const n = this.dv.getUint16(this.o, false); this.o += 2; return this.map(n); }
      case 0xdf: { const n = this.dv.getUint32(this.o, false); this.o += 4; return this.map(n); }
      default: throw new Error(`msgpack: unsupported type byte 0x${b.toString(16)} at ${this.o - 1}`);
    }
  }
}

function unpack(bytes) {
  const d = new Decoder(bytes);
  const v = d.next();
  if (d.o !== bytes.length) throw new Error(`msgpack: ${bytes.length - d.o} trailing byte(s)`);
  return v;
}

// ---------------------------------------------------------------------------
// The module's own memory-import limits, read out of the binary. Guessing them is not an option:
// a memory smaller than the declared minimum fails instantiation with a message that looks like a
// toolchain problem. (The reader is `run_wasm_test_binary.mjs`'s, unchanged in behaviour.)
// ---------------------------------------------------------------------------
function readMemoryImportLimits(buf) {
  let o = 0;
  const u8 = new Uint8Array(buf);
  const u32 = (n) => { let v = 0; for (let i = 0; i < n; i++) v |= u8[o++] << (8 * i); return v >>> 0; };
  const leb = () => {
    let result = 0, shift = 0, byte;
    do { byte = u8[o++]; result += (byte & 0x7f) * 2 ** shift; shift += 7; } while (byte & 0x80);
    return result;
  };
  const name = () => { const n = leb(); const s = new TextDecoder().decode(u8.subarray(o, o + n)); o += n; return s; };
  if (u32(4) !== 0x6d736100) throw new Error('not a wasm module (bad magic)');
  u32(4);
  while (o < u8.length) {
    const id = u8[o++];
    const size = leb();
    const end = o + size;
    if (id === 2) {
      const count = leb();
      for (let i = 0; i < count; i++) {
        name(); name();
        const kind = u8[o++];
        if (kind === 0x00) leb();
        else if (kind === 0x01) { o++; const f = u8[o++]; leb(); if (f & 0x01) leb(); }
        else if (kind === 0x02) { const flags = u8[o++]; const min = leb(); const max = flags & 0x01 ? leb() : undefined; return { min, max, shared: !!(flags & 0x02) }; }
        else if (kind === 0x03) { o++; o++; }
        else throw new Error(`unknown import kind ${kind}`);
      }
    }
    o = end;
  }
  return null;
}

// ---------------------------------------------------------------------------
// The reactor
// ---------------------------------------------------------------------------
class Reactor {
  constructor(instance, memory) {
    this.e = instance.exports;
    this.memory = memory;
    this.owned = new Map(); // ptr -> size, so a leak is a fact rather than an impression
  }
  view() { return new Uint8Array(this.memory.buffer); }
  pages() { return this.memory.buffer.byteLength / 65536; }

  alloc(size) {
    const ptr = this.e.avm_alloc(size);
    if (ptr === 0) throw new Error(`avm_alloc(${size}) returned null`);
    this.owned.set(ptr, size);
    return ptr;
  }
  free(ptr) {
    const size = this.owned.get(ptr);
    if (size === undefined) throw new Error(`avm_free of a pointer this host does not own: ${ptr}`);
    this.e.avm_free(ptr, size);
    this.owned.delete(ptr);
  }
  put(bytes) {
    const ptr = this.alloc(bytes.length);
    this.view().set(bytes, ptr);
    return ptr;
  }
  result() {
    const ptr = this.e.avm_result_ptr();
    const len = this.e.avm_result_len();
    if (len === 0) return null;
    // Copied out: the module owns that buffer and the next call overwrites it.
    return this.view().slice(ptr, ptr + len);
  }
  // A status of 0 is success; anything else leaves an AvmReactorError — upstream's ErrorResponse
  // shape, `{message}` — in the result buffer. A revert is NOT an error: it comes back as a
  // TxSimulationResult with a non-zero revertCode, and conflating the two is the confusion M17's
  // trap-versus-revert requirement exists to prevent.
  check(status, what) {
    if (status === 0) return;
    const buf = this.result();
    let message = '(no error payload)';
    try { if (buf) message = unpack(buf).message; } catch { /* fall through to the raw status */ }
    throw new Error(`${what} failed with status ${status}: ${message}`);
  }
  callWithArgs(fn, name, handle, blob) {
    const ptr = this.put(blob);
    let status;
    try { status = handle === null ? fn(ptr, blob.length) : fn(handle, ptr, blob.length); }
    finally { this.free(ptr); }
    this.check(status, name);
    const out = this.result();
    return out ? unpack(out) : null;
  }
  callNoArgs(fn, name, handle) {
    const status = handle === null ? fn() : fn(handle);
    this.check(status, name);
    const out = this.result();
    return out ? unpack(out) : null;
  }
}

// ---------------------------------------------------------------------------
// Rendering. The SAME shape `avm_differential`'s `dump_result` prints, so the two transcripts are
// comparable line for line rather than "equivalent".
// ---------------------------------------------------------------------------
const HEXDIGITS = '0123456789abcdef';
function hexOf(bin) {
  if (!(bin instanceof Uint8Array)) throw new Error(`expected a field element (bin), got ${typeof bin}`);
  let s = '0x';
  for (const b of bin) s += HEXDIGITS[(b >> 4) & 0xf] + HEXDIGITS[b & 0xf];
  return s;
}
const out = [];
function line(key, value) { out.push(`${key} ${value}`); }
function flush() { process.stdout.write(out.join('\n') + '\n'); }

function snapshotLine(prefix, name, snap) {
  line(`${prefix}.${name}`, `${hexOf(snap.root)} size=${snap.nextAvailableLeafIndex}`);
}
function snapshots(prefix, t) {
  snapshotLine(prefix, 'NOTE_HASH_TREE', t.noteHashTree);
  snapshotLine(prefix, 'NULLIFIER_TREE', t.nullifierTree);
  snapshotLine(prefix, 'PUBLIC_DATA_TREE', t.publicDataTree);
  snapshotLine(prefix, 'L1_TO_L2_MESSAGE_TREE', t.l1ToL2MessageTree);
}

function dumpResult(prefix, r) {
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
  line(`${prefix}.publicLogs.count`, r.publicTxEffect.publicLogs.length);
  line(`${prefix}.callFrames.count`, r.callStackMetadata.length);
  if (r.publicInputs) {
    snapshots(`${prefix}.start`, r.publicInputs.startTreeSnapshots);
    snapshots(`${prefix}.end`, r.publicInputs.endTreeSnapshots);
  } else {
    line(`${prefix}.publicInputs`, 'ABSENT');
  }
  for (const k of Object.keys(r.stats).sort()) line(`${prefix}.stat.${k}`, r.stats[k]);
}

// ---------------------------------------------------------------------------
// The inputs file: `<key> <value>` lines from `avm_differential reactorinputs`.
// ---------------------------------------------------------------------------
function parseInputs(text) {
  const kv = new Map();
  for (const l of text.split('\n')) {
    if (!l) continue;
    const i = l.indexOf(' ');
    if (i < 0) continue;
    kv.set(l.slice(0, i), l.slice(i + 1));
  }
  return kv;
}
function blob(kv, key) {
  const hex = kv.get(key);
  if (hex === undefined) throw new Error(`the inputs file has no ${key}`);
  const n = hex.length / 2;
  const b = new Uint8Array(n);
  for (let i = 0; i < n; i++) b[i] = parseInt(hex.substr(i * 2, 2), 16);
  return b;
}
function programs(kv) {
  const n = Number(kv.get('reactorInputs.programs.count'));
  if (!Number.isInteger(n) || n <= 0) throw new Error('the inputs file declares no programs');
  const names = [];
  for (const k of kv.keys()) {
    const m = /^reactorInputs\.([a-z0-9]+)\.address$/.exec(k);
    if (m) names.push(m[1]);
  }
  if (names.length !== n) throw new Error(`the inputs file declares ${n} programs but carries ${names.length}`);
  return names;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
const [wasmPath, inputsPath, mode, ...rest] = process.argv.slice(2);
if (!wasmPath || !inputsPath || !mode) {
  console.error('usage: avm_reactor_host.mjs <avm.wasm> <inputs.txt> <mode> [args...]');
  process.exit(2);
}

const bytes = await readFile(wasmPath);
const limits = readMemoryImportLimits(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
if (!limits) { console.error(`${wasmPath}: no imported memory — this host is for --import-memory modules`); process.exit(2); }
if (limits.shared) { console.error(`${wasmPath}: imports a SHARED memory; this host is single-threaded`); process.exit(3); }
const memory = new WebAssembly.Memory({ initial: limits.min, maximum: limits.max ?? 65536 });

const wasi = new WASI({ version: 'preview1', args: ['avm.wasm'], env: {}, preopens: {}, returnOnExit: true });
const module = await WebAssembly.compile(bytes);

// Fail loudly on an import this host does not know about, rather than letting instantiate report a
// generic LinkError. The reactor's declared surface is env.memory plus wasi_snapshot_preview1.
const known = { env: { memory }, wasi_snapshot_preview1: wasi.getImportObject().wasi_snapshot_preview1 };
const missing = WebAssembly.Module.imports(module).filter(
  (i) => !(i.module in known) || (i.name !== 'memory' && !(i.name in known[i.module])),
);
if (missing.length) {
  console.error(`${wasmPath}: unsupported imports: ${missing.map((i) => `${i.module}.${i.name}`).join(', ')}`);
  process.exit(4);
}

const instance = await WebAssembly.instantiate(module, known);
wasi.initialize(instance);
const R = new Reactor(instance, memory);

const kv = parseInputs(await readFile(inputsPath, 'utf8'));
const names = programs(kv);

function seed(name) {
  const cdb = R.e.avm_contract_db_create();
  const mdb = R.e.avm_merkle_db_create();
  R.callWithArgs(R.e.avm_contract_db_register_class, 'register_class', cdb, blob(kv, `reactorInputs.${name}.setup.class`));
  R.callWithArgs(R.e.avm_contract_db_register_instance, 'register_instance', cdb, blob(kv, `reactorInputs.${name}.setup.instance`));
  R.callWithArgs(R.e.avm_merkle_db_insert_indexed_leaves_nullifier_tree, 'insert_nullifier', mdb, blob(kv, `reactorInputs.${name}.setup.nullifier`));
  R.callWithArgs(R.e.avm_merkle_db_insert_indexed_leaves_public_data_tree, 'insert_public_data', mdb, blob(kv, `reactorInputs.${name}.setup.publicdata`));
  return { cdb, mdb };
}

function simulate(name, key, cdb, mdb) {
  const b = blob(kv, `reactorInputs.${name}.${key}`);
  const ptr = R.put(b);
  let status;
  try { status = R.e.avm_simulate(ptr, b.length, cdb, mdb); } finally { R.free(ptr); }
  R.check(status, `avm_simulate(${name})`);
  return unpack(R.result());
}

try {
  if (mode === 'transcript') {
    line('reactor.version', String(R.e.avm_abi_version()));
    line('reactor.entryPoint', 'simulate');
    line('reactor.programs.count', names.length);
    for (const name of names) {
      const { cdb, mdb } = seed(name);
      line(`program.${name}.address`, kv.get(`reactorInputs.${name}.address`));
      const r = simulate(name, 'fast', cdb, mdb);
      dumpResult(`program.${name}`, r);
      R.e.avm_contract_db_destroy(cdb);
      R.e.avm_merkle_db_destroy(mdb);
    }
    line('reactor.ownedAllocationsAtExit', R.owned.size);
    line('reactor.done', '1');
  } else if (mode === 'hinted') {
    line('reactorHinted.version', String(R.e.avm_abi_version()));
    line('reactorHinted.entryPoint', 'simulate_with_hinted_dbs');
    line('reactorHinted.programs.count', names.length);
    for (const name of names) {
      const b = blob(kv, `reactorInputs.${name}.proving`);
      const ptr = R.put(b);
      let status;
      const t0 = process.hrtime.bigint();
      try { status = R.e.avm_simulate_with_hinted_dbs(ptr, b.length); } finally { R.free(ptr); }
      const t1 = process.hrtime.bigint();
      R.check(status, `avm_simulate_with_hinted_dbs(${name})`);
      const r = unpack(R.result());
      // The hinted entry point builds its own config internally (`PublicSimulatorConfig config{}`
      // in avm_sim_api.cpp), so it collects neither public inputs nor statistics. The fields it
      // DOES produce are compared; the absent ones are named rather than quietly omitted.
      line(`hinted.${name}.revertCode`, r.revertCode);
      line(`hinted.${name}.totalGas`, `${r.gasUsed.totalGas.l2Gas}/${r.gasUsed.totalGas.daGas}`);
      line(`hinted.${name}.publicGas`, `${r.gasUsed.publicGas.l2Gas}/${r.gasUsed.publicGas.daGas}`);
      line(`hinted.${name}.billedGas`, `${r.gasUsed.billedGas.l2Gas}/${r.gasUsed.billedGas.daGas}`);
      line(`hinted.${name}.txFee`, hexOf(r.publicTxEffect.transactionFee));
      line(`hinted.${name}.nullifiers.count`, r.publicTxEffect.nullifiers.length);
      r.publicTxEffect.nullifiers.forEach((n, i) => line(`hinted.${name}.nullifiers.${i}`, hexOf(n)));
      line(`hinted.${name}.dataWrites.count`, r.publicTxEffect.publicDataWrites.length);
      line(`hinted.${name}.publicInputsPresent`, r.publicInputs ? 1 : 0);
      line(`hinted.${name}.inputBytes`, b.length);
      line(`hinted.${name}.resultBytes`, R.e.avm_result_len());
      line(`hinted.${name}.us`, Number((t1 - t0) / 1000n));
    }
    line('reactorHinted.ownedAllocationsAtExit', R.owned.size);
    line('reactorHinted.done', '1');
  } else if (mode === 'iface') {
    // Every method of BOTH exposed interfaces, called for real. An export that is present but
    // never called is a name in a table, not a surface.
    const name = names[0];
    const { cdb, mdb } = seed(name);
    const c = (fn, label, blobKey) => R.callWithArgs(R.e[fn], fn, cdb, blob(kv, blobKey));
    const m = (fn, label, blobKey) => R.callWithArgs(R.e[fn], fn, mdb, blob(kv, blobKey));

    line('iface.program', name);

    // ContractDBInterface — the eight methods.
    const inst = c('avm_contract_db_get_contract_instance', 'get_contract_instance', `reactorInputs.${name}.args.address`);
    line('iface.contractDb.get_contract_instance', inst === null ? 'nil' : hexOf(inst.currentContractClassId));
    const klass = c('avm_contract_db_get_contract_class', 'get_contract_class', `reactorInputs.${name}.args.classId`);
    line('iface.contractDb.get_contract_class', klass === null ? 'nil' : `bytecodeBytes=${klass.packedBytecode.length}`);
    const commitment = c('avm_contract_db_get_bytecode_commitment', 'get_bytecode_commitment', `reactorInputs.${name}.args.classId`);
    line('iface.contractDb.get_bytecode_commitment', commitment === null ? 'nil' : hexOf(commitment));
    const dbgName = c('avm_contract_db_get_debug_function_name', 'get_debug_function_name', `reactorInputs.${name}.args.debugName`);
    line('iface.contractDb.get_debug_function_name', dbgName === null ? 'nil' : dbgName);
    c('avm_contract_db_add_contracts', 'add_contracts', 'reactorInputs.args.emptyDeployment');
    line('iface.contractDb.add_contracts', 'ok');
    R.check(R.e.avm_contract_db_create_checkpoint(cdb), 'contract_db_create_checkpoint');
    line('iface.contractDb.create_checkpoint', 'ok');
    R.check(R.e.avm_contract_db_commit_checkpoint(cdb), 'contract_db_commit_checkpoint');
    line('iface.contractDb.commit_checkpoint', 'ok');
    R.check(R.e.avm_contract_db_create_checkpoint(cdb), 'contract_db_create_checkpoint');
    R.check(R.e.avm_contract_db_revert_checkpoint(cdb), 'contract_db_revert_checkpoint');
    line('iface.contractDb.revert_checkpoint', 'ok');

    // LowLevelMerkleDBInterface — the fourteen methods.
    const roots = R.callNoArgs(R.e.avm_merkle_db_get_tree_roots, 'get_tree_roots', mdb);
    snapshots('iface.merkleDb.get_tree_roots', roots);
    const path = m('avm_merkle_db_get_sibling_path', 'get_sibling_path', 'reactorInputs.args.treeIndex');
    line('iface.merkleDb.get_sibling_path.depth', path.length);
    line('iface.merkleDb.get_sibling_path.0', hexOf(path[0]));
    const low = m('avm_merkle_db_get_low_indexed_leaf', 'get_low_indexed_leaf', 'reactorInputs.args.treeValue');
    line('iface.merkleDb.get_low_indexed_leaf', `present=${low.is_already_present ? 1 : 0} index=${low.index}`);
    const leafValue = m('avm_merkle_db_get_leaf_value', 'get_leaf_value', 'reactorInputs.args.treeIndex');
    line('iface.merkleDb.get_leaf_value', hexOf(leafValue));
    const pdPre = m('avm_merkle_db_get_leaf_preimage_public_data_tree', 'get_leaf_preimage_public_data_tree', 'reactorInputs.args.leafIndex');
    line('iface.merkleDb.get_leaf_preimage_public_data_tree', `slot=${hexOf(pdPre.leaf.slot)} nextIndex=${pdPre.nextIndex}`);
    const nulPre = m('avm_merkle_db_get_leaf_preimage_nullifier_tree', 'get_leaf_preimage_nullifier_tree', 'reactorInputs.args.leafIndex');
    line('iface.merkleDb.get_leaf_preimage_nullifier_tree', `nullifier=${hexOf(nulPre.leaf.nullifier)} nextIndex=${nulPre.nextIndex}`);
    const insPd = m('avm_merkle_db_insert_indexed_leaves_public_data_tree', 'insert_indexed_leaves_public_data_tree', 'reactorInputs.args.publicDataLeaf');
    line('iface.merkleDb.insert_indexed_leaves_public_data_tree', `lowLeaves=${insPd.low_leaf_witness_data.length} insertions=${insPd.insertion_witness_data.length}`);
    const insNul = m('avm_merkle_db_insert_indexed_leaves_nullifier_tree', 'insert_indexed_leaves_nullifier_tree', 'reactorInputs.args.nullifierLeaf');
    line('iface.merkleDb.insert_indexed_leaves_nullifier_tree', `lowLeaves=${insNul.low_leaf_witness_data.length} insertions=${insNul.insertion_witness_data.length}`);
    m('avm_merkle_db_append_leaves', 'append_leaves', 'reactorInputs.args.appendLeaves');
    line('iface.merkleDb.append_leaves', 'ok');
    m('avm_merkle_db_pad_tree', 'pad_tree', 'reactorInputs.args.padTree');
    line('iface.merkleDb.pad_tree', 'ok');
    const idBefore = R.callNoArgs(R.e.avm_merkle_db_get_checkpoint_id, 'get_checkpoint_id', mdb);
    R.check(R.e.avm_merkle_db_create_checkpoint(mdb), 'merkle_db_create_checkpoint');
    const idInside = R.callNoArgs(R.e.avm_merkle_db_get_checkpoint_id, 'get_checkpoint_id', mdb);
    m('avm_merkle_db_append_leaves', 'append_leaves', 'reactorInputs.args.appendLeaves');
    R.check(R.e.avm_merkle_db_revert_checkpoint(mdb), 'merkle_db_revert_checkpoint');
    const afterRevert = R.callNoArgs(R.e.avm_merkle_db_get_tree_roots, 'get_tree_roots', mdb);
    R.check(R.e.avm_merkle_db_create_checkpoint(mdb), 'merkle_db_create_checkpoint');
    R.check(R.e.avm_merkle_db_commit_checkpoint(mdb), 'merkle_db_commit_checkpoint');
    const idAfter = R.callNoArgs(R.e.avm_merkle_db_get_checkpoint_id, 'get_checkpoint_id', mdb);
    line('iface.merkleDb.create_checkpoint', 'ok');
    line('iface.merkleDb.commit_checkpoint', 'ok');
    line('iface.merkleDb.revert_checkpoint', 'ok');
    line('iface.merkleDb.get_checkpoint_id.before', idBefore);
    line('iface.merkleDb.get_checkpoint_id.inside', idInside);
    line('iface.merkleDb.get_checkpoint_id.after', idAfter);
    snapshots('iface.merkleDb.afterRevert', afterRevert);

    // The failure arm: a handle that was never created. It must come back as a STATUS and an
    // upstream-shaped error payload, not as a trap.
    let handleStatus = null, handleMessage = null;
    handleStatus = R.e.avm_merkle_db_get_tree_roots(0xdeadbeef);
    handleMessage = unpack(R.result()).message;
    line('iface.badHandle.status', handleStatus);
    line('iface.badHandle.message', handleMessage);

    // And a malformed input: bytes that are not msgpack at all.
    const junk = R.put(new Uint8Array([0xc1, 0xc1, 0xc1, 0xc1]));
    const junkStatus = R.e.avm_simulate(junk, 4, cdb, mdb);
    const junkMessage = unpack(R.result()).message;
    R.free(junk);
    line('iface.malformedInput.status', junkStatus);
    line('iface.malformedInput.messagePresent', junkMessage.length > 0 ? 1 : 0);

    R.e.avm_contract_db_destroy(cdb);
    R.e.avm_merkle_db_destroy(mdb);
    line('iface.ownedAllocationsAtExit', R.owned.size);
    line('iface.done', '1');
  } else if (mode === 'alloc') {
    // Arbitrary sizes, written and read back, then freed; and repeated simulations, so "does not
    // leak linear memory across repeated simulations" is a measurement of the module's own memory
    // rather than of one allocation.
    const sizes = [0, 1, 7, 8, 63, 64, 65, 1023, 4096, 65535, 65536, 65537, 1048576];
    line('alloc.sizes.count', sizes.length);
    const ptrs = [];
    for (const size of sizes) {
      const ptr = R.alloc(size);
      const n = Math.max(size, 1);
      const pattern = new Uint8Array(n);
      for (let i = 0; i < n; i++) pattern[i] = (i * 7 + size) & 0xff;
      if (size > 0) {
        R.view().set(pattern.subarray(0, size), ptr);
        const back = R.view().subarray(ptr, ptr + size);
        for (let i = 0; i < size; i++) {
          if (back[i] !== pattern[i]) throw new Error(`alloc(${size}): byte ${i} read back as ${back[i]}, wrote ${pattern[i]}`);
        }
      }
      line(`alloc.${size}.distinct`, ptrs.includes(ptr) ? 0 : 1);
      line(`alloc.${size}.nonNull`, ptr === 0 ? 0 : 1);
      ptrs.push(ptr);
    }
    for (const ptr of ptrs) R.free(ptr);
    line('alloc.freedAll', R.owned.size === 0 ? 1 : 0);

    // Free-then-reallocate: the module must hand the memory back rather than growing.
    const before = R.pages();
    for (let round = 0; round < 64; round++) {
      const p = R.alloc(1048576);
      R.free(p);
    }
    line('alloc.pagesBeforeChurn', before);
    line('alloc.pagesAfterChurn', R.pages());

    // Repeated simulations through one instance.
    const name = names[0];
    let firstDigest = null;
    for (let round = 0; round < 32; round++) {
      const { cdb, mdb } = seed(name);
      const r = simulate(name, 'fast', cdb, mdb);
      const digest = `${r.revertCode}/${r.gasUsed.totalGas.l2Gas}/${hexOf(r.publicTxEffect.transactionFee)}`;
      if (firstDigest === null) firstDigest = digest;
      line(`alloc.sim.${round}.identicalToFirst`, digest === firstDigest ? 1 : 0);
      line(`alloc.sim.${round}.pages`, R.pages());
      R.e.avm_contract_db_destroy(cdb);
      R.e.avm_merkle_db_destroy(mdb);
    }
    line('alloc.ownedAllocationsAtExit', R.owned.size);
    line('alloc.done', '1');
  } else if (mode === 'steps') {
    const [program, batchArg, ...flags] = rest;
    if (!program || !batchArg) { console.error('usage: ... steps <program> <batch> [--all]'); process.exit(2); }
    const printAll = flags.includes('--all');
    const batch = Number(batchArg);
    if (!Number.isInteger(batch) || batch <= 0) { console.error('batch must be a positive integer'); process.exit(2); }

    const { cdb, mdb } = seed(program);
    const r = simulate(program, 'faststeps', cdb, mdb);
    const declared = r.executionSteps ? r.executionSteps.length : 0;
    const count = R.e.avm_steps_count();
    line('steps.program', program);
    line('steps.inResultCount', declared);
    line('steps.count', count);
    line('steps.batchSize', batch);

    // The whole stream is ALSO inside the single `avm_simulate` result, under upstream's own
    // `executionSteps` field, at a cost of ZERO further crossings. That is the strongest form of
    // "one call per batch" and it is reported as a fact rather than left implicit.
    line('steps.crossingsForWholeStreamInResult', 0);

    // BATCHED: ceil(count / batch) crossings. PER EVENT: the same export, one step per call —
    // the rejected shape, measured through the SAME code path, so the comparison is between two
    // call patterns and not between two APIs.
    //
    // Three repetitions of each arm, interleaved, and the MINIMUM reported. Interleaved rather
    // than blocked because a machine that gets busier halfway through would otherwise put the
    // whole difference into whichever arm ran second; the minimum because it is the run least
    // disturbed by whatever else the machine was doing. The caller asserts its own idleness
    // precondition before believing any of it.
    const drain = (step) => {
      let crossings = 0, decoded = 0;
      const t0 = process.hrtime.bigint();
      for (let from = 0; from < count; from += step) {
        R.check(R.e.avm_steps_batch(from, step), 'avm_steps_batch');
        decoded += unpack(R.result()).length;
        crossings++;
      }
      const t1 = process.hrtime.bigint();
      return { crossings, decoded, us: Number((t1 - t0) / 1000n) };
    };
    const arms = { batched: [], perEvent: [] };
    for (let rep = 0; rep < 3; rep++) {
      arms.batched.push(drain(batch));
      arms.perEvent.push(drain(1));
    }
    for (const label of ['batched', 'perEvent']) {
      const runs = arms[label];
      runs.forEach((r, i) => line(`steps.${label}.us.${i}`, r.us));
      line(`steps.${label}.crossings`, runs[0].crossings);
      line(`steps.${label}.decoded`, runs[0].decoded);
      line(`steps.${label}.us`, Math.min(...runs.map((r) => r.us)));
    }

    // The first and last record, every field, so "the same records" is a comparison and not a count.
    if (count > 0) {
      R.check(R.e.avm_steps_batch(0, 1), 'avm_steps_batch');
      const first = unpack(R.result())[0];
      R.check(R.e.avm_steps_batch(count - 1, 1), 'avm_steps_batch');
      const last = unpack(R.result())[0];
      const fmt = (s) => `ctx=${s.contextId} pc=${s.pc} op=${s.opcode} l2=${s.gasUsed.l2Gas} da=${s.gasUsed.daGas} addr=${hexOf(s.contractAddress)}`;
      line('steps.first', fmt(first));
      line('steps.last', fmt(last));

      // Every record, in the shape `avm_differential steps` prints one, so the two are comparable
      // PER RECORD rather than by count — this campaign has more than once had a count agree
      // while the thing being counted did not.
      if (printAll) {
        for (let from = 0; from < count; from += batch) {
          R.check(R.e.avm_steps_batch(from, batch), 'avm_steps_batch');
          const window = unpack(R.result());
          window.forEach((rec, j) => line(`steps.record.${from + j}`, fmt(rec)));
        }
      }
    }

    // Out of range must be empty rather than a trap or a wrapped index.
    R.check(R.e.avm_steps_batch(count + 1000, batch), 'avm_steps_batch');
    line('steps.pastEnd.length', unpack(R.result()).length);

    // And the arithmetic at the far end of the range, which is the host's to supply and therefore
    // the module's to survive: `from + count` is size_t on a 32-bit target, so a count near
    // 2^32 - from wraps. Asked for the whole stream from the last record, and from the first, with
    // the largest count a uint32 can carry: both must be a status and a sane window, not a trap.
    R.check(R.e.avm_steps_batch(count - 1, 0xffffffff), 'avm_steps_batch');
    line('steps.hugeCountFromLast.length', unpack(R.result()).length);
    R.check(R.e.avm_steps_batch(0, 0xffffffff), 'avm_steps_batch');
    line('steps.hugeCountFromStart.length', unpack(R.result()).length);

    R.e.avm_contract_db_destroy(cdb);
    R.e.avm_merkle_db_destroy(mdb);
    line('steps.ownedAllocationsAtExit', R.owned.size);
    line('steps.done', '1');
  } else {
    console.error(`avm_reactor_host: unknown mode: ${mode}`);
    process.exit(2);
  }
} catch (e) {
  flush();
  console.error(`avm_reactor_host: ${e && e.stack ? e.stack : e}`);
  process.exit(5);
}

flush();
