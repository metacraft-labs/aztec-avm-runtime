# M24 implementation log — `.ct` Writer Binding and the Trace Event ABI

Rule: **written after every completed step**, not at the end of a phase. Six interruptions so
far in this campaign; each lagging log cost a reconstruction from `git status`.

**No commits. No pushes.** A review agent follows.

---

## Step 0 — read the briefs, take the machine's condition (DONE)

Read, in order: `scratchpad/campaign/m24-brief.md`, `CAMPAIGN-BRIEF.md` in full, the M24
section of the milestones file, M15 (the event shape) and M12 (the batched step stream), and
`BOUNDARY-SHAPE.md` §3 and §8.

What M15/M12 settled, and which M24 must honour rather than re-decide:

- `TxSimulationResult.execution_steps` carries the whole step stream; **38,903 records for
  `burn` after ONE crossing**. `avm_steps_batch(from, count)` exists for a host that wants to
  stream into a writer as it goes, at `ceil(N/B)` crossings. M12 measured 38,903 crossings at
  batch size 1, 76 at 512, 10 at 4,096.
- M15's own note: *"M25's OQ-6 is a measurement against M12's numbers and should re-derive them
  rather than quote this file."* — so OQ-6 is a fresh measurement, on the WRITER side of the
  boundary (host → `.ct` writer), not a re-quote of the AVM → host side.
- `ExecutionStep` is `MSGPACK_CAMEL_CASE_FIELDS(context_id, contract_address, pc, opcode,
  gas_used)` — five fields, and that is the event shape M24's ABI must carry.

Machine condition, taken at the start (2026-08-26 13:55 local, this host):

```
load average: 0.10 0.29 0.41       (idle; 3 users, up 24 days)
32 cores        AMD Ryzen 9 5950X 16-Core (SMT on)
62 GiB RAM      13 free, 42 buff/cache, 55 available
swap 66 GiB     22 used            <-- noted; see below
/tmp   tmpfs 32G, 21G used, 12G AVAIL   <-- RAM. Not storage. $TMPDIR repointed by lib.sh.
/home  953G disk, 220G avail
node   v25.9.0
```

22 GiB of swap in use with 55 GiB available is old, cold anonymous memory from a 24-day
uptime, not pressure — `free` shows 13 GiB genuinely free and no reclaim activity. Recorded
because a benchmark run on a swapping box is not a benchmark, and the campaign's standard is to
STATE the condition rather than assert idleness.

## Step 1 — enumerate every `.ct` writer before choosing one (IN PROGRESS)

