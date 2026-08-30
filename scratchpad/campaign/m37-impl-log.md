# M37 Implementation Log — Reconciliation: Everything on the Latest Upstream

The campaign's final milestone. **Two reconciliations, two repositories, two very different sizes.**

Written **as I go**, per the campaign brief's standing rule. Nothing below is a prediction; every
figure is measured at the moment the line was written, and the command that took it is recorded.

---

## Step 0 — preconditions

- `codetracer-specs/Planned-Work/Aztec-AVM-Runtime.milestones.org` M37 read (lines 14312–14437).
- `CAMPAIGN-BRIEF.md` read **in full** (2,311 lines).
- `m36-review-log.md` (567 lines) and `m35-review-log.md` read.
- `REACTOR-ABI.md`, `DRIFT.md`, `PROVENANCE.md`, `REUSE-INVENTORY.md`, `pins.json` read.

**Live-sweep check.** `ps aux | grep -E 'verify-m|verify-l|sweep'` returns three stale `tail -f`
processes from the M14 / M22 / M30 review sessions (Aug 24 / 26 / 28) and **no live sweep**.

**`aztec-avm-runtime`**: `git fetch origin`, `HEAD == origin/dev == 12a9c26`,
`rev-list --left-right --count` = `0 0`. Tree clean. The four-track branch is quiescent.

**`carry/*.json` checksummed before anything ran** (a sweep is a writer, and so is `verify-m11`):

```
ec959b8477513b55ebb5b6be983c65a228548b77606daca75efc19aea26940d0  carry/exposure.json
6d4d275af39a1e65382fb2df97b5b235b01fc27a107921b8d0a282a2b5c6b445  carry/overlap.json
aaeb68772fd333ba7a1fa91e3adf42d7f1640d0f1057c4cf5d4c8e825cb254ea  carry/rebase.json
da2298960875b93e0e33eb98bb428f3114809e4223e5af2a4daaa68635fa70e8  carry/series.json
```

---

## Step 1 — NOIR: the topology, measured before anything was moved

`git ls-remote` at `metacraft-labs/noir`, 2026-08-30:

| branch | tip | published? | `Cargo.toml` workspace version |
|---|---|---|---|
| `blocktracer` | `4d2381630` | **yes** (`refs/heads/blocktracer`) | **1.0.0-beta.18** |
| `wasm/reconcile-then-extract` | `4f49a6e96` | yes | **1.0.0-beta.26** |
| `wasm/upstream-clean` | `4111457c3` | yes | 1.0.0-beta.26 |
| `wasm/extract-from-fork` | `b8fd9f08a` | yes | 1.0.0-beta.18 |
| `wasm/webpage` | `f0e7edcd2` | **NO — zero published refs**, deliberately (OQ-7 fact 7) | 1.0.0-beta.26 |

`wasm/webpage` is absent from `git ls-remote --heads origin` — verified by grepping the full
listing, not by trusting the plan. **It was not touched by this milestone.**

**The reconciliation is a five-commit segment on `wasm/reconcile-then-extract`, and it is separable
from the wasm campaign that sits on top of it.** `merge-base(blocktracer, wasm/reconcile-then-extract)`
is `6db58caad` — the `codetracer` branch's head, the merge of the column-aware tracer. From there:

* `blocktracer` is **4 commits**: `eb8b28c27` (Field hex), `01cf48082` (fixture repin),
  `fe4b0c1e4` (VFS compiler), `4d2381630` (SSA timer).
* `wasm/reconcile-then-extract` is **1,607 commits**, of which the first six are the reconciliation —
  `444e4bd3f` *merge: upstream/master 3d3a1ce78 (1593 commits) into the tracer fork* plus five
  fixups ending at **`f403193bb`** — and the remaining eight are the wasm campaign.

So the base the milestone names is `f403193bb`, and it is a tree, not a rebase target.

### THE MILESTONE'S SSA-TIMER SENTENCE IS FALSE IN ONE DIRECTION, AND THE DELIVERABLE IS STILL OWED

M37 says the patch *"has never been applied to the tree it was found in"*. Measured, by reading the
`time()` helper out of five revisions rather than by reading the plan:

| revision | `time()` reads the clock |
|---|---|
| `blocktracer` (`4d2381630`) | **early-returns — THE FIX IS HERE** |
| `f403193bb` (the reconciled base) | unconditionally |
| `wasm/reconcile-then-extract` | unconditionally |
| `3d3a1ce78` (upstream beta.26) | unconditionally |
| `wasm/upstream-clean` (`4111457c3`) | unconditionally |

The fix exists on **`blocktracer` and nowhere else**, and `4d2381630` is literally the commit the
prepared patch's `From:` line names. What has never had it is the **reconciled** tree — which is what
the deliverable asks for and is what the merge below supplies. The patch's own `PR.md` declares
`Base: 3d3a1ce78` and says the function is *"byte-identical at that commit and at our own fork's
tip"*, which the table above confirms: four of the five spellings are one text.

## Step 2 — NOIR: the merge, and the ONE conflicted file

`git merge --no-commit --no-ff f403193bb` onto `blocktracer` in a worktree **sited as a workspace
sibling** (`/home/zahary/m/blocktracer/noir-m37`), because `Cargo.toml` resolves
`codetracer_trace_writer_nim` through a bare `../codetracer-trace-format` path — a worktree under
`~/.cache` resolves nothing and would have produced a "it does not build here" claim of exactly the
kind this campaign has already paid for once.

**One conflicted file: `tooling/tracer/tests/test_tracer.rs`, twelve regions.** Everything else
auto-merged, including `compiler/noirc_evaluator/src/ssa/builder.rs` — so the SSA-timer fix survives
the reconciliation without a hand edit, verified by reading the merged `time()` back out of the
worktree.

The twelve regions are all **pinned expectation values**, and they divide cleanly by cause:

* `counts["types"]` and the type tables — HEAD's values, and they are lower by exactly one per
  `Field`-carrying fixture. That is `eb8b28c27`'s doing: a `Field` rendered as a `String` no longer
  makes the writer register a nameless companion type.
