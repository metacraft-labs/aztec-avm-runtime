#!/usr/bin/env bash
# test_observer_fires_on_exceptional_halt
#
# The hook fires for the instruction that throws, so an out-of-gas or a failing opcode is the LAST
# RECORDED STEP rather than a missing one.
#
# That is a property of the hoist, and it is measured against a control that undoes it rather than
# argued from the source. `$M9_WORK/m9nohoist` is the measured tree plus ONE commit moving the
# observer call back inside the try block — the shape the hook would have without the hoist — and
# the difference between the two builds is the whole claim:
#
#   hoisted   burn 38,903 records   oob 3 records, the last one carrying LAST_OPCODE_SENTINEL
#   no hoist  burn 38,902           oob 2, and the sentinel record is gone
#   and the six programs that halt NORMALLY are unaffected in both, which is what makes the
#   control specific rather than merely different.
#
# Two exceptional shapes are covered because they are not the same shape:
#
#   burn  runs out of gas. The instruction was fetched, so the observer reports its real opcode.
#   oob   jumps past the end of its own bytecode, so `read_instruction` throws BEFORE the opcode is
#         known. `pc` has been assigned and the opcode has not, which is exactly the case the
#         patch's LAST_OPCODE_SENTINEL initialiser exists for.
#
# And `revert`, which halts NORMALLY through REVERT_8, is asserted NOT to report the sentinel — so
# "the sentinel marks a failed fetch" is a discrimination and not a statement about every program.

set -uo pipefail
TEST_NAME=test_observer_fires_on_exceptional_halt
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m9_observer.sh"

m9_measured
m8_require_artifacts "$(m9_steps_native)" "$(m9_steps_v8)" "$(m9_steps_native_err)" "$(m9_steps_v8_err)"

sentinel="$(m9_sentinel_opcode)"
assert_true "LAST_OPCODE_SENTINEL was derived from upstream's own opcodes.hpp, not restated here" \
  test -n "$sentinel"

# ---------------------------------------------------------------------------
# The mechanism, in upstream's own source: seven catch handlers, and the observer call AFTER all
# of them. If the call were inside the try, none of the seven would reach it.
# ---------------------------------------------------------------------------
hybrid="$M9_TREE/barretenberg/cpp/src/barretenberg/vm2/simulation/standalone/hybrid_execution.cpp"
assert_file "the fast execution loop is in the measured tree" "$hybrid"
assert_eq "the loop has seven catch handlers, every one of which the hoist has to survive" "7" \
  "$(grep -cE '^ *(} )?catch \(' "$hybrid")"
call_line="$(grep -n 'execution_observer_->on_instruction' "$hybrid" | head -1 | cut -d: -f1)"
last_catch="$(grep -nE '^ *(} )?catch \(' "$hybrid" | tail -1 | cut -d: -f1)"
if [ -n "$call_line" ] && [ -n "$last_catch" ] && [ "$call_line" -gt "$last_catch" ]; then
  pass "the observer call is below the last catch handler  [line $call_line > $last_catch]"
else
  fail "the observer call is not below the last catch handler  [call=$call_line last catch=$last_catch]"
fi
assert_true "the hoisted opcode starts as the sentinel, so a throw before the fetch is representable" \
  grep -qE 'WireOpCode observed_opcode = WireOpCode::LAST_OPCODE_SENTINEL;' "$hybrid"
assert_true "the interface documents the sentinel as the pre-fetch value" \
  grep -q 'LAST_OPCODE_SENTINEL if the halt happened' \
  "$M9_TREE/barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/execution_observer.hpp"

