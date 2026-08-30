#!/usr/bin/env bash
# test_historical_block_zero_read_returns_genesis
#
# The milestone conditions this one on "if block-pinned reads are needed". **They are not**, and
# this check is what makes that a settled disposition instead of an omission. It has three jobs, and
# a skip is not one of them.
#
#   1. Establish, BY EXECUTION, that the reference has no block-pinned view to get wrong: no method
#      of `world_state_reference::MemoryMerkleDB` and none of the fourteen on
#      `LowLevelMerkleDBInterface` takes a `WorldStateRevision`, and the compiled artefact agrees
#      with the declaration — `nm` over the built library finds the symbol in `world_state`'s
#      objects and not in the reference's. A reference that holds exactly one view cannot return the
#      tip for a genesis-anchored read, because it cannot be asked.
#
#   2. Establish, BY EXECUTION, that the sentinel behaves as its own comment claims. The vocabulary
#      is DEFINED in the reference component, so this is the reference's contract to keep even
#      though the reference does not consume it: `LATEST` is max(uint32) and not 0, a default
#      revision is NOT historical, and a revision pinned to block 0 IS. That is the regression the
#      sentinel exists to prevent, run rather than read.
#
#   3. Establish, BY EXECUTION, that the implementation which DOES have block-pinned views honours
#      them — upstream's own `world_state_tests`, three cases run by name, in which a view taken at
#      block 0 does not follow the canonical tip. Those are upstream's tests, not ours.
#
# AND THE REASON THE DISPOSITION IS "NOT NEEDED", which is a claim about upstream's code and is
# re-derived here rather than asserted: the only block-pinned archive read in the block pipeline is
# an archive MEMBERSHIP WITNESS for a historical block hash, taken in
# `prover-client/src/orchestrator/block-building-helpers.ts`, and it is on the private-kernel side.
# Public execution — which is all this campaign's wasm AVM performs — never takes one, and the AVM's
# own host interface has no revision parameter to carry one.
#
# Run: just verify-block-zero-read

TEST_NAME="test_historical_block_zero_read_returns_genesis"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m14_world_state.sh"

m14_measured
EXT_OUT="$M14_PROBE_EXT"; BASE_OUT="$M14_PROBE_BASE"
assert_file "the patched probe transcript exists" "$EXT_OUT"
assert_file "the base probe transcript exists" "$BASE_OUT"
assert_file "the patched world_state_tests exists" "$M14_EXT_WORLD_STATE_TESTS"
[ -f "$EXT_OUT" ] && [ -x "$M14_EXT_WORLD_STATE_TESTS" ] || die "inputs missing — run 'just verify-block-level-audit'"

FORK_SHOW() { git -C "$FORK_ROOT" show "$M6_BASE_REV:$1" 2>/dev/null; }

echo "== A. the sentinel, executed =="
assert_eq "WorldStateRevision::LATEST is max(uint32) and not 0" "4294967295" \
  "$(m14_key "$EXT_OUT" revision_latest)"
assert_eq "a default revision is NOT historical" "0" "$(m14_key "$EXT_OUT" revision_default_is_historical)"
assert_eq "a revision pinned to block 0 IS historical" "1" "$(m14_key "$EXT_OUT" revision_block0_is_historical)"
assert_eq "committed() excludes uncommitted state" "0" "$(m14_key "$EXT_OUT" revision_committed_includes_uncommitted)"
assert_eq "uncommitted() includes it" "1" "$(m14_key "$EXT_OUT" revision_uncommitted_includes_uncommitted)"
# The same four on the BASE tree, because the vocabulary is the anchor's and M14's patch must not
# have moved it.
for k in revision_latest revision_default_is_historical revision_block0_is_historical; do
  assert_eq "unchanged by M14's patch: $k" "$(m14_key "$BASE_OUT" "$k")" "$(m14_key "$EXT_OUT" "$k")"
done
assert_contains "and the sentinel's own comment states the regression it exists to prevent" \
  "genesis-anchored witnesses would return the current tip instead of genesis" \
  "$(FORK_SHOW barretenberg/cpp/src/barretenberg/world_state_reference/merkle_tree_id.hpp)"

echo
echo "== B. the reference has no block-pinned view to get wrong =="
REF_HPP="$(cat "$M14_TREE/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp" 2>/dev/null)"
CLASS_BLOCK="$(printf '%s\n' "$REF_HPP" | awk '/^class MemoryMerkleDB \{/{f=1} f{print} f&&/^\};/{exit}')"
assert_ge "the reference declares a real method surface" 12 \
  "$(printf '%s\n' "$CLASS_BLOCK" | grep -cE '^\s+[A-Za-z].*\(.*\)( const)?;$')"
assert_eq "and NONE of those declarations mentions WorldStateRevision" "0" \
  "$(printf '%s\n' "$CLASS_BLOCK" | grep -cE '\bWorldStateRevision\b')"
assert_eq "M14's patch did not add one" "0" \
  "$(git -C "$M14_TREE" diff "$M6_BASE_REV" HEAD -- \
       barretenberg/cpp/src/barretenberg/world_state_reference/ | grep -cE '^\+.*\bWorldStateRevision\b')"

