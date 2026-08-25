#!/usr/bin/env bash
# e2e_form_a_teardown_revert_still_pays_fee — M20.
#
# The deliverable: "A reverting teardown rolls back to the post-setup state, and the transaction
# still lands and still pays its fee."
#
# THE PAIR IS THE TEST. `teardownReverts` and `noTeardown` are the SAME mock seed, the same
# APP_LOGIC call, the same globals and the same funding; they differ in exactly one thing — one
# carries a teardown call request and the other does not. Anything that moves between them is
# caused by the teardown, and anything that does not move is not. A single-arm test would assert
# "a transaction with a teardown paid a fee", which is also true of a transaction whose teardown
# never ran.
#
# BOTH HALVES CARRY AN APP_LOGIC CALL, AND THAT IS A MEASURED DECISION RATHER THAN A DETAIL.
# Teardown gas is accounted SEPARATELY and is not billed. Measured on this module: a transaction
# whose only work is a failing teardown reports `totalGas 0` and `transactionFee 0x0`, so "it
# still pays its fee" would be vacuously true of a fee of nothing. With an APP_LOGIC call in both
# halves the fee is non-zero on both sides and the revert code is free to move.
#
# THE REVERT CODE ONLY MOVES IF YOU READ THE RIGHT ONE, WHICH IS THE FINDING THIS CHECK CARRIES.
# The C++ `RevertCode` has four values; the published `@aztec/stdlib` narrows it to two
# (`RevertCodeEnum` is `OK = 0` / `REVERTED = 1`, and `toRevertCodeEnum` coerces "any value >= 1"
# to 1). So `PublicTxResult.revertCode.getCode()` reads 1 for BOTH halves and cannot tell a
# teardown revert from an app-logic one; M17's `TxOutcome.revertCode`, which does not narrow,
# reads 3 and 1. Both are asserted, in both directions, so the narrowing is pinned as a property
# of the published package rather than rediscovered as a mystery.
#
# Run: just verify-form-a-teardown

TEST_NAME="e2e_form_a_teardown_revert_still_pays_fee"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m20_form_a.sh"

m20_require_anchor
m20_require_arms
mkdir -p "$M20_WORK"
SCRATCH="$(mktemp -d "$M20_WORK/teardown.XXXXXX")" || die "no scratch under $M20_WORK"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# PART 1 — the control flow, read out of the C++ at the pinned anchor
# ---------------------------------------------------------------------------

TXE="$SCRATCH/tx_execution.cpp"
m20_anchor_file barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/tx_execution.cpp > "$TXE"
assert_ge "tx_execution.cpp was read from the anchor" 400 "$(wc -l < "$TXE")"

assert_ge "a teardown failure is CAUGHT rather than escaping" 1 \
  "$(grep -c 'Teardown failure while simulating tx ' "$TXE")"
assert_ge "and rolls back to the post-setup checkpoint" 1 \
  "$(grep -c 'We rollback to the post-setup state' "$TXE")"
assert_ge "setting TEARDOWN_REVERTED, or BOTH_REVERTED when app logic had already reverted" 1 \
  "$(grep -c 'RevertCode::BOTH_REVERTED' "$TXE")"

# The load-bearing ordering: pay_fee is AFTER the teardown catch and outside it, which is the
# whole reason a reverted teardown still pays. Asserted by line number rather than by presence,
# because "both lines exist" is also true of a file where the fee is paid first.
CATCH_LINE="$(grep -n 'Teardown failure while simulating tx ' "$TXE" | head -1 | cut -d: -f1)"
PAY_LINE="$(grep -n '^    pay_fee(tx.fee_payer, fee, fee_per_da_gas, fee_per_l2_gas);' "$TXE" | head -1 | cut -d: -f1)"
note "teardown catch at line $CATCH_LINE, pay_fee at line $PAY_LINE"
assert_true "the teardown catch was found" test -n "$CATCH_LINE"
assert_true "and the pay_fee call was found" test -n "$PAY_LINE"
assert_true "pay_fee comes AFTER the teardown catch, which is why a reverted teardown still pays" \
  test "$PAY_LINE" -gt "$CATCH_LINE"

