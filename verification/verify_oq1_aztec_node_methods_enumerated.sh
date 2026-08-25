#!/usr/bin/env bash
# verify_oq1_aztec_node_methods_enumerated — M21, OQ-1.
#
# THE QUESTION. "It takes an `AztecNode` for verifying settled read requests against the note hash
# and nullifier trees. If that is two or three lookups, our adapter is trivial; if it reaches for
# block headers, contract data or log sync, Form B grows a dependency surface."
#
# THE ANSWER, and the point of this check is that it is RE-DERIVED FROM THE ANCHOR every run rather
# than read back out of our own source: `generateSimulatedProvingResult` calls exactly ONE
# `AztecNode` method, `findLeavesIndexes`, twice — once per tree — and upstream has already written
# the narrowing into the type system as `Pick<AztecNode, 'findLeavesIndexes'>`.
#
# WHY RE-DERIVING MATTERS MORE THAN THE ANSWER. The deliverable's words are "so the adapter surface
# is a known quantity rather than A GROWING ONE". A one-off grep answers today's question; a check
# that re-derives it answers next month's. If upstream adds a `node.getBlockHeader(...)` to that
# function, this goes red and the adapter's cost is re-opened before something silently starts
# needing a real node.
#
# THE SCANNER IS A THING UNDER TEST. `node.` is a short needle and the campaign has been bitten
# fourteen times by needles that matched more than they named. Three controls: a method the
# function does NOT call is not found; the scanner IS shown to find `node.` where it exists; and
# the extraction is asserted to have got a plausible number of lines, so a botched range cannot
# report "no calls" as "a small surface".

set -uo pipefail
TEST_NAME="verify_oq1_aztec_node_methods_enumerated"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== $TEST_NAME"

CPP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' \
       "$REPO_ROOT/pins.json")"
assert_ge "the cpp anchor was read from pins.json" 40 "${#CPP}"

at() { ( cd "$FORK_ROOT" && git show "$CPP:$1" ) 2>/dev/null; }

CFS_PATH='yarn-project/pxe/src/contract_function_simulator/contract_function_simulator.ts'
CFS="$(at "$CFS_PATH")"
assert_ge "the file that declares generateSimulatedProvingResult was read at the anchor" 800 \
  "$(printf '%s\n' "$CFS" | grep -c . || true)"

# ---------------------------------------------------------------------------
echo "== 1. the function, and its parameter"
# ---------------------------------------------------------------------------
assert_true "generateSimulatedProvingResult is declared in that file" \
  str_has_line_re "$CFS" '^export async function generateSimulatedProvingResult\($'
assert_true "…and its third parameter is typed AztecNode, which is why OQ-1 exists" \
  str_has_line_re "$CFS" '^ *node: AztecNode,$'
assert_true "…imported from @aztec/stdlib/interfaces/server" \
  str_has_sub "$CFS" "import type { AztecNode } from '@aztec/stdlib/interfaces/server';"

# ---------------------------------------------------------------------------
echo "== 2. every node.* call in the function body, enumerated"
#
# The body is extracted by line range — from the `export async function` line to the next
# top-level `}` — rather than by grepping the whole file, because the file has 926 lines and other
# functions in it also take a node-shaped argument. `verifyReadRequests` is a separate top-level
# function and is enumerated in its own right below, since it is where the parameter goes.
# ---------------------------------------------------------------------------
body_of() { # <function-declaration-regex> -> that function's lines
  printf '%s\n' "$CFS" | awk -v re="$1" '
    $0 ~ re { inside = 1 }
    inside { print }
    inside && /^\}$/ { exit }
  '
}

GSPR="$(body_of '^export async function generateSimulatedProvingResult[(]')"
assert_ge "generateSimulatedProvingResult's body was extracted and is a plausible length" 200 \
  "$(printf '%s\n' "$GSPR" | grep -c . || true)"
