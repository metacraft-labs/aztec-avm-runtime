# vm2 → WebAssembly feasibility spike

Agent: `vm2-wasm-spike`. Question: can Aztec's real C++ AVM (`vm2_sim`) be compiled to
WebAssembly and executed, so a browser AVM reuses the node's actual interpreter instead
of the deleted pure-TS reimplementation?

Working dir: `/home/zahary/m/blocktracer/aztec-avm-runtime/vm2wasm/`
Upstream checkout: `.../aztec-avm-runtime/upstream/aztec-packages` @ `233d8e0993` (v5.2.0 era)

---

## Phase 0 — reconnaissance (reading, not yet building)

### 0.1 The exclusion is real, and it is coarse

`barretenberg/cpp/src/CMakeLists.txt`:

```cmake
if(NOT FUZZING AND NOT WASM AND NOT BB_LITE)
    add_subdirectory(barretenberg/aztec)
    add_subdirectory(barretenberg/world_state_reference)
    add_subdirectory(barretenberg/world_state)
    # NOTE: Do not conditionally base this on the AVM flag as it defines a necessary vm2_sim library.
    add_subdirectory(barretenberg/vm2)
    add_subdirectory(barretenberg/ipc)
    add_subdirectory(barretenberg/wsdb)
    add_subdirectory(barretenberg/vm2_wsdb)
    add_subdirectory(barretenberg/cdb)
    add_subdirectory(barretenberg/avm)
    add_subdirectory(barretenberg/nodejs_module)
endif()
```

One `if` excludes ten modules at once for WASM. `vm2` is bundled with `world_state`,
`ipc`, `wsdb`, `nodejs_module` — things that genuinely cannot go to wasm. That grouping
is the reason to suspect the exclusion is inherited rather than specific: the comment on
the guard says "Fuzzing preset cannot be built with world_state as world_state cannot
compile with MULTITHREADING=OFF", which is a statement about `world_state`, not `vm2`.

### 0.2 The dependency chain to LMDB

```
vm2_sim  --DEPENDENCIES--> crypto_merkle_tree, world_state_reference
world_state_reference --> crypto_merkle_tree, aztec, crypto_poseidon2
crypto_merkle_tree --> lmdblib          <-- the named blocker
```

`crypto_merkle_tree` is one module directory containing *both* pure tree logic and an
LMDB-backed store. Files under `src/barretenberg/crypto/merkle_tree/`:

- pure: `memory_tree.hpp`, `hash.hpp`, `hash_path.hpp`, `types.hpp`,
  `nullifier_tree/*`, `indexed_tree/indexed_leaf.hpp`, `node_store/array_store.hpp`
- LMDB-coupled: `lmdb_store/lmdb_tree_store.{hpp,cpp}`,
  `node_store/cached_content_addressed_tree_store.hpp`,
  `append_only_tree/content_addressed_append_only_tree.hpp`,
  `indexed_tree/content_addressed_indexed_tree.hpp`, `response.hpp`, `fixtures.hpp`

Note there is exactly **one** non-test `.cpp` in the whole module that mentions lmdb:
`lmdb_store/lmdb_tree_store.cpp`. Everything else is header-only. That is the shape of a
link edge that exists because of one file, not because the tree algorithms need a
database. To be confirmed by build.

Encouraging: `world_state_reference` already exists and its own comment says
*"Standalone in-memory reference world state + world-state vocabulary. vm2-free and
single-threaded (no thread_pool) so it also builds under the fuzzing preset."* — i.e.
someone upstream already did the work of giving `vm2_sim` an LMDB-free, thread-free
world state. That is the configuration a wasm build wants.

### 0.3 Exceptions — the thing I expect to actually hurt

The `wasm` preset sets `CMAKE_CXX_FLAGS: "-DBB_NO_EXCEPTIONS"`. That define drives
`src/barretenberg/common/try_catch_shim.hpp`:

```cpp
#ifdef BB_NO_EXCEPTIONS
struct __AbortStream { void operator<< [[noreturn]] (const auto& error) { info(error.what()); std::abort(); } };
#define THROW __AbortStream() <<
#define try if (true)
#define catch(...) if (false)
```

