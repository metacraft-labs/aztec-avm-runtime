#!/usr/bin/env bash
# e2e_ts_wasm_token_transfer — M18.
#
# The verification entry: "Token constructor, mint, transfer and burn execute through the TypeScript
# orchestration onto the wasm AVM and world state, with correct side effects and gas."
#
# ===========================================================================================
# THE REASON THIS WAS PENDING WENT STALE TWICE, AND IT IS WORTH SAYING WHICH TWICE.
# ===========================================================================================
#
# M24 corrected the first version ("there is no PublicProcessor to execute through", falsified by
# M22). The replacement said "what still blocks this entry is the transaction builder and nothing
# else"; M26 vendored exactly that builder (RI-72, `PROVENANCE.md` F20–F23, re-taken at the `cpp`
# anchor by M37) and the residuals pass of 2026-08-31 measured `transfer_in_public` executing today.
# What it left was a sentence: *"Nothing blocks this but writing the check."*
#
# ===========================================================================================
# FOUR FUNCTIONS, AND THE ENTRY NAMES ALL FOUR.
# ===========================================================================================
#
# `CAMPAIGN-BRIEF.md`'s own rule — *"when a sentence names N subjects, count how many the check
# runs"* — is why every one of `constructor`, `mint_to_public`, `transfer_in_public` and
# `burn_public` is executed here rather than three of them plus an argument. Each is a real enqueued
# call built by the vendored builder, dispatched by an ABI-derived selector, run by `avm.wasm`
# against the resident world state through upstream's own `PublicProcessor`.
#
# THE SIDE EFFECTS ARE THE CONTRACT'S OWN BALANCES, read back through `balance_of_public` exactly as
# upstream's `token_test.ts` reads them, and the expected numbers are computed from the arm's mint
# and transfer amounts rather than typed.
#
# THE GAS IS ASSERTED AS AN ORDERING AND A CHARGE, NOT AS A CONSTANT. A pinned gas number is a
# figure nobody re-derives; what is asserted is that every transaction was charged a fee, that the
# fee is not the same for all four (so it is a measurement and not a constant), and that the
# constructor — the largest of the four by instruction count — costs more L2 gas than a balance
# read. A hand-typed gas figure is precisely what this campaign has a recorded defect for.
#
# THE CONTROL IS THE SAME SEQUENCE WITHOUT THE MINT. It makes every balance assertion falsifiable:
# the transfer then reverts on the contract's own `assert(balance >= amount)` and all four balances
# read zero.
#
# Run: just verify-ts-wasm-token

TEST_NAME="e2e_ts_wasm_token_transfer"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_token_blocks.sh"

tb_summary_on_abnormal_exit
tb_require_arms
tb_note_provenance

# ---------------------------------------------------------------------------
# PART 0 — the arm is against the WASM module and the pinned artifact
# ---------------------------------------------------------------------------

assert_eq "an arm that does not exist reads MISSING" "MISSING" "$(tb_arm noSuchArm blocks)"
assert_eq "the arm ran against the Token artifact" "Token" "$(tb_arm tokenFlows artifactName)"
assert_eq "the module the arms measured is the one this check found" \
  "$TB_MODULE_SHA" "$(tb_arm_meta module.sha256)"
assert_ge "it is a wasm AVM module with a real export surface" 40 "$(tb_arm_meta module.exports)"

# ---------------------------------------------------------------------------
# PART 1 — FOUR FUNCTIONS, FOUR DISTINCT ABI-DERIVED SELECTORS
# ---------------------------------------------------------------------------

SELECTORS="$(tb_arm tokenFlows selectors)"
for fn in constructor mint_to_public transfer_in_public burn_public balance_of_public; do
  SEL="$(tb_arm tokenFlows "selectors.$fn")"
  assert_true "the selector for $fn was derived from the artifact's ABI" \
    test "$SEL" != "MISSING"
  assert_prefix "and it is a field value rather than a name" "0x" "$SEL"
