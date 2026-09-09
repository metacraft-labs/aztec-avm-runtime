# M41 — The Runtime Writes Through the Nim Writer — implementation log

Started 2026-09-02.

## Step 0 — reading, and the pre-flight measurements

- Read the M41 section of `codetracer-specs/Planned-Work/Aztec-AVM-Runtime.milestones.org`
  (lines 16072-16194).
- Read `CAMPAIGN-BRIEF.md` in full (2,933 lines) except the sweep-history block 2249-2580,
  which is the same shape as the blocks either side of it.
- Read `JOIN-SHAPE.md`, `ct-host/src/abi.ts`, `pins.json`,
  `tracing-formats-benchmarks/results/wasm_writer/REPORT.md` §5, §9, §10.

### The ABI is 38, counted rather than trusted

Both numbers in circulation were checked against the artefacts:

- `ct-writer/src/lib.rs` declares **38** `#[unsafe(no_mangle)]` functions.
  `grep -c 'pub extern "C" fn'` gives **26**, which is where the wrong number comes from:
  twelve of the thirty-eight are `pub unsafe extern "C" fn` and that needle cannot see them.
- `ct-host/src/abi.ts`'s four lists are 19 + 11 + 6 + 2 = **38**, all distinct.
- The two sets are **equal**: zero names only in Rust, zero only in TypeScript.
- The built module exports **39** = 38 + `memory` (before the compressor change; see below).

### `wasm/webpage` publication, BEFORE any work

`noir-wt4-webpage` HEAD `f0e7edcd20dc667f789827563e2b2c780b368552`, branch `wasm/webpage`:
`git for-each-ref refs/remotes --contains <head>` is **0**, and `git ls-remote origin
'refs/heads/wasm/webpage'` returns **0** rows. One uncommitted edit
(`tooling/tracer/src/tracer_glue.rs`), which is the state `JOIN-SHAPE.md` §6 declares deliberate.

### Shared branch

`origin/dev` had moved two commits (`6d6312e`, `4699d4c`, both L-track browser work).
Fast-forwarded before starting; no local commits to rebase.

---

## Step 1 — Path A's compressor, fixed upstream FIRST

**Landed and published:** `codetracer-trace-format` `c8802c548f201ec8c9c9b6e07ea1f112e625b893`
on `origin/wasm/ctfs-writer` (was `592fa42cbf`). Verified reachable from a `refs/remotes` ref
after the push, before anything pins it.

### What the change is, and why it is a feature rather than a `--cfg`

`REPORT.md` §9.10 specifies the change and notes that the bare `--cfg ct_pure_rust_zstd` the
benchmark used is not the right upstream mechanism. Taken as **two cargo features on
`codetracer_ctfs`, forwarded by `codetracer_trace_writer`**:

    [features]
    default = ["c-zstd"]
    c-zstd = ["dep:zstd"]
    pure-rust-zstd = ["dep:ruzstd"]

- The choice is expressible in a dependent's manifest and visible in `cargo tree`, which is what
  §9.10's note asks for.
- `codetracer_trace_writer` takes `codetracer_ctfs` with `default-features = false` so the
  opt-out really opts out. **This was not cosmetic** — see the 425-byte residual below.
- Neither feature is a compile error naming both, rather than an unresolved-crate error inside
  the module whose subject is which crate is in use.
- Precedence when both are on (pure-Rust wins) is declared in `Cargo.toml`, not left for a
  reader to derive from `cfg` polarity.

`zeekstd` is **narrowed, not featurised**: it genuinely needs a libc, so its gate goes from all
of `wasm32` to `wasm32-unknown-unknown` alone, and `wasm32-wasip1` links the real seekable
encoder instead of the stub. Both refusal messages now name the target and the reason, in the
message a developer reads as well as in the comment.

### How the runtime supplies `CC_<target>`/`CFLAGS_<target>`

Cargo cannot state the requirement, so the build script must. The runtime's own dev shell
already ships **wasi-sdk 33 (clang 22.1.0)** and exports `WASI_SDK_PATH`, so:

    CC_wasm32_unknown_unknown="$WASI_SDK_PATH/bin/clang"
    AR_wasm32_unknown_unknown="$WASI_SDK_PATH/bin/llvm-ar"
    CFLAGS_wasm32_unknown_unknown="--target=wasm32-unknown-unknown"

No sysroot and no wasi-libc include path: `zstd-sys`'s own `wasm-shim/` is what the build script
turns on for this triple. Confirmed by building.

