# The reuse inventory

**One entry per Aztec component this runtime touches, with a decision and a reason.**

This file exists because the project has been wrong four times about whether a component needed
building, always in the same direction — the C++ AVM in wasm, the in-memory merkle trees, the fact
that those trees were already inside our own wasm build, and TXE. Each time the from-scratch
estimate was the most expensive and least accurate part of the plan. So construction here is a
**recorded choice**, never a default.

Checked by `just verify-reuse-inventory`
(`verification/verify_reuse_inventory_complete.sh`). The check is not cosmetic: it parses every
entry, requires every key, and requires every `build` or `replace` entry to carry a **specific**
rejection reason in one of three admissible forms. "We didn't find one" is not admissible and the
checker rejects it.

## How to read an entry

```
### RI-nn — name
- upstream: <upstream path, package, or "none — searched, see rejection-reason">
- covers: <slug>            one of the components the plan names, or `-`
- decision: depend | vendor | extend | replace | build | open
- milestone: <where the work or the verdict lives>
- why: <the reason for this decision>
- rejection-reason: <required for build/replace; must begin with one of the three tags below>
- confidence: settled | measured | reasoned | open
- experiment: <required when confidence is `open`: the experiment that would settle it>
```

**Decisions**

| decision | meaning |
|---|---|
| `depend` | consumed as upstream publishes it — a package, a library target, a header. No copy of ours. |
| `vendor` | a pinned copy in this tree, because upstream no longer ships it or ships it only inside a monorepo we cannot resolve. Governed by `PROVENANCE.md`. |
| `extend` | upstream's component, plus a change of ours — always prepared as an upstream contribution first, carried downstream only if declined. |
| `replace` | an upstream component exists and is deliberately not used. Requires a rejection reason. |
| `build` | written by us. Requires a rejection reason. |
| `open` | not yet decided. Requires the named experiment and the milestone where the verdict is due. **`open` is not a way to avoid a rejection reason** — an entry may only stay `open` until its milestone. |

**The three admissible rejection reasons.** A `build` or `replace` entry must begin its
`rejection-reason` with one of:

- `does-not-exist:` — we looked, and there is no upstream component for this. The reason must say
  **where** we looked.
- `does-not-cover:` — an upstream component exists and was read, but does not cover our case. The
  reason must say **which** component and **what** it does not cover.
- `cannot-reach-target:` — an upstream component exists and covers the case, but cannot reach a
  target we require (the browser, wasm, a size or dependency budget). The reason must name the
  target and the blocker.

---

## A. The C++ execution core

### RI-01 — AVM interpreter (`vm2_sim`)
- upstream: `barretenberg/cpp/src/barretenberg/vm2/simulation/` @ anchor `cpp`
- covers: avm
- decision: depend
- milestone: M6, M7, M8
- why: This is the consensus node's own AVM. It compiles for `wasm32-wasip1` with essentially no change to the interpreter sources, and its transcripts are byte-identical to native x86-64 under both wasmtime 47 and V8, across revert codes, all gas dimensions, nullifiers, note hashes, data writes, public logs, call frames, instruction counts and all 56 tree-root lines. The design document framed reviving a deleted TypeScript interpreter as the near-term path and this as "the endgame"; execution reversed that. Everything we would have written instead is a component whose drift we would own forever. *"No change to the interpreter sources" was too strong and M6's build corrected it.* The spike reached a green wasm build by adding `add_compile_options(-Wno-error)` under its own flag; with barretenberg's own `-Werror -Wconversion -Wsign-conversion` left promoted — which is what M6 does — **four translation units do not compile**, and fixing them takes **three source changes**, two of them under `vm2/simulation/`: `gadgets/to_radix.cpp` (+1/-1) and `lib/indexed_memory_tree.hpp` (+15/-13, the parameters that should always have been `index_t`). Measured by reverting the three one at a time and rebuilding: `indexed_memory_tree.hpp` alone accounts for `gadgets/retrieved_bytecodes_tree_check.cpp:20` and `gadgets/written_public_data_slots_tree_check.cpp:27`, `world_state_reference/memory_merkle_db.hpp` for its own TU, `to_radix.cpp` for itself. What survives of the original claim, and is what mattered, is the *revert path*: **not one added or removed line under `vm2/simulation/**` mentions `throw` or `catch`**, and the directory's census is unchanged on both sides. The census itself is now stated with its definition rather than approximated: under non-test, non-bench `.cpp` beneath `vm2/simulation/`, it is **40 files carrying 326 throw/catch sites** at `233d8e0993` — which is where "~40 files and 327" came from, within one.
- rejection-reason: n/a
- confidence: settled
- experiment: n/a

### RI-02 — In-memory world state (`world_state_reference`, `MemoryMerkleDB`)
- upstream: `barretenberg/cpp/src/barretenberg/world_state_reference/` @ anchor `cpp` (6 files), plus its vm2 adapter `vm2/simulation/lib/memory_merkle_db.hpp`
- covers: world-state
- decision: depend
- milestone: M6, M8, M14
- why: The design document's §6 — its longest section and its stated critical path — asked us to reproduce the native world state in TypeScript, adapt the deleted `@aztec/merkle-tree`, work around a domain-separator trap and write a checkpoint stack. None of that is required. Upstream added `world_state_reference` on 2026-08-04, declared `barretenberg_module(world_state_reference crypto_merkle_tree aztec crypto_poseidon2)` with no `lmdblib`, vm2-free and single-threaded — and **our own wasm build already contains it**: `libworld_state_reference.a` is in the link output and the driver that produced the matching transcripts holds a `simulation::MemoryMerkleDB`. The trees in those passing runs were Aztec's, not a mock and not a stub.
- rejection-reason: n/a
- confidence: settled
- experiment: n/a

### RI-03 — Hash policies and domain separators
- upstream: `barretenberg/cpp/src/barretenberg/aztec/aztec_hash_policy.hpp` @ anchor `cpp`
- covers: -
- decision: depend
- milestone: M6, M8
- why: Hashing is a `HashingPolicy` template parameter bound to `aztec::AztecMerkleHashPolicy`, `aztec::NullifierMerkleHashPolicy` and `aztec::PublicDataMerkleHashPolicy`. The three `DOM_SEP__*` constants are therefore never restated on our side and cannot be got wrong. This is the single highest-risk defect class in the project — an implementation that hashes internal nodes as `poseidon2([lhs, rhs])` instead of `poseidon2([SEP, lhs, rhs])` compiles, passes its own tests, and produces wrong roots for every transaction — and depending on the policy classes removes it entirely rather than testing for it.
- rejection-reason: n/a
- confidence: settled
- experiment: n/a

### RI-04 — Protocol constants (`aztec_constants.hpp`)
- upstream: generated by `protocol/constants-codegen` from `noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr` @ anchor `cpp`
- covers: -
- decision: depend
- milestone: M1, M6
- why: The header is **not checked in** upstream (confirmed by `git ls-tree` at the anchor: only `CMakeLists.txt` and `aztec_hash_policy.hpp` are tracked in that directory) and is regenerated at CMake configure time by `barretenberg/cpp/scripts/remake-constants.sh`. We reproduce the generation rather than vendoring the output, so a re-pin cannot leave us holding stale constants that still compile. `reference/constants/constants.nr` is vendored as the *input* for reading; it is never the source the build consumes.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-05 — The AVM host surface (`AvmSimAPI`, `ContractDBInterface`, `LowLevelMerkleDBInterface`)
- upstream: `barretenberg/cpp/src/barretenberg/vm2/avm_sim_api.hpp`, `vm2/simulation/interfaces/db.hpp` @ anchor `cpp`
- covers: -
- decision: depend
- milestone: M12, M13, M15
- why: The whole host surface is `simulate(const FastSimulationInputs&, ContractDBInterface&, LowLevelMerkleDBInterface&, CancellationTokenPtr)`. `ContractDBInterface` is **eight methods** — measured at the anchor: `get_contract_instance`, `get_contract_class`, `get_bytecode_commitment`, `get_debug_function_name`, `add_contracts`, and three checkpoint operations (nine `virtual` declarations, of which one is the destructor). `HighLevelMerkleDBInterface` is internal to vm2. There are no precompiles and no oracle or foreign-call surface at all. A surface this small is one to bind to, not to abstract over.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-06 — msgpack IO schemas
- upstream: `barretenberg/cpp/src/barretenberg/vm2/common/avm_io.hpp` (`MSGPACK_CAMEL_CASE_FIELDS`, `SERIALIZATION_FIELDS`) and `world_state_reference/merkle_tree_id.hpp` (`MSGPACK_ADD_ENUM(MerkleTreeId)`) @ anchor `cpp`
- covers: msgpack-io
- decision: depend
- milestone: M12, M17
- why: Upstream already declares generated msgpack schemas for the AVM's own IO types — inputs, hints, tree responses, checkpoint actions, tx effects — and there is already a cross-language golden binary (`minimal_tx.testdata.bin`) that byte-compares the TypeScript encoding against what the C++ tests consume. Inventing an encoding would mean owning both halves of a serialization contract that upstream maintains and tests. M12's deliverable is explicitly to *confirm the generated schemas cover the surface we cross* and only then to define anything of our own — and anything of our own is enumerated there with the reason no upstream schema covers it.
- rejection-reason: n/a
- confidence: reasoned
- experiment: n/a

### RI-07 — Contract DB implementation
- upstream: `PureContractDB` in `vm2/simulation/standalone/concrete_dbs.hpp` (a decorator), `TestContractDB` in `vm2/testing/`, `FuzzerContractDB` in `avm_fuzzer/common/interfaces/`, `HintedRawContractDB` in `vm2/simulation/lib/`, and the IPC-backed `cdb` module fronting the TypeScript `PublicContractsDB` @ anchor `cpp`
- covers: contract-db
- decision: extend
- milestone: M13
- why: **Settled by enumeration in M13, and the enumeration found eight implementations where this entry named three.** The three the plan named are all unfit: `PureContractDB` is a decorator with nothing to decorate — at the anchor it was the ONLY `ContractDBInterface` in `simulation/standalone/`; `TestContractDB`'s `add_contracts` has an empty body and its `get_debug_function_name` is `return std::nullopt;`, which makes two of M13's six deliverables unimplementable against it; and `cdb` links `barretenberg` and `ipc_runtime`, so it cannot reach wasm — and it is a transport adapter rather than a store, because the store it fronts is the TypeScript `PublicContractsDB` served over a unix socket by `cdb_ipc_server.ts`. The two the plan did NOT name matter too: `HintedRawContractDB` is raw, in-memory and already inside `avm.wasm`, but answers only what a previous hint-collecting run asked; and `FuzzerContractDB` implements both of the methods `TestContractDB` does not, in a `FUZZING_AVM`-gated module whose line is `DEPENDENCIES vm2` — the proving `vm2` — with an instance-log decoder that reads the wrong field order (DRIFT D12). So the answer is neither "ship it" nor "write one": it is `simulation::MemoryContractDB` under `standalone/`, beside the decorator that needs a raw one, written in Aztec's module and in a shape they could take. Writing one of ours was rejected because it would be a THIRD copy of the same map-backed store whose drift we would then own forever.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a — settled by `verify_contract_db_reuse_decision_recorded`, which re-derives the eight implementations from the fork at the anchor by one regular expression on every run, and by the five behavioural checks beside it. `CONTRACT-DB.md` carries the enumeration and the three dispositions.

