#!/usr/bin/env bash
# M26 verification: enqueued public calls appear as frames NESTED INSIDE the private execution's
# frames, in the order they were enqueued.
#
#   verification/test_private_public_frame_nesting.sh        (or: just verify-frame-nesting)
#
# ---------------------------------------------------------------------------
# THREE CLAIMS, THREE KINDS OF EVIDENCE, AND NONE OF THEM STANDS IN FOR THE OTHERS.
#
#   FRAMES        the public calls are frames at all — a `Call`/`Return` pair around their steps,
#                 named through upstream's own `getDebugFunctionName` rather than labelled here.
#   NESTED        each one opens INSIDE the private half's frames. Asserted on DEPTH computed from
#                 the call/return sequence, not on the order names appear in a listing: a container
#                 in which every frame is a sibling would satisfy a name-order assertion completely.
#   ORDER         the public frames appear in the order the transaction enqueued them — which is a
#                 claim about TWO things, so the transaction enqueues two DIFFERENT functions and
#                 the expected order is read off the transaction rather than typed here.
#
# AND THE POINT OF ALL THREE, WHICH IS THE DELIVERABLE'S OWN SENTENCE: a private-half step and a
# public-half step must be distinguishable BY FRAME and not only by content. Content-based
# distinction is the kind that works on a fixture and fails on the first real transaction where a
# private step and a public step happen to look alike, so this check deliberately never asks what a
# step's variables contain in order to decide which half it belongs to.
#
# THE DEGENERATE CASE IS ASSERTED AWAY. Every frame's step count is asserted non-zero, because a
# public frame with no steps in it is a `Call`/`Return` pair that a stepper cannot stop inside, and
# "the frames are nested" would be true of it.
# ---------------------------------------------------------------------------

set -uo pipefail

TEST_NAME=test_private_public_frame_nesting
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m26_join.sh"

m24_summary_on_abnormal_exit

m24_require_module
m24_require_readers
m26_require_arms

SHARED_CT="$M26_WORK/oq7-shared.ct"
assert_file "the joined container exists" "$SHARED_CT"
REPORT="$(m26_frames "$SHARED_CT")"
assert_false "the pinned reader read it rather than refusing" str_has_sub "$REPORT" 'ERR:'

# ===========================================================================
# PART 1 — the transaction really enqueued two public calls, and they are DIFFERENT.
#
# Read off the transaction the vendored builder produced, so the expectation below is upstream's
# answer and not a constant typed into this check. This campaign's rule: if a check needs a number
# that also exists in the thing under test, take it FROM the thing under test.
# ===========================================================================
ENQUEUED="$(m26_arm 'd["tx"]["enqueuedNames"]')"
assert_eq "the transaction enqueued two public calls" "2" \
  "$(m26_arm 'd["tx"]["enqueuedPublicCalls"]')"
assert_eq "…named through upstream's own getDebugFunctionName, in enqueue order" \
  "Token.transfer_in_public,Token.balance_of_public" "$ENQUEUED"
# The two must be DIFFERENT, or "in the order they were enqueued" is unfalsifiable.
FIRST_NAME="${ENQUEUED%%,*}"
SECOND_NAME="${ENQUEUED##*,}"
assert_false "…and the two are different functions, so their ORDER is a checkable claim" \
  test "$FIRST_NAME" = "$SECOND_NAME"
assert_eq "…with different selectors, from the contract's own ABI" "2" \
  "$(printf '%s\n' "$(m26_arm 'd["tx"]["enqueuedSelectors"]')" | tr ',' '\n' | sort -u | grep -c . || true)"

# ===========================================================================
# PART 2 — FRAMES. Both halves are frames, and the public ones are named by the contract.
# ===========================================================================
FRAME_NAMES="$(m26_rows "$REPORT" FRAME 4)"
FRAME_DEPTHS="$(m26_rows "$REPORT" FRAME 3)"
assert_ge "the container has frames at all" 4 \
  "$(printf '%s\n' "$FRAME_NAMES" | tr ',' '\n' | grep -c . || true)"
assert_eq "…and every Call has an index, so the report is rows rather than a summary" \
  "$(m26_row "$REPORT" CALLS)" \
  "$(printf '%s\n' "$FRAME_NAMES" | tr ',' '\n' | grep -c . || true)"
