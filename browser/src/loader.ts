// `avm.wasm` in a browser: fetched, gated, instantiated.
//
// THE GATE IS M17'S AND IS NOT REWRITTEN HERE. `assertExceptionSupport`, `readMemoryImport` and
// `sectionIds` live in `node-host/` and are pure functions over bytes with no Node import between
// them — so the browser loader reuses them rather than growing a second opinion about what a
// well-formed `avm.wasm` is. What is Node-only in `node-host/src/loader.ts` is exactly two lines,
// `node:wasi` and `node:fs/promises`, and those two are what this file replaces: `createBrowserWasi`
// for the first and `fetch` for the second.
//
// That division is the reason `node-host/` was not simply forked. A second gate would eventually
// disagree with the first about a module both are supposed to reject, and the disagreement would
// surface as "it works in Node".
//
// ===========================================================================================
// DD-11 — WHAT THIS FETCHES, AND WHAT IT MUST NOT.
// ===========================================================================================
//
// One request, for `avm.wasm`. `verify_public_only_page_never_fetches_barretenberg` asserts that
// on the browser's OWN network log — every `Network.requestWillBeSent` the page emitted — and not
// on this comment and not on the bundler's configuration.
//
// `WebAssembly.compileStreaming` is used when the server sends `application/wasm` and the response
// is falling back otherwise, because a static file server that answers `.wasm` as
// `application/octet-stream` is common and `compileStreaming` REFUSES it with a `TypeError` that
// reads like a corrupt module. The fallback is the boring one — `arrayBuffer()` then `compile()` —
// and which one ran is reported, so "streaming" is never claimed without being measured.

import {
  AvmEngineUnsupported,
  AvmToolchainRegression,
  AvmUnknownImport,
  assertExceptionSupport,
  engineAcceptsLegacyEh,
  engineAcceptsTryTable,
  sectionIds,
} from '../../node-host/src/gate.ts';
import { PAGE_BYTES, readMemoryImport, type MemoryImport } from '../../node-host/src/memory.ts';
import { Reactor, type ReactorExports } from '../../node-host/src/reactor.ts';

import { createBrowserWasi, WASI_IMPORT_NAMES, type BrowserWasi } from './wasi.ts';

export {
  AvmEngineUnsupported,
  AvmToolchainRegression,
  AvmUnknownImport,
  assertExceptionSupport,
  engineAcceptsLegacyEh,
  engineAcceptsTryTable,
  sectionIds,
  PAGE_BYTES,
  readMemoryImport,
  Reactor,
  WASI_IMPORT_NAMES,
};
export type { MemoryImport, ReactorExports, BrowserWasi };

export interface CompiledAvm {
  /** The URL it came from. */
  readonly url: string;
  readonly bytes: Uint8Array;
  readonly module: WebAssembly.Module;
  readonly memoryImport: MemoryImport;
  /** `module.name` for every declared import, sorted. Twelve for M23's avm.wasm, thirteen for M27's. */
  readonly declaredImports: readonly string[];
  /** Whether `compileStreaming` was used, or the buffered fallback. Measured, never assumed. */
  readonly streaming: boolean;
  /** Bytes actually transferred, as the page saw them. */
  readonly byteLength: number;
}

/**
 * Fetches and compiles the module, and runs M17's gate.
 *
 * `fetch` is taken as an argument rather than reached for, so a page can hand it a wrapped one and
 * so a test can count requests without a global. It defaults to the ambient `fetch`, which every
 * browser this targets has.
 */
export async function compileAvmFromUrl(
  url: string,
  options: { readonly fetch?: typeof globalThis.fetch } = {},
): Promise<CompiledAvm> {
  const f = options.fetch ?? globalThis.fetch;
  const response = await f(url);
  if (!response.ok) {
    throw new AvmToolchainRegression(`fetching ${url} answered ${response.status} ${response.statusText}`);
  }
  const contentType = response.headers.get('content-type') ?? '';
  let module: WebAssembly.Module;
  let bytes: Uint8Array;
  let streaming = false;

  // The bytes are needed either way — the gate reads the module's sections — so the streaming path
  // is a `tee`, not a saving of the buffer. What it saves is the compile, which is the expensive
  // half on a 1.6 MB module.
  const buffer = await response.arrayBuffer();
  bytes = new Uint8Array(buffer);
  assertExceptionSupport(bytes);

  if (contentType.startsWith('application/wasm') && typeof WebAssembly.compileStreaming === 'function') {
    // Re-issued from the SAME bytes rather than from a second request: `Response` is single-use and
    // a second `fetch` would double the network log this milestone's central check reads.
    module = await WebAssembly.compileStreaming(
      new Response(bytes, { headers: { 'content-type': 'application/wasm' } }),
    );
    streaming = true;
  } else {
    module = await WebAssembly.compile(bytes as BufferSource);
  }

  const memoryImport = readMemoryImport(bytes);
  if (!memoryImport) {
    throw new AvmToolchainRegression(
      `${url} imports no memory. This host is for --import-memory modules, which is how ` +
        'barretenberg links every wasm artefact; a module that owns its memory is a different build.',
    );
  }
  if (memoryImport.module !== 'env' || memoryImport.name !== 'memory') {
    throw new AvmToolchainRegression(
      `${url} imports its memory as ${memoryImport.module}.${memoryImport.name}, not env.memory`,
    );
  }
  if (memoryImport.shared) {
    throw new AvmToolchainRegression(
      `${url} imports a SHARED memory, i.e. a -pthread build. It would also want wasi ` +
        'thread_spawn, which this shim does not implement, and the AVM reactor is single-threaded.',
    );
  }

  const declaredImports = WebAssembly.Module.imports(module)
    .map((i) => `${i.module}.${i.name}`)
    .sort();

  return { url, bytes, module, memoryImport, declaredImports, streaming, byteLength: bytes.byteLength };
}

