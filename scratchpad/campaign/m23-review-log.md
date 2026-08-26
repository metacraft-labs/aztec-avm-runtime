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
