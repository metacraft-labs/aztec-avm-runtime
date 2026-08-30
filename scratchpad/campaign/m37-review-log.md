# M37 Review Log — Reconciliation (the campaign's final milestone)

Written **as I go**. Every figure below is measured at the moment the line was written, with the
command recorded. Nothing is inherited from the implementation log without re-derivation.

---

## Step 0 — preconditions and the state I inherited

- `CAMPAIGN-BRIEF.md` read in full (2,507 lines).
- `m37-impl-log.md` (724 lines) read in full.
- **No live sweep**: `ps aux` shows four stale `tail -f` processes (M14/M22/M30 review sessions and
  M37's own, Aug 24 / 26 / 28 / 21:49) and no `just verify-*` process.

`carry/*.json`, checksummed before I ran anything (a sweep is a writer, and so is `verify-m11`):

| file | working tree | HEAD |
|---|---|---|
| `carry/exposure.json` | `3836c2b6…` | `ec959b84…` |
| `carry/overlap.json`  | `bec69bce…` | `6d4d275a…` |
| `carry/rebase.json`   | `79f597b2…` | `aaeb6877…` |
| `carry/series.json`   | `da229896…` | `da229896…` |

The working-tree exposure/rebase digests are the post-sweep pair the brief records for every run
since M30, which is M37's Step 7 claim and it holds on disk.

## Step 0b — THE SHARED BRANCHES, AND THE +6 IS NOT WHAT THE HANDOVER DESCRIBED

`origin/dev` is **+6** as the handover says. It is **not** six L-track commits. Three of the six are
labelled **M37** and one of them does a large part of the work M37's own log declares DEFERRED:

| commit | subject | whose |
|---|---|---|
| `8cf321b` | *M37: the Aztec reconciliation is a SPLIT, and one of the two paths "gone at tip" is a rename* | a **second M37 agent** |
| `769e209` | *verification: `\b` is a GNU extension, and six fork greps were asking git a question it could not answer* | the same |
| `b22c550` | *M37: the version gate cannot be repaired, and the hash this repo declared is now checked* | the same |
| `75ffd7e`, `1c1d87f` | L4's browser half | L4 |
| `bb4393c` | brief: the hang-arm rule | (brief only) |

`b22c550`'s own message says *"re-checked origin/dev before pushing — no M37 work in flight"*, which
is true of `origin/dev` and false of the working tree: the M37 implementation this review is for
**never committed**, by the campaign's own rule that implementation agents do not commit. So the
collision-avoidance instrument (look at the branch) cannot see an uncommitted milestone, and two
agents wrote M37 at once.

**This is decisive for the count.** `8cf321b` retires `PROVENANCE.md`'s F24 row, re-anchors every
single-file F-row from `anchors.ts` to `anchors.cpp`, edits fourteen vendored files and adds
`verify_oracle_interface_hash_matches` — all of which are things milestones read. Its own message
declares **M1 179** and **M22 265**, against the 182 / 260 in M37's sweep table. So the 12,069
**cannot** hold across the rebase, and the handover's instruction applies: re-run the affected
milestones rather than absorb the difference.

## Step 1 — the rebase, and the two id collisions it produced

`aztec-avm-runtime`: M37's uncommitted work was committed as one checkpoint and rebased onto
`origin/dev`. **Two conflicts**, both in files the parallel M37 agent also wrote:

* **`DRIFT.md` — an ID COLLISION.** Both agents appended `D23` and `D24`, independently, and the
  subjects are not the same. `8cf321b`'s D23 is the TXE block helper's `l2ToL1Msgs` padding; its D24
  is the fallback teardown gas limits. M37's D23 is the `yarn-project` deletion; its D24 is the
  msgpack schema comparison. **Two of the four are the SAME FINDING derived twice** — M37's Step 13
  finding 3 is `8cf321b`'s D23, and M37's Step 14 is its D24, and the two derivations agree to the
  unit (98,304 / 817,500). Resolved the way this campaign resolves RI collisions: the landed pair
  keeps D23/D24, M37's become **D25** (the deletion) and **D26** (the msgpack comparison), and the
  four cross-references were repointed — `REACTOR-ABI.md:313`, `REUSE-INVENTORY.md:1068` (RI-100),
  `CAMPAIGN-BRIEF.md:1237`, and `pins.json`'s `drift_entries_opened`.
* **`pins.json` — `anchors.ts`.** `8cf321b` narrowed the anchor's role because it MOVED the F-rows;
  M37 wrote the ceiling measurement into the same field. Kept the landed text and **appended M37's
  ceiling measurement**, which `8cf321b` does not state anywhere: it is the fact that bounds the
  move `8cf321b` made.

`REUSE-INVENTORY.md` and `Justfile` auto-merged with no collision: 101 distinct RI ids, `RI-01..RI-101`,
none missing, none repeated (plus the `RI-nn` template heading, which is pre-existing); no duplicated
Justfile recipe.

`codetracer-specs`: `origin/latest` is **+21**, not +19. Three of the twenty-one are `milestones(M37)`
commits from the parallel agent. Two conflicts in the M37 section: `:status:` (`in-progress` against
`partially_completed` — took `partially_completed`, which is the truthful one and the one the
campaign's own rule licenses) and the Noir deliverables block (took the union: all three `[X]`, with
the landed commit citation `a74f565be4` kept).

All four diff3 markers grepped afterwards across both repositories: **zero**.

## Step 2 — THE `yarn-project` DELETION: VERIFIED IN EVERY PART, INDEPENDENTLY

Re-derived in the sibling fork against `upstream/next` = `7471a61f1a`, with none of M37's numbers
consulted while measuring:

| claim | command | result |
|---|---|---|
| `703d896149` deletes `yarn-project/` | `git diff --name-status 703d896149^ 703d896149 -- yarn-project \| wc -l` | **3,328** ✓ |
| …in a commit touching 10,825 paths | same without the pathspec | **10,825** ✓ |
| `git ls-tree <tip> yarn-project` is empty | `git ls-tree upstream/next yarn-project \| wc -l` | **0** ✓ |
| the ceiling is `703d896149^` = `38fd5fc6e9` | `git rev-parse 703d896149^` | **38fd5fc6e9c60d8327ddaaf270a556ca25b48a65** ✓ |
| …and it really is the LAST one | `git ls-tree <c> yarn-project` for every commit `38fd5fc6e9^..upstream/next` | `38fd5fc6e9` yp=1, then **0, 0, 0** — nothing reintroduces it ✓ |
| all fifteen F9–F23 paths absent at the tip | `git cat-file -e <tip>:<path>` per row, paths read out of `PROVENANCE.md` | **15 absent, 0 present** ✓ |
| all fifteen byte-identical at `cpp` and at the ceiling | `git rev-parse <rev>:<path>` per row, blob ids compared | **15 of 15 equal** ✓ |
| `cpp` is 16 commits before the ceiling | `git rev-list --count 233d8e0993..upstream/next` = 19, minus the 3 at/after the ceiling | **16** ✓ |

The ts-era spelling of F22, `avm/fixtures/utils.ts`, is also absent at the tip — so the row is gone
at the tip by BOTH its spellings, and the reason it survives at `cpp` is the rename, not luck.

**VERDICT: the load-bearing fact is true, and it is true for a stronger reason than stated.** The
deletion is not merely "the paths moved"; the TypeScript left the repository and the ceiling is
byte-identical to an anchor this repository already resolves. There is nothing in `aztec-packages`
to advance the `ts` anchor TO.

## Step 3 — M11'S NARROWING: the reasoning holds, one arm does not reach the instrument it names

`verify_carry_set_applies_to_upstream_head` re-run alone after the rebase: **75 assertions, 0
failures, exit 0.**

**The five build-root paths, read rather than inherited.** `git diff --stat 233d8e0993 7471a61f1a --
barretenberg/cpp/` is **five files, 15 insertions, 63 deletions**, and `git log` over that pathspec
names **one** commit, `38fd5fc6e9c`. Confirmed to the number.

**But "every one of the five is the SAME rename" is not exact, and it is stated in three places.**
Read per file:

* the three `scripts/*.sh` are the rename — plus `chonk_inputs.sh` also gains `env -u root -u ci3`;
* `barretenberg/cpp/bootstrap.sh` replaces an INVOCATION:
  `BOOTSTRAP_AFTER=barretenberg BOOSTRAP_TO=yarn-project ../../bootstrap.sh` becomes
  `(cd ../.. && make labs-yarn-project)`;
* `docs/Fuzzing.md` DELETES 50 lines of Docker documentation.

So two of the five are not renames. **The conclusion survives entirely** — none is a CMake file, a
header or a translation unit — but the sentence is a claim about content that two of its five
subjects do not satisfy, and it is written in `CAMPAIGN-BRIEF.md`, in the impl log and in the
check's own header. Corrected where it is written.

**The classifier, measured rather than read** (re-derived independently in the fork at the tip):

| | measured |
|---|---|
| cmake inputs under the build root | **128** — the declared number, exactly |
| the five changed paths, `referenced_by_cmake` | **all five False** |
| `.md` files under the build root | 110, of which **0** are referenced by any cmake input |
| `.sh` files under the build root | 57, of which **5 ARE** referenced (`remake-constants.sh`, four `zig-*.sh`) |

That last row is the strongest thing in the narrowing and the check does not use it: **rule (b) is a
real discriminator** — 5 of 57 `.sh` files under the build root would be classified BUILD INPUTS —
so a `no` really is a measurement and not a predicate that always says no. The check's own positive
control uses `avm_schema.json`, which is not a `.sh`, so it never exercises rule (b) in the
answering-yes direction.

**Conservative in the right direction: YES, and twice.** `verify_..._head.sh:295-301` sends
everything that is neither `*.md` nor an unreferenced `*.sh` to `build_inputs`; and independently
`_carry_overlap.py:183` rejects any in-build-tree path that is `in declared_inputs or not in
declared_non`. An unclassifiable path fails through both.

**Blob pins really expire: YES, verified two ways.** Arm `non-input-stale` moves a declared
`upstream_after` and the verdict goes `void` with token
`non-input-declaration-does-not-match-upstreams-current-change`, exit 2 — observed in the run. And
the code path is `_carry_overlap.py:191-194`, which compares the declaration against blobs the
CHECK re-derives from the fork (`upstream_blobs`), not against anything the declaration carries.

**THE ARM THAT MATTERS DOES NOT RUN THROUGH THE CLASSIFIER.** `build-input-changed` — "a translation
unit under the build root with a complete, blob-accurate declaration in front of it must still be
refused" — INJECTS `…/simulation/execution.cpp` into `d["build_inputs"]` in the decision procedure's
JSON input. It proves `decide()` refuses a path already classified as an input; it does not prove
the classifier classifies a `.cpp` as one. Same for `build-root-unclassified`, which injects a
`.zzz` into neither list. **Both arms bypass the classifier**, and the classifier's `else` branch —
the fail-safe the whole narrowing rests on — **executes zero times on the real data**, because all
five changed paths are `.md`/`.sh`.
This is "a control has to run through the instrument, not beside it", in the one place M11's
green now depends on. Closed below.

**"If no build input changed, the build cannot differ" — sound, and it needs the third leg it has.**
The argument is not classification alone: each surviving non-input is separately measured UNINVOKED
by M6's and M10's own machinery, with the predicate spliced-in-tested per basename. Two independent
reasons per path, plus blob pins that expire. What the classifier alone would not cover is a script
cmake reaches through a variable rather than by name — and the non-invocation measurement is what
closes that, because it asks M6's and M10's actual build scripts.

## Step 4 — DEFECTS FOUND IN M37's OWN HARNESS, AND ONE IS M36's TOO

1. **`just verify-m37` PRINTS `FAILED` AND EXITS 0.** The recipe accumulates `|| rc=1` and ends at
   `fi` with no `exit "$rc"`. Measured: with `verify_aztec_ts_anchor_current` at **5 failures**,
   `just verify-m37` returned **0**. That is "exit status AND the specific failure mode" with the
   status side missing, and it means M37's declared "4/4, exit 0" was taken through an instrument
   that could not have said otherwise. **`verify-m36` HAS THE SAME DEFECT** and shipped through
   M36's review. Censused across the whole Justfile: exactly these two (`verify-m9` accumulates but
   does `exit 1`; `mirror-replay-engine` does too). Both fixed; `just verify-m37` now returns 1 on a
   red check, and `just --list` still parses.
