// `@aztec/foundation/promise` AS THE ANCHOR'S CODE EXPECTS IT, over the pin this bundle installs.
//
// THE FAMILY THIS BELONGS TO. `CAMPAIGN-BRIEF.md`: *"read the anchor to understand the design; read
// the INSTALLED PIN to know what will parse. They are two different questions and this campaign has
// now paid for both."* M23 met it as `AztecNodeDebug` (five methods at the anchor, three at the pin)
// and M34 met it twice in upstream's zod schemas. **M35 is the third, and it is the first where the
// disagreement is a MISSING EXPORT rather than a changed shape**, so it is a build failure rather
// than a run-time surprise — which is the cheap direction.
//
// THE MEASUREMENT. M35 vendors upstream's private-execution oracle wire layer from the `cpp` anchor
// (2026-08-19, RI-97). `browser/` builds against `orchestration/package.json`'s `@aztec/*`, which is
// `pins.json`'s `deletion_era` line (5.0.0-nightly.20260626) and is two months older. Exactly two
// symbols the anchor's code imports do not exist there, and BOTH exist at the `current` line
// (5.3.0-nightly.20260819, which `pins.json` records as corresponding to the `cpp` anchor):
//
//   * `allToCompletion`                  — `@aztec/foundation/promise`, this file
//   * `computeFeeJuiceMessageNullifier`  — `@aztec/stdlib/messaging`, `stdlib_messaging.ts` beside it
//
// Measured both ways rather than assumed: `grep -rl` finds each in `drift/node_modules` (the tree on
// the `current` line) and in neither of `orchestration/node_modules`' barrels.
//
// WHY A SHIM AND NOT AN EDIT. Repointing the import inside the vendored file would be a `local-edits`
// class, and would take those bytes out of `check-drift`'s byte-identity arm for good — the same
// trade `browser/build.mjs`'s `@aztec/simulator/client` alias declines. This file is OURS, sits in
// `browser/src/shims/` beside the three that already exist for the same kind of reason, and is
// reached by an `alias` entry rather than by an edit. All 50 vendored files stay `local-edits: none`.
//
// WHAT IS REPRODUCED, AND FROM WHERE. `allToCompletion` is upstream's own
// `yarn-project/foundation/src/promise/utils.ts` at the `cpp` anchor, re-expressed here. It is a
// promise combinator with no crypto and no protocol content: `Promise.allSettled`, rethrow a lone
// rejection AS ITSELF so error identity survives, aggregate more than one. The behaviour that
// matters — and the reason upstream wrote it rather than using `Promise.all` — is that it runs every
// input to COMPLETION before rejecting, so no abandoned sibling is still producing side effects when
// the caller observes the failure.
//
// WHAT MEASURES THIS FILE, STATED HONESTLY RATHER THAN OPTIMISTICALLY. Nothing M35 SERVES calls
// `allToCompletion`: its only caller in the vendored closure is `fact_store.ts`, and the four fact
// oracles refuse by name. So there is no behavioural arm over it, and claiming one would be the
// "prose drifts from measurement" family in a file header. What IS measured is that the shim is
// REACHED: `browser/esbuild-driver.mjs`'s `anchor-pin-gap` plugin fails the build if any entry in
// its table matches nothing, so a shim that stopped standing in is a build error rather than a
// silent `undefined`. That is the property that matters here, because without this file esbuild
// refuses the whole bundle with `No matching export`.

export * from '../../../orchestration/node_modules/@aztec/foundation/dest/promise/index.js';

/**
 * Like `Promise.all`, but runs every promise to completion before resolving or rejecting.
 *
 * Reproduced from `yarn-project/foundation/src/promise/utils.ts` at the `cpp` anchor; see this
 * file's header for why it is here rather than imported.
 */
export async function allToCompletion<T extends readonly unknown[] | []>(
  promises: T,
): Promise<{ -readonly [P in keyof T]: Awaited<T[P]> }> {
  const results = await Promise.allSettled<unknown>(promises);
  const failures = results.filter((result): result is PromiseRejectedResult => result.status === 'rejected');
  if (failures.length === 1) {
    // Rethrow a lone failure as-is so error identity is preserved for callers that inspect error types.
    throw failures[0].reason;
  } else if (failures.length > 1) {
    throw new AggregateError(
      failures.map(failure => failure.reason),
      `${failures.length} of ${results.length} concurrent operations failed: ${failures
        .map(failure => (failure.reason instanceof Error ? failure.reason.message : String(failure.reason)))
        .join(' | ')}`,
    );
  }
  return results.map(result => (result as PromiseFulfilledResult<unknown>).value) as {
    -readonly [P in keyof T]: Awaited<T[P]>;
  };
}
