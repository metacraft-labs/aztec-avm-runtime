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
- why: This is the consensus node's own AVM. It compiles for `wasm32-wasip1` with **no change to the interpreter sources** — the ~40 files and 327 throw/catch sites in `vm2/simulation/` built unmodified — and its transcripts are byte-identical to native x86-64 under both wasmtime 47 and V8, across revert codes, all gas dimensions, nullifiers, note hashes, data writes, public logs, call frames, instruction counts and all 56 tree-root lines. The design document framed reviving a deleted TypeScript interpreter as the near-term path and this as "the endgame"; execution reversed that. Everything we would have written instead is a component whose drift we would own forever.
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
- upstream: `PureContractDB` in `vm2/simulation/standalone/concrete_dbs.hpp`, `TestContractDB` in `vm2/testing/`, and the native IPC-backed `cdb` module @ anchor `cpp`
- covers: contract-db
- decision: open
- milestone: M13
- why: The world-state half of the host surface is already Aztec's and already running in wasm; the contract-DB half is not yet exercised in the shape we would ship. `PureContractDB` is a **decorator** over a raw `ContractDBInterface`, not a store. `TestContractDB` is the test implementation and is what the passing wasm transcripts actually used. Upstream's shippable raw one is `cdb`, which is native and IPC-backed. So there are three live candidates and the answer is not yet evidenced.
- rejection-reason: n/a
- confidence: open
- experiment: M13's enumeration: build `TestContractDB` into the wasm reactor and drive all eight `ContractDBInterface` methods against the corpus contracts, including `add_contracts` during execution and a deploy/call/revert round trip. If it passes unchanged the answer is "ship it"; if it fails only on test-shaped assumptions the answer is "upstream it as an in-memory store under `standalone/` beside `PureContractDB`"; only if both fail is a store of ours justified — and it is eight methods, four of which are lookups into artifacts the TypeScript layer already holds.

### RI-08 — Per-instruction execution observer
- upstream: `vm2/simulation/events/event_emitter.hpp`'s `EventEmitterInterface<ExecutionEvent>` — a real per-instruction seam, on the wrong execution path. See the rejection reason.
- covers: -
- decision: build
- milestone: M9, M11
- why: Step-level tracing is the feature this runtime exists to provide, and it needs an observation point inside the instruction loop the AVM actually runs.
- rejection-reason: does-not-cover: **corrected in M1 review** — an earlier revision claimed upstream had no per-instruction seam and pointed at `CallStackMetadataCollectorInterface`. That was wrong twice over. `CallStackMetadataCollectorInterface` really is frame-level (its five virtuals are `set_phase`, `notify_enter_call`, `notify_exit_call`, `notify_tx_revert`, `dump_call_stack_metadata`), but upstream **does** have a per-instruction seam: `Execution::execute` emits once per instruction at `vm2/simulation/gadgets/execution.cpp:1818` into `EventEmitterInterface<ExecutionEvent>`, and `ExecutionEvent` carries `wire_instruction` (opcode + operands + addressing mode), register inputs/outputs, and `before_context_event`/`after_context_event` whose `ContextEvent` has `pc`, `gas_used` and `gas_limit`. A `NoopEventEmitter<Event>` already provides the free-when-disabled arm. What it does **not** cover is the path we run: `HybridExecution` (`simulation/standalone/hybrid_execution.hpp`) reimplements the loop expressly "to remove overhead" and never calls `events.emit`, and `AvmSimulationHelper::simulate_fast_internal` (`vm2/simulation_helper.cpp:401`) passes `NoopEventEmitter<ExecutionEvent>` — so the seam is dead on the `AvmSimAPI` path `PublicTxSimulationTester` and this runtime take. Its payload is also sized for batch witness generation (two full `ContextEvent` snapshots including three tree snapshots each, accumulated into a `std::vector`), not for streaming. So the hook is written for the fast path, shaped after the **existing `EventEmitterInterface`** rather than after the call-stack collector, measured at +2.4% with full step recording and free when disabled, and prepared as an upstream contribution (patch 4 of 5) framed as extending an observation mechanism Aztec already maintains rather than adding a second one beside it.
- confidence: measured
- experiment: n/a

