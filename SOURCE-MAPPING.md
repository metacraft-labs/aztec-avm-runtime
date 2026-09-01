<!-- The M25 verdicts. `verify_oq5_source_mapping_verdict_recorded` re-derives every figure in §2
     and §4 from the transpiler's own source at `pins.json`'s `cpp` anchor and from
     `~/.cache/aztec-m25-trace/trace.json` on every run, and fails if this file and the
     measurement disagree. Do not edit the numbers by hand; re-run and copy what it prints. -->

# Source mapping and field rendering — OQ-5 and OQ-4, settled

This file is to M25 what `TRACE-ABI.md` is to M24 and `BOUNDARY-SHAPE.md` is to M15: the verdicts,
the evidence each rests on, the rejected options' measurements retained so a decision can be
revisited without redoing the work, and the consequences for the milestones that depend on them.

---

## 1. The two questions

**OQ-5.** Does `avm-transpiler` preserve enough debug info to map an AVM program counter back to
Aztec.nr source? The fallback ladder, §9.2's, in order:

| rung | what it is |
|---|---|
| 1 | full source-level stepping — a path, a line and a column per instruction |
| 2 | function-level attribution — a position per frame, not per instruction |
| 3 | bytecode-level stepping — `Line(pc)`, with debug-function-name labels |

**The runtime states which rung it is on, per contract, in the trace metadata, and never silently
degrades.** M24 shipped on rung 3 and said so in `emit()`.

**OQ-4.** How does a 254-bit field element render, such that the public half and the private half
of a Form B recording agree?

---

## 2. OQ-5's verdict: **rung 1, with no upstream change**

**The transpiler preserves the mapping, and the path everybody expects is not the path.** It is
*not* `pc → Brillig index → ACIR debug info → source`. `avm-transpiler` **rewrites the debug info
in place**, so a shipped artifact carries a map that is **already keyed by AVM program counter**.
There is no first arrow to reconstruct.

### 2.1 The evidence in the source, at the `cpp` anchor `233d8e0993`

Every line is read out of the fork's object store, never out of a worktree.

| what | where |
|---|---|
| the pc map is built and **returned** | `avm-transpiler/src/transpile.rs:53` — `pub fn brillig_to_avm(...) -> (Vec<u8>, Vec<usize>)`, doc'd *"Returns the bytecode and a mapping from Brillig program counter to AVM program counter"* |
| an AVM pc is a **byte offset** | `transpile.rs:475` — `current_avm_pc += avm_instrs.iter().skip(…).map(\|i\| i.size()).sum()`, and `instructions.rs:83` — `pub fn size(&self) -> usize { self.to_bytes().len() }` |
| the debug info is **re-keyed** | `transpile.rs:1803` — `patch_debug_info_pcs`, whose body is `BrilligOpcodeLocation::new(brillig_pcs_to_avm_pcs[original_opcode_location.index()])` |
| …and the re-keyed map is what is **stored** | `transpile_contract.rs:116` then `:129` — `debug_symbols: ProgramDebugInfo { debug_infos }` on the emitted `AvmContractFunctionArtifact` |
| the C++ AVM's pc is the **same** byte offset | `barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/execution.cpp:1765` — `context.set_next_pc(pc + instruction.size_in_bytes())` |
| the anchor and the fork tip **agree** | `git diff 233d8e0993 HEAD -- avm-transpiler/` is empty |

### 2.2 The evidence on an artefact, which is the half that matters

A source reading establishes what the transpiler *does*. The verdict is about what a *shipped
artifact contains*, so it is measured on one: `@aztec/noir-test-contracts.js`'s `AvmTest`, at the
`deletion_era` pin, as installed.

```
public_dispatch        bytecode 50,939 bytes
debug_symbols          raw-DEFLATE + base64 + JSON
brillig_locations["0"] 9,021 entries, keys in [706, 50,526]
first keys             706, 715, 720, 725, 730, 735, 739, 744, 749, 754, 758, 763, 767, 772, 790
strides                9,020 gaps, min 4, max 410, of which 8,580 are in 4–9
file_map               86 files, each with a `path` and its `source`
```