assert_true "…and it ends at a top-level brace rather than running to the end of the file" \
  str_has_line_re "$GSPR" '^\}$'

# EVERY `node.<name>` occurrence, as a SET, sorted and unique. A census that is printed and not
# compared is what M20's review found; this is compared as an exact set.
NODE_CALLS="$(printf '%s\n' "$GSPR" | grep -oE '\bnode\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/^node\.//' \
              | LC_ALL=C sort -u || true)"
note "node.* in generateSimulatedProvingResult: [$(printf '%s' "$NODE_CALLS" | tr '\n' ' ')]"
assert_eq "generateSimulatedProvingResult itself makes NO direct node call" "" "$NODE_CALLS"
# It does exactly one thing with the node: hands it on.
if str_has_line_re "$GSPR" '^ *await verifyReadRequests[(]$'; then fw=yes; else fw=no; fi
assert_eq "…it forwards the node to verifyReadRequests and nothing else" "yes" "$fw"
FORWARDS="$(printf '%s\n' "$GSPR" | grep -cE '(^|[^A-Za-z0-9_])node([^A-Za-z0-9_]|$)' || true)"
assert_eq "…and 'node' appears in that body exactly twice: the parameter and the forward" "2" \
  "$FORWARDS"

VRR="$(body_of '^async function verifyReadRequests[(]')"
assert_ge "verifyReadRequests' body was extracted" 40 "$(printf '%s\n' "$VRR" | grep -c . || true)"
VRR_CALLS="$(printf '%s\n' "$VRR" | grep -oE '\bnode\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/^node\.//' \
             | LC_ALL=C sort -u || true)"
note "node.* in verifyReadRequests: [$(printf '%s' "$VRR_CALLS" | tr '\n' ' ')]"
assert_eq "THE WHOLE AztecNode SURFACE OQ-1 ASKED ABOUT IS ONE METHOD" "findLeavesIndexes" "$VRR_CALLS"

# TWO CALLS, ONE PER TREE, and the trees are named. "One method" would still be a growing surface
# if it were called with an unbounded set of tree ids.
N_CALLS="$(printf '%s\n' "$VRR" | grep -cE '\bnode\.findLeavesIndexes\(' || true)"
assert_eq "…called exactly twice" "2" "$N_CALLS"
assert_true "…once for the note hash tree" str_has_line_re "$VRR" 'MerkleTreeId\.NOTE_HASH_TREE,'
assert_true "…and once for the nullifier tree" str_has_line_re "$VRR" 'MerkleTreeId\.NULLIFIER_TREE,'
TREES="$(printf '%s\n' "$VRR" | grep -oE 'MerkleTreeId\.[A-Z_]+' | LC_ALL=C sort -u || true)"
assert_eq "…and those are the only two trees it names" \
  "$(printf 'MerkleTreeId.NOTE_HASH_TREE\nMerkleTreeId.NULLIFIER_TREE')" "$TREES"

# ---------------------------------------------------------------------------
echo "== 3. UPSTREAM HAS ALREADY NARROWED IT, in the type system"
#
# This is the finding that makes the deliverable cheap, and it is asserted rather than described:
# `verifyReadRequests` does not take an `AztecNode`, it takes a `Pick<>` of one method. So the
# enumeration above is not a claim about today's body — upstream's own signature enforces it.
# ---------------------------------------------------------------------------
assert_true "verifyReadRequests' parameter is Pick<AztecNode, 'findLeavesIndexes'>" \
  str_has_line_re "$VRR" "^ *node: Pick<AztecNode, 'findLeavesIndexes'>,$"
assert_true "…so a new node call inside it would not compile without widening that Pick" \
  str_has_sub "$VRR" "Pick<AztecNode, 'findLeavesIndexes'>"