2. **`verify_oracle_interface_hash_matches` IS M37's, IS DECLARED IN M37's VERIFICATION SECTION, AND
   NO SWEEP COUNTED IT.** It landed on a standalone recipe (`just verify-oracle-interface-hash`) and
   was never added to `verify-m37`, so its assertions were outside the campaign total — a milestone
   entry that reads as present and measures as absent. M28's exclusion of one M27 check is the
   deliberate shape and it is PINNED by name; this was not a decision, it was an omission. Added.
3. **`verify_no_pipeline_predicates` WAS RED AT 69 / 3.** Two new `| grep -q` survivors, both from
   the parallel M37 commits: `verify_oracle_interface_hash_matches.sh:275` (M37's — fixed, replaced
   with `str_has_sub` plus a spliced positive control, so the absence is a measurement) and
   `verify_browser_replay_dd9_clean.sh:336` (**L4's — recorded, not fixed**). Now 69 / 1.
4. **`verify_aztec_ts_anchor_current` DERIVED ITS POPULATION FROM A DECISION RATHER THAN FROM THE
   SUBJECT.** It selected `PROVENANCE.md` rows by `anchor == "ts"`; the parallel commit moved every
   single-file row to `cpp`, the population went to **zero**, and three assertions compared empty
   sets. The check's own "so that emptiness is not the emptiness of the loop" guards FIRED — the
   guard working — but the repair is a derivation that survives the move: rows whose upstream path
   is under `yarn-project/`, which is **18** before and after. The absence assertion is re-read from
   the other end: every row's path exists at `cpp` (0 absent) and exactly one is absent at `ts` — the
   renamed successor. 28 -> **29**.

### The three `lib_m37.sh` fixes, verified empirically rather than read

| fix | test | result |
|---|---|---|
| `\|\| rc=$?` instead of `if …; then return 0; fi; $?` | `m37_bounded 300 bash -c 'exit 3'` | **rc=3** ✓ (and `exit 0` gives 0) |
| no `--preserve-status` | `m37_bounded 2 sleep 20` | `cannot run: the command exceeded its 2s bound and was killed: sleep 20` ✓ |
| `m37_bounded_out` owns the redirection | the same run's stdout | `t1: 0 assertion(s), 1 failure(s)` **at column 0** ✓ |

Census of call sites: **no redirected `m37_bounded` survives**. All four M37 checks install the
abnormal-exit trap. One overstatement: "a BOUND on every subprocess the checks wait on" — only the
msgpack check bounds anything; the other three run unbounded `git` reads. Object-store reads, so
the risk is small, but the sentence is wider than the code.

## Step 5 — THE DEFERRAL: the coupling is REAL, and it is one rename — so the deferral was CONVENIENT

The pending entry's reason is that re-anchoring is *"coupled to `npm.deletion_era`, which
`orchestration/` consumes and which eleven milestones' checks are measured against, so it is a
change to their subjects rather than a vendoring"*. **Measured, that is an overstatement of a real
but small fact, and the strongest evidence is that the work was DONE while the milestone was
declaring it undoable.**

`8cf321b` (the parallel M37 agent, on `origin/dev`) re-anchored every single-file `PROVENANCE.md`
row from `ts` to `cpp`, re-took the fourteen vendored files, retired F24 with its file, **and moved
no pin value** — `npm.deletion_era` is still `5.0.0-nightly.20260626`, `orchestration/` still
consumes it.

**The entire coupling, at the boundary, is one mechanical rename at two call sites**, and I measured
it rather than reading it. `AztecAddress`'s static API, at the two installed pins:

```
orchestration/node_modules/@aztec/stdlib  5.0.0-nightly.20260626 (deletion_era)
    fromNumber: function      fromNumberUnsafe: undefined
replay/node_modules/@aztec/stdlib         5.3.0-nightly.20260819 (current)
    static fromBigIntUnsafe(...)   static fromNumberUnsafe(...)
```

So the `cpp`-anchor source spells it `fromNumberUnsafe` and the pin `orchestration/` installs does
not have that method — hence the forced edit `fromNumberUnsafe -> fromNumber`, which retires when
`orchestration/` moves to `npm.current`. That is the coupling: **a two-line forced edit, not a
change to eleven milestones' subjects.**

And the re-take's own consequences are measured, on THIS host: `just check-drift` **25 / 0**, 822
files compared; `verify_provenance_complete` **71 -> 70** (F24's one `is tracked` assertion, nothing
else), so **M1 182 -> 181**; `verify_public_processor_vendored_not_reimplemented` **+5**, so
**M22 260 -> 265**.

**VERDICT: the deferral was convenient for the half it was asked about and correct for the half it
conflated with it.** Re-anchoring the F-rows was doable, cost one rename, and has been done.
Retiring `npm.deletion_era` and moving `orchestration/` to `npm.current` is a genuinely coupled,
genuinely larger change and is still open. The pending entry stated the second as the reason for
not doing the first. It is rewritten below to say which half is done and which is not.

## Step 6 — THE TWO FORCED-EDIT FINDINGS: both VERIFIED, at the line

**1. Upstream made the public simulator INJECTABLE, and that is the obstacle M22's edit removed a
factory to work around.** Read at both anchors:

```
ts  3a68d68ac2   return new TelemetryCppPublicTxSimulator(merkleTree, contractsDB, globalVariables, …)
cpp 233d8e0993   constructor(private contractDataSource: ContractDataSource,
                             private avmSimulator: AvmSimulator, …)
                 return new TelemetryPublicTxSimulator(this.avmSimulator, globalVariables, …)
```

`PROVENANCE.md`'s `processor-block-assembly` class removes `PublicProcessorFactory` because its
`createPublicTxSimulator` *"hard-defaults to `TelemetryCppPublicTxSimulator`, the NAPI AVM, with no
flag"*. At `cpp` there is no `Cpp` and no default: the AVM is a constructor parameter. **Half of
M22's reason has expired**, and the landed re-take says so rather than restating it — what survives
is the import graph, which is what DD-9 is about.

**2. The `ts` copy of `block_creation.ts` appends L2→L1 messages into the L1→L2 tree.** Read at both
anchors:

```
ts  await worldTrees.appendLeaves(MerkleTreeId.L1_TO_L2_MESSAGE_TREE,
      padArrayEnd<Fr, number>(txEffect.l2ToL1Msgs, Fr.ZERO, NUMBER_OF_L1_L2_MESSAGES_PER_ROLLUP));
cpp await worldTrees.appendLeaves(MerkleTreeId.L1_TO_L2_MESSAGE_TREE, l1ToL2Messages);
```

**`txEffect.l2ToL1Msgs` into `L1_TO_L2_MESSAGE_TREE`.** Upstream has since fixed it by taking the
block's real `l1ToL2Messages` explicitly and appending them unpadded. This runtime's dev chain
produces neither kind of message, so both spellings append nothing today and the vendored copy is
not visibly wrong — which is exactly the shape `DRIFT.md` exists for. It is D23 in the landed set.

**Both findings were derived INDEPENDENTLY BY TWO AGENTS**, which is corroboration this campaign
almost never gets: M37's Step 13 finding 3 and Step 14 are `8cf321b`'s D23 and D24, and the gas
derivation agrees to the unit (98,304 / 817,500) by two routes.

## Step 7 — NOIR: the reconciliation, verified; three characterisations hold; one assertion could not fail

Measured in `/home/zahary/m/blocktracer/noir` at `5e8e6d03e`, workspace `1.0.0-beta.26`, with
`nargo` **rebuilt at that commit** (the campaign's own rule: `cargo test -p noir_tracer` does not
rebuild the binary these tests spawn).

| claim | verdict |
|---|---|
| four campaign commits preserved by SUBJECT | ✓ all four `merge-base --is-ancestor` |
| …and by CONTENT | ✓ read at HEAD: `field_to_hex` at `tracer_glue.rs:143` used at `:200`; the repin block at `:191`; `vfs.rs` 1,168 lines + `compile_vfs.rs`; `if !print_timings { return f(); }` at `builder.rs:356` |
| two fast-forward pushes, no force | ✓ `origin/blocktracer` reflog has exactly `4d238163→a74f565be→5e8e6d03e`, each ancestor-advancing, no `forced-update` |
| `wasm/webpage` in ZERO published refs | ✓ 65 refs listed in full, no `webpage` ref of any kind |
| `noir-wt4-webpage` untouched | ✓ at `f0e7edcd2`, **but NOT clean** — it carries ` M tooling/tracer/src/tracer_glue.rs` dated 2026-08-27, three days before M37. Not M37's, and the log's word "untouched" is right while "clean" would not be. Left exactly as found; nothing committed there. |

**The SSA-timer sentence: M37's correction is right, and the measurement is exact.** `time()` reads
the clock unconditionally at `f403193bb`, at `3d3a1ce78` (byte-identical) and at `wasm/upstream-clean`;
it early-returns at `4d2381630` and at HEAD. So the fix was on `blocktracer` and what lacked it was
the RECONCILED tree. `nargo compile --force --benchmark-codegen` on `a_1_mul` prints **79** lines
matching `/: [0-9]+ ms$/`; without the flag, **0** lines of stdout at all. Exactly as declared.
(The flag is `#[arg(long, hide = true)]`, so it is not in `--help`.)

**THE THREE FIXTURES — all three characterisations TRUE.**

* **`a_1_mul` REPINNED, not fixed.** At `4d2381630` the `xs` pin is 10 entries / 3 leading `None`s;
  at HEAD it is 14 / 2, and the recorder emits exactly 14 / 2. The comparison is still an exact
  `assert_eq!` on a `Vec`, so it CAN fail. **The doubt-record is gone**: the pre-reconciliation
  header said *"the right expectation is a question about which step a stepper should stop on, so it
  is not repinned here"*; HEAD's replacement is a repin rationale.
* **`a_2_function_calls` still a defect, repinned with no comment.** The fixture is **13 lines**,
  counted. At `4d2381630` the pin ended `("main", 13)` and `142` appeared only in prose; at
  `f403193bb` `142` appears exactly once in the file, inside the pinned sequence, and `cf0a74e7d`'s
  message explains the other two fixtures and says nothing about it. Recorded live: `main`'s step
  lines are `[1, 9, 9, 10, 10, 11, 12, 142]`.
* **`multi_stmt` a defect in the TEST.** The old assertion wanted a step on line 4; the fixture is
  four lines and `assert(a + b + c == 6);` is on **line 3**. Recorded live: steps are
  `(1,c1) (2,c9) (2,c27) (2,c45) (96,None)` — **no step on line 3 at all**, which is the gap the
  replacement pins.

**AND THE NEW DECLARING TEST CARRIED AN ASSERTION THAT COULD NOT FAIL — the fortieth instance.**
`assert!(last > fixture_lines)` sat beside `assert_eq!(fixture_lines, 13)` and `assert_eq!(last, 142)`,
so `142 > 13` was true by construction. It is the assertion the test's own header credits with
*"lengthening the fixture past 142 lines trips it"* — and that property was actually being delivered
by the LENGTH pin, which trips at 14 lines, not at 143.

**And the defect it declares is the TREE's, not `a_2`'s.** Measured on all three fixtures:
`a_2_function_calls` 142 in 13 lines, **`a_1_mul` 264 in 9**, **`multi_stmt_per_line` 96 in 4**.
`a_1_mul`'s fourteen-entry pin covers line 264 without ever asserting it. Fixed: the length is read
and no longer pinned, and all three fixtures are declared. **Calibrated** — with `a_1_mul` pinned at
265 the suite is 6 passed / 1 failed and the failure names the fixture and both numbers.
Unmutated: **7 passed / 0 failed in 0.57 s.** Pushed fast-forward as `7e77c87c1`.
A stale doc comment still saying the `assert` is on `(line=4, column=1)` was corrected in the same
commit, in the test whose body was corrected for that very off-by-one.

**THE SILENT SKIP — the fix is calibrated both ways, by running it.** With both workspace `nargo`
binaries absent and no opt-out: `FAILED. 0 passed; 7 failed`, exit 101, each panic naming the
missing binary AND `cargo build -p nargo_cli --bin nargo` AND the `CODETRACER_NARGO_BIN` escape.
With `NOIR_TRACER_ALLOW_SKIP=1`: `ok. 7 passed` in 0.253 s. And the original defect was reproduced:
without the opt-out the old shape printed `ok. 6 passed … 0.00s` over a tree that ran nothing.
**One residue**: the opt-out path still prints `ok. 7 passed … 0.00 s` with nothing in the summary
line marking the run vacuous, so a CI job that ever sets that variable inherits the whole original
defect. Recorded.

**THE RECONCILIATION DEFECT FOUND BY BUILDING — verified, and the log's caveat is removable.**
Upstream `08f44a128` (*chore!: ACIR instrumentation and optimization*) deletes
`tooling/nargo/src/ops/optimize.rs` and strips `optimize_program`/`optimize_contract` from
`compiler/wasm/src/compile.rs`. At the merge commit `a74f565be`, `vfs.rs:783,795` still call both
and `ops/mod.rs` has no `optimize` symbol — so the merged tree could not compile `noir_wasm`.
`5e8e6d03e` applies the same edit upstream applied to its own `compile.rs`.
`cargo check --release -p noir_wasm` after touching `vfs.rs`: **exit 0**.
**And the wasm32 caveat is a shell fact, not a tree fact — one step further than the log went**:
through `/usr/bin/rustc` it is `E0463`, but through the sibling `codetracer` dev shell
`cargo check -p noir_wasm --target wasm32-unknown-unknown` **finishes, exit 0, 24.5 s**. This is
this campaign's own *"the repo whose shell you need may be a SIBLING"* rule, met again.

## Step 8 — THE MSGPACK COMPARISON: 11 / 7 verified, the control fires, one assertion did not

* **29 assertions, 0 failures** as declared (now **31** after the fix below); reproduced twice.
* **18 declared pairs, 11 agree with identical field ORDER, 7 differ, 0 unreadable**, membership read
  off the comparer's own output. **Caveat worth recording**: 18 *pairs* is **15 distinct C++
  declarations** — `IndexedLeaf`, `LeafUpdateWitnessData` and `SequentialInsertionResult` are each
  paired twice, and 3 of the 11 agreements are the one-field `[message]` envelope. The prose never
  claims otherwise, but "eighteen declared pairs" reads stronger than the underlying 15 / 8.
* **Both sides out of the object store at `anchors.cpp`**: the materialisation is
  `git -C "$FORK_ROOT" show "$ANCHOR:$rel"` for all eight upstream paths, asserted; no read touches
  the fork's worktree.
* **The `camel_case` transcription is exact.** Upstream's C++ at
  `233d8e0993:…/serialize/msgpack.hpp:130-148` was re-implemented independently and differentially
  tested against the Python over an **exhaustive enumeration of `{_,a,Z,2,$,0,z}` up to length 5
  plus 23 adversarial names — 19,631 inputs, 0 mismatches**. `avm2 -> avm2`,
  `l1_to_l2_message_tree -> l1ToL2MessageTree`, `a__b -> aB`, `_2a -> 2a`. The only theoretical
  divergence is bytes vs codepoints, unreachable over C++ identifiers.
* **The three kinds all confirmed at the anchor**, including the strongest sentence:
  `response.hpp:98-103` really does declare `SERIALIZATION_FIELDS(low_leaf_witness_data,
  insertion_witness_data)` — the RAW-name macro — against `wsdb_schema.jsonc:78-81`'s
  `lowLeafWitnessData`. `is_already_present` vs `alreadyPresent` confirmed; the tree-shape
  difference confirmed. `avm_schema.json` is **exactly 24 lines** and declares no AVM field.
* **THE NEGATIVE CONTROL FIRES, AND IT RUNS THROUGH THE INSTRUMENT.** Re-derived independently by
  planting a field into the actual `wsdb_schema.jsonc` (a stronger plant than the check's own
  `inject` hook, because it goes through the JSONC parser): `DIFFER`, `only_in_schema:
  ['plantedByReviewerNotInAnyCpp']`. And against a stop-comparing mutant that copies the schema side
  onto the C++ side, the control row reads `AGREE | ` and goes red **by itself**.
* **BUT ONE ASSERTION COULD NOT FAIL FOR THE REASON IT CLAIMED.** *"with a fabricated field planted,
  the comparer still exits 3"* — the UNPLANTED run already exits 3, since seven pairs differ without
  help. It caught a crash and nothing else while its description claimed to measure the control.
  Replaced by two that are measurements: the plant moves the agreeing set **11 -> 10** and the
  differing set **7 -> 8**. 29 -> **31**.
* **The retired claim is qualified everywhere it is written** — grepped repo-wide, no unqualified
  survivor. One residue fixed by this review: `REACTOR-ABI.md`'s section HEADING still read *"The
  host ABI is upstream's msgpack schemas"*, corrected 37 lines below but not in the heading, which
  is what a scanning reader takes away.
* **One overstatement**, confined to the implementation log: *"three distinct kinds, and only the
  third is about us"*. None of the seven is about us — every differing row's C++ side is an upstream
  declaration at `233d8e0993`. `REUSE-INVENTORY.md` and `DRIFT.md` D26 both carry the accurate
  wording ("only the third is a modelling choice", "none is a defect in this runtime").

## Step 9 — THE MUTATION MATRIX: nine arms, all fire, re-taken against the tree that ships

Re-run after the review's edits (the campaign's own rule — a matrix taken before the last edit is
not a measurement of the tree that ships):