# ---------------------------------------------------------------------------
# THE AVM'S OWN LOG, AND THE ASYMMETRY M8 LEFT TO THIS MILESTONE.
#
# `common/log.cpp` sets `bb_log_level = LogLevel::VERBOSE` UNCONDITIONALLY under `__wasm__` and
# `LogLevel::INFO` (unless BB_VERBOSE=1) otherwise. So the wasm build narrates "halted via
# EXCEPTIONAL_HALT" on fd 2 and the native build says nothing at all — measured by M8 as a
# zero-byte native stderr, and recorded there as an upstream inconsistency belonging to M9.
#
# It is closed here by MOVING it rather than by asserting only on the side where it holds: the
# native binary is re-run with BB_VERBOSE=1 and the same lines appear. And the transcript is
# asserted UNCHANGED by that, so the log level does not touch the result.
# ---------------------------------------------------------------------------
log_src="$M9_WORK/upstream-log.cpp"
m8_upstream_file barretenberg/cpp/src/barretenberg/common/log.cpp "$log_src"
assert_true "upstream sets the wasm log level to VERBOSE unconditionally" \
  grep -qE '__wasm__' "$log_src"
assert_true "and the native one to INFO unless BB_VERBOSE is set" \
  grep -q 'BB_VERBOSE' "$log_src"
assert_eq "so the native run's stderr is empty at the default level" "0" \
  "$(wc -c <"$(m9_steps_native_err)")"
assert_ge "while the wasm run's is not" 20 "$(grep -c '(mem: N/A)' "$(m9_steps_v8_err)" || true)"

verbose_out="$M9_WORK/native-verbose.steps"
verbose_err="$M9_WORK/native-verbose.steps.err"
m9_run_native_verbose "$(m9_native_bin "$M9_TREE")" "$verbose_out" "$verbose_err" steps
assert_eq "the native run under BB_VERBOSE=1 exited 0" "0" "$?"
assert_ge "and it DOES narrate its progress, so the difference is the log level and not the target" \
  20 "$(grep -c '(mem: ' "$verbose_err" || true)"
# A second difference falls out of the same run and is recorded rather than glossed: the native
# build reports a real resident-set figure on those lines and the wasm build reports `N/A`, because
# the memory probe has no wasm implementation. So the two targets' stderr differs in TWO ways, not
# one, and neither is a difference in a result.
assert_ge "the native log lines carry a real memory figure" 20 \
  "$(grep -c '(mem: [0-9]' "$verbose_err" || true)"
assert_eq "and none of them says N/A" "0" "$(grep -c '(mem: N/A)' "$verbose_err" || true)"
assert_eq "while every wasm log line does" "0" \
  "$(grep -c '(mem: [0-9]' "$(m9_steps_v8_err)" || true)"
assert_true "the transcript is byte-identical with and without BB_VERBOSE, so the level touches no result" \
  cmp -s "$verbose_out" "$(m9_steps_native)"

