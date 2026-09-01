<!-- The M24 verdict. `verify_trace_event_abi_batched_faster` re-derives every number in §2 from
     `~/.cache/aztec-m24-oq6/arms.tsv` on every run and fails if this file and the measurement
     disagree. Do not edit the numbers by hand; re-run the benchmark and copy what it prints. -->

# The trace event ABI — OQ-6, settled

**THE MEASUREMENT DOES NOT HAVE A STABLE SIGN, AND THAT IS THE RESULT.** Run eleven times — once in
the system engine and ten times in this repository's dev shell — `perEvent - batched` came out
**+0.20 %**, **+1.09 %**, **-0.58 %**, **-0.09 %**, **+0.96 %**, **+0.98 %**, **+0.85 %**,
**+0.74 %**, **+1.34 %**, **+1.21 %** and **+1.07 %**. Every one is inside the declared **margin of 3 %**; runs 2, 3 and 4 were taken on the *same engine, the
same module and the same binary*, and two of those have 95 % intervals that do not overlap and
point opposite ways. So the honest statement is not "the batched ABI is about one per cent faster"
— it is that **the difference is smaller than the run-to-run variation of the instrument that
measures it**, and speed cannot choose the ABI.

**Runs 5 to 8 are DIFFERENT MODULES, and that is why they exist.** `m24_require_oq6` stamps the
module's content rather than its mtime, so a changed module is a new measurement by construction —
the `trace_format` anchor moved for run 5 (§5, §7), M25 added the source-mapping surface for run 6,
and M26 added the join surface in two steps for runs 7 and 8. They landed at **+0.96 %**,
**+0.98 %**, **+0.85 %** and **+0.74 %** — the same sign, the same size, on four different modules,
all inside the margin. **The instability is a property of the instrument and not of the module**,
which is the one thing four runs on new bytes could have refuted and did not.

**AND RUN 9 IS THE REPLICATE THE OTHER EIGHT NEVER HAD.** Runs 8 and 9 are the SAME engine, the
SAME module and the SAME binary — run 8 was taken by hand and run 9 by `m24_require_oq6` itself,
which re-measured because a hand run writes `arms.tsv` and not the content stamp beside it. They
read **+0.74 %** and **+1.34 %**, and their 95 % intervals are `[+0.11, +1.36]` and
`[+0.67, +2.00]`: overlapping, same sign, and nearly a factor of two apart in the point estimate.
That is the between-run nuisance measured directly on one module, and it is the strongest single
piece of evidence in this file for the sentence at the top.

**RUN 6 MOVED THE CONTAINER AND NOT THE VERDICT, AND THE TWO ARE WORTH SEPARATING.** M25 settled
OQ-4 on a 64-character hex `String` per event where M24 wrote an `i64`, so a 100,000-event
container went **4,440,064 → 4,694,016 bytes** and every arm got slower in absolute terms. The
`perEvent - batched` difference did not leave the noise band, and the crossing-only pair
(`+9.04 %`) was the same size it had been in the first six runs. That is the expected shape: OQ-4
changed the writer work per event, which is the denominator, and left the boundary alone.

**RUNS 7, 8 AND 9 MOVED NEITHER, AND THEY ARE THE STRONGER TEST FOR IT.** M26 added the join surface
in two steps — `ct_log_event` / `ct_log_event_count` for the record that makes two containers one
recording, then `ct_call` / `ct_return` / `ct_call_depth` / `ct_calls_opened` for the FRAMES that
make its two halves distinguishable — and `m24_require_oq6` stamps the module's content, so each
step forced its own measurement. The container is **4,694,016 bytes, unchanged to the byte**, in
both, because the exports add a capability an event stream does not use, and `perEvent - batched`
came back at **+0.85 %**, **+0.74 %** and **+1.34 %**, inside the band and with run 2's sign. What
DID move is the crossing-only pair, to **+15.65 %**, **+18.40 %** and **+17.24 %** against run 6's
+4.56 % on the same engine. That is a fact about the instrument and is recorded in §2 rather than smoothed over: the
crossing costs a fraction of a per cent of a recording at either end.

The ABI is therefore chosen on a stated secondary criterion, recorded in §4, and both ABIs remain
exported.

