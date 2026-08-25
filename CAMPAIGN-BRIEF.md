# Standing Campaign Brief — Aztec AVM Runtime

Durable brief for every remaining milestone (M19–M28). Read this **before** the
milestone's own section in
`codetracer-specs/Planned-Work/Aztec-AVM-Runtime.milestones.org`.

It exists so that an interrupted agent — or an interrupted coordinator — can
resume without re-deriving anything. If you are picking this up cold: the
milestone file is the plan, this is the accumulated discipline, and
`scratchpad/campaign/m<N>-impl-log.md` is where the last agent got to.

---

## The loop

**implement → review → fix (if needed) → commit → next.** One agent touches the
working copy at a time. Implementation agents **never commit**; the review agent
commits and pushes after verifying. Push to `metacraft-labs` only — never
`AztecProtocol`, never open a PR.

**Leave the tree quiescent and your log current at every step, not just at the end.** The
campaign is to be driven to completion without interruption, and an interrupted agent that
recorded which priorities are settled is worth far more than one that has to start over. Write
`scratchpad/campaign/m<N>-*-log.md` as you go.

**Stand the implementation agent down before its review starts.** Two agents
running verify sweeps concurrently has corrupted measurements twice (M9's
timing, and a self-inflicted `verify-m9` collision M15 misattributed to foreign
load).

---

## Rules that were learned the hard way

Each of these is a defect that shipped, not a precaution.

### An assertion must be capable of failing
**Twenty-one instances.** (Five places quote the running total: this line, the two M18 checks
`lib_m18_orchestration.sh` and `verify_no_telemetry_client_in_import_graph.sh`, and the two M19
files `fault_injection.ts` and `e2e_differential_wasm_vs_native_cpp.sh`. M18's review added three,
M19 added one, M19's review added one, and M21 added one. If you add one, move all five numbers
together — M19 wrote "eighteen" into its two new files in the same session it moved the other three
to "nineteen", which is the drift this parenthetical exists to prevent, and **M21 declared its
21st instance in three documents and moved none of the five**, which is the same drift caught by
its review instead of by its author.)
The forms seen so far:

- `assert_eq "" ""` — both sides read missing keys. *Renaming both keys left all
  219 assertions green.*
- `grep -c '…' == 0` on a needle that could never match — passes by construction.
- A **printed literal**: the thing under test emitted `hasRevertCodeProperty` as
  a constant `0`, so the assertion beside it could not move. The gap was
  reachable — a trap would have reported as a transaction that succeeded.
- An assertion requiring its own measurement to be **wrong** to pass:
  `assert_ge "at least one has it FASTER, which a fifth tree cannot cause" 1`.
- **`git status --porcelain -- <path>` on a path that is not tracked yet.** Two checks proved a
  probe had restored a file that way. While `orchestration/` was untracked the command printed
  nothing whatever the probe had done, so both reported success either way. Compare against a copy
  the check itself takes, and give the comparison a control.
- **An absence asked of a tree that excludes the subject by construction.** "No published
  `@aztec` package ships a `ForkCheckpoint`", measured against a `node_modules` from which
  `@aztec/world-state` is deliberately absent. The published package does ship one. Ask the
  question of a tree that could answer it the other way.
- **The same defect again, on a containment requirement, in a check whose header cited the one
  above.** "The shipped import graph does not reach `@aztec/native`", asked of
  `orchestration/node_modules`, where `@aztec/native` is not installed *because the orchestration
  does not depend on it* — which is the thing under test. An import of it is `MODULE_NOT_FOUND`,
  lands in the walker's `unresolvable` list, and never enters `packages`. With a real
  `import * as x from "@aztec/native"` in a reached module the check printed **34 assertions, 0
  failures, PASS**. Non-emptiness assertions do not close this: the tree is not empty, it merely
  cannot contain the subject. Read the walker's `unresolvable` list too, and put the negative
  control on a tree where the package IS resolvable. **And do not let a fixed-string grep be the
  only thing behind a graph claim** — the one here was single-quote-only, so the same import
  spelled `"@aztec/native"` passed everything.
