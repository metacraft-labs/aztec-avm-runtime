// The loader: `avm.wasm` under `node:wasi`, and the toolchain gate that runs before it.
//
// ===========================================================================================
// THE REUSE QUESTION, ASKED BEFORE THIS FILE WAS WRITTEN, AND ANSWERED AGAINST THE DELIVERABLE
// ===========================================================================================
//
// M17's first deliverable says "bb.js already ships a shim for exactly this import set to run
// barretenberg.wasm; check whether it can be reused before writing one". It was checked, by
// enumeration over the whole fork BY SUBDIRECTORY and over the published `@aztec/*` packages, and
// the premise is FALSE. Measured, name by name, against the eleven WASI imports REACTOR-ABI.md
// records for this artefact:
//
//   bb.js `BarretenbergWasmBase.getImportObj`   2 of 11  (clock_time_get, proc_exit)
//     — and it supplies three imports avm.wasm does NOT have: `random_get` (whose ABSENCE
//       REACTOR-ABI.md asserts by name), `env.logstr` and `env.throw_or_abort_impl`. That is not
//       a near miss: barretenberg.wasm is hand-stubbed, with its own `wasi_stubs.cpp` routing
//       fd_write through `env.logstr`, and avm.wasm is a genuine wasi-sdk 33 REACTOR whose libc
//       startup and stdio come from wasi-libc. The two import sets are different because the two
//       artefacts are built differently.
//   @aztec/sqlite3mc-wasm (vendored Emscripten glue)   8 of 11 (no fd_prestat_get,
//     fd_prestat_dir_name, proc_exit) — and Emscripten-internal, not an exported API.
//   node:wasi (Node's own)                    11 of 11.
//
// AND UPSTREAM ITSELF ALREADY DOES THIS, in a directory PARALLEL to bb.js — which is where all
// seven of this campaign's reuse misses were found. `barretenberg/cpp/scripts/
// run_wasm_bench_node.mjs` drives a `--import-memory` WASI barretenberg module from Node with
// `new WASI({ version: 'preview1' })` and `imports.env.memory = memory`. That is this loader's
// shape, and it is Aztec's rather than ours.
//
// So: the WASI half is REUSED — from `node:wasi`, as upstream does — and NOT from bb.js. What is
// ours is exactly one import, `env.memory`, sized from the module's own declared minimum.
//
// ===========================================================================================
// THE TOOLCHAIN GATE
// ===========================================================================================
//
// Two different regressions are guarded, because they fail differently and only one of them is
// what the deliverable named:
//
//   1. EXCEPTIONS COMPILED OUT. Under barretenberg's old `BB_NO_EXCEPTIONS` shim (`#define try
//      if(true)`) every C++ throw silently becomes `std::abort()`, so every AVM revert becomes a
//      trap — the exact confusion this milestone's error surface exists to prevent. Observable:
//      the module has NO TAG SECTION. `avm.wasm` as built has one, of size 3, holding one tag.
//   2. THE LEGACY EXCEPTION ENCODING. wasi-sdk 33's clang emits the final `try_table` encoding; a
//      toolchain that fell back to the legacy `try`/`catch`/`delegate` opcodes would still work
//      today and would stop working on an engine that has dropped them.
//
// AND THE DELIVERABLE'S PREMISE ABOUT (2) IS FALSE ON THE PINNED NODE, MEASURED. Node 24.19.0
// carries V8 13.6.233.17-node.51, whose `--experimental-wasm-legacy-eh` DEFAULTS TO ON: a
// hand-encoded legacy module validates AND RUNS. So "it loaded, therefore it is try_table" is not
// an argument on this engine, and a check that only loaded the module would be a check that
// cannot fail. The guard is therefore run with legacy support switched OFF —
// `node --no-experimental-wasm-legacy-eh` — where the legacy probe is rejected with
// `Invalid opcode 0x06` and `avm.wasm` still compiles. `engineAcceptsLegacyEh()` below reports
// which engine this is, so the caller can say which of the two statements it is entitled to make.

import { WASI } from 'node:wasi';
import { readFile } from 'node:fs/promises';

import { PAGE_BYTES, readMemoryImport, type MemoryImport } from './memory.ts';
import { Reactor, type ReactorExports } from './reactor.ts';

/** The module was built by a toolchain that cannot produce a working AVM. */
export class AvmToolchainRegression extends Error {
  readonly kind = 'toolchain-regression' as const;
  constructor(message: string) {
    super(message);
    this.name = 'AvmToolchainRegression';
  }
}

/** The engine cannot run this module's exception encoding. */
export class AvmEngineUnsupported extends Error {
  readonly kind = 'engine-unsupported' as const;
  constructor(message: string) {
    super(message);
    this.name = 'AvmEngineUnsupported';
  }
}

