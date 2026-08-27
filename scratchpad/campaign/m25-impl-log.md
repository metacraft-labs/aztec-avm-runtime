# M25 — Step-Level Tracing from the Observation Hook — implementation log

Written after every completed step, not at the end.

## Step 0 — orientation (done)

Read, in order: `scratchpad/campaign/m25-brief.md`, `CAMPAIGN-BRIEF.md` in full, the M25 / M9 /
M13 / M24 sections of `codetracer-specs/Planned-Work/Aztec-AVM-Runtime.milestones.org`,
`TRACE-ABI.md`, `pins.json`, `ct-writer/src/lib.rs`, `ct-host/src/abi.ts`, `ct-host/src/writer.ts`.

State at start: `aztec-avm-runtime` clean at `6db58caad`… (no — `5f80bcd`), `codetracer-specs`
clean at `9dfd6e75`. No commits will be made by this agent.

What the tree already has, established by reading rather than assumed:

- `ct-writer/src/lib.rs::emit()` is the ONE place an event becomes writer calls. It is rung 3:
  `TraceWriter::register_step(&mut s.writer, &path, Line(pc as i64))`.
- The contract address is recorded as `contractAddressLow` — `ValueRecord::Int` over the low 64
  bits — explicitly as M24's placeholder for OQ-4.
- `ct_writer_open(..., want_columns)` is honoured at the current `trace_format` anchor
  `592fa42cbf`; `dropped_column_awareness()` answers false. So the writer is not a constraint.
- The event record is 64 bytes, five fields + an 8-byte reserved word asserted zero on ingest.
  Adding a field is a wire-format change.

## Step 1 — three parallel investigations launched (in flight)

1. OQ-5: does `avm-transpiler` preserve pc → Brillig index → ACIR debug info → source location?
2. The transaction-builder closure: `PublicTxSimulationTester`'s vendoring closure, as a number.
3. OQ-4: how the Noir tracer renders a `Field`, and the exact `ValueRecord` variant to match.

## Step 2 — enumeration BEFORE building (done). Five findings, and three change the shape.

The campaign's rule is "enumerate before you build — nine near-misses, every one a parallel
subdirectory". Doing that here found the milestone is much less "ours to write" than its
deliverables read.

**(a) THE BLOCKER'S BUILDER IS ALREADY VENDORED IN THIS REPOSITORY.**
`diffsim/src/public/fixtures/public_tx_simulation_tester.ts` — 338 lines, provenance header,
upstream path `yarn-project/simulator/src/public/fixtures/public_tx_simulation_tester.ts` at
anchor `ts` (`3a68d68ac2`), inventory RI-25. It has been in the tree since M2. The eight entries
blocked "because upstream's only builder constructs a `NativeWorldStateService`" were blocked on
a class this repo already carries a pinned copy of.

**(b) THE `NativeWorldStateService` IS IN THE STATIC FACTORY ONLY, NOT IN THE CLASS.**
`public_tx_simulation_tester.ts:100-113` — `static async create(worldStateService, …)` calls
`worldStateService.fork()` to obtain a `MerkleTreeWriteOperations`. The *constructor*
(`:82-98`) takes that `MerkleTreeWriteOperations` as an argument and never mentions the native
service. And the calldata-and-call-request half is `#createPubicCallRequestForCall` (`:276-308`)
plus `createTxForPublicCalls` — neither of which touches world state at all.

