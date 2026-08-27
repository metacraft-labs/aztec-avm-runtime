# M27 review log — Browser Packaging and Code Splitting

Review agent. Written as I go, per CAMPAIGN-BRIEF.md.

## 0. Starting state

- `aztec-avm-runtime` working tree: **47 paths staged, nothing committed**. M27 is entirely in the
  index. The implementation agent did not commit (correct per the loop) — but see F0.
- **F0. `scratchpad/campaign/m27-impl-log.md` AND `m27-brief.md` DO NOT EXIST.** The campaign brief
  says "Write `scratchpad/campaign/m<N>-*-log.md` as you go" and calls an interrupted agent that
  recorded its state "worth far more than one that has to start over". M27 recorded nothing: the
  scratchpad's newest campaign file is `m26-review-log.md`. There is also no `m27-mutations.sh`, so
  the eleven mutation arms the milestone claims exist **only as prose in the milestone file** —
  there is no script to re-run them. Every earlier milestone from M23 on left one
  (`m23-mutations.sh` … `m26-mutations.sh`). This review therefore has to reconstruct the mutation
  arms from the milestone's description rather than re-run the agent's own.

- Environment: `direnv exec .` gives node v24.19.0; `/usr/bin/chromium` 150.0.7871.128 on PATH.
- Work dir `~/.cache/aztec-m27-browser` is warm: `m27/` build tree, `site/`, `downloads/`,
  `browser.json` (13:45), `browser-last.json`/`browser-failed.json` (13:47), `browser/dist` (15:50).

## 1. First finding, before running anything: the shared arm run is never refreshed

`verification/lib_m27_browser.sh:273-296`:

```sh
    if [ -s "$M27_ARMS.tmp" ]; then
      mv "$M27_ARMS.tmp" "$M27_WORK/browser-failed.json"
    fi
    ...                       # rc==137/124 -> die ; rc!=0 -> die
    mv "$M27_ARMS.tmp" "$M27_ARMS"
```

The first `mv` is **unconditional on `rc`**. On a *successful* run the temp file is moved to
`browser-failed.json`, so the `mv` on line 296 has nothing to move: it prints
`mv: cannot stat …: No such file or directory` and `$M27_ARMS` is **never written**.

Evidence on disk before I ran anything:

- `browser.json` — 4,095,789 bytes, `measuredAt 2026-08-27T10:45:09.693Z`, `arms.timer.blocks` **10**
- `browser-last.json` == `browser-failed.json` — 4,095,595 bytes,
  `measuredAt 2026-08-27T10:47:21.452Z`, `arms.timer.blocks` **9**, `arms.error` **null**

`browser-last.json` is written by `tools/run_browser_arms.mjs:309` itself, i.e. it is the *last
completed* run. It is identical to `browser-failed.json`. So the 13:47 run **succeeded** and its
output was filed as "failed"; every check has been reading the 13:45 file.

Consequences to establish by measurement (below):
1. every behavioural check asserts over an arm run that is not the one that just executed;
2. on a **cold** work dir (no `browser.json`) the first run dies with
   "the browser arm run produced no output" — i.e. the milestone does not reproduce from clean.

This is the exact family CAMPAIGN-BRIEF.md calls "never depend on state you did not produce" and
"a mutated artefact outlived its restored source", and it is also the mechanism by which a mutation
could redden or green *for the wrong reason*.

**Established, both ways.**

- COLD: with `browser.json` moved aside, `verify_public_only_page_never_fetches_barretenberg`
  printed `mv: cannot stat …browser.json.tmp`, then
  `cannot run: the browser arm run produced no output` — **0 assertions, 1 failure**, straight after
  a browser run that had just succeeded. That is 4 of 10 checks (100 of 301 assertions) that a fresh
  clone or CI cannot run at all, and M28's whole subject is CI.
- WARM: the baseline `just verify-m27` printed **four** `mv: cannot stat` lines — one per
  behavioural check — so the arms ran four times (four browsers, not the one the design promises)
  and every one of the four results was discarded.

