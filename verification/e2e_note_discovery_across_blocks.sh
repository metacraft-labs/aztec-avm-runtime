#!/usr/bin/env bash
# e2e_note_discovery_across_blocks
#
# M36's first verification entry: **a note created in block N is discovered and spent in N+2**, with
# the control that a note belonging to another account is NOT discovered.
#
# ===========================================================================================
# THE RUNG THIS OCCUPIES, AND WHY EVERY WORD OF THE CLAIM IS A MEASUREMENT
# ===========================================================================================
#
# `CAMPAIGN-BRIEF.md`'s ladder is *asserted browser-shaped* -> *observed to evaluate* -> *observed to
# do the thing*. M36 ships a note DATABASE that a compiled Noir circuit reaches through upstream's
# oracle wire, so only the third rung is honest, and it is the one this check reads:
#
#   * "created"    — `NoteGetter.insert_note` solves a real witness in Chromium and calls
#                    `notifyCreatedNote` AND all three tagging oracles. **The wallet never hands it
#                    a tag**; it answers `getSenderForTags`, `getAppTaggingSecret` and
#                    `getNextTaggingIndex`, and the contract derives its own.
#   * "in block N" — the frame's OWN claimed public inputs are sealed by `sealPrivateFrame`, which
#                    does the kernel's siloing with upstream's own hash functions.
#   * "discovered" — the wallet computes the siloed tag INDEPENDENTLY and finds the log. Two
#                    producers, one value, compared here — which is `DEV-WALLET.md` §4's own shape.
#   * "spent in N+2" — block 3 carries the note's siloed nullifier and `getNotes(ACTIVE)` stops
#                    returning it, while `ACTIVE_OR_NULLIFIED` still does. **Both sides**, because a
#                    check that read only the first could not tell nullified from never-stored, and
#                    this file's ancestors record a whole milestone that passed on `0 == 0`.
#
# ===========================================================================================
# THE SEVEN CONTROLS, EACH FOR A DIFFERENT WAY THIS COULD BE VACUOUS
# (the header said FOUR while listing seven, and the list was numbered 1,2,3,4,5,7,6 — corrected by
#  M36's review; a header that miscounts its own list is how a control goes missing unnoticed)
# ===========================================================================================
#
#   1. ANOTHER ACCOUNT'S NOTE IS NOT DISCOVERED — and its own wallet DOES find it. Both halves, so
#      "not found" is a statement about the tag rather than about a needle nobody emits. (A first
#      version of the arm recomputed the control's tag for the wrong pair of parties and "did not
#      find" the log for a reason that had nothing to do with the keys; that is the
#      absence-over-an-excluded-subject family, in a control.)
#   2. A FABRICATED NOTE IS REFUSED BY NAME — the same request with the note hash moved by one.
#   3. A QUERY PAST THE PRODUCED HISTORY IS `LocalHistoryOnly` — the boundary, produced.
#   4. AN UNREGISTERED CONTRACT ADDRESS IS REFUSED BY NAME at tier 2's own rung — as
#      `ContractInstanceNotHeld` and NOT as `OracleUnimplemented`, because the two say different
#      things about what to build next and a reader who cannot tell them apart builds the wrong one.
#   5. A CONTRACT MAY NOT READ ANOTHER CONTRACT'S TAGGED LOGS — upstream's own first line in
#      `LogService.fetchLogsByTag`, which this handler was missing until upstream's BODY was read
#      against it. The permissive version is not visibly wrong afterwards: the tag silos with the
#      requested contract and the answer is well-formed either way.
#   6. THE SAME NOTE VALIDATED TWICE IS ONE NOTE WITH TWO SCOPES — upstream keys a stored note by
#      its siloed nullifier. A table of rows would return it twice and a contract would spend it
#      twice; the scope SET is the non-degeneracy that says the second validation was recorded.
#   7. A CONTRACT MAY NOT DERIVE ANOTHER ACCOUNT'S TAGGING SECRET — upstream's
#      `assertAllowedScope(sender, this.scopes)`, likewise missing. Upstream's own doc says the only
#      expected `None` from `getAppTaggingSecret` is an INVALID RECIPIENT, so the two answers are
#      kept apart: an out-of-scope sender FAILS and an invalid recipient returns `None`.
#
# Run: just verify-m36-discovery

TEST_NAME="e2e_note_discovery_across_blocks"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m36_notes.sh"

m36_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m36_require_arms

echo "== 1. THE PAGE RAN, AND IT RAN CLEAN"