### The backend is asserted by behaviour, not by reading the feature back

libzstd honours a compression level; `ruzstd` implements `Fastest` and nothing else. So each arm
carries a test that fails if the other one answered:
`libzstd_is_selected_and_honours_the_level` asserts `len(level 1) != len(level 19)`, and
`the_pure_rust_backend_is_selected_and_ignores_the_level` asserts the two are equal.

**Mutation arm, run:** making the libzstd arm ignore its level (`zstd::encode_all(…, 3)` with
`_level`) gives `FAILED. 2 passed; 1 failed`, on exactly that assertion, with the message naming
the cause — `levels 1 and 19 produced the same 18795 bytes`. Restored, `3 passed; 0 failed`.

`zstd_frame`'s tests read a frame's pledge with `zstd::zstd_safe::get_frame_content_size` —
libzstd answering about a frame this crate produced. Behind the backend feature that oracle
would vanish from the one build whose frames are patched by hand, which is this campaign's
"a conditional assertion block is a skipped test wearing an `if`". It is an **unconditional
dev-dependency** now, so it is linked in every feature combination and absent from `cargo build`.

### Test results

| invocation | passed | failed |
|---|---:|---:|
| `-p codetracer_ctfs -p codetracer_trace_writer` (default) | 154 | 0 |
| same, `--features pure-rust-zstd` | 154 | 0 |
| same, `--no-default-features --features pure-rust-zstd` | 154 | 0 |
| `--workspace --exclude codetracer_trace_writer_nim`, **after** | **321** | 0 |
| `--workspace --exclude codetracer_trace_writer_nim`, at HEAD **before** | **320** | 0 |

`delta +1`, and the one is the backend discriminator. The nim crate is excluded because
`nimble` is not on this PATH — the condition `CAMPAIGN-BRIEF.md` already records, with
`CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL=1` as its escape — and the exclusion is applied
to **both** sides so it cannot hide a regression.

### What it costs the runtime's module — measured, in the runtime's own harness

Built in `~/.cache/aztec-m41-spike` from the runtime's own `ct-writer/src` and `Cargo.toml`
against a copy of the changed trace-format tree, in this repository's dev shell:

| arm | bytes | exports | imports |
|---|---:|---:|---:|
| Path A as shipped, on disk today (`592fa42`, ruzstd) | 263,211 | 39 | 0 |
| Path A, HEAD tree rebuilt in this harness (the baseline) | 263,201 | 39 | 0 |
| Path A, changed tree, `pure-rust-zstd` opt-out | 263,321 | 39 | 0 |
| **Path A, changed tree, default `c-zstd`** | **497,630** | **47** | **0** |

Every unit accounted for in both directions:

- **263,211 vs 263,201 = 10.** The harness rebuild differs from the on-disk artefact by ten
  bytes; both are the same revision, the difference is the build location. Stated rather than
  rounded away.
- **263,321 − 263,201 = +120, and it is entirely the two lengthened `Cbor` refusal messages.**
  Derived twice, independently: reverting only those two strings in the spike copy moved the
  opt-out arm 262,896 → 262,776 in one configuration, and the arithmetic gives the same 120 in
  the other. So the opt-out arm reproduces the shipped module up to the two strings I lengthened,
  which is the control that says the change is inert for anyone who declines it.
- **An earlier reading of the opt-out arm was 425 bytes SMALLER than the baseline, and that was
  a defect in my own manifest, not noise.** Without `default-features = false` on the writer's
  `codetracer_ctfs` dependency, feature unification made the opt-out arm a different build from
  the one it claims to be. Fixing it moved 262,896 → 263,321 and closed the residual to the 120
  above. *A number that does not come out is a finding.*
- **497,630 − 263,201 = +234,429 bytes, and 47 − 39 = 8 exports.** The eight are
  `rust_zstd_wasm_shim_{malloc,calloc,free,memcmp,memcpy,memmove,memset,qsort}`, which is
  `zstd-sys`'s shim re-exporting what Rust's allocator resolved. **Imports stay at 0** on every
  arm, so the "no import cost" claim holds in the runtime's own module and not only in the
  benchmark's.

### So what is the honest size comparison M41 was told to establish?

The milestone's premise was that a Nim-backed module at ~463 K reads as a **1.76×** regression
against 263,211 *only because Path A is compressing badly*. Re-derived here, with Path A's
compressor fixed:

