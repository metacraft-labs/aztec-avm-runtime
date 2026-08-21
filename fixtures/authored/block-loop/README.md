# Tier E, family 1 — the timer-driven block loop

**Authored. There is no upstream fixture for this, and the checks below re-verify that claim
against upstream on every run rather than restating it.**

Fixtures here are written under **M23**, when the chain loop is built. What M2 owes is the entry:
what has to be authored, why nothing upstream can be reused instead, and a justification that a
checker can falsify. `verify_tier_e_authored_fixtures_justified` re-derives every numbered claim
below from the pinned fork; if upstream lands any of them, the check goes red and this family has
to be re-argued rather than quietly kept.

Tier E is deliberately the smallest tier in `fixtures/MANIFEST.md`, and the manifest check asserts
that mechanically: Tier E must have strictly fewer entries than every other tier.

## What upstream DOES have, and is reused rather than reinvented

Naming these first, because the failure mode this campaign keeps hitting is enumerating a package
without descending into its subdirectories, and then declaring the contents "genuinely ours".

| upstream | what it gives us | decision |
|---|---|---|
| `yarn-project/foundation/src/timer/date.ts` — `ManualDateProvider` | A fully frozen clock (`now()`, `setTime`, `advanceTime`, `advanceTimeMs`), written precisely to remove real-time flakiness. This is the injected clock; we do not write one. | reuse |
| `yarn-project/foundation/src/promise/running-promise.ts` — `RunningPromise` | The poll loop `Sequencer` and `AutomineSequencer` already tick on, with `jest.useFakeTimers()` coverage of start / stop / restart and "a second start does not spawn a second poll loop". | reuse |
| `yarn-project/sequencer-client/src/sequencer/automine/automine_sequencer.ts` | `buildEmptyBlock()`, `warpTo`/`warpBy`, the slot-boundary clamp `targetSlot <= lastBuiltSlot -> lastBuiltSlot + 1`. | REUSE-INVENTORY.md RI-41, `open`, verdict due M23 |
| `yarn-project/sequencer-client/src/sequencer/checkpoint_proposal_job.timing.test.ts` | The *pattern* to copy: subclass the job and override `waitUntilNextSubslot` / `waitForTxsPollingInterval` so they advance a `ManualDateProvider` instead of sleeping. | reuse the pattern |
| `yarn-project/stdlib/src/interfaces/aztec-node-debug.ts` — `AztecNodeDebug` | The facade shape: `mineBlock`, `warpL2TimeAtLeastTo`, `warpL2TimeAtLeastBy`. | RI-41 |

So the *primitives* are upstream's. What is missing is a fixture that asserts the **loop's**
behaviour over a sequence of blocks.

## The four claims that make this family necessary

Each is a statement about the pinned fork, and each is re-checked mechanically.

1. **`yarn-project/sequencer-client/src/sequencer/automine/` contains no test file at all.**
   At the `cpp` anchor the directory is exactly `README.md`, `automine_factory.ts`,
   `automine_sequencer.ts`, `index.ts` — **zero** `*.test.ts`. `buildEmptyBlock()` and the
   slot-boundary clamp are untested upstream. (Claim id: `automine-has-no-tests`.)

2. **Upstream's only deadline test is skipped.**
   `yarn-project/simulator/src/public/public_processor/public_processor.test.ts:269` is
   `it.skip('does not go past the deadline', …)` at **both** anchors, with the comment "Flakey
   timing test that's totally dependent on system load/architecture etc." There is no passing test
   anywhere that the block deadline is honoured. (Claim id: `deadline-test-skipped`.)

3. **The standard block test double produces a CONSTANT timestamp.**
   `yarn-project/stdlib/src/rollup/checkpoint_header.ts`'s `CheckpointHeader.random()` sets
   `timestamp: BigInt(Math.floor(Date.now() / 1000))`. Every block a test generates through it
   carries the same wall-clock second, so no upstream helper can produce a sequence of blocks with
   monotonically increasing timestamps to assert against. (Claim id: `random-header-constant-timestamp`.)

4. **TXE's block-sequence helper does not advance time either.**
   `yarn-project/txe/src/oracle/txe_oracle_top_level_context.ts`'s `advanceBlocksBy(n)` is a bare
   `for` loop over `mineBlock()`, and `nextBlockTimestamp` is mutated in exactly one place —
   `advanceTimestampBy` — so `advanceBlocksBy(n)` mines *n* blocks all stamped with the same
   timestamp. It is a block-count helper, not a clock. (Claim id: `txe-advance-blocks-shares-timestamp`.)

## Fixtures to author (M23)

| fixture | assertion | why upstream cannot supply it |
|---|---|---|
| `block_per_tick` | Driving the loop on a `ManualDateProvider` for *N* ticks produces exactly *N* blocks. | Claim 1: the automining sequencer has no tests; `running-promise.test.ts` proves N ticks → N calls of an arbitrary function, never of block production. |
| `monotonic_timestamps` | Across a sequence of blocks, `header.globalVariables.timestamp` is strictly increasing. | Claims 3 and 4: both upstream block generators emit a constant timestamp. Upstream's nearest assertion (`end-to-end/src/composed/e2e_cheat_codes.test.ts`) compares exactly one block pair, and needs a live network. |
| `empty_block_on_idle` | With no pending transactions, a tick still produces a well-formed empty block, and the world-state roots advance exactly as an empty block requires. | Claim 1. Upstream's `'publishes two empty blocks'` is an end-to-end test needing anvil and a real 12-second slot clock, and asserts only `blockNumber >= 3`. |
| `deadline_truncates_block` | A deadline reached mid-transaction truncates the block and rolls the partial transaction back cleanly, with roots equal to the pre-transaction roots. | Claim 2: upstream's deadline test is skipped, and it asserts a processed-count, not roots. |

Every one of the four asserts **world-state roots** where roots are meaningful, because that is
what upstream's mock-based checkpoint tests (`public_processor.test.ts`'s four `checkpoint depth`
cases) structurally cannot do: they assert against a mock, so they pin the call sequence and not
the resulting state.

## Licence

Authored here. Any upstream code these fixtures drive stays Apache-2.0 under
`fixtures/CORPUS.md`'s licence table.
