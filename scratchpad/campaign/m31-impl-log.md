# M31 — `avm-transpiler` to WebAssembly — implementation log

Written as I go, per the brief. **No commits, no pushes.** `noir-wt4-webpage` is never edited
(fact 7 of OQ-7's verdict; `build_oq7_shared_writer_probe.sh` tolerates exactly one uncommitted
edit by name and refuses any other).

---

## Step 0 — state at start

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `a76f016` | clean |
| `aztec-packages` | `aztec-avm-runtime` | `ee3c0528d5` | clean |
| `noir` | `blocktracer` | `4d2381630` | clean |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | **one** edit, `tooling/tracer/src/tracer_glue.rs` — M26's, as found |
| `codetracer-specs` | — | — | clean |

Sweep reference M0–M30 = **10,396**, 31 milestones, 30 of 31 exit 0.

### 0.1 Two facts that decide where the work can happen

1. **`avm-transpiler/` is byte-identical between the campaign anchor `233d8e0993` and
   `aztec-packages` HEAD.** `git diff --stat 233d8e0993 HEAD -- avm-transpiler/` is empty. So the
   milestone can be done at the anchor every prepared patch is based on, and the result is current.
2. **`aztec-packages/noir/noir-repo` is an EMPTY DIRECTORY.** It is a submodule
   (`.gitmodules:23`, `https://github.com/noir-lang/noir.git`) pinned at
   `40d6574f851d926f93e0c3a271bac3e6e82ac905` — *chore: Release Noir(1.0.0-beta.26) (#13392)* —
   at **both** the anchor and HEAD, and it has never been checked out here. Every one of the
   transpiler's five path dependencies points into it
   (`acvm`, `noirc_abi`, `noirc_artifacts`, `noirc_evaluator`, `noirc_frontend`), so **nothing in
   this workspace could build the transpiler at all** before this milestone.

   **The workspace's own `noir` checkout HAS that commit** (`git cat-file -t` → `commit`;
   reachable from four local branches). So it is materialisable without the network, by
   `git archive`, which is the campaign's established pattern (`build_ct_writer_wasm.sh`).
   Recorded honestly: `noir` has **zero** `refs/remotes/*` refs, so the
   `m24_published_refcount` shape cannot be applied to it here; the commit is an upstream
   `noir-lang/noir` release tag, which is a different and stronger kind of published.

### 0.2 Where the work happens, and why not in the repos

All builds run in `~/.cache/aztec-m31-work/tree`, materialised by `git archive` from both repos at
pinned revisions — the `build_ct_writer_wasm.sh` shape. `aztec-packages` is not written to at all;
`noir` is not written to at all. `$TMPDIR` on this host is a RAM-backed tmpfs and is not storage
(CAMPAIGN-BRIEF, Environment). A 64 MB write probe under `~/.cache` succeeded before any work.

---

## Step 1 — THE ENUMERATION (the first deliverable, reported before code)

`cargo metadata --filter-platform wasm32-unknown-unknown` over the materialised tree.

### 1.1 The closure, split by whether the code can enter the module

| closure | packages | why it matters |
|---|---|---|
| full graph (normal + build, dev excluded) | **228** | everything cargo resolves for wasm32 |
| **LINKED** — `normal` edges only, proc-macro crates and their subtrees cut | **189** | the only code that can reach the module |
| HOST-ONLY — build scripts, proc macros and their deps | **39** | runs in the compiler, never in the module |

The split is not cosmetic. `cc`, `autocfg`, `find-msvc-tools`, `proc-macro2`, `syn`,
`version_check` and `rustversion` between them hold 253 host-capability sites, every one of which
runs on the build machine. Counting them would have made the number a third larger and every unit
of the excess irrelevant.

### 1.2 The census — the number, before code

Scanner: `scratchpad/campaign/m31-census.py` (working copy in the work dir), five families with
word-boundary-anchored needles, **and a deliberately over-wide residue net whose misses are
PRINTED** rather than counted — the brief's rule for scanners.

**Over the 189-package LINKED closure, 4,874 `.rs` files:**

