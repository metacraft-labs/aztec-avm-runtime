# The Path A / Path B writer seam — M41, measured

*Every figure here was re-derived on the artefact it describes. Nothing is quoted from a prior
milestone's prose.*

---

## 1. What M41 changed, in one line each

| | before | after |
|---|---|---|
| the seam | none — no `[features]`, no `cfg`, `CtfsTraceWriter` named at the type level in two places | `ct-writer` has `path-a` (default) and `path-b`, and nothing outside `backend_*.rs` names a concrete writer |
| `ct_writer_kind()` | a literal `1` | `ActiveBackend::kind()` — the two builds disagree, which is what makes it a measurement |
| the writer's source | one crate from `pins.json`'s `trace_format` anchor | that, plus Nim source from a NEW `trace_format_nim_writer` anchor, materialised and cross-compiled by `ct-writer/build.rs` |
| the ABI | thirty-eight functions | thirty-eight functions, unchanged, served by both backends |

**The default is still Path A.** That is a decision this milestone took on measurement rather than
a shortfall — §6 says which measurement and what would change it.

---

## 2. The two modules, as built

| | Path A | Path B |
|---|---:|---:|
| bytes | **264,281** | **745,114** |
| sha256 (first 16) | `5d661d3c3e6a7ba0` | `ae2b0c7e9c50c796` |
| wasm imports | **0** | **0** |
| exports | **39** = the 38 ABI functions + `memory` | **39**, the same set |
| instantiates against a literal `{}` | yes | yes |
| container from the shared driver | 176,128 bytes | 143,360 bytes |
| `ct_writer_kind()` | 1 | 2 |

**The size figure is stated without a comparison, deliberately.** Seven distinct module shapes have
been measured across this campaign — WASI command, library-shaped standalone, single-stream, full
FFI, Rust-only with `ruzstd`, Rust-only with C libzstd, and this one — and lining up the wrong two
reads as a regression that does not exist. What the row above compares is the ONLY pair that is
comparable: two builds of ONE crate, on one target, differing in one feature flag.

Path B is **480,833 bytes larger** than Path A as the runtime ships today. That is the honest
number and it is a cost, not an artefact: Path A links `ruzstd`, Path B links a cross-built C
libzstd (537,888 bytes of `libzstd.a`) plus the Nim writer (1,262,700 bytes of
`libct_nim_writer.a`) before `--gc-sections`. What Path B buys for it is §5 and §6.

**No host symbols leak.** The libc surface the Nim C output needs — `malloc`, `free`, `calloc`,
`realloc`, `strlen`, `exit`, the refusing stdio, `getentropy`, `ct_host_unix_ms` — lives in
`ct-writer/src/nim_host_shim.c` and is linked from a static ARCHIVE, which the linker resolves
without exporting. A Rust implementation would have exported every one of them: `#[no_mangle]`
makes rustc pass an explicit `--export` per symbol, and a page could then call `free` on an address
of its choosing. Measured: 39 exports, not 65.

**One heap, not two.** The shim reaches Rust's allocator through function pointers bound before the
first Nim call, rather than carrying a bump allocator of its own. A bump allocator is what the
trace-format repository's freestanding build uses, and it is right there: that build produces one
container and exits. This module is a long-lived browser object that opens and closes a writer per
transaction, and a `free` that does nothing turns every transaction into a permanent cost.

---

## 3. The build, and whether it is reproducible

`ct-writer/build.rs` runs only under `path-b`. Under the default feature set it returns immediately,
so a `cargo build` of the shipped configuration is unchanged by its existence.

1. **Materialise** `codetracer-trace-format-nim` at `pins.json`'s `trace_format_nim_writer` commit,
   with `git archive` out of the OBJECT STORE. Never out of the sibling worktree: that tree is
   moved and edited by other work, and copying from it picks up whatever it currently holds.
   Extracted with `tar -x -m` so a revision change always invalidates — `build_ct_writer_wasm.sh`
   records the measurement that established this on the Rust half.
2. **Cross-build libzstd** for `wasm32-unknown-unknown`. `zstd_bindings.nim` carries an
   unconditional `{.passL: "-lzstd".}`.
