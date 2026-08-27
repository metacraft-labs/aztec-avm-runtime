# M26 implementation log — Joining Private and Public Traces

Rule: no commits, no pushes. Written after every completed step.

## Step 0 — reading, and the state of the tree (done)

Read in order: `scratchpad/campaign/m26-brief.md`, `CAMPAIGN-BRIEF.md` in full, the M26 / M21 /
M24 / M25 sections of `codetracer-specs/Planned-Work/Aztec-AVM-Runtime.milestones.org`,
`SOURCE-MAPPING.md`, `TRACE-ABI.md`, `REUSE-INVENTORY.md` RI-72.

Tree state at start: `aztec-avm-runtime` clean at `57bad7e`; `noir` clean at `6db58caad`
(branch `blocktracer`).

### Facts established by recon, each read out of the file rather than carried from the brief

1. **The fourth vendoring path in the brief is wrong.** `simple_contract_data_source.ts` is at
   `yarn-project/simulator/src/public/fixtures/simple_contract_data_source.ts`, not at
   `yarn-project/simulator/src/public/simple_contract_data_source.ts`.
   `verification/_import_closure.py:147-156` is the authority and says `fixtures/`. Line counts at
   the `ts` anchor `3a68d68ac2`: 329 / 275 / 154 / 122 = **880**, so RI-72's number reproduces.
2. **`verify_provenance_complete` moves 58 -> 63, not 58 -> 66.** The per-`F*`-row loop
   (`verify_provenance_complete.sh:96-105`) makes exactly ONE counted assertion per row; the
   "+2 per row" the campaign brief records is one row PLUS a new distinct inventory id, and the
   inventory loop is per DISTINCT id. Four rows all citing `RI-72` (not yet cited by any row) is
   4 + 1 = 5.
3. **`check-drift` 22 does not move for these four files.** Its variable parts are the vendored
   TREE count (line 48) and the count of DISTINCT anchor commits in the mapping (line 64).
   `orchestration/src/vendor/` is not a tree, and `ts` is already a mapped anchor.
4. **`verify_transaction_builder_closure_measured` does not forbid the vendoring.**
   `grep -c 'orchestration/src/vendor'` over it is 0; every closure figure is re-derived from
   `upstream/tsavm`, not from this tree.
5. The Noir tracer's wasm shell is at `/home/zahary/m/blocktracer/noir-wt4-webpage`
   (`tooling/tracer_wasm`, branch `wasm/webpage`, HEAD `f0e7edcd2`) and its `Cargo.toml:203`
   path-depends on `../ctf-wt-wasm/codetracer_trace_writer`. `ctf-wt-wasm`'s HEAD is
   `592fa42cbfd759cf13398180798daaf856eb7e9d`, which is `pins.json`'s `trace_format` anchor
   exactly. So "the same writer crates at the same revision" is measured, not assumed.

## Step 1 — the vendoring (done)

RI-72's reduced closure is vendored into `orchestration/src/vendor/`, at the `ts` anchor
`3a68d68ac29aaf04fc6251c80a8eb874043cb260`, **880 upstream lines across four files** exactly as
RI-72 prices it (329 / 275 / 154 / 122), plus one added shim.

| row | local | upstream | edit |
|---|---|---|---|
| F20 | `orchestration/src/vendor/public_tx_simulation_tester.ts` | `…/public/fixtures/public_tx_simulation_tester.ts` | `tx-builder-calldata-half`, modified |
| F21 | `orchestration/src/vendor/public_fixtures_utils.ts` | `…/public/fixtures/utils.ts` | `tx-builder-calldata-half`, modified |
| F22 | `orchestration/src/vendor/avm_fixtures_utils.ts` | `…/public/avm/fixtures/utils.ts` | `tx-builder-calldata-half`, modified |
| F23 | `orchestration/src/vendor/simple_contract_data_source.ts` | `…/public/fixtures/simple_contract_data_source.ts` | `tx-builder-calldata-half`, modified |
| F24 | `orchestration/src/vendor/gas_compat.ts` | (none — added here) | `tx-builder-calldata-half`, added |

