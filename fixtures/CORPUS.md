# Test-fixture corpus for the Aztec AVM Runtime

Everything here is either **taken from upstream** (Apache-2.0, see licensing below) or
**generated from an upstream oracle by a script in this repo**. Nothing is invented.

Every count in this document was produced by running the suite, not by reading it. Commands are
given so any claim can be re-checked.

> **Read [`MANIFEST.md`](MANIFEST.md) first.** M2 added a machine-readable fixture manifest with one
> entry per family, each carrying its upstream source, its capture procedure, its licence, and — in
> two separate fields — what a skeptic should conclude from it passing *and what they must not*.
> That file is checked (`just verify-fixture-manifest`); this one is prose and is not. The tier
> letters also differ: the manifest uses the milestone's tiers A–E (plus H for the harness), this
> document uses the older spike-era A–J. The mapping between them is at the foot of the manifest.

## Licensing — one answer for the whole corpus

| source | licence | evidence |
|---|---|---|
| `aztec-packages` (all of `yarn-project/`, `barretenberg/`, `noir-projects/`, `docs/`) | **Apache-2.0** | root `LICENSE` and `barretenberg/LICENSE`, both Apache-2.0, *Copyright 2023 Spilsbury Holdings Ltd*. No `NOTICE` file. Every relevant `package.json` omits `license`, i.e. inherits the repo licence. GitHub reports `spdx_id: Apache-2.0`. |
| `avm-transpiler/` | **MIT OR Apache-2.0** | `avm-transpiler/Cargo.toml` — dual, strictly more permissive |
| `@aztec/bb.js` npm package | declares **MIT** in its `package.json` | more permissive than the repo licence it is built from; either grant is fine |
| `AztecProtocol/protocol-specs-pdf` | **NO LICENCE** | `license: null`, `/license` API 404, no LICENSE file → all rights reserved. **Not vendored. Must not be redistributed.** |
| `AztecProtocol/engineering-designs` | **NO LICENCE** | same. Read-only reference, not vendored. |

Obligation under Apache-2.0: retain the licence text and attribution, and state changes. The
licence copy lives at `reference/LICENSE.aztec-packages.Apache-2.0`; provenance and pinning at
`reference/PROVENANCE.md`; the three source edits made to the vendored tree are marked `SPIKE`
in-source and listed in the repo `README.md`.

`DISCLAIMER.md` at the upstream root is a no-warranty notice, **not** a licence restriction.

---

## Tier A — the TS↔C++ differential oracle

**Where:** `diffsim/` · **Run:** `nix develop`, then `cd diffsim && npm test`
(verified green in the dev shell: 43 suites / 757 passed / 13.0 s. Prefer this over a bare
`npm test` against ambient node — it is the reproducible invocation.)
**Provenance:** `yarn-project/simulator/src/public/` @ `3a68d68ac2` (= `4377ddf64c^`, the parent of
*"refactor: remove the TS AVM simulator"*), with the 7 files that differ from that commit restored
from the `@aztec/simulator@5.0.0-nightly.20260626` npm tarball so both simulators run in-process.

**Measured, 2026-08-21:**

```
Test Suites: 1 skipped, 43 passed, 43 of 44 total
Tests:       153 skipped, 757 passed, 910 total      14.0 s
```

### What the oracle actually covers — read this before quoting the 757

The 757 is **not** 757 differential comparisons. Bucketed by `describe` label:

| bucket | passed | what it means |
|---|---|---|
| `(TS Simulator)` — runs `MeasuredCppVsTsPublicTxSimulator` | 77 | **the differential oracle** |
| `(Cpp Simulator)` — runs `MeasuredCppPublicTxSimulator` | 78 | C++ alone, **no comparison** |
| unlabelled | 602 | pure-TS unit tests, hand-written expectations, **no C++ cross-check** |

The labels are inverted from intuition: `useCppSimulator: false` selects the *differential*
simulator (`fixtures/public_tx_simulation_tester.ts:99-101`).

I instrumented `CppVsTsPublicTxSimulator.simulate()` with a per-invocation counter (edit reverted;
`git status` clean afterwards). The oracle compares exactly **74 transactions**:

| suite | differential txs | what it exercises |
|---|---|---|
| `public_tx_simulator/apps_tests/avm_gadgets.test.ts` | 27 | sha256 (16 lengths + 2 vectors), keccak (4 + f1600), poseidon2 (2), pedersen (2) |
| `public_tx_simulator/apps_tests/custom_bc.test.ts` | 13 | hand-built bytecode unhappy paths: uninitialised relative base, bad indirect tag, relative overflow, PC out of range, invalid opcode/byte/tag, truncated instruction, SET/CAST truncation |
| `public_processor/apps_tests/token.test.ts` | 12 | block-level: token constructor, mint, many transfers |
| `public_tx_simulator/apps_tests/token.test.ts` | 8 | token constructor / mint / transfer / burn / balances |
| `public_tx_simulator/apps_tests/amm.test.ts` | 8 | AMM add-liquidity / swap / remove-liquidity |
| `public_processor/apps_tests/deployments.test.ts` | 5 | deploy-then-call in one tx, deploy in private + call later in block, block-cache poisoning |
| `public_tx_simulator/apps_tests/avm_test.test.ts` | 1 | AvmTest bulk |
| `public_tx_simulator/apps_tests/bench.test.ts` | **0** | opts out — see below |
| `public_processor/apps_tests/timeout_race.test.ts` | **0** | C++-concurrency only |
| `public_tx_simulator/apps_tests/cpp_exception_handling.test.ts` | **0** | C++-only |
| **total** | **74** | |

`bench.test.ts` is a trap for the unwary: it has 30 `(TS Simulator)`-labelled tests and contributes
**zero** differential comparisons. It deliberately opts out at `bench.test.ts:73-75` —
*"For benchmarking, use pure simulators (no CppVsTs comparison overhead)"* — constructing
`MeasuredPublicTxSimulator` directly. It is a **performance suite, not an oracle.**

