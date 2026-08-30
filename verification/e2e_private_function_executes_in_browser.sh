#!/usr/bin/env bash
# e2e_private_function_executes_in_browser
#
# M35's fifth verification entry, and it exists because the milestone delivered something its four
# planned entries do not name: **a real private function, compiled from Noir, executing in a page**.
#
# ===========================================================================================
# THE RUNG THIS OCCUPIES
# ===========================================================================================
#
# `CAMPAIGN-BRIEF.md`'s ladder is *asserted browser-shaped* -> *observed to evaluate* -> *observed to
# do the thing*. M33 owed the first, its review paid the second, M34 paid the third for a wallet.
# M35 ships an EXECUTOR, and the third rung for an executor is a circuit that solves: the ACVM
# fetched as a second wasm module at run time, upstream's `WASMSimulator` driving it, upstream's
# 68-entry oracle registry deserialising every call, and a handler of ours answering — all inside
# Chromium, with the page's own network log as the witness.
#
# ===========================================================================================
# AND THE LAZY HALF, WHICH IS A CLAIM ABOUT AN ABSENCE AND THEREFORE NEEDS A CONTROL
# ===========================================================================================
#
# The ACVM is 3,601,516 bytes and the ABI decoder is 789,053. DD-11's rule is that a page pays for
# what it asks for, so a page that does no private execution must fetch neither. That is an ABSENCE,
# and this file's ancestors record twice what happens when an absence is asked of a tree that
# excludes its subject by construction. So it is asked of a network log that CAN carry a wasm fetch:
# the `lazy` arm is the SAME page, running M34's wallet transfer, and its log carries `avm.wasm`
# while carrying neither of the two. The subject arm's log carries all three, which is the positive
# control that the scanner can find them at all.
#
# Run: just verify-m35-executes

TEST_NAME="e2e_private_function_executes_in_browser"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m35_private.sh"

m35_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m35_require_arms

echo "== 1. THE PAGE RAN, AND IT RAN CLEAN"

CHROME="$(m35_top chromium)"
DIST="$(m35_top dist)"
P_ERRORS="$(m35_arm private.pageErrors)"
P_CONSOLE="$(m35_arm private.consoleErrors)"
S_ERRORS="$(m35_arm surface.pageErrors)"
L_ERRORS="$(m35_arm lazy.pageErrors)"
m35_absent "chromium=$CHROME" "dist=$DIST" "private.pageErrors=$P_ERRORS" \
  "private.consoleErrors=$P_CONSOLE" "surface.pageErrors=$S_ERRORS" "lazy.pageErrors=$L_ERRORS"
assert_true "the arms ran in a real Chromium" str_has_sub "$CHROME" "Chromium"
assert_eq "the private-execution arm raised no page error" "[]" "$P_ERRORS"
assert_eq "and no console error" "[]" "$P_CONSOLE"
assert_eq "the surface arm likewise" "[]" "$S_ERRORS"
assert_eq "and the control arm likewise" "[]" "$L_ERRORS"
assert_eq "the arms were measured over this repository's own dist" "browser/dist" "$DIST"

echo "== 2. A REAL PRIVATE CIRCUIT SOLVED"

E_CONTRACT="$(m35_arm private.report.executes.contractName)"
E_FN="$(m35_arm private.report.executes.functionName)"
E_TYPE="$(m35_arm private.report.executes.functionType)"
E_SELECTOR="$(m35_arm private.report.executes.selector)"
E_BYTES="$(m35_arm private.report.executes.bytecodeBytes)"
E_CTX="$(m35_arm private.report.executes.contextInputFields)"
E_INIT="$(m35_arm private.report.executes.initialWitnessSize)"
E_SOLVED="$(m35_arm private.report.executes.solvedWitnessSize)"
E_OUTCOME="$(m35_arm private.report.executes.outcome)"
E_PUB="$(m35_arm private.report.executes.publicInputs)"
m35_absent "private.report.executes.contractName=$E_CONTRACT" "private.report.executes.functionName=$E_FN" \
  "private.report.executes.functionType=$E_TYPE" "private.report.executes.selector=$E_SELECTOR" \
  "private.report.executes.bytecodeBytes=$E_BYTES" "private.report.executes.contextInputFields=$E_CTX" \
  "private.report.executes.initialWitnessSize=$E_INIT" "private.report.executes.solvedWitnessSize=$E_SOLVED" \
  "private.report.executes.outcome=$E_OUTCOME" "private.report.executes.publicInputs=$E_PUB"

assert_eq "the subject is a private function of a real contract" "abi_private" "$E_TYPE"
assert_eq "and it is the oracle-version contract, whose whole subject is the version oracle" \
  "OracleVersionCheck private_function" "$E_CONTRACT $E_FN"
assert_ge "its bytecode is real ACIR rather than a stub" 1000 "$E_BYTES"
assert_true "its selector is an ABI-derived 4-byte selector" str_has_re "$E_SELECTOR" '^0x[0-9a-f]{8}$'
assert_eq "the frame EXECUTED" "executed" "$E_OUTCOME"

