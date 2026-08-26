#!/usr/bin/env bash
# test_tree_snapshot_vocabulary_reused_not_redefined — one vocabulary, and one decision beside it.
#
# The verification entry: "The facade's state reference uses world_state_reference's TreeSnapshot
# rather than a parallel type, and the separate carrier for full export and import is recorded as a
# distinct decision."
#
# TWO CLAIMS, AND THEY FAIL FOR DIFFERENT REASONS. The first is an ABSENCE — no parallel type — and
# an absence needs a haystack that could have contained it and a control that the scanner works.
# The second is a DECISION, and a decision is only recorded if it names what was rejected and why;
# "we built one" is not a decision, it is an outcome.
#
# THE PARTIAL ANSWER THE MILESTONE ALREADY HAD IS RE-DERIVED, not quoted. `get_snapshot()` returns
# `{root, next_available_leaf_index}` — read out of the fork — and that is a SUMMARY. The rest of
# the answer is what carries a whole state, and the search for one is asserted in the direction
# that would settle it: `world_state::WorldState` has no export API, `TreeSnapshot` is the only
# `*Snapshot*` type in the three C++ tree directories, and upstream's real carrier copies LMDB
# files behind `@aztec/native`.
#
# Run: just verify-chain-snapshot-vocabulary

TEST_NAME="test_tree_snapshot_vocabulary_reused_not_redefined"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit
m23_require_anchor
m23_require_packages

DOC="$(cat "$M23_DOC")"

# ---------------------------------------------------------------------------
# PART 1 — the summary, re-derived from the fork
# ---------------------------------------------------------------------------
echo "== world_state_reference's TreeSnapshot is a summary, and that is read not quoted"

WSR="$(m23_anchor_file barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp)"
assert_true "it declares a TreeSnapshot" str_has_line "$WSR" "struct TreeSnapshot {"
assert_true "…whose first field is a root" str_has_line "$WSR" "    FF root = 0;"
assert_true "…and whose second is a leaf index" \
  str_has_line "$WSR" "    uint64_t next_available_leaf_index = 0;"
# TWO FIELDS AND NO MORE: the count is what makes it a summary rather than a state.
BODY="$(printf '%s\n' "$WSR" | awk '/^struct TreeSnapshot \{/,/^\};/')"
N_FIELDS="$(printf '%s\n' "$BODY" | grep -cE '^    [A-Za-z_][A-Za-z0-9_:<> ]* [a-z_]+ = ' || true)"
assert_eq "TreeSnapshot has exactly two data fields" "2" "$N_FIELDS"
assert_true "…and get_snapshot returns one" str_has_sub "$WSR" "TreeSnapshot get_snapshot()"

echo "== and it is the ONLY *Snapshot* type in the three C++ tree directories"
SNAP_TYPES="$(git -C "$FORK_ROOT" grep -hE '^(struct|class) [A-Za-z_]*Snapshot[A-Za-z_]*' "$M23_CPP_ANCHOR" \
  -- barretenberg/cpp/src/barretenberg/world_state/ \
     barretenberg/cpp/src/barretenberg/world_state_reference/ \
     barretenberg/cpp/src/barretenberg/crypto/merkle_tree/ \
  | sed -E 's/^(struct|class) ([A-Za-z_]+).*/\2/' | sort -u)"
assert_eq "there is exactly one" "TreeSnapshot" "$SNAP_TYPES"
# THE HAYSTACK IS NOT EMPTY AND COULD HAVE ANSWERED OTHERWISE: the three directories exist and the
# same scanner finds plenty of OTHER struct and class declarations in them.
N_TYPES="$(git -C "$FORK_ROOT" grep -hE '^(struct|class) [A-Za-z_]+' "$M23_CPP_ANCHOR" \
  -- barretenberg/cpp/src/barretenberg/world_state/ \
     barretenberg/cpp/src/barretenberg/world_state_reference/ \
     barretenberg/cpp/src/barretenberg/crypto/merkle_tree/ | grep -c . || true)"
assert_ge "…and the same scanner finds many other types in the same directories" 15 "$N_TYPES"

# ---------------------------------------------------------------------------
# PART 2 — the facade uses upstream's vocabulary and declares no parallel type
# ---------------------------------------------------------------------------
echo "== the state reference is @aztec/stdlib's, imported"

CHAIN="$(cat "$ORCH_SRC/chain.ts")"
RUNTIME="$(cat "$ORCH_SRC/avm_runtime.ts")"

assert_true "chain.ts imports AppendOnlyTreeSnapshot from @aztec/stdlib" \
  str_has_sub "$CHAIN" "import type { AppendOnlyTreeSnapshot } from '@aztec/stdlib/trees';"
assert_true "…and StateReference too" str_has_sub "$CHAIN" "StateReference, Tx } from '@aztec/stdlib/tx'"
assert_true "the facade's archive() returns upstream's AppendOnlyTreeSnapshot" \
  str_has_sub "$RUNTIME" "archive(): AppendOnlyTreeSnapshot {"