`try` becomes `if (true)` and `catch` becomes `if (false)`. This is a *textual* shim: it
only rewrites code in translation units that include the shim, and it converts a throw
into `std::abort()`.

Meanwhile `vm2/simulation/` uses raw C++ `throw`/`try`/`catch` in ~327 places across ~40
non-test files. The AVM's semantics depend on this: an out-of-gas or failing opcode is
signalled by throwing, and `tx_execution` / `execution` catch it to produce a *reverted*
(not crashed) call. If exceptions are unavailable, "revert" becomes "abort the whole
wasm instance", which is not a usable AVM.

So the real question is narrower and sharper than "does it compile": **does wasi-sdk 27
clang support real C++ exceptions for wasm32-wasi, so we can simply NOT define
`BB_NO_EXCEPTIONS` for a vm2-enabled wasm build?** Everything else is CMake plumbing.

Upstream pins wasi-sdk 27 (`build-images/src/Dockerfile`). Downloading it next.

---

## Phase 1 — the exception question, settled by execution

Isolated probe (`vm2wasm/probe/exc.cpp`): a `throw`ing function called through
`try`/`catch`, exactly the shape `vm2/simulation/gadgets/execution.cpp` uses for reverts.

**wasi-sdk 27 (the version upstream pins) cannot do C++ exceptions at all.** Its sysroot
ships a libc++abi built with `-fno-exceptions`:

```
$ llvm-ar t share/wasi-sysroot/lib/wasm32-wasi/libc++abi.a
... cxa_noexception.cpp.o ...        # <- present
                                     # cxa_exception.cpp.o / cxa_personality.cpp.o ABSENT
```

Link result, with or without `-fwasm-exceptions`:

```
wasm-ld: error: undefined symbol: __cxa_allocate_exception
wasm-ld: error: undefined symbol: __cxa_throw
wasm-ld: error: undefined symbol: _Unwind_CallPersonality
```

That is why `BB_NO_EXCEPTIONS` and the `try → if(true)` / `catch → if(false)` shim exist
in barretenberg: it is a workaround for a toolchain limitation, not a design choice.

