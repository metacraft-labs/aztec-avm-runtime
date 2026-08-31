# Mainline Merge Log — landing the campaign's side branches

Written **as I go**. Every figure is measured at the moment the line was written, with the command
recorded. Nothing is inherited from `m37-review-log.md` without re-derivation.

Task: merge two side branches onto their mainlines — `codetracer-trace-format` FIRST (noir depends
on it), then `noir` — and re-measure the full campaign sweep against the merged mainlines.

---

## Step 0 — preconditions, measured

`CAMPAIGN-BRIEF.md` read in full (2,679 lines). `m37-review-log.md` read in full (657 lines).

**No live sweep.** `ps aux | grep -iE 'verify-m|verify-l|verify_|just |sweep'` returns five
processes and **all five are stale `tail -f`** (Aug 24 / 26 / 28 / 30, plus M37's review at 00:01).
No `just verify-*`, no check script, no python summariser.

### The four repositories as inherited

| repo | branch | HEAD | status |
|---|---|---|---|
| `codetracer-trace-format` | `blocktracer` | `4bf7ea2` | clean |
| `noir` | `blocktracer` | `7e77c87c1` | clean |
| `aztec-avm-runtime` | `dev` | (see Step 0b) | (see Step 0b) |
| `codetracer-specs` | `latest` | (see Step 0b) | (see Step 0b) |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | ` M tooling/tracer/src/tracer_glue.rs` |

### `noir-wt4-webpage` — the BEFORE reading, taken before anything else ran

```
$ git -C noir-wt4-webpage rev-parse HEAD            f0e7edcd20dc667f789827563e2b2c780b368552
$ git -C noir-wt4-webpage status --porcelain         M tooling/tracer/src/tracer_glue.rs
$ git -C noir-wt4-webpage rev-parse --abbrev-ref HEAD  wasm/webpage
$ git -C noir-wt4-webpage ls-remote origin | wc -l   65
$ ... | grep -ci webpage                             0
$ ... | grep -c f0e7edcd2                            0
```

**`wasm/webpage` is in ZERO published refs**, and the branch's tip commit is in none either. This is
fact 7 of OQ-7's verdict and it is the state I must leave it in. Recorded before, to be re-taken
after.

### `aztec-avm-runtime` and `codetracer-specs` — verified as needing no merge, not assumed

```
$ git -C aztec-avm-runtime fetch origin; git rev-list --left-right --count HEAD...origin/dev   0  0
$ git -C aztec-avm-runtime status --porcelain    ?? scratchpad/campaign/mainline-merge-log.md   (this file)
$ git -C codetracer-specs  fetch origin; git rev-list --left-right --count HEAD...origin/latest 0  0
$ git -C codetracer-specs  status --porcelain    (empty)
```

Both are **0 ahead / 0 behind their own mainline**, on the mainline itself (`dev` / `latest`), with
nothing uncommitted but this log. There is nothing to merge and nothing to rebase. They are left
alone.

`carry/*.json` checksummed before anything ran (a sweep is a writer, and so is `verify-m11`) — and
**working tree equals HEAD for all four**, which is M37's committed-repair state:

```
3836c2b6…  carry/exposure.json      bec69bce…  carry/overlap.json
79f597b2…  carry/rebase.json        da229896…  carry/series.json
```

---

## Step 1 — `codetracer-trace-format`: the target branch is `dev`, and it is not a judgement call

Five independent lines of evidence, every one of them read out of the repository or the policy it
declares rather than inferred:

1. **The policy states it in as many words.** `metacraft-dev-guidelines/policies/branching-policy.md`:
   *"`stable` is the default branch on GitHub … `stable` represents the latest stable release, not
   ongoing development … **Direct pushes to `stable` should be disabled except for tightly
   controlled release automation**"*, against *"`dev` is the starting point for normal feature
   branches. Pull requests for ordinary development should target `dev`"*. Its Normal Change Flow is
   *feature → `dev` → `staging` → `stable`*. Merging a feature branch into `stable` is not a
   different choice, it is the one the policy forbids.
2. **The repo's own history says the same thing, and one of its merge commits cites the policy by
   name.** `8abbb03`'s body: *"Integrates the js-support work into dev as a single integration unit,
   per the branching policy's guidance that dev uses merge commits for feature integration."*
3. **Measured divergence.** `dev` and `stable` share history to `6646afa` (2026-08-11, *"merge:
   reconcile dev and stable"*). Since then `dev` took **3 substantive fix commits** (two `fix(ctfs)`,
   one `fix(writer-nim)`) and `stable` took **1 CI-only commit** (`54ef5d6`, repinning
   `metacraft-github-actions` from `@main` to `@dev` — three workflow files, 8 insertions, 8
   deletions, no source). Code lands on `dev`; `stable` receives it by reconcile merges
   (`6646afa`, `8abbb03`, `c4b101e`, `e7427f5`).
4. **`dev` is closer in subject matter, which is what makes it the right merge rather than merely
   the licensed one.** The three commits `dev` has and the three `blocktracer` has touch the same
   subsystem, and there is exactly **one file both lines touch**:
   `codetracer_trace_writer_nim/src/lib.rs`. `stable`'s one commit touches only `.github/`, so
   merging there would be conflict-free *because it defers the only integration that matters*.
5. **CI treats `dev` as first-class.** `.github/workflows/ci-reprobuild.yml` triggers on push and PR
   to `[main, dev, stable]`.

**Landing on `dev` is also what puts the fix in front of other consumers**, which is the stated
reason this repo goes first: `dev` is the branch the policy calls *"safe for developers and agents
to pull as the current integration baseline"*. Reaching `stable` is a **release promotion**, a
separate decision on this repo's own cadence, and taking it here would be scope I was not given and
a policy violation besides.

### The pre-merge baseline reproduces the reference exactly

`direnv exec <repo> cargo test --workspace`, `setsid`-detached, `TMPDIR` under `~/.cache`, summed by
counting `test result:` lines rather than reading the last one:

| tree | rev | binaries | passed | failed |
|---|---|---|---|---|
| `blocktracer` (the side branch) | `4bf7ea2` | **63** | **340** | **0** |

**340 / 0 / 63 — the last-known-good, to the assertion.** So the reference had not moved before I
touched anything, and any later movement is attributable.

### The merge: CLEAN, zero conflicts

```
$ git checkout dev && git merge --ff-only origin/dev      -> 392c555
$ git merge-tree --write-tree --messages HEAD blocktracer  rc=0
$ git merge --no-ff --no-commit blocktracer
  Auto-merging codetracer_trace_writer_nim/src/lib.rs
  Automatic merge went well
```

**No conflicts.** The one file both lines touched auto-merged. Grepped for all four diff3 markers
(`<<<<<<<`, `|||||||`, `=======`, `>>>>>>>`) across the tree afterwards — **zero**.

Merge commit: **`235e377`** *"merge: land the column-aware writer and the pledged zstd frames"*.

### The suite after the merge — and the number MOVED, so here is why, in both directions

| tree | rev | binaries | passed | failed |
|---|---|---|---|---|
| `dev` alone, pre-merge | `392c555` | 62 | **319** | 0 |
| `blocktracer` alone | `4bf7ea2` | 63 | **340** | 0 |
| **the merge result** | `235e377` | **64** | **353** | **0** |

353 is not a regression and not growth from the merge: it is the union of two disjoint sets of
tests, and **every unit closes from both ends**, taken from the per-binary split rather than from
the totals:

*From `dev`'s side — what the branch adds (+34, +2 binaries):*

| binary | dev alone | merged | delta |
|---|---|---|---|
| `tests/no_streaming_zstd_in_writers` | *(absent)* | 2 | **+2, +1 binary** |
| `tests/writer_differential` | *(absent)* | 12 | **+12, +1 binary** |
| `unittests src/lib.rs \| codetracer_ctfs` | 53 | 58 | **+5** |
| `unittests src/lib.rs \| codetracer_trace_writer` | 31 | 46 | **+15** |

2 + 12 + 5 + 15 = **34**, and 319 + 34 = **353** exactly.

*From the branch's side — what `dev` adds (+13, +1 binary), all of it from the three commits `dev`
already had:*

| binary | blocktracer | merged | delta |
|---|---|---|---|
| `tests/partial_tail_bounds` | 8 | 9 | **+1** |
| `tests/writer_null_data_block` | 4 | 8 | **+4** |
| `tests/unsupported_records_are_not_discarded_silently` | *(absent)* | 8 | **+8, +1 binary** |

1 + 4 + 8 = **13**, and 340 + 13 = **353** exactly.

**Both directions close, and no binary lost a single test.** The merge is purely additive: the diff
of the two per-binary splits contains only additions and increases, in either direction. That is the
measurement that says the merge did not silently drop a test — a total alone could not have said it.

### Pushed, and what was verified afterwards

```
$ git push origin dev        392c555..235e377  dev -> dev     (fast-forward, no force)
```

| property | measured after the push |
|---|---|
| `origin/blocktracer` still exists, at its tip | `4bf7ea2` ✓ **not deleted** |
| `origin/wasm/ctfs-writer` still exists | `592fa42cbf` ✓ |
| the campaign's `pins.json` anchor `592fa42cbf` still reachable from a published ref | **1** `refs/remotes` ref contains it ✓ (`verify_ct_writer_wasm_zero_imports`'s property holds) |
| the three commits are on the mainline | `ad17f22`, `a7de3ec`, `4bf7ea2` all ancestors of `origin/dev` ✓ |
| `origin/stable` untouched | `54ef5d6`, unchanged ✓ |