* `counts["steps"]`, `counts["values"]`, `events.len()` — the two sides disagree for two *different*
  reasons: HEAD's numbers carry the writer's absolute-column-step encoding, the reconciled side's
  carry upstream's rewritten SSA pipeline granularity. **Both effects apply to the merged tree, so
  neither side's number is right a priori and taking either would be an unexecuted expectation.**

Resolved by rule — types from HEAD, step/value/event counts and the re-pinning comments from the
reconciled side, the column-message wording from HEAD — and then **measured**, below. All four diff3
markers grepped afterwards: `0`.

## Step 3 — THE BASELINE, AND A SILENT SKIP THAT MADE THE FIRST ONE WORTHLESS

First baseline run of `cargo test --release -p noir_tracer` in the worktree, with
`CARGO_TARGET_DIR` pointed at a scratch directory:

```
running 6 tests
test result: ok. 6 passed; 0 failed; ... finished in 0.00s
```

**Six green in 0.00 s, over tests that spawn `nargo` and `ct-print`.** `locate_nargo` looks at
`CODETRACER_NARGO_BIN` and then at `<noir>/target/{debug,release}/nargo`; with `CARGO_TARGET_DIR`
elsewhere neither exists, it prints `SKIP:` **to stderr** — which `cargo test` swallows for a passing
test — and every one of the six `let Some(doc) = … else { return; }` sites returns green.

That is this campaign's *"a conditional assertion block is a skipped test wearing an `if`"* and
*"a missing check reads as a smaller milestone, not as a red one"*, in a test file whose own header
says **"so silent skips remain forbidden"**. The `SKIP:` diagnostic was written to make skipping
loud; `cargo`'s output capture makes it silent, and the test still PASSES. Recorded as a defect of
the harness — see Step 6.

Re-taken with `CODETRACER_NARGO_BIN` and `CODETRACER_CT_PRINT_BIN` both set to binaries this session
built or verified:

```
test result: FAILED. 3 passed; 3 failed
```

**BASELINE (pre-reconciliation, `blocktracer` @ `4d2381630`): 3 pass / 3 fail**, and the three are
exactly the three the milestone names, with exactly the symptoms it names:

| test | symptom, read out of the failure |
|---|---|
| `test_a_1_mul_via_ct_print_full` | the per-step `x` sequence is **shifted by one** — measured `[None, None, 3, 3, 3, 12, 144, 20736, 429981696, 429981696]` against an expected `[None, None, None, 3, 3, 3, 12, 144, 20736, 429981696]` |
| `test_a_2_function_calls_via_ct_print_full` | the last step is recorded at **line 142 of a thirteen-line file** (`("main", 142)` where `("main", 13)` belongs) |
| `test_multi_stmt_per_line_column_aware` | line 4's assert step has **no column at all** (`None` against `Some(1)`) |


## Step 4 — NOIR: what the reconciliation did to the three, and it is THREE DIFFERENT ANSWERS

Reconciled tree, `nargo` rebuilt, both binaries pinned: **6 passed / 0 failed in 0.22 s.** That
number is *not* "the three were fixed", and reading it that way is the trap. Each of the three was
traced to the assertion site, in four trees — `6db58caad` (the merge base), `blocktracer`,
`f403193bb` (the reconciled base) and the merge — before anything was concluded:

| test | what actually happened |
|---|---|
| `a_1_mul` per-step sequence | **REPINNED, NOT FIXED.** `blocktracer` expects ten entries with three leading `None`s and the recorder produces two. Upstream's rewritten SSA pipeline doubles the granularity, so the reconciled base's expectation is **fourteen** entries — with **two** leading `None`s, i.e. it was re-pinned to exactly what the tree emits. The comparison is still exact and can still fail; what was lost is the record that the expectation was ever in doubt. |
| `a_2_function_calls` line 142 | **STILL A DEFECT, AND THE RECONCILED BASE WROTE IT INTO THE TEST WITH NO COMMENT.** `("main", 142)` in a thirteen-line file is what the recorder emits at beta.18 *and* at beta.26. `cf0a74e7d` re-pinned the sequence to include it. That is M26's own named hazard — *"a recorder defect a repin would write into a test"* — arriving through a merge. |
| `multi_stmt` line-4 column | **RETIRED, AND IT WAS A DEFECT IN THE TEST.** The assertion looked for a step on **line 4**; the `assert(a + b + c == 6);` it is about is on **line 3**. It never reached its own assertion because an earlier one in the same test always failed first. The reconciled base found the off-by-one and replaced it with a pin on the real gap — *line 3 produces no step* — written so that fixing the gap trips the test. |

### Three edits on top of the merge, each because a green would otherwise mean the wrong thing

1. **`test_a_2_last_step_line_is_the_known_out_of_range_defect`** — a new test that asserts the 142
   defect is STILL THERE and reads the fixture's real length **off disk** rather than restating it.
   Fixing the recorder now trips this file by name; lengthening the fixture past 142 lines trips it
   too, because 142 would stop being out of range; and both halves are guarded by an assertion that
   `main` recorded any steps at all, so a missing step list cannot satisfy either.
2. **`refuse_or_skip`** — the silent-skip fix. Calibrated **both ways**: with no binaries and no
   opt-out the run is `test_a_1_mul_via_ct_print_full ... FAILED` with the reason and the fixing
   command named; with `NOIR_TRACER_ALLOW_SKIP=1` it is `ok. 7 passed` in 0.00 s. A skip is now a
   decision somebody takes rather than one an absent file takes for them.
3. **The module header re-derived from what was measured**, because after the merge it said all
   three were still red, said the `a_1_mul` sequence was "not repinned here" over a file that
   carries the repin, and said repinning 142 "would write a bogus line number into a test" directly
   above the list that does. Three false sentences in the file they are about.

**Suite on the reconciled tree: 7 passed / 0 failed** (six fixtures plus the new declared-defect
test), in 0.24 s, with `nargo` rebuilt in the same worktree.

### Two other measurements on the reconciled tree

