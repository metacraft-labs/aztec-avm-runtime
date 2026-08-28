#!/usr/bin/env bash
# test_transpiled_contract_registers_and_executes — M31.
#
#   verification/test_transpiled_contract_registers_and_executes.sh   (or: just verify-m31)
#
# ============================================================================================
# THE BYTES THE PAGE PRODUCED, RUN BY THE AVM.
# ============================================================================================
#
# `verify_transpiler_wasm_output_identical_to_native` says the browser's output is the native
# transpiler's, to the byte. That is a statement about two producers and says nothing about
# whether either produced something an AVM will execute. This check runs it.
#
# The artifact handed to `orchestration/src/transpiled_contract_driver.ts` is
# `browser-<fixture>.out.json` — written from the base64 the PAGE returned over CDP, not from
# the native binary's output and not from a second transpile. Its sha256 is carried into the
# report and compared here against the file on disk, so "the bytecode the browser produced" is
# a comparison rather than a description.
#
# ============================================================================================
# THE BOUNDARY, STATED RATHER THAN BLURRED.
# ============================================================================================
#
# The TRANSPILE happens in Chromium. The EXECUTION happens in Node, against the same `avm.wasm`,
# the same `AvmRuntime` facade and the same `PublicProcessor` a page uses — but not in a page.
# `bytecodeProvenance` says so in the report and this check asserts the sentence is there, so a
# reader cannot come away thinking the execution half was measured in a browser. Doing the
# execution in the page as well is M32's shape (a worker-hosted node) and is recorded as
# outstanding rather than implied.
#
# ============================================================================================
# THE ASSERTION THIS MILESTONE OWES M29.
# ============================================================================================
#
# M29's review found the campaign's deepest defect: *"every assertion correct, none asking
# whether the subject did anything"* — a demo transaction that REVERTED AT ITS FIRST INSTRUCTION
# passed a milestone, its review and a second milestone's floors. So this check does not stop at
# `outcome: processed`, which is the BLOCK's verdict and is true of a reverting transaction:
#
#   * `revertCode` is read off upstream's own `ProcessedTx` and asserted 0;
#   * a fixture whose dispatch asserts something FALSE is run in the same session and must report
#     a non-zero code, so `revertCode` is not a constant;
#   * the executed instruction count comes from M9's observer through M12's `avm_steps_count()`
#     and must be well past 1 — `1` being M29's exact signature for "read_instruction threw
#     before the opcode was known";
#   * and the counts must DIFFER across contracts of different sizes, so the count is not a
#     constant either.

TEST_NAME="test_transpiled_contract_registers_and_executes"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m31_transpiler.sh"
m31_summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
m31_require_arms

# ---------------------------------------------------------------------------
echo "== 0. the execute arm ran at all"
# ---------------------------------------------------------------------------
AVAILABLE="$(m31_arm arms.execute.available)"
if [ "$AVAILABLE" != "true" ]; then
  die "the execute arm did not run: $(m31_arm arms.execute.reason)
     It needs a built avm.wasm carrying M27's crypto exports. Remedy: just avm-wasm-build-m27,
     or set AVM_WASM_PATH. A skip reported as a pass is worse than a failure."
fi
assert_eq "the execute arm ran" "true" "$AVAILABLE"
AVM_WASM="$(m31_arm arms.execute.avmWasm)"
assert_file "…against a real avm.wasm" "$AVM_WASM"
assert_ge "…with the module's export surface non-empty" 40 "$(m31_arm arms.execute.exports)"
assert_eq "…and the module this check names is the one it ran" \
  "$(sha256sum "$AVM_WASM" | cut -d' ' -f1)" "$(m31_arm arms.execute.avmWasmSha256)"

COUNTER_OUTCOME="$(m31_arm arms.execute.contracts.counter.outcome)"
COUNTER_REVERT="$(m31_arm arms.execute.contracts.counter.revertCode)"
COUNTER_STEPS="$(m31_arm arms.execute.contracts.counter.instructionsExecuted)"
REVERTING_REVERT="$(m31_arm arms.execute.contracts.reverting.revertCode)"
BRANCHES_STEPS="$(m31_arm arms.execute.contracts.branches.instructionsExecuted)"
MEMORY_STEPS="$(m31_arm arms.execute.contracts.memory.instructionsExecuted)"
ABSENT="$(m31_absent outcome="$COUNTER_OUTCOME" revertCode="$COUNTER_REVERT" \
  steps="$COUNTER_STEPS" revertingRevertCode="$REVERTING_REVERT" \
  branchesSteps="$BRANCHES_STEPS" memorySteps="$MEMORY_STEPS")"
[ -z "$ABSENT" ] || die "the execute arm is missing:$ABSENT — every comparison below would compare
     two absent values. The arm's own error, if any: $(m31_arm arms.execute.contracts.counter.error)"
