#!/usr/bin/env bash
# M25 verification: every traced contract records which rung of the source-mapping ladder it
# achieved, and a contract WITHOUT source mapping is labelled rather than silently emitted as if it
# had one.
#
#   verification/test_trace_metadata_declares_mapping_rung.sh   (or: just verify-mapping-rung)
#
# ---------------------------------------------------------------------------
# TWO OBLIGATIONS, TWO KINDS OF EVIDENCE, AND NEITHER STANDS IN FOR THE OTHER.
#
#   STATES IT           — the rung is IN THE CONTAINER, read back by the reference reader as a
#                         TraceLogEvent with its metadata key, its address, its rung and its
#                         reason. A rung that lived in a host variable would be a claim ABOUT a
#                         recording rather than a property OF one, and a check that read the host
#                         variable would be unable to tell the difference.
#   NEVER DEGRADES      — a rung-1 declaration whose steps arrive without positions must THROW.
#                         Asserted as a throw that happens, with the SAME steps declared at rung 3
#                         closing cleanly as its control — otherwise the throw could be caused by
#                         anything about an unpositioned step.
#
# And the property that makes the whole thing measurable rather than assertable: the positioned and
# unpositioned counts come out of the MODULE, sum to the event count, and are asserted non-zero on
# the arm where each is expected. `0 == 0` over an arm that recorded nothing is the shape that
# passed a whole milestone in M23.
# ---------------------------------------------------------------------------

set -uo pipefail

TEST_NAME=test_trace_metadata_declares_mapping_rung
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m25_trace.sh"

m24_summary_on_abnormal_exit

m25_require_arms
m24_require_readers

# ===========================================================================
# PART 1 — the module's own source-mapping surface
# ===========================================================================
assert_eq "the step record is still 64 bytes, so M24's containers are still M24's" \
  "64" "$(m25_arm 'd["surface"]["recordSize"]')"
assert_eq "a position record is 16 bytes, read from the module and not restated by the host" \
  "16" "$(m25_arm 'd["surface"]["positionSize"]')"
assert_eq "M24's nineteen exports are untouched" "19" "$(m25_arm 'd["surface"]["requiredExports"]')"
assert_eq "M25 adds eleven, in their own list" "11" "$(m25_arm 'd["surface"]["sourceMappingExports"]')"
assert_eq "…and the union is exactly the two lists" "30" "$(m25_arm 'd["surface"]["allRequiredExports"]')"
assert_eq "every one of the thirty is present in the built module" "0" \
  "$(m25_arm 'len(d["surface"]["missingFromModule"])')"
# THE RESIDUE IS PRINTED, NOT COUNTED. A module export no list names is a finding — it is either a
# surface the host does not require or a list that has gone stale.
note "unlisted exports: $(m25_arm 'd["surface"]["unlistedExports"]')"
assert_eq "…and the module exports nothing the two lists do not name" "0" \
  "$(m25_arm 'len(d["surface"]["unlistedExports"])')"
assert_eq "the module's exported function count equals the union" \
  "$(m25_arm 'd["surface"]["allRequiredExports"]')" "$(m25_arm 'd["surface"]["exportedFunctions"]')"

# ===========================================================================
# PART 2 — THE RUNG IS IN THE CONTAINER
# ===========================================================================
for arm in rung1 rung3; do
  CT="$(m25_arm "d[\"$arm\"][\"container\"]")"
  assert_file "the $arm arm produced a container" "$CT"
  OUT="$(m24_ct_print "$M24_CTPRINT_WORK/ct-print" "$CT")"
  assert_eq "the reference reader reads the $arm container" "0" "$(printf '%s\n' "$OUT" | head -1)"
  BODY="$(printf '%s\n' "$OUT" | tail -n +2)"
  assert_true "the $arm container carries a TraceLogEvent under the ct.mapping-rung key" \
    str_has_sub "$BODY" '"metadata": "ct.mapping-rung"'
  # THE RUNG IN THE CONTAINER IS THE RUNG THE ARM DECLARED — compared, not just present. A check
  # that asserted only the key's presence would pass over a container that recorded rung 3 for a
  # rung-1 recording, which is the exact silent degradation this test is named for.
  WANT_RUNG="$(m25_arm "d[\"$arm\"][\"mappingRung\"]")"
  assert_true "…and it declares rung $WANT_RUNG, which is the rung this arm resolved to" \
    str_has_sub "$BODY" "rung=$WANT_RUNG reason="
  assert_true "…for the full 254-bit contract address, not a truncation of it" \
    str_has_sub "$BODY" "$(m25_arm 'd["fieldRendering"]["expectedHex"]') rung="
  assert_eq "…and exactly one contract was declared in it" "1" "$(m25_arm "d[\"$arm\"][\"rungsDeclared\"]")"