# THE WITNESS IDENTITIES, WHICH ARE WHAT SAY THE ACVM DID WORK RATHER THAN ECHOING ITS INPUT.
# `PRIVATE_CONTEXT_INPUTS_LENGTH` is read out of the anchor's own @aztec/constants rather than typed.
CONST_LEN="$(python3 -c '
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"PRIVATE_CONTEXT_INPUTS_LENGTH\s*=\s*([0-9]+)", src)
print(m.group(1) if m else "MISSING")' "$REPO_ROOT/orchestration/node_modules/@aztec/constants/dest/constants.gen.js")"
assert_true "PRIVATE_CONTEXT_INPUTS_LENGTH was read from @aztec/constants" test "$CONST_LEN" != "MISSING"
assert_eq "the frame's context inputs are that many fields" "$CONST_LEN" "$E_CTX"
assert_eq "this function declares no arguments, so the initial witness is the context alone" \
  "$E_CTX" "$E_INIT"
assert_true "and the SOLVED witness is far larger than the initial one" test "$E_SOLVED" -gt "$E_INIT"
assert_ge "by a margin a no-op could not produce" 800 "$E_SOLVED"

echo "== 3. THE CIRCUIT'S OWN PUBLIC INPUTS, and one of them is cross-checked against the ledger"

pub() { printf '%s' "$E_PUB" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1','MISSING'))"; }
assert_eq "the public inputs name the contract the frame was built for" \
  "0x0000000000000000000000000000000000000000000000000000000000000777" "$(pub contractAddress)"
assert_true "the side-effect counter advanced" test "$(pub endSideEffectCounter)" -gt "$(pub startSideEffectCounter)"
# THE CROSS-CHECK. `returnsHash` is a value the CIRCUIT computed and wrote into its public inputs;
# `setHashPreimage` is an oracle call the circuit made with the same hash. Two independent paths out
# of one execution, compared — which is stronger than reading either one and calling it well-formed.
LEDGER_HASH="$(m35_arm private.report.executes.oracleCalls | python3 -c '
import json, re, sys
calls = json.load(sys.stdin)
for c in calls:
    if c["oracle"] == "aztec_prv_setHashPreimage":
        m = re.search(r"hash=(0x[0-9a-f]+)", c["detail"])
        print(m.group(1) if m else "NO_HASH_IN_DETAIL")
        break
else:
    print("NO_SET_HASH_PREIMAGE_CALL")')"
assert_true "the frame made a setHashPreimage call" test "$LEDGER_HASH" != "NO_SET_HASH_PREIMAGE_CALL"
assert_eq "and the hash it stored IS the returnsHash the circuit published" "$LEDGER_HASH" "$(pub returnsHash)"
assert_true "which is a real field rather than zero" \
  test "$(pub returnsHash)" != "0x0000000000000000000000000000000000000000000000000000000000000000"

echo "== 4. THE ACVM WAS FETCHED BY THE PAGE, and it is the module this tree installs"

ACVM_REQ="$(m35_arm private.acvmWasmRequests)"
ABI_REQ="$(m35_arm private.noircAbiRequests)"
AVM_REQ="$(m35_arm private.avmWasmRequests)"
BB_REQ="$(m35_arm private.barretenbergRequests)"
ASSETS="$(m35_arm private.report.assets)"
ACVM_META="$(m35_top assets.acvm)"
ABI_META="$(m35_top assets.noircAbi)"
m35_absent "private.acvmWasmRequests=$ACVM_REQ" "private.noircAbiRequests=$ABI_REQ" \
  "private.avmWasmRequests=$AVM_REQ" "private.barretenbergRequests=$BB_REQ" \
  "private.report.assets=$ASSETS" "assets.acvm=$ACVM_META" "assets.noircAbi=$ABI_META"

assert_eq "the page fetched the ACVM" '["/assets/acvm_js_bg.wasm"]' "$ACVM_REQ"
assert_eq "and the ABI decoder" '["/assets/noirc_abi_wasm_bg.wasm"]' "$ABI_REQ"
assert_eq "and avm.wasm, which is the runtime the wallet's own hashing goes through" \
  '["/assets/avm.wasm"]' "$AVM_REQ"
assert_eq "and NOT barretenberg's proving stack — DD-11, unmoved by private execution" "[]" "$BB_REQ"
assert_true "the page was pointed at those URLs rather than at a bundler-resolved default" \
  str_has_sub "$ASSETS" "./assets/acvm_js_bg.wasm"

# WHICH @aztec LINE THE MODULE CAME FROM, because this tree has two installed at once and they are
# not interchangeable: the glue esbuild inlined is `orchestration/`'s, so the wasm must be too.
assert_true "the ACVM came from the tree the bundle is built against" \
  str_has_sub "$ACVM_META" '"root":"orchestration"'
assert_true "and so did the ABI decoder" str_has_sub "$ABI_META" '"root":"orchestration"'
ACVM_BYTES="$(printf '%s' "$ACVM_META" | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])')"
ABI_BYTES="$(printf '%s' "$ABI_META" | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])')"
assert_ge "the ACVM is megabytes rather than a placeholder" 1000000 "$ACVM_BYTES"
assert_ge "and the ABI decoder is hundreds of kilobytes" 100000 "$ABI_BYTES"

echo "== 5. THE CONTROL: a page that asks for no private execution fetches neither"

L_ACVM="$(m35_arm lazy.acvmWasmRequests)"
L_ABI="$(m35_arm lazy.noircAbiRequests)"
L_AVM="$(m35_arm lazy.avmWasmRequests)"
L_BB="$(m35_arm lazy.barretenbergRequests)"
L_REQS="$(m35_arm lazy.requestCount)"
L_OUTCOME="$(m35_arm lazy.report.outcome)"
m35_absent "lazy.acvmWasmRequests=$L_ACVM" "lazy.noircAbiRequests=$L_ABI" "lazy.avmWasmRequests=$L_AVM" \
  "lazy.barretenbergRequests=$L_BB" "lazy.requestCount=$L_REQS"

assert_eq "the control page fetched no ACVM" "[]" "$L_ACVM"
assert_eq "and no ABI decoder" "[]" "$L_ABI"
assert_eq "and no barretenberg" "[]" "$L_BB"
# THE POSITIVE CONTROL FOR THE ABSENCE. Without this the two zeroes above are equally true of a log
# that recorded nothing, which is the defect this campaign lists three times.
assert_eq "while fetching avm.wasm, so the absence is measured over a log that CAN carry a module" \
  '["/assets/avm.wasm"]' "$L_AVM"
assert_ge "over a page that made a real number of requests" 5 "$L_REQS"
L_STEPS="$(m35_arm lazy.report.executedSteps)"
m35_absent "lazy.report.outcome=$L_OUTCOME" "lazy.report.executedSteps=$L_STEPS"
assert_eq "and it did the work M34 measures, so it is a working page rather than a blank one" \
  "processed" "$L_OUTCOME"
assert_ge "having executed a real number of AVM instructions" 100 "$L_STEPS"

echo "== 6. THE TWO ARMS ARE DIFFERENT PAGES AND THE DIFFERENCE IS THE DELIVERABLE"

P_REQS="$(m35_arm private.requestCount)"
m35_absent "private.requestCount=$P_REQS"
assert_ge "the private arm made more requests than the control" "$((L_REQS + 1))" "$P_REQS"
DIFF="$(python3 - "$(m35_arm private.requests)" "$(m35_arm lazy.requests)" <<'PY'
import json, sys
a = {r['url'] for r in json.loads(sys.argv[1])}
b = {r['url'] for r in json.loads(sys.argv[2])}
print('ONLY_PRIVATE\t%s' % ' '.join(sorted(a - b)))
print('ONLY_LAZY\t%s' % ' '.join(sorted(b - a)))
PY
)"
ONLY_PRIVATE="$(printf '%s\n' "$DIFF" | awk -F'\t' '$1=="ONLY_PRIVATE"{print $2}')"
assert_true "the ACVM is in the difference" str_has_word "$ONLY_PRIVATE" "/assets/acvm_js_bg.wasm"
assert_true "and so is the ABI decoder" str_has_word "$ONLY_PRIVATE" "/assets/noirc_abi_wasm_bg.wasm"

