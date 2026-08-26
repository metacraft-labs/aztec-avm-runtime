# M23 implementation log

Rule: append after every COMPLETED step, not at the end of a phase.

## Step 0 — briefs read (done)

- `scratchpad/campaign/m23-brief.md`, `CAMPAIGN-BRIEF.md` in full, milestones file M23 + M22 + M14
  archive material, M22's Outstanding Tasks.
- Repo clean at `f3764a2`.
- Reference sweep M0–M22 = 7,899.

Working facts collected:

- Modules on disk: `~/.cache/aztec-m13-contractdb/m13/…/build-wasm-avm/bin/avm.wasm` (1,591,391 B,
  M13's ten-overlay tree) and `~/.cache/aztec-m15-shapes/m13/…` (same size). M12 trees at
  `~/.cache/aztec-m1{7,8}-*/m12/…` (1,565,773 B).
- `M22_WORK` = `~/.cache/aztec-m22-block` holds `blocks.json`.
- `verification/m14/0001-feat-world_state_reference-archive-tree-so-the-in-me.patch` is the
  prepared archive extension (3 files, +352 / −10 per M14).

## Step 1 — upstream enumeration (done, sub-agent, read-only, at the cpp anchor)

Recorded in full in `m23-enumeration.md`. Headlines:

- **TXE is 41 files / 7,376 lines at the cpp anchor** — the milestone's figure verified exactly.
  At the ts anchor it is 35 files, so the figure is a cpp-anchor fact.
- TXE's chain surface confirmed method by method with line numbers.
  `registerContractAndAddAccount` is **private**, not public — the milestone's table implies
  otherwise.
- **TXE never reads a wall clock for block time**: `nextBlockTimestamp` is a `bigint` field moved
  only by `advanceTimestampBy`. `Date.now(` appears 4 times in 2 files, all diagnostics;
  `setInterval(` once, behind `TXE_WORKER_MEMSTAT`; `setTimeout(` zero.
- TXE is reachable **only over JSON-RPC/HTTP** (`bin/index.ts` → `createTXERpcServer` →
  `startHttpRpcServer`). Its `./server` export is a factory for the same RPC server. Nothing in the
  fork calls `TXEOracleTopLevelContext` in-process.
- TXE imports `@aztec/world-state/native` (2), `@aztec/aztec-node` (1), `@aztec/archiver` (1),
  `@aztec/bb-prover/test` (1), `@aztec/kv-store/lmdb-v2` (6).
- `sequencer-client/src/sequencer/automine/` **exists at the cpp anchor**: 4 files,
  `automine_sequencer.ts` 841 lines. Driven by `RunningPromise` mempool poller.
- **Upstream already ships the injected clock**: `@aztec/foundation/timer` exports `DateProvider`,
  `TestDateProvider`, `ManualDateProvider`. `@aztec/foundation/running-promise` exports
  `RunningPromise` (poll + `trigger()` + interruptible `stop()`).
  `@aztec/foundation` is **already** a dependency of `orchestration/` at the pinned nightly, and
  `node_modules/@aztec/foundation/dest/timer/date.js` carries all three classes. **Verified live.**
- Empty blocks are upstream's too: `buildCheckpointIfEmpty` (default false) +
  `forceCreate: isLastBlock && blocksBuilt === 0 && config.buildCheckpointIfEmpty`.

## Step 2 — the archive route measured, not assumed (done)

M22's Outstanding Tasks priced this at "apply the patch as an eleventh overlay, add ONE reactor
export, add one export-list line, rebuild". Measured:

1. **The eleventh overlay applies.** `git am` of
   `verification/m14/0001-feat-world_state_reference-archive-tree-so-the-in-me.patch` onto
   base + the ten existing overlays succeeds with no `-3`. Tree at
   `~/.cache/aztec-m23-chain/m23`, 11 commits over `233d8e0993`.
2. **"One reactor export" is WRONG, and the missing one is the load-bearing one.** The reactor's
   `avm_merkle_db_*` exports run over `bb::avm2::simulation::MemoryMerkleDB` — the **vm2 adapter**,
   not `bb::world_state::MemoryMerkleDB` — which holds the reference DB in a `private` member and
   exposes only `LowLevelMerkleDBInterface`. So M14's extension does not reach the module at all
   until the adapter carries it. And an append-only export is not enough: the NEXT block header's
   `lastArchive` is a READ, so a module that can only append gives no way to anchor block N+1
   against block N. **Two exports**: `avm_merkle_db_update_archive` and
   `avm_merkle_db_get_archive_snapshot`.
3. **The ripple M22 predicted does not happen.** M22 warned the tree "would export fifty names
   where every pinned export count says thirty-nine or forty-nine". Measured: the reactor's
   `avm_merkle_db_get_tree_roots` packs vm2's `TreeSnapshots` (four trees,
   `MSGPACK_CAMEL_CASE_FIELDS`), **not** `world_state::TreeRoots`, so M14 adding a fifth field to
   `TreeRoots` changes nothing that crosses the boundary. Confirmed by probing the M13 module: the
   msgpack keys are exactly `l1ToL2MessageTree, noteHashTree, nullifierTree, publicDataTree`.
   The export list goes 49 → **51** (two, not one), and only on M23's own tree.