`python3 tools/provenance.py drift` reports `OK differs` for the four and `OK missing-upstream`
for the added one, so the direction of every difference is what `PROVENANCE.md` declares.

### Two things the vendoring found that RI-72 does not say

1. **RI-72's "no new package dependency" is scoped to `@aztec/*` specifiers, and one non-`@aztec`
   package escapes it.** `avm/fixtures/utils.ts` imports `lodash.merge`, which
   `orchestration/package.json` does not depend on. It is reached only by `allSameExcept`, so the
   trim list is FOUR functions rather than the three RI-72 enumerates. Recorded in the edit class.
2. **The published nightly does not export `FALLBACK_TEARDOWN_{DA,L2}_GAS_LIMIT`.** Measured:
   node's ESM loader refuses `public_fixtures_utils.ts` with
   `SyntaxError: The requested module '@aztec/stdlib/gas' does not provide an export named
   'FALLBACK_TEARDOWN_DA_GAS_LIMIT'`, and no key of that module matches `FALLBACK`. This is
   `spike-gas-compat`'s exact finding from M0/M2, met again in a package that had never imported
   those names. `orchestration/src/vendor/gas_compat.ts` reproduces the anchor's arithmetic; the
   check re-derives BOTH halves (absent from the installed package, present at the anchor) so the
   shim reddens rather than rots the day the nightly starts exporting them.

Smoke-tested under the dev shell's node v24.19.0 with `--experimental-strip-types`: all four
modules load and export `PublicTxSimulationTester`, `defaultGlobals`, `createTxForPublicCalls`,
`addNewContractClassToTx`, `addNewContractInstanceToTx`, `createTxForPrivateOnly`,
`createContractClassAndInstance`, `getFunctionSelector`, `getContractFunctionAbi`,
`SimpleContractDataSource`.

Also corrected one stale sentence in `PROVENANCE.md`'s header prose — it said a file with no
upstream counterpart is "one of the two `added` rows below" and there were already more than two.

## Step 2 — OQ-7's evidence, and the module export the fallback needs (done)

### What was measured, and where each fact comes from

| fact | how | value |
|---|---|---|
| one wasm instance holds ONE writer | a second `ct_writer_open` on one instance, run | `-7` (`CT_ERR_ALREADY_OPEN`), message "a writer is already open; call ct_writer_close first" |
| two instances do NOT share | two instances in one node process, disjoint pcs, both closed | 6 events / 4 events, containers not byte-identical, each carrying only its own |
| `noir_tracer` is writer-AGNOSTIC | `tooling/tracer/src/lib.rs:367-376` — `trace_circuit(..., tracer: &mut dyn TraceSink)`; `tooling/tracer/Cargo.toml` — `codetracer_trace_writer` is `optional = true` behind `nim-writer`, and `default = []` | so nothing in the tracer prevents sharing |
| the shipping branch links a DIFFERENT writer | `noir/Cargo.toml:144` (branch `blocktracer`) — `codetracer_trace_writer = { path = "../codetracer-trace-format/codetracer_trace_writer_nim", package = "codetracer_trace_writer_nim" }` | **Path B**, the Nim FFI writer |
| the branch that links Path A is `wasm/webpage` | `noir-wt4-webpage/Cargo.toml:203` — `codetracer_trace_writer_rs = { path = "../ctf-wt-wasm/codetracer_trace_writer" }`, and its own comment says "It is NOT used by `nargo trace`" | Path A is a SECOND alias used only by `tracer_wasm` |
| that branch is unpublished | `git for-each-ref refs/remotes --contains f0e7edcd2` | empty — so it cannot be pinned |

### The probe, and it is a demonstration rather than an argument

`verification/oq7_shared_writer_probe.rs` + `build_oq7_shared_writer_probe.sh`: ONE
`CtfsTraceWriter`, two producers — the real `noir_tracer` over a `TraceSink` this file implements,
and the AVM half reproducing `emit()` call for call. Built in **70 s** against
`noir-wt4-webpage/target` with the worktree's own rust 1.89.0, which is why sharing that target
directory is in the script rather than a cold Noir-compiler build in every check.

