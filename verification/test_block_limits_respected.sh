#!/usr/bin/env bash
# test_block_limits_respected — M22.
#
# The verification entry: "maxTransactions, maxBlockGas and the abort signal each stop block
# building at the right point, leaving unprocessed transactions requeueable."
#
# FIVE LIMITS, TEN ARMS, AND A DISCRIMINATOR PER LIMIT. The brief is explicit that this check has
# four limits and an abort signal and that each needs its own discriminator — "a block that stops at
# the limit *and* a block that does not reach it". An arm in which the block stops is satisfied by a
# processor that stops for any reason at all, including one that stops after two transactions
# always. So every limit is run twice against the SAME four transactions, differing only in the
# limit's value:
#
#     maxTransactions   2  -> stops after 2      10 -> all four
#     maxBlockGas       tuned to ~2.5 tx -> 2    4x the block -> all four
#     maxBlobFields     tuned to ~2.5 tx -> 2    4x the block -> all four
#     signal            pre-aborted     -> 0     an open signal -> all four
#     deadline          in the past     -> 0     an hour ahead  -> all four
#
# THE GAS LIMIT IS DERIVED FROM A MEASUREMENT, NOT TYPED. The driver reads the L2 gas the
# unlimited block actually used and sets the stopping arm's limit from it. A hand-typed number
# would eventually become a number that stops the block for the wrong reason — and the campaign
# has a recorded instance of exactly that, an assertion named for "an exceptional halt consumes all
# allocated L2 gas" asserted against a hand-typed 6540000.
#
# REQUEUEABLE IS A POSITIVE CLAIM AND IS MADE POSITIVELY. The two transactions `maxTransactionsTwo`
# did not reach are submitted again, in a FRESH block, and are required to process. "They were not
# consumed" is not the claim; "they can be processed later" is.
#
# THE ABORT ARMS ARE ALSO `timeout_race.test.ts`'S REPLACEMENT, and DRIFT.md D20 records why.
# Upstream's test proved a race between a libuv worker thread still running the C++ AVM and
# TypeScript reverting checkpoints. There is no worker thread here — `avm.wasm` runs to completion
# on the caller's stack — and the test is unrunnable anyway, importing `NativeWorldStateService`
# and `CppPublicTxSimulator`, both forbidden by DD-9. Upstream has since DELETED it itself, in
# `96082e32ec5`, for a related reason. What survives the reshaping is the pair of properties that
# were never about threads: a deadline stops block building, and an abort signal stops block
# building. Those are the two arms below, and this check asserts the reasoning is recorded rather
# than the file quietly dropped.
#
# Run: just verify-block-limits

TEST_NAME="test_block_limits_respected"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m22_block.sh"

m22_summary_on_abnormal_exit
m22_require_anchor
m22_require_arms

note "module $AVM_WASM_PATH"
note "sha256 $M22_MODULE_SHA"

ALL_FOUR='["t1","t2","t3","t4"]'

# ---------------------------------------------------------------------------
# PART 0 — preconditions, and the accessor's control
# ---------------------------------------------------------------------------

assert_eq "an arm that does not exist reads MISSING" "MISSING" "$(m22_arm noSuchArm processed)"
assert_eq "the unlimited block processed all four, so the arms below start from a full block" \
  "$ALL_FOUR" "$(m22_arm noLimits processed)"
assert_eq "…and left nothing unprocessed" "[]" "$(m22_arm noLimits unprocessed)"
assert_eq "…and threw nobody out, so every stop below is a LIMIT and not a failure" "[]" \
  "$(m22_arm noLimits failed)"

# ---------------------------------------------------------------------------
# PART 1 — the five limit fields are upstream's, and upstream's loop reads them
# ---------------------------------------------------------------------------

echo "== PublicProcessorLimits is a published type and every field is honoured by upstream's loop"