assert_eq "the execute arm carries every field this check reads" "" "$ABSENT"
for name in counter reverting branches memory; do
  assert_eq "$name: the driver did not throw" "MISSING" "$(m31_arm "arms.execute.contracts.$name.error")"
done

# ---------------------------------------------------------------------------
echo "== 1. the bytecode came from the BROWSER, and that is a comparison"
# ---------------------------------------------------------------------------
for name in counter reverting; do
  ON_DISK="$(sha256sum "$M31_WORK/browser-$name.out.json" | cut -d' ' -f1)"
  assert_eq "$name: the driver was handed the page's own output file" "$ON_DISK" \
    "$(m31_arm "arms.execute.contracts.$name.artifactSha256")"
  # …and that file is the one the identity arm judged identical to the native binary's.
  assert_eq "$name: which is the artifact the identity arm compared" \
    "$(m31_arm "identity.$name.browserSha256")" "$ON_DISK"
  assert_eq "$name: and it equals the native transpiler's output" "true" \
    "$(m31_arm "identity.$name.identicalBrowserVsNative")"
done
PROV="$(m31_arm arms.execute.contracts.counter.bytecodeProvenance)"
assert_contains "the report says where the bytecode came from" "inside Chromium" "$PROV"
assert_contains "…and where it was executed, so the boundary is not left to be inferred" \
  "executed here in Node" "$PROV"

# ---------------------------------------------------------------------------
echo "== 2. registerContract took the class and the instance"
# ---------------------------------------------------------------------------
for name in counter reverting branches memory; do
  assert_eq "$name: one contract class registered" "1" \
    "$(m31_arm "arms.execute.contracts.$name.registeredClasses")"
  assert_eq "$name: one contract instance registered" "1" \
    "$(m31_arm "arms.execute.contracts.$name.registeredInstances")"
  assert_ge "$name: the registered bytecode is the transpiled dispatch, not an empty buffer" 20 \
    "$(m31_arm "arms.execute.contracts.$name.dispatchBytecodeBytes")"
done
# The four contracts are four DIFFERENT contracts — different class ids, different addresses. A
# driver that registered the same thing four times would pass every assertion above.
DISTINCT_CLASSES="$(python3 - "$M31_ARMS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["arms"]["execute"]["contracts"]
print(len({v["contractClassId"] for v in d.values() if isinstance(v, dict) and "contractClassId" in v}))
PY
)"
assert_eq "the four contracts have four distinct class ids" "4" "$DISTINCT_CLASSES"
DISTINCT_ADDR="$(python3 - "$M31_ARMS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["arms"]["execute"]["contracts"]
print(len({v["contractAddress"] for v in d.values() if isinstance(v, dict) and "contractAddress" in v}))
PY
)"
assert_eq "…and four distinct addresses" "4" "$DISTINCT_ADDR"
# THE DEPLOYMENT NULLIFIER, without which M29 measured the AVM executing exactly ONE instruction
# while the block still reported the transaction `processed`. Four distinct ones, each a full
# 0x-prefixed 32-byte field: a driver that inserted one nullifier four times would leave three of
# the four contracts uncallable, which is exactly the mistake this asserts against.
NULLIFIER_FACTS="$(python3 - "$M31_ARMS" <<'PYX'
import json, sys
d = json.load(open(sys.argv[1]))["arms"]["execute"]["contracts"]
n = {v["deploymentNullifier"] for v in d.values() if isinstance(v, dict) and "deploymentNullifier" in v}
print(f"{len(n)} {min((len(x) for x in n), default=0)}")
PYX
)"
assert_eq "each contract got its own deployment nullifier, each a full field" "4 66" \
  "$NULLIFIER_FACTS"

# ---------------------------------------------------------------------------
echo "== 3. a real call, with an ABI-derived selector"
# ---------------------------------------------------------------------------
SELECTOR="$(m31_arm arms.execute.contracts.counter.calledSelector)"
CALLDATA_SEL="$(m31_arm arms.execute.contracts.counter.calldataSelector)"
assert_eq "the called function is the contract's public dispatch" "public_dispatch" \
  "$(m31_arm arms.execute.contracts.counter.calledFunction)"
assert_ge "the selector is derived, not empty" 8 "${#SELECTOR}"
# The selector the AVM RECEIVES is calldata field 0. Compared against the ABI-derived one, so a
# transaction that dispatched to something else would fail here.
assert_contains "…and it is what the AVM receives in calldata field 0" "${SELECTOR#0x}" "$CALLDATA_SEL"
assert_ge "the call carries calldata" 1 "$(m31_arm arms.execute.contracts.counter.calldataFields)"
assert_ge "…and the arity came from the artifact's own ABI" 1 \
  "$(m31_arm arms.execute.contracts.counter.parameterCount)"

