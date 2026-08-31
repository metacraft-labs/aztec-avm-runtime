#!/usr/bin/env bash
# e2e_block_deployments_through_processor — M22.
#
# The verification entry: "Contract deployment through a block registers the class and instance and
# makes the contract callable in a later block."
#
# ===========================================================================================
# BOTH STATED BLOCKERS WERE DEAD, THE THIRD ONE WAS REAL, AND IT IS RECORDED HERE BECAUSE IT
# DECIDES THE SHAPE OF THIS CHECK.
# ===========================================================================================
#
# The entry said (1) there is no LATER BLOCK, because sealing needs M14's uncarried archive, and
# (2) the transaction builder is missing. Both were measured false on 2026-08-31:
# `test_block_seal_updates_archive` is passing, and M26 vendored the builder (RI-72). What the
# residuals pass left was: *"nothing puts a deployment ON a Tx"* — the two vendored helpers
# `addNewContractClassToTx` and `addNewContractInstanceToTx` were called by nobody.
#
# CALLING THEM TURNED OUT NOT TO BE SUFFICIENT, AND THE MEASUREMENT IS WORTH THE PARAGRAPH.
# `PublicProcessor` calls `contractsDB.addNewContracts(tx)` in exactly ONE place — inside
# `processPrivateOnlyTx`. Upstream's own `deployments.test.ts` therefore carries its deployment on a
# transaction built by `createTxForPrivateOnly`. **That shape cannot be processed by this runtime**:
# `doTreeInsertionsForPrivateOnlyTx` calls `guardedMerkleTree.batchInsert(NULLIFIER_TREE, …)` and
# `ResidentMerkleWriteOperations.batchInsert` REFUSES by design — *"the module exports no subtree
# insertion. Emulating one with sequential inserts plus pad_tree yields a different indexed tree,
# and a merkle root that is wrong is worse than one that is missing."* The arm exercises it rather
# than asserting it: `privateOnlyCarrier` is run, and the transaction comes back in the block's
# FAILED set.
#
# SO THE DEPLOYMENT RIDES ON A TRANSACTION WITH A PUBLIC CALL, AND IT REACHES THE MODULE BY A ROUTE
# THIS CHECK NAMES RATHER THAN GUESSES: upstream's `AvmTxHint.fromTx` carries the transaction's
# `nonRevertibleContractDeploymentData` and `revertibleContractDeploymentData` into the AVM, and the
# contract-address nullifier `addNewContractInstanceToTx` accumulates is written to the nullifier
# tree by the processor. `ResidentContractsDB.addNewContracts` is NOT the route, and this check
# asserts that it was called zero times — because a check that asserted "the deployment was
# registered" without that could not tell a processor that extracted one from a processor that never
# looked, and the two have different remedies.
#
# ===========================================================================================
# THE 2×2 THAT MAKES THIS A MEASUREMENT.
# ===========================================================================================
#
#                              deployment on the tx        no deployment (the control)
#     called in the SAME block  succeeds, real dispatch     reverts, "is not deployed", 1 instruction
#     called in a LATER block   succeeds, real dispatch     reverts, "is not deployed", 1 instruction
#
# THE SUBJECT AND THE CARRIER ARE DIFFERENT ARTIFACTS, and that is not tidiness. The first version
# of this arm deployed a second instance of the SAME artifact the carrier used, so both contract
# classes carried identical bytecode and a subject that "became callable" could have been the
# carrier's own bytecode answering. The call this check reads is `Child.pub_get_value`, a function
# that exists only in the subject's artifact — so executing it is evidence about the subject.
#
# Run: just verify-block-deployments

TEST_NAME="e2e_block_deployments_through_processor"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_token_blocks.sh"

tb_summary_on_abnormal_exit
tb_require_arms
tb_note_provenance

# ---------------------------------------------------------------------------
# PART 0 — the two arms differ in ONE thing
# ---------------------------------------------------------------------------

assert_eq "an arm that does not exist reads MISSING" "MISSING" "$(tb_arm noSuchArm blocks)"
assert_eq "the subject arm ran the publish block and the later-block call" \
  '["publish","callLater"]' "$(tb_block_labels deployment)"
