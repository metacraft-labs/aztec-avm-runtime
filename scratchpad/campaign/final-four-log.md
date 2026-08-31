# Final-four pass — the last four `pending` entries that are real work in this repository

Started 2026-08-31, immediately after the closeout pass. Baseline: `dev` `e0d45b6`, sweep
**12,534**, `delta +0`, pending 21 -> 13.

The four, in the order the brief gives (tractable first):

1. **M18 `e2e_ts_wasm_amm`**
2. **M25 `test_nested_call_reverted_contributes_no_side_effects`**
3. **M25 `e2e_trace_token_transfer_steppable`**
4. **M21 `test_form_b_tx_matches_pxe_bytes`**

## Step 0 — context read, and the state found

Read in full: `CAMPAIGN-BRIEF.md` (2,788 lines), `scratchpad/campaign/closeout-log.md`,
`scratchpad/campaign/residuals-log.md`, `scratchpad/campaign/m37-review-log.md`, and
`OUT-OF-SCOPE.md`.

State at start, measured:

| repo | branch | HEAD | vs origin | tree |
|---|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `e0d45b6` | 0/0 | clean |
| `codetracer-specs` | `latest` | `1f2cc1ae` | 0/0 | clean |

No `verify-m` / `verify-l` process running (`ps aux` grep: zero matches). Load average 0.60.

---

## ENTRY 1 — M18 `e2e_ts_wasm_amm`

### Step 1.1 — what the entry asked for, and where each piece already was

The entry's residue, re-measured by the closeout pass, named five things. All five compose from
machinery that exists:

| the residue asks for | what supplies it |
|---|---|
| three Token instances plus the AMM | `createContractClassAndInstance` + `registerDirectly` (RI-72 + the closeout pass's own helper) |
| its own `constructor` per contract | `runOneBlock`, four transactions in one block |
| `set_minter` | one more transaction; `is_minter` READ BACK as the discriminator |
| balance seeding | `Token._increase_public_balance`, self-sent per token — upstream's own shape |
| each internal call with `sender` set to the AMM | `TestEnqueuedCall.sender`, which the vendored builder already honours |

The recipe is upstream's `yarn-project/simulator/src/public/fixtures/amm_test.ts` at the `cpp`
anchor, call for call — **except that upstream runs three of the AMM's four `abi_only_self`
entry points and this runs four.** `_swap_tokens_for_exact_tokens` is the fourth.

Upstream's partial-note workaround is kept as one: each `finalize_*_to_private` consumes a
partial-note VALIDITY COMMITMENT the private half would have emitted, computed with upstream's own
`poseidon2HashWithSeparator(…, DomainSeparator.PARTIAL_NOTE_VALIDITY_COMMITMENT)` and inserted
siloed by the emitting token. Eight of them.

### Step 1.2 — it ran first time, and the numbers are the pool's own

Three arms — `amm`, `ammNotSelfSent`, `ammNoMinter` — twelve blocks each, one variable each.

```
poolBefore        0            0            lpSupply 0
addLiquidity      600,000,000  500,000,000  lpSupply 100,000   locked 1,000
swapExactIn       640,000,000  468,837,908
swapExactOut      639,000,000  469,573,822
removeLiquidity   638,361,000  469,104,249  lpSupply 99,900
```

Every one of those is `Token.balance_of_public(amm)` or `Token.total_supply()` static-called in a
LATER block — the contracts' own view functions, never a hand-derived storage slot. The check
asserts them as DELTAS and as the pool's own CONSTANT-PRODUCT INVARIANT, not as constants.
Instruction counts 2,051 / 1,346 / 1,834 / 2,326 against 202 for a view call.

### Step 1.3 — a defect in this pass's own work, found by running

`artifactOnlySelfPublicFunctions` — the scan that makes *"the four this arm drives are all four the
artifact declares"* a measurement rather than a list — came back **EMPTY**, because it read the
LOADED artifact and `loadContractArtifact` does not carry `custom_attributes` through. An empty
list makes "these four are all of them" a comparison of one empty set with another, so the check
asserts the scan found FOUR *before* comparing the sets. Read off the raw JSON now.