**wasi-sdk 33 fixes this.** Release notes for wasi-sdk-33 (2026-04-30) include
*"Build a sysroot that supports C++ exceptions by default"* (PR #606). The sysroot now
ships `eh/` and `noeh/` multilib variants:

```
share/wasi-sysroot/lib/wasm32-wasip1/eh/{libc++.a,libc++abi.a,libunwind.a}
share/wasi-sysroot/lib/wasm32-wasip1/noeh/{libc++.a,libc++abi.a}
```

and clang selects `eh/` automatically when `-fwasm-exceptions` is passed.

Two more flags were needed:

- `-lunwind` — the `eh/` libc++abi needs `_Unwind_RaiseException` /
  `_Unwind_CallPersonality`, and clang does not add `-lunwind` implicitly.
- `-mllvm -wasm-use-legacy-eh=false` — LLVM still defaults to the *legacy* `try`/`catch`
  opcodes, which modern runtimes reject:
  `Invalid input WebAssembly code at offset 777: legacy_exceptions feature required for try instruction`.
  Forcing the standardised `try_table` encoding fixes it.

**Result — verified by execution, not inference:**

```
$ wasi-sdk-33/bin/clang++ --target=wasm32-wasip1 -O2 -fwasm-exceptions \
      -mllvm -wasm-use-legacy-eh=false probe/exc.cpp -lunwind -o probe/exc33b.wasm
$ wasmtime run probe/exc33b.wasm
opcode ok 1
reverted: out of gas       <-- exception thrown, unwound, and CAUGHT inside wasm
opcode ok 7
survived
```

**The single biggest suspected blocker is gone.** Real C++ exceptions work on
`wasm32-wasip1`, so the AVM's throw-to-revert control flow can survive to wasm without
being rewritten to error codes. This is a toolchain-version problem, not a code problem:
upstream is on wasi-sdk 27, and the fix is to move to 33.

### 1.1 The `crypto_merkle_tree → lmdblib` edge, read at code level

Answering question 2 before building, so the build can be aimed correctly.

The whole `crypto_merkle_tree` module contains **exactly one non-test `.cpp`**:
`lmdb_store/lmdb_tree_store.cpp`. Every other file is a header. So as a *library*,
`crypto_merkle_tree` essentially IS the LMDB store; the tree algorithms are header-only
and carry no object code.

What `vm2_sim` + `world_state_reference` actually include from it, across all non-test
sources — five headers, total:

```
crypto/merkle_tree/hash_path.hpp
crypto/merkle_tree/indexed_tree/indexed_leaf.hpp
crypto/merkle_tree/memory_tree.hpp
crypto/merkle_tree/response.hpp
crypto/merkle_tree/types.hpp
```

Of these, `types.hpp` and `response.hpp` touch LMDB, and only as *vocabulary*:

- `types.hpp` includes `lmdblib/types.hpp` + `lmdb.h` solely so `TreeDBStats` can embed
  `bb::lmdblib::DBStats`. And `DBStats` needs `lmdb.h` for exactly one constructor,
  `DBStats(std::string, MDB_stat&)`. Statistics reporting. No storage.
- `response.hpp` includes `lmdb_store/lmdb_tree_store.hpp` (which in turn drags in
  `world_state/types.hpp` and five `lmdblib/*` headers) — but the AVM uses `response.hpp`
  for the *response structs* (`GetSiblingPathResponse`, `AddDataResponse`, …), which are
  plain data.

So the edge is a **header-hygiene problem, not an algorithmic dependency**. Nothing the
simulator executes calls LMDB. `vm2_sim`'s actual merkle work is header-only tree code
plus `world_state_reference`'s in-memory `memory_merkle_db` / `sparse_memory_tree`.

Corroborating evidence that upstream half-expects this: `cmake/module.cmake` already
guards the LMDB external-project dependency with
`if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "wasm32" AND NOT BB_LITE)`.

Spike approach: supply the real `lmdb.h` (header only, no `liblmdb.a`) on the include
path, and make `crypto_merkle_tree` a header-only INTERFACE module under WASM by dropping
its one LMDB `.cpp`. If that works, upstream's clean fix is to split the module — move
`lmdb_store/` into its own `crypto_merkle_tree_lmdb` and strip `DBStats` out of
`types.hpp` — but the spike does not need to do that to answer the question.

---

## Phase 2 — it builds

`vm2_sim` now compiles and archives for `wasm32-wasip1`. What it took, in full:

| # | Change | File | Size |
|---|---|---|---|
| 1 | New `AVM_WASM` option | `CMakeLists.txt` | +2 lines |
| 2 | Supply `lmdb.h` as a header-only include path for wasm (no `liblmdb.a`) | `CMakeLists.txt` | +5 lines |
| 3 | Build `crypto/merkle_tree` under WASM | `crypto/CMakeLists.txt` | 1 line |
| 4 | Under WASM make `crypto_merkle_tree` header-only (drop its single LMDB `.cpp`, drop the `lmdblib` dep) | `crypto/merkle_tree/CMakeLists.txt` | +4 lines |
| 5 | Add `aztec`, `world_state_reference`, `vm2` subdirs for WASM (NOT `world_state`/`ipc`/`wsdb`/`cdb`/`nodejs_module`) | `src/CMakeLists.txt` | +5 lines |
| 6 | Stop forcing `-fno-exceptions` on WASM | `cmake/arch.cmake` | +5 lines |
| 7 | New `wasm-avm` preset: wasi-sdk 33, `-fwasm-exceptions -mllvm -wasm-use-legacy-eh=false -lunwind`, **no** `-DBB_NO_EXCEPTIONS` | `CMakePresets.json` | +1 preset |
| 8 | Demote 4 `-Wshorten-64-to-32` warnings from errors | `src/CMakeLists.txt` | +4 lines |
| 9 | **Fix a real 32-bit bug** (below) | `vm2/simulation/lib/contract_crypto.cpp` | 1 line |

That is the whole list. **No source change to the interpreter.** `vm2/simulation/**` — the ~40
files and 327 throw/catch sites — compiled unmodified.

### 2.1 A real bug that only 32-bit exposes

`vm2/simulation/lib/contract_crypto.cpp:61`:

```cpp
FF compute_public_bytecode_first_field(size_t bytecode_size)
{
    return FF(uint256_t(DOM_SEP__PUBLIC_BYTECODE) + uint256_t(bytecode_size << 32));
}
```

`size_t` is 32-bit on wasm32, so `bytecode_size << 32` is undefined behaviour — and wasm's
`i32.shl` masks the shift count to 5 bits, so it silently evaluates to `bytecode_size << 0`.
The **public bytecode commitment would differ between native and wasm**, silently, for a
consensus-critical hash. Clang caught it as `-Wshift-count-overflow`; it would not have been
caught by any test that only runs on 64-bit.

Fixed here by widening first: `(uint256_t(bytecode_size) << 32) + uint256_t(DOM_SEP__PUBLIC_BYTECODE)`.

This is the concrete argument for why "compile it for wasm" needs a differential test, not just
a green build — and equally, the concrete argument that the exercise is *valuable to upstream*.

### 2.2 The other four are cosmetic

`world_state_reference/memory_merkle_db.hpp:108`, `vm2/simulation/gadgets/to_radix.cpp:53`,
`retrieved_bytecodes_tree_check.cpp:20`, `written_public_data_slots_tree_check.cpp:27` — all
`index_t` (uint64) → `size_t` (uint32) narrowings in tree-index arithmetic. Benign for in-memory
trees whose index space is far below 2^32; upstream would add explicit casts. Left as warnings.

### 2.3 What `vm2_sim` actually pulls in

Link closure of the wasm `libvm2_sim.a`, complete:

```
libvm2_sim.a              7,324,468   (unstripped archive)
libworld_state_reference.a  210,100
libecc.a                  2,258,286
libcommon.a                 231,034
libnumeric.a                133,366
libcrypto_poseidon2.a        30,772
libcrypto_sha256.a           19,080
libcrypto_keccak.a            3,678
libenv.a                      7,168
```

No honk, no polynomials, no srs, no flavor, no stdlib circuit builders. The AVM *simulator* really
is separable from the proving stack — the coordinator's read of the CMake dependency list holds up
at link time.

---

## Phase 3 — it executes, and it agrees with native

"Compiles" and "executes correctly" are separate claims. This phase establishes the second.

### 3.1 The driver

`vm2wasm/src/barretenberg/cpp/src/barretenberg/vm2_spike/avm_run.cpp` — one file, built from
**identical sources** for native x86-64 and wasm32-wasip1, so the two transcripts can be diffed.

It uses `PublicTxSimulationTester`, which is *upstream's own* harness (`vm2/testing/`), not
something I wrote: in-memory world state, in-memory contract DB, driving `AvmSimAPI` the way the
node's simulator does. No mocks of the interpreter, no stubs in the executed path.

Seven hand-assembled AVM programs, using upstream's `BytecodeBuilder` / `InstructionBuilder`:

| program | what it exercises |
|---|---|
| `add` | SET/ADD/RETURN — the smoke path |
| `revert` | explicit `REVERT` — the throw/catch revert path |
| `loop` | 128 MUL/ADD over U64 + tag checks + gas |
| `sha256` | `SHA256COMPRESSION` gadget |
| `poseidon2` | `POSEIDON2PERM` — the protocol's own hash |
| `storage` | `SSTORE` — public data tree write through the merkle DB |
| `burn` | tight `ADD`/`JUMP_32` loop until out-of-gas: 38,903 instructions |

### 3.2 The differential

```
$ build-native-avm-spike/bin/avm_spike_runner        > native.out
$ wasmtime run build-wasm-avm/bin/avm_spike_runner   > wasm.out
$ diff native.results wasm.results
*** RESULTS IDENTICAL ***
```

Every field matches: revert codes, L2/DA gas totals, transaction fees, emitted nullifiers, data
write counts, call-frame counts, instruction counts, and the **contract addresses** (which are
poseidon2 derivations over the bytecode — so the hashing agrees bit for bit, including the
bytecode commitment whose 32-bit bug §2.1 fixed).

Sample, identical on both:

```
-- program burn bytes=95
  address         0x21d55c7b5b27711b5770086763a3af0fa33e49364aca7ff3192c84a834aa30bb
== burn
  revertCode      1
  totalGas        1000000/1000000
  publicGas       460000/999904
  txFee           0x...1e8480
  stat total_instructions_executed = 38903
```

The `revert` program returns `revertCode 1` rather than trapping the module — i.e. the AVM's
`throw` → `catch (const OpcodeExecutionException&)` → `handle_exceptional_halt` path executes
correctly inside wasm. That is the thing `BB_NO_EXCEPTIONS` would have turned into `std::abort()`.

### 3.3 Performance and memory

Per-simulation wall time (steady_clock inside the module, so wasmtime startup excluded):

| | native | wasm | ratio |
|---|---|---|---|
| fixed per-tx cost (genesis trees, fee, nullifier) | ~25.3 ms | ~60.0 ms | 2.4× |
| `burn` total | 36.9 ms | 88.4 ms | 2.4× |
| ⇒ 38,903 instructions alone | 11.6 ms | 28.4 ms | 2.4× |
| ⇒ **throughput** | **3.4M instr/s** | **1.4M instr/s** | |

**~2.4× slower than native**, uniformly. Note the native build uses hand-written assembly for
field multiplication and the wasm build cannot (`DISABLE_ASM` is forced on for wasm), so part of
that gap is field arithmetic, not wasm itself.

Peak linear memory, read from inside the module via `__builtin_wasm_memory_size(0)`:

```
peakLinearMemoryPages 201 (12864 KiB)
```

12.6 MiB, of which 8 MiB is the stack I reserved for the AVM's recursive call machinery. Heap
usage ~4.6 MiB. The 4 GiB wasm32 ceiling is not a consideration for public execution; it is a
consideration for *proving*, which is not what this artefact does.

### 3.4 Imports — is this browser-reachable?

The reactor module's complete import list is 11 symbols, all `wasi_snapshot_preview1`:

```
environ_get environ_sizes_get clock_time_get fd_close fd_fdstat_get
fd_prestat_get fd_prestat_dir_name fd_read fd_seek fd_write proc_exit
```

No filesystem, no network, no threads at runtime — `fd_*` are libc startup and stdio only. bb.js
already ships a JS shim for exactly this set to run `barretenberg.wasm` in the browser, so the
same shim serves. I did **not** attempt `wasm32-unknown-unknown`; it has no libc and the AVM uses
`std::string`/`std::vector`/`std::unordered_map` throughout, so WASI-plus-shim is the right target
and is what bb.js already does.

---

## Phase 4 — artefact size (coordinator's required output #1)

Built a **standalone `vm2_sim`-only reactor** (`vm2_reactor/avm_reactor.cpp`): no `main`, exports
`avm_simulate_with_hints` / `avm_alloc` / `avm_free`, links only `vm2_sim` +
`world_state_reference` + `crypto_merkle_tree`. `-Oz`, `--gc-sections`, exports pruned, stripped.

| artefact | raw | gzip -9 |
|---|---:|---:|
| **`avm.wasm` — standalone AVM reactor** | **1,259,377** (1.20 MiB) | **272,486** (266 KiB) |
| `avm_spike_runner.wasm` (adds test harness + iostreams) | 1,221,184 | 295,060 |
| `barretenberg-threads.wasm` (what bb.js ships today) | 10,387,313 (9.9 MiB) | 3,069,739 (2.93 MiB) |

**The standalone AVM is 11× smaller than `barretenberg.wasm`, both raw and gzipped.**

Against the spec's 60× tension: a public-only page pays **266 KiB gzipped** for the C++ AVM, not
2.93 MiB. Versus the TS interpreter's 115 KiB that is ~2.3×, not 60×. Code splitting survives:
a public-only page loads `avm.wasm` and never fetches barretenberg.

Sharing the existing `barretenberg.wasm` instead is possible (add `vm2_sim` to
`BARRETENBERG_TARGET_OBJECTS`) but is the *wrong* trade for a browser: it would couple public
execution to a 2.93 MiB download that public-only pages currently avoid. The standalone artefact
is both smaller and better factored. Ship two modules.

Caveat: `avm_simulate_with_hints` is the *hinted-DB* entry point (self-contained). A browser AVM
wanting live world state would export `simulate` with host-imported DB callbacks instead — same
code, same size, plus a handful of imports.

---

## Phase 5 — per-instruction observation hook (coordinator's required output #2)

### 5.1 What already exists

The AVM has **three** observation seams today, all production, all config-gated:

1. `CallStackMetadataCollectorInterface` (`simulation/interfaces/call_stack_metadata_collector.hpp`)
   — `notify_enter_call` / `notify_exit_call` / `notify_tx_revert`, with lazy calldata/returndata
   providers. Gated by `PublicSimulatorConfig::collect_call_metadata`. **Call-frame granularity.**
2. `EventEmitterInterface<ExecutionEvent>` — `Execution::execute` emits **one `ExecutionEvent` per
   instruction**, carrying the wire instruction, resolved inputs/outputs, before/after context
   events (pc, gas, contract), addressing event and gas event. Injected as an interface, with three
   existing implementations (`EventEmitter`, `NoopEventEmitter`, `DeduplicatingEventEmitter`).
3. `config.collect_statistics` already reports `total_instructions_executed`.

So the information exists, and interface-injected observation is an established pattern in this
codebase — not something that would have to be invented.

### 5.2 The catch, and it is a real one

`AvmSimAPI::simulate` dispatches to **two different loops**:

- `collect_hints = true` → `Execution::execute` (`gadgets/execution.cpp`), which **does** emit a
  full `ExecutionEvent` per instruction.
- `collect_hints = false` (the fast path a browser would use) → `HybridExecution::execute`
  (`standalone/hybrid_execution.cpp`), whose header says *"It overrides the execution loop (to
  remove overhead)"* — and it emits **no** `ExecutionEvent`s at all.