### What each comparison asserts

Per transaction, `cpp_vs_ts_public_tx_simulator.ts:132-200`:

- `revertCode` equal
- **all four gas dimensions** equal: `totalGas`, `publicGas`, `teardownGas`, `billedGas`
- the full `publicTxEffect` equal
- the AVM circuit **public-inputs buffer** byte-equal
- every app-logic return value equal (when `collectCallMetadata`)
- revert *reason* equal, message text excluded
- **the resulting tree roots equal** (`StateReference`) — *"Tree roots mismatch between TS and C++
  public simulations for tx …"*

### What it would catch

Any divergence in opcode semantics, gas metering, side-effect ordering, tree insertion, note-nonce
derivation, or public-input packing, on a real compiled contract. This is the single strongest
artefact in the corpus.

### What it would not catch

- Anything on a code path none of the 74 transactions reach.
- Anything both implementations get wrong the same way.
- Gas divergence *from current upstream*: the oracle is the C++ AVM as of the 5.0.0 npm line. See
  the expiry note under Risks.

### Why it runs without a barretenberg build

`@aztec/bb.js@5.0.0-nightly.20260626`'s npm tarball ships the prebuilt NAPI module
(`nodejs_module.node`) for amd64/arm64 × linux/macos, and the published nightly still carries the
older **in-process** `CppPublicTxSimulator`. Upstream master moved to out-of-process `bb-avm-sim`
over IPC on 2026-07-16 (`96082e32ec`).

---

## Tier B — the cross-language golden binary

**Fixture:** `barretenberg/cpp/src/barretenberg/vm2/testing/minimal_tx.testdata.bin`
**Test:** `diffsim/src/public/public_tx_simulator/apps_tests/avm_minimal.test.ts`

Runs the minimal public tx (`SET`, `SET`, `ADD`, `RETURN`), serializes
`AvmCircuitInputs(hints, publicInputs)` with msgpack, and **byte-compares** against the file the
C++ tests consume. It is the written contract between the TS and C++ sides of the AVM: one
assertion pinning the widest serialization surface in the system.

**Setup.** `@aztec/foundation/testing/files`'s `getPathToFile()` resolves five directories up from
its own module and requires a `CODEOWNERS` sentinel; in a standalone install that lands on
`node_modules/`. Place a `CODEOWNERS` sentinel and the golden at
`node_modules/barretenberg/cpp/src/barretenberg/vm2/testing/`. Read-only —
`writeTestData` is a no-op unless `AZTEC_GENERATE_TEST_DATA=1`.

**Measured:**

| golden | size | md5 | result |
|---|---|---|---|
| from `3a68d68ac2` (contemporaneous) | 188,945 | `e1f17c71a3917a913de63dedf2f71a11` | **PASS** |
| from `233d8e0993` (master, 8 weeks later) | 190,671 | `369ae621886f3d0f0d4867bcbe7419f3` | **FAIL** |

So this fixture is also a **drift detector with a date on it** — eight weeks of upstream movement
shows up as a hard byte mismatch and a 1,726-byte size change.

**Caveat with teeth.** At master, `vm2/testing/fixtures.cpp::get_minimal_proving_inputs()` builds
these inputs **on the fly**, and nothing in the C++ tree reads `minimal_tx.testdata.bin` by name
any more (grep over all `*.cpp`/`*.hpp`/`CMakeLists.txt` finds no reader). The TS test is the
*producer*; the C++ side has moved on. Going forward this is a **one-way pin** and must be
regenerated against whichever oracle we keep.

A second golden, `tx_result_0x02440a89…testdata.bin` (192,605 bytes, last touched by
`eefae4a8d8 feat(avm)!: callstack metadata collector`), has **no reader anywhere** in the tree.
Dead weight; ignore it.

---

## Tier C — semantic unit fixtures (602 tests)

Pure TypeScript, hand-written expectations, no C++ cross-check. These pin *semantics* against the
original authors' intent, which is exactly what you want when refactoring an interpreter — but they
are **not** independent evidence of agreement with production.

Per-file, measured (`jest --json`):

| area | file(s) | passed |
|---|---|---|
| interpreter, end-to-end | `avm/avm_simulator.test.ts` | 112 |
| memory tags & conversions | `avm/avm_memory_types.test.ts` | 99 |
| arithmetic | `avm/opcodes/arithmetic.test.ts` | 67 |
| memory ops | `avm/opcodes/memory.test.ts` | 35 |
| accrued substate | `avm/opcodes/accrued_substate.test.ts` | 24 |
| conversion (`TORADIXBE`, `CAST`) | `avm/opcodes/conversion.test.ts` | 18 |
| side-effect trace + limits | `side_effect_trace.test.ts` | 17 |
| `public_processor` | `public_processor/public_processor.test.ts` | 16 |
| control flow | `avm/opcodes/control_flow.test.ts` | 15 |
| hashing gadgets | `avm/opcodes/hashing.test.ts` | 15 |
| state manager | `state_manager/state_manager.test.ts` | 15 |
| environment getters | `avm/opcodes/environment_getters.test.ts` | 14 |
| external calls | `avm/opcodes/external_calls.test.ts` | 13 |
| comparators | `avm/opcodes/comparators.test.ts` | 12 |
| bitwise | `avm/opcodes/bitwise.test.ts` | 11 |
| contract ops | `avm/opcodes/contract.test.ts` | 10 |
| nullifiers | `state_manager/nullifiers.test.ts` | 10 |
| bytecode (de)serialization | `avm/serialization/bytecode_serialization.test.ts` | 10 |
| EC add | `avm/opcodes/ec_add.test.ts` | 9 |
| calldata | `avm/calldata.test.ts` | 8 |
| public storage | `state_manager/public_storage.test.ts` | 7 |
| misc | `avm/opcodes/misc.test.ts` | 5 |
| storage opcodes | `avm/opcodes/storage.test.ts` | 7 |
| addressing modes | `avm/opcodes/addressing_mode.test.ts` | 4 |
| gas / context / exec-env / instruction-ser | 4 files | 8 |

