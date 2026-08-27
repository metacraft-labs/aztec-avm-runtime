# M28 review log — Browser CI Gate, and the close of the campaign

Review agent. Written as I go, per `CAMPAIGN-BRIEF.md`.

## 0. Starting state, measured before anything was believed

- `aztec-avm-runtime` on `dev` at `da586b7` (= `origin/dev`), M28's work **uncommitted** in the
  working tree: 4 modified (`.github/workflows/avm-wasm.yml`, `CAMPAIGN-BRIEF.md`, `DRIFT.md`,
  `Justfile`), 12 untracked paths (`BROWSER-GATE.md`, `verification/_m28_bundle_scan.py`,
  `verification/lib_m28_gate.sh`, `verification/ci_browser_gate.sh`, four `verify_*`/`smoke_*`
  scripts, `verification/m28/`, four `scratchpad/campaign/m28-*`).
- **The impl agent's own sweep log re-summarised rather than read.**
  `m28-sweep-sum.py ~/.cache/aztec-m28-sweep.log` prints `TOTAL 10043 milestones 29 failing
  assertions 8 non-zero exits ['m11']`, `delta +0`, **no holes**. So the declared table is what
  that log actually contains. Whether the tree still produces it is my sweep's question.
- **The box is not idle.** A foreign agent is building `codetracer` in
  `/home/zahary/m/prox-fixes/codetracer` (`just test-vm-native`, gcc/Nim). Load average at launch
  1.40 / 3.60 / 3.85 on 32 cores. Recorded, because M9's flake hypothesis is about load; M23's
  sweep reproduced on a non-idle box, so this is a condition, not a disqualification.
- `/tmp` 22 G used of 32 G (10 G free); `/home` 195 G free. `TMPDIR` is under `~/.cache`.

## 1. My sweep — launched first, mutation phase serialised behind it

Launched 21:17:30 `setsid`-detached, `direnv exec <this repo>`, log
`~/.cache/aztec-m28rev-sweep.log`. **No mutation runs while it is up**; §3 onward waits for it.

## 2. What the reading found before anything was run

Recorded here as it was found, so the mutation phase has a list to falsify rather than a hunch.

### F1 — `m28_pack` calls `die` inside `$(…)`. The family M28's own log says it FIXED, two
### functions below the fix, in the same file.

`lib_m28_gate.sh:103` carries a paragraph explaining why `m28_scan` returns non-zero rather than
calling `die`: "every caller uses it as `X="$(m28_scan …)"`, and `CAMPAIGN-BRIEF.md` lists 'a `die`
in `$(…)`' among the ways a check dies before its summary". Arms S and S2 measured it (23 red
assertions over an empty report instead of one refusal) and every one of the seven `m28_scan` call
sites now carries `|| die`.

`m28_pack`, sixty lines lower in the same file, has **two `die`s** (`npm pack failed`, `produced no
tarball`) and calls `m28_bounded`, which `die`s on an overrun — and BOTH its call sites are
`t="$(m28_pack "$REPO_ROOT/$p")"` (`verify_npm_pack_no_optional_native.sh:111`) and
`CTRL_TGZ="$(m28_pack "$CTRL")"` (`:220`). `die` is `exit 1` (`lib.sh:151`), which leaves the
command substitution's subshell.

Predicted consequence, worse than a cascade: `pack_binaries ""` runs `tar -xzf "" -C dir`, which
fails, leaving `$M28_WORK/extract` **empty** — so `assert_eq "the packed $p contains no prebuilt
binary, by extension or by decoding" "" ""` **passes**, three times, over nothing. The only guard is
one `assert_ge … 5` on `find "$M28_WORK/extract"` AFTER the loop, and it measures only the LAST
package's extraction. Driven in §3 as arm RPACK.

### F2 — `BROWSER-GATE.md` §5 carries TWO figures on one line and only one is re-derived.

