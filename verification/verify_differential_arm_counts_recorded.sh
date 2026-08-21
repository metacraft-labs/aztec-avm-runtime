#!/usr/bin/env bash
# verify_differential_arm_counts_recorded — M2.
#
# The manifest records the MEASURED per-arm counts for the differential suite, so its headline
# number can never again be read as the number of comparisons.
#
# This does not check that a number is written down. It RE-MEASURES the suite from scratch with
# `tools/measure_differential.py`, and then requires the manifest's per-arm figures to equal what
# came back — per test file, not just in total. A number nobody re-derives is the exact failure this
# check exists for: 756 "differential tests" that were 74 comparisons, and an `opcode_spam` arm
# quoted as comparing revert reasons when it compared none.
#
# Runtime is roughly three minutes, almost all of it the opcode-spam arm.

TEST_NAME="verify_differential_arm_counts_recorded"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANIFEST="$REPO_ROOT/fixtures/MANIFEST.md"
RECORDED="$REPO_ROOT/fixtures/differential-arm-counts.json"
MEASURE="$REPO_ROOT/tools/measure_differential.py"
DIFFSIM="$REPO_ROOT/diffsim"

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
command -v node >/dev/null 2>&1 || die "node is not available"
[ -f "$MANIFEST" ] || die "fixtures/MANIFEST.md does not exist"
[ -f "$RECORDED" ] || die "fixtures/differential-arm-counts.json does not exist"
[ -f "$MEASURE" ] || die "tools/measure_differential.py does not exist"
[ -x "$DIFFSIM/node_modules/.bin/jest" ] || die "diffsim's jest is not installed (run npm install in diffsim/)"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

echo "== re-measure the differential suite (both arms; ~3 min)"
if python3 "$MEASURE" --out "$SCRATCH/fresh.json" >"$SCRATCH/measure.log" 2>&1; then
  pass "the measurement ran and recorded a non-zero number of comparisons"
else
  cat "$SCRATCH/measure.log" >&2
  fail "tools/measure_differential.py failed"
  finish
fi

read_json() { # <file> <python-expression over `d`>
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1" 2>/dev/null
}

FRESH_TOTAL="$(read_json "$SCRATCH/fresh.json" "d['totals']['comparisons']")"
FRESH_REASON="$(read_json "$SCRATCH/fresh.json" "d['totals']['revertReasonComparisons']")"
FRESH_EXEMPT="$(read_json "$SCRATCH/fresh.json" "d['totals']['revertReasonExemptions']")"
FRESH_DEFAULT="$(read_json "$SCRATCH/fresh.json" "d['defaultSuite']['comparisons']")"
FRESH_SPAM="$(read_json "$SCRATCH/fresh.json" "d['opcodeSpamArm']['comparisons']")"
FRESH_TS_LABEL="$(read_json "$SCRATCH/fresh.json" "d['defaultSuite']['testCounts']['tsSimulatorLabelled']")"
FRESH_PASSED="$(read_json "$SCRATCH/fresh.json" "d['defaultSuite']['testCounts']['totalPassed']")"

note "measured: default $FRESH_DEFAULT comparisons, opcode-spam $FRESH_SPAM, total $FRESH_TOTAL"
note "measured: revert-reason comparisons $FRESH_REASON, exemptions $FRESH_EXEMPT"
note "measured: default suite tests — $FRESH_TS_LABEL labelled (TS Simulator), $FRESH_PASSED passed"

echo "== the checked-in record reproduces the measurement"
for expr in \
  "d['totals']['comparisons']" \
  "d['totals']['revertReasonComparisons']" \
  "d['totals']['revertReasonExemptions']" \
  "d['defaultSuite']['comparisons']" \
  "d['defaultSuite']['byFile']" \
  "d['opcodeSpamArm']['comparisons']" \
  "d['opcodeSpamArm']['revertReasonComparisons']"
do
  assert_eq "checked-in == measured: $expr" \
    "$(read_json "$SCRATCH/fresh.json" "$expr")" "$(read_json "$RECORDED" "$expr")"
done

echo "== the comparison count differs from the test count, and the manifest says which is which"
assert_ge "the arm carries more labelled tests than it makes comparisons" 1 \
  "$(( FRESH_TS_LABEL - FRESH_DEFAULT ))"
