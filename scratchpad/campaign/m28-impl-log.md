# M28 impl log — Browser CI Gate: No Node.js Dependencies

Implementation agent. Written as I go, per `CAMPAIGN-BRIEF.md`.

**This log is in the REPO scratchpad** (`aztec-avm-runtime/scratchpad/campaign/`), where every review
log already lives, and NOT in the session scratchpad. M27's review looked for M27's impl log here,
did not find it (it is in the session scratchpad), and reported it as never written — an agent was
wrongly impugned and a fourteen-arm mutation matrix was rebuilt for nothing. Both directories are
checked before anything is declared missing.

## 0. Starting state, measured

- `aztec-avm-runtime` on `dev` at `da586b7` (= `origin/dev`), **working tree clean**. M27 and its
  review are committed and pushed.
- `codetracer-specs`: M28 section at line 10927, `status: planned`, six verification entries all
  `pending`. Twenty-nine top-level headings; the duplicated M25/M26 pair M27's review resolved is
  gone (`grep -c '^\*\* M2[56]'` = 1 each), so that outstanding item is closed and is not mine.
- `~/.cache/aztec-m27-browser` is **warm**: the thirteen-overlay module at 1,621,354 bytes,
  `browser.json` 4,095,595 bytes written 18:22, `site/`, `downloads/`.
- `browser/dist` built at 18:21: `browser.js`, `testing.js`, `demo.js`, `index.html`, 15 chunks,
  `meta.json` (1,061 inputs / 19 outputs), `node/node.js` + `node/meta.json`, `chunks.json`,
  `substitution.json`, `.build-config.json`.

### M27's review finding #1 is ALREADY FIXED IN THE TREE — verified before assuming otherwise

My brief names this as my first task: "M27's shared arm run was filed as a failure and never
installed … Fix it, and make the fix demonstrable." The brief was written against the state M27's
review *found*, not the state it *left*. `verification/lib_m27_browser.sh:280` now reads

```sh
    if [ "$rc" -ne 0 ] && [ -s "$M27_ARMS.tmp" ]; then
      mv "$M27_ARMS.tmp" "$M27_WORK/browser-failed.json"
    fi
```

— guarded on `rc`, with the install on the success path a named `die` rather than a silent `mv`,
and the staleness predicate re-asked after the refresh. Committed as `9e56c3b`, described in
`m27-review-log.md` §1.

So the work left to me is not the fix but its **demonstration**: a cold work directory must run
every check. That is measured in §1 below rather than taken from the commit message.

## 1. The cold work directory now runs EVERY check — measured

`~/.cache/aztec-m28-cold`, removed first (`rm -rf`), `AVM_WASM_PATH` pointed at the warm module so
the eight-gigabyte overlay build is not repeated; `setsid`-detached, `direnv exec <this repo>`, all
four behavioural M27 checks in order. Log: `~/.cache/m28-cold.log`.

```
verify_public_only_page_never_fetches_barretenberg  20 assertion(s), 0 failure(s)   rc=0
smoke_browser_token_transfer                        37 assertion(s), 0 failure(s)   rc=0
smoke_browser_produces_block_on_real_timer          14 assertion(s), 0 failure(s)   rc=0
e2e_browser_downloads_ct_container_and_ct_print_parses 34 assertion(s), 0 failure(s) rc=0
```

**105 assertions from a cold work directory, zero failures**, against the review's finding of
`0 assertions, 1 failure` on the first of them. Three corroborating facts, each measured rather
than argued:

- `grep -c "running the browser arms"` = **1**. One browser for four checks, not four.
- `grep -c "mv: cannot stat"` = **0**.
- `~/.cache/aztec-m28-cold/` holds `browser.json` (4,095,586 bytes) and `browser-last.json` at the
  same size and **no `browser-failed.json` at all** — the success path installed the report and the
  failure path was not taken.

The reverse direction (that the pre-fix code really would have failed here) is arm **M0** of the
mutation matrix, run in the serialised mutation phase rather than beside a sweep.

## 2. What the artefacts already say, measured before any check was written

These are the facts the six gates are built on. Every one is re-derived by a check below.

