# M29 — Executed Steps, Not Mapped Ones — REVIEW log

Written as I go. Standing rules: mutation and sweep are serialised (both are writers);
the sweep runs `setsid`-detached from this repository's own dev shell and is polled inside
this run; `noir-wt4-webpage` is never committed.

## State at review start

`aztec-avm-runtime` on `dev`, HEAD `3d6966c` (M28's review's last commit). The tree carries
M29's uncommitted work: 16 modified tracked files and 13 untracked, of which 8 are
`verification/` additions and 2 are `browser/src` additions.

## Plan

1. Cheap static claims first (4: `patchFieldsFor`; 5: the deleted synthesised path).
2. The M27 finding — did the demo transaction really revert, why `processed`, and would
   anything catch it now.
3. Re-run `verify-m29`, take the per-check split, then mutate.
4. The discriminator's negative direction; the differential's exclusion list.
5. Cross-milestone counts (M27, M21, M25).
6. Sweep last, after my last commit.

---
## 1. `verify-m29` re-run — 105 CONFIRMED

Detached, in this repository's own dev shell, `TMPDIR` under `~/.cache`, log at
`~/.cache/aztec-m29rev-verify.log`:

```
test_browser_steps_are_executed_not_mapped: 52 assertion(s), 0 failure(s)
e2e_browser_container_opcodes_match_native: 30 assertion(s), 0 failure(s)
test_trace_step_count_matches_instruction_count: 23 assertion(s), 0 failure(s)
```

52 + 30 + 23 = **105**, three of three exit 0, and the log carries exactly **105 `ok` lines**, so
no assertion is printed without being counted. The run was seconds rather than minutes because the
arm report and the two native transcripts were warm; the staleness predicate is sound (below).

**The arms staleness chain was checked rather than assumed**, because every mutation below depends
on it: `m27_bundle_newer_inputs` finds anything under `$BROWSER_SRC`, `$BROWSER_DIR/demo`,
`$ORCH_SRC`, `ct-host/src`, `node-host/src` and the build scripts newer than
`browser/dist/meta.json`, and `m27_arms_newer_inputs` finds anything under `$BROWSER_DIST` newer
than the arm report. So a mutation of `executed_steps.ts`, `native_parity.ts`, `ct_download.ts`,
`token_transfer.ts` or `shipped_module_config.ts` forces a rebuild AND an arm re-run. Verified
live: every mutation below did rebuild.

## 2. Findings from the static pass, before any mutation

### F1 — THE BUILT-BUNDLE HALF OF THE DELETION CLAIM CANNOT FAIL (needle vs. minifier)

`test_browser_steps_are_executed_not_mapped` §5:

```sh
BUNDLE_SITES="$(grep -rl '% 200' "$BROWSER_DIST" 2>/dev/null | grep -c . || true)"
assert_eq "…and neither does any file of the built bundle" "0" "$BUNDLE_SITES"
```

`browser/esbuild-driver.mjs:90` sets `minify: true`. Measured directly against the very esbuild the
build uses (`spike/node_modules/esbuild/lib/main.js`, in the dev shell):

```
in : export function f(pc){ return { opcode: (pc % 200) + 1 }; }
out: export function f(o){return{opcode:o%200+1}}
contains "% 200": false
contains "%200" : true
```