The keys are **sparse, strictly increasing, and bounded above by the bytecode length**. That is
what AVM byte offsets look like. It is *not* what a dense `0..N` Brillig opcode index looks like,
and a map keyed past the end of the bytecode could not be byte offsets at all — `rungFor` refuses
that case by name, and the arms run exercises it.

*This line said "in strides of 4–9" until M25's review re-derived it, and it was wrong: the
**fifteen keys printed two lines above it** contain a stride of 18 (772 → 790), and across the
whole map the strides run to 410. The other five figures in this block were each re-derived by
`verify_oq5_source_mapping_verdict_recorded` and each correct; the stride range was the one figure
here that nothing re-derived, which is this campaign's "a figure nobody re-derives rots" in the
document whose header claims every figure in §2 is re-derived. The census above is now derived by
the arms run and asserted, and what the verdict actually rests on — sparse, strictly increasing,
inside the bytecode — is asserted separately, because a stride distribution is decoration and those
three are the argument.*

### 2.3 What was actually built on top of it

`ct-host/src/source_map.ts` resolves `pc → (path, line, column)` and classifies the rung. Driven
over the **artifact's own first 200 mapped pcs**:

| measurement | value |
|---|---|
| rung reached | **1** |
| pcs driven | 200 |
| resolved to a `(path, line, column)` | **200** |
| unresolved | 0 |
| source paths interned | 8 |
| steps positioned / unpositioned | 200 / 0 |
| rung violations | 0 |
| columns requested / dropped | true / **false** |

Read back through `ct-split-probe` — the v4 split-stream reader, not `ct-print`'s legacy path —
the container reports `COLUMN_AWARE true`, nine paths and 200 steps, and its first step's
`global_position_index` is **104,176** rather than a program counter. The rung-3 control over the
same events reports `COLUMN_AWARE false`, one path, and a first step of **706** — which is the pc.

**Nine and not eight, and the difference is not a discrepancy**: the table above counts the *source*
paths the recording interned (8), while `PATH_COUNT` counts every path in the container, which
includes the session's own program path. The rung-3 control has exactly that one and no source
paths, which is why it reads 1. Stated because the two numbers sit four lines apart and the
difference was not previously written down.

### 2.4 No sixth upstream contribution is warranted for the question as asked

The question was whether the transpiler preserves *enough*. It does. A contribution prepared on the
premise that it does not would be argued from a false statement, which is not how the five in
`codetracer-specs/upstream-bugs/` were argued.

**Three residual holes exist, all measured, none of which blocks rung 1.** They are recorded as a
*candidate* sixth contribution rather than prepared, because bundling them into an answer to a
question they are not the answer to is how a contribution gets declined.

1. **`brillig_procedure_locs` is not re-keyed.** `grep -rn brillig_procedure_locs
   avm-transpiler/src/` finds nothing, and the measurement shows it: in `AvmTest` its values top
   out at **9,589** while the sibling `brillig_locations` reaches **50,526**. One `DebugInfo`
   carries two key spaces at once, and mixing them is a silent wrong answer.
2. **Procedure-region pcs have no entry at all.** Compiled procedures are appended after the main
   body (`transpile.rs:489`, `:505`), past the end of `brillig_pcs_to_avm_pcs`.
   `ContractSourceMap.positionFor` answers `null` for them and **does not round to the nearest
   lower line**, because that would put a step in a function it is not in.
3. **`assert_messages` is dropped.** Neither artifact struct at `transpile_contract.rs:44-76`
   declares the field and there is no `#[serde(flatten)]`.

Estimated size if prepared: ~35 lines across `transpile.rs` and `transpile_contract.rs`.

### 2.5 The trap, recorded because it is the reason this was open for so long

**The type is still called `BrilligOpcodeLocation` after the rewrite.** Anyone who greps the type
name concludes the mapping was never re-keyed. It was. `brillig_pcs_to_avm_pcs` is likewise not
serialised anywhere — searching an artifact for it finds nothing and suggests a gap — because it is
*consumed* before being dropped.

---

## 3. The default rung, and how it is stated

**The runtime's default is the rung the contract's artifact supports, measured per contract, and it
is never rounded up.** `rungFor(debugInfo, bytecodeLength, files)` returns a rung *and its reason*,
and there are five outcomes, four of which are degradations with distinct causes:

| artifact shape | rung | why |
|---|---|---|
| debug symbols, byte-offset keys, source text | **1** | everything a `(path, line, column)` needs |
| debug symbols, byte-offset keys, **no source text** | **2** | a span cannot become a line without the file |
| debug symbols present, `brillig_locations` **empty** | 3 | present is not the same as mapping anything |
| highest key **≥ bytecode length** | 3 | cannot be byte offsets; named, not guessed |
| **no `debug_symbols`** | 3 | nothing to resolve from |

Each declaration is written **into the container**, as a `TraceLogEvent` with metadata
`ct.mapping-rung` and content `<address> rung=<n> reason=<…>`. A rung that lived only in a host
variable would be a claim *about* a recording rather than a property *of* one.

**"Never silently degrades" is enforced in two places on different evidence, and neither can stand
in for the other.**

- The **module** counts. A contract declared at rung 1 whose steps arrive with no position is a
  violation; `ct_rung_violations()` and `ct_rung_violation_pc()` survive close.
- The **host** refuses. `CtWriter.close()` throws `MappingRungDegraded`, naming the count, the
  first offending pc and the positioned/unpositioned split.

Measured: a rung-1 declaration with three unpositioned steps throws, naming pc **706**, `0`
positioned and `3` unpositioned. The control — the **same three steps** declared at rung 3 — closes
cleanly with `rungViolations: 0`. Without that control the throw could be caused by anything about
an unpositioned step rather than by the declaration it contradicts.

### 3.1 What this moves for DD-7

`CARRIES_COLUMNS[path-a]` is still `false`, and the gate is no longer that table alone. Columns are
recordable when **the writer can carry them OR the recording resolves to rung 1**, because at rung 1
there is a real source column to put in them. `TRACE-ABI.md` §5 records that DD-7's refusal had
stopped being about the writer and had become about this runtime having no column to record; that is
the half M25 closes. Measured: `columns: true` at rung 1 resolves; at rung 2 and at rung 3 it throws
`ColumnAwarenessUnavailable` naming the rung; and a rung smuggled in as the string `"1"` or as `4`
falls to rung 3 rather than being believed, because the resolution is a value comparison and types
are erased.

---

## 4. OQ-4's verdict: **`0x` + 64 lowercase big-endian hex, in `ValueRecord::String`**

### 4.1 What the Noir tracer did, why "match it exactly" was not available, and what M26 changed

**M26 APPLIED THE CHANGE §4.4 ASKS FOR, so this section is now a record of what was there rather
than of what is.** The table below is the state M25 measured; the paragraph after it is the state
M26 left. `test_fr_rendering_matches_noir_tracer` asserts the NEW rendering and asserts the old one
is GONE, in both Noir checkouts, so neither this section nor that check can go stale quietly.

**THE TABLE NAMES ITS REVISION NOW, AND ONE OF ITS FOUR ROWS WAS WRONG IN EVERY ERA.** A line
citation with no revision beside it is not re-derivable by anybody, which is how the first row
survived: it said `tracer_glue.rs:160-189`, and the `Field` arm is **148-161** at the revision this
table measures, **160-197** at the one immediately after it, and **162-211** today — so `160-189`
was M26's start with an end that matches nothing, in a table about the state before M26. The other
three rows are correct at the revision now named. Measured on 2026-08-31 against the `noir`
checkout; `test_fr_rendering_matches_noir_tracer` §1 re-derives every figure in this table and in
§4.3 on every run, reading the revision out of this document rather than out of the check.

| what | where, at M25 (`noir` `eb8b28c27^`, 1.0.0-beta.18) |
|---|---|
| `Field` became an `Int` | `noir/tooling/tracer/src/tracer_glue.rs:148-161` — `ValueRecord::Int { i: field_value.to_i128() as i64, type_id }` |
| under `(TypeKind::Int, "Field")` | `tracer_glue.rs:371` |
| and `to_i128` **panics** above 127 bits | `noir/acvm-repo/acir_field/src/field_element.rs:253-256`, gated on `fits_in_i128()` = `num_bits <= 127` |
| then `as i64` truncates | `tracer_glue.rs:152` |

