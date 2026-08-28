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

---

## 3. The two assertions M30 declared could-not-fail — both fixes discriminate

**The decoy control.** Arm M4 (the resolver swallows the whole virtual filesystem), re-run:
`adding a .nr file outside src/ leaves the artifact hash unchanged  expected [848041253], got
[619517153]` in `test_vfs_multifile_compiles`, and `adding app/aaa_decoy.nr leaves the artifact
hash unchanged  expected [499034317], got [3382601085]` in the e2e. **Both fire.** The addition
form is a discriminator; the edit form was not.

**The dependency-sensitivity fixture.** Put back the version the milestone says went red —
`x + x + x - x` instead of `x + x + x` — and `test_vfs_multifile_compiles` reports **67
assertions, 1 failure**: `editing the DEPENDENCY's body changes the compiled bytecode (command
unexpectedly succeeded: … = …)`, the two base64 strings printed and identical. Confirmed: different
SOURCE, same CIRCUIT.

Worth recording, because it decides which of the pair is load-bearing: **the HASH assertion beside
it did NOT fire** on that arm. `x + x + x - x` is a different source, so the `FileId`-based hash
moves while the bytecode does not. For the dependency-sensitivity property the BYTECODE comparison
is the discriminator; for the decoy property the HASH is. The check says which is which in both
places, and it is right in both.

### 3.1 THE CALIBRATION PAIR THE MILESTONE PUBLISHED DOES NOT REPRODUCE

`1206613220 -> 4090147220` appears in four places (`CAMPAIGN-BRIEF.md`, the milestone section,
`tools/m30_vfs_trees.mjs` and `test_vfs_multifile_compiles.sh`) and nothing re-derives it. Re-taken
against the same module the checks build, driven from **node** with an empty import object:

```
base                 ok=true hash=1076565353  bc_sha=b5b89295db8465cd  sources=3
decoy UNDER src/     ok=true hash=848041253   bc_sha=b5b89295db8465cd  sources=4
decoy OUTSIDE src/   ok=true hash=1076565353  bc_sha=b5b89295db8465cd  sources=3
reached imports: []   declared imports: 28
```

The *claim* is exactly right — the hash moves, the bytecode is byte-identical, so the hash is the
discriminating reading. The *numbers* are not. The fixture moved under the figure, which is the
campaign's "a figure nobody re-derives rots" family.

**The remedy is not a corrected number.** `multifileDecoyAddedUnderSrc` is an arm now and the
calibration is three assertions taken on every run: the hash moves, the file is shown to be in
`plan.sources` (which is the mechanism), and the bytecode is still byte-identical. Neither number
appears anywhere.

---

## 4. Claim 5 — the cargo-mtime trap, reproduced in BOTH directions

Not accepted from the write-up. Reproduced end to end:

| step | module sha256 |
|---|---|
| baseline | `25460a02…` |
| `builder.rs` mutated, `build_noir_vfs_wasm.sh` | `4c8df828…` |
| `builder.rs` restored **with `cp -p`**, then a bare `cargo build --release` | **`4c8df828…`** |
| then `build_noir_vfs_wasm.sh` | `25460a02…` |

At the third step `sha256sum -c` confirms `builder.rs` is byte-identical to the original, its mtime
is `10:37:28` and the `noirc_evaluator` rlib's is `10:38:03` — the restored source is OLDER than
what was built from the mutated one, cargo declines to recompile, and **a bare `cargo build`
reports success while emitting the mutated module**. The build script's `touch` of its stamped
inputs is what recovers `25460a02…`. Both halves of the recorded fix are real and both are needed:
the harness's `cp` + `touch`, and the build script's `touch` for every other caller.

---

## 5. Claim 6 — the read-only guard on `noir-wt4-webpage` fires, both conjuncts

Not read; run. The worktree began and ended with **exactly** `M tooling/tracer/src/tracer_glue.rs`
and nothing else, and it was never committed.

**(a) an edit other than the tolerated one.** An untracked `.m30-review-probe` was created; the
build script refused:

> `the Noir worktree … carries edits other than tooling/tracer/src/tracer_glue.rs … Found: ?? .m30-review-probe`

**(b) a published HEAD.** `refs/remotes/m30-review-probe/head` was pointed at `f0e7edcd2` —
`for-each-ref --contains` went from `[]` to one ref — and the script refused:

> `the worktree's HEAD f0e7edcd20… is contained in published remote refs (refs/remotes/m30-review-probe/head). That contradicts JOIN-SHAPE.md §2 fact 7, which OQ-7's verdict rests on.`