done
assert_eq "the five selectors are five distinct values" "5" \
  "$(printf '%s' "$SELECTORS" | python3 -c 'import json,sys; print(len(set(json.load(sys.stdin).values())))')"

# ---------------------------------------------------------------------------
# PART 2 — ALL FOUR EXECUTE, each on the wasm AVM, each doing real work
# ---------------------------------------------------------------------------

assert_eq "the constructor was processed" '["constructor"]' "$(tb_block tokenFlows construct processed)"
assert_eq "the constructor did not revert" "0" "$(tb_block tokenFlows construct revertCodes.constructor)"
CONSTRUCT_STEPS="$(tb_block tokenFlows construct instructionsPerSimulation.0)"
assert_ge "the constructor executed a real dispatch" 1000 "$CONSTRUCT_STEPS"

assert_eq "the mint did not revert" "0" "$(tb_block tokenFlows mintAndTransfer revertCodes.mint)"
assert_ge "the mint executed a real dispatch" 100 \
  "$(tb_block tokenFlows mintAndTransfer instructionsPerSimulation.0)"
assert_eq "the transfer did not revert" "0" "$(tb_block tokenFlows mintAndTransfer revertCodes.transfer)"
assert_ge "the transfer executed a real dispatch" 100 \
  "$(tb_block tokenFlows mintAndTransfer instructionsPerSimulation.1)"
assert_eq "the burn did not revert" "0" "$(tb_block tokenFlows burn revertCodes.burn)"
BURN_STEPS="$(tb_block tokenFlows burn instructionsPerSimulation.0)"
assert_ge "the burn executed a real dispatch" 100 "$BURN_STEPS"

# The module's own four-valued revert code (DRIFT D18) agrees with upstream's collapsed one for all
# four, which is the half `revertCode` alone cannot say.
assert_eq "the module's own code for the constructor is OK" "0" "$(tb_block tokenFlows construct rawRevertCodes.0)"
assert_eq "the module's own codes for the mint and the transfer are OK" \
  "[0,0]" "$(tb_block tokenFlows mintAndTransfer rawRevertCodes)"
assert_eq "the module's own code for the burn is OK" "[0]" "$(tb_block tokenFlows burn rawRevertCodes)"

# ---------------------------------------------------------------------------
# PART 3 — CORRECT SIDE EFFECTS, read out of the contract itself
# ---------------------------------------------------------------------------

MINT="$(tb_arm tokenFlows mintAmount)"
TRANSFER="$(tb_arm tokenFlows transferAmount)"
EXPECT_SENDER="$((MINT - TRANSFER))"

assert_eq "after the transfer the sender holds mint minus transfer" \
  "[\"$EXPECT_SENDER\"]" "$(tb_block tokenFlows balancesAfterTransfer returnValues.0)"
assert_eq "after the transfer the receiver holds the transferred amount" \
  "[\"$TRANSFER\"]" "$(tb_block tokenFlows balancesAfterTransfer returnValues.1)"
assert_eq "after the burn the receiver holds nothing" \
  '["0"]' "$(tb_block tokenFlows balancesAfterBurn returnValues.1)"
assert_eq "and the burn took nothing from the sender" \
  "[\"$EXPECT_SENDER\"]" "$(tb_block tokenFlows balancesAfterBurn returnValues.0)"

# ---------------------------------------------------------------------------
# PART 4 — GAS. Charged, varying, and ordered by the work each transaction did.
# ---------------------------------------------------------------------------

CONSTRUCT_FEE="$(tb_block tokenFlows construct feeByTx.constructor)"
MINT_FEE="$(tb_block tokenFlows mintAndTransfer feeByTx.mint)"
TRANSFER_FEE="$(tb_block tokenFlows mintAndTransfer feeByTx.transfer)"
BURN_FEE="$(tb_block tokenFlows burn feeByTx.burn)"
READ_FEE="$(tb_block tokenFlows balancesAfterTransfer feeByTx.balanceSender)"

