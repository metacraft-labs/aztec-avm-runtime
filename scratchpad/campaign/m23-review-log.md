# M23 review log

Review agent for M23 (Chain Loop, Timer-Driven Empty Blocks, AvmRuntime Facade).
Implementation agent declared `partially_completed`. Verifying adversarially.

Started: session opened against a clean-ish tree — `aztec-avm-runtime` has M23's work
UNCOMMITTED (impl agents never commit), `codetracer-specs` has the milestone file modified.

## Plan
1. Read brief in full, M23/M22/M14 sections, impl log. [done: brief, M23 section]
2. Claim-by-claim verification (9 claims from the review brief).
3. Own mutations beyond the agent's 15.
4. Full M0-M23 sweep, after the last commit.

## Running notes

### Baseline reproduced (review's own run)
`just verify-m23` → **491 assertions, 14/14, exit 0**, split identical to the declared
60/68/35/35/35/49/44/18/21/18/40/15/27/26. 8.5 s with the arm run cached.

### Claim 2 — `test_block_seal_updates_archive` counted exactly once: HOLDS (structurally)
- `Justfile:verify-m22` runs exactly four checks and does NOT include it.
- `Justfile:verify-m23` runs fourteen, including it.
- Milestone file: M23 has **13** `- test_name:` entries (the seal is not among them); the seal is
  M22's entry, `status: passing`, `file:` → M23's check. So one entry, one milestone, one sweep
  bucket (M23's 491). M22's 260 = 71+44+89+56 over its own four.

### Claim 1 — genesis constants ARE upstream's, and the C++ side is not circular
- `orchestration/node_modules/@aztec/constants@5.0.0-nightly.20260626/dest/constants.gen.js`:
  `GENESIS_BLOCK_HEADER_HASH = 6551417544883665873456328017782433997345264442591862482015827744892259451090n`
  → `0x0e7bf88e8833c27b0fca6be614ecc2c63def7bffa35b3ccfa1caff3e39e0c0d2`
  `GENESIS_ARCHIVE_ROOT = 10619256997260439436842531499967995403253967496480475679746178797053672406517n`
  → `0x177a4955b31ecaafad999753938a44e526b54c5ba5d536688227f85f15cfbdf5`
  Both are the impl log's values exactly. `@aztec/stdlib/block` re-exports the first as a
  `BlockHash`. Both are npm artefacts, not ours.
- NOT circular: at the cpp anchor the C++ **computes** the leaf —
  `world_state.cpp:192` seeds the archive with `compute_initial_block_header_hash(...)`, declared at
  `world_state.hpp:348`. The two constants appear in C++ ONLY in `world_state.test.cpp:206,210`,
  i.e. upstream's own cross-language assertion, never in the production path. So the module's
  genesis root is hashed, not read back from a constants header.

### Claim 6 — TXE verdict: the VERDICT holds, three supporting facts do not
Re-derived at the cpp anchor `233d8e0993` (independently, and by a read-only sub-agent):

| sub-claim | measured | verdict |
|---|---|---|
| `yarn-project/txe/src/` = 41 files / 7,376 lines | 41 / 7,376 exactly | holds (the CHECK scopes to `src/`; the MILESTONE row does not say `src/` — whole pkg is 67 / 8,278) |
| ts anchor differs (35 files) | 35 files / 6,250 lines | holds |
| `@aztec/world-state/native` ×2 | 2 (`txe_oracle_top_level_context.ts:89`, `state_machine/synchronizer.ts:12`) | holds |
| `@aztec/aztec-node` ×1 | 1 (`state_machine/index.ts:1`) | holds |
| `@aztec/archiver` ×1 | 1 (`state_machine/archiver.ts:1`) | holds |
| `@aztec/bb-prover/test` ×1 | 1 (`state_machine/index.ts:2`) | holds |
| `@aztec/native` imported directly 0× | 0 | holds |
| `state_machine/` 6 files / 789 lines | exact | holds |
| `registerContractAndAddAccount` private, `deploy` not | both confirmed | holds |
| no in-process caller | only `yarn-project/aztec/src/cli/cmds/start_txe.ts:3` imports `@aztec/txe/server`, and it hands the object to `startHttpRpcServer` — an HTTP entry point, not an in-process driver | **verdict holds** |

**OVERTURNED — F1. "TXE never reads a wall clock for block time" IS FALSE.**
`yarn-project/txe/src/txe_session.ts:349`:
`const nextBlockTimestamp = BigInt(Math.floor(new Date().getTime() / 1000));`
Every TXE session SEEDS its block timestamp from the host wall clock; `advanceTimestampBy` only
moves it from there. The sentence is in `CHAIN-LOOP.md:140`, in the milestone's own deliverables
table ("the most useful thing in it is that it never reads a wall clock for block time"), and it
is the HEADING of a block of assertions in `verify_txe_reuse_verdict_recorded.sh:91`. The evidence
offered is three `grep -c` counts of `Date.now(` / `setInterval(` / `setTimeout(` — and the seed is
spelled `new Date().getTime()`, which none of them matches. **This is the campaign's own
"needles come from the artefact" defect, in the one section whose subject is wall-clock reads.**
The three counts themselves are right (4 / 1 / 0).

**OVERTURNED — F2. `@aztec/kv-store/lmdb-v2` is imported 3 times, not 6.**
`CHAIN-LOOP.md:114` says 6 in a bullet headed "Native dependencies, **by import**". Measured:
3 (`dispatcher_pool.ts:4`, `index.ts:3`, `txe_session.ts:6`). The other three are bare
`@aztec/kv-store` `import type` lines (`state_machine/archiver.ts:6`, `txe_session.ts:5`,
`utils/txe_account_store.ts:1`) — type-only, erased at compile time, and not lmdb-v2 at all. So
the figure doubles the native-binding surface. And the check is the one place that could have
caught it: four of the five counts are `assert_eq`, and lmdb-v2 alone is `assert_ge … 3`
(`verify_txe_reuse_verdict_recorded.sh:155`) — the loose one is exactly the wrong one.

**OVERTURNED — F3 (small). "three files under `yarn-project/aztec/` that start it".**
`CHAIN-LOOP.md:125`. Measured: `@aztec/txe` appears in exactly TWO paths outside `txe/` —
`yarn-project/aztec/package.json` and `yarn-project/aztec/src/cli/cmds/start_txe.ts`.
(`aztec_start_action.ts:73` reaches it by a relative dynamic import, so three .ts+json files only
if the package.json is counted as one that "starts it".)

### Claim 7 — both corrections HOLD
kv-store entry point: `npm.current` = `5.3.0-nightly.20260819` → `./deprecated/indexeddb`;
cpp anchor → `./deprecated/indexeddb`; `npm.deletion_era` = `5.0.0-nightly.20260626` →
`./indexeddb` (`./deprecated/indexeddb` absent); ts anchor → `./indexeddb`. `orchestration/` is on
`deletion_era` and installs no kv-store at all. Rename commit `ffb5fe64bc` confirmed
(author date 2026-06-29, ancestor of the cpp anchor, NOT of the ts anchor), and its package.json
diff is exactly the one-line export swap. `AztecNodeDebug`: 5 methods at the cpp anchor
(`aztec-node-debug.ts:25,38,48,58,66`), 3 in the installed `@aztec/stdlib@5.0.0-nightly.20260626`,
delta exactly `warpL2TimeAtLeastTo`/`warpL2TimeAtLeastBy`, added by `c6a6dbd8bb00`.
Side finding, NOT M23's: `pins.json` `npm.deletion_era.consumers` omits `probe-mt` while
`npm_consumers` puts `probe-mt` on `deletion_era`. Pre-existing (not in M23's diff).

### Claim 5 — §8.4 IS SUPPRESSIBLE. The strongest finding of this review.
`AvmRuntime`'s constructor is `private` — a TYPESCRIPT annotation, erased by Node's type stripping,
which is how this runtime actually runs (it imports `.ts` directly). Measured live:

    new AvmRuntime({}, {}, {simulated:false, protocolVersion:'NOT-PINNED', proving:'groth16',
                            line:'', disclosedAt:'never'})
    -> SUCCEEDED, zero lines written to any sink,
       runtime.disclosure == {"simulated":false,"protocolVersion":"NOT-PINNED","proving":"groth16",…}

So a caller obtains a working runtime with NO disclosure spoken AND a forged `disclosure` record —
and `runtime.disclosure` is the very object `test_receipt_declares_no_proving` treats as the
evidence that a disclosure was made. `create()` is not the only way to get an `AvmRuntime`, and the
check only ever goes through `create()`. Fix: the disclosure moves INTO the constructor, so every
route that produces an instance discloses, and the check gains the bypass route as an arm.

### Claims 3 and 3a — the mutation matrix

**The implementation's own fifteen were re-run and reproduce** (`scratchpad/campaign/m23-mutations.sh`
was not re-run wholesale; the two disputed rows were re-derived directly, below).

**Claim 3 — the two `0 / 1 / 1` rows DO NOT DISCRIMINATE, and the review replaced both.**
`test_timestamps_strictly_monotonic_subsecond` has, in PART 2, a block of assertions that exercise
`nextBlockTimestamp` DIRECTLY on a frozen clock (lines 127-136) — exactly the assertions a `min`
rule would fail. They never run, because `m23_require_arms` is called at line 38 and the mutated
rule kills the arm run first. Same shape for the automine row. So the reported red is the trap's,
not the check's, and the implementation says so — correctly — but leaves the claim unproven.
Replacements, measured by this review (`scratchpad/campaign/m23-review-mutations.sh`):

| replacement | result |
|---|---|
| **R1** the rule ignores the wall clock (`return floor`) instead of taking the max | `test_timestamps_strictly_monotonic_subsecond` **18 / 3 / 1** |
| **R2** `submit()` never seals (automine ignored) | `e2e_automine_seals_on_submission` **18 / 5 / 1** |

Both leave the arm run alive and both are killed by the check's OWN assertions. So the two claims
are now proven; the original two rows are demoted to "the trap works".

**Claim 3a — the review's own mutations, each run against the WHOLE milestone**
(the implementation's harness runs only the one target check, which is precisely how M22's review
found a mutation that passed a milestone green):

| mutation | whole-milestone result |
|---|---|
| **A1** `archiveSnapshot()` reads the NOTE_HASH tree instead of the archive | 19 failing assertions, **3/14 red** (empty-blocks, seal, fake-clock) |
| **A2** `updateArchive` swallows the module's refusal | 2 failing assertions, **1/14 red** (seal) — the refusal control is load-bearing |
| **A3** a planted `Date.now()` in `node-host/src` (the SECOND scanned root; the implementation only planted in `orchestration/src`) | 1 failing assertion, **1/14 red** |

### Further findings, read out of the checks

**F4 — "exercised, not read" does not survive.** M23's Implementation Details say of the replay
override: *"an override that does not advance the chain is refused, and that refusal is exercised
rather than read"*, and the snapshot entry repeats it (*"the override is still required to advance
the chain — exercised, not read"*). What
`e2e_chain_snapshot_export_import_roundtrip.sh:119-139` actually runs, under the heading "THAT
ENFORCEMENT IS RUN, not read", is the OPPOSITE case: a FIRST block, where the guard
(`this.produced.length > 0`) does not apply, being accepted. The probe's own comment concedes it
("the property is exercised through the guard directly"). The refusal itself is asserted only as a
source string (line 116-117). It IS exercisable — `lastTimestamp` and `produced` are
TypeScript-private and therefore erased at run time, the same erasure that made §8.4 suppressible.

**F5 — the arm run has NO TIMEOUT, and a defect in the chain HANGS the milestone instead of
reddening it.** Found by mutation A4 (`const number = 1` — every block numbered 1).
`armHundredBlocks` waits on a `block` subscription for `b.number >= 100`, which then never
resolves, and `m23_require_arms` runs `node tools/run_chain_arms.mjs` with no bound. Measured: the
arm run sat at 0 bytes of output indefinitely and had to be killed by hand; every one of the nine
arm-reading checks would do the same in turn. "A check that dies must read as a RED milestone and
not as a smaller one" is M21's review's lesson, and this is the third state — a check that neither
passes nor fails.

**F6 — a magic tree id, in the file whose own log records fixing exactly that.**
`orchestration/src/chain_e2e_driver.ts:534` reads the archive's first leaf with
`getLeafValue(4 /* ARCHIVE */ as never, 0n)`. `MerkleTreeId.ARCHIVE` IS 4, so the value is right —
but `MerkleTreeId` is already imported at line 25 and used at line 356 for precisely this reason
(defect 2 in the impl log: "A magic tree id, the exact shape of M22's seventh defect"). The same
file carries both the fix and the unfixed instance.

**F7 — a conditional block that drops four assertions silently.**
`test_block_seal_updates_archive.sh:176-192` wraps the source-side half of PART 4 in
`if [ -d "$M23_TREE/…/world_state_reference" ]` with a bare `note` in the `else`. The module can be
found at `$M23_WORK/avm.wasm` without the worktree beside it (`m23_find_module` accepts that path
first), in which case the check reports 40 rather than 44 and passes. A missing check reading as a
smaller milestone is the campaign's most dangerous shape.

**F8 — a label that describes four values and compares three.**
`test_empty_block_advances_number_and_archive.sh:137-138`: "genesis and the three archive roots are
all different values" is asserted over `GEN_ROOT`, `blocks.0.archiveAfter.root` and
`blocks.1.archiveAfter.root` — three values, expecting 3 distinct. Block 3's archive-after is not
in the set.

**F9 — M23 corrected a fact in M28's section and did not update it.** M28's Key Source Files
(milestones file line 9480) still reads "the browser store entry points, currently
`./deprecated/indexeddb` and `./sqlite-opfs`, correcting design-document §6.7 (M23)" — the
uncorrected single-spelling statement that M23's own table replaces. "A MILESTONE THAT MOVES
ANOTHER MILESTONE'S FACT MUST UPDATE THAT MILESTONE'S SECTION."

**F10 — an unmatched emphasis marker in M22's rewritten deliverable.** Milestones file line 8357
ends `See M23's =test_block_seal_updates_archive=.* The sealing PATH is upstream's…` — a stray `*`
closing an emphasis that was already closed.

**F11 — the milestone's TXE row omits the scope.** `CHAIN-LOOP.md:75-77` correctly says
`yarn-project/txe/src/` is 41 / 7,376 and that the whole package is 67 / 8,278; the milestone
file's table row says only "41 files / 7,376 lines VERIFIED exactly at the =cpp= anchor" beside the
name `yarn-project/txe/`.

### F12 — A MUTATION THAT PASSES THE WHOLE MILESTONE GREEN. The M22-review shape, reproduced.

**A5: `wallClockDeviationSeconds: timestamp - wallClockSeconds` → `0n`.**
Whole milestone: **491 assertions, 0 failing assertions, 0/14 checks RED, every check exit 0.**

The declared deviation is the milestone's own honesty field — *"a deviation field that lied would
be worse than none"* — and `test_timestamps_strictly_monotonic_subsecond.sh:80-93` checks the
identity per block. It checks it on the **`emptyBlocks`** arm, and on that arm the deviation is
identically zero:

    block 1 ts 1 wall 1 dev 0
    block 2 ts 2 wall 2 dev 0
    block 3 ts 3 wall 3 dev 0

`ManualDateProvider(0)` advanced one second per block makes `max(prev+1, floor(now/1000))` equal
the wall clock exactly, so the comparison is `0 - 0 != 0`, three times. **The identity is asserted
where both sides are zero.** The arm that HAS a real deviation is `subSecondTimestamps` — measured
deviations of 0,1,2,3,4 across its fifteen rows — and its rows carry only
`{advancedMs, timestamp, wall}`; the driver never records the declared field there, so the check
cannot see it.

This is `assert_eq "" ""` by DATA rather than by key: both sides are read, and both are zero.
Fix: record `wallClockDeviationSeconds` on the sub-second rows, assert the identity over those
fifteen, and require at least one of them to be NON-ZERO — the non-emptiness partner the campaign's
own rule asks for.

## Fixes applied, each with a mutation showing the new assertion can fail

`scratchpad/campaign/m23-review-fixmutations.sh` — eight rows, all red:

    D1 disclosure moved back out of the constructor              45 / 4 / 1
    D2 the constructor accepts a caller-supplied disclosure      45 / 3 / 1
    T1 CHAIN-LOOP.md drifts back to "never reads a wall clock"   72 / 2 / 1
    T2 the lmdb-v2 count asserted against the wrong value        72 / 1 / 1
    V1 wallClockDeviationSeconds is always 0                     20 / 2 / 1
    V2 the declared deviation is off by one                      20 / 2 / 1
    E1 the third block re-reads the archive before the seal      49 / 2 / 1
    S1 produceBlock stops refusing a non-advancing timestamp     29 / 3 / 1

And the silent-skip fix was exercised directly: with `M23_WORK` pointing at a directory holding
`avm.wasm` but no overlay worktree, `test_block_seal_updates_archive` now reports
`34 assertion(s), 2 failure(s)` and FAILS, where before the fix it would have reported 40 and
passed.

`just verify-m23` after the fixes: **506 assertions, 14/14, exit 0** —
60 / 72 / 35 / 35 / 35 / 49 / 45 / 20 / 21 / 18 / 45 / 15 / 27 / 29. +15 over 491, in five checks.

Named regression checks, re-measured: `verify_provenance_complete` **58**, `check-drift` **22**,
`check-repo-hygiene` **28**, `verify_named_checks_exist` **9**, `verify_no_pipeline_predicates`
**69**, `verify_reuse_inventory_complete` **19**, `verify_pinned_nightly_single_source` **28**.
`check_status_file.py`: 198 entries, 153 passing / 45 pending, 29 milestones, every non-pending
entry resolving to a file containing its test name.

Committed in six commits (`aztec-avm-runtime`) and one (`codetracer-specs`). Sweep started after
the last commit.

### Enumeration figures spot-checked independently at the cpp anchor — all hold

| claim | measured |
|---|---|
| `foundation/src/promise/running-promise.ts` 138 lines | 138 |
| `foundation/src/timer/date.ts` 82 lines | 82 |
| `automine/automine_sequencer.ts` 841 lines | 841 |
| TXE's `state_machine/global_variable_builder.ts` 39 lines | 39 |
| `@aztec/ethereum` imported 7 times across automine's two files | 5 + 2 = 7 |
| no first-party `Clock` interface/class anywhere in the fork | `git grep -E '^\s*(export )?(interface\|class) Clock\b'` over `yarn-project/**/*.ts`: nothing |
| `buildCheckpointIfEmpty` default `false`, declared at `config.ts:252-255` | `config.ts:46` default false, `:252-255` declaration |
| twelve overlays over `233d8e0993`, the eleventh M14's archive and the twelfth M23's, `git am` with no `-3` | the am log shows twelve `Applying:` lines and no 3-way fallback; the tree has twelve commits |
| the module exports 51 | `WebAssembly.Module.exports` over the built `avm.wasm`: 51 |
| the build entry point refuses a module without the two archive exports | `build_avm_wasm_m23.sh:94-96`, `die` per missing name |
| `produceEmptyBlocks` default read out of the SHIPPED default, not restated | the check imports `DEFAULT_BLOCK_PRODUCTION` and matches `"produceEmptyBlocks":true` |

### Claim 9 — status honesty
- Deliverables: 12 `[X]`, 1 `[ ]`. The unmet one is DD-5's three entry points, and the deferral is
  REAL: M27's deliverables already carry "A browser ESM entry point with no Node builtins" and M28
  carries the leakage gate over it. Not described as met in spirit.
- The half-met item is `L1TOL2MSGEXISTS`, and it is not quietly counted as whole: the DELIVERABLE
  (`injectL1ToL2Message` appending at the next block boundary) is fully delivered and is what the
  `[X]` claims; the verification entry says "*and it delivers HALF the entry's own criterion —
  which it says rather than implies*"; and `e2e_l1_to_l2_message_injection.sh:125-147` ASSERTS the
  blocker as a fact about the fork (the opcode exists; `PublicTxSimulationTester` is located BY
  NAME and required to reach `NativeWorldStateService`, with a control that a class it does not
  name is not found).
- 13 `- test_name:` entries under M23, all `passing`, all resolving to a file containing the name.

### F13 — the facade mapping's own summary sentence is wrong in BOTH numbers

`CHAIN-LOOP.md:245`: *"Fourteen of the twenty-three have a counterpart; nine do not, and the nine
are the ones this runtime has and a node does not (`simulateTx`, `archive`, `stateReference`,
`exportSnapshot`, `importSnapshot`, `subscribe`, `disclosure`, `provenanceKind`, `receiptFor`)
plus the lifecycle pair."*

Measured off the table the sentence summarises (23 data rows):

    rows with a TXE counterpart    12   (not fourteen)
    rows whose TXE cell is `none`  11   (not nine)
    rows with `none` in BOTH cells 11

and the parenthetical list is nine names while the set is eleven — it omits `fundFeeJuice` and
`start`. "Plus the lifecycle pair" is wrong too: `stop` HAS a counterpart (`close`); only `start`
does not. Nine + a pair would be eleven, which is the right total reached by the wrong route from
the wrong list.

`verify_facade_surface_compared_against_txe.sh` cannot catch it: both counts are `assert_ge`
(`>= 8` claimed counterparts, `>= 5` marked none), and nothing compares the document's stated
split against the measured one. Prose summarising a table in the same file, never re-derived — the
campaign's "bind claims to data" rule, in the one place where the data is three lines above.

### F14 — two rows in the enumeration table carry ts-anchor figures under a cpp-anchor header,
### and one of them names a path that does not exist

`CHAIN-LOOP.md:9` says *"Everything below is measured at the `cpp` anchor `233d8e0993` unless it
says otherwise."* Two rows of §1 say otherwise without saying so:

| row | as written | measured |
|---|---|---|
| a per-block transaction loop | `yarn-project/simulator/src/public/public_processor.ts`, **648 lines** | that path does not exist at either anchor. The file is `simulator/src/public/public_processor/public_processor.ts`, and it is **648 at the ts anchor** and **655 at the cpp anchor** |
| block sealing / archive chaining | `yarn-project/txe/src/utils/block_creation.ts`, **97 lines** | **97 at the ts anchor**, **91 at the cpp anchor** |

Both figures are correct *for what the rows describe* — M22 vendored both from the ts anchor — so
this is an attribution error rather than a wrong measurement. It matters because the header makes
the cpp anchor the default and a reader checking either number at the stated anchor gets a
different one, and because the path in the first row is simply not there.

Every other line and file count in the document was re-derived and holds: `checkpoint_builder.ts`
449, `global_builder.ts` 68, `automine_factory.ts` 152, its `README.md` 60, its `index.ts` 6,
`txe_oracle_top_level_context.ts` 1,024, `bin/index.ts` 49, `rpc_server.ts` 87,
`rpc_translator.ts` 1,229, `dispatcher_pool.ts` 317, and the three C++ tree directories at
9 / 6 / 27 files.

### Does it actually run a chain? YES — measured from my own arm run, not from the checks

`tools/run_chain_arms.mjs` against the 51-export module, all nine arms, **5.6 s wall clock**:

    emptyBlocks    3 blocks, archive 1 -> 4 leaves, each block's lastArchive == the previous
                   block's archive-after, three distinct header hashes
    noEmptyBlocks  produceEmptyBlocks:false — 6 ticks, 0 blocks from the first five, 1 after a tx
    automine on    submit() takes the chain 0 -> 1, queue empties, the block carries the tx and
                   reports itself NOT empty
    automine off   submit() leaves it at 0 with 1 pending; the next tick produces it
    subSecond      15 blocks, strictly increasing, no repeats, over a clock that moved twice
    hundredBlocks  fake ticker 100 blocks in 97 ms; RunningPromise 100 blocks / 100 ticks in
                   202 ms; identical block count, final timestamp AND archive root
    l1ToL2         tree resolved from MerkleTreeId as L1_TO_L2_MESSAGE_TREE; size 0 -> 0 on
                   inject, 0 -> 1 after the block, leaf read back BY INDEX equals the injected one
    disclosure     receipt queued -> processed in block 1, simulated/5.0.0-nightly.20260626/none
    snapshot       export/import into a SECOND world state: identical block count, archive root
                   and four-tree state reference
    archive        genesis root == GENESIS_ARCHIVE_ROOT, leaf 0 == GENESIS_BLOCK_HEADER_HASH,
                   perturbed header REFUSED with WorldState's own message and size 3 -> 3,
                   the same header unperturbed ACCEPTED and 3 -> 4

That is a chain: blocks on a timer, empty blocks by default, sealed headers chained through a real
archive, and a hundred of them in a tenth of a second because the clock is injected.

### Sweep in progress (started 11:18, after the last commit e3a60f5 / 28e2386f)
Order: m0 m1 m22 m23 m18 m20 m21 m2 m17 m13 m16 m19 m10 m12 m11 m14 m15 m3 m4 m5 m6 m7 m8 m9.
`TMPDIR` and the log both on `/home`. At the start: `/tmp` 12 G free, `/home` 220 G free.

## THE SWEEP, M0-M23, re-run by the review after its last commit

**8,408 assertions, every milestone exit 0, zero failures anywhere, NO HOLE in the log.**
`TMPDIR` and the log both on `/home`; `/tmp` never moved (12 G free before and after).

    m0 156  m1 169  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
    m10 450 m11 259 m12 691 m13 458 m14 460 m15 537 m16 223 m17 297 m18 283
    m19 180 m20 237 m21 324 m22 260 m23 506           TOTAL 8,408

Then F13/F14 were applied and the affected milestone re-measured: **m23 506 -> 509**, m0 156 and
m1 169 unchanged. **Final total 8,411.**

Accounting against the M0-M22 reference of 7,899, in both directions:
- M23's own **509** (fourteen checks; thirteen its entries plus M22's seal check).
- **M1 166 -> 169**, `verify_pinned_nightly_single_source` 25 -> 28, three assertions per witness.
- 7,899 + 509 + 3 = **8,411**.
- Every other milestone at its reference value TO THE ASSERTION, with its reference split:
  M9 140/143/113/73/126/83/129 in 1,279 s; M12 691; M13 458; M17 297 (so the `exportNames`
  addition to the node host moved nothing); M22 260 (so nothing repoints M22 at M23's module);
  M19 180 (so the counter-comment edits in its two files moved nothing).

The declared 8,393 was the same measurement of a tree with eighteen fewer assertions in it.
The +18 is itemised per check and every one of the eighteen has a mutation showing it can fail.

### F13's fix broke the check, which is the finding under the finding
`verify_facade_surface_compared_against_txe`'s table extractor ended its `awk` range at
`^Fourteen of the` — the very sentence being corrected — so the range ran to the end of the file
and swallowed §6's kv-store table, whose rows were then looked up as `AztecNodeDebug` methods:
three red assertions naming `./deprecated/indexeddb` as a missing method. **A scanner anchored to
prose breaks the day the prose is fixed.** The range ends at the next section heading now.
