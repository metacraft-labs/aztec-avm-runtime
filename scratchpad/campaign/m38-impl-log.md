# M38 — the Noir tracer serves Aztec's oracles

Started 2026-08-31. Baseline: `dev` `6d3410a` (later `44eeef3`), sweep **12,872**, `delta +0`,
pending 9.

Read in full first: M38's rewritten section, `CAMPAIGN-BRIEF.md` (2,788 lines), `JOIN-SHAPE.md`,
`PRIVATE-EXECUTION.md`, `SOURCE-MAPPING.md`, `final-four-log.md`, `closeout-log.md`,
`OUT-OF-SCOPE.md`.

State at start, measured: `aztec-avm-runtime` `dev` clean at `origin/dev`; `codetracer-specs`
`latest` clean; `noir` `codetracer` clean at `8c2c005ee`; `noir-wt4-webpage` at `f0e7edcd2` with
its ONE pre-existing edit and **zero published refs** — recorded before touching anything, and
re-measured after (§9).

No `verify-m` / `verify-l` process running; the six matches are stale `tail -f` processes on old
sweep logs. Load 0.91.

---

## STEP 1 — THE ENUMERATION, WHICH IS THE FIRST DELIVERABLE AND IS A NUMBER

Taken from a RUN, not from the handler's declaration. `~/.cache/aztec-m35-private/`'s arm report
carries the ordered ledger; the classification comes from the handler's source.

**`OracleVersionCheck.private_function` — 6,306 bytes of ACIR, 37 context fields, an 897-entry
solved witness — makes FOUR oracle calls over THREE distinct oracles, and all four are answerable
SYNCHRONOUSLY.**

| # | oracle | class |
|---|---|---|
| 0 | `aztec_misc_assertCompatibleOracleVersion` | sync-in-wasm |
| 1 | `aztec_prv_isExecutionInRevertiblePhase` | sync-in-wasm |
| 2 | `aztec_prv_setHashPreimage` | sync-in-wasm |
| 3 | `aztec_prv_isExecutionInRevertiblePhase` | sync-in-wasm |

`Token.transfer` makes five: three sync, one host-round-trip (`aztec_prv_isNullifierPending`, which
is declared `async` and awaits `siloNullifier`), one unimplemented (`aztec_utl_getNotes`).
`Token.mint_to_private` makes eighteen and stops at `aztec_prv_getSenderForTags`;
`PrivateVoting.cast_vote` five.

**The handler declares 43 methods of which 9 are `async`**, and every one of the nine awaits CRYPTO
or the tagging half — `poseidon2HashWithSeparator`, `siloNullifier` — both of which go through
`avm.wasm`. **Nothing awaits a network or a disk.** So the boundary is the LANGUAGE's, not the
chain's, which is what makes a pre-fetched tape the right remedy rather than a workaround.

