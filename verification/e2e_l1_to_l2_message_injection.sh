#!/usr/bin/env bash
# e2e_l1_to_l2_message_injection — the declared stand-in for the L1 inbox.
#
# The verification entry: "An injected L1-to-L2 message appears in the tree at the next block
# boundary and is readable by the AVM's L1TOL2MSGEXISTS opcode."
#
# THE SECOND HALF OF THAT SENTENCE IS NOT DELIVERED AND THIS CHECK SAYS SO RATHER THAN IMPLYING
# OTHERWISE. `L1TOL2MSGEXISTS` is an AVM opcode, so exercising it needs a transaction that CALLS A
# REGISTERED CONTRACT, and upstream's only builder of those is `PublicTxSimulationTester` in
# `simulator/src/public/fixtures/`, which constructs a `NativeWorldStateService` — the package DD-9
# forbids and `verify_differential_containment` asserts against in three places. That is M22's
# outstanding task, unchanged, and it is asserted here as a fact about the fork rather than left as
# a gap somebody has to rediscover.
#
# WHAT IS DELIVERED IS THE HALF THE MILESTONE ACTUALLY OWNS, and it is measured three ways:
#
#   * the message is NOT in the tree while it is only injected — the boundary is a boundary;
#   * it IS a leaf of the L1-to-L2 message tree after the next block;
#   * and it is read back BY INDEX out of the module, not inferred from the root moving. A root
#     that moved says something changed; it does not say WHAT, and "the right leaf at the right
#     index" is the claim.
#
# THE TREE ID COMES FROM THE ENUM AND THAT IS NOT PEDANTRY. M22's seventh recorded defect was a
# magic number whose comment was wrong — `3 /* NOTE_HASH_TREE */`, where `NOTE_HASH_TREE` is 1 and
# 3 is `L1_TO_L2_MESSAGE_TREE` — and it passed because the call under it refused before any tree
# dispatch. The first version of this arm made the mirror-image mistake, reading tree 2
# (`PUBLIC_DATA_TREE`), and reported a plausible size of 128 because that tree is prefilled. The
# driver resolves the id from `MerkleTreeId` and reports the RESOLVED NAME, which this check pins.
#
# Run: just verify-chain-l1-to-l2

TEST_NAME="e2e_l1_to_l2_message_injection"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit
m23_require_anchor
m23_require_arms

# ---------------------------------------------------------------------------
# PART 0 — the tree under test is the one the name says
# ---------------------------------------------------------------------------
echo "== the tree id is resolved from the enum"

TREE_ID="$(m23_arm l1ToL2 treeId)"
TREE_NAME="$(m23_arm l1ToL2 treeIdName)"
assert_eq "the arm names the tree L1_TO_L2_MESSAGE_TREE" "L1_TO_L2_MESSAGE_TREE" "$TREE_NAME"
# The number is READ OUT OF the installed enum rather than typed here, so a protocol renumbering
# fails this rather than silently moving the subject.
ENUM_ID="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { MerkleTreeId } from "@aztec/stdlib/trees";
console.log(MerkleTreeId.L1_TO_L2_MESSAGE_TREE);
' 2>&1 | tail -1)"
assert_eq "…and that is the id @aztec/stdlib gives it" "$ENUM_ID" "$TREE_ID"
# THE CONTROL: the neighbouring ids are different, so "the enum agrees" is not true of any number.
OTHERS="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { MerkleTreeId } from "@aztec/stdlib/trees";
console.log([MerkleTreeId.NULLIFIER_TREE, MerkleTreeId.NOTE_HASH_TREE, MerkleTreeId.PUBLIC_DATA_TREE,
             MerkleTreeId.ARCHIVE].join(","));
' 2>&1 | tail -1)"
assert_false "…and the message tree's id is not one of the other four" \
  str_has_word "$(printf '%s' "$OTHERS" | tr ',' ' ')" "$TREE_ID"

# ---------------------------------------------------------------------------
# PART 1 — the boundary
# ---------------------------------------------------------------------------
echo "== injecting does not touch the tree; the next block does"

SIZE_BEFORE="$(m23_arm l1ToL2 sizeBefore)"
SIZE_INJECT="$(m23_arm l1ToL2 sizeAfterInject)"
SIZE_BLOCK="$(m23_arm l1ToL2 sizeAfterBlock)"
ROOT_BEFORE="$(m23_arm l1ToL2 rootBefore)"
ROOT_INJECT="$(m23_arm l1ToL2 rootAfterInject)"
ROOT_BLOCK="$(m23_arm l1ToL2 rootAfterBlock)"

assert_eq "the message tree starts empty" "0" "$SIZE_BEFORE"
assert_eq "…injecting alone leaves it empty" "$SIZE_BEFORE" "$SIZE_INJECT"
assert_eq "…and the root is unchanged by the injection too" "$ROOT_BEFORE" "$ROOT_INJECT"
assert_eq "the block appends exactly one leaf" "1" "$((SIZE_BLOCK - SIZE_INJECT))"
assert_true "…and the root moves" test "$ROOT_BLOCK" != "$ROOT_INJECT"
assert_true "the roots are field elements rather than MISSING" test "${#ROOT_BEFORE}" -eq 66