echo "== 7. THE VENDORED TREES ARE WHAT EXECUTED, and their counts are the ones PROVENANCE declares"

SIM_FILES="$(git -C "$REPO_ROOT" ls-files "browser/src/vendor/simulator" | wc -l)"
PXE_FILES="$(git -C "$REPO_ROOT" ls-files "browser/src/vendor/pxe" | wc -l)"
DECLARED_SIM="$(awk -F'|' '/browser\/src\/vendor\/simulator/{gsub(/ /,"",$8); print $8}' "$REPO_ROOT/PROVENANCE.md")"
DECLARED_PXE="$(awk -F'|' '/browser\/src\/vendor\/pxe /{gsub(/ /,"",$8); print $8}' "$REPO_ROOT/PROVENANCE.md")"
assert_ge "the simulator tree is vendored" 10 "$SIM_FILES"
assert_ge "the oracle wire layer is vendored" 30 "$PXE_FILES"
assert_eq "and PROVENANCE.md's declared simulator count is the tracked one" "$SIM_FILES" "$DECLARED_SIM"
assert_eq "and its declared pxe count likewise" "$PXE_FILES" "$DECLARED_PXE"
# The bundle reached them: the entry point exports the executor, and the executor's own module is in
# the built graph. A metafile records imports, which is all this needs to say.
assert_true "the built wallet entry exports the executor" \
  str_has_sub "$(node -e 'import("'"$BROWSER_DIST"'/wallet.js").then(m => console.log(Object.keys(m).join(" ")))' 2>/dev/null)" \
  "executePrivateFunction"

m35_finish
