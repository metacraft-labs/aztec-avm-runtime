# aztec-avm-runtime — feasibility spike

Can the pure-TypeScript Aztec AVM that upstream deleted on 2026-06-26 be revived as the
basis of a **browser-capable** AVM runtime that executes transactions over a storage state?

**Short answer: yes.** It runs unmodified, against packages published on npm, in seconds.
This repo holds the evidence. It is a spike, not a runtime — nothing here is a design.

Narrative findings and full numbers live in the campaign log
(`.../scratchpad/campaign/avm-spike-log.md`).

## What was deleted, and where it is

`aztec-packages` commit `4377ddf64c` *"refactor: remove the TS AVM simulator"* (2026-06-26)
removed ~16k lines as **redundant**, not broken. The tree is intact at its parent
`3a68d68ac2`, under `yarn-project/simulator/src/public/`.

The key lever this spike found: **`@aztec/simulator@5.0.0-nightly.20260626` on npm still
ships the whole deleted tree**, compiled and with sources, and every sibling package exists
at the same version. Its `src/public` is identical to `3a68d68ac2` in file list and differs
in 8 files / 86 lines — **none of them under `avm/`**. So the deleted code can be built and
tested with `npm install`, with no barretenberg C++ build, no Rust/wasm-bindgen build, no
`nargo` contract compilation and no yarn-berry portal resolution.

## Layout

| path | what |
|---|---|
| `spike/` | `yarn-project/simulator/src` verbatim from `3a68d68ac2`, pinned to `@aztec/*@5.0.0-nightly.20260626` |
| `drift/` | the same sources against `@aztec/*@5.3.0-nightly.20260819` (upstream master `233d8e0993`) |
| `probe-mt/` | merkle-tree probes: native world-state roots vs. the deleted `@aztec/merkle-tree` |
| `browser-probe/` | esbuild browser-bundle probe and its node-builtin shims |
| `upstream/aztec-packages` | git clone (gitignored); `upstream/tsavm` is a worktree at `3a68d68ac2` |

## Reproducing

```sh
cd spike  && npm install && SPIKE_PURE_TS=1 npx jest    # 676 pass, 0 non-C++ failures
cd drift  && npm install && SPIKE_PURE_TS=1 npx jest    # identical numbers on today's deps
cd spike  && npx tsc --noEmit                           # 5 errors, all in C++-only files
```

## Spike-only source edits

Every edit to the vendored tree is marked `SPIKE` in-source. There are three.

1. `spike/src/public/fixtures/gas_compat.ts` — reproduces `FALLBACK_TEARDOWN_{DA,L2}_GAS_LIMIT`,
   which master names and the published nightly inlines. Test fixtures only.
2. A jest `moduleNameMapper` entry for `@aztec/simulator/public/fixtures`, a self-referential
   import in `custom_bc.test.ts`.
3. A `SPIKE_PURE_TS=1` switch in three test entry points. **This one is load-bearing:**
   upstream's suites labelled `(TS Simulator)` do not run the TS simulator alone — they run
   `MeasuredCppVsTsPublicTxSimulator`, the *differential* harness, which needs the native
   `bb-avm-sim` too. The switch selects the pure-TypeScript simulator instead.

`drift/` additionally carries one mechanical rename across 26 files,
`AztecAddress.from{Field,BigInt,Number,String}` → `from…Unsafe`. That rename is the
**entire** API drift between the deletion and upstream master eight weeks later.

## Headline results

- **676 tests pass**; every one of the 81 failures is a `Cpp`-labelled test that needs the
  native `bb-avm-sim` binary. Not one failure on a TypeScript-only path.
- Green includes real compiled Noir contracts end to end: Token (constructor / mint /
  transfer / burn), AMM, AvmTest bulk, deployments through `PublicProcessor`, and the
  merkle-checked note-hash / nullifier / public-storage paths.
- The **AVM opcode set has not changed**: `barretenberg/.../vm2/common/opcodes.hpp` has a
  zero diff between `3a68d68ac2` and `233d8e0993`.
- One real semantic divergence in eight weeks: AND/OR/XOR **lost their dynamic L2 gas**
  upstream, and the revived TS gas table still charges it
  (`spike/src/public/avm/avm_gas.ts:135-140`).
- The trees now hash internal nodes with a **per-tree domain separator**,
  `poseidon2([SEP, lhs, rhs])` — reproduced exactly against the native world state in
  `probe-mt/`. The deleted `@aztec/merkle-tree` package uses undomained `poseidon2([l, r])`
  and would produce wrong roots.
- The whole execution path, `PublicProcessor` included, **bundles for the browser**:
  10.56 MB minified / 6.84 MB gzipped, of which the AVM itself is **115 KB**.
