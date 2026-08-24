#!/usr/bin/env bash
# test_archive_tree_roots_match_real_world_state
#
# The extension's central claim: after a sequence of block-header appends, the reference's archive
# roots are the real WorldState's.
#
# WHERE THE COMPARISON LIVES, AND WHY IT LIVES THERE. Not in a driver of ours. Upstream already
# ships the comparison — `world_state/memory_merkle_db.test.cpp` drives an ephemeral, file-backed
# `world_state::WorldState` and a `MemoryMerkleDB` through the same operations and requires them to
# agree after every step. It constructs the WorldState with FIVE trees and compared FOUR. M14's
# patch closes that: `expect_roots_equal()` compares five, and five cases are added. So this check
# runs UPSTREAM'S OWN GATE, on both trees, per test by name.
#
# That also makes the deliverable's independent-merit argument concrete rather than rhetorical: the
# thing being contributed is not "a tree we needed", it is a fidelity gate that stops omitting a
# tree.
#
# THE THREE COMPARISONS THIS CHECK MAKES, none of which is a count on its own:
#
#   1. the base tree's gate runs SEVEN cases and the patched tree's runs TWELVE, both as identities
#      by NAME, and the five added are the difference between the two name sets rather than a
#      constant typed here;
#   2. all twelve PASS on the patched tree, and the seven that existed before pass on BOTH — an
#      extension that broke an existing case would fail here even if its own five passed;
#   3. the probe's own three-block sequence, run outside gtest, reports an archive that MOVED while
#      the four StateReference trees did NOT, with the size landing on block number + 1 — the
#      invariant upstream's own checkpoint builder checks after every updateArchive.
#
# Run: just verify-archive-roots

TEST_NAME="test_archive_tree_roots_match_real_world_state"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m14_world_state.sh"

m14_measured
assert_file "the base world_state_tests exists" "$M14_BASE_WORLD_STATE_TESTS"
assert_file "the patched world_state_tests exists" "$M14_EXT_WORLD_STATE_TESTS"
[ -x "$M14_BASE_WORLD_STATE_TESTS" ] && [ -x "$M14_EXT_WORLD_STATE_TESTS" ] \
  || die "world_state_tests missing — run 'just verify-block-level-audit'"

RUNDIR="$M14_WORK/gate"; mkdir -p "$RUNDIR"

# gtest is run in the dev shell, stdout and stderr kept apart, and the exit status captured
# SEPARATELY from the transcript, because a suite that died half way still leaves a plausible
# transcript — which is precisely the failure mode M13's own review found in M9's work directory.
run_gate() { # <binary> <label> [extra gtest args...]
  local bin="$1" label="$2"; shift 2
  m6_in_devshell '
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    bin="$1"; shift
    "$bin" "$@"
  ' "$bin" "$@" >"$RUNDIR/$label.out" 2>"$RUNDIR/$label.err"
  printf '%s' "$?" >"$RUNDIR/$label.rc"
}
rc_of()   { cat "$RUNDIR/$1.rc" 2>/dev/null; }
names_of() { sed -n "s/^  \($M14_GATE_SUITE\.\)\?\([A-Za-z0-9_]*\)\$/\2/p" "$RUNDIR/$1.out" 2>/dev/null | sort; }

echo "== A. the gate's case list, both trees, by name =="
run_gate "$M14_BASE_WORLD_STATE_TESTS" list-base --gtest_list_tests --gtest_filter="$M14_GATE_SUITE.*"
run_gate "$M14_EXT_WORLD_STATE_TESTS"  list-ext  --gtest_list_tests --gtest_filter="$M14_GATE_SUITE.*"
assert_eq "the base listing exited 0" "0" "$(rc_of list-base)"
assert_eq "the patched listing exited 0" "0" "$(rc_of list-ext)"

BASE_NAMES="$(names_of list-base)"; EXT_NAMES="$(names_of list-ext)"
assert_eq "the anchor's gate declares seven cases" "$M14_BASE_GATE_TEST_COUNT" \
  "$(printf '%s\n' "$BASE_NAMES" | grep -c .)"
assert_eq "and they are these seven, by name" "$M14_BASE_GATE_TESTS" "$BASE_NAMES"
assert_eq "the patched gate declares twelve" \
  "$((M14_BASE_GATE_TEST_COUNT + M14_NEW_GATE_TEST_COUNT))" \
  "$(printf '%s\n' "$EXT_NAMES" | grep -c .)"
ADDED="$(comm -13 <(printf '%s\n' "$BASE_NAMES") <(printf '%s\n' "$EXT_NAMES"))"
REMOVED="$(comm -23 <(printf '%s\n' "$BASE_NAMES") <(printf '%s\n' "$EXT_NAMES"))"
assert_eq "the five it adds are the DIFFERENCE of the two name sets" "$M14_NEW_GATE_TESTS" "$ADDED"
assert_eq "and it removes none" "" "$REMOVED"

echo
echo "== B. the gate RUN, both trees =="
run_gate "$M14_BASE_WORLD_STATE_TESTS" run-base --gtest_filter="$M14_GATE_SUITE.*"
run_gate "$M14_EXT_WORLD_STATE_TESTS"  run-ext  --gtest_filter="$M14_GATE_SUITE.*"
assert_eq "the anchor's gate exits 0" "0" "$(rc_of run-base)"
assert_eq "the patched gate exits 0" "0" "$(rc_of run-ext)"

passed_of() { grep -oE '^\[       OK \] '"$M14_GATE_SUITE"'\.[A-Za-z0-9_]+' "$RUNDIR/$1.out" 2>/dev/null \
                | sed "s/.*$M14_GATE_SUITE\.//" | sort; }