Note `avm/avm_gas.test.ts` reports **2 passed / 10 skipped** — the gas unit suite is mostly
upstream-skipped. Gas is covered by Tier A, not here.

### Highest-value subsets

- `avm_memory_types.test.ts` (99) — tag semantics, wrapping, truncation. Cheap and catches a whole
  class of silent numeric bugs.
- `bytecode_serialization.test.ts` + `instruction_serialization.test.ts` (12) — the wire format.
- `side_effect_trace.test.ts` (17) — **includes the fork/merge-on-revert cases**, which is the
  checkpoint semantics we must re-implement.
- `state_manager/*` (32) — the layer directly above the merkle trees.

---

## Tier D — the tree oracle (**authored here**, from a native oracle)

> **Framing correction (2026-08-21).** We are **not** implementing merkle trees. The wasm build
> already compiles and runs Aztec's own in-memory trees (`world_state_reference` /
> `simulation::MemoryMerkleDB`) inside upstream's `PublicTxSimulationTester`. So everything in this
> tier is a **verification** fixture set against an upstream component, not bring-up scaffolding for
> code of ours. The deleted `@aztec/merkle-tree` package is now only a documented fallback. See
> Tier I for the native-vs-wasm root parity result.

Upstream ships **no golden merkle-root vectors.** I checked: `vm2/simulation/gadgets/`'s
`merkle_check` (7), `note_hash_tree_check` (5), `public_data_tree_check` (5),
`indexed_tree_check` (6) and `simulation/lib/indexed_memory_tree` (5) all compute their expected
root with `unconstrained_root_from_path(...)` and then assert the emitted event carries that same
root. They are **self-consistency tests, not test vectors** — they cannot detect a wrong hash
function because they use the same one on both sides. `grep -c '0x' merkle_check.test.cpp` → **0**.

So the only oracle is the native world-state service at runtime. I captured it:

**Generator:** `probe-mt/dump_genesis.mjs` · **Fixture:** `fixtures/trees/native-genesis-state.json`
(80 KB) · **Run:** `cd probe-mt && node dump_genesis.mjs > ../fixtures/trees/native-genesis-state.json`

Contents — the complete block-0 state of `NativeWorldStateService.tmp()`:

| tree | depth | size | root |
|---|---|---|---|
| `NOTE_HASH_TREE` | 42 | 0 | `0x2590f2aab19dd791700b4a43d3f52bb88ef2409a3731da8e848663559202e4c6` |
| `NULLIFIER_TREE` | 42 | **128** | `0x18935581a8ed73d08ffd00386fba55ba6c89f3ab848a76b8fedfa9034cee0454` |
| `PUBLIC_DATA_TREE` | 40 | **128** | `0x1bef38b621017d3c7416663d0cd81369424560710526a3fbaaec13e356b9d084` |
| `L1_TO_L2_MESSAGE_TREE` | 36 | 0 | `0x0fef6d80d31109ddb56d6b3f607cbc9c0af0bff3ea0d43e8f278983c64c11f7a` |
| `ARCHIVE` | 30 | 1 | `0x177a4955b31ecaafad999753938a44e526b54c5ba5d536688227f85f15cfbdf5` |

plus the full `StateReference`, the **42-level zero sibling path** for note-hash leaf 0, and
**all 256 genesis-prefill leaf preimages** (128 nullifier + 128 public-data, each with
`nextKey`/`nextIndex` — the indexed-tree linkage, which is the part that is easy to get subtly
wrong).

### What it catches

The single highest-risk defect in the project. The deleted `@aztec/merkle-tree` package hashes
internal nodes as `poseidon2([lhs, rhs])`; the current protocol hashes them as
`poseidon2([SEP, lhs, rhs])` with a **per-tree** domain separator
(`reference/trees-and-state/aztec_hash_policy.hpp`):

| tree | separator |
|---|---|
| note-hash, L1→L2, archive (append-only) | `DOM_SEP__MERKLE_HASH = 2982624097` |
| nullifier (indexed) | `DOM_SEP__NULLIFIER_MERKLE = 1157584160` |
| public-data (indexed) | `DOM_SEP__PUBLIC_DATA_MERKLE = 3756303423` |

An implementation that misses this compiles, passes its own tests, and produces wrong roots for
every transaction. Re-verified by execution today (`probe-mt/probe7.mjs`) — the domain-separated
TypeScript reproduction matches the native roots exactly, and the undomained one does not.

The 256 prefill leaves catch the *other* half: an implementation with the right hash but the wrong
genesis state is equally wrong from block 1 onward.

### Recommended use — the cheapest oracle we have for the trees

Run the **entire recovered suite twice**: once against `NativeWorldStateService`, once against our
in-memory trees, and require identical results. All 757 tests currently run against the native
LMDB world state (16 files import `NativeWorldStateService`), so they are already a tree oracle —
they just need the substitution point. This needs no `bb-avm-sim`, and its failure messages point
straight at the tree bug rather than at "gas differs".

---

## Tier E — contract artifacts (freshly compiled Noir, no `nargo` needed)

| package | artifacts | size |
|---|---|---|
| `@aztec/noir-test-contracts.js` | 51 | 76 MB |
| `@aztec/noir-contracts.js` | 34 | — |

Includes `AvmTest`, `AvmGadgetsTest`, `AvmInitializerTest`, `CalldataLimitTest`,
`StorageProofTest`, `PublicFnsWithEmitRepro`, `Token`, `AMM`, `FeeJuice`, `ContractClassRegistry`,
`ContractInstanceRegistry`. Rebuilt every nightly, so this is **fresh bytecode against a
current compiler** for free — the `drift/` tree proves the revived interpreter executes
`@aztec/noir-test-contracts.js@5.3.0-nightly.20260819` correctly.