Note the pin is deliberately **not** advanced: `592fa42cbf` is a commit on `wasm/ctfs-writer` and
`pins.json` pins a commit rather than following a branch, so the merge does not move it and does not
need to. Its publication property is unaffected.

---

## Step 2 — `noir`: a real merge, and the branch is smaller than it looks

`origin/codetracer` is the default branch and the only mainline candidate — there is no second
one — so the target needed no argument. What needed one is **what to do at each conflict**, and
the answer came out of a measurement rather than a reading.

### THE FINDING THAT SHAPED EVERY RESOLUTION: two of the seven are ALREADY on the mainline

`git cherry -v origin/codetracer HEAD f403193bb` (single merge base, `git merge-base --all`
returns exactly `f403193bb`):

| our commit | subject | status on `codetracer` |
|---|---|---|
| `eb8b28c27` | render `Field` as fixed-width hex | `+` **new** |
| `01cf48082` | repin the fixture expectations | `+` **new** |
| `fe4b0c1e4` | compile a Noir package tree from an in-memory VFS | `+` by patch-id, but **superseded** — see below |
| `4d2381630` | read the pass timer's clock only when printed | **`-` ALREADY THERE**, identical patch-id to `bb7119984` |
| `a74f565be` | merge: reconcile with the beta.26 base | superseded by `072c27d8e` |
| `5e8e6d03e` | the ACIR optimizers moved into compilation | **subsumed** — see below |
| `7e77c87c1` | the out-of-range last step is the tree's defect | `+` **new** |

