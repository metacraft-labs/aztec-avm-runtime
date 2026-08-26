#!/usr/bin/env bash
# test_guarded_merkle_tree_blocks_post_seal_access — M22, and DD-3.
#
# The verification entry: "World-state access after the block is sealed is refused by the guard
# rather than silently succeeding."
#
# THE UNGUARDED CONTROL IS THE WHOLE CHECK. Without it this measures an ABSENCE — it cannot tell
# "the guard stopped this" from "this database answers nothing", and M21's adapter check learned
# that the hard way. So the same operation is run three times against one block, in one process:
#
#     through the guard, BEFORE the seal      -> answers
#     through the guard, AFTER the seal       -> refused, with upstream's own message
#     on the resident database, AFTER the seal -> answers
#
# The third line is what makes the second a guard. A stopped guard is a GATE, not a demolition: the
# world state underneath it is intact and still answering, which is also what makes it safe to seal
# a block and then read the state reference the block certified.
#
# DD-3 IS A DOCUMENTATION DELIVERABLE AND IS CHECKED AS ONE. M22 asks that
# `GuardedMerkleTreeOperations` be "kept, its interface kept, documented as vestigial". Three
# things are therefore asserted rather than described: the class is HERE (vendored, and byte-equal
# to upstream apart from one desugared parameter property — `verify_public_processor_vendored_not_
# reimplemented` pins that diff line for line); its INTERFACE is complete, all twenty-five methods,
# not a convenient subset; and the word "vestigial" appears in a place that says WHY, together with
# the three reasons it is kept anyway.
#
# AND THE ARCHIVE IS MEASURED HERE, because sealing is where it bites. `sealBlock` is upstream's
# `makeTXEBlockHeader`, and its `getTreeInfo(ARCHIVE)` is the one call the shipped module cannot
# serve — M14 decided to EXTEND `world_state_reference` with the archive tree (RI-53), the patch is
# at `verification/m14/` and it is not carried. That is asserted against the MODULE'S OWN EXPORT
# LIST, with a control that an export which IS there is found by the same lookup, so the absence is
# an absence of something in a list that is not empty.
#
# Run: just verify-block-guard

TEST_NAME="test_guarded_merkle_tree_blocks_post_seal_access"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m22_block.sh"

m22_summary_on_abnormal_exit
m22_require_anchor
m22_require_arms

note "module $AVM_WASM_PATH"
note "sha256 $M22_MODULE_SHA"

# ---------------------------------------------------------------------------
# PART 0 — the guard arm ran
# ---------------------------------------------------------------------------

assert_eq "an arm that does not exist reads MISSING" "MISSING" "$(m22_arm guard noSuchField)"
assert_eq "the guard arm recorded an export count, so a module really was instantiated" \
  "49" "$(m22_arm guard exportCount)"

# ---------------------------------------------------------------------------
# PART 1 — the three readings of one operation
# ---------------------------------------------------------------------------

echo "== getStateReference, through the guard and around it, before the seal and after"

assert_eq "BEFORE the seal, the guard answers" "true" "$(m22_arm guard beforeSeal.ok)"
assert_eq "AFTER the seal, the guard REFUSES" "false" "$(m22_arm guard afterSealGuarded.ok)"
assert_eq "…with upstream's own message, which is the guard's and not ours" \
  "Merkle tree access has been stopped" "$(m22_arm guard afterSealGuarded.error)"
assert_eq "THE UNGUARDED CONTROL: the resident database answers the same call after the seal" \
  "true" "$(m22_arm guard afterSealUnguarded.ok)"

# The message is upstream's, at the anchor, in the class itself — so a rename upstream fails this
# check rather than silently leaving a refusal that nothing recognises.
GMT_ANCHOR="$(m22_anchor_file yarn-project/simulator/src/public/public_processor/guarded_merkle_tree.ts)"
assert_true "the refusal message is the anchor's own string" \
  str_has_line "$GMT_ANCHOR" "      throw new Error('Merkle tree access has been stopped');"

# A WRITE is refused too, not only a read. A gate that only stopped reads would leave exactly the
# operation that can invalidate a sealed block.
assert_eq "a WRITE through the guard after the seal is refused too" "false" \
  "$(m22_arm guard afterSealWriteGuarded.ok)"
assert_eq "…with the same message" "Merkle tree access has been stopped" \
  "$(m22_arm guard afterSealWriteGuarded.error)"