**So the Noir half could not render a full-width 254-bit field at all**: it aborted the recorder, or
kept the low 64 bits with a sign fold. A 32-byte Aztec contract address is full-width.
"Cross-check against what the Noir tracer does" therefore could not mean "do the same thing", and
saying so was the finding rather than a caveat on it.

**What M26 changed.** The `Field` arm now renders `ValueRecord::String { text: field_to_hex(...) }`
under the same `(TypeKind::Int, "Field")`, where `field_to_hex` is `format!("0x{}", to_hex())` — the
verdict of §4.3, applied to the other half. Measured on the joined container M26 produces: the Noir
half's `x = 4` and `y = 5` read back as
`0x0000000000000000000000000000000000000000000000000000000000000004` and `…05`, 66 characters each,
`ValueRecord::String`, beside the public half's contract address
`0x3051e7a94116d0ade3f33411a29365e1f0bd72d615eb9ca89705dc6d6da9076d` in the same variant. **One
field element, one spelling, across the join.** `JOIN-SHAPE.md` §5 records it with the container
it was read out of.

### 4.2 The measurement that decided it

Five containers, written by the pinned Path A writer (`trace_format` `592fa42cbf`) natively, each
carrying the **same control** (`control` = `Int 42`) plus one `subject` rendered a different way,
then read by **both** pinned readers.

| arm | subject | `ct-print --full` | `ct-split-probe` |
|---|---|---|---|
| `int` | control only | rc 0 | ok |
| `low64` | `Int { i: <low 8 BE bytes> }` | rc 0 — `361984551142689548` | ok |
| `bigint` | `BigInt { b: <32 BE bytes>, negative: false }` | **rc 1** | ok |
| `string` | `String { text: "0x" + 64 hex }` | rc 0 — all 64 characters | ok |
| `raw` | `Raw { r: "0x" + 64 hex }` | rc 0 — all 64 characters | ok |

The `bigint` arm's message is exact and names its own cause:

```
Error reading events: failed to decode events: cbor: expected byte string (major 2), got major 3
```

`codetracer_trace_types/src/base64.rs` at `592fa42cbf` serialises `BigInt.b` through
`String::serialize(&base64, s)` — a CBOR **text** string, major 3 — while the reference Nim reader
reads a **byte** string, major 2. **The only full-precision variant in the shared `ValueRecord`
cannot be read by the reader this campaign pins.**

**AND THE SPLIT PROBE READ THE BROKEN ONE GREEN.** `ct-split-probe` reports `DONE ok` and lists
`control,subject` for the `bigint` arm, because it counts and names value records without decoding
their contents. That is this campaign's recurring shape — *a check that never exercises the thing it
is named for* — this time in an instrument M24's review added. Both readers are run.

### 4.3 The rendering, and what it costs

```rust
ValueRecord::String { text: "0x" + 64 lowercase big-endian hex, type_id }
//                 with type_id = ensure_type_id(TypeKind::Int, "Field")
```

- **Full precision.** No truncation, no leading-zero stripping, fixed 66 characters.
- **Readable by both pinned readers**, verified over a container the arms run produces, not
  reasoned about.
