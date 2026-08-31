#!/usr/bin/env bash
# e2e_ts_wasm_nested_call_fork_merge — M18.
#
# The verification entry: "CALL and STATICCALL fork the state manager and side-effect trace in
# lockstep; a reverted nested call contributes no side effects and refunds unused gas."
#
# ===========================================================================================
# THE EXTRA REASON THIS ENTRY GAVE WAS FLATLY WRONG, AND IT IS WORTH RECORDING WHY IT SURVIVED.
# ===========================================================================================
#
# The entry said this "additionally wants M13's coordinator build rather than M12's — the
# `avm_coordinator_*` exports are the ten M13 adds, and the artefact this milestone runs against is
# M12's thirty-nine-export module". Measured on 2026-08-31 by dumping `WebAssembly.Module.exports`
# of every built module on this host: the module every current check runs against carries the
# coordinator exports. This check asserts that of the module it actually ran against rather than
# quoting the correction, so the sentence cannot go stale a second time.
#
# ===========================================================================================
# THE ENTRY NAMES THREE PROPERTIES. EACH ONE HAS ITS OWN ARM AND ITS OWN DISCRIMINATOR.
# ===========================================================================================
#
#   1. CALL AND STATICCALL FORK, AND THE FORK MERGES.
#      `nested_call_to_add(3,5)` and `nested_static_call_to_add(3,5)` both return 8 and both cost
#      MORE INSTRUCTIONS than the flat `add_args_return(3,5)` — which is what says a second context
#      was entered rather than the call being inlined away. The merge is a CONSERVATION LAW over the
#      contract store's checkpoints — some created, and every one closed exactly once — and Part 3
#      records the correction that counting them forced: the store sees exactly ONE checkpoint per
#      transaction, the same for a flat call as for a nested one, so the PER-FRAME fork is the
#      module's and does not reach this side. The first version of that section asserted a depth of
#      zero and called it the merge, which a store that never forked satisfies just as well.
#      *The discriminator for the STATIC half* is `nested_static_call_to_set_storage`, which tries
#      to WRITE inside the static frame: the AVM refuses it by name. A "staticcall" that forked like
#      an ordinary call would let that write through, so the refusal is what distinguishes the two.
#
#   2. A REVERTED NESTED CALL CONTRIBUTES NO SIDE EFFECTS — AND THIS IS ASSERTED BY A LATER
#      TRANSACTION RATHER THAN BY A REVERT CODE.
#      `create_different_nullifier_in_nested_call(self, N)` pushes N in the outer frame and N+1 in
#      the nested one; both land. `create_same_nullifier_in_nested_call(self, M)` pushes M in both,
#      so the nested push is a duplicate and the nested frame reverts. Then three follow-up
#      transactions try to emit N, N+1 and M:
#
#          N    must FAIL   — the outer frame's write landed
#          N+1  must FAIL   — the NESTED frame's write landed when the nested call succeeded
#          M    must SUCCEED — the reverted nested frame's write is not in the tree
#
#      Two of the three answers are the opposite of the third. A tree that accepted everything, or
#      one that accepted nothing, fails this triple; a revert code alone would satisfy either.
#      `nested_call_to_nothing_recovers` is the other half of the shape — a nested CALL that fails
#      inside an outer call that SUCCEEDS — and it is asserted here too.
#
#      *WHAT IS NOT CLOSED BY THIS, STATED RATHER THAN IMPLIED*: no contract in the pinned corpus
#      makes a side effect in a nested frame that reverts while the OUTER call goes on to succeed.
#      The two halves are measured separately above. M25 carries a separate verification entry for
#      that joint case — the nested-call-reverted-contributes-no-side-effects one — and it stays
#      `pending` for exactly this reason; see M25's section in the milestone file. Its name is not
#      spelled here on purpose: `verify_named_checks_exist` requires every check name this
#      repository writes down to RESOLVE, and a name for a check that does not exist is precisely
#      the "a comment that tells the next reader to stop looking" defect that check was built for.
#
#   3. UNUSED GAS IS REFUNDED. `nested_call_to_add_with_gas(3,5,L2,DA)` allocates L2 to the nested
#      frame. Run at two allocations that differ by a factor of four, the TRANSACTION's own gas must
#      come out IDENTICAL: what the nested frame did not spend went back to the caller. A single
#      allocation says nothing, and a pinned gas number would be a figure nobody re-derives.
#
# Run: just verify-ts-wasm-nested

TEST_NAME="e2e_ts_wasm_nested_call_fork_merge"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_token_blocks.sh"

tb_summary_on_abnormal_exit
tb_require_arms
tb_note_provenance

# ---------------------------------------------------------------------------
# PART 0 — the module, and the sentence this entry got wrong
# ---------------------------------------------------------------------------

