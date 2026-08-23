# `avm.wasm` — the standalone AVM reactor and its host ABI

One WebAssembly module containing the AVM, its in-memory reference world state and nothing else, so
a page that only executes a public transaction never downloads the proving stack.

Everything below is **measured**, from a tree built by
`verification/lib_m12_reactor.sh` out of the pinned anchor `233d8e0993` plus nine patches: the four
of the `AVM_WASM` series, the prepared per-instruction observation hook, and the four downstream
overlays (`verification/m7`, `m8`, `m9`, `m12`). Every number here is re-derived by a check; nothing
is quoted from elsewhere in the campaign without saying which artefact it belongs to.

Reproduce with `just verify-m12`.

## What the module is

A **WASI reactor**: no `main`, no `_start`. It is instantiated once, initialised through
`_initialize`, and then called through its exports. `-mexec-model=reactor` is the flag that produces
it, and it is a **link-only** driver option — clang rejects it outright as a compile option
(`unsupported option '-mexec-model=' for target 'wasm32-wasip1'`).

It links `vm2_sim`, which pulls `world_state_reference`, `crypto_merkle_tree`, `aztec`, the
poseidon2 / sha256 / keccak gadgets, `ecc`, `numeric`, `common` and `env` — and nothing from the
proving stack. That closure is M6's measurement and this milestone does not restate it.

## The import surface: twelve, of which eleven are WASI

| import | why it is there |
|---|---|
| `env.memory` | `src/CMakeLists.txt` links **every** barretenberg wasm artefact with `-Wl,--import-memory`, so the host owns the linear memory. Declared minimum 130 pages, maximum 65536, **not shared**. |
| `wasi_snapshot_preview1.environ_get` | libc startup |
| `wasi_snapshot_preview1.environ_sizes_get` | libc startup |
| `wasi_snapshot_preview1.clock_time_get` | libc startup |
| `wasi_snapshot_preview1.fd_close` | stdio |
| `wasi_snapshot_preview1.fd_fdstat_get` | stdio |
| `wasi_snapshot_preview1.fd_prestat_get` | stdio |
| `wasi_snapshot_preview1.fd_prestat_dir_name` | stdio |
| `wasi_snapshot_preview1.fd_read` | stdio |
| `wasi_snapshot_preview1.fd_seek` | stdio |
| `wasi_snapshot_preview1.fd_write` | stdio — the AVM's own `vinfo` logging, on fd 2 |
| `wasi_snapshot_preview1.proc_exit` | the abort path |

**No filesystem beyond libc startup, no sockets, no threads, and no oracle or foreign-call surface
at all** — unlike the private ACVM/Brillig side. `verify_avm_wasm_import_surface` asserts the
absence of `sock_*`, `path_*`, `fd_pread`/`fd_pwrite`/`fd_readdir`, `poll_oneoff`, `random_get`,
`thread_spawn` and anything under `env.` but the memory, **by name** rather than by a count.

### The milestone's figure was re-measured, and it survived

The deliverable froze this surface at "eleven `wasi_snapshot_preview1` symbols" and named them.
Measured on this artefact, that list is **exactly right**: eleven functions, those eleven. What the
deliverable did not say is that there is a twelfth import — `env.memory`, the only non-WASI one.
Twelve in total.

### The eleven are a consequence of the link options, not only of the code

This is the check's most useful result, and it took **two** corrections to get right.

The first version of the assertion said "pruning changes exports, not imports". Measured, that is
false: **the `--export-dynamic` control imports fifteen**, adding `fd_fdstat_set_flags`, `path_open`
and `poll_oneoff`.

The second version credited `--gc-sections` with removing them. Measured, that is false too, and
the linker says so itself — `wasm-ld --help` reads
`--gc-sections  Enable garbage collection of unused sections (defualt)`, upstream LLVM's own typo
included, and the check matches both spellings because a needle written from memory of what that
line ought to say is the same mistake as any other prefix match. **The collector is on in
both modules.** Omitting the flag from a link line changes nothing. What that control actually
varies is `--export-dynamic`, which turns every `visibility("default")` symbol in the closure into a
GC **root** and therefore *retains* the code that pulls those three WASI functions in.

So there are two options and they need two controls, one each:

| module | the one thing it changes | WASI imports | raw | gzipped |
|---|---|---|---|---|
| **`avm.wasm`** | — | **11** | 1,565,773 | 350,104 |
| `avm-unpruned.wasm` | `--export-dynamic` | 15 | 1,917,464 | 418,853 |
| `avm-nogc.wasm` | `-Wl,--no-gc-sections` | 45 | 2,716,029 | 617,489 |