### RI-09 — `crypto_merkle_tree` / LMDB coupling
- upstream: `barretenberg/cpp/src/barretenberg/crypto/merkle_tree/` @ anchor `cpp`
- covers: -
- decision: extend
- milestone: M3, M11
- why: `crypto/merkle_tree/types.hpp` includes `lmdb.h` so `TreeDBStats` can embed `lmdblib::DBStats`. The module's tree algorithms are header-only and touch no database — the whole module contains exactly one non-test `.cpp`. The extension is a module split with independent merit (a merkle-tree library should not link LMDB to report statistics), and upstream half-expects it: `cmake/module.cmake` already guards the LMDB external-project dependency with `if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "wasm32" AND NOT BB_LITE)`. Prepared as an upstream patch; downstream carry is the recorded fallback, and the spike's stand-in (a header-only module plus a stray `lmdb.h` on the include path) is explicitly **not** reinstated because the spike itself identified it as the piece most likely to rot.
- rejection-reason: n/a
- confidence: reasoned
- experiment: n/a

### RI-10 — wasm exception support in barretenberg's toolchain
- upstream: `barretenberg/cpp/cmake/`, `CMakePresets.json`, `common/try_catch_shim.hpp` @ anchor `cpp`; wasi-sdk consumed as an upstream binary release
- covers: -
- decision: extend
- milestone: M4, M6, M11
- why: wasi-sdk 27, which upstream pins, cannot compile C++ exceptions at all — its sysroot ships a libc++abi with `cxa_noexception.cpp.o` and no `cxa_exception.cpp.o`. So the wasm preset defines `BB_NO_EXCEPTIONS`, which drives a textual shim (`#define try if (true)`, `#define catch(...) if (false)`) under which any C++ exception in a wasm build silently becomes `std::abort()`. wasi-sdk 33 ships `eh/` and `noeh/` multilib variants. The extension is a toolchain bump that retires the shim across the whole codebase; it removes a workaround for a toolchain limitation rather than a design choice. wasi-sdk itself is **not** forked — it is a binary release, packaged in `nix/wasi-sdk.nix` because nixpkgs has no `wasi-sdk` attribute.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-11 — 32-bit shift in the public bytecode commitment
- upstream: `vm2/simulation/lib/contract_crypto.cpp` @ anchor `cpp`
- covers: -
- decision: extend
- milestone: M5, M11
- why: `compute_public_bytecode_first_field` evaluates `bytecode_size << 32` on a `size_t`; where `size_t` is 32 bits this is undefined behaviour, and wasm's `i32.shl` masks the shift count to five bits and silently evaluates it as `<< 0`. A one-line widening to `uint256_t` produces identical codegen on 64-bit. The evidence that it is an oversight rather than intent — which is what makes the patch easy to accept — is that the function *already carries* `static_assert(DOM_SEP__PUBLIC_BYTECODE <= UINT32_MAX, ...)`: the separator's width was reasoned about carefully and `size_t`'s simply was not.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-12 — AVM-module / server-module CMake split (`AVM_WASM`)
- upstream: `barretenberg/cpp/src/CMakeLists.txt`, `cmake/arch.cmake`, `CMakePresets.json` @ anchor `cpp`
- covers: -
- decision: extend
- milestone: M6, M10, M11
- why: A single `if(NOT FUZZING AND NOT WASM AND NOT BB_LITE)` excludes ten modules at once, and its own comment is a statement about `world_state`, not about `vm2`. The extension is additive and default-off, and the existing `FUZZING_AVM` block already demonstrates the separation. This is the one patch of the five with no purpose except ours, and the plan says so rather than dressing it up — which is why it is submitted last.
- rejection-reason: n/a
- confidence: reasoned
- experiment: n/a

### RI-13 — Proving stack (honk, polynomial, srs, flavor, circuit builders)
- upstream: `barretenberg/cpp/src/barretenberg/{honk,polynomials,srs,flavor,...}` @ anchor `cpp`
- covers: -
- decision: replace
- milestone: M6, M12
- why: We do not prove, so the entire proving half of barretenberg is excluded from the link closure rather than reimplemented or stubbed. Every receipt the runtime issues carries `proving: 'none'`, and §8.4's disclosure makes that un-ignorable rather than a footnote.
- rejection-reason: does-not-cover: the proving stack exists, works, and is what the real node uses — it simply does not serve this runtime's purpose, which is *execution* with a trace. "Replace" here means "excluded from the link closure", not "reimplemented": nothing takes its place. It is recorded because excluding it is a decision with consequences (no `AvmProvingRequest` generation in M22; a public-only browser page never fetching `barretenberg.wasm` in M27), and because the exclusion is to be asserted rather than assumed: `verify_wasm_link_closure_excludes_proving` (M6, **not yet written** — the present tense here was a review finding) will fail if a honk, polynomial, srs, flavor or circuit-builder archive appears. Measured today from the spike link line, which is `vm2_sim world_state_reference crypto_merkle_tree env` and whose nine-archive closure contains none of them.
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
- why: The highest-value verification available for the least construction. Seven hand-assembled programs prove integration; upstream's suite proves correctness across the surface Aztec themselves consider covered, and they keep proving it. Measured under the spike build: 59 suites / 387 tests native, 141 passing under wasm.
- rejection-reason: n/a
- confidence: measured
- experiment: n/a

