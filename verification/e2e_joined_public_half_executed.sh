#!/usr/bin/env bash
# e2e_joined_public_half_executed
#
# M40 verification: **the PUBLIC half of a transaction whose private half executed, executed.**
#
# ===========================================================================================
# WHAT THIS IS FOR
# ===========================================================================================
#
# M39 got `Parent.enqueue_calls_to_child_with_nested_first`'s private half to run — two private
# frames, two ENQUEUED public calls — and `NESTED-CALLS.md` §6 records, in as many words, that the
# enqueued calls are not run. This check is about running them, and about the one thing that makes
# "ran them" different from "ran calls that resemble them":
#
#   **THE CALLDATA IS THE CIRCUIT'S, NOT A RE-ENCODING.** A private circuit commits to each enqueued
#   call by a HASH of its calldata. Every other driver in this repository names a function and its
#   arguments and encodes them — a SECOND producer of a value the circuit already produced, free to
#   disagree with it. This fixture is built to expose exactly that: **its two enqueued calls differ
#   by their ARGUMENT (10 and 20) and not by their function**, so a re-declaration that got the
#   argument wrong would run two identical calls and every count in this file would agree with it.
#
# So the preimage is read out of the transaction's own execution cache, the request is rebuilt from
# it with upstream's `PublicCallRequest.fromCalldata`, and the hash that comes back is compared with
# the one the circuit committed to. That comparison is what this check is mostly about, and it has
# an arm that makes it fail.
#
# ===========================================================================================
# THE CONTROLS ARE PRODUCED, NOT DECLARED
# ===========================================================================================
#
#   `corruptCalldata`        one field of one enqueued call's calldata changed and nothing else.
#                            An identity nobody has seen fail is an identity nobody has calibrated.
#   `noDeploymentNullifier`  the callee's deployment nullifier not seeded. M29 measured that the AVM
#                            then answers the address with no bytecode and executes exactly ONE
#                            instruction while the block still reports the transaction `processed`.
#                            Without it, "146 executed steps" is a floor nobody has watched fail.

set -uo pipefail

TEST_NAME="e2e_joined_public_half_executed"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# lib_m23_chain.sh first: lib_m27_browser.sh dies on M23_REQUIRED_EXPORTS otherwise.
. "$(dirname "${BASH_SOURCE[0]}")/lib_m23_chain.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m27_browser.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m38_private_trace.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m39_nested.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m40_transaction.sh"
m40_summary_on_abnormal_exit

m40_require_arms

SUBJECT=bothHalves

# ===========================================================================================
echo "== 0. THE PRECONDITION: every field this check reads is PRESENT"
# ===========================================================================================
#
# ONE ASSERTION NAMING EVERY ABSENT FIELD, run before the first comparison, with a `die` behind it.
# M29's remedy for two missing keys agreeing: a report with no data in it is a failure and not a
# smaller check.
m38_absent \
  "privateOutcome=$(m40_arm "$SUBJECT.report.run.outcome")" \
  "joinId=$(m40_arm "$SUBJECT.report.joinId")" \
  "enqueued=$(m40_arm "$SUBJECT.report.enqueued")" \
  "publicCalls=$(m40_arm "$SUBJECT.report.publicHalf.calls")" \
  "executedCount=$(m40_arm "$SUBJECT.report.publicHalf.executed.count")" \
  "revertCode=$(m40_arm "$SUBJECT.report.publicHalf.revertCode")" \
  "outcome=$(m40_arm "$SUBJECT.report.publicHalf.outcome")" \
  "declaresInitializer=$(m40_arm "$SUBJECT.report.publicHalf.declaresInitializer")" \
  "corruptRefusal=$(m40_arm "corruptCalldata.report.refusedToRunPublicHalf")" \
  "controlSteps=$(m40_arm "noDeploymentNullifier.report.publicHalf.executed.count")"

# ===========================================================================================
echo "== 1. THE PRIVATE HALF EXECUTED, AND THE ENQUEUED CALLS COME OFF THE CIRCUIT"
# ===========================================================================================
assert_eq "the private half executed" "executed" "$(m40_arm "$SUBJECT.report.run.outcome")"
assert_eq "it stopped at no oracle" "MISSING" "$(m40_arm "$SUBJECT.report.run.stoppedAtOracle")"
NESTED="$(m40_arm "$SUBJECT.report.run.nested")"
assert_true "it has a nested private frame" test "$NESTED" != "MISSING"
NESTED_COUNT="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$NESTED" 2>/dev/null || echo NOTJSON)"
assert_eq "one nested private frame, so the transaction is a TREE" "1" "$NESTED_COUNT"