CHROME="$(m36_top chromium)"
DIST="$(m36_top dist)"
D_ERRORS="$(m36_arm discovery.pageErrors)"
D_CONSOLE="$(m36_arm discovery.consoleErrors)"
L_ERRORS="$(m36_arm lazy.pageErrors)"
m36_absent "chromium=$CHROME" "dist=$DIST" "discovery.pageErrors=$D_ERRORS" \
  "discovery.consoleErrors=$D_CONSOLE" "lazy.pageErrors=$L_ERRORS"
assert_true "the arms ran in a real Chromium" str_has_sub "$CHROME" "Chromium"
assert_eq "the note-discovery arm raised no page error" "[]" "$D_ERRORS"
assert_eq "and no console error" "[]" "$D_CONSOLE"
assert_eq "the control arm likewise" "[]" "$L_ERRORS"
assert_eq "the arms were measured over this repository's own dist" "browser/dist" "$DIST"

echo "== 2. A REAL PRIVATE CIRCUIT CREATED THE NOTE"

C_CONTRACT="$(m36_arm discovery.report.creation.contractName)"
C_FN="$(m36_arm discovery.report.creation.functionName)"
C_TYPE="$(m36_arm discovery.report.creation.functionType)"
C_BYTES="$(m36_arm discovery.report.creation.bytecodeBytes)"
C_WITNESS="$(m36_arm discovery.report.creation.solvedWitnessSize)"
C_OUTCOME="$(m36_arm discovery.report.creation.outcome)"
C_LEDGER="$(m36_arm discovery.report.creation.oracleLedger)"
C_NOTEHASHES="$(m36_arm discovery.report.creation.noteHashes)"
C_LOGLENS="$(m36_arm discovery.report.creation.privateLogLengths)"
C_CREATED="$(m36_arm discovery.report.creation.createdNotes)"
C_HASDISC="$(m36_arm discovery.report.creation.hasDiscovery)"
C_SERVEDSET="$(m36_arm discovery.report.creation.servedSetSize)"
m36_absent "creation.contractName=$C_CONTRACT" "creation.functionName=$C_FN" \
  "creation.functionType=$C_TYPE" "creation.bytecodeBytes=$C_BYTES" \
  "creation.solvedWitnessSize=$C_WITNESS" "creation.outcome=$C_OUTCOME" \
  "creation.oracleLedger=$C_LEDGER" "creation.noteHashes=$C_NOTEHASHES" \
  "creation.privateLogLengths=$C_LOGLENS" "creation.createdNotes=$C_CREATED" \
  "creation.hasDiscovery=$C_HASDISC" "creation.servedSetSize=$C_SERVEDSET"

assert_eq "the subject is a PRIVATE function of a real contract" "abi_private" "$C_TYPE"
assert_eq "and it is the note-creating fixture" "NoteGetter insert_note" "$C_CONTRACT $C_FN"
assert_eq "it EXECUTED — the circuit solved rather than refusing" "executed" "$C_OUTCOME"
assert_ge "its bytecode is real ACIR rather than a stub" 1000 "$C_BYTES"
assert_ge "and its solved witness is a real witness rather than the parameters echoed back" \
  1000 "$C_WITNESS"
assert_eq "a discovery source WAS attached, so the with-discovery partition was in force" \
  "true" "$C_HASDISC"
# READ FROM THE HANDLE AND COMPARED AGAINST THE SURFACE REPORT, not against a literal. A number
# typed here would have to move every time somebody else closes another tier-2 rung on this shared
# branch — which has now happened twice during this milestone — and *"a constant you have just typed
# into a check looks like a measurement to the person typing it"*. Two producers out of one run.
assert_eq "and the served set it reports is that partition's, read from the handle" \
  "$(m36_arm discovery.report.surface.servedWithDiscovery)" "$C_SERVEDSET"

echo "== 2b. THE CONTRACT DERIVED ITS OWN TAG THROUGH M36's THREE TAGGING ORACLES"

# A CITATION IS THE OPPOSITE OF A DEPENDENCY, so this is asked of the LEDGER the execution produced
# rather than of the contract's source or of this check's intentions.
for oracle in aztec_prv_getSenderForTags aztec_prv_getAppTaggingSecret aztec_prv_getNextTaggingIndex; do
  assert_true "the circuit called $oracle" str_has_sub "$C_LEDGER" "\"served:$oracle\""
done
assert_true "and it recorded the note through M35's own notifyCreatedNote" \
  str_has_sub "$C_LEDGER" '"served:aztec_prv_notifyCreatedNote"'
