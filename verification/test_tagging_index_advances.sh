#!/usr/bin/env bash
# test_tagging_index_advances
#
# M36's second verification entry: **the tagging index advances across sends**, with the control
# that **a replayed tag does not double-count**.
#
# ===========================================================================================
# WHY THE FIRST HALF IS ABOUT RESERVATION AND NOT ABOUT ARITHMETIC
# ===========================================================================================
#
# `getNextTaggingIndex` could be a getter, and if it were, two sends to the same recipient would
# both use index *n*, produce ONE tag, and the recipient would see one log where two were sent. So
# the index is RESERVED as it is handed out. Three consecutive calls returning three different
# numbers is the shape of that, and three DIFFERENT SILOED TAGS is its consequence — which is the
# half that matters, because two indexes that differ and hash to the same tag would be the same
# defect wearing different numbers.
#
# AND THE INDEXES DO NOT START AT ZERO, WHICH IS THE MEASUREMENT RATHER THAN AN OFF-BY-ONE. The
# CIRCUIT reserved index 0 while deriving its own tag, so the counter these three calls advance is
# one the contract has already used. A run reporting 0, 1, 2 would be a run whose counter did not
# survive the execution before it, and this check asserts the first index is NON-ZERO for that
# reason.
#
# ===========================================================================================
# THE SECOND HALF: A REPLAYED TAG DOES NOT DOUBLE-COUNT
# ===========================================================================================
#
# The same (secret, index) looked up twice returns the same single log both times. A tag index that
# appended on read — or a discovery that advanced a cursor and re-scanned — would report a note
# twice, and a contract would try to spend it twice. The two readings are asserted EQUAL and
# NON-ZERO: two zeroes would satisfy the equality and say nothing, which is the both-sides-zero
# family this campaign records for a whole milestone that passed on it.
#
# ===========================================================================================
# AND THE THIRD: THE ONE PLACE M36 COULD HAVE READ AMBIENT ENTROPY
# ===========================================================================================
#
# `PRIVATE-EXECUTION.md` §5 measured that upstream's `EphemeralArrayService.allocateSlot` is
# `Fr.random()`, and TWO of M36's own oracle returns are ephemeral arrays. So the deterministic
# allocator is asserted BEHAVIOURALLY — the same seed produces the same slots in two independently
# constructed services and a different seed produces different ones — and the slots the ORACLES
# actually materialised are asserted to be that stream's, which is what says the service was used
# rather than merely constructed.
#
# Run: just verify-m36-tagging

TEST_NAME="test_tagging_index_advances"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m36_notes.sh"

m36_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m36_require_arms

echo "== 1. THE INDEX ADVANCES, AND IT ADVANCES A COUNTER THE CIRCUIT ALREADY USED"

INDEXES="$(m36_arm discovery.report.tagging.indexes)"
TAGS="$(m36_arm discovery.report.tagging.tagsForIndexes)"
DISTINCT="$(m36_arm discovery.report.tagging.distinctTags)"
ACCOUNTS="$(m36_arm discovery.report.tagging.accountCount)"
SENDER="$(m36_arm discovery.report.tagging.senderForTags)"
RANGES="$(m36_arm discovery.report.tagging.usedRanges)"
m36_absent "tagging.indexes=$INDEXES" "tagging.tagsForIndexes=$TAGS" \
  "tagging.distinctTags=$DISTINCT" "tagging.accountCount=$ACCOUNTS" \
  "tagging.senderForTags=$SENDER" "tagging.usedRanges=$RANGES"

I0="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0])' "$INDEXES")"
I1="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[1])' "$INDEXES")"
I2="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[2])' "$INDEXES")"

assert_eq "three consecutive calls were made" "3" \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$INDEXES")"
assert_eq "and each is one more than the last — the index is RESERVED, not read" "1 1" \
  "$((I1 - I0)) $((I2 - I1))"
# THE NON-ZERO START IS THE EVIDENCE THAT THE COUNTER SURVIVED THE EXECUTION. Without it, three
# calls returning 0, 1, 2 would satisfy every assertion above over a counter that had been reset.
assert_ge "the first index is NOT zero, because the circuit reserved index 0 before these ran" \
  1 "$I0"

echo "== 2. THREE INDEXES, THREE DIFFERENT SILOED TAGS"

assert_eq "each index produces its own siloed tag" "3" "$DISTINCT"
assert_eq "and there were three tags to be distinct about" "3" \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$TAGS")"
# NON-DEGENERACY: a tag function that returned the zero field for everything would give ONE distinct
# value, so the assertion above already catches it — but a function returning the INDEX itself would
# give three, and this is what catches that.
assert_eq "and none of them is the index it came from, or the zero field" "0" \
  "$(python3 - "$TAGS" <<'PY'
import json, sys
tags = json.loads(sys.argv[1])
bad = [t for t in tags if int(t, 16) < 16]
print(len(bad))
PY
)"

echo "== 3. THE CONTROL: A REPLAYED TAG DOES NOT DOUBLE-COUNT"

R1="$(m36_arm discovery.report.tagging.replayFirst)"
R2="$(m36_arm discovery.report.tagging.replaySecond)"
m36_absent "tagging.replayFirst=$R1" "tagging.replaySecond=$R2"
assert_eq "the same (secret, index) returns the same count twice" "$R1" "$R2"
# BOTH SIDES READ AND BOTH SIDES ZERO IS THE FAMILY THIS ASSERTION EXISTS TO AVOID. Two lookups over
# an empty index agree perfectly and say nothing about double-counting.
assert_ge "and that count is NOT zero, so the equality above is over data" 1 "$R1"
assert_eq "one log, both times — a discovery is idempotent rather than accumulating" "1" "$R1"