3. **`nim c --compileOnly`**, then compile the emitted C **using the commands nim itself wrote into
   its build plan**. Re-deriving the flags here would mean maintaining a second copy of the
   compiler's own flag set, and the two would diverge on the first `nim.cfg` change upstream.
4. **Archive** and emit the link directives.

**Reproducible: measured, twice.** Deleting the materialised tree, its stamp and the whole target
directory and rebuilding from scratch produced a **byte-identical module**
(`ae2b0c7e9c50c796…`) both times.

**Pinned, and pinned two different ways because the two are different problems.**

- Everything from nixpkgs — clang, llvm-ar, lld, the wasi-libc headers, the zstd source — is
  resolved with `nix build --inputs-from <repo>`, which pins against THIS repository's
  `flake.lock` rather than the invoking user's flake registry. The two answer differently on this
  host: `nixpkgs#llvmPackages.clang-unwrapped` resolves to `603yaax3…` unpinned and `lfjzqzpn…`
  pinned. That difference is what makes the second one a pin rather than a spelling.
- **`nim` is in this repository's own dev shell**, at nixpkgs' **2.2.10** as the same
  `flake.lock` pins it, and `pins.json`'s `toolchain.nim` records that version so `build.rs` can
  refuse a mismatch.

  *It was NOT, in the first version of this work, and that is worth recording rather than
  quietly fixing.* `build.rs` took `nim` from `PATH` and refused a version that did not match,
  which reads like a pin and is not one: an agent's own shell inherits the WORKSPACE's `.envrc`
  and has `nim` on `PATH`, while `direnv exec <this repo>` — the shell the sweep and every CI job
  use — replaces `PATH` entirely and did not. Three of M41's seven checks passed by hand and died
  in the sweep with `nim is required`. M19's `wasm-opt` finding and M25's system-node finding are
  the same defect and this is its third instance; the remedy is the same one, which is to put the
  tool in the shell.

---

## 4. All thirty-eight ABI functions, served

**Thirty-eight, counted three ways and compared AS SETS.** `grep -c 'pub extern "C" fn'` gives
**26** — twelve of the thirty-eight are `pub unsafe extern "C" fn` and that needle cannot see them,
which is where the wrong figure came from. Measured by `verify_all_abi_functions_served`:

- `#[unsafe(no_mangle)]` in `ct-writer/src/lib.rs`: **38**
- `ct-host/src/abi.ts`'s four lists, 19 + 11 + 6 + 2: **38**
- both modules' export tables, minus `memory`: **38**, and all three sets are EQUAL

**None is unserved.** Every one of the thirty-eight is exported by BOTH modules and CALLED by
`verification/ct_writer_drive_core.mjs` on the way to a container — an export table is a promise
and a call is the evidence.

Two of the thirty-eight are served with a behavioural difference rather than an absence, and both
are named here because "served" is not the same as "identical":

- **`ct_writer_open`'s `recording_id` argument.** Path A accepts an empty one and lets the writer
  choose. **Path B REFUSES an empty one**, with a message saying why: `wasm32-unknown-unknown` has
  no CSPRNG, so a writer left to mint its own would mint the SAME identity in every session, and
  identities that collide are indistinguishable in a trace store. `nim_host_shim.c`'s `getentropy`
  refuses rather than filling a constant precisely so that a constant identity cannot be produced.
- **`ct_return`'s `None` type id.** Path A writes a `ValueRecord::None` under the interned `None`
  type; the Nim ABI's `trace_writer_register_return` takes no value and writes its own. The id is
  therefore unused on Path B. Both containers carry a return; only one of them was told which type
  to spell it with.

---

## 5. Container equivalence, stream by stream

*Full table: `verify_container_equivalence_characterised`, which fails on an unexplained difference
AND on a catalogued reason for a difference that has gone away.*

**48 facts agree, 20 differ, every one of the 20 has a recorded reason.** The ones that matter:

