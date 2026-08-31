#!/usr/bin/env bash
# test_settled_read_request_verification — M21.
#
# The verification entry: "A read request against a settled note hash verifies through the in-memory
# world state, and one against an unsettled hash is rejected."
#
# ===========================================================================================
# THE STATED ROUTE NEVER EXISTED, WHICH IS A STRONGER STATEMENT THAN "IT IS BLOCKED".
# ===========================================================================================
#
# This entry said what was pending was "driving it through upstream's own `verifyReadRequests`,
# which lives in the file that needs `@aztec/pxe`". Measured on 2026-08-31 and RE-DERIVED HERE on
# every run rather than quoted: `verifyReadRequests` is a bare `async function` with exactly TWO
# references in the whole package — its definition and its single internal call site — and
# `@aztec/pxe`'s exports map has no path that reaches it. **So installing or vendoring `@aztec/pxe`
# would never have produced that function.** A blocker that names an impossible remedy is worse than
# one that names none, because the remedy closes the search; this check retires it by measurement.
#
# WHAT THE ENTRY ACTUALLY ASKS FOR IS THE SETTLEMENT QUESTION, and that is answerable here. Upstream
# narrowed the surface itself: `verifyReadRequests(node: Pick<AztecNode, 'findLeavesIndexes'>, …)`,
# and its body calls that one method twice — once for `NOTE_HASH_TREE` and once for
# `NULLIFIER_TREE`. `ResidentSettledReadSource` implements exactly that method over the world state
# resident in `avm.wasm`, and an `undefined` from it is what upstream reads as "this leaf has not
# settled".
#
# ===========================================================================================
# WHAT `test_aztec_node_adapter_surface_minimal` DOES NOT DO, WHICH IS WHY THIS CHECK EXISTS.
# ===========================================================================================
#
# That check says so in its own words: *"This check is about the SURFACE, not about the world
# state"*. Its module is a recorder that answers `{is_already_present: true, index: 42}` to
# everything, and its note-hash arm feeds the index by hand. So nothing has ever asked the REAL
# resident world state whether a leaf has settled. This check does, against a built `avm.wasm`:
#
#   NULLIFIER (an INDEXED tree, answered by the module itself)
#     before the insert  -> undefined            the unsettled answer
#     after the insert   -> a real index         the settled answer
#     a value never inserted -> undefined        so it is a lookup and not a constant
#     AND the index is CONFIRMED INDEPENDENTLY: the leaf preimage the world state holds at that
#     index carries the value asked for. An index that is merely non-`undefined` is what
#     `is_already_present` exists to prevent — the low leaf of an ABSENT value is its predecessor,
#     which is a real index for a leaf that is not there.
#
#   NOTE HASH (an APPEND-ONLY tree; the exported surface has no value-to-index method, so the index
#              is kept on this side as the appends happen — the departure `settled_read_source.ts`
#              records)
#     before the append  -> undefined
#     after the append   -> the index the append used
#     AND that index is CONFIRMED against the tree: `getLeafValue(NOTE_HASH_TREE, index)` returns
#     the hash. The index the source reports addresses the leaf the world state actually holds.
#     a hash never appended -> undefined
#
# BOTH DIRECTIONS, ON BOTH TREES, EACH WITH THE "BEFORE" ARM THAT MAKES THE "AFTER" ARM MEAN
# SOMETHING. A source that answered an index for everything passes the settled half; one that
# answered `undefined` for everything passes the unsettled half; neither passes both.
#
# Run: just verify-settled-reads

set -uo pipefail
TEST_NAME="test_settled_read_request_verification"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m21_form_b.sh"
. "$VERIFY_DIR/lib_token_blocks.sh"

tb_summary_on_abnormal_exit
echo "== $TEST_NAME"
m21_prepare
tb_require_module
note "module $AVM_WASM_PATH"
note "sha256 $TB_MODULE_SHA"

# ---------------------------------------------------------------------------
# PART 1 — THE STATED BLOCKER, RETIRED BY MEASUREMENT AT THE PINNED ANCHOR
# ---------------------------------------------------------------------------

