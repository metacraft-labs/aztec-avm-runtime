// A host for barretenberg's own wasm test binaries, on V8.
//
// WHY THIS EXISTS. barretenberg links every wasm artefact with
// `-Wl,--export-memory,--import-memory,...` (`src/CMakeLists.txt`), so the module
// does not own its linear memory: the host has to supply `env::memory` at
// instantiation. Upstream's runner does that with `wasmtime -Wthreads=y
// -Sthreads=y` (`barretenberg/cpp/scripts/wasmtime.sh`), and **wasmtime 47 has
// removed `-Sthreads`** — it exits with "the `-Sthreads` flag is no longer
// supported". That is why the earlier write-up of the wasi-sdk bump had to say it
// could not execute the resulting test binaries.
//
// It is supplied here instead, on node's `node:wasi` (V8). The host provides:
//
//   env.memory                 a WebAssembly.Memory whose limits are read out of
//                              the module's own import section, so nothing is
//                              guessed and a module that wants more than we give
//                              it fails loudly rather than silently.
//   env.logstr                 barretenberg's stdout/stderr path. Its own
//                              `wasi_stubs.cpp` reroutes fd_write through it.
//   env.throw_or_abort_impl    [[noreturn]] in C++; raises here so the run ends
//                              with a non-zero status instead of continuing.
//
// and everything in `wasi_snapshot_preview1` from `node:wasi`.
//
// Exit status is the guest's. A guest that traps, or that calls
// throw_or_abort_impl, exits non-zero. Nothing here can turn a failing run into
// a passing one — which is the property the checks that call it depend on.
//
// Usage: node run_wasm_test_binary.mjs <module.wasm> [args...]

import { WASI } from 'node:wasi';
import { readFile } from 'node:fs/promises';
import process from 'node:process';


// --- the module's own import section -----------------------------------------
// WebAssembly.Module.imports() does not report memory limits portably, so the
// limits are read straight out of the binary. Guessing them is not an option: a
// memory smaller than the declared minimum makes instantiation fail with a
// message that looks like a toolchain problem.
function readMemoryImportLimits(buf) {
  let o = 0;
  const u8 = new Uint8Array(buf);
  const u32 = (n) => {
    let v = 0;
    for (let i = 0; i < n; i++) v |= u8[o++] << (8 * i);
    return v >>> 0;
  };
  const leb = () => {
    let result = 0, shift = 0, byte;
    do {
      byte = u8[o++];
      result += (byte & 0x7f) * 2 ** shift;
      shift += 7;
    } while (byte & 0x80);
    return result;
  };
  const name = () => {
    const n = leb();
    const s = new TextDecoder().decode(u8.subarray(o, o + n));
    o += n;
    return s;
  };

  if (u32(4) !== 0x6d736100) throw new Error('not a wasm module (bad magic)');
  u32(4); // version

  while (o < u8.length) {
    const id = u8[o++];
    const size = leb();
    const end = o + size;
    if (id === 2) {
      const count = leb();
      for (let i = 0; i < count; i++) {
        const mod = name();
        const fld = name();
        const kind = u8[o++];
        if (kind === 0x00) leb();                       // func: typeidx
        else if (kind === 0x01) {                       // table: reftype + limits
          o++;
          const f = u8[o++];
          leb();
          if (f & 0x01) leb();
        } else if (kind === 0x02) {                     // memory
          const flags = u8[o++];
          const min = leb();
          const max = flags & 0x01 ? leb() : undefined;
          return { module: mod, name: fld, min, max, shared: !!(flags & 0x02) };
        } else if (kind === 0x03) { o++; o++; }         // global: valtype + mut
        else throw new Error(`unknown import kind ${kind}`);
      }
    }
    o = end;
  }
  return null;
}

// ---------------------------------------------------------------------------------------------
// EXITING WITHOUT DISCARDING OUTPUT.
//
// `process.exit()` terminates immediately and DROPS anything still queued on stdout. When fd 1 is
// a file Node writes synchronously and the hazard is invisible; when it is a pipe — a `| tee`, a
// CI log collector, a harness that reads the child's output — it is not, and the observable is a
// process that exits 0 having written a PREFIX of its transcript.
//
// That is the exact shape of M9's short V8 run: `wasm-v8.events` held 39,113 of 39,115 lines with
// an exit status of 0, and the four assertions that then failed read like findings about the AVM
// ("oob emitted no events") rather than like the I/O truncation they were. Draining first costs
// nothing and removes the whole class.
// ---------------------------------------------------------------------------------------------
async function exitAfterFlush(code) {
  await new Promise((resolve) => process.stdout.write('', resolve));
  await new Promise((resolve) => process.stderr.write('', resolve));
  process.exit(code);
}

const wasmPath = process.argv[2];
if (!wasmPath) {
  console.error('usage: run_wasm_test_binary.mjs <module.wasm> [args...]');
  await exitAfterFlush(2);
}
const guestArgs = process.argv.slice(3);
const bytes = await readFile(wasmPath);

const limits = readMemoryImportLimits(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
if (!limits) {
  console.error(`${wasmPath}: no imported memory — this host is for --import-memory modules`);
  await exitAfterFlush(2);
}
if (limits.shared) {
  // A shared memory means the module came from a -pthread (wasm-threads) build and
  // will also want wasi thread_spawn, which node:wasi does not implement. Say so
  // rather than failing later with something that looks unrelated.
  console.error(`${wasmPath}: imports a SHARED memory (a threads build); this host is single-threaded`);
  await exitAfterFlush(3);
}
const memory = new WebAssembly.Memory({
  initial: limits.min,
  maximum: limits.max ?? 65536,
});

const wasi = new WASI({
  version: 'preview1',
  args: [wasmPath.split('/').pop(), ...guestArgs],
  env: process.env,
  preopens: { '/': '/', '.': process.cwd() },
  returnOnExit: true,
});

const view = () => new Uint8Array(memory.buffer);
const cstr = (ptr) => {
  const m = view();
  let end = ptr;
  while (m[end] !== 0) end++;
  return new TextDecoder().decode(m.subarray(ptr, end));
};

let aborted = null;
const env = {
  memory,
  logstr: (ptr) => process.stdout.write(cstr(ptr)),
  throw_or_abort_impl: (ptr) => {
    aborted = cstr(ptr);
    throw new Error(`throw_or_abort_impl: ${aborted}`);
  },
  env_hardware_concurrency: () => 1,
};

const module = await WebAssembly.compile(bytes);

// Fail loudly on an import this host does not know about, rather than letting
// WebAssembly.instantiate report it as a generic LinkError.
const known = { env, wasi_snapshot_preview1: wasi.getImportObject().wasi_snapshot_preview1 };
const missing = WebAssembly.Module.imports(module).filter(
  (i) => !(i.module in known) || (i.name !== 'memory' && !(i.name in known[i.module])),
);
if (missing.length) {
  console.error(`${wasmPath}: unsupported imports: ${missing.map((i) => `${i.module}.${i.name}`).join(', ')}`);
  await exitAfterFlush(4);
}

let code;
try {
  const instance = await WebAssembly.instantiate(module, known);
  code = wasi.start(instance);
} catch (e) {
  process.stdout.write('\n');
  console.error(`${wasmPath}: guest failed: ${e && e.message ? e.message : e}`);
  await exitAfterFlush(aborted === null ? 5 : 6);
}
await exitAfterFlush(code ?? 0);