`SimpleContractDataSource` (`fixtures/simple_contract_data_source.ts`) is already an in-memory
contract source, so this tier works unchanged in the browser.

---

## Tier F — the C++ reference corpus (reference, not runnable for us today)

`barretenberg/cpp/src/barretenberg/vm2/` — **174 `.test.cpp` files**: 78 `simulation/`,
59 `constraining/`, 24 `tracegen/`, 7 `common/`, 4 `integration_tests/`, 1 `testing/`, 1 `dsl/`.

Relevant subsets:

- `simulation/gadgets/` (30 files) — alu, bitwise, ecc, poseidon2, sha256, keccakf1600, to_radix,
  field_gt, range_check, data_copy, addressing, gas_tracker, address/class-id derivation,
  update_check, execution, tx_execution, and the five tree-check gadgets.
- `integration_tests/` (4) — `alu_integration`, `custom_bytecode` (19 KB), `opcode_spam` (38 KB),
  `avm_completeness_bitwise_sha256_collision`.
- `common/instruction_spec.test.cpp` — guards the ISA + gas table.

**Note the direction of travel:** commit `000d8979f6 refactor(avm): port custom-bytecode/opcode-spam
tests to C++, remove TS AVM encoder` moved this corpus *out* of TypeScript. The C++ files are the
maintained versions of the same unhappy-path fixtures our TS tree carries. When our TS copies
eventually age, these are where to re-derive them.

`constraining/` and `tracegen/` (83 files) are **proving-side** and out of scope — they test that
the circuit matches the simulator, not that the simulator is right.

Requires a barretenberg build (~1 hr, needs the wasm/native toolchain). Not part of routine CI here.

---

## Tier G — fuzzers

### G1. AVM ↔ Brillig differential fuzzer — **the C++-free oracle, and it survives in our tree**

- **TS side:** `spike/src/public/fuzzing/{avm_fuzzer_simulator.ts,avm_simulator_bin.ts}`
- **Driver:** `noir-lang/noir`'s `tooling/ssa_fuzzer` (`cargo +nightly fuzz run brillig`)
- **Docs:** `yarn-project/simulator/scripts/fuzzing/README.md`, `scripts/run_avm_brilling_fuzz.sh`

Loop: generate Noir SSA → compile to Brillig and execute → transpile the same program with
`avm-transpiler` → simulate the AVM bytecode with the same inputs → **compare**. Disagreement
(`brillig XOR avm failed`, or `brillig_outputs != avm_outputs`) is a bug. `avm_simulator_bin.ts`
speaks base64 msgpack over stdio and reports `reverted`, `output`, `revertReason`,
`endTreeSnapshots`, `publicTxEffect`.

**Why this matters more than it looks.** In *our* recovered tree (`3a68d68ac2`),
`AvmFuzzerSimulator` drives the **pure-TypeScript `PublicTxSimulator`** — so this is a
coverage-guided differential oracle against Noir's own reference VM that needs **no C++ AVM at
all**, only the Noir toolchain and `avm-transpiler`. At HEAD upstream rewired the same harness to
`AvmSimulatorPool` (C++). Since the C++ NAPI oracle has an expiry date and this one does not, this
is the natural successor oracle. Cost: a Rust nightly + `cargo-fuzz` + a matched Noir/transpiler
build. **Not yet stood up — see Gap 4.**

### G2. C++ gadget fuzzers — not an oracle for us

`barretenberg/cpp/src/barretenberg/avm_fuzzer/harness/` — 11 harnesses (alu, bitwise, calldata,
ecc, emit_public_log, external_call, gt, internal_call, memory, merkle_check, range_check).
`fuzzer_comparison_helper.cpp` states its own scope in line 1: *"compare simulation results from
different AVM2 **C++** simulator runs"*. It is C++ self-consistency, **not** C++-vs-TS. Useful as a
source of interesting inputs; useless as a cross-implementation oracle.

---

## Tier I — native-vs-wasm parity, **including tree roots**

**Where:** `fixtures/wasm-parity/` · **Harness:** `vm2wasm/src/.../vm2_spike/avm_run.cpp`
**Run:** build `avm_spike_runner` in `build-native-avm-spike` and `build-wasm-avm`; run the native
binary directly and the wasm one via `node fixtures/tools/run_wasm.mjs <module>`.

The pre-existing transcript compared revert codes, gas, fees, nullifiers, note hashes, data writes,
logs, call frames and instruction counts across 7 hand-assembled programs — but **never a tree
root**, which is the one thing that catches a wrong merkle hash, a wrong domain separator or a
wrong indexed-leaf linkage. Fixed by enabling `collect_public_inputs` and printing
`start_tree_snapshots` / `end_tree_snapshots` (note-hash, nullifier, public-data, L1→L2; root plus
`next_available_leaf_index`) — 8 root lines per program, **56 per transcript**.

**Measured: all 56 root lines identical native vs wasm.** The whole-transcript diff is exactly two
lines: the `pointer=64bit`/`32bit` banner and the wasm-only `peakLinearMemoryPages 217 (13888 KiB)`.
The roots genuinely vary across the 7 programs (7 distinct end-nullifier roots, 7 distinct
end-public-data roots), so this is a real comparison, not a comparison of constants.

**Three-way agreement on the empty note-hash root.**
`0x2590f2aab19dd791700b4a43d3f52bb88ef2409a3731da8e848663559202e4c6` is produced independently by
(1) C++ `MemoryMerkleDB` under wasm, (2) the native LMDB `NativeWorldStateService`
(`fixtures/trees/native-genesis-state.json`), and (3) a domain-separated TypeScript reproduction
(`probe-mt/probe7.mjs`). Same for L1→L2, `0x0fef6d80…4c11f7a`.

Files: `native-with-roots.results`, `wasm-with-roots.results`.

---

## Tier J — upstream's own vm2 simulation suite, built for wasm