CPP_ANCHOR="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' "$REPO_ROOT/pins.json")"
CFS="yarn-project/pxe/src/contract_function_simulator/contract_function_simulator.ts"
CFS_SRC="$(git -C "$FORK_ROOT" show "$CPP_ANCHOR:$CFS" 2>/dev/null)" \
  || die "the fork at $FORK_ROOT has no $CFS at $CPP_ANCHOR (this check's premise is stale)"

assert_ge "the file the blocker names is a real file with real content" 800 \
  "$(printf '%s\n' "$CFS_SRC" | wc -l | tr -d ' ')"
assert_true "verifyReadRequests is declared as a BARE async function, not an exported one" \
  str_has_line_re "$CFS_SRC" '^async function verifyReadRequests\('
assert_false "…and there is no 'export' in front of it anywhere in the file" \
  str_has_line_re "$CFS_SRC" '^export (async )?function verifyReadRequests\('
assert_eq "it has exactly two references in the whole package: its definition and one call site" \
  "2" "$(git -C "$FORK_ROOT" grep -c "verifyReadRequests" "$CPP_ANCHOR" -- yarn-project/pxe \
        | awk -F: '{s+=$NF} END {print s+0}')"
# THE CONTROL FOR THAT COUNT: a symbol in the same file that IS exported has more, so the counter is
# an instrument that can produce a different answer rather than one that always says two.
assert_ge "a symbol the same package really does export is referenced more widely" 3 \
  "$(git -C "$FORK_ROOT" grep -c "ContractFunctionSimulator" "$CPP_ANCHOR" -- yarn-project/pxe \
        | awk -F: '{s+=$NF} END {print s+0}')"

PXE_EXPORTS="$(git -C "$FORK_ROOT" show "$CPP_ANCHOR:yarn-project/pxe/package.json" \
  | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("exports",{}).keys()))')"
assert_ge "the package declares an exports map with several entry points" 4 \
  "$(printf '%s\n' "$PXE_EXPORTS" | wc -l | tr -d ' ')"
SIM_INDEX="$(git -C "$FORK_ROOT" show \
  "$CPP_ANCHOR:yarn-project/pxe/src/contract_function_simulator/index.ts" 2>/dev/null)" \
  || die "the simulator entry point named by the exports map does not exist at $CPP_ANCHOR"
assert_false "the entry point that comes closest does not re-export verifyReadRequests" \
  str_has_sub "$SIM_INDEX" "verifyReadRequests"
# The control: that entry point DOES re-export things, so the absence above is not an empty file.
assert_true "…and it does re-export other names, so the absence is a fact about this one" \
  str_has_sub "$SIM_INDEX" "export {"

# ---------------------------------------------------------------------------
# PART 2 — THE TREES UPSTREAM ASKS ABOUT, RE-DERIVED RATHER THAN RESTATED
# ---------------------------------------------------------------------------

BODY="$(printf '%s\n' "$CFS_SRC" | awk '/^async function verifyReadRequests\(/,/^}/')"
assert_ge "the function's body was located" 20 "$(printf '%s\n' "$BODY" | wc -l | tr -d ' ')"
DECLARED_TREES="$(printf '%s\n' "$BODY" | grep -o 'MerkleTreeId\.[A-Z_]*' | sed 's/MerkleTreeId\.//' | paste -sd, -)"
assert_eq "it asks about exactly two trees, in this order" "NOTE_HASH_TREE,NULLIFIER_TREE" "$DECLARED_TREES"
assert_true "and the runtime's SETTLED_READ_TREES names them in the same order" \
  str_has_sub "$(cat "$M21_SRC/settled_read_source.ts")" \
  "MerkleTreeId.NOTE_HASH_TREE,
  MerkleTreeId.NULLIFIER_TREE,"
# ONE CALL PER TREE, AND THE EXPECTATION IS DERIVED FROM THE TREE LIST RATHER THAN TYPED.
# The first version of this assertion expected 1 and went red at 2 — which is what
# `settled_read_source.ts`'s own header says in as many words ("its body calls
# `node.findLeavesIndexes(...)` twice"). A number typed into a check is a constant; this one is
# now the length of the list the line above derived.
TREE_COUNT="$(printf '%s' "$DECLARED_TREES" | awk -F, '{print NF}')"
assert_eq "the only node method it reaches for is findLeavesIndexes, once per tree" \
  "$TREE_COUNT" "$(printf '%s\n' "$BODY" | grep -c 'node\.findLeavesIndexes' | tr -d ' ')"