Fixed in `9e56c3b`: the move to `browser-failed.json` is guarded on `rc != 0`, the install is a
named failure rather than a diagnostic under a green summary, and the staleness predicate is
re-asked after the refresh so an arm report that outlives its tree fails instead of substituting.
Re-run cold: **20 assertions, 0 failures**, `browser.json` written.

## 2. Baseline, reproduced before touching anything

`just verify-m27`, dev shell, `TMPDIR` unset, detached: **301 assertions, 10/10, exit 0** — the
declared split exactly (41 / 34 / 23 / 61 / 21 / 21 / 20 / 32 / 14 / 34). So the headline number is
real; what it was measured over was not what it said (F1).

## 3. THE PRODUCT CLAIM — verified independently

Run by hand, not through the check:

```
$ ct-print --full ~/.cache/aztec-m27-browser/downloads/aztec-avm-01949fcc-…-000000002701.ct
rc=0   3355 lines
"type": "Step"  x64      "type": "Call" x3      "type": "Path" x5
paths: /aztec/tx.avm, …/aztec-nr/aztec/src/macros/dispatch.nr, …/aztec/src/oracle/avm.nr,
       …/noir-protocol-circuits/crates/serde/src/reader.nr, …/crates/serde/src/type_impls.nr
```

176,128 bytes, sha256 `8b7d0aeb…`, identical to the copy I snapshotted before any run of mine. The
reader, the exit status, the line count and the four Aztec.nr source names all hold.

**It really is the browser's download.** `tools/run_browser_arms.mjs` opens the page with
`Browser.setDownloadBehavior` pointed at `$M27_WORK/downloads`, which it `rmSync`es first, and then
reads the directory; nothing Node-side writes a `.ct` anywhere. Confirmed by mutation — **arm A**,
`offerDownload` made a no-op: **26 assertions, 19 failures**, starting with
`exactly one .ct file reached the download directory  expected [1], got [0]`.

**The transaction is real, and the step stream is not.** Both, stated precisely:

- REAL: `armRecord()` calls `armTokenTransfer()` first and takes the recording's contract address
  and its two frame names from that transaction's own report. `smoke_browser_token_transfer` joins
  the two ABI-derived selectors `0x8c9e5472` / `0xff7949f2` to calldata field 0 of the two enqueued
  calls, in order; outcome `processed` in block 1; 19 module calls; M26's vendored builder.
  Mutation **B** (one frame instead of two) fails `…split across the transaction's two enqueued
  calls  expected [2], got [1]`.
- NOT REAL: the 64 steps are the artifact's own first 64 MAPPED pcs, with `opcode: (pc % 200) + 1`
  and gas a linear function of the index (`ct_download.ts:185-194`). They are not what the
  transaction executed. **The milestone discloses this** in its Outstanding Tasks and in
  `ct_download.ts`'s header, and `test_trace_step_count_matches_instruction_count` is `pending` for
  it. It is disclosed, not hidden — but "the container the browser downloaded is a recording OF that
  transaction" is true only of the address, the frame names and the source positions.

## 4. DD-11 — the finding, checked in every direction it claims

- **The four exported bodies are upstream's.** Compared against the sibling fork:
  `bbapi_ecc.cpp:GrumpkinMul::execute` is an on-curve check then
  `element(point).mul_const_time(scalar).to_affine_const_time()` — the patch's `avm_grumpkin_mul`
  line for line; `GrumpkinAdd::execute` is two on-curve checks then `point_a + point_b`;
  `bbapi_crypto.cpp:Poseidon2Hash::execute` is
  `crypto::Poseidon2<crypto::Poseidon2Bn254ScalarFieldParams>::hash(inputs)` and
  `Poseidon2Permutation::execute` is `Permutation::permutation(inputs)`. **Holds.**
- **The module is 55 exports / 1,621,354 bytes**, measured by `WebAssembly.Module.exports` and
  `stat`. **Holds**, to the byte.
