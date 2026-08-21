#!/usr/bin/env bash
# verify_merkle_lmdb_split_native_neutral
#
# M3's centre. The prepared upstream patch splits `crypto_merkle_tree` from its
# LMDB backend, and its entire case to a maintainer is that it costs upstream
# nothing. That is *demonstrated* here, not asserted: the same targets and the
# same test binaries are built and run before and after, and the numbers are
# compared.
#
# What "before and after" means concretely:
#
#   before  $M3_WORK/base     — aztec-packages at 233d8e0993, unmodified
#   after   $M3_WORK/patched  — the same commit with the format-patch applied
#
# Both are built with the same CMake arguments by the same dev shell, so the
# only variable is the patch.
#
# Two things this check is careful about, both of them lessons from earlier
# milestones in this campaign:
#
#   * It asserts on EXIT STATUS as well as counts. A build that stops half way
#     can still leave a test binary from a previous run on disk, and a test
#     binary that aborts after the summary line still prints plausible numbers.
#     Every ninja invocation and every gtest run contributes its own status
#     assertion, and no count assertion is allowed to stand in for one.
#   * It asserts the TEST NAME SETS are identical, not only that 36 + 96 = 132.
#     Equal counts survive a rename, a drop paired with an addition, or a suite
#     silently disabled; the name sets do not.
#
# Cost: the first run builds barretenberg twice (~3 min wall on 32 cores, plus
# ~1 min for the two configures). Re-runs are incremental — ninja has nothing to
# do — and cost about as long as the test binaries take (~2 min, dominated by
# the 96 LMDB tree tests). Nothing here is skippable: if a tree cannot be
# prepared or a build fails, the check fails.
#
# Run: just verify-merkle-neutral

TEST_NAME="verify_merkle_lmdb_split_native_neutral"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_merkle_lmdb.sh"

note "work directory: $M3_WORK   (override with M3_WORK=...)"

# ---------------------------------------------------------------------------
# The two trees are what they claim to be
# ---------------------------------------------------------------------------
m3_prepare_trees

assert_eq "base worktree is at the patch's base commit" \
  "$(git -C "$FORK_ROOT" rev-parse "$M3_BASE_REV")" \
  "$(git -C "$M3_WORK/base" rev-parse HEAD)"

# The patched tree is built by applying the FILE that would be sent upstream.
# Cross-check it against the local commit that carries the same change: if the
# two ever diverge, everything measured below is measuring the wrong thing.
if git -C "$FORK_ROOT" rev-parse --verify --quiet "$M3_SPLIT_REV^{commit}" >/dev/null; then
  assert_eq "the applied patch reproduces the recorded split commit's tree" \
    "$(git -C "$FORK_ROOT" rev-parse "$M3_SPLIT_REV^{tree}")" \
    "$(git -C "$M3_WORK/patched" rev-parse 'HEAD^{tree}')"
  assert_eq "the recorded split commit sits directly on the base commit" \
    "$(git -C "$FORK_ROOT" rev-parse "$M3_BASE_REV")" \
    "$(git -C "$FORK_ROOT" rev-parse "$M3_SPLIT_REV^")"
else
  fail "the recorded split commit $M3_SPLIT_REV is not in $FORK_ROOT"
fi

# A guard against the whole comparison being vacuous: the two trees must
# actually differ, and differ in the way the patch says they do.
assert_false "the base tree has no crypto/merkle_tree_lmdb module" \
  test -d "$M3_WORK/base/barretenberg/cpp/src/barretenberg/crypto/merkle_tree_lmdb"
assert_dir "the patched tree has the new crypto/merkle_tree_lmdb module" \
  "$M3_WORK/patched/barretenberg/cpp/src/barretenberg/crypto/merkle_tree_lmdb"

# ---------------------------------------------------------------------------
# Build both, and assert on ninja's exit status
# ---------------------------------------------------------------------------
note "building: $M3_COMMON_TARGETS  (+ $M3_PATCHED_EXTRA_TARGETS after)"

m3_build "$M3_WORK/base" $M3_COMMON_TARGETS
rc_base=$?
assert_eq "before: ninja exits 0 building [$M3_COMMON_TARGETS]" 0 "$rc_base"
[ "$rc_base" -eq 0 ] || note "see $M3_WORK/base/m3-build.log"

m3_build "$M3_WORK/patched" $M3_COMMON_TARGETS $M3_PATCHED_EXTRA_TARGETS
rc_patched=$?
assert_eq "after: ninja exits 0 building [$M3_COMMON_TARGETS $M3_PATCHED_EXTRA_TARGETS]" \
  0 "$rc_patched"
[ "$rc_patched" -eq 0 ] || note "see $M3_WORK/patched/m3-build.log"

BB="$M3_WORK/base/barretenberg/cpp/build-native"
BP="$M3_WORK/patched/barretenberg/cpp/build-native"

# The libraries the patch's consumers are: they must exist on both sides. These
# are the "and everything else still builds" half of the claim.
for lib in libvm2_sim.a libworld_state_reference.a libworld_state.a; do
  assert_file "before: $lib built" "$BB/lib/$lib"
  assert_file "after:  $lib built" "$BP/lib/$lib"