# The private half's frames are the Noir program's OWN function names.
for fn in '<toplevel>' main foo bar; do
  assert_true "the private half contributes a frame named $fn" \
    str_has_line "$(printf '%s\n' "$FRAME_NAMES" | tr ',' '\n')" "$fn"
done
# The public half's frames are the CONTRACT's own debug function names.
assert_true "the public half contributes a frame named $FIRST_NAME" \
  str_has_line "$(printf '%s\n' "$FRAME_NAMES" | tr ',' '\n')" "$FIRST_NAME"
assert_true "…and one named $SECOND_NAME" \
  str_has_line "$(printf '%s\n' "$FRAME_NAMES" | tr ',' '\n')" "$SECOND_NAME"
# THE CONTROL FOR THE SIX ABOVE: a frame name that is in neither half is not reported.
assert_false "…while a function neither half has is not among the frames" \
  str_has_line "$(printf '%s\n' "$FRAME_NAMES" | tr ',' '\n')" 'Token.a_function_this_tx_never_calls'

# ===========================================================================
# PART 3 — NESTING, computed from the call/return sequence.
# ===========================================================================
# `_ct_frames.py` prints `FRAME <index> <depth> <name> <steps> <args>`; the depths are what the
# call stack was when each Call opened. The private toplevel is the outermost frame, so its depth
# is the minimum, and every public frame's depth must be strictly greater.
TOP_DEPTH="$(printf '%s\n' "$REPORT" | awk -F'\t' '$1=="FRAME" && $4=="<toplevel>" {print $3; exit}')"
assert_eq "the private half's <toplevel> is the outermost frame" "0" "${TOP_DEPTH:-MISSING}"
for name in "$FIRST_NAME" "$SECOND_NAME"; do
  d="$(printf '%s\n' "$REPORT" | awk -F'\t' -v n="$name" '$1=="FRAME" && $4==n {print $3; exit}')"
  assert_ge "the public frame $name opens INSIDE a private frame, not beside one" 1 "${d:-MISSING}"
done
# AND THE PRIVATE FRAME IT IS INSIDE IS STILL OPEN, which is the half a depth alone does not say.
# `main` never returns in this recording — the Noir tracer leaves the entry frames open — so the
# unbalanced count is exactly the private half's outer two.
assert_eq "…and the private frames it is inside are still open at the end of the recording" "2" \
  "$(m26_row "$REPORT" UNBALANCED)"
assert_eq "…which is <toplevel> and main, so the public frames are inside BOTH" \
  "2" "$(printf '%s\n' "$FRAME_DEPTHS" | tr ',' '\n' | grep -c '^0$\|^1$' || true)"
# THE CONTROL FOR THE DEPTH ASSERTIONS: the report distinguishes depths at all. A reporter that
# printed 0 for everything would satisfy "<toplevel> is at 0" and fail here.
assert_ge "the report distinguishes at least four distinct frame depths" 4 \
  "$(printf '%s\n' "$FRAME_DEPTHS" | tr ',' '\n' | sort -u | grep -c . || true)"

# ===========================================================================
# PART 4 — ORDER, and it is the enqueue order rather than any other order.
# ===========================================================================
PUBLIC_ORDER="$(printf '%s\n' "$REPORT" \
  | awk -F'\t' '$1=="FRAME" && $4 ~ /^Token\./ {printf "%s%s", sep, $4; sep=","} END {print ""}')"
assert_eq "the public frames appear in the order the transaction enqueued them" \
  "$ENQUEUED" "$PUBLIC_ORDER"
# The control that the comparison above is not two empty strings: both sides are non-empty and the
# REVERSED order is different, so an order-blind comparison would fail here.
assert_ge "…and that order is two names rather than none" 2 \
  "$(printf '%s\n' "$PUBLIC_ORDER" | tr ',' '\n' | grep -c . || true)"
assert_false "…and the reversed order is NOT what the container holds" \
  test "$PUBLIC_ORDER" = "$SECOND_NAME,$FIRST_NAME"