- **Numerically correct in BOTH directions.** Positive: 9/9 poseidon inputs, the permutation, the
  domain-separated hash, 5/5 grumpkin scalars and the addition all agree with `@aztec/foundation`.
  Negative (**arm C**, one bit flipped in the host's field decoder): `HASH-OK 0`, `HASH-BAD 9`,
  permutation and separator both `false` — **4 failures**. So 9/9 is a measurement.
- **The overlay applies cleanly** — `~/.cache/aztec-m27-browser/m27-am.log`, thirteen patches, and
  the module it produced is the one every check ran against.
- **The substitution is load-bearing.** **Arm D**, the poseidon2 redirect deleted from the build
  table: the page fetched `/chunks/barretenberg-6RDKZY7O.js` and the module's poseidon2 was called
  **0** times — the absence assertion AND its paired positive both fired.

## 5. Claim 1 — the observed-network control DOES discriminate

**Arm E**: the control page's `loadProvingStack()` call silenced in the runner (not in the page —
editing it out of `demo/main.ts` removes bb.js's only dynamic import from the entry set, re-splits
the chunks and trips a shared-chunk budget, so the build refuses and the arm reddens for the wrong
reason). Result: **3 failures** — `the control page DID reach the proving stack expected [true], got
[false]`, and both list assertions. The control is real.

## 6. Claim 2 — budgets ARE enforced at build time, and one half was NOT

- **Arm F** (the class-registry redirect dropped, which is the realistic regression — the build's
  own "every redirect fired" guard cannot see a redirect that is not in the table): eager
  **253.94 → 750.09 KB** and the build refuses, naming the entry budget. The milestone's number
  reproduces exactly.
- **Arm F2** (a budget deleted): the build refuses naming `covered by no budget`. No catch-all.
- **Arm F-RIGHT**: F with the budgets raised out of the way — `verify_browser_artifacts_lazy`'s
  edge-kind assertions DO fire, four failures naming the `import-statement` edge. So the milestone's
  note that F "is not evidence that the assertion it was written for can fail" is **too pessimistic**:
  it can, and now there is a measurement of it.
- **BUT** — and this is the milestone's own headline deliverable — see F3 below.

## 7. The findings, as a table

Every row measured, not reasoned. "Passed" = the check reported that count with zero failures over
the mutated tree.

| # | claim | what the mutation was | before | after fix |
|---|---|---|---|---|
| F1 | the shared arm run is the run that just executed | (none needed — read off disk) | stale, and cold-start dies | `9e56c3b` |
| F2 | "the fee-juice shim is pinned line by line by `verify_browser_artifacts_lazy`" | P1 one line ×20; P2 two adjacent lines swapped; P3 an inserted `feePayer = …FeeJuice;` | **61/0 each** | 67, each fails by its own assertion; P3 is a REAL corruption (`processed` → `failed`) |
| F3 | "chunk budgets recorded and enforced, and the enforcement is shown to be able to fail" | delete `eagerViolations.push` from `build.mjs` | **budget 23/0, builds 41/0** | 27, §4b |
| F4 | "the SAME needles find `node:fs/promises` in the node bundle" | typo the loop's needle list | **34/0** | 40, the control runs the census |
| F5 | "exports no type named `AztecNode` (§8.4)", ×4 | `export type { AztecNode }` in `entry_browser.ts` | **34/0 and 41/0** | 40, §6b over the sources |
| F6 | "the format is esm / es2022 / browser, read off the artefacts" | `target: 'esnext'` | passes — the assertion selects outputs by a needle and then asserts the needle | 54, entry-point join + ESM export list + flags pinned at the declaration |
| F7 | "the module the PAGE compiled is the one on disk" | both sides `MISSING` | passes | 37, non-emptiness partner |
| F8 | "the block's transaction list contains this transaction" | `txHash: ""` — `str_has_sub` has no empty-needle guard | passes over any block list | 37, hash shape asserted first |
| F9 | "the runtime disclosed, in the page" | empty the disclosure text | passes — the needle is the demo page's own `[disclosure] ` prefix | 37, a fragment of `DISCLOSURE_LINE` taken from its source |
| F10 | "no puppeteer, no playwright" | — | TRUE and asserted nowhere | 54, two trees + a control |
| F11 | `verify_named_checks_exist` covers M27's sources | rename a check, leave `build.mjs` naming the old spelling | not reported | root is `browser/`, 9/0 unchanged |
| F12 | "M27's module imports `random_get` and never calls it" | — | FALSE, in `wasi.ts:114`, ninety lines under the header that corrected it | `a473d68` |
| F13 | `REACTOR-ABI.md`'s eleven-import surface | — | true of M12/M13/M23, false of M27 | per-artefact table added; no check repointed |
| F14 | bb.js "has THREE subpaths … only ONE has a browser condition" | drop `./platform` from the pin | both absences pass over a subpath that is gone | 23, the three asserted |
| F15 | `hardwareConcurrency` is a browser-only marker | — | it is in `dest/node/…/helpers/browser/` too; no negative control | 23, paired 1-vs-0 |
| F16 | "the redirect table: **four** modules" ×2 | — | five | corrected |

