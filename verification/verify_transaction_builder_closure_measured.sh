#!/usr/bin/env bash
# M25 verification: the vendoring closure of upstream's transaction builder is MEASURED, so the
# decision that has blocked eight verification entries since M18 becomes takeable.
#
#   verification/verify_transaction_builder_closure_measured.sh   (or: just verify-tx-builder-closure)
#
# ---------------------------------------------------------------------------
# WHY A CHECK AND NOT A PARAGRAPH.
#
# "A transaction that calls a registered contract" has been deferred eight times, and the reason
# recorded each time was that upstream's only builder — `PublicTxSimulationTester` — constructs a
# `NativeWorldStateService`, which DD-9 forbids. Nobody could price the alternative, so nobody
# decided. M22 met the same shape for `PublicProcessor`, measured it at 1,580 lines, and the
# measurement is what made vendoring obvious.
#
# This check is the measurement, run rather than quoted. It computes the closure with its own
# walker over the `ts` anchor's OBJECT STORE, prints the residue it cannot place, and asserts the
# figures the milestone section and REUSE-INVENTORY.md state. A figure nobody re-derives stops
# being a measurement — that is this campaign's rule and this is a census, where the derivation IS
# the number.
#
# WHAT WOULD HAVE TO BREAK FOR THIS TO FAIL: upstream's file moving or growing; the walker failing
# to resolve an import (the residue is asserted EMPTY); the reduced set stopping being closed under
# its own imports; `NativeWorldStateService` appearing anywhere but the static factory; or a
# document quoting a figure the walk contradicts.
# ---------------------------------------------------------------------------

set -uo pipefail

TEST_NAME=verify_transaction_builder_closure_measured
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m25_trace.sh"

m24_summary_on_abnormal_exit

TSAVM="$REPO_ROOT/upstream/tsavm"
assert_dir "the ts-anchor worktree is checked out" "$TSAVM"
ANCHOR_TS="$(m24_pin ts commit)"
HEAD_TS="$(git -C "$TSAVM" rev-parse HEAD 2>/dev/null)"
assert_eq "…and it is AT the ts anchor, not on somebody's branch" "$ANCHOR_TS" "$HEAD_TS"
# `assert_eq "" ""` IS THIS CAMPAIGN'S OLDEST DEFECT, so the emptiness gets a control: the same
# `git -C` that reports the clean tree must also report a non-empty file list, or "clean" means
# "git did not run here".
assert_eq "…with nothing modified in it" "" \
  "$(git -C "$TSAVM" status --porcelain 2>/dev/null | head -5)"
assert_ge "…and that git DOES answer in this worktree, so the emptiness is a measurement" 100 \
  "$(git -C "$TSAVM" ls-files 'yarn-project/simulator/src/public/*' 2>/dev/null | grep -c . || true)"

START="yarn-project/simulator/src/public/fixtures/public_tx_simulation_tester.ts"
assert_file "upstream's transaction builder is where the inventory says" "$TSAVM/$START"

WALK_OUT="$(python3 "$VERIFY_DIR/_import_closure.py" "$TSAVM" "$START" 2>&1)"
assert_ge "the walker produced output" 5 "$(printf '%s\n' "$WALK_OUT" | grep -c . || true)"
w() { printf '%s\n' "$WALK_OUT" | awk -F'\t' -v k="$1" '$1==k{print $2}'; }

FULL_FILES="$(w FULL_FILES)"
FULL_LINES="$(w FULL_LINES)"
UNRESOLVED="$(w UNRESOLVED)"
note "full closure: $FULL_FILES files, $FULL_LINES lines"
note "unresolvable relative specifiers: ${UNRESOLVED:-0}"

# THE RESIDUE, ASSERTED EMPTY. A walker that silently drops what it cannot resolve turns a
# containment measurement into an undercount, and every number below rests on this one.
assert_eq "the walker resolved every relative specifier it met" "0" "${UNRESOLVED:-0}"
assert_eq "the FULL transitive closure is 65 files" "65" "$FULL_FILES"
assert_eq "…and 10,421 lines" "10421" "$FULL_LINES"

