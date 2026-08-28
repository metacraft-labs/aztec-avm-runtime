#!/usr/bin/env bash
# test_worker_restart_from_snapshot
#
# M32 verification: "terminate mid-chain, restart from an exported snapshot, and the chain resumes at
# the same archive root."
#
# ===========================================================================================
# TERMINATE, NOT CLOSE — AND THE DIFFERENCE IS THE DELIVERABLE
# ===========================================================================================
#
# `close()` is the runtime shutting itself down: the ticker stops, the module's DB handles are
# released, everything unwinds. `terminate()` is the THREAD being killed under it with nothing
# flushed and nothing unwound, which is what a page does when a user hits reset or navigates away.
# The milestone's word is "terminate", and the second is the one a restart has to survive. So this
# check requires the termination to be real: a call made afterwards must be REFUSED BY NAME rather
# than left pending for ever, which is the hang a worker makes newly reachable.
#
# ===========================================================================================
# AND THE COMPARISON HAS TO BE ABLE TO COME OUT UNEQUAL
# ===========================================================================================
#
# "The archive root after the replay equals the archive root before it" is the assertion, and on its
# own it has never been seen to fail — which `CAMPAIGN-BRIEF.md` says is the shape to distrust. The
# arm therefore runs the SAME comparison twice, over two chains, in one page:
#
#   path A   funding, an L1-to-L2 message and three blocks, every one a FACADE call. The replay log
#            has everything the state depends on, so the roots must MATCH.
#   path B   the same, plus a token transfer. `runTokenTransfer` registers a contract class and
#            instance in the module's contract DB and seeds a deployment nullifier, an initialisation
#            nullifier and a token balance DIRECTLY into the trees — none of them a facade call, so
#            none of them in the log. The roots must DIFFER.
#
# Path B is a limitation of M23's replay-log snapshot, stated in `CHAIN-LOOP.md` §5 and measured on a
# real transaction here for the first time. It is also the control, and it is the same comparison
# over the same code.
#
# Run: just verify-m32-restart

TEST_NAME="test_worker_restart_from_snapshot"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m32_worker.sh"

m32_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m32_require_arms

echo "== 0. the arm report carries what this check reads"

ARCHIVE_BEFORE="$(m32_arm restart archiveBefore)"
ARCHIVE_AFTER="$(m32_arm restart archiveAfter)"
REF_BEFORE="$(m32_arm restart stateReferenceBefore)"
REF_AFTER="$(m32_arm restart stateReferenceAfter)"
N_BEFORE="$(m32_arm restart blockNumberBefore)"
N_AFTER="$(m32_arm restart blockNumberAfter)"
TERMINATED="$(m32_arm restart afterTerminationError)"
TARGETS="$(m32_arm restart workerTargetCount)"
U_ARCHIVE_BEFORE="$(m32_arm restart unreplayable.archiveBefore)"
U_ARCHIVE_AFTER="$(m32_arm restart unreplayable.archiveAfter)"
m32_absent \
  "restart.archiveBefore=$ARCHIVE_BEFORE" "restart.archiveAfter=$ARCHIVE_AFTER" \
  "restart.stateReferenceBefore=$REF_BEFORE" "restart.stateReferenceAfter=$REF_AFTER" \
  "restart.blockNumberBefore=$N_BEFORE" "restart.blockNumberAfter=$N_AFTER" \
  "restart.afterTerminationError=$TERMINATED" "restart.workerTargetCount=$TARGETS" \
  "restart.unreplayable.archiveBefore=$U_ARCHIVE_BEFORE" \
  "restart.unreplayable.archiveAfter=$U_ARCHIVE_AFTER"

echo "== 1. four workers really were created"

# A RESTART THAT REUSED THE FIRST THREAD WOULD SHOW ONE. Counted from the browser's own
# `Target.attachedToTarget` events, filtered to this page's session.
assert_eq "the page spawned four worker targets across the arm" "4" "$TARGETS"
assert_eq "no page error while it ran" "[]" "$(m32_arm restart pageErrors)"
assert_eq "…and no console error" "[]" "$(m32_arm restart consoleErrors)"