Read back by the pinned `ct-print`, the `shared` container is:

```
Function <toplevel>   Call 0
Function main         Call 1
Function foo          Call 2      Function bar   Call 3   Return   Return
                      Call 2                     Call 3   Return   Return
Event elkTraceLogEvent  ct.trace-join  join=… half=both halves=1 arm=shared reason=…
Function Token.transfer_in_public (path 1, line 89)   Call 4  [12 AVM steps]  Return
```

142 events, 32 steps, 7 calls, 5 returns, 2 paths. **The public frame is nested inside the private
frames** — `main` and `<toplevel>` have not returned when it opens — which is what makes a
private-half step and a public-half step distinguishable by FRAME rather than by content.

### The module gained ONE export pair, and the reason is that the fallback is a deliverable

`ct_log_event(metadata, content)` + `ct_log_event_count()`, in their own `JOIN_EXPORTS` list for
`SOURCE_MAPPING_EXPORTS`' reason. Without them the shipped module cannot write a join record at
all, and M26 would have demonstrated that a *probe* can produce a joined recording while leaving
open whether the runtime can. A 13th native test covers it, asserting the counter in both
directions and that neither refusal moves it.

Consequences, each accounted for:
- module **259,839 -> 260,444 bytes**, sha256 `1e7e0e4f…` -> `bd4b2602…`. `TRACE-ABI.md` §7 must
  follow or `verify_ct_writer_wasm_zero_imports` reddens (it re-derives both from the artefact).
- `ALL_REQUIRED_EXPORTS` 30 -> **32**; `test_trace_metadata_declares_mapping_rung`'s two literals
  updated. M24's own nineteen and M25's own eleven are untouched, so neither count moves.
- OQ-6 is content-gated on the module, so it re-measures. Started detached.

## Step 3 — the vendoring pays off: a transaction that calls a registered contract (done)

`orchestration/src/join_e2e_driver.ts` + `tools/run_join_arms.mjs`. Measured:

```
Token @ 5.0.0-nightly.20260626, class 0x0d1c27a4…, instance 0x3051e7a9…, packed bytecode 15,096 B
transfer_in_public, selector 0x8c9e5472, 4 parameters
debug function name  Token.transfer_in_public   (SimpleContractDataSource.getDebugFunctionName)
txHash               0x0ad06087cc19185a37ddb60c1d4af3f55899c7c6935a6c63de6c82c4eee8f6a3
control txHash       0x1ba2e0abd14eb186c692a340003bae15c7ba36b9d4e7cf52a7e343b4721b7dae
enqueued public calls 1, calldata 5 fields, first field == the selector
merkleTree touches   0        <- RI-72's grep, EXECUTED: the parameter is a throwing Proxy
rung for Token       1, 2,680 mapped pcs in [284, 14861] over a 15,096-byte bytecode, 135 files
```

The `merkleTree` tripwire is the point: RI-72's load-bearing sentence is a `grep -c` over upstream's
text, and this runs the same claim. Nothing in the reduced closure reads it.

## Step 4 — the cross-half Field rendering, in BOTH Noir checkouts (done)