# The type is upstream's, in the published stdlib, and the deliverable names five fields. Read out
# of the fork rather than out of our own source, so "we honour upstream's limits" is a claim about
# upstream's declaration.
LIMITS_DECL="$(m22_anchor_file yarn-project/stdlib/src/interfaces/block-builder.ts)"
LIMITS_BODY="$(printf '%s\n' "$LIMITS_DECL" | awk '/^export type PublicProcessorLimits = \{/{p=1} p{print} p&&/^\};$/{exit}')"
assert_ge "the PublicProcessorLimits declaration was found and is not empty" 5 \
  "$(printf '%s\n' "$LIMITS_BODY" | grep -c . || true)"
for field in maxTransactions deadline maxBlockGas maxBlobFields signal; do
  assert_true "PublicProcessorLimits declares $field" \
    str_has_line_re "$LIMITS_BODY" "^ *$field\??:"
done
# The control: a field the deliverable does not name, and one that does not exist.
assert_true "…and it declares isBuildingProposal too, which the deliverable does not name" \
  str_has_line_re "$LIMITS_BODY" "^ *isBuildingProposal\??:"
assert_false "…while a field that does not exist is not found by the same needle" \
  str_has_line_re "$LIMITS_BODY" "^ *maxNoSuchLimit\??:"

# And upstream's loop READS each of them, as a whole line in the vendored copy AND in the anchor.
PP_BODY="$(m22_strip_header "$M22_VENDOR/public_processor/public_processor.ts")"
PP_ANCHOR="$(m22_anchor_file yarn-project/simulator/src/public/public_processor/public_processor.ts)"
DESTRUCTURE="    const { maxTransactions, deadline, maxBlockGas, maxBlobFields, isBuildingProposal, signal } = limits;"
assert_true "the vendored loop destructures all six limit fields, in upstream's own line" \
  str_has_line "$PP_BODY" "$DESTRUCTURE"
assert_true "…and that line is the anchor's, unchanged" str_has_line "$PP_ANCHOR" "$DESTRUCTURE"

# The four stopping conditions, as whole lines, in the copy. These are the branches the arms below
# exercise, and naming them here is what ties the measurement to the code that produced it.
for line in "      if (maxTransactions !== undefined && result.length >= maxTransactions) {" \
            "      if (deadline && this.dateProvider.now() > +deadline) {" \
            "      if (signal?.aborted) {" \
            "          totalBlockGas.add(processedTx.gasUsed.totalGas).gtAny(maxBlockGas)"; do
  assert_true "the loop's own stopping branch is present: [$(printf '%s' "$line" | sed 's/^ *//' | cut -c1-52)…]" \
    str_has_line "$PP_BODY" "$line"
done

# ---------------------------------------------------------------------------
# PART 2 — maxTransactions
# ---------------------------------------------------------------------------

echo "== maxTransactions: a block that stops at it, and a block that does not reach it"

assert_eq "maxTransactions=2 processed exactly two" '["t1","t2"]' "$(m22_arm maxTwo processed)"
assert_eq "…and left the other two unprocessed, in submission order" '["t3","t4"]' \
  "$(m22_arm maxTwo unprocessed)"
assert_eq "…and threw nobody out, so the stop is the limit and not a failure" "[]" \
  "$(m22_arm maxTwo failed)"
assert_eq "THE DISCRIMINATOR: maxTransactions=10 does not stop the block" "$ALL_FOUR" \
  "$(m22_arm maxTen processed)"
assert_eq "…and leaves nothing unprocessed" "[]" "$(m22_arm maxTen unprocessed)"

# ---------------------------------------------------------------------------
# PART 3 — maxBlockGas
# ---------------------------------------------------------------------------

echo "== maxBlockGas: derived from what the unlimited block actually used"

PER_TX="$(m22_arm perTxL2Gas '')"
FULL_GAS="$(m22_arm noLimits totalL2Gas)"
assert_true "the per-transaction gas was measured and is non-zero" test "$PER_TX" -gt 0
assert_eq "…and the unlimited block's total is four of them, so the derivation is sound" \
  "$((PER_TX * 4))" "$FULL_GAS"

assert_eq "a gas limit between two and three transactions stops the block at two" '["t1","t2"]' \
  "$(m22_arm gasStops processed)"