## 8. Mutation coverage taken by this review — fourteen arms, all detected

`scratchpad/campaign/m27-review-mutations.sh`. P1 P2 P3 A B C D E F F-RIGHT F2 H I, plus the arms
timeout branch driven directly.

- **H (the hang)** — `armTokenTransfer` awaits a promise that never settles. The die names
  `Runtime.evaluate: {"code":-32000,"message":"Promise was collected"}`, read out of
  `browser-failed.json`, and the trap prints `0 assertion(s), 1 failure(s)`. So the defect H exposed
  — the failed-arms report being discarded, leaving the die pointing at an empty stderr — **is
  fixed**: the message comes from the report, not from stderr.
- **The timeout branch is a separate path and it was not exercised by H.** `CAMPAIGN-BRIEF.md`:
  "when a mutation reddens, read WHICH assertions went red". H returns exit 1 in seconds; the
  `rc == 137/124` arm is what a page that never fires `load` produces. Driven directly with
  `M27_ARMS_TIMEOUT=3`: `did not finish within 3s and was killed`, `0 assertion(s), 1 failure(s)`.
  Both paths work; only one of them is what H exercises.
- **I (die before summary)** — `kill -TERM $$` before section 4: `14 assertion(s), 1 failure(s)`,
  a RED milestone rather than a smaller one. (The trap prints `exited (status 0)` after a signal,
  which is cosmetic and left alone.)

## 9. Claim 4 — "M27 vendored NOTHING, so `verify_provenance_complete` stays at 64"

`PROVENANCE.md` is unmodified by M27 — confirmed, `git diff --cached PROVENANCE.md` is empty, and
the sweep re-measures M1. The *reasoning*, though, was the exclusion's shape and it did hide a
defect: see F2. The exclusion itself is sound — a substitute that deliberately differs cannot be
byte-compared against what it replaces — but "so we pinned it differently" was not true until this
review made it true. The pin is now an ordered line-for-line comparison against upstream's barrel
with the two declared substitutions applied, so **upstream drifting moves the expectation**, which
is stronger than a `PROVENANCE.md` row would have been.

## 10. Claim 7c — the duplicated M25/M26 pair, RESOLVED BY MEASUREMENT

