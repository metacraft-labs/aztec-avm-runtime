// The toolchain and engine gate, and the three ways a module can be wrong before it is run.
//
// SPLIT OUT OF `loader.ts` BY M27 AND NOT REWRITTEN. Everything here is a pure function over
// bytes: no `node:wasi`, no `node:fs`, nothing a browser cannot follow. M27 needs exactly this
// half — a browser fetches the module instead of reading it and supplies its own WASI, but the
// question "is this a module we are willing to run" has one answer and should have one
// implementation. A second gate in `browser/` would eventually disagree with this one about a
// module both are supposed to reject, and the disagreement would surface as "it works in Node".
//
// The reasoning behind the gate itself is in `loader.ts`'s header, where it was written and where
// it still belongs: it is about `avm.wasm`, not about this file.

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