**Where:** `fixtures/wasm-parity/vm2-sim-tests-included.txt`, `fixtures/wasm-parity/EXCLUSIONS.md`,
`fixtures/wasm-parity/vm2-tests-wasm-exclusions.tsv`
**Target:** `vm2_sim_tests`, produced by barretenberg's **own** `cmake/module.cmake` from
`vm2_sim`'s `TEST_SOURCE_FILES` under a new default-off `AVM_SIM_TESTS` option
(`aztec-avm-runtime/verification/m7/`)

Upstream **never builds these tests for wasm in any configuration**: `vm2_sim` is declared with no
`TEST_SOURCE_FILES`, and the `vm2_tests` binary that does carry them is gated on `if(AVM)`, which
pulls in the proving stack (`sumcheck`, `stdlib_honk_verifier`, `goblin_avm`) plus `dsl`, and
`src/CMakeLists.txt` excludes the whole `vm2/` directory from a wasm configure. M7's answer is to
give `vm2_sim` its own `TEST_SOURCE_FILES`, so the binary comes out of upstream's own module
machinery — the same `add_executable`, the same gtest/gmock linkage, the same
`-Wl,-z,stack-size=8388608` under WASM — rather than a bespoke runner.

### Measured 2026-08-22 (M7)

| | tests | suites | exit |
|---|---:|---:|---:|
| native `vm2_sim_tests` | **391 ran, 391 passed, 0 failed** | 60 | 0 |
| **V8** (node 24.19, shipped binary unmodified) | **391 ran, 391 passed, 0 failed** | 60 | 0 |
| **wasmtime 47.0.3** (`env.memory` satisfied by `wasm-merge`) | **391 ran, 391 passed, 0 failed** | 60 | 0 |

The three name sets are **identical per test**, and the 391 are a subset of upstream's own 1,803
name for name. One process each, no `--gtest_filter`, no per-suite splitting.

**Exclusions: 1,412, each named individually** in `vm2-tests-wasm-exclusions.tsv` with the source
file declaring its suite and a reason derived from that file's directory — `constraining/` 1,059,
`tracegen/` 286, `integration_tests/` 59, `dsl/` 5, and `common/avm_io.test.cpp` 3 (its tests call
the tracegen-bound `get_minimal_trace_with_pi`). **Zero** are excluded for needing threads and
**zero** for failing under wasm. See `EXCLUSIONS.md`.

### The three claims this Tier used to make, and what measurement did to them

1. *"24 of 59 suites, 141 tests; the 35 gmock failures are a permanent test-framework
   limitation."* **Superseded.** The cause was an ODR violation across the gtest library boundary,
   not the pthread stubs as such: googletest's CMake puts `-DGTEST_HAS_PTHREAD=1` on gtest's own
   four translation units and does not propagate it, so `internal::MutexBase` is a different type
   inside `libgtest.a` and in every test TU. Making the macro consistent fixes it. Recorded as
   DRIFT **D10**, and the negative control in `verify_vm2_tests_pass_under_v8.sh` reverts the
   correction and shows the same binary reaching **0** passing tests.
   *"Rebuilding gtest+gmock with `GTEST_HAS_PTHREAD=0` was tried and did not help"* is consistent
   with this, for a reason narrower than "it has to be `PUBLIC`": the compile command is
   `$DEFINES $INCLUDES $FLAGS` and googletest puts `cxx_base_flags` in `COMPILE_FLAGS`, so its
   `=1` arrives last and wins on gtest's own units whatever `target_compile_definitions` says.
   `set(gtest_disable_pthreads ON … FORCE)` is the half that fixes gtest's side. Measured on
   review: `PUBLIC` alone → **0 of 391**; consistent `=1` on all 337 → **391 of 391**. The wasi
   pthread stubs are not the defect, the disagreement is.
2. *"Three further suites are gtest death tests, which fork and can never run under WASI."*
   **False.** There is no `EXPECT_DEATH`, `ASSERT_DEATH`, `EXPECT_EXIT` or `ASSERT_EXIT` anywhere
   in the simulation-side sources. One suite is *named* `AvmSimulationEccDeathTest` — a gtest
   naming convention that orders it first — and its body is
   `ASSERT_THROW(ecc.scalar_mul(p, scalar), std::runtime_error)`. It runs and passes under wasm,
   which is also a direct exercise of M6's real C++ exceptions.
3. *"`spike_fixtures.cpp` and `spike_test_main.cpp` are needed."* **Neither is.** The trimmed copy
   of upstream's `fixtures.cpp` is replaced by two `#ifndef AVM_SIM_TESTS_WITHOUT_TRACEGEN` guards,
   so nothing is vendored and nothing drifts; and the explicit `main` is replaced by
   `-Wl,-u,__main_argc_argv`, which makes wasm-ld pull **gtest's own** main. The entry point is
   `__main_argc_argv`, not `main` — wasi-sdk's clang renames it and wasi-libc's `__main_void`
   references it weakly, which is why the archive was never searched.
   The spike also excluded `simulation/gadgets/bytecode_manager.test.cpp` as reaching the proving
   side; it does not — the only `constraining` mentions in it are two comments — and its four tests
   run and pass here.

### Still open

No test here compares a tree **root** native versus wasm. `world_state_reference`'s own in-memory
trees *are* exercised by the 391 — corrected on review: the chain runs through
`vm2/testing/fixtures.cpp`, a support unit the overlay itself compiles in, whose
`get_minimal_proving_inputs()` constructs a `PublicTxSimulationTester` (holding a
`MemoryMerkleDB` by value) and is called from `HintingDBsMinimalTest`'s fixture constructor;
`gdb` on the native binary of the same tree counts **164 calls** into the reference DB across the
suite, including indexed-leaf insertion, `pad_tree`, checkpoint create/commit, roots and sibling
paths. What is missing is the *differential*: the roots are never compared between the two builds.
M8 owns that; Tier I already carries 56 identical root lines native versus wasm for the spike's
build. See `fixtures/wasm-parity/EXCLUSIONS.md`.

