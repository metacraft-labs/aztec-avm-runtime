# Native-vs-wasm parity fixtures

Produced by agent **fixtures-and-specs**, 2026-08-21, by execution.

## Files

| file | what |
|---|---|
| `native-with-roots.results` | `avm_spike_runner` transcript, native x86-64 |
| `wasm-with-roots.results` | the same binary built for wasm32-wasi, run under Node's WASI |
| `vm2-sim-tests-native.txt` | upstream's vm2 simulation suite, native: **387 passed / 59 suites** |
| `vm2-sim-tests-under-wasm.txt` | the same suite under wasm, per-suite: **24 pass / 35 fail, 141 tests passed** |
| `vm2-sim-tests-under-wasm-raw.txt` | the **raw** wasm gtest transcript behind that summary, kept because it is the only record of the gmock trap: the `[ FATAL ] gtest-port.h:1660` assertion and the `memory access out of bounds` in `testing::Sequence::AddExpectation` quoted below are read from it. Regenerating it costs a full wasm barretenberg build, so it is committed rather than reconstructed |
| `vm2_spike-sources/` | **preservation copy** — see the warning below |

## The headline

`diff native-with-roots.results wasm-with-roots.results` is **two lines**: the
`pointer=64bit`/`32bit` banner and the wasm-only `peakLinearMemoryPages 217 (13888 KiB)`.

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

Run the wasm suite **one gtest suite per process** — see the gmock note below.

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

## The gmock limitation

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