> **Path A with C libzstd is 497,630 bytes. The Nim-backed Rust `cdylib` the milestone records
> is 463,066.** The Nim module is **34,564 bytes SMALLER**, not 1.76× larger.

The regression the milestone was braced for does not exist once both sides use the same
compressor. What does exist, and is a decision rather than a defect, is that **fixing Path A's
compressor costs the runtime +234,429 bytes of module** in exchange for the throughput and
container gains — so "swap the compressor" and "switch to Path B" are not independent choices,
and the seam has to carry all three configurations rather than two.

*(The 463,066 figure is the milestone's, taken from a prior measurement; it is the one number in
this section I have not yet re-derived. Flagged rather than quoted as mine.)*

---

## Step 2 — the upstream FFI in-memory constructors

**Landed and published:** `codetracer-trace-format-nim`
`00b3512ec58b5763484ecbc37028ebf3aee50168` on `origin/wasm/nim-to-wasm`
(was `c8780e1`). Verified reachable from a `refs/remotes` ref after the push.

**The `trace_format_nim` ANCHOR DID NOT MOVE.** It names the commit `baea074019`, not
the branch, so pushing the branch tip forward leaves the pin exactly where M24 put it and
`test_ct_container_roundtrip_ct_print`'s reader difference stays at one commit. `pins.json`'s
`branch_tip_at_pin` field is historical by definition and was left alone.

### What was actually missing, which is narrower than the milestone says

The milestone records that the FFI's C ABI "is file-based with no in-memory constructor". Read
against the code, the layer BELOW was already in memory:

- `initMultiStreamWriter` builds on `createCtfs()` and keeps its `path` argument only as
  `filePath` metadata — the multi-stream writer never touched the filesystem at all.
- `newTraceWriterInMemory` (added by `bc6cb98`, already published) is the single-stream sibling.

What was missing was a way to reach either from C, and a way to get the bytes back.
`trace_writer_begin_events` derives a `.ct` path from an events path, and
`trace_writer_close` opens that path — those two, not the writer, are the filesystem.

### Four entry points, 125 -> 129 `exportc` functions

    trace_writer_begin_in_memory   instead of trace_writer_begin_events
    trace_writer_container_ready   1 once close has retained a container
    trace_writer_container_len     its length
    trace_writer_container_ptr     its bytes, owned by the handle

`ready` exists because an empty container is a legitimate result, so a zero LENGTH cannot stand
in for "not finished yet". The bytes are copied into the handle BEFORE `closeCtfs` releases the
writer's storage, so the pointer cannot dangle.

### Two things the test established rather than assumed

1. **A container's LENGTH cannot tell two traces apart.** The first draft asserted that the
   in-memory and file arms produce equal-length containers; the mutation control — one extra
   step — refuted it: **all three arms are 131,072 bytes**, because CTFS allocates in blocks.
   A length comparison would have passed for two demonstrably different traces. The comparison
   is over the DECODED step stream now, read back through this repository's own reader, and the
   length is a reported note that says why.
2. **The mutual-exclusion refusal was half-implemented.** `trace_writer_begin_in_memory` refused
   a writer already open on a file; `trace_writer_begin_events` accepted one already open in
   memory, because both `begin`s are idempotent no-ops on a ready writer. Found by asking for the
   refusal in the second order. Both refuse by name now.

### Controls and mutation arms, run

- **Positive control for "no file appeared":** the file arm, driven with the same events, into a
  directory the test enumerates. Without it the absence is equally true of a directory nothing
  ever wrote to — this campaign's second-most-repeated defect.
- **Mutation arm, narrowed:** the first attempt broke two things at once and reddened on the
  `ready` flag, which is "a mutation that crashes has not exercised the assertion it was written
  for". Re-cut so the bytes are STILL retained and the only change is that the in-memory arm also
  leaves a file: the run reports
  `the in-memory arm wrote @["leaked.ct"] into a directory it was given only so this assertion
  could be made` — the assertion written for it, and only it. Restored; green.
- `test_line_only_orphan_carry_forward`, `test_orphan_call_args_step_location`,
  `test_io_event_pending_step_attribution` and `test_ffi_in_memory` all PASS.
- The static library still builds and `tests/test_ffi.c` still passes end to end.
- The new test is wired into the nimble `test` task, so it is a check the suite runs rather than
  one a document claims.

---

## Step 3 — the feasibility question deliverable 3 rests on, measured

The milestone plans a `build.rs` in `ct-writer` that runs `nim c` to wasm and links the result.
Nothing had established whether the FFI — the thing that would have to serve the 38 ABI
functions — can be built for a freestanding target at all. It can, with one blocker, and the
blocker is not where the milestone's framing suggests.