| arm | declared | re-taken | note |
|---|---|---|---|
| M1 camelCase identity | 29 / 3 | **31 / 3** | same failures, new count |
| M2 schema residue empty | 29 / 4 | **31 / 6** | the review's two new control assertions catch it too |
| M3 declaration excuses a build input | 45 / 4 | 45 / 4 | ✓ |
| M4 non-input loses its declaration | 45 / 4 | 45 / 4 | ✓ |
| M5 declared post-image blob moves | 45 / 1 | 45 / 1 | ✓ exactly the post-image assertion |
| M6 Noir control reads one revision twice | 30 / 4 | 30 / 4 | ✓ |
| **M7 the HANG** | 10 / 1 | **10 / 1** | `cannot run: the command exceeded its 8s bound and was killed: python3 …`, summary at column 0 |
| **M8 die before summary** | 0 / 1 | **0 / 1** | plus `FAIL — exited (status 1) before finish` |
| M9 anchor control reads cpp twice | 25 / 1 | **29 / 3** | the repointed population reddens three |

`HARNESS_RC=0`, every arm `restored; manifest verified`, **no `MUTATION MISS`, no `ABORTED`, no
`DID NOT HOLD`**, tree clean afterwards. `--demo-still-there` **exits 5** with
`DEMO DID NOT HOLD`, restore and manifest verification.