echo "== 2. the termination is real: an outstanding call is REFUSED BY NAME"

note "$TERMINATED"
assert_false "a call after terminate() was not accepted" str_has_sub "$TERMINATED" 'ACCEPTED'
assert_true "…it was refused, naming the operation" str_has_sub "$TERMINATED" "'state'"
assert_true "…and naming the termination as the reason" str_has_sub "$TERMINATED" 'after the worker was terminated'

echo "== 3. the fresh worker really started at genesis"

# NON-DEGENERACY BEFORE THE IDENTITY. If the second worker had somehow inherited the first one's
# state, "the roots match" would be true for the wrong reason — the same defect family as a
# comparison whose two sides are one reading.
FRESH_N="$(m32_arm restart freshBefore.blockNumber)"
FRESH_ARCHIVE="$(m32_arm restart freshBefore.archive)"
assert_eq "the second worker's chain began at block 0" "0" "$FRESH_N"
assert_false "…with an archive that is NOT the first chain's" str_has_sub "$FRESH_ARCHIVE" \
  "$(m32_arm restart archiveBefore.root)"
assert_eq "…and it is open, so 0 is a chain at genesis rather than a closed node" "true" \
  "$(m32_arm restart freshBefore.opened)"

echo "== 4. THE ASSERTION: the replay reaches the same chain"

note "archive before  $ARCHIVE_BEFORE"
note "archive after   $ARCHIVE_AFTER"
assert_ge "the source chain had produced several blocks" 3 "$N_BEFORE"
assert_eq "…and the replayed chain reaches the same block number" "$N_BEFORE" "$N_AFTER"
assert_eq "…the same archive root and next leaf index" "$ARCHIVE_BEFORE" "$ARCHIVE_AFTER"
assert_eq "…and the same four-tree state reference" "$REF_BEFORE" "$REF_AFTER"
# NON-EMPTINESS BESIDE THE EQUALITIES. Two missing values are also equal.
assert_ge "…over a state reference that is a real serialisation" 200 "${#REF_BEFORE}"
assert_true "…and an archive root that is a real field" str_has_sub "$ARCHIVE_BEFORE" '0x'

echo "== 5. …AND IT IS STILL A CHAIN: it produces the next block"

RESUMED_N="$(m32_arm restart resumed.number)"
RESUMED_EMPTY="$(m32_arm restart resumed.empty)"
AFTER_RESUME_N="$(m32_arm restart afterResume.blockNumber)"
assert_eq "the restarted node produced the NEXT block" "$((N_AFTER + 1))" "$RESUMED_N"
assert_eq "…and the node's own block number moved with it" "$RESUMED_N" "$AFTER_RESUME_N"
assert_eq "…it is an empty block, which is what produceBlock on an idle chain makes" "true" "$RESUMED_EMPTY"
# THE CHAIN IS CHAINED. The block produced after the restart must carry an archive DIFFERENT from
# the one the replay landed on — a chain that reproduced a root and then could not extend it would
# be a reconstruction.
assert_false "…and it moved the archive on from the replayed one" \
  str_has_sub "$(m32_arm restart afterResume.archive)" "$(m32_arm restart archiveAfter.root)"
assert_true "…while keeping the archive growing" \
  test "$(m32_arm restart afterResume.archive.nextAvailableLeafIndex)" -gt \
       "$(m32_arm restart archiveAfter.nextAvailableLeafIndex)"

echo "== 6. what the snapshot actually carried"

SNAP_BLOCKS="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(len(d["arms"]["restart"]["snapshot"]["blocks"]))' "$M32_ARMS")"
SNAP_FUNDING="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(len(d["arms"]["restart"]["snapshot"]["funding"]))' "$M32_ARMS")"
SNAP_MESSAGES="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(len(b["l1ToL2Messages"]) for b in d["arms"]["restart"]["snapshot"]["blocks"]))' "$M32_ARMS")"
note "the snapshot carries ${SNAP_BLOCKS} block(s), ${SNAP_FUNDING} funding entr(ies) and ${SNAP_MESSAGES} L1-to-L2 message(s)"
assert_eq "…one snapshot block per produced block" "$N_BEFORE" "$SNAP_BLOCKS"
assert_ge "…the fee-juice funding the facade applied" 1 "$SNAP_FUNDING"
assert_ge "…and the L1-to-L2 message it injected" 1 "$SNAP_MESSAGES"
assert_eq "…and it is M23's replay-log format, not a state dump" "avm-runtime-replay-log" \
  "$(m32_arm restart snapshot.format)"