The milestone says: "The milestone file carries a DUPLICATED M25 and M26 pair, at two places,
differing by about 140 lines (**the later pair is the one M26's review updated**)."

Measured in `codetracer-specs`' git history rather than by reading either copy:

- `ae7dc7ff` ("M26 — the Noir fixture suite, measured rather than assumed", 2026-08-27 11:59)
  inserted 575 lines. **Before it there was exactly one M25 and one M26**; after it there are two of
  each.
- The **second** M26 (line 10874, 314 lines) is **byte-identical to the pre-`ae7dc7ff` version**.
- The two M25 copies are **byte-identical to each other** — so "differing by about 140 lines" is
  true of the M26 pair only.
- The M26 pair differs on a MEASUREMENT: the first copy says the Noir fixture suite is
  *"3 passed, 3 failed"* with an attribution split; the second says it is *"RED AT HEAD, six of
  six"* and that the review *"declined to repin"*.

**So the note is exactly backwards: the EARLIER copy is the updated one.** Anyone resolving the
duplication by following it would have deleted the newer measurement and restored the stale claim.
Corroborated in the other repository: `noir`'s HEAD is `01cf48082` *"repin the fixture expectations
that measurement moved"*, 11:38 — twenty-one minutes before `ae7dc7ff`.

## 11. Claims 5 and the rest

- **No puppeteer/playwright.** TRUE: no `browser/package.json` at all (the package declares no
  dependencies and shares the orchestration's tree by symlink); nothing in any of the seven tracked
  `package.json` files, no lockfile hit, nothing installed. It was asserted **nowhere** — three
  comments and no measurement. Now pinned in `verify_browser_bundle_builds` §6, over two trees, with
  prefix matching (`@playwright/test`, `puppeteer-core`) and a control that shares the instrument.
- **REACTOR-ABI.md.** The module really does import **thirteen** (twelve WASI + `env.memory`) and
  export **55** at 1,621,354 bytes. D21's decision to defer was defensible about the CHECKS and
  wrong about the cost: the per-artefact shape D21 itself prescribes needs no check to move, so the
  false sentence is gone and nothing is repointed. And the shim's own `randomBytes` doc still said
  "never calls it" — corrected once in the header, left standing ninety lines below.
- **M9's timing budget.** See §12.

## 12. M9's timing assertion

The sweep entry for M9 that reddened in an earlier campaign sweep was a TIMING assertion — a +1.27 %
observation, CI [+0.51, +2.03], against a +2 % budget, on a loaded box — not the truncation flake,
and M9 passed alone at 807. Judged here rather than left as a note:

**The budget is measuring machine load as much as it is measuring the subject.** The confidence
interval's upper bound crosses the budget while the point estimate is well inside it, which is the
signature of a comparison whose noise floor is of the same order as the effect it is asked to
resolve. `CAMPAIGN-BRIEF.md` already carries the remedy for this family in the OQ-6 account: "the
session is the unit of replication … five runs say that is not enough here. A future measurement
that needed to resolve a sub-1 % difference would need the RUN as the unit." A ±2 % budget on a
shared box is a sub-1 %-resolution instrument being asked a 2 % question. **The right shape is the
one the brief also states — "timing measurements assert their own preconditions … exit with a
distinct code rather than returning a wrong number on a loaded box"** — i.e. the check should REFUSE
when its own control arm's spread exceeds the budget, rather than reporting a red assertion that
reads as a regression in the subject. That is M9's to change and not M27's; recorded here with the
reasoning so the next sweep that sees it does not re-derive it.
# F17 — BROWSER-PACKAGING.md: the only milestone write-up no check opens

Verified independently (not taken from the audit):

- `lib_m27_browser.sh:32,35` defines and exports `M27_DOC`. `grep -rn M27_DOC verification/` outside
  those two lines: **nothing**. Every other write-up is opened by 2-7 checks
  (`M12_WRITEUP` 3, `M15_WRITEUP` 6, `M23_DOC` 7).
- The document's own line 3-4: *"Everything here is re-derived by a check on every run; where a
  number appears, the check that recomputes it is named beside it."* **Zero of its figures are.**

Eleven figures are ALREADY WRONG, each re-derived by me from the artefact:

| doc | says | artefact says | derived from |
|---|---|---|---|
| `:35` | 8,166 KB total gzipped | **8,149.89** | `chunks.json.totalGzipBytes` 8,345,484 / 1024 |
| `:75` | `util` (37 files) | **43** | `meta.json` importers of `browser-probe/shims/util.js` |
| `:75` | `assert` (5) | **8** | same |
| `:78` | shims "twelve lines between them" | **11** | `wc -l` 4 + 5 + 2 |
| `:79` | "**One** `@aztec/foundation` module is substituted" | **two** (poseidon AND grumpkin) | `.build-config.json` `redirects` |
| `:189` | node "adds **four** declared conveniences" | **five** `NODE_CONVENIENCES` keys | `entry_node.ts:43-50`, and the check's own set equality is over all five |
| `:216` | "`/demo.js` + **6** shared chunks" | **7** | `arms.publicOnly.requests`, and `chunks.json` `eager[demo]` = 8 files |
| `:216` | "**253.94 KB** gzipped of runtime" for the demo page | **277.65** (253.94 is the *browser* entry, whose entry file the demo never fetches) | `chunks.json` `eager` |
| `:212` vs `:214-221` | "Thirteen requests" over an enumeration totalling **12** | — | its own list |
| `:287-297` | the nine-row timer table, absolute epochs | a DIFFERENT run entirely | `browser.json` |
| `:299` | "jumps **four** seconds", "deviation collapses **from 4** to 1" | **three**, from 3 | `browser.json` |

`util` (37) / `assert` (5), "twelve lines", "four conveniences" and the timer table are each repeated
in 2-4 more places (`browser/build.mjs`, `REUSE-INVENTORY.md`, the milestone file), which is the
brief's "move all five numbers together" shape.

**The timer table cannot be pinned at all** and that is the interesting half: the timestamps, the
wall clocks and the deviations are all functions of when the arm ran and how the scheduler behaved.
Any table of them is stale the moment the arms re-run. The check already asserts the INVARIANTS
(strictly increasing, one second per block, a >= 2 s wall-clock gap, >= 3 non-zero deviations); the
document presents one run's numbers as if they were the measurement.

**Three numbers the harness already computes and throws away**, each in the section whose figure the
document leads with:
- `verify_browser_chunk_budget.sh:55` computes `TOTALGZIP` into `$SUMMARY` and never asserts on it —
  that is `:35`'s 8,166.
- `e2e_...sh:108` computes `$LINES` and spends it on a `note` — that is `:244`'s 3,355.
- `lib_m27_browser.sh:137` exports `M27_MODULE_EXPORT_COUNT` and no check reads it — that is
  `:139`'s 55.

## 13. The M0–M27 sweep — 9,695, 28/28, zero failures

`setsid`-detached, `direnv exec <this repo>`, one milestone at a time, nothing else running,
`TMPDIR` and the log under `~/.cache`, no hole in the log, 103 minutes.

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 324  m22 260  m23 509  m24 350  m25 272  m26 313  m27 343
                                                        CAMPAIGN TOTAL 9,695
```

**Every one of M0–M26 came out at its reference value TO THE ASSERTION**, including M9 at **807 in
1,433 s with no flake and no truncation** (immediately after M8's build, which is D19's standing
hypothesis, and it did not fire), M11 at 259 (upstream has not moved a sixth time), M4 at 218 in the
dev shell, M24 at 350 and M25 at 272.

**Both directions.** Declared 9,653 = 9,352 + 301. Measured 9,695 = 9,352 + 343. The +42 is M27's
alone, in six checks and nothing else:

| check | declared | after review | Δ |
|---|---|---|---|
| `verify_browser_bundle_builds` | 41 | 54 | +13 |
| `verify_browser_chunk_budget` | 23 | 33 | +10 |
| `verify_browser_entry_points_are_dd5_shaped` | 34 | 40 | +6 |
| `verify_browser_artifacts_lazy` | 61 | 67 | +6 |
| `smoke_browser_token_transfer` | 32 | 37 | +5 |
| `verify_bb_js_browser_condition_honoured` | 21 | 23 | +2 |
| `test_browser_crypto_matches_bb_js` | 21 | 21 | — |
| `verify_public_only_page_never_fetches_barretenberg` | 20 | 20 | — |
| `smoke_browser_produces_block_on_real_timer` | 14 | 14 | — |
| `e2e_browser_downloads_ct_container_and_ct_print_parses` | 34 | 34 | — |

13 + 10 + 6 + 6 + 5 + 2 = 42, and 301 + 42 = 343.

**Nothing outside M27 moved**, and the two things that could have were measured rather than assumed:
`verify_named_checks_exist` stays at **9** with `browser/` as a scan root instead of two of its
subdirectories, and `verify_provenance_complete` stays at **64** — M27 vendors nothing and
`PROVENANCE.md` is byte-unchanged. After the `codetracer-specs` edits, M11 and M14 were re-run alone
and came back **259** and **460**, the reference exactly.

The final M27 run: **343, 10/10, exit 0**, the arms run **once** and zero `mv: cannot stat`.