assert_eq "…leaving the rest unprocessed" '["t3","t4"]' "$(m22_arm gasStops unprocessed)"
assert_true "…and the gas it did use is under the limit it was given" \
  test "$(m22_arm gasStops totalL2Gas)" -le "$((PER_TX * 2 + PER_TX / 2))"
assert_eq "THE DISCRIMINATOR: four times the block's own gas does not stop it" "$ALL_FOUR" \
  "$(m22_arm gasRoomy processed)"
assert_eq "…and the roomy arm used exactly what the unlimited one did" "$FULL_GAS" \
  "$(m22_arm gasRoomy totalL2Gas)"

# ---------------------------------------------------------------------------
# PART 3b — maxBlobFields
# ---------------------------------------------------------------------------

echo "== maxBlobFields: the limit the deliverable names that had no arm until it was noticed"

PER_BLOB="$(m22_arm perTxBlobFields '')"
FULL_BLOB="$(m22_arm noLimits totalBlobFields)"
assert_true "the per-transaction blob-field count was measured and is non-zero" test "$PER_BLOB" -gt 0
assert_eq "…and the unlimited block's total is four of them" "$((PER_BLOB * 4))" "$FULL_BLOB"

# UPSTREAM CALLS THIS "SILENTLY SKIPPED" AND THAT IS WHY THE ASSERTION IS ABOUT THREE SETS. The
# post-processing arm reverts the transaction's checkpoint and CONTINUES rather than breaking, so a
# skipped transaction is neither processed nor failed — it lands in the unprocessed set, which is
# exactly where a requeueable transaction belongs.
assert_eq "a blob-field limit of two and a half transactions' worth stops the block at two" \
  '["t1","t2"]' "$(m22_arm blobStops processed)"
assert_eq "…and the rest are unprocessed rather than failed" '["t3","t4"]' \
  "$(m22_arm blobStops unprocessed)"
assert_eq "…and none of them is recorded as failed" "[]" "$(m22_arm blobStops failed)"
assert_true "…and the blob fields it did carry are under the limit it was given" \
  test "$(m22_arm blobStops totalBlobFields)" -le "$((PER_BLOB * 2 + PER_BLOB / 2))"
assert_eq "THE DISCRIMINATOR: four times the block's own blob fields does not stop it" "$ALL_FOUR" \
  "$(m22_arm blobRoomy processed)"
assert_eq "…and the roomy arm carried exactly what the unlimited one did" "$FULL_BLOB" \
  "$(m22_arm blobRoomy totalBlobFields)"

# ---------------------------------------------------------------------------
# PART 4 — the abort signal, and the deadline
# ---------------------------------------------------------------------------

echo "== signal and deadline: the two properties timeout_race.test.ts was really about"

assert_eq "a pre-aborted signal stops the block before the first transaction" "[]" \
  "$(m22_arm aborted processed)"
assert_eq "…and every transaction is left unprocessed rather than failed" "$ALL_FOUR" \
  "$(m22_arm aborted unprocessed)"
assert_eq "…and none of them is recorded as failed" "[]" "$(m22_arm aborted failed)"
assert_eq "THE DISCRIMINATOR: an open signal does not stop the block" "$ALL_FOUR" \
  "$(m22_arm notAborted processed)"

assert_eq "a deadline in the past stops the block before the first transaction" "[]" \
  "$(m22_arm pastDeadline processed)"
assert_eq "…and every transaction is left unprocessed rather than failed" "$ALL_FOUR" \
  "$(m22_arm pastDeadline unprocessed)"
assert_eq "…and none of them is recorded as failed" "[]" "$(m22_arm pastDeadline failed)"
assert_eq "THE DISCRIMINATOR: a deadline an hour ahead does not stop the block" "$ALL_FOUR" \
  "$(m22_arm futureDeadline processed)"

# The two stopping arms did not merely produce an empty list: the state reference did not move
# either, so "0 processed" is a block that did nothing rather than a block whose report is empty.
assert_eq "the aborted block and the past-deadline block end in the same state as each other" \
  "$(m22_arm aborted stateReferenceAfter)" "$(m22_arm pastDeadline stateReferenceAfter)"
