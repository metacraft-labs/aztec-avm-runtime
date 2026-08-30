# L2 — implementation log

Kept in the shape L0's and L1's are: what was tried, what it measured, and the two
things that were wrong on the first run and are recorded rather than quietly fixed.

## The order the work actually happened in

1. **Re-took both of the campaign's standing chain facts before building on them.**
   - The retention horizon HOLDS, and on mainnet too, which L1 had not measured.
     Testnet 2026-08-30T13:59Z: tip 62635, `finalized` 62606. Block 62606's transaction
     → `getTxByHash` **null**; 62617 and 62628 → served in full. Mainnet the same
     minute: tip 66288, `finalized` 66250, transactions at 66214 and 66217 both
     **null**, both `TxEffect`s served.
   - "Mainnet is live and completely idle" is **retired**. Blocks 66214 and 66217 carry
     real transactions. But one per seventy blocks against a 38-block window means a
     scan of the whole replayable window finds zero — a mainnet demo needs a follower.
   - Testnet has a **heartbeat**: one transaction every eleven blocks almost exactly
     (62507, 62518, … 62628, 62639), same contract, same 23,157 bytes as L1's fixture.

   **A scanning bug worth recording, because it produced a confident wrong answer.**
   The first activity scan called `getBlock(n)` WITHOUT `{ includeTransactions: true }`
   and counted `body.txEffects`. That answer has no `body` at all — the body-less block
   L0 met live and L1 captured as an artefact — so the scan reported **135 consecutive
   empty testnet blocks** over a range that in fact had thirteen transactions in it.
   The tell was in the same response and was not being read: `header.totalManaUsed` was
   non-zero. Every later scan uses mana as the activity signal and fetches the body only
   for blocks that show it.

2. **Took L1's one handoff first**: the reference block on the wire, as an OPTION with
   `latest` as the default, so L1's un-recapturable recordings keep playing back.
   `just verify-l1` re-taken: **280 / 0**, unchanged.

3. **Spiked the execution before writing a module** (`l2_spike.mjs`). The first run died
   at `compileAvm`: `vm2wasm/avm.wasm` is M6's early artefact and OWNS ITS MEMORY, which
   `node-host`'s loader refuses by name. The module L2 needs is the M27 browser-gate
   build.

4. **The spike executed the real settled transaction on its first working run** — 181
   instructions, into APP_LOGIC, reverting at an assertion where the chain succeeded.
   The last four opcodes before `REVERT_8` were `NULLIFIEREXISTS` → `JUMPI_32` →
   `INTERNALCALL` → `SET_64`, so the missing state was a nullifier the contract requires
   to exist.

5. **Guessed once and it was wrong, which is why the loop exists.** The guess was the
   initialization nullifier, `siloNullifier(address, address)`. Seeding it changed
   nothing: still 181 instructions, still reverting. Guessing what a contract reads does
   not scale past the first guess.

6. **`collectHints` ended the guessing.** With it on, the result carries
   `getPreviousValueIndexHints` — every world-state query the run made, by tree id and
   value. The nullifier the contract wanted was `0x11df9e9c…`, present on chain, and
   there was also a public-data slot `0x093b0ba4…` the transaction reads and does not
   write. Neither was reachable from the `TxEffect`.

7. **The fixpoint loop converged in six rounds** and the replay reproduced the
   transaction: 23 comparisons, 0 mismatches, and gas that sums to the block's own
   `totalManaUsed`.

## Two defects shipped in L2's own loop and caught

Both are this campaign's most-repeated shapes, in the code written to avoid them.

- **A swallowed refusal read as a smaller round rather than a red one.** The loop's
  first version wrote `catch { queries = [] }`. A live run then spent twelve rounds
  printing "0 queries, 0 seeded" and died with `HydrationDidNotConverge` — true and
  useless, over a module that had been saying *"Not enough balance for fee payer to pay
  for transaction"* every single time. Fixed by carrying `refusal` on the round record
  and by adding `ModuleRefusedReplay` as a **separate class**: non-convergence means the
  query set is still growing; this means it stopped growing and the answer is still no.

- **A type check that made every witness read as absent.** `answerQueries` tested
  `typeof leafPreimage.slot !== 'string'`. Through the **client** the response has been
  through upstream's own zod, so the slot is an `Fr`. All nine write-set slots went
  silently unseeded and the failure surfaced four layers away as the fee-payer refusal.
  The reader now takes either shape and returns `undefined` rather than coercing to
  `0x0` — **a zero is a legitimate leaf value here**, four of the subject's nine writes
  are zeros, so a coerced zero would be indistinguishable from a real one.