This file is to M24 what `BOUNDARY-SHAPE.md` is to M15: the verdict, both arms' numbers, the
rejected arm's measurements retained so the decision can be revisited without redoing the work,
and the consequences for the milestones that depend on it.

---

## 1. The question

§9.3 of `Aztec-AVM-Runtime.md` names the trap and does not settle it:

> Batching thousands of events per transaction across the boundary one call at a time is the
> obvious performance trap (the WASM-Instrumentation-Layer spec measured ~33 ns per boundary
> crossing in V8, which is the boundary itself, not the hook body). The likely shape is:
> TypeScript writes a compact binary event buffer into wasm linear memory and calls a single
> `ct_ingest(ptr, len)` per batch. Settling this is **open question OQ-6**.

Both shapes are built, from one module, and **both funnel into one `emit()`** — so what is
compared is the crossing and the decode, not two different amounts of writer work.

| arm | export | crossings for 100,000 events |
|---|---|---|
| `batched` | `ct_ingest(ptr, len)` | 25 (`ceil(100000 / 4096)`) |
| `perEvent` | `ct_step(contextId, pc, opcode, l2Gas, daGas, addressPtr)` | 100,000 |
| `control` | `ct_ingest_control` — a byte-for-byte duplicate of `ct_ingest` | 25 |
| `nopBatched` | `ct_nop_ingest` — the batched crossing with the writer work removed | 25 |
| `nopPerEvent` | `ct_nop_step` — the per-event crossing with the writer work removed | 100,000 |

## 2. The measurement

**12 sessions × 6 ABBA blocks, 100,000 events, batch 4,096, node v24.19.0 / V8 13.6.233.17-node.51.**
A session is a separate **process** and is the unit of replication. Run `setsid`-detached on an
idle box, **inside this repository's own dev shell**: AMD Ryzen 9 5950X (32 threads), 62 GiB RAM,
every artefact under `~/.cache` and nothing written to the 32 GiB `/tmp` tmpfs. **The load average
was not sampled at the ends of run 5**; the run it replaces recorded 0.74 at the start and 1.13 at
the end, and that is stated as run 4's figure rather than borrowed for run 5. What makes run 5's
conditions checkable without it is the arm that exists for the purpose: `control` is a
byte-for-byte duplicate of `batched`, and it reads **+0.41 %, [+0.08, +0.75] %** — within the
margin, and the same size as the difference under test, which is itself the finding.

**The dev shell is not a detail.** The first run of this benchmark used the system node, v25.9.0 /
V8 14.1; every verification check runs under `nix develop`, where node is **v24.19.0 / V8 13.6**,
and so would CI. The two engines give different numbers (that run read +0.20 %, CI [-0.40,+0.81]).
M19's review made the same correction about a compiler — *"a check that compiles must pin its
PATH, not only its toolchain and its flags"* — and it points the same way here: the authoritative
measurement is the one taken in the engine the checks run in. The `#CONFIG` line of `arms.tsv`
carries the node and V8 build, and `verify_trace_event_abi_batched_faster` asserts that this file
names the engine it was measured on, which is why the engine change reddened rather than passing
silently.

| arm | median (µs) | min (µs) | crossings | container (B) |
|---|---|---|---|---|
| `batched` | 628,918 | 616,616 | 25 | 4,694,016 |
| `perEvent` | 634,878 | 621,511 | 100,000 | 4,694,016 |
| `control` | 628,989 | 614,727 | 25 | 4,694,016 |
| `nopBatched` | 4,748 | 4,513 | 25 | 159,744 |
| `nopPerEvent` | 5,617 | 4,934 | 100,000 | 159,744 |

| comparison | median | 95 % interval | reads as |
|---|---|---|---|
| `perEvent - batched` | **+1.07 %** | **[+0.36, +1.78] %** | within noise |
| `control - batched` | +0.22 % | [-0.50, +0.93] % | the instrument is calibrated |
| `nopPerEvent - nopBatched` | +21.21 % | [+16.67, +25.75] % | the crossing, priced alone |

**Verdict: `within-noise`.** The comparator resolves a verdict only when the whole interval lies
OUTSIDE ±3 %, and none of the eleven runs comes close. Within a *single* run the interval is narrow
enough to exclude zero — twice, in opposite directions — which is exactly the pathology
`_timing_compare.py`'s header records for a different measurement: *"six runs of the same
measurement over the same two binaries produced mutually disjoint 95 % intervals"*. The
between-run nuisance is larger than the within-run interval, so a single run's interval must not
be read as the precision of the quantity. §8 tabulates all nine.

