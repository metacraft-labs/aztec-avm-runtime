#!/usr/bin/env bash
# M7: upstream's own vm2 simulation suite runs to completion under V8 — the
# engine the product ships on — with no failure outside the recorded exclusion
# list.
#
# The binary is the SHIPPED artefact, unmodified. barretenberg links every wasm
# output `--import-memory`, so the host supplies `env.memory` with the limits read
# out of the module's own import section (M4's `run_wasm_test_binary.mjs`). The
# host has no way to turn a failing run into a passing one: a guest that traps or
# calls `throw_or_abort_impl` exits non-zero.
#
# Exit status AND the specific failure mode, separately, in both directions.
# `wasm_host/green_summary_exit7.cpp` exists in this repo because a binary can
# print a complete `132 ran / 132 PASSED` summary and still exit 7, so the
# summary line, the per-test lines and the process status are three assertions
# and not one.
#
# TWO NEGATIVE CONTROLS, because "391 tests pass" is a fact about the artefact and
# this milestone claims something stronger: that it passes BECAUSE of two specific
# corrections in the overlay, both of which the prior spike recorded as an
# unfixable "test-framework limitation".
#
#   noentry  the overlay's `-Wl,-u,__main_argc_argv` removed. The binary must
#            still LINK and must then trap at `unreachable` with zero tests run.
#   odr      the overlay's gtest.cmake correction reverted, so gtest's own four
#            translation units are compiled `-DGTEST_HAS_PTHREAD=1` and every
#            consumer sees the header's wasi default of 0. The binary must then
#            fail inside gtest's mutex, and must NOT reach 391.
#
# Each control must fail BY ITS OWN MESSAGE. A control that merely exits non-zero
# proves nothing about which change is load-bearing.

set -uo pipefail

TEST_NAME=verify_vm2_tests_pass_under_v8
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_vm2_tests.sh"

require_nix
m7_measured
note "tree: $M7_TREE"
m7_require_artifacts "$M7_WASM_BIN" "$M7_V8_HOST"

OUT="$M7_WORK/v8-vm2_sim_tests.log"
m7_run_v8 "$M7_WASM_BIN" "$OUT"
v8_rc=$?

assert_eq "the shipped wasm binary exits 0 under V8" 0 "$v8_rc"
assert_eq "gtest's own summary reports $M7_EXPECTED_SIM_TESTS tests ran" \
  "$M7_EXPECTED_SIM_TESTS" "$(m7_summary_ran "$OUT")"
assert_eq "from $M7_EXPECTED_SIM_SUITES test suites" \
  "$M7_EXPECTED_SIM_SUITES" "$(m7_summary_suites "$OUT")"
assert_eq "and $M7_EXPECTED_SIM_TESTS PASSED" \
  "$M7_EXPECTED_SIM_TESTS" "$(m7_summary_passed "$OUT")"

# The summary is gtest's claim; these are the per-test lines it is a claim about.
assert_eq "the per-test [ RUN ] lines agree with the summary" \
  "$M7_EXPECTED_SIM_TESTS" "$(m7_count ran "$OUT")"
assert_eq "the per-test [ OK ] lines agree with the summary" \
  "$M7_EXPECTED_SIM_TESTS" "$(m7_count passed "$OUT")"
assert_eq "no test reported FAILED" 0 "$(m7_count failed "$OUT")"

# Every test that started also finished OK — a test that runs and never reports
# is the shape a trap takes, and equal counts do not exclude it.
m7_names ran "$OUT" >"$M7_WORK/v8-ran.txt"
m7_names passed "$OUT" >"$M7_WORK/v8-passed.txt"
m7_set_equal "every test that started under V8 also passed, per test" \
  "$M7_WORK/v8-ran.txt" "$M7_WORK/v8-passed.txt"

# The committed record of which tests these are, so the set cannot drift silently.
assert_file "the committed included-test list is present" "$M7_INCLUDED_TXT"
m7_set_equal "the V8 run is exactly the committed included-test list, per test" \
  "$M7_WORK/v8-passed.txt" "$M7_INCLUDED_TXT"

# The host is not silently substituting anything: it is the module's own import
# that is satisfied, and the run really went through node.
assert_contains "the transcript is gtest's own main from libgtest_main" \
  "Running main() from" "$(head -5 "$OUT")"

# --- negative control 1: the entry-point fix removed ------------------------
CTL_CMAKE="$M7_TREE/barretenberg/cpp/src/barretenberg/vm2/CMakeLists.txt"
m6_reset_tree "$M7_TREE_NAME"
assert_ge "the overlay's entry-point fix is in the tree to be removed" 1 \
  "$(grep -c -- '-Wl,-u,__main_argc_argv' "$CTL_CMAKE")"