# ---------------------------------------------------------------------------
# PART 2 — the leaf, read back by index
# ---------------------------------------------------------------------------
echo "== the leaf at the injected index IS the injected message"

LEAF="$(m23_arm l1ToL2 leaf)"
READ_BACK="$(m23_arm l1ToL2 leafReadBack)"
assert_true "the injected leaf is a field element" test "${#LEAF}" -eq 66
assert_true "the read-back leaf is not MISSING" test "$READ_BACK" != "MISSING"
assert_eq "…and it equals the injected message, at index $SIZE_BEFORE" "$LEAF" "$READ_BACK"
# NOT A TAUTOLOGY: the value is not zero, which is what an unwritten leaf reads as. The first
# version of this arm read the WRONG TREE and got exactly that, which is how the defect was found.
assert_true "…and the message is not the zero field, which an unwritten leaf would be" \
  test "$LEAF" != "0x0000000000000000000000000000000000000000000000000000000000000000"
assert_true "…nor is the value read back" \
  test "$READ_BACK" != "0x0000000000000000000000000000000000000000000000000000000000000000"

echo "== the block records which messages it carried"
assert_eq "the block reports the one message" "[\"$LEAF\"]" "$(m23_arm l1ToL2 blockMessages)"
assert_eq "…and it was block 1" "1" "$(m23_arm l1ToL2 blockNumber)"

# ---------------------------------------------------------------------------
# PART 3 — the shape is TXE's, and the divergence is declared
# ---------------------------------------------------------------------------
echo "== the semantics are TXE's mineBlock({l1ToL2Messages}) and the signature difference is declared"

TXE="$(m23_anchor_file yarn-project/txe/src/oracle/txe_oracle_top_level_context.ts)"
assert_true "TXE declares sendL1ToL2Message with four parts" \
  str_has_sub "$TXE" "async sendL1ToL2Message(content: Fr, secretHash: Fr, sender: EthAddress, recipient: AztecAddress)"
assert_true "…and mineBlock takes l1ToL2Messages" str_has_sub "$TXE" "l1ToL2Messages?: Fr[]"
assert_false "a signature TXE does not have is not found by the same lookup" \
  str_has_sub "$TXE" "async sendL2ToL1Message(content: Fr, secretHash: Fr"

DOC="$(cat "$M23_DOC")"
assert_true "CHAIN-LOOP.md maps sendL1ToL2Message to injectL1ToL2Message" \
  str_has_sub "$DOC" "\`sendL1ToL2Message(content, secretHash, sender, recipient)\` \`:372\` | \`injectL1ToL2Message(leaf)\`"
assert_true "…and says why the four parts are not taken" \
  str_has_sub "$DOC" "because the four parts are an L1 contract's concern"

# ---------------------------------------------------------------------------
# PART 4 — the OPCODE half is not delivered, and the blocker is measured
# ---------------------------------------------------------------------------
echo "== L1TOL2MSGEXISTS is NOT exercised, and the blocker is a fact about the fork"

# The opcode exists — this is not a claim that the AVM lacks it.
VM2_OPCODES="$(git -C "$FORK_ROOT" grep -l 'L1TOL2MSGEXISTS' "$M23_CPP_ANCHOR" \
  -- barretenberg/cpp/src/barretenberg/vm2/ | grep -c . || true)"
assert_ge "the AVM does have an L1TOL2MSGEXISTS opcode" 1 "$VM2_OPCODES"

# The builder that would exercise it constructs a `NativeWorldStateService`. Read at the anchor,
# from the file the class is actually IN — located by name rather than by a path typed here, so a
# move fails loudly instead of silently making this section vacuous.
TESTER_PATH="$(git -C "$FORK_ROOT" grep -l 'class PublicTxSimulationTester' "$M23_CPP_ANCHOR" -- yarn-project/ \
  | sed "s|^$M23_CPP_ANCHOR:||" | head -1)"
assert_eq "PublicTxSimulationTester is where M22 said it is" \
  "yarn-project/simulator/src/public/fixtures/public_tx_simulation_tester.ts" "$TESTER_PATH"
TESTER="$(m23_anchor_file "$TESTER_PATH")"
assert_ge "…and its source was read" 50 "$(printf '%s\n' "$TESTER" | grep -c .)"
assert_true "it reaches NativeWorldStateService" str_has_sub "$TESTER" "NativeWorldStateService"
assert_false "…and a class it does NOT name is not found by the same lookup" \
  str_has_sub "$TESTER" "AvmRuntimeWorldState"

# And nothing of ours claims otherwise.
assert_true "CHAIN-LOOP.md records that the opcode half is outstanding" \
  str_has_sub "$DOC" "\`L1TOL2MSGEXISTS\` is not exercised"

m23_finish
