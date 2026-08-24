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
| `diffsim/` | `spike/` with the 7 files that differ from master restored from the npm tarball, so **both** simulators run in-process and the TS↔C++ differential harness works |
| `probe-mt/` | merkle-tree probes: native world-state roots vs. the deleted `@aztec/merkle-tree` |
| `browser-probe/` | esbuild browser-bundle probe and its node-builtin shims |
| `../aztec-packages` | the `metacraft-labs/aztec-packages` fork, branch `aztec-avm-runtime` — a **workspace-root sibling**, registered in the workspace manifests alongside this repo (it used to live at `upstream/aztec-packages`) |
| `upstream/tsavm` | gitignored worktree of the fork at `3a68d68ac2`, the commit before the TS AVM was deleted |
| `verification/` | the M0 … M11 verification checks; see `just --list` |
| `carry/` | the **ordered carry set** (`series.json`), the measured carry exposure (`exposure.json`) and the last replay onto upstream (`rebase.json`). `series.json` is the authority for what we carry, in what order, and where each patch stands with upstream |
| `CARRY-LEDGER.md` | the readable carry ledger, **generated** from `carry/` — status per patch, what carrying each costs, and the measured total exposure if upstream accepts nothing |
| `submit/` | one script per prepared contribution, `submit/pr<N>-*.sh`. A **person** runs them; nothing else in this repository can open a pull request, and `just verify-submission-manual` asserts that |
| `fixtures/MANIFEST.md` | **the fixture manifest** — one entry per family, with its upstream source, capture procedure, licence, and *both* what a skeptic should conclude from it passing and what they must not |
| `fixtures/trees/world-state-vectors.json` | the Tier D root oracle: the genesis and post-genesis states upstream publishes (asserted against the fork) plus the mutation sequence, checkpoint/revert, sibling path and prefill leaves it does not |
| `fixtures/differential-arm-counts.json` | what the differential suite actually COMPARES, measured rather than read: 216 comparisons, not 758 tests |
| `fixtures/avm-programs/programs.json` | the seven AVM corpus programs, re-assembled in TypeScript and checked against the byte lengths and derived addresses upstream's C++ `BytecodeBuilder` produced |
| `fixtures/contracts/artifacts.json` | the six compiled Noir contracts and the public functions the corpus actually calls, derived from the sources rather than declared |
| `fixtures/authored/` | Tier E — the two authored fixture families, each with the upstream claims that justify it, re-derived from the fork on every run |
| `REUSE-INVENTORY.md` | **the reuse decision for every Aztec component this runtime touches**, with a reason — and a specific rejection reason wherever we build or replace |
| `REACTOR-ABI.md` | the standalone `avm.wasm` reactor's export and import surface and its msgpack host ABI — M12's write-up |
| `CONTRACT-DB.md` | the eight implementations of `ContractDBInterface` upstream has, the three dispositions, and the one taken — M13's write-up |
| `WORLD-STATE.md` | what the in-memory reference world state covers of block production and what it does not: five implementations enumerated, thirteen operations classified, four dispositions worked in order — M14's write-up |
| `BOUNDARY-SHAPE.md` | how much of the transaction and block loop lives inside wasm, decided on measurement, with the rejected shape's numbers retained — M15's write-up |
| `FALLBACK.md` | the TypeScript-trees fallback: its three triggers evaluated conjunct by conjunct, the switch priced out of the deleted package, and the wrong-root hazard with its target values — M16's write-up, and the milestone closes **not-required** |
| `PROVENANCE.md` | the machine-checked mapping of every vendored file to its upstream path and commit; the input `just check-drift` reads |
| `pins.json` / `PINS.md` | the single authority for every upstream pin, and the policy for moving it |
| `DRIFT.md` | the drift ledger: every place two pinned things disagree, opened when observed rather than when fixed |
| `tools/` | the vendoring, re-pin and constants-codegen machinery the checks drive |

> Working in this checkout alongside other people or agents? Read
> [`AGENTS.md`](AGENTS.md) first — it is short, and it exists because two agents
> already lost work to whole-tree git commands here.

## Reproducing

```sh
cd spike  && npm install && SPIKE_PURE_TS=1 npx jest    # 676 pass, 0 non-C++ failures
cd drift  && npm install && SPIKE_PURE_TS=1 npx jest    # identical numbers on today's deps
cd spike  && npx tsc --noEmit                           # 5 errors, all in C++-only files
cd diffsim && npm install && npx jest                   # 756 pass / 1 fail, incl. the TS-vs-C++ oracle
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
**entire** API drift between the deletion and upstream master eight weeks later — and since M1 it is
a *recorded transformation* rather than a one-off sed: `drift/src` is regenerated from `spike/src`
by `just regen-drift`, and `just check-drift` regenerates it into a scratch directory and requires
byte equality. If a future nightly needs a second edit, that check fails until the second edit is
recorded in `PROVENANCE.md`.

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
  and would produce wrong roots — `FALLBACK.md` §3 carries both target values and re-derives
  them on every run.
- The whole execution path, `PublicProcessor` included, **bundles for the browser**:
  10.56 MB minified / 6.84 MB gzipped, of which the AVM itself is **115 KB**.
- **The deleted TS↔C++ differential harness runs, and it is green.** `diffsim/` gets
  **756 passed / 1 failed** in 11 s from a plain `npm install`, no barretenberg build —
  `@aztec/bb.js`'s npm tarball ships the prebuilt NAPI AVM for four architectures, and the
  published nightly still carries the older in-process adapter. Per transaction the harness
  asserts equal revert code, all four gas dimensions, the full public tx effect, the AVM
  circuit public-inputs buffer, every return value **and the resulting tree roots**. The one
  failure is a fixture generator asserting a repo-root path, not a simulator failure.