- **A pipe that put the failure counter in a subshell.** `assert_false "…" printf '%s\n' "$x" | grep -q NEEDLE`
  binds the pipe to `assert_false`, not to `printf`: the helper ran `printf`, which succeeds, its own
  output went to `grep`, and its increment of `_FAILURES` happened in a subshell and was lost. The
  check printed `FAIL` and reported `0 failure(s)` **in the same run**, and the full-suite output was
  what showed it — reading the line had not. Compute the predicate into a variable first.
  **M21 found two LIVE ones** (`verify_wasi_shim_reuse_decision_recorded.sh:159-160`), and they are
  worse than the account above: with `assert_true` the `ok` line itself goes INTO `grep` and is
  swallowed, so the assertions printed **nothing at all** and were invisible between two neighbouring
  `ok` lines — the check reported 48 where it should report 50. `finish` refusing a run with **no**
  assertions is what catches the degenerate case; nothing catches the partial one but a census.
  There is now a repo-wide check, `verify_no_pipeline_predicates`, and five builtin string
  predicates in `lib.sh` (`str_has_line`, `str_has_sub`, `str_has_word`, `str_has_re`,
  `str_has_line_re`). **Use them.** The census of surviving `| grep -q` lines is pinned at five BY
  NAME, so a new one fails — M21's review wrote two while fixing something else and was caught by
  that pin. And `str_has_re` is not `str_has_line_re`: bash's `=~` has no `REG_NEWLINE`, so `^…$`
  anchors to the whole string and a translated `grep -qE '^foo$'` silently stops matching.
- **A comparison against *fragments* of the expected change rather than its lines.** The check
  that pins the one forced edit in a vendored copy matched each changed line against a regex of
  substrings with `re.search`, so `this.depth = depth + 1` was excused by `this.depth = depth`.
  Line counts were unchanged, so all three assertions passed on a corrupted copy — defeating the
  exact property the deliverable claimed. Compare exact lines; keep the mutation as the control.

**Rule:** anything asserted must be read from the artefact, never printed as a
constant by the thing under test; any comparison whose sides could both be
absent needs a non-emptiness assertion beside it.

### Needles come from the artefact, matched on word boundaries
Fifteen instances. `honk` ⊂ `chonk`. `world_state` ⊂ `world_state_reference`.
`"DEPENDENCIES vm2"` ⊂ `vm2_sim` — **it asserted the opposite of its intent**.
`[A-Z_]+` never matched `L1_TO_L2_MESSAGE_TREE`. `([A-Za-z_]+::)*` found seven
where the truth is eight, because `avm2` has a digit. LLVM spells it
`(defualt)`. `"barretenberg"` matched a path component of every include dir.
An anchored `\.test\.ts$` applied to `path:line:content` never matches.
A `^`-anchored needle without `MULTILINE`.
**A fixed-string search for a function's NAME, used to mean "this check calls it".** Prose
satisfies it. Measured by M21's review: delete every `require_complete_transcript` call from a
comparer and leave one mention of the name in a comment, and
`verify_transcript_truncation_detection_uniform` reports 36 assertions, 0 failures — the comparer
has stopped refusing, the census has not noticed, and the milestone is green. Deleting the name
outright IS caught, so the needle worked exactly until somebody wrote the word down. **A citation
is the opposite of a dependency**, and this campaign has now written that sentence into one check
while the check beside it counted a citation as a call. Strip whole-line comments and require the
name to begin a command.

**And the scanner around the needle counts too.** The import-graph walker stripped comments by
scanning for `//` unconditionally, so a `//` inside a *string literal* began a comment and ate the
rest of the line: `const u = 'http://host'; import 'koa';` reported no imports. Every assertion
written against that walker is an *absence*, so the failure pointed the dangerous way — a package
that is reached looks like a package that is not. Reproduced directly against the old scanner
before fixing it.

### Never depend on state you did not produce
Four checks once passed against an **empty build directory**, because every
predicate returned 0 over a missing path. A check was 6/6 in one work directory
only. `m6_prepare_tree` reused any directory with a `.git` and asserted only the
*commit count* — seven trees were silently stale, one carrying a pre-review
patch. A mutated **artefact** outlived its restored source.