assert_eq "the handler recorded exactly one created note, with its randomness and content" \
  "1" "$C_CREATED"
# NON-DEGENERACY: a ledger with nothing but SERVED entries in it is what says the frame ran to
# completion rather than stopping at the first thing it needed.
#
# COUNTED AS "NOT SERVED" RATHER THAN AS "REFUSED", AND THE DIFFERENCE IS A THIRD OUTCOME THAT NOW
# EXISTS. The landed tier-2 rung added `unavailable` — a served oracle with no answer for THIS
# argument — so a count of `refused:` alone would read zero over a ledger carrying an unavailable
# entry, which is the enumerate-the-spellings family arriving through a value somebody else added.
# The complement is enumerated instead of the failures.
assert_eq "and EVERY entry in that ledger is a served one" "0" \
  "$(python3 -c 'import json,sys; print(sum(1 for x in json.loads(sys.argv[1]) if not x.startswith("served:")))' "$C_LEDGER")"

echo "== 3. THE CIRCUIT'S OWN PUBLIC INPUTS CARRY THE NOTE AND THE LOG"

assert_eq "the circuit claimed exactly one note hash" "1" \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$C_NOTEHASHES")"
assert_eq "and exactly one private log" "1" \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$C_LOGLENS")"
# THE CLAIMED LENGTH IS READ, NOT THE PADDED CAPACITY. `MAX_NOTE_HASHES_PER_CALL` is sixteen and a
# call that creates one note fills one slot; reading the array wholesale would put fifteen ZERO note
# hashes into a note database, and a zero note hash stores exactly like a real one.
assert_ge "the log carries a real payload rather than an empty slot" 2 \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0])' "$C_LOGLENS")"

echo "== 4. THE WALLET COMPUTED THE SILOED TAG INDEPENDENTLY, AND IT IS THE ONE THE BLOCK CARRIES"

T_MINE="$(m36_arm discovery.report.tags.mine)"
T_THEIRS="$(m36_arm discovery.report.tags.theirs)"
T_SEALED="$(m36_arm discovery.report.tags.sealedFirstFields)"
T_MYLOGS="$(m36_arm discovery.report.tags.myLogs)"
T_THEIRSOWN="$(m36_arm discovery.report.tags.theirLogsUnderTheirTag)"
T_MINE_UNDER_THEIRS="$(m36_arm discovery.report.tags.myLogsUnderTheirTag)"
T_THEIRS_UNDER_MINE="$(m36_arm discovery.report.tags.theirLogsUnderMyTag)"
m36_absent "tags.mine=$T_MINE" "tags.theirs=$T_THEIRS" "tags.sealedFirstFields=$T_SEALED" \
  "tags.myLogs=$T_MYLOGS" "tags.theirLogsUnderTheirTag=$T_THEIRSOWN" \
  "tags.myLogsUnderTheirTag=$T_MINE_UNDER_THEIRS" "tags.theirLogsUnderMyTag=$T_THEIRS_UNDER_MINE"

SEALED_0="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0])' "$T_SEALED")"
SEALED_1="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[1])' "$T_SEALED")"

# TWO PRODUCERS, ONE VALUE. The left side is what the WALLET computed from its own keys; the right
# side is the first field of the log the BLOCK carries, which the contract emitted and the sealer
# siloed. Neither was handed to the other.
assert_eq "the wallet's own siloed tag is the first field of the log the block carries" \
  "$T_MINE" "$SEALED_0"
assert_eq "and the second wallet's tag is the first field of ITS log" "$T_THEIRS" "$SEALED_1"
# NON-DEGENERACY: two equal tags would satisfy both assertions above and say nothing.
assert_true "the two tags are DIFFERENT, so the comparison above is not one value twice" \
  test "$T_MINE" != "$T_THEIRS"
assert_true "and neither is the zero field" test "$T_MINE" != "0x0000000000000000000000000000000000000000000000000000000000000000"

echo "== 4b. THE CONTROL: ANOTHER ACCOUNT'S NOTE IS NOT DISCOVERED, AND ITS OWN WALLET FINDS IT"

assert_eq "the wallet finds its own log under its own tag" "1" "$T_MYLOGS"
assert_eq "the second wallet finds ITS log under ITS tag" "1" "$T_THEIRSOWN"
assert_eq "the wallet's log is NOT under the other account's tag" "0" "$T_MINE_UNDER_THEIRS"
assert_eq "and the other account's log is NOT under the wallet's" "0" "$T_THEIRS_UNDER_MINE"

