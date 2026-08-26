# The chain loop, the timer and the facade — what was already there

**M23's first deliverable is an enumeration, and its second is a verdict on TXE reached by
reading it.** This file is both. It is held to the fork by three checks that re-derive their
figures on every run rather than reading them here:
`verify_sequencer_reuse_enumeration_recorded`, `verify_txe_reuse_verdict_recorded` and
`verify_facade_surface_compared_against_txe`.

Everything below is measured at the **`cpp` anchor `233d8e0993`** unless it says otherwise. Where
a fact differs between the anchor and the npm pin this package installs, BOTH are given, because
this milestone found two places where a sentence that was true of one artefact was false of the
other and the difference decided whether an import compiles.

**Two rows of the table below say otherwise, and the first version of them did not say so.** The
files M22 VENDORED were taken from the **`ts` anchor `3a68d68ac2`**, so their line counts are
`ts`-anchor facts; measured at the default anchor a reader gets a different number. Both rows name
both figures now. M23's review found it, along with a path in the first of them that exists at
neither anchor.

> The campaign has a counted family for "believed absent, actually at a parallel subdirectory" and
> `CAMPAIGN-BRIEF.md` holds the number — deliberately not repeated here, because a total quoted in a
> second place is a total that goes stale in silence. Every miss in it was a parallel subdirectory. RI-41 is one of those misses recorded in place: it was `build`, with
> a rejection reason that did not survive checking, because `sequencer-client/` was enumerated and
> `sequencer-client/src/sequencer/automine/` was not.

---

## 1. Upstream's block orchestration, item by item

| what the milestone names | what upstream has | verdict |
|---|---|---|
| a per-block transaction loop | `PublicProcessor.process` — `yarn-project/simulator/src/public/public_processor/public_processor.ts`, **648 lines at the `ts` anchor** (655 at the `cpp` anchor; M22 vendored from the `ts` one, so that is the figure that describes the copy) | **REUSED**, vendored in M22 (RI-21, `PROVENANCE.md` F10). Not one line of it is in `chain.ts` |
| block limits | `PublicProcessorLimits` — `@aztec/stdlib/interfaces/server` | **REUSED**, M22. `maxTxsPerBlock` is handed to `maxTransactions` |
| block sealing / archive chaining | `makeTXEBlockHeader`, `makeTXEBlock` — `yarn-project/txe/src/utils/block_creation.ts`, **97 lines at the `ts` anchor** (91 at the `cpp` anchor), zero relative imports | **REUSED**, vendored byte-identically in M22 (RI-66, F19) |
| the per-block execution engine | `CheckpointBuilder` — `yarn-project/validator-client/src/checkpoint_builder.ts`, 449 lines | **REFERENCE.** It is the right shape — fork, `PublicProcessor`, `ForkCheckpoint` rollback, budget capping — and it constructs its simulator through `createPublicTxSimulatorForBlockBuilding`, which hard-defaults to `TelemetryCppPublicTxSimulator`. DD-9. What we take from it is the pairing it demonstrates, which M22 already has |
| global-variable construction | `GlobalVariableBuilder` — `sequencer-client/src/global_variable_builder/global_builder.ts`, 68 lines | **REJECTED, `cannot-reach-target`.** Its constructor takes a `ViemPublicClient` and wraps a `RollupContract`; `buildCheckpointGlobalVariables` calls `rollupContract.getManaMinFeeAt(...)`, a live L1 read. There is no L1 here. *Upstream itself substitutes it*: `TXEGlobalVariablesBuilder` (39 lines) implements the same interface with zero L1 I/O. `AvmChain.globalsFor` is that substitution, over `GlobalVariables.from(GlobalVariables.empty())` so no field this runtime does not decide is invented |
| the tick source | `RunningPromise` — `foundation/src/promise/running-promise.ts`, 138 lines, exported at `@aztec/foundation/running-promise` and `@aztec/foundation/promise` | **REUSED.** `Sequencer` ticks on it (`sequencer.ts:305-309`, `sequencerPollingIntervalMS`, default 500) and so does `AutomineSequencer` (`automine_sequencer.ts:179,185`, default 50 ms). It owns the sleeping, the coalescing of concurrent `trigger()` callers and an interruptible `stop()`. `RunningPromiseTicker` holds one and forwards |
| the injected clock | `DateProvider`, `TestDateProvider`, `ManualDateProvider` — `foundation/src/timer/date.ts`, 82 lines, exported at `@aztec/foundation/timer` | **REUSED, and no `Clock` of ours is declared.** `DateProvider.now()` is the milestone's `clock.nowMs()`; `nowInSeconds()` is `Math.floor(this.now() / 1000)`. `@aztec/foundation` was already a dependency and `block_assembly.ts` has taken a `DateProvider` since M22. There is **no first-party `Clock` interface anywhere in the fork** — the injectable-clock role is filled entirely by this family |
| empty-block issuance | `buildCheckpointIfEmpty` (`sequencer-client/src/config.ts:252-255`, default `false`) and `forceCreate: timingInfo.isLastBlock && blocksBuilt === 0 && this.config.buildCheckpointIfEmpty` (`checkpoint_proposal_job.ts:1024-1027`), against the `minTxsPerBlock` gate in `waitForMinTxs` (`:1459-1480`) | **SHAPE REUSED, code rejected with the sequencer.** `produceEmptyBlocks` is `buildCheckpointIfEmpty` with the default flipped, and the default is flipped because the milestone says so: a timer that produces nothing when idle is not the deliverable |
| the block timestamp | `getTimestampForSlot(slot, {slotDuration, l1GenesisTime})` — `@aztec/stdlib/epoch-helpers`, called from `global_builder.ts:52-56` | **REJECTED, `cannot-reach-target`.** It derives a timestamp from an L1 genesis time and a slot duration; there is no L1 genesis here and inventing one would be inventing a chain's history. `slotNumber` is therefore left at `GlobalVariables.empty()`'s value rather than fabricated, and §8.4's disclosure covers the class of simplification |
| a serialised entry point | `SerialQueue` and `AutomineSequencer`'s "every operation is serialized through a single `SerialQueue`" | **SHAPE REUSED.** `AvmChain.produceBlock` chains onto the previous production rather than running concurrently — two blocks built against one set of trees would read the same `lastArchive` and the module would refuse the second seal |