### RI-16 — The build target that runs those tests under wasm
- upstream: none **for wasm**. `vm2_sim` is declared with **no** `TEST_SOURCE_FILES`, the `vm2_tests` binary that carries them is gated on `if(AVM)` (which pulls in the proving stack the wasm build excludes), and the whole `vm2/` directory is excluded from a wasm configure. Natively `vm2_tests` builds by default.
- covers: test-harnesses
- decision: build
- milestone: M7
- why: The suite (RI-15) is upstream's; the target that compiles it for `wasm32-wasip1` is not and cannot be.
- rejection-reason: does-not-exist: searched the whole `barretenberg/cpp` CMake graph at the anchor. `vm2_sim`'s `barretenberg_module` declaration lists no test sources, and the only target that does — `vm2_tests` — is inside `if(AVM)` together with `sumcheck`, `stdlib_honk_verifier` and `goblin_avm`. There is no configuration of upstream's build that produces a **wasm** binary running `vm2/simulation/**/*.test.cpp` — and the decisive gate is one level above `if(AVM)`: `src/CMakeLists.txt:123` wraps `add_subdirectory(barretenberg/vm2)` in `if(NOT FUZZING AND NOT WASM AND NOT BB_LITE)`, so under wasm the directory is never added and `if(AVM)` is never evaluated. Natively it is a different story and the entry does not claim otherwise: `option(AVM ... ON)` is default-on, so an ordinary native build does produce `vm2_tests` — which is exactly the 387 tests RI-15 reports. What we build is 3 small support files over 99 upstream translation units, each marked in-source, and it is additive.
- confidence: measured
- experiment: n/a

### RI-17 — gtest/gmock under `wasm32-wasip1`
- upstream: gtest/gmock, consumed through barretenberg's FetchContent
- covers: -
- decision: open
- milestone: M7
- why: 35 of upstream's 59 vm2 simulation suites (≈243 of 387 tests) fail under wasm, and the correlation is exact: every gmock-free suite passes, every suite using `EXPECT_CALL`/`StrictMock` fails. Root cause measured — gtest's threading layer compiles against wasi-libc's pthread **stubs**, `pthread_self()` never matches the recorded mutex owner, `MutexBase::AssertHeld()` fails inside gmock's global expectation registry, and the subsequent unguarded mutation corrupts linear memory. This is a test-framework limitation, not an AVM one, and it is the largest unclaimed coverage win in the corpus.
- rejection-reason: n/a
- confidence: open
- experiment: Rebuilding gtest+gmock with `GTEST_HAS_PTHREAD=0` was already tried and did **not** help (identical 24/59), so the next experiment is narrower: instrument `MutexBase::AssertHeld` under wasm to find whether the failure is the owner comparison alone or the whole `GTEST_HAS_PTHREAD` path, then decide between an upstream gtest contribution and a local single-threaded synchronisation shim. Three further suites are gtest **death tests**, which fork and can never run under WASI; those are exclusions, not failures, and are recorded individually.

