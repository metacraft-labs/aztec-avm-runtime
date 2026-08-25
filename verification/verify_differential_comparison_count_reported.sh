#!/usr/bin/env bash
# verify_differential_comparison_count_reported
#
# CI reports the number of actual differential COMPARISONS, separately from the test count, and
# fails if it falls below the recorded floor.
#
# THE DEFECT THIS EXISTS TO MAKE IMPOSSIBLE. The suite reports 758 passing tests. 77 carry the
# `(TS Simulator)` label, which — because upstream's two labels mean the opposite of what they look
# like — selects the DIFFERENTIAL harness. Those 77 tests drive 74 transactions. "756 differential
# tests" was quoted for a number that is 74. An order of magnitude, from reading one label
# (DRIFT.md D2, D7).
#
# Four things are asserted, and the last two are what stop this being decoration:
#   1. the headline tool exists, runs, and prints TRANSACTIONS above TESTS;
#   2. its numbers equal the measured fixtures, arm by arm — it computes nothing of its own;
#   3. the FLOOR BITES: a fixture reduced below the floor makes it exit non-zero;
#   4. and a fixture that is ABSENT is not read as zero — the tool refuses.
#
# Run: just verify-three-way

TEST_NAME="verify_differential_comparison_count_reported"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m19_differential.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is required"
TOOL="$REPO_ROOT/tools/report_comparisons.py"
FLOOR="$REPO_ROOT/fixtures/differential-comparison-floor.json"
assert_file "the headline tool is present" "$TOOL"
assert_file "the recorded floor is present" "$FLOOR"
assert_file "the two-way measurement is present" "$M19_ARM_COUNTS"
assert_file "the three-way measurement is present" "$M19_COUNTS"

# ---- 1. it runs and it leads with comparisons -------------------------------
out="$(python3 "$TOOL" 2>&1)"
rc=$?
assert_eq "the headline tool exits 0" "0" "$rc"
assert_contains "it prints the transaction count as the headline" "TRANSACTIONS COMPARED" "$out"
assert_contains "it prints the pair count separately" "implementation-pair comparisons" "$out"
assert_contains "it labels the test count as NOT the comparison count" "NOT the comparison count" "$out"

tx_line="$(printf '%s\n' "$out" | grep -n 'TRANSACTIONS COMPARED' | cut -d: -f1)"
tests_line="$(printf '%s\n' "$out" | grep -n 'tests:' | cut -d: -f1)"
assert_true "the transaction count is printed ABOVE the test count" \
  test "$tx_line" -lt "$tests_line"

# ---- 2. the numbers are the measured ones, arm by arm ----------------------
two_default="$(m19_json "$M19_ARM_COUNTS" 'd["defaultSuite"]["comparisons"]')"
two_spam="$(m19_json "$M19_ARM_COUNTS" 'd["opcodeSpamArm"]["comparisons"]')"
three_tx="$(m19_json "$M19_COUNTS" 'd["transactionsCompared"]')"
three_pairs="$(m19_json "$M19_COUNTS" 'd["pairsCompared"]')"
expected_tx=$((two_default + two_spam + three_tx))
expected_pairs=$((two_default + two_spam + three_pairs))

reported_tx="$(printf '%s\n' "$out" | grep 'TRANSACTIONS COMPARED' | grep -oE '[0-9]+$')"
reported_pairs="$(printf '%s\n' "$out" | grep 'implementation-pair comparisons' | grep -oE '[0-9]+$')"
assert_eq "the reported transaction count is the sum of the measured arms" "$expected_tx" "$reported_tx"
assert_eq "the reported pair count is the sum of the measured arms" "$expected_pairs" "$reported_pairs"
assert_ge "the three-way arm contributes more pairs than transactions, as a three-way arm must" \
  $((three_tx + 1)) "$three_pairs"
assert_ge "the surface is materially larger than the two-way baseline alone" \
  $((two_default + two_spam + 1)) "$expected_tx"

# ---- 3. THE FLOOR BITES ----------------------------------------------------
# A floor that has never been observed to fail is not a floor. Both fixtures are perturbed, one at
# a time, in a SCRATCH COPY — nothing here writes to the tree it is checking — and the tool must
# refuse each time.
scratch="$M19_WORK/floor"
rm -rf "$scratch"; mkdir -p "$scratch/fixtures"
cp "$FLOOR" "$scratch/fixtures/"
raised="$scratch/fixtures/raised-floor.json"
python3 - "$FLOOR" "$raised" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["transactions"] += 1
json.dump(d, open(sys.argv[2], "w"))
PY
python3 "$TOOL" --floor "$raised" >"$scratch/raised.out" 2>&1
assert_eq "one transaction below the floor is refused" "3" "$?"
assert_contains "and it says the surface shrank" "SHRANK" "$(cat "$scratch/raised.out")"

python3 - "$FLOOR" "$scratch/fixtures/raised-pairs.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["pairs"] += 1
json.dump(d, open(sys.argv[2], "w"))
PY
python3 "$TOOL" --floor "$scratch/fixtures/raised-pairs.json" >"$scratch/pairs.out" 2>&1
assert_eq "one PAIR below the floor is refused too, so neither dimension is decoration" "3" "$?"

# The positive control for the controls: the unmodified floor passes, which is assertion 1. Stated
# again here as the pairing, because a refusal with no acceptance beside it proves only that the
# tool can exit 3.
python3 "$TOOL" --floor "$FLOOR" >/dev/null 2>&1
assert_eq "and the real floor is met" "0" "$?"

# ---- 4. an absent measurement is not a measurement of zero -----------------
python3 "$TOOL" --floor "$scratch/does-not-exist.json" >"$scratch/missing.out" 2>&1
assert_eq "a missing fixture is refused rather than read as zero" "2" "$?"
assert_contains "and it says so" "must not be reported" "$(cat "$scratch/missing.out")"

# ---- 5. CI reports it, as a step rather than as a comment ------------------
WF="$REPO_ROOT/.github/workflows/avm-wasm.yml"
assert_file "the workflow is present" "$WF"
if command -v yq >/dev/null 2>&1; then
  step_names="$(yq -r '.jobs["differential-oracle"].steps[].name' "$WF" 2>/dev/null)"
else
  step_names="$(nix shell nixpkgs#yq-go --command yq -r '.jobs["differential-oracle"].steps[].name' "$WF" 2>/dev/null)"
fi
[ -n "$step_names" ] || die "the workflow could not be parsed; a job named in a comment is not a job"
assert_contains "the differential job has a step that reports the headline" "THE HEADLINE" "$step_names"
runs="$(if command -v yq >/dev/null 2>&1; then yq -r '.jobs["differential-oracle"].steps[].run // ""' "$WF"; \
        else nix shell nixpkgs#yq-go --command yq -r '.jobs["differential-oracle"].steps[].run // ""' "$WF"; fi)"
assert_contains "and that step actually invokes the tool" "report-comparisons" "$runs"
assert_contains "and the recipe exists" "report-comparisons:" "$(cat "$REPO_ROOT/Justfile")"

finish
