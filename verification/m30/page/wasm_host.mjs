// wasm_host.mjs — instantiate an import-free wasm module and talk to it through `(ptr, len)`.
//
// Deliberately host-agnostic: it is handed the module's BYTES and knows nothing about where
// they came from, so the page and any headless harness run this same code. Whatever a check
// verifies is therefore what the page does.
//
// ==========================================================================================
// NOTHING IS SUPPLIED, AND WHAT IS REACHED IS COUNTED.
// ==========================================================================================
//
// Both modules DECLARE imports — `noir_wasm` links `wasm-bindgen`, so its 28
// `__wbindgen_placeholder__.*` entries are in the import section whether or not the bare
// `nv_*` path can reach them. Declaring is not reaching. So every declared import is
// satisfied with a function that RECORDS the call and then throws, which makes "the compile
// happened inside WebAssembly with no help from JavaScript" a measurement — the `reached`
// list — rather than a claim about a build flag.
//
// This is `BROWSER-PACKAGING.md` §4's shape: that section's first draft said an import
// "would never be called" and the counter said 1. A shim that counts its own calls is the
// only thing that can tell those two apart.

/**
 * @param {BufferSource} wasmBytes
 * @param {string} label - for diagnostics only
 */
export async function instantiateBare(wasmBytes, label) {
  const module = await WebAssembly.compile(wasmBytes);
  const declared = WebAssembly.Module.imports(module).map(({ module: m, name }) => `${m}.${name}`);
  const reached = [];

  const importObject = {};
  for (const { module: m, name } of WebAssembly.Module.imports(module)) {
    importObject[m] ??= {};
    importObject[m][name] = (...args) => {
      reached.push(`${m}.${name}`);
      throw new Error(`${label}: the module reached ${m}.${name}, which this host does not provide`);
    };
  }

  const { exports } = await WebAssembly.instantiate(module, importObject);

  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  // `exports.memory.buffer` is re-read after every call into wasm: the allocator grows
  // linear memory and growing it DETACHES every view taken before. A cached view produces
  // zero-length reads, which read as an empty answer rather than as an error.
  const view = (ptr, len) => new Uint8Array(exports.memory.buffer, ptr, len);

  return {
    label,
    exports,
    declaredImports: declared,
    /** The imports the module actually CALLED. Empty is the interesting answer. */
    reachedImports: reached,

    /**
     * Write a string into linear memory, call `fn(ptr, len)`, and take the result back out.
     *
     * `alloc`/`free`/`resultLen` name the module's own exports, because the two modules
     * spell them `nv_*` and `ct_*`.
     */
    callWithString(fnName, str, { alloc, free, resultLen, resultIsError }) {
      const encoded = encoder.encode(str);
      const inPtr = exports[alloc](encoded.length);
      view(inPtr, encoded.length).set(encoded);
      let outPtr;
      let bytes;
      let isError = false;
      try {
        outPtr = exports[fnName](inPtr, encoded.length);
        const len = exports[resultLen]();
        isError = resultIsError ? exports[resultIsError]() !== 0 : false;
        // `.slice()` copies out of linear memory before it can be freed or grown.
        bytes = view(outPtr, len).slice();
        exports[free](outPtr, len);
      } finally {
        exports[free](inPtr, encoded.length);
      }
      return { bytes, isError, text: () => decoder.decode(bytes) };
    },
  };
}

/** The `noir_wasm` bare ABI: JSON in, JSON out. */
export function vfsCompiler(host) {
  return {
    host,
    run(request) {
      const result = host.callWithString('nv_compile_vfs', JSON.stringify(request), {
        alloc: 'nv_alloc',
        free: 'nv_free',
        resultLen: 'nv_result_len',
      });
      return JSON.parse(result.text());
    },
  };
}

/**
 * The `noir_tracer_wasm` bare ABI: a `TraceRequest` in, `[u32 LE summaryLen][summary][.ct]`
 * out.
 */
export function tracer(host) {
  return {
    host,
    traceToContainer(request) {
      const result = host.callWithString('ct_trace_source_container', JSON.stringify(request), {
        alloc: 'ct_alloc',
        free: 'ct_free',
        resultLen: 'ct_result_len',
        resultIsError: 'ct_result_is_error',
      });
      if (result.isError) {
        throw new Error(new TextDecoder().decode(result.bytes));
      }
      const summaryLen = new DataView(
        result.bytes.buffer,
        result.bytes.byteOffset,
        4,
      ).getUint32(0, true);
      const summary = JSON.parse(
        new TextDecoder().decode(result.bytes.subarray(4, 4 + summaryLen)),
      );
      const ct = result.bytes.subarray(4 + summaryLen);
      if (ct.length !== summary.container.bytes) {
        throw new Error(
          `the module framed ${ct.length} container bytes but reported ${summary.container.bytes}`,
        );
      }
      const { container, ...trace } = summary;
      return { trace, container, ct };
    },
  };
}

/** sha256 of a byte array, as lowercase hex. Available in a page and in Node 24. */
export async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}