# ---------------------------------------------------------------------------
# The behaviour, on both targets. The native log evidence comes from the BB_VERBOSE run, for the
# reason established immediately above.
# ---------------------------------------------------------------------------
for label in native v8; do
  case "$label" in
    native) t="$(m9_steps_native)"; e="$verbose_err" ;;
    v8)     t="$(m9_steps_v8)";     e="$(m9_steps_v8_err)" ;;
  esac
  assert_eq "[$label] the run completed" "1" "$(m9_field "$t" avmSteps.done)"

  # burn: out of gas, opcode known.
  assert_eq "[$label] burn executed $M9_STEPS_burn instructions" "$M9_STEPS_burn" \
    "$(m9_field "$t" steps.burn.instructionsExecuted)"
  assert_eq "[$label] burn recorded a step for every one of them" "$M9_STEPS_burn" \
    "$(m9_field "$t" steps.burn.count)"
  assert_eq "[$label] burn's record count equals the simulator's own statistic" "1" \
    "$(m9_field "$t" steps.burn.countEqualsInstructionsExecuted)"
  assert_eq "[$label] burn reverted" "1" "$(m9_field "$t" steps.burn.revertCode)"
  burn_last="$(m9_field "$t" steps.burn.last)"
  assert_contains "[$label] burn's last record is a real record" "ctx=" "$burn_last"
  assert_eq "[$label] burn's last record does NOT carry the sentinel (its fetch succeeded)" "0" \
    "$(m9_field "$t" steps.burn.lastOpcodeIsSentinel)"
  # The out-of-gas instruction is charged the whole gas limit, which is how you can tell the LAST
  # record is the throwing one rather than the last successful one.
  assert_contains "[$label] burn's last record is the instruction that exhausted the gas  [$burn_last]" \
    "l2=1000000 da=1000000" "$burn_last"
  assert_true "[$label] and the AVM's own log says it halted exceptionally" \
    grep -q 'halted via EXCEPTIONAL_HALT' "$e"
  assert_true "[$label] naming the out-of-gas exception" \
    grep -q 'Out of gas exception' "$e"

  # oob: the fetch itself throws.
  assert_eq "[$label] oob executed $M9_STEPS_oob instructions" "$M9_STEPS_oob" \
    "$(m9_field "$t" steps.oob.instructionsExecuted)"
  assert_eq "[$label] oob recorded a step for every one of them" "$M9_STEPS_oob" \
    "$(m9_field "$t" steps.oob.count)"
  oob_last="$(m9_field "$t" steps.oob.last)"
  assert_contains "[$label] oob's last record carries the sentinel opcode  [$oob_last]" \
    "op=$sentinel " "$oob_last"
  assert_eq "[$label] and is flagged as such" "1" "$(m9_field "$t" steps.oob.lastOpcodeIsSentinel)"
  assert_contains "[$label] at the out-of-range pc the jump targeted" "pc=16776960" "$oob_last"
  assert_true "[$label] and the AVM's own log names the instruction-fetching error" \
    grep -q 'Instruction fetching error' "$e"

  # revert: a NORMAL halt. Not the sentinel, and its last record is the REVERT itself.
  assert_eq "[$label] revert does NOT report the sentinel" "0" \
    "$(m9_field "$t" steps.revert.lastOpcodeIsSentinel)"
  assert_eq "[$label] revert recorded both its instructions" "$M9_STEPS_revert" \
    "$(m9_field "$t" steps.revert.count)"
  assert_false "[$label] and the AVM did not report an exceptional halt for it" \
    grep -q "halted via REVERT.*EXCEPTIONAL" "$e"
  assert_true "[$label] it halted via REVERT" grep -q 'halted via REVERT' "$e"
done

# The two exceptional programs' last records agree native versus wasm, field for field.
assert_eq "burn's last record is identical native versus wasm" \
  "$(m9_field "$(m9_steps_native)" steps.burn.last)" "$(m9_field "$(m9_steps_v8)" steps.burn.last)"
assert_eq "oob's last record is identical native versus wasm" \
  "$(m9_field "$(m9_steps_native)" steps.oob.last)" "$(m9_field "$(m9_steps_v8)" steps.oob.last)"

# ---------------------------------------------------------------------------
# THE CONTROL. Without the hoist the two exceptional programs lose exactly one record each and
# nothing else moves.
# ---------------------------------------------------------------------------
note "building the no-hoist control (the observer call moved back inside the try block)"
nohoist="$(m9_nohoist_tree)"
assert_dir "the no-hoist control tree exists" "$nohoist"
assert_eq "it is the measured tree plus exactly one commit" "9" \
  "$(git -C "$nohoist" rev-list --count "$(m8_anchor)..HEAD" 2>/dev/null)"
assert_eq "nothing under barretenberg/ is modified in it" "" "$(m9_tree_dirty "$nohoist")"
# The mutation is one hunk in one file, and it is the call site.
assert_eq "the control patch touches exactly one file" "1" \
  "$(grep -c '^diff --git' "$M9_NOHOIST_PATCH")"
assert_true "and that file is the fast execution loop" \
  grep -q 'standalone/hybrid_execution.cpp' "$M9_NOHOIST_PATCH"