### `AutomineSequencer` — the verdict RI-41 reserved for a measurement

RI-41's `experiment:` line asked for exactly one thing: *stand it up against our in-memory world
state with no L1 and record which operations survive.* Read at the anchor
(`automine_sequencer.ts`, 841 lines; `automine_factory.ts`, 152; `README.md`, 60; `index.ts`, 6):

| entry point | reaches L1? | where |
|---|---|---|
| `buildIfPending()` | **yes** | `runBuild` → `ethCheatCodes.nextBlockTimestamp()` `:408`, `ethCheatCodes.setNextBlockTimestamp` `:420`, `publisher.enqueueProposeCheckpoint` `:545`, `publisher.sendRequests` `:554`, `ethCheatCodes.lastBlockTimestamp()` `:574` |
| `buildEmptyBlock()` | **yes** | the same `runBuild` |
| `warpTo(ts)` / `warpBy(d)` | **yes** | `runWarp` → `ethCheatCodes.lastBlockTimestamp()` `:626`, `setNextBlockTimestamp` `:639`, then `runBuild` `:640` |
| `prove(upToCheckpoint?)` | **yes** | `runProve` → `RollupCheatCodes.getTips()` `:717`, `markAsProven` `:753`, `ethCheatCodes.evmMine()` `:761` |
| `revertToCheckpoint(n)` | **yes** | `runRevert` → `publicClient.getBlockNumber()` `:682`, `ethCheatCodes.reorg(depth)` `:685`, `rpcCall('anvil_dropAllTransactions')` `:691` |
| `maybeSettle()` | **yes** | calls `prove()` `:345` |
| `syncPoint()` | no | `this.queue.syncPoint()` `:315` — a `SerialQueue` drain. It performs no chain operation |

Its own README states the requirement in terms: *"the deployed rollup must have
`aztecTargetCommitteeSize == 0`"*, and describes `warpTo`/`warpBy` as advancing the clock *"by
publishing an empty checkpoint at the target slot"*. Its `deps` name `EthCheatCodes`
(`@aztec/ethereum/test`), `SequencerPublisherFactory`, `L1TxUtils`, `FullNodeCheckpointsBuilder`
(`@aztec/validator-client`), `P2P` and `Archiver`. `@aztec/ethereum` is imported **7** times
across its two files.