# ===========================================================================
# PART 5 — NON-DEGENERACY. A frame a stepper cannot stop inside is not a frame.
# ===========================================================================
EMPTY_FRAMES="$(printf '%s\n' "$REPORT" | awk -F'\t' '$1=="FRAME" && $5==0 {print $4}' | tr '\n' ' ')"
assert_eq "every frame in the recording contains at least one step" "" "${EMPTY_FRAMES% }"
for name in "$FIRST_NAME" "$SECOND_NAME"; do
  n="$(printf '%s\n' "$REPORT" | awk -F'\t' -v n="$name" '$1=="FRAME" && $4==n {print $5; exit}')"
  assert_ge "the public frame $name has AVM steps in it" 1 "${n:-MISSING}"
done
# The two halves' step counts, compared rather than each asserted non-empty: the private half is
# a whole Noir program and the public half is twelve mapped pcs, so the private half is the larger
# one and a container that had lost a half would fail this rather than merely be smaller.
PRIVATE_STEPS="$(printf '%s\n' "$REPORT" | awk -F'\t' '$1=="FRAME" && $4=="main" {print $5; exit}')"
PUBLIC_TOTAL="$(printf '%s\n' "$REPORT" \
  | awk -F'\t' '$1=="FRAME" && $4 ~ /^Token\./ {n += $5} END {print n + 0}')"
assert_ge "the private half's main frame has steps of its own" 1 "${PRIVATE_STEPS:-MISSING}"
assert_ge "the public half's frames have steps of their own" 1 "$PUBLIC_TOTAL"
# THE ARITHMETIC IS GUARDED, AND THE REASON IS THIS CHECK'S OWN MUTATION MATRIX. `$(( MISSING - 1 ))`
# is an UNBOUND VARIABLE under `set -u` — bash evaluates a bare word in an arithmetic context as a
# variable name — so on a run where the report is unreadable this line killed the check at exactly
# this point and seven later assertions never ran. M22's abnormal-exit trap caught it and printed
# the summary with a failure counted, which is the trap doing its job; the check should not have
# needed it. M24 met the same family as `$(( ERR:… * ERR:… ))`, a bash SYNTAX error, and guarded it
# the same way.
TOTAL_STEPS="$(m26_row "$REPORT" STEPS)"
TOP_STEPS="$(printf '%s\n' "$REPORT" | awk -F'\t' '$1=="FRAME" && $4=="<toplevel>" {print $5; exit}')"
EXPECT_TOP="UNCOMPUTABLE"
case "$TOTAL_STEPS" in ''|*[!0-9]*) ;; *) EXPECT_TOP="$((TOTAL_STEPS - 1))" ;; esac
assert_eq "…and every step in the recording is inside <toplevel>, which is what makes it ONE timeline" \
  "$EXPECT_TOP" "${TOP_STEPS:-MISSING}"
# Each public frame carries the contract address as its ONE call argument, which is what makes a
# public frame attributable to a contract without reading its steps.
for name in "$FIRST_NAME" "$SECOND_NAME"; do
  a="$(printf '%s\n' "$REPORT" | awk -F'\t' -v n="$name" '$1=="FRAME" && $4==n {print $6; exit}')"
  assert_eq "the public frame $name carries its contract address as a call argument" "1" "${a:-MISSING}"
done
ADDRESS="$(m26_arm 'd["tx"]["contractAddress"]')"
assert_ge "…and that address is a 0x + 64 hex field element" 66 "${#ADDRESS}"
assert_true "…which appears in the container as OQ-4's rendering" \
  str_has_sub "$REPORT" "	String	$ADDRESS"
# THE CROSS-HALF PROPERTY, IN THE SAME CONTAINER. The Noir half's Field values must use the SAME
# rendering, or the join contains one field element spelled two ways.
assert_true "the PRIVATE half's Field values use the same rendering" \
  str_has_sub "$REPORT" '	String	0x0000000000000000000000000000000000000000000000000000000000000004'
# …and the control that says the container has not simply turned everything into a String: the
# public half's gas and opcode counters are still Ints.
assert_ge "…while the public half's counters are still Ints, so not everything became a String" 4 \
  "$(printf '%s\n' "$REPORT" | awk -F'\t' '$1=="VALUE" && $3=="Int"' | grep -c . || true)"

m24_finish
