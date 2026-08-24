#!/usr/bin/env bash
# test_archive_tree_participates_in_checkpoints
#
# Creating, reverting and committing a checkpoint has to restore and preserve the archive along with
# the other four. This is not decoration: a block is built inside a checkpoint, and an archive leaf
# that survived a rolled-back block certifies a state that never existed — while every root involved
# still looks perfectly well-formed. That is the same silent failure mode M13's checkpoint
# coordination exists for, one tree further out.
#
# HOW THE ARCHIVE COMES TO BE CHECKPOINTED. It is a member of `MemoryMerkleDB::State`, and
# `create_checkpoint` pushes a copy of `State` while `revert_checkpoint` assigns it back. So the
# archive is not checkpointed by code that says so — it is checkpointed because of where it lives,
# and this check asserts the WHERE as well as the behaviour, because the behaviour could otherwise
# be reproduced by a special case that a later refactor would drop.
#
# THE COMPARISON IS BETWEEN THREE MEASURED STATES, not two. Genesis, inside, after-revert. If
# "inside" were not required to DIFFER from genesis, "after-revert equals genesis" would be
# satisfied by an implementation that never changed anything at all.
#
# TWO WITNESSES: upstream's own gate case `ArchiveParticipatesInCheckpoints`, which drives a REAL
# WorldState in lockstep, and the probe, which reports the roots so the numbers are visible here
# rather than only inside gtest.
#
# Mutation M4 — restoring the archive separately from the rest of State, i.e. not restoring it —
# fails exactly one case, `ArchiveParticipatesInCheckpoints`, and nothing else. That is recorded in
# WORLD-STATE.md and is why this check is a check.
#
# Run: just verify-archive-checkpoints

TEST_NAME="test_archive_tree_participates_in_checkpoints"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m14_world_state.sh"

m14_measured
EXT_OUT="$M14_PROBE_EXT"
assert_file "the patched probe transcript exists" "$EXT_OUT"
assert_file "the patched world_state_tests exists" "$M14_EXT_WORLD_STATE_TESTS"
[ -f "$EXT_OUT" ] && [ -x "$M14_EXT_WORLD_STATE_TESTS" ] || die "inputs missing — run 'just verify-block-level-audit'"

echo "== A. the archive is IN the checkpointed State, structurally =="
REF_HPP="$(cat "$M14_TREE/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp" 2>/dev/null)"
STATE_BLOCK="$(printf '%s\n' "$REF_HPP" | awk '/^    struct State \{/{f=1;next} f&&/^    \};/{exit} f{print}')"
STATE_MEMBERS="$(printf '%s\n' "$STATE_BLOCK" | sed -E 's/^\s*[A-Za-z0-9_]+ ([a-z0-9_]+);$/\1/' | grep -E '^[a-z0-9_]+$' | sort | tr '\n' ' ')"
assert_eq "State now holds five trees, and they are these" \
  "archive_tree l1_to_l2_message_tree note_hash_tree nullifier_tree public_data_tree " "$STATE_MEMBERS"
REF_CPP="$(cat "$M14_TREE/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.cpp" 2>/dev/null)"
assert_contains "create_checkpoint pushes the WHOLE State" "checkpoints_.push(state_);" "$REF_CPP"
assert_contains "and revert_checkpoint assigns the whole State back" "state_ = checkpoints_.top();" "$REF_CPP"
assert_eq "with no per-tree special case anywhere in the checkpoint methods" "0" \
  "$(printf '%s\n' "$REF_CPP" \
     | awk '/^void MemoryMerkleDB::create_checkpoint/,/^uint32_t MemoryMerkleDB::get_checkpoint_id/' \
     | grep -cE 'state_\.(archive|note_hash|nullifier|public_data|l1_to_l2)')"
note "the archive is checkpointed because of WHERE it lives, not because of code that says so"

echo
echo "== B. upstream's own gate, driving a REAL WorldState in lockstep =="
RUNDIR="$M14_WORK/checkpoints"; mkdir -p "$RUNDIR"
m6_in_devshell '
  export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
  "$1" --gtest_filter="$2.ArchiveParticipatesInCheckpoints:$2.Checkpoints"