| question | browser bundle | node bundle |
|---|---|---|
| inputs in the metafile | 1,061 | 967 |
| distinct `external` import targets | **2** | **29** |
| externals that are Node builtins | **0** | **24** (`util` 38, `fs` 9, `stream` 7, `path` 7, `url` 6, `worker_threads` 6, `assert` 5, …) |
| `msgpackr` reached | yes (4 files) | yes (6 files) |
| `msgpackr-extract` reached | **0** | **1** |
| `node-gyp-build-optional-packages` reached | **0** | **2** |
| `@aztec/native` / `cpp_*` / `differential/` | 0 / 0 / 0 | 0 / 0 / 0 |

**The two externals in the browser bundle are both classified, and neither is a shipped edge.**
`browser/src/globals.js` is the `--inject` file, which esbuild records as an external import on
every one of the 1,057 inputs it injects into; `../../node-host/src/reactor.ts` is a TYPE-ONLY
import in `poseidon.ts` and `grumpkin.ts` which the TypeScript loader elides — `grep -rno
"node-host/src/reactor" browser/dist/**/*.js` finds **nothing** in the emitted bytes, only in
`meta.json`. Both are named in the instrument and the residue is printed, so a THIRD external would
be a red line rather than a silent pass.

**`msgpackr-extract` is the control this campaign's own archetype demands.** The recorded defect is
"an absence asked of a tree that excludes the subject by construction" — and it would apply to
`@aztec/native`, which is genuinely not installed under `orchestration/node_modules`. It does NOT
apply to `msgpackr-extract` and `node-gyp-build-optional-packages`: both ARE installed, both ARE
resolvable from the same tree, and the NODE pass of the SAME build reaches both while the browser
pass reaches neither. One instrument, one installed tree, two artefacts, opposite answers.

**And a real finding about the manifest closure, which becomes DRIFT.md D22.** Three of the 427
manifests installed under `orchestration/node_modules` declare `optionalDependencies`, and two of
them are native addons: `msgpackr` -> `msgpackr-extract` (six prebuilt `.node` platforms) and
`@crate-crypto/node-eth-kzg` -> six more. So "the published package declares no optional native
dependency" is true of the package's OWN manifest and false of its transitive closure, and
`verify_npm_pack_no_optional_native` has to say which it means and measure both.

## 3. What was written, reused and vendored

**Reused, not rewritten** — the whole point of putting the gate last:

| reused | from | what it buys |
|---|---|---|
| `tools/browser_cdp.mjs` (331 lines, no npm dependency) | M27 | the headless browser, over CDP on Node 24's global `WebSocket`. No puppeteer, no playwright |
| `tools/run_browser_arms.mjs` + `m27_require_arms` | M27 | ONE browser run shared by every behavioural check, with the staleness re-ask |
| `m27_require_bundle`, `m27_meta`, `m27_arm`, `m27_run` | M27 | the built bundle and its metafiles |
| `verification/build_avm_wasm_m27.sh` | M27 | the thirteen-overlay module |
| `m24_require_readers` / `m24_ct_print` | M24 | the pinned reference reader for the `.ct` container |
| `tools/import_graph.mjs` | M18/M19 | the walker used for BOTH controls — `@aztec/native` reachable from `diffsim`, and `differential/` reachable from verification code |
| `verification/_m27_depscan.py` | M27's review | "no puppeteer, no playwright", asked again of the gate |
| `verify_browser_entry_points_are_dd5_shaped` | M27 | DD-5 itself; the gate RUNS it, M28 does not re-count it |

**Vendored: nothing.** `PROVENANCE.md` is byte-unchanged, so `verify_provenance_complete` stays at 64
and `check-drift` at 22. Measured in the sweep rather than argued.

**Written:**

- `verification/_m28_bundle_scan.py` — one instrument over a BUILT bundle: the metafile's import
  edges (classified into shimmed / external / other, residue printed) and the emitted bytes
  (specifier positions, both quote spellings, with and without `node:`). It has a terminal
  sentinel, because a scanner that dies half way prints a PREFIX of its report and every absence
  read from that prefix reads as a clean bundle.