The collector is worth far more than the export list, on both axes, and neither number could be
read off a single control. `path_open` and `poll_oneoff` — exactly what "no filesystem, no polling"
is a claim about — are imported by **both** controls, which makes their absence from `avm.wasm` a
discrimination rather than an observation.

`-Wl,--gc-sections` on the reactor's own link line is therefore **a restatement of the default, not
a switch that turns something on** — barretenberg passes it nowhere else in `barretenberg/cpp`, and
the anchor has no other occurrence of it. It is kept deliberately: a toolchain whose default changed
would silently cost 1,150,256 bytes and thirty-four WASI imports, and the flag is what says the
build did not mean to rely on a default. What it is not is the thing that produced the difference
the `--export-dynamic` control measures.

M7's "18 functions plus one memory, 19 in total" is a **different artefact**, and both numbers are
right. `vm2_sim_tests` is a WASI *command*: it carries gtest's own `main`, argv and environ
handling, file output and an exit path, and a command pulls more of wasi-libc than a reactor with no
`main` needs. The check builds **both** modules from the same tree and asserts both surfaces, so the
difference is measured here rather than reconciled in prose. The reactor imports nothing the command
does not.

## The export surface: thirty-nine, of which thirty-seven are written out in the link line

`--export-dynamic` is deliberately **not** passed. Each name below is given to the linker as
`-Wl,--export=` and is therefore also a `--gc-sections` root; the two options together are what
"exports pruned" means here — the reachable set is exactly what these names reach.

| group | exports |
|---|---|
| toolchain | `_initialize`, `memory` |
| linear memory | `avm_alloc`, `avm_free`, `avm_result_ptr`, `avm_result_len` |
| version | `avm_abi_version` |
| simulate | `avm_simulate`, `avm_simulate_with_hinted_dbs` |
| step stream | `avm_steps_count`, `avm_steps_batch` |
| contract DB lifecycle | `avm_contract_db_create`, `avm_contract_db_destroy` |
| **`ContractDBInterface`, the eight methods** | `avm_contract_db_get_contract_instance`, `avm_contract_db_get_contract_class`, `avm_contract_db_get_bytecode_commitment`, `avm_contract_db_get_debug_function_name`, `avm_contract_db_add_contracts`, `avm_contract_db_create_checkpoint`, `avm_contract_db_commit_checkpoint`, `avm_contract_db_revert_checkpoint` |
| contract DB population | `avm_contract_db_register_class`, `avm_contract_db_register_instance` |
| merkle DB lifecycle | `avm_merkle_db_create`, `avm_merkle_db_destroy` |
| **`LowLevelMerkleDBInterface`, the fourteen methods** | `avm_merkle_db_get_tree_roots`, `avm_merkle_db_get_sibling_path`, `avm_merkle_db_get_low_indexed_leaf`, `avm_merkle_db_get_leaf_value`, `avm_merkle_db_get_leaf_preimage_public_data_tree`, `avm_merkle_db_get_leaf_preimage_nullifier_tree`, `avm_merkle_db_insert_indexed_leaves_public_data_tree`, `avm_merkle_db_insert_indexed_leaves_nullifier_tree`, `avm_merkle_db_append_leaves`, `avm_merkle_db_pad_tree`, `avm_merkle_db_create_checkpoint`, `avm_merkle_db_commit_checkpoint`, `avm_merkle_db_revert_checkpoint`, `avm_merkle_db_get_checkpoint_id` |

**`HighLevelMerkleDBInterface` is not exposed**, and its absence is asserted by naming methods
rather than by counting exports — the fifteen of its nineteen that do not share a name with a
`LowLevelMerkleDBInterface` method. The other four are `create_checkpoint`, `commit_checkpoint`,
`revert_checkpoint` and `get_checkpoint_id`, which both interfaces declare and which are exported
for the low-level one; naming those as forbidden would have made the check contradict itself. It is internal to vm2: `simulate_fast_internal`
builds a `PureMerkleDB` itself, exactly as it wraps whatever raw contract DB it is handed in
`PureContractDB`. Both facts are read out of the fork at the anchor on every run.

### Why the host interfaces are exports and not imports