## Step 3 — THE ARCHIVE IS CLOSED (done, measured)

Built and probed. `~/.cache/aztec-m23-chain/m23/barretenberg/cpp/build-wasm-avm/bin/avm.wasm`,
1,595,118 B, **51 exports** (M13's is 49).

    archive @genesis  0x177a4955b31ecaafad999753938a44e526b54c5ba5d5366882 27f85f15cfbdf5   size 1
    after one append  0x2931058 7b40f88817f1d54df28d06ff8e3b444cacdfde6f54b5babc528ec4a9   size 2
    mismatched state reference refused: "Can't update archive tree: Block state does not
                                        match world state"   (WorldState's own message)
    get_sibling_path(ARCHIVE, 0) answers 30 levels  (= ARCHIVE_HEIGHT)

The genesis root is the value M14 measured against a real file-backed `WorldState`
(`0x177a4955…15cfbdf5` at size 1). So the extension reaches the module and agrees with the
production world state at genesis, and the refusal path is live.

TWO INDEPENDENT CROSS-IMPLEMENTATION AGREEMENTS, both measured against values upstream publishes
in **TypeScript** while the archive is computed in **C++**:

    archive leaf 0 = 0x0e7bf88e8833c27b0fca6be614ecc2c63def7bffa35b3ccfa1caff3e39e0c0d2
    @aztec/stdlib/block GENESIS_BLOCK_HEADER_HASH = the same value
    archive root   = 0x177a4955b31ecaafad999753938a44e526b54c5ba5d536688227f85f15cfbdf5
    @aztec/constants GENESIS_ARCHIVE_ROOT = 106192569972604394368425314999679954032539674964
                                            80475679746178797053672406517 = the same value

So the C++ `compute_initial_block_header_hash` over the four genesis snapshots reproduces
upstream's published TypeScript genesis constants exactly. That is the evidence that a header
hashed on our side and appended on the module's side agree about what a block header hash IS.

M23's overlay is the twelfth commit `ffaeee9895` in that tree: three files
(`vm2/simulation/lib/memory_merkle_db.{hpp,cpp}`, `vm2/reactor/avm_reactor.cpp`,
`vm2/CMakeLists.txt`). Build started in the background.


## Step 4 — second enumeration (done, sub-agent, read-only)

**Two corrections to facts the milestone states as settled.**

1. **The kv-store correction is right about the FORK and wrong about the PIN.** The deliverable
   says "As of the pinned nightly the actual exports are `./deprecated/indexeddb` and
   `./sqlite-opfs`". Measured:
   - installed `@aztec/kv-store@5.0.0-nightly.20260626` (the pin) exports **`./indexeddb`** —
     present in `spike/`, `diffsim/`, `probe-mt/` node_modules;
   - the fork at the **cpp anchor** `233d8e0993` exports **`./deprecated/indexeddb`**;
   - the fork at the **ts anchor** `3a68d68ac2` exports `./indexeddb`, consistent with the pin;
   - the rename is fork commit `ffb5fe64bceba54430d207323a0eb03897941cb3` (merged 2026-07-08),
     i.e. AFTER the 2026-06-26 pin.
   - `drift/node_modules/@aztec/kv-store` is **5.3.0-nightly.20260819**, a different version from
     the pin, and it has `./deprecated/indexeddb`.
   So the sentence is true of one artefact and false of the other, and which one is meant decides
   whether a persistence import compiles. Both get recorded, each against the artefact it is true
   of. Deprecation IS marked, at the cpp anchor: `kv-store/README.md:19`,
   `src/deprecated/indexeddb/index.ts:8`, `src/deprecated/indexeddb/store.ts:45`.
   `./sqlite-opfs` pulls **WASM** (`@aztec/sqlite3mc-wasm`, `vendor/jswasm/sqlite3.wasm`), not a
   native addon; `@aztec/native` is a kv-store dependency but only `lmdb-v2` reaches it.
   `@aztec/kv-store` is NOT installed under `orchestration/`.

2. **`AztecNodeDebug` has FIVE methods at the cpp anchor and THREE at the installed pin.**
   `warpL2TimeAtLeastTo` / `warpL2TimeAtLeastBy` were added in `c6a6dbd8bb00` (2026-07-08), after
   the pin. At the pin `@aztec/stdlib/interfaces/client` declares `mineBlock`, `prove`,
   `registerContractFunctionSignatures` only.

**The full-state carrier question is answered, and the answer is not a type.** The only
`*Snapshot*` type in `world_state/`, `world_state_reference/` and `crypto/merkle_tree/` is
`world_state_reference`'s `TreeSnapshot` — root + count, a summary, exactly as the deliverable
says. `world_state::WorldState` has no export/serialize API at all: it has forks and checkpoints.
Upstream's real whole-state carrier is **`NativeWorldStateService.backupTo()` → `copyStores()`,
which copies LMDB files**, with `yarn-project/stdlib/src/snapshots/` (`SnapshotDataKeys`,
`SnapshotMetadata`, `SnapshotsIndex`) as the transport vocabulary. Both are behind
`@aztec/world-state` + `@aztec/native`, which DD-9 forbids, and neither has a wasm counterpart.
**Nothing anywhere serialises a whole merkle tree's leaves to a portable blob** —
`foundation/src/trees/merkle_tree.ts` exposes `get leaves()` on an in-memory calculator with no
`toBuffer`.

**`AutomineSequencer` cannot run without L1, and it is measured per operation.** Six of its seven
public entry points reach anvil cheat codes or the rollup publisher:
`buildIfPending`/`buildEmptyBlock` → `runBuild` → `ethCheatCodes.setNextBlockTimestamp` +
`publisher.sendRequests`; `warpTo`/`warpBy` → `runWarp` → `setNextBlockTimestamp` then `runBuild`;
`prove` → `RollupCheatCodes.markAsProven` + `evmMine`; `revertToCheckpoint` → `ethCheatCodes.reorg`
+ `anvil_dropAllTransactions`; `maybeSettle` → `prove`. Only `syncPoint()` — a `SerialQueue` drain
— touches no L1, and it performs no chain operation. Its `deps` name `EthCheatCodes`,
`SequencerPublisherFactory`, `L1TxUtils`, `Archiver`, `P2P` and
`@aztec/validator-client`'s `FullNodeCheckpointsBuilder`. `@aztec/ethereum` is imported 7 times
across the two files.

## Step 5 — the chain, the timer and the facade written and RUNNING (done)

New source, all under `orchestration/src`:

- `chain_clock.ts` — DD-4. Re-exports upstream's `DateProvider`/`TestDateProvider`/
  `ManualDateProvider`; declares NO `Clock` of ours. `nextBlockTimestamp` is the milestone's
  formula in upstream's vocabulary (`nowInSeconds()` IS `floor(now()/1000)`). Ours: the
  three-method `BlockTicker` and three implementations — `RunningPromiseTicker` (upstream's
  `RunningPromise`, unchanged), `ManualTicker`, `DisabledTicker`.
- `chain.ts` — `AvmChain`. Block number, timestamp rule, queue, archive cursor, block store,
  L1→L2 queue, subscriptions, serialised production.
- `disclosure.ts` — §8.4. Registered in `pins.json` as a **pin witness** for `deletion_era`, so
  `repin.py --check` requires the literal to equal the pin (196 → 198 assertions).
- `avm_runtime.ts` — the facade.
- `chain_e2e_driver.ts` + `tools/run_chain_arms.mjs` — nine arms, one instantiation.

Changed: `node-host/src/reactor.ts` gains `exportNames`;
`orchestration/src/resident_merkle_operations.ts` answers `updateArchive`,
`getTreeInfo(ARCHIVE)` and a new `archiveSnapshot()` **when the module's own export list says it
can**, and refuses otherwise by the same code — so M12/M13 modules (M18, M20, M21, M22) still
refuse and their checks are untouched.

**Measured, on M23's module (51 exports):**

    archiveIdentity  genesis root 0x177a4955…, size 1, leaf0 == GENESIS_BLOCK_HEADER_HASH
                     block2.lastArchive == block1.archiveAfter        chained: true
                     a header with a perturbed state reference is REFUSED with upstream's own
                     message, archive size 3 -> 3; the SAME header unperturbed is ACCEPTED, 3 -> 4
    emptyBlocks      3 empty blocks, numbers 1..3, archive 1 -> 4
    noEmptyBlocks    produceEmptyBlocks:false — 5 ticks produce 0 blocks; one tx then produces 1
    subSecond        15 blocks, strictlyIncreasing true, repeats false (10 at 100 ms + a 30 s
                     throttle jump followed by 5 blocks with a stalled clock)
    hundredBlocks    fake ticker 100 blocks in 102 ms; RunningPromise ticker 100 blocks, 100 ticks,
                     217 ms; identical block count, last timestamp AND archive root
    automine         on: submit -> block 0 -> 1, pending 0, block carries 1 tx
                     off: submit -> block stays 0, pending 1; the tick then produces it
    l1ToL2           tree id from the ENUM (3 = L1_TO_L2_MESSAGE_TREE); size 0 -> 0 on inject,
                     0 -> 1 after the block, leaf read back BY INDEX equals the injected leaf
    disclosure       one line spoken; a discarding sink leaves the record intact; receipt carries
                     simulated/5.0.0-nightly.20260626/none, `queued` then `processed` in block 1
    snapshot         export/import into a SECOND world state: identical block count, archive root
                     AND state reference, byte for byte

**Three defects found by running it, each a rule this campaign already had:**

1. **Every transaction executed TWICE.** The facade called `executeExternallySettledTx` and then
   queued the transaction, so the block re-ran it and the second run collided with the nullifiers
   the first had inserted. Found because the collision is loud. Fixed: a submission only queues;
   execution happens once, in the block, through upstream's `PublicProcessor`. DD-1 is then
   satisfied *structurally* — the queue holds `Tx` and the provenance never travels to the
   executing path at all. `simulateTx` is where `executeExternallySettledTx` is called now, under
   a checkpoint pair that is reverted in a `finally`.
2. **A magic tree id, the exact shape of M22's seventh defect.** The L1→L2 arm read
   `getTreeInfo(2 /* L1_TO_L2_MESSAGE_TREE */)`; 2 is `PUBLIC_DATA_TREE` and 3 is the message
   tree. It reported size 128 (the public-data prefill) and looked plausible. `MerkleTreeId` now,
   with the resolved name reported in the arm so the check can pin it.
3. **A "stale header" that was not stale.** The refusal arm re-offered an earlier block's header,
   but an EMPTY block does not move the four trees, so the header legitimately still matched and
   the module accepted it — `NOT-REFUSED`, an assertion that could not fail for the reason it
   named. It perturbs one tree's root now, and the unperturbed header is the control that the same
   call ACCEPTS.

## Step 6 — documents (done)

- `CHAIN-LOOP.md` written: the enumeration (§1), the TXE verdict (§2), the two recorded
  divergences (§3), the facade mapping member by member (§4), the snapshot-carrier decision (§5),
  the kv-store correction with all four artefacts (§6), what is genuinely ours (§7), Outstanding.
- `REUSE-INVENTORY.md`: **RI-39 open → replace** (`cannot-reach-target`, per-import),
  **RI-40 open → replace**, **RI-41 open → build** (`cannot-reach-target`, per-operation).
  New: **RI-69** `DateProvider` + `RunningPromise` (depend), **RI-70** the two archive reactor
  exports (extend), **RI-71** the snapshot carrier (build).
  `verify_reuse_inventory_complete` 19/0, unchanged.
- `REACTOR-ABI.md`: the export count is now stated as a property of a TREE (39 / 49 / 51) and the
  archive has its own section — the document mentioned "archive" **zero** times before, which is
  how M14's export decision got lost across M15, M22 and into M23.
- `pins.json`: `orchestration/src/disclosure.ts` registered as a pin witness for `deletion_era`;
  `repin.py --check` 196 → 198.

## Step 7 — the behavioural checks (done)

`verification/lib_m23_chain.sh` (the shared machinery: one arm run, the module preconditions
including the two archive exports, `m23_summary_on_abnormal_exit`) plus eight checks so far:

| check | assertions |
|---|---|
| `test_empty_block_advances_number_and_archive` | 49 |
| `test_block_seal_updates_archive` (closes M22's entry) | 44 |
| `test_timestamps_strictly_monotonic_subsecond` | 18 |
| `test_fake_clock_hundred_blocks` | 21 |
| `e2e_automine_seals_on_submission` | 18 |
| `test_receipt_declares_no_proving` | 40 |
| `test_no_ambient_clock_or_timer` | 15 |
| `e2e_l1_to_l2_message_injection` | 27 |
| `e2e_chain_snapshot_export_import_roundtrip` | 26 |

**A fourth defect, found by a check rather than by a run.** `test_no_ambient_clock_or_timer`
scanned the shipped source and reported **two live `Date.now()` calls in M22's
`block_e2e_driver.ts`** — the deadline arms, `new Date(Date.now() - 60_000)` and
`+ 3_600_000`. They are the only ambient wall-clock reads under `orchestration/src`. Repointed
through a `DateProvider`; the values are identical (`DateProvider.now()` IS `Date.now()`), so M22's
deadline arms are unaffected, and the read is now on an object a caller can replace, which is the
whole of DD-4.

## Step 8 — the enumeration checks, the Justfile, the build entry point (done)

`just verify-m23` — **fourteen checks, 491 assertions, 14/14, exit 0**:

    verify_sequencer_reuse_enumeration_recorded          60
    verify_txe_reuse_verdict_recorded                    68
    verify_facade_surface_compared_against_txe           35
    test_tree_snapshot_vocabulary_reused_not_redefined   35
    verify_kv_store_browser_exports_recorded             35
    test_empty_block_advances_number_and_archive         49
    test_block_seal_updates_archive                      44   (M22's entry)
    test_timestamps_strictly_monotonic_subsecond         18
    test_fake_clock_hundred_blocks                       21
    e2e_automine_seals_on_submission                     18
    test_receipt_declares_no_proving                     40
    test_no_ambient_clock_or_timer                       15
    e2e_l1_to_l2_message_injection                       27
    e2e_chain_snapshot_export_import_roundtrip           26

`verification/build_avm_wasm_m23.sh` (`just avm-wasm-build-m23`) builds the twelve-overlay tree
from scratch and refuses a module without the two archive exports. Verified from empty: 51 exports.

**Four more defects, every one caught by a check on its own first run and every one already on
the campaign's list:**

5. **`M6_WORK` set BEFORE the libraries were sourced.** Several `lib_m*.sh` repoint it when
   sourced, so M23's twelve-patch tree landed under `~/.cache/aztec-m14-archive/` — where
   `m23_find_module` would never look. Set after the sourcing now, with the reason in the file.
6. **A character class without a digit.** `verify_facade_surface_compared_against_txe` counted
   `AztecNodeDebug`'s methods with `^  [a-zA-Z]+\(` and found **three of five**, because
   `warpL2TimeAtLeastTo` and `warpL2TimeAtLeastBy` have a `2` in them — in the section whose entire
   subject is those two methods. This is the campaign's `avm2` defect, reproduced exactly.
7. **A table's HEADER row read as data.** The same check extracted the facade mapping with
   `grep '^| \`'`, which matches the header too, so the literal strings `TXE` and `AztecNodeDebug`
   entered the claimed-counterpart set and were looked up as TXE methods.
8. **A `printf … | grep -q` predicate.** One line, in the same check.
   `verify_no_pipeline_predicates` pins the surviving census at five BY NAME and went **69/3**.
   Replaced with `str_has_sub`; back to 69/0.

And three needles that spanned a line break, because `CHAIN-LOOP.md` wraps at 100 columns. All
three went red for a reason with nothing to do with their subject. Needles are line fragments now.

Named checks 9/0, `check-repo-hygiene` 28/0, `check-drift` 22/0, `verify_provenance_complete`
58/0, `verify_pinned_nightly_single_source` 28/0 (repin's own note 196 → 200),
`verify_reuse_inventory_complete` 19/0, `verify_no_pipeline_predicates` 69/0.

## Step 9 — MUTATION MATRIX (done)

`scratchpad/campaign/m23-mutations.sh` — fifteen mutations, one per check plus a second for the
seal, each targeting that check's CENTRAL claim. Applied, run, restored from a copy the script
takes itself (never `git checkout`: a path that is not tracked yet restores to nothing).
**Every one goes red.**

| check | mutation | result (assertions / failures / rc) |
|---|---|---|
| `verify_sequencer_reuse_enumeration_recorded` | RI-41's decision reverted to `open` | 60 / **1** / 1 |
| `verify_txe_reuse_verdict_recorded` | RI-39's rejection reason emptied of its call sites | 68 / **3** / 1 |
| `verify_facade_surface_compared_against_txe` | one facade member dropped from the mapping table | 35 / **1** / 1 |
| `test_tree_snapshot_vocabulary_reused_not_redefined` | a parallel `TreeSnapshot` declared in `chain.ts` | 35 / **1** / 1 |
| `verify_kv_store_browser_exports_recorded` | the deletion-era row deleted from the table | 35 / **1** / 1 |
| `test_empty_block_advances_number_and_archive` | `archiveBefore` read AFTER the seal — the chain stops chaining | 49 / **8** / 1 |
| `test_block_seal_updates_archive` | `updateArchive` passes the CURRENT trees instead of the header's state | 44 / **4** / 1 |
| `test_block_seal_updates_archive` | one export line removed from M23's overlay patch | 44 / **1** / 1 |
| `test_timestamps_strictly_monotonic_subsecond` | the rule takes the MINIMUM instead of the maximum | 0 / **1** / 1 |
| `test_fake_clock_hundred_blocks` | `ManualTicker` delivers each tick twice | 21 / **6** / 1 |
| `e2e_automine_seals_on_submission` | `submit()` seals whether or not automine is set | 0 / **1** / 1 |
| `test_receipt_declares_no_proving` | `create()` stops writing the disclosure to the sink | 40 / **8** / 1 |
| `test_no_ambient_clock_or_timer` | a planted `Date.now()` in `chain.ts` | 15 / **1** / 1 |
| `e2e_l1_to_l2_message_injection` | `injectL1ToL2Message` appends immediately, not at the boundary | 27 / **5** / 1 |
| `e2e_chain_snapshot_export_import_roundtrip` | `exportSnapshot` omits the fee-juice funding | 26 / **4** / 1 |

**Two rows read `0 / 1 / 1` and that is the abnormal-exit trap doing its job, not a weak check.**
The min-instead-of-max rule and the always-seal submission both make the SHARED ARM RUN die —
the chain refuses a timestamp that does not advance, and an unconditional seal collides — so
`m23_require_arms` dies before any assertion runs. `m23_summary_on_abnormal_exit` then prints a
summary line **with a failure counted**, which is exactly M21's review's lesson: a check that dies
must read as a RED milestone and not as a smaller one. Both exit 1 and both print a summary. The
cost is stated: those two mutations are less DISCRIMINATING than the others, because they would
turn every behavioural check red rather than only their own.

Baseline for every check is `N / 0 / 0`, re-measured before the mutations and again after the
restore: `just verify-m23` is 491 assertions, 14/14, exit 0 both times.

## Step 10 — status file updated, sweep started (in progress)

`codetracer-specs/Planned-Work/Aztec-AVM-Runtime.milestones.org`:

- **M23** rewritten: `partially_completed` (one deliverable unmet — three entry points per DD-5,
  which is M27's packaging and M28's gate — and one met in half, the `L1TOL2MSGEXISTS` opcode).
  Thirteen entries, all `passing`, each with a `file:`; plus the mutation matrix, the eight
  defects, Key Source Files and Outstanding Tasks.
- **M22**: `test_block_seal_updates_archive` **pending → passing**, with `file:` pointing at
  M23's check because it measures M23's module. Header corrected: seven entries, **five** pass,
  two remain pending on a DIFFERENT fact (the transaction builder). Its third deliverable flipped
  to `[X]` with the attribution to M23. Its Outstanding "THE ARCHIVE" entry now records that M23
  closed it and that "one reactor export" was two, with the original text kept unedited because
  its reasoning about ownership was right.
- **M14**: its /Out of scope/ "whether the reactor should export archive operations at all is
  M15's boundary decision" now records that M23 took it and why it went unowned for three
  milestones.

`check_status_file.py`: 198 entries, 153 passing / 45 pending, 29 milestones, **all non-pending
entries resolve to a file containing the test name**.

Sweep M0–M23 started, nothing else running. `TMPDIR` and the log both on `/home` (220 GB free) —
M22's sweep lost two regions of its own log to the shared tmpfs.

## Step 11 — THE SWEEP, M0–M23 (done)

One milestone at a time, nothing else running, `TMPDIR` and the log both on `/home`.
**8,393 assertions, every milestone exit 0, zero failures anywhere.** No hole in the log.

    m0 156  m1 169  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
    m10 450 m11 259 m12 691 m13 458 m14 460 m15 537 m16 223 m17 297 m18 283
    m19 180 m20 237 m21 324 m22 260 m23 491            CAMPAIGN TOTAL 8,393

**Every unit of change accounted for in both directions.** Reference M0–M22 = 7,899.

- **M23's own 491** — fourteen checks, thirteen its entries plus M22's
  `test_block_seal_updates_archive`.
- **M1 166 → 169**, and it is `verify_pinned_nightly_single_source` **25 → 28**:
  `orchestration/src/disclosure.ts` is now a declared `npm_pin_witness`, and that check makes
  exactly THREE assertions per witness — it is tracked, it carries a nightly literal at all, and
  the literal equals the declared pin. Confirmed in both parts by the split: M1 is
  19 / 58 / 10 / 21 / 33 / **28** against a reference of 19 / 58 / 10 / 21 / 33 / **25**, and
  `verify_provenance_complete` is unchanged at 58.
- 491 + 3 = 494. 7,899 + 494 = **8,393**.
- **Every other milestone came out at its reference value to the assertion** — including
  **M22 at 260** with `block_e2e_driver.ts` edited (repointing its two `Date.now()` deadline calls
  through a `DateProvider` changes no value), and **M9 at 807** reproducing its
  140/143/113/73/126/83/129 split exactly, in 1,296 s.

Per-milestone seconds: m9 1296, m10 657, m4 629, m5 606, m14 472, m15 397, m3 259, m19 252,
m12 247, m6 245, m2 201, m8 181, m7 170, m17 135, m11 112, m13 102, m0 38, m1 24, m18 20,
m20/m21/m22 13, m23 9, m16 4.

## Step 12 — post-sweep edits and re-measure (done)

Made AFTER the sweep, then the affected milestones re-run:

- `CAMPAIGN-BRIEF.md`: needle family **sixteen → nineteen**, with the three M23 forms written into
  the list (the digit class again, in the section about the two methods with a digit in them; a
  needle spanning a line break in a wrapped document; a table's header row read as data). Sweep
  block updated to M0–M23 with the +494 accounting.
- `CHAIN-LOOP.md`: the quoted reuse-miss total ("nine") **retired** and replaced by a pointer to
  the family in `CAMPAIGN-BRIEF.md`. It was a sixth place quoting a number, and `CAMPAIGN-BRIEF.md`
  itself says **eight** — a divergence I introduced from the M23 brief's "nine". Naming the family
  and not the number is what the campaign's own rule asks for.
- Milestones file: M23's Verification section now carries the measured sweep block and the
  accounting.

Re-measured after those edits: `just verify-m23` **491, 14/14, exit 0** (identical split),
`just verify-m1` **169, exit 0**, `just verify-m0` **156, exit 0**.
`check_status_file.py`: 198 entries, 153 passing / 45 pending, all non-pending resolve.

## Tree state

Nothing committed, nothing pushed. New files are `git add -N` so `git ls-files` sees them (several
checks require tracked paths); content is unstaged. Untracked: this log and
`scratchpad/campaign/m23-mutations.sh`.