python3 - "$CTL_CMAKE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "    target_link_options(vm2_sim_tests PRIVATE -Wl,-u,__main_argc_argv)\n"
assert s.count(old) == 1, "entry-point fix not found exactly once"
open(p, "w").write(s.replace(old, ""))
PY
ctl_edit=$?
assert_eq "the control edit removes exactly that one line" 0 "$ctl_edit"
m6_configure "$M7_TREE" wasm-avm build-wasm-noentry -DAVM_SIM_TESTS=ON
assert_eq "the control tree still configures" 0 $?
m6_build "$M7_TREE" build-wasm-noentry vm2_sim_tests
assert_eq "and still LINKS — the fix is not about compiling" 0 $?
NOENTRY_BIN="$M7_TREE/barretenberg/cpp/build-wasm-noentry/bin/vm2_sim_tests"
assert_file "the control binary exists" "$NOENTRY_BIN"
# The mechanism, not a proxy for it: gtest_main.cc's own banner string is in the
# working artefact and not in this one, because wasm-ld never searched
# libgtest_main.a for `__main_argc_argv`. (`llvm-nm` cannot see the difference --
# once linked the entry is internalised and neither name appears in either
# binary -- so a symbol count here would be the vacuous version of this.)
assert_eq "the working binary carries gtest's own main" 1 \
  "$(grep -c 'Running main() from' "$M7_WASM_BIN" || true)"
assert_eq "and the control does NOT, which is the mechanism" 0 \
  "$(grep -c 'Running main() from' "$NOENTRY_BIN" || true)"
assert_true "so the control is the smaller binary" \
  test "$(stat -c %s "$NOENTRY_BIN")" -lt "$(stat -c %s "$M7_WASM_BIN")"
CTL1_OUT="$M7_WORK/v8-control-noentry.log"
m7_run_v8 "$NOENTRY_BIN" "$CTL1_OUT"
ctl1_rc=$?
assert_false "the control binary does NOT exit 0" test "$ctl1_rc" -eq 0
assert_contains "and it fails by its own message: it traps at unreachable" \
  "unreachable" "$(cat "$CTL1_OUT")"
assert_eq "with zero tests started" 0 "$(grep -c '^\[ RUN      \] ' "$CTL1_OUT" || true)"
assert_eq "and zero tests passed" 0 "$(grep -c '^\[       OK \] ' "$CTL1_OUT" || true)"

# --- negative control 2: the gtest ODR correction reverted ------------------
CTL_GTEST="$M7_TREE/barretenberg/cpp/cmake/gtest.cmake"
m6_reset_tree "$M7_TREE_NAME"
git -C "$M7_TREE" checkout "HEAD^" -- barretenberg/cpp/cmake/gtest.cmake \
  || die "could not revert cmake/gtest.cmake in $M7_TREE"
assert_eq "the reverted gtest.cmake is upstream's again" 0 \
  "$(grep -c 'GTEST_HAS_PTHREAD' "$CTL_GTEST")"
m6_configure "$M7_TREE" wasm-avm build-wasm-odr -DAVM_SIM_TESTS=ON
assert_eq "the ODR control tree configures" 0 $?
odr_one="$(grep -c -- '-DGTEST_HAS_PTHREAD=1' "$M7_TREE/barretenberg/cpp/build-wasm-odr/build.ninja" || true)"
assert_ge "gtest's own units are compiled -DGTEST_HAS_PTHREAD=1 there" 1 "$odr_one"
assert_eq "and nothing else is (which is the mismatch)" 0 \
  "$(grep -c -- '-DGTEST_HAS_PTHREAD=0' "$M7_TREE/barretenberg/cpp/build-wasm-odr/build.ninja" || true)"
m6_build "$M7_TREE" build-wasm-odr vm2_sim_tests
assert_eq "the ODR control still builds" 0 $?
ODR_BIN="$M7_TREE/barretenberg/cpp/build-wasm-odr/bin/vm2_sim_tests"
assert_file "the ODR control binary exists" "$ODR_BIN"
CTL2_OUT="$M7_WORK/v8-control-odr.log"
m7_run_v8 "$ODR_BIN" "$CTL2_OUT"
ctl2_rc=$?
assert_false "the ODR control does NOT exit 0" test "$ctl2_rc" -eq 0
assert_contains "and it fails by its own message, inside gtest's mutex" \
  "gtest-port.h" "$(cat "$CTL2_OUT")"
assert_contains "naming the pthread condition the prior write-up quoted" \
  "pthread" "$(cat "$CTL2_OUT")"
odr_passed="$(grep -c '^\[       OK \] ' "$CTL2_OUT" || true)"
assert_false "and it does not reach $M7_EXPECTED_SIM_TESTS passing tests" \
  test "$odr_passed" -ge "$M7_EXPECTED_SIM_TESTS"
note "ODR control reached $odr_passed passing test(s) before it died"

# --- put the tree back ------------------------------------------------------
m6_reset_tree "$M7_TREE_NAME"
assert_eq "the tree is clean again after both controls" "" "$(m7_tree_dirty)"

finish