The document's own first sentence promises every figure "is looked for **on the line that names its
subject** — not anywhere in the file", citing M24's review's OQ-6 defect (two table rows swapped,
every figure present, 91 assertions 0 failures). M28's impl log §4.6 records converting §3 to one
figure per line for exactly that reason.

**§5 was not converted.** Line 112 is

```
dependency closure of the shipped package is **268** packages, of which **3** declare
```

`doc_figure "dependency closure of the shipped package is" "268"` asks only that `268` appear on
that line. Swap the two and the document says the closure is 3 packages of which 268 declare
optional native dependencies — the reverse of D22 — and `268` is still on the line. The `3` is
re-derived by nothing: `ci_browser_gate.sh` computes `len(seen)` only. Driven in §3 as arm RDOC.

### F3 — `verify_named_checks_exist` cannot see the `smoke_` naming convention at all.

Its header states the rule as "every `verify_*` / `test_*` / `e2e_*` identifier mentioned anywhere
in this repository's own sources must RESOLVE", and `NAME = re.compile(r"\b((?:verify|test|e2e)_…")`
matches it. There are **three** `smoke_*` checks (`smoke_browser_token_transfer`,
`smoke_browser_produces_block_on_real_timer`, `smoke_browser_headless_full_flow`) and they are cited
in `browser/src/entry_testing.ts` and `browser/src/wasi.ts` — shipped sources naming a check to tell
the reader a property is pinned, which is the exact claim this file exists to hold to account.
Measured over the scanned roots (with `dist` and `node_modules` excluded as the check excludes
them): three names, three files outside `verification/`, and **not one of them is in scope**.
`ci_browser_gate.sh` §7 uses `(verify|test|e2e|smoke)_`, so M28's own document check sees a wider
class than the repository-wide rule does. This is "an absence claim is only as wide as the spellings
you enumerated", in the instrument.

### F4 — §5's "discrimination" probe does not contain the thing it is supposed to discriminate.

`verification/m28/skip_probe_clean.txt` exists so that `exit_zero_sites` and `skip_statements` can be
shown not to report "a file whose only mentions are in a comment". Its comment says it *"mentions a
skip statement and a zero exit"* — in those words. It contains neither the token `exit 0` nor the
token `SKIP`, so both predicates answer 0 for the trivial reason.

Mitigating, and measured rather than assumed: the SUBJECTS do exercise the distinction.
`ci_browser_gate.sh` itself contains five `exit 0` and two `SKIP` occurrences (all in comments and
descriptions) and `smoke_browser_headless_full_flow.sh` one, and the main assertion reports zero over
all seven gate checks. So the property is demonstrated; it is the control that is vacuous.

### F5 — the standing brief names the wrong sixth published branch.

`CAMPAIGN-BRIEF.md`'s outstanding list says "**six** branches published — five `pr/*` plus the
downstream `aztec-avm-runtime` — which is what `verify_pr_branches_match_patches` asserts by name
from `series.json`". The check reads `fork.downstream_branch`, which is **`codetracer`**;
`aztec-avm-runtime` is `fork.downstream_base_branch` and is not one of the six it compares.
`git ls-remote` confirms both exist on the fork, so the count is right and the name is wrong.
Inherited prose, republished by M28 in the milestone's closing list.

### F6 — M11's SECTION STATES THREE THINGS M28 ITSELF MEASURED TO BE FALSE, AND ITS CARRY CHECK IS
### FILED AS `status: passing` WHILE THE FINAL SWEEP MEASURES IT RED.

M28 restored `carry/` and `CARRY-LEDGER.md` to HEAD — verified clean: `git status --short carry/
CARRY-LEDGER.md` is empty, `git diff HEAD -- carry/ CARRY-LEDGER.md` is empty, and the last commit
touching them is `892c4e2 carry: re-acknowledge upstream/next at 9df414ec0e`. **That call was
right** and §6 argues why. What was not restored is the PROSE.

`codetracer-specs`' M11 section, present tense, three sites:

| line | what it says | measured now |
|---|---|---|
| 3601 | *"UPSTREAM HAS MOVED FIVE TIMES NOW, AND THE CURRENT MEASUREMENT IS THE FIFTH"* | seven |
| 3603 | *"the current tip is `9df414ec0e`, **fourteen** commits past the base"* | `703d896149`, **seventeen** |
| 3616 | *"upstream changed **ZERO** paths under `barretenberg/cpp/` at the new tip too, so the conjunct that cannot be waived still holds and **no rebuild is owed**"* | **five** paths; the conjunct does NOT hold; whether a rebuild is owed is the open decision |
| 3618 | *"5 applies, 0 conflicts onto `9df414ec0e`"* | true of the pinned data; the replay at `703d896149` is also 5/5, but this sentence reads as current |
| 3262 | the verification description: *"Against `9df414ec0e`, fourteen commits past the base — upstream's **fifth** move"*, *"upstream changed **79 paths**"* | seventeen commits, **10,925** paths |
| 3263 | `status: passing` on `verify_carry_set_applies_to_upstream_head` | red, eight failing assertions, in M28's sweep and in mine |

Measured independently in the sibling checkout rather than taken from M28's log:
`git rev-parse upstream/next` = `703d896149`; `git rev-list --count 233d8e0993..upstream/next` = 17;
`git diff --name-only 233d8e0993..upstream/next -- barretenberg/cpp` = exactly the five paths M28
names; `git diff --name-only 233d8e0993..upstream/next | wc -l` = 10,925. Upstream has **not** moved
an eighth time while this review ran.

This is the fifth move's defect repeating at the seventh: `CAMPAIGN-BRIEF.md` records that the fifth
move *"repaired all three data files and left FOUR sites naming `142dfcf4b2` as current — this
bullet, two in `codetracer-specs`' M11 section, and one in a verification description"*. M28 updated
the bullet and left the same three site classes. The last one is the one that matters: an
unrepaired check filed as `passing` is the campaign's closing artefact stating that a check passes
which its own final sweep measured red.

## 2b. Eleven figures of `BROWSER-GATE.md`, re-derived by me from the artefacts rather than by
## re-running the check that claims to re-derive them

| figure | document | independently measured |
|---|---|---|
| browser inputs | 1061 | 1061 |
| node inputs | 967 | 967 |
| browser builtins left external | 0 | 0 |
| node builtins left external | 22 | 22 |
| browser `msgpackr-extract` | 0 | 0 |
| node `msgpackr-extract` | 1 | 1 |
| directory roots | 6 | 6 (`browser` 15, `browser-probe` 3, `ct-host` 5, `node-host` 5, `orchestration/node_modules` 997, `orchestration/src` 36 — summing to 1061) |
| `util` import edges | 43 | 43 |
| shipped packages | 3 | 3 tracked `package.json` under the three roots |
| declared closure | 268 | 268 |
| manifests in the closure declaring `optionalDependencies` | 3 | 3, and they are `@crate-crypto/node-eth-kzg`, `msgpackr`, `msgpackr-extract` |

`DRIFT.md` D22's own "3 of the 427 manifests installed under `orchestration/node_modules`" also
holds exactly: `find orchestration/node_modules -name package.json | wc -l` is 427 and precisely
three of those 427 declare `optionalDependencies`. Every figure in both documents is true. F2 is
about whether anything would NOTICE if one stopped being true.

### F7 — the bundle's staleness predicate does not watch three of the input classes the bundle is
### built from, and one of them is the polyfill set the whole carve-out rests on.

`m27_bundle_newer_inputs` (`lib_m27_browser.sh:196`) compares `browser/dist/meta.json`'s mtime
against `browser/src`, `browser/demo`, `orchestration/src`, `ct-host/src`, `browser/build.mjs` and
`browser/chunk-budgets.json`. The shipped browser graph's own metafile lists, among its 1,061
inputs:

```
browser-probe/shims/util.js   browser-probe/shims/tty.js   browser-probe/shims/assert.js
node-host/src/{gate,memory,errors,msgpack,reactor}.ts
```

**None of those eight is under a watched root**, and neither is `browser/esbuild-driver.mjs` — the
file that sets `platform`, `alias` and `external`, which are the exact three things
`verify_browser_bundle_no_node_builtins` measures. Three of the four declared polyfills are in that
unwatched set, and "every builtin resolves to a declared shim" is the carve-out the whole gate turns
on.

M28's own mutation harness had to pass `M27_BUNDLE_REFRESH=1` for M1, M1b, M2, M3, M7 and M7b —
which is the workaround for exactly this, applied without the underlying gap being named. The
recorded outstanding item says the predicate is *mtime-based*; it is also *incomplete*, and the
second is the one that bites without anyone doing anything unusual. Driven in §3 as arm RSTALE:
gut `browser-probe/shims/util.js` and run the check with no refresh flag.

### F8 — the milestone says ELEVEN figures are re-derived; there are TWELVE.

`ci_browser_gate.sh` makes exactly **12** `doc_figure` calls, and `BROWSER-GATE.md` §6's own
enumeration adds up to 12 as well (2 recipe sizes + 6 bundle figures + 1 root count + 2 package
figures + 1 `util` edge count). M28's Verification entry for `just ci-browser-gate` says *"eleven
figures of `BROWSER-GATE.md` are taken from the artefact"*. The document is right and the milestone
under-states by one. Nothing re-derives that number, which is why it could drift — the same family
one level out from what §6 exists to prevent.

### F9 — the write-up's own §2 table names the seven checks and nothing re-derives the composition.

Only the SIZE (7) and the EXISTENCE of every name the document contains are checked. Swapping one
row for a different check that exists satisfies both. Driven in §3 as arm RTABLE; the workflow, by
contrast, names no check at all (measured: `grep -rl` over the three files puts every M28 check name
in `Justfile` and `BROWSER-GATE.md` only), which is what arm M12 pins.

### F6b — the impl's sweep measured the SIXTH move, not the seventh, and the two are
### indistinguishable at the assertion level.

Read out of `~/.cache/aztec-m28-sweep.log` rather than from the impl log's summary: M11's four
carry-check failures there are `the exposure measurement was taken against the tip the replay used
expected [9d9523b9735a…] got [9df414ec0e81…]`, a `bootstrap.sh` declared-region mismatch, the
conjunct printing `expected [transfers], got [void]`, and exit status 2 — plus
`verify_carry_ledger_complete` 17/2 and `verify_carry_exposure_measured` 22/2. 4 + 2 + 2 = the eight
claimed, and 43+15+52+17+15+22+95 = 259 with the count unchanged. Both hold.

But the run's own JSON says `"verdict": "void"` with the rejection being the *expired
acknowledgement*, i.e. the SIXTH move — the sweep ran between the two, exactly as M28 says.
`_carry_overlap.py`'s verdict is `void` for either cause, so the assertion text cannot tell them
apart; what distinguishes them is the `upstream_paths_in_build_tree` field, and it was empty there.
My sweep runs M11 at `703d896149`, so it should be the first run of the campaign to carry the
seventh move's actual signature.

**And reading the procedure sharpens the narrowing question.** Conjunct 1 is applied to
`inp["upstream_paths"]` — *all* 10,925 paths upstream changed — not to the intersection: *"a change
under the build root voids the evidence whether or not the carry set happens to touch the same
file"*. So the predicate that is now red is "upstream has touched **any** path whose name starts
`barretenberg/cpp/`", and the five that trip it are one provisioning script, one markdown document
and three benchmark shell scripts. Measured here: **none of the five is read by any of this
repository's build machinery** — `grep` over `lib_avm_wasm.sh`, `lib_m10_cmake_split.sh` and the
verification tree finds no invocation of `barretenberg/cpp/bootstrap.sh`, `chonk_inputs.sh`,
`ci_benchmark_ultrahonk_circuits.sh` or `pinned_chonk_inputs.sh`; the one place
`barretenberg/cpp/bootstrap.sh` is read at all is
`verify_merkle_lmdb_issue_md_complete.sh:172`, and it reads it out of `$M3_WORK/base/`, the pristine
BASE tree, which upstream cannot move.

