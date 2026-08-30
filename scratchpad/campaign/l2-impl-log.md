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