A host-**implemented** `ContractDBInterface` would be an imported callback, and the deliverable's own
"no oracle or foreign-call surface at all" would then be false of this artefact. So the two
interfaces are exposed as exports over implementations resident in the module. The
host-implemented, imported-callback shape is M15's *chatty* arm and is measured there against this
one; nothing here forecloses it.

### The raw contract DB was provisional here, and M13 has since answered it

In **this** artefact — the nine-patch M12 tree these numbers are measured from — the raw
`ContractDBInterface` is `TestContractDB` from `vm2/testing/`. `PureContractDB` is a decorator over
a raw one, and `get_debug_function_name` returns `nullopt` in `TestContractDB`, which the check
asserts rather than papers over. The module names the raw store in one place so the decision was a
one-line change.

**M13 made it, and two things this section used to say were wrong.** The enumeration found **eight**
implementations of `ContractDBInterface` upstream, not the three the question was framed around —
including `FuzzerContractDB` under `avm_fuzzer/`, a barretenberg subdirectory rather than anything
under `vm2/`. And upstream's shippable raw one is **not** the native `cdb` module: `cdb` is a
*transport adapter*, `CdbIpcContractDB` translating eight method calls into IPC, and on the far side
`yarn-project/simulator/src/public/cdb_ipc_server.ts` serves all eight out of the **TypeScript**
`PublicContractsDB`. So the shape upstream ships is store in TypeScript, adapter in C++, and the
wasm analogue of it is M15's *chatty* arm rather than anything C++ resident.

The answer taken is `simulation::MemoryContractDB` under `vm2/simulation/standalone/`, beside the
decorator that had never had a raw store to decorate, with a `CheckpointCoordinator` owning both
checkpoint stacks. That tree is **not** this one: it carries a tenth overlay and exports forty-nine
names rather than thirty-nine, and it is measured in
[`CONTRACT-DB.md`](CONTRACT-DB.md) and reproduced by `just verify-m13`. The identity above is held
to thirty-nine for **this** artefact on purpose — an export appearing is as much a finding as one
disappearing — so the two trees are built and checked separately rather than reconciled in prose.

## The host ABI is upstream's msgpack schemas

Enumerated **by execution**: `avm_msgpack_coverage` builds a populated instance of every crossed
type, packs it, unpacks it, re-packs it and compares the **bytes**, and requires a copy with one
field changed to encode differently. A type with no schema does not fail there — it fails to
*compile*, which is the point of asking the question in C++ rather than by grepping for a macro.

The comparison is on re-packed bytes rather than `operator==` because several crossed types declare
no `operator==` at all — `SequentialInsertionResult` is the first — so an equality-based check would
have silently narrowed the enumeration to the types that happen to have one.

**42 types, 0 failures, identical on x86-64 and on wasm32-wasip1 down to every encoded byte count.**

| origin | count | what it means |
|---|---|---|
| `origin=upstream` | 33 | declared in a file no overlay of ours touches, and read out of the fork at the anchor to prove it |
| `origin=msgpack-adaptor` | 7 | msgpack-c's own `std::tuple`, `std::optional` and `std::vector` adaptors over types already covered. Not a schema; an encoding msgpack provides |
| `origin=prepared-patch` | 1 | `ExecutionStep`, added by the prepared per-instruction observation hook — an upstream contribution, not an overlay |
| `origin=ours` | 1 | `AvmReactorError` |

The upstream schemas cover, among others: `AvmFastSimulationInputs`, `AvmProvingInputs`,
`PublicInputs`, `ExecutionHints`, `TxSimulationResult`, `PublicSimulatorConfig`, `Tx`,
`PublicTxEffect`, `CallStackMetadata`, `ContractInstance`, `ContractClass`,
`ContractClassWithCommitment`, `PublicKeys`, `ContractDeploymentData`, `GlobalVariables`,
`TreeSnapshots`, `AppendOnlyTreeSnapshot`, `GasSettings`, `GasUsed`, `ProtocolContracts`,
`DebugLog`, `IndexedLeaf<NullifierLeafValue>`, `IndexedLeaf<PublicDataLeafValue>`,
`LeafUpdateWitnessData`, `SequentialInsertionResult`, `GetLowIndexedLeafResponse`,
`WorldStateRevision`, and the enums `MerkleTreeId`, `RevertCode` and `CoarseTransactionPhase`.

**The step stream needed nothing of ours.** `ExecutionStep` is already
`MSGPACK_CAMEL_CASE_FIELDS(context_id, contract_address, pc, opcode, gas_used)` and
`TxSimulationResult` already carries `std::optional<std::vector<ExecutionStep>> execution_steps` —
both added by the prepared observation-hook contribution rather than by us.

