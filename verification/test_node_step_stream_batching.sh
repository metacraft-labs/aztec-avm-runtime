#!/usr/bin/env bash
# test_node_step_stream_batching — M17.
#
# THE THIRD DELIVERABLE, WHICH THE MILESTONE'S VERIFICATION LIST DID NOT COVER. "Batched step-stream
# decoding on the host side, matching M12's export" is a deliverable with no entry of its own, and a
# deliverable without a check is worse than one with a weak one. This check is the entry; it is
# recorded as an addition in M17's Implementation Details rather than folded into a neighbour.
#
# WHAT IS BEING CHECKED IS THE HOST'S DECODING, NOT THE MODULE'S EXPORT. M12 already measured the
# export — `ceil(38903 / B)` crossings at four batch sizes, per-record agreement with the native
# driver, the clamped window at the far end of the uint32 range. What is new is that a TypeScript
# consumer gets the same records by both routes and can tell that it did:
#
#   * `TxSimulationResult.execution_steps`, which already carries the WHOLE stream after ONE
#     crossing and zero further ones — upstream's own field, and the strongest form of "one call per
#     batch";
#   * `avm_steps_batch(from, count)`, for the host that would rather stream into a trace writer as
#     it goes (M24, M25).
#
# The two are compared PER RECORD on every field, not by count, because this campaign has more than
# once had a count agree while the thing being counted did not.
#
# Run: just verify-node-steps

TEST_NAME="test_node_step_stream_batching"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m17_node_host.sh"

m17_measured

# ---------------------------------------------------------------------------
echo "== 1. the run"
# ---------------------------------------------------------------------------
m17_run steps "$(m17_out steps)" "$(m17_err steps)" "$M17_STEP_PROGRAM" "$M17_STEP_BATCH"
RC=$?
assert_eq "the steps mode exits 0" 0 "$RC"
assert_eq "…and its transcript is complete rather than truncated" \
  "complete" "$(m17_completeness "$(m17_out steps)" steps)"
T="$(m17_out steps)"
f() { m17_field "$T" "$1"; }

assert_eq "it ran the program M9 measured the stream on" "$M17_STEP_PROGRAM" "$(f steps.program)"
assert_eq "…at the batch size asked for" "$M17_STEP_BATCH" "$(f steps.batchSize)"

# ---------------------------------------------------------------------------
echo "== 2. the count is M9's, and it is the same by both routes"
# ---------------------------------------------------------------------------
# The identity is M9's, quoted through M12 rather than re-derived here.
assert_eq "the module reports the recorded number of records" "$M17_STEP_COUNT" "$(f steps.count)"
assert_eq "…and upstream's own result field carries the same number" \
  "$M17_STEP_COUNT" "$(f steps.inResultCount)"
assert_eq "…and draining the stream produces that many" "$M17_STEP_COUNT" "$(f steps.drained)"
assert_ge "the stream is large enough for batching to mean anything" 1000 "$(f steps.count)"

# ---------------------------------------------------------------------------
echo "== 3. the crossings are exactly ceil(count / batch)"
# ---------------------------------------------------------------------------
WANT_CROSSINGS=$(( ($(f steps.count) + M17_STEP_BATCH - 1) / M17_STEP_BATCH ))
assert_eq "the host's own arithmetic agrees with ceil(count / batch)" \
  "$WANT_CROSSINGS" "$(f steps.expectedCrossings)"
assert_eq "…and that is what the drain cost" "$WANT_CROSSINGS" "$(f steps.crossings)"
# The whole stream inside the result costs ZERO further crossings, which is the point of preferring
# it. MEASURED off the boundary's own call counter as a difference of two readings taken around
# `stepsFromOutcome`, not printed as a constant — the probe used to emit a literal zero here, which
# made this an assertion nothing could falsify.
assert_eq "the stream that arrives inside the result costs no further crossings" \
  "0" "$(f steps.crossingsForWholeStreamInResult)"
# …and the SAME counter over the route that DOES cross, so the zero above is a measurement rather
# than a counter stuck at zero.
assert_eq "the same counter charges the batched drain for every one of its crossings" \
  "$(f steps.crossings)" "$(f steps.moduleCallsDuringDrain)"
assert_true "…and that is more than none, so the counter moves" \
  test "$(f steps.moduleCallsDuringDrain)" -gt 0
assert_true "…which is strictly fewer than draining it, so the two routes really do differ" \
  test "$(f steps.crossings)" -gt "$(f steps.crossingsForWholeStreamInResult)"

# ---------------------------------------------------------------------------
echo "== 4. the same RECORDS, field for field, not the same count"
# ---------------------------------------------------------------------------
assert_eq "every record from the batched drain equals the one inside the result" \
  "0" "$(f steps.resultVersusBatchedDifferences)"
# A comparison of two absent streams would also report zero differences, so both are shown present.
assert_true "…and both streams were actually present to compare" \
  test "$(f steps.inResultCount)" -gt 0
assert_eq "…with the same number of records on each side" \
  "$(f steps.inResultCount)" "$(f steps.drained)"

# The first and last record carry every field, so a formatter that dropped one could not agree.
FIELDS='^ctx=[0-9]+ pc=[0-9]+ op=[0-9]+ l2=[0-9]+ da=[0-9]+ addr=0x[0-9a-f]{64}$'
assert_matches() { # <description> <extended-regex> <value>
  if printf '%s' "$3" | grep -qE "$2"; then pass "$1  [$3]"; else fail "$1  [$3] does not match $2"; fi
}
assert_matches "the first record carries every field" "$FIELDS" "$(f steps.first)"
assert_matches "…and so does the last" "$FIELDS" "$(f steps.last)"
assert_true "…and they are different records, so the stream is not one value repeated" \
  test "$(f steps.first)" != "$(f steps.last)"

# ---------------------------------------------------------------------------
echo "== 5. nothing leaked draining 38,903 records"
# ---------------------------------------------------------------------------
assert_eq "the host owns no linear-memory allocation when the drain ends" \
  "0" "$(f steps.ownedAllocationsAtExit)"

# ---------------------------------------------------------------------------
echo "== 6. the host does not re-clamp the window the module clamps"
# ---------------------------------------------------------------------------
# M12 established WHY the module clamps by subtraction: size_t is 32 bits on wasm32, so `from +
# count` wraps and a wrapped end below the beginning would construct a vector from a reversed range
# — undefined behaviour reachable straight from the boundary, and not catchable by `guarded()`
# because it is not an exception. A host that clamped it again would stop exercising that.
# Whitespace-collapsed, because these needles are sentences in a wrapped comment and a needle that
# happened to span two lines would fail for a reason that has nothing to do with what it asserts.
STEPS_TS="$(sed 's|^//||' "$M17_PKG/src/steps.ts" | tr '\n' ' ' | tr -s ' ')"
assert_contains "the host records why the module owns the clamping" \
  "CLAMPED BY THE MODULE, BY SUBTRACTION" "$STEPS_TS"
assert_contains "…and passes the caller's numbers through unchanged" \
  "passes the caller's numbers through unchanged" "$STEPS_TS"
# A batch of zero would loop for ever and the module cannot say so, because a zero-length window is
# a legitimate answer to a query past the end. The host refuses it.
assert_contains "a batch size of zero is refused by the host" \
  "batch must be a positive integer" "$STEPS_TS"

finish
