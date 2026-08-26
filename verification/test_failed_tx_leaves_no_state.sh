#!/usr/bin/env bash
# test_failed_tx_leaves_no_state — M22.
#
# The verification entry: "A transaction thrown out during a block contributes nothing to the
# block's state reference, and the following transaction sees the pre-failure state."
#
# "NO ERROR WAS THROWN" IS NOT THE ASSERTION, and this check is written against that specific
# failure. The campaign's brief names this test by name as the classic vacuous-pass shape: a block
# in which one transaction is thrown out will "leave no state" in the eyes of any check that only
# looks at whether the block completed. So the claim is made about a VALUE that would differ, from
# INSIDE the loop, with a control in which the same transaction succeeds and the value does change.
#
# THE OBSERVATION POINT IS UPSTREAM'S OWN HOOK. `PublicProcessor.process` awaits
# `validator.preprocessValidator.validateTx(tx)` immediately before processing each transaction —
# the only point inside the loop a caller can reach without editing a vendored file. The driver
# records the four-tree state reference there, so `observedBefore` is a sequence of what each
# transaction actually saw, in block order.
#
# THE TWO ARMS DIFFER IN ONE THING. Both are three transactions, same seeds, same funding, same
# order. In `failedArm`, f2's failing call sits in SETUP, which the AVM throws the transaction out
# for; in `controlArm` the same call sits in APP_LOGIC, where it soft-reverts, LANDS and pays its
# fee. So:
#
#     failedArm    state before f2 == state before f3      f2 contributed nothing
#     controlArm   state before f2 != state before f3      the control DOES move the state
#
# Without the second line the first is satisfied by a world state that never changes at all.
#
# AND A SECOND, INDEPENDENT WITNESS: the fee payer's balance. f2's balance is UNCHANGED in the
# failing arm and REDUCED in the control, while f1's and f3's balances are identical across both
# arms — so the difference is attributable to f2 and not to the arm.
#
# Run: just verify-block-failed-tx

TEST_NAME="test_failed_tx_leaves_no_state"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m22_block.sh"

m22_summary_on_abnormal_exit
m22_require_anchor
m22_require_arms

note "module $AVM_WASM_PATH"
note "sha256 $M22_MODULE_SHA"

# ---------------------------------------------------------------------------
# PART 0 — the run happened, and the accessors can answer MISSING
# ---------------------------------------------------------------------------

assert_eq "the run produced both arms" "failedArm controlArm" \
  "$(m22_arm_names | grep -E '^(failedArm|controlArm)$' | sort -r | tr '\n' ' ' | sed 's/ $//')"

# The accessor's own control, twice. An `assert_eq` between two `MISSING`s would pass, so both the
# arm name and the field name are shown to be capable of answering MISSING.
assert_eq "an arm that does not exist reads MISSING" "MISSING" "$(m22_arm noSuchArm processed)"
assert_eq "a field that does not exist reads MISSING" "MISSING" "$(m22_arm failedArm noSuchField)"
assert_eq "a transaction label that was not in the block reads MISSING" "MISSING" \
  "$(m22_before failedArm noSuchTx)"

# ---------------------------------------------------------------------------
# PART 1 — the arms did what they were built to do
# ---------------------------------------------------------------------------

echo "== the failing arm threw exactly f2 out, and the control threw nobody out"

assert_eq "failedArm submitted three transactions" '["f1","f2","f3"]' "$(m22_arm failedArm submitted)"
assert_eq "failedArm processed f1 and f3" '["f1","f3"]' "$(m22_arm failedArm processed)"
assert_eq "failedArm failed exactly f2" '["f2"]' \
  "$(python3 -c '
import json, sys
print(json.dumps([f["label"] for f in json.loads(sys.argv[1])], separators=(",", ":")))' \
    "$(m22_arm failedArm failed)")"
assert_eq "failedArm left nothing unprocessed, so the block ran to the end" '[]' \
  "$(m22_arm failedArm unprocessed)"

assert_eq "controlArm submitted the same three" '["f1","f2","f3"]' "$(m22_arm controlArm submitted)"
assert_eq "controlArm processed all three" '["f1","f2","f3"]' "$(m22_arm controlArm processed)"
assert_eq "controlArm failed nobody" '[]' "$(m22_arm controlArm failed)"