done
assert_file "before: crypto_merkle_tree_tests built" "$BB/bin/crypto_merkle_tree_tests"
assert_file "after:  crypto_merkle_tree_tests built" "$BP/bin/crypto_merkle_tree_tests"
assert_file "after:  crypto_merkle_tree_lmdb_tests built" "$BP/bin/crypto_merkle_tree_lmdb_tests"
assert_false "before: there is no crypto_merkle_tree_lmdb_tests to run" \
  test -f "$BB/bin/crypto_merkle_tree_lmdb_tests"

# ---------------------------------------------------------------------------
# Run the same binaries and compare. Exit status FIRST, then counts.
# ---------------------------------------------------------------------------
# NOTE: this must NOT be called in a command substitution — the assertion
# counters live in this shell, and a subshell's would be discarded. It sets
# RUN_RAN instead of printing it.
RUN_RAN=
run_and_assert() { # <label> <build-dir> <binary> <expected-count>
  local label="$1" bdir="$2" bin="$3" want="$4" out r status ran passed
  out="$M3_WORK/run-$label-$bin.txt"
  r="$(m3_run_gtest "$bdir" "$bin" "$out")"
  set -- $r; status="$1"; ran="$2"; passed="$3"
  assert_eq "$label $bin: exits 0" 0 "$status"
  assert_eq "$label $bin: tests ran" "$want" "$ran"
  assert_eq "$label $bin: tests passed" "$want" "$passed"
  [ "$status" -eq 0 ] || note "output: $out"
  case "$ran" in ''|*[!0-9]*) RUN_RAN=0 ;; *) RUN_RAN="$ran" ;; esac
}

run_and_assert before "$BB" crypto_merkle_tree_tests 132;      before_cmt="$RUN_RAN"
run_and_assert before "$BB" world_state_tests 33;              before_ws="$RUN_RAN"
run_and_assert after  "$BP" crypto_merkle_tree_tests 36;       after_cmt="$RUN_RAN"
run_and_assert after  "$BP" crypto_merkle_tree_lmdb_tests 96;  after_lmdb="$RUN_RAN"
run_and_assert after  "$BP" world_state_tests 33;              after_ws="$RUN_RAN"

# The neutrality arithmetic, stated as its own assertion so the number in PR.md
# has a check behind it rather than a derivation in prose.
assert_eq "the merkle-tree suite is redistributed, not reduced: after == before" \
  "$before_cmt" "$((after_cmt + after_lmdb))"
assert_eq "world_state_tests is untouched by the split" "$before_ws" "$after_ws"

# ---------------------------------------------------------------------------
# The stronger statement: the same tests, not merely the same number of them
# ---------------------------------------------------------------------------
m3_gtest_names "$BB" crypto_merkle_tree_tests >"$M3_WORK/names-before.txt"
{
  m3_gtest_names "$BP" crypto_merkle_tree_tests
  m3_gtest_names "$BP" crypto_merkle_tree_lmdb_tests
} | sort >"$M3_WORK/names-after.txt"

n_before="$(wc -l <"$M3_WORK/names-before.txt" | tr -d ' ')"
n_after="$(wc -l <"$M3_WORK/names-after.txt" | tr -d ' ')"
assert_eq "the enumerated test names before match the tests that ran" "$before_cmt" "$n_before"
assert_eq "the enumerated test names after match the tests that ran" \
  "$((after_cmt + after_lmdb))" "$n_after"
assert_ge "the name lists are not empty (the enumeration itself works)" 100 "$n_before"

if diff -u "$M3_WORK/names-before.txt" "$M3_WORK/names-after.txt" >"$M3_WORK/names.diff" 2>&1; then
  pass "every test name is preserved across the split — no test renamed, dropped or added"
else
  fail "the test name sets differ across the split; see $M3_WORK/names.diff"
  head -20 "$M3_WORK/names.diff" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
# Record the measurement so the other M3 checks read the same numbers
# ---------------------------------------------------------------------------
{
  printf 'M3_BUILD_RC_BASE=%s\n'     "$rc_base"
  printf 'M3_BUILD_RC_PATCHED=%s\n'  "$rc_patched"
  printf 'M3_BEFORE_CMT_RAN=%s\n'    "$before_cmt"
  printf 'M3_BEFORE_WS_RAN=%s\n'     "$before_ws"
  printf 'M3_AFTER_CMT_RAN=%s\n'     "$after_cmt"
  printf 'M3_AFTER_CMT_LMDB_RAN=%s\n' "$after_lmdb"
  printf 'M3_AFTER_WS_RAN=%s\n'      "$after_ws"
} >"$M3_WORK/measured.env"
note "measurement recorded in $M3_WORK/measured.env"
note "before: crypto_merkle_tree_tests=$before_cmt  world_state_tests=$before_ws"
note "after:  crypto_merkle_tree_tests=$after_cmt  crypto_merkle_tree_lmdb_tests=$after_lmdb  world_state_tests=$after_ws"

finish