# ---------------------------------------------------------------------------
# PART 2 — the guard's interface is COMPLETE, which is the other half of DD-3
# ---------------------------------------------------------------------------

echo "== all twenty-five methods, kept"

GMT_LOCAL="$(m22_strip_header "$M22_VENDOR/public_processor/guarded_merkle_tree.ts")"

# The method list is extracted from UPSTREAM'S declaration and then required of ours, so the number
# is upstream's rather than a count of what we happened to copy.
UP_METHODS="$(printf '%s\n' "$GMT_ANCHOR" | python3 -c '
import re, sys
names = []
for line in sys.stdin:
    m = re.match(r"^  (?:public |async )*([a-zA-Z][A-Za-z0-9_]*)(?:<[^(]*)?\(", line)
    if m and m.group(1) not in ("constructor", "if", "for", "return"):
        names.append(m.group(1))
print(" ".join(sorted(set(names))))')"
N_UP="$(printf '%s\n' "$UP_METHODS" | tr ' ' '\n' | grep -c . || true)"
note "upstream declares: $UP_METHODS"
assert_eq "upstream's GuardedMerkleTreeOperations declares twenty-five named methods" "25" "$N_UP"

OUR_METHODS="$(printf '%s\n' "$GMT_LOCAL" | python3 -c '
import re, sys
names = []
for line in sys.stdin:
    m = re.match(r"^  (?:public |async )*([a-zA-Z][A-Za-z0-9_]*)(?:<[^(]*)?\(", line)
    if m and m.group(1) not in ("constructor", "if", "for", "return"):
        names.append(m.group(1))
print(" ".join(sorted(set(names))))')"
assert_eq "…and the kept copy declares exactly the same set" "$UP_METHODS" "$OUR_METHODS"

# The extractor is not vacuous: it finds a method name it should, and does not invent one.
assert_true "the extractor really found updateArchive, the method this milestone needs" \
  str_has_word "$OUR_METHODS" "updateArchive"
assert_false "…and did not invent one that is not declared" \
  str_has_word "$OUR_METHODS" "updateArchiveTwice"

# Every method goes through the gate. `getUnderlyingFork`, `stop`, `getInitialHeader`, `getRevision`
# and `getIpcPath` are upstream's deliberate exceptions — the first is how the processor reaches the
# raw fork for its own checkpoint, and the last three are synchronous accessors — so the census is
# stated in both directions rather than as "most of them".
N_GUARDED="$(printf '%s\n' "$GMT_LOCAL" | grep -c 'this.guardAndPush(' || true)"
assert_eq "twenty of the twenty-five forward through guardAndPush" "20" "$N_GUARDED"
# 20 + 5 = 25, and the five are named below, so the census closes rather than nearly closing.
assert_eq "…and the five that do not are the ones named, so the two numbers add up" "25" \
  "$((N_GUARDED + 5))"