# ---------------------------------------------------------------------------
# PART 2 — the pair really differs in exactly the teardown request
# ---------------------------------------------------------------------------

assert_eq "the teardown arm carries a teardown call request" "1" \
  "$(m20_arm teardownReverts shape.teardown)"
assert_eq "and its partner carries none" "0" "$(m20_arm noTeardown shape.teardown)"
assert_eq "both carry one APP_LOGIC call" "1|1" \
  "$(m20_arm teardownReverts shape.appLogic)|$(m20_arm noTeardown shape.appLogic)"
assert_eq "and neither carries a SETUP call" "0|0" \
  "$(m20_arm teardownReverts shape.setup)|$(m20_arm noTeardown shape.setup)"
assert_true "the teardown request costs wire bytes, so the two are genuinely different payloads" \
  test "$(m20_arm teardownReverts shape.wireBytes)" -gt "$(m20_arm noTeardown shape.wireBytes)"

# ---------------------------------------------------------------------------
# PART 3 — it lands, it pays, and the revert code says teardown
# ---------------------------------------------------------------------------

assert_eq "the transaction with the reverting teardown LANDS" "landed" \
  "$(m20_arm teardownReverts external.kind)"
assert_eq "and so does its partner, so landing is not what the teardown changed" "landed" \
  "$(m20_arm noTeardown external.kind)"

TD_RAW="$(m20_arm teardownReverts external.rawRevertCode)"
NT_RAW="$(m20_arm noTeardown external.rawRevertCode)"
TD_TYPED="$(m20_arm teardownReverts external.revertCode)"
NT_TYPED="$(m20_arm noTeardown external.revertCode)"
note "raw revert codes: teardown $TD_RAW, no-teardown $NT_RAW"
note "typed revert codes: teardown $TD_TYPED, no-teardown $NT_TYPED"

assert_eq "the module's own revert code is BOTH_REVERTED (3) when app logic AND teardown revert" \
  "3" "$TD_RAW"
assert_eq "and APP_LOGIC_REVERTED (1) when only app logic does" "1" "$NT_RAW"
assert_true "so the raw code DOES discriminate the pair" test "$TD_RAW" != "$NT_RAW"

# THE FOUR-VALUED CODE IS THE RUNTIME'S OWN OUTCOME, NOT A NUMBER THE DRIVER SCRAPED.
# D18's decision is that this runtime reports the module's four-valued code and carries upstream's
# collapsed one only for consumers that demand that type. An earlier revision captured the raw code
# in a closure the DRIVER hung on the boundary, which made "which phase reverted" a property of the
# test harness rather than of the runtime — a consumer of `executeExternallySettledTx` still could
# not tell a teardown revert from an app-logic one. `FormALanded` carries it now, so these are
# assertions about the shipped path.
assert_ge "FormALanded declares the module's four-valued revert code as an outcome field" 1 \
  "$(grep -c 'readonly revertCode: number | undefined;' <(sed -n '/export interface FormALanded/,/^}/p' "$ORCH_SRC/form_a.ts") || true)"
assert_ge "and the phase it names" 1 \
  "$(grep -c 'readonly revertedIn: TxRevertPhase | undefined;' <(sed -n '/export interface FormALanded/,/^}/p' "$ORCH_SRC/form_a.ts") || true)"
assert_eq "the four phase names are the C++ RevertCode's own order" \
  "['none', 'appLogic', 'teardown', 'both']" \
  "$(grep -oE "\['none', 'appLogic', 'teardown', 'both'\]" "$ORCH_SRC/form_a.ts" | head -1)"
