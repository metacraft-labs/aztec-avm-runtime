// The two Node GLOBALS `@aztec`'s compiled output reaches for, supplied through esbuild `inject`.
//
// A FREE IDENTIFIER IS A DIFFERENT PROBLEM FROM AN UNRESOLVED IMPORT, and it is the worse one.
// `import { inspect } from 'util'` fails the BUILD, loudly, with the file and the line. A bare
// `Buffer.from(...)` builds fine and then dies in the page with `Buffer is not defined`, at
// whatever moment the first buffer is made — which in this graph is inside a field element's
// constructor, three layers below anything a page author wrote.
//
// So both are supplied here rather than left to chance, and `verify_browser_bundle_builds` asserts
// that neither name survives as a free identifier in the built bundle.
//
// `Buffer` IS THE REAL ONE. `buffer@6` is already in this tree — it is a transitive dependency of
// the `@aztec` packages and esbuild resolves it without anything being added — and a hand-written
// stand-in would be the wrong kind of economy: `Fr.fromBuffer`, `BufferReader`, every `toBuffer()`
// and the whole msgpack path run through it, and a subtly different `subarray` would be a wrong
// field element rather than a crash.
//
// `process` IS NOT the real one, and does not need to be. Measured over the built bundle: what the
// graph reads is `process.env.<NAME>` (log levels, `BB_WASM_PATH`) and `process.platform`. An
// object with an empty `env` answers all of them the way an unset environment does, which is what a
// page has. `process.exit` is deliberately absent rather than a no-op — a library that calls it in
// a browser is a library doing something a page must not silently tolerate.

import { Buffer } from 'buffer';

const shimProcess = {
  env: {},
  platform: 'browser',
  version: '',
  versions: {},
  argv: [],
  browser: true,
  nextTick: (fn, ...args) => queueMicrotask(() => fn(...args)),
  cwd: () => '/',
  // `hrtime.bigint()` is a MONOTONIC COUNTER, not a wall clock, and it is here because bundled
  // pino reads it at module-evaluation time — a `process` without it makes the bundle die on
  // import rather than on use. DD-4 is about the runtime's own sources reading a clock; this is a
  // dependency's timestamp formatter, and `test_no_ambient_clock_or_timer` scans the sources that
  // ship rather than the shims that stand in for a platform.
  hrtime: Object.assign(
    (previous) => {
      const ns = BigInt(Math.round(performance.now() * 1e6));
      const s = Number(ns / 1000000000n);
      const n = Number(ns % 1000000000n);
      return previous ? [s - previous[0], n - previous[1]] : [s, n];
    },
    { bigint: () => BigInt(Math.round(performance.now() * 1e6)) },
  ),
};

export { Buffer };
export { shimProcess as process };