done
# THE TWO ARMS DECLARE DIFFERENT RUNGS, which is what makes the comparison above capable of
# failing: if both were rung 3, the assertion would hold for a runtime that could only say 3.
assert_eq "the rung-1 arm's container says 1" "1" "$(m25_arm 'd["rung1"]["mappingRung"]')"
assert_eq "the rung-3 arm's container says 3" "3" "$(m25_arm 'd["rung3"]["mappingRung"]')"
# …and the reason travels with it, because "rung 3 because no artifact was supplied" and "rung 3
# because the artifact has no debug symbols" are different facts about a deployment.
RUNG3_OUT="$(m24_ct_print "$M24_CTPRINT_WORK/ct-print" "$(m25_arm 'd["rung3"]["container"]')" | tail -n +2)"
assert_true "the rung-3 declaration carries the reason it degraded, not just the number" \
  str_has_sub "$RUNG3_OUT" 'reason=no artifact was supplied for this contract'

# ===========================================================================
# PART 3 — THE STEPS ARE WHAT THE RUNG SAYS THEY ARE
#
# The rung is a claim about where a step points. So the claim is checked against the steps: at
# rung 1 the first step's global position index must NOT be a program counter, and at rung 3 it
# must BE one. Reading the declaration alone would pass over a rung-1 recording full of pcs.
# ===========================================================================
R1_PROBE="$(m25_split_probe_of rung1)"
R3_PROBE="$(m25_split_probe_of rung3)"
assert_true "the split-stream reader opens the rung-1 container" \
  str_has_line "$R1_PROBE" "$(printf 'OPEN\tok')"
assert_true "…and the rung-3 container" str_has_line "$R3_PROBE" "$(printf 'OPEN\tok')"
assert_true "the rung-1 container is COLUMN-AWARE, which only a real source column earns" \
  str_has_line "$R1_PROBE" "$(printf 'COLUMN_AWARE\ttrue')"
assert_true "the rung-3 container is NOT, which is the control for that" \
  str_has_line "$R3_PROBE" "$(printf 'COLUMN_AWARE\tfalse')"
assert_true "the rung-3 container's first step addresses the PROGRAM COUNTER 706" \
  str_has_line "$R3_PROBE" "$(printf 'STEP0_GLI\t706')"
R1_GLI="$(printf '%s\n' "$R1_PROBE" | awk -F'\t' '$1=="STEP0_GLI"{print $2}')"
assert_ge "…while the rung-1 container's first step is a global position index, far above any pc" \
  100000 "$R1_GLI"
assert_true "…and it is not 706, which is what it would be if the position had been ignored" \
  test "$R1_GLI" -ne 706
assert_true "the rung-1 container interned more than one source path" \
  test "$(printf '%s\n' "$R1_PROBE" | awk -F'\t' '$1=="PATH_COUNT"{print $2}')" -gt 1
assert_eq "the rung-3 container interned exactly one, the session's own" "1" \
  "$(printf '%s\n' "$R3_PROBE" | awk -F'\t' '$1=="PATH_COUNT"{print $2}')"

