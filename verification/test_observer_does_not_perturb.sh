#!/usr/bin/env bash
# test_observer_does_not_perturb
#
# Every program produces the same simulation result with and without an observer attached, and the
# steps are absent altogether when `collect_execution_steps` is off.
#
# The driver runs each of the eight programs THREE times in three fresh testers — untraced, traced,
# and untraced again — and prints four facts per program:
#
#   absentWhenOff                   `execution_steps` is std::nullopt with the flag off
#   presentWhenOn                   and populated with it on
#   untracedRunsReproducible        two untraced runs of the same program compare EQUAL
#   resultIdenticalWithStepsRemoved the traced result, with the steps stripped, equals the untraced
#
# The third of those is what stops the fourth from measuring determinism instead of the observer,
# and `avmSteps.crossProgramDistinctResults` is what stops `TxSimulationResult::operator==` from
# being a tautology: the eight untraced results must be pairwise DISTINCT under the very same
# operator, so "identical" is a finding rather than a property of the comparison.
#
# `operator==` on TxSimulationResult is `= default`, so it compares every field of every nested
# struct — gas, revert code, the whole public tx effect, the call-stack metadata and the stats map.
# Not a hash and not a chosen subset.
#
# Asserted on BOTH targets, because "does not perturb" on x86-64 is not a statement about wasm.

set -uo pipefail
TEST_NAME=test_observer_does_not_perturb
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m9_observer.sh"

m9_measured
m8_require_artifacts "$(m9_steps_native)" "$(m9_steps_v8)" "$(m9_steps_wasmtime)"

# `operator==` is defaulted, read out of the tree rather than assumed, because "compares every
# field" is the reason this check is worth anything.
avm_io="$M9_TREE/barretenberg/cpp/src/barretenberg/vm2/common/avm_io.hpp"
assert_file "avm_io.hpp is in the measured tree" "$avm_io"
assert_true "TxSimulationResult::operator== is defaulted, so it compares every field" \
  grep -q 'bool operator==(const TxSimulationResult& other) const = default;' "$avm_io"
assert_true "ExecutionStep::operator== is defaulted too" \
  grep -q 'bool operator==(const ExecutionStep& other) const = default;' "$avm_io"
assert_true "execution_steps is an optional, so absence is representable" \
  grep -q 'std::optional<std::vector<ExecutionStep>> execution_steps;' "$avm_io"

for label in native v8 wasmtime; do
  case "$label" in
    native)   t="$(m9_steps_native)" ;;
    v8)       t="$(m9_steps_v8)" ;;
    wasmtime) t="$(m9_steps_wasmtime)" ;;
  esac
  assert_file "[$label] the step transcript exists" "$t"

  # First: this transcript really is a complete run of a tree carrying the patch. Never depend on
  # state you did not produce without asserting it.
  assert_eq "[$label] the run completed" "1" "$(m9_field "$t" avmSteps.done)"
  assert_eq "[$label] the tree carried the observer patch" "1" \
    "$(m9_field "$t" avmSteps.observerCompiledIn)"
  assert_eq "[$label] all eight programs ran" "$M9_EXPECTED_PROGRAMS" \
    "$(m9_field "$t" avmSteps.programs.count)"

  # The discrimination, first, so everything after it means something.
  assert_eq "[$label] the eight untraced results are pairwise distinct under the same operator==" \
    "$M9_EXPECTED_PROGRAMS" "$(m9_field "$t" avmSteps.crossProgramDistinctResults)"
  assert_eq "[$label] no two of them compare equal" "0" \
    "$(m9_field "$t" avmSteps.crossProgramEqualPairs)"

  for prog in $M9_PROGRAMS; do
    assert_eq "[$label] $prog: execution_steps is absent with the flag off" "1" \
      "$(m9_field "$t" "steps.$prog.absentWhenOff")"
    assert_eq "[$label] $prog: execution_steps is present with the flag on" "1" \
      "$(m9_field "$t" "steps.$prog.presentWhenOn")"
    assert_eq "[$label] $prog: two untraced runs compare equal (so the next line is not about determinism)" "1" \
      "$(m9_field "$t" "steps.$prog.untracedRunsReproducible")"
    assert_eq "[$label] $prog: the traced result with the steps removed equals the untraced result" "1" \
      "$(m9_field "$t" "steps.$prog.resultIdenticalWithStepsRemoved")"
  done
