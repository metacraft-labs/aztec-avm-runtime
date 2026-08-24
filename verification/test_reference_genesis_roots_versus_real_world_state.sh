#!/usr/bin/env bash
# test_reference_genesis_roots_versus_real_world_state
#
# M14's genesis deliverable, settled by comparison rather than by assumption.
#
# THE QUESTION THE MILESTONE ASKS. `DEFAULT_NULLIFIER_TREE_PREFILL` and
# `DEFAULT_PUBLIC_DATA_TREE_PREFILL` are both 128, matching the design document — but the source
# comment at the anchor says they match "the values the WorldState is initialized with IN THE
# FUZZER", and `pad_tree` pads with empty leaves rather than inserting protocol-contract leaves. So:
# do the resulting roots agree with the real world state's, and is the 128 a fuzzer's configuration
# or the protocol's?
#
# THREE INDEPENDENT WITNESSES, and the point of using three is that agreement between two of them
# could be one value copied twice:
#
#   1. the REFERENCE, run — the probe's genesis section, produced by executing MemoryMerkleDB;
#   2. UPSTREAM'S OWN published expectations — `world_state.test.cpp`'s
#      GetInitialTreeInfoForAllTrees, read live out of the fork at the anchor with `git show`, and
#      GENESIS_ARCHIVE_ROOT / GENESIS_BLOCK_HEADER_HASH read TWICE: from
#      `noir-projects/.../constants.nr`, which is in git, and from the generated
#      `aztec/aztec_constants.hpp` the C++ actually compiled against, which is NOT — it is
#      gitignored and produced at configure time by `scripts/remake-constants.sh`, and the first
#      version of this check tried to `git show` it and silently got an empty string;
#   3. TIER D — fixtures/trees/world-state-vectors.json, captured from `@aztec/world-state`'s
#      NativeWorldStateService, the production LMDB world state, driven from TypeScript.
#
# THE ANSWER IS RECORDED AS A FACT EITHER WAY. The four StateReference trees agree, and that half
# was already M8's; what M14 adds is the FIFTH tree, where the base tree has nothing to compare and
# the patched tree agrees with both other witnesses, and the finding about the 128.
#
# THE FINDING. The 128 is not the fuzzer's. @aztec/world-state defines
# INITIAL_NULLIFIER_TREE_SIZE = 2 * MAX_NULLIFIERS_PER_TX and
# INITIAL_PUBLIC_DATA_TREE_SIZE = 2 * MAX_TOTAL_PUBLIC_DATA_UPDATE_REQUESTS_PER_TX, and both of
# those protocol constants are 64. The source comment is narrower than the truth, which is a
# comment-drift finding (DRIFT D13) and is the reason the patch restates the constants in the form
# they are derived in.
#
# Run: just verify-genesis-versus-world-state

TEST_NAME="test_reference_genesis_roots_versus_real_world_state"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m14_world_state.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is required to read the Tier D vectors"
m14_measured
BASE="$M14_PROBE_BASE"; EXT="$M14_PROBE_EXT"
assert_file "the base probe transcript exists" "$BASE"
assert_file "the patched probe transcript exists" "$EXT"
assert_file "the Tier D capture exists" "$M14_TIER_D"
[ -f "$BASE" ] && [ -f "$EXT" ] && [ -f "$M14_TIER_D" ] || die "inputs missing"

tierd() { # <TREE_ID> <root|size>
  python3 -c "
import json,sys
d=json.load(open('$M14_TIER_D'))['upstreamPublished']['genesisTrees']['$1']
print(d['$2'])"
}

FORK_SHOW() { git -C "$FORK_ROOT" show "$M6_BASE_REV:$1" 2>/dev/null; }

echo "== A. the prefill is the PROTOCOL's, not the fuzzer's =="
# TWO sources, because `aztec/aztec_constants.hpp` is gitignored and generated at configure time —
# it is what the C++ compiled against, but it is not in the repository, and a check that reached for
# it with `git show` got nothing. The generated header is read from the built worktree; the protocol
# source, `noir-projects/.../constants.nr`, is read from git at the anchor; and the two are required
# to agree on the derivation as well as on the value.
MAXNULL="$(m14_generated_constant "$M14_BASE_TREE" MAX_NULLIFIERS_PER_TX)"
MAXPD="$(m14_generated_constant "$M14_BASE_TREE" MAX_TOTAL_PUBLIC_DATA_UPDATE_REQUESTS_PER_TX)"
assert_eq "MAX_NULLIFIERS_PER_TX, from the header the build compiled against" "64" "$MAXNULL"
assert_eq "MAX_TOTAL_PUBLIC_DATA_UPDATE_REQUESTS_PER_TX, likewise" "64" "$MAXPD"
assert_eq "and the same value is what the AVM's own binaries carry" "$MAXNULL" \
  "$(m14_key "$BASE" max_nullifiers_per_tx)"
assert_eq "and likewise for the public-data one" "$MAXPD" \
  "$(m14_key "$BASE" max_total_public_data_update_requests_per_tx)"
