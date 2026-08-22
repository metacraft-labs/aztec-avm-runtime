#!/usr/bin/env bash
# M7: every test that passes natively passes under wasm — compared PER TEST, not
# by aggregate count.
#
# Why per test. Equal counts survive a rename, and they survive a drop plus an
# addition. M3 and M4 both found a name-set comparison catching something a count
# did not, and M4's review made it a standing lesson. So every comparison here is
# `comm` over sorted name sets, and a difference is reported as the names that
# differ rather than as a number.
#
# Four sets, all from the SAME tree and the same five patches:
#
#   N_list   what the native vm2_sim_tests binary DECLARES (--gtest_list_tests)
#   N_pass   what it PASSES when run
#   W_pass   what the wasm binary passes under V8
#   T_pass   what it passes under wasmtime
#
# and the containment that makes the whole exercise honest:
#
#   A_list   what upstream's OWN native vm2_tests declares -- the full suite,
#            proving stack and dsl included. N_list must be a SUBSET of it, name
#            for name. Without that, "391 of 391" is a pass rate against a suite
#            whose size we chose.
#
# Declared-versus-passed is kept as two facts on each side. A binary can declare
# 391 tests, start 391 and finish 12; only the RUN/OK line sets separate those.

set -uo pipefail

TEST_NAME=verify_vm2_tests_native_wasm_per_test_parity
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_vm2_tests.sh"

require_nix
m7_measured
m7_require_artifacts "$M7_WASM_BIN" "$M7_NATIVE_VM2_TESTS" "$M7_NATIVE_SIM_TESTS" "$M7_NAMES"

# --- the two sides are comparable in the one place they could silently differ --
# barretenberg declares GTest with FIND_PACKAGE_ARGS, so a native configure will
# happily take the HOST's gtest while a wasm configure -- which cannot find a
# package at all -- always builds googletest v1.13.0 from source. Comparing a
# 1.17.0 native run against a 1.13.0 wasm run would be comparing two test
# frameworks as well as two targets. Both builds are asserted to use the same
# FetchContent'd googletest, from its own source directory.
for b in "$M7_NATIVE_BUILD" "$M7_WASM_BUILD"; do
  nj="$M7_TREE/barretenberg/cpp/$b/build.ninja"
  assert_file "$b has a build.ninja to read" "$nj"
  assert_ge "$b builds googletest from FetchContent's own source" 1 \
    "$(grep -c '_deps/gtest-src' "$nj" || true)"
  assert_eq "$b links no gtest from outside the build tree" 0 \
    "$(grep -oE '[^ ]*libgtest[^ ]*\.so[^ ]*' "$nj" | LC_ALL=C sort -u | grep -c . || true)"
done
gtest_tag="$(grep -oE 'GIT_TAG v[0-9.]+' "$M7_TREE/barretenberg/cpp/cmake/gtest.cmake" | head -1)"
assert_eq "and it is the version upstream pins" "GIT_TAG v1.13.0" "$gtest_tag"

# --- native: upstream's own full suite, listed ------------------------------
A_LIST_RAW="$M7_WORK/native-vm2_tests.list"
m7_run_native "$M7_NATIVE_VM2_TESTS" "$A_LIST_RAW" --gtest_list_tests
assert_eq "upstream's own native vm2_tests lists its tests, exit 0" 0 $?
m7_names list "$A_LIST_RAW" >"$M7_WORK/A_list.txt"
assert_eq "and it declares $M7_EXPECTED_ALL_TESTS tests" \
  "$M7_EXPECTED_ALL_TESTS" "$(wc -l <"$M7_WORK/A_list.txt" | tr -d ' ')"

# --- native: the simulation-side target ------------------------------------
N_LIST_RAW="$M7_WORK/native-vm2_sim_tests.list"
m7_run_native "$M7_NATIVE_SIM_TESTS" "$N_LIST_RAW" --gtest_list_tests
assert_eq "the native vm2_sim_tests lists its tests, exit 0" 0 $?
m7_names list "$N_LIST_RAW" >"$M7_WORK/N_list.txt"
assert_eq "and it declares $M7_EXPECTED_SIM_TESTS tests" \
  "$M7_EXPECTED_SIM_TESTS" "$(wc -l <"$M7_WORK/N_list.txt" | tr -d ' ')"

# THE CONTAINMENT. Not a count: every one of the 391 names must occur in the
# 1,803, so the wasm target is a subset of upstream's suite and not a rewrite of
# it under the same name.
stray="$(LC_ALL=C comm -13 <(LC_ALL=C sort -u "$M7_WORK/A_list.txt") <(LC_ALL=C sort -u "$M7_WORK/N_list.txt"))"
assert_eq "every wasm-side test name is also in upstream's own vm2_tests" "" \
  "$(printf '%s' "$stray" | tr '\n' ' ' | sed 's/ *$//')"