/** The module declares an import this host does not supply. */
export class AvmUnknownImport extends Error {
  readonly kind = 'unknown-import' as const;
  readonly imports: readonly string[];
  constructor(imports: readonly string[]) {
    super(`avm.wasm declares imports this host does not supply: ${imports.join(', ')}`);
    this.name = 'AvmUnknownImport';
    this.imports = imports;
  }
}

// ---------------------------------------------------------------------------------------------
// The two hand-encoded exception-handling probes.
//
// Hand-encoded rather than assembled with `wat2wasm`, so the gate depends on nothing outside the
// engine it is measuring. Both are the same module — one tag, one exported `probe(): i32` that
// throws and catches its own exception and returns 1 — differing ONLY in the encoding of the
// exception handler, which is the single variable the gate is about.
// ---------------------------------------------------------------------------------------------
const WASM_HEADER = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
// type: [] -> [i32] (the function) and [] -> [] (the tag)
const PROBE_TYPE = [0x01, 0x08, 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x00, 0x00];
const PROBE_FUNC = [0x03, 0x02, 0x01, 0x00];
const PROBE_TAG = [0x0d, 0x03, 0x01, 0x00, 0x01];
const PROBE_EXPORT = [0x07, 0x09, 0x01, 0x05, 0x70, 0x72, 0x6f, 0x62, 0x65, 0x00, 0x00];

function probeModule(body: readonly number[]): Uint8Array<ArrayBuffer> {
  const fn = [0x00, ...body]; // no locals
  return new Uint8Array([
    ...WASM_HEADER,
    ...PROBE_TYPE,
    ...PROBE_FUNC,
    ...PROBE_TAG,
    ...PROBE_EXPORT,
    0x0a,
    fn.length + 2,
    0x01,
    fn.length,
    ...fn,
  ]);
}

/** block { try_table (catch_all -> block) { throw 0 } }; i32.const 1 — the FINAL encoding. */
export const TRY_TABLE_PROBE: Uint8Array<ArrayBuffer> = probeModule([
  0x02, 0x40, // block (empty)
  0x1f, 0x40, 0x01, 0x02, 0x00, // try_table (empty) with one catch_all -> the enclosing block
  0x08, 0x00, // throw tag 0
  0x0b, // end try_table
  0x0b, // end block
  0x41, 0x01, // i32.const 1
  0x0b, // end function
]);

/** try (result i32) { throw 0 } catch_all { i32.const 1 } — the LEGACY encoding. */
export const LEGACY_EH_PROBE: Uint8Array<ArrayBuffer> = probeModule([
  0x06, 0x7f, // try (result i32)
  0x08, 0x00, // throw tag 0
  0x19, // catch_all
  0x41, 0x01, // i32.const 1
  0x0b, // end try
  0x0b, // end function
]);

/** True when this engine still accepts the legacy encoding. Node 24.19's V8 13.6 does. */
export function engineAcceptsLegacyEh(): boolean {
  return WebAssembly.validate(LEGACY_EH_PROBE);
}

/** True when this engine accepts the final `try_table` encoding. */
export function engineAcceptsTryTable(): boolean {
  return WebAssembly.validate(TRY_TABLE_PROBE);
}

const SECTION_TAG = 13;

/** Every top-level section id present in a module, in order. */
export function sectionIds(bytes: Uint8Array): number[] {
  let o = 8;
  const ids: number[] = [];
  const leb = (): number => {
    let r = 0;
    let s = 0;
    let x: number;
    do {
      x = bytes[o++];
      r += (x & 0x7f) * 2 ** s;
      s += 7;
    } while (x & 0x80);
    return r;
  };
  while (o < bytes.length) {
    ids.push(bytes[o++]);
    // `o += leb()` would be wrong: JavaScript reads the left operand before evaluating the right,
    // so leb()'s own advance of `o` would be discarded and the walk would desynchronise.
    const size = leb();
    o += size;
  }
  return ids;
}

/**
 * The gate, run before the module is compiled.
 *
 * Throws `AvmEngineUnsupported` if this engine cannot run the final encoding at all, and
 * `AvmToolchainRegression` if the module carries no exception tag — which is what a build with
 * exceptions compiled out looks like from the outside.
 */
export function assertExceptionSupport(bytes: Uint8Array): void {
  if (!engineAcceptsTryTable()) {
    throw new AvmEngineUnsupported(
      'this engine rejects the final WebAssembly exception encoding (try_table). ' +
        'avm.wasm needs it: wasi-sdk 33 compiles the AVM’s 327 throw/catch sites with it, ' +
        'and without exceptions every AVM revert becomes an abort.',
    );
  }
  if (!sectionIds(bytes).includes(SECTION_TAG)) {
    throw new AvmToolchainRegression(
      'the module has no tag section, so it was built with exceptions compiled out. ' +
        'Under that build every C++ throw is std::abort(), so every AVM revert would reach the ' +
        'host as a trap — a transaction outcome reported as a runtime bug.',
    );
  }
}