### RI-08 — Per-instruction execution observer
- upstream: `vm2/simulation/events/event_emitter.hpp`'s `EventEmitterInterface<ExecutionEvent>` — a real per-instruction seam, on the wrong execution path. See the rejection reason.
- covers: -
- decision: build
- milestone: M9, M11
- why: Step-level tracing is the feature this runtime exists to provide, and it needs an observation point inside the instruction loop the AVM actually runs.
- rejection-reason: does-not-cover: **corrected in M1 review** — an earlier revision claimed upstream had no per-instruction seam and pointed at `CallStackMetadataCollectorInterface`. That was wrong twice over. `CallStackMetadataCollectorInterface` really is frame-level (its five virtuals are `set_phase`, `notify_enter_call`, `notify_exit_call`, `notify_tx_revert`, `dump_call_stack_metadata`), but upstream **does** have a per-instruction seam: `Execution::execute` emits once per instruction at `vm2/simulation/gadgets/execution.cpp:1818` into `EventEmitterInterface<ExecutionEvent>`, and `ExecutionEvent` carries `wire_instruction` (opcode + operands + addressing mode), register inputs/outputs, and `before_context_event`/`after_context_event` whose `ContextEvent` has `pc`, `gas_used` and `gas_limit`. A `NoopEventEmitter<Event>` already provides the free-when-disabled arm. What it does **not** cover is the path we run: `HybridExecution` (`simulation/standalone/hybrid_execution.hpp`) reimplements the loop expressly "to remove overhead" and never calls `events.emit`, and `AvmSimulationHelper::simulate_fast_internal` (`vm2/simulation_helper.cpp:401`) passes `NoopEventEmitter<ExecutionEvent>` — so the seam is dead on the `AvmSimAPI` path `PublicTxSimulationTester` and this runtime take. Its payload is also sized for batch witness generation (two full `ContextEvent` snapshots including three tree snapshots each, accumulated into a `std::vector`), not for streaming. So the hook is written for the fast path, shaped after the **existing `EventEmitterInterface`** rather than after the call-stack collector, and prepared as an upstream contribution (patch 4 of 5) framed as extending an observation mechanism Aztec already maintains rather than adding a second one beside it. *Two things in this entry were narrower or wider than the measurement and are corrected in M9.* **First, the surviving seam is deader than "dead on the `AvmSimAPI` path" suggests, and the correction matters because this entry is also the FALLBACK if the patch is declined**: `simulate_for_hint_collection_internal` — the `collect_hints = true` arm of `AvmSimAPI::simulate` — instantiates `simulate_for_witgen_internal<NoopEventEmitter, NoopEventEmitter>` with the comment "we don't want to collect events", so *neither* arm of the production entry point returns an `ExecutionEvent`. They materialise only in `AvmSimulationHelper::simulate_for_witgen(hints)`, a public method `AvmSimAPI` never calls, which runs a **second complete simulation** over the hinted DBs. The fallback therefore costs hint collection *plus* a re-simulation. **Second, "+2.4% with full step recording" is the WASM figure quoted as though it were both targets.** Re-measured in M9 on the 38,903-instruction program with every record materialised, traced against untraced interleaved inside one process, and given as the RANGE across sessions rather than as one draw, because it moves: **+9.0% .. +10.2% on the minimum and +9.4% .. +10.9% on the median natively**, +2.6% / +2.4% to +2.8% / +2.9% on V8 and +1.5% / +1.6% to +2.0% / +1.8% on wasmtime. The spread between targets is not a defect — the wasm32 untraced loop is about 2.3x slower, so the same absolute per-record store is a smaller fraction of it — but one number cannot serve for both. *And the seam itself is confirmed free when disabled, by an equivalence test rather than by a small number — after the estimator behind that test was replaced.* M9's review ran the identical measurement six times and got six mutually disjoint "95% intervals" spanning −1.03% to +1.48%: the interval was a bootstrap over ONE session's samples, so it described how precisely that session's median was known and not the between-session shift, which is 2–3x larger. What moves between sessions was then measured — where a binary's pages physically land, fixed for a given file and *re-drawn by a copy*: over twelve sessions the same-bytes control's session-to-session sd is **0.39pp with the files reused and 1.50pp with them re-copied**. So the SESSION is now the unit of replication: every session re-copies all three arms, one estimate is taken per session, and the 95% interval goes over the sessions. Two consecutive runs of the prepared `verify.sh` under that estimator gave **−0.44% CI [−0.63%, −0.24%]** and **−0.25% CI [−0.56%, +0.06%]**, against same-bytes controls of +0.33% and +0.09% — *overlapping*, which the intervals of the method it replaced were not. What that bounds is the patch together with the incidental code layout it causes; re-copying does not re-draw the linker's function order, and there is one build per side. *The strongest evidence that the hook is CORRECT is not a timing number at all*: every one of **39,086 step records over eight programs is field for field the `ExecutionEvent` upstream's own seam emits for the same instruction** — context id, pc, opcode, cumulative l2 and da gas, contract address — including on both shapes of exceptional halt.
- confidence: measured
- experiment: n/a

### RI-09 — `crypto_merkle_tree` / LMDB coupling
- upstream: `barretenberg/cpp/src/barretenberg/crypto/merkle_tree/` @ anchor `cpp`
- covers: -
- decision: extend
- milestone: M3, M11
- why: `crypto/merkle_tree/types.hpp` includes `lmdb.h` so `TreeDBStats` can embed `lmdblib::DBStats`. The module's tree algorithms are header-only and touch no database — the whole module contains exactly one non-test `.cpp`. The extension is a module split with independent merit (a merkle-tree library should not link LMDB to report statistics), and upstream half-expects it: `cmake/module.cmake` already guards the LMDB external-project dependency with `if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "wasm32" AND NOT BB_LITE)`. Prepared as an upstream patch (M3, verified by rebuilding both sides: 132 tests → 36 + 96, identical test-name sets, `crypto_merkle_tree_tests` carrying 144 `mdb_*` symbols before and none after); downstream carry is the recorded fallback, and the spike's stand-in (a header-only module plus a stray `lmdb.h` on the include path) is explicitly **not** reinstated — it duplicates a third-party header the tree already fetches, is invisible in the CMakeLists, and goes stale silently when the vendored LMDB revision moves. The spike that built that stand-in judged it the same way at the time: `scratchpad/campaign/vm2-wasm-spike-log.md` calls it "a *spike hack*, and the shape most likely to rot", names the module split as "the refactor it stands in for", and its closing assessment says "the merkle-tree piece is the one most likely to conflict". `vm2wasm/README.md` says the same in the artefact table. *Attribution history, so it is not re-litigated a third time*: M3 removed that attribution as unsupported after searching `campaign/avm-spike-log.md`, which is a **different** spike log — the pure-TS-AVM viability spike, which mentions LMDB exactly once, as a blocker, and never built a stand-in. The M3 review restored it against the log of the spike that did.
- rejection-reason: n/a
- confidence: reasoned
- experiment: n/a