* `cargo test --release -p noirc_evaluator`: **1,879 passed, 4 failed**. The four are
  `flatten_cfg::tests::assumes_inlining_has_run`,
  `mutable_array_set::tests::disallows_multiple_blocks::{_fold,_inline}_expects` and
  `unrolling::tests::pre_check_rejects_const_condition_jmpif_in_loop_header` — all four are
  `should_panic`-shaped pre-check tests, i.e. exactly the shape a `--release` build (no
  `debug_assertions`) turns green-to-red. Controlled by re-running them in **debug**; see Step 7.
* `cargo check -p noir_wasm --target wasm32-unknown-unknown` fails with `E0463` on the first
  dependency: this host's `/usr/bin/rustc` has no `wasm32-unknown-unknown` std installed. **An
  environment fact, not a tree fact** — recorded rather than reported as a reconciliation defect,
  and named here rather than left to be rediscovered.

---

## Step 5 — AZTEC: THE MEASUREMENT THAT DECIDES THE WHOLE TS HALF

M37's table says the `ts` anchor is 2,007 commits behind `origin/next` (`651bda5d5f1`, **2026-08-20**)
and asks for it to be "advanced to current". Measured against `upstream/next` in the sibling fork —
`7471a61f1a`, **2026-08-27**, the tip this repository's own M11 replay uses:

```
cpp 233d8e0993 -> upstream/next :    19 commits, ancestor: yes
ts  3a68d68ac2 -> upstream/next : 2,024 commits, ancestor: yes
```

**Then the decisive one.** Every upstream path `PROVENANCE.md` F9–F23 vendors, resolved at the tip:

```
simulator/src/public/public_processor/public_processor.ts            tip=ABSENT
simulator/src/public/public_db_sources.ts                            tip=ABSENT
simulator/src/public/db_interfaces.ts                                tip=ABSENT
… all fifteen …                                                      tip=ABSENT
```

`git ls-tree 7471a61f1a yarn-project` is **empty**. The cause is one commit:

> **`703d896149` — `chore!: delete the in-tree labs components (#25321)`, 2026-08-27.**
> Deletes `yarn-project/` (**3,328 files**), `noir-projects/labs/`, `docs/`, `playground/`,
> `spartan/`, `aztec-up/`, `release-image/` and `labs-aztec-toolchain/` — **10,825 changed paths** —
> and rebuilds them from a new `labs` **submodule**, `aztec-labs-eng/aztec-node.git` (branch `main`,
> `update = none`, shallow), pinned at `1f14e9a69d1`.

**So "advance the `ts` anchor to current" has no meaning inside `aztec-packages` any more: the
TypeScript is not in that repository.** The ceiling is `703d896149^` = **`38fd5fc6e9`** (2026-08-27,
*chore!: build and test the labs components from the submodule*), the last commit at which
`yarn-project/` exists in-tree.

### AND AT THAT CEILING, EVERY FILE WE VENDOR IS BYTE-IDENTICAL TO THE `cpp` ANCHOR

Blob ids at `233d8e0993` and at `38fd5fc6e9`, for all fifteen F-row upstream paths: **identical in
every one.** Sixteen commits apart and not one of them touched a file this repository vendors. So
the whole "advance the `ts` anchor" deliverable collapses to a much smaller and much safer move —
re-anchor the F-rows to `cpp`, which is a commit `check-drift` already resolves — and the residual
drift is `ts -> cpp`, which is:

| file | `ts` -> `cpp` |
|---|---|
| `public_processor/public_processor.ts` | 24+ / 17− of 655 lines |
| `public_db_sources.ts` | 1+ / 1− of 406 |
| `public_tx_simulator/public_tx_simulator_interface.ts` | 5+ / 5− of 33 |
| `txe/src/utils/block_creation.ts` | 4+ / 10− of 91 |
| `fixtures/public_tx_simulation_tester.ts` | 41+ / 55− of 315 |
| `fixtures/utils.ts` | 6+ / 11− of 270 |
| `fixtures/simple_contract_data_source.ts` | 1+ / 1− of 122 |
| the other **seven** F-rows | **byte-identical at both anchors — zero drift** |

`avm/fixtures/utils.ts` (F22) is **ABSENT at `cpp`**: it is one of the ~16k lines `4377ddf64c`
removed, which is the very commit the `ts` anchor is defined as the parent of. F24 (`gas_compat.ts`)
is `added` and has no upstream counterpart. So the F-row population is 13 re-anchorable, 1 that
cannot move, 1 that has nowhere to move to.

The labs remote is **public and reachable** — `git ls-remote https://github.com/aztec-labs-eng/aztec-node.git`
answers, `main` at `4a7a2e2335`. Opening an anchor in a second repository is a decision of a size
this milestone should not take silently; it is recorded here as the option, with the measurement
that makes it the only route to a genuinely "current" TypeScript anchor.

---

## Step 6 — THE MSGPACK COMPARISON, MADE: **THEY DO NOT AGREE FIELD FOR FIELD**

New: `verification/_msgpack_schema_compare.py` and
`verification/verify_msgpack_schemas_match_field_for_field.sh` — **29 assertions, 0 failures.**

Both sides come out of the fork's **object store** at `anchors.cpp`, never a worktree. The wire keys
are derived by transcribing upstream's own `msgpack_detail::camel_case` from
`serialize/msgpack.hpp`, because `SERIALIZATION_FIELDS` emits the C++ member names verbatim and
`MSGPACK_CAMEL_CASE_FIELDS` does not — normalising both sides to a third spelling would have made the
comparison agree with itself.

**18 declared pairs: 11 AGREE, 7 DIFFER, 0 UNREADABLE.** And the agreements are stronger than set
equality — the field ORDER is identical in all eleven.

**The eleven that agree.** `NullifierLeafValue` `[nullifier]`, `PublicDataLeafValue` `[slot, value]`,
`IndexedLeaf<…>` `[leaf, nextIndex, nextKey]` (both instantiations), `WorldStateRevision`
`[forkId, blockNumber, includeUncommitted]`, `SiblingPathAndIndex` `[index, path]`,
`LeafUpdateWitnessData<…>` `[leaf, index, path]` (both), and the error envelope `[message]` — against
BOTH services' schemas **and** against upstream's own `bb::bbapi::ErrorResponse`, which is the control
that says the agreement is about a shape rather than about our copy.