export interface CompiledAvm {
  readonly path: string;
  readonly bytes: Uint8Array<ArrayBuffer>;
  readonly module: WebAssembly.Module;
  readonly memoryImport: MemoryImport;
  /** `module.name` for every declared import, sorted. Twelve for avm.wasm. */
  readonly declaredImports: readonly string[];
}

/**
 * Reads and compiles the module, and runs the gate. Compilation is the expensive half — a block
 * of transactions must not pay it per transaction — so it is separated from instantiation and
 * `ModuleCache` in `pool.ts` keeps the result.
 */
export async function compileAvm(path: string): Promise<CompiledAvm> {
  const bytes = await readFile(path);
  assertExceptionSupport(bytes);

  const memoryImport = readMemoryImport(bytes);
  if (!memoryImport) {
    throw new AvmToolchainRegression(
      `${path} imports no memory. This host is for --import-memory modules, which is how ` +
        'barretenberg links every wasm artefact; a module that owns its memory is a different build.',
    );
  }
  if (memoryImport.module !== 'env' || memoryImport.name !== 'memory') {
    throw new AvmToolchainRegression(
      `${path} imports its memory as ${memoryImport.module}.${memoryImport.name}, not env.memory`,
    );
  }
  if (memoryImport.shared) {
    throw new AvmToolchainRegression(
      `${path} imports a SHARED memory, i.e. a -pthread build. It would also want ` +
        'wasi thread_spawn, which node:wasi does not implement, and the AVM reactor is ' +
        'single-threaded by construction.',
    );
  }

  const module = await WebAssembly.compile(bytes);
  const declaredImports = WebAssembly.Module.imports(module)
    .map((i) => `${i.module}.${i.name}`)
    .sort();

  return { path, bytes, module, memoryImport, declaredImports };
}

export interface InstantiateOptions {
  /**
   * Pages to give the instance initially. Defaults to the module's own declared minimum, which is
   * the only number that is certainly right; anything smaller fails instantiation and anything
   * larger is a policy choice the caller can make.
   */
  readonly initialPages?: number;
  /** Maximum pages. Defaults to the module's declared maximum, or 65536. */
  readonly maximumPages?: number;
  /** Environment handed to WASI. Empty by default: the AVM reads none of it. */
  readonly env?: Readonly<Record<string, string | undefined>>;
}

/**
 * Instantiates one reactor.
 *
 * The import object is exactly twelve entries: the eleven `wasi_snapshot_preview1` functions from
 * `node:wasi` and `env.memory`. Every declared import is checked against it BY NAME first, so an
 * import the module grew is reported as itself rather than as a generic LinkError.
 */
export async function instantiateAvm(compiled: CompiledAvm, options: InstantiateOptions = {}): Promise<Reactor> {
  const initial = options.initialPages ?? compiled.memoryImport.min;
  if (initial < compiled.memoryImport.min) {
    throw new AvmToolchainRegression(
      `asked for ${initial} pages but ${compiled.path} declares a minimum of ${compiled.memoryImport.min}; ` +
        'instantiation would fail with a LinkError that reads like a toolchain problem',
    );
  }
  const memory = new WebAssembly.Memory({
    initial,
    maximum: options.maximumPages ?? compiled.memoryImport.max ?? 65536,
  });

  const wasi = new WASI({
    version: 'preview1',
    args: ['avm.wasm'],
    env: options.env ?? {},
    preopens: {},
    returnOnExit: true,
  });

  // `getImportObject()`'s RETURN TYPE depends on which declaration of `node:wasi` wins, and this
  // package is compiled under two projects that answer differently. Its own `types/` declares it
  // as `{ wasi_snapshot_preview1: … }`; @types/node, which is present in any project that
  // depends on the @aztec packages, declares it as `object`. Under the second, reading the
  // property is TS2339 — found when `orchestration/` type-checked these sources for M18. The
  // shape is asserted here once, so the value is the same under either declaration and neither
  // project has to be told which one to believe.
  const importObject = wasi.getImportObject() as {
    wasi_snapshot_preview1: Record<string, unknown>;
  };
  const supplied: Record<string, Record<string, unknown>> = {
    env: { memory },
    wasi_snapshot_preview1: importObject.wasi_snapshot_preview1,
  };

  const unknown = WebAssembly.Module.imports(compiled.module)
    .filter((i) => !(i.module in supplied) || !(i.name in supplied[i.module]))
    .map((i) => `${i.module}.${i.name}`);
  if (unknown.length) throw new AvmUnknownImport(unknown);

  const instance = await WebAssembly.instantiate(compiled.module, supplied as unknown as WebAssembly.Imports);
  // A reactor has `_initialize`, not `_start`. `WASI.initialize` calls it and throws if the module
  // is a command instead, which is the distinction this whole host rests on.
  wasi.initialize(instance);

  return new Reactor(instance.exports as unknown as ReactorExports, memory, compiled.memoryImport);
}

/** Bytes of linear memory currently mapped by an instance. */
export function memoryBytes(pages: number): number {
  return pages * PAGE_BYTES;
}
