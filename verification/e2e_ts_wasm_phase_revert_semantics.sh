#!/usr/bin/env bash
# e2e_ts_wasm_phase_revert_semantics — M18.
#
# The verification entry: "The asymmetric revert model holds — SETUP revert throws the tx out,
# APP_LOGIC soft-reverts to the post-setup state with teardown still running, TEARDOWN rolls back
# but the tx lands and still pays its fee."
#
# ===========================================================================================
# THE STATED REASON WAS FALSE TWICE OVER, AND THE TRUE GAP WAS NARROWER.
# ===========================================================================================
#
# It said the corpus "has not got" a transaction with calls in more than one phase because "every
# program is one app-logic call". Measured on 2026-08-31: the vendored builder takes the phases
# DIRECTLY — `createTx(sender, setupCalls, appCalls, teardownCall, …)` — and files them into
# `nonRevertibleAccumulatedData`, `revertibleAccumulatedData` and `publicTeardownCallRequest`;
# every live caller passed `[]` and `undefined` by choice, not by limit. And the asymmetry was
# already asserted, over mockTx-built transactions calling UNREGISTERED contracts.
#
# THE TRUE GAP WAS THAT NOTHING PUT A REAL CONTRACT'S CALLS IN SETUP AND TEARDOWN AND SHOWED
# APP_LOGIC SOFT-REVERTING TO THE POST-SETUP STATE. That is what these four arms do.
#
# ===========================================================================================
# FOUR ARMS, ONE VARIABLE EACH, AND THE STATE READ BACK AS VALUES.
# ===========================================================================================
#
# Every arm submits ONE transaction with a real `AvmTest` call in each of the three phases, each
# writing a different key of the contract's own storage map. They differ in which phase additionally
# calls `assertion_failure`:
#
#     allSucceed        nothing fails
#     setupReverts      the SETUP call fails
#     appReverts        the APP-LOGIC call fails
#     teardownReverts   the TEARDOWN call fails
#
# A LATER BLOCK THEN READS THE THREE KEYS BACK through `read_storage_map`, so "soft-reverts to the
# post-setup state" is a comparison of VALUES rather than of a revert code. A revert code says which
# phase complained; only the read-back says what survived.
#
# THE THREE SENTENCES OF THE ENTRY, AND WHERE EACH ONE IS ASSERTED:
#
#   "SETUP revert throws the tx out"          `setupReverts` is in `failed`, not in `processed`, and
#                                             NONE of the three keys is written.
#   "APP_LOGIC soft-reverts to the post-setup  `appReverts` LANDS (processed, revertCode 1), the
#    state with teardown still running"        setup key survives, the app key is rolled back, and
#                                             the TEARDOWN key is written — which is the "teardown
#                                             still running" half, and it is the half a revert code
#                                             cannot show.
#   "TEARDOWN rolls back but the tx lands      `teardownReverts` LANDS, the setup key survives, and
#    and still pays its fee"                   the fee it is charged is asserted equal to the
#                                             all-succeed arm's — which is what "still pays" means.
#
# AND THE MODULE'S OWN FOUR-VALUED REVERT CODE DISCRIMINATES THE TWO SOFT REVERTS. Upstream's
# published `RevertCode` narrows four values to two (DRIFT.md D18), so `appReverts` and
# `teardownReverts` both read 1 there; the module reports 1 and 2. Asserting both is what says the
# two arms reverted in DIFFERENT phases rather than in the same one twice.
#
# Run: just verify-ts-wasm-phases

TEST_NAME="e2e_ts_wasm_phase_revert_semantics"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_token_blocks.sh"

tb_summary_on_abnormal_exit
tb_require_arms
tb_note_provenance

ARMS="phasesAllSucceed phasesSetupReverts phasesAppReverts phasesTeardownReverts"

# ---------------------------------------------------------------------------
# PART 0 — the four arms exist, differ in one thing, and agree about everything else
# ---------------------------------------------------------------------------

assert_eq "an arm that does not exist reads MISSING" "MISSING" "$(tb_arm noSuchArm which)"
for a in $ARMS; do
  assert_eq "$a ran the phase block and the read-back block" \
    '["phases","readBack"]' "$(tb_block_labels "$a")"
done
assert_eq "the four arms are the four cases and not one case four times" "4" \
  "$(for a in $ARMS; do tb_arm "$a" which; done | sort -u | wc -l | tr -d ' ')"