```
fs       322 sites   (240 in lib-linked files)   46 packages
env      147 sites   (120 in lib-linked files)   39 packages
time     694 sites   (363 in lib-linked files)   21 packages
thread   685 sites   (421 in lib-linked files)   29 packages
process   60 sites   ( 31 in lib-linked files)   22 packages
------------------------------------------------------------
TOTAL  1,908 sites   (1,175 in lib-linked files)
residue no family placed: 347 lines across 45 packages
```

**THE NUMBER IS 1,908 — of which 1,175 are in files a lib target can compile** (the other 733 are
in `tests/`, `benches/`, `examples/`, `fuzz/`), and **14 of those 1,175 are cfg-gated to
`unix`/`windows`/a named OS** and cannot compile for wasm32 at all, leaving **1,161**.

Plus **253** sites in the 39 host-only packages, which are named and excluded with a reason rather
than silently dropped.

### 1.3 Why a source-tree census is an over-count, and what the decisive reading is

A source-tree census counts every site in every crate's source directory whether or not the
feature that compiles it is on and whether or not the module links that function. It is the
right first reading — it says where to look — and it is **not** the verdict. Stated plainly
because the campaign's rule is that a census IS its derivation.

The decisive readings are two, and both are taken on the artefact:

1. **the module's own import section** — on `wasm32-unknown-unknown` the only way host capability
   can leave the module is a declared import (wasm-bindgen `js_sys`/`web_sys`, or an
   `extern "C"` into `env`);
2. **what the module REACHES at run time** — M30's instrument: satisfy every declared import with
   a recorder that throws, and see which ones fire.

Both are in §3.

### 1.4 Per-package, where the risk was expected to be

Top of the LINKED census, after the cfg filter:

```
 179  rayon           thread:179      <- noirc_evaluator
 163  time            time:154 fs:8   <- serde_with
  97  hashbrown       thread:97
  65  chrono          time:45 fs:16   <- noirc_evaluator, serde_with   *** the M30 shape ***
  63  jiff            time:45 fs:12   <- env_logger
  41  indexmap        thread:40
  41  tracing         fs:41
  28  noirc_frontend  fs:24 thread:3 time:1
  26  rayon-core      thread:22
  18  js-sys          time:18         <- chrono
  12  noirc_evaluator fs:8  thread:3
  10  avm-transpiler  fs:8  env:2
```

Reverse edges, measured rather than assumed:

- `js-sys`, `wasm-bindgen` ← **`chrono`** ← `noirc_evaluator` and `serde_with`. **This is exactly
  M30's blocker**: `chrono::Utc::now()` on `wasm32-unknown-unknown` is `js_sys::Date::new_0`, a
  JS import.
- `rayon` ← `noirc_evaluator` only.
- `jiff` ← `env_logger` (log timestamps).
- `getrandom` ← `crypto-bigint`, `crypto-common` (the ECDSA path under `acvm_blackbox_solver`).
- `rand` ← `ark-std`.

### 1.5 The transpiler's own ten sites, with a verdict each

This is the part where a per-site verdict is possible and useful.