**The seven that differ, in three distinct kinds, and only the third is about us.**

1. **A SPELLING UPSTREAM DISAGREES WITH ITSELF ABOUT.** `SequentialInsertionResult{Nullifier,PublicData}`:
   the generated schema declares `lowLeafWitnessData` / `insertionWitnessData`, and upstream's own C++
   struct declares `SERIALIZATION_FIELDS(low_leaf_witness_data, insertion_witness_data)` — the raw-name
   macro. The IPC service and the type our export returns are the same type with two different sets of
   wire keys, and neither of them is ours.
2. **A NAME, NOT ONLY A CASE.** `FindLowLeaf`'s response is `alreadyPresent`; `GetLowIndexedLeafResponse`,
   which `avm_merkle_db_get_low_indexed_leaf` returns, is `is_already_present`. The `is_` prefix is
   dropped as well as the case changed, so no case transform reconciles them.
3. **A SHAPE.** `GetTreeInfo` answers per tree — `[treeId, root, size, depth]` — where
   `AppendOnlyTreeSnapshot` is `[root, nextAvailableLeafIndex]`, and `GetStateReference` returns a
   `TreeStateReference[]` where `avm_merkle_db_get_tree_roots` returns one `TreeSnapshots` with four
   *named* members. Upstream's IPC models the trees as a list keyed by id; the AVM models them as a
   record.

**And the AVM half declares nothing at all.** `avm_schema.json` is twenty-four lines. Both commands —
`Simulate` and `SimulateWithHints`, upstream's spellings of `avm_simulate` and
`avm_simulate_with_hinted_dbs` — have a request of exactly `{inputs: "bytes"}` and a response of
`{result: "bytes"}`. The payload is **opaque to the schema**, while our exports take
`AvmFastSimulationInputs` `[wsRevision, config, tx, globalVariables, protocolContracts]` and
`AvmProvingInputs` `[publicInputs, hints]`.

**THE VERDICT, RECORDED AS MEASURED RATHER THAN PROMOTED.** "Two transports over one schema" is true
of the *transport* and false of the *declaration*. The inner types really are upstream's — that is
what the eleven agreements and `avm_msgpack_coverage`'s 42 round-trips say — but the generated IPC
schemas are a **second, independently-written description** of a subset of them, and where they
overlap they disagree in seven places. The negative control works: a fabricated field planted on the
schema side of an agreeing pair turns it `DIFFER` and names the plant.


---

## Step 7 — M11: RESOLVED, AND BY A NARROWING RATHER THAN A WAIVER

**M11 is 285, 7 of 7, exit 0.** It was 262 with the ninth-upstream-move signature and had been the
sweep's one standing red since the eighth move.

### What was actually wrong — six failures, two causes, and only one of them a decision

First run of `just verify-m11` (before anything was changed) — and the *first* run repaired part of
it by itself, because `verify-m11` is a writer and re-measures `carry/exposure.json` and
`carry/rebase.json` on every run. The residue is what matters:

| failure | cause |
|---|---|
| `bootstrap.sh`: the acknowledgement declares the region upstream changed | mechanical. **Four** upstream commits now touch the file, not one; the entry declared `[[876,1073]]` and the measurement is sixteen regions spanning 310..1221 |
| `upstream changed no path under barretenberg/cpp` — expected 0, got **5** | **the decision half.** `CAMPAIGN-BRIEF.md` records this as *"the seventh is a new class and is OPEN"* |
| the verdict is `void`, and its exit status | consequences of the two above |
| `CARRY-LEDGER.md` is not byte-identical to what the data renders to (×2) | consequence of the replay report moving |

### The five paths, read rather than assumed

`git diff --stat 233d8e0993 7471a61f1a -- barretenberg/cpp/` is **five files, 15 insertions, 63
deletions**, from **one** commit — `38fd5fc6e9c`, *chore!: build and test the labs components from
the submodule*. Read in full, every one of the five is the SAME rename, `yarn-project/` ->
`labs/yarn-project/`, in benchmark-input plumbing and one document. **No CMake file, no translation
unit, no header, no preset.** It is the other end of the same upstream change D23 is about.

### The narrowing, and it is computed rather than argued

Conjunct 1 was *"upstream changed no path under `barretenberg/cpp` AT ALL"* — a SUFFICIENT
condition, free for six upstream moves, and unavailable for a change no compiler can see. What
replaces it is not a looser version: every path upstream changed under the build root is
**CLASSIFIED**, at the tip, and the BUILD-INPUT set must be empty.

* `*.md` is documentation.
* `*.sh` is a non-input only if its basename appears in **none** of the build root's cmake inputs
  **at the tip** — 128 files, searched on every run, so a script an `add_custom_command` invokes
  reclassifies itself the day it becomes one. Calibrated: `avm_schema.json` **is** referenced from a
  `CMakeLists.txt` and must come back referenced, which is what says a `no` is a measurement.
* **Anything the classifier cannot place is a build input.** Fail-safe, on purpose.

The second half is that a classification is not evidence: each surviving non-input is **declared**
in `carry/overlap.json`'s new `build_root_non_inputs` block, pinned to upstream's blob ids at both
ends so upstream touching the path again expires the entry — and separately **measured** to be
uninvoked by M6's and M10's own build machinery, through the same spliced-in-tested invocation
predicate the top-level `bootstrap.sh` acknowledgement already used, one predicate per basename.

**And the dangerous direction is still unwaivable.** Four new mutation arms, each breaking exactly
one rule: a translation unit under the build root **with a complete, blob-accurate declaration in
front of it** is refused (`upstream-changed-a-build-input`); a file neither rule places is refused;
a declaration whose blobs have moved is refused; a build-root change with no declaration is refused.
All four `void`, all four naming their own token, all four exit 2.

```
verify_carry_set_complete: 46          verify_pr_branches_match_patches: 15
verify_carry_set_applies_to_upstream_head: 75   (was 52 with four failures)
verify_carry_ledger_complete: 17       verify_accepted_patches_dropped_from_carry: 15
verify_carry_exposure_measured: 22     verify_submission_is_a_manual_step: 95
                                                       M11 = 285, 0 failures, exit 0
```

