#!/usr/bin/env bash
# test_empty_block_advances_number_and_archive — M23's headline.
#
# The verification entry: "An empty block still advances the block number, appends to the archive
# and gives Form B a fresh anchor header."
#
# THIS IS THE MILESTONE. The campaign was asked for "a way to execute transactions, potentially
# wrapped in blocks, over a storage state, with self-issuance of empty blocks on a timer". M20 gave
# the transactions and M22 gave the blocks. An empty block that advances nothing is a no-op with a
# number on it; an empty block that advances the ARCHIVE is a chain moving forward with no
# transactions in it, which is what self-issuance means.
#
# THE ARCHIVE IS WHAT MAKES IT A CHAIN, and it is checked as a chain rather than as three
# independent facts: block N's header carries `lastArchive`, the archive's snapshot BEFORE the
# block, and sealing appends the header's hash. So block N+1's `lastArchive` must EQUAL block N's
# archive-after. A run in which each block merely got a different root would pass a "the root
# moved" assertion and would not be a chain.
#
# AND THE GENESIS IS ANCHORED AGAINST UPSTREAM'S OWN PUBLISHED CONSTANTS, in the direction that
# makes it evidence: the archive's first leaf is computed in C++ by
# `MemoryMerkleDB::compute_initial_block_header_hash` over the four genesis snapshots, and it is
# compared against `GENESIS_BLOCK_HEADER_HASH`, which upstream publishes in TypeScript; the
# archive's root at size one is compared against `@aztec/constants`' `GENESIS_ARCHIVE_ROOT`. Two
# independent cross-implementation agreements. Without them "the archive advanced" would be a
# statement about a number this repository produced and nothing else.
#
# THE CONTROL FOR "EMPTY BLOCKS ARE PRODUCED" IS A RUN THAT DOES NOT PRODUCE THEM.
# `produceEmptyBlocks: false` must leave the chain at block 0 across five ticks and then produce
# one when a transaction arrives. Without that arm, "three empty blocks were produced" is satisfied
# by a chain that produces a block on every tick whatever the flag says.
#
# Run: just verify-chain-empty-blocks

TEST_NAME="test_empty_block_advances_number_and_archive"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit
m23_require_anchor
m23_require_arms

note "module $AVM_WASM_PATH"
note "sha256 $M23_MODULE_SHA"

# ---------------------------------------------------------------------------
# PART 0 — the module is the one with the archive, and that is a MEASUREMENT
# ---------------------------------------------------------------------------
echo "== the module carries the archive"

EXPORTS="$(m23_module_exports "$AVM_WASM_PATH")"
N_EXPORTS="$(printf '%s\n' "$EXPORTS" | grep -c .)"
assert_eq "the module's export list is the fifty-one of M23's overlay stack" "51" "$N_EXPORTS"
assert_true "…and the run report agrees about that count" \
  test "$(m23_run exports)" = "$N_EXPORTS"
while IFS= read -r want; do
  [ -n "$want" ] || continue
  assert_true "the module exports $want" str_has_line "$EXPORTS" "$want"
done <<< "$M23_ARCHIVE_EXPORTS"
# THE CONTROL FOR THAT LOOKUP: a name that is not there is not found by it. Without this, a broken
# `str_has_line` would report every export present.
assert_false "…and a name the module does not export is not found by the same lookup" \
  str_has_line "$EXPORTS" "avm_merkle_db_update_archive_that_does_not_exist"

assert_eq "the adapter reports that this module has the archive" "true" \
  "$(m23_arm archiveIdentity hasArchive)"

# ---------------------------------------------------------------------------
# PART 1 — genesis, against upstream's own published constants
# ---------------------------------------------------------------------------
echo "== the archive's genesis agrees with upstream, in two independent ways"

GEN_ROOT="$(m23_arm archiveIdentity genesisRoot)"
GEN_SIZE="$(m23_arm archiveIdentity genesisSize)"
GEN_LEAF="$(m23_arm archiveIdentity genesisLeaf)"

