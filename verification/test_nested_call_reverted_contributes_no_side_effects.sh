#!/usr/bin/env bash
# test_nested_call_reverted_contributes_no_side_effects — M25.
#
#   verification/test_nested_call_reverted_contributes_no_side_effects.sh
#   (or: just verify-nested-reverted-no-side-effects)
#
# ============================================================================================
# THE BLOCKER WAS A CORPUS GAP, AND THE REMEDY IS A CONTRACT.
# ============================================================================================
#
# This entry asks for a nested frame that MAKES a side effect and then REVERTS while the OUTER call
# goes on to succeed. The closeout pass proved by enumeration that the pinned corpus cannot express
# it: of `AvmTest`'s 127 functions, exactly TWO recover from a failed nested call, and NEITHER
# nested target makes a side effect. That enumeration is RE-DERIVED here rather than quoted — see
# §6 — because a figure nobody re-derives rots.
#
# So the contract is authored: `fixtures/transpiler-contracts/nested_effects/`, compiled by the
# nargo M31 builds from the anchor's own `noir` submodule and transpiled to AVM bytecode by the
# module M31 runs IN CHROMIUM. That is the intended use of M30 and M31, and it is why this check
# reads M31's arm report: the bytes it executes are the bytes a page produced.
#
# ============================================================================================
# THREE INDEPENDENT WITNESSES, BECAUSE ONE OF THEM IS NOT ENOUGH.
# ============================================================================================
#
#   1. the transaction's own `TxEffect.nullifiers` — what it RECORDED;
#   2. public storage read back through the contract itself in a later block — what the tree HOLDS;
#   3. a follow-up transaction re-emitting each nullifier — what the tree ANSWERS.
#
# Each is asserted in BOTH directions by the succeeding arm, which is the same contract, the same
# outer function and the same nested CALL with the callee not failing. Without it, "the inner side
# effects are absent" is equally satisfied by a nested call that never happened, by an SSTORE that
# does not work, and by a reader that always answers zero.
#
# ============================================================================================
# AND THE FOURTH THING, WHICH IS WHAT THE ENTRY IS REALLY ABOUT.
# ============================================================================================
#
# "No side effects" is a much weaker sentence if the frame never MADE any. §5 is the arm that
# separates them: the same outer, the same callee, the same dispatch path, with `arg` deciding
# whether the callee halts BEFORE or AFTER its two side-effect opcodes. The state read-backs of
# those two arms are IDENTICAL — which is the point — and the executed instruction counts are not.
#
# Run: just verify-nested-reverted-no-side-effects

TEST_NAME="test_nested_call_reverted_contributes_no_side_effects"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m31_transpiler.sh"

m31_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is not available"
m31_require_arms

NE="arms.execute.nestedEffects"
REV="$NE.arms.reverting"
SUC="$NE.arms.succeeding"
EARLY="$NE.arms.revertingEarly"

# ---------------------------------------------------------------------------
echo "== 0. the arms ran, and every field this check reads is present"
# ---------------------------------------------------------------------------

AVAILABLE="$(m31_arm arms.execute.available)"
[ "$AVAILABLE" = "true" ] || die "the execute arm did not run: $(m31_arm arms.execute.reason)
     It needs a built avm.wasm. Remedy: just avm-wasm-build-m27, or set AVM_WASM_PATH.
     A skip reported as a pass is worse than a failure."
NE_AVAILABLE="$(m31_arm "$NE.available")"
[ "$NE_AVAILABLE" = "true" ] || die "the nested-effect arms did not run: $(m31_arm "$NE.reason")
     $(m31_arm "$NE.stack")"
assert_eq "the execute arm ran" "true" "$AVAILABLE"
assert_eq "…and the nested-effect arms with it" "true" "$NE_AVAILABLE"
assert_eq "a path that is not in the report reads MISSING" "MISSING" "$(m31_arm "$NE.arms.noSuchArm")"