### The one type that is ours, and why

`AvmReactorError { std::string message; SERIALIZATION_FIELDS(message); }`.

Upstream **has** an error envelope: `bb::bbapi::ErrorResponse` in `bbapi/bbapi_shared.hpp`, with the
same single `message` field and the same `SERIALIZATION_FIELDS`. It is not usable here, and the
reason is a fact about upstream's build graph rather than a preference:

- the `bbapi` module's own line is
  `barretenberg_module(bbapi common chonk dsl crypto_poseidon2 crypto_pedersen_commitment crypto_pedersen_hash crypto_blake2s crypto_aes128 crypto_schnorr crypto_ecdsa ecc srs)`
  — `chonk`, `dsl`, `ecc` and `srs` are the proving stack this artefact exists to exclude, and `srs`
  is on M6's own forbidden list;
- the header does not stand alone: it names `ChonkStepProcessor` and `acir_format::AcirFormat`.

Ours is shaped identically, so a host decoder written for upstream's `ErrorResponse` decodes it
unchanged and deleting ours in favour of upstream's is a one-line change if `bbapi` is ever split.
Both halves of that reason are re-derived from the fork at the anchor on every run.

### The calling convention

Every call that produces bytes leaves them in a module-owned buffer and returns a status; the host
then reads `avm_result_ptr()` / `avm_result_len()` and copies them out before the next call. One
buffer, reused, owned by the module: returning a freshly allocated pointer the host must free makes
every error path a leak.

| status | meaning |
|---|---|
| 0 | success; the result buffer holds the msgpack result, or is empty for a void method |
| 1 | a `std::exception` escaped — including an input that is not decodable. The buffer holds an `AvmReactorError` |
| 2 | a non-`std::exception` escaped |
| 3 | no such DB handle |

**A revert is not an error.** It comes back as status 0 with a `TxSimulationResult` whose
`revertCode` is non-zero. A C++ exception is never allowed to unwind out of an export — it would
trap the instance, and a trapped instance and a reverted transaction are different things. M17
enforces that distinction on the host side; this is its C++ half.

Method arguments that are more than one value are packed as a msgpack **array** of types already
covered — msgpack-c's own `std::tuple` adaptor. That is an encoding msgpack provides, not a schema
we declared, and it is enumerated as such.

## The two entry points, both built and measured

| | `avm_simulate` | `avm_simulate_with_hinted_dbs` |
|---|---|---|
| input | `AvmFastSimulationInputs` | `AvmProvingInputs` |
| DBs | host-named resident handles | none; everything is in the hints |
| public inputs / tree roots | yes, when the config asks | **no** |
| statistics | yes, when the config asks | **no** |
| input size, `add` | 1,951 bytes | 186,712 bytes |
| input size, `burn` | 1,951 bytes | 187,651 bytes |
| input size, `storage` (the largest) | 1,951 bytes | 191,807 bytes |

The hinted path collects neither public inputs nor statistics because upstream's own
`AvmSimAPI::simulate_with_hinted_dbs` constructs `const PublicSimulatorConfig config = {}` for it
(`vm2/avm_sim_api.cpp`). That is asserted, not worked around. On the fields it does produce — revert
code, all four gas dimensions, the transaction fee, the nullifier and data-write counts — it agrees
with the driver and with the resident path exactly, for all seven corpus programs.

The choice between them is **M15's**, and this milestone records the two measurements it will need
rather than making it.

## The step stream

`TxSimulationResult.execution_steps` already carries the whole stream, so a host that decodes the
result has all 38,903 of `burn`'s records after **one** call and **zero** further crossings. That is
the strongest form of the deliverable's "one call per batch" and it is upstream's own field.

`avm_steps_batch(from, count)` exists for the host that does not want to decode the whole result, or
that wants to stream records into a trace writer as it goes (M24, M25). Drained at batch size *B* it
costs exactly `ceil(38903 / B)` crossings, asserted at four batch sizes:

| batch | crossings |
|---|---|
| 1 | 38,903 |
| 512 | 76 |
| 4,096 | 10 |
| 65,536 | 1 |

The window is **clamped by subtraction, not by addition**: `size_t` is 32 bits on `wasm32` and
`count` is a `uint32` the *host* chooses, so `begin + count` wraps for a count near `2^32 - begin`
and a wrapped `end` below `begin` would construct a vector from a reversed range — undefined
behaviour reachable straight from the boundary, which `guarded()` cannot catch because it is not an
exception. Reading past the end returns an empty batch, and `count = 2^32 - 1` returns the whole
remaining window from wherever it starts; both are asserted.

