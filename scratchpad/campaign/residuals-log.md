# Residuals pass — closing the Aztec AVM Runtime campaign

Started 2026-08-31. Baseline: mainline merge `505cb11`, sweep **12,141**, `delta +0`.
Tree clean, branch `dev`, no `verify-m`/`verify-l` processes running at start.

## Step 0 — context read

- `CAMPAIGN-BRIEF.md` read in full (2,679 lines).
- `scratchpad/campaign/m37-review-log.md` Step 12 (outstanding list) and Steps 13–14 (the sweep) read.
- `OUT-OF-SCOPE.md` read: the **headless CodeTracer replay SDK is owned elsewhere**. M26's
  `e2e_joined_trace_opens_in_codetracer` must stay `pending`; do not invent a driver, do not extend
  `tools/browser_cdp.mjs` toward one. `GuiAssert` is the workspace's home for it.

## Step 1 — the pending census, derived rather than remembered

Parsed `codetracer-specs/Planned-Work/Aztec-AVM-Runtime.milestones.org` by `- test_name:` /
`status:` pairs (the file's actual entry shape; a first parse on `- name:` returned zero and was
discarded rather than believed).

**237 verification entries. 21 `pending`.** Statuses: 191 `passing`, 21 `pending`, 20 `passed`,
4 `completed`, 1 `verified`.

The closing review's Step 12 says **22**. The difference is named below.

## Step 1b — MANDATE EXPANDED MID-PASS

The coordinator relayed the user's instruction: *all known defects must be fixed; follow-up items
and residuals addressed as well.* "Pinned rather than hidden" stops being an acceptable resting
state for anything fixable. Added to scope:

1. `a_2_function_calls` records its last step at line 142 of a 13-line file (recorder defect,
   unchanged beta.18 → beta.26); it has a *declared* test that trips when fixed — fix it.