So step-level tracing is available today with **zero code change** by running with
`collect_hints = true`, at hint-collection cost. For the fast path, a hook must be added.

### 5.3 I added one, and measured it

New file `vm2/simulation/interfaces/execution_observer.hpp` (38 lines), shaped deliberately like
`CallStackMetadataCollectorInterface`:

```cpp
class ExecutionObserverInterface {
  public:
    virtual void on_instruction(uint32_t context_id,
                                const AztecAddress& contract_address,
                                PC pc,
                                const Instruction& instruction,
                                const Gas& gas_used) = 0;
};
```

plus **19 lines** in `hybrid_execution.cpp`: hoist `pc`/`instruction` out of the `try` block (so
the hook still fires on an exceptional halt) and one call site in the "finally" section of the loop.
That is the entire interpreter-side change. One place, one file.

The driver implements a `StepRecorder` that appends `{context_id, pc, opcode, l2_gas_used}` per
instruction. Measured, running each program **twice** — once untraced, once traced:

| program | steps | native untraced → traced | wasm untraced → traced | same result? |
|---|---:|---|---|---|
| `add` | 4 | 25.8 → 25.4 ms | 60.3 → 59.9 ms | yes |
| `loop` | 132 | 25.2 → 25.5 ms | 60.1 → 60.1 ms | yes |
| `burn` | **38,903** | 36.9 → 37.7 ms | 88.4 → 90.5 ms | yes |

