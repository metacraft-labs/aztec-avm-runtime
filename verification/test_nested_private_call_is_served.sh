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

echo "== 4b. THE CHILD'S CALLER IS ITS PARENT, NOT THE TRANSACTION'S ORIGIN"
# UPSTREAM'S `deriveCallContext` PASSES THIS FRAME'S CONTRACT, so that a contract cannot impersonate
# the caller of the frame above it. **Nothing else in a report can see this.** `Child.value` does not
# read `msg_sender`, so handing the child the transaction's origin changes no step count, no
# counter, no oracle ledger and no returned value — measured, by a mutation arm that did exactly
# that and left every assertion in this file green. It is read out of the CIRCUIT's own
# `CallContext` rather than out of the request that built it.
CHILD_SENDER="$(m39_arm nested.report.run.nested.0.publicInputs.msgSender)"
PARENT_ADDR="$(m39_arm nested.report.run.publicInputs.contractAddress)"
PARENT_SENDER="$(m39_arm nested.report.run.publicInputs.msgSender)"
m38_absent childSender="$CHILD_SENDER" parentAddr="$PARENT_ADDR" parentSender="$PARENT_SENDER"
assert_eq "the child's msgSender is the CALLER's contract address" "$PARENT_ADDR" "$CHILD_SENDER"
# THE NON-DEGENERACY: the transaction's origin is a DIFFERENT address, so the equality above is not
# satisfied by a runtime that hands every frame the same sender.
assert_true "and the transaction's own origin is a different address, so that is not free" \
  test "$PARENT_SENDER" != "$PARENT_ADDR"
assert_true "the child's msgSender is not the origin" test "$CHILD_SENDER" != "$PARENT_SENDER"

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
# ONCE PER NESTED CALL, DERIVED. The shim regroups `callPrivateFunction`'s RETURN, so it fires
# exactly as often as the transaction makes one — a literal 1 here would be a property of this
# fixture typed into a check rather than a relation between two of its readings.
NESTED_FRAMES_N="$(m39_arm nested.report.run.nested | python3 -c '
import json, sys
d = sys.stdin.read().strip()
print(len(json.loads(d)) if d.startswith("[") else "MISSING")')"
m38_absent nestedFramesN="$NESTED_FRAMES_N"
assert_eq "the shim fired once per nested call the transaction made" "$NESTED_FRAMES_N" "$OK_APPLIED"
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
# AND THE SAME COMPARISON ON A SECOND FUNCTION, because one function agreeing is a coincidence a
# hard-coded answer would also produce. The first draft of this line grepped `$EXEC_SRC` for the
# exported function's NAME — a name grepped in the file that declares that name, which cannot be
# less than true and which reads beside a real measurement as if it were one.
PARENT_SEL_UP="$( cd "$REPO_ROOT/orchestration" && node --input-type=module -e "
import { FunctionSelector, loadContractArtifact } from '@aztec/stdlib/abi';
import { readFileSync } from 'node:fs';
const loaded = loadContractArtifact(JSON.parse(readFileSync(process.argv[1], 'utf8')));
const fn = loaded.functions.find(f => f.name === 'entry_point');
process.stdout.write((await FunctionSelector.fromNameAndParameters(fn.name, fn.parameters)).toString());
" -- "$REPO_ROOT/$(m39_top assets.parent.root)/node_modules/@aztec/noir-test-contracts.js/artifacts/parent_contract-Parent.json" 2>/dev/null | tail -1 )"
m38_absent parentSelectorUpstream="$PARENT_SEL_UP"
assert_eq "the CALLER's own selector is upstream's too, on a second function" \
  "$PARENT_SEL_UP" "$(m39_arm nested.report.run.selector)"

