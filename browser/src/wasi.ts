// The browser's `wasi_snapshot_preview1` — TWELVE functions for M27's module, and not one more.
//
// ===========================================================================================
// TWELVE, NOT ELEVEN, AND THE TWELFTH ARRIVED WITH M27'S OWN OVERLAY.
// ===========================================================================================
//
// `REACTOR-ABI.md` records ELEVEN WASI imports for `avm.wasm` and asserts the ABSENCE of
// `random_get` BY NAME. That is true of M12's, M13's and M23's modules and it is FALSE of M27's,
// and the reason is this milestone's own thirteenth overlay: exporting `avm_grumpkin_mul` /
// `avm_grumpkin_add` makes barretenberg's `ecc` curve code reachable, and with it
// `bb::numeric::RandomEngine`. Traced through the unstripped module's disassembly rather than
// guessed: `wasi_snapshot_preview1.random_get` <- `__wasi_random_get` <- `__getentropy` <-
// `RandomEngine::get_random_uint{64,128,256}()`. Those are VIRTUAL, so the call sites are
// `call_indirect` through a vtable and `--gc-sections` cannot prove them dead however unreachable
// they are in practice.
//
// AND IT IS CALLED EXACTLY ONCE, BY THE FIRST `avm_grumpkin_mul`, AND NOT BY ANYTHING ELSE.
// The first draft of this comment asserted the call count would be ZERO, on the reasoning that
// nothing this runtime exercises needs randomness. The counter said **1** after a transaction, so
// the reasoning was wrong; the counter was then read at four points in one process:
//
//     after instantiate      random_get 0
//     after poseidon2 hash   random_get 0
//     after grumpkin MUL     random_get 1     <- here, and only here
//     after grumpkin ADD     random_get 1
//
// `mul_const_time` blinds, and barretenberg's `RandomEngine` seeds itself once, lazily, on first
// use. So: not at `_initialize`, not in the AVM, not in the hash, and once per instance in the
// curve multiply. The blinding is internal and does not move the result —
// `test_browser_crypto_matches_bb_js` gets identical points from bb.js over the whole corpus.
//
// THE POINT IS NOT THE NUMBER, IT IS THAT THE NUMBER WAS MEASURED. "It imports random_get but
// never calls it" was a plausible sentence that was FALSE, and the only reason it did not ship is
// that this shim counts. `CAMPAIGN-BRIEF.md`'s rule is that anything asserted must be read from the
// artefact; a WASI shim is a place where that is cheap, so it does it.
//
// DD-3 — "injected randomness where any is needed" — is why `randomBytes` is an OPTION rather than
// an unconditional `crypto.getRandomValues`. A host that wants a deterministic module passes its
// own; the default is the platform's CSPRNG, which is the right answer for a page.
//
// ===========================================================================================
// THE REUSE QUESTION WAS ASKED IN M17 AND ITS ANSWER IS NOT REOPENED HERE.
// ===========================================================================================
//
// `NODE-HOST.md` records the enumeration, name by name, against the eleven imports
// `REACTOR-ABI.md` declares for M12's artefact:
//
//   bb.js `BarretenbergWasmBase.getImportObj`         2 of 11  (clock_time_get, proc_exit)
//   @aztec/sqlite3mc-wasm's Emscripten glue           8 of 11  (and Emscripten-internal)
//   node:wasi                                        11 of 11  — and Node-only
//
// So M17 reused `node:wasi` and a browser cannot follow it there. What this file is, is the
// *browser half* of a decision that was already made: the same eleven names, the same twelfth
// `env.memory`, satisfied by ~200 lines instead of by a Node builtin. It is NOT a general WASI
// implementation and does not try to be one — `REACTOR-ABI.md` records that the module imports no
// `path_*`, no `sock_*`, no `poll_oneoff`, no `random_get` and no `fd_pread`/`fd_pwrite`, so a
// general implementation would be nine-tenths dead code that nothing could exercise.
//
// ===========================================================================================
// DD-4: THE CLOCK IS INJECTED, ALWAYS — AND THAT REACHES INTO WASI.
// ===========================================================================================
//
// `clock_time_get` is a clock read. It is the one place in this package where the host would
// naturally reach for `Date.now()`, and DD-4 says no source file in the runtime does that. So
// `nowMs` is a REQUIRED argument of `createBrowserWasi`: there is no default, and a caller who
// wants the wall clock has to say so by passing upstream's `DateProvider.now`. That is not
// ceremony — `smoke_browser_produces_block_on_real_timer` runs the page in a THROTTLED background
// tab, where a runtime that assumed even ticks produces a lumpy chain and blames itself.
//
// ===========================================================================================
// WHAT THE MODULE ACTUALLY CALLS, AND WHY THE REST STILL EXIST.
// ===========================================================================================
//
// `REACTOR-ABI.md` classifies the eleven: three are libc startup (`environ_get`,
// `environ_sizes_get`, `clock_time_get`), seven are stdio, and one is the abort path
// (`proc_exit`). In practice the AVM's own `vinfo` logging reaches `fd_write` on fd 2 and nothing
// else is called on a successful run. They are all implemented anyway because an IMPORT that is
// declared and not supplied is a `LinkError` at instantiation, not a lazy failure — the module
// cannot be instantiated with ten.

