#!/usr/bin/env bash
# M25 verification, OQ-5: the transpiler debug-info investigation records a VERDICT WITH ITS
# EVIDENCE, and the runtime's default rung follows it.
#
#   verification/verify_oq5_source_mapping_verdict_recorded.sh     (or: just verify-oq5)
#
# ---------------------------------------------------------------------------
# WHAT WOULD HAVE TO BE BROKEN FOR THIS TO FAIL, AND IS THAT WHAT THE NAME PROMISES?
#
# The campaign's recurring defect is a check that is a correct assertion about the wrong thing. So,
# stated up front, this check fails if and only if one of these stops being true:
#
#   1. The transpiler at the `cpp` anchor stops re-keying `brillig_locations` by AVM pc — the
#      claim the whole verdict rests on. Read out of the OBJECT STORE, four call sites, by line.
#   2. A SHIPPED Aztec artifact stops carrying a byte-offset-keyed map — re-derived from
#      `@aztec/noir-test-contracts.js`'s `AvmTest`, never from a fixture of ours.
#   3. `SOURCE-MAPPING.md` states a figure the measurement contradicts. Every number in §2 is
#      re-derived; each needle is anchored to its ROW, not to the file, because M24's review
#      measured that a file-wide `| <number> |` match let two rows swap and stay green.
#   4. The runtime's default rung stops following the verdict — `rungFor` is RUN over five artifact
#      shapes and each rung is asserted, so the ladder cannot collapse to one step.
#
# What it deliberately does NOT do: assert that a document contains a sentence. A bare-text needle
# satisfied by prose is on this campaign's list twice.
# ---------------------------------------------------------------------------

set -uo pipefail

TEST_NAME=verify_oq5_source_mapping_verdict_recorded
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m25_trace.sh"

m24_summary_on_abnormal_exit

DOC="$REPO_ROOT/SOURCE-MAPPING.md"
assert_file "the verdict document exists" "$DOC"
DOC_TEXT="$(cat "$DOC" 2>/dev/null)"
assert_ge "and it is not an empty file" 100 "$(printf '%s\n' "$DOC_TEXT" | grep -c . || true)"

# ===========================================================================
# PART 1 — the transpiler, at the anchor, out of the object store
# ===========================================================================
ANCHOR="$(m24_pin cpp commit)"
assert_eq "the cpp anchor is read from pins.json rather than typed here" \
  "233d8e099336c1773b89e939100af047ed9c4f71" "$ANCHOR"

TRANSPILE="$(m25_transpiler_file src/transpile.rs)"
CONTRACT="$(m25_transpiler_file src/transpile_contract.rs)"
INSTR="$(m25_transpiler_file src/instructions.rs)"
# NON-EMPTINESS FIRST. Every assertion below is a `str_has_*` over these, and a `git show` that
# resolved to nothing would make every one of them fail for a reason that has nothing to do with
# the transpiler — or, if any were negative, pass for one.
assert_ge "avm-transpiler/src/transpile.rs reads back from the anchor" 1000 \
  "$(printf '%s\n' "$TRANSPILE" | grep -c . || true)"
assert_ge "avm-transpiler/src/transpile_contract.rs reads back from the anchor" 50 \
  "$(printf '%s\n' "$CONTRACT" | grep -c . || true)"
assert_ge "avm-transpiler/src/instructions.rs reads back from the anchor" 50 \
  "$(printf '%s\n' "$INSTR" | grep -c . || true)"

assert_true "brillig_to_avm RETURNS the pc map rather than dropping it" \
  str_has_sub "$TRANSPILE" 'pub fn brillig_to_avm(brillig_bytecode: &[BrilligOpcode<FieldElement>]) -> (Vec<u8>, Vec<usize>)'
assert_true "the AVM pc advances by the BYTE SIZE of the instructions emitted" \
  str_has_sub "$TRANSPILE" 'brillig_pcs_to_avm_pcs.push(current_avm_pc);'
assert_true "…and an instruction's size is the length of its bytes" \
  str_has_sub "$INSTR" 'pub fn size(&self) -> usize {'