if [ "$(m22_arm aborted stateReferenceAfter)" = "$(m22_arm notAborted stateReferenceAfter)" ]; then
  fail "the aborted block ended in the same state as the one that ran, so nothing distinguishes them"
else
  pass "…and in a DIFFERENT state from the block that ran, so the stop really stopped something"
fi

# ---------------------------------------------------------------------------
# PART 5 — the unprocessed transactions are REQUEUEABLE
# ---------------------------------------------------------------------------

echo "== requeueable, as a positive claim"

assert_eq "the requeued block was given exactly what maxTransactions=2 did not reach" \
  "$(m22_arm maxTwo unprocessed)" "$(m22_arm requeued submitted)"
assert_eq "…and it processed both of them" '["t3","t4"]' "$(m22_arm requeued processed)"
assert_eq "…with nothing failed" "[]" "$(m22_arm requeued failed)"
assert_eq "…and nothing left over" "[]" "$(m22_arm requeued unprocessed)"
assert_eq "…and they used the gas two transactions use, so they really ran" \
  "$((PER_TX * 2))" "$(m22_arm requeued totalL2Gas)"

# The requeue is not vacuous: the submitted set is non-empty and is a strict subset of the four.
assert_eq "the requeued set is two transactions, not zero" "2" \
  "$(python3 -c '
import json, sys
print(len(json.loads(sys.argv[1])))' "$(m22_arm requeued submitted)")"

# ---------------------------------------------------------------------------
# PART 6 — the resident database's own numbers, and its refusals
# ---------------------------------------------------------------------------

echo "== the adapter underneath: tree heights from the protocol, refusals by name"

# THE TREE HEIGHTS ARE THE PROTOCOL'S. The first draft of `resident_merkle_operations.ts` typed
# 40/40/40/39/30 into a table; the protocol says 42/42/40/36/30. Four of the five were wrong and
# nothing in a block would have failed on it, because `depth` in a `TreeInfo` is read by nobody on
# this path. So the mapping is asserted against `@aztec/constants` here.
HEIGHTS="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { ARCHIVE_HEIGHT, L1_TO_L2_MSG_TREE_HEIGHT, NOTE_HASH_TREE_HEIGHT, NULLIFIER_TREE_HEIGHT,
         PUBLIC_DATA_TREE_HEIGHT } from "@aztec/constants";
import { MerkleTreeId } from "@aztec/stdlib/trees";
import { TREE_HEIGHTS } from "./src/resident_merkle_operations.ts";
const want = {
  [MerkleTreeId.NULLIFIER_TREE]: NULLIFIER_TREE_HEIGHT,
  [MerkleTreeId.NOTE_HASH_TREE]: NOTE_HASH_TREE_HEIGHT,
  [MerkleTreeId.PUBLIC_DATA_TREE]: PUBLIC_DATA_TREE_HEIGHT,
  [MerkleTreeId.L1_TO_L2_MESSAGE_TREE]: L1_TO_L2_MSG_TREE_HEIGHT,
  [MerkleTreeId.ARCHIVE]: ARCHIVE_HEIGHT,
};
const bad = Object.keys(want).filter(k => TREE_HEIGHTS[k] !== want[k]);
console.log(bad.length === 0 ? "AGREE" : "DISAGREE " + bad.join(","));
console.log(Object.keys(want).map(k => want[k]).join("/"));
' 2>&1 | tail -2)"
assert_eq "every tree height in the adapter is the protocol constant of the same name" "AGREE" \
  "$(printf '%s\n' "$HEIGHTS" | head -1)"
assert_eq "…and they are the five distinct heights the protocol declares, not five copies of one" \
  "42/42/40/36/30" "$(printf '%s\n' "$HEIGHTS" | tail -1)"

