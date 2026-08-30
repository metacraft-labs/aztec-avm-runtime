#!/usr/bin/env bash
# test_deployment_through_wallet
#
# M34 verification: "deployment goes through the wallet seam, and the direct-write shortcut still
# works and is labelled as a shortcut."
#
# ===========================================================================================
# TWO CLAIMS, AND THE SECOND IS THE ONE WITH TEETH
# ===========================================================================================
#
# The milestone's deliverable is *"`registerContract` moves BEHIND the wallet, so deployment goes
# through the same seam. Keep the direct store write as an explicitly-named dev shortcut, not a
# silent alternative."* Both halves are asserted, and the second is where the work is: "still works"
# and "is labelled" are different statements, and a shortcut that silently kept working while
# nothing named it is exactly the arrangement the deliverable forbids.
#
# ===========================================================================================
# THE TWO ROUTES ARE COMPARED, NOT DESCRIBED
# ===========================================================================================
#
# Both routes derive a contract class and an instance from the SAME artifact. If they agreed only
# because nobody compared them, the seam would be a second implementation wearing the first one's
# name. So the class id and the address are compared ACROSS the two routes, and the comparison is
# shown to be capable of disagreeing: the wallet's `getContractClassMetadata` is asked about a class
# id it has never seen and must answer the other way.
#
# Run: just verify-m34-deployment

TEST_NAME="test_deployment_through_wallet"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m33_wallet.sh"
. "$VERIFY_DIR/lib_m34_wallet.sh"

m34_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m34_require_arms

echo "== 1. REGISTRATION WENT THROUGH THE WALLET, and the wallet's ledger says so"

DECISIONS="$(m34_arm transfer.report.decisions)"
CLASS_ID="$(m34_arm transfer.report.contractClassId)"
ADDRESS="$(m34_arm transfer.report.contractAddress)"
ARTIFACT="$(m34_arm transfer.report.artifactName)"
m34_absent "transfer.report.decisions=$DECISIONS" "transfer.report.contractClassId=$CLASS_ID" \
  "transfer.report.contractAddress=$ADDRESS" "transfer.report.artifactName=$ARTIFACT"

# THE DETAIL, NOT THE NAME. A ledger entry saying `registerContractClass` proves the method was
# called; the class id inside its detail proves the wallet DERIVED the class rather than being told
# one. `CAMPAIGN-BRIEF.md`'s rule that a check needing a value which also exists in the subject must
# take it FROM the subject applies to the wallet's own record as much as to a document.
CLASS_DETAIL="$(python3 - "$M34_ARMS" registerContractClass <<'PYD'
import json, sys
d = json.load(open(sys.argv[1]))
rows = [x for x in d['arms']['transfer']['report']['decisions'] if x['method'] == sys.argv[2]]
print(rows[0]['detail'] if rows else 'MISSING')
PYD
)"
INSTANCE_DETAIL="$(python3 - "$M34_ARMS" registerContract <<'PYD'
import json, sys
d = json.load(open(sys.argv[1]))
rows = [x for x in d['arms']['transfer']['report']['decisions'] if x['method'] == sys.argv[2]]
print(rows[0]['detail'] if rows else 'MISSING')
PYD
)"
m34_absent "transfer.registerContractClass.detail=$CLASS_DETAIL" \
  "transfer.registerContract.detail=$INSTANCE_DETAIL"

assert_true "the wallet registered the class, and DERIVED its id" \
  str_has_sub "$CLASS_DETAIL" "classId=$CLASS_ID"
assert_true "…from the artifact it was given, by name" \
  str_has_sub "$CLASS_DETAIL" "artifact=$ARTIFACT"
# THE NODE ACCEPTED IT. `registered=1` is the count `AvmRuntime.registerContract` returned, so a
# wallet that recorded a decision without the store write behind it would read `registered=0`.
assert_true "…and the node's resident store accepted exactly one new class" \
  str_has_sub "$CLASS_DETAIL" 'registered=1'
assert_true "the wallet registered the instance, at the address the page uses" \
  str_has_sub "$INSTANCE_DETAIL" "instance=$ADDRESS"
assert_true "…bound to that same class id" str_has_sub "$INSTANCE_DETAIL" "classId=$CLASS_ID"
assert_true "…and the node accepted exactly one new instance" \
  str_has_sub "$INSTANCE_DETAIL" 'registered=1'

echo "== 2. THE PAGE DID NOT REACH AROUND THE SEAM"

# The counts the WALLET recorded are the only registrations in this arm. `registeredClasses` and
# `registeredInstances` are fields the DIRECT path reports and this arm's report does not carry at
# all — so their absence here is the seam, stated as a measurement rather than as an intention.
assert_eq "the wallet arm reports no direct registration counts, because it made none" "MISSING" \
  "$(m34_arm transfer.report.registeredClasses)"