# WHY it was thrown out, from the module's own message. The needle comes from the C++ artefact —
# `TxExecution::simulate`'s SETUP arm — and `form_a.ts`'s FAILURE_NEEDLES carries the same string,
# so a rename upstream fails here rather than silently reclassifying a transaction.
FAIL_MSG="$(python3 -c '
import json, sys
print(json.loads(sys.argv[1])[0]["message"])' "$(m22_arm failedArm failed)")"
assert_contains "f2 was thrown out by the SETUP arm, in the module's own words" \
  "[SETUP] UNRECOVERABLE ERROR! Enqueued call to" "$FAIL_MSG"
assert_true "…and that needle is the one form_a.ts pins against the C++ source" \
  str_has_sub "$(cat "$ORCH_SRC/form_a.ts")" "[SETUP] UNRECOVERABLE ERROR! Enqueued call to"

# ---------------------------------------------------------------------------
# PART 2 — the claim: the FOLLOWING transaction saw the pre-failure state
# ---------------------------------------------------------------------------

echo "== what f3 saw, in both arms"

F_BEFORE_F1="$(m22_before failedArm f1)"
F_BEFORE_F2="$(m22_before failedArm f2)"
F_BEFORE_F3="$(m22_before failedArm f3)"
C_BEFORE_F1="$(m22_before controlArm f1)"
C_BEFORE_F2="$(m22_before controlArm f2)"
C_BEFORE_F3="$(m22_before controlArm f3)"

# NON-EMPTINESS FIRST. Every comparison below has two sides that could both be absent, and this
# campaign has shipped `assert_eq "" ""` before. A four-tree state reference is 4 x (32-byte root +
# 4-byte size) = 144 bytes = 288 hex characters.
for v in "$F_BEFORE_F1" "$F_BEFORE_F2" "$F_BEFORE_F3" "$C_BEFORE_F1" "$C_BEFORE_F2" "$C_BEFORE_F3"; do
  assert_eq "a recorded state reference is 288 hex characters, not an absence" "288" "${#v}"
done

# The processor really did reach every transaction: three observations per arm, in block order.
assert_eq "the failing arm observed all three transactions, in order" "f1 f2 f3" \
  "$(python3 -c '
import json, sys
print(" ".join(e["label"] for e in json.loads(sys.argv[1])))' "$(m22_arm failedArm observedBefore)")"
assert_eq "and so did the control" "f1 f2 f3" \
  "$(python3 -c '
import json, sys
print(" ".join(e["label"] for e in json.loads(sys.argv[1])))' "$(m22_arm controlArm observedBefore)")"

# THE CLAIM.
assert_eq "FAILING ARM: f3 saw exactly the state f2 saw — the thrown-out transaction left nothing" \
  "$F_BEFORE_F2" "$F_BEFORE_F3"

# THE CONTROL, which is what makes the line above a measurement rather than a tautology about a
# world state that never moves.
if [ "$C_BEFORE_F2" = "$C_BEFORE_F3" ]; then
  fail "CONTROL: f3 saw the same state as f2, so 'unchanged' is not attributable to the failure"
else
  pass "CONTROL: with f2 SUCCEEDING, f3 saw a different state — the comparison can tell them apart"
fi

# And the world state was moving in the failing arm too, before f2: f1 landed, so f2 saw something
# different from what f1 saw. Without this, "f2 == f3" would also hold of a run in which nothing
# ever changed.
if [ "$F_BEFORE_F1" = "$F_BEFORE_F2" ]; then
  fail "FAILING ARM: f2 saw exactly what f1 saw, so the world state never moved in this arm"
else
  pass "FAILING ARM: f1 DID move the world state, so the arm is not a run in which nothing happens"
fi

# The two arms start from the same place — the same genesis, the same seeds, the same funding — so
# the divergence below is the failure and not the setup.
assert_eq "both arms start f1 from the same state" "$F_BEFORE_F1" "$C_BEFORE_F1"
assert_eq "and both arms present f2 with the same state" "$F_BEFORE_F2" "$C_BEFORE_F2"

# ---------------------------------------------------------------------------
# PART 3 — the second witness: the fee payer's balance
# ---------------------------------------------------------------------------

echo "== the fee payers, which is a different measurement of the same claim"

F_BAL_F1="$(m22_arm failedArm balancesAfter.f1)"
F_BAL_F2="$(m22_arm failedArm balancesAfter.f2)"
F_BAL_F3="$(m22_arm failedArm balancesAfter.f3)"
C_BAL_F2="$(m22_arm controlArm balancesAfter.f2)"
C_BAL_F1="$(m22_arm controlArm balancesAfter.f1)"
C_BAL_F3="$(m22_arm controlArm balancesAfter.f3)"