| what differs | Path A | Path B | why |
|---|---|---|---|
| `events.log` | present | **absent** | THE DIFFERENCE THE MILESTONE NAMED IN ADVANCE, and it is larger than described. The milestone said "prefixes `events.log` with an 8-byte header the Nim writer omits". Measured: the Nim multi-stream writer writes **no `events.log` at all**, and `ct-print` diverts any container carrying one to its LEGACY combined-stream reader — so the two containers are read by two different code paths in the same binary |
| `meta.dat` schema version | **3** | **4** | v3 packs a line-only step position as `prefixSum[path] + line`; v4 packs `prefixSum[path] + (line - 1)` |
| CTFS container version (header byte 5) | 3 | 4 | a v4 reader accepts 2, 3 and 4, so this byte is not what decides readability |
| step count | 7 | **8** | the Nim ABI's `trace_writer_start` emits a step at the entry line; the Rust `start` records the entry position without one. The driver makes 7 step-producing calls |
| function / call count | 2 / 2 | **1 / 1** | the Rust writer's `start` interns a `<toplevel>` function and opens a frame for it. `ct_calls_opened()` — the MODULE's own count — is **1 in both**, which is what says the difference is the writer's |
| capability flags | **not reported at all** | reported | a consequence of the first row: the legacy `events.log` reader reconstructs `program`/`args`/`workdir` and knows nothing about meta.dat capability bits |

And the facts that AGREE, which is the claim that matters: `eventsWritten`, `sourceStepsWritten`,
`stepsPositioned`, `stepsUnpositioned`, `pathCount`, `rungCount`, `logEvents`, `callsOpened`,
`callDepth`, `columnsRequested`, `droppedColumnAwareness`, `rungViolations`, the CTFS magic, the
program and workdir, the path table, the varname table, column-awareness, the LAST step's global
line index, the io-event count, and the frame's entry step and depth.

### What the per-step comparison found, which no count would have

`e2e_runtime_traces_through_nim_writer` compares the `(path, line, column)` of every step read back
against the positions the driver asked for. The first Path B build produced **exactly the right
number of steps with every column one too high**: the Nim ABI's `register_delta_column` takes a
DELTA from a step that already sits at column 1, and the backend passed the column itself. Nothing
refused it — a column one to the right is a real position in a real line — so it is the
silent-wrong-answer shape, and only a comparison against what was asked for could see it. Fixed;
`col - 1` is now what crosses, and the comment says why.

---

## 6. Which reader reads which container, and why Path A is still the default

**Neither of the two pinned readers reads both containers.** Measured, in both directions:

| | Path A container | Path B container |
|---|---|---|
| reader at `trace_format_nim` (2026-08-20) | **reads it** | `steps.dat: index file too small for trailer`; no `values.off`, no `events.off` — and it does **not refuse the container**, it reports an empty program and every capability flag false |
| reader at `trace_format_nim_writer` (2026-09-09) | **REFUSES it by name**: *"schema version 3 predates the global line index correction … a step read under the current decode would come back one line high rather than fail"* | **reads it completely** — 8 steps, 8 value records, 2 io events, all counts resolved |

That is not a defect either revision introduced. It is what two anchors nineteen days apart means,
and it is the reason the runtime's default is unchanged:

- **Everything downstream of a container in this repository reads it with the reader anchor.**
  `test_ct_container_roundtrip_ct_print` and the M25/M26/M29/M40 checks all do. Making Path B the
  default would turn those from checks about a writer into checks about a reader that predates it.
- **Moving the reader anchor is explicitly not this milestone's to do.** `pins.json`'s
  `trace_format_nim` anchor names a commit rather than a branch tip so that
  `test_ct_container_roundtrip_ct_print`'s reader difference stays at ONE commit; moving it forward
  makes that difference three and breaks the stated rationale. So the writer role got **its own
  anchor** — which is exactly what the milestone instructed — and the default stayed put.

**What would flip the default**, stated so the next reader does not have to derive it: a decision
about the reader anchor, taken with the roundtrip check's one-commit rationale in view. Nothing
else in this milestone is in the way. **§9 makes that concrete — the flip was made, built and
measured, and costs +73 failing assertions in three milestones, every one of them the pinned
reader answering with nothing.**

### The v4 flag day, which is the same fact from a third side

The workspace moved `meta.dat` to version **4** and current readers refuse **3** by name.
Re-derived here, in the two materialised trees this crate builds from:

- `ct-writer/build-wasm-deps/ctf/codetracer_trace_writer/src/meta_dat.rs:31` —
  `pub const META_DAT_VERSION: u16 = 3;` (the `trace_format` anchor, `592fa42cbf`, Path A)