*(The scanner's first draft found FOUR async methods, because `discoveryServed` sits inside a
`discovery ? { … }` conditional and its methods are indented eight spaces rather than four. The
undercount was in the direction that reads as good news. Found by comparing the scanner's set
against the one a reader counts in the file — the campaign's own "run the derivation twice,
differently, before believing it".)*

---

## STEP 2 — THE FEASIBILITY MEASUREMENT THAT DECIDED EVERYTHING, TAKEN BEFORE ANY DESIGN

`@aztec/noir-test-contracts.js` is compiled by nargo **1.0.0-beta.22**; this fork is **beta.26**.
Whether beta.26's `acir` can read that bytecode decides whether any of this is possible, so it was
measured before anything was written:

```
bytecode base64 8,408 -> 6,306 bytes decoded
DESERIALIZED OK: 1 acir function, 5 brillig functions
  circuit 0: 889 opcodes
debug_symbols: 625 bytes deflate -> 2,713 bytes json
  ProgramDebugInfo OK: 1 debug_infos
```

It reads. Everything after this follows from that one probe.

---

## STEP 3 — THE SEAM, IN `noir`

`TracingContext::with_executor` and `trace_circuit_with_executor`, with both existing entry points
keeping their signatures and delegating with `None`. The two in-tree callers — `trace_cmd.rs` and
`tracer_wasm/src/lib.rs` — are unchanged to the byte.

`tooling/tracer/tests/test_foreign_call_executor.rs`, four tests, compiling their fixtures **in
process** with `noirc_driver` rather than spawning `nargo` (the campaign's own recorded baseline
defect: `cargo test -p noir_tracer` does not rebuild `nargo`).

**And the fourth test is a finding about the tracer rather than about Aztec.**
`DefaultForeignCallBuilder::build` composes over `layers::Empty`, whose `execute` is
`Ok(ForeignCallResult::default())` for every call — so `nargo trace` over a program calling an
oracle nobody implements does **not** fail; it continues over an empty answer. Nothing in the tree
said which of "no handler ran" and "no handler was needed" the tracer does. It is the control that
makes M38's refusals a measurement rather than a tautology.

### The seam is NOT upstreamable, and that is a measurement rather than a decision

`tooling/tracer/CARRY-VS-UPSTREAM.md` measures the fork at **533 lines in five files**; everything
else — `tooling/tracer` (2,490 lines), `tooling/tracer_wasm` (860) — is ADDITIVE. There is nothing
upstream for this seam to be a seam in. What upstream DOES have is `tooling/debugger`, and the two
defects below are split along exactly that line.

---

## STEP 4 — TWO DEFECTS THE ARTIFACT FOUND, BOTH IN `noir`, ONE OF THEM UPSTREAM'S

**1. `get_source_location_for_debug_location` PANICKED.** It looks a Brillig function up in
`brillig_locations` and `unwrap()`s it, ten characters from an `unwrap_or_default()` that already
tolerates a missing entry INSIDE that map. `OracleVersionCheck.private_function` has **5** Brillig
functions and `brillig_locations` for **3**.

**The line is byte-identical at `noir-lang/noir` `3d3a1ce788` (`v1.0.0-beta.26`)**, so it is
upstream's. Prepared as `codetracer-specs/upstream-bugs/noir-debugger-brillig-locations-unwrap/`
with `ISSUE.md`, the patch, and a `reproduce.sh` calibrated in BOTH directions:

```
--repo <unfixed>   brillig_locations EMPTY : PANICKED      brillig_locations PRESENT : completed
--repo <fixed>     brillig_locations EMPTY : completed     brillig_locations PRESENT : completed
```

The control arm differs from the subject in one map entry and passes in both, so a run that
panicked twice would say INCONCLUSIVE and exit 2 rather than claim a reproduction. **That case is
not hypothetical: two earlier drafts of the reproduction hit it**, once on an uninitialised Brillig
memory slot (`value is not typed as Brillig usize`) and once on an empty `location_tree`
(`index out of bounds: the len is 0 but the index is 0`), and the script named both.

**2. THE RECORDER EMITTED NO STEPS AT ALL** for a program compiled without debug instrumentation.
`update_record` reads its step's position out of `stack_frames`, which `DebugVars` fills from the
`__debug_*` calls the instrumenter injects; a contract artifact carries none. Measured before the
fix: **1,004 opcodes stepped, 44 carrying a source location at 13 distinct positions, and 0 steps
recorded.**

**AND THE FIRST VERSION OF THE FIX WAS GATED ON THE WRONG THING, WITH A COMMENT CLAIMING IT COULD
NOT MATTER.** The comment said "this cannot change any existing recording: it is reached only when
`stack_frames` is empty, which is exactly the case that recorded nothing before". That is false: an
instrumented program's frame stack is also empty before its first `__debug_fn_enter`, and **six of
the twelve fixture tests went red with one extra step each** (`a_1_mul` 14 → 15). Keying on the
ARTIFACT declaring no variables and no functions separates the two cases by their cause instead of
by a symptom they share, and all twelve are unchanged.

*The baseline that caught it needed `nargo` REBUILT.* The first run of the fixture suite after the
change reported 12 passed in 1.37 s — over the OLD binary, because `cargo test -p noir_tracer` does
not rebuild `nargo`. This campaign records that exact trap and it still cost a run.

---

## STEP 5 — HOW THE ANSWERS CROSS A BOUNDARY THAT CANNOT BE CROSSED AT RUN TIME

`ForeignCallExecutor::execute` is synchronous Rust; M35's handlers are TypeScript. The answers are
**pre-fetched** — the deliverable's own first option — by `PrivateExecutionRequest.recordTape`,
which wraps upstream's own `ACIRCallback` (after `deserializeParams`, before `serializeReturn`) so
the tape is what crossed the WIRE rather than what the handler was thinking.

*(A slot is a field OR an array of fields. The first draft spread the single-field case into
sixty-six one-character strings — wrong in a shape a reader skims past, because it is still an
array of strings of the right total length. Found by reading the first tape rather than by
reasoning about it.)*

The probe implements **no** Aztec oracle, asserted over its own comment-stripped source with a
paired positive. Four things make it refuse, each BY NAME; the one that matters is a call past the
recording's own SERVED prefix, because a refused call and a void oracle look identical on the tape.

---

## STEP 6 — THE RESULT

| arm | steps | refused |
|---|---|---|
| `replay` | 21 | — |
| `truncate` | 13 | `aztec_prv_isExecutionInRevertiblePhase` |
| `refuseAll` | 2 | `aztec_misc_assertCompatibleOracleVersion` |
| `permuted` | 2 | `aztec_misc_assertCompatibleOracleVersion` |
| `transfer` | 62 | `aztec_utl_getNotes` |

21 steps over 12 distinct positions in **five** `aztec-nr` files, every one with a column, into a
745,472-byte container the pinned `ct-print` reads back as **22** `Step` events (the extra one is
`TraceSink::start`'s entry step, asserted as an IDENTITY). `Token.transfer` — 76,875 bytes, 5,602
ACIR opcodes — steps 62 and refuses **the same oracle by the same name that M35's own browser run
stopped at**.

`PRIVATE-TRACE.md` is the write-up.

---

## STEP 7 — THE MUTATION MATRIX, RE-TAKEN AFTER THE LAST EDIT

| arm | subject | result | what it killed |
|---|---|---|---|
| M1 | an unanswered call is PADDED instead of refused | 27 / **3** | the transfer arm's refusal and the browser/native agreement |
| M2 | the executor stops comparing recorded inputs | 21 / **3** | the permuted arm, entirely |
| M3 | the classifier ignores the `async` declaration | 35 / **1** | exactly the assertion written for it |
| M4 | the container's step paths are synthesised | 49 / **8** | the columns, the file count, the interned-path identity, the §6 discriminator and two document rows |
| M5 | the executor suite reports fewer tests than it declares | 23 / **3** | the three names it stopped reporting |
| M6 | the arm run HANGS (bound cut to 20 s) | **0 / 1**, rc 137, bound NAMED | the precondition, with a summary line at column 0 |
| M7 | the arm report is truncated | **1 / 2** | the precondition |
| M8 | the staleness predicate stops watching the tape | 49 / 0 | **EXPECTED SURVIVOR**, declared: every other arm runs under `REFRESH=1` |
| demo | `still_there` over a silently undone mutation | exit **5** | — |

`HARNESS: restored; manifest verified`; no `MUTATION MISS`, no `DID NOT HOLD`; tree clean after.

### THE MATRIX FOUND FIVE DEFECTS IN M38's OWN WORK, AND TWO OF THEM WERE GUARDS THAT COULD NOT GUARD

1. **THE ABNORMAL-EXIT TRAP WAS INSTALLED BY TRAPPING THE INSTALLER.** All four checks said
   `trap m38_summary_on_abnormal_exit EXIT`. `summary_on_abnormal_exit` *installs* the handler, so
   the exit handler installed a handler and printed nothing — a `die` read to the sweep as a check
   that is not there rather than as a red one, which is this campaign's 283-assertion silent-shrink
   shape. Found by arm M1, which reddened correctly and printed no summary line.
2. **`m38_absent` KNEW ONE SPELLING OF ABSENCE.** It looks for `MISSING`, which is a key that is not
   there. A TRUNCATED report makes `json.load` throw, the reader print nothing, and the guard pass
   over ten fields it could not read — `assert_eq "" ""`, ten times, under the guard written to
   prevent exactly that. Found by arm M7.
3. **`m38_num` DIED INSIDE A COMMAND SUBSTITUTION**, so the `die` killed the subshell and the parent
   carried on with an empty string — and two empty strings compare equal. `every recorded call was
   replayed` reported **ok** over a report with nothing in it.
4. **ARM M4's NEEDLE WAS TWO LINES AND `grep -F` READ IT AS AN ALTERNATION**, so the guard matched
   on the first line while the substitution did not apply. `still_there` caught it, restored and
   exited 5 rather than printing the result the arm predicted.
5. **ARM M5 MUTATED A FILE THE BACKUP DID NOT HOLD**, so its substitution survived the run in the
   working tree. Every file any arm mutates is in `FILES` now.

---

## STEP 8 — THE SWEEP WAS ABORTED TWICE, AND BOTH ABORTS WERE BOUGHT BY THE ONLY WORK A SWEEP LEAVES

**1. THE ROW ANCHOR WAS DEFEATED BY THE TOOL, IN THE CHECKS THAT CLAIM IT.** `str_has_re` is bash's
`=~`, whose `.` **matches a newline**. Thirteen document assertions were written in M24's OQ-6 shape
— anchor the needle to the ROW — as `str_has_re "$DOC" 'subject.*\*\*N\*\*'`, and every one could
match a subject on one line and a figure many lines below. Measured by swapping two figures onto
each other's rows: **the old form reports 33 assertions, 0 failures over a document stating the
reverse of its own data**; `str_has_line_re` reports 33 / 2, naming both rows. The census is over
the FORM: all 33 other `str_has_re` uses in the repository apply to a single-value haystack with
`^…$` anchors. `CAMPAIGN-BRIEF.md`'s running total moves to **forty-four**.

**2. AND THE REPAIR EXPOSED THE LARGER HALF.** Thirteen of the write-up's twenty-six table figures —
including every second column of §5 — were stated and compared by NOTHING, while the document's own
header claimed all of §1, §3, §4 and §5 were re-derived on every run.
`_m38_doc_figures.py` walks lines, takes the Nth bold figure on the row a needle names, refuses a
needle that names more than one row, and reports how many figures it compared — so "no
disagreement" cannot be "nothing compared". **It found two rotted rows on its first run, both
mine**: `distinct (path, line) among them` stated the PROBE's count in a row whose neighbours are
CONTAINER readings (12 / 46 where the answer is 13 / 47, because the entry step is a distinct
position too), and `carrying a source location` matched two lines so it named no row at all.

---

## STEP 9 — THE HARD CONSTRAINT, MEASURED BEFORE AND AFTER

`noir-wt4-webpage`: HEAD `f0e7edcd20dc667f789827563e2b2c780b368552`, exactly its one pre-existing
edit to `tooling/tracer/src/tracer_glue.rs`, **`git for-each-ref --contains HEAD refs/remotes`
empty** and `git ls-remote origin | grep -c f0e7edcd2` **zero** — before the work and after it.
Nothing here builds from that worktree; M38 builds from `noir` on `codetracer`, and
`e2e_private_function_steps_into_ct_container` §8 asserts the emptiness on every run with a positive
control that the same counter answers non-zero for a commit that IS published.

---

## STEP 10 — THE SWEEP: **13,022**, `delta +0`, NO HOLE, AND M9 DID NOT FLAKE

Measured M0–M38 on 2026-09-01 **after the last edit**, `setsid`-detached in this repository's own
dev shell (node v24.19.0), one milestone at a time with nothing else running, `TMPDIR` and the log
under `~/.cache`. **78 markers for 39 milestones, no hole. 34 of 39 exit 0.** Polled **inside the
agent's own run**, in nine-minute blocks — the four background waiters attached to it were all
killed by the harness, which is why the campaign's rule is what it is.

```
m0 156   m1 181   m2 293   m3 199   m4 218   m5 236   m6 363   m7 287   m8 516   m9 807
m10 450  m11 287  m12 691  m13 458  m14 460  m15 537  m16 225  m17 297  m18 578
m19 180  m20 237  m21 451  m22 349  m23 512  m24 350  m25 454  m26 340  m27 345
m28 358  m29 127  m30 218  m31 450  m32 237  m33 248  m34 217  m35 239  m36 150
m37 171  m38 150
                                                       CAMPAIGN TOTAL 13,022
```

The summariser validated the reference's own `_total` first and then reported **`delta +0`**:
every one of the thirty-nine came out at its declared value, and the single move was named in
`m38-reference.json` before the run. **12,872 + 150 = 13,022 exactly**, and M38's 150 is
35 / 23 / 40 / 52.

**M9 DID NOT FLAKE** — 807, rc 0, **1,282 s**, immediately after m8's **176 s** build, which is
D19's standing condition, present and not firing. M15 did not flake either (537, 383 s).

**FIVE NON-ZERO EXITS, AND NOT ONE IS M38's.** Four were declared in the reference before the run;
the fifth was not, and is attributed below rather than explained away.

| milestone | check | count | offending subject | whose |
|---|---|---|---|---|
| m20 | `verify_named_checks_exist` 9/1 | unchanged | `tools/scan_reverted_transactions.mjs` | **L3's** (`a601ce7`) |
| m21 | `verify_no_pipeline_predicates` 69/1 | unchanged | a sixth `\| grep -q` in `verify_browser_replay_dd9_clean.sh` | **L4's** (`75ffd7e`) |
| m28 | `verify_npm_pack_no_optional_native` 55/1 | unchanged | `replay/package.json` as an eighth tree | **L0's** (`541bf5f`) |
| m11 | four checks, 9 failing assertions | **287, unchanged** | the tenth upstream move | **upstream's** |
| m16 | `verify_fallback_cost_priced` 147/1 | **unchanged** | a needle a parallel commit changed | **`bbfa872`'s** |

**The fourteen L0–L4 check names appear ZERO times as a column-0 summary line**, grepped one at a
time against the summariser's own anchored pattern. None of their assertions is in the 13,022.

### The fourth red: the TENTH upstream move, declared before the run

`upstream/next` went `7471a61f1a` -> **`f6bf848795`** (*"fix(ci3): the GitHub runner no longer needs
the build-instance SSH key in SSM mode"*, #25349), by a fetch in the sibling `aztec-packages`
checkout since M37. Measured by hand BEFORE the sweep and written into the reference:
`verify_carry_set_applies_to_upstream_head` fails on the stale recorded tip, the stale exposure hash
and `bootstrap.sh`'s acknowledged region; `verify_carry_ledger_complete` on the stale rendered
ledger; `verify_accepted_patches_dropped_from_carry` on a commit now in upstream HEAD.
**m11's count is 287 — the reference value** — which is what says a pinned list moved and not a
structure. NOT REPAIRED: the check's own conjunct prints the decision-needed signal rather than the
mechanical one, and the decision half is M11's work.

### The fifth red, which was NOT declared, and its attribution

`verify_fallback_cost_priced` fails one assertion — a POSITIVE CONTROL: *"the same regex finds all
three of them in the deleted package itself"*, expected 3, got 0.

**It is not M38's**: `git diff 44eeef3..HEAD -- verification/verify_fallback_cost_priced.sh` is
empty, the count is unchanged at 147 (and m16 at 225), and the last commit on that file is
`bbfa872` — *"verification: two more platform needles — a seventh `\b`, an eighth, and `nm`'s
Mach-O underscore"* — which landed on `origin/dev` at 22:02 on 2026-08-31, before this milestone's
first commit and before its rebase.

**And the cause is worth recording, because it is a THIRD engine.** That commit replaced `\b` with
the POSIX bracket expression `([^[:alnum:]_]|$)` for portability, in a needle used twice: once
through `git grep -E` and once through `m16_words`. The check's own header already records that
those were two different engines and that the control had been scoped to the wrong one — and
`m16_words` is neither of them, it is **Python's `re`**, which does not implement POSIX classes
inside brackets. Measured: `implements UpdateOnlyTree` is present in `sparse_tree.ts` and GNU grep
finds it; the same needle through Python's `re` returns **0** for all three files.
So the fix for a two-engine hazard introduced a three-engine one.

**Recorded and deliberately not fixed** — a second track editing the first track's expectations is
the collision this campaign has already paid for.

**A sweep is a writer**: `carry/*.json` checksummed before, `sha256sum -c` after — **`exposure.json`
and `rebase.json` came back FAILED**, were restored from HEAD, and re-verified all four OK. The
working tree is clean.

---

## STEP 11 — THE UPSTREAM CONTRIBUTION, EXECUTED RATHER THAN SHIPPED UNRUN

And running it found that it did not run.

**The first version of `reproduce.sh` was an external crate with path dependencies, and it could
never have worked for a maintainer.** `noir_debugger` upstream exposes `run_repl_session`,
`run_dap_loop`, `errors` and three re-exported structs; **`context` and `foreign_calls` are PRIVATE
modules**, so `DebugContext` cannot be constructed from outside the crate at all. This fork makes
both `pub` — part of its own 209 lines in that crate. So the reproduction built and reproduced
against `noir`, and failed against `noir-lang/noir`'s own tree with
`E0603: module 'foreign_calls' is private`. **A reproduction that only runs on the fork it was
written in is not a reproduction**, and nothing but running it against the right tree would have
said so.

Rewritten as an in-crate `#[cfg(test)]` module appended to `context.rs`, run, and removed by a trap
with the restore verified by sha256. Two further drafts failed before it worked, and each was
NAMED as `INCONCLUSIVE` rather than reported as a reproduction: an uninitialised Brillig memory
slot, an empty `location_tree`, and `serde_json` — which the header had asserted was one of
`noir_debugger`'s dependencies and is not.

**Four arms, all against `noir-lang/noir` `3d3a1ce78` (`v1.0.0-beta.26`) itself:**

| arm | tree | subject | control | verdict |
|---|---|---|---|---|
| D | upstream base, unpatched | **PANICKED** | completed | **REPRODUCED**, rc 1 |
| E | upstream base + only this patch | completed | completed | **FIXED**, rc 0 |
| — | `git apply` of the patch to `3d3a1ce78` | — | — | applies, no offset |
| — | `cargo test -p noir_debugger --lib` both ways | — | — | **4 passed / 0 failed** each |

The control differs from the subject in one map entry and passes in both directions.

**And the script's own guard was wrong for the workflow it exists to serve.** It refused when
`context.rs` differed from HEAD — but the intended use is `git apply` the patch and then reproduce,
so the fixed-tree arm was unrunnable. The guard is about the PROBE now (a previous run that did not
clean up), not about `git status`.

---

## STEP 12 — THE TWO FIXES THAT MUST NOT BE FILED

`noir/tooling/tracer/CARRY-VS-UPSTREAM.md` gains a table naming all three of M38's `noir` changes
and which of them has an upstream to go to. Two do not, for a structural reason rather than a
judgement: `tooling/tracer` is 2,490 lines of additive fork code, so the executor seam and the
uninstrumented-program step rule have nothing upstream to be a change TO. The one-command test is
recorded beside them, and so is the second, narrower reason — a file can be upstream's while its
public surface is not, which is what cost the reproduction its first draft.