# ---------------------------------------------------------------------------
echo "== 4. IT EXECUTED, and 'executed' is not 'was processed'"
# ---------------------------------------------------------------------------
assert_eq "the transaction was placed in a block" "processed" "$COUNTER_OUTCOME"
assert_eq "…in block 1" "1" "$(m31_arm arms.execute.contracts.counter.blockNumber)"
# THE ASSERTION M29 OWES THIS MILESTONE. `outcome` is the block's verdict and is `processed` for a
# transaction that reverted at instruction one.
assert_eq "and it did NOT revert" "0" "$COUNTER_REVERT"
assert_eq "…which upstream spells OK" "OK" \
  "$(m31_arm arms.execute.contracts.counter.revertDescription)"
assert_eq "…with no revert reason" "None" "$(m31_arm arms.execute.contracts.counter.revertReason)"
# M9's observer, through M12's export. `1` is M29's recorded signature for a dispatch that never
# got past reading its first instruction.
assert_ge "the AVM executed many instructions, not the one M29 found" 20 "$COUNTER_STEPS"
assert_ge "…and the module was called" 1 "$(m31_arm arms.execute.contracts.counter.moduleCalls)"

# ---------------------------------------------------------------------------
echo "== 5. THE CONTROLS — the two fields that could be constants are not"
# ---------------------------------------------------------------------------
# (a) `revertCode`. A field that is always 0 satisfies section 4 whatever the AVM did. The
# `reverting` fixture's dispatch runs the same loop and then asserts something false.
assert_eq "the reverting fixture reverts" "1" "$REVERTING_REVERT"
assert_eq "…and upstream describes it as such" "Reverted" \
  "$(m31_arm arms.execute.contracts.reverting.revertDescription)"
assert_false "…so revertCode is not a constant" test "$COUNTER_REVERT" = "$REVERTING_REVERT"
# It reverted having EXECUTED, which is what makes it a control for section 4 rather than a
# second way of failing at instruction one.
assert_ge "…and it reverted after executing, not before" 20 \
  "$(m31_arm arms.execute.contracts.reverting.instructionsExecuted)"
# The refusal is the contract's own, not a harness error: the transaction still reached a block.
assert_eq "…and the reverting transaction was still processed into a block" "processed" \
  "$(m31_arm arms.execute.contracts.reverting.outcome)"

# (b) `instructionsExecuted`. Three contracts of visibly different size must not all report the
# same count. `counter` and `reverting` coincide at the same figure — the assert replaces the
# return — which is exactly why the control uses the other two.
assert_false "the instruction count is not the same for every contract" \
  test "$COUNTER_STEPS" = "$BRANCHES_STEPS"
assert_false "…nor for the smallest one" test "$COUNTER_STEPS" = "$MEMORY_STEPS"
# DIRECTIONAL, so the counts are not merely three different numbers: more AVM bytecode, more
# instructions. Read from the same report.
C_BC="$(m31_arm arms.execute.contracts.counter.dispatchBytecodeBytes)"
B_BC="$(m31_arm arms.execute.contracts.branches.dispatchBytecodeBytes)"
M_BC="$(m31_arm arms.execute.contracts.memory.dispatchBytecodeBytes)"
assert_true "branches has more bytecode than counter ($B_BC > $C_BC)" test "$B_BC" -gt "$C_BC"
assert_true "…and executes more instructions ($BRANCHES_STEPS > $COUNTER_STEPS)" \
  test "$BRANCHES_STEPS" -gt "$COUNTER_STEPS"
assert_true "memory has less bytecode than counter ($M_BC < $C_BC)" test "$M_BC" -lt "$C_BC"
assert_true "…and executes fewer instructions ($MEMORY_STEPS < $COUNTER_STEPS)" \
  test "$MEMORY_STEPS" -lt "$COUNTER_STEPS"

# ---------------------------------------------------------------------------
echo "== 6. §8.4 honesty survives the trip"
# ---------------------------------------------------------------------------
assert_eq "the receipt still says the execution was simulated" "true" \
  "$(m31_arm arms.execute.contracts.counter.simulated)"
assert_eq "…and that nothing was proved" "none" "$(m31_arm arms.execute.contracts.counter.proving)"

# ---------------------------------------------------------------------------
echo "== 7. the vendored builder still never touched a world state"
# ---------------------------------------------------------------------------
# M26's RI-72 tripwire: the driver hands `PublicTxSimulationTester` a `Proxy` that throws on every
# access. A touch would have thrown inside the driver and surfaced as `error` above, which section
# 0 asserts is absent — so this is the same claim read from the other end, and it is here so that
# the reason section 0's `error` matters is written down rather than remembered.
assert_eq "no fixture's driver run recorded an error" "" \
  "$(python3 - "$M31_ARMS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["arms"]["execute"]["contracts"]
print(" ".join(sorted(k for k, v in d.items() if isinstance(v, dict) and "error" in v)))
PY
)"
assert_ge "…over four fixtures, so the emptiness is not an empty corpus" 4 \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["arms"]["execute"]["contracts"]))' "$M31_ARMS")"

m31_finish