- `ct-writer/build-wasm-deps/ctf-nim/src/codetracer_trace_writer/meta_dat.nim:121` —
  `MetaDatVersion*: uint16 = 4` (the `trace_format_nim_writer` anchor, Path B)

**So the containers this runtime ships today are v3 and are unreadable by current tooling**, and
Path B's are v4 and read correctly — not merely "open": `e2e_runtime_traces_through_nim_writer`
compares every step's `(path, line, column)` read back against the position the driver asked for,
and all eight match. That predicate is the whole point of the version bump: the superseded encode
put every step ONE LINE HIGH with no error, because the address lands inside the trace's own space
and nothing can refuse it.

**The pinned writer's constant is NOT bumped, and must not be.** `wasm/ctfs-writer` carries the old
encode; stamping v4 on old-convention addresses converts a loud refusal into a silent one-line-high
read, which is strictly worse than the current state. The remedy is the switch, not the stamp.

**A second, independent statement of the same fact, from the other side of the join:**
`noir/Cargo.toml`'s own comment on the `codetracer_trace_writer` line says the pure-Rust writer
*"emits a SplitBinary single-shard variant that the Nim ct-print decoder cannot read"*. The Noir
campaign reached the same conclusion from its own measurements and resolved it the other way — by
using the Nim writer.

---

## 7. OQ-7 fact 6

`JOIN-SHAPE.md` §2 fact 6: *"the shipping Noir branch links a **different writer** … while this
runtime is Path A"*.

**Measured, on the `noir` checkout at `codetracer`:**

- `noir/Cargo.toml:181` resolves `codetracer_trace_writer` to
  `../codetracer-trace-format/codetracer_trace_writer_nim`, package `codetracer_trace_writer_nim` —
  DD-7's Path B.
- `noir/tooling/nargo_cli/Cargo.toml:55` takes `noir_tracer` with `features = ["nim-writer"]`, and
  `noir/tooling/tracer/Cargo.toml:38` declares `nim-writer = ["dep:codetracer_trace_writer"]`.

So the Noir half is Path B, confirmed rather than assumed.

**Fact 6 is RETIRABLE, and is NOT RETIRED.** The seam turns "this runtime is Path A" from a
property of the code into a build-time choice, and a `--features path-b` build of this runtime
links the same writer the Noir half links, with nothing published that was not already published.
What is not true yet is that the runtime SHIPS that way, and fact 6 is a statement about what
ships. Retiring it needs §6's reader-anchor decision.

**`JOIN-SHAPE.md` §2 IS THEREFORE NOT EDITED.** The milestone says to update its framing *"only
once the switch lands"*, and the default did not move. Editing it now would put a claim in the
document that the artefacts do not support — which is the failure `verify_named_checks_exist` was
written for, one level up.

**`wasm/webpage` remains unpublished, and nothing here needed it.** Checked before and after: zero
published refs contain its HEAD, and zero `refs/heads/wasm/webpage` rows on the remote. Retiring
fact 6 is what makes publishing that branch unnecessary; it is not what would make it safe.

---

## 8. The upstream change this needed, and why it was the minimum

One commit in `codetracer-trace-format-nim`, published on `dev` before anything pinned it:
**`0638684686` — `feat(ffi): let a caller pin the recording identity`.**

Every constructor on that C ABI resolved the recording id itself — the caller's when non-empty, a
freshly minted UUIDv7 otherwise — and the ABI offered no way to supply one, so an embedder always
got the minted branch. On a freestanding wasm target the mint draws on host stubs, and a constant
answer means every recording a page produces carries the same identity.

`trace_writer_set_recording_id` is the whole change: a handle field, four constructor call sites
threaded, and a refusal for an id set after the writer is begun. Its test pairs the positive
assertion with the arm that gives it meaning — a writer that does NOT call the setter gets a
DIFFERENT, valid id — because without that arm the assertion cannot tell a working setter from a
no-op on a host whose stubs mint a constant. Three mutation arms were run against it and each
reddened on its own assertion.

---

## 9. The flip was made and measured, and then made again in reverse

M41's goal is that this runtime writes through the Nim writer. **`default = ["path-b"]` was set,
built and measured** rather than argued about. Every M41 check went green at 169 assertions, the
default module reported kind 2, and the container it produced was v4 and read completely by the
reader at the writer anchor.