export interface InstantiateOptions {
  /** DD-4. Milliseconds since the epoch, from the caller's clock. Required; see `wasi.ts`. */
  readonly nowMs: () => number;
  /** Pages to start with. Defaults to the module's own declared minimum (130), the only certainly-right number. */
  readonly initialPages?: number;
  /** Maximum pages. Defaults to the module's declared maximum, or 65536. */
  readonly maximumPages?: number;
  /** The guest's environment. Empty by default: the AVM reads none of it. */
  readonly env?: Readonly<Record<string, string>>;
  /** Where the guest's `fd_write` goes. */
  readonly writeLine?: (fd: number, line: string) => void;
  /** DD-3. Fills a buffer with random bytes for `random_get`. See `wasi.ts`. */
  readonly randomBytes?: (out: Uint8Array) => void;
}

export interface InstantiatedAvm {
  readonly reactor: Reactor;
  readonly wasi: BrowserWasi;
}

/**
 * Instantiates one reactor.
 *
 * The import object is `env.memory` plus every `wasi_snapshot_preview1` function this shim
 * implements — eleven for M12's, M13's and M23's modules and twelve for M27's, whose grumpkin
 * exports make `random_get` reachable through a vtable (see `wasi.ts`).
 *
 * Every declared import is checked against it BY NAME first, so an import the module
 * grew is reported as itself rather than as a generic `LinkError` — M17's rule, kept because the
 * failure mode it prevents is worse in a browser, where there is no stack to read.
 */
export async function instantiateAvm(
  compiled: CompiledAvm,
  options: InstantiateOptions,
): Promise<InstantiatedAvm> {
  const initial = options.initialPages ?? compiled.memoryImport.min;
  if (initial < compiled.memoryImport.min) {
    throw new AvmToolchainRegression(
      `asked for ${initial} pages but ${compiled.url} declares a minimum of ${compiled.memoryImport.min}; ` +
        'instantiation would fail with a LinkError that reads like a toolchain problem',
    );
  }
  const memory = new WebAssembly.Memory({
    initial,
    maximum: options.maximumPages ?? compiled.memoryImport.max ?? 65536,
  });

  const wasi = createBrowserWasi({
    nowMs: options.nowMs,
    ...(options.writeLine ? { writeLine: options.writeLine } : {}),
    ...(options.env ? { env: options.env } : {}),
    ...(options.randomBytes ? { randomBytes: options.randomBytes } : {}),
  });
  wasi.bind(memory);

  const supplied: Record<string, Record<string, unknown>> = {
    env: { memory },
    wasi_snapshot_preview1: wasi.imports,
  };

  const unknown = WebAssembly.Module.imports(compiled.module)
    .filter((i) => !(i.module in supplied) || !(i.name in supplied[i.module]))
    .map((i) => `${i.module}.${i.name}`);
  if (unknown.length) throw new AvmUnknownImport(unknown);

  const instance = await WebAssembly.instantiate(compiled.module, supplied as unknown as WebAssembly.Imports);

  // A reactor has `_initialize`, not `_start`. Node's `WASI.initialize` calls it and throws if the
  // module is a command instead; here that distinction is made by hand, and the throw is kept,
  // because a WASI *command* — `vm2_sim_tests` is one, with nineteen imports — would otherwise sit
  // in a page doing nothing while looking instantiated.
  const exports = instance.exports as unknown as Record<string, unknown>;
  if (typeof exports._start === 'function') {
    throw new AvmToolchainRegression(
      `${compiled.url} exports _start: it is a WASI COMMAND, not a reactor. This host drives a ` +
        'reactor, initialised once through _initialize and then called through its exports.',
    );
  }
  if (typeof exports._initialize !== 'function') {
    throw new AvmToolchainRegression(`${compiled.url} exports neither _initialize nor _start`);
  }
  (exports._initialize as () => void)();

  return { reactor: new Reactor(exports as unknown as ReactorExports, memory, compiled.memoryImport), wasi };
}

/** Bytes of linear memory currently mapped by an instance. */
export function memoryBytes(pages: number): number {
  return pages * PAGE_BYTES;
}