assert_true "…measured as to_bytes().len(), so a pc is a byte offset and not an index" \
  str_has_sub "$INSTR" 'self.to_bytes().len()'
assert_true "patch_debug_info_pcs exists and takes the map" \
  str_has_sub "$TRANSPILE" 'pub fn patch_debug_info_pcs('
# THE LOAD-BEARING LINE. Not "the function exists" — the function BODY re-keys, and this is the
# expression that does it. A rename of the function would still leave the mapping preserved; this
# expression disappearing is what would break the verdict.
assert_true "…and its body re-keys each location THROUGH the map" \
  str_has_sub "$TRANSPILE" 'brillig_pcs_to_avm_pcs[original_opcode_location.index()]'
assert_true "…assigning the re-keyed map back onto the DebugInfo" \
  str_has_sub "$TRANSPILE" 'patched_debug_info.brillig_locations = patched_brillig_locations;'
assert_true "the contract transpiler CALLS it on the function's own debug symbols" \
  str_has_sub "$CONTRACT" 'patch_debug_info_pcs('
assert_true "…and stores the result as the emitted artifact's debug_symbols" \
  str_has_sub "$CONTRACT" 'debug_symbols: ProgramDebugInfo { debug_infos },'

# THE NEGATIVE CONTROL FOR THE WHOLE BLOCK. A needle that could never match, over the same
# haystacks, so the eight assertions above are assertions of a lookup that works.
assert_false "a needle that is in none of the three files does NOT match" \
  str_has_sub "$TRANSPILE$CONTRACT$INSTR" 'patch_debug_info_pcs_THAT_DOES_NOT_EXIST'

# The C++ side's pc is the same byte offset, which is what makes the two halves the same number.
EXEC_CPP="$(git -C "$FORK_ROOT" show "$ANCHOR:barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/execution.cpp" 2>/dev/null)"
assert_ge "vm2's execution.cpp reads back from the anchor" 1000 \
  "$(printf '%s\n' "$EXEC_CPP" | grep -c . || true)"
assert_true "the AVM advances its pc by the instruction's size IN BYTES" \
  str_has_sub "$EXEC_CPP" 'context.set_next_pc(pc + static_cast<PC>(instruction.size_in_bytes()));'

# The residual hole, asserted as an ABSENCE with its spellings enumerated — this campaign's rule is
# that an absence claim is only as wide as the spellings you wrote down.
PROC_HITS="$(printf '%s\n%s\n' "$TRANSPILE" "$CONTRACT" | grep -c 'brillig_procedure_locs' || true)"
assert_eq "the transpiler never mentions brillig_procedure_locs, so it cannot be re-keying it" \
  "0" "$PROC_HITS"
ASSERT_MSG_HITS="$(printf '%s\n%s\n' "$TRANSPILE" "$CONTRACT" | grep -c 'assert_messages' || true)"
assert_eq "…and never mentions assert_messages either, so the artifact drops them" \
  "0" "$ASSERT_MSG_HITS"
# The control for those two zeros: a name that IS there, counted the same way.
assert_ge "the same grep finds brillig_locations, so the two zeros are zeros of a grep that works" \
  1 "$(printf '%s\n%s\n' "$TRANSPILE" "$CONTRACT" | grep -c 'brillig_locations' || true)"

# ===========================================================================
# PART 2 — the artefact, and the arms
# ===========================================================================
m25_require_arms
note "artifact: $M25_ARTIFACT"
note "roots searched:"
while IFS=$'\t' read -r root found; do note "  $root: $found"; done < <(m25_artifact_roots_found)
assert_ge "at least one node_modules root ships the AvmTest artifact" 1 \
  "$(m25_artifact_roots_found | grep -c 'yes$' || true)"