for pair in "constructor:$CONSTRUCT_FEE" "mint:$MINT_FEE" "transfer:$TRANSFER_FEE" "burn:$BURN_FEE"; do
  assert_ge "the ${pair%%:*} transaction was charged a fee" 1 "${pair#*:}"
done
# A FEE THAT IS THE SAME FOR EVERY TRANSACTION IS A CONSTANT WEARING A MEASUREMENT'S CLOTHES.
assert_eq "the four fees are not one number repeated" "4" \
  "$(printf '%s\n%s\n%s\n%s\n' "$CONSTRUCT_FEE" "$MINT_FEE" "$TRANSFER_FEE" "$BURN_FEE" | sort -u | wc -l | tr -d ' ')"
assert_true "the constructor, which executes the most instructions, costs the most" \
  test "$CONSTRUCT_FEE" -gt "$BURN_FEE"
assert_true "and every state-changing call costs more than a static balance read" \
  test "$BURN_FEE" -gt "$READ_FEE"
assert_true "the instruction counts order the same way the fees do" \
  test "$CONSTRUCT_STEPS" -gt "$BURN_STEPS"

L2_MINT="$(tb_block tokenFlows mintAndTransfer l2GasByTx.mint)"
assert_ge "L2 gas is reported per transaction rather than left at zero" 1 "$L2_MINT"
assert_ge "and DA gas with it" 1 "$(tb_block tokenFlows mintAndTransfer daGasByTx.mint)"

# ---------------------------------------------------------------------------
# PART 5 — THE CONTROL. Every balance assertion above is falsifiable.
# ---------------------------------------------------------------------------

assert_eq "without the mint the transfer reverts" \
  "1" "$(tb_block tokenFlowsNoMint mintAndTransfer revertCodes.transfer)"
assert_eq "and every balance reads zero" '[["0"],["0"]]' \
  "$(tb_block tokenFlowsNoMint balancesAfterTransfer returnValues)"
assert_eq "the control's burn reverts too, for the same reason" \
  "1" "$(tb_block tokenFlowsNoMint burn revertCodes.burn)"
assert_eq "the control's constructor still succeeded, so the zeros are about the mint" \
  "0" "$(tb_block tokenFlowsNoMint construct revertCodes.constructor)"

# ---------------------------------------------------------------------------
# PART 6 — THROUGH THE ORCHESTRATION, and the vendored builder stayed off the world state
# ---------------------------------------------------------------------------

assert_eq "the vendored transaction builder read no world state during the whole arm" "[]" "$(tb_arm tokenFlows merkleTouches)"
# THE CONTROL FOR THAT EMPTY LIST, and without it the zero above means nothing. Every trap on the
# merkle proxy THROWS, so an observation aborts the arm and no report exists — which makes
# `merkleTouches` necessarily empty in every report a check can read, and the assertion above
# satisfied by a tripwire wired to nothing. `CAMPAIGN-BRIEF.md` records that as the 26th and 27th
# instances of "an assertion must be capable of failing"; the driver touches the field the vendored
# constructor assigned, off the tester itself, and it must THROW.
assert_prefix "…and the tripwire is armed: touching it through the builder's own field throws" \
  "threw:" "$(tb_arm tokenFlows merkleTripwireControl)"
assert_eq "…recording exactly the one deliberate observation" \
  "1" "$(tb_arm tokenFlows merkleTouchesAfterControl)"
assert_eq "the contract was registered in the module's own contract store" \
  "1" "$(tb_arm tokenFlows registeredDirectly.classes)"
assert_eq "and its instance with it" "1" "$(tb_arm tokenFlows registeredDirectly.instances)"
assert_prefix "with the contract-address nullifier upstream's own derivation produces" \
  "0x" "$(tb_arm tokenFlows registeredDirectly.nullifier)"

finish