# ONE ASSERTION THAT NAMES EVERY ABSENT FIELD, run before the first comparison. M29's remedy: a
# report with no data in it is a failure and not a smaller check, and two `MISSING`s compare equal.
ABSENT="$(m31_absent \
  revOuterRc="$(m31_arm "$REV.blocks.0.revertCodes.outer")" \
  sucOuterRc="$(m31_arm "$SUC.blocks.0.revertCodes.outer")" \
  earlyOuterRc="$(m31_arm "$EARLY.blocks.0.revertCodes.outer")" \
  revSteps="$(m31_arm "$REV.blocks.0.instructionsPerSimulation.0")" \
  sucSteps="$(m31_arm "$SUC.blocks.0.instructionsPerSimulation.0")" \
  earlySteps="$(m31_arm "$EARLY.blocks.0.instructionsPerSimulation.0")" \
  revSiloedOuter="$(m31_arm "$REV.siloedNullifiers.outer")" \
  revSiloedInner="$(m31_arm "$REV.siloedNullifiers.inner")" \
  revBytes="$(m31_arm "$REV.dispatchBytecodeBytes")")"
[ -z "$ABSENT" ] || die "the nested-effect arms are missing:$ABSENT — every comparison below would
     compare two absent values."
assert_eq "the arms carry every field this check reads" "" "$ABSENT"

ARTIFACT="$M31_WORK/browser-nested_effects.out.json"
assert_file "the browser's own transpiler output for this fixture is on disk" "$ARTIFACT"
ON_DISK="$(sha256sum "$ARTIFACT" | cut -d' ' -f1)"
assert_eq "the driver was handed that file" "$ON_DISK" "$(m31_arm "$REV.artifactSha256")"
assert_eq "…which is the artifact the identity arm compared" \
  "$(m31_arm identity.nested_effects.browserSha256)" "$ON_DISK"
assert_eq "…and it is byte-identical to the NATIVE transpiler's output" "true" \
  "$(m31_arm identity.nested_effects.identicalBrowserVsNative)"
PROV="$(m31_arm "$REV.bytecodeProvenance")"
assert_contains "the report says where the bytecode came from" "inside Chromium" "$PROV"
assert_contains "…and where it was executed, so the boundary is not left to be inferred" \
  "executed here in Node" "$PROV"

# ---------------------------------------------------------------------------
echo "== 1. the contract is this repository's own, and it is a real program"
# ---------------------------------------------------------------------------

FIXTURE_DIR="$M31_FIXTURES/nested_effects"
assert_dir "the fixture is a source directory in this repository" "$FIXTURE_DIR"
assert_file "…with its own package manifest" "$FIXTURE_DIR/Nargo.toml"
assert_file "…the contract" "$FIXTURE_DIR/src/main.nr"
assert_file "…and the AVM opcode declarations it needs" "$FIXTURE_DIR/src/avm_ops.nr"
assert_eq "the contract the arms ran is the one this fixture declares" "NestedEffects" \
  "$(m31_arm "$REV.artifactName")"
assert_ge "the transpiled dispatch is real bytecode and not an empty buffer" 200 \
  "$(m31_arm "$REV.dispatchBytecodeBytes")"
assert_eq "the fixture is in the corpus the arms enumerate" "true" \
  "$(m31_arm fixtures | python3 -c 'import json,sys; print("true" if "nested_effects" in json.load(sys.stdin) else "false")')"
for who in reverting succeeding revertingEarly; do
  assert_eq "$who: one contract class registered in the module's own store" "1" \
    "$(m31_arm "$NE.arms.$who.registeredDirectly.classes")"
  assert_eq "$who: and one instance" "1" "$(m31_arm "$NE.arms.$who.registeredDirectly.instances")"
done

# ---------------------------------------------------------------------------
echo "== 2. three arms, and each differs from its neighbour in ONE thing"
# ---------------------------------------------------------------------------

assert_eq "the three arms declare three distinct variants" "3" \
  "$(printf '%s\n%s\n%s\n' "$(m31_arm "$REV.variant")" "$(m31_arm "$SUC.variant")" \
      "$(m31_arm "$EARLY.variant")" | sort -u | wc -l | tr -d ' ')"
# THE SUBJECT AND THE INSTRUCTION-COUNT CONTROL TAKE THE SAME PATH. Same outer mode, same callee
# mode — so the only difference between them is the argument, and §5's comparison is not a
# comparison of two different dispatch depths. The first draft of this fixture DID put them in
# separate branches, and the early-reverting arm then executed MORE instructions, not fewer.
assert_eq "the subject and the early-revert control call the same outer function" \
  "$(m31_arm "$REV.outerMode")" "$(m31_arm "$EARLY.outerMode")"