**(c) THE RESIDENT CONTRACT DB CAN ALREADY REGISTER A CONTRACT.**
`orchestration/src/resident_contracts_db.ts:180` `registerClass(contractClass)` and `:210`
`registerInstance(instance)` are public methods that push a class (with arbitrary
`packedBytecode` and upstream's own `computePublicBytecodeCommitment`) and an instance at an
arbitrary address straight into the module's resident store. "A registered contract" does not
need a world-state service in this runtime; it needs these two calls.

**(d) THE ARTEFACTS ARE PINNED AND PRESENT.** `fixtures/contracts/artifacts.json` declares
`Token` (`@aztec/noir-contracts.js/Token`, 19 public functions, `transfer_in_public` among the
called set) and `AvmTest` (`@aztec/noir-test-contracts.js/AvmTest`, 85 public functions,
including **`debug_logging`**) — both with `aztecVersionMatchesDeclaredPin: true`.
So both of the two "blocked" entries have their subject already pinned in this tree.

**(e) MOST OF WHAT M25 CALLS "TRACE CONTENT" IS ALREADY IN UPSTREAM'S OWN RESULT STRUCT.**
`barretenberg/cpp/src/barretenberg/vm2/common/avm_io.hpp:552` `TxSimulationResult` at the `cpp`
anchor carries, msgpack-encoded, all of:

| what M25 wants | where it already is | gate |
|---|---|---|
| call/return frames, nested, with `reverted` | `call_stack_metadata` (`CallStackMetadata`, `:506`) — `contract_address`, `caller_pc`, `calldata`, `is_static_call`, `gas_limit`, `output`, `reverted`, `nested`, `internal_call_stack_at_exit`, `halting_message` | `collect_call_metadata` |
| side effects | `public_tx_effect` (`PublicTxEffect`, `:540`) — `note_hashes`, `nullifiers`, `l2_to_l1_msgs`, `public_logs`, `public_data_writes` | always |
| `debug_log` with message and fields | `logs` (`std::optional<std::vector<DebugLog>>`); `DebugLog` is `aztec_types.hpp:589` — `contract_address`, `level`, `message`, `fields` | `collect_debug_logs` |
| the AVM's own executed-instruction statistic | `stats["total_instructions_executed"]` | `collect_statistics` |
| per-instruction steps | `execution_steps` (M9's patch) / `avm_steps_batch` | `collect_execution_steps` |

`shipped_module_config.ts:42` currently hard-codes `collectExecutionSteps: false` and nothing
sets the other four. That is the seam M25 opens.

**(f) THE MODULE IS ALREADY BUILT.** `~/.cache/aztec-m23-chain/m23/…/bin/avm.wasm`, 2026-08-26,
twelve overlays including `$M9_OBSERVER_PATCH` and `$M9_PATCH_7` (the step record). No multi-hour
C++ build is required for M25.


## Step 3 — OQ-5 SETTLED, with evidence, and the verdict is the favourable one (done)

**The transpiler DOES preserve the mapping, and the naive path is wrong in a favourable
direction.** It is not `pc → Brillig index → ACIR debug info`; `avm-transpiler` **rewrites the
debug info in place**, so the shipped artifact carries a map that is **already keyed by AVM pc**.

Source evidence, all read at the `cpp` anchor `233d8e0993` out of the object store:

- `avm-transpiler/src/transpile.rs:53` — `pub fn brillig_to_avm(...) -> (Vec<u8>, Vec<usize>)`,
  doc'd "Returns the bytecode and a mapping from Brillig program counter to AVM program counter".
- `transpile.rs:475` — `current_avm_pc += avm_instrs.iter().skip(...).map(|i| i.size()).sum();
  brillig_pcs_to_avm_pcs.push(current_avm_pc);` and `instructions.rs:83` —
  `pub fn size(&self) -> usize { self.to_bytes().len() }`. **So an AVM pc is a BYTE OFFSET.**
- `transpile.rs:1803` — `pub fn patch_debug_info_pcs(debug_infos, brillig_pcs_to_avm_pcs)`, whose
  body re-keys every `brillig_locations` entry:
  `BrilligOpcodeLocation::new(brillig_pcs_to_avm_pcs[original_opcode_location.index()])`.
- `transpile_contract.rs:106,116-119,129` — the call site: `brillig_to_avm` then
  `patch_debug_info_pcs(function.debug_symbols.debug_infos, &brillig_pcs_to_avm_pcs)`, stored as
  `debug_symbols: ProgramDebugInfo { debug_infos }` on the emitted `AvmContractFunctionArtifact`.
- The C++ AVM's pc is the same byte offset:
  `vm2/simulation/gadgets/execution.cpp:1765` — `context.set_next_pc(pc + instruction.size_in_bytes())`.
- `git diff 233d8e0993 HEAD -- avm-transpiler/` is EMPTY, so the anchor and the fork tip agree.

**And it is confirmed on the artefact rather than only in the source.** Measured just now against
the installed `@aztec/noir-test-contracts.js/artifacts/avm_test_contract-AvmTest.json`
(`diffsim/node_modules`, `deletion_era` pin):

```
public_dispatch: bytecode 50,939 bytes
debug_symbols -> inflateRaw -> JSON: debug_infos[0].brillig_locations["0"]
  9,021 entries, min key 706, max key 50,526
  first keys: 706,715,720,725,730,735,739,744,749,754,758,763,767,772,790
file_map: 86 files
brillig_procedure_locs: {"0":{"0":[9571,9589],"1":[9313,9325],"3":[9329,9339],"11":[9340,9342]}}
```

The keys are **sparse, increasing, strides of 4–9, and bounded above by the bytecode length** —
which is what AVM byte offsets look like and is *not* what a dense Brillig opcode index would look
like. That is the decisive evidence, and it is re-derivable by a check.

**Verdict: rung 1 — full source-level stepping — is reachable with NO upstream change**, for any
contract whose artifact is available to the runtime. **No sixth upstream contribution is
warranted for OQ-5's question as asked.**

Three residual holes, none of which blocks rung 1, all measured:

1. **`brillig_procedure_locs` is NOT re-keyed.** `grep -rn brillig_procedure_locs avm-transpiler/src/`
   → zero hits, and the measurement above shows values (9313..9589) far below the 50,526 the
   sibling map reaches. So one `DebugInfo` carries two key spaces at once.
2. **Procedure-region pcs have no `brillig_locations` entry**, because compiled procedures are
   appended after the main body (`transpile.rs:489,505`) past the end of `brillig_pcs_to_avm_pcs`.
3. **`assert_messages` is dropped** — neither artifact struct at `transpile_contract.rs:44-76`
   declares the field and there is no `serde(flatten)`.

Those three are a candidate SIXTH upstream contribution, and it is a small one (~35 lines across
two files). It is recorded as a candidate rather than prepared, because OQ-5's question is
answered without it and the campaign's rule is that a contribution is argued on upstream's own
terms rather than bundled.

**The one thing that contradicts a naive reading, recorded because it is a trap:** the type is
still called `BrilligOpcodeLocation` after the rewrite. Anyone grepping the type name concludes
the mapping was never rewritten. It was.

## Step 4 — OQ-4 SETTLED BY MEASUREMENT, five arms, one differs (done)

What the Noir tracer does, verified in `/home/zahary/m/blocktracer/noir`:

- `tooling/tracer/src/tracer_glue.rs:148-152` — `PrintableType::Field` becomes
  `ValueRecord::Int { i: field_value.to_i128() as i64, type_id }`.
- `tooling/tracer/src/tracer_glue.rs:371` — the type is `(TypeKind::Int, "Field")`.
- `acvm-repo/acir_field/src/field_element.rs:253-256` — **`to_i128` PANICS** unless
  `fits_in_i128()`, which is `num_bits <= 127`. Then `tracer_glue.rs:152` truncates with `as i64`.

**So the Noir half cannot render a full-width 254-bit field at all today**: it either aborts the
recorder or keeps the low 64 bits with a sign fold. A 32-byte Aztec contract address is
full-width. "Match the Noir tracer exactly" would mean matching a rendering that panics.

**So the question was put to the artefact.** Five containers, written by the pinned Path A writer
(`592fa42cbf`) natively, each carrying the SAME control variable (`control` = `Int 42`) plus one
`subject` rendered a different way, then read by BOTH pinned readers:

| arm | subject rendering | `ct-print --full` | `ct-split-probe` |
|---|---|---|---|
| `int` | (control only) | rc=0 | ok |
| `low64` | `Int { i: <low 8 BE bytes> }` | rc=0, `361984551142689548` | ok |
| `bigint` | `BigInt { b: <32 BE bytes>, negative: false }` | **rc=1** | ok |
| `string` | `String { text: "0x" + 64 hex }` | rc=0, full 64 hex chars | ok |
| `raw` | `Raw { r: "0x" + 64 hex }` | rc=0, full 64 hex chars | ok |

The bigint arm's message is exact and names the cause:

```
Error reading events: failed to decode events: cbor: expected byte string (major 2), got major 3
```

`codetracer_trace_types/src/base64.rs` at the pinned revision serialises `BigInt.b` with
`String::serialize(&base64, s)` — a CBOR **text** string (major 3) — while the reference Nim
reader reads a **byte** string (major 2). So the only full-precision variant in the shared
`ValueRecord` **cannot be read by the reader this campaign pins**.

**AND THE SPLIT PROBE READS THE BROKEN ONE GREEN.** `ct-split-probe` reports `DONE ok` and lists
`control,subject` for the bigint arm, because it counts and names value records without decoding
their contents. That is this campaign's recurring shape — a check that never exercises the thing
it is named for — found in an instrument M24 added. Both readers are run in the check for that
reason.

**Verdict: the contract address is recorded as `ValueRecord::String { text }` where `text` is
`0x` + 64 lowercase big-endian hex characters, under `ensure_type_id(TypeKind::Int, "Field")`.**
It is full precision, it round-trips through both pinned readers, and it is producible by both
halves. `String` rather than `Raw` because `Raw` is Noir's escape hatch for values it cannot
represent (`"()"`, `"fn"` — `tracer_glue.rs:252,285`) and this is a value it can.

**The cross-half work this leaves, named rather than implied**: the Noir half must be changed to
match, in `noir/tooling/tracer/src/tracer_glue.rs:148-152`. That is a Metacraft repository, not
Aztec, so it is NOT the sixth upstream contribution.

## Step 5 — the transaction-builder closure, as a number (done)

Computed independently, by my own import walker over
`upstream/tsavm/yarn-project` at the `ts` anchor `3a68d68ac2` (relative specifiers only, block
and line comments stripped, `.js` → `.ts` resolution, `index.ts` fallback, residue printed):

```
FILES 65   LINES 10421   UNRESOLVED []
```

**Full closure: 65 files, 10,421 lines** — against M22's `PublicProcessor` at 1,580. Seven of the
65 are already vendored under `orchestration/src/vendor/`, so 58 files / 9,739 lines would be new.

**But the shape the M23 Q&A predicted is the shape that is there.** `NativeWorldStateService`
appears twice in the whole file: the import at `public_tx_simulation_tester.ts:22` and the first
parameter of the **static factory** `create(...)` at `:101`, whose only use is
`const merkleTree = await worldStateService.fork()` at `:108`. **The constructor at `:82` takes a
`MerkleTreeWriteOperations`** — an interface from `@aztec/stdlib/interfaces/server` that this
repo's `ResidentMerkleWriteOperations` already implements. Dropping the static and the import
severs the `@aztec/world-state` edge entirely.

**Reduced closure — the calldata-and-call-request half — is 5 files, 1,042 lines**, verified by
`wc -l` at the anchor:

| file | lines | what |
|---|---|---|
| `simulator/src/public/fixtures/public_tx_simulation_tester.ts` | 329 | `createTx`, `#createPubicCallRequestForCall`, `defaultGlobals` |
| `simulator/src/public/fixtures/utils.ts` | 275 | `createTxForPublicCalls` — **a LEAF, zero relative imports** |
| `simulator/src/public/avm/fixtures/utils.ts` | 154 | `getFunctionSelector`, `getContractFunctionAbi`, `createContractClassAndInstance` |
| `simulator/src/public/fixtures/simple_contract_data_source.ts` | 122 | the in-memory artifact/class/instance source |
| `simulator/src/public/avm/fixtures/base_avm_simulation_tester.ts` | 162 | `registerAndDeployContract` — optional |

**Without the base tester: 4 files, 880 lines.** Three local trims inside
`avm/fixtures/utils.ts` sever the rest: `resolveContractAssertionMessage` (`:84`) is the only
thing reaching `common/` (4 files, 241 lines), and `randomMemory*` (`:41-55`) is the only thing
reaching `avm_memory_types.js` and `errors.js`.

**No new package dependency.** Every `@aztec/*` specifier in the reduced set resolves inside
`@aztec/{constants,foundation,protocol-contracts,stdlib}`, which `orchestration/package.json`
already depends on; the only non-`@aztec` edges are `assert` (builtin) and `lodash.merge`
(reached only by the droppable `allSameExcept`).

**So the number that has blocked eight entries since M18 is 880, or 1,042 with the registration
helper — against M22's 1,580, which the campaign already judged obvious.**

## Step 6 — built (done). What was reused, what was written, what was NOT changed.

### The design decision that shaped everything: the step record did NOT grow

`TRACE-ABI.md` §7 offered the step record's reserved bytes as the wire-format extension point and
said there were **eight** at offset 12. **There are four.** The offsets are `0,4,8,12,16,24,32+32`
— sixty used, four reserved, sixty-four total — and `const _: () = assert!(OFF_ADDRESS +
ADDRESS_LEN == CT_RECORD_SIZE)` had been pinning the TOTAL all along while nothing compared the
other two figures to the layout. The module's own header said "the 56 the fields need" and it is
60. Both are constants now (`CT_RECORD_FIELD_BYTES`, `CT_RECORD_RESERVED_BYTES`), asserted against
the offsets at compile time AND by a native test, and §7 is corrected.

A `(path_id, line, column)` triple is twelve bytes, so it would not have fitted anyway. Growing the
record to 80 would have moved every container size M24 measured, invalidated §3's
byte-identical-container claim and required OQ-6's twelve-session benchmark to be re-taken.
**So M25 added a separate 16-byte position channel** — `ct_positions(ptr, len)`, handed over
immediately before the step batch, paired **by order**. With no positions supplied, every byte the
module writes is what M24 measured: `ct_record_size()` is still 64 and
`CT_ERR_RESERVED_NOT_ZERO` is still reachable.

### Reused

- **`lib_m24_ct_writer.sh` entire** — the module build, the bounded runner, the abnormal-exit trap,
  the pin reader, the published-refcount predicate, `m24_ct_print`, `m24_split_probe`.
  `lib_m25_trace.sh` sources it rather than copying it: one crate, one artefact.
- **`CtfsTraceWriter::register_step_with_column` and `register_path_with_line_lengths`** at the
  pinned `trace_format` anchor — the column-aware step encoder and the `paths.dat` Layout A
  line-length table. Nothing about columns is written here.
- **Upstream's own `debug_symbols`** — decoded, never re-derived.
- **`@aztec/noir-test-contracts.js`'s `AvmTest`**, at the `deletion_era` pin, as the artefact OQ-5
  is settled against. A fixture of ours would have measured this repository's opinion.

### Written

| file | what | depends on |
|---|---|---|
| `ct-writer/src/lib.rs` (+~330) | 11 exports: `ct_intern_path`, `ct_positions`, `ct_declare_rung` and eight counters; the position FIFO; the rung table; OQ-4's hex renderer; 6 new native tests | `codetracer_trace_types`, `codetracer_trace_writer` (unchanged) |
| `ct-host/src/source_map.ts` (new, 300) | `rungFor`, `ContractSourceMap`, `lineLengths`, `lineColumnOf`, `locationsOf` | nothing — no npm dependency, no Node import |
| `ct-host/src/abi.ts` (+~120) | `SOURCE_MAPPING_EXPORTS`, `ALL_REQUIRED_EXPORTS`, the rung constants, `encodePosition`/`decodePosition` | — |
| `ct-host/src/config.ts` (+~60) | `mappingRung` on the config, the rung-aware column gate, `MappingRungDegraded` | — |
| `ct-host/src/writer.ts` (+~140) | `internPath`, `declareRung`, position staging in `push`/`flush`, the close-time refusal | — |
| `tools/run_trace_arms.mjs` (new, 380) | eight arms, one run, shared | `node:zlib` (a tool, not `ct-host`) |
| `verification/_import_closure.py` (new, 175) | the closure walker, residue printed | — |
| `verification/oq4_rendering_probe.rs` + `build_oq4_rendering_probe.sh` (new) | five rendering arms out of the pinned writer | `ct-writer`'s own `Cargo.lock` |
| `verification/lib_m25_trace.sh` (new, 160) | the arms, the artifact search, the transpiler reader | `lib_m24_ct_writer.sh` |
| four checks | 61 + 50 + 83 + 42 = **236** assertions | the above |
| `SOURCE-MAPPING.md` (new) | both verdicts, with evidence | — |
| `REUSE-INVENTORY.md` RI-72 | the closure, as a number | — |

### Measured, end to end, against a real Aztec contract

```
rung reached                     1
pcs driven / resolved            200 / 200
source paths interned            8
steps positioned / unpositioned  200 / 0
rung violations                  0
columns requested / dropped      true / false
ct-split-probe COLUMN_AWARE      true          (rung-3 control: false)
first step's position index      104,176       (rung-3 control: 706, which is the pc)
ct-print                         rc 0 on both
```

The rung declaration reads back out of the container as
`elkTraceLogEvent  metadata "ct.mapping-rung"  content "0x2f1a… rung=3 reason=no artifact was
supplied for this contract"`.

### A defect found in my own instrument, recorded because it is the campaign's own shape

The first draft of `_import_closure.py` used `[^;\n]*?` between `import` and `from`, which loses
every **multi-line** import clause — the shape prettier produces past 120 columns and the shape
upstream writes constantly. It returned **47 files / 8,083 lines** against the true **65 / 10,421**:
an 18-file, 2,338-line undercount, *in the direction that reads as good news*. Caught because two
independent walks disagreed. The class is `[^;]` now and the regression is recorded in RI-72.

### Module

`259,839 bytes`, sha256 `1f785f24…`, imports still **0**. Was 253,122 at the anchor move.
`TRACE-ABI.md` §7 re-derives both from the artefact, so this had to be updated in the same change.

## Step 7 — the M24 movements M25 causes, accounted for in both directions (in progress)

Two, and both are M25's OQ-4 change reaching a pin M24 deliberately made exact:

1. **`test_ct_container_roundtrip_ct_print`** pinned the five per-step variable names as a SET, by
   name, twice — `dv VARNAMES` and `sv VALUES0_NAMES`. `contractAddressLow` became
   `contractAddress`, so both went red. **That is the pin working.** A count of five would have
   passed on a renamed field, and M24's own comment beside it says so. Repointed, with the reason
   written into the check rather than into a commit message. **The assertion COUNT does not move**
   — 86 before and after.
2. **`verify_ct_writer_wasm_zero_imports`** re-derives `TRACE-ABI.md` §7's byte count and sha256
   prefix from the built module on every run, so the module growing 253,122 → 259,839 turned it red
   until §7 was updated in the same change. Also by design. **The count does not move** — the two
   assertions compare, they do not enumerate.

**And one consequence that is a real cost rather than a repoint: OQ-6 must be re-measured.**
`m24_require_oq6` stamps the module's CONTENT, so a changed module is a new measurement by
construction — that is exactly the property M24 built to stop an mtime-triggered re-measurement,
and it fires correctly here. §2's twelve-session table will be re-derived from the new `arms.tsv`
and `TRACE-ABI.md` updated to whatever it prints. §3's byte-identical-container claim is NOT
affected: the step record did not change, so the containers the two ABIs produce are still the same
bytes as each other.

## Step 8 — regression across M0, M1 and M24 (done, with one correction to my own procedure)

- **M0 = 156**, to the assertion (28 / 27 / 27 / 19 / 16 / 39). Unmoved.
- **M1 = 169**, to the assertion (19 / 58 / 10 / 21 / 33 / 28). Unmoved — RI-72 is a new entry and
  `verify_reuse_inventory_complete` is `assert_ge`-based, so it stays at 19, and no
  `PROVENANCE.md` row was added so `verify_provenance_complete` stays at 58.
- **M24**: the two repoints above, plus the OQ-6 re-measurement.

**AND I RAN THE FIRST REGRESSION IN THE WRONG SHELL, WHICH IS THE DEFECT M19's REVIEW ALREADY
NAMED.** I used `direnv exec <workspace-root>`; the checks and CI use `direnv exec
<aztec-avm-runtime>`, which is a *different* dev shell. Two things came out of it, and both are
exactly what that rule predicts:

1. `verify_ct_writer_wasm_zero_imports` read **57 with one failure**, `tsc is not on PATH`, against
   its reference 58. Not a regression — a shell.
2. **The OQ-6 benchmark ran on `node v25.9.0 / V8 14.1` — the SYSTEM node.** `TRACE-ABI.md` §2 says
   in as many words that the authoritative measurement is the one taken in the engine the checks
   run in, and `verify_trace_event_abi_batched_faster` asserts the file names its engine. So that
   `arms.tsv` was not merely stale, it was *not authoritative*, and rendering the document from it
   would have put a system-node measurement into a document that says it must not be one.

Deleted and re-run under `direnv exec /home/zahary/m/blocktracer/aztec-avm-runtime`, which reports
`node v24.19.0`. "A check that compiles must pin its PATH" generalises to "a measurement must pin
its engine, and so must the agent taking it".

**One real consequence of OQ-4 shows up here**: the container grew, because a 64-character hex
`String` per event is much larger than an `i64`. The `batched` arm's container went **4,440,064 →
4,694,016 bytes**. §3's byte-identical-container claim is unaffected — the two ABIs still produce
the same bytes as each other — but §2's container column and every figure derived from the timing
must follow the new measurement.

## Step 9 — OQ-6 re-measured on M25's module, and it is run 6 (done)

`m24_require_oq6` stamps the module's CONTENT, so M25's module is a new measurement by
construction. Twelve sessions × six ABBA blocks, 100,000 events, batch 4,096, on
**node v24.19.0 / V8 13.6.233.17-node.51** — this repository's dev shell, which is the second time
in this milestone that mattered.

| arm | median (µs) | min (µs) | crossings | container (B) |
|---|---|---|---|---|
| `batched` | 625,653 | 608,876 | 25 | 4,694,016 |
| `perEvent` | 631,290 | 619,473 | 100,000 | 4,694,016 |
| `control` | 621,202 | 609,074 | 25 | 4,694,016 |
| `nopBatched` | 4,758 | 4,507 | 25 | 159,744 |
| `nopPerEvent` | 5,070 | 4,520 | 100,000 | 159,744 |

`perEvent - batched` = **+0.98 %, [+0.29, +1.67] %** — inside the 3 % margin, so the verdict is
still `within-noise` and §4's stated secondary criterion still decides. `control - batched` =
−0.38 %, so the instrument is calibrated. `nopPerEvent - nopBatched` = +4.56 %, the smallest the
crossing-only pair has read in six runs and still positive.

**RUN 6 MOVED THE CONTAINER AND NOT THE VERDICT, AND THAT SEPARATION IS THE INTERESTING PART.**
OQ-4 put a 64-character hex `String` where M24 wrote an `i64`, so a 100,000-event container went
**4,440,064 → 4,694,016 bytes** and every arm got slower in absolute terms — the crossing's share
fell to 0.05 % and the writer-work-to-boundary-work ratio rose to ~2,005×, which is the expected
direction: OQ-4 made the denominator bigger and left the boundary alone. It is the stronger of the
two "different module" tests §2 now records, because unlike run 5 it also changed what an event
*costs*, and the difference still did not leave the noise band.

**THREE RUNS WERE TAKEN ON THIS MODULE AND THEY READ +1.29 %, −0.06 % AND +0.98 %** — same engine,
same binary, minutes apart, with the interval of the middle one straddling zero at [-2.44, +2.32] %
and the other two excluding it in the same direction. Only the last exists as an artefact, and only
the last is quoted; the first two were overwritten by the re-measurements the two procedure defects
below caused. The trio is worth recording anyway, because it is runs 2-versus-3 happening again on
M25's bytes, and it is exactly why §2 refuses to quote any single run's interval as a precision.

§2, §3, §4 and §8 are re-derived; §3's byte-identical-container figure moved 282,624 → **290,816**
for the same 2,000 events, and the two ABIs still produce the same bytes as each other.
`verify_trace_event_abi_batched_faster` went 15 failures → 1 → 0 across the render cycles, and the
one that survived the automated render was §8's retained-run row, which the renderer does not own.

### A procedure defect of mine, recorded because it cost forty minutes twice

I ran the OQ-6 benchmark **by hand** and deleted `arms.tsv.stamp` first. `m24_require_oq6` treats a
missing stamp as stale — correctly, because the stamp is the only evidence that the `arms.tsv`
present was measured against the module present — so the check then re-ran the whole twelve-session
benchmark over the file my hand run had just written, **overwriting it**. The mechanism is right
and my use of it was wrong: `just oq6-measure` and the hand invocation do not write the stamp, only
the check does, so a hand run followed by the check is always two runs. The way to re-measure is to
delete `arms.tsv` and let the CHECK do it, once.

### And a second procedure defect, from the same family, recorded for the same reason

I edited **one comment** in `ct-writer/src/lib.rs` after the module had been built and the
benchmark taken. The release module embeds panic `Location`s from that file — a property this
campaign already measured and wrote into `CAMPAIGN-BRIEF.md` (*"the fix is written in the SAME
NUMBER OF LINES and reproduces `5eef4b11…` exactly"*) — so a four-line comment becoming five lines
changed the module's bytes, its sha256, §7's two figures, and the OQ-6 content stamp, which forced
a third twelve-session benchmark.

**Freeze the source before you measure it.** Both of my procedure defects in this milestone are
the same shape one level up from the checks: an input I did not think of as an input.

## Step 10 — the mutation matrix (in flight; M1–M7 landed)

Twelve arms, each restored by a trap and the restore VERIFIED by rebuilding the module from the
restored source and re-running all four checks. What each arm expects is named in the script, and
what it *actually* reddened is read out of the run rather than assumed — M24 declared three hang
mutations and exactly one hung.

| # | mutation | check | result | which assertions |
|---|---|---|---|---|
| M1 | the address renders LITTLE-endian | `test_fr_rendering…` | 50 / **6** | the full-hex decode in every arm |
| M2 | M24's low-64 `contractAddressLow` is back | `test_fr_rendering…` | 50 / **9** | the name, the variant and the value |
| | | `test_trace_metadata…` | 83 / 0 | correctly unaffected — it does not assert the rendering |
| M3 | every supplied position is ignored | `test_trace_metadata…` | 83 / **15** | *"the rung1 arm produced a container — MISSING"*: the rung-1 arm now THROWS `MappingRungDegraded`, which is the enforcement doing its job |
| | | `verify_oq5…` | 61 / **3** | the resolved/positioned counts |
| M4 | declared, but no event written into the container | `test_trace_metadata…` | 83 / **7** | the `ct.mapping-rung` `TraceLogEvent`, both arms |
| M5 | a rung-1 violation is never counted | `test_trace_metadata…` | 83 / **8** | *"a rung-1 declaration with no positions THROWS at close — expected MappingRungDegraded, got MISSING"* |
| M6 | **two figures SWAPPED between rows, both still present in the file** | `verify_oq5…` | 61 / **2** | both row-anchored needles, naming the swapped pair |
| M7 | `rungFor` always answers rung 1 | `verify_oq5…` | **21** / 1 | the arms driver dies; the trap prints a summary and counts the abnormal exit |
| | | `test_trace_metadata…` | **0** / 1 | same, and this is the shape M22's trap exists for — a check that dies reports **0 assertions and 1 failure with a summary line**, not silence |

**M6 IS THE ONE THAT MATTERED MOST**, and it is M24's review's defect reproduced deliberately:
swapping §2.2's bytecode length with the pc-range maximum leaves *both numbers present in the file*
and would pass a `str_has_sub` over the whole document. Both needles are anchored to the row that
attributes the figure, and both go red naming the pair.

**M7 IS THE DIE-BEFORE-SUMMARY ARM AND THE TRAP HELD.** 61 → 21 and 83 → 0 are exactly the
"silent shrink" this campaign has been bitten by five times; the difference is that each printed a
summary line ending `1 failure(s)`, so the sweep reads a RED milestone rather than a smaller one.

M8 (hang), M9 (die: no artifact), M10 (the walker's own regex defect), M11 (`locationsOf` stops at
the innermost frame) and M12 (the column gate stops reading the rung) are still running; the
restore-verified re-run of all four checks is the last arm.

## Step 11 — WHERE THIS AGENT STOPPED, AND WHAT IS STILL RUNNING

**A DETACHED PIPELINE IS IN FLIGHT AND THE TREE IS NOT QUIESCENT UNTIL IT FINISHES.** Read this
before reading the working copy. Three `setsid`-detached jobs are chained; each waits for the one
before it:

| job | log | done when the log contains |
|---|---|---|
| the mutation matrix | `~/.cache/aztec-m25-mut.log` | `MUTCHAINDONE` |
| the M0–M25 sweep | `~/.cache/aztec-m25-sweep.log` | `SWEEPDONE` |

The mutation script (`scratchpad/campaign/m25-mutations.sh`) restores every file it touches from
`~/.cache/aztec-m25-mutbak` on EXIT, INT and TERM, and its last arm restores, **rebuilds the
module from the restored source** and re-runs all four M25 checks. Per-arm check output is under
`~/.cache/aztec-m25-mutout/`. Until `MUTCHAINDONE` appears, `ct-writer/src/lib.rs`,
`ct-host/src/{source_map,config}.ts`, `tools/run_trace_arms.mjs`,
`verification/{_import_closure.py,lib_m25_trace.sh}` and `SOURCE-MAPPING.md` may hold a mutation.

Summarise the sweep with `scratchpad/campaign/m25-sweep-sum.py ~/.cache/aztec-m25-sweep.log`. Its
reference table carries **M24 = 350**, which is the value before M25 touched it; see step 7 for the
two movements M25 causes and why neither changes an assertion count.

**The sweep had not completed when this agent stood down.** Every number in this log and in the
milestone section is measured; the campaign total is not, and is not claimed.

### The four M25 checks, measured, at the state the tree is in

```
verify_oq5_source_mapping_verdict_recorded     61
test_fr_rendering_matches_noir_tracer          50
test_trace_metadata_declares_mapping_rung      83
verify_transaction_builder_closure_measured    42
                                              ---
                                              236   0 failures
```

### Milestones re-run so far, against the reference

```
m0   156  =   m1   169  =   m24  (see step 7; verify_trace_event_abi_batched_faster re-measured)
```

### Outstanding for whoever picks this up

1. Read `MUTCHAINDONE` and `SWEEPDONE`, then `m25-sweep-sum.py`. Account for every unit **in both
   directions**; M9 has a recorded flake and is re-run alone rather than reported as a drop.
2. `verify_trace_event_abi_batched_faster` was at **91 / 0** after the third render cycle. If the
   sweep re-measures OQ-6 again, the module's bytes changed — check `sha256` against
   `TRACE-ABI.md` §7's `1e7e0e4f…` before believing anything else.
3. The four pending verification entries are all behind the 880-line vendoring RI-72 prices.

### M8 GENUINELY HANGS — verified while it was hanging, not after

The campaign's rule is that *a mutation which crashes has not exercised the assertion it was
written for*: M24 declared three hang mutations and exactly one hung, the other two dying in
seconds for unrelated reasons. So M8 was checked **live**, from `ps`, rather than inferred from
its eventual failure:

```
timeout --signal=TERM --kill-after=30 900 node … tools/run_trace_arms.mjs …
node … run_trace_arms.mjs      99.6 %CPU   4:25 CPU time   state Rl
```

A spinning process at ~100 % CPU under its bound, with the bound's wrapper alive above it. That is
the state a trap cannot reach — a process that never exits has no exit — so what ends it is
`m24_require_bounded_logged`'s `timeout`, and what the check prints is a `die` naming the command
and the bound rather than nothing at all.

## Step 12 — the mutation matrix, COMPLETE, and its restore arm found a defect in the harness

**All twelve arms reddened.** The five that landed after step 10:

| # | mutation | check | result | what reddened |
|---|---|---|---|---|
| M8 | **HANG** — the arms driver never exits | `test_trace_metadata…` | **0** / 1 | the 900 s bound fired; `m24_require_bounded_logged` `die`d naming the command and the bound, and the trap printed a summary |
| M9 | **DIE** — the artifact cannot be found | `test_trace_metadata…` | **0** / 1 | `m25_require_artifact` `die`d; summary line present |
| | | `verify_oq5…` | **21** / 1 | same, after its 21 transpiler assertions had already run |
| M10 | the walker loses multi-line imports | `verify_transaction_builder…` | 42 / **3** | 65 → 47 files and 10,421 → 8,083 lines, plus the RI-72 row |
| M11 | `locationsOf` stops at the innermost frame | `test_trace_metadata…` | 83 / **10** | the parent-chain unit assertions and the resolved positions |
| M12 | the column gate stops reading the rung | `test_trace_metadata…` | 83 / **20** | every refusal in the gate's five negative cases |

**M8 was verified hanging while it hung** — `ps` showed the node process at 99.6 % CPU with 4:25 of
CPU time under `timeout --signal=TERM --kill-after=30 900`. That matters because this campaign's
rule is that a mutation which *crashes* has not exercised what it was written for, and M24
declared three hang mutations of which only one hung.

### THE RESTORE ARM WENT RED, AND IT WAS RIGHT TO

```
=== RESTORE VERIFIED — the module is rebuilt from the restored source and all four re-run
verify_oq5_source_mapping_verdict_recorded     61 / 0
test_fr_rendering_matches_noir_tracer          50 / 0
test_trace_metadata_declares_mapping_rung      83 / 8      <-- RED
verify_transaction_builder_closure_measured    42 / 0
```

Diagnosed rather than re-run: the SOURCE was clean (`grep` for M5's mutation: 0 hits) and the
MODULE was not — **259,696 bytes, sha `53c40094…`**, against the declared 259,839 / `1e7e0e4f…`.

**The cause is `cp -p`, and it is this campaign's own catalogued defect: "a mutated ARTEFACT
outlived its restored source".** `cp -p` restores the *backup's* mtime, which is older than the
module built by the last rebuilding arm (M5). cargo fingerprints on mtime, so `rebuild_module`
decided the artefact was current and rebuilt nothing — leaving M5's disabled violation counter in
the module beside a clean `lib.rs`. The failure signature is M5's exactly: 83 / **8**. The three
checks that do not read that behaviour passed, which is why it could not have been caught by
"the milestone is green".

**The harness shipped with the defect its own header claims to defeat**, and only the
restore-verification arm stood between that and a corrupt handover. Two fixes:

1. `restore()` now `touch`es `ct-writer/src/lib.rs` and `Cargo.toml` after copying, so cargo
   cannot skip the rebuild.
2. The tree was repaired the same way and re-measured: **259,839 bytes, sha256 `1e7e0e4f…`**,
   byte-identical to what `TRACE-ABI.md` §7 declares, so the build is deterministic in both
   directions.

**The sweep was killed 3 markers in**, because `MUTCHAINDONE` had released it over the mutated
module. It is restarted after the four checks confirm green.