Assert artefacts present *first*. `require_work_dir` takes an `flock` whose fd is
**inherited by children** — respect the liveness check.

**And the SHELL is state you did not produce.** M19's review ran the sweep through
`direnv exec .` — this repository's own dev shell, the one `.envrc` exists to provide and the one
CI's `dev-exec` uses — and M4 went red on `the flagged module emits the standardised try_table
expected [21], got [19]` with nothing in the tree changed. Clang's WebAssembly driver runs
`wasm-opt` after `wasm-ld` at `-O2` **if it finds one on PATH**; every earlier sweep had run from a
plain shell that had none, so the pinned 21 was the count of an *unoptimised* module. Reproduced
byte-for-byte both ways. **A check that compiles must pin its PATH, not only its toolchain and its
flags** — and the two sweeps to compare are the dev-shell one and the plain one, because CI only
ever runs the first.

### Conjunctions need a negative case per conjunct
A four-tree conjunction whose only negative case exercised one tree: dropping any
of the other three passed all twelve cases.

### Exit status *and* the specific failure mode
Counts alone miss a binary printing `132 ran / 132 PASSED` while exiting 7.
Exit status alone misses a discriminator failing for the wrong reason.
`-Wfatal-errors` makes `': error: '` count **zero** on a failed build, and
`grep ' error: '` matches `fatal error:` as a substring.
A CI job piping into `tee` under `bash -e {0}` **cannot fail** — use `shell: bash`.

### Timing measurements assert their own preconditions
Exit with a distinct code rather than returning a wrong number on a loaded box.
The session is the unit of replication; page placement is the dominant nuisance
and is re-drawn by a copy. A same-bytes control must not be able to swallow a
measured regression.

### Prose drifts from measurement
It has happened to an implementation agent, a review agent, **and a reviewer
reviewing that very defect**. A corrected `PR.md` shipped beside a stale commit
message three times. Bind claims to data, or expect them to rot.

**And a GENERATED document can drift too, if it derives a number from a sentence.**
`CARRY-LEDGER.md`'s *Upstream changes* column was rendered by
`re.search(r"at base lines ([0-9]+\.\.[0-9]+)", entry["reason"])` over the acknowledgement's prose.
With one acknowledgement, worded to suit it, nobody noticed; the moment M21's review added a second
and a third, two of the three rows rendered `lines see below` while the check had computed the exact
ranges seconds earlier. The region is a declared field now and the check asserts the declared value
equals the measured one. **Rendering from data is not the same as rendering from a file** — ask
what, inside the file, the number actually comes from.

**A MILESTONE THAT MOVES ANOTHER MILESTONE'S COUNT MUST UPDATE THAT MILESTONE'S SECTION.**
M21 took `verify_carry_set_complete` 37 → 43 and `verify_block_level_gap_audit_complete` 130 → 131,
re-ran both milestones, wrote the new totals into its own section — and left M11's and M14's
Verification headers saying 246 and 459, and left four facts about upstream's tip stated twice each
in M11's prose. Grep the status file for the check's name, not only for your own milestone.

### A harness that counts is a thing under test too
The sweep counter summed every line matching `[0-9]+ assertion(s)`. One check prints a NOTE —
`  --   repin: 175 assertion(s), 0 problem(s)` — reporting a *sub-tool's* internal count, and the
counter added it to the milestone total. **M1 came out at 316 when it is 141**, and it was
reported as "consistent with the references" before anyone looked. Nothing in M1 had moved; all
six of its checks were identical to the reference. 141 + 175 = 316 exactly.

**Rule:** a summary line is at column 0 and ends `assertion(s), N failure(s)`; a note is indented.
Count only summary lines, and when a total moves, get the **per-check split** before believing any
story about why — the split is what distinguishes "a check grew" from "the counter is wrong",
and those are indistinguishable from the total alone.

**And the summariser is a thing under test too.** M21's read `^([A-Za-z_0-9]+):` as the check name
and therefore DROPPED `just check-repo-hygiene: 28 assertion(s), 0 failure(s)` — the one check whose
printed name contains a space — so m0 came out 128 against a reference of 156. The M1 316-versus-141
shape again, in the opposite direction, in the tool written to guard against it. The needle is
`^([A-Za-z_0-9][A-Za-z_0-9 .-]*): (\d+) assertion\(s\), (\d+) failure\(s\)$`, still anchored at
column 0.

### A SWEEP IS A MEASUREMENT OF THE TREE AT THE MOMENT IT RAN
**Three instances, and all three were read as regressions first.** M19 committed a pin-carrying
fixture after its own sweep and M1 went red. M20 committed the phase splitter after its own sweep
and M1 went **149 → 151** (`PROVENANCE.md` 70 rows → 71; `verify_provenance_complete` loops per
vendored file, so one row is +2 — confirmed by deleting that one row and re-measuring at 41). M20
committed a sixth candidate contribution to `codetracer-specs` after its own sweep and **M11 and
M14 both went red**, neither for anything in the repository the checks live in.

So: **run your sweep after your last commit, not before it**, and when a milestone you did not
touch moves, look for a commit that landed between the reference sweep and yours — in *either*
repository — before writing a story. Both attributions above were re-derived independently by the
review and both held; that is the standard, not the presumption.

Current per-milestone counts. Measured in one sweep, **M0-M21, on 2026-08-26**, one milestone at a
time, nothing else running — every milestone **exit 0 and 0 failures anywhere**, including M9 and
including M11:

```
m0 156  m1 151  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 278
m19 180  m20 237  m21 324                              CAMPAIGN TOTAL 7,619
```

M9's split is **140/143/113/73/126/83/129** and it reproduced on a box that was NOT idle — a foreign
build was running when the sweep started, and the flake did not appear.

Every move since the M0-M19 reference of 7,019, with the reason and the per-check split taken:
M20 added its own 237 and moved M1 141 -> 149 and M19 176 -> 180. Then, across M21 and its review:
**M1 149 -> 151** (M20's phase-splitter vendoring, `PROVENANCE.md` 70 rows -> 71 — the review
deleted that one row and re-measured `verify_provenance_complete` at 41, so the +2 is that row);
**M8 515 -> 516** (the truncation refusal is `lib.sh`'s and BOTH transcripts are asserted);
**M9 804 -> 807** (three transcript preconditions before the comparator);
**M11 246 -> 259** (`verify_carry_set_complete` 37 -> 43 for `not_carried`, and
`verify_carry_set_applies_to_upstream_head` 45 -> 52: +4 for the two overlaps upstream's fourth move
added, +3 for the declared line ranges the ledger now renders from);
**M14 459 -> 460** (the carry count reads the manifest instead of a directory listing);
**M17 295 -> 297** (two assertions that had never existed — see the pipe bullet above);
**M21 324** (new). 2 + 1 + 3 + 13 + 1 + 2 + 324 = 346, and 7,273 + 346 = 7,619.

---

## M9 is FLAKY, not broken — SETTLED, and the check still reports the flake as findings

**Settled by M19's review**: run alone on a machine verified idle first, `verify-m9` is
**804 assertions, 7/7, exit 0** in 21 minutes, every per-check number equal to the reference
(137 / 143 / 113 / 73 / 126 / 83 / 129), including
`verify_observation_hook_step_records_identical` back at 137/0. So 798 / 3-pass-4-fail was the
CHECK and not the subject, and the fix that is still outstanding is `m9_completeness`'s, not the
AVM's. The account below stands as the record of what the flake looked like.

`verify-m9` came out **798 assertions, 3 pass / 4 FAIL, 32 failing assertions** inside a full
sweep (last green reference 804, 7/7). **Re-run alone on an idle machine at the same commit, it
passes** — `verify_observation_hook_step_records_identical` back to 137/0, matching the reference
exactly. So it is not a regression in the subject and not a code defect: **it is a flaky check.**

All 32 failures had one cause: the **V8 step transcript stopped inside `burn` at record 16,719 of
38,915**, `oob` produced no records, and the terminal `avmSteps.done` sentinel never arrived.
Native and wasmtime produced the full 39,086 records in the same run. **stderr was complete and
included `oob`'s output**, so the guest ran every program to the end — only stdout was short. Not
a timeout (`M7_RUN_TIMEOUT` is 900 s; the block ran in under four minutes) and not stale artefacts.

What is established: the loss is on the guest's WASI `fd_write` path, which does not go through
`process.stdout` and so is not covered by the `exitAfterFlush` drain `93d8255` added to the host —
that drain does not truncate for the host's own writes (reproduced at 40,000 lines, through a pipe
and to a file). What is **not** established is the trigger. No other run of mine overlapped M9's
window; the run began seconds after M8's build finished, so writeback or memory pressure is
plausible and unproven. **Do not attribute this to `93d8255`** — I did, on the reasoning that M9
had not been re-run since that commit, and the idle-machine control refuted it.

**This is a fourth defect in that check, not a finding about the AVM.** An incomplete transcript
is a fact about the RUN. The check has `m9_completeness`, added exactly for this, and its own
comment records an earlier instance (39,113 of 39,115 lines). It must **refuse to compare** on an
incomplete transcript — one precondition failure naming the truncation — instead of emitting 32
assertion failures with names like "oob recorded no steps" and "burn's last record is not the
instruction that exhausted the gas", each of which reads like a discovery about the interpreter
and none of which is.

**Two lessons, and the second is mine.** Sweeps must not overlap other work: this brief already
said so, and I ran M18 checks alongside the sweep earlier in the same session. And a check that
can produce 32 red assertions from one truncated pipe will eventually be believed.

---

## The reuse discipline

**The campaign has been wrong eight times about whether something needed
building.** Every miss was a *parallel subdirectory* to the one being searched:

Five of the eight, the ones with a location crisp enough to be worth memorising:

| believed absent | actually at |
|---|---|
| chain loop, timer, facade | `sequencer-client/src/sequencer/automine/` |
| a shippable contract DB | `avm_fuzzer/common/interfaces/` (and upstream's is **TypeScript**) |
| a chatty merkle DB | `barretenberg/vm2_wsdb/` |
| a TypeScript msgpack encoder | `@aztec/stdlib/avm` — upstream calls it on the same type |
| a telemetry no-op | `telemetry-client/src/noop.ts` + 16 stubs in `txe/esbuild/stubs/` |

**Enumerate across the whole fork and the published `@aztec/*` packages, by
subdirectory, before concluding anything is ours to write.** An entry marked
"build" needs a specific rejection reason: does-not-exist, does-not-cover, or
cannot-reach-target. "We didn't find one" is not a reason.

---

## Status-file conventions

Format spec: `~/ah/dev/agent-harbor/ah-lib/specs/Milestones-Files.md`.

- Every non-`pending` entry needs a `file:` that **exists and contains the named
  test**.
- Prose goes in `description:`, **never** in `status:` — four entries using
  `status: pending — <prose>` broke the campaign's own validator.
- `Implementation Details`, `Key Source Files`, `Outstanding Tasks` required once
  started.
- Header counts and entry counts must agree — they have diverged twice.
- **No time or effort estimates anywhere.** Sequencing is `:depends_on:` only.
- `partially_completed` is a legitimate outcome. Three agents refused to flip a
  status while a criterion was measurably unmet, and each was right.

---

## Environment

- `direnv exec /home/zahary/m/blocktracer nix shell nixpkgs#rustup --command bash -c 'cd <repo> && …'`
- `~/.cache` work dirs — **never** `$TMPDIR`, a quota-limited tmpfs where `df`
  reports GB free and `dd` fails at 356 MiB. Do a **write probe**, not `statvfs`.
  **And this rule applies to the CHECKS, not only to your probes.** A bare `mktemp -d` lands in
  `$TMPDIR`. M21's review hit it live: with another agent's build occupying `/tmp`,
  `verify_vendor_drift_clean` — which stages the whole tracked tree (1,427 files) as a template and
  again per negative control — died mid-`cp` with `Disk quota exceeded`, printed **no summary line
  at all**, and took **M1 from 151 to 141 with no failure reported**. A missing check reads as a
  smaller milestone, not as a red one. Re-run with `TMPDIR` under `~/.cache` it is 10/0; that check
  now owns `~/.cache/aztec-m1-vendor-drift`. **TWENTY-EIGHT other sites still use a bare `mktemp -d`**
  — measured, `grep -rn 'mktemp -d' verification/*.sh | grep -v '\-p \|mktemp -d "'` — including
  `check_drift.sh:112`, `lib_m8_differential.sh:206`, `lib_m9_observer.sh:502`,
  `lib_wasi33.sh:351`, `lib_vm2_tests.sh:216` and `lib_avm_wasm.sh:791`. They carry smaller payloads
  and have not failed, but the failure mode is silent and the fix is one line each. Do not add a
  twenty-ninth.
- Do not clean by prefix; prefixes have twice matched another agent's directories.
- Do not edit a shell script while a run is reading it — it kills the run.
- `ccache` is wired via `CMAKE_{C,CXX}_COMPILER_LAUNCHER` in both dev shells.
  It must **not** make two different trees produce identical artefacts; that
  property is asserted separately and underpins every base-versus-patched claim.
- Ambient **all-lowercase exported** names (`out`, `name`, `phases`…) turn a large
  assignment into an over-long environment and every `exec` fails `E2BIG`.
  `lib.sh` de-exports them at source time.

---

## Load-bearing facts

- **Neutrality harness stays on the patch stack.** M3–M10 compare pristine
  `233d8e0993` against base-plus-patches as *separate trees*. Never repoint it at
  the `codetracer` branch — that would turn base-versus-patched into
  patched-versus-patched and make every claim a tautology while staying green.
- **Upstream moves — FOUR times now, and it is M11's work every time.** `upstream/next` has gone
  `233d8e0993` (base) → three commits → `44a57f8c4a` (seven) → `9487ed3e9b` (nine) →
  `142dfcf4b2` (twelve, 2026-08-26). Each move can turn `verify_carry_set_applies_to_upstream_head`
  red without anything of ours changing. Distinguish that from a regression, and then FIX it rather
  than recording it — M21 measured the third move and left the red for the review to find.
  **The repair is half mechanical and half a decision.** Mechanical: `just carry-exposure`
  re-measures `carry/exposure.json` at the new tip, `just carry-ledger` re-renders
  `CARRY-LEDGER.md`, and the replay rewrites `carry/rebase.json` on every run — commit all four
  together or the ledger and the data disagree. The decision: every overlap OUTSIDE
  `barretenberg/cpp` needs an entry in `carry/overlap.json` with a reason, a
  why-it-does-not-reach-the-build, a consequence, the declared line ranges, and the blob ids at
  both ends so it expires when upstream touches the path again. Read the check's own output first
  — it tells you whether conjunct 1 (nothing under the build tree) and conjunct 3 (disjoint
  regions) still hold, and if conjunct 1 has failed no acknowledgement can help and M6 and M10 owe
  a rebuild.
- **The CI is published and scheduled, and every job dies at one step.** The
  workflow *is* on `origin`, *is* picked up by a `garm-*` runner, and *does* run
  on schedule — then every job aborts at `Generate CI token` with
  `Input required and not supplied: app-id`. "It has never run" invites the wrong
  first hypothesis (runner availability); the cause is scoped to this repository.
  `codetracer-ci` is private, same org, same runner group, same label, same `@v1`
  action, same `vars.` spelling, and its token step **succeeds** — so plan and
  variable visibility are ruled out. Never imply a gate exists: no job has ever
  reached a check.
- **Nothing is filed upstream.** Five patches prepared and **six** branches published — five
  `pr/*` plus the downstream `aztec-avm-runtime` — which is what
  `verify_pr_branches_match_patches` asserts by name from `series.json`. Submission is the user's
  manual step via `submit/pr<N>-*.sh`; there are five such scripts.
- **PR #22815** (Emscripten migration) is open and would delete what patch 2
  changes. Patches 1, 3, 4 are unaffected but for one shared file.