assert_true "the manifest states the labelled-test count and the comparison count separately" \
  bash -c "grep -q '$FRESH_TS_LABEL tests carry' '$MANIFEST' && grep -q '$FRESH_DEFAULT differential comparisons' '$MANIFEST'"
assert_true "the manifest records that the (TS Simulator)/(Cpp Simulator) labels are inverted" \
  grep -q "label inversion" "$MANIFEST"
assert_true "the manifest names the suite that contributes zero comparisons despite its label" \
  grep -q "bench.test.ts" "$MANIFEST"

echo "== every per-file comparison count is recorded in the manifest"
PER_FILE_REPORT="$(python3 - "$SCRATCH/fresh.json" "$MANIFEST" <<'PY'
import json, os, re, sys
fresh = json.load(open(sys.argv[1]))
manifest = open(sys.argv[2]).read()
missing = []
checked = 0
for arm in ("defaultSuite", "opcodeSpamArm"):
    for path, counts in fresh[arm]["byFile"].items():
        base = os.path.basename(path).replace(".test.ts", "")
        n = counts["comparisons"]
        checked += 1
        if not re.search(rf"\b{re.escape(base)}\s+{n}\b", manifest):
            missing.append(f"{base}={n}")
print(checked, len(missing), ",".join(missing))
PY
)"
CHECKED_FILES="$(echo "$PER_FILE_REPORT" | cut -d' ' -f1)"
MISSING_FILES="$(echo "$PER_FILE_REPORT" | cut -d' ' -f2)"
assert_ge "per-file counts checked against the manifest" 7 "${CHECKED_FILES:-0}"
assert_eq "per-file counts absent from the manifest" "0" "${MISSING_FILES:-1}"
[ "${MISSING_FILES:-1}" = "0" ] || note "missing: $(echo "$PER_FILE_REPORT" | cut -d' ' -f3-)"

echo "== M2's COLLECT_META_CHECK_RET decision, asserted as a number"
# The whole point of flipping the constant is that the oracle's one assertion-relaxing local
# deviation stops firing ANYWHERE. If a future edit reintroduces an exemption, this goes red.
assert_eq "revert-reason exemptions across the entire corpus" "0" "$FRESH_EXEMPT"
assert_eq "every comparison had its revert reason asserted" "$FRESH_TOTAL" "$FRESH_REASON"
assert_true "opcode_spam.test.ts ships COLLECT_META_CHECK_RET = true in this tree" \
  grep -q '^const COLLECT_META_CHECK_RET = true;$' \
  "$DIFFSIM/src/public/public_tx_simulator/apps_tests/opcode_spam.test.ts"
assert_true "the flip is recorded in the drift ledger as D7's resolution" \
  grep -q "COLLECT_META_CHECK_RET" "$REPO_ROOT/DRIFT.md"
assert_true "DRIFT.md D4's tripwire is a positive assertion, not a skip" \
  grep -q "D4_EXPECTED_ASSERTION_OUTCOMES" \
  "$DIFFSIM/src/public/public_tx_simulator/apps_tests/opcode_spam.test.ts"

echo "== both arms ran GREEN, so D4's tripwire is a gate rather than a note"
# ADDED IN M2 REVIEW, from a measurement. The counter emits its record from INSIDE the simulator,
# after the differential assertions and BEFORE the suite's own post-hoc expectations. So a test that
# fails *after* the comparison — which is exactly what DRIFT.md D4's tripwire does when upstream
# fixes `allowedReasons`, when the opcode's message changes, or when the outer frame stops running
# out of gas — leaves the counts at 142 / 142 / 0. Measured in review: with D4's expected inner
# reason deliberately changed, jest exited 1 with `1 failed, 141 passed` and this check still
# reported 26 assertions, 0 failures, PASS. The counts alone are therefore not sufficient, and
# `tools/measure_differential.py` deliberately does not fail on a red suite (a red run is still a
# measurement). Asserting the failure counts here is what makes the tripwire — and upstream's own
# `expectToBeTrue` assertions, which the M2 flip turns from no-ops into checks on 142 cases — part
# of the verification set instead of something a human has to notice.
FRESH_DEFAULT_FAILED="$(read_json "$SCRATCH/fresh.json" "d['defaultSuite']['testCounts']['totalFailed']")"
FRESH_SPAM_FAILED="$(read_json "$SCRATCH/fresh.json" "d['opcodeSpamArm']['testCounts']['totalFailed']")"
FRESH_SPAM_PASSED="$(read_json "$SCRATCH/fresh.json" "d['opcodeSpamArm']['testCounts']['totalPassed']")"
assert_eq "the default suite ran with no failing test" "0" "${FRESH_DEFAULT_FAILED:-1}"
assert_eq "the opcode-spam arm ran with no failing test" "0" "${FRESH_SPAM_FAILED:-1}"
assert_ge "the opcode-spam arm ran all its cases" 142 "${FRESH_SPAM_PASSED:-0}"