assert_eq "so did the control" '["publish","callLater"]' "$(tb_block_labels deploymentControl)"
assert_eq "the subject attached the deployment" "true" "$(tb_arm deployment deployInBlockOne)"
assert_eq "the control did not" "false" "$(tb_arm deploymentControl deployInBlockOne)"
assert_eq "both aimed at the same contract address" \
  "$(tb_arm deployment contractAddress)" "$(tb_arm deploymentControl contractAddress)"
assert_eq "and used the same carrier" \
  "$(tb_arm deployment carrierAddress)" "$(tb_arm deploymentControl carrierAddress)"

# THE SUBJECT IS NOT THE CARRIER, AND THE TWO ARTIFACTS ARE DIFFERENT.
assert_eq "the subject is the Child artifact" "Child" "$(tb_arm deployment subjectArtifact)"
assert_eq "the carrier is a different one" "AvmTest" "$(tb_arm deployment carrierArtifact)"
assert_true "so the subject and the carrier are different contract classes" \
  test "$(tb_arm deployment contractClassId)" != "$(tb_arm deployment carrierClassId)"
assert_true "at different addresses" \
  test "$(tb_arm deployment contractAddress)" != "$(tb_arm deployment carrierAddress)"

# ---------------------------------------------------------------------------
# PART 1 — THE PUBLISHING BLOCK. The carrier ran; the deployment travelled with it.
# ---------------------------------------------------------------------------

assert_eq "the publishing block carried the deploy transaction and a same-block call" \
  '["deployTx","sameBlockCall"]' "$(tb_block deployment publish submitted)"
assert_eq "and processed both" '["deployTx","sameBlockCall"]' "$(tb_block deployment publish processed)"
assert_eq "the deploy transaction did not revert" "0" "$(tb_block deployment publish revertCodes.deployTx)"
assert_eq "the carrier call returned its own answer, so the block did real work" \
  '["3"]' "$(tb_block deployment publish returnValues.0)"
assert_ge "and executed a real dispatch" 100 "$(tb_block deployment publish instructionsPerSimulation.0)"
assert_prefix "the contract-address nullifier is upstream's own derivation" \
  "0x" "$(tb_arm deployment contractAddressNullifier)"

# THE ROUTE, NAMED. `ResidentContractsDB.addNewContracts` is not it, and saying so is what makes
# "the deployment was registered" a statement about a mechanism rather than about an outcome.
assert_eq "the processor never called addNewContracts for a transaction with public calls" \
  "0" "$(tb_block deployment publish contractStoreCalls.addNewContracts)"
assert_eq "so the deferred flush registered nothing" \
  '{"classes":0,"instances":0}' "$(tb_block deployment publish registrations)"

# ===========================================================================================
# THE POSITIVE CONTROL FOR THAT ZERO, AND IT SEPARATES THREE THINGS A ZERO CANNOT.
# ===========================================================================================
#
# A count of zero is equally produced by a counter wired to nothing, by a store that could not
# extract a deployment even if it were asked, and by the fact this check means to state — that the
# PROCESSOR never asks. The three have different remedies. So the driver hands the same transaction
# shape to `addNewContracts` BY HAND, after the blocks, and drains the flush.
assert_eq "the counter counts: a deliberate call reads one" \
  "1" "$(tb_arm deployment extractionProbe.calls)"
assert_eq "…the store QUEUED what the transaction carried" \
  "1" "$(tb_arm deployment extractionProbe.queuedBeforeFlush)"
assert_eq "…and the flush registered a class and an instance from it" \
  '{"classes":1,"instances":1}' "$(tb_arm deployment extractionProbe.registered)"
assert_prefix "…for a contract class the probe names" "0x" "$(tb_arm deployment extractionProbe.subjectClassId)"
# So the zero above is a fact about the PROCESSOR and not about the store or the counter.

assert_eq "the vendored transaction builder read no world state" "[]" "$(tb_arm deployment merkleTouches)"
assert_prefix "…and the tripwire is armed, so that empty list is a measurement" \
  "threw:" "$(tb_arm deployment merkleTripwireControl)"