- `verification/lib_m28_gate.sh` — the work dir, the abnormal-exit trap (the FIFTH copy; declined
  to move it to `lib.sh` for M22's own reason, recorded in the file), a bounded subprocess, the
  scan wrapper and the `npm pack` helpers.
- Five checks + the gate's own check, listed with their counts in §6.
- `BROWSER-GATE.md` — M28's write-up, **opened and re-derived by `ci_browser_gate.sh` §6 on every
  run**, which is F17's lesson applied before rather than after.
- `DRIFT.md` **D22** — the declared closure's three optional native dependencies.
- Justfile: `ci-browser-gate`, `verify-m28`, and six per-check recipes.
- `.github/workflows/avm-wasm.yml`: the `browser-gate` job — the twelfth — invoking
  `just ci-browser-gate` **by recipe name**.
- `verification/m28/skip_probe_{clean,planted}.txt` — the two halves of §5's control.

## 4. Six defects in my own checks, all found on their first run

Recorded because "get there first" is what M26 means by it, and four of the six are shapes this
campaign already has names for.

1. **The scanner counted the control as the subject.** `browser/dist/node/` lives INSIDE
   `browser/dist/`, so the first run of `_m28_bundle_scan.py` walked the node bundle's emitted bytes
   as part of the browser bundle's and reported 24 Node builtins in "the browser bundle". An
   instrument that cannot tell the subject from its control. `--exclude` is a parameter now, not a
   comment.
2. **`find "$REPO_ROOT" -name '*.tgz'`** — for "packing left nothing in the tree" — reported four
   helm charts vendored under `upstream/tsavm/spartan/`, which are gitignored and have nothing to do
   with npm. Asked of `git status --porcelain --untracked-files=all` now, which is the question that
   was meant, WITH a control that copies a tarball into the tree and requires it to be reported.
3. **"every harness tree declares `@aztec/native`" was false.** `probe-mt` declares
   `@aztec/world-state` and not `@aztec/native`. The property that actually separates the harness
   trees from the shipped ones is the DD-9 SET, and the names each declares are printed.
4. **A citation counted as a call, twice, in my own instrument.** The `exit 0` predicate was
   `^[^#]*\bexit 0\b`, and it reported two of the gate's own checks — one because an assertion's
   DESCRIPTION reads "so exit 0 above is a verdict", the other because `ci_browser_gate.sh` names
   the rule it enforces. The same happened to the `continue-on-error` predicate, which reported the
   CI job's own comment saying there is no `continue-on-error`. Both predicates now require command
   position / stripped comments, and **the probe text moved into `verification/m28/` fixtures** so
   the file defining the rule does not have to be exempted from it.
5. **A control that edited the assertion counters.** The first `doc_figure` control asserted
   deliberately-failing cases and then saved and restored `_FAILURES`. It worked — 8 FAIL lines, 6
   counted — and it is exactly the cleverness a reviewer should not have to verify. It is a verdict
   function now (`ok` / `missing` / `wrong:<line>`) that the caller asserts on.
6. **A document row carrying two figures can have them swapped.** `BROWSER-GATE.md` §3 was a table
   with browser and node in one row, so the row-anchored needle found both numbers whichever column
   they were in — M24's review's OQ-6 defect, reproduced by me in the section that cites it. §3 is
   one figure per line now, each with its own subject.

Two more that reddened for a reason worth recording: `avmWasmRequests` is a LIST and I compared it
with `assert_ge`; and the `|| true` census over the CI job reported five artefact `cp`s and two
diagnostic `grep`s. The second is not a defect in the job — it is a predicate that was too wide, and
the fix is a classification whose RESIDUE is asserted rather than a count.

## 5. The mutation matrix

`scratchpad/campaign/m28-mutations.sh`, run `setsid`-detached in this repository's own dev shell,
with **no sweep running** — a mutation harness and a verification sweep are two writers over one
working tree. Every arm restores what it touched and the restoration is checked against a digest of
`git diff` taken at harness start (not `git diff --quiet`: M28 is uncommitted work, so the Justfile,
`DRIFT.md` and the workflow are legitimately modified and `--quiet` would abort on arm one).

Log: `~/.cache/m28-mutations.log`.

### THE HARNESS ITSELF PRODUCED THE CAMPAIGN'S NAMED DEFECT, AND IT IS WORTH MORE THAN THE ARM

**M7's build failed at the chunk budget AFTER esbuild had already written `browser/dist`**, so the
mutated bundle — 1,480 inputs, seven directory roots, 78 `util` edges — stayed on disk. `restore_all`
put `entry_browser.ts` back with `cp -p`, **which preserves the mtime**, so
`m27_bundle_newer_inputs` saw no input newer than `meta.json` and did not rebuild. M9, M10, M11 and
M12 each then reported **four extra failures** naming figures from M7's bundle.

That is `CAMPAIGN-BRIEF.md`'s "**a mutated artefact outlived its restored source**", reproduced by
the harness written by the agent who had read the sentence that morning. Two things follow:

1. **The harness now `touch`es every file it restores**, so the staleness predicate fires.
2. **The staleness predicate is mtime-based and a restore can preserve mtimes.** This is the same
   shape M24 met with `git archive` (which stamps files with the COMMIT's timestamp, so `--force`
   alone did not invalidate a cargo build). It is a property of `m27_bundle_newer_inputs`, not of
   M28, and it is recorded here rather than changed on the way out of the campaign: any restore
   that preserves mtimes — `cp -p`, `git checkout` of an unchanged blob, a `git stash pop` — can
   leave `browser/dist` describing a tree that is no longer there.

The four spurious failures are **declared as not counting toward coverage**; each of M9–M12's own
assertions fired for its own reason, and all four arms were re-run over a clean bundle (§5.3).

### 5.2 The matrix — 19 arms, every one detected

`rc` and the failing assertion names are in `~/.cache/m28-mutations{,2,3}.log`. "Saw it" means the
assertions that went red are the ones the arm was written for.

| arm | what was broken | result | saw it? |
|---|---|---|---|
| **M0** | the `rc` guard removed from the arm install (M27 review #1, reversed) | `cannot run: the browser arm run succeeded but its report could not be installed`; **0 assertions, 1 failure** | yes — and it is the exact failure the review measured |
| **M1** | `external: ['util']` added to the browser pass | **64/0, PASS** — NOT DETECTED, and the reason is the arm's: esbuild applies `alias` BEFORE externalisation, so the shim still won and nothing changed. Declared as **not coverage** | no |
| **M1b** | the `util` SHIM removed *and* `util` left external | **60 assertions, 4 failures**: the shim table, `util` external in the GRAPH (43 edges), `util` in the EMITTED BYTES (37 in one chunk), and the shimmed-set size | yes, both arms |
| **M2** | a polyfill DECLARED that nothing imports (`path` added to the shim table) | 66/2: the declared set and the set-equality, in both directions | yes |
| **M3** | a `cpp_*` file reached by the browser entry | 44/1: `inputs contain no cpp-file` | yes |
| **M4** | the scanner's package derivation weakened to a SUBSTRING | 44/3: `@aztec/native`, `@aztec/world-state` and `cpp-file` all light up — the boundary-vs-substring distinction is load-bearing | yes |
| **M5** | a shipped package declares `optionalDependencies: @aztec/native` | 52/2: the packed manifest and the native-name census | yes |
| **M6a** | `ct-host/src/prebuilt.node` (real ELF bytes) | 52/1: `extension package/src/prebuilt.node` | yes |
| **M6b** | the same bytes named `lookup.json` | 52/1: `not-utf8 package/src/lookup.json` — **only the decode arm can catch this**, which is why the decode arm exists | yes |
| **M7** | the planted `differential/` import | **reddened for the WRONG reason**: the eager set went past its budget and the BUILD refused first (`0 assertions, 1 failure`). Right behaviour, **not coverage** | no |
| **M7b** | the same import, budgets raised out of the way (M27's review's F-RIGHT pattern) | **37 assertions, 6 failures**: a SEVENTH directory root named `diffsim`, 419 inputs under a forbidden root, `differential/` = 1, and the source-level import | yes — this is the entry's positive control |
| **M8** | the page's reported digest taken over one byte more than it held | 50/1: `the same digest, re-hashed here rather than read from the report`. Every stage still passed; only the JOIN broke — which is what this check adds over M27's four | yes |
| **M9** | a check dropped from the gate recipe | 98/4: the size, the ordered list, the gate-vs-`verify-m28` difference, and the doc figure that states the size | yes |
| **M10** | `continue-on-error: true` on the CI gate step | 101/2, both escape-hatch assertions | yes |
| **M11** | one figure in `BROWSER-GATE.md` rotted by one | 101/1, exactly that figure | yes |
| **M12** | the CI job runs the checks itself instead of the recipe | 101/1: `the job runs no check script directly` | yes |
| **H1** | the browser arms never settle | `did not finish within 45s and was killed`; **0 assertions, 1 failure** | yes |
| **H2** | the timeout branch driven directly (`M27_ARMS_TIMEOUT=3`) | same branch, same shape at 3s | yes, but see below |
| **E** | an arm THROWS | `the browser arm run failed (exit 1): deliberate M28 arm failure`, read back out of the report; `browser-failed.json` **present**, `browser.json` **absent** | yes |
| **D** | `kill -TERM $$` mid-check | **12 assertion(s), 1 failure(s)**, `FAIL — exited before finish` — a RED gate of twelve rather than a silent zero | yes |
| **S** | the scanner dies non-zero mid-report | `cannot run: the browser bundle scan could not be read`; 5/1 | yes |
| **S2** | the scanner exits **0** with a report that never reaches its sentinel | same refusal; 5/1. **This is the arm the sentinel exists for** — S is caught by the exit status, S2 by nothing else | yes |

**Two arms that are not coverage, declared as such** (M27's honesty, kept): **M1** changed nothing
and **M7** was caught by an earlier gate. Both were replaced by arms that do reach the assertions
(M1b, M7b), and both replacements fired.

**H1 and H2 took the SAME branch**, and that is worth stating rather than counting twice: both
exceeded the bound and were killed (`rc` 137). M27's review found its own hang arm surfacing
*instead* as `Promise was collected` — a fast non-zero exit — so the arm-error branch is a different
path, and **E** is the arm that exercises it.

### 5.3 A defect in my own library, found by arm S

The first draft of `m28_scan` called `die` on a bad report. Every caller uses it as
`X="$(m28_scan …)"`, so `die`'s `exit` left the **subshell**: the assignment got an empty string and
the check carried on, producing **23 red assertions over an empty report** instead of one refusal
naming the truncation. `CAMPAIGN-BRIEF.md` lists "a `die` in `$(…)`" by name. It returns non-zero
now and every call site carries `|| die`; re-run, S and S2 both give `5 assertions, 1 failure` and a
refusal that names the scan. **It reddened either way — this was the misattributing shape, not the
silent one** — which is the same distinction `m9_completeness` exists to make one milestone over.

## 6. Per-check counts, and the gate under the CI's own chromium

`just ci-browser-gate`, this repository's dev shell, `setsid`-detached, nothing else running:

```
just ci-browser-gate                                101
verify_browser_bundle_no_node_builtins               64
verify_browser_bundle_no_native_deps                 44
verify_npm_pack_no_optional_native                   52
verify_verification_code_unreachable_from_browser    37
verify_browser_entry_points_are_dd5_shaped           40   (M27's — counted in M27, not in M28)
smoke_browser_headless_full_flow                     50
                                     THE GATE      388, 7 of 7, exit 0
                                     M28           348, 6 of 6, exit 0
```

**M27's DD-5 check reproduced at 40 exactly**, which is its post-review value, so running it from the
gate moves nothing.

### THE CI PROVISIONING LINE IS DEMONSTRATED, NOT ASSERTED

The workflow gets chromium from nixpkgs rather than from the runner image, because
`lib_m27_browser.sh` takes chromium from PATH and a runner image may have no browser at all. That
line was run here, with **both work directories removed first**:

```
nix shell nixpkgs#chromium --command bash -c 'export M27_CHROMIUM="$(command -v chromium)"; just ci-browser-gate'

M27_CHROMIUM=/nix/store/b3zmxxdfbv1q13fy1vkgxaszmnkwkf0z-chromium-151.0.7922.137/bin/chromium
Chromium 151.0.7922.137
… 388 assertions, 7 of 7, exit 0
```

A **different browser from the one the rest of this work used** (the ambient Arch chromium is
150.0.7871.128) and a **cold `M27_WORK` and `M28_WORK`**, and the gate is green. So the step the CI
job would run is executable and the arms do not depend on the host's browser. What has NOT executed
is the job: no job in `avm-wasm.yml` has ever reached a check, for the token reason.

## 7. Small findings recorded rather than fixed on the way out

- **`m27-sweep-sum.py`'s reference table says `"m27": 339`.** The sweep it summarised measured
  **343** and both `m27-review-log.md` §13 and the milestone say 343. The review updated its log and
  the milestone and not its own summariser's table — the "prose drifts from measurement" family, in
  a scratchpad tool rather than in a check, so nothing goes red for it. `m28-sweep-sum.py` carries
  `"m27": 343, "m28": 348`; M27's copy is left as the historical artefact it is.
- **`verify_named_checks_exist` still does not scan the repository-root `.md` files**, which M27's
  review recorded as a standing gap. `BROWSER-GATE.md` closes it for itself — `ci_browser_gate.sh`
  §7 resolves every `verify_*`/`test_*`/`e2e_*`/`smoke_*` name the document contains and carries the
  one declared exception (`test_trace_step_count_matches_instruction_count`, M25's pending entry,
  cited in the paragraph that says it does not exist) with an assertion that the exception is not
  dead. The general gap stands.
- **The abnormal-exit trap is now in FIVE milestone libraries** and M9's four checks — the
  retrospective case — still do not have it. Declined for M22's own reason and the count is recorded
  in `lib_m28_gate.sh` itself.
- **`browser/dist`'s staleness predicate is mtime-based** (see §5.1). Recorded, not changed.

## 8. The M0–M28 sweep — 10,043 across 29 milestones, 28 of 29 exit 0

`setsid`-detached, `direnv exec <this repo>`, one milestone at a time, nothing else running,
`TMPDIR` and the log under `~/.cache`, **no hole in the log**, 19:15 → 21:00.

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 324  m22 260  m23 509  m24 350  m25 272  m26 313  m27 343
m28 348
                                                       CAMPAIGN TOTAL 10,043
```

**Both directions.** 9,695 + 348 = 10,043 exactly, and the summariser's own reference table (which
carries 9,695's per-milestone values plus M28's declared 348) reports `delta +0`. **Every one of
M0–M27 came out at its reference value TO THE ASSERTION**, including **M9 at 807 in 1,320 s with no
flake and no truncation** — immediately after M8's build, which is D19's standing hypothesis, and it
did not fire — M4 at 218 in the dev shell (M19's review's PATH pin holds), M24 at 350, M25 at 272,
M26 at 313 and M27 at 343.

**M28's 348 is the sum of its own six checks and nothing else**: 101 + 64 + 44 + 52 + 37 + 50. The
gate is 388 because it also runs M27's `verify_browser_entry_points_are_dd5_shaped`, which came out
at **40**, its post-review value, inside M27 where it is counted.

### THE ONE NON-ZERO EXIT IS M11's, AND IT IS THE SIXTH UPSTREAM MOVE — THEN THE SEVENTH

**m11 259, rc=1, EIGHT failing assertions, and the assertion COUNT is unchanged**, which is the
recorded signature of an upstream move rather than a regression. Measured in the sibling checkout's
reflog rather than inferred:

```
703d896149  fetch upstream next: fast-forward   2026-08-27 20:59:55 +0300
9d9523b973  fetch upstream next: fast-forward   2026-08-27 20:28:38 +0300
9df414ec0e  fetch upstream next: fast-forward   2026-08-26 22:23:12 +0300
142dfcf4b2  fetch upstream next: fast-forward   2026-08-26 00:25:02 +0300
```

**`upstream/next` moved TWICE during this session, thirty-one minutes apart**, and the sweep's M11
ran between the two. `CAMPAIGN-BRIEF.md` names five moves; this is the sixth and the seventh.

**I attempted the repair and stopped, deliberately, and the tree is left at HEAD.** What happened,
in order:

1. At `9d9523b973` the failure was the familiar mechanical one plus one expired acknowledgement.
   `bootstrap.sh`'s `upstream_after` blob had moved `189faea6f4` -> `30cbed0f71` because
   `9d9523b9735` (*chore: labs submodule with a foundation patch series*) inserted 24 lines of
   `labs-patches` git-hook plumbing at base lines 315..316, 318..319, 322..323, 324..325 and
   334..335. Patch 2 touches base line 18, so the regions were still disjoint by ~297 lines and the
   acknowledgement still held on its merits. I updated the entry, re-ran `just carry-exposure`, and
   re-ran the check.
2. **Upstream had moved again while I did that** — `703d896149`, *chore!: delete the in-tree labs
   components* — so the freshly-written acknowledgement was stale on arrival.
3. **And the seventh move breaks a conjunct that no acknowledgement can excuse.** For six moves
   upstream changed nothing under `barretenberg/cpp`; at `703d896149` it has changed **five** paths
   there (`bootstrap.sh`, `docs/Fuzzing.md`, `scripts/chonk_inputs.sh`,
   `scripts/ci_benchmark_ultrahonk_circuits.sh`, `scripts/pinned_chonk_inputs.sh`).
   `_carry_overlap.py` rejects that class *before* it reads `carry/overlap.json` at all, which is
   the design, and `CAMPAIGN-BRIEF.md` says so in as many words: "if conjunct 1 has failed no
   acknowledgement can help and M6 and M10 owe a rebuild".

**What is and is not established about the seventh move**, because the distinction decides the
remedy:

- **The carry set still applies.** The replay at `703d896149` reports `5 patch(es): 5 applies`,
  p1..p5, and the intersection with upstream's 10,925 changed paths is still the same **three**
  paths — `bootstrap.sh`, `build-images/src/Dockerfile`, `scripts/setup-container.sh` — **none of
  them under `barretenberg/cpp`**. So this is not a rebase conflict.
- **Conjunct 1 is about the BUILD TREE, not about the intersection.** It asks whether upstream has
  touched `barretenberg/cpp` at all since the base, because M6's and M10's evidence is a build of
  BASE + this stack. It has, and the five paths are one provisioning script, one document and three
  benchmark scripts — **none of them a CMake file or a translation unit**. So the *substance* is
  very likely unaffected and the *conjunct* is correctly red: the check is deliberately
  conservative and the narrowing is a decision.

**That decision is M11's and I did not take it**, for three reasons stated plainly rather than as an
excuse: it is a different milestone's judgement about what its own guard should mean; it needs
M6's and M10's builds re-run to say anything stronger than "the paths look irrelevant"; and the
target moved twice in the thirty-five minutes I spent on it, so any pin I wrote would be stale
before a reviewer read it. `carry/{overlap,exposure,rebase}.json` and `CARRY-LEDGER.md` are
restored to HEAD with `git checkout`, so **the tree carries M28's changes and nothing else**, and
M11's red is exactly what the sweep measured rather than a half-finished repair.

## 9. After the documents were written, the two milestones that could have moved were re-run

`CAMPAIGN-BRIEF.md`: "M20 committed a sixth candidate contribution to `codetracer-specs` after its
own sweep and **M11 and M14 both went red**, neither for anything in the repository the checks live
in." So after writing M28's section into the milestone file and updating `CAMPAIGN-BRIEF.md`, M14
and M28 were re-run alone:

```
verify-m14   460, 8/8, exit 0   (131 + 31 + 59 + 53 + 31 + 37 + 59 + 59)
verify-m28   348, 6/6, exit 0
```

Both at their sweep values to the assertion. M11 is not re-run: it is red for the upstream reason
above and re-running it would only re-measure a tip that has moved again.

## 10. Decisions taken and NOT taken, each with its reason

- **No `REUSE-INVENTORY.md` entry was added.** The inventory records decisions about UPSTREAM
  components — does-not-exist / does-not-cover / cannot-reach-target — and M28 took none: it reused
  this repository's own machinery (M27's CDP driver and arm runner, M24's reader, M18/M19's import
  walker, M27's depscan) and wrote no substitute for anything upstream ships. Adding an entry would
  also put `verify_reuse_inventory_complete` (19) and `verify_orchestration_reuse_enumerated` (66,
  which pins its census EXACTLY per subject) back in play after the sweep had measured them. The
  reuse is recorded in §3 of this log and in each check's own header instead.
- **The abnormal-exit trap was NOT moved into `lib.sh`**, for M22's own reason, and the cost is
  recorded in `lib_m28_gate.sh`: this is the FIFTH copy and M9's four checks — the retrospective
  case — still lack it.
- **`m27_bundle_newer_inputs` was NOT changed to a content stamp.** It is mtime-based and a restore
  that preserves mtimes defeats it (§5.1). A content stamp is what `_m24_oq6_stamp` is, and
  `CAMPAIGN-BRIEF.md` records what that costs; changing M27's staleness predicate on the way out of
  the campaign, after the sweep, is not a trade M28 should make unmeasured.
- **The running total of "an assertion that must be capable of failing" is NOT moved.** Four defects
  were found in my own checks before they landed (§4, §5.3) and every one belongs to a family this
  brief already names — "a citation counted as a call" twice (the `exit 0` and `continue-on-error`
  predicates reporting their own comments), M24's review's row-anchoring defect once (a document row
  carrying two figures can have them swapped), and "a `die` in `$(…)`" once. None is a fresh
  instance of an assertion that could not fail, so the five places that quote the number are left
  alone rather than bumped on a judgement call.

## 11. Final state, and what is outstanding at the end of the campaign

**No commits, no pushes, anywhere.** `aztec-avm-runtime` is at `da586b7` with M28's changes in the
working tree; `codetracer-specs` is at `572a83d3` with the milestone file modified.
`noir-wt4-webpage` is untouched by this session and is NOT to be committed — publishing
`wasm/webpage` is fact 7 of OQ-7's verdict and one of two conditions `JOIN-SHAPE.md` §6 names as
reopening the question. (It carries a pre-existing `tooling/tracer/src/tracer_glue.rs` modification
that predates this session.)

Files changed in `aztec-avm-runtime`: `.github/workflows/avm-wasm.yml`, `CAMPAIGN-BRIEF.md`,
`DRIFT.md`, `Justfile` (modified); `BROWSER-GATE.md`, `verification/_m28_bundle_scan.py`,
`verification/lib_m28_gate.sh`, five check scripts, `verification/m28/skip_probe_*.txt`, and four
`scratchpad/campaign/m28-*` files (new).

### Outstanding, at the close of twenty-nine milestones

1. **The CI secret, which is the user's and only the user's.**
   `gh variable set CI_TOKEN_PROVIDER_APP_ID --repo metacraft-labs/aztec-avm-runtime --body 3115338`
   and
   `gh secret set CI_TOKEN_PROVIDER_PRIVATE_KEY --repo metacraft-labs/aztec-avm-runtime < ci-app-private-key.pem`.
   Until then **no job in `avm-wasm.yml` has ever reached a check**, this one included. Every gate
   M28 declares has EXECUTED locally, against a planted violation; the JOB has not.
2. **Nothing is filed upstream.** Five patches prepared, six branches published, five
   `submit/pr<N>-*.sh` scripts. Submission is a manual step. **And PR #22815** (the Emscripten
   migration) is open and would delete what patch 2 changes.
3. **M11 is red and it is the seventh upstream move.** The carry set still applies (5 of 5) and the
   intersection is unchanged at three paths, but upstream has touched `barretenberg/cpp` for the
   first time and that conjunct cannot be acknowledged away. It needs an M11 decision — narrow the
   conjunct to paths that reach the CMake build, or re-run M6's and M10's builds and say so — on a
   tip that is currently moving every ~30 minutes.
4. **`test_trace_step_count_matches_instruction_count` is still `pending`**, in Node and in the
   browser, because the step stream in a recording is the artifact's own mapped program counters
   rather than the instructions executed. Wiring the AVM's observation hook through is what closes
   it. `BROWSER-GATE.md` §8 says the gate does not gate it.
5. **`verify_named_checks_exist` still scans no `.json` and no repository-root `.md`**, so
   `browser/chunk-budgets.json` and the root write-ups can name a check that has been renamed away.
   `BROWSER-GATE.md` closes it for itself.
6. **The abnormal-exit trap is in five milestone libraries and not in `lib.sh`**; M9's four checks —
   the case that would have turned a 283-assertion silent shrink into a red milestone — still lack
   it.
7. **`browser/dist`'s staleness predicate is mtime-based** and a restore that preserves mtimes
   defeats it, measured in M28's own mutation harness.
8. **No Web Worker, and persistence is deliberately absent.** Both are M27's recorded decisions and
   neither is foreclosed.