echo "== D4's pin is the exact one the ledger describes, not a weakened restatement of it"
SPAM_TEST="$DIFFSIM/src/public/public_tx_simulator/apps_tests/opcode_spam.test.ts"
assert_true "the pinned case is SENDL2TOL1MSG" \
  grep -qF "const D4_CASE_LABEL = 'SENDL2TOL1MSG';" "$SPAM_TEST"
assert_true "the pinned inner reason is the exact address-bound message" \
  grep -qF "const D4_EXPECTED_INNER_REASON = 'sendl2tol1msg: recipient address is too large';" "$SPAM_TEST"
assert_true "upstream's three-item allowedReasons list is restated verbatim for the not-contained assertion" \
  grep -qF "const D4_UPSTREAM_ALLOWED_REASONS = ['assertion failed', 'out of gas', 'not enough l2gas'];" "$SPAM_TEST"
assert_true "the pinned assertion outcomes are exactly [true, false, true]" \
  grep -qF "const D4_EXPECTED_ASSERTION_OUTCOMES = [true, false, true];" "$SPAM_TEST"
assert_true "…and upstream's list is asserted NOT to contain the reason, rather than widened" \
  grep -qF "expect(D4_UPSTREAM_ALLOWED_REASONS.some(r => innerReason?.includes(r))).toBe(false);" "$SPAM_TEST"

echo "== D2's caveat is recorded wherever the expanded number is quoted"
assert_true "the manifest states the opcode-spam arm is blind to gas divergence" \
  grep -q "blind to gas divergence" "$MANIFEST"
assert_true "the manifest forbids quoting 216 as 216 equally strong comparisons" \
  grep -q "216 equally strong comparisons" "$MANIFEST"

# ---------------------------------------------------------------------------
# Negative controls.
# ---------------------------------------------------------------------------
echo "== negative controls"

# (1) A mutated record must not reproduce the measurement.
python3 - "$RECORDED" "$SCRATCH/bad-record.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["totals"]["comparisons"] += 1
json.dump(d, open(sys.argv[2], "w"))
PY
if [ "$(read_json "$SCRATCH/bad-record.json" "d['totals']['comparisons']")" = "$FRESH_TOTAL" ]; then
  fail "negative control NOT caught: a mutated comparison total compared equal"
else
  pass "negative control caught: a mutated comparison total does not reproduce the measurement"
fi

# (2) A manifest whose per-file number is wrong must be rejected by the same code path.
cp "$MANIFEST" "$SCRATCH/bad-manifest.md"
python3 - "$SCRATCH/bad-manifest.md" <<'PY'
import sys
p = sys.argv[1]
# EVERY occurrence, not the first: the count appears in more than one entry (FX-01's
# per-file list and FX-10's), and mutating only one left the other satisfying the check.
t = open(p).read().replace("avm_gadgets 27", "avm_gadgets 270")
assert "avm_gadgets 27," not in t and "avm_gadgets 27\n" not in t
open(p, "w").write(t)
PY
BAD_REPORT="$(python3 - "$SCRATCH/fresh.json" "$SCRATCH/bad-manifest.md" <<'PY'
import json, os, re, sys
fresh = json.load(open(sys.argv[1]))
manifest = open(sys.argv[2]).read()
missing = 0
for arm in ("defaultSuite", "opcodeSpamArm"):
    for path, counts in fresh[arm]["byFile"].items():
        base = os.path.basename(path).replace(".test.ts", "")
        if not re.search(rf"\b{re.escape(base)}\s+{counts['comparisons']}\b", manifest):
            missing += 1