assert_eq "…and none for instances either" "MISSING" \
  "$(m34_arm transfer.report.registeredInstances)"
# AND THE CONTROL FOR THAT ABSENCE: the SHORTCUT arm does report them, so the field name is one the
# report format knows about and the absence above is a fact rather than a typo.
assert_ge "the shortcut arm DOES report them, so the field exists in this format" 1 \
  "$(m34_arm shortcut.report.registeredClasses)"
assert_ge "…for instances too" 1 "$(m34_arm shortcut.report.registeredInstances)"

echo "== 3. THE METADATA THE WALLET ANSWERS MOVES, so it is a reading and not a constant"

BEFORE_PUB="$(m34_arm transfer.report.metadataBefore.isContractPublished)"
BEFORE_INIT="$(m34_arm transfer.report.metadataBefore.initializationStatus)"
AFTER_PUB="$(m34_arm transfer.report.metadataAfter.isContractPublished)"
AFTER_INIT="$(m34_arm transfer.report.metadataAfter.initializationStatus)"
m34_absent "transfer.report.metadataBefore.isContractPublished=$BEFORE_PUB" \
  "transfer.report.metadataBefore.initializationStatus=$BEFORE_INIT" \
  "transfer.report.metadataAfter.isContractPublished=$AFTER_PUB" \
  "transfer.report.metadataAfter.initializationStatus=$AFTER_INIT"

# BOTH READINGS COME OUT OF THE NODE'S NULLIFIER TREE — the place the AVM itself looks to decide a
# contract exists (M29's finding). Asked before the dev shortcuts run and again after, one call, one
# instrument, two answers. An `isContractPublished` that were a constant `true` would fail here.
assert_eq "before the deployment nullifier lands, the wallet says the contract is not published" \
  "false" "$BEFORE_PUB"
assert_eq "…and not initialized" "UNINITIALIZED" "$BEFORE_INIT"
assert_eq "after it lands, the same call says it IS published" "true" "$AFTER_PUB"
assert_eq "…and initialized" "INITIALIZED" "$AFTER_INIT"

# THE CLASS LOOKUP IS KEYED BY ID, and the control is a fabricated id. Without it,
# `isArtifactRegistered` could be `artifacts.size > 0` — an answer that cannot say no, wearing the
# shape of a lookup. It was exactly that in the first draft.
KNOWN="$(m34_arm transfer.report.classMetadata.isArtifactRegistered)"
UNKNOWN="$(m34_arm transfer.report.unknownClassMetadata.isArtifactRegistered)"
m34_absent "transfer.report.classMetadata.isArtifactRegistered=$KNOWN" \
  "transfer.report.unknownClassMetadata.isArtifactRegistered=$UNKNOWN"
assert_eq "the wallet knows the class it registered" "true" "$KNOWN"
assert_eq "…and does NOT know a class id it has never seen" "false" "$UNKNOWN"

echo "== 4. THE DIRECT SHORTCUT STILL WORKS, AND IS LABELLED"

LABEL="$(m34_arm shortcut.report.label)"
S_OUTCOME="$(m34_arm shortcut.report.outcome)"
S_REVERT="$(m34_arm shortcut.report.revertCode)"
S_CLASS="$(m34_arm shortcut.report.contractClassId)"
S_ADDR="$(m34_arm shortcut.report.contractAddress)"
m34_absent "shortcut.report.label=$LABEL" "shortcut.report.outcome=$S_OUTCOME" \
  "shortcut.report.revertCode=$S_REVERT" "shortcut.report.contractClassId=$S_CLASS" \
  "shortcut.report.contractAddress=$S_ADDR"

assert_eq "the direct path still processes a transaction" "processed" "$S_OUTCOME"
assert_eq "…without reverting" "0" "$S_REVERT"
assert_true "…and the arm LABELS it a shortcut, in the report a check reads" \
  str_has_sub "$LABEL" 'DEV SHORTCUT'

# LABELLED WHERE A PERSON WOULD SEE IT, not only in a report. The demo page writes `[DEV SHORTCUT]`
# into its own log for every direct write it makes, and the SOURCE is scanned for the count so a
# shortcut added later without a label fails.
SHORTCUT_LABELS="$(grep -c -F '[DEV SHORTCUT]' "$M34_DEMO_SRC" || true)"
assert_ge "the demo page names every direct store write as a DEV SHORTCUT, in its own log" 4 \
  "$SHORTCUT_LABELS"
note "the wallet demo names $SHORTCUT_LABELS direct write(s) as shortcuts"
# THE SCANNER IS SHOWN TO DISCRIMINATE: the same needle over the WALLET's own source is zero,
# because the wallet takes no shortcuts. A count that were positive everywhere would say nothing.
assert_eq "…and the wallet itself declares none, because it takes none" "0" \
  "$(grep -c -F '[DEV SHORTCUT]' "$M34_WALLET_SRC" || true)"