### The writer half is freestanding-clean; the READER half is the only blocker

`nim c --compileOnly --os:any --cpu:wasm32 --mm:arc -d:useMalloc --noMain -d:ctHostClock
-d:ctLeanRecord` over `src/codetracer_trace_writer_ffi.nim` stops at exactly one place:

    src/codetracer_trace_writer/new_trace_reader.nim(390, 10) Error: undeclared identifier: 'fileExists'

With the `ct_reader_*` / `ct_meta_dat_*` entry points and the `TraceReaderHandle` alias removed
in a **scratch copy** (75 of 129 `exportc` functions remain — the whole writer surface),
the compile is **exit 0, 56 C files emitted**. Nothing else in the module graph objects.

*This is a probe, not a proposed change, and nothing was committed for it.* What it settles is
that the upstream work deliverable 3 needs is a **filesystem gate on the reader half**, which is
small and local, rather than a rewrite of the writer.

### And it LINKS, and the module instantiates

Linked with the existing `host_stub.o` / `trace_writer_host_stub.o`, the cross-built
`libzstd.a` and compiler-rt, plus a two-symbol probe stub for `fopen`/`setvbuf` (both of which
REFUSE rather than pretend, so the probe cannot answer a different question than it asked):

> **722,115 bytes, ZERO imports, 20 exports** (19 requested + `memory`), and it **instantiates in
> node against a literal `{}`** with `codetracerTraceWriterNimMain()` running without trapping.

### What that does to the size comparison — and it is not what the milestone expects

| module (`wasm32-unknown-unknown`, 0 imports throughout) | bytes |
|---|---:|
| Path A, ruzstd — as this runtime ships today | 263,201 |
| Path A, C libzstd — after the compressor fix | 497,630 |
| Path B, the single-stream standalone shape — the milestone's figure | 463,066 |
| **Path B, the FULL FFI writer half — measured here** | **722,115** |

**The 463,066 the milestone plans against is a lower bound taken on a writer that cannot serve
the ABI.** `newTraceWriterInMemory` is the SINGLE-stream `TraceWriter`; the 38 ABI functions need
the MULTI-stream surface — steps with columns, values, calls, path interning, rungs, log events —
which is `initMultiStreamWriter` and everything under it. The shape that can serve the ABI
measures 722,115 bytes as it stands.

That does not settle the decision against Path B, and I am not claiming it does: the reader was
cut crudely rather than gated, `std/json` and `std/tables` are in the link and may be reachable
only from paths a gate would remove, and nothing has been dead-strip-tuned. It does mean **the
size comparison M41 was about to settle is not settled by the numbers M41 has**, and the figure
to re-derive after the reader gate is this one and not 463,066.

*The missing `malloc` export is a probe artefact, not a design problem: the shipping shape is a
Rust `cdylib` linking the Nim writer as a static library, where both sides share one linear
memory and pointers come from Rust's allocator.*

---

## What is NOT done, stated plainly

Of the six deliverables, two are landed and published and four are not started:

- [x] In-memory constructors upstream in `codetracer-trace-format-nim`, published — `00b3512`.
- [ ] A `build.rs` in `ct-writer`. **Blocked on the reader gate above**, which is now a measured
      and bounded piece of upstream work rather than an unknown.
- [ ] All 38 ABI functions served, or each unserved one named. The set is verified at 38 and the
      Rust and TypeScript sides are verified equal; none is served through Path B yet.
- [ ] A real seam with `ct_writer_kind()`. **The compressor fix makes this a THREE-way seam, not
      a two-way one** — Path A/ruzstd, Path A/C-libzstd and Path B are three configurations with
      three different sizes and two different container encodings, and `ct_writer_kind()`'s single
      `WRITER_KIND_PATH_A_PURE_RUST = 1` cannot name them.
- [ ] `pins.json` writer role. Not added. **The `trace_format` anchor now WANTS to move** to
      `c8802c5` for the compressor fix; that is a separate decision from adding a writer role and
      I have not taken either.
- [ ] Container equivalence characterised stream by stream. Not done.

Not run: the five M41 verification checks (they do not exist), and the full 41-milestone sweep.
**No sweep was taken, so no campaign total is claimed.** The reference stands at 13,374.