# WHICH ARTIFACT, NOT JUST THAT THERE IS ONE — added by M25's review.
#
# TWO @aztec NIGHTLY LINES ARE INSTALLED IN THIS TREE AT ONCE and `pins.json` says in as many words
# that they are not interchangeable: `deletion_era` (5.0.0-nightly.20260626 — diffsim, spike,
# orchestration) is the frozen evidence §2.2 names, and `current` (5.3.0-nightly.20260819 — drift)
# is a DIFFERENT build of the same contract. Measured: the diffsim and spike copies are
# byte-identical to each other and the drift copy is not.
#
# `M25_ARTIFACT_ROOTS` is "diffsim spike drift probe-mt orchestration", so the search crosses both
# lines and puts a `current` root THIRD — ahead of `orchestration`, which is a `deletion_era` one.
# With `diffsim/node_modules` and `spike/node_modules` absent, every figure below would be measured
# against the wrong contract. Those assertions would go red, so it fails safe — but they would read
# as "the transpiler stopped preserving the mapping", which is a discovery about the subject rather
# than about the tree, and this campaign has believed that kind of red before.
#
# So the pin is asserted from the artifact's OWN `aztec_version` against what `pins.json` declares,
# and a mismatch is one named failure instead of six anonymous ones.
DECLARED_PIN="$(python3 -c '
import json, sys
print((json.load(open(sys.argv[1], encoding="utf-8")).get("npm", {}).get("deletion_era", {})
       or {}).get("version", "MISSING"))' "$REPO_ROOT/pins.json" 2>/dev/null || printf 'MISSING\n')"
assert_true "pins.json declares a deletion_era npm pin, so the comparison below has two sides" \
  test "$DECLARED_PIN" != "MISSING"
assert_eq "the artifact measured is the deletion_era pin's, not the current line's" \
  "$DECLARED_PIN" "$(m25_arm 'd["artifact"]["aztecVersion"]')"
assert_true "…and §2.2 names that same pin as the one it measured" \
  str_has_sub "$DOC_TEXT" '`deletion_era` pin'

BYTECODE="$(m25_arm 'd["artifact"]["bytecodeLength"]')"
MAPPED="$(m25_arm 'd["artifact"]["mappedPcs"]')"
FILES="$(m25_arm 'd["artifact"]["fileCount"]')"
PROCMAX="$(m25_arm 'd["artifact"]["procedureLocMax"]')"
PCMIN="$(m25_arm 'd["verdicts"]["real"]["pcRange"]["min"]')"
PCMAX="$(m25_arm 'd["verdicts"]["real"]["pcRange"]["max"]')"

assert_eq "the shipped AvmTest public_dispatch bytecode is 50,939 bytes" "50939" "$BYTECODE"
assert_eq "its debug symbols map 9,021 program counters" "9021" "$MAPPED"
assert_eq "over an 86-file file_map" "86" "$FILES"
assert_eq "the lowest mapped pc is 706" "706" "$PCMIN"
assert_eq "the highest mapped pc is 50,526" "50526" "$PCMAX"
# THE DECISIVE INEQUALITY, and it is asserted rather than described: byte offsets must fit inside
# the bytecode, and a Brillig OPCODE INDEX for a 9,021-instruction program would be nowhere near.
assert_true "the highest mapped pc is INSIDE the bytecode, as a byte offset must be" \
  test "$PCMAX" -lt "$BYTECODE"
assert_true "…and it is within 1% of the end, which a dense opcode index could not be" \
  test "$PCMAX" -gt "$((BYTECODE - BYTECODE / 100))"
# THE STRIDE CENSUS, ADDED BY M25'S REVIEW.
#
# §2.2 stated that the keys advance "in strides of 4–9" and NOTHING RE-DERIVED IT. It is false: the
# fifteen keys the document prints two lines above contain a stride of 18 (772 -> 790), and across
# the whole map the strides run to 410. Every other figure in that block was re-derived and every
# other figure was right, which is what makes this the campaign's "a figure nobody re-derives rots"
# rather than a typo — in the document whose own header says every figure in §2 is re-derived.
#
# The census is asserted in full, INCLUDING the figure that makes the retired claim false, so a
# regression back to "4–9" cannot pass. The shape facts the verdict actually rests on — sparse,
# strictly increasing, inside the bytecode — are asserted separately above and below, because a
# stride distribution is decoration and those are the argument.
SCOUNT="$(m25_arm 'd["artifact"]["strideCount"]')"
SMIN="$(m25_arm 'd["artifact"]["strideMin"]')"
SMAX="$(m25_arm 'd["artifact"]["strideMax"]')"
SBAND="$(m25_arm 'd["artifact"]["stridesInFourToNine"]')"
assert_eq "there is exactly one stride between each pair of mapped pcs" "$((MAPPED - 1))" "$SCOUNT"
assert_eq "the smallest gap between two mapped pcs is 4" "4" "$SMIN"
assert_eq "…and the largest is 410, which is why a RANGE was the wrong shape of claim" "410" "$SMAX"
assert_eq "8,580 of the gaps fall in the 4–9 band" "8580" "$SBAND"
assert_true "…which is most of them but NOT all, so the retired '4–9' claim stays retired" \
  test "$SBAND" -lt "$SCOUNT"