### Why the difference is this small

The crossing-only pair is the number that explains it, and *its SIGN* is stable while its size is
not: `nopPerEvent - nopBatched` came out +16.50 %, +6.98 %, +6.07 %, +6.65 %, +8.73 %, +4.56 %, +15.65 %, +18.40 % and
**+17.24 %** across the nine runs — always positive, always tiny in absolute terms, and spanning a
factor of four. In this run, 100,000 crossings cost 5,540 µs where 25 cost 4,769 µs:
**771 µs for 99,975 extra crossings, or ~7.7 ns each** — against §9.3's ~33 ns prior, and
**0.12 % of a 632,180 µs recording**. A whole recording costs about **820×** what its extra
crossings cost, at this event shape: one `register_step` and five
`register_variable_with_full_value` calls per event.

*This paragraph said the crossing-only pair "is stable" until run 7, which is 3.4× run 6's figure
on the same engine, and run 8 is higher again — so what is stable is the SIGN and the order of
magnitude, and the ratio has been ~700× to ~2,000× across the runs. The conclusion does not move (both ends are "less than a
per cent of a recording"), which is why this is a correction to a claim rather than to a decision.*

So §9.3's "obvious performance trap" is, at this writer's cost per event, **worth less than a
tenth of a per cent** — small enough that what the per-event arm actually pays is dominated by
host-side work (a 32-byte scratch write and a six-argument wasm call per event) rather than by the
boundary, and small enough that the sign of the total is decided by whichever way the run drifts.
That is a correction to a stated expectation, and it is stated here rather than left implicit.

## 3. The choice is about cost, not semantics

The same 2,000 events through both ABIs produce **byte-identical containers** — 290,816 bytes
each, at 8 crossings versus 2,000. Asserted by comparison of the bytes, not by design intent, in
`test_ct_container_roundtrip_ct_print`.

## 4. The decision, and the criterion that made it

**`ct_ingest` — the batched binary buffer — is the shipped ABI.** Not because it is faster: over
nine runs it was faster seven times and slower twice, by less than 1.4 % every time. The stated secondary
criterion is:

> **The per-event ABI's cost is linear in an engine constant this project has not measured and
> does not control; the batched ABI's is linear in one it does.**

8.7 ns per crossing is *V8-in-node-24*'s number. M27 packages this runtime for a browser and M28
gates on one, and neither engine has been measured. A per-event ABI makes a 38,903-step `burn`
recording's overhead a function of whichever engine the page happens to run in; a batched ABI
makes it a function of `encodeStep`, which is ours and which every arm above exercises.

Secondary, and weaker but real: M12's producer already hands step records over in batches —
`avm_steps_batch(from, count)`, `ceil(N / B)` crossings — so a batched ingest composes with it,
while a per-event ingest would fan a batch back out into individual calls.

**The rejected arm is kept, exported and exercised.** `ct_step` is in the shipped module, is
driven by the equivalence arm on every run, and `CtWriterOptions.stepExport` selects it. M15's
convention: a decision taken on numbers must be revisitable without redoing the work.

### What would reopen this

- **A browser engine measured with a materially higher per-crossing cost**, which would make the
  criterion above decisive rather than precautionary — or a materially *lower* one, which would
  make it moot.
- **A cheaper `emit()`.** The ~1,800× ratio is a fact about how much writer work an event costs. If
  M25 settles OQ-5 in favour of source-level stepping and the per-event writer work shrinks, the
  crossing's share grows and the arms could separate.
- **Events arriving one at a time.** The batched arm's whole advantage presumes a producer that
  has a batch. A future observation hook that delivered one event per host callback would remove
  the choice rather than settle it.

## 5. DD-7, and the revisit trigger M24 owes

**Path A is the writer**: `codetracer_trace_writer::ctfs_writer::CtfsTraceWriter`, pure Rust,
`wasm32-unknown-unknown`, zero wasm imports, at `pins.json`'s `trace_format` anchor. The container
records which path produced it — `ct_writer_kind()` returns 1 and it is carried into every
recording's result rather than inferred by a reader.

Columns are refused, not dropped: `resolveTracingConfig({columns: true}, path-a)` throws
`ColumnAwarenessUnavailable` **at configuration time**.

### THE ANCHOR MOVED, AND WHAT DD-7 RESTS ON MOVED WITH IT

`pins.json`'s `trace_format` anchor moved `9cbc127ef8` → `592fa42cbf` on 2026-08-26. Two things
change here, and they point in opposite directions, so they are stated separately rather than
summarised.

**The writer can carry columns now.** At the old anchor it could not, and the paragraph in the
superseded trigger below enumerates exactly why: no `sekDeltaColumn` encoder, no `paths.dat`
Layout A `line_lengths` table, `meta.dat` capability bits 4/6/7 unset. All three now exist. So
`ct_writer_open(want_columns = 1)` is **honoured**, and `dropped_column_awareness()` answers
`false` where at the old anchor it answered `true`.

**DD-7's refusal still stands, and its subject is no longer the writer.** What this runtime does
not have is a *source column to record*: `emit()` is on §9.2's rung 3 and writes a program counter
as `Line(pc)`. There is no source mapping, so there is no column, and enabling column-aware mode
would set the `meta.dat` bits that tell a reader this recording's columns are breakpoint-sharp
over positions that are program counters. `CARRIES_COLUMNS[path-a]` therefore stays `false` and
its declared meaning is now *this writer path, as wired into this runtime*, rather than *this
writer, structurally*.

**AND `dropped_column_awareness()` IS NO LONGER A BACKSTOP THAT CAN FIRE.** Through this ABI the
only way to reach a `true` was a writer that could not honour the request; the writer honours it
now, and the one remaining reachable `true` — a request arriving after
`begin_writing_trace_events` — is not reachable through `ct_writer_open`, which makes the call
before. M24 rested one bypass on that signal (a resolved configuration mutated after the gate
ran, caught at close). That bypass is closed at **configuration time** instead, by freezing the
resolved object, which survives type stripping where a modifier does not. The signal is still
read and still reported on every recording; it is corroboration now rather than enforcement, and
saying so is cheaper than a later reader discovering that an assertion in the tree cannot fail.

> ### REVISIT TRIGGER — **SUPERSEDED, AND KEPT RATHER THAN DELETED**
>
> **The trigger below no longer fires, because its premise has been overtaken by a decision taken
> outside this milestone: the Rust CTFS writer (Path A) is to be brought to full parity with the
> Nim writer — latest wire format, column support.** So a column-aware OQ-5 outcome no longer
> forces a *writer swap*; it forces Path A to have finished its parity work by the time M25 needs
> it. **M25's OQ-5 outcome does not choose between writers any more.** The trigger is left standing
> because it is the record of what the decision rested on, and because the structural gap it
> enumerates below is exactly the parity work's scope — if that work stalls, this is what a
> reopened DD-7 would have to weigh again.
>
> The trigger, as recorded when DD-7 was taken:
>
> **If M25's source-mapping investigation (OQ-5) resolves in favour of full source mapping *with*
> columns, DD-7 is reopened in favour of the column-aware Nim writer (Path B).**
>
> Path A's column limitation is structural rather than a missing flag: its `steps.dat` /
> `values.dat` / `events.dat` are not the v4 wire format, its `paths.dat` records are bare path
> bytes with no `line_lengths` Layout A table, its step positions use a private
> `(path_id << 32) | line` packing rather than the spec's `global_position_index`, and it has no
> `sekDeltaColumn` encoder. No amount of configuration reaches that.
>
> What the trigger costs, so the decision is not re-derived from scratch: Path B is a nix
> wasi-sdk build plus a C shim plus a build script, against Path A's one `cargo build`, and it is
> 542 KB full-WASI against Path A's 253 KB (246 KB when the trigger was written; see §7). `codetracer-trace-format-nim`'s `wasm/nim-to-wasm`
> branch — already pinned here as `trace_format_nim`, for its reader — carries
> `wasm/build-emscripten.sh`, `wasm/build-wasi.sh` and `wasm/build-standalone.sh`, so the work is
> a port of an existing build rather than a new one.
>
> **M25 must state which rung of §9.2's ladder it reached, per contract, in the trace metadata.**
> Until then this runtime is on rung 3 — bytecode-level stepping — and `emit()` says so where it
> records a program counter as `Line(pc)`.

## 6. The reader, and why it is pinned

A wasm-produced Path A container **cannot be read by stock `ct-print`**, and the stock reader
exits 1 with

```
Error reading events: chunk compressed data extends beyond events.log
```

— which is **not** the `RangeDefect` §9.3 predicted. The symptom is recorded as measured.

The fix is one commit, `baea074 fix(reader): read an events.log written by the Rust
CtfsTraceWriter`. `verification/build_ct_print.sh` builds the reader **at that commit and at its
parent**, both out of the object store, and `test_ct_container_roundtrip_ct_print` runs both
against the same bytes: exit 0 and exit 1. The claim is a one-commit difference and it is held as
one.

**THE `trace_format` MOVE NARROWS WHAT THAT ONE COMMIT IS DOING, AND THIS ANCHOR STILL DOES NOT
MOVE.** `baea074` fixes *two independent* mismatches and its own message names both: the Rust
writer prefixes `events.log` with the 8-byte CodeTracer file header the Nim writer omits, and its
chunks were streaming-encoder frames with no pledged content size. The anchor move retires the
**second** — every stream pledges now, on both targets — and does not touch the **first**. So the
parent still refuses the container, still with the message above, and the message is the
header-prefix half rather than the frame half. That is measured on every run rather than reasoned
here: both readers are run over the same bytes, and the day the parent starts reading it, the
check goes red and this paragraph is what it is disagreeing with.

### AND `ct-print` NEVER TOUCHED THE SPLIT STREAMS — A THIRD READER DOES

`codetracer_ct_print.nim` chooses its reader by whether the container carries `events.log`, and
diverts to the **legacy** combined-stream reader when it does — which is every container the Rust
writer produces. Its own comment says so. So every decode assertion in
`test_ct_container_roundtrip_ct_print` was satisfied out of `events.log`, and the check never read
`steps.dat`, `values.dat`, `calls.dat` or `events.dat`. It would have reported the same green over
a container in which all four are unreadable — which is precisely what a Path A container at the
**old** anchor was: three of the four read back as **zero records** through the v4 stream readers,
silently, because a streaming zstd frame carries no size for them to trust.

`verification/ct_split_probe.nim`, built by the same script from the same pinned revision into
`ct-split-probe`, opens the container through `openNewTrace` — the v4 split-stream reader
`ct-print` declines to use here — and reports each stream's answer separately, an unreadable one
as `ERR:<stream>: <reason>` rather than as a silence. `test_ct_container_roundtrip_ct_print`
asserts the four counts against the arm report and pulls a real value record, a real call and the
step positions, so the streams are exercised rather than enumerated. Proved by mutation: with
`pins.json` set back to `9cbc127ef8`, the repaired check goes **red naming the streams** — see the
anchor-move log for the measured output.

**Both anchors are published, and they were not.** M24 pinned `trace_format` (`9cbc127ef8`) and
`trace_format_nim` (`baea074019`, control `47ba17f43d`) to commits that existed only on local
branches in worktrees on one machine — no `origin/wasm/ctfs-writer`, no `origin/wasm/nim-to-wasm`.
`build_ct_writer_wasm.sh` and `build_ct_print.sh` take them out of the object store, so both
resolved here and would have failed in CI and in every other checkout, **with every check in this
milestone green either way**. M24's review pushed both branches to `metacraft-labs` and made
publication a checked property: `verify_ct_writer_wasm_zero_imports` and
`test_ct_container_roundtrip_ct_print` assert that each pinned commit is reachable from a
`refs/remotes` ref, with a negative control on the counter so the assertion can fail. A pin nobody
else can resolve is a local file wearing a pin's clothes.

## 7. Consequences for the milestones that depend on this

### M25 — step-level tracing

- **The event shape is upstream's `ExecutionStep`** and M24 did not invent one: `context_id`,
  `contract_address`, `pc`, `opcode`, `gas_used`, in a 64-byte little-endian record whose size the
  module publishes as `ct_record_size()`.
- **Adding a field is a wire-format change**, not a host change. The reserved bytes at offset 12
  are asserted zero on ingest, so the day one of them means something, a stale host fails loudly
  rather than being reinterpreted.

  *M25 CORRECTED THIS LINE'S FIGURE AND THE MODULE DOC'S. It said **8** reserved bytes and the
  module's own header said the fields need **56**; the offsets are `0,4,8,12,16,24,32+32`, so the
  fields need **60** and **4** are reserved. `const _: () = assert!(OFF_ADDRESS + ADDRESS_LEN ==
  CT_RECORD_SIZE)` had been pinning the total all along while nothing compared the other two
  figures to the layout — a figure nobody re-derives rots even when the assertion beside it is
  correct. Both are `CT_RECORD_FIELD_BYTES` and `CT_RECORD_RESERVED_BYTES` now, asserted against
  the offsets at compile time and by a native test. And M25 did NOT spend them: a `(path_id, line,
  column)` triple is twelve bytes, so the source position went on a separate channel —
  `SOURCE-MAPPING.md` §5.*
- **`emit()` is where an event becomes writer calls, and M25 SETTLED BOTH OPEN QUESTIONS IN IT.**
  OQ-5 resolved in favour of **rung 1** — `avm-transpiler` re-keys `brillig_locations` by AVM pc,
  so a step records a real `(path, line, column)` when the host resolves one and falls back to
  `Line(pc)` when it cannot, counted per contract rather than silently. OQ-4 resolved to `0x` +
  64 lowercase big-endian hex in `ValueRecord::String`, replacing `contractAddressLow`, because
  the full-precision `BigInt` variant is refused by the reader this campaign pins. Both verdicts,
  with their evidence, are in `SOURCE-MAPPING.md`.
- **Backpressure is solved and measured**: 250,000 events at 1,024 records per batch hold 65,536
  bytes of host-side buffer, constant, at `ceil(N / 1024)` crossings exactly.

### M26 — joining private and public traces

- OQ-7 asks whether the Rust-side Noir tracer and this TypeScript-side runtime can share one
  writer instance. **M24's answer to the half it can answer**: the module holds **one** global
  session, `ct_writer_open` returns `CT_ERR_ALREADY_OPEN` (−7) for a second, and the module is
  single-threaded with unshared memory. So sharing an instance means sharing a *module instance*,
  not opening two writers — and the Noir tracer's own wasm shell
  (`noir-wt4-webpage/tooling/tracer_wasm`) builds against the same writer crates at the same
  revision, which is the precondition for that being possible at all.
- **M26 SETTLED IT, and the verdict is in `JOIN-SHAPE.md`.** Sharing is *possible* and is
  demonstrated on one container; it is *not shippable*, because the only branch on which the Noir
  tracer and this runtime resolve the same writer crate is unpublished, and a pin that is not
  published is not a pin. The fallback — two containers with an EXPLICIT join record in each — is
  therefore the shipped path, and `ct_log_event` (§7 above) is what lets the module write it.

### M27 / M28 — browser packaging and the no-Node gate

- **The module has zero wasm imports**, so it instantiates under a bare
  `WebAssembly.instantiate(bytes, {})` with no WASI shim, no `wasm-bindgen` and no glue file.
  `ct-host` has **no npm dependencies** and imports no Node module in its trace path.
- **263,211 bytes** for the writer plus this ABI, release, `opt-level = "z"`, LTO,
  `panic = "abort"`, one codegen unit, stripped. Two clean builds (`rm -rf target`) are
  byte-identical, sha256 `e94baceb…`.

  *Re-derived on 2026-09-02, when M40 added the source-step surface: **262,693 -> 263,211, +518
  (+0.20 %)**, and the import count is unchanged at **0**. The growth is TWO exports —
  `ct_source_step` and `ct_source_steps_written`, in their own `SOURCE_STEP_EXPORTS` list for the
  reason `JOIN_EXPORTS` is in its own — plus one field on the session. **The step record did not
  grow** and the 100,000-event container is 4,694,016 bytes, unchanged TO THE BYTE, so §3's
  byte-identical-container claim still holds and run 11 in §8 measures the same event stream on
  different module bytes. The pair exists because a Noir private frame's step is a
  `(path, line, column)` and `emit()` records five AVM variables per step: writing one through
  `ct_step` would mean a host inventing four counters per step, which is the shape M29 found in
  M27's synthesised opcodes. See `BOTH-HALVES.md` §3.*

  *Re-derived on 2026-08-27, when M26 added the join surface: **259,839 -> 262,693, +2,854
  (+1.10 %)**, and the import count is unchanged at **0**. The growth is six exports —
  `ct_log_event`, `ct_log_event_count`, `ct_call`, `ct_return`, `ct_call_depth` and
  `ct_calls_opened`, in their own `JOIN_EXPORTS` list for the reason `SOURCE_MAPPING_EXPORTS` is in
  its own — plus three fields on the session. **The step record did not grow** and the
  100,000-event container is 4,694,016 bytes, unchanged TO THE BYTE, so §3's
  byte-identical-container claim still holds and run 8 in §8 measures the same event stream on
  different module bytes. Without those exports the shipped module cannot write the join record
  M26's fallback is defined by, nor the frames that make its two halves distinguishable, which is
  why a capability an event stream never uses is nevertheless in the module rather than in a
  probe. See `JOIN-SHAPE.md` §4.*

  *Re-derived on 2026-08-27, when M25 added the source-mapping surface: **253,122 → 259,839,
  +6,717 (+2.65 %)**, and the import count is unchanged at **0**.
  The growth is eleven exports — `ct_intern_path`, `ct_positions`, `ct_declare_rung` and the eight
  counters — plus the position FIFO, the rung table and the hex renderer OQ-4 settled on. **The
  step record did not grow**: `ct_record_size()` is still 64, so §3's byte-identical-container
  claim and §2's twelve-session benchmark are still measurements of what they were taken on. See
  `SOURCE-MAPPING.md` §5.*

  *Re-derived from the artefact on 2026-08-26, when the `trace_format` anchor moved
  `9cbc127ef8` → `592fa42cbf`: **246,527 → 253,122, +6,595 (+2.68 %)**, and the import count
  is unchanged at **0**, verified against a hand-built control module that imports one
  function and reports 1. The growth is the column-aware step encoder, the `paths.dat`
  Layout A producer, `zstd_frame` and the frame-content-size patcher. The old figure is kept
  here so the delta is a measurement rather than an assertion, and `§7`'s two numbers are
  re-derived from the built module by `verify_ct_writer_wasm_zero_imports` on every run —
  which is why moving the anchor without editing this line turns that check red.*

  *An earlier draft of this line recorded 245,724 bytes and a different hash, and that
  artefact was a MUTATION's — M6's infinite-spin `ct_ingest`, surviving a `cp -p` restore
  because cargo's fingerprint is mtime-based and the restore put the original timestamp
  back. The source was clean and what had been built from it was not. Recorded because a
  measurement taken against a mutated artefact is worse than no measurement.*

## 8. The rejected arm's numbers, retained

Kept so §4's decision can be revisited without re-running anything, and kept for BOTH engines,
because which engine a number was taken in turns out to matter. The per-event ABI would be
reconsidered if any of these changed:

| quantity | measured | where |
|---|---|---|
| `perEvent - batched`, median | +1.07 % | §2 |
| its 95 % interval | [+0.36, +1.78] % | §2 |
| cost of one boundary crossing in V8 | ~8.7 ns | §2 |
| the crossing's share of a 100k-event recording | 0.14 % | §2 |
| writer work versus boundary work | ~724× | §2 |
| containers produced by the two ABIs | byte-identical | §3 |
| host-side buffer at 250,000 events | 65,536 B, constant | §7 |

**All eleven runs, retained**, because the disagreement between them is the finding rather than a
nuisance. None is wrong; they are what this measurement does.

| # | engine | `perEvent - batched` | 95 % interval | `control - batched` | `nopPerEvent - nopBatched` | crossing |
|---|---|---|---|---|---|---|
| 1 | node v25.9.0 / V8 14.1.146.11-node.25 (system node) | +0.20 % | [-0.40, +0.81] % | +0.08 % | +16.50 % | ~5.6 ns |
| 2 | node v24.19.0 / V8 13.6.233.17-node.51 (dev shell) | +1.09 % | [+0.79, +1.39] % | +0.16 % | +6.98 % | ~3.2 ns |
| 3 | node v24.19.0 / V8 13.6.233.17-node.51 (dev shell) | -0.58 % | [-1.13, -0.03] % | -0.01 % | +6.07 % | ~2.7 ns |
| 4 | node v24.19.0 / V8 13.6.233.17-node.51 (dev shell) | -0.09 % | [-0.68, +0.51] % | +0.26 % | +6.65 % | ~2.9 ns |
| 5 | node v24.19.0 / V8 13.6.233.17-node.51 (dev shell, new module) | +0.96 % | [+0.12, +1.80] % | +0.41 % | +8.73 % | ~4.2 ns |
| 6 | node v24.19.0 / V8 13.6.233.17-node.51 (dev shell, M25's module) | +0.98 % | [+0.29, +1.67] % | -0.38 % | +4.56 % | ~3.1 ns |
| 7 | node v24.19.0 / V8 13.6.233.17-node.51 (dev shell, M26's module, join records) | +0.85 % | [+0.50, +1.21] % | -0.21 % | +15.65 % | ~8.6 ns |
| 8 | node v24.19.0 / V8 13.6.233.17-node.51 (dev shell, M26's module, + frames) | +0.74 % | [+0.11, +1.36] % | -0.16 % | +18.40 % | ~7.9 ns |
| 9 | node v24.19.0 / V8 13.6.233.17-node.51 (dev shell, **the SAME module as run 8**) | +1.34 % | [+0.67, +2.00] % | -0.17 % | +17.24 % | ~7.7 ns |
| 10 | node v24.19.0 / V8 13.6.233.17-node.51 (dev shell, the SAME module as runs 8 and 9) | +1.21 % | [+0.58, +1.85] % | -0.35 % | +18.71 % | ~8.7 ns |
| 11 | node v24.19.0 / V8 13.6.233.17-node.51 (dev shell, M40's module, source steps) | **+1.07 %** | **[+0.36, +1.78] %** | +0.22 % | +21.21 % | ~8.7 ns |

Run 11 is the one §2 tabulates, because it is the one `arms.tsv` currently holds and the one the
check compares this file against. **Runs 2, 3 and 4 are the same engine, the same module and the
same binary**, and runs 2 and 3 have disjoint intervals with opposite signs — which is why §2 says
the sign is not stable rather than quoting any one run's interval as a precision. **Runs 5 to 8
are the same engine and DIFFERENT modules**, so none is a replicate of runs 2–4 and none is
offered as one. What they do is put the instability to a test it could have failed four times —
any of them could have come back with runs 3 and 4's sign and a tight interval, and all four came
back with run 2's. **Runs 8, 9 AND 10 are replicates of each other**, same engine and same module, and
they read +0.74 %, +1.34 % and +1.21 %: the point estimate nearly doubles between two runs of one
binary, and the third lands between them. Three replicates is what the earlier eight runs never
had, and they span +0.74 to +1.34 with overlapping intervals — the between-run nuisance measured
directly rather than inferred from runs that differed in something else.
In all eleven the control reports no difference beyond the margin, so the instrument is calibrated
in all eleven; what is not stable is the subject.

**RUN 11 IS M40's MODULE, AND IT IS THE FIFTH TIME A NEW MODULE HAS BEEN PUT TO THE SAME TEST.**
`ct_source_step` and its counter add 518 bytes and no step-record field, and the run reads
**+1.07 %, [+0.36, +1.78] %** — run 2's sign, run 10's size, on a fifth distinct module. The
control reads **+0.22 %** with an interval that straddles zero, which is the instrument saying it
cannot resolve a difference between two byte-for-byte identical arms; that is the same statement
the subject's own interval makes, and it is why the verdict stays `within-noise`.

**RUN 10 EXISTS BECAUSE A COMMENT WAS CORRECTED**, which is a fact about the instrument worth
having in the record. `_m24_oq6_stamp` hashes `ct-host/src/{writer,abi,config}.ts` and
`tools/run_oq6_arms.mjs` WHOLE, so M26's review changing one sentence of a docstring in `abi.ts` —
a change that cannot move a measurement — invalidated the stamp, re-ran the twelve-session
benchmark, and left this file quoting run 9 against an `arms.tsv` holding run 10: fifteen red
assertions in a milestone nobody had touched, with the assertion COUNT unchanged at 91. The
document is rendered from the new data rather than the stamp being loosened, because a stamp that
tries to tell a comment from code is a harder thing to get right than a re-render is to run.