# The reduced set: the calldata-and-call-request half.
RED_FILES="$(w REDUCED_FILES)"
RED_LINES="$(w REDUCED_LINES)"
MIN_FILES="$(w MINIMAL_FILES)"
MIN_LINES="$(w MINIMAL_LINES)"
assert_eq "the reduced closure is 5 files" "5" "$RED_FILES"
assert_eq "…and 1,042 lines" "1042" "$RED_LINES"
assert_eq "without the registration helper it is 4 files" "4" "$MIN_FILES"
assert_eq "…and 880 lines" "880" "$MIN_LINES"
# The comparison that makes the number mean something: M22 vendored 1,580 lines and the campaign
# judged that obvious. Asserted as an inequality so it cannot rot into prose.
assert_true "the reduced closure is SMALLER than the PublicProcessor vendoring M22 judged obvious" \
  test "$RED_LINES" -lt 1580
assert_true "…and the full one is far larger, which is why the split is the whole finding" \
  test "$FULL_LINES" -gt 1580

# ===========================================================================
# WHERE THE FORBIDDEN DEPENDENCY ACTUALLY IS
#
# The claim that has blocked eight entries is that the builder CONSTRUCTS a
# `NativeWorldStateService`. It does not: it takes one, in a static factory, and calls `.fork()` on
# it. The constructor takes the `MerkleTreeWriteOperations` that call produces — and, as the block
# below this one measures, the calldata half never calls a single method on it.
# ===========================================================================
TESTER="$(git -C "$TSAVM" show "$ANCHOR_TS:$START" 2>/dev/null)"
assert_ge "the builder reads back from the object store" 250 \
  "$(printf '%s\n' "$TESTER" | grep -c . || true)"
NWS_HITS="$(printf '%s\n' "$TESTER" | grep -c 'NativeWorldStateService' || true)"
assert_eq "NativeWorldStateService appears exactly twice in the whole file" "2" "$NWS_HITS"
assert_true "…once as an import" \
  str_has_line "$TESTER" "import { NativeWorldStateService } from '@aztec/world-state';"
assert_true "…and once as the STATIC FACTORY's first parameter" \
  str_has_sub "$TESTER" 'worldStateService: NativeWorldStateService, // make sure to close this later'
assert_eq "it is never CONSTRUCTED here — no .tmp(), no new" "0" \
  "$(printf '%s\n' "$TESTER" | grep -c 'NativeWorldStateService\.\|new NativeWorldStateService' || true)"
assert_true "the only use is a fork, which yields a MerkleTreeWriteOperations" \
  str_has_sub "$TESTER" 'const merkleTree = await worldStateService.fork();'
assert_true "and the CONSTRUCTOR takes that interface instead" \
  str_has_sub "$TESTER" 'merkleTree: MerkleTreeWriteOperations,'
# The negative control for those five: a needle that is not in the file.
assert_false "a needle absent from the builder does not match" \
  str_has_sub "$TESTER" 'NativeWorldStateServiceThatDoesNotExist'
# ===========================================================================
# WHY THE REDUCED SET IS REACHABLE — AND IT IS NOT THE REASON THIS CHECK USED TO GIVE
#
# THE LINE THAT WAS HERE WAS BOTH VACUOUS AND FALSE, which is a combination worth naming:
#
#   assert_ge "this runtime already has a MerkleTreeWriteOperations implementation" 1 \
#     "$(grep -c 'ResidentMerkleWriteOperations' orchestration/src/resident_merkle_operations.ts)"
#
#   * It COULD NOT FAIL. The needle is a class name and the haystack is the file that DECLARES that
#     class, so the count is >= 1 by construction. It is this campaign's oldest family — an
#     assertion incapable of failing. The running total is CAMPAIGN-BRIEF.md's and is
#     deliberately not repeated here.
#   * It stood in for a SEMANTIC property with a NAME GREP, which is the "a citation is the
#     opposite of a dependency" shape one level up.
#   * And the property it claimed IS FALSE. `resident_merkle_operations.ts` says in its own
#     docstring that it is "deliberately NOT declared `implements MerkleTreeWriteOperations`",
#     because the declaration "would be a claim of totality" — M19's review having found exactly
#     that defect in a mirror claiming totality while intercepting two of four methods. The class
#     is structurally compatible where it can be and *loudly incompatible where it cannot*, with
#     enumerated refusals that throw `ResidentMerkleDbCannotAnswer`.
#
# So the reduced set's reachability rested on a claim that the tree contradicts. The TRUE reason is
# stronger and is measured below: THE CALLDATA HALF NEVER TOUCHES THE INTERFACE AT ALL. `merkleTree`
# is a constructor parameter that is stored and forwarded to the simulator, and the simulator is
# one of the five edges the reduction severs. No merkle implementation — ours, upstream's or any
# other — is needed to build a transaction.
# ===========================================================================
RESIDENT="$REPO_ROOT/orchestration/src/resident_merkle_operations.ts"
assert_file "the resident merkle operations module exists" "$RESIDENT"
RESIDENT_TEXT="$(cat "$RESIDENT" 2>/dev/null)"
assert_ge "…and reads back, so the two counts below are counts of something" 200 \
  "$(printf '%s\n' "$RESIDENT_TEXT" | grep -c . || true)"