`wasm/webpage` re-checked after all work: HEAD `f0e7edcd20`, **0** published refs containing it,
**0** `refs/heads/wasm/webpage` rows on the remote — unchanged from the pre-flight reading.
`JOIN-SHAPE.md` line 171 is **not** edited, because the switch has not landed and the milestone
says to update the framing only once it has.

---

# Session 2 — 2026-09-09/10: the seam, and what building it found

The four deliverables Step 3 left open are done, and one of them turned out to be a decision
rather than a build. Everything below was re-derived in this session; nothing is carried over from
Session 1's numbers, which were taken on a spike harness rather than on the shipped crate.

## What landed

- **`ct-writer` has a seam.** `backend.rs` declares `CtWriterBackend` — eighteen methods, the exact
  set `lib.rs` used to call on `CtfsTraceWriter` — with `backend_rust.rs` and `backend_nim.rs`
  behind `path-a` (default) and `path-b`. Nothing outside those two files names a concrete writer.
  `ct_writer_kind()` answers `ActiveBackend::kind()`.
- **`ct-writer/build.rs`**, running only under `path-b`: materialise from the object store,
  cross-build libzstd, `nim c --compileOnly`, compile the emitted C with the commands NIM wrote,
  archive, link. **Byte-identical across two from-scratch rebuilds**, twice.
- **`pins.json` gained `trace_format_nim_writer`** at `0638684686` and `toolchain.nim` at 2.2.4.
  The reader anchor did NOT move.
- **Seven checks, 164 assertions, 0 failures**, all seven with controls and both mutation
  directions.

## The upstream commit, and why it was needed

`0638684686 feat(ffi): let a caller pin the recording identity`, on `origin/dev`. Without it a
Path B module mints its recording id inside the sandbox, from host stubs, and every container a
page produced would carry the same identity. `nim_host_shim.c`'s `getentropy` REFUSES rather than
filling a constant, precisely so that outcome is unreachable; the setter is how the host supplies
the real one instead. Three mutation arms run, each reddening on its own assertion.

That repo was dirty with another agent's work on five files under
`src/codetracer_trace_writer/`. My change is in `codetracer_trace_writer_ffi.nim` and one new
test, both untouched by them; the commit named its paths explicitly and the push was a
fast-forward. `test_reader_ffi` is red in that repo at `8cfb1bb` and identically red at my commit
— pre-existing, verified in a clean worktree at HEAD before I started.

## Two defects this work found, both silent

1. **Every column one too high.** The Nim ABI's `register_delta_column` takes a delta from a step
   that already sits at column 1; the backend passed the column itself. The container had exactly
   the right number of steps, all readable, all one column to the right. No reader can object to
   that. Found by comparing positions read back against positions ASKED FOR, and by nothing else.
2. **`report.eventsWritten` was 0 in every run of every module, and two arms both reporting 0
   AGREE.** `ct_events_written()` answers from the session and `ct_writer_close()` takes the
   session apart, so the driver read it after the close. The equivalence check's "the two
   containers agree on eventsWritten" passed while measuring nothing. Now read before the close;
   both arms report 7.

## The finding that changed the milestone's shape

**Neither of the two pinned readers reads both writers' containers.** The reader anchor
(2026-08-20) reads Path A's and MISREADS Path B's without refusing — empty program, every
capability flag false, counts −1. The reader at the writer anchor (2026-09-09) reads Path B's
completely and REFUSES Path A's by name over `meta.dat` schema version 3 versus 4.

So flipping the default is not a `Cargo.toml` edit; it is a decision about the reader anchor,
which `pins.json` deliberately holds at a commit so `test_ct_container_roundtrip_ct_print`'s
difference stays at one. M41 was told not to move it. **The default therefore stays Path A**, and
`WRITER-SEAM.md` §6 says so with the measurement rather than leaving it to be rediscovered.

## Figures, all re-derived

| | Path A | Path B |
|---|---:|---:|
| module bytes | 264,281 | 771,318 |
| imports / exports | 0 / 39 | 0 / 39 |
| container from the shared driver | 176,128 | 143,360 |

The seam cost Path A **+753 bytes** (263,528 -> 264,281, measured against a build of HEAD in this
same environment). A separate **+317** had already accumulated between the figure `TRACE-ABI.md`
§7 recorded and a HEAD build here, with no source change under `ct-writer/` — toolchain drift,
stated separately rather than folded in.

Path B is **507,037 bytes larger** than Path A as shipped. Stated without a comparison to any
other module shape: seven distinct shapes have been measured in this campaign and lining up the
wrong two reads as a regression that does not exist.
