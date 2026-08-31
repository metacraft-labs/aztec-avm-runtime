#!/usr/bin/env bash
# e2e_block_token_flows — M22.
#
# The verification entry: "Token operations spanning several transactions in one block produce the
# expected final state."
#
# ===========================================================================================
# WHAT WAS BLOCKING THIS AND WHAT ACTUALLY WAS.
# ===========================================================================================
#
# The recorded blocker was "the same transaction-builder fact as the deployments entry" — upstream's
# only builder constructs a `NativeWorldStateService`, the package DD-9 forbids. M26 vendored the
# builder without that edge (RI-72, `PROVENANCE.md` F20–F23) and the residuals pass of 2026-08-31
# measured the blocker dead, leaving one sentence: *"What does not exist is a check that submits two
# or more Token transactions before one produceBlock and asserts the final balances."* This is it.
#
# ===========================================================================================
# WHY THE ARM IS SHAPED THE WAY IT IS.
# ===========================================================================================
#
# `orchestration/src/token_block_driver.ts` runs upstream's own `token_test.ts` sequence — the file
# is vendored into this repository three times over as `diffsim/`, `spike/` and `drift/`'s
# `token_test.ts` (RI-25) — through `assembleBlock`, which is M22's own machinery unchanged:
#
#     block `construct`             the contract's `constructor`, alone, because every `#[public]`
#                                   function of a contract with an initializer calls
#                                   `assert_is_initialized_public` first
#     block `mintAndTransfer`       *** TWO TRANSACTIONS, ONE BLOCK *** — the mint and the transfer
#     block `balancesAfterTransfer` the balances, read back through the contract's own `#[view]`
#     block `burn` / `balancesAfterBurn`
#
# THE BALANCES ARE READ OUT OF THE CONTRACT, NOT DERIVED BESIDE IT. Upstream's own `checkBalance`
# calls `balance_of_public` as a static call and compares its app-logic RETURN VALUE, and so does
# this. Nothing here computes a storage slot: the constructor and the mint RUN, so the balances are
# whatever the contract itself wrote. A slot derived in a check is a second thing to keep in step
# with the contract, and this campaign has a rule about exactly that.
#
# AND THE EXPECTED NUMBERS ARE DERIVED FROM THE ARM'S OWN AMOUNTS. 100 minted and 50 transferred
# gives 50 and 50; the burn of 50 gives 50 and 0. Both are computed from `mintAmount` and
# `transferAmount` as the driver reports them, so an arm that changed its amounts changes the
# expectations with it — rather than reddening a constant somebody would then re-type.
#
# THE CONTROL IS `tokenFlowsNoMint`, AND IT IS THE WHOLE OF THE DISCRIMINATION. The identical
# sequence with the MINT TRANSACTION NOT SUBMITTED: the transfer then meets an empty balance, the
# contract's own `assert(balance >= amount)` fires, and every balance comes back zero. Without it,
# "the final state is right" is satisfied by a balance reader that returns a constant.
#
# Run: just verify-block-token-flows

TEST_NAME="e2e_block_token_flows"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_token_blocks.sh"

tb_summary_on_abnormal_exit
tb_require_arms
tb_note_provenance

# ---------------------------------------------------------------------------
# PART 0 — the accessors' own controls
# ---------------------------------------------------------------------------

assert_eq "an arm that does not exist reads MISSING" "MISSING" "$(tb_arm noSuchArm blocks)"
assert_eq "a block label that does not exist reads MISSING" \
  "MISSING" "$(tb_block tokenFlows noSuchBlock processed)"
assert_eq "the subject arm ran the five blocks this check reads, in order" \
  '["construct","mintAndTransfer","balancesAfterTransfer","burn","balancesAfterBurn"]' \
  "$(tb_block_labels tokenFlows)"
assert_eq "the control arm ran the same five" \
  '["construct","mintAndTransfer","balancesAfterTransfer","burn","balancesAfterBurn"]' \
  "$(tb_block_labels tokenFlowsNoMint)"
assert_eq "the subject arm submitted the mint" "true" "$(tb_arm tokenFlows expectMint)"
assert_eq "the control arm did not" "false" "$(tb_arm tokenFlowsNoMint expectMint)"
assert_eq "both arms ran against the same contract, so the one variable is the mint" \
  "$(tb_arm tokenFlows contractAddress)" "$(tb_arm tokenFlowsNoMint contractAddress)"

MINT="$(tb_arm tokenFlows mintAmount)"
TRANSFER="$(tb_arm tokenFlows transferAmount)"
assert_ge "the arm minted something" 1 "$MINT"
assert_true "the arm transferred less than it minted, so the two expectations differ" \
  test "$TRANSFER" -lt "$MINT"
EXPECT_SENDER="$((MINT - TRANSFER))"
EXPECT_RECEIVER="$TRANSFER"

# ---------------------------------------------------------------------------
# PART 1 — SEVERAL TRANSACTIONS IN ONE BLOCK. The entry's first clause.
# ---------------------------------------------------------------------------

assert_eq "the mint and the transfer were submitted to ONE block" \
  '["mint","transfer"]' "$(tb_block tokenFlows mintAndTransfer submitted)"
assert_eq "and that one block processed both, in submission order" \
  '["mint","transfer"]' "$(tb_block tokenFlows mintAndTransfer processed)"