assert_eq "…and the same callee" "$(m31_arm "$REV.calleeMode")" "$(m31_arm "$EARLY.calleeMode")"
assert_true "…and differ only in the argument the outer forwards" \
  test "$(m31_arm "$REV.outerArg")" != "$(m31_arm "$EARLY.outerArg")"
# WHICH CALLEE EACH OUTER MODE CALLS, READ OUT OF THE CONTRACT AND NOT OFF THE DRIVER'S REPORT.
#
# `calleeMode` is a DECLARATION: the callee is compiled into the outer mode's `call_opcode`
# argument and the driver cannot change it. Measured by this pass's own mutation arm B1 — flipping
# the driver's `CALLEE_FOR.succeeds` and nothing else — exactly ONE assertion moved, and it was this
# comparison of two of the driver's own fields. That is "a producer's report about itself is not its
# output" in a small disguise. The mapping is derived from the fixture's own source now and compared
# against the declaration, so the two are two measurements.
FIXTURE_SRC="$FIXTURE_DIR/src/main.nr"
FIXTURE_CODE="$(grep -v '^[[:space:]]*//' "$FIXTURE_SRC")"
assert_ge "the comment stripper left code behind" 20 "$(printf '%s\n' "$FIXTURE_CODE" | grep -c . || true)"
assert_true "…and removed the prose, so a citation cannot be read as a call" \
  test "$(printf '%s\n' "$FIXTURE_CODE" | grep -c . || true)" -lt "$(grep -c . "$FIXTURE_SRC")"
FIXTURE_CALLEES="$(printf '%s\n' "$FIXTURE_CODE" | python3 -c '
import re, sys
cur = None
rows = {}
for line in sys.stdin.read().split("\n"):
    m = re.search(r"(?:if|else if) mode == (\d+) \{", line)
    if m:
        cur = m.group(1)
    c = re.search(r"call_opcode\([^)]*\[selector, (\d+),", line)
    if c and cur is not None:
        rows[cur] = c.group(1)
for k in sorted(rows, key=int):
    print(f"{k} {rows[k]}")
')"
assert_eq "the contract declares exactly two outer modes that make a nested call" "2" \
  "$(printf '%s\n' "$FIXTURE_CALLEES" | grep -c . || true)"
for who in "$REV" "$SUC" "$EARLY"; do
  WANT="$(printf '%s\n' "$FIXTURE_CALLEES" | sed -n "s/^$(m31_arm "$who.outerMode") //p")"
  assert_eq "the callee the driver declares for outer mode $(m31_arm "$who.outerMode") is the one the CONTRACT calls" \
    "$WANT" "$(m31_arm "$who.calleeMode")"
done
assert_true "the succeeding arm calls a DIFFERENT callee, which is what makes it a control" \
  test "$(m31_arm "$REV.calleeMode")" != "$(m31_arm "$SUC.calleeMode")"
assert_eq "the three arms are three distinct contract instances, so no arm sees another's state" \
  "3" "$(printf '%s\n%s\n%s\n' "$(m31_arm "$REV.contractAddress")" "$(m31_arm "$SUC.contractAddress")" \
      "$(m31_arm "$EARLY.contractAddress")" | sort -u | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
echo "== 3. THE HEADLINE: the nested call failed and the OUTER call succeeded"
# ---------------------------------------------------------------------------

assert_eq "the subject's outer transaction did not revert" "0" "$(m31_arm "$REV.blocks.0.revertCodes.outer")"
assert_eq "…and neither did the succeeding arm's" "0" "$(m31_arm "$SUC.blocks.0.revertCodes.outer")"
assert_eq "…nor the early-revert control's" "0" "$(m31_arm "$EARLY.blocks.0.revertCodes.outer")"
# The module's own four-valued code (D18) agrees, which is the half a collapsed `revertCode` cannot
# say on its own.
assert_eq "the module's own code for the subject's outer call is OK too" "[0]" \
  "$(m31_arm "$REV.blocks.0.rawRevertCodes")"

