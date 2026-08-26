#!/usr/bin/env bash
# test_block_seal_updates_archive — M22's entry, closed in M23.
#
# The verification entry, which is M22's: "Sealing a block appends its header to the archive and
# the header is retrievable as an anchor."
#
# WHY THIS CHECK IS IN M23'S SET AND NOT M22'S. M22 could not close it, and was right not to: the
# shipped module had no archive, `sealBlock` reported `{sealed: false, refusal}` and the blocker
# was measured four ways on every run. Closing it needed an ABI decision that M14 assigned to M15
# and M15 never took — `REACTOR-ABI.md` contained the word "archive" zero times. M23 took it,
# because a chain whose seal refuses is not a chain. M22's own module is unchanged and its four
# checks still measure the refusal against it; this check measures the ANSWER against M23's.
#
# WHAT M22 ALREADY HAD, and what M23 added. The sealing PATH was upstream's and was in place:
# `makeTXEBlockHeader` vendored byte-identically (RI-66), called by `sealBlock`, reading the state
# reference and `getTreeInfo(ARCHIVE)` and then calling `updateArchive(header)`. What was missing
# was the tree. M23 applied M14's patch as an eleventh overlay and added the two reactor exports
# that carry it across the vm2 adapter (RI-70, `verification/m23/`).
#
# THE REFUSAL IS THE MOST IMPORTANT ASSERTION HERE, AND IT HAS A CONTROL.
# `world_state::MemoryMerkleDB::update_archive` compares the header's four-tree state reference
# against the trees' current one and throws if they differ. A check that only ever saw an ACCEPTED
# append could not tell "the module verified the header" from "the module appends whatever it is
# given", and a chain whose archive certifies states that never existed is worse than one with no
# archive at all. So the same header is offered twice — once with one tree's root perturbed, once
# unchanged — and the archive's SIZE is read after each, because a refusal that had already
# appended would still be a refusal by message.
#
# AND THE FIRST VERSION OF THAT ARM COULD NOT FAIL. It re-offered an earlier block's header on the
# reasoning that the trees had moved under it; but an EMPTY block does not move the four trees, so
# the header legitimately still matched and the module accepted it — `NOT-REFUSED`, in the arm
# whose entire purpose was to see a refusal. It perturbs the reference now.
#
# Run: just verify-chain-seal

TEST_NAME="test_block_seal_updates_archive"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit
m23_require_anchor
m23_require_arms

note "module $AVM_WASM_PATH"
note "sha256 $M23_MODULE_SHA"

# ---------------------------------------------------------------------------
# PART 1 — the seal SUCCEEDS, and the header lands in the archive
# ---------------------------------------------------------------------------
echo "== sealing appends the header to the archive"

# A seal that refused would leave `AvmChain.produceBlock` throwing `ChainSealRefused`, and the arm
# run would have died. That it produced blocks at all is the first fact; the sizes are the second.
assert_eq "the chain produced three blocks, so three seals succeeded" "3" \
  "$(m23_arm emptyBlocks finalBlockNumber)"
assert_eq "the archive was one leaf before the first block" "1" \
  "$(m23_arm emptyBlocks blocks.0.archiveBefore.size)"
assert_eq "…and four after the third" "4" "$(m23_arm emptyBlocks blocks.2.archiveAfter.size)"

# ONE LEAF PER BLOCK, stated as a subtraction rather than as three separate numbers, because three
# numbers can be right while the relation between them is not what is claimed.
for i in 0 1 2; do
  before="$(m23_arm emptyBlocks "blocks.$i.archiveBefore.size")"
  after="$(m23_arm emptyBlocks "blocks.$i.archiveAfter.size")"
  assert_eq "block $((i + 1)) appended EXACTLY one archive leaf" "1" "$((after - before))"
done

echo "== the header is retrievable as an anchor: the next block reads it"
assert_eq "block 2's lastArchive IS block 1's archive-after" \
  "$(m23_arm emptyBlocks blocks.0.archiveAfter.root)" \
  "$(m23_arm emptyBlocks blocks.1.lastArchive.root)"
assert_eq "block 3's lastArchive IS block 2's archive-after" \
  "$(m23_arm emptyBlocks blocks.1.archiveAfter.root)" \
  "$(m23_arm emptyBlocks blocks.2.lastArchive.root)"
assert_eq "the archiveIdentity arm chains the same way" "true" \
  "$(m23_arm archiveIdentity chained)"

# ---------------------------------------------------------------------------
# PART 2 — the refusal, and its control
# ---------------------------------------------------------------------------
echo "== a header whose state reference is not the world state's is REFUSED"

REFUSAL="$(m23_arm archiveIdentity staleHeaderRefusal)"
assert_true "the perturbed header was refused rather than accepted" \
  test "$REFUSAL" != "NOT-REFUSED"