echo "== 5. THE NOTE WAS VALIDATED AGAINST THE BLOCK'S OWN NOTE HASHES, AND STORED"

N_STORED="$(m36_arm discovery.report.notes.stored)"
N_ACTIVE="$(m36_arm discovery.report.notes.activeAfterCreation)"
N_ACTIVE_AFTER="$(m36_arm discovery.report.notes.activeAfterSpend)"
N_EITHER_AFTER="$(m36_arm discovery.report.notes.eitherAfterSpend)"
N_ROWS2="$(m36_arm discovery.report.notes.rowsAfterRevalidation)"
N_SCOPES="$(m36_arm discovery.report.notes.scopesOnTheNote)"
N_ACTIVE2="$(m36_arm discovery.report.notes.activeAfterRevalidation)"
N_CREATED_BLOCK="$(m36_arm discovery.report.notes.creationBlock)"
N_SPEND_BLOCK="$(m36_arm discovery.report.notes.spendBlock)"
m36_absent "notes.stored=$N_STORED" "notes.activeAfterCreation=$N_ACTIVE" \
  "notes.activeAfterSpend=$N_ACTIVE_AFTER" "notes.eitherAfterSpend=$N_EITHER_AFTER" \
  "notes.creationBlock=$N_CREATED_BLOCK" "notes.spendBlock=$N_SPEND_BLOCK" \
  "notes.rowsAfterRevalidation=$N_ROWS2" "notes.scopesOnTheNote=$N_SCOPES" \
  "notes.activeAfterRevalidation=$N_ACTIVE2"

assert_eq "exactly one note is in the table" "1" "$N_STORED"
assert_eq "and getNotes(ACTIVE) returns it after creation" "1" "$N_ACTIVE"

echo "== 5b. THE CONTROL: THE SAME NOTE UNDER A SECOND SCOPE IS ONE NOTE, NOT TWO"

# UPSTREAM KEYS A STORED NOTE BY ITS SILOED NULLIFIER AND UNIONS THE SCOPE INTO IT
# (`NoteStore.addNotes` -> `StoredNote.addScope`; `NoteStore.getNotes` collects into a Map keyed by
# the same value). A table of ROWS would hold two, `getNotes` would return two, and a contract would
# try to spend one note twice — the double-count `test_tagging_index_advances`' control is about,
# arriving from the storage side. Found by reading upstream's own `note_store.ts` against this one.
assert_eq "the table still holds ONE row after a second validation" "1" "$N_ROWS2"
assert_eq "and getNotes returns it ONCE" "1" "$N_ACTIVE2"
# NON-DEGENERACY: the two readings above are also what a second validation that did NOTHING AT ALL
# would produce. The scope set is what says the second one was recorded.
assert_eq "and the note now carries BOTH scopes, so the second validation was not a no-op" \
  "2" "$N_SCOPES"

echo "== 6. CREATED IN BLOCK N, SPENT IN BLOCK N+2"

assert_eq "the note was created in block 1" "1" "$N_CREATED_BLOCK"
assert_eq "and its nullifier landed in block 3" "3" "$N_SPEND_BLOCK"
assert_eq "which is N+2 — computed from the two blocks rather than typed" "2" \
  "$((N_SPEND_BLOCK - N_CREATED_BLOCK))"
assert_eq "getNotes(ACTIVE) no longer returns it" "0" "$N_ACTIVE_AFTER"
# THE OTHER SIDE OF THE PAIR, AND IT IS WHY THE ZERO ABOVE MEANS SOMETHING. A note that was never
# stored also gives 0 for ACTIVE; only the second reading tells the two apart.
assert_eq "and getNotes(ACTIVE_OR_NULLIFIED) still does — so 'nullified' is not 'never stored'" \
  "1" "$N_EITHER_AFTER"

echo "== 7. ALL EIGHT DISCOVERY ORACLES WERE EXERCISED, AS A SET"

S_DISCOVERY="$(m36_arm discovery.report.surface.discovery)"
S_EXERCISED="$(m36_arm discovery.report.surface.exercised)"
S_SERVED_WITH="$(m36_arm discovery.report.surface.servedWithDiscovery)"
S_REFUSING_WITH="$(m36_arm discovery.report.surface.refusingWithDiscovery)"
S_SERVED_WITHOUT="$(m36_arm discovery.report.surface.servedWithout)"
S_REFUSING_WITHOUT="$(m36_arm discovery.report.surface.refusingWithout)"
S_REGISTRY="$(m36_arm discovery.report.surface.registry)"
m36_absent "surface.discovery=$S_DISCOVERY" "surface.exercised=$S_EXERCISED" \
  "surface.servedWithDiscovery=$S_SERVED_WITH" "surface.refusingWithDiscovery=$S_REFUSING_WITH" \
  "surface.servedWithout=$S_SERVED_WITHOUT" "surface.refusingWithout=$S_REFUSING_WITHOUT" \
  "surface.registry=$S_REGISTRY"