assert_eq "the keys are STRICTLY increasing, which is the property the byte-offset reading needs" \
  "true" "$(m25_arm 'd["artifact"]["strictlyIncreasing"]')"

# The residual hole, measured on the artefact rather than only grepped for above.
assert_true "brillig_procedure_locs' values top out far below the pc map's maximum, so it is a SECOND key space" \
  test "$PROCMAX" -lt "$((PCMAX / 2))"
assert_ge "…and that maximum was actually read rather than defaulting to zero" 1 "$PROCMAX"

# ===========================================================================
# PART 3 — the LADDER IS RUN, all five shapes, each rung with a case
#
# A ladder whose only exercised rung is the top one is a ladder with one step, and "the default
# rung follows the verdict" would then be a statement about one artifact.
# ===========================================================================
assert_eq "a real shipped artifact reaches rung 1" "1" "$(m25_arm 'd["verdicts"]["real"]["rung"]')"
assert_eq "no debug symbols at all is rung 3" "3" "$(m25_arm 'd["verdicts"]["noDebugInfo"]["rung"]')"
assert_eq "debug symbols that map nothing is rung 3 — SEPARATELY, because present != mapping" \
  "3" "$(m25_arm 'd["verdicts"]["emptyLocations"]["rung"]')"
assert_eq "a map keyed past the end of the bytecode is rung 3" \
  "3" "$(m25_arm 'd["verdicts"]["keyedPastEnd"]["rung"]')"
assert_eq "a mapped artifact with no source TEXT is rung 2, not rounded up to 1" \
  "2" "$(m25_arm 'd["verdicts"]["noSourceText"]["rung"]')"
# Each reason is distinct and NAMES its cause — a rung number with a shared reason would make the
# four degradations indistinguishable to a reader of the container.
for arm in real noDebugInfo emptyLocations keyedPastEnd noSourceText; do
  assert_ge "the $arm verdict carries a reason of its own" 30 \
    "$(printf '%s' "$(m25_arm "d[\"verdicts\"][\"$arm\"][\"reason\"]")" | wc -c)"
done
assert_eq "the five reasons are five DISTINCT sentences" "5" \
  "$(for a in real noDebugInfo emptyLocations keyedPastEnd noSourceText; do
       m25_arm "d[\"verdicts\"][\"$a\"][\"reason\"]"; done | sort -u | grep -c . || true)"
assert_true "…and the keyed-past-end reason says WHY it is not byte offsets" \
  str_has_sub "$(m25_arm 'd["verdicts"]["keyedPastEnd"]["reason"]')" 'NOT keyed by AVM byte offset'

# ===========================================================================
# PART 4 — the DOCUMENT states the measurement, ROW BY ROW
#
# M24's review found that matching a figure as `| <number> |` anywhere in a file let two rows swap
# and the check stay green over a document that said the reverse of its data. Every figure here is
# matched inside the line that attributes it.
# ===========================================================================
doc_row() { # <needle-that-identifies-the-row>
  printf '%s\n' "$DOC_TEXT" | grep -F -- "$1" | head -1
}
# The document writes its figures with thousands separators, so the MEASUREMENT is formatted the
# same way rather than the document being matched loosely. A loose match is how `| 50939 |`
# elsewhere in the file would satisfy a row assertion.
commafy() { printf "%'d" "$1"; }
assert_true "§2.2's bytecode figure is stated in the line that names public_dispatch" \
  str_has_sub "$(doc_row 'public_dispatch        bytecode')" "$(commafy "$BYTECODE")"