' "$M14_EXT_WORLD_STATE_TESTS" "$M14_GATE_SUITE" >"$RUNDIR/cp.out" 2>"$RUNDIR/cp.err"
CP_RC=$?
assert_eq "the two checkpoint cases exit 0" "0" "$CP_RC"
assert_eq "and exactly two ran" "2" "$(grep -c '^\[ RUN      \]' "$RUNDIR/cp.out")"
assert_eq "both passed" "2" "$(grep -c '^\[       OK \]' "$RUNDIR/cp.out")"
assert_eq "none failed" "0" "$(grep -c '^\[  FAILED  \]' "$RUNDIR/cp.out")"
for t in ArchiveParticipatesInCheckpoints Checkpoints; do
  assert_contains "and $t is one of them, by name" "$M14_GATE_SUITE.$t" "$(cat "$RUNDIR/cp.out")"
done
GATE="$(cat "$M14_TREE/barretenberg/cpp/src/barretenberg/world_state/memory_merkle_db.test.cpp" 2>/dev/null)"
CP_CASE="$(printf '%s\n' "$GATE" | awk '/ArchiveParticipatesInCheckpoints\)/{f=1} f{print} f&&/^\}$/{exit}')"
assert_contains "that case checkpoints the REAL world state too" \
  "ws->checkpoint(world_state::CANONICAL_FORK_ID);" "$CP_CASE"
assert_contains "reverts it" "ws->revert_checkpoint(world_state::CANONICAL_FORK_ID);" "$CP_CASE"
assert_contains "commits it" "ws->commit_checkpoint(world_state::CANONICAL_FORK_ID);" "$CP_CASE"
assert_contains "and requires the archive to have MOVED inside, so the restore is not two copies of one state" \
  "EXPECT_NE(inside.archive_tree.root, genesis.archive_tree.root);" "$CP_CASE"

echo
echo "== C. the three states, as numbers, from the probe =="
G_ROOT="$(m14_key "$EXT_OUT" genesis.archive_tree.root)"
G_SIZE="$(m14_key "$EXT_OUT" genesis.archive_tree.size)"
I_ROOT="$(m14_key "$EXT_OUT" checkpoint.inside.archive_tree.root)"
I_SIZE="$(m14_key "$EXT_OUT" checkpoint.inside.archive_tree.size)"
R_ROOT="$(m14_key "$EXT_OUT" checkpoint.after_revert.archive_tree.root)"
R_SIZE="$(m14_key "$EXT_OUT" checkpoint.after_revert.archive_tree.size)"

assert_eq "the checkpoint id inside is 1" "1" "$(m14_key "$EXT_OUT" checkpoint.id_inside)"
assert_eq "and 0 again after the revert" "0" "$(m14_key "$EXT_OUT" checkpoint.id_after_revert)"
assert_eq "genesis archive size" "1" "$G_SIZE"
assert_eq "inside the checkpoint the archive has grown" "2" "$I_SIZE"
assert_eq "the probe reports that the root moved inside" "1" "$(m14_key "$EXT_OUT" checkpoint.archive_moved_inside)"
assert_false "and the two roots really are different values" test "$I_ROOT" = "$G_ROOT"
assert_eq "after the revert the archive root is back" "$G_ROOT" "$R_ROOT"
assert_eq "and so is its size" "$G_SIZE" "$R_SIZE"
assert_eq "every tree came back, not only the archive" "1" "$(m14_key "$EXT_OUT" checkpoint.everything_restored)"
# The note-hash tree moved inside the checkpoint too, so "everything came back" is a statement about
# more than one tree returning to a value it never left.
assert_eq "the note-hash tree had also moved inside" "1" "$(m14_key "$EXT_OUT" checkpoint.inside.note_hash_tree.size)"
assert_eq "and it came back to zero" "0" "$(m14_key "$EXT_OUT" checkpoint.after_revert.note_hash_tree.size)"

echo
echo "== D. and a COMMITTED checkpoint keeps it =="
assert_eq "the checkpoint id is 0 after the commit" "0" "$(m14_key "$EXT_OUT" checkpoint.id_after_commit)"
assert_eq "the state after the commit is the state that was inside it" "1" \
  "$(m14_key "$EXT_OUT" checkpoint.commit_preserved)"
assert_eq "the archive kept the leaf written inside the committed checkpoint" "2" \
  "$(m14_key "$EXT_OUT" checkpoint.after_commit.archive_tree.size)"
assert_false "and its root is not the genesis root" \
  test "$(m14_key "$EXT_OUT" checkpoint.after_commit.archive_tree.root)" = "$G_ROOT"

finish