# The refusal census, by name and in both directions. `REFUSING_METHODS` and `ANSWERING_METHODS`
# are exported so this is a set comparison rather than a grep over prose.
CENSUS="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { ANSWERING_METHODS, REFUSING_METHODS } from "./src/resident_merkle_operations.ts";
import { REFUSING_CONTRACT_READS } from "./src/resident_contracts_db.ts";
console.log(REFUSING_METHODS.join(" "));
console.log(ANSWERING_METHODS.length);
console.log(REFUSING_CONTRACT_READS.join(" "));
' 2>&1 | tail -3)"
assert_eq "the merkle adapter refuses exactly these eight methods" \
  "batchInsert updateArchive getInitialHeader getIpcPath findLeafIndices findLeafIndicesAfter findSiblingPaths getBlockNumbersForLeafIndices" \
  "$(printf '%s\n' "$CENSUS" | sed -n 1p)"
# THE CLAUSE "which is the size of LowLevelMerkleDBInterface" WAS REMOVED FROM THIS DESCRIPTION.
# Both sets happen to have fourteen members and they are NOT THE SAME FOURTEEN — one is a subset of
# upstream's TypeScript `MerkleTreeWriteOperations`, the other is the C++ host interface — so the
# clause asserted a correspondence the body never tested, which is the catalogued form of "an
# assertion whose NAME claims a relationship its body never tests".
assert_eq "…and answers fourteen methods out of the module" "14" \
  "$(printf '%s\n' "$CENSUS" | sed -n 2p)"
assert_eq "the contracts adapter refuses exactly the four reads" \
  "getContractInstance getContractClass getBytecodeCommitment getDebugFunctionName" \
  "$(printf '%s\n' "$CENSUS" | sed -n 3p)"

# EXECUTED, not read: each refusing method throws its own error type, naming itself. Run against a
# module stub, because the refusals are decided before any export is reached — which is itself the
# claim, since a refusal that needed the module could not be relied on when the module is absent.
REFUSALS="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { REFUSING_METHODS, ResidentMerkleDbCannotAnswer, ResidentMerkleWriteOperations }
  from "./src/resident_merkle_operations.ts";
const stub = { callWithBlob: () => { throw new Error("the module was reached"); },
               callWithHandle: () => { throw new Error("the module was reached"); } };
const db = new ResidentMerkleWriteOperations(stub, 1);
const out = [];
for (const m of REFUSING_METHODS) {
  try {
    const r = db[m](0, [], 0);
    if (r && typeof r.then === "function") { await r; }
    out.push(m + "=RETURNED");
  } catch (e) {
    out.push(m + "=" + (e instanceof ResidentMerkleDbCannotAnswer ? e.method : "WRONG:" + e.message));
  }
}
console.log(out.join(" "));
' 2>&1 | tail -1)"
assert_eq "every refusing method throws the adapter's own error, naming itself" \
  "batchInsert=batchInsert updateArchive=updateArchive getInitialHeader=getInitialHeader getIpcPath=getIpcPath findLeafIndices=findLeafIndices findLeafIndicesAfter=findLeafIndicesAfter findSiblingPaths=findSiblingPaths getBlockNumbersForLeafIndices=getBlockNumbersForLeafIndices" \
  "$REFUSALS"

# THE CONTROL FOR THAT: the class is not "throws at everything". A method that ANSWERS reaches the
# module — proved by the stub's own throw arriving instead of the adapter's.
ANSWERED="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { ResidentMerkleDbCannotAnswer, ResidentMerkleWriteOperations }
  from "./src/resident_merkle_operations.ts";
const stub = { callWithBlob: () => { throw new Error("REACHED-MODULE"); },
               callWithHandle: () => { throw new Error("REACHED-MODULE"); } };
const db = new ResidentMerkleWriteOperations(stub, 1);
try { await db.getStateReference(); console.log("NO-THROW"); }
catch (e) { console.log(e instanceof ResidentMerkleDbCannotAnswer ? "REFUSED" : e.message); }
' 2>&1 | tail -1)"
assert_eq "an ANSWERING method reaches the module instead of refusing" "REACHED-MODULE" "$ANSWERED"

echo "== the contracts adapter's deferred-registration seam, exercised against a recording stub"