# WHAT THE OUTER FRAME ITSELF OBSERVED. `SUCCESSCOPY` after the CALL, written to a storage slot by
# the contract — so "the nested call failed" is the CONTRACT's own reading and not an inference from
# the state being empty.
VERDICT_FAILED="$(m31_arm "$REV.calleeVerdictValues.failed")"
VERDICT_OK="$(m31_arm "$REV.calleeVerdictValues.succeeded")"
assert_true "the two verdict values are two values" test "$VERDICT_FAILED" != "$VERDICT_OK"
ne_ret() { # <arm-path> <block-index> <return-index>
  m31_arm "$1.blocks.$2.returnValues.$3" | python3 -c '
import json,sys
try:
    v = json.load(sys.stdin)
except Exception:
    print("MISSING"); raise SystemExit(0)
print(v[0] if isinstance(v, list) and len(v) == 1 else "MISSING")
'
}
assert_eq "the subject's outer frame READ the nested call as failed" "$VERDICT_FAILED" "$(ne_ret "$REV" 1 2)"
assert_eq "the succeeding arm's outer frame read it as succeeded" "$VERDICT_OK" "$(ne_ret "$SUC" 1 2)"
assert_eq "the early-revert control's outer frame read it as failed too" "$VERDICT_FAILED" "$(ne_ret "$EARLY" 1 2)"

# ---------------------------------------------------------------------------
echo "== 4. THE VALUES COME FROM THE CONTRACT'S SOURCE, not from this check"
# ---------------------------------------------------------------------------
#
# The two writes the fixture makes are `storage_write_opcode(1, 4242)` in the outer frame and
# `storage_write_opcode(2, 5151)` in the nested one. Both numbers are read OUT OF THE FIXTURE and
# compared against what the AVM wrote, so the check is a comparison of two ends rather than a
# constant typed beside a measurement.

OUTER_SLOT="$(m31_arm "$REV.slots.outer")"
INNER_SLOT="$(m31_arm "$REV.slots.inner")"
OUTER_VALUE="$(sed -n "s/.*storage_write_opcode($OUTER_SLOT, \([0-9]\+\));.*/\1/p" "$FIXTURE_SRC" | sort -u)"
INNER_VALUE="$(sed -n "s/.*storage_write_opcode($INNER_SLOT, \([0-9]\+\));.*/\1/p" "$FIXTURE_SRC" | sort -u)"
assert_eq "the fixture writes ONE value to the outer slot, and the scan found it" "1" \
  "$(printf '%s\n' "$OUTER_VALUE" | grep -c . || true)"
assert_eq "…and one to the inner slot" "1" "$(printf '%s\n' "$INNER_VALUE" | grep -c . || true)"
assert_true "…and the two are different values, so a read-back cannot satisfy both" \
  test "$OUTER_VALUE" != "$INNER_VALUE"

echo "== 4a. WITNESS TWO — public storage, read back through the contract itself"
assert_eq "the subject: the OUTER frame's write survived" "$OUTER_VALUE" "$(ne_ret "$REV" 1 0)"
assert_eq "the subject: the reverted NESTED frame's write did not" "0" "$(ne_ret "$REV" 1 1)"
assert_eq "the control: the outer frame's write survived there too" "$OUTER_VALUE" "$(ne_ret "$SUC" 1 0)"
assert_eq "the control: and the nested frame's write IS there — so the slot works" \
  "$INNER_VALUE" "$(ne_ret "$SUC" 1 1)"
assert_eq "…and every read-back transaction succeeded, so a zero is a value and not a failure" \
  '{"readCalleeVerdict":0,"readInnerSlot":0,"readOuterSlot":0}' "$(m31_arm "$REV.blocks.1.revertCodes")"

# ---------------------------------------------------------------------------
echo "== 4b. WITNESS ONE — the transaction's own TxEffect nullifiers"
# ---------------------------------------------------------------------------

SILOED_OUTER="$(m31_arm "$REV.siloedNullifiers.outer")"
SILOED_INNER="$(m31_arm "$REV.siloedNullifiers.inner")"
assert_true "the two siloed nullifiers are two values" test "$SILOED_OUTER" != "$SILOED_INNER"
assert_prefix "…and they are field values rather than names" "0x" "$SILOED_OUTER"
REV_NULLS="$(m31_arm "$REV.blocks.0.nullifiersByTx.outer")"
SUC_NULLS="$(m31_arm "$SUC.blocks.0.nullifiersByTx.outer")"
assert_contains "the subject's transaction RECORDED the outer frame's nullifier" \
  "$SILOED_OUTER" "$REV_NULLS"