**DECISION: `cannot-reach-target`.** The target is a runtime with no L1, no anvil and no rollup
contract — DD-9's world and M27/M28's browser. Six of seven entry points are unreachable there and
the seventh does nothing. The rejection is stated per operation rather than per package, because
"it is a node component" is precisely the assumption this plan has been wrong about.

**What is taken anyway**, because 841 lines of anvil-style chain driver is prior art whether or
not it runs: the serialised single entry point; an explicit `buildEmptyBlock` separate from the
mempool-driven build; an injected date provider reconciled to an external time source rather than
read from the host; a poller with a `trigger()` that bypasses the interval; and the discipline of
never advancing the clock to a time that has not happened.

---

## 2. TXE — the verdict, reached by reading it

`yarn-project/txe/src/` is **41 files and 7,376 lines at the `cpp` anchor** — the milestone's
figure, verified by summing `wc -l` over `git ls-tree -r`. At the `ts` anchor it is 35 files, so
the figure is a `cpp`-anchor fact. The whole package directory is 67 files / 8,278 lines.

### Its surface, against ours

`TXEOracleTopLevelContext` (`txe/src/oracle/txe_oracle_top_level_context.ts`, 1,024 lines,
`implements IMiscOracle, ITxeExecutionOracle`):

| TXE, with its line | ours |
|---|---|
| `mineBlock({nullifiers?, l1ToL2Messages?})` `:392` | `AvmRuntime.produceBlock()` / `AvmChain.produceBlock()` |
| `advanceBlocksBy(blocks)` `:246` | `AvmRuntime.advanceBlocksBy(n)` — same name, same loop-calling-`mineBlock` shape |
| `advanceTimestampBy(duration)` `:254` | **not taken as a delta.** See §3 |
| `sendL1ToL2Message(content, secretHash, sender, recipient)` `:372` | `injectL1ToL2Message(leaf)` — the leaf, not the four parts, because the four parts are an L1 contract's concern |
| `deploy(contractPath, initializer, args, secret, salt, deployer)` `:263` | none. Deployment needs a transaction builder that reaches `@aztec/world-state`; see Outstanding |
| `addAccount(secret)` `:307`, `createAccount(secret, partialAddress)` `:331` | none — no key store here |
| `registerContractAndAddAccount(...)` `:312` | none. **It is `private`**, which the milestone's table does not say |
| `getNextBlockNumber()` `:175` | `AvmRuntime.nextBlockNumber` |
| `getNextBlockTimestamp()` `:179` | `AvmRuntime.nextBlockTimestamp` |
| `getLastBlockTimestamp()` `:183` | `AvmRuntime.lastBlockTimestamp` |
| `getLastTxEffects()` `:187` | `AvmRuntime.blocks` — the block store, which carries more |
| `privateCallNewFlow(...)` `:417` | `submitLocal` (Form B, M21) |
| `publicCallNewFlow(...)` `:677` | `submitExternal` (Form A, M20) |
| `addAuthWitness(address, messageHash)` `:340` | none — M21's auth witnesses are not on the facade yet |
| `getRandomField()` `:156` | none. DD-3's injected randomness is not M23's |

Its `state_machine/` is 789 lines across six files — `index.ts` 152, `archiver.ts` 118,
`global_variable_builder.ts` 39, `synchronizer.ts` 105, `dummy_p2p_client.ts` 264,
`mock_epoch_cache.ts` 111 — and every one of them is **upstream itself substituting a node's
component with a dev-shaped one**, which is the pattern this whole project is built on. That is
the strongest argument for reuse and it is why this entry exists.

### The counterpoint, measured