The needle carries a space the bundler removes. **The assertion is 0 by construction and could not
be anything else** — the second form on `CAMPAIGN-BRIEF.md`'s list, "a `grep -c` on a needle that
could never match", in the deliverable's own words ("the rule's absence is asserted over the browser
SOURCE TREE and over the BUILT BUNDLE"). It has no control either: the SOURCE grep has one
(`SYNTH_RULE_ALL >= 1`, the stripper's own effect), the BUNDLE grep has none. Confirmed by mutation
below: with the rule put back the bundle contains `%200` and this assertion stays green.

### F2 — NOTHING ANYWHERE ASKS WHETHER THE DEMO TRANSACTION REVERTED

Grepped the whole repository: `revertCode` appears in `orchestration/src/form_a.ts`,
`form_a_e2e_driver.ts`, `node-host/src/transcript.ts`, the vendored `public_processor.ts` and
`browser/src/native_parity.ts` — and **not once on the demo transfer path**.
`TokenTransferReport` has no revert field; the arm report's `publicOnly.transfer` carries
`outcome: 'processed'` and `outcomeRecord: {kind, blockNumber}` and nothing else, because
`orchestration/src/chain.ts:138`'s `TxOutcomeRecord` has no revert dimension at all.

### F3 — `patchFieldsFor`'s run-time key-set assertion cannot fail for any input

`out` is built by iterating `Object.keys(PATCH_REQUIRED_CONFIG_FIELDS)`, so `produced` is
`declared` by construction and the `throw` is unreachable for every input. The *property* holds —
it holds structurally, which is better than an assertion — but the milestone advertises it as a
run-time assertion, and it is one that cannot fire.

### F4 — `excluded == 0` is the count of arguments the check itself passed

`_m29_record_compare.py` prints `excluded\t{len(sys.argv[3:])}`; the check invokes it with no
excluded fields. `assert_eq "…field for field, with NOTHING excluded" "0" "$(m29_cmp excluded)"`
therefore reports a property of its own call site. The exclusion machinery is never exercised in
either direction, so "the exclusion list is EMPTY" is a statement about the invocation and not a
measurement of the instrument.

## 3. The M27 finding, established independently — AND IT IS WORSE THAN M29 REPORTED

### 3.1 The pre-M29 demo transaction really did revert at instruction one

`browser/src/token_transfer.ts` was reverted to `HEAD` (M27's exact file, no seedings) with M29's
plumbing left in place, the bundle rebuilt, and `tools/run_browser_arms.mjs` run into a scratch
work directory of my own so the result did not depend on the shared report. Measured:

```
outcome        = processed
outcomeRecord  = {'kind': 'processed', 'blockNumber': 1}
executed.count = 1
instructionsExecuted = 1
distinctOpcodes= 1
opcodeHistogram= {'68': 1}
records        = ['ctx=1 pc=0 op=68 l2=6540000 da=786432 addr=0x115d1b9c…96c1']
download.recording.events = 1   stepsPositioned = 0   stepsUnpositioned = 1
download.recording.bytes  = 176128
```

Every figure M29 reports is reproduced: one record, `pc=0`, opcode **68** (M9's
`LAST_OPCODE_SENTINEL`), while the block reports **`processed`**. And the container is still
well-formed — 176,128 bytes, the same size M27 recorded — so `ct-print` had nothing to object to.
**The M27 finding is TRUE.**

### 3.2 Why `processed` — it is upstream's own vocabulary, and nothing is masking a failure

Read out of the installed `@aztec/stdlib`'s own `dest/tx/processed_tx.d.ts`:

```ts
/** Represents a tx that has been processed by the sequencer public processor … */
export type ProcessedTx = { …; revertCode: RevertCode; revertReason: SimulationError | undefined; };
/** Represents a tx that failed to be processed by the sequencer public processor. */
export type FailedTx  = { tx: Tx; error: Error };
```

A reverted transaction IS a `ProcessedTx` — it carries a non-zero `revertCode`, it produces a
`TxEffect` and it pays its fee. `FailedTx` is the *processor* throwing. `orchestration/src/chain.ts`
maps the two faithfully (`assembled.processed` -> `kind: 'processed'`,
`assembled.failed` -> `kind: 'failed'`). **So `processed` is correct and nothing is hiding a
failure.** What is missing is not a correction to the vocabulary; it is that the one dimension
upstream carries and this runtime discards — `revertCode` — never reached the demo path at all.

### 3.3 WOULD ANYTHING CATCH IT NOW? THE DEGENERATE REVERT YES, A REAL ONE NO.

Two measurements rather than one, because the answer differs.

**(a) The degenerate revert (M27's own, one instruction).** Over the reverted `token_transfer.ts`:

| check | result |
|---|---|
| `smoke_browser_token_transfer` | **37 assertions, 0 failures — PASS** |
| `e2e_browser_downloads_ct_container_and_ct_print_parses` | 36, **8 failures** |
| `test_browser_steps_are_executed_not_mapped` | 52, **11 failures** |
| `test_trace_step_count_matches_instruction_count` | 23, **2 failures** |
| `e2e_browser_container_opcodes_match_native` | 30, 0 — PASS (it measures a different arm) |

So M29 does catch M27's exact failure, by the `>= 100` floor, the sentinel assertion, the
two-context floor and the positioned floor. That much of the milestone's claim holds.

**(b) A REAL revert — and this is the finding.** `isStaticCall: true` was removed from the
`#[view]` call and nothing else: seeding gap 4, the LAST one M29 found, which M29's own log records
as `471 -> 516, revertCode 0`. Reproduced exactly — 471 records, contexts `[1, 2]`, 26 distinct
opcodes, the last record `op=60` (`REVERT_8`), `outcome = processed`, a 192,512-byte container with
342 positioned / 129 unpositioned:

| check | result |
|---|---|
| `smoke_browser_token_transfer` | 37, 0 — **PASS** |
| `e2e_browser_downloads_ct_container_and_ct_print_parses` | 36, 0 — **PASS** |
| `test_browser_steps_are_executed_not_mapped` | 52, 0 — **PASS** |
| `test_trace_step_count_matches_instruction_count` | 23, 0 — **PASS** |
| `e2e_browser_container_opcodes_match_native` | 30, 0 — **PASS** |

**`just verify-m29` is 105 of 105 green over a demo transaction that reverts.** Every assertion is
correct; none of them asks whether the subject did what it was for. It is the campaign's
most-repeated defect in its purest form, and it is worse here than in M27: M27 did not know its
transaction reverted, whereas **M29 found the revert, fixed four causes of it, and shipped no
assertion that would notice the fifth.** The `>= 100` floor, the two-context floor and the sentinel
assertion are all satisfied by a transaction that runs 471 instructions and then reverts.

`nativeParity.revertCode` is **1** in the same arm report, computed by `native_parity.ts:122` and
**read by no check** — the "a number the harness already computes and throws away" family, and it
is the control the missing assertion needs.

## 4. F1 proven by mutation: the bundle assertion is green over a bundle containing the rule

`opcode: (step.pc % 200) + 1` put back at the WRITE site of `ct_download.ts`, rebuilt:

```
test_browser_steps_are_executed_not_mapped: 52 assertion(s), 3 failure(s)
  FAIL no browser source COMPUTES an opcode as (pc % 200) + 1        (the SOURCE grep)
  FAIL THE CONTAINER'S OPCODE HISTOGRAM IS THE DRAINED STREAM'S      (section 7)
  FAIL …and it is NOT the histogram the container carries            (section 7's second control)
grep -rl "% 200" browser/dist -> 0      <-- the assertion, still GREEN
grep -rl "%200"  browser/dist -> 2      <-- the rule IS in two files of the bundle
```

The needle was blind; §7 is what caught the mutation, exactly as the impl agent's own harness found.
The bundle half of the deliverable contributed nothing.

## 5. The other claims, verified

### Claim 2 — the discriminator, both directions, read off the artefacts the check produced

```
REAL   residue 0  pairs 516  distinctOpcodes 24  syntheticRuleMatches 2   syntheticRuleHolds 0
       pcsStrictlyIncreasing 0  pcsAllDistinct 0  pcRevisits 137  backwardJumps 5  verdict executed
SYNTH  residue 0  pairs 64   distinctOpcodes 51  syntheticRuleMatches 64  syntheticRuleHolds 1
       pcsStrictlyIncreasing 1  pcsAllDistinct 1  pcRevisits 0    backwardJumps 0  verdict mapped
```

24 / 137 / 5 / 0 exactly as declared. **The negative direction holds and BOTH conjuncts fire on
it** — the synthetic stream satisfies `(pc % 200) + 1` AND is strictly increasing AND pairwise
distinct — so neither criterion is riding along on the other. `syntheticRuleMatches 2` on the real
stream (2 of 516 opcodes coincidentally satisfy the rule) says the conjunct is not trivially far
from firing. `cmp` of the container's histogram against the drained stream's is IDENTICAL, and §7's
two controls (a one-count corruption; M27's rule applied to the SAME executed pcs) both fail as
required. **Claim 2 SURVIVES.**

### Claim 3 — the differential is not shallow

`compare.txt`: `leftRecords 38903 / rightRecords 38903 / leftResidue 0 / rightResidue 0 /
lengthDiffers 0 / compared 38903 / mismatches 0`. Both residues zero is what says the six-field
regex parsed every one of the 77,806 lines rather than dropping them into a bucket — verified by
mutation (narrowing `pc=(\S+)` to `pc=([0-9])` gives `residue 38901` on both sides and eight
failures). `burn` uses three distinct opcodes and one address, so the discriminating variation is
`pc` and the two gas counters across 38,903 records; the comparator is shown to catch a changed
ctx, a changed opcode, a dropped record and a wrong program. **Claim 3 SURVIVES**, with F4 fixed.

### Claim 4 — the one-line cause, and nothing else is hard-coded through that spread

`orchestration/src/shipped_module_config.ts:57` is `PATCH_REQUIRED_CONFIG_FIELDS`, one key, spread
at line 116 as `{ ...config, ...patchFieldsFor(options), ...injectedConfigFields }`. Every other
`...CONSTANT` spread in `orchestration/src`, `browser/src`, `node-host/src` and `ct-host/src` was
enumerated: `chain.ts:246` is `{ ...DEFAULT_BLOCK_PRODUCTION, ...config }` — the constant FIRST, so
the caller wins, which is the opposite direction and not an instance; `abi.ts` and `gate.ts` spread
arrays into other arrays. `defaultPublicSimulatorConfig` delegates to upstream's
`PublicSimulatorConfig.from(overrides)` and hard-codes nothing. **No second instance.** The
encoding delta is enforced by `e2e_form_a_external_tx_roundtrip` Part 8, which computes it from the
DECODED BYTES and injects a second key to prove the walk can fail — that check is real and it can
fail. **Claim 4 SURVIVES, with F3 fixed.**

### Claim 5 — the synthesised path is deleted

`% 200` occurs in `browser/src` and `browser/demo` only inside comments (2 sites, both prose);
`recordAndDownload` throws `ExecutedStepsUnavailable` on a `null`, an empty stream, or a
count/decoded disagreement; `DEMO_STEPS` and the mapped-pc walk are gone. `tools/run_join_arms.mjs`
still carries `(pc % 200) + 1` at :217 and :441 — that is M26's join driver, and the milestone's
own Outstanding Tasks declares it in as many words rather than hiding it. **Claim 5 SURVIVES for
the browser path**, and the bundle half of it is now measured rather than assumed (F1).

### Claim 6 — counts and cross-milestone moves

- **M27 345** re-measured in my own run: 54 + 40 + 33 + 67 + 23 + 21 + 20 + 37 + 14 + 36 = **345**.
- The **three removed assertions**, checked for "could not fail" rather than "was inconvenient":
  `…every step at a resolved SOURCE position` (`EVENTS == POS`) and `…and none unpositioned`
  (`UNPOS == 0`) were unfailable for TWO independent reasons — M27's steps were the artifact's
  mapped pcs, chosen for having positions, and, one level stronger, `CtWriter.close()` throws
  `MappingRungDegraded` on a rung-1 container with an unpositioned step, so a container that EXISTS
  at rung 1 satisfies both by construction (M27's own review had already recorded that second
  argument as G2). The third, `…declared at rung 1`, is not deleted at all — it is the same
  predicate under a new name (`the artifact itself earning rung 1`). So the true accounting is two
  unfailable assertions removed, one renamed, four new; `34 - 3 + 5 = 36` holds either way and 36
  is what the check reports.
- **M21 325**: the diff adds exactly one entry to the `COMPARERS` list, which is one assertion in
  a loop; the two `assert_eq` constants moved (30 -> 31, 8 -> 9) add none.
- **M25 272 unchanged**: the retired entry was `status: pending` with no `file:`, so it never
  carried an assertion. Structural; re-measured in the sweep.

## 6. The fixes, each with the mutation that proves it can fail

| # | fix | mutation | result |
|---|---|---|---|
| F2 | `token_transfer.ts` reports upstream's `ProcessedTx.revertCode`; `test_browser_steps_are_executed_not_mapped` §3b asserts it is 0, with the parity arm's own non-zero code as the control | `isStaticCall` removed (seeding gap 4) | **62 assertions, 2 failures**, both about the subject: `THE DEMO TRANSACTION DID NOT REVERT expected [0], got [1]` and `expected [OK], got [Reverted]` |
| F1 | the bundle scan strips whitespace and its needle is DERIVED by minifying the rule through the build's own esbuild, with the fixture as the instrument's positive control | `opcode: (step.pc % 200) + 1` at the write site | **62, 4 failures**, now including `…and neither does any file of the built bundle expected [0], got [2]`, naming `dist/node/node.js` and `dist/chunks/chunk-GHR7DKTW.js`. The same mutation before the fix: that assertion GREEN |
| F4 | the exclusion machinery is exercised (size, name, and that excluding the corrupted field hides the corruption) and the residue is read | `excluded = set()` in the comparator | **35, 3 failures**, one per new assertion |
| F4b | `leftResidue`/`rightResidue` asserted zero | `pc=(\S+)` -> `pc=([0-9])` | 35, 8 failures, of which the two residue ones name the undercount (38,901 of 38,903). *Stated honestly: these two add DIAGNOSIS, not detection — `compared == COUNT` already detects the same corruption.* |
| F3 | `patchFieldsFor` validates the CALLER's option keys instead of comparing `Object.keys(X)` with `Object.keys(X)` | `patchFieldsFor({ collectExecutionStep: true })` | before: silently `{collectExecutionSteps:false}`; after: `patchFieldsFor was asked for [collectExecutionStep], which PATCH_REQUIRED_CONFIG_FIELDS does not declare`. `{}` and `{collectExecutionSteps:true}` still answer `false`/`true` |

**`just verify-m29` after the fixes: 62 / 35 / 23 = 120, three of three, exit 0.**
The one control that had to be re-written is recorded rather than swapped quietly: the first form
of §3b's control was `assert_false test "$PARITY_REVERT" -eq "$REVERT_CODE"`, which is coupled to
the subject — with the reverting transaction it produced a THIRD failure that read as a broken
instrument. It is two independent readings now (`REVERT_CODE == 0`, `PARITY_REVERT >= 1`), and the
reverting transaction produces exactly two failures, both naming the subject.

`BROWSER-PACKAGING.md` §1 and §6 rotted by a few bytes because `token_transfer.ts` grew — the
testing/demo/node eager totals and the grand total, re-derived and refused by
`verify_browser_chunk_budget` exactly as they were for M29 itself. Corrected to
279.77 / 280.97 / 225.36 and 8,155.19; the browser reference entry is unmoved at 255.79 because
`token_transfer.ts` is not in its graph.

## 7. F5 — the three figures M29 published about its own hole were re-derived by nothing

`SOURCE-MAPPING.md`'s new §6 is M29's, and it states **516 / 389 / 127 and 24.6%** — the first
numbers §2.4's residual hole 2 has ever had. Two checks open that document
(`verify_oq5_source_mapping_verdict_recorded`, `test_fr_rendering_matches_noir_tracer`) and neither
reads any of them; grepped for `389`, `127` and `24.6` across `verification/` and the only hits are
unrelated. That is `CAMPAIGN-BRIEF.md`'s "if a document states a measurement, something must take
that measurement again and compare", and the subject makes it worse than usual: the hole closes the
day upstream re-keys `brillig_procedure_locs`, and the document would then be publishing a figure
about a hole that is no longer there.

The sentence also **wrapped between `516 executed` and `instructions, of which 389`**, which is the
"a needle that spanned a line break" family waiting to happen, so §6's measurement is a TABLE now,
one figure per row, each row naming its subject — and section 8 of
`test_browser_steps_are_executed_not_mapped` matches **each row by its own subject** rather than
each figure anywhere in the file, which is M24's review's correction to the OQ-6 check. The share is
COMPUTED from the other two, so a document carrying three consistent numbers and a percentage
belonging to a different transaction fails on the percentage alone.

Three mutations, each caught by the assertion written for it:

| mutation | result |
|---|---|
| the positioned and unpositioned figures SWAPPED (M24's review's exact shape) | 69, **2 failures**, one per row |
| the share changed to `12.5%` while the other three stay right | 69, **1 failure**, the share row |
| a row deleted | **64, 2 failures** — the row census names `unpositioned` and the abnormal-exit trap turns the `die` into a reported failure rather than a smaller check |

Measured green: `§6 should read 516 / 389 / 127 / 24.6%`, and the document says exactly that.

## 8. The impl agent's two rewritten mutation arms, read rather than taken on trust

- **M2's first form measured nothing and the script says so in its own comment.** It passed
  `count - 1` as `drainSteps`' `total`, which bounds the LOOP; with a 4,096-record batch and 516
  records there is one iteration either way. The replacement is
  `steps: drained.steps.slice(0, -1)` in `executed_steps.ts` — it drops a record from what the host
  DECODED, which is what `count !== steps.length` inside `recordAndDownload` refuses on, and the
  diagnostic quotes the producer's own precondition.
- **M5's first form did not hang.** An `await` on a promise nothing settles is collected by V8 and
  CDP answers `Promise was collected` in seconds — M24's review's "a mutation that crashes has not
  exercised the assertion it was written for", reproduced. The replacement is
  `while (true) { }` before `runNativeParity` in the demo page, which blocks the RENDERER, so
  `Runtime.evaluate` never answers and the arm-run timeout is what ends it. That is the state
  M23's review named as worse than red — a check that reports nothing at all — and it is the one
  the bound exists for.

Both replacements break something the assertion under test can see, and both are recorded in the
script rather than swapped in quietly. **Both survive.**

## 9. The container-opcode scanner's refusals, exercised rather than read

`_m29_container_opcodes.py` claims "a name that never appears is a refusal rather than an empty
histogram". Driven directly against the real `ct-print --full` document with three corruptions:

```
baseline  : rc 0   0<TAB>113, 2<TAB>1, …
renamed   : rc 4   no VariableName record names 'opcode'
no Steps  : rc 5   the 'opcode' variable was named but no Step carried a value for it
no events : rc 3   the reader's output has no 'events' array
```

Three distinct refusals, none of them an empty histogram that would compare equal to another empty
one. And the check's `CONTAINER_TOTAL == REC_EVENTS` assertion means a scanner that found SOME
opcodes but not all of them fails too. **Survives.**

## 10. M28's review's timing recommendation — DECLINED, and the reason is measured

M28's review recommended that `test_observer_disabled_is_free`'s timing arm "refuse when its
control arm's spread exceeds the budget rather than emit a red that reads as a regression". Read
against the check and `verification/wasm_host/_timing_compare.py`, that recommendation is **already
implemented, and the version in the tree is deliberately stronger than the one proposed**:

- The same-bytes control IS a precondition with its own exit code (4), documented at length: "if the
  method cannot call two copies of the same bytes equivalent within the budget, it has been shown —
  by its own evidence, on this run — to be incapable of resolving a difference at this scale."
- And it is **conditional on there being nothing else to report**, which is M15's own correction to
  itself, made after measuring the failure mode the plain form has: *"a table carrying a real +30%
  regression AND a control the machine had scattered used to return 4 with no rows … `just verify-m9`
  reports 4 as PRECONDITION UNMET, so a measured +30% came out as a non-red sweep."* Taking the
  recommendation literally would re-open that hole.

**And it does not apply to the condition it was written about.** M29's red is
`+1.29% CI [+0.52%, +2.05%]` against a `+2%` cost budget — a half-width of 0.765pp, well inside the
1.00pp the precision precondition requires, so the interval was sharp ENOUGH and exit 4 correctly
did not fire. The assertion that failed is `obs_hi <= budget` on the SUBJECT, by 0.05 percentage
points, on a loaded box. Nothing about the control was the cause. Declined, and recorded here rather
than left as an open suggestion for the next review to re-derive.

## 11. Verdict on what M27's product claim actually proved

`e2e_browser_downloads_ct_container_and_ct_print_parses` is the check M27 calls "the only test that
proves the actual product claim". Reconstructed and measured rather than argued:

**What it proved before M29.** That a headless Chromium ran a page, that the page produced a
well-formed 176,128-byte `.ct` whose sha256 matched the bytes it held, that the reference reader
parsed it and named four real Aztec.nr source files, and that the container carried two frames and
64 Step records at resolved source positions. **Every one of those is true, and every one of them is
also true of a transaction that executed exactly one instruction and reverted** — which is what the
transaction was doing. Reproduced directly: with M27's `token_transfer.ts` restored, the arm reports
`executed.count 1`, `op=68`, `outcome processed`, and a container of *exactly the size M27
recorded*.

So the product claim proved **the container, the writer, the reader and the source map** — the whole
chain from a browser to `ct-print` — over a *subject that had not run*. The 64 steps were the
artifact's mapped pcs and the opcodes were `(pc % 200) + 1`, so nothing in the container was a
function of the execution and nothing in the check could be. It was a proof about the plumbing
presented as a proof about a recording. **M29's finding is right, and it is the more damning reading
of the two**: not "the opcodes were fabricated" but "there was nothing to fabricate them from".

**What it proves now.** The same chain over 516 instructions the AVM really executed, with a real
opcode mix, real pc revisits and real backward jumps, and — after this review — over a transaction
asserted not to have reverted. The two assertions M29 retired really could not fail, for two
independent reasons; the five that replaced them can.

**And the same defect was still open in M29 itself**, one level up: M29 knew the transaction had
been doing nothing, fixed four causes of it, and left every floor it added satisfiable by a
transaction that runs 471 instructions and reverts. That is what §3b now closes.

## 12. Claims that did not survive

| # | claim | verdict |
|---|---|---|
| 1 | "the rule's absence is asserted … over the BUILT BUNDLE" | **OVERTURNED.** The needle carried a space the minifier removes; green over a bundle carrying the rule in two files. Fixed, with the needle derived by minifying through the build's own esbuild |
| 2 | "the exclusion list is EMPTY … a measurement rather than a convenience" | **OVERTURNED as an assertion.** It was `len(sys.argv[3:])` of an invocation passing no arguments. The list really is empty and nothing really diverges — `leftResidue 0 / rightResidue 0 / mismatches 0` over 38,903 records — but the ASSERTION could not fail. Fixed |
| 3 | "`patchFieldsFor` … asserts at run time that what it produced has exactly those keys" | **OVERTURNED.** `Object.keys(X)` compared with `Object.keys(X)`; the `throw` was unreachable. The property holds by construction; the check is over the caller's keys now |
| 4 | "M29 closed the gap M27 disclosed" (implicitly, that the milestone would notice its recurrence) | **OVERTURNED.** 105 of 105 green over a demo transaction that reverts. Fixed |
| 5 | `SOURCE-MAPPING.md` §6's 516 / 389 / 127 / 24.6% | **UNPINNED, now pinned.** Re-derived by nothing, in a document two checks already open, about a hole that closes when upstream re-keys `brillig_procedure_locs` |
| 6 | M28's review's recommendation that M9's timing arm refuse on a wide control | **DECLINED.** Already implemented and deliberately stronger; taking it as stated would re-open the hole M15 measured and closed, and it does not apply to the condition it was written about |

Claims that SURVIVED, each re-measured rather than accepted: `verify-m29` = 105 (52/30/23) at the
delivered tree; the executed-vs-mapped discriminator in both directions with both conjuncts firing;
the container histogram identity through the pinned reader; the 38,903-record differential with an
empty exclusion list and zero residue on both sides; the one-line cause and the absence of a second
instance of it; the deletion of the synthesised path from `browser/`; M27 = 345 with the three
retired assertions genuinely unfailable; M21 = 325; M25 = 272; the two rewritten mutation arms.

## 13. THE SWEEP — M0–M29, taken after the last commit

`setsid`-detached, `direnv exec <aztec-avm-runtime>` (this repository's own dev shell, not the
workspace root's), `TMPDIR` and the log under `~/.cache`, one milestone at a time with nothing else
running, **no hole in the log**, 30 start markers and 30 `rc=` markers.

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127
                                                       CAMPAIGN TOTAL 10,178
```

**28 of 30 exit 0.** The summariser (a review copy of `m29-sweep-sum.py` whose reference table
carries m29 = 127, so it reports a delta rather than agreeing with a number that has moved) read the
sweep at **9,895 with m9 at 524**; `10,178 - 9,895 = 283 = 140 + 143`, the two comparers that
correctly refuse and print no summary line while doing it. **Every milestone but m9 came out at its
reference value TO THE ASSERTION**, m29's own 127 included.

**M9 flaked and passed alone, which is the settled procedure.** In the sweep: 524, rc 1, 15 failing
assertions. Re-run alone: **807, 7 of 7, exit 0**, split
**140 / 143 / 113 / 73 / 126 / 83 / 129** — the reference exactly. Two things about the flake are
NEW and are in `DRIFT.md` D19 now rather than only here:

- **a fifth truncation point, and it is a quarter the length of the shortest before it** —
  `truncated-after-3943-lines-last-key-steps.burn.3669`, against a previous minimum of 14,572. The
  five are 39,113 / 16,719 / 14,572 / 17,866 / 3,943, same input, same module, same host. A
  truncation that lands at 10% of the transcript and at 99.995% of it is not a buffer filling at a
  size.
- **a SECOND transcript truncated in the same run** — the fallback EVENT stream, at
  `events.burn.15101` after 15,306 lines. Every earlier sighting is of the STEP transcript. That is
  evidence for the shared WASI `fd_write` path under V8 and against anything specific to the step
  encoder, and it is why this flake reads **15 failing assertions rather than the recorded 12**:
  `test_existing_event_emitter_path_still_available` has a completeness assertion on that second
  transcript and correctly reports 4 rather than 1.

**And `test_observer_disabled_is_free` came out 126 / 0 IN the flaking sweep**, on a box that had
been running headless browsers and wasm builds all session — so M29's `+1.29% CI [+0.52%, +2.05%]`
red did not reproduce. Two independent measurements now say that red was the machine.

**M11 went red for the ninth upstream move and nothing else.** 259 with **nine** failing assertions
and the count unchanged, `7471a61f1a92f5b2f474db714f34430253892d99` — the recorded signature, with
the `barretenberg/cpp` conjunct failing, which is the seventh move's known open class. **Upstream
did not move a tenth time during this review**, which is worth stating because it has moved during
four of the last five. `carry/` is left at HEAD rather than half-repaired, and
`carry/rebase.json` / `carry/exposure.json` — which `verify-m11` rewrites on every run, so a sweep
is itself a writer — were checksummed before and restored after (`aaeb6877…`, `ec959b84…`).

## 14. The two rewritten mutation arms, RUN rather than read

Both re-run by this review after the sweep, into a work directory of my own:

```
=== M2 — THE DRAIN LOSES THE LAST RECORD
  test_browser_steps_are_executed_not_mapped       rc=1  0 assertion(s), 1 failure(s)
  test_trace_step_count_matches_instruction_count  rc=1  0 assertion(s), 1 failure(s)
  diagnostic: ExecutedStepsUnavailable: … the module counted 516 step(s) and the drain decoded 515

=== M5 — THE HANG
  e2e_browser_container_opcodes_match_native       rc=1  0 assertion(s), 1 failure(s)
  diagnostic: Runtime.evaluate did not complete within 60000 ms. That is the HANG state reported
              as a failure.
```

M2 is caught by the producer's own count-versus-decoded precondition, quoted by name — the assertion
the arm exists for. M5 really does block the renderer: the CDP evaluate timed out at its bound
rather than returning `Promise was collected` in seconds. **Both fire for the right reason**, and
the abnormal-exit trap turns each `die` into a reported failure rather than a smaller milestone. The
harness restored all five files byte-identically and its restore-control (a one-line corruption of a
copy) was reported, so the tree the sweep measured is the tree that is committed.