echo "== 5. THE TWO ROUTES AGREE, AND THE COMPARISON CAN DISAGREE"

# The strongest thing this check says: the class the WALLET derived from the artifact and the class
# the DIRECT path derived are the same object, and so is the address. Two routes, one artifact, one
# derivation — which is what makes the seam a substitution rather than a second implementation.
assert_eq "the wallet's contract class id IS the direct path's" "$S_CLASS" "$CLASS_ID"
assert_eq "…and so is the address it deployed to" "$S_ADDR" "$ADDRESS"
# NON-DEGENERACY: two `MISSING`s are also equal. Both sides are asserted to be real field elements.
assert_true "…over a real class id and not two absences" \
  str_has_re "$CLASS_ID" '^0x[0-9a-f]{64}$'
assert_true "…and a real address" str_has_re "$ADDRESS" '^0x[0-9a-f]{64}$'
# AND THE COMPARATOR IS SHOWN TO SAY NO, OVER TWO VALUES OF THE SAME KIND.
#
# THIS CONTROL USED TO COMPARE A TRANSACTION HASH WITH A CONTRACT ADDRESS — two different kinds,
# under a label claiming it "distinguishes the two runs' transactions". It could only have failed if
# BOTH were `MISSING`, which makes it a degeneracy guard wearing a comparator's label rather than a
# demonstration that the equality above is a result. Retaken by M34's review over two real
# `0x`-64-hex field elements from the SAME arm — the class id and the address, which the assertions
# above have just shown are both real and which must not be equal — so the instrument is seen to
# separate two values it could have joined.
assert_false "the same comparison separates two real field elements that differ" \
  test "$CLASS_ID" = "$ADDRESS"
# …and the degeneracy guard the old form was actually providing, kept and named as one.
assert_false "…over two values neither of which is MISSING" \
  test "$CLASS_ID" = "MISSING"

echo "== 5b. THE TWO ROUTES EXECUTE THE SAME PROGRAM, AND THAT IS NOW A MEASUREMENT"

# `DEV-WALLET.md` §4: *"the step count is M27's and M29's direct-path figure to the step, which is
# the interesting part: the wallet route and the back-door route execute the same program."* Until
# M34's review nothing asserted it — §3 asserts FLOORS, and §8 re-derives the document's 516 from
# the wallet arm alone, so the sentence's right-hand side was a number measured in another
# milestone's arm run and re-derived by nobody. That is `CAMPAIGN-BRIEF.md`'s "a figure nobody
# re-derives rots" family sitting under the milestone's headline claim.
#
# The direct path runs in the SAME browser session, in a runtime of its own, so the right-hand side
# is a measurement rather than a citation. And the agreement is NOT by construction: the wallet
# enters M26's vendored builder through its no-`fnName` branch with `[derivedSelector, ...args]`
# after re-deriving the selector from the artifact IT registered, while `runTokenTransfer` enters
# through the `fnName` branch and lets the builder derive and prepend. Two routes, one program.
W_STEPS="$(m34_arm transfer.report.executedSteps)"
W_CONTEXTS="$(m34_arm transfer.report.contexts)"
S_STEPS="$(m34_arm shortcut.report.executedSteps)"
S_CONTEXTS="$(m34_arm shortcut.report.contexts)"
m34_absent "transfer.report.executedSteps=$W_STEPS" "transfer.report.contexts=$W_CONTEXTS" \
  "shortcut.report.executedSteps=$S_STEPS" "shortcut.report.contexts=$S_CONTEXTS"
# NON-DEGENERACY FIRST: two zeroes are also equal, and the declining arm proves 0 is reachable.
assert_ge "the direct path executed a real program too" 100 "$S_STEPS"
assert_eq "the wallet route executes the direct route's program, to the step" "$S_STEPS" "$W_STEPS"
assert_eq "…across the same number of AVM contexts" "$S_CONTEXTS" "$W_CONTEXTS"
# AND THE SAME COMPARISON IS SHOWN TO SEPARATE STEP COUNTS: the declining arm's is 0.
assert_false "…and the same comparison would notice a route that executed something else" \
  test "$(m34_arm declined.report.executedSteps)" = "$W_STEPS"

echo "== 6. THE SHORTCUT IS THE ONE M27 SHIPPED, unchanged"

# `runTokenTransfer` is M27's function and M34 does not touch it. The wallet demo IMPORTS it rather
# than reimplementing it, which is what makes "the shortcut still works" a statement about the same
# code path rather than about a copy of it.
assert_true "the wallet demo drives M27's own runTokenTransfer for the shortcut arm" \
  str_has_sub "$(cat "$M34_DEMO_SRC")" 'runTokenTransfer'
assert_ge "…which is still exported from the testing entry point" 1 \
  "$(grep -c -F 'runTokenTransfer' "$BROWSER_SRC/entry_testing.ts" || true)"

m34_finish