Then the rest of the suite was measured, and this is the whole result:

| milestone | default `path-a` | default `path-b` | Δ failures |
|---|---|---|---:|
| m24 | 350 assertions, 14 failures | 350, **58** | **+44** |
| m25 | 456, 0 | 456, **15** | **+15** |
| m40 | 145, 12 | 145, **26** | **+14** |
| m26 | 135, 4 | 135, 4 | 0 |
| m29 | 127, 0 | 127, 0 | 0 |
| m38 | 107, 4 | 107, 4 | **0** |
| m39 | 80, 10 | 80, 10 | **0** |

**Every assertion COUNT is unchanged.** Nothing structural moved; one class of assertion started
failing, and it is one class.

### It does NOT clear m38 and m39, and that refutes the obvious hypothesis

The natural reading of those two reds was that they are this runtime writing v3 into readers that
now refuse it. **Measured, they are identical under both defaults** — 107/4 and 80/10 either way.
Whatever they are, they are not the shipped writer's version. The earlier attribution stands.

### What the +73 is, and it is one thing

**This repository verifies every container it writes with the `ct-print` pinned at
`trace_format_nim`, which is a version-3-era reader.** On M24's own 4.6 MB container, produced by
the Path B module:

| reader | events | program | steps |
|---|---:|---|---:|
| `ct-print` @ `baea074019` — the **reader anchor** | **0** | `''` | 1,830 |
| `ct-print-writer` @ `0638684686` — the **writer anchor** | **250,001** | `aztec-avm-runtime` | **250,001** |

The pinned reader **does not refuse** — it answers, with nothing. So under a `path-b` default this
repository would be shipping containers its own suite cannot verify, and m25's and m40's content
assertions fail not because a record is wrong but because the reader hands back no records at all.

### Why the default is `path-a` anyway, which is a pin decision and not a writer one

The flip is blocked on `trace_format_nim`, and that is the one pin M41 was told not to move. Its
rationale is specific: it names a commit rather than a tip so
`test_ct_container_roundtrip_ct_print`'s reader difference stays at **one** commit, with the
control being that commit's parent. Moving it to the writer anchor makes the control `8cfb1bb`,
which **reads** a v4 container — so the check's "the parent must not read it" arm has to be
re-designed rather than re-pointed. That is M24's work, not M41's.

**And the failure modes are not symmetric.** Shipping v3 today is a **loud** failure downstream:
current readers refuse it by name, saying which version and why. Shipping v4 today would leave
this repository unable to verify its own containers at all — trading a refusal for a silence,
which is the direction this campaign's rules run against.

### The reader anchor cannot simply be re-pointed, and that is measured too

The obvious remedy — move `trace_format_nim` to the writer anchor — does not work, and the reason
is arithmetic rather than preference. `test_ct_container_roundtrip_ct_print` asserts two things
about that anchor at once:

1. the control reader **must NOT read** the container, and
2. `control_commit` **IS the reader commit's parent** — a one-commit difference, asserted against
   `git rev-parse "$FIX^"`.

Move the anchor to `0638684686` and the control becomes its parent, `8cfb1bb`. **That parent reads
a v4 container.** Measured without building it: `git diff --name-only 8cfb1bb 0638684686` is three
files — the nimble file, `codetracer_trace_writer_ffi.nim`, and one test — and **no reader file
differs at all**, so a reader built there behaves exactly as `ct-print-writer` does, and
`ct-print-writer` reads v4 completely.

So there is **no commit that is simultaneously the new reader's parent and unable to read a v4
container**, because the version bump and the fix this anchor names are not adjacent. The
demonstration has to be re-designed rather than re-pointed, and its design is M24's.