assert_eq "the archive starts at exactly one leaf, as the WorldState's does" "1" "$GEN_SIZE"
assert_true "the genesis root is a field element and not MISSING" \
  test "${#GEN_ROOT}" -eq 66
assert_true "the genesis leaf is a field element and not MISSING" \
  test "${#GEN_LEAF}" -eq 66

# `GENESIS_ARCHIVE_ROOT` and `GENESIS_BLOCK_HEADER_HASH` are read out of the INSTALLED packages,
# never typed here: a constant typed into a check looks like a measurement to the person typing it.
UPSTREAM_CONSTS="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { GENESIS_ARCHIVE_ROOT } from "@aztec/constants";
import { GENESIS_BLOCK_HEADER_HASH } from "@aztec/stdlib/block";
const hex = v => "0x" + BigInt(v).toString(16).padStart(64, "0");
console.log(hex(GENESIS_ARCHIVE_ROOT));
console.log(GENESIS_BLOCK_HEADER_HASH.toString());
' 2>&1 | tail -2)"
UP_ARCHIVE="$(printf '%s\n' "$UPSTREAM_CONSTS" | sed -n 1p)"
UP_HEADER="$(printf '%s\n' "$UPSTREAM_CONSTS" | sed -n 2p)"
assert_true "GENESIS_ARCHIVE_ROOT was read out of @aztec/constants" test "${#UP_ARCHIVE}" -eq 66
assert_true "GENESIS_BLOCK_HEADER_HASH was read out of @aztec/stdlib" test "${#UP_HEADER}" -eq 66

assert_eq "the module's archive root at genesis IS upstream's GENESIS_ARCHIVE_ROOT" \
  "$UP_ARCHIVE" "$GEN_ROOT"
assert_eq "…and its first leaf IS upstream's GENESIS_BLOCK_HEADER_HASH" \
  "$UP_HEADER" "$GEN_LEAF"
# The two constants are DIFFERENT values, so the pair of assertions above is two claims and not
# one written twice. (A root over one leaf is not that leaf.)
assert_true "the two upstream constants are different values" test "$UP_ARCHIVE" != "$UP_HEADER"

# ---------------------------------------------------------------------------
# PART 2 — three empty blocks: number, timestamp, archive, and the CHAIN
# ---------------------------------------------------------------------------
echo "== three empty blocks advance the number, the timestamp and the archive"

assert_eq "three empty blocks were produced" "3" "$(m23_arm emptyBlocks finalBlockNumber)"
for i in 0 1 2; do
  n=$((i + 1))
  assert_eq "block $n is numbered $n" "$n" "$(m23_arm emptyBlocks "blocks.$i.number")"
  assert_eq "block $n reports itself EMPTY" "true" "$(m23_arm emptyBlocks "blocks.$i.empty")"
  assert_eq "block $n carries no transactions" "[]" "$(m23_arm emptyBlocks "blocks.$i.txHashes")"
  assert_eq "block $n's GlobalVariables carry the same block number" \
    "$n" "$(m23_arm emptyBlocks "blocks.$i.blockNumberInGlobals")"
  assert_eq "block $n's archive grew to $((n + 1)) leaves" \
    "$((n + 1))" "$(m23_arm emptyBlocks "blocks.$i.archiveAfter.size")"
  assert_eq "block $n's archive-before is $n leaves" \
    "$n" "$(m23_arm emptyBlocks "blocks.$i.archiveBefore.size")"
  # The header's `lastArchive` is the archive BEFORE the block. Upstream's `makeTXEBlockHeader`
  # decides that, and this asserts it rather than assuming the vendored copy still does.
  assert_eq "block $n's header lastArchive IS its archive-before" \
    "$(m23_arm emptyBlocks "blocks.$i.archiveBefore.root")" \
    "$(m23_arm emptyBlocks "blocks.$i.lastArchive.root")"
done

