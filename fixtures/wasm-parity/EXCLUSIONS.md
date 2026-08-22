# Upstream's vm2 test suite under wasm — what runs, and what does not

Produced by M7, 2026-08-22, by execution. Measured at `aztec-packages` `233d8e0993` plus the
four `AVM_WASM` series patches and M7's `AVM_SIM_TESTS` overlay
(`aztec-avm-runtime/verification/m7/`).

The point of this file is that **the wasm pass rate is never quoted against a suite whose
size we chose**. Upstream's own `vm2_tests` binary is the denominator, and every test that is
not in the wasm run is named individually, with a reason, in
[`vm2-tests-wasm-exclusions.tsv`](vm2-tests-wasm-exclusions.tsv) — one row per test.

## The numbers

| set | tests | suites | source files |
|---|---:|---:|---:|
| upstream's own native `vm2_tests` | **1803** | — | 174 `*.test.cpp` under `vm2/` |
| `vm2_sim_tests`, native **and** `wasm32-wasip1` | **391** | 60 | 48 contributing + 41 mock/support |
| excluded | **1412** | 155 | 89 |

391 + 1412 = 1803, and the 391 are a **subset of the 1803 name for name**, not merely a
count that adds up. `verify_vm2_tests_exclusions_enumerated.sh` asserts the partition as
name sets, both directions, with no overlap.

## Results

| run | tests ran | passed | failed | exit |
|---|---:|---:|---:|---:|
| native `vm2_sim_tests` | 391 from 60 suites | 391 | 0 | 0 |
| wasm on **V8** (node 24.19, shipped binary unmodified) | 391 from 60 suites | 391 | 0 | 0 |
| wasm on **wasmtime 47.0.3** (memory import satisfied by `wasm-merge`) | 391 from 60 suites | 391 | 0 | 0 |

The three name sets are **identical, per test**.
[`vm2-sim-tests-included.txt`](vm2-sim-tests-included.txt) is the committed copy of that set.

## Reason codes

`AVM_SIM_TESTS` selects test sources by directory, so **where a test's source file sits is
the reason it is in or out**. Every row's reason is derived from the tree by
`verification/wasm_host/_exclusions.py`, which maps a test name back to the file declaring
its suite through gtest's own `TEST` / `TEST_F` / `TEST_P` / `TYPED_TEST` /
`INSTANTIATE_TEST_SUITE_P` macros — and **exits 4 rather than emit a row it cannot
attribute**, so the list cannot quietly grow a sixth category.

| code | tests | files | what it is |
|---|---:|---:|---|
| `proving-stack` | 1059 | 59 | `constraining/**` — the constrained-relation tests. They exercise the `vm2` module, which is declared `DEPENDENCIES sumcheck stdlib_honk_verifier goblin_avm vm2_sim boomerang_value_detection`. An `AVM_WASM` build excludes all of it. |
| `tracegen` | 286 | 24 | `tracegen/**` — trace generation, same module, same exclusion. |
| `proving-stack+dsl` | 59 | 4 | `integration_tests/**` — simulate → tracegen → prove. `vm2/CMakeLists.txt` additionally does `target_link_libraries(vm2_tests PRIVATE dsl vm2)` for these. |
| `dsl` | 5 | 1 | `dsl/avm2_recursion_constraint.test.cpp` — AVM recursion constraints over `dsl`. |
| `tracegen-fixture` | 3 | 1 | `common/avm_io.test.cpp` — the **only** simulation-side file left out. Its three tests call `testing::get_minimal_trace_with_pi()`, which builds a tracegen trace; the overlay compiles that fixture out under `AVM_SIM_TESTS_WITHOUT_TRACEGEN`. |

**No test is excluded for needing threads.** The milestone expected that category; it is
empty, and that is a result rather than an omission. `MULTITHREADING=OFF` is already the
`wasm` preset's setting and the simulation side is single-threaded by construction.

**No test is excluded for failing under wasm.** Every test the wasm binary declares, it
runs; every test it runs, it passes. There is no filter, no `--gtest_filter`, and no
per-suite process splitting anywhere in M7's harness.

## Target-level exclusion: `crypto_merkle_tree_tests`

M6's `AVM_WASM` patch makes `crypto_merkle_tree_tests` a target in an `AVM_WASM` configure —
it is one of the seven graph nodes that milestone counts. **It does not build for wasm**, and
M6 counted the node without building it. Measured here:

- exactly one translation unit fails, `crypto/merkle_tree/node_store/content_addressed_cache.test.cpp`,
  on `crypto/merkle_tree/fixtures.hpp:61: use of undeclared identifier 'ThreadPool'` — the
  `wasm` preset sets `MULTITHREADING=OFF`, which removes it;
- no `bin/crypto_merkle_tree_tests` is produced;
- and independently of that, `crypto/merkle_tree/CMakeLists.txt` links it against
  `stdlib_poseidon2`, which is proving-side, so it is not the right target for an AVM-only
  wasm build even once it compiles.

Recorded rather than fixed: the fix belongs in the `AVM_WASM` patch (M10 owns that file's
final shape), not in M7's downstream test overlay.

## `world_state_reference`: what has a target, what has coverage, and what is still open

**Corrected on review, 2026-08-22, by measurement.** The first version of this section said the
reference world state's in-memory trees were "linked into the wasm binary and not driven by any of
these 391 tests". That is false, and the reachability argument behind it stopped one hop short.