assert_eq "and it reaches for no OTHER node method at all" "0" \
  "$(printf '%s\n' "$BODY" | grep -o 'node\.[a-zA-Z]*' | grep -vc 'node\.findLeavesIndexes' | tr -d ' ')"

# ---------------------------------------------------------------------------
# PART 3 — THE PROBE: the real resident world state, both trees, both directions
# ---------------------------------------------------------------------------

PROBE="$(cat <<EOS
import { MerkleTreeId } from '@aztec/stdlib/trees';
import { Fr } from '@aztec/foundation/curves/bn254';

import { compileAvm, instantiateAvm } from '$REPO_ROOT/node-host/src/loader.ts';
import { ResidentMerkleDb } from '$M21_SRC/resident_db.ts';
import { ResidentMerkleWriteOperations } from '$M21_SRC/resident_merkle_operations.ts';
import { ResidentSettledReadSource, SETTLED_READ_TREES } from '$M21_SRC/settled_read_source.ts';

const line = (k, v) => console.log(\`\${k} \${v}\`);
const show = (v) => (v === undefined ? 'undefined' : String(v));

const reactor = await instantiateAvm(await compileAvm('$AVM_WASM_PATH'));
const handle = reactor.createMerkleDb();
const write = new ResidentMerkleWriteOperations(reactor, handle);
const seeding = new ResidentMerkleDb(reactor, handle);
// THE SAME HANDLE, deliberately: the source reads the world state the writes went into, rather
// than a second boundary with its own idea of the revision.
const source = new ResidentSettledReadSource(reactor, handle);

const NULLIFIER = SETTLED_READ_TREES[1];
const NOTE_HASH = SETTLED_READ_TREES[0];

// ---- the nullifier tree: an INDEXED tree the module can search itself ------
const settledNullifier = new Fr(918273645n);
const neverInserted = new Fr(918273646n);
line('nullifier.before', show((await source.findLeavesIndexes(null, NULLIFIER, [settledNullifier]))[0]));
seeding.insertNullifier(settledNullifier);
const afterIdx = (await source.findLeavesIndexes(null, NULLIFIER, [settledNullifier]))[0];
line('nullifier.after', show(afterIdx));
line('nullifier.unsettled', show((await source.findLeavesIndexes(null, NULLIFIER, [neverInserted]))[0]));
// THE INDEPENDENT CONFIRMATION: the world state's own leaf preimage at that index must carry the
// value. A non-undefined index is not the claim; the right index is.
let preimageValue = 'unread';
try {
  const pre = await write.getLeafPreimage(NULLIFIER, afterIdx);
  const v = pre?.leaf?.value ?? pre?.value ?? pre?.leaf?.nullifier;
  preimageValue = v === undefined ? 'no-value-field' : String(BigInt(v.toString()));
} catch (e) {
  preimageValue = \`threw:\${e?.constructor?.name ?? 'Error'}\`;
}
line('nullifier.preimageValue', preimageValue);
line('nullifier.expectedValue', settledNullifier.toBigInt());

// ---- the note-hash tree: APPEND-ONLY, so the index is kept on this side ----
const settledHash = new Fr(555000111n);
const neverAppended = new Fr(555000112n);
line('noteHash.beforeAppend', show((await source.findLeavesIndexes(null, NOTE_HASH, [settledHash]))[0]));
line('noteHash.indexFedBefore', source.noteHashesAppended);
const info = await write.getTreeInfo(NOTE_HASH);
const appendIndex = BigInt(info.size);
await write.appendLeaves(NOTE_HASH, [settledHash]);
source.noteHashAppended(settledHash, appendIndex);
line('noteHash.afterAppend', show((await source.findLeavesIndexes(null, NOTE_HASH, [settledHash]))[0]));
line('noteHash.appendIndex', appendIndex);
line('noteHash.indexFedAfter', source.noteHashesAppended);
line('noteHash.unsettled', show((await source.findLeavesIndexes(null, NOTE_HASH, [neverAppended]))[0]));
// THE INDEPENDENT CONFIRMATION for this tree: the leaf the world state holds at that index.
const leaf = await write.getLeafValue(NOTE_HASH, appendIndex);
line('noteHash.leafAtIndex', leaf === undefined ? 'undefined' : leaf.toBigInt());
line('noteHash.expectedValue', settledHash.toBigInt());
// The tree really grew, so the append is a write and not a no-op.
const after = await write.getTreeInfo(NOTE_HASH);
line('noteHash.sizeBefore', BigInt(info.size));
line('noteHash.sizeAfter', BigInt(after.size));

reactor.destroyMerkleDb(handle);
line('settledReads.done', 1);
EOS
)"

OUT="$M21_WORK/probes/settled.out"
m21_probe settled "$PROBE" >"$OUT"
RC=$?
assert_eq "the settled-read probe exited 0" "0" "$RC"
[ "$RC" -eq 0 ] || die "the settled-read probe exited $RC. Its stderr, which is where the reason is:
$(head -20 "$(m21_probe_err settled)")"
require_complete_transcript "$OUT" settledReads.done "the settled-read probe's"

f() { m21_field "$OUT" "$1"; }

# ---------------------------------------------------------------------------
# PART 4 — THE NULLIFIER TREE, BOTH DIRECTIONS
# ---------------------------------------------------------------------------

assert_eq "before the insert the world state reports the leaf as NOT settled" \
  "undefined" "$(f nullifier.before)"
assert_true "after the insert it reports an index" test "$(f nullifier.after)" != "undefined"
assert_ge "…and it is a real index" 0 "$(f nullifier.after)"
assert_eq "a value that was never inserted is still reported unsettled" \
  "undefined" "$(f nullifier.unsettled)"
assert_eq "and the world state's own leaf preimage at that index carries the value asked for" \
  "$(f nullifier.expectedValue)" "$(f nullifier.preimageValue)"

# ---------------------------------------------------------------------------
# PART 5 — THE NOTE-HASH TREE, BOTH DIRECTIONS
# ---------------------------------------------------------------------------

assert_eq "before the append the hash is reported NOT settled" "undefined" "$(f noteHash.beforeAppend)"
assert_eq "…and the index says it has been told about nothing, which is a fact not an absence" \
  "0" "$(f noteHash.indexFedBefore)"
assert_eq "after the append the hash resolves to the index the append used" \
  "$(f noteHash.appendIndex)" "$(f noteHash.afterAppend)"
assert_eq "…and the index says it has been told about one" "1" "$(f noteHash.indexFedAfter)"
assert_eq "a hash that was never appended is still reported unsettled" \
  "undefined" "$(f noteHash.unsettled)"
assert_eq "and the leaf the WORLD STATE holds at that index is the hash" \
  "$(f noteHash.expectedValue)" "$(f noteHash.leafAtIndex)"
assert_true "the append really grew the tree, so it was a write and not a no-op" \
  test "$(f noteHash.sizeAfter)" -gt "$(f noteHash.sizeBefore)"

# ---------------------------------------------------------------------------
# PART 6 — THE TWO ANSWERS ARE DIFFERENT ANSWERS
# ---------------------------------------------------------------------------
#
# A source that answered an index for everything satisfies the settled half; one that answered
# `undefined` for everything satisfies the unsettled half. This is the assertion that neither does.

assert_true "the settled and unsettled answers differ on the nullifier tree" \
  test "$(f nullifier.after)" != "$(f nullifier.unsettled)"
assert_true "and on the note-hash tree" test "$(f noteHash.afterAppend)" != "$(f noteHash.unsettled)"
assert_eq "the two trees' settled answers are indexes rather than the same one value" "2" \
  "$(printf '%s\n%s\n' "$(f nullifier.after)" "$(f noteHash.afterAppend)" | sort -u | wc -l | tr -d ' ')"

finish