* **Native dependencies, by import, in `txe/src/`:** `@aztec/world-state/native` **2**
  (`txe_oracle_top_level_context.ts:89` `ForkCheckpoint`, `state_machine/synchronizer.ts:12`
  `NativeWorldStateService`), `@aztec/aztec-node` **1** (`state_machine/index.ts:1`
  `AztecNodeService`), `@aztec/archiver` **1** (`state_machine/archiver.ts:1`),
  `@aztec/bb-prover/test` **1** (`state_machine/index.ts:2`), `@aztec/kv-store/lmdb-v2` **3**
  (`dispatcher_pool.ts:4`, `index.ts:3`, `txe_session.ts:6`).
  `@aztec/native` is never imported directly — it arrives through `@aztec/world-state`. DD-9
  forbids the first and `verify_differential_containment` asserts against it in three places.
  *The lmdb-v2 figure said **6** until M23's review re-derived it.* Six is the count of every
  `@aztec/kv-store*` import, and three of those are bare `import type { AztecAsyncKVStore }` lines
  (`state_machine/archiver.ts:6`, `txe_session.ts:5`, `utils/txe_account_store.ts:1`) — type-only,
  erased at compile time, and not `lmdb-v2` at all. In a bullet headed *by import*, that doubled
  the native-binding surface. The check now asserts **3** exactly, as it does for the other four;
  it asserted `>= 3` for this one alone, which is why this was the number that drifted.
* **Its state machine wraps a real node.** `TXEStateMachine` constructs an `AztecNodeService` and
  a `NativeWorldStateService.ephemeral()`. The substitutions are *around* a node, not instead of
  one.