# The tallies, out of the module, summing to the events.
R1_POS="$(m25_arm 'd["rung1"]["stepsPositioned"]')"
R1_UNPOS="$(m25_arm 'd["rung1"]["stepsUnpositioned"]')"
R1_EVENTS="$(m25_arm 'd["rung1"]["events"]')"
assert_ge "the rung-1 arm positioned a non-degenerate number of steps" 100 "$R1_POS"
assert_eq "…and left none unpositioned" "0" "$R1_UNPOS"
assert_eq "…and the two tallies sum to the event count" "$R1_EVENTS" "$((R1_POS + R1_UNPOS))"
R3_POS="$(m25_arm 'd["rung3"]["stepsPositioned"]')"
R3_UNPOS="$(m25_arm 'd["rung3"]["stepsUnpositioned"]')"
assert_eq "the rung-3 arm positioned nothing" "0" "$R3_POS"
assert_ge "…and its unpositioned count is non-zero, so the zero above is attributable" 1 "$R3_UNPOS"
assert_eq "…and its tallies sum to its event count too" \
  "$(m25_arm 'd["rung3"]["events"]')" "$((R3_POS + R3_UNPOS))"

# ===========================================================================
# PART 4 — NEVER SILENTLY DEGRADES, as a refusal that happens
# ===========================================================================
assert_eq "a rung-1 declaration with no positions THROWS at close" "MappingRungDegraded" \
  "$(m25_arm 'd["degraded"]["threw"]["name"]')"
assert_eq "…and it is the declared class, not something that happens to share a name" "true" \
  "$(m25_arm 'd["degraded"]["threw"]["isMappingRungDegraded"]')"
assert_eq "…so the container was NOT produced" "false" "$(m25_arm 'd["degraded"]["closedAnyway"]')"
assert_eq "…naming one violating contract" "1" "$(m25_arm 'd["degraded"]["threw"]["violations"]')"
assert_eq "…and the FIRST offending pc, so a diagnosis has somewhere to start" "706" \
  "$(m25_arm 'd["degraded"]["threw"]["firstViolationPc"]')"
assert_eq "…with the split that shows why: nothing positioned" "0" \
  "$(m25_arm 'd["degraded"]["threw"]["stepsPositioned"]')"
assert_eq "…and three steps not" "3" "$(m25_arm 'd["degraded"]["threw"]["stepsUnpositioned"]')"
assert_true "…and the message says what the container WOULD have looked like" \
  str_has_sub "$(m25_arm 'd["degraded"]["threw"]["message"]')" 'SILENT DEGRADATION'
# THE CONTROL. The same three steps, the same absence of positions, a rung-3 declaration.
assert_eq "the SAME unpositioned steps declared at rung 3 close cleanly" "0" \
  "$(m25_arm 'd["rung3"]["rungViolations"]')"
assert_ge "…having produced a container" 1 "$(m25_arm 'd["rung3"]["containerBytes"]')"
assert_eq "and the rung-1 arm, which supplied positions, reports no violation either" "0" \
  "$(m25_arm 'd["rung1"]["rungViolations"]')"

# The other direction: more positions than steps is refused too, and refused differently.
assert_eq "one extra position was accepted by the module" "1" "$(m25_arm 'd["desync"]["accepted"]')"
assert_true "…and the host refuses to close over it" \
  str_has_sub "$(m25_arm 'd["desync"]["threw"]["message"]')" 'that no step consumed'

# ===========================================================================
# PART 5 — the COLUMN gate is now a function of the rung, with a case per conjunct
# ===========================================================================
assert_eq "columns are accepted at rung 1" "false" "$(m25_arm 'd["columnGate"]["withColumns"]["rung1"]["threw"]')"
assert_eq "…and the resolved rung really is 1" "1" \
  "$(m25_arm 'd["columnGate"]["withColumns"]["rung1"]["resolvedRung"]')"
for bad in rung2 rung3 unset stringOne four; do
  assert_eq "columns are REFUSED at $bad" "true" \
    "$(m25_arm "d[\"columnGate\"][\"withColumns\"][\"$bad\"][\"threw\"]")"
  assert_eq "…with ColumnAwarenessUnavailable, the declared class" "true" \
    "$(m25_arm "d[\"columnGate\"][\"withColumns\"][\"$bad\"][\"isColumnAwarenessUnavailable\"]")"