assert_eq "neither was thrown out" "[]" "$(tb_block tokenFlows mintAndTransfer failed)"
assert_eq "and neither was left unreached" "[]" "$(tb_block tokenFlows mintAndTransfer unprocessed)"
assert_eq "the mint did not revert" "0" "$(tb_block tokenFlows mintAndTransfer revertCodes.mint)"
assert_eq "the transfer did not revert" "0" "$(tb_block tokenFlows mintAndTransfer revertCodes.transfer)"

# THE TRANSACTIONS RAN. A transaction that reverts at its first instruction reports `processed`;
# this campaign shipped that once and every floor it added was satisfied by it.
assert_ge "the mint executed a real dispatch" 100 \
  "$(tb_block tokenFlows mintAndTransfer instructionsPerSimulation.0)"
assert_ge "the transfer executed a real dispatch" 100 \
  "$(tb_block tokenFlows mintAndTransfer instructionsPerSimulation.1)"
assert_eq "the block made exactly two simulations, one per transaction" \
  "2" "$(tb_block tokenFlows mintAndTransfer instructionsPerSimulation \
        | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

# ---------------------------------------------------------------------------
# PART 2 — THE EXPECTED FINAL STATE, read out of the contract
# ---------------------------------------------------------------------------

assert_eq "both balance reads were processed" \
  '["balanceSender","balanceReceiver"]' "$(tb_block tokenFlows balancesAfterTransfer processed)"
assert_eq "the sender's balance after the transfer is mint minus transfer" \
  "[\"$EXPECT_SENDER\"]" "$(tb_block tokenFlows balancesAfterTransfer returnValues.0)"
assert_eq "the receiver's balance after the transfer is the transferred amount" \
  "[\"$EXPECT_RECEIVER\"]" "$(tb_block tokenFlows balancesAfterTransfer returnValues.1)"

assert_eq "the burn did not revert" "0" "$(tb_block tokenFlows burn revertCodes.burn)"
assert_eq "after the burn the sender still holds mint minus transfer" \
  "[\"$EXPECT_SENDER\"]" "$(tb_block tokenFlows balancesAfterBurn returnValues.0)"
assert_eq "and the receiver holds nothing" '["0"]' "$(tb_block tokenFlows balancesAfterBurn returnValues.1)"

# NON-DEGENERACY. Two balances that are equal at every reading are equally explained by a reader
# that returns one constant; the pair after the burn is 50 and 0 and must differ.
assert_true "the two final balances are not the same number" \
  test "$(tb_block tokenFlows balancesAfterBurn returnValues.0)" \
       != "$(tb_block tokenFlows balancesAfterBurn returnValues.1)"

# ---------------------------------------------------------------------------
# PART 3 — THE CONTROL. Without the mint the very same transfer cannot happen.
# ---------------------------------------------------------------------------

assert_eq "the control's block carried the transfer alone" \
  '["transfer"]' "$(tb_block tokenFlowsNoMint mintAndTransfer submitted)"
assert_eq "it was still processed — a revert is not a failure" \
  '["transfer"]' "$(tb_block tokenFlowsNoMint mintAndTransfer processed)"
assert_eq "and it REVERTED, on the contract's own balance assertion" \
  "1" "$(tb_block tokenFlowsNoMint mintAndTransfer revertCodes.transfer)"
assert_contains "the revert names an assertion rather than a missing contract" \
  "Assertion failed" "$(tb_block tokenFlowsNoMint mintAndTransfer revertReasons.transfer)"
assert_ge "the control's transfer executed a real dispatch before reverting" 100 \
  "$(tb_block tokenFlowsNoMint mintAndTransfer instructionsPerSimulation.0)"
assert_eq "so the control's sender balance is zero" \
  '["0"]' "$(tb_block tokenFlowsNoMint balancesAfterTransfer returnValues.0)"
assert_eq "and the control's receiver balance is zero" \
  '["0"]' "$(tb_block tokenFlowsNoMint balancesAfterTransfer returnValues.1)"

# THE CONTROL'S OWN NON-DEGENERACY: its constructor still ran and still succeeded, so the zero
# balances are a fact about the mint and not about a contract that never worked.
assert_eq "the control's constructor ran and succeeded" \
  "0" "$(tb_block tokenFlowsNoMint construct revertCodes.constructor)"
assert_eq "in the same number of instructions as the subject's" \
  "$(tb_block tokenFlows construct instructionsPerSimulation.0)" \
  "$(tb_block tokenFlowsNoMint construct instructionsPerSimulation.0)"

# ---------------------------------------------------------------------------
# PART 4 — the block is a BLOCK: it advanced the world state, and the builder never touched one
# ---------------------------------------------------------------------------

assert_true "the state reference moved across the mint-and-transfer block" \
  test "$(tb_block tokenFlows construct stateReferenceAfter)" \
       != "$(tb_block tokenFlows mintAndTransfer stateReferenceAfter)"
assert_eq "the vendored transaction builder never read a world state" "[]" "$(tb_arm tokenFlows merkleTouches)"
assert_eq "the contract store's checkpoint depth is back to zero after the block" \
  "0" "$(tb_block tokenFlows mintAndTransfer checkpointDepthAfter.contracts)"

finish