# AS A SET AND IN BOTH DIRECTIONS. "Implemented" has to mean "observed to answer" (M35's rule), and
# a size comparison would pass over a set with one name swapped for another.
assert_eq "the exercised set EQUALS the declared discovery set" "$S_DISCOVERY" "$S_EXERCISED"
assert_eq "and it is eight oracles" "8" \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$S_EXERCISED")"
assert_eq "the two partitions sum to the registry, with a discovery source" \
  "$S_REGISTRY" "$((S_SERVED_WITH + S_REFUSING_WITH))"
assert_eq "and without one" "$S_REGISTRY" "$((S_SERVED_WITHOUT + S_REFUSING_WITHOUT))"
# EIGHT AND NOT NINE, AND THE MISSING ONE IS THE RECONCILIATION. `aztec_utl_getContractInstance`
# was M36's ninth until the parallel tier-2 answer landed on `origin/dev` serving it
# UNCONDITIONALLY from a directory the wallet holds, with a third ledger outcome (`unavailable`) for
# an address it does not. That is the better model — M36's own version recorded `refused` for an
# unheld address, which writes a fact about the DATA as a fact about the PARTITION — so the second
# partition is the eight note and tagging oracles and the rung is in the first.
assert_eq "the with-discovery served set is exactly eight larger" "8" \
  "$((S_SERVED_WITH - S_SERVED_WITHOUT))"
assert_eq "and tier 2's rung is in the ALWAYS-served set rather than in the discovery one" "0" \
  "$(python3 -c 'import json,sys; print(1 if "aztec_utl_getContractInstance" in json.loads(sys.argv[1]) else 0)' "$S_DISCOVERY")"
assert_eq "the registry is upstream's 68" "68" "$S_REGISTRY"
# AND THE ALWAYS-SERVED SET IS NON-TRIVIAL AND NOT THE WHOLE REGISTRY, so "34 + 34" and "43 + 25" are
# both partitions of something rather than one set and its empty complement.
assert_ge "the always-served set is a real set" 30 "$S_SERVED_WITHOUT"
assert_ge "and the refusing set is too, so the partition is not degenerate" 20 "$S_REFUSING_WITH"

echo "== 8. THE CONTROLS"

F_REFUSAL="$(m36_arm discovery.report.controls.fabricatedRefusal)"
B_REFUSAL="$(m36_arm discovery.report.controls.boundaryRefusal)"
U_REFUSAL="$(m36_arm discovery.report.controls.unregisteredRefusal)"
X_REFUSAL="$(m36_arm discovery.report.controls.crossContractRefusal)"
S_REFUSAL="$(m36_arm discovery.report.controls.outOfScopeRefusal)"
T_REFUSAL="$(m36_arm discovery.report.controls.uncontrolledSenderRefusal)"
m36_absent "controls.fabricatedRefusal=$F_REFUSAL" "controls.boundaryRefusal=$B_REFUSAL" \
  "controls.unregisteredRefusal=$U_REFUSAL" "controls.crossContractRefusal=$X_REFUSAL" \
  "controls.outOfScopeRefusal=$S_REFUSAL" "controls.uncontrolledSenderRefusal=$T_REFUSAL"

# THE PRECONDITION UPSTREAM STATES AND ENFORCES NOWHERE.
# `resolve_sender` requires the default tag sender to be an account the wallet CONTROLS, in a
# comment; tag senders are unconstrained, so nothing downstream checks it. A sender the wallet
# cannot derive as raises NO error: the oracle answers it, the contract tags with it, the
# transaction is valid, and the tagging state belongs to an account nobody can recover — the
# recipient simply never finds the message. A liveness failure with nothing attached, which is why
# it is refused at CONFIGURATION time rather than per call: answering it correctly a thousand times
# does not make an unrecoverable sender recoverable.
assert_true "a default tag sender the wallet cannot derive as is refused" \
  str_has_sub "$T_REFUSAL" "is not one of the"
