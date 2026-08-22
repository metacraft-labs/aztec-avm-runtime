# Native-vs-wasm parity fixtures

Produced by agent **fixtures-and-specs**, 2026-08-21, and extended by **M8**, 2026-08-22, both by execution.

## Files

| file | what |
|---|---|
| `avm-differential-native.results` | **M8, current**: `avm_differential` transcript, native x86-64, from the tree this campaign ships (anchor + the four AVM_WASM patches + M7's overlay + M8's) |
| `avm-differential-wasm-v8.results` | **M8, current**: the same translation unit built for `wasm32-wasip1`, run on V8 through `verification/wasm_host/run_wasm_test_binary.mjs`, shipped binary unmodified |
| `native-with-roots.results` | **superseded (spike, 2026-08-21)**: `avm_spike_runner` transcript, native x86-64 |
| `wasm-with-roots.results` | **superseded (spike, 2026-08-21)**: the same binary built for wasm32-wasi, run under Node's WASI |
| `vm2-sim-tests-included.txt` | **M7, current**: the 391 tests the wasm suite runs, one name per line. Native, V8 and wasmtime pass all 391 and the three name sets are identical per test |
| `vm2-tests-wasm-exclusions.tsv` | **M7, current**: one row per excluded test — 1,412 rows of `<test>\t<file>\t<reason>` — regenerated from the tree by `just verify-vm2-tests-exclusions` |
| `EXCLUSIONS.md` | **M7, current**: the numbers, the five reason codes, the target-level exclusion and what is linked but not exercised |
| `vm2-sim-tests-native.txt` | **superseded (spike, 2026-08-21)**: 387 passed / 59 suites, from the spike's smaller `vm2_sim_tests` target |
| `vm2-sim-tests-under-wasm.txt` | **superseded (spike, 2026-08-21)**: 24 pass / 35 fail, 141 tests passed. Kept as the record of what was believed; see "The gmock limitation" below |
| `vm2-sim-tests-under-wasm-raw.txt` | the **raw** wasm gtest transcript behind that summary, kept because it is the only record of the gmock trap: the `[ FATAL ] gtest-port.h:1660` assertion and the `memory access out of bounds` in `testing::Sequence::AddExpectation` quoted below are read from it. Regenerating it costs a full wasm barretenberg build, so it is committed rather than reconstructed |
| `vm2_spike-sources/` | **preservation copy** — see the warning below |

## The headline — M8, 2026-08-22

`diff avm-differential-native.results avm-differential-wasm-v8.results` is **ten lines**, and every
one of them is `diag `-prefixed: one whose *value* differs — the pointer width, 64 versus 32 — and
nine that exist only under wasm: `wasm.peakLinearMemoryPages 173`,
`wasm.peakLinearMemoryKiB 11072`, and one `wasm.peakLinearMemoryPages.after.<program>` for each of
the seven corpus programs. Ten is the size of the comparator's own enumeration table and the count
`verify_native_wasm_transcripts_identical` asserts. (Corrected on review from "three", which counted
kinds rather than lines and predates the per-program diagnostics.) The **1,308 non-diagnostic
lines are byte-identical**, and they carry **200 root+size lines, 622 individual sibling-path
hashes (167 distinct values) and 256 genesis prefill leaf preimages, all 256 distinct**.

The `diag ` prefix is the point. "identical apart from the wasm-specific lines", implemented as a
`grep -v`, is a comparison whose scope nobody has measured — the same filter would swallow a value
divergence on any line that happened to contain the pattern. `verification/wasm_host/_transcript_compare.py`
carries a table of exactly which `diag` keys exist and on which side each may appear; a key that is
not in the table is a **failure naming the key**, and that is exercised as a negative control.

**The roots are also compared against something that is not ours.** The driver replays Tier D's
eight-step mutation sequence — the same sequence, value for value, that `drift/capture_world_state.mjs`
drove through Aztec's production LMDB `NativeWorldStateService` — inside the wasm module, and
compares all four roots and sizes after every step, plus the checkpoint/mutate/revert cycle, the
42-level genesis sibling path and all 256 prefill preimages. **129 assertions, 0 failures.** Run
`just verify-roots-vs-world-state`.