assert_eq "ResidentMerkleWriteOperations does NOT declare itself a MerkleTreeWriteOperations" "0" \
  "$(printf '%s\n' "$RESIDENT_TEXT" | grep -c 'class ResidentMerkleWriteOperations[^{]*implements' || true)"
assert_true "…and the file says that is deliberate, and why" \
  str_has_sub "$RESIDENT_TEXT" 'deliberately NOT declared `implements MerkleTreeWriteOperations`'
# THE CONTROL FOR THAT ZERO. The same grep, over the same text, finds the declaration itself — so
# the zero is a zero of a needle that matches rather than of one that never could.
assert_ge "…and the class really is declared in the file that zero was measured over" 1 \
  "$(printf '%s\n' "$RESIDENT_TEXT" | grep -c '^export class ResidentMerkleWriteOperations' || true)"

# THE REAL REASON, MEASURED. The tx-building leaf reaches no merkle or world-state name at all.
LEAF_PATH="yarn-project/simulator/src/public/fixtures/utils.ts"
LEAF="$(git -C "$TSAVM" show "$ANCHOR_TS:$LEAF_PATH" 2>/dev/null)"
assert_ge "the tx-building leaf reads back from the object store" 200 \
  "$(printf '%s\n' "$LEAF" | grep -c . || true)"
assert_eq "createTxForPublicCalls's file names no merkle tree and no world state" "0" \
  "$(printf '%s\n' "$LEAF" | grep -ciE 'merkletree|world-?state' || true)"
# …and the SAME needle matches in the builder, so the zero above is a measurement rather than a
# broken pattern. This is the conjunct's own negative case.
assert_ge "…while the same needle DOES match in the builder, so that zero is attributable" 1 \
  "$(printf '%s\n' "$TESTER" | grep -ciE 'merkletree|world-?state' || true)"
# In the builder itself the parameter is only ever stored or forwarded — never called.
assert_eq "the builder never invokes a method ON merkleTree" "0" \
  "$(printf '%s\n' "$TESTER" | grep -c 'merkleTree\.' || true)"
assert_ge "…and the parameter is present to be called, so that zero means something" 5 \
  "$(printf '%s\n' "$TESTER" | grep -c 'merkleTree' || true)"

# ===========================================================================
# THE HALF THAT IS ALREADY HERE — enumerated, because "enumerate before you build" is the rule
# that has been wrong eight times in this campaign.
# ===========================================================================
assert_file "a pinned copy of the SAME file already exists in this tree, at the same anchor" \
  "$REPO_ROOT/diffsim/src/public/fixtures/public_tx_simulation_tester.ts"
VENDORED="$(cat "$REPO_ROOT/diffsim/src/public/fixtures/public_tx_simulation_tester.ts" 2>/dev/null)"
assert_true "…with a provenance header naming the upstream path" \
  str_has_sub "$VENDORED" "upstream-path:   $START"
assert_true "…and the ts anchor" str_has_sub "$VENDORED" "upstream-commit: $ANCHOR_TS"
# The registration half is already reachable too, in the orchestration, by name.
RCDB="$REPO_ROOT/orchestration/src/resident_contracts_db.ts"
assert_file "the resident contracts DB exists" "$RCDB"
RCDB_TEXT="$(cat "$RCDB" 2>/dev/null)"
assert_true "…and registering a class is a PUBLIC method, not a private step of addNewContracts" \
  str_has_sub "$RCDB_TEXT" 'async registerClass(contractClass: ContractClassPublic): Promise<boolean>'
assert_true "…as is registering an instance at an address" \
  str_has_sub "$RCDB_TEXT" 'registerInstance(instance: ContractInstanceWithAddress): boolean'