* **It is driven over a protocol, not as a library.** `txe/src/bin/index.ts` (49 lines) calls
  `createTXERpcServer` and `startHttpRpcServer`; `rpc_server.ts` (87 lines) wraps a
  `TXEDispatcher` in `createSafeJsonRpcServer`. `rpc_translator.ts` is 1,229 lines of
  JSON-RPC↔oracle translation and `dispatcher_pool.ts` 317 of worker dispatch. The package's
  `./server` export is a factory for the same RPC server, and outside `txe/` the specifier
  `@aztec/txe` appears in exactly **two** paths in the whole tree —
  `yarn-project/aztec/package.json` and `yarn-project/aztec/src/cli/cmds/start_txe.ts:3`, which
  hands the object straight to `startHttpRpcServer`; `aztec_start_action.ts:73` reaches that one by
  a relative dynamic import. (This bullet said "three files" until M23's review counted them.)
  **Nothing in the fork calls
  `TXEOracleTopLevelContext` in process.** The class is exported and constructible — that much of
  RI-41's correction stands — but there is no in-process caller to copy, and the surface a caller
  would drive is the RPC schema.

### DECISION: **reference implementation**, `cannot-reach-target`

The target is a browser page with no native addon (DD-9, M27, M28). `@aztec/world-state/native`
alone is disqualifying and there are three more. Substituting them is not the small change it
looks like: the substitution point is `TXEStateMachine`, which exists to wire a real
`AztecNodeService`, so replacing its dependencies means replacing the thing that holds them.

**And its API shape informs ours anyway**, which is the other half of the deliverable and is not
a formality: `advanceBlocksBy`, `getNextBlockNumber`, `getNextBlockTimestamp` and
`getLastBlockTimestamp` are TXE's names on our facade; `mineBlock`'s l1-to-l2 boundary semantics
are ours; and its handling of block time is the most useful thing in it — **but the fact is
narrower than the milestone's own table states, and the first version of this section repeated the
overstatement.**

**TXE never ADVANCES block time from a wall clock. It SEEDS it from one.**
`txe/src/txe_session.ts:349` is

```ts
const nextBlockTimestamp = BigInt(Math.floor(new Date().getTime() / 1000));
```

and that value is handed to the `TXEOracleTopLevelContext` constructor (`:370`, `:403`), so every
session's first block timestamp is the host's clock and a test that reads `block.timestamp` gets a
different number on every machine and on every run. From there the field is what the milestone
says: a plain `bigint` moved only by `advanceTimestampBy` (`:256`), with `mineBlock` stamping
`timestamp: this.nextBlockTimestamp` (`:404`) without incrementing it.

**The needle that missed it is worth recording, because this is the section whose subject is
wall-clock reads.** `Date.now(` appears 4 times in 2 files (`dispatcher_pool.ts`, `index.ts`), all
diagnostic elapsed-time logging; `setInterval(` once, in `worker.ts:67`, behind
`TXE_WORKER_MEMSTAT` and `.unref()`'d; `setTimeout(` **zero times**. All three counts are correct,
and all three are blind to `new Date().getTime()`, which is the spelling TXE uses. The count of
that spelling is asserted now — it is 1, and it is that line — so the claim rests on a measurement
rather than on an absence nobody looked for.

**What we take is the ADVANCEMENT discipline and not an absence that is not there.** Ours is
injected all the way down, seed included: `AvmChain` reads its time only through an injected
`DateProvider`, `test_no_ambient_clock_or_timer` asserts structurally that no shipped source file
calls `Date.now(`, `setInterval(` or `setTimeout(`, and `ManualDateProvider(0)` is what makes a
hundred blocks cost 97 ms.

---

## 3. Where we diverge from the prior art, and why

Two divergences, both recorded rather than discovered.

**We do not take `advanceTimestampBy` as a delta.** TXE's time is a field the caller pushes
forward; ours is derived per block from an injected clock by
`max(prev + minBlockSpacingSeconds, clock.nowInSeconds())`. The reason is that TXE has no timer at
all — every block is an explicit oracle call — and this milestone's whole point is a timer. A
delta-only API cannot answer "what happens when the tab is throttled and the wall clock jumps 30
seconds", which is the case DD-4 names. The replay path *does* take an absolute timestamp
(`produceBlock({timestamp})`), because a replay must reproduce headers and a recomputed timestamp
is a different header; monotonicity is enforced for the override too.

**`AztecNodeDebug` names two different surfaces and we follow the installed one.**
`yarn-project/stdlib/src/interfaces/aztec-node-debug.ts` at the anchor declares **five** methods —
`mineBlock()` `:25`, `prove(upToCheckpoint?)` `:38`, `warpL2TimeAtLeastTo(ts)` `:48`,
`warpL2TimeAtLeastBy(d)` `:58`, `registerContractFunctionSignatures(sigs)` `:66` — with
`AztecNodeDebugApiSchema` beside it `:69-78`, implemented by `AztecNodeService`
(`aztec-node/src/aztec-node/server.ts:163`) and exposed over JSON-RPC behind `--node-debug`
(`register_node_rpc_handlers.ts:36-39`, `aztec_start_options.ts:178-183`). **The installed
`@aztec/stdlib` at this package's pin declares only three**: the two `warp*` methods were added in
`c6a6dbd8bb00` (2026-07-08), after the 2026-06-26 `deletion_era` pin. `mineBlock` is
`produceBlock`; `prove` has no counterpart and cannot (§8.4: there is no prover);
`registerContractFunctionSignatures` has no counterpart yet. The `warp*` pair is deliberately not
adopted: warping means publishing an empty checkpoint at a target slot, and a slot is an L1
concept.

---

## 4. The facade, mapped

Every public member of `AvmRuntime`, with its counterpart or `none`.
`verify_facade_surface_compared_against_txe` extracts the member list from the class itself and
requires every one of them to appear here.

| `AvmRuntime` | TXE | `AztecNodeDebug` |
|---|---|---|
| `start` | none | none |
| `stop` | `close` | none |
| `submitExternal` | `publicCallNewFlow` | none |
| `submitLocal` | `privateCallNewFlow` | none |
| `provenanceKind` | none | none |
| `simulateTx` | none | none |
| `registerContract` | `registerContractAndAddAccount` (private) | `registerContractFunctionSignatures` |
| `fundFeeJuice` | none | none |
| `injectL1ToL2Message` | `sendL1ToL2Message` | none |
| `blockNumber` | `getLastBlockNumber` (private) | none |
| `nextBlockNumber` | `getNextBlockNumber` | none |
| `lastBlockTimestamp` | `getLastBlockTimestamp` | none |
| `nextBlockTimestamp` | `getNextBlockTimestamp` | none |
| `blocks` | `getLastTxEffects` | none |
| `archive` | none | none |
| `stateReference` | none | none |
| `produceBlock` | `mineBlock` | `mineBlock` |
| `receiptFor` | none | none |
| `advanceBlocksBy` | `advanceBlocksBy` | none |
| `subscribe` | none | none |
| `exportSnapshot` | none | none |
| `importSnapshot` | none | none |
| `disclosure` | none | none |

**12** of the 23 members have a TXE counterpart and **11** do not. The eleven are the ones this
runtime has and a node does not — `provenanceKind`, `simulateTx`, `archive`, `stateReference`,
`receiptFor`, `subscribe`, `exportSnapshot`, `importSnapshot` and `disclosure` — plus `start`,
which is a process TXE does not own, and `fundFeeJuice`, which TXE reaches only through `deploy`.
`stop` is **not** among them: TXE's `close` is its counterpart.

*This sentence read "Fourteen of the twenty-three … nine do not … plus the lifecycle pair" until
M23's review counted the rows it summarises.* It was wrong in both numbers, listed nine names for a
set of eleven, and reached the right total by the wrong route: `stop` HAS a counterpart, so the
pair is one. Prose summarising a table three lines above it, never re-derived — and the check could
not catch it, because both counts were `>=`. Both are exact now and
`verify_facade_surface_compared_against_txe` requires the numbers in this paragraph to EQUAL the
ones it computes from the table.

---

## 5. Snapshot export and import — what carries a full state

The milestone requires the existing pieces to be checked before a format is defined, and says the
check has already returned a partial answer. It has, and the rest of it is here.

* `world_state_reference`'s `TreeSnapshot` (`memory_merkle_db.hpp:34`) is
  `{root, next_available_leaf_index}` — a **summary**, matching the protocol's
  `AppendOnlyTreeSnapshot` (`stdlib/src/trees/append_only_tree_snapshot.ts:16`, fields `root: Fr`,
  `nextAvailableLeafIndex: UInt32`, with `toBuffer`/`fromBuffer`/`schema`). It is the right
  vocabulary for a state **reference** and `AvmChain` uses it as one, unchanged: `archive()`
  returns an `AppendOnlyTreeSnapshot` and `stateReference()` returns `@aztec/stdlib`'s
  `StateReference` over `PartialStateReference`. **No parallel type is declared** —
  `test_tree_snapshot_vocabulary_reused_not_redefined` asserts that.
* **It is the only `*Snapshot*` type in the C++ world-state trees at all.** Searched across
  `world_state/` (9 files), `world_state_reference/` (6) and `crypto/merkle_tree/` (27).
* **`world_state::WorldState` has no export API.** It has forks and checkpoints:
  `create_fork` `:285`, `delete_fork` `:286`, `checkpoint` `:302`, `commit_checkpoint` `:303`,
  `revert_checkpoint` `:304`, `commit_all_checkpoints_to` `:305`, `revert_all_checkpoints_to`
  `:306`. Nothing named `snapshot`, `dump`, `export` or `serialize`.
* **Upstream's real whole-state carrier is a file copy.**
  `NativeWorldStateService.backupTo(dstPath, compact)`
  (`world-state/src/native/native_world_state.ts:420-426`) calls `instance.copyStores(...)`, which
  copies the per-tree LMDB `data.mdb` files, with `stdlib/src/snapshots/`'s `SnapshotDataKeys`
  (`archiver`, `nullifier-tree`, `public-data-tree`, `note-hash-tree`, `archive-tree`,
  `l1-to-l2-message-tree`), `SnapshotMetadata` and `SnapshotsIndex` as the transport vocabulary.
  It is behind `@aztec/world-state` and `@aztec/native` — DD-9 — and it has no wasm counterpart.
* **Nothing serialises a merkle tree's leaves to a portable blob.** `crypto/merkle_tree/` has
  nothing; `foundation/src/trees/merkle_tree.ts:17` exposes `get leaves(): Buffer[]` on an
  in-memory calculator with no `toBuffer` and no persistence format.

**DECISION: the carrier is a REPLAY LOG made of upstream's own serialisation.** `ChainSnapshot`
records, per block, the block's timestamp, its L1-to-L2 messages and its transactions as
`Tx.toBuffer()` hex, plus the fee-juice funding that preceded them. Import replays them in order
at their recorded timestamps into a fresh world state. Defining a state format instead would mean
inventing a serialisation for somebody else's merkle trees, which is the parallel-type mistake one
level up from the one the `TreeSnapshot` deliverable names.

The cost is stated rather than hidden: a replay re-executes, so it costs what the original run
cost, and a chain whose transactions are not reproducible is not exportable this way.
`e2e_chain_snapshot_export_import_roundtrip` measures the property that matters — a fresh runtime
reloaded from a snapshot reaches an identical block number, archive root and four-tree state
reference.

---

## 6. Persistence substrate — `@aztec/kv-store`, as it actually is

The design document said `./indexeddb` and `./sqlite-opfs`. The milestone's correction says the
IndexedDB entry point is `./deprecated/indexeddb` "as of the pinned nightly". **Both sentences are
true of one artefact and false of another, and the difference decides whether an import
resolves.** Measured:

| artefact | version | IndexedDB subpath |
|---|---|---|
| `drift/node_modules/@aztec/kv-store` — `pins.json` `npm.current` | `5.3.0-nightly.20260819` | `./deprecated/indexeddb` |
| `spike/`, `diffsim/`, `probe-mt/` `node_modules` — `npm.deletion_era` | `5.0.0-nightly.20260626` | `./indexeddb` |
| the fork at the `cpp` anchor (2026-08-19) | — | `./deprecated/indexeddb` |
| the fork at the `ts` anchor (2026-06-25) | — | `./indexeddb` |

The rename is fork commit `ffb5fe64bceba54430d207323a0eb03897941cb3`, merged 2026-07-08 — after
the `deletion_era` pin and before the `current` one. So the milestone's correction is right about
`npm.current` and about the anchor, and wrong about the line **`orchestration/` is actually on**:
`orchestration/package.json` pins `deletion_era`, where the subpath is `./indexeddb`.

`@aztec/kv-store` is **not installed under `orchestration/` at all**, so nothing here depends on
either spelling today.

Full export list at the anchor: `.` and `./interfaces` → `dest/interfaces/index.js`, `./lmdb`,
`./lmdb-v2`, `./deprecated/indexeddb`, `./sqlite-opfs`, `./stores`. Every target exists.
Deprecation is marked in three places: `kv-store/README.md:19` ("**deprecated** browser backend …
New browser code must use `@aztec/kv-store/sqlite-opfs`"), `src/deprecated/indexeddb/index.ts:8`
and `src/deprecated/indexeddb/store.ts:45` (`@deprecated` on `class AztecIndexedDBStore`).

**`./sqlite-opfs` is the live browser store and it pulls WASM, not a native addon**:
`src/sqlite-opfs/worker.ts:2` imports `@aztec/sqlite3mc-wasm`, which ships
`vendor/jswasm/sqlite3.wasm` and no `.node` file. `@aztec/native` *is* a dependency of the package
but only `src/lmdb-v2/store.ts:3` reaches it. So a browser build that imports `./sqlite-opfs` and
nothing else does not pull the NAPI addon — which is the fact M27 will need.

---

## 7. What is genuinely ours after all of that

Four things, and they are what the milestone predicted:

1. **`BlockTicker`** — a three-method interface and three implementations
   (`RunningPromiseTicker` over upstream's `RunningPromise`, `ManualTicker`, `DisabledTicker`).
   The interface exists because the thing upstream ticks on cannot be the thing a fake-clock test
   ticks on: `RunningPromise` sleeps against the host's timers, so a hundred blocks at a
   one-second interval is a hundred seconds no matter what clock is injected.
2. **The timestamp rule** — `nextBlockTimestamp`, six lines, in upstream's vocabulary.
3. **`AvmChain`** — block number, queue, archive cursor, block store, L1-to-L2 queue,
   subscriptions, serialised production. No transaction loop and no header construction.
4. **`AvmRuntime`** and **`disclosure.ts`** — the facade's shape (mapped above) and §8.4.

## Outstanding

* **`deploy`, `addAccount`, `getRandomField`, `addAuthWitness` have no counterpart on the facade.**
  The first two need a transaction builder that calls a registered contract, and upstream's only
  one — `PublicTxSimulationTester` in `simulator/src/public/fixtures/` — constructs a
  `NativeWorldStateService`. That is M22's outstanding task and it is still outstanding.
* **`L1TOL2MSGEXISTS` is not exercised.** `e2e_l1_to_l2_message_injection` proves the message is a
  leaf of the L1-to-L2 message tree at the next block boundary and reads it back by index out of
  the module. Proving the AVM's opcode can see it needs a contract that calls it, which needs the
  builder above.
* **`prove` will never have a counterpart**, and that is §8.4 rather than an omission.
