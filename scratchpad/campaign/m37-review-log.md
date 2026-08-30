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
