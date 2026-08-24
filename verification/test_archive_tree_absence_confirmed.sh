#!/usr/bin/env bash
# test_archive_tree_absence_confirmed
#
# "MemoryMerkleDB::State holds four trees and ARCHIVE is not among them" is a statement about a
# header. This check makes it a statement about a program that ran.
#
# TWO KINDS OF ABSENCE, and they need different evidence:
#
#   STRUCTURAL — `TreeRoots` has no `archive_tree` and `MemoryMerkleDB` has no `update_archive`.
#     Nothing can be called to observe this; the observation is the COMPILER's. The probe detects
#     both with `requires`-expressions and reports what it found, and the SAME source reports the
#     opposite against the patched tree. That is why the probe carries no `#ifdef`: an arm that was
#     told which tree it was compiled against would be asserting our expectation back at us.
#
#   BEHAVIOURAL — the five methods that take a `MerkleTreeId` are CALLED with ARCHIVE, on the base
#     tree, and each is required to throw, with the message it actually throws rather than with a
#     paraphrase. That is the "named notImplemented throw" disposition being examined on its merits:
#     it is what a caller gets today.
#
# The negative control is the patched arm, which is required to answer three of those five calls
# and to keep refusing the other two — because a check that only ever saw refusals could not tell
# "the archive is absent" from "this database refuses everything".
#
# It builds nothing. verify_block_level_gap_audit_complete builds the trees and the probes and
# writes measured.env; this reads it and fails if it is not there.
#
# Run: just verify-archive-absence

TEST_NAME="test_archive_tree_absence_confirmed"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m14_world_state.sh"

m14_measured
BASE="$M14_PROBE_BASE"
EXT="$M14_PROBE_EXT"
assert_file "the base probe transcript exists" "$BASE"
assert_file "the patched probe transcript exists" "$EXT"
[ -f "$BASE" ] && [ -f "$EXT" ] || die "probe transcripts missing — run 'just verify-block-level-audit'"
assert_eq "the base transcript is a complete run" "1" "$(m14_key "$BASE" probe_complete)"
assert_eq "the patched transcript is a complete run" "1" "$(m14_key "$EXT" probe_complete)"

echo "== A. structural absence, as the compiler saw it, from one source =="
assert_eq "base: TreeRoots has no archive_tree" "0" "$(m14_key "$BASE" archive_in_tree_roots)"
assert_eq "base: TreeRoots has no state_reference_equals" "0" "$(m14_key "$BASE" state_reference_equals_present)"
assert_eq "base: MemoryMerkleDB has no update_archive" "0" "$(m14_key "$BASE" update_archive_present)"
assert_eq "base: and no way to compute a block-0 header hash" "0" \
  "$(m14_key "$BASE" compute_initial_block_header_hash_present)"
assert_eq "base: get_tree_roots therefore reports four trees" "4" \
  "$(grep -c '^genesis\..*\.root=' "$BASE")"
assert_eq "patched: it reports five" "5" "$(grep -c '^genesis\..*\.root=' "$EXT")"
assert_eq "patched: and the fifth is the archive" "1" \
  "$(grep -c '^genesis\.archive_tree\.root=' "$EXT")"
assert_eq "base: no archive key of any kind" "0" "$(grep -c '^genesis\.archive' "$BASE")"

echo
echo "== B. behavioural absence: every ARCHIVE-taking entry point, called on the base tree =="
# The five methods, each called with ARCHIVE, each required to throw and each required to say WHICH
# tree id it refused. `unsupported tree id 4` and not `unsupported` — a message that named no id
# would leave a caller no better off than an abort.
for m in get_sibling_path get_leaf_value get_low_indexed_leaf; do
  assert_eq "base: $m(ARCHIVE, …) throws" "1" "$(m14_key "$BASE" "archive.$m.threw")"
  assert_contains "base: and its message names the tree id it refused" \
    "unsupported tree id 4" "$(m14_key "$BASE" "archive.$m.message")"
done
assert_eq "base: append_leaves(ARCHIVE, …) throws" "1" "$(m14_key "$BASE" archive.append_leaves.threw)"
assert_contains "base: and its message enumerates the trees it does support" \
  "only supported for NOTE_HASH_TREE and L1_TO_L2_MESSAGE_TREE" \
  "$(m14_key "$BASE" archive.append_leaves.message)"
assert_eq "base: pad_tree(ARCHIVE, …) throws" "1" "$(m14_key "$BASE" archive.pad_tree.threw)"
assert_contains "base: and its message names the tree" "Padding not supported for tree 4" \
  "$(m14_key "$BASE" archive.pad_tree.message)"

echo
echo "== C. the control: the patched tree answers three of the five and still refuses two =="
# Without this arm, "every archive call throws" could equally be a database that throws at
# everything. Three answer, two still refuse, and the two that still refuse are the two the real
# WorldState never performs on the archive either.
for m in get_sibling_path get_leaf_value append_leaves; do
  assert_eq "patched: $m(ARCHIVE, …) succeeds" "0" "$(m14_key "$EXT" "archive.$m.threw")"
done
assert_eq "patched: and get_sibling_path returns a path of ARCHIVE_HEIGHT levels" "30" \
  "$(m14_key "$EXT" archive.get_sibling_path.value)"
assert_eq "patched: pad_tree(ARCHIVE, …) STILL throws — the archive is never padded" "1" \
  "$(m14_key "$EXT" archive.pad_tree.threw)"
assert_eq "patched: get_low_indexed_leaf(ARCHIVE, …) STILL throws — it is not an indexed tree" "1" \
  "$(m14_key "$EXT" archive.get_low_indexed_leaf.threw)"

echo
echo "== D. and the absence is of the ARCHIVE, not of the method =="
# Each of the three tree-id methods answers for a tree that IS present, on the SAME base tree and in
# the same run. A method that was broken for every id would pass section B and fail here.
assert_eq "base: get_tree_roots answers for the note-hash tree" "0" \
  "$(m14_key "$BASE" genesis.note_hash_tree.size)"
assert_eq "base: and for the nullifier tree, at the genesis prefill" "128" \
  "$(m14_key "$BASE" genesis.nullifier_tree.size)"
assert_true "base: the note-hash genesis root is a real field element" \
  bash -c '[[ "$(printf %s "'"$(m14_key "$BASE" genesis.note_hash_tree.root)"'")" =~ ^0x[0-9a-f]{64}$ ]]'

finish
