// Shared machinery for the hosts that drive `avm.wasm` from Node.
//
// Extracted by M13, which needed all of it a second time. The alternative was a second copy of a
// msgpack decoder, and this file's own header used to warn — correctly — that two implementations
// of an encoding are two things that can disagree; that argument does not stop applying because
// both copies would be ours. `avm_reactor_host.mjs` (M12) and `avm_contract_db_host.mjs` (M13) now
// import the same decoder, the same module-import reader and the same result-buffer protocol, so a
// difference between the two transcripts is a difference in what the module did.
//
// Nothing here encodes. Every input blob crossing into the module is produced by
// `avm_differential`, that is by upstream's own msgpack packers in C++, and arrives as hex. The
// decoder is unavoidable — results have to be read — and it is generic: it knows the wire format,
// not the schemas.

import { WASI } from 'node:wasi';
import { readFile } from 'node:fs/promises';

// ---------------------------------------------------------------------------
// msgpack decoding — RE-EXPORTED, NOT REIMPLEMENTED.
//
// The decoder lives in `node-host/src/msgpack.ts` and this file re-exports it. M13 extracted it
// once already so M12's and M13's hosts could not disagree about an encoding, and that argument
// does not stop applying because the third copy would be in TypeScript: two implementations of a
// wire format are two things that can disagree, and a difference between two transcripts must be a
// difference in what the MODULE did.
//
// Node runs the `.ts` source directly by stripping types, so there is no build step between this
// import and the sources; `node-host/tsconfig.json` sets `erasableSyntaxOnly`, which is what makes
// that safe rather than incidental.
//
// It decodes and never encodes. Every input blob crossing into the module is produced by
// upstream's own msgpack packers in C++ (`avm_differential reactorinputs` emits them as hex), and
// what is decoded here is the WIRE FORMAT rather than the schemas.
// ---------------------------------------------------------------------------
// IMPORTED and then re-exported, not `export … from`: a bare re-export does not bind the names
// LOCALLY, so `Reactor.callWithArgs`'s own `unpack(...)` became a ReferenceError. `just verify-m12`
// caught it — 150 failures across three checks — which is what that regression run was for.
import { Decoder, unpack, hexOf } from '../../node-host/src/msgpack.ts';
export { Decoder, unpack, hexOf };

// ---------------------------------------------------------------------------
// The module's own memory-import limits, read out of the binary. Guessing them is not an option:
// a memory smaller than the declared minimum fails instantiation with a message that looks like a
// toolchain problem. (The reader is `run_wasm_test_binary.mjs`'s, unchanged in behaviour.)
// ---------------------------------------------------------------------------
export function readMemoryImportLimits(buf) {
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
export class Reactor {
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
  // The error payload of the last call, or null. Used by a caller that EXPECTS a failure and wants
  // to read the message rather than have it thrown.
  errorMessage() {
    const buf = this.result();
    if (!buf) return null;
    try { return unpack(buf).message ?? null; } catch { return null; }
  }
  // A status of 0 is success; anything else leaves an AvmReactorError — upstream's ErrorResponse
  // shape, `{message}` — in the result buffer. A revert is NOT an error: it comes back as a
  // TxSimulationResult with a non-zero revertCode, and conflating the two is the confusion M17's
  // trap-versus-revert requirement exists to prevent.
  check(status, what) {
    if (status === 0) return;
    const message = this.errorMessage() ?? '(no error payload)';
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
// Instantiation. Fails loudly on an import the host does not know about, rather than letting
// `instantiate` report a generic LinkError: the reactor's declared surface is `env.memory` plus
// `wasi_snapshot_preview1`, and an unexpected import is a finding.
//
// Exit codes are the caller's contract and are kept identical across hosts: 2 no imported memory,
// 3 a shared memory, 4 an unsupported import.
// ---------------------------------------------------------------------------
export async function instantiateReactor(wasmPath) {
  const bytes = await readFile(wasmPath);
  const limits = readMemoryImportLimits(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
  if (!limits) {
    console.error(`${wasmPath}: no imported memory — this host is for --import-memory modules`);
    process.exit(2);
  }
  if (limits.shared) {
    console.error(`${wasmPath}: imports a SHARED memory; this host is single-threaded`);
    process.exit(3);
  }
  const memory = new WebAssembly.Memory({ initial: limits.min, maximum: limits.max ?? 65536 });
  const wasi = new WASI({ version: 'preview1', args: ['avm.wasm'], env: {}, preopens: {}, returnOnExit: true });
  const module = await WebAssembly.compile(bytes);
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
  return new Reactor(instance, memory);
}

// ---------------------------------------------------------------------------
// Rendering and inputs
// ---------------------------------------------------------------------------
// The inputs file: `<key> <value>` lines from `avm_differential`.
export function parseInputs(text) {
  const kv = new Map();
  for (const l of text.split('\n')) {
    if (!l) continue;
    const i = l.indexOf(' ');
    if (i < 0) continue;
    kv.set(l.slice(0, i), l.slice(i + 1));
  }
  return kv;
}

export function blobFrom(kv, key) {
  const hex = kv.get(key);
  if (hex === undefined) throw new Error(`the inputs file has no ${key}`);
  const n = hex.length / 2;
  const b = new Uint8Array(n);
  for (let i = 0; i < n; i++) b[i] = parseInt(hex.substr(i * 2, 2), 16);
  return b;
}