echo "== 9. FOUR OF THE FIVE REFUSAL GROUNDS ARE PRODUCED BY A REAL CIRCUIT, NOT GREPPED"
# ===========================================================================================
# THE FIRST VERSION OF THIS SECTION WAS SIX TAUTOLOGIES, AND THIS FILE IS WHERE IT WAS CAUGHT.
# ===========================================================================================
#
# It asserted `str_has_sub "$(cat private_oracles.ts)" "'unregistered-contract'"` for each of the
# five grounds — a name GREPPED IN THE FILE THAT DECLARES THAT NAME, which is this campaign's own
# catalogued form and cannot be less than true. Found by re-reading the check while a sweep ran,
# which is the only work a sweep leaves and is where this campaign's aborts keep finding things.
#
# Each arm below removes exactly ONE thing the oracle needs from the WORKING transaction and leaves
# everything else alone, so the ground the ACVM reports back is attributable to that one thing. The
# transaction is otherwise the arm section 2 asserts executes, which is what makes each of these a
# difference rather than a run that failed for its own reasons.
ORACLES_TEXT="$(cat "$ORACLES_SRC")"
GROUNDS_EXERCISED=0
for ground in unregistered-contract unknown-selector not-private depth-exceeded; do
  outcome="$(m39_arm "refusals.report.$ground.run.outcome")"
  stopped="$(m39_arm "refusals.report.$ground.run.stoppedAtOracle")"
  chain="$(m39_arm "refusals.report.$ground.run.errorChain")"
  ledger="$(m39_arm "refusals.report.$ground.run.oracleCalls")"
  m38_absent "${ground}Outcome=$outcome" "${ground}Stopped=$stopped" "${ground}Chain=$chain" \
    "${ground}Ledger=$ledger"
  assert_eq "$ground: the transaction is refused" "refused" "$outcome"
  assert_eq "$ground: at the nested-call oracle and no other" "aztec_prv_callPrivateFunction" "$stopped"
  # THE GROUND IS NAMED IN THE ERROR THE ACVM CARRIED OUT, not in the source. `NestedCallRefused`
  # is not `OracleUnimplemented` and the distinction is the point: the oracle IS served, and this
  # particular call cannot be.
  assert_true "$ground: the error names NestedCallRefused and this ground" \
    str_has_sub "$chain" "NestedCallRefused: $ground:"
  # AND THE LEDGER RECORDS `unavailable`, WHICH IS THE THIRD OUTCOME AND NOT `refused`. A fact about
  # the DATA written as a fact about the PARTITION is what makes one oracle appear in both the
  # served and the refused sets of a single run — M35's own finding, and the reason `unavailable`
  # exists at all.
  # PARSED, NOT GREPPED, AND TIED TO THE LAST ENTRY. A substring search for an outcome anywhere in
  # the ledger would be satisfied by any entry having it, and the key ORDER is the reader's
  # (`sort_keys`) rather than the producer's — a needle that assumed `outcome` follows `reason` was
  # the first spelling here and matched nothing.
  last="$(printf '%s' "$ledger" | python3 -c '
import json, sys
calls = json.load(sys.stdin)
last = calls[-1]
print("%s|%s|%s" % (last["oracle"], last["outcome"], last["detail"].split(" ")[0]))')"
  m38_absent "${ground}Last=$last"
  assert_eq "$ground: the ledger's last entry is the nested call, unavailable, on this ground" \
    "aztec_prv_callPrivateFunction|unavailable|$ground" "$last"
  # AND `unavailable` IS THE THIRD OUTCOME AND NOT `refused`. A fact about the DATA written as a
  # fact about the PARTITION is what makes one oracle appear in both the served and the refused sets
  # of one run — M35's own finding, and the reason the third outcome exists at all.
  assert_eq "$ground: and nothing in this run was recorded as refused" "0" \
    "$(printf '%s' "$ledger" | python3 -c '
import json, sys
print(sum(1 for c in json.load(sys.stdin) if c["outcome"] == "refused"))')"
  GROUNDS_EXERCISED=$(( GROUNDS_EXERCISED + 1 ))
done
# THE EXPECTED COUNT COMES FROM THE ARM'S OWN REPORT, NOT FROM THIS LOOP'S LENGTH. Comparing a
# loop's iteration count against the list it iterates is an assertion over the number of arguments
# the check itself passed — a form this campaign has already shipped once, in a check advertising
# "the exclusion list is EMPTY" while reporting `len(sys.argv[3:])`. The arm decides how many
# grounds it produced; this asserts the loop reached all of them.
GROUNDS_IN_REPORT="$(m39_arm refusals.report | python3 -c '
import json, sys
d = sys.stdin.read().strip()
print(len(json.loads(d)) if d.startswith("{") else "MISSING")')"
m38_absent groundsInReport="$GROUNDS_IN_REPORT"
assert_ge "the refusals arm produced grounds at all" 2 "$(m38_num "$GROUNDS_IN_REPORT" 'grounds in report')"
assert_eq "every ground the arm produced was exercised through a real circuit" \
  "$GROUNDS_IN_REPORT" "$GROUNDS_EXERCISED"