# THIS SECTION EXISTS BECAUSE RI-68'S `experiment:` LINE CLAIMED IT. Nothing in the block arms
# registers a contract — the mock transactions publish none — so `addNewContracts`, `flush`,
# `registerClass` and `registerInstance` had no exercise at all while the inventory entry said they
# did. That is prose drifting from measurement inside the entry that documents the code, which is
# the defect this campaign has met at an implementation agent, a review agent and a reviewer
# reviewing that very defect. It is measured now, against a RECORDING STUB rather than the module,
# because the seam is about queueing and de-duplication and needs no wasm.
REG="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { Fr } from "@aztec/foundation/curves/bn254";
import { ResidentContractsDB } from "./src/resident_contracts_db.ts";
const sent = [];
const stub = { callWithBlob: (name) => { sent.push(name); return null; }, callWithHandle: () => null };
const db = new ResidentContractsDB(stub, 1);
const cls = { id: new Fr(11n), artifactHash: new Fr(12n), privateFunctionsRoot: new Fr(13n),
              packedBytecode: Buffer.from([1, 2, 3]) };
const out = [];
out.push("queued0=" + db.pendingRegistrations);
out.push("class1=" + (await db.registerClass(cls)));
out.push("class2=" + (await db.registerClass(cls)));           // deduplicated
out.push("sent=" + sent.join(","));
// The deferred half: queue two transactions worth by hand, then flush.
db["queue"].push({ classes: [{ ...cls, id: new Fr(21n) }], instances: [] });
db["queue"].push({ classes: [], instances: [] });
out.push("queuedBefore=" + db.pendingRegistrations);
const flushed = await db.flush();
out.push("flushed=" + flushed.classes + "/" + flushed.instances);
out.push("queuedAfter=" + db.pendingRegistrations);
console.log(out.join(" "));
' 2>&1 | tail -1)"
note "$REG"
assert_contains "the queue starts empty" "queued0=0" "$REG"
assert_contains "a class is SENT the first time" "class1=true" "$REG"
assert_contains "…and de-duplicated the second, so a repeated deployment is not double-registered" \
  "class2=false" "$REG"
assert_contains "…and exactly one blob reached the module's registration export" \
  "sent=avm_contract_db_register_class " "$REG"
assert_contains "two queued entries are visible BEFORE the flush" "queuedBefore=2" "$REG"
assert_contains "…the flush reports what it SENT rather than what was queued" "flushed=1/0" "$REG"
assert_contains "…and the queue is empty after it" "queuedAfter=0" "$REG"

# The block arms' own honest state, asserted rather than left to be assumed: NOTHING was registered
# during any block, because the mock transactions publish no contracts. A number that is zero and is
# asserted to be zero is a fact; one that is zero and unasserted is an absence nobody noticed.
assert_eq "no block arm registered a contract, because mockTx publishes none" '{"classes":0,"instances":0}' \
  "$(m22_arm noLimits registrations 2>/dev/null || echo MISSING)"

# ---------------------------------------------------------------------------
# PART 8 — timeout_race.test.ts: reshaped, with the reasoning recorded
# ---------------------------------------------------------------------------

echo "== the reshaping of timeout_race.test.ts is recorded, and its three premises are true"

# 1. It exists at the ts anchor.
TR_PATH="yarn-project/simulator/src/public/public_processor/apps_tests/timeout_race.test.ts"
TR_BODY="$(m22_anchor_file "$TR_PATH")"
assert_ge "upstream's timeout_race.test.ts exists at the ts anchor and is a real file" 300 \
  "$(printf '%s\n' "$TR_BODY" | grep -c . || true)"

# 2. Its subject is a worker thread and a native handle — its own words.
assert_true "its header names the libuv worker thread as the cause" \
  str_has_sub "$TR_BODY" "The C++ simulation continues running on a libuv worker thread"
assert_true "…and the native handle" str_has_sub "$TR_BODY" "It directly accesses WorldState via the native handle"
assert_true "…and it imports NativeWorldStateService, which DD-9 forbids here" \
  str_has_sub "$TR_BODY" "import { ForkCheckpoint, NativeWorldStateService } from '@aztec/world-state';"