`crypto_merkle_tree_tests` is a target in an `AVM_WASM` configure and **does not build** for wasm
(one TU, `node_store/content_addressed_cache.test.cpp`, on `ThreadPool` under `MULTITHREADING=OFF`),
and it links `stdlib_poseidon2`. Recorded in `EXCLUSIONS.md`; the fix belongs in the `AVM_WASM`
patch, which M10 owns.

---

## Tier H — opcode-spam matrix (upstream ships it disabled)

`public_tx_simulator/apps_tests/opcode_spam.test.ts` + `fixtures/opcode_spammer.ts` (39 labelled
configs across ~30 opcodes, per-tag variants → **142 cases**, reported as `skipped` in a default
run). Gated on `RUN_AVM_OPCODE_SPAM=1`.

Its `CppVsTs` mode is **commented out upstream** (`opcode_spam.test.ts:68-72`) with the note
*"Cpp vs TS simulation is very slow (because TS is slow), so we skip it by default. It is useful to
manually run to make sure these tests perform identically between simulators."*

Re-enabling it is a one-line change and is the **cheapest available expansion of Tier A**.
Measured, both experiments run:

| experiment | result |
|---|---|
| enable the `CppVsTs` arm as-is | **142 failed / 142**, 144 s |
| …plus a blanket skip of the two revert-reason asserts when C++ returns no reason | 142 passed / 142, 145 s — **withdrawn, see below** |
| …plus a *checked out-of-gas* exemption | 140 passed / 2 failed, 153 s — **also withdrawn; its stated cause was wrong** |
| …plus the *no-C++-metadata* exemption actually shipped (M1) | **142 passed / 142**, 147 s |

All 142 first-round failures hit the *same* assertion (the structured revert-reason comparison) —
and everything before it passed for every case: `revertCode`, **all four gas dimensions**,
`publicTxEffect` and the public-inputs buffer.

### The blanket skip was wrong, and its "142 passed" is withdrawn

The first guard skipped both revert-reason asserts whenever C++ returned no reason at all, on the
stated reasoning that C++ does not plumb revert metadata for *exceptional halts* — upstream's own
comment three lines above the assert. **That reasoning does not survive measurement.**

Probe instrumentation over `opcode_spam` + `custom_bc` + `token` + `amm` + `deployments`
(2026-08-21) shows the C++ reason is absent only for **out-of-gas** halts. Every other exceptional
halt in the corpus — invalid opcode, invalid tag, addressing errors, PC out of range, truncated
instruction — **does** carry a C++ reason, and those comparisons pass in full. Upstream's comment
is about message *text* differing, and the text is already excluded from the comparison.

So the shipped guard is conditioned on out-of-gas, and it is not a skip: when C++ returns no reason
the oracle **asserts** that the TS reason is the documented out-of-gas one
(`OutOfGasError`, `avm/errors.ts:125`). That converts a silent exemption into a checked claim.

**It immediately caught two cases the blanket skip reported as green:**

| case | TS | C++ |
|---|---|---|
| `SENDL2TOL1MSG` | `SENDL2TOL1MSG: Recipient address is too large` | no reason |
| `REVERT_8` | `Assertion failed: ` — `revertReasonFromExplicitRevert`, an **explicit REVERT opcode**, not an exceptional halt at all | no reason |

### …and then the out-of-gas attribution turned out to be wrong too (M1, 2026-08-21)

Both cases are now **withdrawn as C++/TS divergences**, and the exemption has been re-conditioned.
Full evidence is in [`DRIFT.md`](../DRIFT.md) D3 and D4; the short version:

`PublicTxResult.findRevertReason()` derives the **C++** reason only from `callStackMetadata`, while
the **TS** result carries `revertReason` directly on its call-stack object via the legacy
`TODO(fcarreiro): Remove this after migration to the C++ simulator` branch of the same function.
`opcode_spam.test.ts` ships `COLLECT_META_CHECK_RET = false` — upstream's own constant — so
`collectCallMetadata` is **off** and the C++ side reports no reason **for any halt in this suite**,
out-of-gas included. The asymmetry was structural, not semantic.

Flipping the constant to `true` makes `REVERT_8` pass the reason comparison outright, and makes
`SENDL2TOL1MSG` pass it and fail later, in upstream's *own* `testSideEffectOpcodeSpam` expectation
(`fixtures/opcode_spammer.ts`), whose `allowedReasons` list — `['assertion failed', 'out of gas',
'not enough l2gas']` — does not contain the address-bound error that case produces. Measured, inner
reason `"sendl2tol1msg: recipient address is too large"`, outer C++ halting message
`"Out of gas: total L2 used 6549936 of 6540000, total DA used 786432 of 786432"`. That fixture gap
is a genuine upstream finding and stays open as `DRIFT.md` D4; it is unreachable in a default run
because `expectToBeTrue` is a no-op while the constant is false.

The shipped exemption is therefore conditioned on **the C++ result having no call-stack metadata at
all** — the real cause — rather than on the halt kind. That is strictly tighter where it matters:
in `custom_bc`, `token`, `amm` and `deployments`, which all collect metadata, the exemption can no
longer fire, so a C++ AVM that genuinely dropped a reason fails loudly instead of being excused by a
plausible-looking out-of-gas message. Measured in M1 review rather than reasoned: across those four
suites the exemption fired **0 times in 38 transactions**, and three injected divergences — C++
drops the reason, C++ reports a *different* reason, C++ reports one where TS reports none — produce
12, 12 and 7 failures respectively. Negative control: forcing the exemption's condition false makes
the arm fail with the new message.

### M2 took the flip: the arm now makes 142 REAL revert-reason comparisons

`COLLECT_META_CHECK_RET` is `true` in this tree as of M2. Measured by
`tools/measure_differential.py`, recorded in [`differential-arm-counts.json`](differential-arm-counts.json):
**142 comparisons, 142 revert-reason comparisons, 0 exemptions**, 142 s — and across the whole
corpus **216 / 216 / 0**, so the oracle's one assertion-relaxing local deviation now fires nowhere
at all. It also revives two dimensions the arm did not compare while the constant was false: the
call-stack metadata (`MAX_CALL_STACK_ITEMS`/`_DEPTH` go from 0 to 10000) and the app-logic
return-value comparison, which is guarded by `if (this.config?.collectCallMetadata)`.