# So "a registered contract" does not need a world-state service in THIS runtime.
assert_eq "and the resident contracts DB reaches @aztec/world-state nowhere" "0" \
  "$(printf '%s\n' "$RCDB_TEXT" | grep -c '@aztec/world-state' || true)"

# ===========================================================================
# THE DOCUMENTS STATE THE MEASUREMENT, and each figure is matched in the ROW that attributes it.
# ===========================================================================
INV="$REPO_ROOT/REUSE-INVENTORY.md"
assert_file "the reuse inventory exists" "$INV"
INV_TEXT="$(cat "$INV" 2>/dev/null)"
inv_row() { printf '%s\n' "$INV_TEXT" | grep -F -- "$1" | head -1; }
assert_true "RI-72 exists" str_has_line "$INV_TEXT" "### RI-72 — Upstream's transaction builder, and the closure it drags"
assert_true "…and states the full closure in the sentence that names it" \
  str_has_sub "$(inv_row 'full transitive relative-import closure of')" \
    "$(printf "%'d" "$FULL_FILES") files and $(printf "%'d" "$FULL_LINES") lines"
assert_true "…and the reduced one in ITS own sentence" \
  str_has_sub "$(inv_row 'calldata-and-call-request half is')" \
    "$(printf "%'d" "$MIN_FILES") files and $(printf "%'d" "$MIN_LINES") lines"
assert_true "…and the 5-file variant with its own count" \
  str_has_sub "$(inv_row 'calldata-and-call-request half is')" \
    "$(printf "%'d" "$RED_FILES") files and $(printf "%'d" "$RED_LINES") lines"
assert_true "the inventory records that the forbidden dependency is in the static factory only" \
  str_has_sub "$INV_TEXT" 'static factory'
# …and that it records the CORRECTED reason. NOT asserted as the ABSENCE of the retracted sentence:
# the entry QUOTES that sentence in order to retract it, so an absence assertion would fail on the
# correction itself. The campaign has met the mirror image of this — a citation counted as a call —
# and the lesson is the same one, that a fixed-string search cannot tell a claim from a quotation of
# it. What is asserted instead is the correction's own content, which prose cannot satisfy by
# accident.
assert_true "…and that the reduced set needs no merkle implementation at all" \
  str_has_sub "$INV_TEXT" 'THE REDUCED SET NEEDS NO MERKLE IMPLEMENTATION AT ALL'
assert_true "…with the retraction naming the docstring that contradicts the retracted claim" \
  str_has_sub "$INV_TEXT" 'deliberately NOT declared `implements MerkleTreeWriteOperations`'
# The walker's own defect is recorded with its measured undercount, so the fix is a measurement.
assert_true "…and the undercount the first walker returned, so the residue rule has a case" \
  str_has_sub "$INV_TEXT" '47 files / 8,083 lines'

# The reduced set's escaping edges are ENUMERATED rather than assumed absent, and their count is
# pinned: a sixth escape appearing is a file the trim would have to sever and nobody noticed.
ESCAPES="$(w REDUCED_ESCAPES)"
note "edges the reduced set must sever: $ESCAPES"
printf '%s\n' "$WALK_OUT" | awk -F'\t' '$1=="REDUCED_ESCAPE"{printf "  --   sever %s -> %s\n", $2, $4}'
assert_eq "the reduced set has exactly eight escaping relative edges, all named" "8" "$ESCAPES"
assert_eq "…five of them from the tester's simulator half" "5" \
  "$(printf '%s\n' "$WALK_OUT" | awk -F'\t' '$1=="REDUCED_ESCAPE" && $2 ~ /public_tx_simulation_tester/' | grep -c . || true)"
assert_eq "…and three from avm/fixtures/utils.ts's three droppable functions" "3" \
  "$(printf '%s\n' "$WALK_OUT" | awk -F'\t' '$1=="REDUCED_ESCAPE" && $2 ~ /avm\/fixtures\/utils/' | grep -c . || true)"
assert_eq "…and none at all from fixtures/utils.ts, which is a LEAF" "0" \
  "$(printf '%s\n' "$WALK_OUT" | awk -F'\t' '$1=="REDUCED_ESCAPE" && $2 ~ /fixtures\/utils\.ts/ && $2 !~ /avm/' | grep -c . || true)"

m24_finish