Enumeration agent dispatched over: `codetracer-trace-format`, `codetracer-trace-format-nim`,
`noir` (the earlier campaign's tracer), the whole `aztec-avm-runtime` fork including
`upstream/tsavm` and the vendored `diffsim/` `drift/` `spike/` copies and every `node_modules`
root, and `codetracer` itself.

The campaign has been wrong **nine** times about whether something needed writing and every
miss was a parallel subdirectory. Nothing is written until this returns.

Established without waiting for it, because they bound what M24 can do at all:

- `DD-7` is in `codetracer-specs/Planned-Features/Aztec-AVM-Runtime.md:1356`. Path A's entry
  point is named there: `codetracer_trace_writer::ctfs_writer::CtfsTraceWriter::new_in_memory`,
  `wasm32-unknown-unknown`, 383 KB, and it exposes `dropped_column_awareness()` *precisely so a
  consumer can assert rather than discover the loss downstream*. The three crates that must
  resolve to one instantiation are named there too: `codetracer_trace_types`,
  `codetracer_trace_writer`, `codetracer_ctfs`.
- §9.3's last paragraph is OQ-6 verbatim: *"TypeScript writes a compact binary event buffer into
  wasm linear memory and calls a single `ct_ingest(ptr, len)` per batch"* is the LIKELY shape,
  and *"~33 ns per boundary crossing in V8"* is the prior number. M24 measures; it does not
  assume.
- **There is no Rust wasm toolchain in this tree yet.** System `rustc` is Arch's 1.97.1 and
  `/usr/lib/rustlib/` holds only `x86_64-unknown-linux-gnu` — no `wasm32-unknown-unknown`, no
  `rustup`. `grep -rn rustup` over the tree finds it only in `CAMPAIGN-BRIEF.md`'s environment
  line and in vendored `cargo-fuzz` READMEs. M24 is the first Rust build in this repository, so
  the toolchain is a deliverable and not a given.
- `node-host/src/memory.ts` already contains a **wasm import-section reader** written in
  TypeScript (`readMemoryImport`, LEB128 + section walk). `verify_ct_writer_wasm_zero_imports`
  reuses that rather than writing a second one.
- `verification/wasm_host/_timing_compare.py` (482 lines) already holds this campaign's
  measurement standard as code: percentile-bootstrap and Student-t CIs with **the session as the
  unit of replication**, the wider of the two intervals reported so it is not selected for being
  narrow, a `control` arm, distinct exit codes for "too few sessions" (3) and "ran but cannot
  resolve" (4), and the rule that a recorded FAIL outranks both. OQ-6 reuses its primitives.
- `verification/lib_m15_shapes.sh:370-405` holds the **ABBA** rationale and `m15_bench_min`.
  Measured there: the first run of a session reads 6,630 us where the same binary's second reads
  9,384 — *the order effect is larger than the quantity the comparison is for*. OQ-6 interleaves.

### Step 1 result — and it is the tenth time the campaign was nearly wrong

**Two real `.ct` writers exist in this workspace and neither of them is ours to write.** Every
other appearance is a *path dependency into the same object store* — no vendored copy, no fork,
no second implementation, in twenty-two recorder repos.

| writer | where | what |
|---|---|---|
| Path A, pure Rust | `codetracer-trace-format/codetracer_trace_writer` (`CtfsTraceWriter`, `ctfs_writer.rs`) | DD-7's choice |
| Nim | `codetracer-trace-format-nim/src/codetracer_trace_writer.nim` | Path B, column-aware |

`codetracer_trace_writer_nim` is an FFI shim from Rust to the second, **not** a third writer, and
`codetracer_trace_writer_ffi` is a 24-function C ABI over the first — `staticlib`+`cdylib`,
cbindgen, `trace_writer_new/_begin_metadata/_register_step/…`, **one call per event**. That is
OQ-6's arm A, already written, by somebody else, for Go.

**And three worktrees hold work M24 would otherwise have written from scratch.** All three are
local-only branches with no `origin/` counterpart, which is exactly the "parallel subdirectory"
shape the campaign has been caught by nine times:

| worktree | branch | HEAD | what it already does |
|---|---|---|---|
| `/home/zahary/m/blocktracer/ctf-wt-wasm` | `wasm/ctfs-writer` | `9cbc127` | **the whole Path A wasm deliverable** |
| `/home/zahary/m/blocktracer/ctfnim-wt-wasm` | `wasm/nim-to-wasm` | `0f01698` | the **reader** that can read what it produces |
| `/home/zahary/m/blocktracer/noir-wt4-webpage` | `wasm/webpage` | `f0e7edc` | a Noir tracer writing `.ct` from wasm in a browser |

`ctf-wt-wasm` is six commits on top of `blocktracer`'s `6646afa`:

```
4521468 feat(ctfs): build for wasm32 and lay containers out in memory
aa32515 feat(writer): produce CTFS containers on wasm32, in memory
aff39a6 test(writer): pin that the in-memory container matches the on-disk one
97aa047 feat(demo): a wasm32 module that builds a .ct container
51ebb44 feat(writer): close() and the column-aware family, for trait parity
9cbc127 feat(writer): make a dropped column-aware request detectable   <-- DD-7's signal
```

`wasm-ctfs-demo/src/lib.rs` is 141 lines and is **the reference C ABI**: four `extern "C"`
functions over linear memory, no `wasm-bindgen`, no glue, zero imports, instantiating under a
bare `WebAssembly.instantiate(bytes, {})`. It also records the two things a wasm host must supply
that a native recorder gets free — a `recording_id` (no clock, no CSPRNG in the sandbox) and a
workdir (no current directory).

**The reader-side consequence is already solved and I would have re-derived it.** `ruzstd`'s
frame compressor leaves `frame_content_size` unset; the Nim v3 reader used to raise on it.
`ctfnim-wt-wasm` carries `decompressFrameOfUnknownSize` (`src/codetracer_trace_reader.nim:629`)
under commit `baea074 fix(reader): read an events.log written by the Rust CtfsTraceWriter`, with
`tests/test_rust_written_events_log.nim` pinning an unpledged frame. So M24 *builds* `ct-print`
from that branch; it does not work around anything.

**`noir-wt4-webpage/tooling/tracer_wasm/src/ctfs_sink.rs` already implements DD-7's discipline**,
and its header states the loss precisely: `paths.dat` records are bare path bytes rather than
Layout A, the step position packs `(path_id << 32) | line` rather than `global_position_index`,
there is no `sekDeltaColumn` (tag `0x07`) encoder, and therefore **`meta.dat` capability bits
4 / 6 / 7 are deliberately not set** — *"advertising a capability the bytes do not carry would
make a reader ask for columns and decode garbage rather than fail."* `dropped_column_awareness`
is surfaced into the page's summary. M24 reuses the discipline; the code itself implements
`noir_tracer::TraceSink` and is Noir's.

`noir-wt4-webpage/Cargo.toml:175-203` states the single-instantiation constraint in the words
RI-42 uses, having hit it: *"two copies of `codetracer_trace_types` on different paths are two
distinct types and `FullValueRecord`/`ValueRecord` will not unify. `[patch.crates-io]` cannot
express this."* It resolves it with three path deps into **one** checkout plus a `package =`
rename so both writers coexist.

**So what remains genuinely unwritten is the event-ingest ABI and its host.** `tracer_wasm`'s
exports are `ct_trace(program, inputs)` — hand the module a program and it traces it itself.
M24's events come from the *outside*, from the AVM through TypeScript, which is a different ABI
and is what OQ-6 is about.

**Negative findings, stated because an absence claim is only as wide as the search:**
`aztec-avm-runtime` has no writer, no reader and no codetracer dependency of any kind — in all
**21** of its `Cargo.toml` files, its **five** `node_modules` roots (`spike/`, `drift/`,
`probe-mt/`, `diffsim/`, `orchestration/`), `upstream/tsavm/`, and the vendored `diffsim/`
`drift/` `spike/` copies. Every hit is prose. `codetracer` itself has no writer — it consumes
the sibling repos by path and by flake input, and its 33 vendored Nim libs contain no
trace-format copy. `noir` on `blocktracer` has no writer either: `tooling/tracer` drives
`dyn TraceWriter`, and its `Cargo.toml:144` renames **`codetracer_trace_writer_nim`** to
`codetracer_trace_writer` — so "the Noir tracer's writer" is the *Nim* one, for a stated reason:
the pure-Rust writer emits a SplitBinary single-shard variant stock `ct-print` cannot read.

## Step 2 — the one correction owed from M23 (DONE)

M18's stale reason clause said *"there is no TypeScript orchestration in this package yet —
RI-19..RI-23 are decided but not vendored, so there is no `PublicProcessor` to execute
through."* M22 falsified it. Verified against the tree rather than against the brief:

```
orchestration/src/vendor/  -> 10 files, incl. public_processor/{public_processor,
                              guarded_merkle_tree,public_processor_metrics}.ts
PROVENANCE.md              -> rows F10..F19, anchor `ts`, inventory RI-21/23/22/19/66
```

Corrected in **two** places, because the clause lives in both and fixing one would leave the
document contradicting itself:

1. the `e2e_ts_wasm_token_transfer` entry description (the `e2e_ts_wasm_amm` entry says "for the
   same one reason as the token entry" and inherits the fix);
2. M18's *"What is not done"* prose, §First.


**Status unchanged on all five pending entries** — the conclusion (blocked on the transaction
builder and the TypeScript-side DB seeding) is still correct, and this is a reason-not-conclusion
correction. Checked first that no verification check greps these sentences:
`grep -rln 'milestones.org' verification/ tools/ Justfile` finds only
`verify_fallback_triggers_recorded_and_evaluated.sh`, which reads M16's trigger section.


## Step 3 — feasibility probe: does Path A actually build to wasm here? (DONE)

Answered by execution rather than by reading the branch's commit messages. `~/.cache/aztec-m24-probe`.

**The materialisation is from the OBJECT STORE, not the worktree**, which is the campaign's
enforced precondition and is trivial here:
`git -C codetracer-trace-format archive 9cbc127… | tar -x`. `ctf-wt-wasm` is a *worktree of the
same repository*, so the rev is reachable from the canonical checkout and no second clone exists.

Toolchain — **and it is not in either dev shell**, which is a finding rather than a footnote:

```
nix shell nixpkgs#rustup nixpkgs#capnproto
RUSTUP_HOME=~/.cache/aztec-m24-rustup  CARGO_HOME=~/.cache/aztec-m24-cargo
rustc 1.98.0 (88d9e12ae 2026-08-18)   targets: wasm32-unknown-unknown, x86_64-unknown-linux-gnu
Cap'n Proto 1.4.0
```

**`capnp` is a hard build-time dependency and the failure does not say so usefully.** Without it
the build dies in `codetracer_trace_format_capnp`'s `build.rs:2` with `exit status: 101` and a
panic — a *build-script* failure four crates deep, not a missing-tool diagnostic at the top. It
is `codetracer_trace_writer` -> `codetracer_trace_format_capnp` -> `capnpc` -> the `capnp`
binary. Recorded here because the next agent to build this will otherwise read it as a broken
branch. Dependency lists were read at this repo's own pin before adding anything: `capnproto` is
a nixpkgs derivation, not a crate, and the crate graph itself is whatever `9cbc127`'s
`Cargo.lock` resolves — no crate was added by hand.

Result, measured:

```
ct_writer_probe.wasm   408,670 bytes   release, opt-level="z", lto, panic="abort"
WebAssembly.Module.imports()            -> 0        [] , exactly
exports                                 -> memory, probe_build, probe_len, probe_dropped_columns
new WebAssembly.Instance(mod, {})       -> instantiates with an EMPTY import object
probe_build(64) -> ptr 1153072, len 172032
container magic  c0 de 72 ac e2  version 03          (CTFS)
```

So DD-7's Path A is live, it reaches `wasm32-unknown-unknown`, and **zero wasm imports is a
measured property of the artefact rather than an intention**. 383 KB in §9.3 was writer+demo;
408,670 B here is writer + a slightly larger demo body.

## Step 4 — the crate, the pin and the host (DONE)

### Written

| path | what | its own dependency list |
|---|---|---|
| `ct-writer/Cargo.toml` + `src/lib.rs` (~740 lines) | the event ABI over `CtfsTraceWriter` | **two path deps into ONE checkout**: `codetracer_trace_types`, `codetracer_trace_writer`. `codetracer_ctfs` is deliberately NOT named — it is the writer's own dep and naming it again could only create a second path to it. Build-time: `capnp` 1.4.0, `rustc` 1.98.0, target `wasm32-unknown-unknown`. |
| `ct-host/` (`package.json`, `tsconfig.json`, `types/node-subset.d.ts`, `src/{abi,config,writer,index}.ts`) | the TypeScript host | **none.** No npm dependency at all, and no `@types/node`: two Node modules are declared in `types/`. The module has zero wasm imports so the host owes it `{}` and a `DataView`; that is what makes the same code run in a browser for M27. |
| `verification/build_ct_writer_wasm.sh` | materialise + build | `nix`, `python3`, `git`, `tar` |
| `pins.json` `anchors.trace_format` | the pin | — |

### Reused, unmodified

`codetracer_trace_writer::ctfs_writer::CtfsTraceWriter` (Path A), `codetracer_ctfs`,
`codetracer_trace_types`, all at `9cbc127ef8`; `wasm-ctfs-demo` as the **C-ABI reference**;
`ctfnim-wt-wasm`'s `ct-print` as the reader. **Nothing was vendored** — RI-42's decision is
`depend`, so `PROVENANCE.md` gains no row and `verify_provenance_complete` does not move.

### The pin, and why it is an anchor rather than a Cargo `rev`

`pins.json` gains a fourth anchor, `trace_format` -> `9cbc127ef8e8c09027f5da047c333149f54c8320`,
and it is the **first anchor in this file that is not aztec-packages**. `build_ct_writer_wasm.sh`
reads it and does `git -C codetracer-trace-format archive <rev> | tar -x` into
`ct-writer/build-wasm-deps/ctf/` — **the object store, never the worktree**. The trap that closes
is a *revision* difference: `../ctf-wt-wasm` is a worktree sitting on the branch this revision is
the tip of, and copying from it would pick up uncommitted edits and would follow the branch when
it moves. A sha1 typed into the build script would have been a second authority; PINS.md says
there is one.

Checked, not assumed, that the new anchor moves no count: `verify_pinned_nightly_single_source`
asserts `assert_ge 3` on the anchor count (not `assert_eq`), and `check_drift.sh` resolves only
the anchors **the PROVENANCE mapping names** — this one is named by no row, so `check-drift`
never asks the aztec-packages fork for a commit it cannot have.

### Measured, on the built artefact

```
ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm   246,527 bytes
WebAssembly.Module.imports()   -> []            zero, exactly
exports                        -> 19 functions + memory
cargo test --release           -> 5 passed, 0 failed          (native, --test-threads=1)
```

End to end through the host, 5,000 events at 512 records/batch:

```
events 5000   crossings 10 (= ceil(5000/512), exactly)   memory growths 8
writerKind 1  columnsRequested false  droppedColumnAwareness false
container 368,640 bytes    bufferBytes 32,768 (constant)
ct-print (wasm/nim-to-wasm)  rc=0   5000 Step, 25000 Value, 1 Path, 1 Function, 1 Call
ct-print (stock, blocktracer) rc=1  "chunk compressed data extends beyond events.log"
```

**Two corrections to settled prose, both measured:**

1. §9.3 says stock `ct-print` "raises `RangeDefect`" on an unpledged frame. It does not, at these
   revisions: it exits **1** with `Error reading events: chunk compressed data extends beyond
   events.log`. The consequence is the one recorded; the symptom is not.
2. **Eight `memory.grow` events happened inside one 5,000-event recording.** `WebAssembly.Memory.grow`
   detaches `memory.buffer`, so every cached `DataView` and `Uint8Array` dies mid-recording. This
   is not a hazard M24 anticipated from the documents — it was found by the smoke run — and
   `CtWriter.refresh()` exists for it. It is counted and reported (`memoryGrowths`) so a check can
   assert the path was exercised rather than merely present.

### The DD-7 gate, and the type-erasure lesson applied ahead of the mutation

Four refusals, all executed rather than read:

```
resolveTracingConfig({columns:true}, PATH_A)        -> ColumnAwarenessUnavailable   (config time)
  ... the same call routed through `as any`         -> ColumnAwarenessUnavailable   (value, not type)
new CtWriter(inst, {shape-identical object})        -> UnresolvedTracingConfig      (WeakSet identity)
columns resolved against PATH_B, run on the PATH_A
  module, closed                                    -> ColumnAwarenessDropped       (close time)
```

**Nothing in the gate is a type.** No `private constructor`, no branded type, no literal type — all
of those are erased by Node's stripper, which is exactly how M23's §8.4 disclosure was bypassable.
The config-time refusal tests the **value** `columns === true`; the constructor tests **object
identity** through a module-private `WeakSet`, which `RESOLVED.has(x)` actually runs. And the
close-time assertion is CONDITIONAL on `columnsRequested`, per DD-7 — asserting
`dropped_column_awareness()` unconditionally would fail every ordinary recording, because the
signal is false precisely because nobody asked.

## Step 5 — OQ-6 measured, and it did not choose (DONE)

**12 sessions x 6 ABBA blocks, 100,000 events, batch 4,096, node v25.9.0 / V8 14.1.146.11-node.25.**
Run `setsid`-detached. Machine as recorded in Step 0; load 0.1-0.4 throughout, `/tmp` untouched
(everything under `~/.cache`).

```
arm            median us    min us     crossings   container
batched          515,176    502,843           25   4,435,968
perEvent         516,681    505,961      100,000   4,435,968
control          515,232    503,784           25   4,435,968
nopBatched         3,793      3,598           25     159,744
nopPerEvent        4,352      4,196      100,000     159,744

perEvent - batched            median  +0.20 %   CI [-0.40, +0.81]   min +0.45 %
control  - batched            median  +0.08 %   CI [-0.34, +0.50]     <-- the negative control
nopPerEvent - nopBatched      median +16.50 %   CI [+12.33, +20.67]   <-- the crossing, alone
```

**VERDICT: `within-noise`.** And it is a resolved result, not an unresolvable one: the interval is
+/-0.6 pp around +0.20% against a 3% margin, so the measurement says the difference is small
rather than saying it cannot tell.

**The negative control did its job.** `ct_ingest_control` is a byte-for-byte duplicate of
`ct_ingest` exported from the same module and run in the same rotation: +0.08%, CI [-0.34,+0.50].
An instrument that reports no difference where there is none is calibrated; one that has never
been shown to is not.

**The crossing, priced on its own, is the number that explains the null.** With the writer work
removed, 100,000 crossings cost 4,352 us against 25 crossings at 3,793 us: **559 us for 99,975
extra crossings = 5.6 ns each**, against §9.3's ~33 ns prior. That is **0.11% of a 515,000 us
recording**. The writer work outweighs the boundary by about 135x, so no ABI choice at this event
shape can move the total by a measurable amount. §9.3 called per-event crossing "the obvious
performance trap"; measured, at this writer's cost per event, it is not one.

**So the ABI is chosen on a stated secondary criterion, and the number that chose it is the one
that failed to.** The criterion, stated rather than implied:

> **The per-event ABI's cost is linear in an engine constant this project has not measured and
> does not control; the batched ABI's is linear in one it does.** 5.6 ns/crossing is
> *V8-in-node-25*'s. M27 packages for a browser and M28 gates on one, and neither has been
> measured. A per-event ABI would make a 38,903-step `burn` recording's overhead a function of
> whichever engine the page runs in; a batched one makes it a function of `encodeStep`, which is
> ours. Secondary: M12's producer already hands records over in batches
> (`avm_steps_batch(from, count)`), so a batched ingest composes with it, while a per-event ingest
> would fan a batch back out into individual calls.

**`ct_ingest` ships. `ct_step` is kept, exported and exercised** — M15's convention for a rejected
arm — and the equivalence arm proves the choice is about cost and not semantics: the same 2,000
events through both ABIs produce **byte-identical containers** (282,624 bytes each, 8 crossings
versus 2,000).

**The entry `verify_trace_event_abi_batched_faster` is named after a premise the measurement
refuted.** The name is kept because it is the declared name; the check asserts what was actually
established — that OQ-6 was settled to the standard, that the recorded verdict equals the measured
one, and that the shipped ABI follows the recorded decision — and the milestone entry says so in
those words.

## Step 6 — the reader, built at the fix and at its parent (DONE)

DD-7's recorded consequence is a claim about a DIFFERENCE, so it is held as one. Both readers are
built by `verification/build_ct_print.sh` out of `codetracer-trace-format-nim`'s **object store**:

```
ct-print      @ 0f01698307  (wasm/nim-to-wasm)   rc=0   250,056 lines of JSON
ct-print-pre  @ 47ba17f43d  (= baea074^)         rc=1   "Error reading events: chunk compressed
                                                          data extends beyond events.log"
```

**One commit apart.** `baea074 fix(reader): read an events.log written by the Rust CtfsTraceWriter`
adds `decompressFrameOfUnknownSize`, and it is the whole difference between a container that reads
and one that does not. `pins.json` gains a fifth anchor, `trace_format_nim`, carrying both commits
— `commit` and `control_commit` — so the control is a declared field rather than a shell constant.

The trap worth recording: `nix shell nixpkgs#zstd.dev` puts the package's *bin* directory on `PATH`
and sets no `CPATH`, so the nim build fails `fatal error: zstd.h: No such file or directory` with
the dependency present. Resolved explicitly and passed with `--passC`/`--passL`.

## Step 7 — the functional arms (DONE)

`tools/run_ct_writer_arms.mjs` -> `~/.cache/aztec-m24-ct-writer/ct.json`, measured once and shared.

```
surface        imports 0   19 exports + memory   moduleRecordSize 64 == hostRecordSize 64
               writerKind 1 (Path A)   missingRequired []
roundtrip      5,000 events   10 crossings (= ceil(5000/512))   442,368 B   8 memory growths
equivalence    2,000 events through BOTH ABIs -> identical: TRUE, 282,624 B each,
               8 crossings vs 2,000
backpressure   25,000 -> 250,000 events (10x) at batchRecords 1,024 (a QUARTER of roundtrip's):
                 bufferBytes   65,536 -> 65,536          CONSTANT
                 crossings     25 -> 245                 = ceil(N/1024) exactly, both
                 heap delta    71,288 B -> 108,536 B     1.52x for 10x the events
                 container     1,499,136 B -> 13,520,896 B
                 memory growths 223
gates          columns-on-path-a               -> ColumnAwarenessUnavailable
               columns-on-path-a-through-any   -> ColumnAwarenessUnavailable  (JSON.parse'd `true`)
               unresolved-config-object        -> UnresolvedTracingConfig
               columns-requested-then-dropped  -> ColumnAwarenessDropped
               ordinary-recording-is-allowed   -> DID NOT THROW      <-- the gates' own control
codec          encode/decode round trip over four records: exact
```

The fifth gate is the one that makes the other four mean something: without it, a host that
refused *everything* would satisfy all of them.

## Step 8 — the six checks (DONE)

All six run green. Per-check assertion counts, measured:

```
verify_ct_writer_wasm_zero_imports        49
test_ct_container_roundtrip_ct_print      46
test_dropped_column_awareness_asserted    39
test_single_trace_types_instantiation     37
test_trace_writer_backpressure            30
verify_trace_event_abi_batched_faster     81
                                    M24  282
```

Justfile: `ct-writer-build`, `ct-print-build`, `ct-writer-arms`, `oq6-measure`,
`typecheck-ct-host`, six per-check targets, and `verify-m24`.

### Four defects the checks found in their OWN authorship, before any mutation

Recorded because each is a named family and each cost one red run rather than a milestone:

1. **`\t` IS NOT A TAB IN A POSIX ERE.** Bash's `=~` is an ERE; `str_has_line_re "$s" '^EXPORT\tct_step\tfunction$'`
   matched nothing while the haystack plainly contained the line. **26 of 49** assertions in
   `verify_ct_writer_wasm_zero_imports` went red at once for a reason with nothing to do with
   their subject. Every pattern now carries a real tab through `TAB=$'\t'`.
2. **A CITATION COUNTED AS A CALL — in the check written to prevent M23's erased-`private`
   defect.** `grep -rc 'private constructor' ct-host/src` returned **1**, and the occurrence was
   the comment in `config.ts` explaining why one is not used. The count is taken over code now
   (`verification/_strip_ts_comments.py`), and the presence of the phrase *in a comment* is
   asserted too, so the stripper is shown to be doing work rather than returning nothing.
3. **A VACUOUS PASS, caught by its own non-emptiness partner.** `CARGO_HOME` was unset inside
   `nix shell … --command bash -c` under `set -u`, so `cargo tree --duplicates` produced **empty
   output** — and `assert_false "names no codetracer crate"` PASSED on it. Only `assert_true
   "cargo tree ran"` beside it went red. This is the campaign's oldest family, live, in M24's own
   work.
4. **AND THE ASSERTION THAT REPLACED IT WAS WRONG IN THE OTHER DIRECTION.** `cargo tree
   --duplicates` prints one *subtree* per duplicated crate, and a codetracer crate appears deep
   inside those subtrees as a parent of `syn` and `schemars` — so a substring search for
   `codetracer` over the whole output goes red on a graph with no trace-crate duplicate in it.
   The duplicated crates are the lines at column 0. Likewise `DUPLICATES 0` over the lock file was
   wrong: the real lock has four legitimately duplicated crates (`syn`, `schemars`, `hashbrown`,
   `indexmap`, two majors each). The assertion is on the codetracer-filtered count, with the
   unfiltered count asserted NON-zero beside it so the filter is visible.

### Two more, in the artefacts rather than the checks

5. **A UNICODE MINUS.** `TRACE-ABI.md` was written with `−` (U+2212) in its intervals, and the
   check builds its needle from the comparator's ASCII `-`. Red. The document is ASCII in every
   figure a check re-derives.
6. **`.rev` STAMPS.** `m24_require_readers` originally rebuilt only when a binary was ABSENT, so a
   `ct-print` left behind by an earlier hand-build was used and its revision never checked — "never
   depend on state you did not produce", live. It compares the stamps against `pins.json` now.

## Step 9 — mutation testing, and what it found in M24's own machinery (IN PROGRESS)

`scratchpad/campaign/m24-mutations.sh` — thirteen mutations, restored from a copy the script takes
itself and verified by `cmp`, never by `git checkout` (an untracked file would silently not be
restored) and never by an inverse edit (an inverse that does not exactly invert leaves a corrupted
tree the next run reports as a regression). **Nothing in it edits a shell script**, because a
check reads its own file while it runs.

Batch A (M1–M4), all detected:

| id | mutation | result |
|---|---|---|
| M1 | `emit()` writes four variables per step instead of five — the container still reads | roundtrip **2 failures**, backpressure **1** |
| M2 | the DD-7 identity gate becomes a **TypeScript-only** guarantee (M23's erased `private`) | DD-7 **6 failures** |
| M3 | the config-time column refusal removed; only the type forbids it | DD-7 **8 failures** |
| M4 | `ct_dropped_column_awareness()` returns a printed constant instead of the writer's signal | DD-7 **4 failures** |

**And the HANG mutations found a defect in my own preconditions — twice, the second one caused by
the fix for the first.** This is the campaign's most valuable kind of finding and it is worth the
detail:

- **M5/M6 (the arms driver never exits; `ct_ingest` spins inside wasm).** The bound fired and the
  check went red — but with **27 assertions named "the roundtrip arm wrote a container — missing
  file"** and **"ct-print reads the container — expected 0, got 1"**. Every one reads like a
  discovery about the writer and none of them is: the run TIMED OUT. Cause: `ARMS="$(m24_require_arms)"`
  runs the precondition in a **command substitution**, so its `die` exited the *subshell* and the
  check carried on with an empty `$ARMS`. That is M9's shape exactly — "a check that can produce
  32 red assertions from one truncated pipe will eventually be believed" — in a precondition
  written to prevent it.
- **The first fix reintroduced the silence it was fixing.** Keeping the `printf` and writing
  `m24_require_arms >/dev/null` means the redirection is still in effect when `die` calls `exit`,
  so **the EXIT trap's summary line went to `/dev/null`** and the check reported
  `<NO SUMMARY LINE AT ALL>` — the exact shape M22 built the trap for. The preconditions now set
  globals and **print nothing**, so they cannot be redirected into silence.

**One standing rule was broken and is recorded rather than glossed:** I edited
`verification/lib_m24_ct_writer.sh` and four checks **while a mutation run was reading them**. The
run was killed, every mutated source restored from the harness's own backup and verified by
`grep -c MUTATION` returning 0 on all six, the module rebuilt from clean sources, and the batch
re-run from scratch.

### The ninth defect, and it is the one the brief warned about in those exact words

**A MUTATED ARTEFACT OUTLIVED ITS RESTORED SOURCE.** `cp -p` preserves mtime; cargo's fingerprint
is mtime-based. So restoring `ct-writer/src/lib.rs` from the mutation backup put the *original*
timestamp back, cargo said "Finished in 0.06s", and `ct_writer.wasm` **kept M6's infinite-spin
`ct_ingest` while `grep -c MUTATION` was 0 on every source file**.

Everything downstream then hung, and it hung *quietly*, which is the shape that matters:

- the arms driver ran for five minutes at 99% CPU instead of two seconds;
- `just verify-m24` sat on its second check for twenty minutes;
- and a **"build reproducibility" measurement recorded the mutated artefact's size and hash as the
  clean build's** — I wrote "two consecutive clean builds are byte-identical at 245,724 bytes"
  into `TRACE-ABI.md` and into this log, and 245,724 was *M6's binary*.

The campaign brief names this exact shape in one line — *"A mutated artefact outlived its restored
source"* — and I read it this morning and still met it. Three fixes, in the harness rather than in
a note: `restore()` now `touch`es what it restores, deletes the derived `ct.json`, and the final
teardown does `rm -rf ct-writer/target` before its `--force` rebuild.

**The corrected number:** the clean build is **246,527 bytes, sha256 `75626c72…`**, and a full
arms run takes **2.4 s**. `TRACE-ABI.md` §7 now says so, and says what the earlier figure was.

### The tenth: the benchmark was measured on a DIFFERENT ENGINE from the one the check runs in

`verify_trace_event_abi_batched_faster` went red with **15 failures**, every one of them of the
form "TRACE-ABI.md quotes `batched`'s measured median (539,444)" — the check re-measured, the
document disagreed, and it said so. **That is the check working**, and it is exactly what
"the document is compared against the data, not read" was written for.

Two causes, and the second is the interesting one:

1. The module was rebuilt (the mutated artefact above), so `m24_require_oq6` correctly treated
   `arms.tsv` as stale and re-measured. Fine.
2. **The re-measurement ran inside `nix develop` and the first one did not.** Measured:

   ```
   system node   v25.9.0     <- the first OQ-6 run, and the numbers TRACE-ABI.md carried
   dev-shell node v24.19.0   <- what every check runs under, and what CI would run
   ```

   This is M19's review's finding in a different guise — *"a check that compiles must pin its
   PATH, not only its toolchain and its flags"* — and it points the same way: **the authoritative
   measurement is the dev-shell one**, because that is the engine the checks and CI use. The
   system-node numbers are not wrong, they are about a different V8.

So OQ-6 is being re-measured inside the dev shell, on a box waited for until its load average
dropped below 1, and `TRACE-ABI.md` §2 will be rewritten from the comparator's own output. The
node version and the V8 build are already carried in the table's `#CONFIG` line and asserted by
the check, which is why the engine mismatch reddened rather than passing silently.

### The eleventh and twelfth, and OQ-6's real finding

**Two more instances of the redirection family, and the second was the fix for the first.**

- `m24_require_arms >/dev/null` — the redirection is still in effect when `die` calls `exit`, so
  the EXIT trap's **stdout** half (the `N assertion(s), M failure(s)` line) went to `/dev/null`
  while its stderr half survived. The M5 hang mutation reported `<NO SUMMARY LINE AT ALL>`.
  Preconditions now set globals and print nothing.
- `m24_require_bounded … >/dev/null || die` — **the same thing one level deeper**, because the
  redirection binds to the *function call*. The M6 wasm-spin mutation reported
  `FAIL — exited (status 1) before finish` with the assertion line missing. A bounded run that
  wants its subprocess quiet now redirects **the subprocess** (`timeout … "$@" >"$log" 2>&1`), and
  the log is named in the diagnostic — strictly better than `/dev/null`, because a driver that
  failed for a reason now has somewhere to have said so.

After both fixes, **all three hang mutations produce `0 assertion(s), 1 failure(s)`** with a named
diagnostic naming the command and the bound. That is the answer to "make a check hang".

**And OQ-6's real finding, which took four runs to see.**

| run | engine | `perEvent − batched` | 95 % interval | control | crossing |
|---|---|---|---|---|---|
| 1 | node v25.9.0 / V8 14.1 (system) | +0.20 % | [−0.40, +0.81] | +0.08 % | ~5.6 ns |
| 2 | node v24.19.0 / V8 13.6 (dev shell) | +1.09 % | [+0.79, +1.39] | +0.16 % | ~3.2 ns |
| 3 | node v24.19.0 / V8 13.6 (dev shell) | −0.58 % | [−1.13, −0.03] | −0.01 % | ~2.7 ns |
| 4 | node v24.19.0 / V8 13.6 (dev shell) | −0.09 % | [−0.68, +0.51] | +0.26 % | ~3.0 ns |

**Runs 2, 3 and 4 are the same engine, the same module and the same binary**, and runs 2 and 3
have *disjoint intervals with opposite signs*. Had I stopped at run 2 I would have written "the
batched ABI is reliably about one per cent faster" into a document, with a 95 % interval to back
it — and it would have been wrong in the way `_timing_compare.py`'s header already describes:
*"six runs of the same measurement over the same two binaries produced mutually disjoint 95 %
intervals"*. The session is the unit of replication *within* a run and nothing balances the drift
*between* runs.

The control behaved in all four (+0.08, +0.16, −0.01, +0.26 %), so the instrument is calibrated
and the subject is what moves. The crossing-only pair is stable and positive in all four
(+16.50, +6.98, +6.07, +6.65 %) at 2.7–5.6 ns per crossing — **0.05–0.11 % of a recording**.

Three of those four runs happened because the staleness test was **mtime-based**: the benchmark's
output *is* a measurement, `TRACE-ABI.md` is asserted to quote it, and every rebuild — including
byte-identical ones — re-ran twelve minutes of benchmark and made the document stale for a reason
that had nothing to do with the tree. It is content-hashed now.

## Step 10 — the sweep (RUNNING)

`~/.cache/aztec-m24-sweep/sweep.sh`, M0–M24, `setsid`-detached, one milestone at a time, in M23's
review's order with m24 inserted after m1. `TMPDIR` and the log both under `~/.cache`.
Interim, matching the references exactly:

```
m0  156   m1 169   m22 260   m23 509        <- all at their reference values
m24 292   (new)    split 49/46/39/37/30/91
```

## Step 11 — the mutation matrix, complete

Thirteen mutations. Every one detected; **no mutation passed a check green.**

| id | what was broken | check | result |
|---|---|---|---|
| M1 | `emit()` writes 4 variables per step, not 5 — *the container still reads* | roundtrip / backpressure | **2 / 1 failures** |
| M2 | the DD-7 identity gate becomes a **TypeScript-only** guarantee | DD-7 | **6 failures** |
| M3 | the config-time column refusal removed; only the type forbids it | DD-7 | **8 failures** |
| M4 | `ct_dropped_column_awareness()` returns a printed constant | DD-7 | **4 failures** |
| M5 | **HANG**: the arms driver never exits | roundtrip / backpressure | **0 assertions, 1 failure**, named |
| M6 | **HANG IN WASM**: `ct_ingest` spins, no signal handler, no unwind | roundtrip | **0 assertions, 1 failure**, named |
| M7 | the host stops flushing until close | backpressure | **0 assertions, 1 failure**, named |
| M8 | a second path to `codetracer_trace_types` in the real manifest | single-instantiation | detected (cargo refuses / E0308) |
| M9 | the OQ-6 comparator can only ever say `within-noise` | OQ-6 | detected by the fabricated-table controls |
| M11 | the per-event ABI silently drops every other event | roundtrip | **2 failures** (equivalence) |
| M12 | the module declares one wasm import | zero-imports | **0 assertions, 1 failure**, named |
| M13 | the module's record size drifts from the host's | zero-imports | **1 failure**, at 49 assertions |

The three named requirements are covered: a mutation that would have passed silently (**M1** —
the container still reads and every count still looks plausible), a mutation that makes a check
**hang** (**M5**, **M6**, and **M7** by consequence), and a mutation that bypasses a
**TypeScript-only guarantee** (**M2**, with **M3** as its value-check sibling).

**The hang mutations are the ones that paid.** They found three defects in the preconditions
themselves — a `die` in a command substitution, a `die` under `>/dev/null`, and a `die` under a
`>/dev/null` one level deeper — and each one turned a hang into either 27 misattributed red
assertions or a missing summary line. All three are fixed and all three re-mutations now produce
one named failure.

## Step 12 — the sweep, M0–M24

`~/.cache/aztec-m24-sweep/sweep.sh`, `setsid`-detached, one milestone at a time, nothing else
running, `TMPDIR` and the log under `~/.cache`. Order: `m0 m1 m24 m22 m23 m18 m20 m21 m2 m17 m13
m16 m19 m10 m12 m11 m14 m15 m3 m4 m5 m6 m7 m8 m9`.

Named checks, all at their reference values:

```
check-repo-hygiene              28   (reference 28)
verify_provenance_complete      58   (reference 58)
check-drift                     22   (reference 22, as a NOTE inside verify_vendor_drift_clean)
verify_named_checks_exist        9   (reference  9, with ct-host/src added to its scanned roots)
verify_pinned_nightly_single_source 28  (two new anchors moved nothing: it asserts `>= 3`)
verify_reuse_inventory_complete 19   (RI-42's confidence reasoned -> settled moved nothing)
verify_orchestration_reuse_enumerated 66
```

### The sweep, complete

**8,703 assertions, ZERO failures, every milestone exit 0, no hole in the log.**

```
m0 156  m1 169  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 324  m22 260  m23 509  m24 292        TOTAL 8,703
```

**Every one of M0–M23 came out at its reference value TO THE ASSERTION.** 8,411 + 292 = 8,703
exactly, so M24 moved exactly one number and it moved it in the direction it should. M9 reproduced
its 140/143/113/73/126/83/129 split in 1,294 s.

Three changes M24 made to shared machinery were checked for movement in advance and moved nothing:

| change | why it moves nothing | measured |
|---|---|---|
| two new `pins.json` anchors | `verify_pinned_nightly_single_source` asserts `>= 3` on the anchor count, not `==` | 28, unchanged |
| `ct-host/src` added to `verify_named_checks_exist`'s roots | every assertion there is an `assert_ge` or an emptiness comparison | 9, unchanged |
| RI-42 `confidence: reasoned` → `settled` | `verify_reuse_inventory_complete` is `assert_ge`/`assert_contains` throughout | 19, unchanged |

`CAMPAIGN-BRIEF.md`'s reference block is updated to M0–M24 = 8,703 with that accounting written
into it, so the next milestone compares against a measured figure rather than a remembered one.

## Step 13 — DONE. Tree quiescent, no commits, no pushes.

Re-confirmed **after** the last document edit, because a sweep is a measurement of the tree at the
moment it ran and M24's own section, `CAMPAIGN-BRIEF.md` and the milestones file were edited after
the sweep finished:

```
just verify-m24                  292 assertions, 6/6, exit 0
just verify-m16                  223 assertions (it is the one check that READS the milestones file)
just check-repo-hygiene           28 assertions
verify_named_checks_exist          9 assertions
```

`git status` in both repositories shows only intended changes and nothing untracked that looks
like a build artefact. **No commit, no push** — the review agent commits.

### What is left for the review

- The six verification entries all pass; the milestone is `completed` with seven outstanding
  tasks recorded, none of which is a gap in what M24 claims.
- The one thing worth a reviewer's scepticism is **§4's secondary criterion**, because it is a
  *precautionary* argument about an engine nobody has measured. The number that would falsify it
  is a browser crossing cost, and M28 is where it gets taken.
- The OQ-6 benchmark is not deterministic. Re-measuring will produce a different number and
  `verify_trace_event_abi_batched_faster` will say so; re-render `TRACE-ABI.md` with
  `scratchpad/campaign/m24-render-trace-abi.py` rather than hand-editing figures.