`61960c8ee` and `bb7119984` on `origin/codetracer` are **the same work by the same author**
(`Zahary Karadjov`, 2026-08-30 17:51) re-landed onto the mainline two days after the branch wrote
them (2026-08-28 10:54), carried onto the beta.26 base. So the branch's VFS half had already been
promoted, in an evolved form, and the merge's job for those files is to recognise that rather than
to re-apply it.

### The four conflicts, and how each was resolved

`git merge --no-commit blocktracer` on `codetracer` (so **ours = the mainline**, **theirs = the
branch**) — four conflicts, previewed first with `git merge-tree --write-tree --messages`, which
touches nothing:

#### 1 & 2. `compiler/wasm/src/vfs.rs`, `compiler/wasm/src/compile_vfs.rs` (add/add) → **took the mainline, byte for byte**

Not because the mainline wins by default, but because it was **measured to be a strict superset**.
Enumerating every `fn` / `struct` / `enum` / `impl` / `const` / `type` and every `#[test]` on both
sides and diffing the sets:

| file | symbols only in the branch | tests, branch → mainline |
|---|---|---|
| `vfs.rs` | **none** | 21 → **22** (`the_debug_mode_instruments_the_program_and_the_program_mode_does_not`) |
| `compile_vfs.rs` | **none** | 6 → 6 |

Nothing in the branch's copy is absent from the mainline's. The mainline additionally carries the
branch's own `5e8e6d03e` fix — its contract arm says *"No `nargo::ops::optimize_contract` here …
`08f44a128` … deleted `tooling/nargo/src/ops/optimize.rs`"*, which is the same fact in the same
place — plus a `for_debugging` parameter and `mode: "debug"`. Resolved with `git checkout --ours`
and then **verified by hash**: both resolved blobs are byte-identical to
`origin/codetracer:<path>`.

#### 3. `tooling/tracer/src/tracer_glue.rs` (content) → **the mainline's structure, the branch's semantics**