# EACH ARM STOPS FOR ITS OWN REASON AND NOT FOR A SHARED ONE. Four refusals that all named the same
# ground would satisfy every assertion above; the SET is what says they are four.
DISTINCT_GROUNDS="$(for g in unregistered-contract unknown-selector not-private depth-exceeded; do
    m39_arm "refusals.report.$g.run.errorChain" | grep -o 'NestedCallRefused: [a-z-]*:' | head -1
  done | sort -u | grep -c .)"
assert_eq "and the grounds they reported are all DIFFERENT from each other" \
  "$GROUNDS_EXERCISED" "$DISTINCT_GROUNDS"
# THE DIAGNOSTIC'S SHAPE IS WHAT MADE THE SELECTOR DEFECT FINDABLE: `unknown-selector` names the
# requested selector AND every selector the artifact derives. Read out of the RUN.
US_CHAIN="$(m39_arm refusals.report.unknown-selector.run.errorChain)"
assert_true "unknown-selector names the artifact's own derivations back" \
  str_has_sub "$US_CHAIN" "The artifact derives"
assert_true "and it names the selector that was asked for" \
  str_has_sub "$US_CHAIN" "0xdeadbeef"
# `no-args-preimage` IS DECLARED AND NOT EXERCISED, AND THE CHECK SAYS WHICH IS WHICH. Producing it
# needs a contract that calls the oracle WITHOUT storing its arguments first, and every `#[aztec]`
# contract stores them one opcode earlier — so there is no fixture for it here. A section that
# quietly grepped all five would make four measurements and one claim look like five measurements.
assert_true "the fifth ground is declared, and this check does not pretend to exercise it" \
  str_has_sub "$ORACLES_TEXT" "'no-args-preimage'"

echo "== 10. THE PARTITION RECONCILIATION COVERS ALL FOUR COMBINATIONS OF THE TWO SOURCES"
# THE SERVED SET THE RUN REPORTS AGAINST THE ONE THE SOURCE LISTS DERIVE — two producers for one
# number. The first draft of this line grepped for `oraclesServedFor`'s declaration, which is a name
# in the file that declares it.
IMPL_N="$(python3 - "$ORACLES_SRC" <<'PY2'
import re, sys
src = open(sys.argv[1]).read()
i = src.index("export const ORACLE_IMPLEMENTED: readonly string[] = Object.freeze(")
block = src[i:src.index("].sort(),", i)]
code = "\n".join(l for l in block.splitlines() if not l.strip().startswith("//"))
print(len(set(re.findall(r"'(aztec_[A-Za-z0-9_]+)'", code))))
PY2
)"
m38_require_num implN="$IMPL_N"
assert_ge "the always-served list is a real list" 30 "$IMPL_N"
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
# AND THE SAME NUMBER FROM A SECOND PRODUCER: the always-served LIST parsed out of the source, plus
# tier 4's one. The line above compares two RUNS; this compares a run against a declaration, so a
# partition that had drifted from its own list fails one of the two.
assert_eq "the run's served set is the always-served list plus tier 4's one oracle" \
  "$(( IMPL_N + 1 ))" "$SERVED_WITH"

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
# THE CALLEE THE CIRCUIT COMMITTED TO IS THE ADDRESS THE PAGE DERIVED, which ties the enqueued call
# to a value produced by `makeContractInstanceFromClassId` rather than to one the wallet recorded
# about itself. The first draft of this line grepped the extractor's own source line for its own
# text — a producer's report about itself, one level further in.
assert_eq "the enqueued call's callee is the contract instance the page derived" \
  "$(m39_arm bothHalves.report.child.address)" "$OUTER_ADDR"

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