assert_not_contains "…and did NOT record the reverted nested frame's" "$SILOED_INNER" "$REV_NULLS"
assert_contains "the control's transaction recorded the outer frame's" \
  "$(m31_arm "$SUC.siloedNullifiers.outer")" "$SUC_NULLS"
assert_contains "…and the nested frame's WITH it, so the emit works" \
  "$(m31_arm "$SUC.siloedNullifiers.inner")" "$SUC_NULLS"
# The counts, as well as the membership: the two lists differ by exactly one entry, which is what
# says the difference is the nested frame's nullifier and not a list that lost everything.
REV_N="$(printf '%s' "$REV_NULLS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
SUC_N="$(printf '%s' "$SUC_NULLS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
assert_ge "the subject's transaction recorded nullifiers at all" 1 "$REV_N"
assert_eq "…and the control's list is longer by exactly one" "$((REV_N + 1))" "$SUC_N"

# ---------------------------------------------------------------------------
echo "== 4c. WITNESS THREE — what the nullifier tree itself answers"
# ---------------------------------------------------------------------------
#
# A nullifier that landed cannot be emitted again; one that never landed can. Two follow-up
# transactions, two opposite answers — either alone is satisfied by a tree that accepts everything
# or by one that refuses everything.

assert_eq "the subject: re-emitting the reverted frame's nullifier SUCCEEDS — it is still free" \
  "0" "$(m31_arm "$REV.blocks.2.revertCodes.reEmitInner")"
assert_eq "the subject: re-emitting the OUTER frame's nullifier REVERTS — it landed" \
  "1" "$(m31_arm "$REV.blocks.3.revertCodes.reEmitOuter")"
assert_eq "the control: re-emitting the nested frame's nullifier REVERTS there — it landed" \
  "1" "$(m31_arm "$SUC.blocks.2.revertCodes.reEmitInner")"
assert_eq "the control: and the outer frame's reverts too" "1" \
  "$(m31_arm "$SUC.blocks.3.revertCodes.reEmitOuter")"
# THE THIRD ANSWER, so "reverts" is not simply what this contract does when asked to emit. A value
# no frame ever emitted goes in cleanly in both arms.
assert_eq "a nullifier no frame emitted goes in cleanly in the subject" "0" \
  "$(m31_arm "$REV.blocks.4.revertCodes.flatEmit")"
assert_eq "…and in the control" "0" "$(m31_arm "$SUC.blocks.4.revertCodes.flatEmit")"

# ---------------------------------------------------------------------------
echo "== 5. THE EFFECTS WERE MADE AND THEN DISCARDED, which is the entry's real subject"
# ---------------------------------------------------------------------------
#
# "No side effects" is a much weaker sentence about a frame that never made any. The early-revert
# control is the same outer, the same callee and the same dispatch path with the halt moved in
# front of the two side-effect opcodes.

REV_STEPS="$(m31_arm "$REV.blocks.0.instructionsPerSimulation.0")"
EARLY_STEPS="$(m31_arm "$EARLY.blocks.0.instructionsPerSimulation.0")"
SUC_STEPS="$(m31_arm "$SUC.blocks.0.instructionsPerSimulation.0")"
FLAT_STEPS="$(m31_arm "$REV.blocks.4.instructionsPerSimulation.0")"

assert_ge "the subject executed a real dispatch rather than halting at instruction one" 20 "$REV_STEPS"
assert_true "…and more than a transaction that makes no nested call at all" \
  test "$REV_STEPS" -gt "$FLAT_STEPS"
assert_true "THE REVERTED FRAME REACHED ITS SIDE EFFECTS: it executed more instructions than the
             same frame halted in front of them" \
  test "$REV_STEPS" -gt "$EARLY_STEPS"
assert_true "…and fewer than the frame that ran to completion" test "$REV_STEPS" -lt "$SUC_STEPS"
# AND THE DIFFERENCE IS INVISIBLE IN THE STATE, which is why the count is the instrument. The two
# arms' three read-backs are identical to the value; only the instruction count separates them.
assert_eq "the two reverting arms leave IDENTICAL state, so the count is the only discriminator" \
  "$(m31_arm "$REV.blocks.1.returnValues")" "$(m31_arm "$EARLY.blocks.1.returnValues")"
