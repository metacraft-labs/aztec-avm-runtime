#!/usr/bin/env bash
# test_nested_private_call_is_served — a private function calls another private function, in
# Chromium, and the transaction that results is TWO FRAMES rather than one.
#
# ===========================================================================================
# WHAT THIS ASSERTS THAT "outcome: executed" DOES NOT
# ===========================================================================================
#
# A green outcome is equally true of a handler that answered `callPrivateFunction` with a plausible
# pair of fields and never ran anything. Every section below is therefore about a value that only a
# real child frame can produce:
#
#   * THE CHILD'S RETURN CROSSED THE SHARED EXECUTION CACHE, and the crossing is in the LEDGERS.
#     The child stores its return under its own `returnsHash`; the parent loads it back under the
#     same hash IN ITS OWN FRAME. `aztec-nr`'s `ReturnsHash::get_preimage` is
#     `execution_cache::load(self.hash)` run by the CALLER over a hash the CALLEE stored, so a
#     per-frame cache fails on the opcode AFTER the nested call rather than at it.
#   * THE VALUE THAT CROSSED IS THE ONE ONLY A CORRECTLY-PARENTED CHILD PRODUCES.
#     `Child.value(input) = input + chain_id + version`, called with `input = 0` on a chain whose id
#     and version are both 1, so the answer is 2. A child that had not been handed the PARENT's
#     `txContext` returns something else and nothing in the parent asserts it — this is the only
#     place that disagreement is visible.
#   * THE COUNTER RANGE CHAINS. `self.side_effect_counter = end_side_effect_counter + 1` is the
#     circuit's own rule; the parent's end is asserted to be the child's end plus one.
#   * THE PARTITION IS DERIVED, NOT TYPED, AND ALL FOUR COMBINATIONS ARE RECONCILED. A served set
#     that grew by a name nobody added to the registry, or that grew in the wrong combination of
#     attached sources, throws at construction.
#
# THE CONTROLS, each for a different way this could be vacuous:
#
#   * WITH THE WIRE REGROUPING OFF, the same transaction halts at the slot count. So the shim's
#     necessity is a measurement and the arm that needs it is not a run that would have worked
#     anyway.
#   * THE ANCHOR-LINE CORPUS IS REFUSED BEFORE A SINGLE OPCODE, with its 38-field context against
#     this environment's 37. A claim that a corpus cannot run here is a claim.
#   * THE SELECTOR THE CALLER PASSES IS THE ONE THE PROTOCOL DERIVES, checked against upstream's own
#     `loadContractArtifact` + `getFunctionSelector` rather than against this runtime's own answer.
#     That derivation was wrong from the first frame ever executed here and nothing could see it.
#
# Run: just verify-m39-nested

TEST_NAME="test_nested_private_call_is_served"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# `lib_m23_chain.sh` FIRST, and it is not decoration: `lib_m27_browser.sh:84` builds its required
# export list from `M23_REQUIRED_EXPORTS`, so sourcing the browser library alone dies on an unbound
# variable under `set -u` — before a single assertion, which reads to a sweep as a check that is not
# there. Same order as `e2e_private_function_executes_in_browser.sh`, for the same reason.
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m38_private_trace.sh"
. "$VERIFY_DIR/lib_m39_nested.sh"
# INSTALLED BY CALLING IT, NOT BY TRAPPING IT — M38's arm M1 found what the other spelling costs.
m39_summary_on_abnormal_exit

m39_require_arms

ORACLES_SRC="$BROWSER_SRC/wallet/private_oracles.ts"
EXEC_SRC="$BROWSER_SRC/wallet/private_execution.ts"

echo "== 1. THE ORACLE IS SERVED, AND THE PARTITION THAT SERVES IT IS DERIVED"
NESTED_LIST="$(python3 - "$ORACLES_SRC" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"export const ORACLE_NESTED: readonly string\[\] = Object\.freeze\(\[([^\]]*)\]\)", src, re.S)
if not m:
    print("MISSING"); raise SystemExit(0)
print(",".join(sorted(re.findall(r"'([A-Za-z0-9_]+)'", m.group(1)))))
PY
)"
m38_absent nestedList="$NESTED_LIST"
assert_eq "tier 4's partition is exactly the nested-call oracle" \
  "aztec_prv_callPrivateFunction" "$NESTED_LIST"