**One** conflicted region, and it is exactly the `Field` arm. The mainline had renamed the whole
file's trait from `TraceWriter` to `TraceSink` and changed `begin_trace`/`finish_trace`'s
signatures; the branch had changed one match arm's rendering. Orthogonal, textually adjacent.
Resolved by taking the branch's body and applying the mainline's rename to it
(`TraceWriter::ensure_type_id` → `TraceSink::ensure_type_id`).

Verified rather than eyeballed — the resolved file against `origin/codetracer`'s is **50
insertions, 2 deletions**, and the two deletions are exactly the two lines the branch replaces:

```
-use acvm::acir::AcirField; // necessary, for `to_i128` to work
+use acvm::acir::AcirField; // necessary, for `to_i128` and `to_hex` to work
+fn field_to_hex(field_value: &FieldElement) -> String { format!("0x{}", field_value.to_hex()) }
-                ValueRecord::Int { i: field_value.to_i128() as i64, type_id }
+                ValueRecord::String { text: field_to_hex(field_value), type_id }
```

The one surviving `TraceWriter` in the file is `NimTraceWriter` in a doc comment, present
identically on the mainline.

#### 4. `tooling/tracer/tests/test_tracer.rs` (content) → **the union, and one real decision**

Four conflicted regions, **all four in the locator/skip machinery** — the six shared test bodies
did not conflict at all, and the reason is worth stating because it is what made this tractable:
**the mainline changed none of the six.** Measured by extracting each `fn` body at base, ours and
theirs and comparing digests, with the extractor calibrated first (a name that does not exist
yields 0 lines; the branch-only test yields 49 lines in the branch and 0 on the mainline):

| test | base | branch | mainline |
|---|---|---|---|
| `a_1_mul`, `if_then_else_reduced` | — | unchanged | unchanged |
| `a_2_function_calls`, `assert`, `types_test`, `multi_stmt_per_line` | — | **changed** | unchanged |

**The decision: both lines had independently grown a panic-by-default guard**, with different
names — the branch's `refuse_or_skip` / `NOIR_TRACER_ALLOW_SKIP`, the mainline's
`missing_prerequisite` / `skipping_allowed` / `CODETRACER_TRACER_TESTS_ALLOW_SKIP`. Same finding,
derived twice, which is corroboration rather than conflict. **The mainline's survives**, on
evidence and not on precedence:

* `CODETRACER_TRACER_TESTS_ALLOW_SKIP` is named by a **specification** — `codetracer-specs`
  `Verno-Noir-Sync-Survey.md:224` and `Verno-CodeTracer-Integration.milestones.org:381`.
  `NOIR_TRACER_ALLOW_SKIP` is named in **no spec and no check** — grepped across
  `aztec-avm-runtime`, `codetracer-specs` and `noir`, its only occurrences are this campaign's own
  prose (`CAMPAIGN-BRIEF.md:902` and two scratchpad logs). **So renaming it moves no assertion**,
  which is the measurement that made this safe.
* The mainline's `test_source_views_embed_the_compiled_source` names that variable in its own
  panic text, so keeping the branch's would have meant editing a test to suit a merge.

The branch's now-orphaned `refuse_or_skip` was **deleted, not left**: a second guard naming a
variable that no longer does anything is this brief's *"a citation is the opposite of a
dependency"* waiting for a reader with `grep`. Its one unique asset — the **measurement**
(`ok. 6 passed; 0 failed` in **0.00 s** with `CARGO_TARGET_DIR` pointed away, over a tree whose
real result is 3 pass / 3 fail) — is folded into `skipping_allowed`'s doc, because the mainline's
version described the defect without measuring it.