2. `multi_stmt`'s `assert` on line 3 produces no step at all.
3. `a_1_mul`'s step-sequence question is open under a pin that no longer records the doubt.
4. The secret-set deduplication covered by nothing (M36's review).
5. The out-of-range last step live in three fixtures (same family as 1).
6. Retire `npm.deletion_era`, move `orchestration/` to `npm.current` — **measure the cost first**.
7. D19's truncation trigger, unestablished after eight sightings across two streams.

**Serialisation, and it is not optional.** M30 builds the Noir wasm module, so editing `noir` while
a sweep runs corrupts that measurement — this campaign's thrice-paid concurrency failure. Order:
**all `noir` work → all runtime work → the sweep, last.** D19's analysis is read-only over logs on
disk and is the one item safe to do *during* a sweep, which is what the brief says such windows are
for.

Legitimately open and to be STATED rather than worked around: upstream filing (user's step), the CI
secret (user's step), M16's four "if triggered" fallbacks, the L0–L4 tracks' own reds, the
CodeTracer replay SDK (`OUT-OF-SCOPE.md`), and a second anchor in `aztec-labs-eng/aztec-node`.

## Step 2 — concurrent writes found before doing anything

`git fetch` in both repos, at start:

| repo | branch | state found |
|---|---|---|
| `aztec-avm-runtime` | `dev` | `505cb11` == `origin/dev`, clean |
| `codetracer-specs` | `latest` | `15674012`, **behind 1** (`d209f5ea`, an ID0 licensing milestone — not this campaign's) and **carrying an uncommitted edit to `Planned-Work/Aztec-AVM-Runtime.milestones.org`, mtime 07:42, seven minutes before this pass began** |
| `noir` | `codetracer` | `6c590c778`, clean — the mainline merge; `7e77c87c1` and `6db58caad` both ancestors |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2`, ` M tracer_glue.rs` — the one pre-existing edit, **not mine, not to be committed** |

The uncommitted specs edit rewrites M37's Outstanding task, which had said the F-row re-anchoring
was still owed **while the entry two screens above it read `verified`** — one of the three stale-
reason instances this pass was briefed on. It is somebody else's in-flight work. **It will be
verified rather than inherited** before it is kept (see Step 4).

## Step 3 — THE NOIR RECORDER DEFECTS: ONE FIX, TWO MISATTRIBUTIONS

Done first and finished before any sweep, because M30 builds the Noir wasm module and editing
`noir` under a running sweep is this campaign's thrice-paid concurrency failure.
`noir` `codetracer` `6c590c778` -> **`8c2c005ee`, pushed fast-forward**. `blocktracer` left at
`7e77c87c1` (untouched — `verify_noir_base_is_reconciled` reads `refs/heads/blocktracer`).

### 3.1 The out-of-range last step — DIAGNOSED AND FIXED, and it is ONE off-by-one

The three declared numbers were never three defects. **All three equal `file_size - line_count`**,
which is the sum of the per-line byte lengths — i.e. a raw byte cursor at end of source, not a line:

| fixture | declared "line" | file bytes | lines | `bytes - lines` |
|---|---|---|---|---|
| `a_2_function_calls` | 142 | 155 | 13 | **142** |
| `a_1_mul` | 264 | 273 | 9 | **264** |
| `multi_stmt_per_line` | 96 | 100 | 4 | **96** |

**Proved to be a byte cursor rather than a line, by experiment**: padding line 2 of
`multi_stmt_per_line` with ten spaces *without changing its line count* moved the number
**96 -> 106**. A reading, not an argument.

**The cause, found by instrumenting rather than by reading.** Two probes (`register_step` and
`convert_debugger_location`), 36 s and 13 s rebuilds. The final location is
`span=(99..99)` — the empty span at the newline after `main`'s closing brace, which *every* traced
program produces exactly once. `codespan`'s `column_index` clamps to `line_range.end` and a codespan
line range **includes its terminator**, so it reports `column = 2` for a one-character line. The
writer encodes a step as `sum(len(1..line-1)) + (column - 1)`; that column lands one past the last
addressable byte; the reader cannot invert it and surfaces the cursor as the line.

**A SECOND DEFECT WAS FOUND BESIDE IT.** `codespan`'s column counts **characters**;
`compute_line_lengths` counts **bytes**. They agree for ASCII — every fixture in
`test_programs/trace` — and disagree silently for any source with a multi-byte character before the
step, in the direction that produces a plausible wrong position rather than an obvious one. The one
repair fixes both: the column is derived from the source's own byte offsets and clamped to the
line's byte length.

**The declared test tripped by name** — `left: 13, right: 142` — which is what declaring a defect is
for. It is now `test_last_main_step_is_in_range_in_every_fixture` over **seven** fixtures.

**And my own first version of that test over-claimed.** It asserted "the last step is the fixture's
last line" for all seven and went red on `assert`, whose `assert(a != b)` on line 4 of a five-line
file **fails**, so the run aborts and never reaches the closing brace. The assertion is a partition
now, derived from the recording (`counts.io_events > 0`) rather than from a list typed in the test,
with **both arms asserted to have been taken** so a branch that stopped being reachable cannot read
as agreement.

### 3.2 `multi_stmt`'s line-3 `assert` — NOT A RECORDER DEFECT

It produces no step because **all three operands are compile-time constants and the SSA pipeline
folds the constraint away**. There is no opcode to stop on; a recorder cannot record a step for code
that is not in the program.

Established by CONTROL, not by argument: the same program with `a` bound to a runtime parameter —
the only change — produces **two** steps on line 3 (columns 12 and 5). Both halves are now asserted
in one test, through the same `nargo` and the same `ct-print`, because "no step on line 3" alone is
equally satisfied by a recorder that dropped it, which is exactly how it had been read.

It had been carried as a gap "pinned so that fixing it trips this test" — *describing a fix nobody
could make*. That is the second of this suite's three "recorder defects" to turn out not to be one.

### 3.3 `a_1_mul`'s step-sequence doubt — DISCHARGED, not restored

The pin `[None, None, Some(3), …]` was re-pinned by the reconciliation with the record of the doubt
deleted — a correct number standing on nothing. **It is two, and the cause is now a measurement.**
The first four steps are `(1,1)`, `(3,13)`, `(3,21)`, `(3,29)`: the entry step, then **one step per
parameter at that parameter's own column in the signature**, with a parameter bound only *after* its
own step is recorded — which is why `x` first reads 3 at `y`'s step. Every column the new test uses
is derived from the fixture's signature line rather than typed.

### 3.4 Two harness defects found while mutation-testing

1. **A locator override that silently fell back.** `CODETRACER_NARGO_BIN` / `CODETRACER_CT_PRINT_BIN`
   were read as `if p.exists() { return Some(p) }` with **no `else`**, so a typo or a stale path fell
   through to the workspace default and the run measured a *different* binary from the one it was
   told to use, reporting success — the stale-`nargo` hazard the file's own header warns about,
   reached through the escape hatch provided to avoid it. **Found because the obvious mutation of the
   vacuity guard did nothing**: pointing `CODETRACER_CT_PRINT_BIN` at a non-existent path changed
   nothing and the suite reported twelve passes. Hard error now.

2. **Residual (d) verified, and its own statement was stale.** The claim that a
   `CODETRACER_TRACER_TESTS_ALLOW_SKIP=1` run "still prints `ok. N passed … 0.00s` with nothing
   marking it vacuous" is **FALSE at the merged HEAD**: `test_source_views_embed_the_compiled_source`
   ignores the opt-out and panics, and has since `6939457ff`, which is in the mainline. Measured
   directly — that test panicked in my forced-absent run. So the panic-by-default guard *is* closed.
   What was genuinely open is narrower: the failure said *"a trace with no embedded source is the
   defect this test exists to catch"* over a run whose real problem is a missing binary — **a wrong
   explanation, which this campaign's own rule calls worse than none**. A guard now fails in those
   runs naming the missing binary and the vacuity. I corrected the sentence rather than claiming to
   have closed something already closed.

### 3.5 Mutation matrix — three arms, each killing only its own tests

| arm | result | assertions killed |
|---|---|---|
| clamp removed from `convert_debugger_location` | **10 passed / 2 failed** | exactly `test_last_main_step_is_in_range_in_every_fixture` and `test_a_2_function_calls_via_ct_print_full` |
| the constant-fold CONTROL made constant too | **11 / 1** | exactly `test_multi_stmt_line_3_assert_is_constant_folded_not_dropped`, on "must produce steps" |
| a parameter step expected at the wrong derived column | **11 / 1** | exactly `test_a_1_mul_parameter_binding_explains_the_leading_unbound_steps` |
| opt-out set + `ct-print` forced absent | **10 / 2** | the vacuity guard (naming `ct-print`) and the source-views refusal |

Final: **12 passed, 0 failed, 1.4 s** — not 0.00 s, which is the only thing on the screen that says
a suite spawning a compiler twelve times actually ran. `cargo fmt --check` clean; `cargo clippy`
adds no warning of mine (the two remaining in the file are pre-existing, lines 1521/1529).

### 3.6 RECORDED, NOT FIXED: the fix is in `noir` and not in the `noir-wt4-webpage` worktree

The OQ-7 shared-writer probe builds `noir_tracer` from **`$OQ7_NOIR_ROOT`, which is
`noir-wt4-webpage`**, not from `noir` — so the joined container's private half still carries the
byte-cursor defect. I am instructed not to commit that worktree (`f0e7edcd2`, one pre-existing
edit, `wasm/webpage` in zero published refs), so this is a divergence recorded rather than closed.
It is also why the M26 join checks are unaffected by the fix, and why the sweep should not move on
its account.

## Step 4 — THE PENDING 21, ENTRY BY ENTRY

Full before/after is in the report. Summary: **15 of 21 stated reasons were stale**; 6 left, each
with its blocker **re-measured today rather than quoted**. No entry's *conclusion* changed — which
is the point: this campaign's defect is a stale reason surviving a correct conclusion.

Two whole groups were blocked on things that now exist — M26's vendored transaction builder (7
entries) and M35/M36's vendored simulator + 68-oracle registry (5 entries) — and three individual
reasons were **false**, not merely superseded:

1. `e2e_ts_wasm_nested_call_fork_merge` said the shipping module is "M12's thirty-nine-export
   module". Dumped `WebAssembly.Module.exports`: **55 exports, eight `avm_coordinator_*`**. The
   four-export module is M6's spike and is deliberately unused.
2. `e2e_block_deployments_through_processor` said there is no later block because sealing needs an
   uncarried archive extension. `test_block_seal_updates_archive` is passing and asserts three
   blocks sealed and the archive going 1 leaf to 4.
3. `test_settled_read_request_verification`'s stated route **never existed**: `verifyReadRequests`
   is a bare `async function` with two references in the whole package and no export path reaching
   it, so vendoring or installing `@aztec/pxe` would never have produced it.

And `e2e_wallet_private_transfer` — whose reason M35 kept current — had gone stale the *other* way:
with M36's discovery source attached, `Token.mint_to_private` **executes** (1,047-entry witness, 22
served oracles).

## Step 5 — `npm.deletion_era`: MEASURED, AND LARGER THAN CLAIMED

M37's Outstanding task said moving `orchestration/` to `npm.current` is *"one mechanical rename at
two call sites"*. Probed every `@aztec/*` symbol `orchestration/src` imports against **both**
installed pins — `orchestration/node_modules` at `deletion_era` and `drift/node_modules` at
`current` — so neither side is a tree that excludes the subject:

- **140 module-level symbols across 35 subpaths resolve identically**, zero import errors on either
  side. *(A first version of this probe reported zero differences because every module failed to
  import in BOTH trees — Node resolves a bare specifier relative to the importing module, not the
  cwd. Two missing keys agreeing. Caught by asserting the error count instead of reading the diff.)*
- **Three member-set differences across 88 classes.** Only one is used: `AztecAddress`'s
  `fromNumber` / `fromField` / `fromString` / `fromBigInt` -> the `*Unsafe` spellings — **four
  methods, not one**. `SiblingPath.deserialize` is gone at `current` and is not called;
  `HashedValues.schemaFor` is additive.
- **TWELVE call sites across SEVEN files**, not two: `fromNumber` x7, `fromField` x4, `fromString`
  x1. The two the entry counted are the vendored pair; the other ten are this repository's own code
  and move in the opposite direction.
- **"Retire `npm.deletion_era`" is not achievable as written.** It has three consumers and
  `pins.json` says bumping it "would destroy the artefact rather than update it".

Not done, and left with the true number rather than the claimed one. A value-and-member probe is
also blind to behavioural change across two months of nightlies, and M34's review already recorded
upstream schemas differing at the pin in ways silent until something runs.

## Step 6 — D19 CLOSED: the trigger is the pipe, reproduced on demand, and fixed

The single largest finding of this pass. `m6_in_devshell` ran its dev-shell command as
`( … ) | awk …`, so every guest launched through it — **node, in seven libraries** — had fd 1 on a
**pipe** whose reader is `awk`. D19 asked "whether the loss depends on the sink being a pipe rather
than a file" on the day it opened and nobody had looked.

Four arms, same module, same host, same command, one variable:

| arm | fd 1 | reader | stdout | sentinel | stderr | exit |
|---|---|---|---|---|---|---|
| A | pipe | `cat` | 39,200 lines | present | 21,082 B | 0 |
| B | pipe | python, **10 s sleep first** | **504 lines / 53,186 B** | **absent** | 21,082 B | **0** |
| C | pipe | same python, no sleep | 39,200 | present | 21,082 B | 0 |
| D | **file** | — | 39,200 | present | 21,082 B | 0 |

Arm B is the recorded signature exactly and it is **deterministic** — 504 / 53,186 three runs out of
three — which is why the real sightings looked random: on a loaded box it is `awk` that stalls.
libuv adopts a pipe fd 1 as a non-blocking Socket and the guest's WASI `fd_write` goes straight to
that fd, so a write that cannot complete is **dropped rather than retried**; a C++/Rust guest blocks
and retries, which is why native and wasmtime were complete in the very runs where V8 was not.

It explains every row of the ledger that had never explained the others: all eight sightings inside
sweeps and none alone; points scattered rather than at a buffer size; sighting c stopping
mid-record; sighting g truncating a second transcript in one run; and `93d8255` not helping.

**Fixed and proved by the same harness**: the payload goes through a file, and under the same
10-second starvation the result is **byte-identical to the clean baseline**. Cost stated: output is
no longer streamed while produced.

## Step 7 — the sweep reference, which now checks itself

`m37rev-reference.json` summed to **12,114** against a declared 12,141 — `m26` 313 where the live
sweep measures 340. Corrected on disk (12,114 + 27 = 12,141 exactly).

The generalising fix is in `residuals-sweep-sum.py`: **a reference file declares its own `_total`
and the summariser REFUSES one that does not add up.** Calibrated three ways — a good reference
passes with a self-check line, a reference with no `_total` is refused, and the exact stale value
(`m26: 313`) is refused naming the `-27`.

**Declared before the sweep runs**, from the 12,141 baseline:

| milestone | check | from | to | delta |
|---|---|---|---|---|
| m16 | `verify_fallback_cost_priced` | 145 | 147 | **+2** |
| m21 | `verify_transcript_truncation_detection_uniform` | 44 | 50 | **+6** |
| m23 | `verify_sequencer_reuse_enumeration_recorded` | 60 | 63 | **+3** |
| m25 | `test_fr_rendering_matches_noir_tracer` | 57 | 68 | **+11** |
| m36 | `e2e_note_discovery_across_blocks` | 77 | 87 | **+10** |

`m2` unchanged (the `fx = 26 + i` fix moves no count, which is how a narrowing is told from a
re-pin) and **m9 unchanged at 807** (the refusals and the trap add no assertion). Every milestone
attribution was derived from the Justfile rather than remembered.

**PREDICTED TOTAL 12,173** = 12,141 + 32.

## Step 8 — THE SWEEP: 12,176, `delta +0`, NO HOLE, AND M9 DID NOT FLAKE

Measured M0–M37 on 2026-08-31 after the last edit, `setsid`-detached in this repository's own dev
shell (node v24.19.0), one milestone at a time with nothing else running, `TMPDIR` and the log under
`~/.cache`. **76 markers for 38 milestones, no hole. 35 of 38 exit 0.**

```
m0 156   m1 181   m2 293   m3 199   m4 218   m5 236   m6 363   m7 287   m8 516   m9 807
m10 450  m11 287  m12 691  m13 458  m14 460  m15 537  m16 225  m17 297  m18 283
m19 180  m20 237  m21 334  m22 265  m23 512  m24 350  m25 284  m26 340  m27 345
m28 357  m29 127  m30 218  m31 421  m32 237  m33 248  m34 217  m35 239  m36 150
m37 171
                                                       CAMPAIGN TOTAL 12,176
```

**Every unit accounted in both directions.** `12,141 + 2 + 9 + 3 + 11 + 10 = 12,176`, and all five
moves were named in `residuals-reference.json` *before* the run. The summariser reports
`delta +0` against it, and it validated the reference's own `_total` first.

**The +35 in the other direction — what each unit bought:**

| move | assertions | what they assert that nothing did before |
|---|---|---|
| m16 +2 | derived-absent fixture id | that the id the control plants really is absent, and that it was derived and not typed |
| m21 +9 | +2 the two M9 checks named, not just counted; +2 the trailing-comment probe and its positive control; +5 D19's entry re-pinned to an ESTABLISHED trigger with its reproduction figure and its control | |
| m23 +3 | derived-absent inventory id, its freshness, and the same extractor answering for a real id | |
| m25 +11 | the `Field` arm's range re-derived at the historical revision AND at the tip, the two asserted different, and the two escape-hatch lines | |
| m36 +10 | the secret-set deduplication: two arms through the real handler, discriminated by probes (work done), with both arms' inputs asserted | |

**m2 unchanged at 293** — the `fx = 26 + i` repair moves no count, which is the only way to tell a
narrowing from a re-pin. **m9 unchanged at 807** — a refusal and a trap add no assertion.

**M9 DID NOT FLAKE, ON THE FIRST SWEEP SINCE D19 WAS FIXED.** 807, rc 0, 1,324 s, immediately after
m8's build — D19's standing condition, present and not firing — split
140/143/113/73/126/83/129, the reference exactly. `INCOMPLETE:` and `truncated-after` appear **zero**
times in the whole log. M15 did not flake (537, 384 s). *One clean sweep is not proof a race is gone.
It is the first one taken with the cause known and removed.*

**THE THREE REDS ARE ALL PARALLEL TRACKS', RE-DERIVED NOT INHERITED** (`git log --follow` per file):
m20 `verify_named_checks_exist` 9/1 → `tools/scan_reverted_transactions.mjs` → **L3's** `a601ce7`;
m21 `verify_no_pipeline_predicates` 69/1 → `verify_browser_replay_dd9_clean.sh:336` → **L4's**
`75ffd7e`; m28 `verify_npm_pack_no_optional_native` 54/1 → `replay/package.json` → **L0's**
`541bf5f`. Every count unchanged; none of the three files is in this pass's diff.

**The fifteen L0–L4 check names appear ZERO times as a column-0 summary line.**

**A sweep is a writer**: `carry/*.json` byte-identical before and after — nothing to restore.

**AND THE SWEEP WAS ABORTED ONCE AT m1, WHICH IS THE RULE WORKING.** Closing D19 falsified four
statements, one pinned by a CHECK and one inside the refusal MESSAGE a developer reads. Found by
grepping for what the fix had made false. Killed two minutes in, all four corrected, restarted after
the last edit.

**The short tail times (m22 13 s, m36 7 s) are cache warmth, not skipping** — every one of those
milestones reports its full assertion count, and a check dying at a precondition reports a smaller
one or none. The artefacts were built by this pass's own earlier check runs and the content stamps
matched.