**Cost of full step-level tracing on the hottest program: +2.3% native, +2.4% wasm** — while
materialising all 38,903 step records into a vector. Disabled, the hook is one
`if (ptr != nullptr) [[unlikely]]` per instruction, below measurement noise.

And the step records are **identical between native and wasm** — same pcs, same opcodes, same
running gas:

```
first steps: (ctx1 pc0 op39 gas540027) (ctx1 pc5 op39 gas540054)
             (ctx1 pc10 op0 gas540066) (ctx1 pc15 op59 gas540075)
```

`sameResult=1` on every program: attaching the observer does not perturb the simulation.

**Verdict on the precondition: satisfied, cheaply.** Step-level tracing is not lost when the
TypeScript loop goes away. It costs a ~40-line header, a ~19-line insertion in one function, and
~2.4% runtime. In the spike I attach the observer through a process-global (`g_execution_observer`)
purely to avoid threading a 21st parameter through `Execution`'s constructor for a measurement;
upstream would inject it the way `CallStackMetadataCollectorInterface` already is, gated by a new
`PublicSimulatorConfig::collect_execution_steps` flag alongside the existing `collect_call_metadata`.

---

## Phase 6 — upstreamability (coordinator's required output #3)

Complete patch footprint against upstream `233d8e0993`, excluding my two spike-only directories
(`vm2_spike/` driver, `vm2_reactor/` size probe) and the reformatting noise in `CMakePresets.json`:

| file | + | − | character |
|---|---:|---:|---|
| `cpp/CMakeLists.txt` | 7 | 0 | new `AVM_WASM` option + lmdb-header path |
| `cpp/CMakePresets.json` | ~35 | 0 | one new preset (rest of diff is reformatting) |
| `cpp/cmake/arch.cmake` | 6 | 1 | don't force `-fno-exceptions` under `AVM_WASM` |
| `cpp/src/CMakeLists.txt` | 25 | 0 | add 3 subdirs for wasm; link opts; `-Wno-error` |
| `crypto/CMakeLists.txt` | 1 | 1 | build `merkle_tree` under wasm |
| `crypto/merkle_tree/CMakeLists.txt` | 19 | 11 | header-only variant under wasm |
| `vm2/simulation/lib/contract_crypto.cpp` | 3 | 1 | **the 32-bit shift bug fix** |
| `vm2/simulation/standalone/hybrid_execution.cpp` | 19 | 0 | the per-instruction hook |
| `vm2/simulation/interfaces/execution_observer.hpp` | 38 | — | new file |

**~80 lines of real change across 8 files, plus one new 38-line header.** Every one is additive
and behind an off-by-default `AVM_WASM` flag; nothing changes for any existing build.

How likely is each to survive upstream churn, and would Aztec take it?