assert_true "…and their instruction counts are not identical" test "$REV_STEPS" != "$EARLY_STEPS"
assert_eq "the early-revert control's nested frame left no nullifier either" "0" \
  "$(m31_arm "$EARLY.blocks.2.revertCodes.reEmitInner")"

# ---------------------------------------------------------------------------
echo "== 6. THE CORPUS GAP, re-derived from upstream's own source rather than quoted"
# ---------------------------------------------------------------------------
#
# The entry's stated reason is an enumeration over `AvmTest`'s Noir source at the `cpp` anchor. A
# figure nobody re-derives rots, so it is re-taken here — anchored to a DEFINITION (`fn <name>(`)
# and not to a mention, because that source carries a commented-out call to one of the two.

ANCHOR="$(python3 -c 'import json;print(json.load(open("pins.json"))["anchors"]["cpp"]["commit"])')"
AVMTEST_PATH='noir-projects/labs/noir-contracts/contracts/test/avm_test_contract/src/main.nr'
AVMTEST_SRC="$(git -C "$WORKSPACE_ROOT/aztec-packages" show "$ANCHOR:$AVMTEST_PATH" 2>/dev/null || true)"
# A NON-EMPTINESS FLOOR, so the five absences below mean something. 500 rather than a figure taken
# from today's reading: the file measures 893 non-empty lines at this anchor, and a floor set AT the
# measurement is a pin that breaks the day upstream deletes a comment.
assert_ge "AvmTest's Noir source is readable at the pinned anchor" 500 \
  "$(printf '%s\n' "$AVMTEST_SRC" | grep -c . || true)"
RECOVERERS="$(printf '%s\n' "$AVMTEST_SRC" | sed -n 's/^[[:space:]]*fn \([a-z_0-9]*_recovers\)(.*/\1/p' | sort -u)"
assert_eq "exactly TWO of its functions recover from a failed nested call" "2" \
  "$(printf '%s\n' "$RECOVERERS" | grep -c . || true)"
assert_true "…and they are the two the entry names" \
  str_has_line "$RECOVERERS" "nested_call_to_nothing_recovers"
assert_true "…and the second" str_has_line "$RECOVERERS" "external_call_to_divide_by_zero_recovers"
# NEITHER NESTED TARGET MAKES A SIDE EFFECT. `nested_call_to_nothing_recovers` calls a garbage
# address with no code; the other calls `divide_by_zero`, whose whole body is one division.
DIVIDE_BODY="$(printf '%s\n' "$AVMTEST_SRC" | sed -n '/^[[:space:]]*fn divide_by_zero(/,/^[[:space:]]*}/p')"
assert_ge "…and `divide_by_zero`'s body is readable" 2 "$(printf '%s\n' "$DIVIDE_BODY" | grep -c . || true)"
for effect in 'storage_write' 'emit_nullifier' 'emit_note_hash' 'emit_public_log' 'send_l2_to_l1'; do
  assert_false "…and it contains no $effect, so the nested target makes no side effect" \
    str_has_sub "$DIVIDE_BODY" "$effect"
done
# THE PAIRED POSITIVE. Five absences over a body of two lines prove nothing about the scanner; the
# same needles ARE found in a function of the same contract that does make side effects.
NULLIFIER_FN="$(printf '%s\n' "$AVMTEST_SRC" | sed -n '/^[[:space:]]*fn create_different_nullifier_in_nested_call(/,/^[[:space:]]*}/p')"
assert_ge "the side-effect scanner has a body to look at" 2 \
  "$(printf '%s\n' "$NULLIFIER_FN" | grep -c . || true)"
assert_true "…and it DOES find a side effect where there is one" \
  str_has_sub "$NULLIFIER_FN" "new_nullifier"

# ---------------------------------------------------------------------------
echo "== 7. through the vendored builder, with the world state off limits"
# ---------------------------------------------------------------------------

for who in reverting succeeding revertingEarly; do
  assert_eq "$who: the vendored transaction builder read no world state" "[]" \
    "$(m31_arm "$NE.arms.$who.merkleTouches")"
done
assert_prefix "…and the tripwire is armed: touching it through the builder's own field throws" \
  "threw:" "$(m31_arm "$REV.merkleTripwireControl")"
assert_eq "…recording exactly the one deliberate observation" "1" \
  "$(m31_arm "$REV.merkleTouchesAfterControl")"

finish