# And it arrives, named, on the arms — with the pair DISCRIMINATED by it, which is the whole point.
assert_eq "the reverting-teardown arm names BOTH phases" "both" \
  "$(m20_arm teardownReverts external.revertedIn)"
assert_eq "and its partner names only app logic" "appLogic" \
  "$(m20_arm noTeardown external.revertedIn)"
assert_true "so the NAMED phase discriminates the pair, which upstream's type cannot" \
  test "$(m20_arm teardownReverts external.revertedIn)" != "$(m20_arm noTeardown external.revertedIn)"
# The control: a landing arm that did NOT revert at all would name 'none', so the vocabulary is
# not one that only ever says the same thing. No arm here reaches it — every arm's call fails —
# so this is asserted as the mapping rather than as an observation, from the table itself.
assert_eq "and index 0 of that table is 'none', so a non-reverting transaction is expressible" \
  "none" "$(grep -oE "\['none'" "$ORCH_SRC/form_a.ts" | head -1 | tr -d "[']")"

# The narrowing, pinned in both directions.
assert_eq "upstream's published RevertCode narrows both to 1" "1|1" "$TD_TYPED|$NT_TYPED"
assert_eq "so the TYPED code cannot discriminate the pair, and a check reading only it would pass on either" \
  "same" "$([ "$TD_TYPED" = "$NT_TYPED" ] && echo same || echo different)"

# The narrowing is upstream's code, not a decode of ours. Read out of the installed package.
RC="$ORCH_DIR/node_modules/@aztec/stdlib/dest/avm/revert_code.js"
assert_file "the published RevertCode implementation is installed" "$RC"
assert_ge "it coerces any value >= 1 to 1" 1 \
  "$(grep -c 'return value >= 1 ? 1 : 0;' "$RC")"
assert_eq "and declares only two enum members, so the four-valued C++ code cannot survive it" "0" \
  "$(grep -c 'TEARDOWN_REVERTED\|BOTH_REVERTED' "$RC" || true)"
# The control: the four-valued spelling DOES exist on the C++ side, so the grep above is looking
# for something that exists somewhere rather than for a string nobody uses.
assert_ge "while the C++ does declare BOTH_REVERTED" 1 "$(grep -c 'BOTH_REVERTED' "$TXE")"

# ---------------------------------------------------------------------------
# PART 4 — it still pays, and the payment is read out of the tree
# ---------------------------------------------------------------------------

TD_FEE="$(python3 -c 'import sys; print(int(sys.argv[1], 16))' "$(m20_arm teardownReverts external.transactionFee)")"
TD_BEFORE="$(m20_arm teardownReverts balanceBefore)"
TD_AFTER="$(m20_arm teardownReverts balanceAfter)"
note "teardown arm: $TD_BEFORE -> $TD_AFTER, fee $TD_FEE"

assert_true "the reverting-teardown transaction paid a NON-ZERO fee" test "$TD_FEE" -gt 0
assert_true "its balance was read out of the tree before the run" test "$TD_BEFORE" != "null"
assert_eq "and it was debited by exactly the reported fee" "$TD_FEE" \
  "$(python3 -c 'import sys; print(int(sys.argv[1]) - int(sys.argv[2]))' "$TD_BEFORE" "$TD_AFTER")"

# The rollback: the teardown's own state changes are discarded, so the pair pays the SAME fee.
# Teardown gas is accounted separately and is not billed, which is what makes this equality the
# expected result rather than a coincidence.
NT_FEE="$(python3 -c 'import sys; print(int(sys.argv[1], 16))' "$(m20_arm noTeardown external.transactionFee)")"
assert_eq "the reverted teardown adds nothing to the billed fee — teardown gas is not billed" \
  "$NT_FEE" "$TD_FEE"
assert_eq "and both consumed the same L2 gas" \
  "$(m20_arm noTeardown external.totalGas)" "$(m20_arm teardownReverts external.totalGas)"

finish