# The compiled artefact, not the header: `nm` over the two libraries the same build produced.
LIBDIR="$M14_TREE/barretenberg/cpp/$M14_NATIVE_BUILD/lib"
assert_file "the reference library was built" "$LIBDIR/libworld_state_reference.a"
assert_file "and the real world state's library beside it" "$LIBDIR/libworld_state.a"
NM_OUT="$M14_WORK/nm.txt"
m6_in_devshell '
  nm -C --defined-only "$1/libworld_state_reference.a" 2>/dev/null | sed "s/^/REF /"
  nm -C --defined-only "$1/libworld_state.a" 2>/dev/null | sed "s/^/WS /"
' "$LIBDIR" >"$NM_OUT" 2>"$NM_OUT.err"
assert_ge "nm produced symbols" 100 "$(grep -c . "$NM_OUT")"
assert_eq "no symbol of the reference library mentions WorldStateRevision" "0" \
  "$(grep '^REF ' "$NM_OUT" | grep -cE '\bWorldStateRevision\b')"
assert_ge "while the real world state's library is full of them" 10 \
  "$(grep '^WS ' "$NM_OUT" | grep -cE '\bWorldStateRevision\b')"
assert_ge "and the reference library does define MemoryMerkleDB symbols, so the comparison is not vacuous" 10 \
  "$(grep '^REF ' "$NM_OUT" | grep -cE 'world_state::MemoryMerkleDB::')"

echo
echo "== C. the implementation that DOES have them honours block 0 — upstream's own tests =="
RUNDIR="$M14_WORK/blockzero"; mkdir -p "$RUNDIR"
FILTER="$(printf '%s' "$M14_BLOCK_ZERO_TESTS" | tr '\n' ':')"
m6_in_devshell '
  export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
  "$1" --gtest_filter="$2"
' "$M14_EXT_WORLD_STATE_TESTS" "$FILTER" >"$RUNDIR/bz.out" 2>"$RUNDIR/bz.err"
BZ_RC=$?
assert_eq "the block-0 cases exit 0" "0" "$BZ_RC"
assert_eq "and exactly three ran" "$M14_BLOCK_ZERO_TEST_COUNT" "$(grep -c '^\[ RUN      \]' "$RUNDIR/bz.out")"
assert_eq "all three passed" "$M14_BLOCK_ZERO_TEST_COUNT" "$(grep -c '^\[       OK \]' "$RUNDIR/bz.out")"
assert_eq "none failed" "0" "$(grep -c '^\[  FAILED  \]' "$RUNDIR/bz.out")"
for t in $M14_BLOCK_ZERO_TESTS; do
  assert_contains "ran by name: $t" "$t" "$(cat "$RUNDIR/bz.out")"
done
# And the case that carries the property, read out of the fork: a fork taken at block 0 must NOT
# follow the canonical tip.
WS_TEST="$(FORK_SHOW barretenberg/cpp/src/barretenberg/world_state/world_state.test.cpp)"
BZ_CASE="$(printf '%s\n' "$WS_TEST" | awk '/ForkingAtBlock0AndAdvancingCanonicalState\)/{f=1} f{print} f&&/^\}$/{exit}')"
assert_contains "the case forks at block 0" "ws.create_fork(0);" "$BZ_CASE"
assert_contains "advances the canonical archive" \
  "ws.append_leaves<bb::fr>(MerkleTreeId::ARCHIVE, { fr(1) });" "$BZ_CASE"
assert_contains "and requires the two views to DIFFER afterwards" \
  "EXPECT_NE(fork_archive_state_after_insert.meta, canonical_archive_state_after_insert.meta);" "$BZ_CASE"
assert_contains "with the block-0 view keeping its own leaf" \
  "MerkleTreeId::ARCHIVE, 1, 2);" "$BZ_CASE"

echo
echo "== D. why the disposition is 'not needed', re-derived rather than asserted =="
HELPERS="$(FORK_SHOW yarn-project/prover-client/src/orchestrator/block-building-helpers.ts)"
assert_contains "the only archive membership witness in the block pipeline is for a historical block hash" \
  "getMembershipWitnessFor(blockHash.toFr(), MerkleTreeId.ARCHIVE, ARCHIVE_HEIGHT, db)" "$HELPERS"
# It is on the private side: it feeds a base-rollup input, not public execution.
#
# And there is nothing in vm2 to pin a revision TO. `\bARCHIVE\b` matches two lines there, both in
# one tree-name switch — the `case` label and the `return` under it — so both are excluded by their
# own text and what remains must be nothing. The first form of this excluded only the `return` and
# reported the label as a read, which was a true count of the wrong thing.
VM2_ARCHIVE_READS="$(git -C "$FORK_ROOT" grep -E '(^|[^[:alnum:]_])ARCHIVE([^[:alnum:]_]|$)' "$M6_BASE_REV" -- \
      'barretenberg/cpp/src/barretenberg/vm2/*' 2>/dev/null \
     | grep -v '\.test\.cpp' \
     | grep -v 'case world_state::MerkleTreeId::ARCHIVE:' \
     | grep -v 'return "ARCHIVE";')"
assert_eq "and vm2 has no archive read at all to pin, only the two lines of a name switch" "0" \
  "$(printf '%s\n' "$VM2_ARCHIVE_READS" | grep -c .)"
DB_HPP="$(FORK_SHOW barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/db.hpp)"
assert_eq "and the AVM's host interface has no revision parameter to carry one" "0" \
  "$(printf '%s\n' "$DB_HPP" | grep -cE '\bWorldStateRevision\b')"

DOC="$(cat "$M14_WRITEUP" 2>/dev/null)"
assert_contains "WORLD-STATE.md records the disposition" "DECISION: not needed" "$DOC"
assert_contains "and names what would change it" "block-pinned" "$DOC"

finish