### RI-18 — Native-vs-wasm transcript driver (`avm_run.cpp`, `StepRecorder`)
- upstream: none for a deterministic printable transcript; `PublicTxSimulationTester` (RI-14) supplies everything underneath it
- covers: -
- decision: build
- milestone: M8, M12
- why: The differential between native and wasm needs a program whose entire output is a deterministic text transcript, so two builds can be diffed byte for byte.
- rejection-reason: does-not-exist: upstream's equivalents were read and none is a program whose **entire output** is a deterministic transcript — the gtest suites assert internally and print pass/fail, the AVM fuzzer compares three in-process C++ `TxSimulationResult`s structurally (`avm_fuzzer/fuzzer_lib.cpp:195`) and is `if(FUZZING_AVM)`-gated and native, `bb-avm-sim` (`barretenberg/avm/cli.cpp`) has exactly one leaf subcommand, `msgpack run`, requiring an IPC socket path and no `--dump`/`--trace`/`--print`, and `bb avm_simulate` only times the run. A per-instruction *line* does exist — `execution.cpp:1764` and `hybrid_execution.cpp:53` both `debug("@", pc, " ", instruction.to_string())` — but it is `#ifndef NDEBUG`, interleaved with other log output, carries no gas or memory, and is not the program's entire output, so it cannot be diffed between two builds. What we build is ~290 lines of driver over upstream's own harness; every simulation primitive underneath it is RI-14's.
- confidence: settled
- experiment: n/a

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
- why: It is the **only** production `@aztec/world-state/native` import in the whole non-test subtree (`public_processor.ts:64`; note that four non-test files do import `NativeWorldStateService` from the *bare* `@aztec/world-state` specifier — see RI-27 — so it is the subpath that is exclusive, not the package), and it is 46 lines of pure TypeScript with no native dependency of its own. Copying those 46 lines is what lets RI-27's replacement be total rather than partial. Vendoring a file to sever a dependency edge is a habit worth being suspicious of, which is why this entry exists rather than the copy being silent.
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
- why: The design document's §6 assumed this package would be adapted. It is now a priced, held-ready fallback rather than the plan, and M16's triggers are narrowed so that *doubt about the trees is not one of them*.
- rejection-reason: does-not-cover: the package was read and probed, not merely dismissed. It hashes internal nodes as `poseidon2([lhs, rhs])`; the current protocol hashes them as `poseidon2([SEP, lhs, rhs])` with a per-tree domain separator, so as shipped it produces **wrong roots** — the empty `NOTE_HASH_TREE` at depth 42 is `0x2590f2aa…9202e4c6` natively and `0x2ac5dda1…59a8a30a` from the package, with sibling paths diverging from level 1 upward (measured: the package root in `probe-mt/probe.mjs` and `probe2.mjs`, the domain-separated chain that reproduces the native root in `probe7.mjs`). It also offers *snapshots* — O(state), immutable, outliving their creator — where execution needs *checkpoints*: nesting, O(changes), strictly LIFO. And it fails `TypeError: this.nodes.get is not a function` against the June-2026 kv-store. The honest counterweight is recorded in M16: tree code rarely changes and a revival would probably work. It is the second choice because it would be **ours to maintain** and RI-02 is Aztec's, not because it could not be made correct.
- confidence: measured
- experiment: n/a

### RI-29 — `@aztec/telemetry-client`
- upstream: npm `@aztec/telemetry-client`
- covers: -
- decision: replace
- milestone: M18, M28
- why: Several vendored files construct telemetry clients; a no-op stub satisfies them.
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

### RI-49 — WASI shim for `avm.wasm`'s eleven imports
- upstream: `@aztec/bb.js` already ships a shim for exactly this import set, to run `barretenberg.wasm`
- covers: -
- decision: open
- milestone: M17, M27
- why: The import surface is frozen at eleven `wasi_snapshot_preview1` symbols — all libc startup and stdio, no filesystem, no network, no threads. bb.js's existing shim serves the same surface for the same engine, so writing one is the fallback rather than the plan.
- rejection-reason: n/a
- confidence: open
- experiment: M17's deliverable: attempt instantiation of `avm.wasm` under bb.js's shim unchanged; if it fails, record which of the eleven imports it does not satisfy and write only that difference. `verify_wasi_shim_reuse_decision_recorded` requires the answer either way.

---

## Not in this inventory, and why

- **wasi-sdk** — a binary toolchain release, consumed and deliberately not forked. Packaged in `nix/wasi-sdk.nix` only because nixpkgs has no `wasi-sdk` attribute. Recorded in M0's reuse audit.
- **`noir-lang/noir`** — belongs to the separate Noir tracing campaign and is untouched here. Its `tooling/ssa_fuzzer` is a *driver* for RI-34, not a component of this runtime.
- **`AztecProtocol/protocol-specs-pdf` and `AztecProtocol/engineering-designs`** — both **unlicensed** (`license: null`, `/license` 404, no LICENSE file). Read-only. Must not be vendored or redistributed, and are not.