echo "== 4. THE DETERMINISTIC EPHEMERAL SLOTS — THE MEASUREMENT M35 LEFT OPEN"

SLOTS="$(m36_arm discovery.report.ephemeral.allocatedSlots)"
A="$(m36_arm discovery.report.ephemeral.firstSlots.a)"
B="$(m36_arm discovery.report.ephemeral.firstSlots.b)"
OTHER="$(m36_arm discovery.report.ephemeral.firstSlots.other)"
PENDING_SLOT="$(m36_arm discovery.report.ephemeralOracles.pendingSlot)"
BYTAG_SLOTS="$(m36_arm discovery.report.ephemeralOracles.byTagSlots)"
m36_absent "ephemeral.allocatedSlots=$SLOTS" "ephemeral.firstSlots.a=$A" \
  "ephemeral.firstSlots.b=$B" "ephemeral.firstSlots.other=$OTHER" \
  "ephemeralOracles.pendingSlot=$PENDING_SLOT" "ephemeralOracles.byTagSlots=$BYTAG_SLOTS"

assert_eq "the same seed draws the same slots in two independent services" "$A" "$B"
assert_true "and a different seed draws different ones" test "$A" != "$OTHER"
assert_ge "the streams are not empty" 4 \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$A")"
# AND THE DRAWS WITHIN ONE SEED ARE DISTINCT, because a generator returning one slot forever would
# satisfy both equalities above. M35's own `getRandomField` assertion, in a second place.
assert_eq "and the four draws within one seed are all different" "4" \
  "$(python3 -c 'import json,sys; print(len(set(json.loads(sys.argv[1]))))' "$A")"

echo "== 4b. AND THE SLOTS THE ORACLES ACTUALLY ISSUED ARE THAT STREAM'S"

# THIS IS THE HALF THAT SAYS THE SERVICE WAS USED. `allocatedSlots` stayed at ZERO across a run that
# had constructed the service and never materialised a slot — `EphemeralArray.fromValues` is lazy and
# only the WIRE's serialisation reaches `materializeSlot`. A service that had never been used read
# exactly like a service that never read entropy.
assert_ge "the oracles materialised slots at all" 3 "$SLOTS"
assert_eq "the pending-logs oracle's slot is the deterministic stream's first" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0])' "$A")" "$PENDING_SLOT"
assert_eq "and the two by-tag arrays took the next two" \
  "$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); print(json.dumps(a[1:3],separators=(",",":")))' "$A")" \
  "$BYTAG_SLOTS"

echo '== 5. THE TAGGING HALF ANSWERS, AND ITS none IS HONEST'

STRATEGY="$(m36_arm discovery.report.ephemeralOracles.strategyType)"
SENDER_SOME="$(m36_arm discovery.report.ephemeralOracles.senderForTagsIsSome)"
SECRET_SOME="$(m36_arm discovery.report.ephemeralOracles.appSecretIsSome)"
FOREIGN_SOME="$(m36_arm discovery.report.ephemeralOracles.foreignSecretIsSome)"
PENDING="$(m36_arm discovery.report.ephemeralOracles.pendingCount)"
BYTAG="$(m36_arm discovery.report.ephemeralOracles.byTagCounts)"
m36_absent "ephemeralOracles.strategyType=$STRATEGY" \
  "ephemeralOracles.senderForTagsIsSome=$SENDER_SOME" \
  "ephemeralOracles.appSecretIsSome=$SECRET_SOME" \
  "ephemeralOracles.foreignSecretIsSome=$FOREIGN_SOME" \
  "ephemeralOracles.pendingCount=$PENDING" "ephemeralOracles.byTagCounts=$BYTAG"

assert_eq "the wallet has two accounts to derive tagging secrets as" "2" "$ACCOUNTS"
assert_true "and a default sender for tags" test "$SENDER" != "null"
assert_eq "resolveTaggingStrategy returns upstream's own default, address-derived" \
  "unconstrained-secret" "$STRATEGY"
assert_eq "getSenderForTags answers Some" "true" "$SENDER_SOME"
assert_eq "getAppTaggingSecret answers Some for an account this wallet holds" "true" "$SECRET_SOME"
# THE HONEST NONE, AND IT IS THE ASSERTION THAT SAYS THE ORACLE IS NOT A CONSTANT. Upstream's own
# doc: *"the only expected `None` case is an invalid recipient address; missing sender data fails
# while deriving."* So this is asked of an INVALID RECIPIENT — the zero address, which has no address
# point — and a sender outside the execution's scopes is a REFUSAL instead, asserted by the discovery
# check's §8b. Keeping the two apart is upstream's split and it was worth getting right: "this wallet
# will not act for that account" and "that account has no derivable secret" are two statements.
assert_eq "and NONE for an invalid recipient — the declared Option, used" "false" "$FOREIGN_SOME"

echo "== 6. AND THE TWO EPHEMERAL-RETURN ORACLES FOUND THE LOG"

assert_eq "getPendingTaggedLogsV2 discovered exactly one pending log" "1" "$PENDING"
assert_eq "getLogsByTagV2 answered both requests with one log each" "[1,1]" "$BYTAG"
# THE SECOND REQUEST IS THE CONTROL WALLET'S TAG, so the oracle is seen to DISCRIMINATE rather than
# to return the same bucket twice: each request gets ITS OWN log, and §4b of the discovery check
# asserts the two tags are different.
assert_eq "the index recorded one used range for the secret the circuit drew from" "1" "$RANGES"

m36_finish