The single case that fails upstream's own `allowedReasons` expectation — `SENDL2TOL1MSG`, D4 — is
neither skipped nor excused by widening upstream's list. `opcode_spam.test.ts` asserts the
known-wrong behaviour exactly: the inner reason must be
`sendl2tol1msg: recipient address is too large`, upstream's list must not contain it, and upstream's
three assertions must come out exactly `[true, false, true]`. If upstream fixes the list, that goes
red and D4 is re-decided. Full reasoning in [`DRIFT.md`](../DRIFT.md) D7, which is now `closed`.

One correction D7 carries and this section repeats, because it is the same mistake in miniature:
the "141 real reason comparisons" figure quoted before the decision was the passing **test** count.
The **comparison** count is 142 — `SENDL2TOL1MSG` passes the reason comparison and fails later.

**The paragraph below describes the state BEFORE that flip, and is kept because the measurement is
the evidence for taking it.**

**Say plainly what the old 142/142 cost in this suite, because the number invited the wrong reading.**
The same measurement shows the exemption fires on **142 of 142** opcode-spam cases, so the arm
contributes **zero** revert-reason comparisons; forcing the condition false fails all 142, which is
what proves every one of them depends on it. 142/142 is honest only about revert code, the four gas
dimensions, `publicTxEffect`, the public-inputs buffer and the tree roots. It is *not* "the revert
reason genuinely compared" — that phrasing was a review finding and is withdrawn. Recorded as
[`DRIFT.md`](../DRIFT.md) D7, alongside D2's gas blindness. The measured alternative, left open for
M2: flipping `COLLECT_META_CHECK_RET` to `true` makes the exemption unreachable here and yields
**141 real reason comparisons** in 165 s, with the single failure being D4 — upstream's own
`allowedReasons` gap, not a divergence of ours.

### The 216 are not 216 equally strong comparisons

**The differential surface goes from 74 transactions to 216**, covering
ADD/SUB/MUL/DIV/FDIV/EQ/LT/LTE/AND/OR/XOR/NOT/SHL/SHR/CAST/MOV/SET/JUMP/JUMPI/INTERNALCALL/
INTERNALRETURN/SSTORE/SLOAD/EMITNOTEHASH/EMITNULLIFIER/DEBUGLOG/POSEIDON2/SHA256COMPRESSION/
KECCAKF1600/ECADD/TORADIXBE with per-tag variants, for ~153 s of wall time. Still the cheapest
coverage available anywhere in the corpus — but read the caveat.

**The added 142 are blind to gas divergence** — recorded as [`DRIFT.md`](../DRIFT.md) D2, because
this is the caveat most likely to be dropped when the number is quoted. Mutation-tested: adding +1 L2 gas to *every* opcode
in the TS gas table is caught in `custom_bc`/`token` at the `totalGas` assertion, and is **not**
caught anywhere in `opcode_spam`. The reason is structural — opcode-spam transactions run until
they exhaust their gas limit, so both simulators consume exactly the limit no matter what the
per-opcode cost is, and the gas assertions compare two identical saturated totals. Since gas is the
single most valuable thing Tier A checks, the 142 are materially weaker than the original 74.

The three mutations that *are* caught, so the arm is not vacuous: a shifted TS noir call stack
(11 failures in `custom_bc`), a changed TS out-of-gas message (fires on every spam case), and the
gas mutation in the non-spam suites. Both edits are marked as local deviations in-source.

---

## Gaps — what upstream does not give us

These are the parts of the runtime with **no upstream fixture of any kind**, because upstream has
no equivalent component.

### Gap 1 — checkpoint/rollback semantics (narrowed, but still real)

Largely **closed** by the change of plan: we reuse upstream's `MemoryMerkleDB` rather than
implementing trees, and Tiers D, I and J now verify it (genesis oracle, native-vs-wasm root parity,
and `MerkleCheckSimulationTest` + `IndexedMemoryTree` + `HintingDBs*` passing under wasm).

What remains uncovered is **checkpoint/rollback across the three layers in lockstep** — merkle
trees, contracts DB, and `PublicPersistableStateManager` — driven by `fork()`/`merge()`/`reject()`.
The only upstream tests that touch this are `public_processor.test.ts`'s four `checkpoint depth`
cases, and they assert against a **mock**, so they pin the call sequence but not the resulting
state. Fixtures must be authored: nested fork/merge/reject at depth, revert-to-depth, and revert
during each of SETUP / APP_LOGIC / TEARDOWN, each asserting **roots** afterwards (which is what the
mock-based tests cannot do).

### Gap 2 — the timer-driven block loop (**effectively uncovered upstream**)

Upstream's block loop is `PublicProcessor.process(txs, limits)` where `limits` is
`{ maxTransactions, deadline, maxBlockGas, maxBlobFields, isBuildingProposal, signal }`.

What exists:

- `DateProvider` / `TestDateProvider` / `ManualDateProvider` in `@aztec/foundation/timer` —
  `ManualDateProvider` freezes time entirely and advances only on explicit `advanceTime()`.
  This is a genuinely good injected-clock primitive and we should adopt it rather than invent one.
- `public_processor.test.ts` covers `maxTransactions` (1 test), `maxBlobFields` (2), and
  `signal`-driven abort (1).

What does **not** exist:

- **`it.skip('does not go past the deadline')`** — `public_processor.test.ts:269`. Upstream's only
  deadline test is *skipped*. There is no passing test anywhere that the deadline is honoured.
- No test of monotonic block timestamps, minimum block spacing, or repeated blocks at all.
  `PublicProcessor` processes *one* block; the loop that produces a *sequence* of blocks lives
  above it, in the sequencer, which is not in scope and has no reusable fixture.