echo "== 13. EVERY FIGURE NESTED-CALLS.md STATES IS THE ONE THE ARTEFACTS PRODUCE"
# THE COMPARER IS M38's, AND ITS TWO REFUSALS ARE EXERCISED BELOW. `str_has_re` is bash's `=~`,
# whose `.` MATCHES A NEWLINE, so the obvious spelling of "anchor the needle to the row" is not
# anchored at all — thirteen of M38's assertions were written that way and reported 33 / 0 over a
# document stating the reverse of its own data. `_m38_doc_figures.py` walks LINES, takes the Nth
# bold figure on the row a needle names, refuses a needle that names more than one row, and reports
# how many figures it compared, so "no disagreement" cannot be "nothing compared".
[ -s "$M39_DOC" ] || die "there is no write-up at $M39_DOC"
REQS_TOTAL=29; REQS_HAVE=5; REQS_MISSING=24; REQS_SHARE=6; REQS_NEW=4
m39_assert_doc_ok() { m38_assert_doc "$@"; }
P_BYTES="$(m39_arm nested.report.run.bytecodeBytes)"
P_WITNESS="$(m39_arm nested.report.run.solvedWitnessSize)"
C_BYTES="$(m39_arm nested.report.run.nested.0.bytecodeBytes)"
C_WITNESS="$(m39_arm nested.report.run.nested.0.solvedWitnessSize)"
P_CALLS="$(m39_arm nested.report.run.oracleCalls | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
C_CALLS="$(m39_arm nested.report.run.nested.0.oracleCalls | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
SERVED_N="$(m39_arm nested.report.run.servedSetSize)"
COMPAT_N="$(m39_arm nested.report.run.wireCompatApplied)"
BH_CALLS="$(m39_arm bothHalves.report.run.oracleCalls | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
BH_OUT_N="$(m39_arm bothHalves.report.run.publicInputs.publicCallRequests | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
BH_IN_N="$(m39_arm bothHalves.report.run.nested.0.publicInputs.publicCallRequests | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
BH_END="$(m39_arm bothHalves.report.run.publicInputs.endSideEffectCounter)"
LEGACY_N="$( cd "$REPO_ROOT" && python3 -c '
import re, sys
src = open(sys.argv[1]).read()
body = src[src.index("export const LEGACY_ORACLE_REGISTRY"):]
print(len(set(re.findall(r"^  (aztec_[A-Za-z0-9_]+): legacyOracle", body, re.M))))' \
  "$BROWSER_SRC/vendor/pxe/contract_function_simulator/oracle/legacy_oracle_registry.ts" )"
A_DECL="$(m39_arm anchorLine.report.contextInputFieldsDeclared)"
N_DECL="$(m39_arm nested.report.contextInputFieldsDeclared)"
m38_absent pBytes="$P_BYTES" pWitness="$P_WITNESS" cBytes="$C_BYTES" cWitness="$C_WITNESS" \
  pCalls="$P_CALLS" cCalls="$C_CALLS" servedN="$SERVED_N" compatN="$COMPAT_N" \
  bhCalls="$BH_CALLS" bhOut="$BH_OUT_N" bhIn="$BH_IN_N" bhEnd="$BH_END" legacyN="$LEGACY_N" \
  aDecl="$A_DECL" nDecl="$N_DECL"
m38_assert_doc "NESTED-CALLS.md sections 1, 3 and 5" "$M39_DOC" \
  "distinct requirements|0|$REQS_TOTAL" \
  "of them already present|0|$REQS_HAVE" \
  "of them missing|0|$REQS_MISSING" \
  "share what is currently per-frame|0|$REQS_SHARE" \
  "genuinely new subsystems|0|$REQS_NEW" \
  "\`Parent.entry_point\` bytecode|0|$P_BYTES" \
  "the caller's solved witness|0|$P_WITNESS" \
  "oracle calls the caller made|0|$P_CALLS" \
  "the callee's solved witness|0|$C_WITNESS" \
  "oracle calls the callee made|0|$C_CALLS" \
  "\`Child.value\` bytecode|0|$C_BYTES" \
  "the served set with a nested-call source attached|0|$SERVED_N" \
  "refusal grounds exercised through a real circuit|0|$GROUNDS_EXERCISED" \
  "refusal grounds declared and NOT exercised|0|1" \
  "times the call-private wire regrouping fired|0|$COMPAT_N" \
  "oracle calls the outer frame made|0|$BH_CALLS" \
  "public calls the outer frame enqueued|0|$BH_OUT_N" \
  "public calls the nested frame enqueued|0|$BH_IN_N" \
  "side-effect counter range ends at|0|$BH_END"
# AND THE PROSE FIGURES UNDER THOSE TABLES, which are the half M38's own review found stated and
# compared by NOTHING — thirteen of twenty-six, under a header claiming all were re-derived.
m38_assert_doc "NESTED-CALLS.md sections 5a and 6" "$M39_DOC" \
  "Entries in that table|0|$LEGACY_N" \
  "context width the \`deletion_era\` artifacts declare|0|$N_DECL" \
  "context width the anchor line declares|0|$A_DECL"

m39_finish