# ---------------------------------------------------------------------------
echo "== 4. controls: the scanner can find things, and does not find things that are not there"
# ---------------------------------------------------------------------------
# (a) A method AztecNode really has, that this function does not call, must NOT be found.
# `getBlockHeader` is NOT one of them, measured: `grep -cw getBlockHeader` over
# `aztec-node.ts` at the anchor is 0, while the five below are 2 each. It was in this list on the
# first draft, which would have made one of the six absences an absence of nothing — the campaign's
# "an absence asked of a tree that excludes the subject by construction", in miniature.
for absent in getContractClass simulatePublicCalls getTxEffect sendTx getChainTips; do
  if str_has_sub "$NODE_CALLS$VRR_CALLS" "$absent"; then found=yes; else found=no; fi
  assert_eq "the enumeration does not report node.$absent, which AztecNode does have" "no" "$found"
done
# …and those names are real, or the six absences above are six absences of nothing. Read from
# upstream's own interface at the anchor.
IFACE="$(at 'yarn-project/stdlib/src/interfaces/aztec-node.ts')"
assert_ge "AztecNode's own declaration was read at the anchor" 200 \
  "$(printf '%s\n' "$IFACE" | grep -c . || true)"
for real in getContractClass simulatePublicCalls getTxEffect sendTx getChainTips findLeavesIndexes; do
  if str_has_word "$IFACE" "$real"; then present=yes; else present=no; fi
  assert_eq "…and $real IS a member of AztecNode, so its absence above is a real absence" \
    "yes" "$present"
done
# The other direction, so "is a member" is a discriminating test rather than one that says yes to
# anything: a plausible name AztecNode does NOT declare must read no.
if str_has_word "$IFACE" "getBlockHeader"; then present=yes; else present=no; fi
assert_eq "…while getBlockHeader, which sounds like one, is not declared there" "no" "$present"
# (b) The scanner IS able to report a node call: plant one in a copy of the body.
PLANTED="$(printf '%s\n' "$VRR"; printf '%s\n' '  await node.getBlockHeader(anchorBlockHash);')"
PLANTED_CALLS="$(printf '%s\n' "$PLANTED" | grep -oE '\bnode\.[A-Za-z_][A-Za-z0-9_]*' \
                 | sed 's/^node\.//' | LC_ALL=C sort -u || true)"
assert_eq "with one planted call the same scanner reports two methods, not one" \
  "$(printf 'findLeavesIndexes\ngetBlockHeader')" "$PLANTED_CALLS"
# (c) The extraction cannot silently return nothing: an unmatched regex must yield an empty body,
#     and the assertions above must therefore be reading a real body.
# A CONTROL THAT PASSED FOR THE WRONG REASON, AND IS WHY THIS ONE HAS A SECOND HALF.
# The first draft's regexes carried `\(`; gawk warned and then died with
# `fatal: invalid regexp: Unmatched ( or \(`, so EVERY extraction returned nothing — and this
# control, which asserts that a non-matching extraction returns nothing, PASSED. An empty answer
# from a crashed tool is indistinguishable from an empty answer from a working one unless the
# working case is asserted beside it.
EMPTY="$(body_of '^export async function thisFunctionDoesNotExist[(]' 2>&1)"
assert_eq "an extraction that matches nothing yields nothing, so a botched range is visible" "0" \
  "$(printf '%s' "$EMPTY" | grep -c . || true)"
assert_not_contains "…and it is empty because nothing matched, not because awk died" \
  "fatal" "$EMPTY"

# ---------------------------------------------------------------------------
echo "== 5. and the surface is measured against what an AztecNode actually is"
#
# "One method" is only interesting beside the size of the thing it is one method of.
# ---------------------------------------------------------------------------
IFACE_METHODS="$(printf '%s\n' "$IFACE" | grep -cE '^ +[a-z][A-Za-z0-9_]*(<[^>]*>)?\(' || true)"
note "AztecNode declares $IFACE_METHODS method(s); Form B needs 1"
assert_ge "AztecNode is a large interface, which is why §8.4 forbids exporting one" 30 "$IFACE_METHODS"

finish