**Reproducing:** `just avm-differential` from `aztec-avm-runtime/`. It builds both, diffs them, and
exits non-zero on any divergence; `AVM_DIFF_INJECT=root|diag|same|swap|truncate` injects one.

**Coverage.** The program half is **seven hand-assembled programs, compared field for field** — an
integration check across two targets, *not* a breadth claim. Breadth is `vm2-sim-tests-included.txt`
(391 of upstream's own tests); semantics is the differential oracle's 77 comparisons.

---

## The spike's headline (2026-08-21) — superseded

`diff native-with-roots.results wasm-with-roots.results` is **two lines**: the
`pointer=64bit`/`32bit` banner and the wasm-only `peakLinearMemoryPages 217 (13888 KiB)`.

That transcript is the vm2-wasm **spike's**, taken inside `vm2wasm/` from `spike.patch`, with the
three hacks M6 later measured and removed — a header-only `crypto_merkle_tree`, a stray `lmdb.h` on
`LMDB_INCLUDE`, and `add_compile_options(-Wno-error)`. Its `217` pages does not carry over: that
driver ran every program **twice**, once with a step recorder materialising all 38,903 step records.
M8's measures 173 pages / 11,072 KiB — and peak linear memory turns out not to be a property of the
module alone, being 172 under wasmtime because the WASI environment is copied into linear memory
before `main` (demonstrated by moving it in both directions in `verify_wasm_peak_memory_budget.sh`).

All **56 tree-root lines** are identical. That is the assertion the previous transcript did not
make: it compared revert codes, gas, fees, nullifiers, note hashes, data writes, logs, call frames
and instruction counts, but never a root — and a root is the only thing that catches a wrong merkle
hash, a wrong domain separator or a wrong indexed-leaf linkage.

The roots vary across the 7 programs (7 distinct end-nullifier roots, 7 distinct end-public-data
roots), so this is a real comparison rather than a comparison of constants.

The empty note-hash root `0x2590f2aab19dd791700b4a43d3f52bb88ef2409a3731da8e848663559202e4c6` is
produced independently by three implementations: C++ `MemoryMerkleDB` under wasm, the native LMDB
`NativeWorldStateService` (`../trees/native-genesis-state.json`), and a domain-separated TypeScript
reproduction (`../../probe-mt/probe7.mjs`).

## Reproducing

```sh
cd vm2wasm/src/barretenberg/cpp
cmake --build build-native-avm-spike --target avm_spike_runner vm2_sim_tests -j12
cmake --build build-wasm-avm          --target avm_spike_runner vm2_sim_tests -j12

cd ../../../..                       # back to vm2wasm/
./src/barretenberg/cpp/build-native-avm-spike/bin/avm_spike_runner 2>/dev/null
node ../fixtures/tools/run_wasm.mjs src/barretenberg/cpp/build-wasm-avm/bin/avm_spike_runner

# upstream's own simulation suite
LD_LIBRARY_PATH=<gtest-1.17.0>/lib ./src/barretenberg/cpp/build-native-avm-spike/bin/vm2_sim_tests
node ../fixtures/tools/run_wasm.mjs src/barretenberg/cpp/build-wasm-avm/bin/vm2_sim_tests \
     --gtest_filter='<OneSuite>.*'
```

That reproduction is the **spike's**. M7's is `just verify-m7` from `aztec-avm-runtime/`, and it
runs the whole suite in **one process with no filter** on both runtimes; the per-suite splitting
below was a workaround for the ODR defect and is no longer needed.

## ⚠️ `vm2_spike-sources/` is a preservation copy, not the build input

`vm2wasm/src/` is gitignored (`.gitignore:11`), and `vm2wasm/README.md` states that *"every source
delta is captured in `vm2wasm/spike.patch`"*. The four files in `vm2_spike-sources/` are my
additions to that ignored tree and are therefore **not** yet in `spike.patch`:

| file | status |
|---|---|
| `avm_run.cpp` | **modified** — `collect_public_inputs = true` + start/end tree-snapshot printing |
| `CMakeLists.txt` | **modified** — new `vm2_sim_tests` target |
| `spike_fixtures.cpp` | **new** |
| `spike_test_main.cpp` | **new** |

Whoever owns `spike.patch` must regenerate it, or these are lost on the next reconstruction.

## The gmock limitation — SUPERSEDED by M7, 2026-08-22

> **This section is kept because it is the record of what was measured and believed on
> 2026-08-21, and because the raw transcript beside it is the only copy of that run. It is
> wrong about the cause and about the remedy.**
>
> M7 re-measured it on M6's build (wasi-sdk 33, real C++ exceptions, the module split, `-Werror`)
> and the symptom reproduces exactly — the same `gtest-port.h:1660` assertion, and
> `gtest-port.h:1642:: pthread_mutex_lock(&mutex_) failed with error 16` once the death-named
> suite is filtered out. **The cause is an ODR violation, not the pthread stubs as such.**
> googletest's own CMake puts `-DGTEST_HAS_PTHREAD=1` into `cxx_base_flags` whenever
> `find_package(Threads)` succeeds — under wasi-sdk it does, because the sysroot ships pthread
> *stubs* — and applies it to gtest's own four translation units and to nothing else. Every
> consumer of the headers sees `gtest-port.h`'s wasi default of **0**, so `internal::MutexBase`
> is a different type inside `libgtest.a` and in every test object. Making the macro consistent
> takes the suite from **0** to **391 of 391**, on V8 and on wasmtime.
>
> That is why "rebuilding gtest+gmock with `GTEST_HAS_PTHREAD=0` was tried and did not help", and
> the reason is more specific than "it has to be `PUBLIC`": the compile command is
> `$DEFINES $INCLUDES $FLAGS`, googletest puts `cxx_base_flags` in `COMPILE_FLAGS`, so its
> `-DGTEST_HAS_PTHREAD=1` arrives **after** anything `target_compile_definitions` emits and wins on
> gtest's own four units — `PRIVATE` or `PUBLIC` alike. The half of M7's correction that fixes
> gtest's side is `set(gtest_disable_pthreads ON … FORCE)`; `PUBLIC` fixes only the consumers.
> Measured on review: `PUBLIC` alone gives 4 lines at `=1` and 333 at `=0` and passes **0 of 391**,
> while making the macro consistently `=1` on all 337 passes **391 of 391** — so the wasi pthread
> stubs are not the defect, the disagreement is, and either consistent value works.
>
> The claim about death tests below is also false. There is no `EXPECT_DEATH`, `ASSERT_DEATH`,
> `EXPECT_EXIT` or `ASSERT_EXIT` anywhere in the simulation-side sources. One suite is *named*
> `AvmSimulationEccDeathTest` — a gtest naming convention that orders it first — and its body is
> `ASSERT_THROW(ecc.scalar_mul(p, scalar), std::runtime_error)`, which runs and passes under wasm.
>
> Recorded as `DRIFT.md` **D10**. The correction lives in
> `aztec-avm-runtime/verification/m7/0001-test-vm2-AVM_SIM_TESTS-*.patch` and is gated on
> `WASM AND AVM_SIM_TESTS`, so no configuration M4 or M6 measured moves.


35 of the 59 suites trap under wasm32-wasi. The correlation is exact: every gmock-free suite
passes, every suite using `EXPECT_CALL`/`StrictMock` fails. gtest's threading layer compiles
against wasi-libc's pthread **stubs**, so `pthread_self()` never matches the recorded mutex owner:

```
[ FATAL ] gtest-port.h:1660:: Condition has_owner_ && pthread_equal(owner_, pthread_self()) failed.
          The current thread is not holding the mutex
```

`MutexBase::AssertHeld()` fails inside gmock's global expectation registry and the subsequent
unguarded mutation corrupts linear memory — surfacing as `memory access out of bounds` in
`testing::Sequence::AddExpectation`. Rebuilding gtest+gmock with `GTEST_HAS_PTHREAD=0` **was tried
and did not help** (identical 24/59, 141 tests). Three further suites are gtest **death tests**,
which fork and can never run under WASI.

**This is a test-framework limitation, not an AVM one.** The AVM itself produces a byte-identical
transcript native vs wasm, tree roots included.

## Licensing

The transcripts are outputs of Apache-2.0 upstream code. `spike_fixtures.cpp` is upstream's
`vm2/testing/fixtures.cpp` (Apache-2.0) with two tracegen-bound definitions removed; the change is
stated in its header comment, as Apache-2.0 §4(b) requires.