- **The bug fix** — they'd take it today, wasm or no wasm. It is a latent UB on any 32-bit target.
- **`-fno-exceptions` under a flag** — small and self-contained, but it forks the wasm toolchain
  policy. The real ask is bigger and better: **move barretenberg from wasi-sdk 27 to 33**, which
  makes `BB_NO_EXCEPTIONS` and the `try → if(true)` shim unnecessary everywhere. That is a change
  they plausibly want anyway.
- **The merkle_tree/lmdb split** — my version (header-only module under wasm + a stray `lmdb.h` on
  the include path) is a *spike hack*, and the shape most likely to rot. The upstreamable version
  is the refactor it stands in for: move `lmdb_store/` into its own `crypto_merkle_tree_lmdb`
  module and lift `TreeDBStats`/`DBStats` out of `crypto/merkle_tree/types.hpp`. Maybe 200 lines of
  mechanical header surgery, and it makes the module honest regardless of wasm.
- **The CMake wiring** (splitting one `if(NOT FUZZING AND NOT WASM AND NOT BB_LITE)` into "AVM
  modules" and "server modules") — this is *tidying*, and the `FUZZING_AVM` block already proves
  the AVM modules stand alone without `ipc`/`wsdb`/`nodejs_module`.
- **The observation hook** — additive interface + one call site, matching an existing pattern.
  Acceptance depends on whether Aztec wants a debugger seam in the fast path; the 2.4% traced /
  ~0% untraced numbers are the argument.

**Assessment:** this is not a permanent downstream fork. The moving parts that would rot are the
merkle-tree hack and the preset, both of which are replaceable by refactors upstream benefits from
independently. Realistic worst case: carry ~80 lines of CMake against a repo whose CMake is stable,
plus rebase the observer hook if `hybrid_execution.cpp` is rewritten. That is an order of magnitude
less than maintaining a forked TypeScript interpreter with a drift ledger — the maintenance tax is
genuinely retired, not relocated. The honest caveat is that until the changes are actually merged,
"~80 lines" is a downstream patch set someone has to rebase, and the merkle-tree piece is the one
most likely to conflict.

---

## Phase 7 — it runs on V8 (the browser engine), not just wasmtime

wasmtime accepting a module is not proof a browser will. So the same `.wasm` was run under
**Node 25's V8** with `node:wasi` (`vm2wasm/probe/run_node.mjs`) — same engine as Chrome, same
wasm exception-handling implementation:

```
$ node probe/run_node.mjs build-wasm-avm/bin/avm_spike_runner
compiled ok; V8 accepted the module (incl. try_table exception handling)
...
exit code 0
$ diff node.results native.results
*** V8 RESULTS MATCH NATIVE ***
```

V8 accepts the standardised `try_table` encoding, executes all seven programs, catches the AVM's
reverts, and produces results **identical to native x86-64**. Step-level traces match too.

V8 is also *faster* than wasmtime here:

| | native | wasmtime | V8 (Node) |
|---|---|---|---|
| fixed per-tx cost | ~25.3 ms | ~60.0 ms | ~61.0 ms |
| `burn` (38,903 instr) traced | 37.7 ms | 90.5 ms | **80.5 ms** |
| peak linear memory | — | 12.6 MiB | 13.6 MiB |

The only thing between this and a browser tab is the WASI shim for those 11 imports — which bb.js
already ships and which browsers have no trouble with.

---

## Summary of what was established, by execution

- ✅ `vm2_sim` **compiles** for `wasm32-wasip1`, with **no change to the interpreter sources**.
- ✅ It **executes correctly**: seven AVM programs, results byte-identical to native x86-64,
  under both wasmtime and V8.
- ✅ **Real C++ exceptions work** (wasi-sdk 33 + `-fwasm-exceptions -mllvm -wasm-use-legacy-eh=false
  -lunwind`), so the AVM's throw-to-revert control flow survives unmodified.
- ✅ The `crypto_merkle_tree → lmdblib` edge is **vocabulary only** — one non-test `.cpp` and a
  `DBStats` field in a stats struct. Nothing `vm2_sim` executes touches LMDB.
- ✅ Standalone artefact: **1.20 MiB raw / 266 KiB gzipped** — 11× smaller than `barretenberg.wasm`.
- ✅ **Per-instruction observation hook** works at **+2.4%** with full step recording; ~57 lines.
- ✅ Peak memory **12.6 MiB**; the 4 GiB wasm32 ceiling is irrelevant to public execution.
- ⚠️ Found and fixed a **real 32-bit correctness bug** (`bytecode_size << 32`) that would have
  silently changed a consensus-critical hash on wasm.
- ⚠️ Requires **wasi-sdk 33**; upstream pins **27**, which cannot do exceptions at all.
- ⚠️ ~80 lines of downstream CMake patches until upstreamed; the merkle-tree piece is a hack
  standing in for a real (and independently worthwhile) module split.

---

## Final artefacts

In `/home/zahary/m/blocktracer/aztec-avm-runtime/vm2wasm/`:

| path | what |
|---|---|
| `avm.wasm` / `avm.wasm.gz` | standalone AVM reactor, stripped — **1,259,737 raw / 272,661 gzip** (with the observation hook compiled in) |
| `src/barretenberg/cpp/build-wasm-avm/bin/avm_spike_runner` | wasm differential driver |
| `src/barretenberg/cpp/build-native-avm-spike/bin/avm_spike_runner` | native reference, identical sources |
| `native.results` / `wasm.results` / `node.results` | the three transcripts that match |
| `spike.diff` | full diff against upstream `233d8e0993` |
| `probe/exc.cpp`, `probe/run_node.mjs` | the exception probe and the V8 runner |
| `shims/lmdb.h` | header-only `lmdb.h` (spike stand-in for the merkle-tree module split) |
| `wasi-sdk-33/` | the toolchain the whole thing depends on |

Reproduce:

```
cd vm2wasm/src/barretenberg/cpp
cmake --preset wasm-avm         && ninja -C build-wasm-avm avm_spike_runner avm.wasm
cmake --preset native-avm-spike && ninja -C build-native-avm-spike avm_spike_runner
wasmtime run build-wasm-avm/bin/avm_spike_runner
node ../../../probe/run_node.mjs build-wasm-avm/bin/avm_spike_runner
```

One non-obvious build input: `barretenberg/cpp/src/barretenberg/aztec/aztec_constants.hpp` is
generated (not checked in) by `protocol/constants-codegen` from the Noir protocol constants. I
generated it with `node src/cli.ts --cpp ... --selection .../cpp.json`. Any wasm CI job needs that
step, same as the native build does.