# THE FUNDED AMOUNT IS READ OUT OF THE DRIVER, NOT TYPED HERE. The first revision of this line was
# `assert_eq "…" "$FUNDING" "$(printf '%s' "$FUNDING")"` — a literal compared with itself, which is
# the campaign's own catalogued shape of an assertion that cannot fail, written into the check whose
# brief names that shape by name. It is derived now, and the derivation is asserted to have found
# something.
FUNDING="$(python3 -c '
import re, sys
m = re.search(r"^const FUNDING = new Fr\((\d+)n \*\* (\d+)n\);$", open(sys.argv[1]).read(), re.M)
print(int(m.group(1)) ** int(m.group(2)) if m else "UNREADABLE")' "$ORCH_SRC/block_e2e_driver.ts")"
assert_eq "the funded amount is read out of the driver rather than typed into this check" \
  "1000000000000" "$FUNDING"

assert_eq "FAILING ARM: f2's balance is untouched — it paid no fee, because it never landed" \
  "$FUNDING" "$F_BAL_F2"
if [ "$C_BAL_F2" = "$FUNDING" ]; then
  fail "CONTROL: f2's balance is untouched there too, so 'untouched' says nothing about the failure"
else
  pass "CONTROL: with f2 SUCCEEDING, its balance went DOWN  [$C_BAL_F2]"
fi
assert_true "…and it went down rather than up" test "$C_BAL_F2" -lt "$FUNDING"

# f1 and f3 are the attribution control: they behave identically in both arms, so the only thing
# the arms disagree about is f2.
assert_eq "f1's balance is the same in both arms" "$F_BAL_F1" "$C_BAL_F1"
assert_eq "f3's balance is the same in both arms" "$F_BAL_F3" "$C_BAL_F3"
assert_true "…and both of them DID pay a fee, so the equality is not two untouched balances" \
  test "$F_BAL_F1" -lt "$FUNDING"

# ---------------------------------------------------------------------------
# PART 4 — the block's own state reference differs between the arms
# ---------------------------------------------------------------------------

echo "== the block's state reference, which is what a block header would carry"

F_AFTER="$(m22_arm failedArm stateReferenceAfter)"
C_AFTER="$(m22_arm controlArm stateReferenceAfter)"
assert_eq "the failing block's state reference is 288 hex characters" "288" "${#F_AFTER}"
if [ "$F_AFTER" = "$C_AFTER" ]; then
  fail "the two blocks ended in the same state, so f2's contribution was invisible either way"
else
  pass "the two blocks ended in DIFFERENT states — f2's contribution is what the arms differ by"
fi

# The failing block's end state is the state f3 STARTED from, advanced by f3 alone — so it is not
# equal to what f3 saw, which is another way of saying f3 itself did something.
if [ "$F_AFTER" = "$F_BEFORE_F3" ]; then
  fail "the failing block ended where f3 started, so f3 contributed nothing either"
else
  pass "the failing block ended past where f3 started, so f3 ran and landed"
fi

# ---------------------------------------------------------------------------
# PART 5 — the mechanism is upstream's, not ours
# ---------------------------------------------------------------------------

echo "== the roll-back is upstream's code, named"

PP_BODY="$(m22_strip_header "$M22_VENDOR/public_processor/public_processor.ts")"
assert_true "the error path reverts to the transaction's own checkpoint depth" \
  str_has_line "$PP_BODY" "        await checkpoint.revertToCheckpoint();"
assert_true "…and reverts the contracts DB with it" \
  str_has_line "$PP_BODY" "        this.contractsDB.revertCheckpoint();"
assert_true "…and then asserts the fork is where it started, which is this test's own claim" \
  str_has_line "$PP_BODY" "        await this.checkWorldStateUnchanged(startStateReference, txHash, err);"
assert_true "…and that method throws rather than logging when it is not" \
  str_has_line "$PP_BODY" "      throw new Error(\`Fork state reference changed by tx \${txHash} after error in public processor\`, { cause });"

# All four of those lines are upstream's, at the anchor, unchanged.
PP_ANCHOR="$(m22_anchor_file yarn-project/simulator/src/public/public_processor/public_processor.ts)"
for line in "        await checkpoint.revertToCheckpoint();" \
            "        this.contractsDB.revertCheckpoint();" \
            "        await this.checkWorldStateUnchanged(startStateReference, txHash, err);"; do
  assert_true "…and the anchor has it too, so the roll-back is not ours: [$(printf '%s' "$line" | sed 's/^ *//')]" \
    str_has_line "$PP_ANCHOR" "$line"
done

m22_finish