# AGREEMENT PLUS THE VALUE. Four arms that all read `MISSING` agree too, which is what an arm the
# accessor cannot reach looks like — so the address is asserted to be an address before the four are
# asserted to share it.
PHASE_ADDRESS="$(tb_arm phasesAllSucceed contractAddress)"
assert_prefix "the arms name a real contract address" "0x" "$PHASE_ADDRESS"
assert_eq "all four ran against the same contract, so the phase is the only variable" "1" \
  "$(for a in $ARMS; do tb_arm "$a" contractAddress; done | sort -u | wc -l | tr -d ' ')"
assert_eq "…and it is that address" "$PHASE_ADDRESS" "$(tb_arm phasesTeardownReverts contractAddress)"

SETUP_VALUE="$(tb_arm phasesAllSucceed expected.setup)"
APP_VALUE="$(tb_arm phasesAllSucceed expected.app)"
TEARDOWN_VALUE="$(tb_arm phasesAllSucceed expected.teardown)"
assert_eq "the three phases write three DIFFERENT values, so a read-back cannot confuse them" "3" \
  "$(printf '%s\n%s\n%s\n' "$SETUP_VALUE" "$APP_VALUE" "$TEARDOWN_VALUE" | sort -u | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
# PART 1 — THE BASELINE. All three phases run and all three writes survive.
# ---------------------------------------------------------------------------

assert_eq "the all-succeed transaction was processed" \
  '["phased"]' "$(tb_block phasesAllSucceed phases processed)"
assert_eq "and did not revert" "0" "$(tb_block phasesAllSucceed phases revertCodes.phased)"
assert_eq "the module's own code agrees" "0" "$(tb_block phasesAllSucceed phases rawRevertCodes.0)"
assert_ge "it executed a real dispatch across three phases" 300 \
  "$(tb_block phasesAllSucceed phases instructionsPerSimulation.0)"
assert_eq "the setup phase's write survived" \
  "[\"$SETUP_VALUE\"]" "$(tb_block phasesAllSucceed readBack returnValues.0)"
assert_eq "the app-logic phase's write survived" \
  "[\"$APP_VALUE\"]" "$(tb_block phasesAllSucceed readBack returnValues.1)"
assert_eq "the teardown phase's write survived" \
  "[\"$TEARDOWN_VALUE\"]" "$(tb_block phasesAllSucceed readBack returnValues.2)"

# ---------------------------------------------------------------------------
# PART 2 — SETUP REVERT THROWS THE TRANSACTION OUT
# ---------------------------------------------------------------------------

assert_eq "the setup-reverting transaction was NOT processed" \
  "[]" "$(tb_block phasesSetupReverts phases processed)"
assert_eq "it is in the block's FAILED set" \
  '["phased"]' "$(tb_block phasesSetupReverts phases failed \
    | python3 -c 'import json,sys; print(json.dumps([f["label"] for f in json.load(sys.stdin)],separators=(",",":")))')"
assert_contains "and the failure names the SETUP phase" \
  "SETUP" "$(tb_block phasesSetupReverts phases failed \
    | python3 -c 'import json,sys; print(" ".join(f["message"] for f in json.load(sys.stdin)))')"
assert_eq "a thrown-out transaction is charged nothing, because there is no ProcessedTx" \
  "{}" "$(tb_block phasesSetupReverts phases feeByTx)"
assert_eq "and NONE of the three writes survived" '[["0"],["0"],["0"]]' \
  "$(tb_block phasesSetupReverts readBack returnValues)"

# ---------------------------------------------------------------------------
# PART 3 — APP_LOGIC SOFT-REVERTS TO THE POST-SETUP STATE, AND TEARDOWN STILL RUNS
# ---------------------------------------------------------------------------

assert_eq "the app-logic-reverting transaction LANDED" \
  '["phased"]' "$(tb_block phasesAppReverts phases processed)"
assert_eq "and was not thrown out" "[]" "$(tb_block phasesAppReverts phases failed)"
assert_eq "upstream's revert code says it reverted" "1" "$(tb_block phasesAppReverts phases revertCodes.phased)"
assert_eq "the module's own four-valued code says APP_LOGIC" \
  "1" "$(tb_block phasesAppReverts phases rawRevertCodes.0)"
assert_eq "the SETUP write survived the app-logic revert" \
  "[\"$SETUP_VALUE\"]" "$(tb_block phasesAppReverts readBack returnValues.0)"