# The protocol source derives both from a subtree height rather than writing 64, which is why
# restating the prefill as 2 * the constant keeps it tied to the protocol rather than to a literal.
assert_eq "the protocol source derives MAX_NULLIFIERS_PER_TX from the nullifier subtree height" \
  "1<<NULLIFIER_SUBTREE_HEIGHT" "$(m14_noir_constant MAX_NULLIFIERS_PER_TX)"
assert_eq "and that height is 6" "6" "$(m14_noir_constant NULLIFIER_SUBTREE_HEIGHT)"
assert_eq "so 1 << 6 is the 64 the header carries" "$MAXNULL" "$((1 << $(m14_noir_constant NULLIFIER_SUBTREE_HEIGHT)))"

TS_SIZES="$(FORK_SHOW yarn-project/world-state/src/world-state-db/merkle_tree_db.ts)"
assert_contains "the production world state derives its nullifier initial size from the protocol constant" \
  "export const INITIAL_NULLIFIER_TREE_SIZE = 2 * MAX_NULLIFIERS_PER_TX;" "$TS_SIZES"
assert_contains "and its public-data initial size likewise" \
  "export const INITIAL_PUBLIC_DATA_TREE_SIZE = 2 * MAX_TOTAL_PUBLIC_DATA_UPDATE_REQUESTS_PER_TX;" "$TS_SIZES"

# The fuzzer's own literal, so "the fuzzer uses 128" is measured rather than assumed.
FUZZ_CTOR="$(FORK_SHOW barretenberg/cpp/src/barretenberg/avm_fuzzer/common/interfaces/dbs.cpp \
             | awk '/FuzzerWorldStateManager::FuzzerWorldStateManager/{f=1} f{print} f&&/^\{\}/{exit}')"
assert_contains "the fuzzer constructs the reference with 128 / 128" \
  "/*nullifier_tree_prefill=*/128, /*public_data_tree_prefill=*/128" "$FUZZ_CTOR"

# Four numbers that must all be the same 128: the protocol's, the fuzzer's, the reference's (from
# the probe, i.e. executed) and Tier D's captured genesis SIZE from the production world state.
assert_eq "2 * MAX_NULLIFIERS_PER_TX" "128" "$((2 * MAXNULL))"
assert_eq "the reference's DEFAULT_NULLIFIER_TREE_PREFILL, executed" "128" \
  "$(m14_key "$BASE" default_nullifier_prefill)"
assert_eq "Tier D's captured nullifier genesis size, from the production world state" "128" \
  "$(tierd NULLIFIER_TREE size)"
assert_eq "2 * MAX_TOTAL_PUBLIC_DATA_UPDATE_REQUESTS_PER_TX" "128" "$((2 * MAXPD))"
assert_eq "the reference's DEFAULT_PUBLIC_DATA_TREE_PREFILL, executed" "128" \
  "$(m14_key "$BASE" default_public_data_prefill)"
assert_eq "Tier D's captured public-data genesis size" "128" "$(tierd PUBLIC_DATA_TREE size)"
note "RECORDED AS A FACT: the 128 is 2x a protocol constant, and the anchor's comment calling it the fuzzer's is narrower than the truth (DRIFT D13)"

# And the patched tree states it that way, which is what stops the comment drifting again.
assert_eq "the patched tree derives the same 128 from the protocol constant" "128" \
  "$(m14_key "$EXT" default_nullifier_prefill)"
assert_contains "and says so in the source rather than in a comment" \
  "static constexpr size_t DEFAULT_NULLIFIER_TREE_PREFILL = 2 * MAX_NULLIFIERS_PER_TX;" \
  "$(cat "$M14_TREE/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp" 2>/dev/null)"

echo
echo "== B. the four StateReference trees: reference vs upstream's constants vs Tier D =="
# Upstream's own hardcoded genesis expectations, read live so a re-pin that moves them fails here
# instead of agreeing with a stale copy.
WS_TEST="$(FORK_SHOW barretenberg/cpp/src/barretenberg/world_state/world_state.test.cpp)"
for pair in "nullifier_tree:NULLIFIER_TREE" "note_hash_tree:NOTE_HASH_TREE" \
            "public_data_tree:PUBLIC_DATA_TREE" "l1_to_l2_message_tree:L1_TO_L2_MESSAGE_TREE"; do
  key="${pair%%:*}"; id="${pair##*:}"
  probe_root="$(m14_key "$BASE" "genesis.$key.root")"
  probe_size="$(m14_key "$BASE" "genesis.$key.size")"
  assert_eq "$id root: the reference and Tier D's production capture agree" \
    "$(tierd "$id" root)" "$probe_root"
  assert_eq "$id size: likewise" "$(tierd "$id" size)" "$probe_size"
  assert_contains "$id root: and upstream's own C++ test hardcodes the same value" \
    "$probe_root" "$WS_TEST"
  # The patched tree must produce the identical four, or the extension moved something it should not.
  assert_eq "$id root is unchanged by M14's patch" "$probe_root" "$(m14_key "$EXT" "genesis.$key.root")"
  assert_eq "$id size is unchanged by M14's patch" "$probe_size" "$(m14_key "$EXT" "genesis.$key.size")"