/** WASI `errno`. Only the values this shim can return are named. */
export const WASI_ESUCCESS = 0;
export const WASI_EBADF = 8;
export const WASI_EINVAL = 28;
export const WASI_ENOSYS = 52;
export const WASI_ENOTSUP = 58;

/** `filetype` — 2 is `CHARACTER_DEVICE`, which is what a tty-ish stdio fd is. */
const FILETYPE_CHARACTER_DEVICE = 2;
/** `rights`: enough for a write to be attempted. The AVM never inspects them. */
const RIGHTS_ALL = 0xffff_ffffn;

/** The three standard descriptors, and nothing else is open. */
export const STDIN = 0;
export const STDOUT = 1;
export const STDERR = 2;

export interface BrowserWasiOptions {
  /**
   * DD-4. Milliseconds since the epoch, from the caller's injected clock. There is no default:
   * `Date.now` is not called anywhere in this package and a check asserts that.
   */
  readonly nowMs: () => number;
  /**
   * Where the guest's `fd_write` goes. Defaults to collecting lines; a page that wants them on the
   * console passes a sink. The AVM writes its `vinfo` logging here and a browser has no stderr.
   */
  readonly writeLine?: (fd: number, line: string) => void;
  /** The guest's environment. Empty by default: the AVM reads none of it. */
  readonly env?: Readonly<Record<string, string>>;
  /**
   * DD-3. Fills `out` with random bytes. Defaults to `crypto.getRandomValues`.
   *
   * M27's module IMPORTS `random_get` and (measured) never calls it — see the header. The option
   * exists so that a host which wants a module it can prove deterministic can supply its own, and
   * so that the default is a decision rather than an accident.
   */
  readonly randomBytes?: (out: Uint8Array) => void;
}

/** The module called `proc_exit`. A reactor that exits has aborted. */
export class WasiProcExit extends Error {
  readonly kind = 'wasi-proc-exit' as const;
  readonly code: number;
  constructor(code: number) {
    super(
      `avm.wasm called proc_exit(${code}). A reactor does not exit: this is the abort path, which ` +
        'is what a C++ std::abort() or an unhandled exception reaches. The instance is unusable.',
    );
    this.name = 'WasiProcExit';
    this.code = code;
  }
}

export interface BrowserWasi {
  /** The import object's `wasi_snapshot_preview1` namespace. Twelve functions; see the header. */
  readonly imports: Record<string, (...args: never[]) => number>;
  /** Called once after instantiation, with the instance's memory. */
  bind(memory: WebAssembly.Memory): void;
  /** Everything the guest wrote, in order, as `[fd, text]`. */
  readonly written: ReadonlyArray<readonly [number, string]>;
  /** Times each function was called. Read by the checks; a zero here is a real statement. */
  readonly calls: Readonly<Record<string, number>>;
}