assert_eq "the APP-LOGIC write was rolled back" '["0"]' "$(tb_block phasesAppReverts readBack returnValues.1)"
assert_eq "AND THE TEARDOWN STILL RAN — its write is there" \
  "[\"$TEARDOWN_VALUE\"]" "$(tb_block phasesAppReverts readBack returnValues.2)"
assert_ge "the transaction was charged a fee" 1 "$(tb_block phasesAppReverts phases feeByTx.phased)"

# ---------------------------------------------------------------------------
# PART 4 — TEARDOWN ROLLS BACK, THE TRANSACTION LANDS, AND IT STILL PAYS
# ---------------------------------------------------------------------------

assert_eq "the teardown-reverting transaction LANDED" \
  '["phased"]' "$(tb_block phasesTeardownReverts phases processed)"
assert_eq "upstream's revert code says it reverted" \
  "1" "$(tb_block phasesTeardownReverts phases revertCodes.phased)"
assert_eq "the module's own four-valued code says TEARDOWN, which is a DIFFERENT phase" \
  "2" "$(tb_block phasesTeardownReverts phases rawRevertCodes.0)"
assert_eq "the SETUP write survived" \
  "[\"$SETUP_VALUE\"]" "$(tb_block phasesTeardownReverts readBack returnValues.0)"
assert_eq "the TEARDOWN write did not" '["0"]' "$(tb_block phasesTeardownReverts readBack returnValues.2)"

# "STILL PAYS ITS FEE" IS A CHARGE AND NOT A GAS FIGURE, and the comparison that makes it a claim
# is against the arm where nothing reverted.
ALL_FEE="$(tb_block phasesAllSucceed phases feeByTx.phased)"
TEARDOWN_FEE="$(tb_block phasesTeardownReverts phases feeByTx.phased)"
assert_ge "the teardown-reverting transaction was charged a fee" 1 "$TEARDOWN_FEE"
assert_eq "and it is the same fee the transaction that did not revert paid" "$ALL_FEE" "$TEARDOWN_FEE"

# ---------------------------------------------------------------------------
# PART 5 — THE ASYMMETRY IS AN ASYMMETRY. The three outcomes are three, not one.
# ---------------------------------------------------------------------------

assert_eq "the three revert phases produced three different module codes" "3" \
  "$(printf '%s\n%s\n%s\n' \
      "$(tb_block phasesAllSucceed phases rawRevertCodes.0)" \
      "$(tb_block phasesAppReverts phases rawRevertCodes.0)" \
      "$(tb_block phasesTeardownReverts phases rawRevertCodes.0)" | sort -u | wc -l | tr -d ' ')"
# "THE ONLY ONE" IS ASSERTED AS A COUNT OVER ALL FOUR, not claimed beside a single reading.
assert_eq "the setup arm produced no ProcessedTx at all" \
  "[]" "$(tb_block phasesSetupReverts phases rawRevertCodes)"
assert_eq "…and it is the ONLY arm of the four that did not" "1" \
  "$(for a in $ARMS; do [ "$(tb_block "$a" phases rawRevertCodes)" = "[]" ] && echo x; done | wc -l | tr -d ' ')"
assert_eq "and the read-backs are three different patterns" "3" \
  "$(printf '%s\n%s\n%s\n' \
      "$(tb_block phasesAllSucceed readBack returnValues)" \
      "$(tb_block phasesAppReverts readBack returnValues)" \
      "$(tb_block phasesTeardownReverts readBack returnValues)" | sort -u | wc -l | tr -d ' ')"

# The read-back block is itself asserted to work, so "everything reads zero" in the setup arm is a
# fact about that arm and not about a reader that always answers zero.
#
# THE FIRST VERSION OF THIS ASSERTED ONLY THAT THE FOUR ARMS AGREED — a set of size one — which four
# arms whose read-backs all REVERTED would satisfy just as well. A set size standing in for a value
# is the same shape as a depth of zero standing in for a merge, and it is asserted as the VALUE now,
# with the agreement kept beside it.
READBACK_CODES='{"readSetup":0,"readApp":0,"readTeardown":0}'
assert_eq "the read-back transactions all succeeded, in every arm" "1" \
  "$(for a in $ARMS; do tb_block "$a" readBack revertCodes; done | sort -u | wc -l | tr -d ' ')"
for a in $ARMS; do
  assert_eq "…and in $a the three reads are the three that did not revert" \
    "$READBACK_CODES" "$(tb_block "$a" readBack revertCodes)"
done

finish