The ref was deleted immediately and `for-each-ref --contains` is `[]` again. This is M24's review's
dangling-commit technique applied to the other direction, and it says the guard is an assertion
that can say no rather than one that has only ever said yes.

---

## 6. Claim 1 — the enumeration. WHO WAS RIGHT ABOUT `source-resolver`

**The implementation agent was right and my own brief was wrong.** `source-resolver`,
`source_resolver`, `initializeResolver`, `initialiseResolver`: **zero code hits** across all five
`noir` worktrees, `aztec-avm-runtime`, `aztec-packages` and every `node_modules` on the machine.
The only four hits anywhere are the agent's own prose in `m30-impl-log.md`. It is not merely absent
— it was **deleted upstream on 2023-12-14** (`57d2505d5`, *"chore!: remove unused 'source-resolver'
package (#3791)"*), immediately after `e3dcc21cb` made the file manager read-only to the compiler.
The pull-shaped callback was replaced by the push-shaped `PathToFileSourceMap` +
`file_manager_with_source_map`, which is the seam M30 extends. The brief that named it was two
years stale, and a check grepping for the old name would have asserted an absence that is true for
the wrong reason — which is exactly what the agent said.

The rest of the enumeration:

- **`PathToFileSourceMap` at `compile.rs:131-159`, `file_manager_with_source_map` at `:248-265`,
  `compile_new.rs:37`** — VERIFIED, cites accurate to the line.
- **`compiler/fm/src/lib.rs` has no `std::fs`** — VERIFIED literally: the only match for `fs` in
  that file is the doc comment at `:133`. Crate-wide it is nearly but not entirely pure —
  `file_map.rs:111` calls `std::env::current_dir().ok()` to shorten displayed names. Not a
  filesystem read, and `.ok()` makes it harmless on wasm, but "no `std::fs` in the file" is the
  claim that was made and it is the claim that holds.
- **`test/compiler/browser/compile.test.ts:30-35`** — **THE CITE IS FALSE.** Lines 26-43 are the
  `simple` case, and `test/fixtures/simple/Nargo.toml` has an **empty** `[dependencies]` table: it
  is the one case in that file with no dependency at all. The case that compiles a local `path`
  dependency is `deps`, at **:45-62**, over `test/fixtures/with-deps` → `deps/lib-a` → `deps/lib-b`
  — two levels, so the "transitively onto a second one" half is right. It is a real browser test
  (`web-test-runner` + `playwrightLauncher({ product: 'chromium' })`, run in CI at
  `.github/workflows/test-js-packages.yml:419`) and `memfs` really is how file access happens, but
  indirectly: `webpack.config.ts:88-89`'s `alias: { fs: 'memfs' }` in the **web** config, with
  `createFileManager` = `createNodejsFileManager` (`src/index.mts:129`). Worth stating plainly:
  that test proves the **TypeScript** stack works in a browser over memfs. It exercises no
  Rust-side manifest handling at all, which is precisely the gap M30 closes.

---

## 7. Claim 2 — the four gaps

| gap | verdict |
|---|---|
| the Rust side never parses `Nargo.toml` | **VERIFIED**, cites exact (`compile.rs:126-130`, `package.ts:127-132` behind `@ltd/j-toml`). Two details M30 did not have: `parseNoirPackageConfig` (`types/noir_package_config.ts:51-53`) is a **no-op cast** — `return config;`, no validation — and `@ltd/j-toml` is a **devDependency** only, working solely because webpack inlines it |
| no git-dependency refusal anywhere | **OVER-STATED.** One exists: `github-dependency-resolver.ts:49-51`, `throw new Error('Only github dependencies are supported')`. It is **unreachable** — `:35-37` has already `return null`ed for any non-github host, and the guard beside the throw compares a `URL` object with `null` — and it names no dependency. The effective behaviour is as M30 described. But the milestone also says the two needle hits are "both of the GitHub resolver declining a NON-github URL so the next resolver can try", and one of them is this throw, which is not that |
| `git clone`'s status discarded | **VERIFIED, and worse than stated.** `git.rs:51-64` ends `.status().expect("git clone command failed to start"); Ok(loc)`. `.expect` fires only if the process could not be **spawned**; the `ExitStatus` is never bound. A clone that exits non-zero yields `Ok(loc)`, and `nargo_toml/src/lib.rs:342,355` then reports a **missing manifest** at a path under `$HOME/nargo` — a misdiagnosis, not a failure |
| `[package].entry` ignored / honoured | **VERIFIED**, both cites exact (`package.ts:62-80` hard-codes; `nargo_toml/src/lib.rs:193-202` honours it and refuses a missing one naming the path). `entry?: string` is declared in the TS type at `noir_package_config.ts:16` and referenced nowhere else in `src/`, so with the no-op parser above it is silently dropped |
| `Diagnostic` carries byte offsets | **VERIFIED IN SUBSTANCE, TWO CORRECTIONS.** `DiagnosticLabel` is at `errors.rs:75-80`, not `:83-104` (that is `Diagnostic` + its `impl`). And "an INDEX printed as a line number" is too strong: `lineOffsets[i]` is the start offset of 0-based line `i`, so `findIndex(offset > start)` returns `k+1` for an error on 0-based line `k` — **the correct 1-based line**. It is accidentally right. The genuine defects are `-1` on a last-line error, `-1` for every position in a file `#resolveFile` cannot read (its `catch` returns `''` at `:176-183`), no column at all, and the secondary's own `message` never printed |

---

## 8. Claim 3 — M5, and whether "only the native suite sees it" was acceptable

It was not, and it is closed.

M5 makes the resolver ignore `[package].entry` — the shipped TypeScript's behaviour, and the
milestone's own "silent wrong answer". As delivered the arm reads **67 / 2, and both failures are
§9's `cargo test -p noir_wasm` assertions**. The deliverable says a page holding a tree of Noir
sources honours `Nargo.toml` including `entry`; the evidence offered for the `entry` clause was a
`cargo test` on the source the module is built from. That is an inference — a strong one, since the
build is content-stamped from that source — but it is not a measurement of the artefact, and this
campaign's standard is the artefact.

Two browser arms close it. `declaredEntry` declares `entry = "src/entry_point.nr"` **while leaving
`src/main.nr` in the tree with a different ABI** (`x, y` against `x`), so honouring the field and
ignoring it produce different **artifacts** and not merely different plans; `declaredEntryMissing`
names a root that is not there. Ten assertions, and the arm now reads **80 / 8, six of them in the
browser half**:

```
FAIL a manifest that declares [package].entry gets that file as its crate root
     expected [app/src/entry_point.nr], got [app/src/main.nr]
FAIL …and the module says the root was DECLARED rather than defaulted   expected [true], got [false]
FAIL …and the artifact is the declared root's                            expected [["x"]], got [["x","y"]]
FAIL a declared entry that is not in the tree is refused                 expected [missing-entry], got [None]
FAIL …naming the path the manifest asked for
FAIL …and saying it was DECLARED, not defaulted
```

The expected entry path and both ABIs are **derived from the fixture text** (`entryOf`,
`mainParamsOf`), not typed into the check.

---

## 9. Claim 4 revisited — TWO MORE ASSERTIONS THAT COULD NOT FAIL, one per browser check

M30 found two of its own and said so. There was a third shape, in both browser checks, and it is
the 36th instance of the family:

```bash
assert_eq "the trees the page compiled are byte-identical to the ones this check names" \
  "$(m30_arm trees.sha256)" "$(m30_arm trees.servedSha256)"
```

`run_vfs_arms.mjs` does `copyFileSync(TREES_SRC, SITE/m30_vfs_trees.mjs)` at the start of the run
and then, at the end, writes `sha256: sha(TREES_SRC)` and `servedSha256: sha(SITE/…)` into the same
report. **Two digests of one file, produced by one process, equal by construction.** The
description says "the ones this check names" — the check names nothing; it reads two numbers out of
the report the runner wrote.

The left-hand digest is taken by the check itself now (`sha256sum "$M30_TREES"`), which makes it a
comparison between two independently produced values. Demonstrated to discriminate: with the
fixture edited and the report `touch`ed past the staleness predicate,

```
FAIL the trees the page were served are the ones on disk now
     expected [a372fb3c…], got [450b56b6…]
test_vfs_multifile_compiles: 80 assertion(s), 1 failure(s)
```

and the old form was **green** in exactly that state — measured, not reasoned.

## 10. The mutation harness's own instrument, and the negative controls that hold

`verify_restore_control` is real: it corrupts a scratch copy by one character and the checker
reports it, on every run. Every arm's restore was verified byte-identical against a copy the script
took, and after all eleven arms the tree is `restore: every file is byte-identical to its
pre-mutation copy`.

The M11 guard added by this review carries its own control, exercised both ways: over the full
report the predicate exits 0 (the `die` would fire); over the hollowed report it exits 1 (it does
not).

---

## 11. Claim 8 — are the four Outstanding Tasks honestly open?

1. **The TypeScript resolver chain still fetches.** Open and honest. `verify_git_dependency_refused_by_name`
   §7 re-derives it from the three shipped files with a paired control (the same haystacks must NOT
   contain `git-dependency-refused`), so the day it changes the check says so. Independently
   confirmed: `noir-wasm-compiler.ts:71-79`, `github-dependency-resolver.ts:39-40` → `#fetchZipFromGithub`,
   `dependency-manager.ts:122-124`.
2. **`createMemFSFileManager`'s recursive readdir, recorded rather than fixed.** The bug is real
   and slightly worse than described: `for (const handle in contents)` over an array yields `"0"`,
   `"1"`, …, and `.isFile()` on a **string** throws `TypeError` — it does not merely return bare
   names. Is "recorded rather than fixed" defensible? **Yes, and the evidence the brief demands was
   missing and is supplied now.** None of the five `noir` worktrees has a `node_modules`; they are
   Yarn Berry and `.yarn/cache` is **empty (0 entries)**, so `yarn install` needs the network before
   `mocha` could run. And the three test files that construct a `createMemFSFileManager`
   (`file-manager`, `local-dependency-resolver`, `github-dependency-resolver`) never call `readdir`
   on it, so there is no existing test to extend either. A fix that cannot be executed is the
   artefact `CAMPAIGN-BRIEF.md`'s "IT DOES NOT BUILD HERE" rule exists to prevent — but that rule
   also says *say what you tried*, and M30 did not. It does now.
3. **The SSA-timer contribution was a candidate.** No longer — see §12.
4. **`[package].entry` diverges between the two paths.** Open, correctly: M30 closed its own half
   and the shipped TypeScript still hard-codes `main.nr`. Verified independently. Closing the other
   half is an upstream question.

None of the four is quietly abandoned; three are open with a check or a measurement behind them and
the fourth is done.

---

## 12. THE UPSTREAM SSA-TIMER PATCH — verdict and action

**Verdict: real, clean, and worth filing. Prepared.**

Everything the headline claims survived:

- **the trap**, reproduced by the M9 arm with the full frame list —
  `js_sys::Date::new_0` ← `chrono::offset::utc::Utc::now` ← `SsaBuilder::run_passes` ←
  `optimize_ssa_builder_into_acir` ← `create_program_with_passes` ← `create_program` ←
  `compile_no_check` ← `compile_main` ← `noir_wasm::vfs::compile_resolved`. (The milestone
  abbreviates the chain by two frames; the two it names are in it.)
- **the fix**, one behavioural line, verified to leave the printing path arithmetically identical;
- **the gating**, which is **seven** call sites at the upstream base and six in our fork, every one
  passing a `print_codegen_timings` flag;
- **the 1,079**, and now its baseline: `cargo test -p noirc_evaluator` is **1,079 passed, 0 failed**
  at the parent commit in a separate worktree with its own target directory, and **1,079 passed, 0
  failed** with the change. "Unchanged" is a comparison rather than a single reading.

**Action.** `codetracer-specs/upstream-bugs/noir-ssa-pass-timer-unconditional-clock/` — `PR.md`,
`0001-perf-ssa-read-the-pass-timer-s-clock-only-when-the-t.patch`, `verify.sh`. Base
`noir-lang/noir` @ `3d3a1ce78` (the same base as the other prepared Noir entry); the patch applies
there with a 31-line offset, and the function is byte-identical at that commit and at our tip, so
the offset is not a hazard.

`verify.sh` was **executed, not shipped unrun**: `24 assertions, 0 failures` at that base, and its
first two runs failed for real reasons that are now fixed — it looked for a flag spelled
`--print-codegen-timings` when the CLI spells it `--benchmark-codegen` (so §3 measured **zero**
timed passes and reported it as a failure rather than as a fact), and its "same labels in the same
order" assertion passed over two EMPTY label lists, caught by its own non-emptiness partner. Both
are the campaign's own families, met in a script written to demonstrate them.

What it establishes, on upstream's terms and executed in upstream's tree:

- all seven call sites, with the **residue printed** rather than a count compared, so a caller that
  reached the clock some other way appears as a named line;
- the CLI switch bound to the field it sets, read out of `noirc_driver` — without that assertion a
  renamed flag turns the whole cost measurement into a silent zero, which is precisely what the
  first run looked like;
- **79 timed passes** for a two-line program, which IS the count of discarded clock reads, because
  the benchmark flag prints one line per `time()` call — no instrumentation, and a maintainer can
  re-take it in one command;
- neutrality demonstrated in four ways, before and after in the same checkout: **1,992 passed / 0
  failed** both ways, a **byte-identical** compiled artifact (`4ac32d9a…`, 919 B), **79** timing
  lines both ways with the **same labels in the same order** (md5 `29941be9…`), and zero timing
  lines without the flag both ways.

`PR.md` argues it on upstream's own terms — a timer that reads a clock nobody will look at is work
on every compile on every target, and the function's own name implies the flag decides both —
states in the header that **upstream has no live defect** in its own `wasm-bindgen` configuration,
lists four verifications explicitly **not** performed (no wasm arm in `verify.sh`, no full-workspace
suite, no timing benchmark, `Combine artifacts` covered by the call-site assertion rather than by
execution), records the prior-art search, and discloses our motive at the end rather than leading
with it.

One thing the patch's comment had to change to be shippable: M30's version cited
`compiler/wasm/src/compile_vfs.rs`, a file upstream does not have. The comment is rewritten so it
stands alone in upstream's tree **and** is true in ours — the real change rather than a divergent
one, which is the convention's own instruction.

---

## 13. ONE MORE FINDING: THE MODULE'S CONTENT STAMP NAMES NINE FILES AND THE MODULE LINKS 711

`build_noir_vfs_wasm.sh`'s stamp is the sha256 of nine files — `vfs.rs`, `compile_vfs.rs`,
`compile.rs`, `compile_new.rs`, `errors.rs`, `lib.rs`, `Cargo.toml`, `.cargo/config.toml` and
`noirc_evaluator/src/ssa/builder.rs`. When the stamp matches, the script **exits before invoking
cargo at all**:

```bash
if [ "$FORCE" = 0 ] && [ -f "$OUT" ] && [ -f "$STAMP" ] && \
   [ "$(cat "$STAMP" 2>/dev/null)" = "$STAMP_WANT" ]; then
  say "up to date …"; printf '%s\n' "$OUT"; exit 0
fi
```

The module links the whole Noir compiler: **711 `.rs` files under `compiler/` and `tooling/`**. A
change to any of the other 702 leaves the stamp matching, so no cargo is run, the module on disk is
the one built before the change, and the four checks measure it and report green. That is the
campaign's "a mutated artefact outlived its restored source" with a wider aperture — the same
family M30's own harness met in `cp -p`, one level out.

It is not a hypothetical distinction from the mtime trap: the mtime trap needed cargo to be
*invoked* and decline; this one never invokes it.

**Cost of closing it, measured rather than guessed: 62 ms.** `find compiler tooling -name '*.rs'
-o -name 'Cargo.toml' | sort | xargs sha256sum | sha256sum` over 711 files takes 0.062 s on this
host, which is nothing beside the build it guards.

Deferred until after the sweep and then fixed, because `CAMPAIGN-BRIEF.md` says not to edit a shell
script while a run is reading it and `m30` is the last milestone in the sweep. See §15 for what was
re-measured afterwards.

---

## 14. AND THE NEEDLE CENSUS BEHIND THE DELIVERABLE DOES NOT REPRODUCE EITHER

`verify_git_dependency_refused_by_name`'s header, and the milestone section, both say:

> `grep -rn 'refus|not supported|only github'` over `compiler/wasm/src`, `tooling/nargo_toml/src`
> and `tooling/tracer_wasm/src` finds exactly two hits, and both are about the GitHub resolver
> declining a NON-github URL so the next resolver can try.

Re-measured. Excluding M30's own files, over exactly those three trees, there is **one** hit:

```
compiler/wasm/src/noir/dependencies/github-dependency-resolver.ts:50:
    throw new Error('Only github dependencies are supported');
```

`tooling/tracer_wasm/src` (which exists only in the `wasm/webpage` worktree) has **zero**.

Three things are wrong with the published sentence and one of them is structural:

1. **The count is one, not two.** Whatever the second was, it is not in the trees named.
2. **The hit is not "declining so the next resolver can try".** It is an unreachable `throw`:
   `resolveDependency` has already `return null`ed at `:35-37` for any non-github host, and the
   guard beside the throw compares a `URL` object with `null`, which is always true. The
   *decline-and-continue* is the `return null` at `:35-37`, which the needles do not match at all.
3. **The census has already gone stale inside its own repository.** Run today over the same three
   trees *without* excluding M30's own work it is about forty hits, because `vfs.rs` and
   `compile_vfs.rs` live in `compiler/wasm/src` and are full of the word. A census whose haystack
   now contains the thing it was counting the absence of is the campaign's "ask what the haystack
   is" family.

The header is corrected to state the measurement that is stable — one pre-existing hit, unreachable,
naming nothing — and to say which trees it excludes and why. §7's three re-derived facts, each with
a paired negative control, are what actually hold the deliverable up and they were sound.

---

## 15. THE SWEEP — 10,396, taken after the last commit

`setsid`-detached, `direnv exec <aztec-avm-runtime>` (this repository's own dev shell, not the
workspace root's), one milestone at a time with nothing else running, `TMPDIR` and the log under
`~/.cache`. **62 markers for 31 milestones: no hole.** 30 of 31 exit 0.

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218
                                                       CAMPAIGN TOTAL 10,396
```

**M30's REVIEW MOVED EXACTLY ONE MILESTONE AND IT IS M30's OWN.** 203 -> **218**, and the
summariser reports `delta +15` against the reference table with **every one of M0-M29 at its
reference value TO THE ASSERTION**. 10,381 + 15 = 10,396 exactly. The fifteen are in two checks
and nothing else:

| check | delivered | now | the units |
|---|---|---|---|
| `test_vfs_multifile_compiles` | 67 | **80** | +3 the decoy calibration arm (the hash moves, the file is in `plan.sources`, the bytecode is still identical); +10 `[package].entry` in the browser (the absence guard, the declared root, `entry_was_declared`, the ABI, the two ABIs differing, `main.nr` still a source, the refusal's kind, its path, its `[package].entry` wording, and the default-root refusal NOT carrying that wording) |
| `test_vfs_compile_errors_carry_positions` | 41 | **43** | +2 the `Diagnostic` envelope pinned beside its label — the header claims "no line and no column anywhere" and that half was not read out of the file |

3 + 10 = 13, and 2, and 13 + 2 = 15. **Nothing else moved**, each re-run rather than inferred:
`m0` 156 (128 plus `just check-repo-hygiene`'s 28, whose printed name contains a space),
`m1` 175, `verify_provenance_complete` 64, `verify_pinned_nightly_single_source` 28,
`verify_no_pipeline_predicates` 69, `verify_reuse_inventory_complete` 19 (the entry count check is
`>= 20`, and the review edited two `why:` fields rather than adding rows),
`verify_named_checks_exist` 9, `verify_oq7_shared_writer_verdict_recorded` 65.

- **M9 DID NOT FLAKE.** 807, 7/7, exit 0 in **1,281 s**, immediately after m8's build — which is
  `DRIFT.md` D19's standing hypothesis, and it did not fire. Two sweeps in a row now.
- **M11 IS THE ONE RED, AND IT IS STILL THE NINTH UPSTREAM MOVE.** 259 with **nine** failing
  assertions and the count unchanged, at tip `7471a61f1a` — the recorded signature exactly, and
  upstream did not move a tenth time during this run. Not repaired: the seventh move's
  `barretenberg/cpp` conjunct is still open (`upstream changed no path under barretenberg/cpp …
  expected [0], got [5]`) and `carry/` is left at HEAD rather than half-repaired.
- **A SWEEP IS A WRITER.** `carry/rebase.json` and `carry/exposure.json` were checksummed before
  (`aaeb6877…`, `ec959b84…`), came out of the sweep as `79f597b2…` and `3836c2b6…`, and were
  restored — `sha256sum -c` confirms both back at the pre-sweep digests.

### 15.1 What changed AFTER the sweep, and what was re-measured for it

Three things, all confined to `m30` and to prose, and each re-measured rather than assumed:

1. **`build_noir_vfs_wasm.sh`'s stamp is the whole tree now** (§13). Deferred past the sweep
   because `m30` is the last milestone in it and the brief forbids editing a script a run is
   reading. **Its discriminator was measured both ways**: with the old nine-file stamp a change to
   `compiler/noirc_frontend/src/lib.rs` left the script printing `up to date`; with the new one the
   same change prints `building …`. The `noir` tree was restored and is clean.
2. **`verify_git_dependency_refused_by_name`'s header census** (§14) and **RI-76's two line
   citations** — prose only, no assertion touched.
3. `just verify-m30` re-run after all three: **80 / 43 / 44 / 51 = 218**, unchanged; and `m0`
   (156) and `m1` (175) re-run because they are the two milestones that scan this repository's own
   files, both at reference.