## What is NOT here

The three named `verification/*.sh` checks. `just replay-settled` exercises the path and
exits non-zero on a mismatch, so it is a check before a check wraps it — but it is not
three scripts with counted assertions, controls and mutation arms. Until it is, L2's
evidence is one green run and not a measured floor.

The control that matters most, named so it is not re-derived: **seed the pre-state at
block 62639 instead of 62638** and the replay reads the values the transaction ITSELF
wrote. That is the "green and measuring nothing" arm this deliverable most needs.

---

# L2's verification, added after the first landing

The first L2 commit named the three `verification/*.sh` checks as **not done** rather
than letting `just replay-settled` exiting non-zero stand in for a gate. They exist now.

## The floor

| check | assertions | what its control is |
|---|---|---|
| `e2e_replay_matches_published_effects` | **92** | the SAME loop with the pre-state read at the SETTLING block instead of its parent — every read returns the value the transaction itself wrote |
| `verify_hydrated_roots_match_state_reference` | **91** | `declareTreeRoots` handed the CHAIN'S OWN roots must answer `agrees` for all four; plus a half-control perturbing one root by one nibble |
| `verify_state_route_decided_on_measurement` | **99** | the two upstream sources re-read from the anchor's OBJECT STORE, with every absence paired to a presence from the same file |

`just verify-l2` — **282 assertions, 0 failures**, offline, against the M27 module.
`just verify-l1` went 292 → **328** (141 / 110 / 77) with the `capturedBy` assertions.

## The mutation harness — 16 arms red, 1 recorded survivor

`scratchpad/campaign/l2-mutations.sh`. The three that matter:

- **M6** makes `preStateBlockForControls` a no-op → 16 failures, ALL in §3 and §4.
  This is the arm that tests the **control** rather than the subject: without it,
  "the control does not reproduce" could be true because the control never ran.
- **M14** reports the roots as the UNSEEDED ones while leaving seeding intact → exactly
  **2** failures, both §2's "the tree MOVED", with §1 entirely green. That is the proof
  §2 is load-bearing: an EMPTY tree also differs from the chain.
- **M11** turns `collectHints` off → 7 failures including "the module reported real
  world-state queries: expected >= 15, got 0". Route 3's premise, measured.

**M13 mutates the FIXTURE**, in L1's discipline: one recorded `getPublicDataWitness`
value incremented by one → 5 failures. The slot still matches, so the hydration seeds it
happily; only the arithmetic downstream disagrees. That is a wrong VALUE at a RIGHT slot,
which is the exact shape `historical_state.ts` refuses to produce by coercion.

## Three things the harness found in L2's own work

1. **`MHANG` was not a hang.** Its first form was `await new Promise(() => {})`, which has
   no pending handle — node's loop drains and the process exits **13** on "unsettled
   top-level await". A die-before-summary wearing a hang's label. **L1's review recorded
   the identical trap and I walked into it anyway.** Fixed with a long TIMER, which is a
   live handle: rc **124**, killed at its bound.
2. **`M5` SURVIVES, and is recorded as a survivor rather than deleted.**
   `reproduced: comparisons.length > 0 && …` — the length guard is **unreachable**, because
   `revertCode`, `transactionFee` and the two length comparisons are pushed
   unconditionally, so the array is never empty for any input. Not even a transaction with
   no public half distinguishes the two forms. A mutation nothing can kill is a fact about
   the code, not a gap in the check. The guard is kept and `replay_execution.ts` now says
   why at the line.
3. **`M8` could not reach the section it was written for**, and is kept labelled COARSE.
   With nothing seeded the AVM refuses and the probe dies first, so what caught it was the
   exit-status assertion — MDIE's statement, not §2's. M14 was written to actually reach §2.

## The regeneration wiring, which was missing

`testnet_settled_tx_refblock.json` names a capture script that needs
`--pin-reference-block`, and **no recipe passed it** — so the fixture was frozen by an
accident of the CLI rather than by the retention horizon, which is the only reason a
fixture here is allowed to be frozen. Now `just capture-replay-fixture pin=1`, proven by
regenerating to a scratch path: a fresh transaction in block **62672**, with
`aztec_getContract ["0x2a9a1d0e…", 62672]` on the wire.

`l1_prepare` now asserts, for every declared fixture, that `provenance.capturedBy` names a
script that exists and is TRACKED — so the wiring is checked offline instead of described.
It deliberately does NOT assert that re-running reproduces the file: against a live chain
it never could, and L1's two transactions are gone.