echo "== 7. THE CONTROL: state seeded behind the facade does NOT round-trip"

# ===========================================================================================
# THE SAME COMPARISON, OVER THE SAME CODE, ANSWERING THE OTHER WAY.
# ===========================================================================================
note "unreplayable archive before  $U_ARCHIVE_BEFORE"
note "unreplayable archive after   $U_ARCHIVE_AFTER"
assert_eq "the second chain's replay did not throw — it produced a chain, just not the same one" \
  "none" "$(m32_arm restart unreplayable.error)"
assert_false "…and its post-import state was really read" \
  test "$U_ARCHIVE_AFTER" = "MISSING"
assert_eq "…and it reached the same BLOCK NUMBER, so the log itself replayed" \
  "$(m32_arm restart unreplayable.blockNumberBefore)" "$(m32_arm restart unreplayable.blockNumberAfter)"
assert_false "…but NOT the same archive root" str_has_sub "$U_ARCHIVE_AFTER" \
  "$(m32_arm restart unreplayable.archiveBefore.root)"
assert_false "…nor the same four-tree state reference" \
  test "$(m32_arm restart unreplayable.stateReferenceBefore)" = "$(m32_arm restart unreplayable.stateReferenceAfter)"
# THE TRANSACTION THAT CAUSED IT REALLY RAN, or "the state diverged" is a story about nothing.
assert_eq "…and the transaction whose seeding is missing was processed" "processed" \
  "$(m32_arm restart unreplayable.tokenTransfer.outcome)"
assert_eq "…without reverting" "0" "$(m32_arm restart unreplayable.tokenTransfer.revertCode)"
assert_ge "…having executed a substantial number of instructions" 100 \
  "$(m32_arm restart unreplayable.tokenTransfer.executedSteps)"
assert_true "…and the arm records WHY the replay cannot reproduce it" \
  str_has_sub "$(m32_arm restart unreplayable.reason)" 'directly into the trees'

echo "== 8. the pair read together — the identity in §4 is capable of failing"

assert_true "the two paths ran the same comparison and got different answers" \
  test "$ARCHIVE_BEFORE" = "$ARCHIVE_AFTER" -a "$U_ARCHIVE_BEFORE" != "$U_ARCHIVE_AFTER"

echo "== 9. WORKER-NODE.md §7's account, compared AGAINST THE DOCUMENT"

assert_file "the write-up exists" "$M32_DOC"
DOC="$(cat "$M32_DOC")"
row_for() { printf '%s\n' "$DOC" | grep -F "$1" | head -1; }
WORKERS_ROW="$(row_for 'workers in one page')"
assert_true "§7 states how many workers the arm creates" test -n "$WORKERS_ROW"
assert_true "…and it is the number the browser attached to" str_has_word "$WORKERS_ROW" \
  "$(python3 -c '
import sys
print(["zero","one","two","three","four","five","six"][int(sys.argv[1])].capitalize())' "$TARGETS")"
BLOCKS_ROW="$(row_for 'an L1-to-L2 message and')"
assert_true "§7 states how many blocks path A produces" test -n "$BLOCKS_ROW"
assert_true "…and it is the number the run produced" str_has_word "$BLOCKS_ROW" \
  "$(python3 -c '
import sys
print(["zero","one","two","three","four","five","six"][int(sys.argv[1])])' "$N_BEFORE")"
assert_true "…and §7 says path B's archive root and state reference come out DIFFERENT" \
  str_has_sub "$DOC" '**DIFFERENT**'
assert_true "…naming the seeding that is not in the replay log" \
  str_has_sub "$DOC" 'directly into the trees'
assert_true "…and saying that path B is also the control" \
  str_has_sub "$DOC" 'never been seen to come out unequal'

m32_finish