### F10 — UPSTREAM MOVED AN EIGHTH TIME, DURING THIS SWEEP, AND M11 IS 259 WITH **TEN** FAILING
### ASSERTIONS RATHER THAN EIGHT.

`git reflog show upstream/next`: `703d896149` at 2026-08-27 20:59:55 → **`7df97dce1b`** at
**2026-08-27 22:29:07**, which is the minute my sweep started m11. Eighteen commits past the base,
10,933 changed paths, still exactly the same five under `barretenberg/cpp`. Four moves in
twenty-six hours; three of them inside two hours. `CAMPAIGN-BRIEF.md`'s chain, updated by M28 today
to "SEVEN times now", is already one short — and that is the fourth time the chain has gone stale,
which is what the "one place states it" remedy was supposed to stop and cannot, because the number
is a fact about a moving target rather than about this repository.

m11: **259 assertions, 10 failures, rc=1**, split 43/15/52/17/15/22/95 — the count unchanged, which
is the recorded signature. Against M28's eight, the two extra are:

1. `FAIL upstream changed no path under barretenberg/cpp, the tree M6 and M10 compile expected [0],
   got [5]`. **The seventh move's real signature, measured inside a sweep for the first time.**
   M28's sweep could not have seen it (F6b).
2. `FAIL a commit that IS in upstream HEAD is detected as already applied (chore!: build and test
   the labs components from the submodul) expected [yes], got [no]` — in
   `verify_accepted_patches_dropped_from_carry`, which went 15/0 in M28's sweep and is 15/1 in mine.

### F11 — AND THE SECOND OF THOSE IS A DEFECT IN A POSITIVE CONTROL: IT REDDENS FOR A REASON THAT
### HAS NOTHING TO DO WITH WHAT IT CONTROLS.

`verify_accepted_patches_dropped_from_carry.sh:70` takes upstream's three most recent commits
(`git rev-list -n 3 "$tip"`) and asserts the `already_applied` detector — imported from
`tools/rebase_upstream_patches.py` rather than reimplemented, which is right — reports `yes` for
each. The premise is *"a commit in HEAD's history has its changes in HEAD's tree"*.

Upstream falsified that premise in **thirty-one minutes**: `38fd5fc6e9` *chore!: build and test the
labs components from the submodule* is the third of the three, and `703d896149` *chore!: delete the
in-tree labs components* — the very next commit — undoes it. The detector is **correct** to answer
`no`; a content-based test of "is this patch already in the tree" must say no about a change that
has been reverted. It is the CONTROL that is wrong.

This is the mirror image of the family this campaign hunts. The recorded rule is *"when a mutation
reddens, read WHICH assertions went red — 'the check failed' and 'the check saw what I broke' are
different statements"*. Here a control fails while the thing it controls is working, which reads to
the next person as a finding about the detector. The premise has to be checked before it is
asserted on: select control commits whose effect SURVIVES to HEAD, and assert that at least one was
found so the selection cannot silently empty itself.

## 3. The mutation phase — plan, written before it runs

`scratchpad/campaign/m28-review-mutations.sh`, serialised behind the sweep. Twelve arms:

| arm | what it drives | expected |
|---|---|---|
| RDOC | F2: §5's two figures swapped | **PASS** would confirm the finding |
| RPACK | F1: `M28_PACK_TIMEOUT=1` makes `m28_pack` `die` inside `$(…)` | vacuous passes on the binary-member absences |
| RSTALE | F7: the `util` shim gutted, no refresh flag | **PASS** over a stale bundle would confirm |
| RWALK | the positive control the brief asks for by name: the walker resolves nothing | §5 must redden |
| M6b | binary bytes named `lookup.json` | `not-utf8 package/src/lookup.json`, decode arm only |
| M4 | the package derivation weakened to a substring | 3 failures |
| M11 | one document figure rotted by one | 1 failure, that figure |
| M12 | the CI job runs check scripts directly | 1 failure |
| M1 | `external: ['util']` alone — DECLARED not coverage | must still be 64/0 |
| M1b | the shim removed AND `util` external | 4 failures, graph and bytes |
| M7 | the planted import at the real budgets — DECLARED not coverage | the BUILD refuses first |
| M7b | the same import, budgets raised | 6 failures, a seventh root |
| M8 | the page's digest over one byte more | 1 failure, the join only |

## 4. The mutation phase — what was measured

Serialised behind the sweep, `setsid`-detached, in this repository's own dev shell. Logs:
`~/.cache/m28rev-mutations{,2,3,4}.log`, `~/.cache/m28rev-rpack2.log`, `~/.cache/m28rev-cold.log`,
`~/.cache/m28rev-nixgate.log`.

### 4.1 The five findings, driven

| arm | result | verdict |
|---|---|---|
| RDOC — §5's two figures swapped | `just ci-browser-gate: 101 assertions, 0 failures, PASS` | **F2 confirmed** |
| RPACK — the pack bound made unreachable (`M28_PACK_TIMEOUT=0.01`) | `52 assertions, 26 failures`, and the three "contains no prebuilt binary" assertions PASS `ok []` over an empty extraction | **F1 confirmed, worse than predicted** |
| RSTALE — the `util` shim gutted, no refresh flag | no rebuild at all; `64 assertions, 0 failures, PASS` | **F7 confirmed** |
| RTABLE — §2's table row renamed to another existing check | `101 assertions, 0 failures, PASS` | **F9 confirmed** |
| RWALK — the walker resolves nothing | `37 assertions, 5 failures` naming the walk's size and all three DD-9 packages | **the positive control WORKS; the claim survives** |

`M28_PACK_TIMEOUT=1` was not enough — `npm pack` finishes inside a second — so the first RPACK run
came back green and proved nothing. Recorded because an arm that does not reach its subject is not
evidence, which is this campaign's own rule about mutations that crash.

### 4.2 The six gates, reproduced