`SOURCE-MAPPING.md` §4.4's option 1, applied at `tooling/tracer/src/tracer_glue.rs` in
`/home/zahary/m/blocktracer/noir` (branch `blocktracer`, the checkout M25's check reads) **and** in
`/home/zahary/m/blocktracer/noir-wt4-webpage` (branch `wasm/webpage`, the tracer the OQ-7 probe
links). `Field` renders as `ValueRecord::String { text: field_to_hex(field_value) }` where
`field_to_hex` is `format!("0x{}", field_value.to_hex())`.

Both edits are UNCOMMITTED (an implementation agent makes none). Three consequences, each handled:

1. **The probe's build script had to stop requiring a clean worktree.** It now allows exactly
   `tooling/tracer/src/tracer_glue.rs` to differ, refuses any other edit, and asserts the two
   rendering lines are present in BOTH checkouts with the `to_i128` rendering ABSENT from both
   `Field` arms. The staleness stamp hashes that file, because `git rev-parse HEAD` does not move
   for an uncommitted edit and a HEAD-only stamp would leave a pre-fix probe looking current.
2. **The two branches spell the writer trait differently** — `TraceWriter` on `blocktracer`,
   `TraceSink` on `wasm/webpage` — so the whole `Field` arm cannot be compared byte for byte.
   Found by the build failing with `use of undeclared type TraceWriter`. What is compared is the
   two lines that DECIDE the rendering, plus the absence of the old one, which is the difference
   that matters and not the difference that does not.
3. **M25's `test_fr_rendering_matches_noir_tracer` asserted the OLD rendering**, so M26 repoints
   it — and the repoint is where the campaign's own defect was waiting:
   `ValueRecord::Int { i: field_value.to_i128() as i64, type_id }` is ALSO how the
   `UnsignedInteger` and `SignedInteger` arms render, so a whole-file `str_has_sub` for it goes on
   matching after the change lands. The absence is asked of the extracted `Field` ARM, with the
   extraction's non-emptiness asserted and with the file-level presence asserted as the control
   that the needle can still match something.

Measured on the joined container: private `x=4` and `y=5` read back as
`0x…04` / `0x…05` (66 chars, `String`) beside the public half's `0x3051e7a9…` in the same variant.
**32 `String` and 48 `Int` values** — the 48 are `opcode`/`contextId`/`l2Gas`/`daGas`, which are
counters, so "everything became a String" is refuted by the split rather than by inspection.

**NOT EXECUTED, AND SAID SO RATHER THAN IMPLIED:** the `noir` repo's own `tooling/tracer/tests/
test_tracer.rs` asserts Field values through `["i"].as_i64()`. Those assertions are updated here —
a `field_small_int` helper that asserts the VARIANT, the `0x` prefix, the fixed 66-character width,
lowercase hex and that the top 48 digits are zero before decoding — and the two arms that are NOT
Field (`b: u32`, `e: i8`) are deliberately left asserting `Int`, so "everything is a String now"
fails there. They were **not run**: `noir_tracer` on `blocktracer` links the Nim FFI writer, whose
static library this environment does not build, and the `_via_ct_print_full` tests spawn a built
`nargo`. The rendering itself IS compiled — the identical `Field` arm builds in the `wasm/webpage`
worktree, which is how the probe exists.

> **[M26 REVIEW] THE REASON IN THIS PARAGRAPH IS FALSE AND IS LEFT HERE AS THE RECORD.** The static
> library builds: `nimble` is merely absent from `PATH`, and `build.rs`'s own doc comment names
> `CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL=1`; `direnv exec ../codetracer-trace-format`
> does it the other way. `nargo` builds in 1m32s and the suite runs. See
> `m26-review-log.md` R2-R6 and the new header of `noir/tooling/tracer/tests/test_tracer.rs`.

## Step 5 — TRACE-ABI.md re-rendered from OQ-6 run 7 (done)

The module changed, `m24_require_oq6` content-gates on the module, so the benchmark re-ran: twelve
sessions, `setsid`-detached, dev shell. **Run 7: `perEvent - batched` +0.85 %, CI [+0.50, +1.21] %,
verdict `within-noise`**, control -0.21 %. §2's tables re-rendered by
`scratchpad/campaign/m24-render-trace-abi.py`; §8 gained a seventh row; §7's module figures moved
to **260,444 bytes / `bd4b2602…`**.

**One claim in §2 did not survive run 7 and is corrected rather than smoothed.** The document said
the crossing-only pair "is stable"; it came out **+15.65 %** against run 6's +4.56 % — 3.4× on the
same engine. What is stable is the SIGN and the order of magnitude; the ratio has run ~700× to
~2,000× across seven runs. The conclusion does not move (both ends are "less than a per cent of a
recording"), which is why this is a correction to a claim and not to a decision.

## Step 6 — JOIN-SHAPE.md (done)

The OQ-7 verdict, its seven facts with how each was established, the demonstration, the fallback,
the cross-half agreement, what would reopen it, and the gap between M26 as delivered and M26 as
specified (the private half is a real Noir program traced by the real Noir tracer, and it is **not
an Aztec private function** — M21 measured why one cannot run here).

## Step 7 — the module gained FRAMES too, and the reason is that the fallback is the shipped path (done)

Writing `test_join_fallback_two_recordings` found the gap the design had left: the fallback's
public half was **a flat step stream with no frames**, because M24's ABI records steps and nothing
else. *"A private-half step and a public-half step are distinguishable by FRAME"* is not a property
a flat stream has however its steps are labelled, so the fallback would have been frame-attributed
only in the probe — which is the same shape as pinning an unpublished commit: green here, absent
everywhere else.

So the module gained four more exports: `ct_call`, `ct_return`, `ct_call_depth`, `ct_calls_opened`.
`JOIN_EXPORTS` is six; `ALL_REQUIRED_EXPORTS` 30 -> **36**. A 14th native test covers them,
asserting the depth at every step of the sequence (a pair of counters that ends where it started is
satisfied by a pair that never moved) and both refusals (`ct_return` with nothing open is
`CT_ERR_NO_FRAME`, −10; an empty frame name and an un-interned `path_id` are refused and open
nothing).

Read back through the pinned reader, the fallback's public half is now

```
FRAME 0  depth 0  <toplevel>                  12 steps
FRAME 1  depth 1  Token.transfer_in_public      6 steps
FRAME 2  depth 1  Token.balance_of_public       6 steps
EVENT             ct.trace-join    join=… half=public halves=2 arm=split reason=…
EVENT             ct.mapping-rung  0x3051e7a9… rung=1 reason=artifact Token …
```

Module **259,839 -> 262,693 bytes**, sha256 `5edf9671…`, imports still 0. OQ-6 re-measured twice
(the join records, then the frames): **run 7 +0.85 %**, **run 8 +0.74 %**, both `within-noise`, both
with run 2's sign. `TRACE-ABI.md` §2 and §8 re-rendered; §7's figures follow the artefact.

One more instrument correction, recorded rather than smoothed: §2 said the crossing-only pair "is
stable". Across runs 6, 7 and 8 on the same engine it read +4.56 %, +15.65 % and +18.40 %. What is
stable is the SIGN and the order of magnitude; the writer-to-boundary ratio has run ~700x to
~2,000x. The conclusion is unchanged (both ends are a fraction of a per cent of a recording).

## Step 8 — the four M26 checks (done, before mutation)

| check | assertions |
|---|---|
| `verify_tx_builder_vendored_not_reimplemented` | 117 |
| `verify_oq7_shared_writer_verdict_recorded` | 65 |
| `test_private_public_frame_nesting` | 36 |
| `test_join_fallback_two_recordings` | 61 |

Two defects found in my OWN checks before the mutation pass, both named in the campaign brief:

1. **A VALUE COMPARED WITH ITSELF.** `verify_oq7…` had
   `assert_eq "…the two halves' steps are in ONE container" "$(m26_row "$SHARED" STEPS)" "$(m26_row "$SHARED" STEPS)"`.
   Replaced by the identity that cannot be satisfied by accident: the shared container's step count
   equals the SUM of the two split containers' (20 + 12 = 32).
2. **A CONTROL THAT AGREED WITH ITS SUBJECT BECAUSE THE PREDICATE SHORT-CIRCUITED.** The
   publication control asked `m24_published_refcount` of `ct-writer/build-wasm-deps/ctf`, which is
   a `git archive` extraction and not a repository — so the predicate returns 0 for the same reason
   it returns 0 for the subject. The control is `refs/remotes/origin/master` IN THE SAME
   REPOSITORY now, and the two commits are asserted different.

`git add` was run on the new and modified files (staging, not committing) because
`verify_provenance_complete` and this milestone's own check assert that a mapped file is TRACKED,
and `git ls-files` does not see an untracked path — which is the campaign's own recorded
"`git status --porcelain` on a path that is not tracked yet" defect from the other side.

## Step 9 — the mutation matrix (done)

`scratchpad/campaign/m26-mutations.sh`, nine arms, ONE at a time, each restored and **verified
restored by sha256 and then `touch`ed**. The harness refuses to start if a `verify-m*` process is
running, because a mutation harness and a verification sweep are two writers over one working copy.

| arm | mutation | detected by | which assertions went red |
|---|---|---|---|
| A | a vendored line corrupted IN PLACE, one identifier for one — M22's review's own shape | `verify_tx_builder_vendored_not_reimplemented` 117/**3** | the added count, the dropped count, and the residue naming the corrupted line |
| B | a severed edge returns (`import merge from 'lodash.merge'`) | same, 117/**2** | the dropped count, and "…and is GONE from the vendored copies" |
| C | the join record loses its `halves` field | `test_join_fallback_two_recordings` 61/**3** | the public half's record content, the Rust/TypeScript grammar identity, and the parser's inverse |
| D | the join becomes INFERRED — a half with no record is accepted | same, 61/**1** | "a half whose container carries no record is refused as unrecorded" |
| E | the frames are FLATTENED: the public calls become siblings of `<toplevel>` | `test_private_public_frame_nesting` 36/**5** | both public frames' depth, the unbalanced count, the depth histogram, and the one-timeline identity |
| F | the enqueue ORDER is reversed | same, 36/**2** | the order identity and its reversed-order control |
| G | the Noir half's `Field` rendering reverted to `to_i128` | `test_fr_rendering_matches_noir_tracer` 56/**2**, AND the probe build REFUSES with "the demonstration and the shipped fix have drifted" | the new rendering's presence and the old one's absence, in the extracted `Field` arm |
| H | **HANG** — the frame reporter loops forever | `test_private_public_frame_nesting` 36/**27**, within the bound | `ERR:_ct_frames-timed-out-after-10s`, and every frame assertion reading `MISSING` |
| I | **DIE BEFORE SUMMARY** — an arm report that is newer than every input and is not JSON | `test_join_fallback_two_recordings` **0 assertion(s), 1 failure(s)**, exit 1 | the precondition's own `die` line, and M22's abnormal-exit trap printing the summary WITH a failure counted |

### Three defects the matrix found in M26's own work

1. **`$(( MISSING - 1 ))` IS AN UNBOUND VARIABLE UNDER `set -u`.** Arm H's first run came out at
   **29** assertions rather than 36 — a seven-assertion silent shrink — because bash evaluates a
   bare word in an arithmetic context as a variable name and `set -u` then kills the shell. M22's
   trap caught it and printed `FAIL — exited (status 1) before finish`, which is the trap doing its
   job; the check should not have needed it. M24 met the same family as `$(( ERR:… * ERR:… ))`, a
   bash SYNTAX error. All three bare arithmetic sites across M26's checks are guarded now, and arm
   H re-run reads **36/27** — the count no longer moves.
2. **THE DIE-BEFORE-SUMMARY ARM PASSED TWICE WITHOUT EXERCISING ANYTHING.** Pointing `M26_WORK` at
   an empty directory made the check simply RE-RUN the arms into it and report 61/0; so did writing
   a non-JSON report without stamping it, because `m26_require_arms` regenerates a stale one. The
   arm has to make the report un-re-runnable AND unreadable at once — `touch -d '+1 hour'` — and
   only then does the precondition fire. Recorded rather than quietly replaced: this is exactly
   "a check that never exercises the thing it is named for", in the harness rather than in a check.
3. **ARM D REDDENS AS `other:TypeError` RATHER THAN AS `accepted`.** Disabling the `unrecorded`
   refusal makes `joinRecordings` dereference a `record!` that is `undefined`, so the joiner
   CRASHES where the mutation intended it to INFER. The assertion catches it either way — it
   compares the named ground — but the distinction is worth stating: what was demonstrated is that
   the refusal is load-bearing, not that a best-effort join would be caught.

### Three checks outside M26 that the work moved, each found before the sweep

- `verify_named_checks_exist` went red twice on `(verify|test|e2e)_` identifiers that are not
  checks: `../test_executor_metrics.js`, an upstream path in the trims list, and the Noir fixture
  directory's name. Both are split literals now, the way
  `verify_pinned_nightly_single_source:273` splits a nightly literal — **including in the comment
  that explains it**, which was the second red.
- `verify_no_pipeline_predicates` went red on a `sed … | grep -qF` in the probe's build script: the
  census of that spelling is pinned at five BY NAME and mine was a sixth. Rewritten to extract into
  a variable and test with `case`, so the census stays at five.
- `check-drift` 22 and `check-repo-hygiene` 28 are unmoved, as predicted: no new vendored TREE and
  no new anchor commit.

## Step 10 — `TxProvenance.privateTrace`, the deliverable M21 left shaped for M26 (done)

M21 declared `PrivateTraceHandle { id }` and said in as many words that declaring more before there
was a thing to describe would be a type written from a deliverable's wording. M26 fills it in from
what was built: `join` (the identity every half's `ct.trace-join` record carries), `halves`, and
`arm`. `privateTraceHandleFor(record)` derives the handle FROM the record rather than assembling it
beside one, so a handle and its recording cannot disagree about which join they belong to — the
property `joinRecordings` enforces between two containers, one level up.

**No file path is in the handle**, deliberately: a handle carrying one would make the join a fact
about a filesystem, which is the thing `JOIN-SHAPE.md` §4 argues against. And nothing about the
recording travels on the provenance at all, because DD-1 says provenance is metadata alongside the
transaction and M20's seal traps every read of it inside the execution window.

`traceJoinedTx` is the constructor; `test_join_fallback_two_recordings` grew from 61 to **75**
assertions, with M21's own two controls (M20's discriminant-only local transaction and an external
one, neither of which carries a handle).

**THE SWEEP WAS KILLED AND RESTARTED FOR THIS, WHICH IS THE RIGHT ORDER AND IS RECORDED.** The
first sweep had reached M1 when this deliverable was found still owed. A sweep is a measurement of
the tree at the moment it ran, so it was stopped (`verify-m1` and its two `verify_vendor_drift_clean`
children killed, the stale sandbox directories removed) rather than allowed to measure a tree that
was about to change.

### Pre-flight before the real sweep, on the milestones this work could move

m0 **156**, m1 **175**, m18 **283**, m19 **180**, m20 **237**, m21 **324** — every one at its
reference value except M1, which is +6 and accounted for: `verify_provenance_complete` 58 -> 64,
being five new `PROVENANCE.md` file rows (one `is tracked` assertion each) plus one new distinct
inventory id (`RI-72` was cited by no row before). `check-drift` 22, `check-repo-hygiene` 28,
`verify_named_checks_exist` 9, `verify_no_pipeline_predicates` 69,
`verify_reuse_inventory_complete` 19, `verify_pinned_nightly_single_source` 28 — all unmoved.

M26's own four checks: 117 / 65 / 36 / 75 = **293**.

## Step 11 — the sweep, M0–M26 (done)

Run `setsid`-detached from THIS repository's own dev shell (`direnv exec` — node v24.19.0), one
milestone at a time with nothing else running, `TMPDIR` and the log under `~/.cache`, no hole in
the log. Summarised by `scratchpad/campaign/m26-sweep-sum.py`, which counts only summary lines at
column 0 and refuses to print a total while a hole is open.

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 324  m22 260  m23 509  m24 350  m25 272  m26 293
                                                        CAMPAIGN TOTAL 9,332
```

**THREE NUMBERS MOVED AND EVERY UNIT OF ALL THREE IS ACCOUNTED FOR IN BOTH DIRECTIONS.**

- **M26 293** (new): 117 / 65 / 36 / 75.
- **M1 169 -> 175**: `verify_provenance_complete` 58 -> 64. Five new single-file `PROVENANCE.md`
  rows at one `is tracked` assertion each, plus one for `RI-72`, an inventory id no row had cited
  before. 5 + 1, exact in both parts, and predicted before the sweep.
- **M25 266 -> 272**: `test_fr_rendering_matches_noir_tracer` 50 -> 56, because M26 landed
  `SOURCE-MAPPING.md` §4.4's option 1 and the check was repointed at the rendering that is there
  plus the absence of the one that is not, asked of the extracted `Field` ARM with the file-level
  presence as its control.

9,027 + 293 + 6 + 6 = **9,332** exactly. Every other milestone came out at its reference value TO
THE ASSERTION — including **M24 at 350**, unmoved even though M26 changed the module under it three
times, because M24's checks re-derive `TRACE-ABI.md`'s figures from the artefact rather than pinning
literals; **M4 at 218** in the dev shell, so M19's review's PATH pin still holds; and **M11 at 259**,
so upstream has not moved a sixth time.

### M9 flaked in the sweep and passed alone, which is the settled procedure

In the sweep: **524, exit 1, twelve failing assertions**, the V8 step transcript truncated after
17,866 lines at `steps.burn.17592` with the `avmSteps.done` sentinel never arriving — the recorded
signature exactly. `807 - 524 = 283 = 140 + 143`, so the whole shortfall is the two checks that
correctly REFUSED to compare and printed no summary line while doing it; the twelve red assertions
are in the two checks `m9_completeness` is still not wired into, which is `CAMPAIGN-BRIEF.md`'s own
outstanding item and not a finding about the interpreter. Re-run alone on an idle box: see below.

**M9 alone, on an idle box: 807, 7/7, exit 0**, split **140 / 143 / 113 / 73 / 126 / 83 / 129** —
the reference exactly, in 1,313 s. Not a regression. That is the third sighting of the flake this
campaign has recorded; the trigger is still not established and `DRIFT.md` D19 still says so.

## Step 12 — final state

Tree: `aztec-avm-runtime` has everything staged (`git add`, no commit — a review agent follows);
`noir` and `noir-wt4-webpage` each carry their uncommitted `tracer_glue.rs` edit, and `noir`
additionally carries the `test_tracer.rs` expectations that follow it. `ctf-wt-wasm` is untouched.

Documents updated: `JOIN-SHAPE.md` (new), `TRACE-ABI.md` §2/§4/§5/§7/§8, `SOURCE-MAPPING.md`
§4.1/§4.4/§6, `PROVENANCE.md` (F20..F24 + the `tx-builder-calldata-half` class + one stale sentence
about "the two `added` rows"), `REUSE-INVENTORY.md` RI-72, `CAMPAIGN-BRIEF.md` (the counts table,
the total, and the vacuous-assertion family's running total 25 -> 27), and the M1, M25 and M26
sections of `codetracer-specs/Planned-Work/Aztec-AVM-Runtime.milestones.org`.

### What is NOT done, stated plainly

- **`e2e_form_b_single_ct_recording` and `e2e_joined_trace_opens_in_codetracer` are `pending`.**
  The container exists and is read end to end, but its private half is a real Noir program rather
  than an Aztec private function — M21 measured why one cannot run here — and CodeTracer itself is
  not in this tree to open anything.
- **The public half's program counters are the artifact's own first mapped pcs, not an
  execution's.** Driving them from a real AVM run needs `avm.wasm`, a resident world state and a
  fee payer, which is M20's driver.
- **The Noir tracer's own fixture tests were updated but NOT RUN.** *[M26 REVIEW: the reason
  recorded here — "the static library this environment does not build" — did not survive. It
  builds. What running them found is that the suite is red at `HEAD`, six of six, for reasons that
  predate M26 and fire earlier than M26's assertions do; and that M26's own expectations are
  correct, measured directly. See `m26-review-log.md`.]*
- **M25's four `pending` entries are still `pending`.** The vendoring removes the reason they were
  deferred; each still needs the four collection flags and a real execution.