**So it is one line, gated on one decision**, and everything else is in place: both arms build,
both are exercised, the checks derive which writer ships from the manifest rather than asserting
it, and the crate's native tests are pinned to the arm that can host them. `just
ct-writer-build --path-b` produces the shipped-shape Path B module today.

---

## 9b. m26, and why its refusal is not a stale declaration

`build_oq7_shared_writer_probe.sh` refuses:

```
the Noir worktree resolves its writer crates at .../ctf-wt-wasm (c8802c548f…)
and pins.json's trace_format is 592fa42cbf…
```

**The precondition is correct and should stay.** It is this repository's own rule — never build
against a revision the pin does not declare — applied to the one dependency that is resolved by
relative path out of a sibling checkout rather than materialised from an object store.

**What drifted is the WORKTREE, not the declaration.** `592fa42cbf` is exactly the revision the
shipped Path A module is built from, pinned deliberately at a commit rather than a branch tip.
`ctf-wt-wasm` is a worktree of `codetracer-trace-format` sitting on `wasm/ctfs-writer`, and earlier
M41 work moved that branch forward to `c8802c5`.

**Moving the pin to `c8802c5` was tried and measured.** It does not build: that commit makes the
Zstandard backend a cargo feature with C libzstd as the default, and the Path A wasm build has no
`CC_wasm32_unknown_unknown` configured, so it dies inside `zstd-sys` compiling `cover.c` with the
host `gcc`. Making it work means selecting a backend explicitly and either accepting **+234,429
bytes** of module or opting out — a compressor migration for the writer this milestone exists to
move off.

**So the remedy is neither of the two obvious ones.** It is for the probe to materialise
`codetracer-trace-format` at the pinned revision out of the object store, the way
`build_ct_writer_wasm.sh` and `ct-writer/build.rs` already do — which it cannot do today because
the Noir worktree resolves those crates by a relative path in its own manifest. That is a change in
a Noir worktree, which this milestone is not permitted to touch, and it is recorded here so the
next person meets the reason rather than the symptom.

---

## 10. The sweep

Measured M0–M41 on 2026-09-10, **after this milestone's last commit**, `setsid`-detached under
`direnv exec` — this repository's own dev shell — one milestone at a time with nothing else
running. 84 markers for 42 milestones, no hole.

> **TOTAL 13,184 · 42 milestones · delta −354 against 13,538 · 25 of 42 exit 0**
>
> **m41 = 164, rc=0, exactly its reference.** m24 = 350, unchanged.

Every unit accounted in both directions — **+9 +1 −206 +2 +8 −43 −125 = −354**:

| milestone | move | whose |
|---|---:|---|
| m11 | +9 | the upstream move, the campaign's standing condition |
| m25 | +1 | `e2e_trace_token_transfer_steppable.sh`, edited by an L-track commit this milestone rebased onto |
| m27 | +2 | the browser chunk budget, same eleven commits |
| m28 | +8 | M28's derived job census, same eleven commits |
| m38 | −43 | the v3→v4 flag day reaching this repository's Noir arms — zero steps, unreadable frame fields, from sibling repositories nothing here changed |
| m39 | −125 | the same |
| **m26** | **−206** | **M41's own, and recorded as such** |

**m26 is the one to read carefully.** `build_oq7_shared_writer_probe.sh` refuses by name:

```
the Noir worktree resolves its writer crates at .../ctf-wt-wasm (c8802c548f…)
and pins.json's trace_format is 592fa42cbf…
```

Earlier M41 work moved `wasm/ctfs-writer` forward to `c8802c5` — the Path A compressor fix — and
deliberately did **not** move the runtime's pin with it. **The refusal is the check working**: it
declines to build against a revision the pin does not declare rather than building and reporting a
number about the wrong tree. The remedy is a pin decision, not a repair: moving `trace_format` to
`c8802c5` picks up the compressor fix at a measured **+234,429 bytes** of module and does **not**
address §6's v3 problem, because that branch still carries the superseded encode.

### What the FIRST sweep found, which was M41's own defect

It measured m41 at **73** against 164. Three of the seven checks build Nim — two through
`build_ct_print.sh`, one through `ct-writer/build.rs` — and this repository's dev shell did not
provide `nim`. They passed by hand and died in the sweep with `nim is required`, because an agent's
own shell inherits the workspace's `.envrc` and `direnv exec <this repo>` replaces `PATH`. `nim` is
in `flake.nix` now. *A tool a check needs belongs in the shell the check is run in; a version
assertion over `PATH` only tells you which shell you were in.*

**A sweep is a writer.** `carry/*.json` checksummed before and `sha256sum -c` after, both runs:
`exposure.json` and `rebase.json` came back changed, were restored from HEAD, all four re-verified
OK, and neither was staged.