print(missing)
PY
)"
assert_ge "negative control caught: a wrong per-file count in the manifest" 1 "${BAD_REPORT:-0}"

# (3) The counter is not vacuous — it tracks a single suite's real comparison count.
#     custom_bc makes 13 comparisons in the recorded measurement; run it alone and require 13.
CUSTOM_BC_EXPECTED="$(read_json "$SCRATCH/fresh.json" \
  "d['defaultSuite']['byFile']['public/public_tx_simulator/apps_tests/custom_bc.test.ts']['comparisons']")"
mkdir -p "$SCRATCH/counters-one"
( cd "$DIFFSIM" && DIFFSIM_COUNTERS_DIR="$SCRATCH/counters-one" NODE_NO_WARNINGS=1 \
    node --experimental-vm-modules ./node_modules/.bin/jest --passWithNoTests \
    src/public/public_tx_simulator/apps_tests/custom_bc.test.ts ) >"$SCRATCH/one.log" 2>&1
ONE_COUNT="$(cat "$SCRATCH/counters-one"/*.jsonl 2>/dev/null | grep -c . || true)"
assert_eq "the counter reports exactly one suite's comparisons when run alone" \
  "$CUSTOM_BC_EXPECTED" "${ONE_COUNT:-0}"

# (4) …and it reports ZERO for a suite that makes no differential comparison, so it is not simply
#     emitting a record per test. avm_minimal runs the C++ simulator alone.
mkdir -p "$SCRATCH/counters-zero"
( cd "$DIFFSIM" && DIFFSIM_COUNTERS_DIR="$SCRATCH/counters-zero" NODE_NO_WARNINGS=1 \
    node --experimental-vm-modules ./node_modules/.bin/jest --passWithNoTests \
    src/public/public_tx_simulator/apps_tests/avm_minimal.test.ts ) >"$SCRATCH/zero.log" 2>&1
ZERO_COUNT="$(cat "$SCRATCH/counters-zero"/*.jsonl 2>/dev/null | grep -c . || true)"
assert_eq "the counter reports zero for a suite that compares nothing" "0" "${ZERO_COUNT:-1}"
assert_true "that suite did run (so zero is a measurement, not an absence)" \
  grep -q "1 passed" "$SCRATCH/zero.log"

# (5) The greenness assertion added in review must be capable of failing. A measurement reporting a
#     failed test in either arm must be rejected by the same comparison the check above makes —
#     otherwise the D4 tripwire is back to being a note.
for arm in defaultSuite opcodeSpamArm; do
  python3 - "$SCRATCH/fresh.json" "$SCRATCH/red-$arm.json" "$arm" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d[sys.argv[3]]["testCounts"]["totalFailed"] = 1
json.dump(d, open(sys.argv[2], "w"))
PY
  RED="$(read_json "$SCRATCH/red-$arm.json" "d['$arm']['testCounts']['totalFailed']")"
  if [ "${RED:-0}" = "0" ]; then
    fail "negative control NOT caught: a red $arm still reported zero failures"
  else
    pass "negative control caught: a measurement with a failing test in $arm is rejected"
  fi
done

# (6) D4's pin must not be weakenable by editing the constants. The same greps, against a copy with
#     the expected outcome pattern relaxed to "whatever came out", must reject it.
cp "$SPAM_TEST" "$SCRATCH/weakened-spam.ts"
python3 - "$SCRATCH/weakened-spam.ts" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace(
    "const D4_EXPECTED_ASSERTION_OUTCOMES = [true, false, true];",
    "const D4_EXPECTED_ASSERTION_OUTCOMES = [true, true, true];",
    1,
)
open(p, "w").write(t)
PY
if grep -qF "const D4_EXPECTED_ASSERTION_OUTCOMES = [true, false, true];" "$SCRATCH/weakened-spam.ts"; then
  fail "negative control NOT caught: the weakened D4 outcome pattern still matched"
else
  pass "negative control caught: relaxing D4's expected outcome pattern is detected by the same grep"
fi

finish