done
# A rung smuggled past the erased type must fall to the PESSIMISTIC end, not be believed.
assert_eq "a rung arriving as the string \"1\" resolves to 3, not to 1" "3" \
  "$(m25_arm 'd["columnGate"]["withColumns"]["stringOne"]["rung"]')"
assert_eq "…and a rung of 4 does too" "3" "$(m25_arm 'd["columnGate"]["withColumns"]["four"]["rung"]')"
# THE CONJUNCT'S OWN NEGATIVE CASE: the same rungs with columns OFF must NOT throw, so the
# refusals above are attributable to the column request rather than to the rung on its own.
assert_eq "rung 3 without columns resolves fine" "3" \
  "$(m25_arm 'd["columnGate"]["withoutColumns"]["rung3"]["resolvedRung"]')"
assert_eq "…and rung 1 without columns resolves fine too" "1" \
  "$(m25_arm 'd["columnGate"]["withoutColumns"]["rung1"]["resolvedRung"]')"
assert_eq "…with columns off in both" "false" \
  "$(m25_arm 'd["columnGate"]["withoutColumns"]["rung1"]["columns"]')"
# …and the module CONFIRMS the request was honoured rather than dropped, at rung 1.
assert_eq "the rung-1 recording asked the module for columns" "true" \
  "$(m25_arm 'd["rung1"]["columnsRequested"]')"
assert_eq "…and the writer did not drop them" "false" \
  "$(m25_arm 'd["rung1"]["droppedColumnAwareness"]')"

# ===========================================================================
# PART 6 — the resolver's own units, on inputs whose answers are checkable by hand
# ===========================================================================
assert_eq "line lengths are characters + 1, so the position past a line's end is addressable" \
  "[11, 13, 1, 15, 1]" "$(m25_arm 'd["unit"]["lineLengths"]')"
assert_eq "byte offset 0 is line 1 column 1" "{'line': 1, 'column': 1}" "$(m25_arm 'd["unit"]["at0"]')"
assert_eq "byte offset 4 is line 1 column 5" "{'line': 1, 'column': 5}" "$(m25_arm 'd["unit"]["at4"]')"
assert_eq "byte offset 11 is the start of line 2" "{'line': 2, 'column': 1}" "$(m25_arm 'd["unit"]["at11"]')"
assert_eq "a span past the end is CLAMPED rather than throwing away the recording" \
  "$(m25_arm 'd["unit"]["atEnd"]')" "$(m25_arm 'd["unit"]["pastEnd"]')"
# THE BYTE-VERSUS-UTF16 DIFFERENCE IS MEASURED, NOT DESCRIBED. Noir's span is a byte offset and a
# JS string is UTF-16; upstream's own resolver uses `substring` and answers differently.
assert_eq "a byte offset into non-ASCII source resolves by BYTES: column 2 after a two-byte é" \
  "{'line': 1, 'column': 2}" "$(m25_arm 'd["unit"]["utf8"]')"
assert_eq "…where a UTF-16 index would answer 3, which is the difference this avoids" \
  "3" "$(m25_arm 'd["unit"]["utf8NaiveUtf16Column"]')"
assert_eq "an unrecognised call-stack tree is REPORTED, not treated as no locations" \
  "unrecognised-tree" "$(m25_arm 'd["unit"]["treeUnrecognised"]')"
assert_eq "…while an absent one is genuinely empty" "[]" "$(m25_arm 'd["unit"]["treeEmpty"]')"
assert_eq "…and an id past the end of the arena is empty too" "[]" \
  "$(m25_arm 'd["unit"]["treeOutOfRange"]')"
assert_eq "a parent chain is walked, outermost first, so an inlined frame is not lost" "2" \
  "$(m25_arm 'len(d["unit"]["treeChain"])')"
assert_eq "…with the INNERMOST location last, which is where a stepper stops" "8" \
  "$(m25_arm 'd["unit"]["treeChain"][-1]["file"]')"
assert_eq "…and the outermost first" "7" "$(m25_arm 'd["unit"]["treeChain"][0]["file"]')"

m24_finish