**M11 262 -> 285 is +23 and every unit of it is in one check**: `verify_carry_set_applies_to_upstream_head`
52 -> 75. Three for the classifier's own calibration, one for the narrowed conjunct, one for the
non-input acceptance identity, ten for the five non-inputs' non-invocation and their five spliced
controls, and nine for the three new mutation arms.

`carry/exposure.json` and `carry/rebase.json` now hold `3836c2b6…` / `79f597b2…` — **the same two
post-sweep digests the brief has recorded on every run since M30**. The half-repaired state is gone:
the working tree now holds what every sweep was producing anyway.

`CARRY-LEDGER.md` renders the new block too, from the same file, so a decision recorded in data is
visible in the document rather than only in a check's output. 233 -> 263 lines,
`verify_carry_ledger_complete` unchanged at 17.

## Step 8 — THE FOUR M37 CHECKS

```
verify_noir_base_is_reconciled:                 30
verify_aztec_ts_anchor_current:                 25
verify_msgpack_schemas_match_field_for_field:   29
verify_m11_carry_set_resolved_or_retired:       45
                                        M37 = 129, 4/4, exit 0
```

Every one is a question about a REVISION, answered out of an object store, and **none of them
fetches** — `verify_carry_set_applies_to_upstream_head` is the one check in this repository that
does, and two checks fetching the same remote in one sweep would be two different tips inside one
measurement.

## Step 9 — WHAT THE RECONCILIATION MOVED IN THIS REPOSITORY, FOUND BY RUNNING RATHER THAN BY READING

Two, and both are the family M37's last deliverable names.

1. **A NEEDLE THE RECONCILIATION MOVED, IN A CHECK.** `test_fr_rendering_matches_noir_tracer`
   asserted `acir_field`'s `fits_in_i128` gate as the fixed string `num_bits <= 127`. beta.26 spells
   it `self.num_bits() <= 127`, and the old needle does not occur in the new spelling because of the
   parentheses — so the check went red for a reason with nothing to do with its subject. The
   property is unchanged. Re-derived, with the predicate's own declaration asserted beside it so a
   predicate renamed away cannot satisfy it either: **56 -> 57**, which takes **M25 272 -> 273**.
2. **A STALE SENTENCE, IN THE FILE IT IS ABOUT.** `build_avm_transpiler_wasm.sh` said *"`noir` on
   `blocktracer` is 1.0.0-beta.18 and the pin is 1.0.0-beta.26, with the pin NOT an ancestor of
   `blocktracer`"*. Measured after the reconciliation: `40d6574f85` **IS** an ancestor of
   `blocktracer` now, and the branch reports beta.26. The conclusion survives on a better reason —
   the branch carries four commits the pin does not, so a module built from the branch is not a
   module built from the pin — and it is corrected where it is written. A comment, so no count moves.


## Step 10 — THE MUTATION MATRIX: nine arms, and one of them found a defect in the harness itself

`scratchpad/campaign/m37-mutations.sh`. M37 has nothing to rebuild — every check is a question
about a revision answered out of an object store — so the arms mutate the INSTRUMENTS and the
DECLARATIONS, plus the two harness conditions this campaign has been bitten by.

| arm | what it breaks | measured |
|---|---|---|
| M1 | the camelCase transform is an identity | **29 / 3** — the self-test, the "nothing wrong" read, and the not-an-identity assertion (`l1tol2messagetree`) |
| M2 | the schema-side residue is always empty, so a planted field is invisible | **29 / 4** — the two pinned spelling residues, the AVM `inputs` residue, and **the negative control**, which reports `AGREE \| ` where it wants `DIFFER \| zzzFabricated…` |
| M3 | a declaration is allowed to excuse a BUILD INPUT | **45 / 4** — arm (a) `transfers` where it must `void`, its token, its exit status, and one neighbouring arm's token |
| M4 | a build-root non-input loses its declaration | **45 / 4** — three per-path re-derivations and the count 5 -> 4 |
| M5 | a declared post-image blob no longer matches upstream | **45 / 1** — exactly the post-image assertion, and the "upstream really did change it" partner stays GREEN, which is what says the two readings are not one reading twice |
| M6 | the Noir check's control reads the same revision at both ends | **30 / 4** — the beta.18 reading, the two-ends-differ assertion, the not-already-an-ancestor control, and the SSA fix's presence at `PRE` |
| **M7 — THE HANG** | the comparer never returns | **10 / 1**, bounded at 8 s, `cannot run: the command exceeded its 8s bound and was killed: python3 …` |
| **M8 — DIE BEFORE THE SUMMARY** | the comparer is not where the check looks | **0 / 1**, plus `FAIL — exited (status 1) before finish` |
| M9 | the anchor check's ts→cpp difference control compares `cpp` with itself | **25 / 1** — exactly "the same comparison DOES report differences", 0 where it wants ≥ 1 |

`HARNESS_RC=0`, every arm `restored; manifest verified`, **no `MUTATION MISS`, no `ABORTED`, no
`DID NOT HOLD`** in the final run.

**`still_there` was demonstrated to exit non-zero**, on its own path rather than by argument:
`--demo-still-there` applies a mutation, restores the file behind the harness's back, and the guard
prints `DEMO DID NOT HOLD`, restores, verifies the manifest, clears the marker and **exits 5**. A
guard nobody has seen fire is a guard nobody has seen work.

### AND M7 FOUND A DEFECT IN THE INSTRUMENT IT WAS WRITTEN TO EXERCISE

On its first run the hang arm printed **nothing at all** — no summary line, no diagnostic, just
`restored; manifest verified`. `m37_bounded` had done exactly what it was written to do; the call
site was

```
m37_bounded "$M37_BOUND" python3 "$CMP" … > "$WORK/out.json" 2>"$WORK/out.err"
```

and those redirections were **still in force when `exit` ran the EXIT trap**, so the summary line
went into `out.json` and the diagnostic into `out.err`. A check that dies with its summary
redirected into a scratch file reads to the sweep as a check that is not there — *"a missing check
reads as a smaller milestone, not as a red one"*, arriving through a file descriptor, inside the
function written to prevent the hang half of it. `m37_bounded_out` owns the redirection now, and
the arm prints `10 assertion(s), 1 failure(s)` at column 0.