# The message is UPSTREAM'S OWN, read out of `WorldState::update_archive` at the anchor rather than
# typed here — a message typed into a check is a constant that looks like a measurement.
UP_MSG="$(m23_anchor_file barretenberg/cpp/src/barretenberg/world_state/world_state.cpp \
  | grep -o "Can't update archive tree: Block state does not match world state" | head -1)"
assert_eq "…and upstream's own message was read out of world_state.cpp at the anchor" \
  "Can't update archive tree: Block state does not match world state" "$UP_MSG"
assert_true "the refusal carries that message" str_has_sub "$REFUSAL" "$UP_MSG"

echo "== and the refusal did not append: the archive's size is unchanged"
# THREE: genesis plus the arm's two blocks. Read from the arm rather than typed, and then
# required to be unchanged — the number itself is not the claim, the SUBTRACTION is.
SIZE_BEFORE="$(m23_arm archiveIdentity sizeBeforeRefusal)"
assert_eq "the archive is three leaves before the refused append (genesis + two blocks)" "3" "$SIZE_BEFORE"
assert_eq "…and the refusal appended NOTHING" "$SIZE_BEFORE" "$(m23_arm archiveIdentity sizeAfterRefusal)"

echo "== THE CONTROL: the same header, unperturbed, IS accepted by the same call"
assert_eq "an unperturbed header is accepted" "ACCEPTED" \
  "$(m23_arm archiveIdentity acceptedControl)"
assert_eq "…and the archive then grew by exactly one" "$((SIZE_BEFORE + 1))" \
  "$(m23_arm archiveIdentity sizeAfterControl)"

# ---------------------------------------------------------------------------
# PART 3 — the path is UPSTREAM'S, and that is asserted rather than asserted about
# ---------------------------------------------------------------------------
echo "== the sealing path is upstream's vendored block-creation helper"

VENDORED="$REPO_ROOT/orchestration/src/vendor/txe_block_creation.ts"
assert_file "the vendored TXE block-creation helper is here" "$VENDORED"
COPY="$(cat "$VENDORED")"
ANCHOR_COPY="$(git -C "$FORK_ROOT" show "$M23_TS_ANCHOR:yarn-project/txe/src/utils/block_creation.ts" 2>/dev/null)"
assert_true "…and the ts anchor has the file it was taken from" test -n "$ANCHOR_COPY"

# The three lines that MAKE the chaining, required present in the copy AND in the anchor blob, as
# whole lines. An absence measured against a haystack that could have contained it.
for line in \
  "  const archiveInfo = await worldTrees.getTreeInfo(MerkleTreeId.ARCHIVE);" \
  "    lastArchive: new AppendOnlyTreeSnapshot(new Fr(archiveInfo.root), Number(archiveInfo.size))," \
  "  await worldTrees.updateArchive(header);"
do
  assert_true "the copy carries upstream's line: ${line:0:48}…" str_has_line "$COPY" "$line"
  assert_true "…and so does the anchor's own blob" str_has_line "$ANCHOR_COPY" "$line"
done
# A one-character variant of one of them must NOT match, or the needle is matching something else.
assert_false "a one-character variant of the updateArchive line does not match" \
  str_has_line "$COPY" "  await worldTrees.updateArchive(headers);"

echo "== and `sealBlock` calls it rather than reimplementing it"
SEAL="$(cat "$REPO_ROOT/orchestration/src/block_assembly.ts")"
assert_true "sealBlock calls makeTXEBlockHeader" \
  str_has_sub "$SEAL" "await makeTXEBlockHeader(guarded as never, globalVariables)"