assert_true "…and stateReference() returns upstream's StateReference" \
  str_has_sub "$RUNTIME" "stateReference(): Promise<StateReference> {"

echo "== and no parallel snapshot or state-reference type is declared by us"
# The needle is a DECLARATION, and the four names are the ones a parallel type would plausibly
# take. `TreeSnapshot` itself is included: declaring it here would be the exact mistake.
PARALLEL=""
for name in TreeSnapshot TreeRoots StateRef ChainStateReference AppendOnlyTreeSnapshot; do
  hits="$(grep -rn -E "^\s*(export )?(interface|class|type) $name\b" "$ORCH_SRC" "$REPO_ROOT/node-host/src" || true)"
  [ -n "$hits" ] && PARALLEL="$PARALLEL $name"
done
assert_eq "none of the five parallel-type names is declared by us" "" "$PARALLEL"
# THE CONTROL: the same matcher DOES find a type we do declare, so the absence is not the matcher
# failing to match anything at all.
assert_true "…and the same matcher finds our own ChainBlock declaration" \
  test -n "$(grep -rn -E '^\s*export interface ChainBlock\b' "$ORCH_SRC" || true)"

# The four-tree state reference the chain reports is upstream's own encoding, not a shape of ours:
# `StateReference.toBuffer()`, 288 hex characters. Read out of one arm rather than asserted.
STATE="$(m23_arm emptyBlocks blocks.0.stateReference)"
assert_eq "the recorded state reference is upstream's 144-byte encoding" "288" "${#STATE}"

# ---------------------------------------------------------------------------
# PART 3 — the export carrier is a DISTINCT decision with a rejection reason
# ---------------------------------------------------------------------------
echo "== the carrier for a full export is recorded as a separate decision"

INV="$REPO_ROOT/REUSE-INVENTORY.md"
assert_true "RI-71 exists and is about a chain snapshot's carrier" \
  grep -q '^### RI-71 — A chain snapshot' "$INV"
ENTRY="$(awk '/^### RI-71 — /,/^### RI-72 — |^---$/' "$INV")"
assert_ge "…and it is a substantial entry" 6 "$(printf '%s\n' "$ENTRY" | grep -c .)"

DEC="$(printf '%s\n' "$ENTRY" | sed -n 's/^- decision:[ ]*//p')"
assert_eq "its decision is build" "build" "$DEC"
RR="$(printf '%s\n' "$ENTRY" | sed -n 's/^- rejection-reason:[ ]*//p')"
assert_prefix "…with an admissible tagged rejection reason" "cannot-reach-target:" "$RR"
assert_true "…naming upstream's actual carrier" str_has_sub "$RR" "backupTo"
assert_true "…and the mechanism it uses" str_has_sub "$RR" "copyStores"
assert_true "…and why it cannot come here" str_has_sub "$RR" "@aztec/native"

echo "== and the rejection's own searches are re-derived here"

# (a) `world_state::WorldState` has no export API. Asserted against a haystack that DOES contain
#     the checkpoint and fork methods, so the absence is about export and not about the file.
WS="$(m23_anchor_file barretenberg/cpp/src/barretenberg/world_state/world_state.hpp)"
assert_true "WorldState declares create_fork" str_has_sub "$WS" "create_fork("
assert_true "…and checkpoint" str_has_sub "$WS" "uint32_t checkpoint("
for absent in "serialize(" "dump(" "export_state(" "to_buffer("; do
  assert_false "…and NOT $absent" str_has_sub "$WS" "$absent"
done

# (b) Upstream's real carrier, in the TypeScript world-state package.
NWS="$(git -C "$FORK_ROOT" show "$M23_CPP_ANCHOR:yarn-project/world-state/src/native/native_world_state.ts" 2>/dev/null || true)"
assert_true "NativeWorldStateService really does have backupTo" str_has_sub "$NWS" "backupTo("
assert_true "…which calls copyStores" str_has_sub "$NWS" "copyStores("
assert_false "…and a method it does not have is not found by the same lookup" \
  str_has_sub "$NWS" "exportToBuffer("

# (c) Nothing serialises a tree's leaves to a portable blob.
FMT="$(git -C "$FORK_ROOT" show "$M23_CPP_ANCHOR:yarn-project/foundation/src/trees/merkle_tree.ts" 2>/dev/null || true)"
assert_true "foundation's MerkleTree exposes its leaves" str_has_sub "$FMT" "get leaves()"
assert_false "…but has no toBuffer" str_has_sub "$FMT" "toBuffer()"

echo "== the document records the two questions separately"
assert_true "CHAIN-LOOP.md separates the reference from the carrier" \
  str_has_sub "$DOC" "what carries a full state"
assert_true "…and states the carrier decision" \
  str_has_sub "$DOC" "**DECISION: the carrier is a REPLAY LOG"
assert_true "…and states its cost rather than hiding it" \
  str_has_sub "$DOC" "a replay re-executes"

m23_finish