assert_eq "…recording exactly the one deliberate observation" \
  "1" "$(tb_arm deployment merkleTouchesAfterControl)"

# ---------------------------------------------------------------------------
# PART 2 — CALLABLE. In the same block, and in a later one.
# ---------------------------------------------------------------------------

assert_eq "the same-block call to the published contract succeeded" \
  "0" "$(tb_block deployment publish revertCodes.sameBlockCall)"
assert_eq "and returned the subject contract's own answer" \
  '["5"]' "$(tb_block deployment publish returnValues.1)"
assert_ge "having executed a real dispatch of the SUBJECT's bytecode" 20 \
  "$(tb_block deployment publish instructionsPerSimulation.1)"

assert_eq "the later block's call was processed" '["call"]' "$(tb_block deployment callLater processed)"
assert_eq "and did not revert" "0" "$(tb_block deployment callLater revertCodes.call)"
assert_eq "returning the subject's own answer again" '["5"]' "$(tb_block deployment callLater returnValues.0)"
assert_eq "in the same number of instructions, which is the same bytecode running twice" \
  "$(tb_block deployment publish instructionsPerSimulation.1)" \
  "$(tb_block deployment callLater instructionsPerSimulation.0)"

# ---------------------------------------------------------------------------
# PART 3 — THE CONTROL. Without the deployment, the identical calls cannot run.
# ---------------------------------------------------------------------------

assert_eq "the control's carrier call still succeeded, so the block itself works" \
  "0" "$(tb_block deploymentControl publish revertCodes.deployTx)"
assert_eq "and returned the same carrier answer" '["3"]' "$(tb_block deploymentControl publish returnValues.0)"
assert_eq "but the control's same-block call REVERTED" \
  "1" "$(tb_block deploymentControl publish revertCodes.sameBlockCall)"
assert_contains "naming the address as not deployed" \
  "is not deployed" "$(tb_block deploymentControl publish revertReasons.sameBlockCall)"
assert_contains "and it is the SUBJECT's address it names" \
  "$(tb_arm deploymentControl contractAddress)" \
  "$(tb_block deploymentControl publish revertReasons.sameBlockCall)"
assert_eq "the control's later-block call reverted too" \
  "1" "$(tb_block deploymentControl callLater revertCodes.call)"
assert_eq "at instruction one, because there was no bytecode to run" \
  "1" "$(tb_block deploymentControl callLater instructionsPerSimulation.0)"
assert_eq "and it returned nothing" "[]" "$(tb_block deploymentControl callLater returnValues.0)"

# ---------------------------------------------------------------------------
# PART 4 — UPSTREAM'S OWN CARRIER SHAPE, EXERCISED RATHER THAN CLAIMED ABOUT
# ---------------------------------------------------------------------------
#
# `deployments.test.ts` carries the deployment on a private-only transaction. This runtime refuses
# it, and the refusal is measured here so the limitation is evidence rather than a sentence.

assert_eq "a private-only carrier is NOT processed by this runtime" \
  "[]" "$(tb_arm deployment privateOnlyCarrier.processed)"
assert_eq "it lands in the block's failed set" \
  '["privateOnlyDeployTx"]' "$(tb_arm deployment privateOnlyCarrier.failed \
    | python3 -c 'import json,sys; print(json.dumps([f["label"] for f in json.load(sys.stdin)],separators=(",",":")))')"
assert_contains "and the failure is the nullifier-tree insertion the resident world state refuses" \
  "nullifiers" "$(tb_arm deployment privateOnlyCarrier.failed \
    | python3 -c 'import json,sys; print(" ".join(f["message"] for f in json.load(sys.stdin)))')"
# The refusal is the resident merkle DB's, and the reason it gives is the one this check quotes.
assert_contains "the resident world state declares that refusal in its own words" \
  "the module exports no subtree insertion" \
  "$(cat "$REPO_ROOT/orchestration/src/resident_merkle_operations.ts")"

finish
