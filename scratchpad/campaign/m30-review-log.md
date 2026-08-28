# M30 — Compiling Noir from a Virtual Filesystem — REVIEW log

Written as I go. The implementation agent is stood down; nothing else is running.

State at start: `aztec-avm-runtime` on `dev` HEAD `efa7c07`, M30's work uncommitted;
`noir` on `blocktracer` HEAD `01cf48082` with 4 modified + 2 untracked files;
`codetracer-specs` with the M30 section modified; `noir-wt4-webpage` carrying **exactly**
`tooling/tracer/src/tracer_glue.rs` and nothing else — M26's one tolerated edit, as found.

---

## 0. The headline: the SSA pass timer

### 0.1 The diff is one behavioural line

`compiler/noirc_evaluator/src/ssa/builder.rs` — the helper now returns `f()` early when
`print_timings` is false, so the two `chrono::Utc::now()` reads happen only on the printing
path. The rest of the diff is a 17-line comment. **Behaviour is unchanged in both
directions**, read rather than assumed: with `print_timings` true the same two reads bracket
the same call and the same `println_to_stdout!` fires.

### 0.2 The gating claim — TRUE, but there are SIX call sites and not two

My own brief said "both call sites"; the count is **six**, and every one of them passes a
`print_codegen_timings` boolean:

```
compiler/noirc_evaluator/src/ssa/builder.rs:235   self.print_codegen_timings
compiler/noirc_evaluator/src/ssa/builder.rs:253   self.print_codegen_timings
compiler/noirc_evaluator/src/ssa/mod.rs:415       options.print_codegen_timings   (SSA to Brillig)
compiler/noirc_evaluator/src/ssa/mod.rs:424       options.print_codegen_timings   (underconstrained)
compiler/noirc_evaluator/src/ssa/mod.rs:432       options.print_codegen_timings   (brillig constraints)
compiler/noirc_evaluator/src/ssa/mod.rs:444       options.print_codegen_timings   (SSA to ACIR)
```

`mod.rs:38` is `use builder::time;`, so all six are the one helper. The gating claim holds
and is *wider* than the milestone states. Neither M30 nor the milestone claims "two", so this
is a correction to my brief, not to the work.

### 0.3 The module's imports — re-measured from the BYTES, not from the report

Parsed `noir/target/wasm32-unknown-unknown/release/noir_wasm.wasm` (14,418,442 B, sha256
`25460a02a2d8…`, matching the arm report) with an independent leb128 import/export walker:

```
import section: 28 entries
  __wbindgen_externref_xform__   2
  __wbindgen_placeholder__      26   (incl. __wbg_new0_f788a2397c7ca929, __wbg_getTime_46267b1c24877e30)
export section: nv_alloc, nv_compile_vfs, nv_free, nv_result_len  (+ memory, __data_end, __heap_base)
```

**28, two modules, both `__wbindgen_*`. No WASI, no `env`.** The claim is confirmed against
the artifact rather than against the arm report. Note that `__wbg_new0_…` (the `Date::new_0`
binding) is still **declared** — the fix removes the *call*, not the import — which is
exactly why "declared 28 / reached 0" is the honest pair.

### 0.4 The trap, and the zero, re-derived in a THIRD host

`node` was pointed straight at the module — `WebAssembly.instantiate` with every declared
import satisfied by a recorder that throws, no browser, no page, no CDP
(`scratchpad/hashprobe.mjs`). Result: **`reached imports: []`, `declared imports: 28`**, and
the three-file tree compiles. So the zero is not a property of the page's harness.

The trap itself was reproduced by the M9 mutation arm — see §2.

### 0.5 53 CLOCK READS PER COMPILE, MEASURED RATHER THAN ARGUED

`time()` instrumented with an `eprintln!` and one compile of the three-file tree run natively:
**53 calls**. Before the change each of those read `chrono::Utc::now()` **unconditionally**, so
a browser compile of a trivial program crossed into JavaScript 53 times to compute durations it
then discarded. That is the number the upstream contribution is argued from.

---

## 1. Baseline

`just verify-m30` in this repository's own dev shell:

```
test_vfs_multifile_compiles              67
test_vfs_compile_errors_carry_positions  41
e2e_vfs_edit_recompile_retrace           44
verify_git_dependency_refused_by_name    51
                                        203
```

203 confirmed, 4/4, exit 0.

---

## 2. The mutation matrix — ALL ELEVEN ARMS RE-RUN, and one does not survive

| arm | recorded | re-run by this review | verdict |
|---|---|---|---|
| M1 | 3 / 4 | **3 / 4**, with the summary line | reproduces |
| M2 | 51 / 2 | **51 / 2**, exactly the two "names itself" | reproduces |
| M3 | 51 / 5 | **51 / 5**, exactly the five position assertions | reproduces |
| M4 | 67 / 6 and 44 / 4 | **67 / 6 and 44 / 4** | reproduces |
| M5 | 67 / 2, native only | **67 / 2**, both in §9 | reproduces |
| M6 | 41 / 6 | **41 / 6** | reproduces |
| M7 | 41 / 3 | **41 / 3**, incl. the VFS-key assertion | reproduces |
| M8 | 44 / 1 | **44 / 1**, the join assertion | reproduces |
| M9 | arms run exits 1 naming `__wbg_new0_…` | **0 / 1**, named | reproduces |
| M10 | 0 / 1, the HANG named | **0 / 1**, named, at the 180 s bound | reproduces |
| M11 | 1 / 2 with a summary | **1 / 2 alone — 67 / 0 and 44 / 0 IN SEQUENCE** | **DOES NOT SURVIVE** |

### 2.1 M11 IS ORDER-DEPENDENT AND THE HARNESS CANNOT TELL "NOT DETECTED" FROM "NOT APPLIED"

Run as `m30-mutations.sh M10 M11`, the M11 arm reported

```
test_vfs_multifile_compiles: 67 assertion(s), 0 failure(s)   ### rc=0
e2e_vfs_edit_recompile_retrace: 44 assertion(s), 0 failure(s)   ### rc=0
```

— green, exit 0, and **nothing said the mutation had been undone**. Run alone it reproduces the
recorded 1 / 2 on both checks exactly.

The mechanism: `restore_all` `touch`es the stamped sources, so `build_noir_vfs_wasm.sh`'s
content stamp — which still names the *previous* arm's mutated content — rebuilds the module.
`m30_require_modules` runs BEFORE the staleness predicate, so the freshly built module is newer
than the hollowed report, `m30_require_arms` re-measures, and the hollow report is overwritten
before a single assertion reads it. The arm's own `touch "$ARM_REPORT"` cannot win that race
because the module is rebuilt after it.

This is the campaign's "a mutation that reddens has not exercised the assertion it was written
for", in its worst direction: a mutation that goes **green** and is printed as the arm's result.
An agent reading that sequential run would record "M11 is not detected" — the opposite of the
truth — or, as happened here, record 1 / 2 from a run in which it happened to work and never
learn that the arm is fragile.

**Fixed** (see §5.1): the arm now asserts, after the run, that the report it hollowed is still
hollow, and `die`s naming the cause if it was re-measured.