There is deliberately **no per-step export**. Measuring the rejected shape does not need one:
`avm_steps_batch(i, 1)` *is* one crossing per record, through the same export, so the comparison is
between two call patterns and not between two APIs, and the encode/decode work is identical on both
sides.

**Per-event crossings are rejected on measurement.** Three interleaved repetitions of each arm, the
minimum of each taken, on an idle machine — the check exits 3, a code of its own, if the machine is
busy, and on this run it waited 15 s for the load average to come down before it would measure.

| session | arm | rep 0 | rep 1 | rep 2 | minimum |
|---|---|---|---|---|---|
| 1 | batched, B = 4,096 | 88,933 us | 84,570 us | 97,411 us | **84,570 us** |
| 1 | per event, B = 1 | 114,395 us | 109,869 us | 109,724 us | **109,724 us** |
| 2 | batched, B = 4,096 | 86,807 us | 84,844 us | 98,187 us | **84,844 us** |
| 2 | per event, B = 1 | 113,636 us | 108,553 us | 109,896 us | **108,553 us** |
| 3 | batched, B = 4,096 | 90,997 us | 84,851 us | 98,089 us | **84,851 us** |
| 3 | per event, B = 1 | 111,477 us | 109,567 us | 112,393 us | **109,567 us** |

Per-event costs **1.29x**, **1.27x** and **1.29x** the batched arm across three sessions, over
**38,893 extra crossings**, which puts the marginal cost of one boundary crossing at **646 ns**,
**609 ns** and **635 ns** respectively. Three sessions are quoted rather than one because that is
the spread this measurement has on this host; the check asserts the ordering and the crossing-count
identities, not a particular ratio.

The ratio is not larger than it is, and the reason is worth stating rather than hiding: **both arms
encode and decode all 38,903 records**, and that work dominates. What the difference isolates is the
crossing itself. So the number to carry into M15 is the 600-650 ns per crossing, not the 1.3x — a
transaction that crosses the boundary per storage read pays that per read, and a shape that crosses
once per transaction pays it once.

Only `x86_64-linux` was exercised, as in M6 through M9.

All 38,903 records are compared **per record** against the native driver's own `steps` transcript —
context id, pc, opcode, cumulative L2 and DA gas, contract address — and the comparator is shown to
find a single altered record, so a zero is a measurement rather than an absence.

## Size

Measured, stripped, with the observation hook compiled in:

| artefact | raw | gzipped |
|---|---|---|
| **`avm.wasm`** | **1,565,773** | **350,104** |
| `avm-unpruned.wasm` (control 1: `--export-dynamic`) | 1,917,464 | 418,853 |
| `avm-nogc.wasm` (control 2: `-Wl,--no-gc-sections`) | 2,716,029 | 617,489 |
| `avm-reactor-debug.wasm` (the linker's output, unstripped) | 9,990,457 | — |
| `barretenberg.wasm` from the same tree and toolchain | 18,017,075 | ~4,046,715 |

**The budget: 1800000 raw and 400000 gzipped.**

It is deliberately not the measurement — a budget equal to the measurement fails on any change at
all and therefore gets raised rather than read — and it is deliberately not a round number pulled
out of the air. It is chosen so that **both controls fail it**, on both axes. A budget the controls
pass is a budget that would not notice either link option going away.

`avm.wasm.gz` is 11.5 times smaller than `barretenberg.wasm.gz` from the same tree (measured
ratio 115/10). The milestone's
comparison figure of 2.93 MiB gzipped is for `barretenberg-threads.wasm`, a preset this tree does
not configure; what is measured above is the single-threaded `barretenberg.wasm` from the `wasm-avm`
preset.

**That figure is quoted with a `~` because `barretenberg.wasm` is not byte-reproducible.** Measured:
two builds of the same tree with the same toolchain, in two different work directories, produce a
`barretenberg.wasm` of the same size (18,017,075) that differs in **64 bytes**, which gzip turns
into 4,046,715 and 4,046,721 in two different work directories. `avm.wasm` itself **is** byte-identical across those same two
builds, so this is a property of the comparison artefact and not of the module under test. An
earlier version of `verify_avm_wasm_size_budget` required this page to carry the gzipped figure
verbatim and therefore failed on a correct build from a clean work directory; it is asserted with a
1% tolerance instead.

### The milestone's size figure was stale and is corrected

The deliverable states "1,259,737 bytes raw and 272,661 gzipped". That figure predates this
artefact. It was taken from the vm2-wasm spike's reactor, which had no msgpack host ABI, no
resident-DB export surface and no `testing/` translation units in its link closure. The measured
figures above replace it.

### Each of the four size measures is measured separately

- **`-Oz`** — read off every one of barretenberg's own compile commands in the wasm build's compile
  database, including the reactor's own four entries (`avm_reactor.cpp` is compiled three times, once
  for the module and once for each control, plus `avm_msgpack_coverage.cpp`), with `-O2` asserted
  absent.