# --- native: run ------------------------------------------------------------
N_RUN="$M7_WORK/native-vm2_sim_tests.run"
m7_run_native "$M7_NATIVE_SIM_TESTS" "$N_RUN"
native_rc=$?
assert_eq "the native vm2_sim_tests exits 0" 0 "$native_rc"
assert_eq "its summary reports $M7_EXPECTED_SIM_TESTS ran" \
  "$M7_EXPECTED_SIM_TESTS" "$(m7_summary_ran "$N_RUN")"
assert_eq "and $M7_EXPECTED_SIM_TESTS passed" \
  "$M7_EXPECTED_SIM_TESTS" "$(m7_summary_passed "$N_RUN")"
assert_eq "with nothing FAILED" 0 "$(m7_count failed "$N_RUN")"
m7_names ran "$N_RUN" >"$M7_WORK/N_ran.txt"
m7_names passed "$N_RUN" >"$M7_WORK/N_pass.txt"
m7_set_equal "natively, what is declared is what runs" \
  "$M7_WORK/N_list.txt" "$M7_WORK/N_ran.txt"
m7_set_equal "and what runs is what passes" \
  "$M7_WORK/N_ran.txt" "$M7_WORK/N_pass.txt"

# --- wasm: run under both hosts --------------------------------------------
W_RUN="$M7_WORK/parity-v8.log"
m7_run_v8 "$M7_WASM_BIN" "$W_RUN"
assert_eq "the wasm binary exits 0 under V8" 0 $?
m7_names ran "$W_RUN" >"$M7_WORK/W_ran.txt"
m7_names passed "$W_RUN" >"$M7_WORK/W_pass.txt"
m7_set_equal "under wasm, what starts is what passes" \
  "$M7_WORK/W_ran.txt" "$M7_WORK/W_pass.txt"

T_RUN="$M7_WORK/parity-wasmtime.log"
m7_run_wasmtime "$M7_WASM_BIN" "$T_RUN"
assert_eq "the wasm binary exits 0 under wasmtime" 0 $?
m7_names passed "$T_RUN" >"$M7_WORK/T_pass.txt"

# --- THE PARITY -------------------------------------------------------------
m7_set_equal "the wasm binary DECLARES exactly what the native one declares" \
  "$M7_WORK/N_list.txt" "$M7_WORK/W_ran.txt"
m7_set_equal "every test that passes natively passes under wasm on V8, per test" \
  "$M7_WORK/N_pass.txt" "$M7_WORK/W_pass.txt"
m7_set_equal "and under wasmtime, per test" \
  "$M7_WORK/N_pass.txt" "$M7_WORK/T_pass.txt"

# The comparison is not vacuous: the sets have to be big and they have to contain
# the things the milestone cares about.
assert_ge "the compared set is the whole simulation suite, not a fragment" \
  "$M7_EXPECTED_SIM_TESTS" "$(wc -l <"$M7_WORK/N_pass.txt" | tr -d ' ')"
assert_ge "spread over $M7_EXPECTED_SIM_SUITES suites" "$M7_EXPECTED_SIM_SUITES" \
  "$(awk -F. '{print $1}' "$M7_WORK/N_pass.txt" | LC_ALL=C sort -u | wc -l | tr -d ' ')"

# A CONTROL for the comparator itself: the same machinery must REJECT a set that
# differs by one name, otherwise "identical" is a statement about the comparison
# and not about the runs. This campaign has shipped a check that passed a decoy
# differing only in a degenerate row.
DECOY="$M7_WORK/decoy_pass.txt"
LC_ALL=C sort -u "$M7_WORK/W_pass.txt" | tail -n +2 >"$DECOY"
decoy_diff="$(m7_set_diff "$M7_WORK/N_pass.txt" "$DECOY")"
assert_eq "the comparator rejects a set with one test dropped" 1 \
  "$(printf '%s\n' "$decoy_diff" | grep -c '^< ')"
RENAMED="$M7_WORK/renamed_pass.txt"
LC_ALL=C sort -u "$M7_WORK/W_pass.txt" | sed '1s/$/X/' >"$RENAMED"
renamed_diff="$(m7_set_diff "$M7_WORK/N_pass.txt" "$RENAMED")"
assert_eq "and a set with one test RENAMED, which an equal count would not" 2 \
  "$(printf '%s\n' "$renamed_diff" | grep -c '^[<>] ')"

finish