# THE REFUSAL REASON STAYS — the oracle is refused when no source is attached, and
# `assertOracleSurfaceMatchesDeclaration` requires every refused oracle to declare one. What must
# change is WHAT IT SAYS. The old text named "its own ephemeral-array service and its own
# side-effect counter range", and the built thing shares the counter range and does NOT share the
# ephemeral service — so two thirds of a stated cause became false. This file's own
# `aztec_utl_recordFact` entry is the record of what that costs: *a refusal whose stated cause has
# been removed is a refusal a reader will act on wrongly.*
STILL_REFUSING="$(python3 - "$ORACLES_SRC" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
i = src.find("export const ORACLE_REFUSAL_REASONS")
if i < 0:
    print("MISSING"); raise SystemExit(0)
block = src[i:src.index("});", i)]
# The keys of the object, which is where a refusal reason lives. A NAME IN A COMMENT IS NOT A KEY —
# this file carries several retired oracles named in prose beside the entries that replaced them,
# and counting one of those as a refusal is the campaign's own "a citation is the opposite of a
# dependency".
code = "\n".join(l for l in block.splitlines() if not l.strip().startswith("//"))
print("yes" if re.search(r"^\s*aztec_prv_callPrivateFunction:", code, re.M) else "no")
PY
)"
m38_absent stillRefusing="$STILL_REFUSING"
assert_eq "it still declares a refusal reason, because without a source it still refuses" "yes" "$STILL_REFUSING"
REASON="$(python3 - "$ORACLES_SRC" <<'PY2'
import re, sys
src = open(sys.argv[1]).read()
i = src.find("export const ORACLE_REFUSAL_REASONS")
block = src[i:src.index("});", i)]
code = "\n".join(l for l in block.splitlines() if not l.strip().startswith("//"))
m = re.search(r"aztec_prv_callPrivateFunction:\s*(.*?)\n\s*[a-zA-Z_]+:", code, re.S)
print(" ".join(m.group(1).split()) if m else "MISSING")
PY2
)"
m38_absent reason="$REASON"
assert_true "and the reason names what the handler LACKS rather than a milestone" \
  str_has_sub "$REASON" "built WITHOUT a nested-call source"
# THE TWO CLAUSES THAT BECAME FALSE ARE ASSERTED ABSENT, each by its own words. A single assertion
# that the text changed would pass for any edit; these two name the specific statements the built
# thing falsified.
assert_true "the stale ephemeral-service clause is gone" \
  test "$(printf '%s' "$REASON" | grep -c 'own ephemeral-array service')" = "0"
assert_true "and the stale counter-range clause is gone" \
  test "$(printf '%s' "$REASON" | grep -c 'own side-effect counter range')" = "0"
assert_true "while the three other tier-4 oracles still do" \
  test "$(grep -c '^  aztec_utl_callUtilityFunction:\|^  aztec_utl_getUtilityContext:\|^  aztec_prv_resolveCustomRequest:' "$ORACLES_SRC")" = "3"

echo "== 2. THE TRANSACTION EXECUTED, AND IT IS TWO FRAMES"
OUTCOME="$(m39_arm nested.report.run.outcome)"
STOPPED="$(m39_arm nested.report.run.stoppedAtOracle)"
HAS_NESTED="$(m39_arm nested.report.run.hasNested)"
DEPTH="$(m39_arm nested.report.run.depth)"
CHILD_OUTCOME="$(m39_arm nested.report.run.nested.0.outcome)"
CHILD_DEPTH="$(m39_arm nested.report.run.nested.0.depth)"
CHILD_NAME="$(m39_arm nested.report.run.nested.0.functionName)"
CHILD_CONTRACT="$(m39_arm nested.report.run.nested.0.contractName)"
m38_absent outcome="$OUTCOME" stopped="$STOPPED" hasNested="$HAS_NESTED" depth="$DEPTH" \
  childOutcome="$CHILD_OUTCOME" childDepth="$CHILD_DEPTH" childName="$CHILD_NAME" \
  childContract="$CHILD_CONTRACT"