done

echo
echo "== C. the FIFTH tree, which is what M14 adds =="
ARCHIVE_TIERD_ROOT="$(tierd ARCHIVE root)"
ARCHIVE_TIERD_SIZE="$(tierd ARCHIVE size)"
assert_eq "Tier D captured an archive at genesis, with one leaf in it" "1" "$ARCHIVE_TIERD_SIZE"
assert_eq "base: the reference has no archive genesis to compare at all" "" \
  "$(m14_key "$BASE" genesis.archive_tree.root)"
assert_eq "patched: the reference's archive genesis size" "1" "$(m14_key "$EXT" genesis.archive_tree.size)"
assert_eq "patched: and its root equals Tier D's, from the production world state" \
  "$ARCHIVE_TIERD_ROOT" "$(m14_key "$EXT" genesis.archive_tree.root)"

# The third witness: upstream's own constant, and upstream's own test that checks it.
CONST_ARCHIVE="$(m14_generated_constant "$M14_TREE" GENESIS_ARCHIVE_ROOT)"
CONST_HEADER="$(m14_generated_constant "$M14_TREE" GENESIS_BLOCK_HEADER_HASH)"
# The protocol source is the third reading of the same two values, and it is in git.
assert_eq "GENESIS_ARCHIVE_ROOT agrees between the generated header and the protocol source" \
  "$(m14_noir_constant GENESIS_ARCHIVE_ROOT)" "$CONST_ARCHIVE"
assert_eq "GENESIS_BLOCK_HEADER_HASH likewise" \
  "$(m14_noir_constant GENESIS_BLOCK_HEADER_HASH)" "$CONST_HEADER"
assert_eq "GENESIS_ARCHIVE_ROOT, read out of the fork, equals Tier D's capture" \
  "$ARCHIVE_TIERD_ROOT" "$CONST_ARCHIVE"
assert_eq "and the probe reports the same constant" "$CONST_ARCHIVE" \
  "$(m14_key "$EXT" genesis_archive_root_constant)"
assert_contains "upstream's own C++ test checks the archive against that constant" \
  "EXPECT_EQ(info.meta.root, bb::fr(GENESIS_ARCHIVE_ROOT));" "$WS_TEST"
assert_contains "and the block-0 header hash against its own" \
  "MerkleTreeId::ARCHIVE, 0, bb::fr(GENESIS_BLOCK_HEADER_HASH)" "$WS_TEST"
assert_prefix "GENESIS_BLOCK_HEADER_HASH is a field element" "0x" "$CONST_HEADER"

# It is DERIVED, not stored. If the patched reference merely hardcoded the constant this comparison
# would still pass, so the discriminating statement is that changing any of the four genesis
# snapshots moves it — which is what the gate's own GenesisArchiveMatchesPublishedConstants asserts
# by recomputing the hash from the snapshots, and what mutation M1 (genesis timestamp 0 -> 1)
# demonstrated by failing all twelve cases.
REF_CPP="$(cat "$M14_TREE/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.cpp" 2>/dev/null)"
assert_not_contains "the patched reference does not hardcode GENESIS_ARCHIVE_ROOT" \
  "GENESIS_ARCHIVE_ROOT" "$REF_CPP"
assert_not_contains "nor GENESIS_BLOCK_HEADER_HASH" "GENESIS_BLOCK_HEADER_HASH" "$REF_CPP"
assert_contains "it computes the block-0 header hash from the genesis state reference" \
  "compute_initial_block_header_hash(get_tree_roots()" "$REF_CPP"
assert_contains "with the same generator point the WorldState uses" \
  "DOM_SEP__BLOCK_HEADER_HASH" \
  "$(cat "$M14_TREE/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp" 2>/dev/null)"

echo
echo "== D. pad_tree pads with EMPTY leaves, and that is what the real one does too =="
# The milestone flags this explicitly. The reference's pad_leaves writes FF::zero(); upstream's own
# equivalence gate pads the WorldState side by appending zero leaves and requires the roots to match,
# so "empty rather than protocol-contract leaves" is upstream's behaviour and not a shortcut.
GATE="$(cat "$M14_TREE/barretenberg/cpp/src/barretenberg/world_state/memory_merkle_db.test.cpp" 2>/dev/null)"
assert_contains "upstream's gate pads the real world state with zero leaves" \
  'ws->append_leaves<FF>(MerkleTreeId::NOTE_HASH_TREE, std::vector<FF>(padding, FF(0)));' "$GATE"
assert_contains "and the reference with pad_tree, then requires the roots to agree" \
  'mem->pad_tree(MerkleTreeId::NOTE_HASH_TREE, padding);' "$GATE"
REF_HPP_TXT="$(cat "$M14_TREE/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp" 2>/dev/null)"
assert_contains "the reference's indexed pad writes an empty leaf hashing to zero" \
  "tree_.update_element(insertion_index, FF::zero());" "$REF_HPP_TXT"
note "RECORDED AS A FACT: empty-leaf padding AGREES with the production world state; no protocol-contract leaf is inserted by either"

finish
