// `node:module`, for the one thing in this graph that reaches for it.
//
// `@aztec/blob-lib/dest/kzg_context.js` does `import { createRequire } from 'module'` and uses it
// to locate a trusted-setup file on disk. That is a KZG context for blob commitments — an L1 data
// availability concern — and nothing on the public-execution path calls it; it arrives in the graph
// because `@aztec/stdlib`'s block types import the blob library eagerly.
//
// SO THE SHIM THROWS RATHER THAN RETURNING SOMETHING PLAUSIBLE, and that is the whole design. A
// `createRequire` that returned a function yielding `{}` would let `kzg_context` construct a
// context out of nothing and produce blob commitments that are wrong rather than absent. A page
// that reaches this gets a message naming the module and the reason instead.
//
// `verify_browser_bundle_builds` asserts that this throw is NOT reached during any arm, by reading
// the page's console: an arm that tripped it would have logged it.

export function createRequire() {
  throw new Error(
    'createRequire is not available in the browser build. Something reached @aztec/blob-lib\'s ' +
      'KZG context, which loads a trusted setup off disk to build blob commitments for L1 data ' +
      'availability. This runtime has no L1 (§8.4) and nothing on the public-execution path needs ' +
      'it; it is in the module graph only because @aztec/stdlib imports the blob library eagerly.',
  );
}

export default { createRequire };