assert_eq "an arm that does not exist reads MISSING" "MISSING" "$(tb_arm noSuchArm blocks)"
EXPORTS="$(tb_module_exports "$AVM_WASM_PATH")"
COORDINATOR="$(printf '%s\n' "$EXPORTS" | grep -c '^avm_coordinator_' || true)"
assert_ge "the module these arms ran against carries the coordinator exports" 8 "$COORDINATOR"
assert_true "which is not the four-export vm2wasm spike this entry believed it was" \
  test "$(printf '%s\n' "$EXPORTS" | wc -l)" -gt 40
assert_true "the coordinator's lockstep assertion is one of them" \
  str_has_line "$EXPORTS" avm_coordinator_assert_lockstep

assert_eq "the nested arm ran the eleven blocks this check reads" \
  '["nestedCall","nestedStaticCall","nestedStaticWrite","nestedRecovers","nestedGasSmall","nestedGasLarge","flatCall","nullifiersLand","nullifiersDiscarded","reuseLanded","reuseLandedNested","reuseDiscarded"]' \
  "$(tb_block_labels nested)"

# ---------------------------------------------------------------------------
# PART 1 — CALL AND STATICCALL FORK
# ---------------------------------------------------------------------------

assert_eq "the nested CALL returned the nested frame's own answer" \
  '["8"]' "$(tb_block nested nestedCall returnValues.0)"
assert_eq "the nested STATICCALL returned the same answer" \
  '["8"]' "$(tb_block nested nestedStaticCall returnValues.0)"
assert_eq "the flat call returns it too, so 8 is not evidence of a fork by itself" \
  '["8"]' "$(tb_block nested flatCall returnValues.0)"

FLAT="$(tb_block nested flatCall instructionsPerSimulation.0)"
NESTED="$(tb_block nested nestedCall instructionsPerSimulation.0)"
STATIC="$(tb_block nested nestedStaticCall instructionsPerSimulation.0)"
assert_ge "the flat call executed a real dispatch" 100 "$FLAT"
assert_true "the nested CALL executed strictly more instructions than the flat one" \
  test "$NESTED" -gt "$FLAT"
assert_true "the nested STATICCALL did too" test "$STATIC" -gt "$FLAT"
# A fork that costs the same as no fork is a fork nobody took. The margin is asserted as a
# multiple rather than as a pinned difference, so it survives a compiler that moves the numbers.
assert_true "and both cost at least twice the flat call, which is a second context and not a jump" \
  test "$NESTED" -ge "$((FLAT * 2))"

# ---------------------------------------------------------------------------
# PART 2 — THE STATIC FORK IS ENFORCED, which is what tells the two apart
# ---------------------------------------------------------------------------

assert_eq "a write attempted inside the static frame reverts the transaction" \
  "1" "$(tb_block nested nestedStaticWrite revertCodes.nestedStaticWrite)"
assert_contains "and the AVM refuses it by name, in a static context" \
  "static context" "$(tb_block nested nestedStaticWrite revertReasons.nestedStaticWrite)"
assert_contains "naming the opcode it refused" \
  "SSTORE" "$(tb_block nested nestedStaticWrite revertReasons.nestedStaticWrite)"
assert_ge "the refusal came after a real dispatch, not at instruction one" 100 \
  "$(tb_block nested nestedStaticWrite instructionsPerSimulation.0)"

# ---------------------------------------------------------------------------
# PART 3 — THE MERGE, AS A CONSERVATION LAW, AND A CORRECTION TO WHAT IT MEASURES
# ---------------------------------------------------------------------------
#
# THE FIRST VERSION OF THIS SECTION ASSERTED A DEPTH OF ZERO AND CALLED IT THE MERGE. A store that
# never forked reads zero too, so that assertion was satisfied by the ABSENCE of the thing it was
# about. Counting the calls turns it into a conservation law — some checkpoints were created, and
# every one of them was closed exactly once — and the depth becomes the consequence.
#
# AND THE COUNTS CORRECT THE SENTENCE. Measured: the contract store sees EXACTLY ONE checkpoint per
# transaction, created and committed, and the FLAT call sees the same one. So the per-frame
# fork/merge of a nested call happens INSIDE the module and does not reach the TypeScript store;
# what this section measures is the transaction-level checkpoint balancing, which is a real property
# and a different one. The nested fork's own evidence is Part 1's instruction delta and Part 2's
# refusal, and it is stated that way rather than borrowed from here.

for b in nestedCall nestedStaticCall nestedStaticWrite nestedRecovers flatCall; do
  CREATED="$(tb_block nested "$b" checkpoints.created)"
  assert_ge "the contract store really was checkpointed during $b" 1 "$CREATED"
  assert_eq "…and every checkpoint it opened was closed exactly once" \
    "$CREATED" "$(( $(tb_block nested "$b" checkpoints.committed) + $(tb_block nested "$b" checkpoints.reverted) ))"
  assert_eq "…leaving the depth at zero, which is the consequence and not the claim" \
    "0" "$(tb_block nested "$b" checkpointDepthAfter.contracts)"
done