assert_true "§2.2's entry count is stated in the brillig_locations line" \
  str_has_sub "$(doc_row 'brillig_locations["0"]')" "$(commafy "$MAPPED")"
assert_true "…with the pc range in the same line, both ends" \
  str_has_sub "$(doc_row 'brillig_locations["0"]')" "[$(commafy "$PCMIN"), $(commafy "$PCMAX")]"
assert_true "§2.2's file count is stated in the file_map line" \
  str_has_sub "$(doc_row 'file_map               ')" "$FILES files"
# …and the stride census, in ITS own row, all four figures together. Stated as one row rather than
# four scattered numbers precisely because the figure it replaced was a loose phrase in prose.
assert_true "§2.2's stride census is stated in the row that names it" \
  str_has_sub "$(doc_row 'strides                ')" \
    "$(commafy "$SCOUNT") gaps, min $SMIN, max $SMAX, of which $(commafy "$SBAND") are in 4–9"
assert_true "§2.3's resolved count is in the row that names it" \
  str_has_sub "$(doc_row 'resolved to a `(path, line, column)`')" \
    "$(m25_arm 'd["rung1"]["resolvedCount"]')"
assert_true "§2.3's rung is in the row that names it" \
  str_has_sub "$(doc_row '| rung reached |')" "**$(m25_arm 'd["rung1"]["mappingRung"]')**"
assert_true "§2.3's interned-path count is in its own row" \
  str_has_sub "$(doc_row 'source paths interned')" "$(m25_arm 'd["rung1"]["pathsInterned"]')"
assert_true "§2.4's procedure-loc maximum is in the sentence that contrasts the two key spaces" \
  str_has_sub "$(doc_row "out at **$(commafy "$PROCMAX")**")" "**$(commafy "$PCMAX")**"

# The verdict itself, and the rung the runtime defaults to, as statements that can be wrong.
assert_true "the document records the verdict as rung 1 with no upstream change" \
  str_has_sub "$DOC_TEXT" 'rung 1, with no upstream change'
assert_true "…and records that no sixth upstream contribution is warranted for the question asked" \
  str_has_sub "$DOC_TEXT" 'No sixth upstream contribution is warranted for the question as asked'
assert_true "…and names the three residual holes as a CANDIDATE rather than a prepared one" \
  str_has_sub "$DOC_TEXT" 'candidate* sixth contribution rather than prepared'

# ===========================================================================
# PART 5 — the RUNTIME follows it, which is the half a document cannot assert about itself
# ===========================================================================
assert_eq "the rung-1 arm resolved every pc it drove" \
  "$(m25_arm 'd["rung1"]["pcsDriven"]')" "$(m25_arm 'd["rung1"]["resolvedCount"]')"
assert_ge "…and it drove enough of them for that to mean something" 100 \
  "$(m25_arm 'd["rung1"]["pcsDriven"]')"
assert_eq "…leaving nothing unresolved" "0" "$(m25_arm 'd["rung1"]["unresolvedCount"]')"
# NON-DEGENERACY. Every assertion above would pass over an arm that drove zero pcs and resolved
# zero, which is the `0 == 0` shape M23's review found passing a whole milestone.
assert_ge "the resolved positions are not degenerate: at least two DISTINCT lines were produced" 2 \
  "$(m25_arm 'len(set((p["pathId"], p["line"]) for p in d["rung1"]["firstResolved"]))')"
assert_eq "the source map placed no location in a file the file_map lacks" "0" \
  "$(m25_arm 'd["rung1"]["missingFileReferences"]')"
assert_eq "…and met no call-stack node whose shape it could not place" "0" \
  "$(m25_arm 'd["rung1"]["unrecognisedTreeNodes"]')"
assert_ge "more than one source path was interned, so the 86-file map is really being walked" 2 \
  "$(m25_arm 'd["rung1"]["pathsInterned"]')"

m24_finish
