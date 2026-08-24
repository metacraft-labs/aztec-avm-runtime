// The module's own declared memory import, read out of the binary.
//
// `avm.wasm` imports its linear memory — `src/CMakeLists.txt` links every barretenberg wasm
// artefact with `-Wl,--import-memory` — and REACTOR-ABI.md records the declaration as
// **minimum 130 pages, maximum 65536, not shared**. The host has to satisfy that minimum, and
// guessing it is not an option: a memory below the declared minimum fails instantiation with a
// LinkError whose text reads like a toolchain problem.
//
// `WebAssembly.Module.imports()` reports the name and the kind but NOT the limits, so the limits
// are read from the import section directly. This is the same reader `run_wasm_test_binary.mjs`
// and `reactor_lib.mjs` use, in TypeScript and with the module/name of the memory import kept
// rather than discarded — the loader asserts that it is `env.memory` and not merely "a memory".

export interface MemoryImport {
  /** The import's module name. For avm.wasm: `env`. */
  readonly module: string;
  /** The import's field name. For avm.wasm: `memory`. */
  readonly name: string;
  /** Declared minimum, in 64 KiB pages. For avm.wasm: 130. */
  readonly min: number;
  /** Declared maximum, in pages, or undefined when the module declares none. */
  readonly max: number | undefined;
  /** True for a `-pthread` build. avm.wasm is single-threaded and this must be false. */
  readonly shared: boolean;
}

const WASM_MAGIC = 0x6d736100;
const SECTION_IMPORT = 2;

/** One page, in bytes. */
export const PAGE_BYTES = 65536;

/**
 * Reads the first imported memory out of a module's import section.
 *
 * Returns `null` when the module imports no memory at all — which for this package is a finding,
 * not a default: a module that owns its memory is not the artefact this host is for.
 */
export function readMemoryImport(bytes: Uint8Array): MemoryImport | null {
  let o = 0;
  const u32 = (): number => {
    let v = 0;
    for (let i = 0; i < 4; i++) v |= bytes[o++] << (8 * i);
    return v >>> 0;
  };
  const leb = (): number => {
    let result = 0;
    let shift = 0;
    let byte: number;
    do {
      byte = bytes[o++];
      result += (byte & 0x7f) * 2 ** shift;
      shift += 7;
    } while (byte & 0x80);
    return result;
  };
  const name = (): string => {
    const n = leb();
    const s = new TextDecoder().decode(bytes.subarray(o, o + n));
    o += n;
    return s;
  };

  if (u32() !== WASM_MAGIC) throw new Error('not a wasm module (bad magic)');
  u32(); // version

  while (o < bytes.length) {
    const id = bytes[o++];
    const size = leb();
    const end = o + size;
    if (id === SECTION_IMPORT) {
      const count = leb();
      for (let i = 0; i < count; i++) {
        const mod = name();
        const fld = name();
        const kind = bytes[o++];
        if (kind === 0x00) {
          leb(); // func: typeidx
        } else if (kind === 0x01) {
          o++; // table: reftype
          const flags = bytes[o++];
          leb();
          if (flags & 0x01) leb();
        } else if (kind === 0x02) {
          const flags = bytes[o++];
          const min = leb();
          const max = flags & 0x01 ? leb() : undefined;
          return { module: mod, name: fld, min, max, shared: (flags & 0x02) !== 0 };
        } else if (kind === 0x03) {
          o += 2; // global: valtype + mut
        } else {
          throw new Error(`unknown import kind ${kind}`);
        }
      }
    }
    o = end;
  }
  return null;
}
