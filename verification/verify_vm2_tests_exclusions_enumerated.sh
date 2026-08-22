#!/usr/bin/env bash
# M7: every test excluded from the wasm run is recorded INDIVIDUALLY with its
# reason, and the list is asserted against so it cannot grow silently.
#
# This is the deliverable that keeps the wasm pass rate honest. "391 of 391" is a
# fact about a target whose size we chose; the number that matters is that the
# 391 sit inside upstream's own 1,803, and that each of the other 1,412 is named
# here with a reason derived from the tree rather than typed into a document.
#
# The reason is DERIVED, not asserted. `AVM_SIM_TESTS` selects test sources by
# directory, so where a test's source file sits IS the reason it is in or out:
# `_exclusions.py` maps every excluded test name back to the file declaring its
# suite (via gtest's own TEST/TEST_F/TEST_P/TYPED_TEST/INSTANTIATE macros) and
# refuses -- exit 4 -- to emit a row it cannot attribute. So the committed file
# is regenerated here and compared, and a test that appeared, vanished or changed
# category since it was written makes this check red.
#
# Two hazards this is written against, both of which have bitten this campaign:
#
#   * A partition that does not cover. `included + excluded` must be EXACTLY the
#     full suite, as a name set, with no overlap; otherwise a test can be in
#     neither list and nobody notices.
#   * A validator whose scope does not cover what it claims. The reason table has
#     five codes and the generator FAILS rather than inventing a sixth, and that
#     refusal is exercised here with a planted row.

set -uo pipefail

TEST_NAME=verify_vm2_tests_exclusions_enumerated
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_vm2_tests.sh"

require_nix
m7_measured
m7_require_artifacts "$M7_NATIVE_VM2_TESTS" "$M7_NATIVE_SIM_TESTS" \
  "$M7_EXCLUSIONS_TSV" "$M7_INCLUDED_TXT" "$M7_EXCLUSIONS_PY" "$M7_SUITE_SOURCES"

VM2_SRC="$(m7_vm2_src)"
assert_dir "the vm2 source tree the reasons are derived from" "$VM2_SRC"

# --- the two lists, from the binaries -----------------------------------------
A_RAW="$M7_WORK/excl-native-vm2_tests.list"
N_RAW="$M7_WORK/excl-native-vm2_sim_tests.list"
m7_run_native "$M7_NATIVE_VM2_TESTS" "$A_RAW" --gtest_list_tests
assert_eq "upstream's own vm2_tests lists, exit 0" 0 $?
m7_run_native "$M7_NATIVE_SIM_TESTS" "$N_RAW" --gtest_list_tests
assert_eq "the wasm-side target lists, exit 0" 0 $?

m7_names list "$A_RAW" >"$M7_WORK/excl_all.txt"
m7_names list "$N_RAW" >"$M7_WORK/excl_included.txt"
assert_eq "the full suite is $M7_EXPECTED_ALL_TESTS tests" \
  "$M7_EXPECTED_ALL_TESTS" "$(wc -l <"$M7_WORK/excl_all.txt" | tr -d ' ')"
assert_eq "the included set is $M7_EXPECTED_SIM_TESTS tests" \
  "$M7_EXPECTED_SIM_TESTS" "$(wc -l <"$M7_WORK/excl_included.txt" | tr -d ' ')"

# --- regenerate the exclusion list -------------------------------------------
GEN="$M7_WORK/exclusions.generated.tsv"
python3 "$M7_EXCLUSIONS_PY" "$A_RAW" "$N_RAW" "$VM2_SRC" >"$GEN"
gen_rc=$?
assert_eq "the exclusion list regenerates from the tree, exit 0" 0 "$gen_rc"
assert_eq "and it has $M7_EXPECTED_EXCLUDED rows, one per excluded test" \
  "$M7_EXPECTED_EXCLUDED" "$(wc -l <"$GEN" | tr -d ' ')"