### RI-10 — wasm exception support in barretenberg's toolchain
- upstream: `barretenberg/cpp/cmake/`, `CMakePresets.json`, `common/try_catch_shim.hpp` @ anchor `cpp`; wasi-sdk consumed as an upstream binary release
- covers: -
- decision: extend
- milestone: M4, M6, M11
- why: wasi-sdk 27, which upstream pins, cannot compile C++ exceptions at all — its sysroot ships a libc++abi with `cxa_noexception.cpp.o` and no `cxa_exception.cpp.o`. So the wasm preset defines `BB_NO_EXCEPTIONS`, which drives a textual shim (`#define try if (true)`, `#define catch(...) if (false)`) under which any C++ exception in a wasm build silently becomes `std::abort()`. wasi-sdk 33 ships `eh/` and `noeh/` multilib variants. The extension is a toolchain bump that makes retiring the shim possible across the whole codebase; it removes a workaround for a toolchain limitation rather than a design choice. wasi-sdk itself is **not** forked — it is a binary release, packaged in `nix/wasi-sdk.nix` because nixpkgs has no `wasi-sdk` attribute (parameterised by version since M4, which needs 27 as a pinned negative control; 27 is in no dev shell). Prepared as an upstream patch (M4), and **the patch as prepared moves only the pin** — `-fno-exceptions`, `BB_NO_EXCEPTIONS` and the shim stay exactly as they are, asserted from both builds' compile databases, so the shipped artefact is built the same way and removing the shim stays a separate decision (M6/M10's `AVM_WASM` work). Verified by execution rather than by citing release notes: 27 fails to link the probe with and without `-fwasm-exceptions`, naming `__cxa_allocate_exception`, `__cxa_throw`, `__cxa_begin_catch`, `_Unwind_CallPersonality` and `__wasm_lpad_context`, while the *same program with the throw removed* links and runs on the same command line; 33 links it and catches by type on wasmtime **and** V8. `barretenberg.wasm` built from identical sources with each toolchain is **1.02% smaller** under 33 (17,239,547 → 17,063,295 bytes) with a byte-identical import list (6) and C-ABI export list (5), and 1,009 native translation units carry byte-identical compile commands before and after. `ecc_tests` was **run** on both — the limitation the first write-up declared (wasmtime 47 removed the `-Sthreads` that supplied the `--import-memory` module's `env::memory`) is closed by a `node:wasi` host that supplies the memory from the module's own declared limits: **998 ran / 924 passed on both toolchains, transcripts identical line for line**. One asymmetry, in 33's favour and recorded rather than smoothed over: after that identical green summary the 27-built binary **never terminates**, and the 33-built one exits 0 — reproduced on wasmtime as well as V8, so it is the guest, and reproduced with `--gtest_filter=-*` (zero tests run), so it is the process exit path rather than anything a test leaves behind. It is confined to the single-threaded `wasm` preset: the `wasm-threads` `ecc_tests` built with 27 exits 0. The `wasm-threads` binary — the one upstream's CI runs — was executed on both toolchains under wasmtime 21 (`nix shell nixpkgs/nixos-24.05#wasmtime`, which still has `-Sthreads`): **1,104 tests from 78 suites, 1,010 passed, exit 0 on both, transcripts identical line for line**. The bump also forces a second fix: `cmake/threading.cmake`'s `wasm32-wasi-threads` triple is deprecated and fatal under `-Werror`, and every barretenberg translation unit the `wasm-threads` build reaches fails on it under 33 with **nothing failing for any other reason** (29-34 units, depending on how far the parallel build gets before ninja stops; 30 in the review's own cold run) — the four FetchContent'd gtest/gmock units get through only because they carry no `-Werror`, which is read out of the build's own `compile_commands.json`: 503/503 barretenberg TUs carry `-Werror`, 0/4 gtest/gmock TUs do.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-11 — 32-bit shift in the public bytecode commitment
- upstream: `vm2/simulation/lib/contract_crypto.cpp` @ anchor `cpp`
- covers: -
- decision: extend
- milestone: M5, M11
- why: `compute_public_bytecode_first_field` evaluates `bytecode_size << 32` on a `size_t`; where `size_t` is 32 bits this is undefined behaviour. A one-line widening to `uint256_t` fixes it. The evidence that it is an oversight rather than intent — which is what makes the patch easy to accept — is that the function *already carries* `static_assert(DOM_SEP__PUBLIC_BYTECODE <= UINT32_MAX, ...)`: the separator's width was reasoned about carefully and `size_t`'s simply was not. Prepared as an upstream patch (M5) and **measured on both sides rather than argued**. *Native neutrality is established by calling upstream's own function*: `vm2_sim` built from two worktrees of `233d8e0993` differing only by the patch, with a driver linked against each tree's own `libvm2_sim.a` calling `compute_public_bytecode_first_field` **and** `compute_public_bytecode_commitment` — the poseidon2 hash itself — over nine sizes: **18 facts per run, identical line for line**, the largest being `first_field(93000) = 0x16b480f8411f1`, which is the value the source's own comment predicts. *The 32-bit half is real execution*: the same two expressions, in barretenberg's own `uint256_t` and with its own `DOM_SEP__PUBLIC_BYTECODE`, compiled for `wasm32-wasip1` with the nix-pinned wasi-sdk 33 and run on wasmtime — the widened form agrees with x86-64 on **13 of 13** sizes and the current form on **0 of 13**. *What the UB actually does was measured, not predicted, and it is three different values in the same expression, toolchain- and optimisation-dependent rather than one definite wrong answer*: with the shift count in a `volatile`, so a real `i32.shl` is emitted, `<< 32` is masked to `<< 0` and the field becomes `DOM_SEP + bytecode_size`; with the literal 32 at the preset's `-O3`, LLVM folds the shift to poison and **the whole first field collapses to `0`**, domain separator included; and with the literal 32 at `-O0`, `0x0f8411f1`, the bare separator. (This entry said "two different things" and then listed three; corrected in M5's review, where all three were re-measured on a second wasmtime.) *One claim in this entry was wrong and is corrected*: it said the widening "produces identical codegen on 64-bit". It does not. Compiled from both sources with the same command line (clang 20, the `default` preset's `-O3 -march=skylake`), the function emits **one more instruction, 184 → 185** — the `shr` that materialises the high word the truncating form cannot produce — and the translation unit's `.text` grows **16 bytes out of 67,312**. No value moves; instructions do, and it is the same fact as "the change can only widen the set of inputs handled correctly", seen from the code generator's side. *"The only place in vm2" is now a measurement rather than a grep*: all **249** non-test `vm2` translation units in the build's own `compile_commands.json` were recompiled `--target=wasm32-wasip1 -fsyntax-only`, and exactly **one** carries `-Wshift-count-overflow`, at `contract_crypto.cpp:61:77`. *And the patch's reach is stated rather than overstated*: under barretenberg's own `-Werror`, **5** of those 249 fail for wasm32 before the patch and **4** after — the remaining four are unrelated `-Wshorten-64-to-32` / `-Wsign-conversion` narrowings in `retrieved_bytecodes_tree_check.cpp`, `written_public_data_slots_tree_check.cpp`, `written_slots_tree.bench.cpp` and `to_radix.cpp`, which this patch does not address. `-m32` was tried as a second 32-bit target and does not build at all, for an unrelated reason: `numeric/uint128/uint128_impl.hpp`'s non-native-128 fallback calls `BB_ASSERT` (an `std::ostringstream`) inside a `constexpr` function, ill-formed before C++23. Downstream carry is the recorded fallback and is the cheapest of the five: one expression in one file.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-12 — AVM-module / server-module CMake split (`AVM_WASM`)
- upstream: `barretenberg/cpp/CMakeLists.txt`, `barretenberg/cpp/src/CMakeLists.txt`, `barretenberg/cpp/src/barretenberg/crypto/CMakeLists.txt`, `cmake/arch.cmake`, `CMakePresets.json` @ anchor `cpp`
- covers: -
- decision: extend
- milestone: M6, M10, M11
- why: A single `if(NOT FUZZING AND NOT WASM AND NOT BB_LITE)` excludes ten modules at once, and its own comment is a statement about `world_state`, not about `vm2`. The extension is additive and default-off, and the existing `FUZZING_AVM` block already demonstrates the separation. This is the one patch of the five with no purpose except ours, and the plan says so rather than dressing it up — which is why it is submitted last. **Built and measured in M6.** `cmake --preset wasm-avm && ninja vm2_sim world_state_reference` produces nine wasm32 archives from a stack of four patches on `233d8e0993`; with the option off the wasm target list is identical (3,384 targets, no difference) and `barretenberg.wasm` is byte-identical (`fe9ea3c1…`, 17,063,295 bytes); forcing `-DAVM_WASM=ON` on the native `default` preset changes none of its 4,290 targets and none of its 1,008 compile commands. *One neutrality claim did not survive the measurement and is stated rather than rounded*: rewriting `add_compile_options(-fno-exceptions -fno-slp-vectorize)` as an if/else **transposes those two tokens on all 539 command lines** of a default wasm build — flag multisets equal, nothing added or removed, artefact byte-identical, but the strings are not identical and the check says so. The extension also carries a configure-time exceptions probe (`check_cxx_source_compiles` under `AVM_WASM` only), which stops wasi-sdk 27 at configure naming 33.0 and leaves the plain `wasm` preset configuring exactly as before. The `$penv{WASI_SDK_PREFIX}` correction the preset needs belongs to **RI-11's patch, not this one** — M4 already made it, and `wasm-avm` inherits it by declaring no `environment` block of its own. **Completed and re-measured in M10, which owns the patch's final shape.** Three things the entry and the write-up said did not survive execution. *First, the `FUZZING_AVM` evidence is weaker than it was stated to be and is now stated precisely*: that block adds **four** modules, `world_state` among them, because the `fuzzing-avm` preset sets `MULTITHREADING=ON` — the very constraint the main guard's comment names — so what it demonstrates is the AVM modules standing without `ipc`, `wsdb`, `cdb`, `avm` or `nodejs_module`, and not the three-module group on its own. `PR.md`, the patch's commit message and the comment the patch adds to `src/CMakeLists.txt` all said "already builds exactly this set" and all three are corrected. *Second, "every existing preset is unaffected" is now a statement rather than a sample*: `barretenberg/cpp` declares 42 configure presets and this host can configure a handful, so the module guard is settled by lifting its region verbatim out of each tree and evaluating it with `cmake -P` over **all 32 assignments** of the five variables its conditions reference (`FUZZING`, `WASM`, `BB_LITE`, `AVM_WASM`, `FUZZING_AVM`) — 30 rows identical, 2 gaining exactly `aztec`, `vm2` and `world_state_reference` and losing nothing. *Third, native neutrality now has a test result behind it and not only a compile database*: the patch changes three C++ files every native build compiles, so upstream's own `world_state_tests` (33/33) and `vm2_tests` (1,803 declared, 1,800 ran, 1,798 passed, 2 skipped) were built and run on both sides with the declared, ran and passed NAME SETS identical, closing `PR.md`'s "the AVM's own test suite was not run" limitation on its native half. The dependency claim is also split: only the merkle/LMDB patch is an **apply** prerequisite (`git am` onto the bare base is rejected on `crypto/CMakeLists.txt`); the wasi-sdk bump and the widening fix are **build** prerequisites, the latter measured as exactly one failing translation unit.
- rejection-reason: n/a
- confidence: reasoned
- experiment: n/a

### RI-13 — Proving stack (honk, polynomial, srs, flavor, circuit builders)
- upstream: `barretenberg/cpp/src/barretenberg/{honk,polynomials,srs,flavor,...}` @ anchor `cpp`
- covers: -
- decision: replace
- milestone: M6, M12
- why: We do not prove, so the entire proving half of barretenberg is excluded from the link closure rather than reimplemented or stubbed. Every receipt the runtime issues carries `proving: 'none'`, and §8.4's disclosure makes that un-ignorable rather than a footnote.
- rejection-reason: does-not-cover: the proving stack exists, works, and is what the real node uses — it simply does not serve this runtime's purpose, which is *execution* with a trace. "Replace" here means "excluded from the link closure", not "reimplemented": nothing takes its place. It is recorded because excluding it is a decision with consequences (no `AvmProvingRequest` generation in M22; a public-only browser page never fetching `barretenberg.wasm` in M27), and because the exclusion is to be asserted rather than assumed: `verify_wasm_link_closure_excludes_proving` **is written and passing as of M6**, and fails if a honk, polynomial, srs, flavor or circuit-builder archive appears. It is measured two ways from the real `AVM_WASM` build rather than from the spike's link line: `vm2_sim`'s transitive closure in CMake's own target graph, and the set of archives ninja actually produces in a build directory made fresh first — nine, none of them proving. The absence is **not vacuous**: the `wasm-avm` preset inherits `wasm`, so `honk`, `polynomials`, `srs`, `flavor`, `stdlib_circuit_builders`, `sumcheck`, `commitment_schemes`, `stdlib_honk_verifier`, `goblin_avm` and `ultra_honk` are all real static-library targets *in that very build tree*, each asserted to exist there before its absence from the closure is claimed. At symbol level, `llvm-nm -u` over `libvm2_sim.a` (3,338 undefined) and `libworld_state_reference.a` (76) reports **zero** proving-stack symbols and zero `mdb_*`.
- confidence: settled
- experiment: n/a

---

## B. C++ test harnesses and their build

### RI-14 — vm2 test harness (`PublicTxSimulationTester`, `BytecodeBuilder`, `InstructionBuilder`)
- upstream: `barretenberg/cpp/src/barretenberg/vm2/testing/` @ anchor `cpp`
- covers: test-harnesses
- decision: depend
- milestone: M2, M8
- why: These drive `AvmSimAPI` over `simulation::MemoryMerkleDB` and a contract DB with **no mock in the executed path**. They are what produced the native and wasm transcripts that agree byte for byte. A harness we wrote ourselves would prove that we are self-consistent; this one is the harness upstream uses to convince themselves.
- rejection-reason: n/a
- confidence: settled
- experiment: n/a

### RI-15 — Upstream's own vm2 test suite
- upstream: `barretenberg/cpp/src/barretenberg/vm2/**/*.test.cpp` (174 files) @ anchor `cpp`
- covers: test-harnesses
- decision: depend
- milestone: M7
- why: The highest-value verification available for the least construction. Seven hand-assembled programs prove integration; upstream's suite proves correctness across the surface Aztec themselves consider covered, and they keep proving it. **Re-measured by M7 on M6's build, and the earlier figure is superseded rather than reconciled**: upstream's own native `vm2_tests` declares **1,803** tests over 174 files; the simulation-side subset that an `AVM_WASM` build can carry is **391** over 60 suites, and it runs 391 / passes 391 / exits 0 natively, on V8 and on wasmtime 47, with the three name sets identical per test and the 391 a subset of the 1,803 name for name. The 1,412 outside it are recorded one row per test in `fixtures/wasm-parity/vm2-tests-wasm-exclusions.tsv`. The spike's earlier "59 suites / 387 native, 141 under wasm" was a different, smaller target and a gtest ODR defect (DRIFT D10), not a property of the AVM.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-16 — The build target that runs those tests under wasm
- upstream: none **for wasm**. `vm2_sim` is declared with **no** `TEST_SOURCE_FILES`, the `vm2_tests` binary that carries them is gated on `if(AVM)` (which pulls in the proving stack the wasm build excludes), and the whole `vm2/` directory is excluded from a wasm configure. Natively `vm2_tests` builds by default.
- covers: test-harnesses
- decision: build
- milestone: M7
- why: The suite (RI-15) is upstream's; the target that compiles it for `wasm32-wasip1` is not and cannot be. **What we build is smaller than this entry first said**: M7 does not add a bespoke runner at all — it gives `vm2_sim` its own `TEST_SOURCE_FILES` under a default-off `AVM_SIM_TESTS` option, so `vm2_sim_tests` is produced by barretenberg's *own* `cmake/module.cmake`, with upstream's `add_executable`, upstream's gtest/gmock linkage and upstream's `-Wl,-z,stack-size=8388608`. The spike's three support files are all gone: `spike_fixtures.cpp` (a trimmed copy of upstream's Apache-2.0 `vm2/testing/fixtures.cpp`) is replaced by two `#ifndef` guards on the two tracegen-bound definitions, so nothing is vendored and nothing drifts; `spike_test_main.cpp` is replaced by `-Wl,-u,__main_argc_argv`, which makes wasm-ld pull gtest's own `main`; and the third, `avm_run.cpp`, was never part of this target. The overlay touches nine files, adds no file at all, and adds no test source: five of the nine are narrowing corrections in upstream's own test sources, three are CMake and one is the fixtures guard.
- rejection-reason: does-not-exist: searched the whole `barretenberg/cpp` CMake graph at the anchor. `vm2_sim`'s `barretenberg_module` declaration lists no test sources, and the only target that does — `vm2_tests` — is inside `if(AVM)` together with `sumcheck`, `stdlib_honk_verifier` and `goblin_avm`. There is no configuration of upstream's build that produces a **wasm** binary running `vm2/simulation/**/*.test.cpp` — and the decisive gate is one level above `if(AVM)`: `src/CMakeLists.txt:123` wraps `add_subdirectory(barretenberg/vm2)` in `if(NOT FUZZING AND NOT WASM AND NOT BB_LITE)`, so under wasm the directory is never added and `if(AVM)` is never evaluated. Natively it is a different story and the entry does not claim otherwise: `option(AVM ... ON)` is default-on, so an ordinary native build does produce `vm2_tests` — which is exactly the 387 tests RI-15 reports. What we build is one CMake option and the `TEST_SOURCE_FILES` list that goes with it, over 89 upstream translation units, and it is additive: with `AVM_SIM_TESTS` off, a wasm configure declares no `vm2_sim_tests` and no `vm2_sim_test_objects` target at all, which is asserted.
- confidence: measured
- experiment: n/a

### RI-17 — gtest/gmock under `wasm32-wasip1`
- upstream: gtest/gmock v1.13.0, consumed through barretenberg's FetchContent
- covers: test-harnesses
- decision: depend
- milestone: M7
- why: **Closed by M7, by finding the actual cause.** The failure reproduces on M6's build — `[ FATAL ] gtest-port.h:1660:: Condition has_owner_ && pthread_equal(owner_, pthread_self()) failed`, and with the death-named suite filtered out, `gtest-port.h:1642:: pthread_mutex_lock(&mutex_) failed with error 16` — but it is not the pthread stubs as such. googletest's own CMake puts `-DGTEST_HAS_PTHREAD=1` into `cxx_base_flags` whenever `find_package(Threads)` succeeds, which under wasi-sdk it does, and applies it to gtest's own four translation units only; every consumer of the headers falls back to `gtest-port.h`'s wasi default of 0. `internal::MutexBase` is therefore a different type on the two sides of the library boundary, and every wasm gtest binary barretenberg builds is an ODR violation. Making the macro consistent (`gtest_disable_pthreads` plus `PUBLIC` compile definitions, gated on `WASM AND AVM_SIM_TESTS`) takes the suite from 0 to **391 of 391**. Recorded as DRIFT **D10**; the same file has the same shape twice more, with `GTEST_HAS_EXCEPTIONS=0` and `GTEST_HAS_STREAM_REDIRECTION=0` `PRIVATE` on gtest under WASM — and the first of those is wrong for an `AVM_WASM` build, which has real exceptions.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a — done. The experiment this entry proposed was run and its premise was wrong in two places. "Rebuilding gtest+gmock with `GTEST_HAS_PTHREAD=0` did not help" is consistent with the ODR diagnosis rather than against it, though not for the reason first recorded here: the compile command is `$DEFINES $INCLUDES $FLAGS`, and googletest's `cxx_base_flags` reaches the compiler through `COMPILE_FLAGS`, i.e. through `$FLAGS`, **after** anything `target_compile_definitions` puts in `$DEFINES`. So `GTEST_HAS_PTHREAD=0` added to gtest is overridden on gtest's own four translation units whether it is `PRIVATE` or `PUBLIC`; the half of the correction that fixes gtest's side is `set(gtest_disable_pthreads ON … FORCE)`, which changes `cxx_base_flags` itself, and `PUBLIC` fixes only the consumers. Measured on review: a variant carrying the `PUBLIC` definitions **without** `gtest_disable_pthreads` produces 4 command lines at `=1` and 333 at `=0` and passes **0 of 391**, dying on the same `gtest-port.h:1660` condition. And "three further suites are gtest death tests, which fork and can never run under WASI" is false — `grep -rn 'EXPECT_DEATH|ASSERT_DEATH|EXPECT_EXIT|ASSERT_EXIT'` over every simulation-side test source returns nothing; one suite is *named* `AvmSimulationEccDeathTest`, a gtest ordering convention, and its body is `ASSERT_THROW(..., std::runtime_error)`, which runs and passes under wasm. The discriminating evidence is `verify_vm2_tests_pass_under_v8.sh`'s `odr` control: the same tree with only the `cmake/gtest.cmake` hunk reverted builds, links and then passes **0** of 391. That control shows the hunk is load-bearing but cannot separate "the two sides disagree" from "the wasi pthread stubs do not work"; a review experiment can, and does. Making the macro **consistently `=1`** on gtest's own four translation units and on all 337 consumers — `gtest_disable_pthreads` left off, `target_compile_definitions(gtest PUBLIC GTEST_HAS_PTHREAD=1 …)` — builds, links and passes **391 of 391**, exit 0. The stubs are not the problem; the disagreement is. Either consistent value works.

### RI-18 — Native-vs-wasm transcript driver (`avm_run.cpp`, `StepRecorder`)
- upstream: none for a deterministic printable transcript; `PublicTxSimulationTester` (RI-14) supplies everything underneath it
- covers: -
- decision: build
- milestone: M8, M12
- why: The differential between native and wasm needs a program whose entire output is a deterministic text transcript, so two builds can be diffed byte for byte.
- rejection-reason: does-not-exist: upstream's equivalents were read and none is a program whose **entire output** is a deterministic transcript — the gtest suites assert internally and print pass/fail, the AVM fuzzer compares three in-process C++ `TxSimulationResult`s structurally (`avm_fuzzer/fuzzer_lib.cpp:195`) and is `if(FUZZING_AVM)`-gated and native, `bb-avm-sim` (`barretenberg/avm/cli.cpp`) has exactly one leaf subcommand, `msgpack run`, requiring an IPC socket path and no `--dump`/`--trace`/`--print`, and `bb avm_simulate` only times the run. A per-instruction *line* does exist — `execution.cpp:1764` and `hybrid_execution.cpp:53` both `debug("@", pc, " ", instruction.to_string())` — but it is `#ifndef NDEBUG`, interleaved with other log output, carries no gas or memory, and is not the program's entire output, so it cannot be diffed between two builds. What we build is ~290 lines of driver over upstream's own harness; every simulation primitive underneath it is RI-14's.
- confidence: measured
- experiment: n/a — done, and the entry is now about a driver that exists in this tree rather than about the spike's. M8 built it: `barretenberg/cpp/src/barretenberg/vm2/differential/avm_differential.cpp`, added by `verification/m8/0001-test-vm2-AVM_DIFFERENTIAL-…patch` behind a default-off `AVM_DIFFERENTIAL` option, compiled by the same CMake code for x86-64 and for `wasm32-wasip1`. The rejection reason survived contact with the work: nothing upstream prints a deterministic whole-program transcript. Two things about the SPIKE's driver did not survive and are not carried: its `StepRecorder` and the `g_execution_observer` process global it hangs off belong to M9 and are absent here, and its `avm_run.cpp` was built inside `vm2wasm/` from `spike.patch` with `-Wno-error` and two other hacks M6 removed. Measured 2026-08-22: **1,308 non-diagnostic transcript lines byte-identical** native versus wasm, 200 root+size lines, 622 sibling-path fields, 256 leaf preimages; the whole difference is **ten** enumerated `diag` lines (corrected on review from "three", which counted kinds: one key whose value differs and nine that exist only under wasm).

### RI-50 — Upstream's own reference-versus-real world-state fidelity gate
- upstream: `barretenberg/cpp/src/barretenberg/world_state/memory_merkle_db.test.cpp` @ anchor `cpp` — seven `TEST_F(MemoryMerkleDBEquivalenceTest, …)` cases, in the `world_state_tests` target
- covers: world-state
- decision: depend
- milestone: M8
- why: **The reuse audit's answer to "how do we know the in-memory world state is faithful to the real one" is: upstream already asks that question, in seven cases, and maintains the answer.** The file's own header says it "is the canonical-fidelity gate for MemoryMerkleDB": it drives an ephemeral, file-backed `world_state::WorldState` and an in-memory `MemoryMerkleDB` through the same sequence and compares, after every step, roots, sibling paths, low-leaf lookups, indexed-leaf preimages and leaf values — `GenesisMatches`, `AppendNoteHashes`, `PadNoteHashTree`, `InsertNullifiers`, `InsertAndUpdatePublicData`, `Checkpoints`, `MixedSequence`. M8's deliverable asked for exactly this "rather than a dual-run harness of ours", and it is consumed as upstream publishes it: `verify_upstream_world_state_reference_gate_green.sh` asserts the source is byte-identical to the anchor, that no patch in our series touches it, that it really constructs a real `WorldState` (a reference-versus-reference comparison would be the one shape that makes the gate worthless), then runs it and asserts the seven **by name**. Measured 2026-08-22: 7 ran, 7 passed, exit 0. It runs NATIVELY and cannot run under wasm — `world_state` is LMDB-backed and `src/CMakeLists.txt` adds that subdirectory only under `if(NOT FUZZING AND NOT WASM AND NOT BB_LITE)`, asserted both ways — which is also why these seven are outside M7's 391.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-51 — `PublicTxSimulationTester::merkle_db()`
- upstream: `barretenberg/cpp/src/barretenberg/vm2/testing/public_tx_simulation_tester.hpp` @ anchor `cpp` — the class exposes `contract_db()` and holds `simulation::MemoryMerkleDB merkle_db_` privately
- covers: world-state
- decision: extend
- milestone: M8, M11
- why: The differential has to emit tree roots after every mutating operation, and the tester's own mutating helpers (`deploy_contract`, `set_public_storage`, `insert_siloed_nullifier`, `append_note_hash`, `append_l1_to_l2_message`) all write to a database no caller can read. Two lines beside the existing `contract_db()` accessor. It is an asymmetry rather than a safety property: the two databases carry independent `create`/`commit`/`revert` and the simulator requires them to stay in lockstep, which is M13's whole risk, so exposing one half and not the other is the thing that needs justifying. Prepared as part of M8's overlay patch; M10 owns the final shape of what goes upstream and M11 owns submission.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a — the accessor is used by `avm_differential.cpp` and the roots it exposes are compared against Tier D's capture from the real world state, so it is exercised rather than merely added.

---

## C. TypeScript orchestration (vendored from the `ts` anchor)

Everything in this section shares one reason for being `vendor` rather than `depend`: upstream
**deleted** it in `4377ddf64c` (2026-06-26) as *redundant*, not broken. It is not published from any
current package, and the version that is published is inside a monorepo whose
`workspace:`/`portal:` resolution we cannot use. Per-entry `why` therefore records what the
component is and what it costs us, and does not repeat the deletion.

### RI-19 — Public transaction simulator (`public_tx_simulator/`)
- upstream: `yarn-project/simulator/src/public/public_tx_simulator/` @ anchor `ts`
- covers: transaction-simulator
- decision: vendor
- milestone: M18, M19
- why: The three-phase transaction model — SETUP / APP_LOGIC / TEARDOWN, the asymmetric revert semantics, gas and fee accounting through `PublicTxContext` — is consensus behaviour, not glue. It is also where the interpreter swap seam lives: `PublicTxSimulatorInterface` and the `createPublicTxSimulator` factory were built by Aztec to run two AVM implementations side by side, which is exactly the seam a wasm AVM plugs into. We did not design it and are not stretching it.
- rejection-reason: n/a
- confidence: settled
- experiment: n/a

### RI-20 — State manager (`state_manager/`)
- upstream: `yarn-project/simulator/src/public/state_manager/` @ anchor `ts`
- covers: -
- decision: vendor
- milestone: M18
- why: `PublicPersistableStateManager` is the layer directly above the merkle trees: siloing, note-hash uniqueness, nullifier and public-storage semantics, and the `fork()`/`merge()`/`reject()` discipline that nested calls and reverts depend on. Its 32 upstream unit tests come with it.
- rejection-reason: n/a
- confidence: settled
- experiment: n/a

### RI-21 — Block processor (`public_processor/`)
- upstream: `yarn-project/simulator/src/public/public_processor/` @ anchor `ts`
- covers: block-processor
- decision: vendor
- milestone: M18, M22
- why: `PublicProcessor.process(txs, limits)` is upstream's block orchestration and is imported at upstream HEAD by four production consumers — the validator client, the prover node, the aztec node and TXE itself. It already does a fork checkpoint per transaction, dispatch on `tx.hasPublicCalls()`, then commit or revert, and it already honours `maxTransactions`, `deadline`, `maxBlockGas`, `maxBlobFields` and `signal`. `GuardedMerkleTreeOperations` is kept with it and documented as vestigial rather than deleted: its original reason evaporates without a native simulator, but it still enforces "no world-state access after the block is sealed", and deleting it means diverging from upstream for no gain.
- rejection-reason: n/a
- confidence: settled
- experiment: n/a

### RI-22 — Side-effect trace (`side_effect_trace*.ts`)
- upstream: `yarn-project/simulator/src/public/side_effect_trace.ts`, `side_effect_trace_interface.ts`, `side_effect_errors.ts` @ anchor `ts`
- covers: side-effect-trace
- decision: vendor + extend
- milestone: M18, M25
- why: Vendored because it carries the per-transaction side-effect limits and the fork/merge-on-revert semantics, with 17 upstream tests covering exactly those cases. Extended in M25 by a `CodeTracerSideEffectTrace` that **decorates** the real `SideEffectTrace` rather than replacing it, so limit enforcement is untouched and its `fork()`/`merge()` happen in lockstep with the state manager's own — which means nested calls and reverts are handled for free and our observer never models the call tree itself. A replacement would have had to reimplement the limits and would have got the revert semantics subtly wrong.
- rejection-reason: n/a
- confidence: settled
- experiment: n/a

### RI-23 — DB interfaces and public DB sources
- upstream: `yarn-project/simulator/src/public/{db_interfaces.ts,public_db_sources.ts,hinting_db_sources.ts,contracts_db_checkpoint.ts,debug_fn_name.ts}` @ anchor `ts`
- covers: contract-db
- decision: vendor
- milestone: M18, M13
- why: The TypeScript-side view of the same contract-DB and world-state surfaces RI-05 and RI-07 cover on the C++ side. `SimpleContractDataSource` is already an in-memory contract source, so this layer works unchanged in the browser without any adaptation of ours.
- rejection-reason: n/a
- confidence: settled
- experiment: n/a

### RI-24 — TypeScript AVM interpreter (`public/avm/`)
- upstream: `yarn-project/simulator/src/public/avm/` @ anchor `ts`
- covers: avm
- decision: vendor
- milestone: M18, M19
- why: Vendored as a **reference implementation and a second opinion**, explicitly not as the shipped interpreter — RI-01 is. Its value is that it is a differential counterpart written by the same organisation from the same spec: `e2e_differential_wasm_vs_ts_interpreter` compares the wasm AVM against it, and the Brillig fuzzer (RI-34) drives it with no C++ at all. Its steady-state value declines once the shipped interpreter *is* the C++ AVM, and the plan says so.
- rejection-reason: n/a
- confidence: settled
- experiment: n/a

### RI-25 — Differential harness (`CppVsTsPublicTxSimulator`)
- upstream: `yarn-project/simulator/src/public/public_tx_simulator/cpp_vs_ts_public_tx_simulator.ts` @ anchor `ts`
- covers: test-harnesses
- decision: vendor + extend
- milestone: M2, M19
- why: Per transaction it already asserts equal revert code, all four gas dimensions, the full public tx effect, the AVM circuit public-inputs buffer, every return value and the resulting tree roots. Extended in two ways, both recorded. First, the revert-reason exemption: upstream's is unconditional ("C++ returned no reason"), ours is conditioned on the C++ result carrying **no call-stack metadata at all**, and asserts loudly if C++ has metadata but no reason where TS has one — so in every suite that collects metadata (`custom_bc`, `token`, `amm`, `deployments`) it cannot fire, and the reason is genuinely compared. Measured in M1 review: across those four suites the exemption fired **0 times in 38 transactions**, and three injected divergences (C++ drops the reason, C++ reports a different reason, C++ reports a reason where TS reports none) are all caught. The counterweight is recorded rather than left implicit: in `opcode_spam`, which ships upstream's `COLLECT_META_CHECK_RET = false`, the exemption fires on **142 of 142** cases, so that arm contributes **zero** revert-reason comparisons — see `DRIFT.md` D2 and D7. An earlier revision of this line described the exemption as a *checked out-of-gas* one that "surfaced two real divergences"; both halves were wrong and are withdrawn (`DRIFT.md` D3, D4). Second, M19 turns it into a three-way comparator. The inverted upstream naming (`useCppSimulator: false` selects the *differential* simulator) is fixed in our tree rather than merely documented, because it has already caused a coverage figure to be overstated by an order of magnitude once.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-26 — `ForkCheckpoint`
- upstream: `@aztec/world-state/native` @ anchor `ts` — `world-state/src/native/fork_checkpoint.ts`, 46 lines over `MerkleTreeCheckpointOperations`
- covers: -
- decision: vendor
- milestone: M18
- why: **Corrected in M18, and the correction is to the scope rather than to the decision.** This entry, and M18's deliverable, both said it is the *only* production `@aztec/world-state/native` import in the whole non-test subtree, with a carve-out for four non-test files importing `NativeWorldStateService` from the *bare* specifier. Enumerated over the whole fork at the anchor and split on the path rather than on the grep line, the SUBPATH has **sixteen** import sites of which **three are production**: `simulator/src/public/public_processor/public_processor.ts:49` (`ForkCheckpoint`), `txe/src/oracle/txe_oracle_top_level_context.ts:83` (`ForkCheckpoint`) and `txe/src/state_machine/synchronizer.ts:12` (`NativeWorldStateService`). So the exclusivity holds of the SIMULATOR subtree — the orchestration RI-19..RI-23 vendor — and not of the tree as a whole; the other two are in `txe/`, which RI-39 has open for M23. The decision survives on the reason that actually decides it: the class's only import is an `import type`, so the copy has no runtime dependency, and severing the specifier is what lets RI-27's replacement be total rather than partial. **It is 46 lines and it could not be copied verbatim**: the constructor uses parameter properties, which Node's type stripper refuses with `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX` and `tsc --erasableSyntaxOnly` with TS1294, so the two are desugared into two fields and two assignments and `verify_orchestration_reuse_enumerated` diffs the body against upstream's and requires the difference to be EXACTLY that. Vendoring a file to sever a dependency edge is a habit worth being suspicious of, which is why this entry exists rather than the copy being silent.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

---

## D. npm packages, and the ones we refuse

### RI-27 — `@aztec/world-state` (native LMDB world state)
- upstream: `yarn-project/world-state`, npm `@aztec/world-state`
- covers: world-state
- decision: replace
- milestone: M18, M28
- why: 21 files in the vendored tree import `NativeWorldStateService` — 17 tests and **four non-test** files (`public/fixtures/public_tx_simulation_tester.ts`, `public/avm/fixtures/avm_simulation_tester.ts`, `public/fuzzing/avm_fuzzer_simulator.ts`, `public/fuzzing/avm_simulator_bin.ts`) — so this is a real dependency of the code as it stands, larger than a test-only one, and severing it is a decision.
- rejection-reason: cannot-reach-target: the target is a browser page with no server. `NativeWorldStateService` is an LMDB-backed NAPI addon; it is a native binary, it needs a filesystem, and no polyfill makes it reachable. What replaces it is **not code of ours** — it is RI-02, Aztec's own `world_state_reference` compiled to wasm, which is why this entry is `replace` and not `build`. The native service is retained on the verification side only, as the Tier D oracle that RI-02's roots are checked against, and M28 asserts it is unreachable from any browser entry point.
- confidence: settled
- experiment: n/a

### RI-28 — `@aztec/merkle-tree` (the deleted TypeScript trees)
- upstream: npm `@aztec/merkle-tree@5.0.0-nightly.20260316`, removed upstream in `e264dd4893` (2026-03-16)
- covers: world-state
- decision: replace
- milestone: M16
- why: The design document's §6 assumed this package would be adapted. It is now a priced, held-ready fallback rather than the plan, and M16's triggers are narrowed so that *doubt about the trees is not one of them*. **M16 evaluated all three triggers and none fired**, so the milestone closes as not-required; the evaluation, the price and the hazard's target values are in `FALLBACK.md`, re-derived on every run by `just verify-m16`.
- rejection-reason: does-not-cover: the package was read and probed, not merely dismissed. It hashes internal nodes as `poseidon2([lhs, rhs])`; the current protocol hashes them as `poseidon2([SEP, lhs, rhs])` with a per-tree domain separator, so as shipped it produces **wrong roots** — the empty `NOTE_HASH_TREE` at depth 42 is `0x2590f2aa…9202e4c6` natively and `0x2ac5dda1…59a8a30a` from the package, with sibling paths diverging from level 1 upward (measured: the package root in `probe-mt/probe.mjs` and `probe2.mjs`, the domain-separated chain that reproduces the native root in `probe7.mjs`). It also offers *snapshots* — O(state), immutable, outliving their creator — where execution needs *checkpoints*: nesting, O(changes), strictly LIFO. And it fails `TypeError: this.nodes.get is not a function` against the June-2026 kv-store. The honest counterweight is recorded in M16: tree code rarely changes and a revival would probably work. It is the second choice because it would be **ours to maintain** and RI-02 is Aztec's, not because it could not be made correct.
- confidence: measured
- experiment: n/a

### RI-29 — `@aztec/telemetry-client`
- upstream: npm `@aztec/telemetry-client`
- covers: -
- decision: replace
- milestone: M18, M28
- why: Several vendored files construct telemetry clients; a no-op stub satisfies them. **M18's enumeration found that upstream has already written it — twice — and that the package boundary is what puts it out of reach.** `telemetry-client/src/noop.ts` is 152 lines of `NoopTelemetryClient`/`NoopTracer`/`NoopSpan`/`NoopMeter` whose only runtime dependency is `@opentelemetry/api`; `telemetry-client/src/start.ts` already returns one from `getTelemetryClient()` by default, with the heavy path behind a lazy `await import('./otel.js')`; and `yarn-project/txe/esbuild/stubs/telemetry_stub.ts` (39 lines) and `telemetry_start_stub.ts` (15 lines), wired by `txe/esbuild.config.mjs`, already redirect the whole package for a browser build, with TXE's own comment giving the identical rationale. That directory holds sixteen such stubs. **It is unreachable from outside the monorepo**, and that is measured rather than read: `import('@aztec/telemetry-client/dest/noop.js')` and `'@aztec/telemetry-client/noop'` both fail with `ERR_PACKAGE_PATH_NOT_EXPORTED` — the `exports` map has no `./noop` — while `'.'` resolves and is the 1,658-module closure. TXE reaches `dest/noop.js` by a monorepo-RELATIVE path from source, which a consumer of the published package cannot do. So the replacement is upstream's decision in upstream's shape, forced into a local module by one missing line in an exports map; adding `"./noop": "./dest/noop.js"` is a candidate sixth contribution and is recorded under M11's outstanding tasks rather than taken.
- rejection-reason: cannot-reach-target: the target is the browser bundle, and the load-bearing fact — verified in M1 review against `node_modules/@aztec/telemetry-client/package.json` at the `deletion_era` pin — is that **none of its five exports (`.`, `./bench`, `./config`, `./start`, `./otel-pino-stream`) carries any export condition at all**, browser or otherwise, so a bundler has no branch to resolve away from the node build. What it then pulls is server metrics machinery: `prom-client` is a direct dependency reached **eagerly** (`dest/index.js` → `prom_otel_adapter.js`), `@opentelemetry/host-metrics` is a direct dependency reached through a dynamic `await import('./otel.js')` in `dest/start.js`, and `systeminformation` arrives transitively as host-metrics' sole dependency. Two corrections to an earlier revision of this reason, both found in review: it is not a *single* entrypoint, and **`koa` is not a dependency of this package** — the only reference is `import type Koa from 'koa'` in `src/otel_propagation.ts`, erased at compile time; `koa` is in `node_modules` because `@aztec/foundation` depends on it, which is a different package and one RI-30 keeps. The replacement is a no-op stub, and M28's assertion must therefore name prom-client, `@opentelemetry/host-metrics` and systeminformation — naming koa would either pass trivially or fail for a reason that has nothing to do with telemetry.
- confidence: measured
- experiment: n/a

### RI-30 — `@aztec/foundation`, `@aztec/stdlib`, `@aztec/constants`, `@aztec/protocol-contracts`, `@aztec/standard-contracts`
- upstream: npm, at the pin declared in `pins.json`
- covers: -
- decision: depend
- milestone: M18, M21
- why: Field arithmetic, `AztecAddress`, protocol types, the generated constants and the canonical protocol contracts. All browser-capable, all published, all consumed from the registry at a pinned nightly. `@aztec/foundation/timer`'s `ManualDateProvider` is specifically adopted rather than reinvented: it freezes time entirely and advances only on explicit `advanceTime()`, which is exactly DD-4's injected clock, already solved upstream.
- rejection-reason: n/a
- confidence: settled
- experiment: n/a

### RI-60 — The msgpack encoder for the AVM's own input schemas
- upstream: `@aztec/stdlib/avm` — `serializeWithMessagePack` / `deserializeFromMessagePack` (`dest/avm/message_pack.js`), and `AvmFastSimulationInputs` / `AvmTxHint.fromTx` @ the `ts` anchor and in the published package
- covers: -
- decision: depend
- milestone: M18
- why: **This entry exists because the campaign had been working around a thing it already had.** `NODE-HOST.md`'s "Out of scope: Encoding" rule is narrow and correct — that package has no dependencies, so an encoder of *its own* would be a second implementation of upstream's schemas — but it was applied as though no TypeScript encoder could be used at all, and that shaped work: M12's `reactorinputs` mode exists to emit per-program msgpack blobs from C++ as hex precisely so no JavaScript would encode them, and every host since reads that file. Upstream's encoder is not a second implementation of anything, so the rule never reached it. (M18's review corrected this entry's own first draft, which quoted `NODE-HOST.md` as saying "there is no TypeScript encoder for the AVM's input schemas" and M17's write-up as calling that the load-bearing constraint on M18. Neither sentence is in the record — `git log -S` finds no commit that ever added the first — and the finding does not need them.) Upstream ships the encoder, in the package M18 already depends on, and calls it on exactly this type: `CppPublicTxSimulator.simulate` builds an `AvmFastSimulationInputs` and calls `.serializeWithMessagePack()` before handing the buffer to `@aztec/native`'s `avmSimulate`. `WasmAvmPublicTxSimulator` reuses that chain verbatim — `AvmTxHint.fromTx`, the `AvmFastSimulationInputs` constructor, `serializeWithMessagePack` and the `deserializeFromMessagePack` / `PublicTxResult.fromPlainObject` pair — and changes the transport. (M18's review replaced "differs in one step out of six" with that: upstream's `simulate` has eleven steps, not six, and beside the transport four more are ABSENT under the RESIDENT shape — the IPC path, `ContractProviderForCpp`, the cancellation token and the `SimulationError` translation — each for a reason, but "one of six" was not the count and was carrying an argument.) It registers msgpackr extensions for `Fr`, `Fq`, `AztecAddress`, `Point` and `EthAddress` so a field element is written as the 32-byte big-endian `bin` the C++ side reads, and encodes with `useRecords: false` so the output is plain MessagePack maps. **The read side is asymmetric and that is upstream's own note**, in `@aztec/native/src/msgpack_channel.ts`: "this only works for writes. Unpacking from C++ can't create Fr instances because the data is passed as raw, untagged, buffers." Measured in M18: over `avm.wasm`'s own output the fee comes back as a `Buffer`, not an `Fr`.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a — `e2e_ts_wasm_result_decodes_as_upstream_types` runs all seven corpus programs and requires `PublicTxResult.fromPlainObject` to accept the module's bytes, with two corruptions of the same object that it must reject.

### RI-62 — the three-way differential arm: what was reused, and the one thing that had to be written
- upstream: `yarn-project/simulator/src/public/` @ anchor `ts` — `CppVsTsPublicTxSimulator` (the two-way comparator and its checkpoint discipline), `PublicTxSimulationTester` and `BaseAvmSimulationTester` (the fixture world), `SimpleContractDataSource`, and the corpus drivers `token_test.ts`, `amm_test.ts`, `bulk_test.ts`, `custom_bytecode_tests.ts`; plus `@aztec/stdlib/avm`'s `AvmTxHint.fromTx`, `AvmFastSimulationInputs`, `serializeWithMessagePack` and `deserializeFromMessagePack` (RI-60), and `@aztec/stdlib/contract`'s `computePublicBytecodeCommitment`
- covers: the comparator, the corpus, the checkpoint discipline, the encoder and the decoder
- decision: extend
- milestone: M19
- why: enumerated across the whole fork and the published packages by subdirectory before anything was written, because the campaign has been wrong eight times about whether something needed building and every miss was a parallel subdirectory. Almost all of it was there. The comparator is upstream's and is SUBCLASSED, not reimplemented — its two arms, its assertion list and its merkle-plus-contracts-DB checkpoint discipline are inherited unchanged, and the third arm is added around them. The corpus is upstream's own fixture drivers, driven UNEDITED: a differential whose corpus is its own is a differential that says nothing about the corpus everyone else measures. The fixture world is reached through the seam upstream already provides — `PublicTxSimulationTester`'s constructor takes the merkle tree and the contract data source, so both are wrapped rather than the fixture being modified. The encoder is upstream's, called the way `CppPublicTxSimulator` calls it.
- rejection-reason: n/a
- confidence: measured
- experiment: What genuinely had no upstream counterpart, and why: the RESIDENT-DB SEEDING. `avm.wasm` owns its merkle DB and its contract DB (M15's resident shape), so nothing outside the module can hand it a fork, and "run the other side from the identical pre-transaction state" had to be established rather than assumed. Two payload shapes were written — `ContractClassWithCommitment` and `[AztecAddress, ContractInstance]`, quoted from `vm2/common/aztec_types.hpp` at anchor `cpp` — and they are NOT upstream's `AvmContractClassHint` / `AvmContractInstanceHint`, which were checked first and are a different message: the class hint carries a `hintKey` and lacks `publicBytecodeCommitment`. Encoding one where the other is expected decodes into plausible garbage rather than failing, so the near-miss is recorded here rather than left for someone to rediscover. The two merkle-leaf payloads (`{nullifier}`, `{slot, value}`) are likewise the C++ structs' own field names. Everything above them is upstream's `serializeWithMessagePack`.

### RI-61 — TXE's esbuild stub library
- upstream: `yarn-project/txe/esbuild/` @ anchor `ts` — sixteen stubs under `stubs/`, five plugins under `plugins/`, wired by `txe/esbuild.config.mjs`
- covers: -
- decision: depend
- milestone: M18, M28
- why: `depend` in the sense RI-56 uses it — what is taken is upstream's answer, not upstream's binary. The problem M28 exists to solve — a Node-only package reachable from a browser entry point, with no export condition to resolve away from — is one upstream has already solved for its own browser build, in a directory nobody had enumerated. The `redirects.mjs` plugin maps a specifier to a stub; `telemetry_stub.ts`, `telemetry_start_stub.ts` and `world_state_stub.ts` are the three that overlap ours directly, and the last one is instructive for what it does NOT cover: it throws for `createWorldState` and `createWorldStateSynchronizer` and says nothing about `@aztec/world-state/native`, so it would not have severed `ForkCheckpoint` (RI-26). Recorded as prior art for M28 rather than adopted wholesale, because our bundler and our entry points are not TXE's; what is adopted now is the SHAPE of the telemetry replacement and the argument for it. Whether any of these files is VENDORED is M28's decision and is deliberately not pre-empted here.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-31 — `@aztec/kv-store`
- upstream: npm `@aztec/kv-store` — browser entry points measured at anchor `cpp`: `./deprecated/indexeddb` and `./sqlite-opfs`
- covers: -
- decision: depend
- milestone: M23
- why: The persistence substrate for anything the runtime keeps across reloads. Recorded here with one correction to the design document, which lists `./indexeddb` and `./sqlite-opfs` as the browser entry points: at anchor `cpp` the IndexedDB export is `./deprecated/indexeddb` — **deprecated** — and `./sqlite-opfs` is the live browser store. The disambiguation matters: at anchor `ts` the same field still reads `./indexeddb`, so the design document was right for the older pin and the deprecation happened between the two anchors. Recorded before any persistence work leans on the stale list.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-32 — `@aztec/bb.js` prebuilt NAPI AVM
- upstream: npm `@aztec/bb.js` at the `deletion_era` pin — its tarball ships `nodejs_module.node` for amd64/arm64 × linux/macos
- covers: -
- decision: depend
- milestone: M2, M19, M28
- why: It is the C++ oracle the differential runs against, and it needs no barretenberg build. Two things are recorded with it rather than discovered later. **It has an expiry date**: it is the in-process adapter from the 5.0.0 npm line, and upstream moved to out-of-process `bb-avm-sim` over IPC on 2026-07-16 (`96082e32ec`), so as the pin ages Tier A stays green while meaning progressively less — DD-12's version-gap report exists for this. And **containment is a hard requirement**: the `cpp_*` files and `@aztec/native` live only under a differential directory, the published package has zero optional native dependencies, and M28 asserts both on the built artifact.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-33 — Compiled Noir contract artifacts
- upstream: npm `@aztec/noir-contracts.js` (34 artifacts) and `@aztec/noir-test-contracts.js` (51 artifacts, 76 MB)
- covers: -
- decision: depend
- milestone: M2
- why: Token, AMM, AvmTest, AvmGadgetsTest, StorageProofTest, PublicFnsWithEmitRepro and the rest arrive compiled, rebuilt every nightly, with **no `nargo` and no compilation** on our side. This is fresh bytecode against a current compiler for free. Compiling from source with `aztec-nargo` + `avm-transpiler` stays documented for when a tracing experiment needs debug info (OQ-5), but it is not on the critical path.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-34 — AVM↔Brillig differential fuzzer
- upstream: `yarn-project/simulator/src/public/fuzzing/` @ anchor `ts`, driven by `noir-lang/noir`'s `tooling/ssa_fuzzer`
- covers: test-harnesses
- decision: vendor
- milestone: M2 (Gap 4)
- why: A coverage-guided differential oracle against Noir's own reference VM. In the vendored tree `AvmFuzzerSimulator` drives the **pure-TypeScript** `PublicTxSimulator`, so it needs no C++ AVM at all — only the Noir toolchain and `avm-transpiler`. Since RI-32's oracle expires and this one does not, it is the natural successor oracle. It is vendored and **not yet stood up**, and that is recorded as a gap rather than as coverage.
- rejection-reason: n/a
- confidence: reasoned
- experiment: n/a

### RI-35 — `avm-transpiler`
- upstream: `avm-transpiler/` @ anchor `cpp` — dual `MIT OR Apache-2.0`
- covers: -
- decision: depend
- milestone: M2, M25
- why: Noir/Brillig → AVM bytecode lowering. Vendored into `reference/` for reading only; consumed as a tool when the fuzzer (RI-34) is stood up or when a tracing experiment needs to compile from source. M25's OQ-5 may find it does not preserve enough debug info to map an AVM program counter to Aztec.nr source; if it *could* preserve the mapping but does not, that becomes a sixth upstream contribution prepared the same way as the five — not a fork.
- rejection-reason: n/a
- confidence: reasoned
- experiment: n/a

---

## E. The private half, and the chain around it

### RI-36 — Private execution (`WASMSimulator`, ACVM, Brillig)
- upstream: npm `@aztec/noir-acvm_js`, `@aztec/noir-noirc_abi`, and `simulator/src/private/` @ anchor `ts`
- covers: private-execution
- decision: depend
- milestone: M21
- why: Already wasm, already browser-shipped by Aztec in production. Form B's private half is `WASMSimulator` → `generateSimulatedProvingResult(...)` → `PrivateKernelTailCircuitPublicInputs` → `new PrivateSimulationResult(...).toSimulatedTx()` — exactly the path PXE takes under `skipKernels: true`, which is its default. Every piece of it is Aztec's own code. The private-execution *path* is therefore not a component we build; only the node adapter under it is (RI-37).
- rejection-reason: n/a
- confidence: reasoned
- experiment: n/a

### RI-37 — `AztecNode` adapter for settled read requests
- upstream: `AztecNode` in `@aztec/aztec-node` / `@aztec/stdlib`
- covers: private-execution
- decision: build
- milestone: M21
- why: `generateSimulatedProvingResult` calls into a node to verify settled read requests. We have no node; we have an in-memory world state.
- rejection-reason: cannot-reach-target: the target is a self-contained browser runtime, and §8.4 forbids exporting anything shaped like a node. Three corrections from M1 review, because the reason as written was overstated. **The surface is already enumerated, by upstream.** `generateSimulatedProvingResult` (`pxe/src/contract_function_simulator/contract_function_simulator.ts:440`) makes exactly one `node.*` call in its whole body — a pass-through at `:570` into `verifyReadRequests(node: Pick<AztecNode, 'findLeavesIndexes'>, …)` (`:766`), whose `Pick<>` *is* the enumeration, over `NOTE_HASH_TREE` and `NULLIFIER_TREE`. So OQ-1's deliverable is a quotation rather than an investigation, and the throw-on-anything-else check (`test_aztec_node_adapter_surface_minimal`) is asserting a boundary upstream already draws. **The blocker is not sockets.** `AztecNodeService` is the single production implementation, and TXE constructs *that very class* with `DummyP2P`, `MockEpochCache` and `sequencer: undefined` — no sockets at all. What actually stops us reusing it is native and kv dependencies: `state_machine/synchronizer.ts` needs `NativeWorldStateService.ephemeral()` and an `AvmSimulatorPool` subprocess, `state_machine/archiver.ts` needs an `AztecAsyncKVStore`. **And TXE is not doing the same substitution we are** — it substitutes a node's *components*, keeping the real node class, which is a different pattern from writing a narrow adapter and should not be cited as precedent for one. One thing to read before writing the adapter, found in review and not previously enumerated: `aztec-node/src/modules/node_world_state_queries.ts` implements `findLeavesIndexes` over three interfaces and opens nothing itself, with a header comment saying it was extracted so the logic "can be unit-tested without standing up the whole node". It is not in the package's export map, so reuse means a deep import or a copy — but it is upstream code for exactly this call and M21 must weigh it rather than start from a blank file.
- confidence: reasoned
- experiment: n/a

### RI-38 — PXE (`@aztec/pxe` `client/lazy`)
- upstream: npm `@aztec/pxe`
- covers: private-execution
- decision: open
- milestone: M21
- why: Note discovery, tagging, capsules and a keystore are a large, subtle surface that PXE already implements and ships to browsers. The governing principle puts reimplementation on the wrong side of the scale by default, so the burden of proof is on reimplementing, not on embedding.
- rejection-reason: n/a
- confidence: open
- experiment: OQ-2's deciding evidence, stated before the fact: a page that imports `@aztec/pxe/client/lazy`, executes one private function with **no node attached**, and reports its bundle cost. Embed unless that number breaks M27's chunk budget; if it does, the reimplementation is scoped against the measured surface rather than guessed.

### RI-39 — TXE (`yarn-project/txe/`)
- upstream: `yarn-project/txe/` @ anchor `cpp` — `txe/src/` is 41 files / 7,376 lines; the whole package directory is 67 files / 8,278 lines
- covers: -
- decision: open
- milestone: M23
- why: This is the entry that exists because the mistake was nearly made a fourth time: the chain loop and facade were called "the plan's largest genuinely-ours component" with upstream's sequencer and `PublicProcessor` enumerated as the things to check, and TXE — a chain-shaped facade for testing Aztec contracts that already wires `PublicProcessor` — was not enumerated at all. Its surface overlaps ours directly rather than loosely: `mineBlock`, `advanceBlocksBy`, `advanceTimestampBy` (it already advances time explicitly rather than reading a wall clock, which is DD-4's discipline solved upstream), `sendL1ToL2Message`, `deploy`, `addAuthWitness`, `privateCallNewFlow`/`publicCallNewFlow`, `getRandomField`. Its `state_machine/` (789 lines) is more relevant still — `archiver.ts`, `global_variable_builder.ts`, `synchronizer.ts`, `dummy_p2p_client.ts`, `mock_epoch_cache.ts` are *upstream themselves* substituting a node's components with dev-shaped ones, which is the pattern this whole project is built on. The counterpoint is real and may be decisive: it depends on `@aztec/world-state`, `@aztec/aztec-node`, `@aztec/archiver` and `@aztec/bb-prover`, so it is not browser-capable as it stands, and it is driven from Aztec.nr test harnesses over an oracle protocol rather than from a JavaScript facade.
- rejection-reason: n/a
- confidence: open
- experiment: M23's verdict, reached by reading it: substitute its native dependencies the way this project already substitutes elsewhere and drive it beneath our facade (`reuse`), or decline it for the stated dependency and interface reasons and let its API shape inform ours anyway (`reference implementation`). Either outcome is acceptable; declining **without looking** is the one outcome forbidden, and `verify_txe_reuse_verdict_recorded` is the check that forbids it.

### RI-40 — Sequencer and validator-client block builders
- upstream: `yarn-project/sequencer-client/`, `yarn-project/validator-client/` @ anchor `cpp`
- covers: block-processor
- decision: open
- milestone: M23
- why: Upstream has a sequencer, a validator-client checkpoint builder, and a `PublicProcessor` that already assembles blocks. Block sealing, global-variable construction, transaction selection and limits are all things one of them already does. "That is a node component we cannot use" is exactly the kind of assumption this plan has been wrong about, so it is not made here.
- rejection-reason: n/a
- confidence: open
- experiment: M23's enumeration: list what each already provides — block sealing, global-variable construction, transaction selection, limits — mark each item reused or rejected-with-reason, and record the enumeration **before any loop code is written**. `verify_sequencer_reuse_enumeration_recorded` is the check.

### RI-41 — Chain loop, timer, and the `AvmRuntime` facade
- upstream: `yarn-project/sequencer-client/src/sequencer/automine/` (`AutomineSequencer`) and `yarn-project/stdlib/src/interfaces/aztec-node-debug.ts` (`AztecNodeDebug`) @ anchor `cpp` — an anvil-style automining sequencer and the JavaScript facade over it
- covers: -
- decision: open
- milestone: M23
- why: **Reopened in M1 review.** This entry was `build`, with a rejection reason that did not survive checking — and it failed in the project's own recurring direction, by enumerating `sequencer-client/` and `validator-client/` (RI-40) without looking at `sequencer-client/src/sequencer/automine/`, which is the subdirectory that matters. Every one of the three items the entry reserved as "genuinely ours" exists upstream. **The timer**: `RunningPromise` (`@aztec/foundation/running-promise`) is what `Sequencer` and `AutomineSequencer` already tick on (`automine_sequencer.ts:179,185`). **Empty-block issuance**: `AutomineSequencer.buildEmptyBlock()` (`automine_sequencer.ts:268`) plus `warpTo(ts)`/`warpBy(delta)`, which the module's own README describes as advancing the clock "by publishing an empty checkpoint at the target slot". **The facade's shape**: `AztecNodeDebug` is exactly an anvil-style JS facade — `mineBlock()`, `prove(upToCheckpoint?)`, `warpL2TimeAtLeastTo(targetTimestamp)`, `warpL2TimeAtLeastBy(duration)` — with a zod JSON-RPC schema, exposed by the CLI behind `--debug`. The two claims the old reason rested on are also false as written: automine's own README lists "no proposer-turn check, no sync check, no pipelining, no timetable enforcement, no validator orchestration, no P2P proposal gossip" and "there is no real proof", so "a sequencer inside a node that selects from a p2p mempool and proves" does not describe it; and TXE's `advanceBlocksBy`/`mineBlock` are plain public methods on the exported `TXEOracleTopLevelContext` class, constructed directly from `TXESession`, so they are reachable from TypeScript rather than only over the Aztec.nr oracle protocol. What remains genuinely open is whether automine can be reached at all without L1 — it drives anvil through cheat codes, which is a far stronger objection than the one that was written — and that is the question M23 must answer rather than assume.
- rejection-reason: n/a
- confidence: open
- experiment: M23, before any loop code is written: stand `AutomineSequencer` up against our in-memory world state with no L1 and record exactly which of its operations survive — `buildEmptyBlock`, `warpTo`/`warpBy`, `maybeEnqueueBuild` with `minTxsPerBlock: 0` (the setting `AztecNodeService.mineBlock()` already flips to force an empty block out of the ordinary 500 ms `RunningPromise` loop) — and which of them are unreachable because they publish to a rollup contract. Then decide between three recorded outcomes: reuse `AutomineSequencer` beneath our facade; adopt `AztecNodeDebug`'s method shape and reimplement only the L1-free subset; or, only if both fail, build the loop, with the surface fixed by that enumeration. The facade's *shape* is not open in any case — it follows `AztecNodeDebug` unless a divergence is recorded.

---

## F. Tracing — where the upstream to reuse is ours

### RI-42 — CodeTracer `.ct` writer and trace format
- upstream: `codetracer-trace-format` (ours) — the Path A pure-Rust writer, the readers, `ct-print`, and its own fixtures
- covers: -
- decision: depend
- milestone: M24
- why: One of the few places where the upstream to reuse is our own. The writer is compiled to wasm with a raw C ABI over linear memory and zero wasm imports, and the validation tooling already exists. Two consequences are recorded rather than discovered: a single instantiation of the trace-types, trace-writer and CTFS crates is required (two copies on different paths are two distinct types and will not unify), and a wasm-produced Path A container cannot be read by stock `ct-print` because the Rust zstd frame compressor leaves every frame unpledged, so verification uses the reader from the corresponding trace-format branch.
- rejection-reason: n/a
- confidence: reasoned
- experiment: n/a

### RI-43 — Noir tracer for the private half
- upstream: the existing Noir tracer (ours), driving one ACVM step at a time
- covers: private-execution
- decision: depend
- milestone: M26
- why: The private half of a Form B recording is traced by the tracer that already exists, writing into the same container — reused, not rebuilt. What is genuinely open is whether the Rust-side tracer and the TypeScript-side runtime can share one writer instance across the language boundary (OQ-7); the fallback, two recordings joined explicitly rather than inferred, is implemented if they cannot.
- rejection-reason: n/a
- confidence: reasoned
- experiment: n/a

### RI-44 — Aztec-specific golden traces and step-level trace fixtures
- upstream: none
- covers: -
- decision: build
- milestone: M2 (Tier E), M25
- why: Trace output is the one thing this runtime produces that no Aztec component produces, so there is nothing upstream to compare a recording against and the fixtures must be authored. This is Tier E, deliberately the smallest tier, and each entry in it records why no upstream equivalent exists so the authored tier cannot grow by default.
- rejection-reason: does-not-exist: upstream has several instruction-observing seams and **none of them serialises a step-level artefact in any stable format**. `PublicSideEffectTraceInterface` records tx-level side effects for limit enforcement; `AvmSimulator`'s `tallyInstructionFunction` is a metrics tally receiving a class name and a gas delta; `avm_simulator.ts:150` already logs a per-step `[PC:…] [IC:…] …` line at trace level, to a logger, not an artefact; vm2's `ExecutionEvent` stream (RI-08) is a genuine per-instruction record but is in-memory only, drained into tracegen; and `vm2/tooling/debugger.cpp` is an interactive `#ifndef NDEBUG` REPL over circuit rows. The one thing upstream *does* write is `DumpingPublicTxSimulator`'s `avm-circuit-inputs-tx-<hash>.bin` — msgpack prover inputs for proving benchmarks, not a trace. Nothing upstream tests trace *output* because upstream produces none. The authored fixtures are therefore unavoidable, and each is required to record why no upstream equivalent exists (`verify_tier_e_authored_fixtures_justified`) so the authored tier cannot grow by default. One of the four assertions is deliberately cheap and self-checking: recorded step count equals the AVM's own executed-instruction statistic.
- confidence: settled
- experiment: n/a

---

## G. Fixtures and oracles

### RI-45 — World-state golden root vectors (Tier D)
- upstream: partially — upstream ships **genesis** roots as hardcoded constants (`world_state/world_state.test.cpp`, `constants.nr`, `abis/block_header.nr`, `merkle_tree/root.nr`) **and one post-genesis `StateReference`** (`world_state.test.cpp`'s `SyncExternalBlockFromEmpty`). It ships nothing past that. See the rejection reason.
- covers: -
- decision: build
- milestone: M2
- why: The trees are the highest-risk correctness surface and need an oracle that does not share our mistakes.
- rejection-reason: does-not-cover: **corrected in M1 review** — an earlier revision claimed `does-not-exist:` on the strength of having searched only `vm2/simulation/gadgets/` and `simulation/lib/`. That generalisation was false. Upstream ships golden roots in three places, and they are the *same values* our capture records: `barretenberg/cpp/src/barretenberg/world_state/world_state.test.cpp`'s `GetInitialTreeInfoForAllTrees` hardcodes `0x18935581…cee0454` (nullifier), `0x2590f2aa…9202e4c6` (note hash), `0x1bef38b6…56b9d084` (public data) and `0x0fef6d80…64c11f7a` (L1→L2), all four byte-for-byte what `fixtures/trees/native-genesis-state.json` captures; `noir-projects/…/types/src/constants.nr:201` declares `GENESIS_ARCHIVE_ROOT = 0x177a4955…15cfbdf5`, which is our ARCHIVE root, with a comment saying it is *taken from* that same C++ test; and `types/src/merkle_tree/root.nr`'s `test_merkle_roots_match_typescript` / `test_empty_tree_root` hardcode empty roots at heights 1, 2, 6 and 10 — a genuine cross-implementation golden vector. What upstream does **not** cover is everything past genesis: post-operation roots for a scripted mutation sequence, the full 42-level zero sibling paths, the `stateReference` shape and the genesis prefill, none of which appear as a vector anywhere. The gadget suites really are self-consistent rather than vectored (`grep -c '0x' merkle_check.test.cpp` → **0**, and the three `*_tree_check` suites assert against gmock dummies rather than computed roots), but that is a supporting observation, not the reason. What is built is therefore not an implementation but a **capture script** against upstream's own native `NativeWorldStateService`, checked in with its generator so it regenerates byte-for-byte — and M2 must assert the genesis subset against upstream's constants rather than only against our own capture. **Corrected again in M2, in the same direction, and this is the third revision of one reason:** upstream also publishes a POST-genesis vector. `world_state.test.cpp`'s `WorldStateTest.SyncExternalBlockFromEmpty` checks in a whole `StateReference` — `0x2e2e2d8b…` at 129, `0x25c4ef02…` at 1, `0x1e2d8d1c…` at 129, `0x22c6f787…` at 1 — for the state after one leaf is written to each of the four trees, and the TypeScript world state reproduces all four exactly (measured 2026-08-21). So the earlier phrasing 'what upstream does not cover is everything past genesis' was still too strong: it does not cover everything past ONE OPERATION. The capture is scoped accordingly and the scoping is enforced rather than described: `test_world_state_golden_vectors_regenerate` compares every value in the fixture's `upstreamPublished` section against the fork read live at the anchor, and requires every root the `captured` section introduces to be absent from the whole fork at that anchor — measured, 9 novel roots, 0 of them found upstream. What genuinely remains uncovered is steps 2 through 8 of the mutation sequence, the checkpoint/revert restoration, the 42-level zero sibling path and the 256 prefill leaf preimages with their linkage.
- confidence: measured
- experiment: n/a

### RI-46 — The seven AVM corpus programs
- upstream: assembled through upstream's own `BytecodeBuilder`/`InstructionBuilder` (RI-14)
- covers: -
- decision: build
- milestone: M2
- why: Integration evidence across the whole stack for a handful of programs whose intent is recorded. Promoted to a checked-in corpus in M2 (`diffsim/src/corpus/avm_corpus_programs.ts`), each carrying its recorded intent, and each re-assembled with upstream's own TypeScript encoder so that its derived contract address must equal the one upstream's C++ `BytecodeBuilder` produced — a hash over the whole bytecode, so agreement on it is agreement on every byte, and it needs no barretenberg build.
- rejection-reason: does-not-cover: upstream's own suites (RI-15) cover semantics far more broadly and are used for exactly that, but they assert internally and produce no comparable transcript, so they cannot serve as a native-vs-wasm differential. These seven exist to be *diffed between two builds*, not to prove semantics — and the plan says so plainly: seven hand-assembled programs prove integration, not broad correctness, which is why running upstream's own suite under wasm (RI-15/RI-16) is near the front of the plan rather than behind them. Every instruction in them is emitted by upstream's builders.
- confidence: settled
- experiment: n/a

### RI-47 — Reference material under `reference/`
- upstream: `yarn-project/simulator/docs/avm/`, `barretenberg/cpp/pil/vm2/`, `vm2/common/`, the protocol constants, the docs extracts and the deleted protocol specs — see `PROVENANCE.md`
- covers: -
- decision: vendor
- milestone: M0, M1
- why: Vendored because upstream's `next` takes nightly merges, and anything we *reason against* must be pinned or a future reader cannot tell which version a claim was made about. The whole bundle is 3.2 MB. It is reference input, never a build input: the constants the build consumes come from RI-04's regeneration, not from `reference/constants/constants.nr`. Its staleness is recorded per directory in `reference/PROVENANCE.md`, including that `historical-protocol-specs/` is abandoned on purpose and every claim taken from it must be re-verified.
- rejection-reason: n/a
- confidence: settled
- experiment: n/a

---

## H. Browser packaging

### RI-48 — Browser bundler configuration and node-builtin polyfills
- upstream: the Aztec Playground's vite configuration @ anchor `cpp`
- covers: -
- decision: depend
- milestone: M27
- why: Aztec's deployed Playground is a working public reference for every hard part — it already solves the node-builtin polyfill problem for the same dependency set (`assert` across 13 AVM files, `util.inspect` and `tty` for stdlib formatters) and already lazy-loads the two heavy chunks. The deliverable is to start from what they do and **record any divergence**, rather than to derive a configuration and discover the same problems in a different order.
- rejection-reason: n/a
- confidence: reasoned
- experiment: n/a

### RI-49 — bb.js's WASI shim, as the host for `avm.wasm`'s twelve imports
- upstream: `barretenberg/ts/bb.js/src/barretenberg_wasm/barretenberg_wasm_base/index.ts` — `BarretenbergWasmBase.getImportObj` @ anchor `cpp`
- covers: -
- decision: replace
- milestone: M17 (answered), M28 (the browser asks it again)
- why: M12 measured the surface — **eleven `wasi_snapshot_preview1` functions plus `env.memory`, twelve in total** — and this entry stood `open` on the expectation that bb.js's existing shim would serve it, because bb.js already supplies a host-owned memory for `barretenberg.wasm`. M17 asked the question by enumeration over the WHOLE fork by subdirectory and over the published `@aztec/*` packages, and the expectation was wrong. The replacement is not something we wrote: it is **`node:wasi`**, recorded as RI-59, which covers eleven of eleven, plus exactly one import of ours — `env.memory`, sized from the module's own declared 130-page minimum read out of the binary's import section. And the reuse is upstream's own practice rather than a fallback: `barretenberg/cpp/scripts/run_wasm_bench_node.mjs`, a directory PARALLEL to `barretenberg/ts/`, already drives a `--import-memory` WASI barretenberg module from Node with `new WASI({version:'preview1'})` and `imports.env.memory = memory`.
- rejection-reason: does-not-cover: measured name by name against the eleven, bb.js's `getImportObj` supplies **two** — `clock_time_get` and `proc_exit` — and misses the other nine, all of them libc startup and stdio (`environ_get`, `environ_sizes_get`, `fd_close`, `fd_fdstat_get`, `fd_prestat_get`, `fd_prestat_dir_name`, `fd_read`, `fd_seek`, `fd_write`). It is not a partial shim for this module but a complete shim for a DIFFERENT one: it also supplies `random_get`, `env.logstr` and `env.throw_or_abort_impl`, none of which `avm.wasm` imports, and `random_get`'s absence is something REACTOR-ABI.md asserts by name — so the single import bb.js exists to provide is the one this module must not have. Its own comment says so: "We literally only need to support random_get, everything else is noop implementated in barretenberg.wasm." The cause is the two artefacts' builds: `barretenberg.wasm` is hand-stubbed through `wasi_stubs.cpp`, and `avm.wasm` is a genuine wasi-sdk 33 reactor whose libc startup and stdio come from wasi-libc.
- confidence: measured
- experiment: n/a — `verify_wasi_shim_reuse_decision_recorded` re-runs the whole enumeration on every invocation rather than reading the conclusion back: it reads the eleven out of REACTOR-ABI.md's own table, reads bb.js's shim out of the fork at the anchor and counts which of the eleven it defines, enumerates every wasm instantiation site in the fork by subdirectory, and enumerates the installed `@aztec/*` packages for WASI names.

### RI-59 — `node:wasi`, as the WASI host for `avm.wasm`
- upstream: Node.js's own `node:wasi` (`WASI`, `getImportObject`, `initialize`) — used for the same job by upstream's `barretenberg/cpp/scripts/run_wasm_bench_node.mjs` @ anchor `cpp`
- covers: node-host
- decision: depend
- milestone: M17
- why: It supplies **eleven of `avm.wasm`'s eleven** WASI imports, which is the whole WASI half of the twelve, and it is what upstream itself reaches for when it drives a `--import-memory` WASI barretenberg module from Node. Depending on it rather than on a shim of ours means the preview1 semantics are Node's to keep correct, and it is also what makes `node-host/` a package with **no dependencies at all** — no bb.js, no `@types/node` — so a clean checkout type-checks and runs it with no `npm install` and no network. The one thing it does not supply is the memory, because the module imports it: barretenberg links every wasm artefact `-Wl,--import-memory`, so the host owns the linear memory. That single import is ours, and its size is read out of the module's own import section rather than guessed, because a memory below the declared minimum fails instantiation with a LinkError that reads like a toolchain problem. The browser has no `node:wasi` and M28 must ask the question again; bb.js's shim is not the answer there either, for RI-49's reasons.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a — `verify_node_v8_accepts_module` instantiates `avm.wasm` with exactly `node:wasi`'s import object plus `env.memory`, having first asserted that the module's eleven WASI names EQUAL the eleven REACTOR-ABI.md records, on both sides and with both non-empty.

### RI-52 — The owner of the two checkpoint stacks
- upstream: `TxExecution::simulate` in `vm2/simulation/gadgets/tx_execution.cpp` pairs `merkle_db` and `contract_db` checkpoints at five sites @ anchor `cpp`; `PublicTxSimulator` and `PublicProcessor` do the equivalent on the TypeScript side
- covers: -
- decision: build
- milestone: M13
- why: Inside a transaction the pairing is upstream's and M13 does not second-guess it: `TxExecution` opens a checkpoint on BOTH DBs at the end of setup and closes it on the app-logic and teardown paths, while `ContextProvider` and `Execution` open one on the merkle DB alone per call frame — deliberately, since a nested call can write storage and cannot publish a contract class. What has no upstream counterpart is an owner OUTSIDE a simulation, where a consumer opens a checkpoint per transaction or per block across two interfaces that know nothing about each other. That is a property of our boundary — the reactor exposes both interfaces as exports and a host can drive either — and not of upstream's product, where the two stacks are only ever moved by code that already holds both.
- rejection-reason: does-not-exist: searched upstream for a type that owns both stacks — `git grep` for every call site of `create_checkpoint` / `commit_checkpoint` / `revert_checkpoint` under `barretenberg/cpp/src/barretenberg/vm2/` at the anchor, and for the TypeScript equivalents under `yarn-project/simulator/src/public/`. Every pairing found is INSIDE a transaction: `TxExecution` (five paired sites), `MerkleDB`/`PureMerkleDB` pairing the raw merkle DB with the written-slots tree, and `SideEffectTrackingDB` pairing it with the side-effect tracker. None of them is an owner a host can hold across transactions, none exposes a depth or an id for the contract side — `ContractDBInterface` declares no `get_checkpoint_id` where `LowLevelMerkleDBInterface` does — and `PublicContractsDB` on the TypeScript side throws on underflow while `world_state::MemoryMerkleDB` pops an empty `std::stack`. The coordinator is 70 lines and lives beside the store in `standalone/`, so it goes upstream with it.
- confidence: measured
- experiment: n/a — `test_checkpoint_lockstep_contract_and_merkle` runs the same injected desynchronisation twice, once through the coordinator (detected, by name) and once by hand (a plausible-looking wrong state), so the value of the owner is a comparison of two measured runs.

### RI-53 — The archive tree on the in-memory reference world state
- upstream: `barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.{hpp,cpp}` @ anchor `cpp` — four trees in `MemoryMerkleDB::State`, four members in `TreeRoots`, and `ARCHIVE` in the `MerkleTreeId` enum beside them
- covers: world-state
- decision: extend
- milestone: M14
- why: Block production advances the archive once per block and reads it twice — `lastArchive` into the header, and the new snapshot into the block — and the reference has no archive at all. The disposition was worked in the milestone's order and each step was measured rather than argued. **Does upstream cover it elsewhere?** Yes, in `world_state::WorldState`, which stores five trees in LMDB (`world_state_stores.hpp` holds five `LMDBTreeStore::SharedPtr`, one of them `archiveStore`) and takes a `thread_pool_size` on every constructor — so it cannot reach `wasm32-wasip1`. And unlike M13's contract DB, there is no store on the far side of the IPC boundary to reach for instead: `wsdb/CMakeLists.txt` builds `aztec-wsdb` from C++ sources and links `barretenberg env ipc_runtime world_state`, where `cdb`'s server is TypeScript. **Can M15's boundary avoid it?** Not through the AVM: `vm2/common/aztec_types.hpp`'s `TreeSnapshots` has four members and is both msgpack- and column-serialised, so an archive root cannot travel through `LowLevelMerkleDBInterface` in either shape without a circuit change. Not in TypeScript either: upstream's only TypeScript tree, `foundation/src/trees/merkle_tree.ts`, enforces `2 ** (height + 1) - 1` nodes in its constructor, which at `ARCHIVE_HEIGHT` 30 is 2,147,483,647. **Is a named throw enough?** It is what the anchor already does, and it defers rather than disposes: M22 needs an archive root for every header. So: extend, on the reference's own surface and NOT on the AVM's. One more `MemoryAppendOnlyTree<aztec::AztecMerkleHashPolicy>` at `ARCHIVE_HEIGHT` — the same template already instantiated twice in the same class — inside the checkpointed `State`, with a genesis seeded by computing the block-0 header hash from the four other trees' snapshots rather than by storing `GENESIS_ARCHIVE_ROOT`.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a — upstream's own `MemoryMerkleDBEquivalenceTest` goes from seven cases to twelve and `expect_roots_equal()` from four snapshots to five, so the archive is compared against a real, file-backed `WorldState` after every step of every case. Four mutation controls: moving the genesis timestamp fails all twelve, removing the state-reference check fails exactly one, a no-op archive append fails all twelve, and restoring the archive outside `State` fails exactly one.

### RI-54 — Block-pinned world-state reads (`WorldStateRevision`)
- upstream: `barretenberg/cpp/src/barretenberg/world_state_reference/merkle_tree_id.hpp` defines `WorldStateRevision` with its `LATEST = max(uint32)` sentinel; `world_state::WorldState` consumes it on fourteen methods @ anchor `cpp`
- covers: world-state
- decision: depend
- milestone: M14
- why: The vocabulary lives in the reference component and the reference has no use for it, and M14's finding is that we do not either. No method of `world_state_reference::MemoryMerkleDB` takes a `WorldStateRevision` — confirmed against the compiled symbol table as well as the declaration, `nm` over `libworld_state_reference.a` finds it in no `MemoryMerkleDB` symbol while `libworld_state.a` is full of them — and neither does any of the fourteen methods of `LowLevelMerkleDBInterface`, so the AVM's host surface has no parameter to carry one in either of M15's shapes. The only block-pinned archive read anywhere in the block pipeline is an archive membership witness for a historical block hash, in `prover-client/src/orchestrator/block-building-helpers.ts`, and that is the private-kernel side; public execution never takes one. So the regression the sentinel exists to prevent — a genesis-anchored read returning the current tip — is not reachable in a database that holds exactly one view, because it cannot be asked. What is depended on is upstream's: the sentinel's semantics, executed rather than read, and three of upstream's own `world_state_tests` cases in which a view taken at block 0 does not follow the canonical tip.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a — `test_historical_block_zero_read_returns_genesis` runs the sentinel's three properties out of a compiled probe, reads the symbol tables of both libraries, and runs `ForkingAtBlock0SameState`, `ForkingAtBlock0AndAdvancingFork` and `ForkingAtBlock0AndAdvancingCanonicalState` by name. Revisit if a consumer needs to simulate against a historical state; M20 is the first place that could arise.

### RI-55 — A compiler cache in the dev shells
- upstream: none — `barretenberg/cpp/CMakeLists.txt`, `CMakePresets.json` and `cmake/` contain no `ccache` and no `COMPILER_LAUNCHER` at anchor `cpp`; the fork's own flake carried `pkgs.ccache` from M0 and nothing invoked it
- covers: -
- decision: build
- milestone: M14
- why: Not a component of the product — a property of the harness, and the reason three regression sweeps died in the same place. `m6_native_configure` deletes the build directory before every configure, so M6, M7, M9 and M10's native builds were cold on EVERY run, and M9's seventh check builds upstream's `vm2_tests` twice from nothing. Measured on that exact build, build directory deleted between the two passes so what is measured is the cache and not ninja: **327 s cold with 639 misses and 0 hits, 9 s warm with 639 direct hits and 0 misses, same sha256 out of both.** What was built is six exports in each of the two `shellHook`s, `${VAR:-default}` throughout: the two `CMAKE_<LANG>_COMPILER_LAUNCHER` variables, which CMake reads as the default for its own cache variables and which therefore reach every configure site including `cmake --preset wasm` without editing a build script; `CCACHE_BASEDIR`, which is what lets one upstream translation unit built in two work directories share an entry; `CCACHE_DIR` and `CCACHE_MAXSIZE`; and `CCACHE_COMPILERCHECK` set to `%compiler% --version` rather than ccache's `mtime` default, because every binary in /nix/store has mtime 1970 and `mtime` would be discriminating two toolchains by size.
- rejection-reason: does-not-exist: searched the fork at anchor `cpp` for any compiler-cache integration — `git grep -ciE 'ccache|COMPILER_LAUNCHER'` over `barretenberg/cpp/CMakeLists.txt`, `barretenberg/cpp/CMakePresets.json` and `barretenberg/cpp/cmake/` returns zero, and the `wasm`, `wasm-threads`, `clang20`, `clang20-no-avm`, `fuzzing-avm` and `default` presets declare no launcher and no toolchain file that sets one. Upstream's own build orchestration caches at a coarser grain (ci3 caches whole build outputs by content hash) and has nothing per-translation-unit for a developer shell to inherit, so there is nothing to depend on. The assertion that this is still true is re-derived on every run by `verify_compiler_cache_effective`, so an upstream integration appearing later becomes a finding rather than a silent double-configuration.
- confidence: measured
- experiment: n/a — `verify_compiler_cache_effective` re-measures the cold/warm identity on a smaller target and asserts, separately, that the cache cannot mask a difference: M14's own base and patched trees differ in exactly one translation unit in the targets it builds, and compiling the second from a different absolute path against the warm cache gives 1 miss and the rest hits, with the two libraries differing by sha256. Two wasi-sdk toolchains compiling the same bytes miss and produce different objects.

### RI-56 — The chatty boundary shape (`ContractDBInterface` / `LowLevelMerkleDBInterface` over an imported callback)
- upstream: `barretenberg/vm2_wsdb/wsdb_ipc_merkle_db.hpp` — `WsdbIpcMerkleDB`, a `final` implementation of all fourteen `LowLevelMerkleDBInterface` methods over a WSDB IPC transport @ anchor `cpp`
- covers: -
- decision: build
- milestone: M15
- why: **Upstream already ships the chatty shape**, and finding that out was the enumeration this entry exists for. `WsdbIpcMerkleDB` holds a `WsdbIpcClient&` and a `WorldStateRevision` and translates each interface call into an IPC command over a Unix domain socket — per-method translate-and-cross, which is exactly the shape a host-implemented DB behind a wasm import needs. It lives in `barretenberg/vm2_wsdb/`, a subdirectory **parallel to** `vm2/` — the same shape that hid `automine/` under `sequencer-client/` and `FuzzerContractDB` under `avm_fuzzer/`. (An earlier revision called it "the seventh instance"; no document enumerates six prior ones and nothing asserts the count, so the count is dropped. M14 had already pinned `WsdbIpcMerkleDB` in `verification/lib_m14_world_state.sh:129-136`, so M15 confirmed it rather than found it.) What is built is written *against* it rather than from a blank file: `verification/m15/avm_chatty_dbs.{hpp,cpp}` is the same per-method translation with the revision dropped (the AVM's interface has no parameter to carry one — RI-54) and one wasm import, `env.avm_host_db_call`, in place of the socket. **It is prepared and deliberately not measured**: M15's decision turns on the crossing COUNT and the crossing COST, and both are measured without it — the count from upstream's own hint record, the cost through the twenty-two exports M12 and M13 already built. BOUNDARY-SHAPE.md records it as prepared-not-measured rather than leaving it an unstated gap.
- rejection-reason: cannot-reach-target: `WsdbIpcMerkleDB` cannot reach `wasm32-wasip1`. `vm2_wsdb/CMakeLists.txt` declares it against `wsdb` and `ipc_runtime`; `ipc_runtime` is a Unix-domain-socket transport and `wsdb` links `world_state`, which is lmdb-backed and takes a thread pool. The target is a browser runtime with no sockets and no threads.
- confidence: measured
- experiment: n/a — the enumeration is re-derived by `verify_boundary_crossing_budget`, which asserts the op table against `vm2/simulation/interfaces/db.hpp` method by method in both directions.

### RI-57 — The boundary-crossing count of a transaction
- upstream: `barretenberg/cpp/src/barretenberg/vm2/simulation/lib/hinting_dbs.hpp` (`HintingRawDB`) and the `ExecutionHints` schema it fills @ anchor `cpp`
- covers: -
- decision: depend
- milestone: M15
- why: M15 was asked to decide a boundary shape on measurement, and the quantity the decision turns on — how many times a transaction crosses the boundary in the chatty shape — is a number **upstream already records**. `HintingRawDB` is a recording decorator over both host DBs: it forwards every call and writes it into `ExecutionHints`, which is what makes `simulate_with_hinted_dbs` a replay. So the hint record is a per-METHOD tally of the calls a host-implemented DB would have had to answer *that a replay cannot derive*, and eighteen of its categories map one-to-one onto methods of the two interfaces. The number is the sum of the hint arrays' LENGTHS, which makes it a measured LOWER BOUND rather than a total — **at least 18 to 22 per transaction** over the seven corpus programs, with `burn` executing 38,903 instructions against tens of hinted DB calls rather than tens of thousands. (This entry called it "a COUNT and not an estimate" for two revisions. Three methods are called without being hinted — `get_tree_roots`, which is the most-called one, `pad_tree` twice per transaction and `get_checkpoint_id` once per nested call — and BOUNDARY-SHAPE.md §3 enumerates them. The decision is unaffected: even sixty crossings at 19 ns is about a microsecond.) Nothing of ours computes it; `verification/wasm_host/_hint_crossings.mjs` is a 22-row mapping table and a decoder, and it reports any hint category it does not recognise rather than dropping it.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-58 — Checkpointing in the reference world state
- upstream: `barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.{hpp,cpp}` — `create_checkpoint` / `commit_checkpoint` / `revert_checkpoint` over `std::stack<State>` @ anchor `cpp`
- covers: world-state
- decision: extend
- milestone: M15 (measurement), upstream contribution (the optimisation)
- why: Depended on as it stands and **measured for the first time**, because nobody had: at the pinned anchor no benchmark anywhere in the fork names `world_state_reference`, `MemoryMerkleDB` or `memory_merkle_db`, and the only file that exercises checkpoints — `world_state/memory_merkle_db.test.cpp` — asserts equivalence and contains no clock. The class's own header says checkpoints "deep-copy the whole tree state onto a stack and restore on revert", and §6.4's design constraint asked for O(changes); the mechanism is `checkpoints_.push(state_)` where `State` is four whole trees by value — five with M14's archive patch — each a `SparseMemoryTree` over an `std::unordered_map<uint64_t, FF>`, so a push is a node-by-node rehash of every map and a pop a node-by-node destruction. Checkpoints are taken per nested call, per phase and per transaction. The disposition is an **upstream optimisation with independent merit, not a rewrite**: copy-on-write on the node map (`nodes_` behind a `shared_ptr`, cloned on first write after a checkpoint) or an undo journal of `(key, previous value)` per write — either makes `create_checkpoint` O(1) and moves the cost to the writes, where O(changes) puts it, without changing a single caller. The merit is upstream's own: `MemoryMerkleDB` is what the AVM fuzzer and `PublicTxSimulationTester` run against, and both take a checkpoint per nested call.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a — `test_checkpoint_cost_characterised` re-measures create, commit and revert over populations a decade apart, against the anchor's four trees AND M14's five, from one source that detects which it has with a `requires`-expression, and asserts the growth as a ratio rather than the microseconds as a budget.

---

## Not in this inventory, and why

- **wasi-sdk** — a binary toolchain release, consumed and deliberately not forked. Packaged in `nix/wasi-sdk.nix` only because nixpkgs has no `wasi-sdk` attribute. Recorded in M0's reuse audit.
- **`noir-lang/noir`** — belongs to the separate Noir tracing campaign and is untouched here. Its `tooling/ssa_fuzzer` is a *driver* for RI-34, not a component of this runtime.
- **`AztecProtocol/protocol-specs-pdf` and `AztecProtocol/engineering-designs`** — both **unlicensed** (`license: null`, `/license` 404, no LICENSE file). Read-only. Must not be vendored or redistributed, and are not.