| # | site | family | verdict |
|---|---|---|---|
| 1 | `src/main.rs:6` `use std::env` | env | **binary only.** `main.rs` is the `avm-transpiler` bin target; a cdylib does not link it |
| 2 | `src/main.rs:7` `use std::fs` | fs | binary only |
| 3 | `src/main.rs:28` `env::args().collect()` | env | binary only |
| 4 | `src/main.rs:37` `fs::read_to_string` | fs | binary only |
| 5 | `src/main.rs:52` `Path::new(..).exists()` | fs | binary only |
| 6 | `src/main.rs:53` `std::fs::copy` | fs | binary only |
| 7 | `src/main.rs:68` `fs::write` | fs | binary only |
| 8 | `src/lib.rs:9` `use std::fs` | fs | **library, and only reached from `avm_transpile_file`** |
| 9 | `src/lib.rs:98,114,115,134` `fs::read_to_string` / `Path::exists` / `fs::copy` / `fs::write` | fs | `avm_transpile_file` only. On wasm32 these compile (std's fs is a stub) and return errors — a **refusal**, not a plausible value |
| 10 | — | — | **`avm_transpile_bytecode` — the in-memory entry point — touches NONE of them.** It takes `(*const u8, usize)`, returns a `TranspileResult` holding a heap buffer, and reads no clock, no file, no environment variable, and spawns nothing |

**That is the finding that makes M31 possible**: upstream already ships a pure in-memory C ABI
(`avm_transpile_bytecode`, `lib.rs:148`), added for the C++ caller, and it is exactly the shape a
browser needs. Nothing had to be invented for the entry point.

---

## Step 2 — the two blocking symbols, both named, both fixed

A `cdylib` build was attempted immediately, so that the enumeration's predictions were tested
rather than trusted.

### 2.1 BLOCKER 1 — `getrandom::backends::fill_inner`

```
error: The wasm32-unknown-unknown targets are not supported by default; you may need to
       enable the "wasm_js" crate feature.
  --> getrandom-0.4.1/src/backends.rs:176:17
error[E0425]: cannot find function `fill_inner` in module `backends`
error[E0425]: cannot find function `inner_u32` in module `backends`
error[E0425]: cannot find function `inner_u64` in module `backends`
```

**Reused, not invented.** `noir` solves exactly this in three of its own wasm crates —
`compiler/wasm/.cargo/config.toml:5`, `acvm-repo/acvm_js/.cargo/config.toml:6`,
`tooling/noirc_abi_wasm/.cargo/config.toml:5` — each carrying
`rustflags = ['--cfg', 'getrandom_backend="wasm_js"']` plus the `wasm_js` feature on all three
getrandom majors.

**Not copied, though, and the reason is the campaign's own rule.** `wasm_js` answers the request
with `crypto.getRandomValues` — a *plausible value* — and getrandom 0.4.1 ships a
`getrandom_backend="unsupported"` backend whose whole body is `Err(Error::UNSUPPORTED)`
(`src/backends/unsupported.rs`). Randomness is not needed to transpile: the only edges into
`getrandom` are `crypto-bigint` and `crypto-common`, i.e. ECDSA key material under
`acvm_blackbox_solver`, which transpilation does not touch. So the build takes the **refusal**,
which costs no dependency, no feature and no JS import, and which fails loudly if the assumption
is ever wrong.

### 2.2 BLOCKER 2 — `libc::{c_char, c_int, size_t}`

```
error[E0432]: unresolved imports `libc::c_char`, `libc::c_int`, `libc::size_t`
 --> src/lib.rs:7:12
```

`libc` defines nothing for `wasm32-unknown-unknown` (unknown OS). The whole of the crate's use of
`libc` is **one line** — `src/lib.rs:7` — plus `use libc as _;` at `src/main.rs:16` to silence
`unused_crate_dependencies`. All three aliases are in `core::ffi` (`c_char`, `c_int`) and the
third, `libc::size_t`, is a type alias for `usize`.

Fix: `use core::ffi::{c_char, c_int};`, `size_t` → `usize`, and the `libc` dependency dropped
entirely. **ABI-identical on every existing target** — `core::ffi::c_char` and `libc::c_char`
follow the same platform rules, and `size_t` *is* `usize`. `avm_transpiler.h` is unchanged.

This is the prepared upstream contribution (Step 5).

### 2.3 It builds

```
Finished `release` profile [optimized] target(s) in 12.53s
avm_transpiler.wasm   4,970,171 bytes
```

**Both blocking symbols are named and both are one-line-class fixes. The milestone's risk did not
materialise.**

---

## Step 3 — the artefact readings

### 3.1 The import section — FOUR imports, and not one of them is a clock

Walked with an independent leb128 import/export walker (`m31-wasmwalk.py`), not `wasm-tools`,
because the point is a second reading:

```
IMPORTS: 4
  __wbindgen_externref_xform__   __wbindgen_externref_table_grow
                                 __wbindgen_externref_table_set_null
  __wbindgen_placeholder__       __wbg___wbindgen_throw_be289d5034ed271b
                                 __wbindgen_describe
EXPORTS: 858  — of which the C ABI is
  avm_transpile_bytecode, avm_transpile_file, avm_free_result, memory,
  __wbindgen_malloc, __wbindgen_realloc, __wbindgen_free
```

**M30's blocker is absent here, and its absence is measured.** `chrono` is in the linked closure
and `js-sys` under it, and the module still carries **no `__wbg_new0_…` and no
`__wbg_getTime_…` import** — the `Date` bindings' *describe* stubs survive as exports, but the
call sites do not, because the transpiler never enters `noirc_evaluator::ssa`. It links
`noirc_evaluator` for `ErrorType` and nothing else.

(To be continued — Step 3.2 the run-time reach, Step 4 byte-identity, Step 5 the upstream patch.)

### 3.2 REACHED: nothing, in two hosts

M30's instrument, reused: every declared import is satisfied by a function that RECORDS the call
and then throws. Over seven transpiles in one Chromium page load with ONE
`WebAssembly.instantiate` and ONE `.wasm` request:

```
declaredImports 4    reachedImports []      (Chromium)
declaredImports 4    reachedImports []      (Node, same module, separate instantiation)
```

Empty is the interesting answer and 4 is what stops it being vacuous.

---

## Step 4 — byte-identity, which is the acceptance test

Seven contracts, three independent producers, one digest each:

```
contract          native      node        browser     verdict
counter           add246a4…   add246a4…   add246a4…   IDENTICAL
branches          b4f481d1…   b4f481d1…   b4f481d1…   IDENTICAL
memory            855a87b0…   855a87b0…   855a87b0…   IDENTICAL
multi             74eab476…   74eab476…   74eab476…   IDENTICAL
private_only      2323b397…   2323b397…   2323b397…   IDENTICAL
counter_variant   96d0798e…   96d0798e…   96d0798e…   IDENTICAL
reverting         …           …           …           IDENTICAL
control: counter vs counter_variant                    DIFFERENT
```

(The digests move whenever the fixtures are recompiled, because `file_map` carries the absolute
path of the source. They are re-derived on every run and no check quotes one.)

The corpus is deliberately several shapes, not one program seven times: arithmetic with a loop,
comparison and control flow, array indexing, two AVM functions plus an ACIR one in a single
artifact, a contract with NO public function (which is the only route to
`create_revert_dispatch_fn`), a one-token variant of the first, and one that reverts.

**The native arm is a separate PROCESS reading and writing real files** — `avm_transpile_file`,
the entry point that does touch a filesystem — rather than a second call into the same library.
"Identical" is therefore a statement about two code paths and not about one.

---

## Step 5 — the rung, over the browser's own bytes

`tools/run_transpiler_arms.mjs` decodes `browser-<fixture>.out.json` and drives **M25's own**
`ct-host/src/source_map.ts` (`rungFor`, `ContractSourceMap`) unchanged (RI-81).

```
contract/function              rung  pcs  positioned  bytecode  key range   input keys
counter/public_dispatch          1    27      27        204     [64, 194]   [12 … 38]
branches/public_dispatch         1    56      56        558     [64, 489]   [12 … 86]
memory/public_dispatch           1    15      15        144     [64, 134]   [12 … 26]
multi/public_dispatch            1    10      10        119     [64, 109]   [12 … 21]
multi/second_public              1     1       1         74     [64,  64]   [12]
counter_variant/public_dispatch  1    26      26        199     [64, 189]   [12 … 37]
private_only/public_dispatch     3     0       —          22     —           —
```

Zero unpositioned, zero unrecognised call-stack nodes, zero locations naming a file the
`file_map` does not carry, across the whole corpus. The first resolved position for `counter` is
`counter/src/main.nr:7:19` — a line AND a column, and the line is checked against the fixture
file's own length.

### 5.1 The control is the failure mode itself

The milestone's risk is that a wasm build silently loses `patch_debug_info_pcs` and rung 1
degrades to rung 3 with nothing saying so. That exact artefact is constructed: the INPUT's
Brillig-index map spliced onto the transpiled bytecode, asked about the AVM pcs an executor
presents.

```
avm pcs                            27
positioned by the re-keyed map     27
positioned by the NOT-re-keyed map  0
stale key range              [12, 38]   (disjoint from [64, 194])
```

Two further controls are LABELLED rather than accepted, and **one of them the transpiler produced
itself**: `private_only` has no `abi_public` function, so `create_revert_dispatch_fn` appends a
22-byte reverting `public_dispatch` with no debug info, and `rungFor` says *rung 3, "the
debug_symbols are present but brillig_locations is empty"*. The third strips `debug_symbols`
entirely and gets *rung 3, "carries no debug_symbols"*. The paired positive is the same resolver
answering **1** for `counter`, with the reason naming the AVM byte offset re-keying.

### 5.2 A RANGE IS NOT A SET, and the first version of this check got it wrong

Section 2 originally asserted "not one input key falls inside the output's RANGE". That is true of
`counter` (Brillig [12, 38] against AVM [64, 194]) and **false of `branches`**, which has 56
Brillig opcodes and AVM offsets in [64, 489]: 22 input indices sit inside the output's interval
while not one of them is the same entry. The check went red for a reason that had nothing to do
with the subject. It compares the key LISTS as sets now — same count, list not equal, fewer than
half shared, and the key space grown — and `pcKeys` was added to the arm report so the comparison
has both sides.

---

## Step 6 — register and execute

`orchestration/src/transpiled_contract_driver.ts`, over `browser-<fixture>.out.json`:

```
contract    bytecode  steps  revertCode  outcome     block
counter        204     41     0 / OK     processed     1
reverting      241     41     1 / Reverted processed   1
branches       558     71     0 / OK     processed     1
memory         144     29     0 / OK     processed     1
```

**The two fields that could be constants are shown not to be.** `revertCode` is 0 for three
contracts and 1 for the one whose dispatch asserts something false — and that one reverted *after*
executing 41 instructions, so it is a control for section 4 rather than a second way of failing at
instruction one. `instructionsExecuted` is 41 / 41 / 71 / 29, directional with bytecode size in
both directions.

`counter` and `reverting` coinciding at 41 is recorded rather than hidden: the assert replaces the
return, so the paths are the same length. It is exactly why the non-degeneracy control uses
`branches` and `memory`.

**The boundary is stated.** The transpile is in Chromium; the execution is in Node against the
same `avm.wasm` a page fetches. `bytecodeProvenance` carries the sentence and the check asserts it
is there.

### 6.1 Two things upstream's loader needed that a hand-written contract has to declare

- `#['abi_public]` — the transpiler selects on `custom_attributes.contains("abi_public")`, and a
  plain `#[abi_public]` is *not* it: noir requires an attribute to resolve to a comptime function
  unless it is a `#['tag]` (`noirc_frontend/src/parser/parser/attributes.rs:142`).
- `#[abi(functions)] pub struct <fn>_abi { return_type: … }` — `@aztec/stdlib`'s
  `loadContractArtifact` reads `outputs.structs["functions"]` for `<Contract>::<fn>_abi`
  (`dest/abi/contract_artifact.js:148`) and throws `Cannot read properties of undefined` without
  it. aztec-nr's macros generate these.

Both are inert with respect to bytecode, and both exist so the execution check drives **upstream's
own loader** rather than an artifact object this repository assembled.

---

## Step 7 — the checks

| check | assertions |
|---|---|
| `verify_transpiler_wasm_output_identical_to_native` | **120** |
| `test_transpiled_contract_registers_and_executes` | **59** |
| `verify_transpiler_rung1_mapping_survives` | **114** |
| `verify_transpiler_native_build_unaffected` | **80** |
| | **373** |

## Step 8 — what else in the repository moved, and why

- **`verify_carry_set_complete` 43 → 46.** M11's check derives every `aztec-*` directory under
  `codetracer-specs/upstream-bugs/` and requires each to be in the carry set or declared
  `not_carried` with a reason. A sixth directory therefore had to be declared, and the check makes
  exactly three assertions per declared entry (it exists on disk, its reason is stated, it is not
  also in the carry set). **So M11 moves 259 → 262**, on top of being red for the ninth upstream
  move. Accounted for in both directions.
- **`verify_reuse_inventory_complete` stays 19.** RI-78..81 add four entries and the entry-count
  assertion is `>= 20`.
- `verify_provenance_complete` unmoved: M31 vendors nothing.
- `verify_pinned_nightly_single_source` unmoved: M31 declares no new `pins.json` anchor. The two
  revisions it pins are read from git — the aztec anchor from `pins.json`'s own value via the
  check, and the noir commit from `git ls-tree <anchor> noir/noir-repo`, so it is a *reading* of
  upstream's submodule pointer rather than a second declaration.

---

## Step 9 — the mutation matrix

Eleven arms, in `scratchpad/campaign/m31-mutations.sh`. Every arm records the failing assertion
TEXT; every mutated file is restored by CONTENT and then `touch`ed, and the restore is compared by
sha256 against a copy the script took, with the comparison shown on every run to notice a
one-character corruption. Every arm also asserts, AFTER the run, that its mutation is still there
— M30's review's finding, that a mutation silently undone and printed as the arm's result reads as
absent coverage of a property that is in fact covered.

| arm | broken | result |
|---|---|---|
| M1 | `avmt_transpile` echoes its input | 120 / **26** — every byte-identity assertion, in BOTH hosts |
| M2 | the page reports the INPUT's digest as the output's | 120 / **8** — the seven browser comparisons and the paired identity |
| M3 | the rung arm is fed the NOT-re-keyed map | 114 / **22** — the key-set comparison, per function |
| M4 | a rung-3 artifact is reported as rung 1 | 114 / **1** — exactly the labelling assertion |
| M5 | `counter_variant` becomes a copy of `counter` | 120 / **1** — the source-difference calibration |
| M6 | `revertCode` becomes the constant 0 | 59 / **2** — the reverting control and its non-constancy partner |
| M7 | `instructionsExecuted` becomes the constant 41 | 59 / **4** — all four non-degeneracy assertions |
| M8 | the neutrality baseline is patched too | **13 / 1** with a summary line — the build script's own guard refuses |
| M9 | a `__wbg_new0` import is PLANTED in the module | 120 / **4** — the import count, the needle, and both declared-count reads |
| M10 | **THE HANG** — the page never becomes ready | rc 1, `Runtime.evaluate did not complete within 30000 ms. That is the HANG state reported as a failure.` |
| M11 | **DIE BEFORE THE SUMMARY** | **62 / 1 WITH a summary line** — the abnormal-exit trap |

### 9.1 THE HARNESS FOUND A REAL DEFECT IN THE BUILD SCRIPT, AND IT FOUND IT BY GOING GREEN

**M8's first run was 80 / 0.** The arm patches the baseline tree and the build script's own guard
should refuse — and did not, because the guard's branch was never taken.

The cause is a **name collision**: `build_avm_transpiler_wasm.sh` read `M31_WORK` for its build
directory, and `lib_m31_transpiler.sh` **exports** `M31_WORK` as the ARM REPORT's directory. So a
check invoking the build script silently redirected the whole build tree into
`~/.cache/aztec-m31-arms/`, while the harness's `rm -rf "$BUILD_DIR/baseline"` deleted
`~/.cache/aztec-m31-transpiler/baseline`, which nothing was using. The stamp in the real directory
still matched, the baseline was not re-materialised, and the mutated branch never ran.

Nothing about the artefacts was wrong — both directories built the same thing from the same
revisions — but the arm reported "not detected" for a property that is in fact detected. The fix is
in the build script (`M31_BUILD_WORK`, its own name) rather than in the harness, because the
collision is the defect. Re-run: **13 / 1**, the guard refusing by name.

The arm now also asserts the mutation's EFFECT — the baseline tree is checked to be non-pristine
after the run — because a mutation whose text is present and whose effect is absent is exactly the
state that reads as "the check does not notice".

### 9.2 AND M9 TOOK THREE ATTEMPTS, EACH OF WHICH IS A DIFFERENT LESSON

1. **`getrandom_backend="wasm_js"` does not give the module a JS import.** That value is not in
   getrandom 0.4.1's backend dispatch at all (`src/backends.rs:10-38`), so the build falls through
   to the target arm and hits blocker 1's `compile_error!`. Measured: `0 / 1`, a build failure,
   with the import census never reached. Kept in the file as a comment, because it is also
   independent evidence for RI-79's decision: `wasm_js` cannot be selected without adding a
   feature, i.e. without adding a dependency.
2. **A planted import behind a provably-false branch is eliminated.** `if RESULT_LEN == usize::MAX`
   — every store into that cell is `0` or a `Vec::len()` — so LLVM removed the call, the import
   never entered the module, **the module rebuilt to the SAME 5,196,936 bytes**, and the arm
   reported **120 / 0**. A mutation defeated by the optimiser reads exactly like a check that does
   not notice. The arm now asserts the planted import is in the BUILT MODULE and `die`s if it is
   not.
3. **A planted import that is CALLED is detected by the wrong instrument.** The page's throwing
   recorder fires, the arms run exits 1, and the check dies at its precondition: `0 / 1`. Correct,
   but it is not the census. The arm is `#[used]`-kept and **never called** now, which is exactly
   the state the census exists for — `reachedImports` stays empty and the import section grows by
   one — and it reads **120 / 4**.

### 9.3 One more thing the matrix changed, in the arm runner rather than in a check

M1's first run was `0 / 1`: a transpiler that echoes its input makes the rung arm throw, and the
runner set `exitCode = 1`, so `m31_require_arms` refused the whole report and the IDENTITY check
died as a precondition failure **with zero assertions** instead of reporting the mismatches it
exists for. That is "a mutation that reddens has not exercised the assertion it was written for",
caused by the runner. The rung arm's failure is recorded and **not fatal** now —
`verify_transpiler_rung1_mapping_survives` §0 asserts `arms.rungError` is MISSING, so it goes red
for its own reason and nothing else does. M1 re-run: **120 / 26**.

### 9.4 The self-review pass, before the sweep, found two assertions that could not fail

Both in `verify_transpiler_wasm_output_identical_to_native`, both found by asking of each green
assertion what input would make it red:

1. **`assert_eq "…and the browser arm did not record an error" "MISSING" "$(m31_arm arms.error.message)"`.**
   The runner sets a non-zero exit when the browser arm throws, and `m31_require_arms` refuses the
   report on a non-zero exit — so the check cannot reach that line with `arms.error` present. It is
   replaced by three readings of what the page actually FETCHED (the module, M30's `wasm_host.mjs`,
   the fixture list), which are measurements of the run and can be red.
2. **`assert_eq "the transpiler came from the campaign anchor" "233d8e0993" "$M31_AZTEC_REV"`** —
   a literal compared against the build script's DEFAULT for the same value, i.e. two copies of one
   decision. The anchor is read from `pins.json` now, with a non-emptiness assertion beside it.

**The count moved 120 -> 123 and M31 373 -> 376**: minus one, plus three; minus one, plus two.
The sweep was stopped fourteen minutes in and restarted after these, because a sweep is a
measurement of the tree at the moment it ran.

---

## Step 10 — the sweep, taken after the last edit

`setsid`-detached, `direnv exec <aztec-avm-runtime>` (this repository's own dev shell, not the
workspace root's — M25's correction), `TMPDIR` and the log under `~/.cache`, one milestone at a
time with nothing else running. **64 markers for 32 milestones: no hole.** **31 of 32 exit 0.**

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 376
                                                       CAMPAIGN TOTAL 10,775
```

`10,396 + 376 + 3 = 10,775` exactly, and the summariser reports **`delta +0`** against a reference
table that names both moves in advance.

- **Every one of M0–M30 came out at its reference value TO THE ASSERTION**, with the single
  exception of M11, which moved for a reason M31 declared before the sweep ran.
- **M11 262, and both facts about it are separate.** The count is 259 -> **262** because M31 adds a
  sixth `aztec-*` directory under `codetracer-specs/upstream-bugs/` and declares it `not_carried`
  in `carry/series.json`; `verify_carry_set_complete` makes exactly three assertions per declared
  entry and reads **46** where it read 43. That is M31's doing and is accounted for in both
  directions. The **rc=1 with nine failing assertions** is not: it is the recorded signature of the
  ninth upstream move (`7471a61f1a`), unchanged, and `carry/` is left at HEAD rather than
  half-repaired.
- **M9 DID NOT FLAKE.** 807, 7/7, exit 0 in **1,282 s** — the reference exactly, and the third
  consecutive sweep in which `DRIFT.md` D19's standing hypothesis had its condition and did not
  fire.
- **A SWEEP IS A WRITER.** `carry/rebase.json` and `carry/exposure.json` were checksummed before
  (`aaeb6877…`, `ec959b84…`), came out of the sweep as `79f597b2…` and `3836c2b6…`, and were
  restored — `sha256sum` confirms both back at the pre-sweep digests. `carry/series.json` carries
  M31's one deliberate addition and is unchanged by the sweep.

### 10.1 Nothing else moved, and each is a reading rather than an inference

`verify_provenance_complete` 64 (**M31 vendors nothing** — no `PROVENANCE.md` row),
`verify_pinned_nightly_single_source` 28 (**no new `pins.json` anchor**: the aztec anchor is READ
from `pins.json` and the noir commit is READ from `git ls-tree <anchor> noir/noir-repo`, so both
are readings of declarations that already exist), `verify_reuse_inventory_complete` 19 (the entry
count assertion is `>= 20`, so RI-78..81 add none), `verify_no_pipeline_predicates` 69 (M31 adds no
`| grep -q` predicate; every `grep -c` in its checks computes into a variable first),
`verify_named_checks_exist` 9, `just check-repo-hygiene` 28 (no new path matches the generated-file
deny list), `verify_oq7_shared_writer_verdict_recorded` 65.

### 10.2 Final tree state

```
aztec-avm-runtime   M Justfile, M REUSE-INVENTORY.md, M carry/series.json,
                    ?? avm-transpiler-wasm/, ?? fixtures/transpiler-contracts/,
                    ?? orchestration/src/transpiled_contract_driver.ts,
                    ?? tools/run_transpiler_arms.mjs,
                    ?? verification/{build_avm_transpiler_wasm.sh,lib_m31_transpiler.sh,4 checks,m31/},
                    ?? scratchpad/campaign/m31-*
aztec-packages      clean — never written to
noir                clean — never written to
noir-wt4-webpage    M tooling/tracer/src/tracer_glue.rs   — EXACTLY as found
codetracer-specs    M Planned-Work/Aztec-AVM-Runtime.milestones.org, M upstream-bugs/SERIES.md,
                    ?? upstream-bugs/aztec-transpiler-core-ffi/
```

No commits and no pushes, in any repository.

---

## Step 11 — the prepared upstream contribution, EXECUTED

`codetracer-specs/upstream-bugs/aztec-transpiler-core-ffi/` — the patch, `PR.md`, `verify.sh`.

`verify.sh` was **run, not shipped unrun** — the artefact `CAMPAIGN-BRIEF.md`'s "IT DOES NOT BUILD
HERE IS A CLAIM" rule exists to prevent:

```
./verify.sh <aztec-packages> --noir <noir-repo> --artifacts <dir> --wasm
verify.sh: 37 assertion(s), 0 failure(s)
```

in two throwaway `git worktree`s at `233d8e0993`, one patched, both removed afterwards
(`aztec-packages` is clean and has the same 89 worktrees it started with). What it establishes on
upstream's own terms:

- the diff is four files, all under `avm-transpiler/`, `+3 / -7`, and the generated C header is
  **not among them** — asserted from the patch file rather than described;
- both trees build;
- **the transpiled output of all seven contract artifacts is byte-identical** between the pristine
  and patched binaries, with a non-emptiness assertion before each comparison and a calibration
  that the comparison CAN report a difference;
- `libc` leaves the crate's dependency list and **stays in the lock**, because other packages want
  it — both halves, because "the dependency is gone" is the wrong claim and an easy one to make;
- **the discriminator**: the pristine crate does NOT build for `wasm32-unknown-unknown` and
  **fails on exactly the import this patch removes** (the reason is checked, not just the exit
  status — a build that failed for some other cause would otherwise read as the patch's
  justification), and the patched crate does.

It also **refuses by name** when `noir/noir-repo` is absent, with the remedy, rather than failing
four crates deep — measured by running it without `--noir` first. And section 4 is *reported as
skipped* rather than passed when no `--artifacts` corpus is supplied, because two runs that both
produced nothing compare equal.

`avm_transpiler.h`'s digest is `03fb51b3725da80c…` in both trees. The one figure `PR.md` states
about the patch's shape — four files, +3 / -7 — is re-derived by `verify.sh` §1 and by
`verify_transpiler_native_build_unaffected` §1, so nothing in that document is a number only a
human wrote down.