for direct in getUnderlyingFork stop getInitialHeader getRevision getIpcPath; do
  assert_false "…and $direct deliberately does not, exactly as upstream has it" \
    str_has_re "$(printf '%s\n' "$GMT_LOCAL" | grep -A1 "  $direct(")" "guardAndPush"
done

# ---------------------------------------------------------------------------
# PART 3 — DD-3: the class is documented as vestigial, and why it is kept anyway
# ---------------------------------------------------------------------------

echo "== DD-3, as prose that says something checkable"

BA="$(cat "$ORCH_SRC/block_assembly.ts")"
assert_true "the word DD-3 appears where the class is used" str_has_sub "$BA" "DD-3"
assert_true "…and the class is called vestigial in that specific sense" \
  str_has_sub "$BA" "VESTIGIAL in that specific sense"
assert_true "…with the original reason named: a NAPI worker thread" \
  str_has_sub "$BA" "a NAPI worker thread the"
assert_true "…and the reason it evaporated: the module runs to completion on the caller's stack" \
  str_has_sub "$BA" "runs to completion on the"
# The three reasons it is kept. Each is a separate claim and each is checkable elsewhere in this
# file, so the prose is an index into assertions rather than a substitute for them.
assert_true "reason 1 — it still enforces no-access-after-seal" \
  str_has_sub "$BA" "IT STILL ENFORCES THE PROPERTY THE BLOCK NEEDS"
assert_true "reason 2 — deleting it diverges from upstream for no gain" \
  str_has_sub "$BA" "DELETING IT MEANS DIVERGING FROM UPSTREAM FOR NO GAIN"
assert_true "reason 3 — the serial queue is not vestigial even if the thread is" \
  str_has_sub "$BA" "THE SERIAL QUEUE IS NOT VESTIGIAL EVEN IF THE THREAD IS"
# …and the needle can fail: a claim the file does not make is not found.
assert_false "a reason the file does not give is not found by the same needle" \
  str_has_sub "$BA" "REASON 4 — IT IS FASTER"

# The class is KEPT, not re-declared: it is the vendored file, and `sealBlock` calls its `stop()`.
assert_file "the class is the vendored copy" "$M22_VENDOR/public_processor/guarded_merkle_tree.ts"
assert_true "sealBlock stops it" str_has_sub "$BA" "await guarded.stop();"
assert_eq "and no class of ours re-declares it" "0" \
  "$(grep -rl 'class GuardedMerkleTreeOperations' "$ORCH_SRC" 2>/dev/null \
      | grep -v "$M22_VENDOR/" | grep -c . || true)"
# The control for that zero: the same lookup DOES find the vendored declaration.
assert_eq "…and the same lookup finds the vendored one, so the zero is not a broken search" "1" \
  "$(grep -rl 'class GuardedMerkleTreeOperations' "$ORCH_SRC" 2>/dev/null | grep -c . || true)"

# ---------------------------------------------------------------------------
# PART 4 — sealing, and the archive
# ---------------------------------------------------------------------------

echo "== the seal, and the one call the shipped module cannot serve"

assert_eq "the seal did not produce a header" "false" "$(m22_arm guard seal.sealed)"
assert_eq "…and it says exactly which call it could not make" "getTreeInfo(ARCHIVE)" \
  "$(m22_arm guard seal.refusal.method)"
assert_contains "…and why" "the archive tree is not in this module" \
  "$(m22_arm guard seal.refusal.reason)"
assert_eq "…and the guard was stopped ANYWAY, because sealing is an attempt and not an outcome" \
  "true" "$(m22_arm guard seal.stopped)"

# THE ABSENCE IS ASKED OF THE MODULE, and of a list that is not empty.
assert_eq "the module exports no avm_merkle_db_update_archive" "false" \
  "$(m22_arm guard archiveExportPresent)"
assert_eq "THE CONTROL: an export that IS there is found by the same lookup" "true" \
  "$(m22_arm guard knownExportPresent)"
assert_ge "…in an export list of a real module, not an empty one" 39 "$(m22_arm guard exportCount)"

# Asked of the WASM BINARY as well as of the instantiated module, because the two are different
# questions: one is what the instance exposes, the other is what the artefact declares.
BIN_EXPORTS="$(m22_module_exports "$AVM_WASM_PATH")"
assert_false "the binary declares no avm_merkle_db_update_archive either" \
  str_has_line "$BIN_EXPORTS" "avm_merkle_db_update_archive"
assert_true "…while it does declare the fourteen-method group's own get_tree_roots" \
  str_has_line "$BIN_EXPORTS" "avm_merkle_db_get_tree_roots"

# THE C++ SIDE OF THE SAME FACT: the extension M14 decided on is not carried into the fork's own
# branch. Measured, not quoted — this is the claim `resident_merkle_operations.ts` rests on.
CPP_ANCHOR="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' "$REPO_ROOT/pins.json")"
assert_eq "world_state_reference at the cpp anchor has no update_archive" "0" \
  "$(git -C "$FORK_ROOT" grep -c "update_archive" "$CPP_ANCHOR" \
      -- 'barretenberg/cpp/src/barretenberg/world_state_reference/' 2>/dev/null | grep -c . || true)"
assert_eq "…nor does the fork's own branch head" "0" \
  "$(git -C "$FORK_ROOT" grep -c "update_archive" HEAD \
      -- 'barretenberg/cpp/src/barretenberg/world_state_reference/' 2>/dev/null | grep -c . || true)"
# TWO CONTROLS, because an absence asked of a tree that does not contain the SUBJECT BY
# CONSTRUCTION is this campaign's most-repeated defect — twice in a row, in checks whose headers
# cited each other. `git grep` over a path that does not exist at that revision prints nothing and
# reads exactly like "the name is not there".
#
# First: the directory EXISTS at both revisions and is non-empty by the same command.
for rev_label in "cpp-anchor:$CPP_ANCHOR" "branch-head:$(git -C "$FORK_ROOT" rev-parse HEAD)"; do
  rev="${rev_label#*:}"
  assert_ge "the world_state_reference directory is non-empty at ${rev_label%%:*}, so the absence is of a name and not of a tree" 3 \
    "$(git -C "$FORK_ROOT" ls-tree -r --name-only "$rev" \
        -- 'barretenberg/cpp/src/barretenberg/world_state_reference/' 2>/dev/null | grep -c . || true)"
  assert_ge "…and it DOES contain MemoryMerkleDB there, by the same grep that found no update_archive" 1 \
    "$(git -C "$FORK_ROOT" grep -c "MemoryMerkleDB" "$rev" \
        -- 'barretenberg/cpp/src/barretenberg/world_state_reference/' 2>/dev/null | grep -c . || true)"
done

# Second: the same search DOES find it in the patch M14 prepared, so "not carried" is about
# the tree and not about the search.
M14_PATCH="$REPO_ROOT/verification/m14/0001-feat-world_state_reference-archive-tree-so-the-in-me.patch"
assert_file "M14's prepared archive patch is on disk" "$M14_PATCH"
assert_ge "…and it is the thing that adds update_archive, by the same needle" 5 \
  "$(grep -c "update_archive" "$M14_PATCH" || true)"

# And the refusal is what a caller SEES, not only what the driver reported: run it directly.
DIRECT="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { ResidentMerkleDbCannotAnswer, ResidentMerkleWriteOperations }
  from "./src/resident_merkle_operations.ts";
import { MerkleTreeId } from "@aztec/stdlib/trees";
const stub = { callWithBlob: () => null, callWithHandle: () => null };
const db = new ResidentMerkleWriteOperations(stub, 1);
try { await db.getTreeInfo(MerkleTreeId.ARCHIVE); console.log("ANSWERED"); }
catch (e) { console.log(e instanceof ResidentMerkleDbCannotAnswer ? e.method : "WRONG:" + e.message); }
' 2>&1 | tail -1)"
assert_eq "getTreeInfo(ARCHIVE) refuses by name when called directly" "getTreeInfo(ARCHIVE)" "$DIRECT"

# The control for THAT: a tree the module does have is not refused for the same reason — it reaches
# the module, which the stub reports by answering nothing rather than by refusing.
DIRECT_OK="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { ResidentMerkleDbCannotAnswer, ResidentMerkleWriteOperations }
  from "./src/resident_merkle_operations.ts";
import { MerkleTreeId } from "@aztec/stdlib/trees";
const stub = { callWithBlob: () => null, callWithHandle: () => { throw new Error("REACHED-MODULE"); } };
const db = new ResidentMerkleWriteOperations(stub, 1);
try { await db.getTreeInfo(MerkleTreeId.NULLIFIER_TREE); console.log("ANSWERED"); }
catch (e) { console.log(e instanceof ResidentMerkleDbCannotAnswer ? "REFUSED:" + e.method : e.message); }
' 2>&1 | tail -1)"
assert_eq "…while a tree the module DOES have reaches the module instead" "REACHED-MODULE" "$DIRECT_OK"

# ---------------------------------------------------------------------------
# PART 5 — the sealing path is upstream's, so what is missing is the tree and not the loop
# ---------------------------------------------------------------------------

echo "== makeTXEBlockHeader is upstream's, unmodified"

TXE_LOCAL="$(m22_strip_header "$M22_VENDOR/txe_block_creation.ts")"
TXE_ANCHOR="$(m22_anchor_file yarn-project/txe/src/utils/block_creation.ts)"
assert_eq "the vendored block-creation helper is byte-identical to the anchor" "" \
  "$(diff <(printf '%s\n' "$TXE_ANCHOR") <(printf '%s\n' "$TXE_LOCAL") || true)"
for line in "  const archiveInfo = await worldTrees.getTreeInfo(MerkleTreeId.ARCHIVE);" \
            "  await worldTrees.updateArchive(header);" \
            "    lastArchive: new AppendOnlyTreeSnapshot(new Fr(archiveInfo.root), Number(archiveInfo.size)),"; do
  assert_true "upstream's chaining line is present: [$(printf '%s' "$line" | sed 's/^ *//' | cut -c1-48)…]" \
    str_has_line "$TXE_LOCAL" "$line"
done
assert_true "and sealBlock calls it rather than reimplementing the chaining" \
  str_has_sub "$BA" "await makeTXEBlockHeader(guarded as never, globalVariables);"

m22_finish