- `public_processor/apps_tests/timeout_race.test.ts` (4 tests) looks relevant and **is not**: it is
  entirely about a C++ libuv worker thread racing world-state reverts. With a single-threaded
  TypeScript simulator there is no race to reproduce. Its value to us is narrow but real — it
  demonstrates driving `PublicProcessor` with an injected `TestDateProvider` and a 20 ms deadline.

**Authored fixtures needed:** deterministic clock advance; a block produced per tick; deadline
truncating a block mid-tx with clean rollback; monotonic non-decreasing timestamps across blocks;
empty-block behaviour when no txs are pending; `maxBlockGas` exhaustion (untested upstream too).

### Gap 3 — CodeTracer trace output (**no upstream analogue whatsoever**)

Upstream has two tracing seams and neither produces a CodeTracer trace:

- `PublicSideEffectTraceInterface` (15 methods) — tx-level side effects, forked/merged in lockstep
  with the state manager. Covered by `side_effect_trace.test.ts` (17 tests) *for its own purpose*.
- `AvmSimulator`'s per-instruction hook — `avm/avm_simulator.ts:177`,
  `this.tallyInstructionFunction(instruction.constructor.name, gasUsed)`, called once per
  instruction. It is a **metrics tally**, not a trace: it receives only a class name and a gas
  delta, no operands, no memory, no PC.

So step-level tracing is currently a property of the TypeScript interpreter, and nothing upstream
tests trace *output* because upstream produces none.

What we do have to build against: the CodeTracer trace-format repo already ships readers,
`ct-print`, and its own fixtures (`codetracer-trace-format/codetracer_ctfs/tests/fixtures`), so the
*validation* tooling exists. The gap is Aztec-specific golden traces.

**Authored fixtures needed:** for a small set of pinned transactions (the minimal SET/SET/ADD/RETURN
tx, one Token transfer, one reverting tx, one nested external call), a golden `.ct` recording
checked by (a) reader round-trip, (b) `ct-print --full` output comparison, (c) step count equal to
the interpreter's own instruction tally, and (d) side-effect events in the trace matching
`PublicTxResult.publicTxEffect`. Item (c) is the cheap, high-value one: it cross-checks the tracer
against a number the engine already computes.

Note the structural risk: both TypeScript seams live **inside** the TS interpreter. If the
interpreter is swapped for the C++/wasm AVM, `tallyInstructionFunction` does not survive at all —
there is no TS loop to hook. Any trace fixture written against the TS interpreter is implicitly a
fixture for *that* interpreter.

**This is now much less alarming than it was.** The wasm spike added a per-instruction
`ExecutionObserverInterface` hook in the C++ AVM (`vm2/simulation/interfaces/execution_observer.hpp`,
driven from `hybrid_execution.cpp`), and `vm2_spike/avm_run.cpp`'s `StepRecorder` already consumes
it, recording `(context_id, pc, opcode, l2_gas_used)` per instruction. The runner asserts
`sameResult` between an observed and an unobserved run of the same program, so the hook is verified
non-perturbing. So the seam **does** survive the swap — but it is *our* hook in *our* fork, not
upstream's, which makes upstreaming it (or maintaining it) a real cost. A trace fixture should be
written against both seams so the two interpreters can be compared step for step.

### Gap 4 — the Brillig differential fuzzer is not stood up

Tier G1 exists in source and has never been run here. Standing it up is the highest-leverage
unclaimed item in the corpus, because it is the only oracle that does not expire with the NAPI
binary. Unknown until tried: whether a current `avm-transpiler` and a current `ssa_fuzzer` still
agree with a `3a68d68ac2`-era `avm_simulator_bin.ts`.

### Gap 5 — gmock does not work under wasm32-wasi

The single largest unclaimed coverage win. 35 of upstream's 59 vm2 simulation suites (≈243 of 387
tests) cannot run under wasm because gtest's threading layer compiles against wasi-libc's pthread
stubs and gmock's global expectation registry corrupts linear memory as a result. Details and the
failed `GTEST_HAS_PTHREAD=0` attempt are in Tier J. Fixing it is a port of gmock's synchronisation
to single-threaded wasm — bounded, but not trivial, and it is upstream-shaped work.

Until then, the honest statement is: **the AVM itself is verified identical native-vs-wasm
(transcript + 56 tree-root lines), and 141 of upstream's own semantics tests run under wasm; the
remaining 243 are blocked by the test framework, not by the VM.**

### Gap 6 — browser execution

Every one of the 757 tests runs under Node, and 16 test files import `NativeWorldStateService`.
So the suite validates the interpreter, the tx phases and the block loop, and says **nothing** about
the browser build. No upstream fixture exists for browser AVM execution because upstream's browser
path is a network hop to a node. Authored fixtures needed: the same pinned transactions executed in
a headless browser against the in-memory trees, asserting identical `publicTxEffect` and roots; plus
a bundle assertion that a public-only page never fetches the barretenberg wasm.

---

## Risks that make green numbers less reassuring than they look

1. **The C++ oracle has an expiry date.** It is the in-process NAPI AVM from the 5.0.0 npm line.
   Upstream moved to out-of-process `bb-avm-sim` on 2026-07-16. As the pinned oracle ages, Tier A
   stays green while meaning progressively less. CI must report the version gap as a number, not
   assume it.
2. **The oracle never says which side should move.** A green differential proves agreement with a
   snapshot, not correctness against current consensus.
3. **A known live divergence already exists.** AND / OR / XOR lost their dynamic L2 gas upstream
   (`instruction_spec.cpp`) and `AVM_BITWISE_DYN_L2_GAS` was removed from constants, but the
   published `@aztec/constants` nightly still ships the old value — so the revived TS gas table
   charges it, and **every test passes anyway**. This is the exact failure mode the corpus is
   supposed to catch and currently does not.
4. **602 of the 757 are self-referential.** Valuable as regression protection, worthless as
   independent evidence.