# THE CORRECTION, ASSERTED SO IT CANNOT DRIFT BACK: the nested call and the flat call produce the
# SAME contract-store checkpoint count. If they ever differed, the sentence above would be wrong and
# this assertion is what would say so.
assert_eq "a nested call and a flat one checkpoint the contract store identically" \
  "$(tb_block nested flatCall checkpoints)" "$(tb_block nested nestedCall checkpoints)"
assert_eq "…which is one per transaction, committed" \
  '{"created":1,"committed":1,"reverted":0}' "$(tb_block nested flatCall checkpoints)"
# So the per-frame fork is the MODULE's. The module carries the coordinator's own lockstep
# assertion, asserted present in Part 0; M13's `avm_contract_db_host.mjs` is what drives it, and
# this check does not claim to.
assert_eq "and a transaction that REVERTED still balanced its checkpoint" \
  "$(tb_block nested nestedStaticWrite checkpoints.created)" \
  "$(( $(tb_block nested nestedStaticWrite checkpoints.committed) + $(tb_block nested nestedStaticWrite checkpoints.reverted) ))"

# ---------------------------------------------------------------------------
# PART 4 — A REVERTED NESTED CALL CONTRIBUTES NO SIDE EFFECTS
# ---------------------------------------------------------------------------

assert_eq "a nested CALL that fails inside an outer call that recovers leaves the outer succeeding" \
  "0" "$(tb_block nested nestedRecovers revertCodes.nestedRecovers)"
assert_ge "and it ran the recovery path rather than halting" 100 \
  "$(tb_block nested nestedRecovers instructionsPerSimulation.0)"

assert_eq "the arm that lands two nullifiers succeeded" \
  "0" "$(tb_block nested nullifiersLand revertCodes.nullifiersLand)"
assert_eq "the arm whose NESTED frame emits a duplicate reverted" \
  "1" "$(tb_block nested nullifiersDiscarded revertCodes.nullifiersDiscarded)"
assert_contains "and the AVM named the duplicate emission" \
  "duplicate nullifier" "$(tb_block nested nullifiersDiscarded revertReasons.nullifiersDiscarded)"

# THE TRIPLE. Two must fail and one must succeed; any tree that answers all three the same way
# fails here, which is what a revert code on its own cannot say.
assert_eq "the OUTER frame's landed nullifier cannot be emitted again" \
  "1" "$(tb_block nested reuseLanded revertCodes.reuseLanded)"
assert_eq "the NESTED frame's landed nullifier cannot be emitted again either" \
  "1" "$(tb_block nested reuseLandedNested revertCodes.reuseLandedNested)"
assert_eq "but the REVERTED nested frame's nullifier is still free — it contributed nothing" \
  "0" "$(tb_block nested reuseDiscarded revertCodes.reuseDiscarded)"
assert_ge "and that succeeding follow-up really emitted one" 100 \
  "$(tb_block nested reuseDiscarded instructionsPerSimulation.0)"

# The three values are distinct, so the triple above is three questions and not one asked thrice.
assert_eq "the three nullifiers are three different values" "3" \
  "$(tb_arm nested nullifiers | python3 -c 'import json,sys; print(len(set(json.load(sys.stdin).values())))')"

# ---------------------------------------------------------------------------
# PART 5 — UNUSED GAS IS REFUNDED
# ---------------------------------------------------------------------------

SMALL_ALLOC="$(tb_arm nested gasAllocations.small.l2)"
LARGE_ALLOC="$(tb_arm nested gasAllocations.large.l2)"
assert_true "the two arms allocated genuinely different amounts to the nested frame" \
  test "$LARGE_ALLOC" -ge "$((SMALL_ALLOC * 2))"
assert_eq "both nested-with-gas calls returned the nested frame's answer" \
  "$(tb_block nested nestedGasSmall returnValues.0)" "$(tb_block nested nestedGasLarge returnValues.0)"
assert_eq "and neither reverted" \
  "0" "$(tb_block nested nestedGasSmall revertCodes.nestedGasSmall)"
assert_eq "neither did the larger allocation" \
  "0" "$(tb_block nested nestedGasLarge revertCodes.nestedGasLarge)"
SMALL_GAS="$(tb_block nested nestedGasSmall l2GasByTx.nestedGasSmall)"
LARGE_GAS="$(tb_block nested nestedGasLarge l2GasByTx.nestedGasLarge)"
assert_ge "the transaction spent L2 gas" 1 "$SMALL_GAS"
assert_eq "and spent EXACTLY THE SAME whatever the nested frame was allocated — unused gas returns" \
  "$SMALL_GAS" "$LARGE_GAS"
# The non-degeneracy for that equality: a run whose gas did not depend on what happened would make
# it vacuous, so a call that does MORE work must cost more.
assert_true "gas is not a constant: the nested call costs more than the flat one" \
  test "$(tb_block nested nestedCall l2GasByTx.nestedCall)" \
       -gt "$(tb_block nested flatCall l2GasByTx.flatCall)"

finish