**The hang arm's own finding — the redirection swallowing the trap's summary — is verified fixed by
construction and by measurement.** No redirected `m37_bounded` call site survives (`grep`), and the
three `lib_m37.sh` fixes were each exercised directly: status passthrough returns **3**, the bound
fires at 2 s with a named diagnostic, and the summary line lands at column 0. That shape — a check
that dies with its summary in a scratch file — is this campaign's silent-death family, and it is
closed here in the function written to prevent the other half of it.

## Step 10 — MILESTONE-FILE CORRECTIONS THE REVIEW OWED

* **M11's four `status: failing` entries were STALE.** `verify_carry_set_applies_to_upstream_head`,
  `verify_carry_ledger_complete`, `verify_accepted_patches_dropped_from_carry` and
  `verify_carry_exposure_measured` all still read `failing` with "as of 2026-08-27" prose, while M11
  is green. Set to `passing`, each with a leading `RESOLVED:` sentence naming what closed it and
  marking the historical account as historical. **`status: failing` now appears zero times in the
  whole file.**
* **M11's header 285 -> 287**, per check `46 / 15 / 77 / 17 / 15 / 22 / 95`, in all four places that
  quote it.
* **M37's own entries re-stated to the assertion**: the anchor check 25 -> 29 with its population
  re-derivation recorded, the msgpack check 29 -> 31 with the replaced control recorded, and
  `verify_oracle_interface_hash_matches` 35 -> 36 with the fact that no sweep ran it until now.