| arm | recorded | measured here |
|---|---|---|
| M6b — binary bytes named `lookup.json` | 52/1, `not-utf8 package/src/lookup.json` | **same**, and `.json` is not in `BINARY_EXT`, so the decode arm is the only thing that can see it |
| M3 — a `cpp_*` file reached | 44/1 | **same** |
| M4 — the derivation weakened to a substring | 44/**3** | **44/2** — see 4.3 |
| M11 — one document figure rotted by one | 101/1 | **same**, exactly that figure |
| M12 — the job runs check scripts directly | 101/1 | **same** |
| M1 — `external: ['util']` alone, DECLARED not coverage | 64/0 PASS | **same** — the honest declaration holds |
| M1b — the shim removed AND `util` external | 60/4 | **same**: the shim table, `util` external in the graph (43 edges), `util` in the emitted bytes (37 in one chunk), the shimmed-set size |
| M7 — the planted import at the real budgets, DECLARED not coverage | build refuses, 0/1 | **same** — the honest declaration holds |
| M7b — the same import, budgets raised | 37/6 | **same**: a seventh root `diffsim`, 419 forbidden-root inputs, `differential/` = 1, the source-level import |
| M8 — the page's digest over one byte more | 50/1 | **same**, and every stage passes: `processed`, block 1, exactly one `.ct` downloaded, `ct-print --full` exit 0. **Only the join breaks**, which is what the entry claims to add over M27's four |

### 4.3 M4's recorded THREE failures is TWO, and the third was M3's bundle

M28 records `M4 → 3 failures`, the third being `the browser bundle's inputs contain no cpp-file`.
M4 weakens only the FORBIDDEN-**PACKAGE** loop; it cannot produce a FORBIDDEN-**PATH** failure. Over
a clean bundle it is **2**. The third came from arm **M3**, which runs immediately before it, plants
`browser/src/cpp_probe.ts`, rebuilds — and is then restored with `cp -p`, which preserves the mtime,
so `m27_bundle_newer_inputs` did not rebuild for M4.

That is the contamination M28 found, named and repaired **for arms M9–M12 only**. M4 is a sixth arm
and was never re-run. It is also the reason this review re-ran every arm it quotes rather than
citing M28's logs.

### 4.4 Finding #1, reproduced in all three directions

- **Cold start**: `~/.cache/aztec-m28rev-cold` removed with `rm -rf`; 20 + 37 + 14 + 34 =
  **105 assertions, zero failures**, four rc=0. `grep -c "running the browser arms"` = **1** — one
  browser for four checks. `grep -c "mv: cannot stat"` = **0**. The work dir holds `browser.json`
  and `browser-last.json` at 4,095,789 bytes each and **no `browser-failed.json` at all**.
- **M0** (the guard removed): `cannot run: the browser arm run succeeded but its report could not be
  installed`, **0 assertions, 1 failure** — M27's review's finding exactly.
- **E** (an arm throws): `browser-failed.json` **present**, `browser.json` **absent**, and the
  refusal reads `arms.error.message` back out of the report.

### 4.5 The CI provisioning line, executed

`nix shell nixpkgs#chromium`, both work directories removed first:
`M27_CHROMIUM=/nix/store/b3zmxxdfbv1q13fy1vkgxaszmnkwkf0z-chromium-151.0.7922.137/bin/chromium`,
`Chromium 151.0.7922.137`, and **101 + 64 + 44 + 52 + 37 + 40 + 50 = 388 assertions, 7 of 7,
exit 0** (pre-fix figures). The job itself has still never run, which `BROWSER-GATE.md` §8 states in
its own first bullet — `str_has_sub "$DOC" "never run in CI"` is asserted, so the statement cannot
quietly disappear.

## 5. The fixes, and the count in both directions

| fix | check | assertions |
|---|---|---|
| F1 `m28_pack` returns non-zero; non-emptiness inside the loop | `verify_npm_pack_no_optional_native` | 52 → **54** (+3 per-package, −1 post-loop) |
| F2 §5's two figures split, both re-derived from one walk | `just ci-browser-gate` | +1 |
| F9 §2's composition compared as a set, with a non-emptiness read | `just ci-browser-gate` | +2 |
| F7 the staleness predicate watches its own inputs | `lib_m27_browser.sh` | 0 |
| F3 `smoke_` added to the named-checks rule | `verify_named_checks_exist` | 0 |
| F4 the probe carries the tokens it discriminates | fixture | 0 |

`just ci-browser-gate` 101 → **104**; `verify_npm_pack_no_optional_native` 52 → **54**; 3 + 2 = 5,
and **348 + 5 = 353**. Re-measured after the last commit: M28 353 (6/6), and the three milestones
the fixes could otherwise have moved are unchanged — **M0 156, M1 175, M20 237, M27 343**. The blast
radius was measured rather than assumed: no check OPENS `CAMPAIGN-BRIEF.md` (every mention is a
comment citation), `lib_m27_browser.sh` is sourced only by M27's and M28's checks, and
`verify_named_checks_exist` runs in M20.

Each fix carries its own mutation control, run after the fix: the swapped §5 gives 2 failures, the
swapped table row gives 1, the gutted shim now rebuilds and the build fails, the unreachable pack
bound gives one refusal at 11/1, and the renamed `smoke_` check gives 9/1 where it gave 9/0 before.