# Byte comparison against the committed file: the record is the derivation, so a
# hand edit to either side is a failure.
if diff -q "$GEN" "$M7_EXCLUSIONS_TSV" >/dev/null 2>&1; then
  pass "the committed exclusion list is byte-identical to the regenerated one"
else
  fail "the committed exclusion list differs from the tree: $(diff "$GEN" "$M7_EXCLUSIONS_TSV" | head -6 | tr '\n' ' ')"
fi

# --- the partition covers -----------------------------------------------------
cut -f1 "$M7_EXCLUSIONS_TSV" | LC_ALL=C sort -u >"$M7_WORK/excl_names.txt"
assert_eq "the exclusion list names $M7_EXPECTED_EXCLUDED DISTINCT tests" \
  "$M7_EXPECTED_EXCLUDED" "$(wc -l <"$M7_WORK/excl_names.txt" | tr -d ' ')"
m7_set_equal "the committed included list is what the binary declares, per test" \
  "$M7_WORK/excl_included.txt" "$M7_INCLUDED_TXT"
cat "$M7_WORK/excl_included.txt" "$M7_WORK/excl_names.txt" | LC_ALL=C sort -u >"$M7_WORK/excl_union.txt"
m7_set_equal "included + excluded is EXACTLY upstream's own suite, per test" \
  "$M7_WORK/excl_union.txt" "$M7_WORK/excl_all.txt"
overlap="$(LC_ALL=C comm -12 <(LC_ALL=C sort -u "$M7_WORK/excl_included.txt") "$M7_WORK/excl_names.txt" | wc -l | tr -d ' ')"
assert_eq "and the two do not overlap" 0 "$overlap"
assert_eq "arithmetic: $M7_EXPECTED_SIM_TESTS + $M7_EXPECTED_EXCLUDED = $M7_EXPECTED_ALL_TESTS" \
  "$M7_EXPECTED_ALL_TESTS" "$((M7_EXPECTED_SIM_TESTS + M7_EXPECTED_EXCLUDED))"

# --- the reasons --------------------------------------------------------------
# Pinned as an identity with its counts, so a category cannot quietly absorb a
# test from another one.
reasons="$(cut -f3 "$M7_EXCLUSIONS_TSV" | LC_ALL=C sort | uniq -c | awk '{print $2"="$1}' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the reason codes and their counts are exactly the recorded ones" \
  "dsl=5 proving-stack=1059 proving-stack+dsl=59 tracegen=286 tracegen-fixture=3" \
  "$reasons"

# Every row's file really is where its suite is declared, re-derived here rather
# than trusted from the generator that wrote the row.
python3 "$M7_SUITE_SOURCES" "$VM2_SRC" >"$M7_WORK/suite_sources.tsv"
assert_ge "gtest suites were found in the tree" 100 \
  "$(wc -l <"$M7_WORK/suite_sources.tsv" | tr -d ' ')"
bad_rows="$(python3 - "$M7_EXCLUSIONS_TSV" "$M7_WORK/suite_sources.tsv" "$VERIFY_DIR/wasm_host" <<'PY'
import sys, collections
sys.path.insert(0, sys.argv[3])
from _gtest_suite_sources import suite_of
tab = collections.defaultdict(set)
for line in open(sys.argv[2]):
    s, p = line.rstrip("\n").split("\t")
    tab[s].add(p)
bad = 0
for line in open(sys.argv[1]):
    name, rel, _code = line.rstrip("\n").split("\t")
    if rel not in tab.get(suite_of(name), ()):
        bad += 1
print(bad)
PY
)"
assert_eq "every excluded test's recorded file really declares its suite" 0 "$bad_rows"

# No test is excluded because of threads -- the milestone expected that category
# and it is empty, which is a result rather than an omission.
assert_eq "no test is excluded for needing threads" 0 \
  "$(cut -f3 "$M7_EXCLUSIONS_TSV" | grep -c 'thread' || true)"