**Two more, both found by running rather than by reading**, and both in `lib_m37.sh`:

* `if timeout …; then return 0; fi; local rc=$?` — an `if` whose condition is FALSE with no `else`
  exits **0**, so `$?` after the `fi` is the `if` statement's status, not the command's. The
  comparer exited 3 and the wrapper returned 0, reddening exactly the two assertions that read the
  comparer's status. `|| rc=$?` now.
* `timeout --preserve-status` returns the killed command's own status — **143** — so a timeout was
  indistinguishable from an ordinary failure and fell straight through the 124/137 test. Measured
  with `m37_bounded 2 sleep 20`. The flag is gone.


## Step 11 — `@aztec/native`: the gutting measured at the registration, and one sentence corrected

Read out of the addon's own `NODE_API_MODULE` registration rather than out of the plan —
`barretenberg/cpp/src/barretenberg/nodejs_module/init_module.cpp`:

| anchor | exported NAPI names |
|---|---|
| `ts` `3a68d68ac2` | **7** — `LMDBStore`, `MsgpackClient`, `MsgpackClientAsync`, `avmSimulate`, `avmSimulateWithHintedDbs`, `createCancellationToken`, `cancelSimulation` |
| `cpp` `233d8e0993` | **3** — the first three |

`yarn-project/native/src/native_module.ts` goes from **eight** exports to **one**, `NativeLMDBStore`.
`barretenberg/cpp/src/barretenberg/nodejs_module/` goes 23 files to 17. So the gutting is exactly
the size M37 claims.

**BUT THE WORLD STATE IS NOT PART OF IT, AND THAT SENTENCE WAS ABOUT TO GO INTO AN INVENTORY ENTRY.**
M37 says *"the AVM and the WorldState both left the addon"*. Measured: `NativeWorldStateService` is
declared in `@aztec/world-state`, never in `@aztec/native`, and
`yarn-project/world-state/src/native/ipc_world_state_instance.ts` exists at **both** anchors — so the
world state's IPC move predates the `ts` anchor and only the AVM's happened between them. RI-100's
first draft had inherited the plan's wording; corrected where it is written, and the sweep was
**aborted to do it** rather than left to ship the sentence.

The conclusion is unchanged and slightly sharper: what moved toward us in these eight weeks is the
AVM, and the world state had already moved before this campaign anchored.

## Step 12 — INVENTORY: RI-100 and RI-101, and the three-digit namespace exercised

The task's instruction was to take the next free ids and to verify that the parsers fixed after the
`RI-100` incident handle them. Both done, and the second is a measurement rather than a reading:

* **RI-100** — upstream's `aztec-wsdb` and `bb-avm-sim` IPC services. `build`, with a
  `cannot-reach-target:` reason: they are native PROCESSES (`execute_avm_server(input_path,
  wsdb_path, cdb_path)` connects to a running WSDB and CDB over IPC paths), a page can spawn
  neither, and DD-9 forbids the addon that is the only other route to the same code. What IS reused
  is upstream's msgpack TYPES, and the field-for-field result is recorded in the entry.
* **RI-101** — the `labs` submodule, `aztec-labs-eng/aztec-node`. `open`, with a three-part
  experiment and the verdict due above this campaign, because opening an anchor in a second upstream
  repository would need a second fork, a second anchor set and a second drift surface.

**The three-digit namespace, exercised rather than asserted.** `_manifest_parser.py`'s entry regex
`^### (RI-\d{2,}) ` and its residue regex `RI-\d{2,}(?!\d)` and `_inventory_parser.py`'s
`\bRI-\d+\b` were each run against `RI-100`, `RI-101` and `RI-99`: all three read three digits
whole, and the entry regex correctly declines a bare id with no heading. The inventory now really
carries RI-100 and RI-101 — so this is the live case, not a synthetic one. **`verify_fixture_corpus_manifest_complete`'s
DERIVED absent-id control moves with it**: it is one past the highest declared id, now `RI-102`, and
its "the derived absent inventory id really is absent" assertion is green. **M2 re-run at 293** and
`verify_reuse_inventory_complete` at **19**, both unchanged.


## Step 13 — A LIMITATION STATED WITH A FALSE REASON, IN MY OWN WORK, AND THE SWEEP ABORTED TO FIX IT

Reading the seven `ts -> cpp` diffs while the sweep ran — the only work available during one, and
the work the brief says finds what a check cannot — produced three findings, and the first is a
correction to something I had already written into four places.

**1. F22's upstream file MOVED; it was not deleted.** I had written, in `DRIFT.md` D23, in
`pins.json`'s `anchors.ts`, in the milestone section and in the check's own assertion text, that
`avm/fixtures/utils.ts` is *"one of the ~16k lines `4377ddf64c` removed"* and that the row
*"cannot move at all"*. Measured: `4377ddf64c` **renamed** it to `avm/testing/utils.ts` and shrank
it **154 -> 115** lines, and `simple_contract_data_source.ts`'s own import moves with it in the same
commit — which is how it surfaced, out of that file's one-line diff. That is
*"a limitation stated with a false reason is worse than one stated with none, because the false
reason closes the search"* — this campaign's own rule, in my own work, about a row I had declared
immovable.

**Corrected in all four places**, and the check no longer merely records an absence: the successor
is asserted PRESENT at `cpp`, asserted ABSENT at `ts` so the move is between the two anchors, and
the commit that made the move is asserted to be `4377ddf64c` itself. `verify_aztec_ts_anchor_current`
**25 -> 28**, so **M37 129 -> 132**.

**2. Upstream made the public simulator INJECTABLE, which is the obstacle M22's forced edit works
around.** `PROVENANCE.md`'s `processor-block-assembly` class removes `PublicProcessorFactory`
because *"its `protected createPublicTxSimulator` hard-defaults to `TelemetryCppPublicTxSimulator`,
the NAPI AVM, with no flag"*. At the `cpp` anchor the factory's constructor takes
`private avmSimulator: AvmSimulator` and `createPublicTxSimulator` builds a
`TelemetryPublicTxSimulator(this.avmSimulator, globalVariables, contractsDB, forkId, …)` — no `Cpp`,
no default. **A re-vendoring at `cpp` would re-derive that edit smaller, and possibly not need it.**
That is what "each forced edit re-derived, not carried forward blind" is for, and it is the strongest
argument in the file for doing the re-anchoring the deliverable defers.