assert_true "…and then updateArchive" str_has_sub "$SEAL" "await guarded.updateArchive(header)"
# NOTHING OF OURS RE-IMPLEMENTS THE CHAINING, AND THE NEEDLE IS CALL-SHAPED. A bare-text search
# for `lastArchive` is satisfied by prose — this campaign's "a citation is the opposite of a
# dependency" — and `chain.ts` and `block_assembly.ts` both EXPLAIN the chaining in comments. What
# would constitute a reimplementation is CONSTRUCTING the header's lastArchive, which is
# `lastArchive: new AppendOnlyTreeSnapshot(`, exactly what `makeTXEBlockHeader` does.
NEEDLE='lastArchive: new AppendOnlyTreeSnapshot('
OURS=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in */vendor/*) continue ;; esac
  if grep -qF "$NEEDLE" "$f"; then OURS="$OURS $f"; fi
done <<EOF
$(find "$ORCH_SRC" -name '*.ts' -type f)
EOF
assert_eq "no file of ours outside vendor/ constructs a header's lastArchive" "" "$OURS"
# TWO CONTROLS, because an empty result is also what a broken scanner produces. The vendored file
# DOES construct one — so the needle works — and files of ours DO mention the name in prose, so the
# absence above is about code and not about the word.
assert_true "…the vendored file DOES construct one, so the needle works" \
  grep -qF "$NEEDLE" "$VENDORED"
assert_true "…and files of ours DO mention lastArchive in prose" \
  grep -q 'lastArchive' "$REPO_ROOT/orchestration/src/chain.ts"

# ---------------------------------------------------------------------------
# PART 4 — the module-side half: what M22 measured as absent is present
# ---------------------------------------------------------------------------
echo "== what M22 measured four ways as absent is present here"

EXPORTS="$(m23_module_exports "$AVM_WASM_PATH")"
assert_true "avm_merkle_db_update_archive is in the instantiated module's exports" \
  str_has_line "$EXPORTS" "avm_merkle_db_update_archive"
assert_true "avm_merkle_db_get_archive_snapshot is too" \
  str_has_line "$EXPORTS" "avm_merkle_db_get_archive_snapshot"
assert_true "…and it is in the wasm binary's own name section" \
  grep -qa 'avm_merkle_db_update_archive' "$AVM_WASM_PATH"

# `update_archive` in the SOURCE the module was built from. The tree is M23's worktree, so this
# says the carried patch is what produced the export rather than something else with the same name.
# THE SOURCE-SIDE HALF IS NOT OPTIONAL. It used to sit behind
# `if [ -d "$M23_TREE/…" ]` with a bare `note` in the `else`, so on a machine where the module was
# found at `$M23_WORK/avm.wasm` without the worktree beside it this check reported 40 assertions
# instead of 44 AND PASSED. A missing check reading as a smaller milestone rather than a red one is
# the shape M21's review named and M23's review found again here. The tree is a precondition now,
# with the remedy in the message.
M23_TREE="$M23_WORK/m23"
assert_true "M23's overlay worktree is present, so the source-side half is measured" \
  test -d "$M23_TREE/barretenberg/cpp/src/barretenberg/world_state_reference"
[ -d "$M23_TREE/barretenberg/cpp/src/barretenberg/world_state_reference" ] \
  || die "M23's overlay worktree is not at $M23_TREE.
             The module can be found without it and the four assertions below would then be
             silently skipped. Remedy: just avm-wasm-build-m23."
N_UP="$(grep -rc 'update_archive' \
  "$M23_TREE/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.cpp" 2>/dev/null || echo 0)"
assert_ge "update_archive is in the built tree's world_state_reference" 1 "$N_UP"
# AND IT IS ABSENT AT THE ANCHOR — with the control that the directory EXISTS and is non-empty
# there and DOES contain MemoryMerkleDB by the same grep, because an absence asked of a tree that
# does not contain the subject by construction is this campaign's most-repeated defect.
ANCHOR_WSR="$(git -C "$FORK_ROOT" ls-tree -r --name-only "$M23_CPP_ANCHOR" \
  -- barretenberg/cpp/src/barretenberg/world_state_reference/ | grep -c . || true)"
assert_ge "world_state_reference exists at the anchor and is non-empty" 4 "$ANCHOR_WSR"
ANCHOR_SRC="$(m23_anchor_file barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.cpp)"
assert_true "…and it does contain MemoryMerkleDB by the same grep" \
  str_has_sub "$ANCHOR_SRC" "MemoryMerkleDB"
assert_false "…and it does NOT contain update_archive" str_has_sub "$ANCHOR_SRC" "update_archive"

# ---------------------------------------------------------------------------
# PART 5 — the overlay patch is the one this repository ships
# ---------------------------------------------------------------------------
echo "== M23's overlay patch is present and is the one that adds the two exports"

assert_file "M23's overlay patch is in the repository" "$M23_PATCH"
PATCH="$(cat "$M23_PATCH")"
assert_true "it adds avm_merkle_db_update_archive to the export list" \
  str_has_line "$PATCH" "+            avm_merkle_db_update_archive"
assert_true "it adds avm_merkle_db_get_archive_snapshot to the export list" \
  str_has_line "$PATCH" "+            avm_merkle_db_get_archive_snapshot"
assert_true "it defines the update export" \
  str_has_sub "$PATCH" "+WASM_EXPORT int32_t avm_merkle_db_update_archive(uint32_t handle, const uint8_t* args, uint32_t len)"
assert_true "it defines the read export" \
  str_has_sub "$PATCH" "+WASM_EXPORT int32_t avm_merkle_db_get_archive_snapshot(uint32_t handle)"
# It touches the vm2 ADAPTER, which is the fact M22's "one export" pricing missed.
assert_true "and it carries the archive across the vm2 adapter" \
  str_has_sub "$PATCH" "vm2/simulation/lib/memory_merkle_db.hpp"
assert_false "a needle for an export it does not add finds nothing" \
  str_has_line "$PATCH" "+            avm_merkle_db_delete_archive"

m23_finish