**Result: nine tests, and each body is byte-identical to where it came from** — the branch's seven
match `blocktracer:`, the mainline's two (`while_loop`, `source_views`) match `origin/codetracer:`.
`field_small_int`, the helper the branch's `Field` expectations go through, auto-merged in. The
merged module header is 149 `//!` lines against the branch's 143 and the mainline's 44; the **8**
branch header lines not carried are, one at a time, the superseded pre-guard `SKIP:` prose and the
stale *"five fixtures (out of 20)"* count, each replaced by a truer mainline line. The
type-table measurement `tracer_glue.rs` points at (*"`tests/test_tracer.rs`' header carries the
full measurement"*) **is present**, so that pointer is not left dangling.

`rustfmt --check` was red on one hunk (the branch was not rustfmt'd, the mainline is, after
`4f49a6e96`); rustfmt applied, and the diff it made is **exactly** that hunk. Re-checked clean —
with a control, because the first reading of `rc` was `grep`'s and not `rustfmt`'s, which is this
brief's own pipe-status defect met in my own instrument: a deliberately misformatted copy gives
`rc=1`, so the checker can say no.

**All four diff3 markers grepped across the worktree afterwards: zero.**
Merge commit **`6c590c778`**.

### The suite on the merge result, with `nargo` rebuilt each time

`cargo test -p noir_tracer --test test_tracer` **does not rebuild `nargo`**, and these tests SPAWN
it — this campaign's own rule, and a stale binary would have measured the old recorder against the
new expectations. Every run below rebuilt `nargo` first, in the sibling
`codetracer-trace-format` dev shell (`noir` has **no `.envrc`**; `codetracer_trace_writer_nim`'s
`build.rs` needs `nim` on PATH — confirmed present: `nim 2.2.8`, `nimble 0.20.1`).

| noir | trace-format | tests | result | elapsed |
|---|---|---|---|---|
| `blocktracer` `7e77c87c1` | `blocktracer` `4bf7ea2` | 7 | **7 passed, 0 failed** | **0.60 s** |
| `blocktracer` `7e77c87c1` | **`dev` merged** `235e377` | 7 | **7 passed, 0 failed** | **0.61 s** |
| **`codetracer` merged** `6c590c778` | **`dev` merged** `235e377` | **9** | **9 passed, 0 failed** | **0.63 s** |

Row 1 reproduces M37's review's reference (it reported 7 / 0 in 0.57 s; the task's *"6 passed"* is
the figure from before that review added the seventh test). **Row 2 is the control that matters
for ordering**: the trace-format merge, with `nargo` genuinely relinked (`codetracer_trace_writer_nim`
→ `noir_tracer` → `nargo_cli` recompiled, binary 59,000,904 → 54,788,904 bytes), **moves the noir
suite by nothing**. Row 3 is +2 and both are the mainline's own tests.

### "VERIFY THE TESTS ACTUALLY RAN" — calibrated in both directions, not inferred

The campaign's warning is that this suite once reported `6 passed` in **0.00 s** over a tree that
ran nothing, because `cargo test` captures the `SKIP:` stderr of a *passing* test.

* **Elapsed 0.63 s**, not 0.00 s, and `grep -c "SKIP:"` over the run's log is **0**.
* **A first control did NOT reach the guard, and saying so matters**: pointing
  `CODETRACER_NARGO_BIN` at a nonexistent path left the suite green, because the locator treats
  the variable as a *preference* and falls back to the workspace binaries. A control that passes
  for a reason that is not the one it names is this brief's commonest defect; it is reported here
  rather than quietly replaced.
* **The control that does reach it**: both workspace `nargo` binaries moved aside, no opt-out →
  **`FAILED. 0 passed; 9 failed`**. The guard panics on every test.
* **And the opt-out arm, which found something.** With `CODETRACER_TRACER_TESTS_ALLOW_SKIP=1` and
  the binaries still absent: **`FAILED. 8 passed; 1 failed`** — `test_source_views_embed_the_compiled_source`
  is deliberately un-skippable and reddens anyway. **That closes outstanding item 9 of M37's
  review** (*"`NOIR_TRACER_ALLOW_SKIP=1` still prints `ok. 7 passed … 0.00 s` with nothing marking
  the run vacuous, so a CI job that ever sets it inherits the whole original defect"*). Under the
  merged guard the opt-out **cannot** produce an all-green run. It is closed by the mainline's
  design, not by anything I wrote.
* Binaries restored under a trap and the restore **verified by inode, size and mtime** — identical,
  no `.calib` leftovers.

### Pushed, and what was verified afterwards

```
$ git push origin codetracer   61960c8ee..6c590c778  codetracer -> codetracer   (fast-forward, no force)
```

| property | measured after |
|---|---|
| all seven branch commits reachable from `origin/codetracer` | ✓ seven of seven |
| `origin/blocktracer` still exists, at its tip | `7e77c87c1` ✓ **not deleted** |
| `noir-wt4-webpage` HEAD | `f0e7edcd2` ✓ unchanged |
| `noir-wt4-webpage` working tree | ` M tooling/tracer/src/tracer_glue.rs` ✓ **the same one pre-existing edit**, untouched |
| `noir-wt4-webpage` branch | `wasm/webpage` ✓ |
| **`wasm/webpage` in published refs** | 65 refs listed, **0 match `webpage`**, **0 contain `f0e7edcd2`** — identical to the BEFORE reading ✓ |

### A rot this merge introduces, declared rather than left to be found

`SOURCE-MAPPING.md` cites the `Field` arm as `noir/tooling/tracer/src/tracer_glue.rs:160-189`, and
`test_fr_rendering_matches_noir_tracer` asserts that string is **in the document**, not that it
matches the file — so it stays green either way. The arm is now at **162–211** (it was 160–209 on
the branch, so the cited end was already off by twenty before this merge; the start moves by two).
Every one of M25's *substantive* needles was re-checked against the merged file before the sweep
and all hold: the arm extracts at 51 non-empty lines (floor 8), the glue reads back 426 (floor
300), `ValueRecord::String { text: field_to_hex(field_value), type_id }` present,
`format!("0x{}", field_value.to_hex())` present, `PrintableType::Field => (TypeKind::Int,
"Field".to_string()),` present, the `to_i128` rendering **absent from the arm** and **present in
the file** (its own control). Not corrected here, because editing the document would redden the
check that pins its text, and editing the check is a change to the campaign's own instrument that
this task does not license.

---

## Step 3 — THE RE-MEASURED SWEEP: **12,141, delta +0, and NOT ONE MILESTONE MOVED**

Measured M0–M37 on 2026-08-31 **against the merged mainlines** — `codetracer-trace-format` at
`dev` `235e377` and `noir` at `codetracer` `6c590c778`, both pushed — `setsid`-detached in this
repository's own dev shell (node **v24.19.0**), one milestone at a time with nothing else running,
`TMPDIR` and the log under `~/.cache`. **76 markers for 38 milestones, NO HOLE.**

Pre-flight, each measured rather than assumed: no `verify-m`/`verify-l` process in flight (five
`ps` hits, all of them stale `tail -f`); `HEAD == origin/dev` at 0/0 after a fetch, so nothing to
rebase; a **write probe** (512 MiB actually written, not `statvfs`) with 160 GB free on `/home`.

```
m0 156   m1 181   m2 293   m3 199   m4 218   m5 236   m6 363   m7 287   m8 516   m9 807
m10 450  m11 287  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 265  m23 509  m24 350  m25 273  m26 340  m27 345
m28 357  m29 127  m30 218  m31 421  m32 237  m33 248  m34 217  m35 239  m36 140
m37 171
                                                       CAMPAIGN TOTAL 12,141
```

**`delta +0`. Every one of the thirty-eight came out at its reference value TO THE ASSERTION.**
Three failing assertions, three non-zero exits, and **all three are the L-tracks' recorded reds** —
there is nothing to account for in either direction, because nothing moved in either direction.
That is the answer to the question this exercise asked: the 12,141 was measured with `noir` and
`codetracer-trace-format` on side branches, and it is the same 12,141 with both on their mainlines.

### What that rests on, since "nothing moved" is the easiest result to get wrongly

* **M9 did not flake** — 807, rc 0, **1,281 s**, split **140 / 143 / 113 / 73 / 126 / 83 / 129**,
  the reference exactly, immediately after m8's 177 s build, which is **D19's standing condition
  and it did not fire**. The log's three `truncated-after` hits are the completeness checks' own
  assertion text over synthetic 100-line and 2-line fixtures, read one at a time — **no ninth
  sighting**. M15 did not flake either (537, 384 s).
* **M11 is 287 and GREEN**, so M37's narrowing of conjunct 1 survives a sweep it did not take.
* **M30 is 218 and green over a module genuinely REBUILT from the merged noir**, which is the
  reading that matters most, because M30's subject IS `../noir/compiler/wasm`. Verified by mtime,
  not by trust: `noir_wasm.wasm` rebuilt at **04:22:26** and `vfs.json` re-measured at **04:22:32**,
  against a merge commit dated **02:36:03**, with the log's own `re-measuring the VFS arms … this
  compiles two wasm modules in a browser`. And its `cargo test -p noir_wasm` reads **38 passed**
  where the pre-merge tree gives 37 — the mainline's extra
  `the_debug_mode_instruments_the_program_and_the_program_mode_does_not` — under an `assert_ge 30`
  floor, **so the count could not move and did not**. All three tests M30 names by regex are
  present in the resolved `vfs.rs`.
* **M25 is 273 and M26 is 340**, the two other checks that read the `noir` tree. M25's needles were
  re-checked against the merged `tracer_glue.rs` *before* the sweep and all held; the sweep
  confirms it.

### The three non-zero exits, each attribution RE-DERIVED by `git log` rather than accepted

The task named these in advance. Deriving them independently is the standard, and one of them was
mis-attributed by M37 itself before M37's review corrected it — so accepting a label here would be
the exact failure this campaign's standard exists to prevent.

| milestone | failing assertion | offending path | `git log` on that path | in my working diff? |
|---|---|---|---|---|
| **m20** 237, 1 failure | `verify_named_checks_exist` 9/1 — `UNRESOLVED test_reverted_transaction_recorded_as_reverted` | `tools/scan_reverted_transactions.mjs` | **`a601ce7`, the file's ONLY commit — *"L3's verification: 235 assertions…"*** → **L3's** | no |
| **m21** 325, 1 failure | `verify_no_pipeline_predicates` 69/1 — `expected [5], got [6]` surviving `\| grep -q` | `verification/verify_browser_replay_dd9_clean.sh:336` | `75ffd7e`, `1c1d87f`, `d324221`, `4b4e684`, **every one labelled L4** → **L4's** | no |
| **m28** 357, 1 failure | `verify_npm_pack_no_optional_native` 54/1 — got `… probe-mt replay spike` | `replay/package.json` | **`541bf5f` — *"L0: the replay node client…"*** → **L0's** | no |

**Every count is unchanged**, which is what says a pinned list moved and not a structure. All three
recorded and deliberately **not fixed** — a second track editing the first track's expectations is
a collision this campaign has already paid for. `git status --porcelain -- replay/` is **empty**:
nothing L0's or L4's was modified.

**The fourteen L0–L4 check names appear ZERO times as a column-0 summary line**, grepped one at a
time against the summariser's own anchored pattern. None of their assertions is in the 12,141.

### A sweep is a writer

`carry/*.json` checksummed before and after: **all four byte-identical**, nothing to restore —
`3836c2b6…` / `bec69bce…` / `79f597b2…` / `da229896…`, which is M37's committed-repair state
holding across a full sweep. The working tree ends carrying only this log and its reference file.

### A FINDING ABOUT THE CAMPAIGN'S OWN REFERENCE FILE

`scratchpad/campaign/m37rev-reference.json` — the reference the campaign left on disk — sums to
**12,114**, not 12,141. The single disagreement is **`m26`: it says 313 where the review log's own
final table says 340**, and 12,114 + 27 = 12,141 exactly. It was written before m26's re-run and
never updated: *a figure nobody re-derives rots*, this time in the artefact whose whole purpose is
to be the figure. The sweep above was run against a reference built from the review log's declared
table (`mainline-merge-reference.json`, sum verified 12,141 before use), and the live sweep
measured **m26 = 340**, which settles which of the two is right. Recorded rather than silently
corrected, because the stale file is M37's record and not mine to rewrite.

---

## Closing state

| repo | branch | HEAD | ahead/behind mainline | working tree |
|---|---|---|---|---|
| `codetracer-trace-format` | `dev` | `235e377` | 0 / 0 | clean |
| `noir` | `codetracer` | `6c590c778` | 0 / 0 | clean |
| `aztec-avm-runtime` | `dev` | `b6a40f1` | 0 / 0 | this log + its reference file only |
| `codetracer-specs` | `latest` | `15674012` | 0 / 0 | clean |
| `noir-wt4-webpage` | `wasm/webpage` | **`f0e7edcd2`** | — | **` M tracer_glue.rs`, the one pre-existing edit** |

Side branches **published and not deleted**: `codetracer-trace-format` `origin/blocktracer`
`4bf7ea2`, `noir` `origin/blocktracer` `7e77c87c1`. Both pushes were **fast-forwards**; nothing was
force-pushed anywhere.

`noir-wt4-webpage`'s `ls-remote` before and after differ in **exactly two lines** — `HEAD` and
`refs/heads/codetracer` advancing `61960c8ee → 6c590c778`, which is my own noir merge seen through
the same remote — and in nothing else. **65 refs before, 65 after, ZERO matching `webpage` in
either.** `wasm/webpage` remains in no published ref, which is fact 7 of OQ-7's verdict, unreopened.