echo "== and they form a CHAIN rather than three unrelated roots"
A1_AFTER="$(m23_arm emptyBlocks blocks.0.archiveAfter.root)"
A2_BEFORE="$(m23_arm emptyBlocks blocks.1.archiveBefore.root)"
A2_AFTER="$(m23_arm emptyBlocks blocks.1.archiveAfter.root)"
A3_BEFORE="$(m23_arm emptyBlocks blocks.2.archiveBefore.root)"
assert_eq "block 2 is anchored on block 1's archive" "$A1_AFTER" "$A2_BEFORE"
assert_eq "block 3 is anchored on block 2's archive" "$A2_AFTER" "$A3_BEFORE"
# NOT A TAUTOLOGY: the roots must also be DISTINCT. Equal roots would satisfy every assertion above
# and would mean the archive never moved. FOUR VALUES, because the label said "genesis and the
# three archive roots" while the set held genesis and TWO of them — block 3's archive-after was not
# in it. Prose drifting from measurement, in the direction that made the assertion weaker.
A3_AFTER="$(m23_arm emptyBlocks blocks.2.archiveAfter.root)"
DISTINCT="$(printf '%s\n%s\n%s\n%s\n' "$GEN_ROOT" "$A1_AFTER" "$A2_AFTER" "$A3_AFTER" \
  | sort -u | grep -c .)"
assert_eq "genesis and the three archive roots are four different values" "4" "$DISTINCT"

echo "== the timestamps advance"
T1="$(m23_arm emptyBlocks blocks.0.timestamp)"
T2="$(m23_arm emptyBlocks blocks.1.timestamp)"
T3="$(m23_arm emptyBlocks blocks.2.timestamp)"
assert_true "block 2's timestamp is after block 1's" test "$T2" -gt "$T1"
assert_true "block 3's timestamp is after block 2's" test "$T3" -gt "$T2"

echo "== each block's header hash is distinct, so the archive leaves are distinct"
H0="$(m23_arm emptyBlocks headerHashes.0)"
H1="$(m23_arm emptyBlocks headerHashes.1)"
H2="$(m23_arm emptyBlocks headerHashes.2)"
assert_true "the first header hash is a field element" test "${#H0}" -eq 66
N_HASH="$(printf '%s\n%s\n%s\n' "$H0" "$H1" "$H2" | sort -u | grep -c .)"
assert_eq "three empty blocks produce three DIFFERENT header hashes" "3" "$N_HASH"
assert_true "and none of them is the genesis header hash" test "$H0" != "$UP_HEADER"

# ---------------------------------------------------------------------------
# PART 3 — "gives Form B a fresh anchor header": the anchor is READABLE
# ---------------------------------------------------------------------------
echo "== the sealed header is retrievable as an anchor"

# The claim in the entry is that the block gives Form B a FRESH ANCHOR. What that means
# mechanically is that after the block the archive read returns the new snapshot, which is what the
# next header's `lastArchive` will be — so block N+1's lastArchive equalling block N's after IS the
# retrievability, measured above. What is added here is that the anchor moves with EVERY block and
# not only with the first: three blocks, three different `lastArchive` values.
L1="$(m23_arm emptyBlocks blocks.0.lastArchive.root)"
L2="$(m23_arm emptyBlocks blocks.1.lastArchive.root)"
L3="$(m23_arm emptyBlocks blocks.2.lastArchive.root)"
N_ANCHOR="$(printf '%s\n%s\n%s\n' "$L1" "$L2" "$L3" | sort -u | grep -c .)"
assert_eq "each of the three blocks was anchored on a DIFFERENT header" "3" "$N_ANCHOR"
assert_eq "the first block's anchor is genesis" "$GEN_ROOT" "$L1"

# ---------------------------------------------------------------------------
# PART 4 — THE CONTROL: a chain that does not produce empty blocks
# ---------------------------------------------------------------------------
echo "== produceEmptyBlocks: false — the discriminator"

assert_eq "the no-empty-blocks arm ticked six times" "6" "$(m23_arm noEmptyBlocks ticks)"
assert_eq "…and five of those ticks produced NO block at all" "0" \
  "$(m23_arm noEmptyBlocks afterEmptyTicks)"
assert_eq "…while the tick after a transaction arrived produced one" "1" \
  "$(m23_arm noEmptyBlocks afterTx)"

m23_finish