assert_true "…in upstream's own terms, so the requirement is findable" \
  str_has_sub "$T_REFUSAL" "an account the wallet CONTROLS"
assert_true "…and saying why nothing downstream would have caught it" \
  str_has_sub "$T_REFUSAL" "unconstrained"

assert_true "a fabricated note is REFUSED rather than stored" \
  test "$F_REFUSAL" != "null"
assert_true "and the refusal names the transaction it was not in" \
  str_has_sub "$F_REFUSAL" "actually wrote"
assert_true "and says why a stored one would be worse" str_has_sub "$F_REFUSAL" "would then be spent"

assert_true "a query past the produced history is refused" test "$B_REFUSAL" != "null"
assert_true "and the refusal NAMES itself" str_has_sub "$B_REFUSAL" "LocalHistoryOnly"
assert_true "and says what the block source actually holds" str_has_sub "$B_REFUSAL" "blocks 1.."

assert_true "an unregistered contract address is refused at tier 2's own rung" \
  test "$U_REFUSAL" != "null"
assert_true "and the refusal names the oracle" str_has_sub "$U_REFUSAL" "aztec_utl_getContractInstance"
# THE REFUSAL CARRIES THE MEASUREMENT THAT DECIDED IT, which is what makes it actionable rather than
# cautious: a fabricated instance does not carry the circuit one instruction further.
assert_true "and it is ContractInstanceNotHeld rather than OracleUnimplemented" \
  str_has_sub "$U_REFUSAL" "ContractInstanceNotHeld"
# THE TWO REFUSALS SAY DIFFERENT THINGS ABOUT WHAT TO BUILD NEXT — "register the contract" against
# "build tier 2" — and a handler that conflated them would pass every count in this file while
# sending a reader to the wrong milestone.
assert_false "and NOT the partition refusal, which would name the wrong milestone" \
  str_has_sub "$U_REFUSAL" "OracleUnimplemented"
assert_true "and it says how many the directory holds, so 'not held' over empty and over four differ" \
  str_has_sub "$U_REFUSAL" "the directory holds"

echo "== 8b. THE TWO UPSTREAM GUARDS THIS HANDLER WAS MISSING"

# BOTH WERE FOUND BY READING UPSTREAM'S OWN HANDLER BODIES AGAINST THIS ONE while a sweep ran, which
# is the only work available during one and is where M35's three aborts found four validations. In
# both cases the permissive version is not visibly wrong afterwards.
assert_true "a log retrieval request for ANOTHER contract is refused" test "$X_REFUSAL" != "null"
assert_true "and the refusal names the oracle" str_has_sub "$X_REFUSAL" "aztec_utl_getLogsByTagV2"
assert_true "and names BOTH addresses — the one asked for and the one executing" \
  str_has_sub "$X_REFUSAL" "this frame is executing as"

assert_true "a tagging secret for an account outside the execution's scopes is refused" \
  test "$S_REFUSAL" != "null"
assert_true "and the refusal names the oracle" str_has_sub "$S_REFUSAL" "aztec_prv_getAppTaggingSecret"
assert_true "and names the scope AND the list, so a reader can see which is which" \
  str_has_sub "$S_REFUSAL" "allowed scopes ["

echo "== 9. THE DOCUMENT'S FIGURES, RE-DERIVED FROM THE ARTEFACTS"

[ -s "$M36_DOC" ] || die "there is no $M36_DOC"
FIG="$(python3 "$VERIFY_DIR/_m36_doc_figures.py" "$M36_DOC" "$BROWSER_DIST/chunks.json" "$M36_ARMS")"
CHECKED="$(printf '%s\n' "$FIG" | awk -F'\t' '$1=="CHECKED"{print $2}')"
# `xargs` RATHER THAN `tr`, and it is not cosmetic: `tr '\n' ' '` over an EMPTY list produces a
# single SPACE, so the assertion compares "" against " " and fails on a document with nothing wrong
# with it — a check that can only ever be red is the mirror of one that can only ever be green.
BAD="$(printf '%s\n' "$FIG" | awk -F'\t' '$1=="BAD"{print $2}' | xargs -r echo)"
MISSING="$(printf '%s\n' "$FIG" | awk -F'\t' '$1=="MISSING"{print $2}' | xargs -r echo)"
assert_ge "the comparer found figures to compare rather than an empty list" 15 "$CHECKED"
assert_eq "every figure LOCAL-HISTORY.md states is the one the artefacts produce" "" "$BAD"
assert_eq "and every subject line it names is still in the document" "" "$MISSING"

m36_finish