**3. The `ts` anchor's `block_creation.ts` carries an upstream defect upstream has since fixed.**
At `ts` it appends `padArrayEnd(txEffect.l2ToL1Msgs, Fr.ZERO, NUMBER_OF_L1_L2_MESSAGES_PER_ROLLUP)`
into `MerkleTreeId.L1_TO_L2_MESSAGE_TREE` — **L2-to-L1 messages into the L1-to-L2 tree**. At `cpp`
the function takes an explicit `l1ToL2Messages: Fr[] = []` and appends it unpadded at compact
indices. This runtime's dev chain produces neither kind of message, so both sides append nothing
today and the vendored copy is **not visibly wrong** — which is precisely the shape `DRIFT.md`
exists for, and it is D23's second sub-entry now.


## Step 14 — A FORCED EDIT RE-DERIVED, AND UPSTREAM AGREES WITH IT TO THE UNIT

Read out of the remaining `ts -> cpp` diffs while the sweep ran. `PROVENANCE.md`'s
`spike-gas-compat` class exists because *"the anchor commit imports
`FALLBACK_TEARDOWN_{DA,L2}_GAS_LIMIT` from `@aztec/stdlib/gas` but the published nightly inlines"*
them, so `gas_compat.ts` reproduces the two values as **derivations**:

```
APPROXIMATE_MAX_DA_GAS_PER_BLOCK = floor(MAX_PROCESSABLE_DA_GAS_PER_CHECKPOINT / 4)
FALLBACK_TEARDOWN_L2_GAS_LIMIT   = floor(MAX_PROCESSABLE_L2_GAS / 8)
FALLBACK_TEARDOWN_DA_GAS_LIMIT   = floor(APPROXIMATE_MAX_DA_GAS_PER_BLOCK / 2)
```

**At the `cpp` anchor upstream itself has inlined them**, as two literals in
`public_tx_simulation_tester.ts`: `TEARDOWN_DA_GAS_LIMIT = 98_304` and
`TEARDOWN_L2_GAS_LIMIT = 817_500`.

Evaluated from upstream's own `constants.nr` at that anchor — `FIELDS_PER_BLOB = 4096`,
`BLOBS_PER_CHECKPOINT = 6`, `DA_BYTES_PER_FIELD = 32`, `DA_GAS_PER_BYTE = 1`,
`PUBLIC_TX_L2_GAS_OVERHEAD = 540000`, `AVM_MAX_PROCESSABLE_L2_GAS = 6_000_000`:

| | our derivation | upstream's literal |
|---|---|---|
| `FALLBACK_TEARDOWN_DA_GAS_LIMIT` | 6·4096·32 / 4 / 2 = **98,304** | **98,304** |
| `FALLBACK_TEARDOWN_L2_GAS_LIMIT` | (540,000 + 6,000,000) / 8 = **817,500** | **817,500** |

**Both to the unit.** So the forced edit is not merely defensible, it computes exactly what upstream
has since written down — and at the `cpp` anchor the edit becomes two literals rather than a
derivation, which is a third thing a re-vendoring would re-derive rather than carry. (The first
attempt at this got `DA_GAS_PER_BYTE` wrong from memory — it is `1`, not `16`, and it is commented
`// Arbitrary.` — which is why the constants were read out of `constants.nr` at the anchor rather
than recalled.)


### …and the SOURCE-level `ts -> cpp` drift is the same rename the npm pins carry

`fixtures/utils.ts`'s only non-gas change is
`AztecAddress.fromNumber(...)` -> `AztecAddress.fromNumberUnsafe(...)`. `PROVENANCE.md`'s derived-tree
entry declares that *"the entire API drift across those eight weeks is one mechanical rename,
`AztecAddress.from{Field,BigInt,Number,String}` -> `from…Unsafe`"* — a statement about the two **npm
pins**, checked by regenerating `drift/` from `spike/`. It is now corroborated at the **source**
level too, in the fork's own object store, on a file the regeneration does not touch. Two
independent routes to the same sentence, which is corroboration this campaign rarely gets.


---

## Step 15 — THE SWEEP: **12,069, `delta +0`, 76 markers for 38 milestones, no hole**

Measured M0–M37 on 2026-08-30 **after the last edit**, `setsid`-detached in this repository's own dev
shell (node v24.19.0), one milestone at a time with nothing else running, `TMPDIR` and the log under
`~/.cache`, at `origin/dev` `d324221`. **34 of 38 exit 0.**

```
m0 156  m1 182  m2 293  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 285  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 273  m26 313  m27 345
m28 357  m29 127  m30 218  m31 421  m32 237  m33 248  m34 217  m35 239  m36 140
m37 132
                                                       CAMPAIGN TOTAL 12,069
```

**Every one of M0–M36 came out at its declared reference value TO THE ASSERTION**, and
`11,910 + 23 + 1 + 3 + 132 = 12,069` exactly. Every move was in the reference table before the sweep
started:

| move | mechanism, measured | whose |
|---|---|---|
| **M11 262 -> 285** | `verify_carry_set_applies_to_upstream_head` 52 -> 75, the whole of it | M37's — the standing red closing |
| **M25 272 -> 273** | `test_fr_rendering_matches_noir_tracer` 56 -> 57, the needle the beta.26 refactor moved | M37's |
| **M36 137 -> 140** | `e2e_note_discovery_across_blocks` 74 -> 77 | **NOT M37's** — the parallel `m36:` commit `86c36ad` declares it |
| **M37 — -> 132** | 30 / 28 / 29 / 45 | M37's |

**M9 DID NOT FLAKE** — 807, rc 0, **1,290 s**, immediately after m8's 177 s run, which is D19's
standing condition and it did not fire. **M15 did not flake either** (537, 386 s).

### FOUR NON-ZERO EXITS AND NOT ONE OF THEM IS M37's — each attributed from the log's own per-check split