/** The twelve names, frozen, so a drift on either side of the boundary is visible. */
export const WASI_IMPORT_NAMES: readonly string[] = Object.freeze([
  'clock_time_get',
  'environ_get',
  'environ_sizes_get',
  'fd_close',
  'fd_fdstat_get',
  'fd_prestat_dir_name',
  'fd_prestat_get',
  'fd_read',
  'fd_seek',
  'fd_write',
  'proc_exit',
  // M27's module only; see the header. Present in the list because the loader checks every
  // DECLARED import against what this shim supplies, and a module that declares it must find it.
  'random_get',
]);

export function createBrowserWasi(options: BrowserWasiOptions): BrowserWasi {
  const { nowMs } = options;
  if (typeof nowMs !== 'function') {
    // A VALUE CHECK, not a type. Node and every bundler strip types before this runs, so a
    // `readonly nowMs: () => number` is gone by the time a caller gets here; DD-4 is worth a
    // run-time refusal for the reason `ct-host/src/config.ts` gives at length.
    throw new TypeError('createBrowserWasi requires an injected clock: nowMs must be a function (DD-4)');
  }
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const written: Array<readonly [number, string]> = [];
  const calls: Record<string, number> = {};
  for (const n of WASI_IMPORT_NAMES) calls[n] = 0;

  let memory: WebAssembly.Memory | undefined;

  // THE BUFFER IS RE-READ ON EVERY CALL AND NEVER CACHED. `WebAssembly.Memory.grow` REPLACES
  // `memory.buffer` and DETACHES the old one; the AVM allocates while it runs, so growth happens
  // mid-call and not at a convenient boundary. `ct-host/src/writer.ts` carries the long version of
  // this and the same rule applies to a WASI shim, which is otherwise the easiest place in a
  // browser host to cache a `DataView` for the lifetime of the instance.
  const view = (): DataView => {
    if (!memory) throw new Error('the WASI shim was used before bind(memory)');
    return new DataView(memory.buffer);
  };
  const bytes = (): Uint8Array => {
    if (!memory) throw new Error('the WASI shim was used before bind(memory)');
    return new Uint8Array(memory.buffer);
  };

  // The environment, flattened once into the `KEY=value\0` form WASI hands back.
  const envEntries = Object.entries(options.env ?? {}).map(([k, v]) => encoder.encode(`${k}=${v}\0`));
  const envBufSize = envEntries.reduce((a, b) => a + b.length, 0);

  const count = (name: string): void => {
    calls[name] = (calls[name] ?? 0) + 1;
  };

  // fd_write buffers until a newline, so a `vinfo` line arrives as one line rather than as the
  // three writes libc splits it into.
  const partial = new Map<number, string>();
  const emit = (fd: number, text: string): void => {
    const carried = (partial.get(fd) ?? '') + text;
    const lines = carried.split('\n');
    partial.set(fd, lines.pop() ?? '');
    for (const line of lines) {
      written.push([fd, line]);
      options.writeLine?.(fd, line);
    }
  };

  const imports: Record<string, (...args: never[]) => number> = {
    // ---- libc startup -----------------------------------------------------------------------
    clock_time_get: ((_id: number, _precision: bigint, out: number): number => {
      count('clock_time_get');
      // DD-4. Nanoseconds, from the injected clock; `Date.now` is not called here or anywhere in
      // this package.
      view().setBigUint64(out, BigInt(Math.floor(nowMs())) * 1_000_000n, true);
      return WASI_ESUCCESS;
    }) as never,

    environ_sizes_get: ((countOut: number, sizeOut: number): number => {
      count('environ_sizes_get');
      const v = view();
      v.setUint32(countOut, envEntries.length, true);
      v.setUint32(sizeOut, envBufSize, true);
      return WASI_ESUCCESS;
    }) as never,

    environ_get: ((ptrsOut: number, bufOut: number): number => {
      count('environ_get');
      const v = view();
      const b = bytes();
      let cursor = bufOut;
      envEntries.forEach((entry, i) => {
        v.setUint32(ptrsOut + i * 4, cursor, true);
        b.set(entry, cursor);
        cursor += entry.length;
      });
      return WASI_ESUCCESS;
    }) as never,

    // ---- stdio ------------------------------------------------------------------------------
    fd_write: ((fd: number, iovsPtr: number, iovsLen: number, writtenOut: number): number => {
      count('fd_write');
      if (fd !== STDOUT && fd !== STDERR) return WASI_EBADF;
      const v = view();
      const b = bytes();
      let total = 0;
      for (let i = 0; i < iovsLen; i++) {
        const base = v.getUint32(iovsPtr + i * 8, true);
        const len = v.getUint32(iovsPtr + i * 8 + 4, true);
        if (len === 0) continue;
        emit(fd, decoder.decode(b.subarray(base, base + len)));
        total += len;
      }
      v.setUint32(writtenOut, total, true);
      return WASI_ESUCCESS;
    }) as never,

    fd_read: ((_fd: number, _iovsPtr: number, _iovsLen: number, readOut: number): number => {
      count('fd_read');
      // There is no stdin. Zero bytes read is end-of-file, which is the truthful answer and not an
      // error: reporting EBADF here would make a guest that probes stdin at startup abort.
      view().setUint32(readOut, 0, true);
      return WASI_ESUCCESS;
    }) as never,

    fd_close: ((_fd: number): number => {
      count('fd_close');
      return WASI_ESUCCESS;
    }) as never,

    fd_seek: ((_fd: number, _offset: bigint, _whence: number, _newOffsetOut: number): number => {
      count('fd_seek');
      // A character device is not seekable. libc uses the refusal to decide the stream is
      // unbuffered, which is what we want for `vinfo` logging.
      return WASI_ENOTSUP;
    }) as never,

    fd_fdstat_get: ((fd: number, out: number): number => {
      count('fd_fdstat_get');
      if (fd !== STDIN && fd !== STDOUT && fd !== STDERR) return WASI_EBADF;
      const v = view();
      v.setUint8(out, FILETYPE_CHARACTER_DEVICE);
      v.setUint16(out + 2, 0, true); // fs_flags
      v.setBigUint64(out + 8, RIGHTS_ALL, true); // fs_rights_base
      v.setBigUint64(out + 16, RIGHTS_ALL, true); // fs_rights_inheriting
      return WASI_ESUCCESS;
    }) as never,

    fd_prestat_get: ((_fd: number, _out: number): number => {
      count('fd_prestat_get');
      // No preopened directories. EBADF is how a guest learns the preopen walk is over; it is the
      // answer `node:wasi` gives with `preopens: {}`, which is what M17's loader passes.
      return WASI_EBADF;
    }) as never,

    fd_prestat_dir_name: ((_fd: number, _pathPtr: number, _pathLen: number): number => {
      count('fd_prestat_dir_name');
      return WASI_EBADF;
    }) as never,

    // ---- randomness (M27's module only) -------------------------------------------------------
    random_get: ((ptr: number, len: number): number => {
      count('random_get');
      const out = bytes().subarray(ptr, ptr + len);
      const fill =
        options.randomBytes ??
        ((buf: Uint8Array) => {
          globalThis.crypto.getRandomValues(buf);
        });
      fill(out);
      return WASI_ESUCCESS;
    }) as never,

    // ---- the abort path ---------------------------------------------------------------------
    proc_exit: ((code: number): number => {
      count('proc_exit');
      // THROWING IS THE POINT. A reactor has no exit; a `proc_exit` is an abort, and an abort that
      // returned would let the module carry on with a corrupted invariant. `NODE-HOST.md`'s
      // trap-versus-revert table says a trap is a runtime bug and a revert is a transaction
      // outcome — this is the first.
      throw new WasiProcExit(code);
    }) as never,
  };

  return {
    imports,
    bind(m: WebAssembly.Memory) {
      memory = m;
    },
    written,
    calls,
  };
}