# And exactly one simulation-side file is excluded, with three tests in it.
assert_eq "exactly one simulation-side source file is excluded" 1 \
  "$(awk -F'\t' '$3=="tracegen-fixture"{print $2}' "$M7_EXCLUSIONS_TSV" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
assert_eq "and it is common/avm_io.test.cpp" "common/avm_io.test.cpp" \
  "$(awk -F'\t' '$3=="tracegen-fixture"{print $2}' "$M7_EXCLUSIONS_TSV" | LC_ALL=C sort -u)"
assert_ge "which really does call the tracegen-bound fixture" 1 \
  "$(grep -c 'get_minimal_trace_with_pi' "$VM2_SRC/common/avm_io.test.cpp" || true)"

# --- the generator REFUSES what it cannot attribute --------------------------
# A validator that silently drops what it does not understand is the defect this
# campaign has found twice. Plant a simulation-side test file that is not in the
# target and is not the one known exception, and require exit 4.
PLANT="$VM2_SRC/simulation/lib/m7_planted_control.test.cpp"
cat >"$PLANT" <<'CPP'
// Planted by verify_vm2_tests_exclusions_enumerated as a negative control and
// removed again in the same run. If this file is in a git status, that check died.
#include <gtest/gtest.h>
TEST(M7PlantedControlSuite, PlantedCase) { EXPECT_TRUE(true); }
CPP
PLANTED_LIST="$M7_WORK/planted_all.list"
{ cat "$A_RAW"; printf 'M7PlantedControlSuite.\n  PlantedCase\n'; } >"$PLANTED_LIST"
python3 "$M7_EXCLUSIONS_PY" "$PLANTED_LIST" "$N_RAW" "$VM2_SRC" >"$M7_WORK/planted.tsv" 2>"$M7_WORK/planted.err"
plant_rc=$?
rm -f "$PLANT"
assert_eq "the generator REFUSES a test it cannot give a reason (exit 4)" 4 "$plant_rc"
assert_contains "and names it rather than dropping it" \
  "M7PlantedControlSuite.PlantedCase" "$(cat "$M7_WORK/planted.err")"
assert_false "the planted control file is gone again" test -e "$PLANT"

# A second refusal: an included test that is NOT in the full suite means the two
# inputs do not describe the same binary, and the list would be meaningless.
STRAY_LIST="$M7_WORK/stray_sim.list"
{ cat "$N_RAW"; printf 'M7StraySuite.\n  StrayCase\n'; } >"$STRAY_LIST"
python3 "$M7_EXCLUSIONS_PY" "$A_RAW" "$STRAY_LIST" "$VM2_SRC" >/dev/null 2>"$M7_WORK/stray.err"
assert_eq "the generator REFUSES a sim list that is not a subset (exit 3)" 3 $?
assert_contains "naming the stray test" "M7StraySuite.StrayCase" "$(cat "$M7_WORK/stray.err")"

# --- the prose record --------------------------------------------------------
EXCL_MD="$REPO_ROOT/fixtures/wasm-parity/EXCLUSIONS.md"
assert_file "the exclusion list has a written record beside it" "$EXCL_MD"
md="$(cat "$EXCL_MD")"
for n in "$M7_EXPECTED_ALL_TESTS" "$M7_EXPECTED_SIM_TESTS" "$M7_EXPECTED_EXCLUDED" 1059 286 59 5 3; do
  assert_contains "EXCLUSIONS.md states the number $n" "$n" "$md"
done
for code in proving-stack tracegen "proving-stack+dsl" dsl tracegen-fixture; do
  assert_contains "EXCLUSIONS.md defines the reason code '$code'" "$code" "$md"
done
assert_contains "and records that no test is excluded for needing threads" \
  "threads" "$md"
assert_contains "and that crypto_merkle_tree_tests cannot be built under wasm" \
  "crypto_merkle_tree_tests" "$md"

# The tree is untouched by this check.
assert_eq "this check left the tree clean" "" "$(m7_tree_dirty)"

finish