Three separate facts, which the earlier text ran together:

**1. There is no `world_state_reference` test TARGET, and that is not the same as no coverage.**
The module declares **no** `TEST_SOURCE_FILES` and has no `*.test.cpp` of its own, so no
`world_state_reference_tests` target exists in any configuration — asserted against target lists
that do carry `bin/vm2_tests`. But upstream tests the module's central component from the module
next door: `src/barretenberg/world_state/memory_merkle_db.test.cpp` declares seven
`TEST_F(MemoryMerkleDBEquivalenceTest, …)` cases which drive an ephemeral file-backed
`world_state::WorldState` and a `MemoryMerkleDB` through an identical sequence and compare roots,
sibling paths, low-leaf lookups, indexed-leaf preimages and leaf values — its own comment calls it
"the canonical-fidelity gate for MemoryMerkleDB". `world_state` is LMDB-backed and server-side, so
`bin/world_state_tests` is a native target and not a wasm one; that is why those seven are outside
this suite, and it is a target-level fact rather than a property of the tests.

**2. The reference trees ARE exercised by the 391.** The chain, each link asserted by
`verify_world_state_reference_tests_pass_under_wasm.sh`:

- `sparse_memory_tree.hpp` has exactly one consumer in the whole tree,
  `world_state_reference/memory_merkle_db.hpp`; vm2's adapter over that,
  `vm2/simulation/lib/memory_merkle_db.hpp`, has exactly two,
  `vm2/testing/public_tx_simulation_tester.hpp` and `avm_fuzzer/common/interfaces/dbs.hpp` — and
  `avm_fuzzer` is not a target in a wasm build at all;
- no `*.test.cpp` inside the target's globs names `public_tx_simulation_tester` directly — the
  three that do are the excluded `integration_tests/` files — **but `vm2/testing/fixtures.cpp`
  does**, and it is a *support* translation unit that the `AVM_SIM_TESTS` overlay itself sweeps
  into `vm2_sim_test_objects` (`file(GLOB VM2_SIM_TEST_SUPPORT_FILES testing/*.cpp)`, and ninja
  really builds `…/testing/fixtures.cpp.obj`);
- `AVM_SIM_TESTS_WITHOUT_TRACEGEN` compiles out exactly two definitions, `empty_trace()` and
  `get_minimal_trace_with_pi()`. `get_minimal_proving_inputs()` is **not** one of them, and it is a
  defined symbol in the wasm artefact;
- it constructs a `PublicTxSimulationTester`, which holds a `simulation::MemoryMerkleDB merkle_db_`
  **by value**, so constructing it builds the reference trees;
- and `simulation/lib/hinting_dbs.test.cpp:57` calls it from `HintingDBsMinimalTest`'s fixture
  constructor. `HintingDBsMinimalTest.ContractDBCheckpoints` and
  `HintingDBsMinimalTest.MerkleDBCheckpoints` are in the 391 and pass on both runtimes.

Measured directly on the native binary of the same tree (`gdb -batch`,
`rbreak ^bb::world_state::MemoryMerkleDB::`, whole suite, no filter, `[  PASSED  ] 391 tests.`):
**164 calls into the reference DB** — 2 constructions, 104 `get_tree_roots`, 8 `get_low_indexed_leaf`,
6 `get_sibling_path`, 4 `insert_indexed_leaves_public_data_tree`, 4
`insert_indexed_leaves_nullifier_tree`, 4 `pad_tree`, 4 `get_leaf_preimage_public_data_tree`,
2 `get_leaf_preimage_nullifier_tree`, 2 `create_checkpoint`, 2 `commit_checkpoint`,
10 `get_checkpoint_id` — with the backtrace
`SparseMemoryTree::update_element ← MemoryIndexedTree ← MemoryMerkleDB ← PublicTxSimulationTester ←
get_minimal_proving_inputs ← TestFactoryImpl<HintingDBsMinimalTest_ContractDBCheckpoints_Test>::CreateTest`.
So the trees are constructed, mutated, checkpointed and read.

**3. What is still open is narrower than "not exercised".** No test here compares a tree **root**
native versus wasm. The 391 exercise the trees identically on all three runtimes and agree per test,
which is evidence that they behave the same; it is not a root-value differential. M8 owns that;
Tier I of the corpus (`native-with-roots.results` / `wasm-with-roots.results`) already carries 56
identical tree-root lines native versus wasm, for the spike's build rather than this one.

Also true, and unchanged: `libworld_state_reference.a` is on the wasm test binary's link line, 73
`MemoryMerkleDB` symbols are in the artefact, and the module's *vocabulary* (`MerkleTreeId`,
`getMerkleTreeName`) reaches the tests through `vm2/simulation/interfaces/db.hpp`.

## Regenerating

```sh
just verify-vm2-tests-exclusions      # regenerates the TSV from the tree and diffs it
```

The TSV is the derivation, not a hand-maintained document: the check regenerates it from
the two binaries' `--gtest_list_tests` output and the vm2 source tree, and fails on any
difference.

## Supersedes

`fixtures/CORPUS.md` Tier J and `fixtures/wasm-parity/README.md` recorded, from the vm2-wasm
spike, "24 pass / 35 fail suites, 141 tests passed" and called the gmock failures a
permanent test-framework limitation. **That limitation is closed, not carried** — see
`README.md`'s "The gmock limitation" section, now annotated, and M7's entry in the
milestones file.