- **pruned exports** — the difference between `avm.wasm` and `avm-unpruned.wasm`, which adds
  `--export-dynamic` and nothing else: 351,691 bytes raw and 68,749 gzipped, **2,077 exports down to
  39, and three WASI imports** (`fd_fdstat_set_flags`, `path_open`, `poll_oneoff`).
- **`--gc-sections`** — the difference between `avm.wasm` and `avm-nogc.wasm`, which adds
  `-Wl,--no-gc-sections` and nothing else: 1,150,256 bytes raw and 267,385 gzipped, and **45 WASI
  imports down to 11** with the export list unchanged at 39. It needs its own control because
  wasm-ld collects by default.
- **symbols stripped** — the difference between `avm.wasm` and the linker's own output: 8,424,685
  bytes.

`avm.wasm.gz` is produced by the build with `gzip -9 -n`, and the check re-runs that and requires
byte-identical output, so the gzipped figure is not a property of whichever gzip a script found.

## Two modules, deliberately: `vm2_sim` is not added to `BARRETENBERG_TARGET_OBJECTS`

`barretenberg.wasm` is assembled from `BARRETENBERG_TARGET_OBJECTS` in
`barretenberg/cpp/src/CMakeLists.txt`. Adding `vm2_sim_objects` to that list would give one module
instead of two — and would couple public execution to a `barretenberg.wasm.gz`-sized download that a
public-only page currently avoids entirely, an eleven-fold cost for nothing it needs. The decision is
to ship two modules. `verify_avm_wasm_size_budget` asserts that `vm2_sim` is absent from that list
both in the fork at the anchor and after M12's overlay, so the decision cannot be reversed silently.

## The transcript agreement

The native `avm_differential` — x86-64, one process, `PublicTxSimulationTester` driving `AvmSimAPI`
directly in C++ — against `avm.wasm` on V8 driven from JavaScript across the msgpack boundary. 147
result lines for the seven corpus programs, of which 56 are tree roots and sizes. **Zero
mismatches.**

This is not "the wasm build agrees with the native build" — that is M8's number and M8's coverage
statement. It is "the ABI does not lose or alter anything on the way through", across a different
target, a different language and a serialisation round trip.

The comparison is directional and the exceptions are enumerated rather than filtered: the driver
emits `.beforeDeploy`, `.afterDeploy` and `.afterSimulate` lines, which are the *tester's* own DB —
a C++ harness object with no counterpart on the reactor's ABI — and a `.bytes` line per program,
which is the bytecode length rather than a result field.

The seeding the host replays into the resident DBs is **read back out of the tester's own trees** at
the index the values landed at, not re-derived from `DOM_SEP__*` constants and a fee-payer balance
restated downstream. `fund_fee_payer` is private on the tester precisely because it is upstream's
business, and a constant restated downstream is a constant that can drift away from upstream's
silently.

## Coverage, stated so no number here can be quoted as another milestone's

The transcript half is the **same seven hand-assembled corpus programs** M8 compares, driven this
time through the reactor's msgpack ABI from JavaScript. That is an integration check across a
boundary. Breadth is M7's 391 upstream tests; semantics is M19's 77-comparison oracle; the
per-record step agreement is M9's 39,086 across eight programs, of which this milestone re-checks
`burn`'s 38,903 across the boundary.

## CI

`.github/workflows/avm-wasm.yml` carries a third job, `avm-reactor`, running `just verify-m12`.

**It has never run.** Neither of that workflow's two existing jobs has ever run to completion
either: both abort at `Generate CI token` on "Input required and not supplied: app-id", and M11
recorded that as undiagnosed. So "the size budget is enforced in CI" means *the job exists, is
wired, and names this check* — not that a run has ever gated anything. The check asserts the former
and this paragraph states the latter.