- **`String` and not `Raw`**, because `Raw` is Noir's escape hatch for values it *cannot* represent
  (`"()"` at `tracer_glue.rs:302`, `"fn"` at `:335`, at the `noir` checkout's current tip), and an
  address is not one of those. (These read 252 and 285 until 2026-08-31 — the `eb8b28c27^` numbers,
  in a present-tense sentence, fifty lines out of date. Both are re-derived by
  `test_fr_rendering_matches_noir_tracer` §1 now.)
- **The same type record as the Noir half** — `(TypeKind::Int, "Field")`, reused rather than a
  second type, because the cross-half requirement is about the type table as much as the value.

What M24 recorded for the same address, kept so this is a delta rather than a claim:
`contractAddressLow = 361984551142689548`. The variable is now `contractAddress`.

### 4.4 The cross-half work this leaves, named rather than implied

**The Noir half must change to match**, at `noir/tooling/tracer/src/tracer_glue.rs:148-161` — the
arm as it stood at `eb8b28c27^`, which is where this instruction was written; it is at **162-211**
today, and both figures are re-derived by `test_fr_rendering_matches_noir_tracer` §1. That is
a Metacraft repository and not Aztec, so it is **not** the sixth upstream contribution, and it is
M26's to land — M26 is where the two halves become one container and where a disagreement between
them is a defect rather than a divergence.

***M26 LANDED OPTION 1***, in both Noir checkouts (`noir` on `blocktracer`, and the
`noir-wt4-webpage` worktree the OQ-7 probe builds from), with the two rendering lines asserted
byte-identical between them so the demonstration and the shipped fix cannot drift. The cost is
recorded rather than glossed: **a small field now reads as `0x…04` instead of `4`**, which is worse
for an ordinary Noir program and is the price of one spelling across the join. Option 2 —
fixing `BigInt`'s CBOR encoding in the shared crate — remains the better long-run answer and
remains a decision above this milestone.

**AND THERE IS A SECOND COST, WHICH M26 DID NOT DECLARE AND M26'S REVIEW MEASURED.** The change is
neutral in the TYPE RECORD and not in the TYPE TABLE. The writer registers a nameless companion
type for a `TypeKind::Int` type the first time that type carries an `Int` VALUE; a `Field` no
longer carries one, so the companion is never created and every trace containing a `Field` has one
fewer type-table entry. Measured with a baseline `nargo` built in a separate worktree, across three
Noir fixtures: `assert` goes `[None, Field, type_1]` -> `[None, Field]`, `a_2_function_calls` goes
`[None, Field, type_1, ()]` -> `[None, Field, ()]`, and `types_test` loses the entry after `Field`
while the companions after `u32` and `i8` survive and renumber (`type_3` -> `type_2`,
`type_6` -> `type_5`). `a_1_mul`, whose only companion follows `u32`, is unchanged. It is recorded
in `tracer_glue.rs` beside the rendering and in `tests/test_tracer.rs`' header, because it is the
half of this change that a reader of the diff cannot see.

Two options exist and the reason for preferring the first is recorded:

1. **Render `Field` as this same `String`.** No wire risk, readable today, and it makes the panic at
   `field_element.rs:253` unreachable from the tracer — which is a bug fix, not a rendering change.
2. **Fix `BigInt`'s encoding** in `codetracer_trace_types::base64` so `b` is a CBOR byte string, and
   use `BigInt` on both sides. Better in the long run, and it is a *wire-format* change to a shared
   crate with other consumers, which is a decision above M25.

---

## 5. The side channel, and why the step record did not grow

`TRACE-ABI.md` §7 offered the step record's reserved bytes as the wire-format extension point and
said there were eight of them at offset 12. **There are four.** The offsets are
`0,4,8,12,16,24,32+32`: sixty bytes used, four reserved, sixty-four total, and
`const _: () = assert!(OFF_ADDRESS + ADDRESS_LEN == CT_RECORD_SIZE)` has been pinning the total the
whole time while nothing compared the other two figures to the layout. Both are corrected in
`ct-writer/src/lib.rs`, in `ct-host/src/abi.ts` and in §7, and they are asserted against the offsets
now rather than typed beside them.

A `(path_id, line, column)` triple is twelve bytes, so it would not have fitted regardless. M25
therefore adds **`ct_positions(ptr, len)`** — a separate 16-byte-record channel handed over
immediately before the step batch it belongs to, paired **by order**.

The consequence is the point: **with no positions supplied, every byte this module writes is what
M24 measured.** `ct_record_size()` is still 64, `CT_ERR_RESERVED_NOT_ZERO` is still reachable, §3's
byte-identical-container claim still holds, and OQ-6's twelve-session benchmark is still a
measurement of the artefact it was taken on.

**Pairing by order rather than by `(contract, pc)` is deliberate**, and its failure mode is what
makes it the right choice: a map would silently mis-attribute a pc that repeats across contracts,
while an order mismatch is countable. `ct_steps_positioned()` and `ct_steps_unpositioned()` sum to
the event count; `ct_positions_pending()` must be zero at close and the host refuses if it is not; a
step for which the host has no position stages a `line: 0` record rather than skipping the slot,
because skipping one would shift every later step in the batch onto a real-looking wrong line.

---

## 6. Consequences for the milestones that depend on this

### M26 — joining private and public traces

- The two halves' `Field` renderings **do not agree yet**, and §4.4 says exactly what has to change
  and where. This is now a known, located, one-file divergence rather than an open question.
- The rung is in the container, so a joined recording can say that its public frames are rung 1 and
  its private frames are whatever the Noir tracer achieves, per contract, without inference.

### M27 / M28 — browser packaging and the no-Node gate

- `ct-host` still has **no npm dependencies and imports no Node module in its trace path**.
  `source_map.ts` takes a decoded `DebugInfo` and a file map as plain data; the deflate/base64/JSON
  decode is in `tools/run_trace_arms.mjs`, which is a tool.
- The module still has **zero wasm imports**.

### M29 — executed steps, and the first time "never rounded up" had to bite

**§3's ladder was written against a stream that could not degrade, and M29 gave it one that can.**
Until M29 every step this repository recorded was one of the artifact's own MAPPED program counters
— M25's arms drove "the artifact's first 200 mapped pcs", M26's join driver did the same, and M27's
browser container did the same for 64 — so "the contract is rung 1 and 200 of 200 steps are
positioned" was true *by construction*. A declaration that cannot be contradicted is not a
declaration, and the whole `ct_rung_violations()` / `MappingRungDegraded` apparatus had never been
exercised by anything but its own deliberate control.

M29 records what the AVM executed. Measured on the browser demo's token transfer — and **every cell
of this table is re-derived from the arm report by `test_browser_steps_are_executed_not_mapped` on
every run**, one row at a time, anchored to the row that names its subject. It was not, until M29's
review: three figures stated here and nowhere re-measured, in a document whose subject is a hole
that will close the day upstream re-keys `brillig_procedure_locs`, which is the shape this campaign
calls "a figure nobody re-derives rots even when the milestone knows it is wrong".

| what | measured |
|---|---|
| executed instructions | **516** |
| …resolving to a `(path, line, column)` | **389** |
| …with no `brillig_locations` entry at all | **127** |
| hole 2's share of one ordinary public transaction | **24.6%** |

The 127 are §2.4's residual hole 2 — compiled procedures are appended after the main body
(`transpile.rs:489`, `:505`), past the end of `brillig_pcs_to_avm_pcs`, and
`ContractSourceMap.positionFor` answers `null` for them rather than rounding to the nearest lower
line.

So a rung-1 declaration for that contract would now be false, the module would count 127 violations,
and `CtWriter.close()` would refuse the container. **The rung is therefore declared from the
EXECUTION rather than from the artifact**: rung 1 when every executed step of that contract
resolved, rung 2 otherwise, with the reason carrying the split, the first unmapped pc, and the
artifact's own verdict. `browser/src/ct_download.ts` does that in a pass of its own before the first
step is ingested, because the declaration has to be on the module's list before the records it is
judged against arrive.

**Two rungs, two questions, and they are not the same question.** The SESSION's rung stays
`RUNG_SOURCE` and columns stay on: §3.1's rule is that columns are recordable when the recording
resolves to rung 1, and this recording really does resolve a real `(path, line, column)` — with a
real column — for every step it positions. The CONTRACT's declaration is the coverage claim, and it
is the one that is now measured. `e2e_browser_downloads_ct_container_and_ct_print_parses` asserts
the implication in the direction that can fail: the declared rung is 1 exactly when the unpositioned
count is 0.

**And hole 2 has a number now.** §2.4 recorded it as a measured gap with no consequence attached;
its consequence is the table above. That is the figure a sixth upstream contribution would be
worth, if one is ever prepared.

---

## 7. L5 — where the artifact comes from for a CHAIN-FETCHED contract, and what proves it

§2 established that a shipped artifact carries a map already keyed by AVM program counter. §3
established that the rung is measured per contract and never rounded up. **Neither said where the
artifact comes from when the contract was not compiled here**, and for the live-chain replay
campaign that was the whole gap: an Aztec node serves
`{ id, privateFunctionsRoot, version, artifactHash, packedBytecode }` and no debug symbols, no file
map and no source text.

**The chain holds a COMMITMENT to the artifact and not the artifact, and upstream says so in the
field's own doc comment**: `artifactHash` is *"intended to be used by clients to verify that an
OFFCHAIN FETCHED ARTIFACT matches a registered class"*. `replay/src/artifact_resolution.ts` performs
that fetch and that verification.

### 7.1 Three checks, and check 2 alone is what a block explorer does

| # | check | what it proves |
|---|---|---|
| 1 | `computeArtifactHash(candidate)` equals the class's `artifactHash` | this is the registered artifact |
| 2 | the candidate's `public_dispatch` bytes equal the class's `packedBytecode` | this is the deployed code |
| 3 | `computeContractClassId({artifactHash, privateFunctionsRoot, publicBytecodeCommitment})` equals the class's `id` | the two are bound to the identity the instance names |

**Measured on a real published release, 2026-09-01:** `@aztec/protocol-contracts@5.0.0-rc.2`'s
`FeeJuice` has bytecode *byte-identical* to the class deployed at `0x…03`, under artifact hash
`0x1df228ba…` against the deployed `0x1a57ff2a…`, with `debug_symbols` of 2,968 base64 characters
against 2,964. A bytecode-only check — which is Aztecscan's own — accepts it and produces
real-looking line numbers out of a different compilation. `5.2.0` and `5.3.0-nightly.20260819`
reproduce both hashes exactly.

### 7.2 What `artifactHash` does NOT commit to, and it is exactly §2's two inputs

`computeArtifactHash`'s preimage is the private-function tree root, the utility-function tree root
and `computeArtifactMetadataHash`. **`debug_symbols` and `file_map` are in none of them.**

`test_offchain_artifact_resolution_verified` §5 demonstrates this rather than arguing it: the
installed FeeJuice with every `brillig_locations` entry rewritten to call-stack id 0 **passes all
three checks**, with the same artifact hash and the same class id, differing only in a digest taken
over the two uncommitted fields.

The exposure is bounded by §2's own property and the bound is worth stating: a map is keyed by AVM
byte offset into bytecode check 2 has just proved byte-equal to the chain's, so `rungFor` refuses a
map whose highest key reaches past the bytecode and `ContractSourceMap.positionFor` answers `null`
rather than rounding. What is undetectable is wrong *text* behind an in-range map — so the container
states which distributor attested it, in `ct.source-provenance`, and whether a second one agreed.

### 7.3 The measurement, on the artifact that resolves

| what | measured |
|---|---|
| class deployed at `0x…03`, both chains | `0x1f85d8b901a87b3f…`, never updated |
| resolved by | `npm:@aztec/protocol-contracts@5.3.0-nightly.20260819 FeeJuice` |
| `public_dispatch` | **1,947 bytes**, byte-equal to `packedBytecode` |
| `rungFor` verdict | **rung 1** |
| mapped pcs | **314**, in **[130, 1785]** — inside the bytecode, which is what makes them byte offsets |
| …resolving to a `(path, line, column)` | **314** |
| `file_map` | **32** files, of which the mapping reaches **12** ids over **12** paths |
| pc 130 | `fee_juice_contract/src/main.nr` **203:12** |
| corroboration | **single-distributor** — Aztecscan's `/l2/artifacts/0x1a57ff2a…` is 404 on both deployments |

### 7.4 The durability risk, recorded because the capability depends on it

`@aztec/protocol-contracts/src/scripts/cleanup_artifacts.ts` sets `fileData.file_map = {}` on every
shipped artifact. It runs from `yarn build` (`generate:cleanup-artifacts`) and **not** from
`yarn generate` — and `yarn-project/bootstrap.sh:132` runs `… 'cd {} && yarn generate'`, so it never
executes and the published artifacts keep their source.

**If upstream changes that line to `yarn build`, every future protocol-contracts release loses its
`file_map` and every protocol contract drops from rung 1 to rung 2.** §3's ladder would say so by
name — *"no file_map source text was supplied, so a span cannot become a line and a column"* — which
is the honest failure, and the capability would be gone. `build:keep-debug-symbols` exists in the
same `package.json` and omits the cleanup; it is what a consumer would have to ask upstream to
publish from.