done

# The observable side of "unperturbed", spelled out rather than left to operator==: the revert code
# and the total gas of each program are identical between the traced and untraced runs by
# construction above, and they are also identical between the two TARGETS, which is a different
# fact and is asserted here.
for prog in $M9_PROGRAMS; do
  n_rc="$(m9_field "$(m9_steps_native)" "steps.$prog.revertCode")"
  w_rc="$(m9_field "$(m9_steps_v8)" "steps.$prog.revertCode")"
  n_gas="$(m9_field "$(m9_steps_native)" "steps.$prog.totalGas")"
  w_gas="$(m9_field "$(m9_steps_v8)" "steps.$prog.totalGas")"
  assert_eq "$prog: the traced revert code agrees native versus wasm" "$n_rc" "$w_rc"
  assert_eq "$prog: the traced total gas agrees native versus wasm  [$n_gas]" "$n_gas" "$w_gas"
done

# And the revert codes are not a constant: exactly three of the eight end non-zero, and they are
# named. A column of zeroes compared against a column of zeroes is not a comparison.
nonzero=""
for prog in $M9_PROGRAMS; do
  rc="$(m9_field "$(m9_steps_native)" "steps.$prog.revertCode")"
  [ "$rc" = "0" ] || nonzero="$nonzero $prog"
done
assert_eq "exactly the three programs that fail report a non-zero revert code" \
  " revert burn oob" "$nonzero"

# ---------------------------------------------------------------------------
# AND THE MILESTONE BEFORE IT IS NOT PERTURBED EITHER.
#
# M9's overlay adds argv dispatch and four modes to M8's driver, and the observer patch adds a
# field to `TxSimulationResult` and a branch to the fast loop. Neither may move anything M8
# measured. That is checked against M8's OWN COMMITTED TRANSCRIPT — an artefact this milestone did
# not produce and cannot have tuned — rather than by re-running M8's checks against M8's own tree,
# which would prove nothing about this one.
# ---------------------------------------------------------------------------
m8_committed="$REPO_ROOT/fixtures/wasm-parity/avm-differential-native.results"
assert_file "M8's committed native transcript is present" "$m8_committed"
default_out="$M9_WORK/m8mode-native.transcript"
m9_run_native "$(m9_native_bin "$M9_TREE")" "$default_out" "$M9_WORK/m8mode-native.stderr"
assert_eq "the driver with NO arguments still runs M8's transcript and exits 0" "0" "$?"
m8_require_artifacts "$default_out"
a="$M9_WORK/m8mode.ord"; b="$M9_WORK/m8committed.ord"
m9_ordinary "$default_out" >"$a"
m9_ordinary "$m8_committed" >"$b"
assert_eq "it carries M8's recorded number of non-diagnostic lines" \
  "$M8_EXPECTED_ORDINARY_LINES" "$(wc -l <"$a")"
assert_eq "and so does the committed copy, so the comparison is against M8's own number" \
  "$M8_EXPECTED_ORDINARY_LINES" "$(wc -l <"$b")"
assert_true "every one of them is byte-identical to M8's committed transcript" cmp -s "$a" "$b"
assert_eq "including all $M8_EXPECTED_ROOT_LINES root+size lines" "$M8_EXPECTED_ROOT_LINES" \
  "$(m8_root_lines "$default_out" | wc -l)"
assert_true "the root+size lines are identical to M8's, line for line" \
  bash -c "diff <(m8_root_lines '$default_out') <(m8_root_lines '$m8_committed') >/dev/null"
assert_eq "and the driver emitted no step record in its default mode" "0" \
  "$(m9_step_record_count "$default_out")"

# The same claim about the no-hoist control build lives in
# test_observer_fires_on_exceptional_halt, which owns that tree: moving the call site must not
# change the simulation either, or the record difference that check reports would be about the AVM
# having run differently rather than about the observer.

finish
