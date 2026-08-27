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
import {
  AvmEngineUnsupported,
  AvmToolchainRegression,
  AvmUnknownImport,
  LEGACY_EH_PROBE,
  TRY_TABLE_PROBE,
  assertExceptionSupport,
  engineAcceptsLegacyEh,
  engineAcceptsTryTable,
  sectionIds,
} from './gate.ts';

// Re-exported so this module's surface is unchanged: `node-host/src/index.ts` and four checks
// import these names from here, and M27's split must not be visible to any of them.
export {
  AvmEngineUnsupported,
  AvmToolchainRegression,
  AvmUnknownImport,
  LEGACY_EH_PROBE,
  TRY_TABLE_PROBE,
  assertExceptionSupport,
  engineAcceptsLegacyEh,
  engineAcceptsTryTable,
  sectionIds,
};


import { Reactor, type ReactorExports } from './reactor.ts';

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