assert_eq "the transaction executed" "executed" "$OUTCOME"
assert_eq "and stopped at no oracle" "null" "$STOPPED"
assert_eq "the handler was built with a nested-call source" "true" "$HAS_NESTED"
assert_eq "the entry frame is at depth 0" "0" "$DEPTH"
assert_eq "and it has exactly one child" "1" "$(m39_arm nested.report.run.nested | python3 -c 'import json,sys; d=sys.stdin.read().strip(); print(len(json.loads(d)) if d.startswith("[") else "MISSING")')"
assert_eq "the child executed" "executed" "$CHILD_OUTCOME"
assert_eq "at depth 1" "1" "$CHILD_DEPTH"
assert_eq "and it is the CHILD contract, not the parent again" "Child" "$CHILD_CONTRACT"
assert_eq "and the child function is the one the selector named" "value" "$CHILD_NAME"

echo "== 3. THE CHILD'S RETURN CROSSED THE SHARED EXECUTION CACHE, AND THE LEDGERS SHOW THE CROSSING"
PARENT_LEDGER="$(m39_arm nested.report.run.oracleCalls)"
CHILD_LEDGER="$(m39_arm nested.report.run.nested.0.oracleCalls)"
m38_absent parentLedger="$PARENT_LEDGER" childLedger="$CHILD_LEDGER"
CHILD_RETURNS_HASH="$(m39_arm nested.report.run.nested.0.publicInputs.returnsHash)"
PARENT_RETURNS_HASH="$(m39_arm nested.report.run.publicInputs.returnsHash)"
m38_absent childReturnsHash="$CHILD_RETURNS_HASH" parentReturnsHash="$PARENT_RETURNS_HASH"
# The CHILD stored under that hash …
assert_true "the child stored its return under its own returnsHash" \
  str_has_sub "$CHILD_LEDGER" "\"aztec_prv_setHashPreimage\""
CHILD_STORED="$(printf '%s' "$CHILD_LEDGER" | python3 -c '
import json, sys
calls = json.load(sys.stdin)
print(",".join(c["detail"].split("hash=")[1].split(" ")[0]
               for c in calls if c["oracle"] == "aztec_prv_setHashPreimage") or "NONE")')"
PARENT_LOADED="$(printf '%s' "$PARENT_LEDGER" | python3 -c '
import json, sys
calls = json.load(sys.stdin)
print(",".join(c["detail"].split("hash=")[1].split(" ")[0]
               for c in calls if c["oracle"] == "aztec_prv_getHashPreimage") or "NONE")')"
m38_absent childStored="$CHILD_STORED" parentLoaded="$PARENT_LOADED"
assert_true "the child stored under the hash its own public inputs declare" \
  str_has_word "${CHILD_STORED//,/ }" "$CHILD_RETURNS_HASH"
assert_true "and the PARENT loaded that same hash back in its own frame" \
  str_has_word "${PARENT_LOADED//,/ }" "$CHILD_RETURNS_HASH"
# … and the parent's own return is the child's, because `entry_point` returns what `value` returned.
assert_eq "the parent's returnsHash equals the child's, which is what its body says" \
  "$CHILD_RETURNS_HASH" "$PARENT_RETURNS_HASH"

echo "== 4. THE VALUE THAT CROSSED IS THE ONE ONLY A CORRECTLY-PARENTED CHILD PRODUCES"
CHAIN_ID="$(m39_arm nested.report.chain.chainId)"
CHAIN_VERSION="$(m39_arm nested.report.chain.version)"
m38_require_num chainId="$CHAIN_ID" version="$CHAIN_VERSION"
# `Child.value(input) = input + chain_id + version`, and the arm calls it with `input = 0`.
EXPECTED_RETURN="$(( CHAIN_ID + CHAIN_VERSION ))"
CROSSED="$(m39_arm nested.report.run.tape | python3 -c '
import json, sys
tape = json.load(sys.stdin)
for e in tape:
    if e["oracle"] == "aztec_prv_getHashPreimage" and e["outputs"]:
        print(int(e["outputs"][0][0], 16)); raise SystemExit(0)
print("NONE")')"
m38_absent crossed="$CROSSED"
assert_eq "the field the child returned is input + chain_id + version" "$EXPECTED_RETURN" "$CROSSED"
# THE NON-DEGENERACY: 2 is a small number and a handler that answered 2 for everything would satisfy
# the line above. The chain fields are read from the ARM's own request, so a run on a different
# chain moves the expectation with the answer, and the two are asserted to be non-zero.
assert_ge "the chain id is not zero, so the identity is not 0 == 0" 1 "$CHAIN_ID"
assert_ge "nor is the version" 1 "$CHAIN_VERSION"

echo "== 5. THE SIDE-EFFECT COUNTER RANGE CHAINS, WHICH IS THE CIRCUIT'S OWN RULE"
P_START="$(m39_arm nested.report.run.publicInputs.startSideEffectCounter)"
P_END="$(m39_arm nested.report.run.publicInputs.endSideEffectCounter)"
C_START="$(m39_arm nested.report.run.nested.0.publicInputs.startSideEffectCounter)"
C_END="$(m39_arm nested.report.run.nested.0.publicInputs.endSideEffectCounter)"
m38_require_num pStart="$P_START" pEnd="$P_END" cStart="$C_START" cEnd="$C_END"
assert_true "the child's range is inside the parent's" \
  test "$P_START" -lt "$C_START" -a "$C_END" -lt "$P_END"
assert_eq "and the parent resumes one past the child's end, as private_context.nr says" \
  "$(( C_END + 1 ))" "$P_END"

echo "== 6. THE CONTROL — WITH THE WIRE REGROUPING OFF, THE SAME TRANSACTION HALTS"
NC_OUTCOME="$(m39_arm noCompat.report.run.outcome)"
NC_ERROR="$(m39_arm noCompat.report.run.error)"
NC_APPLIED="$(m39_arm noCompat.report.run.wireCompatApplied)"
OK_APPLIED="$(m39_arm nested.report.run.wireCompatApplied)"
m38_absent ncOutcome="$NC_OUTCOME" ncError="$NC_ERROR" ncApplied="$NC_APPLIED" okApplied="$OK_APPLIED"
assert_eq "with the shim off the transaction fails" "failed" "$NC_OUTCOME"
assert_true "on the slot count, naming both sides" \
  str_has_sub "$NC_ERROR" "2 output values were provided as a foreign call result for 1 destination slots"
assert_eq "the shim fired exactly once on the arm that needs it" "1" "$OK_APPLIED"
assert_eq "and not at all on the arm that disabled it" "0" "$NC_APPLIED"
# AND THE CHILD RAN IN BOTH, so the difference between the arms is the PARENT's wire and not whether
# a nested call happened at all. Without this the control would be satisfied by an arm that refused
# earlier for any reason.
assert_eq "the child executed on the control arm too" "executed" "$(m39_arm noCompat.report.run.nested.0.outcome)"

echo "== 7. THE CONTROL — THE ANCHOR-LINE CORPUS CANNOT BE ASSEMBLED INTO A FRAME HERE"
A_DECLARED="$(m39_arm anchorLine.report.contextInputFieldsDeclared)"
A_BUILT="$(m39_arm anchorLine.report.contextInputFieldsBuilt)"
A_REFUSED="$(m39_arm anchorLine.report.refusedToAssemble)"
N_DECLARED="$(m39_arm nested.report.contextInputFieldsDeclared)"
N_BUILT="$(m39_arm nested.report.contextInputFieldsBuilt)"
m38_absent aDeclared="$A_DECLARED" aBuilt="$A_BUILT" aRefused="$A_REFUSED" \
  nDeclared="$N_DECLARED" nBuilt="$N_BUILT"
assert_eq "the corpus that RUNS declares the width this environment builds" "$N_BUILT" "$N_DECLARED"
assert_true "the anchor line declares a wider one" test "$A_DECLARED" -gt "$A_BUILT"
assert_true "and its frame is refused before a single opcode" \
  str_has_sub "$A_REFUSED" "argument field(s) beyond its context inputs"
assert_eq "the two lines are two different nightlies, so this is a comparison" \
  "false" "$(if [ "$(m39_arm anchorLine.report.aztecVersion)" = "$(m39_arm nested.report.aztecVersion)" ]; then echo true; else echo false; fi)"

echo "== 8. THE SELECTOR A CALLER PASSES IS THE ONE THE PROTOCOL DERIVES"
# ASKED OF UPSTREAM'S OWN LOADER RATHER THAN OF THIS RUNTIME'S ANSWER. `privateFunctionSelector`
# derived over the RAW artifact's parameters — which begin with the `inputs` context the macro
# injects — and produced a selector no contract ever names. It was wrong from the first frame and
# nothing compared it with anything until a nested call had to FIND a callee by it.
SELECTOR_CMP="$( cd "$REPO_ROOT/orchestration" && node --input-type=module -e "
import { FunctionSelector, loadContractArtifact } from '@aztec/stdlib/abi';
import { readFileSync } from 'node:fs';
const raw = JSON.parse(readFileSync(process.argv[1], 'utf8'));
const loaded = loadContractArtifact(raw);
const fn = loaded.functions.find(f => f.name === 'value');
const upstream = await FunctionSelector.fromNameAndParameters(fn.name, fn.parameters);
const rawFn = raw.functions.find(f => f.name === 'value');
const withContext = await FunctionSelector.fromNameAndParameters({
  name: 'value', parameters: rawFn.abi.parameters,
});
console.log(JSON.stringify({ upstream: upstream.toString(), withContext: withContext.toString() }));
" -- "$REPO_ROOT/$(m39_top assets.child.root)/node_modules/@aztec/noir-test-contracts.js/artifacts/child_contract-Child.json" 2>/dev/null | tail -1 )"
UPSTREAM_SEL="$(printf '%s' "$SELECTOR_CMP" | python3 -c 'import json,sys; d=sys.stdin.read().strip(); print(json.loads(d)["upstream"] if d.startswith("{") else "MISSING")')"
WITHCTX_SEL="$(printf '%s' "$SELECTOR_CMP" | python3 -c 'import json,sys; d=sys.stdin.read().strip(); print(json.loads(d)["withContext"] if d.startswith("{") else "MISSING")')"
ARM_SEL="$(m39_arm nested.report.child.selector)"
m38_absent upstreamSelector="$UPSTREAM_SEL" withContextSelector="$WITHCTX_SEL" armSelector="$ARM_SEL"
assert_eq "the selector this runtime derived is upstream's own" "$UPSTREAM_SEL" "$ARM_SEL"
# THE PAIR IS TWO MEASUREMENTS AND NOT ONE FIGURE COMPARED WITH ITSELF. Including the context
# parameter gives a DIFFERENT selector; asserting only the equality above would pass for a
# derivation that had silently stopped stripping it if upstream's loader ever stopped too.
assert_true "and it is NOT what the raw parameter list derives, so the strip is doing work" \
  test "$UPSTREAM_SEL" != "$WITHCTX_SEL"
assert_true "the derivation is exported once and used by both consumers" \
  str_has_sub "$(cat "$EXEC_SRC")" "export async function privateFunctionSelector"

echo "== 9. THE NESTED-CALL ORACLE REFUSES ON FIVE DISTINGUISHABLE GROUNDS, EACH BY NAME"
ORACLES_TEXT="$(cat "$ORACLES_SRC")"
for ground in unregistered-contract unknown-selector not-private no-args-preimage depth-exceeded; do
  assert_true "the oracle can refuse on '$ground'" \
    str_has_sub "$ORACLES_TEXT" "'$ground'"
done
# AND ONE OF THEM WAS EXERCISED BY A REAL RUN RATHER THAN GREPPED. The both-halves fixture passes a
# selector the raw-parameter derivation could not find, so `unknown-selector` fired on real data
# before the derivation was fixed; what is asserted here is that the SHAPE of that refusal names
# both the requested selector and the ones the artifact derives, which is what made it diagnosable.
assert_true "and unknown-selector names the artifact's own derivations back" \
  str_has_sub "$ORACLES_TEXT" 'The artifact derives'

echo "== 10. THE PARTITION RECONCILIATION COVERS ALL FOUR COMBINATIONS OF THE TWO SOURCES"
assert_true "the served set is a function of what the handler was given" \
  str_has_sub "$ORACLES_TEXT" "export function oraclesServedFor"
COMBOS="$(python3 - "$ORACLES_SRC" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
i = src.find("export function assertOracleSurfaceMatchesDeclaration")
block = src[i:i + 4000]
print(len(re.findall(r"\[(?:true|false), (?:true|false)\]", block)))
PY
)"
m38_require_num combos="$COMBOS"
assert_eq "and all four combinations are reconciled, not the two that used to exist" "4" "$COMBOS"
SERVED_WITH="$(m39_arm nested.report.run.servedSetSize)"
SERVED_WITHOUT="$(m38_top 'arms' >/dev/null 2>&1; python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["arms"]["private"]["report"]["executes"]["servedSetSize"])' "${M35_ARMS:-$HOME/.cache/aztec-m35-private/private-execution.json}" 2>/dev/null || echo MISSING)"
m38_require_num servedWith="$SERVED_WITH"
m38_absent servedWithout="$SERVED_WITHOUT"
assert_eq "attaching a nested-call source adds exactly one oracle to the served set" \
  "$(( SERVED_WITHOUT + 1 ))" "$SERVED_WITH"

echo "== 11. BOTH HALVES OF A TRANSACTION EXIST — TWO PRIVATE FRAMES AND TWO ENQUEUED PUBLIC CALLS"
BH_OUTCOME="$(m39_arm bothHalves.report.run.outcome)"
BH_OUTER="$(m39_arm bothHalves.report.run.publicInputs.publicCallRequests)"
BH_INNER="$(m39_arm bothHalves.report.run.nested.0.publicInputs.publicCallRequests)"
BH_CHILD_FN="$(m39_arm bothHalves.report.run.nested.0.functionName)"
m38_absent bhOutcome="$BH_OUTCOME" bhOuter="$BH_OUTER" bhInner="$BH_INNER" bhChildFn="$BH_CHILD_FN"
assert_eq "the both-halves transaction executed" "executed" "$BH_OUTCOME"
assert_eq "its nested frame is the self-call the fixture makes" "enqueue_call_to_child" "$BH_CHILD_FN"
for label in outer:"$BH_OUTER" inner:"$BH_INNER"; do
  json="${label#*:}"
  assert_eq "the ${label%%:*} frame enqueued exactly one public call" "1" \
    "$(printf '%s' "$json" | python3 -c 'import json,sys; d=sys.stdin.read().strip(); print(len(json.loads(d)) if d.startswith("[") else "MISSING")')"
done
# THE TWO ENQUEUED CALLS GO TO ONE CONTRACT AND CARRY DIFFERENT CALLDATA, which is the fixture's own
# point: 10 from the nested frame and 20 from the outer one. Asserting only "two calls" would be
# satisfied by the same call counted twice.
OUTER_ADDR="$(printf '%s' "$BH_OUTER" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[0]["contractAddress"])')"
INNER_ADDR="$(printf '%s' "$BH_INNER" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[0]["contractAddress"])')"
OUTER_HASH="$(printf '%s' "$BH_OUTER" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[0]["calldataHash"])')"
INNER_HASH="$(printf '%s' "$BH_INNER" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[0]["calldataHash"])')"
m38_absent outerAddr="$OUTER_ADDR" innerAddr="$INNER_ADDR" outerHash="$OUTER_HASH" innerHash="$INNER_HASH"
assert_eq "both enqueued calls address the same contract" "$OUTER_ADDR" "$INNER_ADDR"
assert_true "and they carry different calldata, so they are two calls and not one counted twice" \
  test "$OUTER_HASH" != "$INNER_HASH"
assert_true "the enqueued calls are read from the CIRCUIT's public inputs" \
  str_has_sub "$(cat "$EXEC_SRC")" "publicCallRequests: claimed(publicInputs.publicCallRequests)"

echo "== 12. THE EPHEMERAL-ARRAY SERVICE IS PER FRAME, WHICH IS THE HALF THAT POINTS THE OTHER WAY"
# Six things became the TRANSACTION's; this one deliberately did not, because upstream constructs it
# fresh in every oracle and ships `EphemeralParent.test_isolation` to say a child must not see its
# parent's slots. Sharing everything would have been the easy edit.
assert_true "the transaction's shared state does not carry the ephemeral service" \
  test "$(python3 - "$ORACLES_SRC" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
i = src.find("export interface PrivateFrameState {")
block = src[i:src.index("}\n", i)]
code = "\n".join(l for l in block.splitlines() if not l.strip().startswith(("*", "/*", "//")))
print("yes" if "ephemeral" in code else "no")
PY
)" = "no"
for field in executionCache pendingNullifiers capsules transient revertible calldata; do
  assert_true "and it does carry $field" \
    test "$(python3 - "$ORACLES_SRC" "$field" <<'PY'
import sys
src = open(sys.argv[1]).read()
i = src.find("export interface PrivateFrameState {")
block = src[i:src.index("}\n", i)]
code = "\n".join(l for l in block.splitlines() if not l.strip().startswith(("*", "/*", "//")))
print("yes" if ("readonly %s:" % sys.argv[2]) in code else "no")
PY
)" = "yes"
done

m39_finish