BASE_PASSED="$(passed_of run-base)"; EXT_PASSED="$(passed_of run-ext)"
assert_eq "seven cases passed on the anchor" "$M14_BASE_GATE_TEST_COUNT" \
  "$(printf '%s\n' "$BASE_PASSED" | grep -c .)"
assert_eq "and the set that passed is the set that was declared" "$BASE_NAMES" "$BASE_PASSED"
assert_eq "twelve passed on the patched tree" \
  "$((M14_BASE_GATE_TEST_COUNT + M14_NEW_GATE_TEST_COUNT))" \
  "$(printf '%s\n' "$EXT_PASSED" | grep -c .)"
assert_eq "and the set that passed is the set that was declared" "$EXT_NAMES" "$EXT_PASSED"
assert_eq "every case the anchor had still passes with the patch" "$BASE_PASSED" \
  "$(comm -12 <(printf '%s\n' "$BASE_PASSED") <(printf '%s\n' "$EXT_PASSED"))"
for t in $M14_NEW_GATE_TESTS; do
  assert_contains "the added case $t is among those that passed" "$t" "$EXT_PASSED"
done
assert_eq "no case failed on the patched tree" "0" \
  "$(grep -c '^\[  FAILED  \]' "$RUNDIR/run-ext.out")"

echo
echo "== C. the gate really drives the REAL world state, not a second copy of the reference =="
# Otherwise "they agree" is a comparison of one implementation with itself. The gate's own source is
# the evidence: it constructs a file-backed world_state::WorldState with five trees and reads the
# archive back out of it.
GATE_SRC="$M14_TREE/barretenberg/cpp/src/barretenberg/world_state/memory_merkle_db.test.cpp"
assert_file "the gate's source is in the patched tree" "$GATE_SRC"
GATE="$(cat "$GATE_SRC" 2>/dev/null)"
assert_contains "it constructs a real WorldState" "ws = std::make_unique<WorldState>(" "$GATE"
assert_contains "on a real directory" "data_dir = crypto::merkle_tree::random_temp_directory();" "$GATE"
assert_contains "with the archive among its five trees" \
  "{ MerkleTreeId::ARCHIVE, ARCHIVE_HEIGHT }," "$GATE"
assert_contains "and it compares the archive snapshot against that world state" \
  "check_snapshot(MerkleTreeId::ARCHIVE, mem_snap.archive_tree);" "$GATE"
assert_contains "the archive append goes through the real WorldState::update_archive" \
  "ws->update_archive(ws->get_state_reference(revision()), block_header_hash);" "$GATE"
assert_eq "expect_roots_equal compares five snapshots" "5" \
  "$(printf '%s\n' "$GATE" | grep -c 'check_snapshot(MerkleTreeId::')"

echo
echo "== D. the same sequence outside gtest, from the probe =="
EXT_OUT="$M14_PROBE_EXT"
assert_file "the patched probe transcript exists" "$EXT_OUT"
PREV_ROOT="$(m14_key "$EXT_OUT" genesis.archive_tree.root)"
assert_prefix "the genesis archive root is a field element" "0x" "$PREV_ROOT"
for block in 1 2 3; do
  ROOT="$(m14_key "$EXT_OUT" "block$block.archive_tree.root")"
  SIZE="$(m14_key "$EXT_OUT" "block$block.archive_tree.size")"
  assert_eq "block $block: the archive size is the block number plus one" "$((block + 1))" "$SIZE"
  assert_false "block $block: and its root moved" test "$ROOT" = "$PREV_ROOT"
  assert_eq "block $block: while the four StateReference trees did NOT move" "1" \
    "$(m14_key "$EXT_OUT" "block$block.state_reference_unchanged")"
  assert_eq "block $block: the leaf written is the header hash asked for" \
    "0x00000000000000000000000000000000000000000000000000000000b10c000$block" \
    "$(m14_key "$EXT_OUT" "block$block.archive_leaf")"
  assert_eq "block $block: and a sibling path of ARCHIVE_HEIGHT levels is available for it" "30" \
    "$(m14_key "$EXT_OUT" "block$block.archive_sibling_path_levels")"
  PREV_ROOT="$ROOT"
done
# The three roots are three DIFFERENT values, so the sequence is a sequence.
DISTINCT="$(for b in 1 2 3; do m14_key "$EXT_OUT" "block$b.archive_tree.root"; done | sort -u | grep -c .)"
assert_eq "the three block roots are three distinct values" "3" "$DISTINCT"

echo
echo "== E. the refusal, and its control =="
assert_eq "a header carrying a stale state reference is refused" "1" \
  "$(m14_key "$EXT_OUT" update_archive.stale_state_reference.threw)"
assert_contains "with the real WorldState's own message" \
  "Can't update archive tree: Block state does not match world state" \
  "$(m14_key "$EXT_OUT" update_archive.stale_state_reference.message)"
assert_eq "and nothing was written: the archive is still at genesis" "1" \
  "$(m14_key "$EXT_OUT" update_archive.archive_size_after_refusal)"
assert_eq "the CURRENT state reference is accepted" "0" \
  "$(m14_key "$EXT_OUT" update_archive.current_state_reference.threw)"
assert_eq "and that one did write" "2" "$(m14_key "$EXT_OUT" update_archive.archive_size_after_acceptance)"
# The message is upstream's, matched against upstream's own source rather than against a copy here.
assert_contains "the message is WorldState::update_archive's, read out of the fork" \
  'throw std::runtime_error("Can'"'"'t update archive tree: Block state does not match world state");' \
  "$(git -C "$FORK_ROOT" show "$M6_BASE_REV:barretenberg/cpp/src/barretenberg/world_state/world_state.cpp" 2>/dev/null)"

finish