assert_true "…and CppPublicTxSimulator, which reaches the NAPI AVM" \
  str_has_sub "$TR_BODY" "cpp_public_tx_simulator.js"

# 3. UPSTREAM DELETED IT. Absent at the cpp anchor and at HEAD, and the deleting commit is named.
CPP_ANCHOR="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' "$REPO_ROOT/pins.json")"
assert_false "it is ABSENT at the cpp anchor — upstream deleted it" \
  git -C "$FORK_ROOT" cat-file -e "$CPP_ANCHOR:$TR_PATH"
assert_false "…and absent at upstream HEAD" \
  git -C "$FORK_ROOT" cat-file -e "$(git -C "$FORK_ROOT" rev-parse HEAD):$TR_PATH"
# The control: a SIBLING test in the same directory IS present at both, so the absence is the
# file's and not the directory's.
SIBLING="yarn-project/simulator/src/public/public_processor/apps_tests/token.test.ts"
assert_true "…while its sibling token.test.ts IS present at the cpp anchor, so the absence is the file's" \
  git -C "$FORK_ROOT" cat-file -e "$CPP_ANCHOR:$SIBLING"

DELETING_COMMIT="$(git -C "$FORK_ROOT" log --oneline --diff-filter=D -1 --format=%h -- "$TR_PATH" 2>/dev/null)"
assert_true "the deleting commit is nameable" test -n "$DELETING_COMMIT"
assert_contains "…and its subject is the move to an out-of-process simulator" \
  "cut simulator over to generated bb-avm-sim IPC service" \
  "$(git -C "$FORK_ROOT" log -1 --format=%s "$DELETING_COMMIT" 2>/dev/null)"

# 4. It is NOT vendored here, and the reasoning IS recorded — in DRIFT.md, as a real entry.
assert_false "the file is not vendored into this tree" \
  test -e "$M22_VENDOR/public_processor/apps_tests/timeout_race.test.ts"
assert_eq "no copy of it exists anywhere under orchestration/" "0" \
  "$(find "$ORCH_DIR" -name 'timeout_race*' -not -path '*/node_modules/*' 2>/dev/null | grep -c . || true)"

DRIFT="$(cat "$REPO_ROOT/DRIFT.md")"
assert_true "DRIFT.md carries an entry for it" str_has_line "$DRIFT" "- id: D20"
assert_true "…and the entry names the file" str_has_sub "$DRIFT" "\`timeout_race.test.ts\` tests a race this runtime cannot have"
assert_true "…and names the deleting commit, so the third premise is written down and not only checked here" \
  str_has_sub "$DRIFT" "96082e32ec5"
assert_true "…and names what replaced it" str_has_sub "$DRIFT" "test_block_limits_respected"
# The needle is not satisfied by the vocabulary alone: an id that is not in the ledger is absent.
assert_false "…and an entry id the ledger does not have is not found by the same needle" \
  str_has_line "$DRIFT" "- id: D99"

# 5. The property the reshaping keeps — no `cancel` on this simulator, because there is nothing to
#    cancel — is asserted rather than described.
WAPTS="$(cat "$ORCH_SRC/wasm_avm_public_tx_simulator.ts")"
assert_true "the wasm simulator's own source says why it declares no cancel" \
  str_has_sub "$WAPTS" "a wasm instance runs to completion on the"
CANCEL="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { WasmAvmPublicTxSimulator } from "./src/wasm_avm_public_tx_simulator.ts";
console.log(typeof WasmAvmPublicTxSimulator.prototype.cancel);
' 2>&1 | tail -1)"
assert_eq "…and it really has no cancel method, which is how a caller finds out" "undefined" "$CANCEL"
assert_eq "…while it does have the simulate the interface requires" "function" \
  "$(cd "$ORCH_DIR" && node --input-type=module -e '
import { WasmAvmPublicTxSimulator } from "./src/wasm_avm_public_tx_simulator.ts";
console.log(typeof WasmAvmPublicTxSimulator.prototype.simulate);
' 2>&1 | tail -1)"

m22_finish