ENQ="$(m40_arm "$SUBJECT.report.enqueued")"
ENQ_COUNT="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$ENQ" 2>/dev/null || echo NOTJSON)"
# THE COUNT IS READ FROM THE CIRCUIT'S PUBLIC INPUTS, WALKED OVER THE WHOLE FRAME TREE. A count
# taken from the outer frame alone would be 1 and would look like a working transaction.
assert_eq "the transaction enqueued two public calls" "2" "$ENQ_COUNT"

# AND THEY WERE ENQUEUED BY DIFFERENT FRAMES, which is what makes the tree walk necessary rather
# than decorative: one call is the outer frame's and one is the nested frame's.
ENQ_FRAMES="$(python3 -c '
import json, sys
print(",".join(sorted({e["frame"] for e in json.loads(sys.argv[1])})))' "$ENQ" 2>/dev/null || echo NOTJSON)"
assert_eq "one from each private frame" \
  "enqueue_call_to_child,enqueue_calls_to_child_with_nested_first" "$ENQ_FRAMES"

# ===========================================================================================
echo "== 2. THE CALLDATA IS THE ONE THE CIRCUIT COMMITTED TO, PER CALL"
# ===========================================================================================
CALLS="$(m40_arm "$SUBJECT.report.publicHalf.calls")"
# JSON RENDERING, NOT PYTHON's. `str(False)` is `False` and every other reader in this repository
# spells a boolean `false`; two spellings of one value is how a comparison comes to be about the
# renderer.
readcalls() { python3 -c '
import json, sys
calls = json.loads(sys.argv[1])
field = sys.argv[2]
def render(v):
    return json.dumps(v) if isinstance(v, bool) else str(v)
print("\n".join(render(c[field]) for c in calls))' "$CALLS" "$1"; }

assert_eq "both enqueued calls reached the public half" "2" \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$CALLS")"

# EVERY CALL'S TWO INDEPENDENTLY-DERIVED HASHES AGREE. The left-hand side is what the circuit put in
# its public inputs; the right-hand side is what upstream's own `fromCalldata` derives from the
# preimage the execution cache handed back.
MISMATCHED="$(python3 -c '
import json, sys
bad = [c for c in json.loads(sys.argv[1]) if c["committedCalldataHash"] != c["rebuiltCalldataHash"]]
print(len(bad))' "$CALLS")"
assert_eq "every enqueued call's preimage hashes to the circuit's own commitment" "0" "$MISMATCHED"
assert_eq "and the report says so per call" "0" \
  "$(python3 -c 'import json,sys; print(sum(1 for c in json.loads(sys.argv[1]) if not c["calldataHashMatches"]))' "$CALLS")"

# THE TWO CALLS ARE THE SAME FUNCTION AND DIFFERENT CALLDATA, WHICH IS THE FIXTURE'S WHOLE POINT.
# A driver that re-declared them from a function name would satisfy the selector assertion and
# could still run the same arguments twice.
assert_eq "both calls dispatch to one function" "1" \
  "$(readcalls selector | sort -u | grep -c .)"
assert_eq "and the two calldata hashes are DIFFERENT" "2" \
  "$(readcalls committedCalldataHash | sort -u | grep -c .)"
assert_eq "the selector resolves to a function the artifact declares" "pub_set_value" \
  "$(readcalls functionName | sort -u)"
assert_eq "both calls carry a selector and one argument" "2" \
  "$(readcalls calldataFields | sort -u)"
assert_eq "neither is a static call" "false" "$(readcalls isStaticCall | sort -u)"
# The counters are the CIRCUIT's side-effect counters, so the order the calls ran in is the
# protocol's rather than the frame tree's visit order.
assert_eq "the two calls carry distinct side-effect counters" "2" \
  "$(readcalls counter | sort -u | grep -c .)"

# ===========================================================================================
echo "== 3. THE PUBLIC HALF EXECUTED, AND IT IS THE AVM RATHER THAN A REPORT"
# ===========================================================================================
STEPS="$(m38_num "$(m40_arm "$SUBJECT.report.publicHalf.executed.count")" 'executed step count')"
INSTR="$(m38_num "$(m40_arm "$SUBJECT.report.publicHalf.executed.instructionsExecuted")" 'instructionsExecuted')"
IN_RESULT="$(m38_num "$(m40_arm "$SUBJECT.report.publicHalf.executed.inResult")" 'inResult')"
CONTEXTS="$(m38_num "$(m40_arm "$SUBJECT.report.publicHalf.executed.contexts")" 'contexts')"
OPCODES="$(m38_num "$(m40_arm "$SUBJECT.report.publicHalf.executed.distinctOpcodes")" 'distinctOpcodes')"
m38_require_num steps="$STEPS" instructions="$INSTR" inResult="$IN_RESULT" contexts="$CONTEXTS" opcodes="$OPCODES"

# THE IDENTITY, NOT A FLOOR. `stats["total_instructions_executed"]` is the module's own counter and
# the drained stream is what the observer wrote; a recording that lost a step and a counter that
# counted the wrong thing both break this and neither breaks a floor.
assert_eq "the drained step count equals the module's own instruction counter" "$INSTR" "$STEPS"
assert_eq "and equals the count in the simulation result" "$IN_RESULT" "$STEPS"
assert_eq "the collector says the drain matched the result" "true" \
  "$(m40_arm "$SUBJECT.report.publicHalf.executed.drainedMatchesResult")"
assert_ge "the transaction executed a non-degenerate number of instructions" 100 "$STEPS"
assert_eq "across two AVM contexts — the dispatch and the function it dispatched to" "2" "$CONTEXTS"
assert_ge "over a real instruction set rather than one opcode repeated" 10 "$OPCODES"

# NO STEP CARRIES M9's `LAST_OPCODE_SENTINEL`. 68 is what `read_instruction` reports when it threw
# before the opcode was known, and a stream of them is the shape a transaction that never fetched
# bytecode produces — which is exactly what the control arm below reproduces.
FIRST_OPS="$(m40_arm "$SUBJECT.report.publicHalf.executed.firstOpcodes")"
assert_eq "no sentinel opcode among the first steps" "0" \
  "$(python3 -c 'import json,sys; print(sum(1 for o in json.loads(sys.argv[1]) if o == 68))' "$FIRST_OPS")"

assert_eq "the block processed it" "processed" "$(m40_arm "$SUBJECT.report.publicHalf.outcome")"
# UPSTREAM's OWN `ProcessedTx.revertCode`, matched by transaction hash in the sealed block.
# `outcome` cannot answer this: `processed` is the BLOCK's verdict and a reverted transaction is
# still processed. M29's finding, and the reason this field exists at all.
assert_eq "and it did not revert" "0" "$(m40_arm "$SUBJECT.report.publicHalf.revertCode")"
assert_eq "the revert description says so in words" "OK" \
  "$(m40_arm "$SUBJECT.report.publicHalf.revertDescription")"
assert_eq "and carries no revert reason" "MISSING" \
  "$(m40_arm "$SUBJECT.report.publicHalf.revertReason")"

# ===========================================================================================
echo "== 4. THE SEEDING IS A DECISION READ OFF THE ARTIFACT"
# ===========================================================================================
#
# `assert_is_initialized_public` is emitted into every `#[public]` function of a contract that HAS
# an initializer and into none of a contract that does not. Seeding unconditionally would put a
# nullifier in the tree that no circuit asserts on.
assert_eq "the callee declares no initializer" "false" \
  "$(m40_arm "$SUBJECT.report.publicHalf.declaresInitializer")"
SEEDED="$(m40_arm "$SUBJECT.report.publicHalf.seededNullifiers")"
assert_eq "so exactly one nullifier was seeded — the deployment one" "1" \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$SEEDED")"

# THE CARRIER'S FIRST NULLIFIER IS DERIVED, NOT MINTED. Upstream's own tester uses `420000 + txCount`
# — a counter, which makes two runs of one transaction two different carriers.
assert_eq "the carrier's first nullifier is the transaction's own join identity" \
  "$(m40_arm "$SUBJECT.report.joinId")" "$(m40_arm "$SUBJECT.report.publicHalf.firstNullifier")"
assert_true "and the report says where it came from" \
  str_has_sub "$(m40_arm "$SUBJECT.report.publicHalf.firstNullifierSource")" 'argsHash'

# ===========================================================================================
echo "== 5. THE CONTROLS, EACH PRODUCED BY CHANGING ONE THING"
# ===========================================================================================
CORRUPT="$(m40_arm "corruptCalldata.report.refusedToRunPublicHalf")"
assert_true "with one calldata field changed, the public half REFUSES" \
  test "$CORRUPT" != "MISSING"
assert_true "and the refusal names BOTH hashes rather than only saying no" \
  str_has_sub "$CORRUPT" 'and the circuit committed to'
assert_true "and says what it would otherwise have done" \
  str_has_sub "$CORRUPT" 'a call this transaction did not enqueue'
assert_eq "so that arm ran no public half at all" "MISSING" \
  "$(m40_arm "corruptCalldata.report.publicHalf")"
# THE PERTURBATION IS REPORTED, so "one field of one call" is a reading rather than a claim about
# what the arm meant to do.
assert_true "the arm reports which field it changed" \
  str_has_sub "$(m40_arm "corruptCalldata.report.corruptedCalldata")" 'field='
assert_eq "and the subject arm changed none" "MISSING" \
  "$(m40_arm "$SUBJECT.report.corruptedCalldata")"

CTL_STEPS="$(m38_num "$(m40_arm "noDeploymentNullifier.report.publicHalf.executed.count")" 'control steps')"
CTL_OPS="$(m40_arm "noDeploymentNullifier.report.publicHalf.executed.firstOpcodes")"
CTL_REVERT="$(m40_arm "noDeploymentNullifier.report.publicHalf.revertCode")"
m38_require_num controlSteps="$CTL_STEPS"
# M29's ONE-INSTRUCTION SHAPE, REPRODUCED. Without the deployment nullifier the AVM answers the
# address with no bytecode: one step, at pc 0, with the sentinel opcode, and the block still calls
# the transaction `processed`.
assert_eq "without the deployment nullifier the AVM executes exactly one instruction" "1" "$CTL_STEPS"
assert_eq "and that instruction's opcode is M9's LAST_OPCODE_SENTINEL" "[68]" "$CTL_OPS"
assert_eq "in one context rather than two" "1" \
  "$(m40_arm "noDeploymentNullifier.report.publicHalf.executed.contexts")"
assert_eq "and the transaction REVERTS" "1" "$CTL_REVERT"
assert_eq "while the block still reports it processed — which is why revertCode is read at all" \
  "processed" "$(m40_arm "noDeploymentNullifier.report.publicHalf.outcome")"
# AND THE CONTROL IS THE SAME TRANSACTION: its enqueued calls are the subject's, so the difference
# is the seeding and nothing else.
assert_eq "the control ran the same two enqueued calls" "2" \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' \
      "$(m40_arm "noDeploymentNullifier.report.publicHalf.calls")")"

# ===========================================================================================
echo "== 6. THE CLASS ID IS THE COMMITMENT OF THE BYTECODE, AND THE OTHER DERIVATION IS SHOWN"
# ===========================================================================================
#
# `classIdOf` hashed the artifact's base64 TEXT where `makeContractClassPublic` wants the decoded
# bytecode. Every address derived from it is self-consistent, so `get_contract_instance`'s assertion
# holds and no private frame can tell; it became visible the moment the AVM had to find bytecode by
# that id. This section is the pair of derivations, taken here rather than quoted — a figure nobody
# re-derives rots, and this one is two lines of node.
ARTIFACT_ROOT=""
for r in diffsim spike probe-mt; do
  [ -f "$REPO_ROOT/$r/node_modules/@aztec/noir-test-contracts.js/artifacts/child_contract-Child.json" ] \
    && { ARTIFACT_ROOT="$r"; break; }
done
assert_true "the callee's artifact is on disk to derive from" test -n "$ARTIFACT_ROOT"
# FROM THE TREE THAT HAS `@aztec/stdlib` INSTALLED. There is no `node_modules` at the repository
# root, so a resolution from there answers nothing at all — and `2>/dev/null` would turn that into
# two empty strings comparing equal, which is this campaign's first defect form. The stderr is kept
# and the derivation is asserted to have produced something before it is compared.
CLASS_IDS="$(cd "$REPO_ROOT/browser" && node --input-type=module -e '
import { readFileSync } from "node:fs";
import { makeContractClassPublic } from "@aztec/stdlib/testing";
import { loadContractArtifact } from "@aztec/stdlib/abi";
const raw = JSON.parse(readFileSync(process.argv[1], "utf8"));
const b64 = raw.functions.find((f) => f.name === "public_dispatch").bytecode;
const decoded = loadContractArtifact(raw).functions.find((f) => f.name === "public_dispatch").bytecode;
console.log((await makeContractClassPublic(27, b64)).id.toString());
console.log((await makeContractClassPublic(27, decoded)).id.toString());
' "$REPO_ROOT/$ARTIFACT_ROOT/node_modules/@aztec/noir-test-contracts.js/artifacts/child_contract-Child.json" 2>&1)"
FROM_TEXT="$(printf '%s\n' "$CLASS_IDS" | sed -n '1p')"
FROM_BYTECODE="$(printf '%s\n' "$CLASS_IDS" | sed -n '2p')"
assert_true "the base64-text derivation produced a class id" str_has_re "$FROM_TEXT" '^0x[0-9a-f]{64}$'
assert_true "and so did the decoded-bytecode one" str_has_re "$FROM_BYTECODE" '^0x[0-9a-f]{64}$'
# TWO MEASUREMENTS RATHER THAN ONE FIGURE COMPARED WITH ITSELF: they must DIFFER, and the page must
# have used the second. Asserting only the second would pass over a tree where the defect never
# existed, and asserting only that they differ would pass over a page that used either.
assert_true "the two derivations DISAGREE, which is what made the defect a defect" \
  test "$FROM_TEXT" != "$FROM_BYTECODE"
assert_eq "and the page registered the class the DECODED bytecode commits to" \
  "$FROM_BYTECODE" "$(m40_arm "$SUBJECT.report.publicHalf.contract.classId")"
assert_eq "the callee's instance is the one the private half addressed" \
  "$(m40_arm "$SUBJECT.report.child.address")" \
  "$(m40_arm "$SUBJECT.report.publicHalf.contract.address")"
assert_eq "and it is the address both enqueued calls name" "1" \
  "$(readcalls contractAddress | sort -u | grep -c .)"
assert_eq "which is the callee's" "$(m40_arm "$SUBJECT.report.child.address")" \
  "$(readcalls contractAddress | sort -u)"

# ===========================================================================================
echo "== 7. THE PAGE PAID NO PROVING STACK FOR ANY OF IT"
# ===========================================================================================
# DD-11, on the browser's own network log. An absence measured over a log that CAN carry the
# subject: the same log carries `avm.wasm` as the positive control.
assert_eq "the subject arm fetched zero barretenberg chunks" "[]" \
  "$(m40_arm "$SUBJECT.barretenbergRequests")"
assert_ge "while its log does carry the AVM module, so the scanner can find things" 1 \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$(m40_arm "$SUBJECT.avmWasmRequests")")"
assert_eq "and the page reported no errors" "[]" "$(m40_arm "$SUBJECT.pageErrors")"

# ===========================================================================================
echo "== 8. BOTH-HALVES.md section 2 IS RE-DERIVED FROM THIS RUN"
# ===========================================================================================
assert_file "the write-up exists" "$M40_DOC"
m38_assert_doc "BOTH-HALVES.md section 2" "$M40_DOC" \
  "public calls the transaction enqueued|0|$ENQ_COUNT" \
  "instructions the public half executed|0|$STEPS" \
  "AVM contexts they ran in|0|$CONTEXTS" \
  "distinct opcodes among them|0|$OPCODES" \
  "the public half's container bytes|0|$(m38_num "$(m40_arm "$SUBJECT.report.publicContainer.containerBytes")" 'public container bytes')" \
  "steps of it positioned in aztec-nr source|0|$(m38_num "$(m40_arm "$SUBJECT.report.publicContainer.stepsPositioned")" 'public positioned')" \
  "instructions the unseeded control executed|0|$CTL_STEPS"

m40_finish