| milestone | check | reading | whose |
|---|---|---|---|
| m20 | `verify_named_checks_exist` | **9 / 1**, `UNRESOLVED test_reverted_transaction_recorded_as_reverted` in `tools/scan_reverted_transactions.mjs` | **L4's** (`75ce835`) |
| m21 | `verify_no_pipeline_predicates` | **69 / 1**, "the surviving set is exactly the five enumerated lines, expected 5, got **6**" — the sixth is `verify_browser_replay_dd9_clean.sh:297` | **L4's** (`d324221`) |
| m27 | `verify_browser_chunk_budget` | **33 / 1**, `total-kb expected 8,230.46` against a measured `8,230.24` | **L4's** browser half (`4b4e684`) |
| m28 | `verify_npm_pack_no_optional_native` | **54 / 1**, `replay/package.json` as a fifth tree | **L0's**, sixth milestone running |

**Every one has its COUNT unchanged**, which is what says a pinned list moved and not a structure.
Each was confirmed not-mine two ways: the offending file is not in M37's working diff
(`git status --porcelain` over both paths is empty), and `git log` on it names only the parallel
track's commits. All four **recorded and deliberately not fixed** — a second track editing the first
track's expectations is a collision this campaign has already paid for three times.

**The nine L0–L4 check names appear ZERO times as a summary line** in the whole sweep log, grepped
one at a time against the column-0 pattern. None of their assertions is in the 12,069.

**A sweep is a writer.** `carry/*.json` were checksummed before and `sha256sum -c` after: **all four
OK**. `exposure.json` and `rebase.json` now sit at `3836c2b6…` / `79f597b2…` — which are the
post-sweep digests every run since M30 has produced. M37 committed the repair the sweep had been
re-deriving and throwing away, so the half-repaired state is gone.

### M11's own milestone section is updated, and its `:status:` is NOT

The campaign's rule is that a milestone which moves another milestone's count updates that
milestone's section, so M11's Verification header now reads **285, per check 46 / 15 / 75 / 17 / 15 /
22 / 95**, and its "What the seventh and eighth moves broke, and the decision that is now owed"
subsection records the decision as **taken**, with what it did and what it did not need.

**Its `:status:` stays `partially_completed`, deliberately.** M16's
`verify_fallback_triggers_recorded_and_evaluated` reads M11's status as its own negative control —
*"the status reader returns something OTHER than completed where that is the truth (M11)"* — so
flipping it would redden M16 for a reason that has nothing to do with fallbacks. And it would be
wrong on the merits: M11's carry set now applies, but nothing is filed upstream, which is the
deliverable that is still open.

## Step 16 — POST-SWEEP EDITS, AND WHY THEY MOVE NOTHING

Three files were edited after the sweep — the milestone section, `CAMPAIGN-BRIEF.md` and this log —
and the reason that is not "run your sweep after your last edit" being broken is **measured rather
than assumed**:

* **No check opens the milestone file except M16's**, which reads `FALLBACK.md`'s seven conjunct
  texts, M7's and M8's `:status:` and M11's. M37's section is not in its reach, M11's status is
  unchanged, and m16 was green at 223 in the sweep.
* **No check opens `CAMPAIGN-BRIEF.md`.** Ten verification files mention it; every one is a prose
  citation — measured by M36's review and re-measured here with a grep for an actual read.
* **`scratchpad/` is not in `verify_named_checks_exist`'s roots** (`orchestration/src`,
  `node-host/src`, `ct-host/src`, `browser`, `verification`, `tools`), so this log is outside every
  scanner.


## Step 17 — FINAL STATE

| repo | branch | HEAD | committed / pushed |
|---|---|---|---|
| `noir` | `blocktracer` | **`5e8e6d03e`** | **yes — two commits, both fast-forward pushes, no force** |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | **not touched, not committed; zero published refs** |
| `aztec-avm-runtime` | `dev` | `d324221` (the sweep's tree) | **NOT committed** — 15 modified, 10 untracked, as the standing rule requires |
| `codetracer-specs` | `latest` | `4707c4da` | **NOT committed** — one modified file |

`git status --porcelain | grep -c '^.. replay/'` is **0**: nothing under `replay/` is touched.
All four diff3 markers grepped separately across the tree: **none**, `CAMPAIGN-BRIEF.md`'s own prose
about the markers excluded by name.
`carry/*.json`: **all four OK** against the pre-sweep digests.
`verify-m37` re-run after the last edit: **30 / 28 / 29 / 45, 4/4, exit 0.**
`just check-repo-hygiene`: **28, 0 failures.**
`verify_carry_set_applies_to_upstream_head` re-run alone: **75, 0 failures.**

**AND BOTH SHARED BRANCHES MOVED AGAIN AFTER THE SWEEP FINISHED, WHICH IS RECORDED RATHER THAN
CHASED.** `origin/dev` is six commits ahead of `d324221` and `origin/latest` nineteen ahead of
`4707c4da`, both since 23:33. The sweep is a measurement of `d324221` and says so; rebasing now would
silently make the 12,069 a figure about a tree nobody measured, and re-sweeping a fourth time is not
affordable. The review rebases — which is what M33's and M34's did for the same reason — and the four
non-zero exits already tell it which parallel-track expectations are live.

## What is NOT done, stated as a list rather than as a mood

1. **The `ts` anchor is not advanced and the F-rows are not re-taken.** Measured, sized and
   recorded: seven files with content to re-take (82+ / 100−), seven byte-identical, one (F22)
   re-anchorable to a renamed successor. Deferred because it is coupled to `npm.deletion_era`, which
   `orchestration/` consumes and eleven milestones' checks are measured against.
   `verify_vendored_files_retaken_from_new_anchor` is `pending`, with that as its reason.
2. **`npm.deletion_era` is not retired and `orchestration/` is not moved off it** — the same
   coupling, the same entry.
3. **The `a_1_mul` step-sequence question is still open**, and is now open under a pin that no longer
   records that it is open. The module header records it; nothing measures it.
4. **No anchor was opened in `aztec-labs-eng/aztec-node`.** RI-101 is `open` with a three-part
   experiment and the verdict due above this campaign.