assert_true "the control build still installs an observer (it moves the call, it does not remove it)" \
  grep -q 'execution_observer_->on_instruction' \
  "$nohoist/barretenberg/cpp/src/barretenberg/vm2/simulation/standalone/hybrid_execution.cpp"

m9_build_native "$nohoist"
assert_eq "the control's configure exited 0" "0" "${M9_NATIVE_CONFIGURE_RC:-missing}"
assert_eq "the control's build exited 0" "0" "${M9_NATIVE_BUILD_RC:-missing}"
control_bin="$(m9_native_bin "$nohoist")"
m8_require_artifacts "$control_bin"
m9_run_native "$control_bin" "$(m9_nohoist_steps)" "$M9_WORK/nohoist.steps.err" steps
assert_eq "the control run exited 0" "0" "$?"
m8_require_artifacts "$(m9_nohoist_steps)"
assert_eq "the control run completed" "1" "$(m9_field "$(m9_nohoist_steps)" avmSteps.done)"
assert_eq "the control still carries the observer patch" "1" \
  "$(m9_field "$(m9_nohoist_steps)" avmSteps.observerCompiledIn)"

lost_total=0
for prog in $M9_PROGRAMS; do
  want="$(m9_expect_steps "$prog")"
  got="$(m9_field "$(m9_nohoist_steps)" "steps.$prog.count")"
  executed="$(m9_field "$(m9_nohoist_steps)" "steps.$prog.instructionsExecuted")"
  assert_eq "control: $prog still EXECUTES $want instructions (the AVM is unchanged)" \
    "$want" "$executed"
  lossvar="M9_NOHOIST_LOSS_$prog"
  expect_loss="${!lossvar:-0}"
  expect_got=$((want - expect_loss))
  assert_eq "control: $prog records $expect_got of them without the hoist" "$expect_got" "$got"
  lost_total=$((lost_total + want - got))
  # And the simulation itself is untouched, so the record difference is about the OBSERVER.
  assert_eq "control: $prog's traced result is still unperturbed" "1" \
    "$(m9_field "$(m9_nohoist_steps)" "steps.$prog.resultIdenticalWithStepsRemoved")"
  assert_eq "control: $prog's total gas is unchanged" \
    "$(m9_field "$(m9_steps_native)" "steps.$prog.totalGas")" \
    "$(m9_field "$(m9_nohoist_steps)" "steps.$prog.totalGas")"
done
assert_eq "exactly two records are lost across the whole corpus without the hoist" "2" "$lost_total"

# The specific losses, named.
assert_eq "control: burn's count no longer equals its instruction count" "0" \
  "$(m9_field "$(m9_nohoist_steps)" steps.burn.countEqualsInstructionsExecuted)"
assert_eq "control: oob's count no longer equals its instruction count" "0" \
  "$(m9_field "$(m9_nohoist_steps)" steps.oob.countEqualsInstructionsExecuted)"
assert_eq "control: and the sentinel record is gone altogether" "0" \
  "$(m9_field "$(m9_nohoist_steps)" steps.oob.lastOpcodeIsSentinel)"
assert_true "control: burn's last record is now a DIFFERENT instruction" \
  test "$(m9_field "$(m9_nohoist_steps)" steps.burn.last)" != "$(m9_field "$(m9_steps_native)" steps.burn.last)"
assert_true "control: oob's last record is now a DIFFERENT instruction" \
  test "$(m9_field "$(m9_nohoist_steps)" steps.oob.last)" != "$(m9_field "$(m9_steps_native)" steps.oob.last)"
# ... and the six that halt normally record exactly what they did before, per record.
for prog in add loop sha256 poseidon2 storage revert; do
  a="$(grep -c "^steps\.$prog\.[0-9]* " "$(m9_steps_native)" || true)"
  b="$(grep -c "^steps\.$prog\.[0-9]* " "$(m9_nohoist_steps)" || true)"
  assert_eq "control: $prog is untouched by the mutation" "$a" "$b"
done

finish