* **The pending entry rewritten.** See Step 5.

**And one defect this review introduced and caught in itself.** Merging the two agents' `pins.json`
history entries left the newest entry not naming `npm.current`'s and `npm.deletion_era`'s current
values, and `verify_pinned_nightly_single_source` — which requires exactly that — went **29 / 2**.
Found by running it rather than by reading the merge. Restored: **28 / 0**, the reference value.

### And the deferral's own figure was wrong, in the direction that reads as smaller

The pending entry said the coupling reaches *"eleven milestones' checks"*. Re-derived — the 50
verification scripts that read `orchestration/`, mapped to the milestones whose Verification
entries name them — it is **fifteen**: M18, M19, M20, M21, M22, M23, M25, M26, M27, M28, M29, M31,
M33, M34, M35. A figure nobody re-derived, in the sentence a deliverable was deferred on. It makes
the *scope* larger and the *argument* no stronger, because the re-take was taken without moving the
pin and those fifteen are measured green by this review's own sweep.

## Step 11 — THE FOUR NON-ZERO EXITS: three attributions hold, ONE NAMES THE WRONG TRACK

Re-derived by `git log` on the offending path and by `git status --porcelain` over it (empty for all
four, so none is in this review's working diff):

| milestone | offending path | M37 declared | measured |
|---|---|---|---|
| m20 `verify_named_checks_exist` | `tools/scan_reverted_transactions.mjs` | **L4's** (`75ce835`) | **L3's** (`a601ce7`) — that file's ONLY commit, `--follow`ed; `75ce835` touches four files and none is this one |
| m21 `verify_no_pipeline_predicates` | `verification/verify_browser_replay_dd9_clean.sh` | L4's | **L4's** ✓ (`75ffd7e`, `1c1d87f`, `d324221`) |
| m27 `verify_browser_chunk_budget` | `replay/browser-budgets.json` | L4's browser half | **L4's** ✓ (same three) |
| m28 `verify_npm_pack_no_optional_native` | `replay/package.json` | L0's | **L0's** ✓ (`541bf5f`) |

**The substance of all four survives — none is M37's — and one names the wrong track.** m20's red is
**L3's**, not L4's. It is the smallest kind of error and it is exactly the kind this campaign's
standard exists to catch: *"both attributions were re-derived independently by the review and both
held; that is the standard, not the presumption."* Here one did not.

## Step 12 — WHAT REMAINS OUTSTANDING ACROSS ALL 38 MILESTONES

Derived from the milestone file rather than remembered: **240 Verification entries, of which 22 are
`pending`.** `status: failing` is now **zero** (M11's four were stale and are corrected above).

**The pending 22, grouped by what actually blocks them.**

*Blocked on a human, not on the tree (1):*
- **M11 `verify_all_five_patches_submitted`** — five prepared patches, five published `pr/*` branches
  plus the downstream `codetracer` branch, and **nothing filed upstream**. The user runs
  `submit/pr<N>-*.sh`, which writes the URL into `carry/series.json`, the entry's `PR.md` and
  `CARRY-LEDGER.md`, at which point the check becomes checkable. Until then all five read
  `READY TO REVIEW — not filed` and all five ledger statuses read `prepared`, and
  `verify_carry_ledger_complete` asserts those two agree rather than pretending otherwise.

*Guarded by "if triggered" — a fallback nobody has needed (4):* **M16**
`test_fallback_empty_note_hash_tree_root`, `test_fallback_domain_separators_from_constants`,
`test_fallback_checkpoint_stack_is_o_changes`, `e2e_fallback_matches_golden_vectors`. No trigger has
fired, so there is no TypeScript tree to assert about. What CAN be checked is, by
`verify_fallback_cost_priced`.

*Blocked on a transaction builder that does not reach `@aztec/world-state` (7):* **M18**
`e2e_ts_wasm_token_transfer`, `e2e_ts_wasm_amm`, `e2e_ts_wasm_nested_call_fork_merge`,
`test_custom_bytecode_unhappy_paths`; **M22** `e2e_block_deployments_through_processor`,
`e2e_block_token_flows`; **M25** `e2e_trace_token_transfer_steppable`. Upstream's only builder is
`PublicTxSimulationTester`, which constructs a `NativeWorldStateService` — the package DD-9 forbids.
**M18 `e2e_ts_wasm_phase_revert_semantics` is different and is a CORPUS gap**: every program in the
corpus is one app-logic call, and the asymmetric revert model needs a transaction with calls in more
than one phase.

*Blocked on `@aztec/pxe`, which hard-depends on `@aztec/simulator` -> `@aztec/native` +
`@aztec/world-state` (4):* **M21** `test_form_b_tx_matches_pxe_bytes`,
`test_settled_read_request_verification`; **M26** `e2e_form_b_single_ct_recording`; **M25**
`test_nested_call_reverted_contributes_no_side_effects` and `test_debug_log_events_surface` (the
guarantee and the source both exist upstream; the transaction that drives them is not built).

*Blocked on tier 2 of private execution (2):* **M35** `e2e_wallet_private_transfer` — the stop set is
now a measured singleton per program and the rung that blocks is `aztec_utl_getNotes` /
`aztec_prv_getSenderForTags` / `aztec_utl_getPublicKeysAndPartialAddress` — and
`e2e_joined_private_public_trace`, which depends on it and on `aztec_prv_callPrivateFunction`.

*Blocked on a binary that does not exist in this workspace (1):* **M26**
`e2e_joined_trace_opens_in_codetracer` — the `codetracer` repository IS a sibling checkout and there
is **no built `ct` binary anywhere in it**, measured rather than asserted.

*Blocked on a pin move this milestone did not take (1):* **M37**
`verify_vendored_files_retaken_from_new_anchor` — see Step 5. The FIRST half (re-anchor the F-rows)
is DONE; what remains is retiring `npm.deletion_era` and moving `orchestration/` to `npm.current`.

**Owed beyond the pending entries:**

1. **Nothing is filed upstream.** Five patches prepared, six branches published (five `pr/*` plus the
   downstream `codetracer`). Submission is the user's manual step, five scripts under `submit/`.
2. **PR #22815** (Emscripten migration) is open upstream and would delete what patch 2 changes.
   Patches 1, 3 and 4 are unaffected but for one shared file.
3. **The CI is published and scheduled and every one of its twelve jobs dies at `Generate CI token`**
   with `Input required and not supplied: app-id`. No job has ever reached a check. The cause is
   scoped to this repository — `codetracer-ci` is same org, same runner group, same label, same
   action, same `vars.` spelling, and its token step succeeds.
4. **`m9_completeness` is wired into two of the four checks that read the V8 transcript.**
   `test_observer_fires_on_exceptional_halt` and `test_existing_event_emitter_path_still_available`
   still produce red assertions that read like discoveries about the interpreter when the transcript
   truncates. This has been the file's own outstanding item since M24.
5. **D19's trigger is unestablished** after seven distinct truncation points.
6. **`verify_tier_e_authored_fixtures_justified`'s `fx = 26 + i`** synthesises Tier E ids from a
   hardcoded base the manifest overtook, injecting duplicate ids; recorded as fragility rather than a
   hole because the tier-size rule still fires.
7. **The `a_1_mul` step-sequence question is open under a pin that no longer records that it is
   open.** The reconciliation re-pinned it to today's output; the module header records the doubt and
   nothing measures it.
8. **The out-of-range last step is a live recorder defect in three fixtures**, now declared by name
   in `noir`'s own suite. Nothing fixes it.
9. **`NOIR_TRACER_ALLOW_SKIP=1` still prints `ok. 7 passed … 0.00s`** with nothing in the summary
   line marking the run vacuous. A CI job that ever sets it inherits the original defect.
10. **No anchor is opened in `aztec-labs-eng/aztec-node`.** RI-101 is `open`; the remote is public and
    answers `ls-remote`. It is the only route to a genuinely current TypeScript anchor and it needs a
    second fork, a second anchor set and a second drift surface.
11. **One surviving `| grep -q` predicate**, `verify_browser_replay_dd9_clean.sh:336` — **L4's**,
    recorded and deliberately not fixed, so M21 reads 69 / 1.
12. **`noir-wt4-webpage` carries uncommitted work** (` M tooling/tracer/src/tracer_glue.rs`, dated
    2026-08-27) on a branch published nowhere. Not this milestone's, not touched, recorded.

## Step 13 — THE REBASED SWEEP: **12,141**, and SIX OF THE NINE REDS WERE M37's OWN

Measured M0–M37 on 2026-08-31, **after the rebase onto `origin/dev` `33e8ad5` and after the
review's last edit**, `setsid`-detached in this repository's own dev shell (node v24.19.0), one
milestone at a time with nothing else running, `TMPDIR` and the log under `~/.cache`.
**76 markers for 38 milestones, NO HOLE.**

```
m0 156   m1 181   m2 293   m3 199   m4 218   m5 236   m6 363   m7 287   m8 516   m9 807
m10 450  m11 287  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 265  m23 509  m24 350  m25 273  m26 340  m27 345
m28 357  m29 127  m30 218  m31 421  m32 237  m33 248  m34 217  m35 239  m36 140
m37 171
                                                       CAMPAIGN TOTAL 12,141
```

**Every unit of the move from 12,069 is accounted for in both directions**, and
`12,069 − 1 + 2 + 5 + 27 + 39 = 12,141` exactly:

| move | mechanism, measured | whose |
|---|---|---|
| **m1 182 -> 181** | `verify_provenance_complete` 71 -> 70 — F24's one `is tracked` assertion, its row retired with its file | the parallel M37 agent's (`8cf321b`) |
| **m11 285 -> 287** | `verify_carry_set_applies_to_upstream_head` 75 -> 77, the classifier run through its own function over synthetic paths | **this review's** |
| **m22 260 -> 265** | `verify_public_processor_vendored_not_reimplemented` 71 -> 76, the RI-65 worktree block turned the right way up | `8cf321b` |
| **m26 313 -> 340** | `verify_tx_builder_vendored_not_reimplemented` 133 -> 160; `git log` names `8cf321b` as that file's most recent commit | `8cf321b` |
| **m37 132 -> 171** | 30 / 29 / 31 / 45 / 36 — +1 anchor population, +2 msgpack control, **+36 a check no sweep had ever run** | M37's + this review's |

**M9 FLAKED, AT AN EIGHTH DISTINCT TRUNCATION POINT, AND IT IS THE HIGHEST YET.**
`truncated-after-32788-lines-last-key-steps.burn.32514`, `807 − 524 = 283 = 140 + 143` — the two
comparers that correctly refuse and print no summary while doing it. The sightings are now
**39,113 / 16,719 / 14,572 / 17,866 / 3,943 / 15,688 / 4,051 / 32,788**; same input, same module,
same host, and the trigger stays unestablished. The twelve red assertions are 11 in
`test_observer_fires_on_exceptional_halt` and 1 in `test_existing_event_emitter_path_still_available`
— **the two checks `m9_completeness` is STILL not wired into**, which is this file's own outstanding
item, unchanged since M24. Re-run alone: see below. **M15 did NOT flake** (537, 395 s).

### THE NINE NON-ZERO EXITS, AND THE HEADLINE "NONE IS M37's" DOES NOT SURVIVE

M37's own sweep reported four non-zero exits and *"not one of them is this milestone's"*. Re-measured
after the rebase there are **nine**, and **six of them are M37's own work** — the parallel agent's
re-take of the vendored files, whose consequences no sweep had seen because that agent's own sweep
was disk-blocked at 492 MB free and thirty of its thirty-seven milestones died on a work-directory
precondition.

| milestone | failure | whose | action |
|---|---|---|---|
| m9 | D19 truncation, 8th point | the machine | re-run alone |
| m20 | `verify_named_checks_exist` 9/1, `test_reverted_transaction_recorded_as_reverted` in `tools/scan_reverted_transactions.mjs` | **L3's** (`a601ce7` — M37 said L4's) | recorded, not fixed |
| m21 | `verify_no_pipeline_predicates` 69/1, a sixth `\| grep -q` at `verify_browser_replay_dd9_clean.sh:336` | **L4's** | recorded, not fixed |
| m27 | `verify_browser_chunk_budget` 33/1 — **three parts**: `testing.js` 291.09 vs 291.08 and `node/node.js` 225.49 vs 225.48 (**ours**), and total-kb 8,230.24 vs 8,230.44 (**L4's figure, moved by our re-take**) | **mixed** | **fixed** |
| m28 | `just ci-browser-gate` 104/1, the metafile input count 1197 vs 1196 (**ours** — F24's file left the graph); and `verify_npm_pack_no_optional_native` 54/1, `replay/package.json` (**L0's**) | **mixed** | doc fixed; L0's recorded, not fixed |
| m32 | `test_worker_transferable_container_not_copied` 8 failures over four `WORKER-NODE.md` §5 rows | **ours** | **fixed** |
| m34 | `e2e_wallet_public_transfer` 1, `DEV-WALLET.md`'s wallet-demo eager KB | **ours** | **fixed** |
| m35 | `verify_oracle_coverage_is_measured` 1, `PRIVATE-EXECUTION.md`'s same row | **ours** | **fixed** |
| m36 | `e2e_note_discovery_across_blocks` 1, `LOCAL-HISTORY.md`'s same row | **ours** | **fixed** |

**ONE CAUSE, ELEVEN DOCUMENT FIGURES, SIX MILESTONES.** Re-taking fourteen vendored files and
deleting `gas_compat.ts` moved four entry points' eager gzipped size by **one hundredth of a KB
each**, moved the bundle total by 0.20 KB and removed one input from the browser metafile — and no
document was updated, because the agent that made the change could not run a sweep. **Every count
stayed exactly at its reference**, which is what says a pinned figure moved and not a structure, and
every one of the eleven is a figure a check re-derives from the artefact on every run, which is the
only reason they were found. Corrected to the CHECK's value, which is this campaign's settled rule
for the rounding family. Re-run after the corrections: **m27 345/0, m32 237/0, m33 248/0,
m34 217/0, m35 239/0, m36 140/0, all exit 0**; m28 **357** with its one remaining failure being
L0's, unchanged. **No count moved.**

**The nine L0–L4 check names — fourteen, counting L3's and L4's — appear ZERO times as a summary
line in the whole sweep log**, grepped one at a time against the column-0 pattern. None of their
assertions is in the 12,141.

**A sweep is a writer**: `carry/*.json` checksummed before, `sha256sum -c` after — **all four OK, and
unchanged**, because M37 committed the repair the sweep had been re-deriving and discarding, so
`3836c2b6…` / `79f597b2…` are now what is on disk before and after.

## Step 14 — M9 ALONE, AND THE FINAL STATE

`just verify-m9` alone, on an otherwise idle box: **807 assertions, 7/7, exit 0**, split
**140 / 143 / 113 / 73 / 126 / 83 / 129** — the reference exactly, with no truncation (the three
`truncat` hits in the log are the completeness assertions' own text). Not a regression.

Post-correction re-runs, each after the last document edit: **m1 181, m27 345/0, m28 357 (one
failure, L0's), m32 237/0, m33 248/0, m34 217/0, m35 239/0, m36 140/0, m37 171/0**,
`just check-repo-hygiene` **28/0**, `verify_named_checks_exist` **9/1** (L3's, unchanged).

**CAMPAIGN TOTAL 12,141.**

| repo | branch | state |
|---|---|---|
| `aztec-avm-runtime` | `dev` | committed and pushed, fast-forward, rebased twice onto `origin/dev` |
| `codetracer-specs` | `latest` | committed and pushed |
| `noir` | `blocktracer` | `7e77c87c1`, pushed fast-forward |
| `noir-wt4-webpage` | `wasm/webpage` | **not touched, not committed**, zero published refs |

All four diff3 markers grepped across both repositories: **none**.
`git status --porcelain -- replay/`: **empty** — nothing L0's or L4's was modified.
