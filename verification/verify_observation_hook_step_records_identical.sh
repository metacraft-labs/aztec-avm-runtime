#!/usr/bin/env bash
# verify_observation_hook_step_records_identical
#
# M9's check that BUILDS. Everything else in the milestone reads what this one produces.
#
# Prepares $M9_WORK/m9 — 233d8e0993 + the four AVM_WASM series patches + THE PREPARED OBSERVER
# PATCH + M7's AVM_SIM_TESTS overlay + M8's AVM_DIFFERENTIAL overlay + M9's driver overlay —
# builds `avm_differential` for x86-64 and for wasm32-wasip1 from the SAME translation unit, and
# runs its `steps` mode on three hosts: native, node's WASI (V8) over the SHIPPED module, and
# wasmtime over a `wasm-merge`d copy.
#
# The subject is 39,086 individual per-instruction step records — context id, pc, opcode,
# cumulative l2 and da gas, contract address — compared PER RECORD and IN ORDER, never by count.
#
# Additive is measured on the OFF side too: with `collect_execution_steps` left at its default the
# records are absent, and the default is read out of the PATCH'S OWN added line rather than
# assumed.
#
# Three negative controls, each required to fail by its own message: a single flipped field (which
# leaves the line count unchanged), a truncated transcript (whose surviving records are an
# identical PREFIX, which is why a count is not enough), and the same transcript handed in on both
# sides with its pointer width intact — a comparison of a binary with itself, which is M5's lesson.

set -uo pipefail
TEST_NAME=verify_observation_hook_step_records_identical
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m9_observer.sh"


# THE SUMMARY LINE ON AN ABNORMAL EXIT — installed 2026-08-31, closing the other half of the
# `m9_completeness` item that has been open since M24.
#
# This check can now `die` on an incomplete transcript, which is the point. A `die` prints no
# summary line, and the sweep counts summary lines, so without this trap a correct refusal makes
# M9 read 524 where it reads 807 — a 283-assertion silent shrink with nothing red to explain it.
# That is exactly what M31's, M32's review's and M37's review's sweeps recorded, every time.
summary_on_abnormal_exit

mkdir -p "$M9_WORK"

# ---------------------------------------------------------------------------
# The prepared patch, before anything is built from it.
# ---------------------------------------------------------------------------
assert_file "the prepared observer patch exists" "$M9_OBSERVER_PATCH"
assert_file "M9's driver overlay exists" "$M9_PATCH_7"

anchor="$(m8_anchor)"
assert_true "the anchor was read from pins.json" test -n "$anchor"
# The load-bearing assertion about applicability is that `git am` applies the patch to the anchor
# with NO -3, which m6_prepare_tree performs below and dies on;
# verify_execution_observer_patch_applies_to_upstream applies it to the anchor ALONE and pins the
# resulting tree hash, because a patch can be altered and still apply cleanly (M3's lesson).

# ---------------------------------------------------------------------------
# The tree.
# ---------------------------------------------------------------------------
tree="$(m9_tree)"
assert_dir "the M9 worktree exists" "$tree"
assert_eq "the worktree is the anchor plus exactly eight patches" "8" \
  "$(git -C "$tree" rev-list --count "$anchor..HEAD" 2>/dev/null)"
assert_eq "nothing under barretenberg/ is modified in the worktree" "" "$(m9_tree_dirty "$tree")"
assert_file "the observer patch really landed: the interface header is in the tree" \
  "$tree/barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/execution_observer.hpp"
assert_file "the reference collector is in the tree" \
  "$tree/barretenberg/cpp/src/barretenberg/vm2/simulation/lib/execution_observer.cpp"

# The flag's DEFAULT, read out of the patch's own added line rather than out of the tree, so a
# later edit that flipped it on could not pass here.
default_line="$(grep -E '^\+ *bool collect_execution_steps' "$M9_OBSERVER_PATCH" | head -1)"
assert_contains "the patch adds collect_execution_steps defaulting to false" \
  "collect_execution_steps = false" "$default_line"
assert_eq "the patch adds exactly one collect_execution_steps field" "1" \
  "$(grep -cE '^\+ *bool collect_execution_steps' "$M9_OBSERVER_PATCH")"

# The interface takes a WireOpCode, not an Instruction. That is the design decision the spike's own
# measurement forced (hoisting an Instruction, which owns a vector, puts cleanup on every exception
# path) and it is asserted here rather than left in prose.
obs_hpp="$tree/barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/execution_observer.hpp"
assert_true "on_instruction takes a WireOpCode" \
  grep -q "WireOpCode opcode" "$obs_hpp"
assert_false "on_instruction does NOT take an Instruction" \
  grep -qE "const Instruction&" "$obs_hpp"
hybrid="$tree/barretenberg/cpp/src/barretenberg/vm2/simulation/standalone/hybrid_execution.cpp"
assert_true "pc is hoisted out of the try block" \
  grep -qE "^ *PC observed_pc = 0;" "$hybrid"
assert_true "the opcode is hoisted out of the try block, initialised to the sentinel" \
  grep -qE "^ *WireOpCode observed_opcode = WireOpCode::LAST_OPCODE_SENTINEL;" "$hybrid"
# ... and the hoist is BEFORE the try, which is the whole point. Line numbers, compared.
hoist_line="$(grep -n 'PC observed_pc = 0;' "$hybrid" | head -1 | cut -d: -f1)"
try_line="$(grep -n '^ *try {' "$hybrid" | head -1 | cut -d: -f1)"
if [ -n "$hoist_line" ] && [ -n "$try_line" ] && [ "$hoist_line" -lt "$try_line" ]; then
  pass "the hoist is above the try block  [line $hoist_line < $try_line]"
else
  fail "the hoist is not above the try block  [hoist=$hoist_line try=$try_line]"
fi
# The observer is injected, not reached through a global. The spike used a process global; the
# shipped shape is a constructor parameter and a member, as CallStackMetadataCollectorInterface is.
exec_hpp="$tree/barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/execution.hpp"
assert_true "the observer is injected through Execution's constructor" \
  grep -qE "ExecutionObserverInterface\* execution_observer = nullptr" "$exec_hpp"
assert_true "and stored as a member, beside the call-stack collector" \
  grep -qE "ExecutionObserverInterface\* execution_observer_ = nullptr;" "$exec_hpp"
assert_eq "no process global is introduced anywhere by the patch" "0" \
  "$(grep -cE '^\+.*g_execution_observer' "$M9_OBSERVER_PATCH")"

# ---------------------------------------------------------------------------
# The builds. cmake's status and ninja's asserted SEPARATELY from anything parsed out of either:
# a stale binary will happily print a plausible transcript over a build that did not happen.
# ---------------------------------------------------------------------------
note "building for wasm32-wasip1 (this is the slow part)"
m9_build_wasm "$tree"
assert_eq "the wasm configure exited 0" "0" "${M9_WASM_CONFIGURE_RC:-missing}"
assert_eq "the wasm build of avm_differential exited 0" "0" "${M9_WASM_BUILD_RC:-missing}"

note "building for x86-64"
m9_build_native "$tree"
assert_eq "the native configure exited 0" "0" "${M9_NATIVE_CONFIGURE_RC:-missing}"
assert_eq "the native build of avm_differential exited 0" "0" "${M9_NATIVE_BUILD_RC:-missing}"

# A build failure under -Wfatal-errors emits exactly one `fatal error:` per unit and nothing after
# it, and `grep ' error: '` matches `fatal error:` as a substring — both hazards this campaign has
# met. So the build logs are asserted on the ABSENCE of any diagnostic at all, anchored.
for label in "$M9_WASM_BUILD" "$M9_NATIVE_BUILD"; do
  assert_eq "no compiler error in the $label log" "0" \
    "$(m6_build_log "$tree" "$label" | grep -cE '(^|[^-a-z])(fatal )?error:' || true)"
done

wasm_bin="$(m9_wasm_bin "$tree")"
native_bin="$(m9_native_bin "$tree")"
m8_require_artifacts "$wasm_bin" "$native_bin"
assert_file "the wasm module exists" "$wasm_bin"
assert_file "the native binary exists" "$native_bin"
assert_eq "the wasm artefact is a wasm module" "0061736d" \
  "$(head -c 4 "$wasm_bin" | od -An -tx1 | tr -d ' \n')"

# Identical sources: both targets' avm_differential built from the same translation units, taken
# from the two targets' own object lists rather than from a compile-database grep — which reported
# a false difference for M8, because a native AVM=ON configure legitimately compiles
# vm2/testing/*.cpp a second time into the vm2 module.
# The two toolchains name object files differently — clang writes `.o`, the wasi-sdk driver
# through CMake writes `.obj` — so the extension is stripped and the SOURCE names compared. That
# is what "identical sources" means here, and it is taken from the two targets' own object lists
# rather than from a compile-database grep, which reported a false difference for M8 because a
# native AVM=ON configure legitimately compiles vm2/testing/*.cpp a second time into vm2.
objlist() {
  find "$1/src/barretenberg/vm2/CMakeFiles/avm_differential.dir" \
    \( -name '*.o' -o -name '*.obj' \) -printf '%f\n' 2>/dev/null \
    | sed 's/\.o$//; s/\.obj$//' | LC_ALL=C sort | tr '\n' ' '
}
wasm_objs="$(objlist "$tree/barretenberg/cpp/$M9_WASM_BUILD")"
native_objs="$(objlist "$tree/barretenberg/cpp/$M9_NATIVE_BUILD")"
assert_true "the wasm target has objects to list" test -n "$wasm_objs"
assert_true "the native target has objects to list" test -n "$native_objs"
assert_eq "both targets are built from the same six translation units" "$wasm_objs" "$native_objs"
assert_eq "which is six" "6" "$(printf '%s\n' $wasm_objs | wc -l)"
assert_contains "and that list includes the driver itself" "avm_differential.cpp" "$wasm_objs"

# ---------------------------------------------------------------------------
# The runs. stdout is the transcript, exactly; stderr goes to its own file, for M8's reason.
# ---------------------------------------------------------------------------
note "running the step-record mode on three hosts"
m9_run_native "$native_bin" "$(m9_steps_native)" "$(m9_steps_native_err)" steps
assert_eq "the native run exited 0" "0" "$?"
m9_run_v8 "$wasm_bin" "$(m9_steps_v8)" "$(m9_steps_v8_err)" steps
assert_eq "the V8 run of the SHIPPED module exited 0" "0" "$?"
m9_run_wasmtime "$wasm_bin" "$(m9_steps_wasmtime)" "$(m9_steps_wasmtime_err)" steps
assert_eq "the wasmtime run exited 0" "0" "$?"

m8_require_artifacts "$(m9_steps_native)" "$(m9_steps_v8)" "$(m9_steps_wasmtime)"

# THE TRUNCATION IS A PRECONDITION HERE NOW, WHICH IS THE FIX THE BRIEF RECORDS AS OUTSTANDING.
#
# This check produced 798 assertions, 3 pass / 4 FAIL and 32 failing assertions once, and all 32
# had one cause: the V8 step transcript stopped inside `burn` at record 16,719 of 38,915 and the
# terminal `avmSteps.done` sentinel never arrived. Stderr was complete, so the guest had run every
# program to the end. The failures were named "oob recorded no steps" and "burn's last record is
# not the instruction that exhausted the gas" — each reads like a discovery about the interpreter
# and none of them is. `_steps_compare.py` DOES detect the truncation, but it detects it as a
# `FAIL` line among dozens of others, which is precisely the shape that gets believed.
#
# So the question is asked BEFORE the comparator runs, of all three transcripts, through lib.sh's
# single implementation. One precondition failure naming the truncation, instead of 32 assertions
# naming the AVM. The comparator's own truncation detection stays exactly as it is — the control at
# "a truncated run is rejected" below depends on it, and that control is about the COMPARATOR.
for _which in native v8 wasmtime; do
  case "$_which" in
    (native)   _tf="$(m9_steps_native)" ;;
    (v8)       _tf="$(m9_steps_v8)" ;;
    (wasmtime) _tf="$(m9_steps_wasmtime)" ;;
  esac
  require_complete_transcript "$_tf" avmSteps.done "the $_which step" "$(m9_steps_native)"
  assert_eq "the $_which step transcript is complete, so what follows is about the AVM" \
    "complete" "$(transcript_completeness "$_tf" avmSteps.done)"
done

# The streams really are separate, and that is asserted in BOTH directions rather than being a
# claim about silence: `common/log.cpp` sets bb_log_level = VERBOSE unconditionally under __wasm__
# and INFO otherwise, so the wasm run logs on fd 2 and the native one does not.
assert_eq "no AVM log line leaked into the native transcript" "0" \
  "$(grep -c '(mem: N/A)' "$(m9_steps_native)" || true)"
assert_eq "no AVM log line leaked into the V8 transcript" "0" \
  "$(grep -c '(mem: N/A)' "$(m9_steps_v8)" || true)"
assert_ge "the wasm run's own stderr carries the AVM's log lines" 20 \
  "$(grep -c '(mem: N/A)' "$(m9_steps_v8_err)" || true)"

# ---------------------------------------------------------------------------
# The comparison itself.
# ---------------------------------------------------------------------------
sentinel="$(m9_sentinel_opcode)"
assert_true "WireOpCode::LAST_OPCODE_SENTINEL was derived from upstream's own opcodes.hpp" \
  test -n "$sentinel"
note "LAST_OPCODE_SENTINEL = $sentinel (derived, not restated)"

python3 "$M9_STEPS_COMPARE" "$(m9_steps_native)" "$(m9_steps_v8)" \
  "$M9_STEPS_PEAK_PAGE_BUDGET" "$sentinel" >"$M9_WORK/steps-compare.tsv" 2>"$M9_WORK/steps-compare.err"
rc=$?
assert_eq "the step comparator ran" "0" "$rc"
[ "$rc" -eq 0 ] || die "the comparator failed: $(head -3 "$M9_WORK/steps-compare.err")"
m8_report "$M9_WORK/steps-compare.tsv"

# The second runtime is not a formality: a result one host reports is a result about that host.
python3 "$M9_STEPS_COMPARE" "$(m9_steps_native)" "$(m9_steps_wasmtime)" \
  "$M9_STEPS_PEAK_PAGE_BUDGET" "$sentinel" >"$M9_WORK/steps-compare-wasmtime.tsv" 2>/dev/null
assert_eq "the step comparator ran against wasmtime too" "0" "$?"
assert_eq "no failure in the wasmtime comparison" "0" \
  "$(grep -c '^FAIL' "$M9_WORK/steps-compare-wasmtime.tsv" || true)"
assert_ge "the wasmtime comparison made assertions" 40 \
  "$(grep -c . "$M9_WORK/steps-compare-wasmtime.tsv" || true)"

# The counts, as identities, at this level too, so the numbers this milestone quotes are asserted
# and not only computed inside the comparator.
n_records="$(m9_step_record_count "$(m9_steps_native)")"
assert_eq "the native transcript carries the recorded number of step records" \
  "$M9_EXPECTED_STEP_RECORDS" "$n_records"
assert_eq "the V8 transcript carries the same" \
  "$M9_EXPECTED_STEP_RECORDS" "$(m9_step_record_count "$(m9_steps_v8)")"
assert_eq "the wasmtime transcript carries the same" \
  "$M9_EXPECTED_STEP_RECORDS" "$(m9_step_record_count "$(m9_steps_wasmtime)")"
assert_eq "the non-diagnostic line count is the recorded one" \
  "$M9_EXPECTED_ORDINARY_LINES" "$(m9_ordinary "$(m9_steps_native)" | wc -l)"

# ---------------------------------------------------------------------------
# Negative controls. Each must be rejected, and by its OWN message.
# ---------------------------------------------------------------------------
ctl="$M9_WORK/controls"; rm -rf "$ctl"; mkdir -p "$ctl"

# (1) One flipped field, in the middle of `burn`. The line count does not move.
sed '0,/^steps\.burn\.20000 /s/^\(steps\.burn\.20000 ctx=[0-9]* pc=\)[0-9]*/\19999/' \
  "$(m9_steps_v8)" >"$ctl/flipped.steps"
assert_false "the flipped-field control is not identical to the original" \
  cmp -s "$ctl/flipped.steps" "$(m9_steps_v8)"
python3 "$M9_STEPS_COMPARE" "$(m9_steps_native)" "$ctl/flipped.steps" \
  "$M9_STEPS_PEAK_PAGE_BUDGET" "$sentinel" >"$ctl/flipped.tsv" 2>/dev/null
assert_ge "a single flipped field is rejected" 1 "$(grep -c '^FAIL' "$ctl/flipped.tsv" || true)"
assert_true "and it is rejected by the per-record assertion, naming the field" \
  grep -q '^FAIL	the step records are identical field for field' "$ctl/flipped.tsv"
assert_eq "the flipped control still has the same number of lines, so a count would have passed it" \
  "$(wc -l <"$(m9_steps_v8)")" "$(wc -l <"$ctl/flipped.steps")"

# (2) A truncated run. Its surviving records are an identical PREFIX.
head -n 20000 "$(m9_steps_v8)" >"$ctl/truncated.steps"
python3 "$M9_STEPS_COMPARE" "$(m9_steps_native)" "$ctl/truncated.steps" \
  "$M9_STEPS_PEAK_PAGE_BUDGET" "$sentinel" >"$ctl/truncated.tsv" 2>/dev/null
assert_ge "a truncated run is rejected" 1 "$(grep -c '^FAIL' "$ctl/truncated.tsv" || true)"
assert_true "and it is rejected for not having run to completion" \
  grep -q '^FAIL	B ran to completion' "$ctl/truncated.tsv"

# (3) The same transcript on both sides. This is the shape that reports "IDENTICAL" while having
# compared a binary with itself — M5's declared limitation, closed there and asserted here.
python3 "$M9_STEPS_COMPARE" "$(m9_steps_native)" "$(m9_steps_native)" \
  "$M9_STEPS_PEAK_PAGE_BUDGET" "$sentinel" >"$ctl/same.tsv" 2>/dev/null
assert_ge "the same transcript handed in twice is rejected" 1 \
  "$(grep -c '^FAIL' "$ctl/same.tsv" || true)"
assert_true "and it is rejected because the second side is not a 32-bit target" \
  grep -q '^FAIL	the B target is 32-bit' "$ctl/same.tsv"

# (4) The two sides swapped, which nothing else here would notice.
python3 "$M9_STEPS_COMPARE" "$(m9_steps_v8)" "$(m9_steps_native)" \
  "$M9_STEPS_PEAK_PAGE_BUDGET" "$sentinel" >"$ctl/swapped.tsv" 2>/dev/null
assert_ge "the two sides swapped are rejected" 1 "$(grep -c '^FAIL' "$ctl/swapped.tsv" || true)"

# (5) An empty transcript makes the comparator REFUSE rather than agree with nothing.
: >"$ctl/empty.steps"
python3 "$M9_STEPS_COMPARE" "$(m9_steps_native)" "$ctl/empty.steps" \
  "$M9_STEPS_PEAK_PAGE_BUDGET" "$sentinel" >"$ctl/empty.tsv" 2>/dev/null
assert_eq "an empty transcript makes the comparator exit 3 rather than pass vacuously" "3" "$?"
assert_eq "and it produced no PASS rows at all" "0" "$(grep -c '^PASS' "$ctl/empty.tsv" || true)"

# ---------------------------------------------------------------------------
# The record every other M9 check reads.
# ---------------------------------------------------------------------------
{
  printf 'M9_TREE=%s\n' "$tree"
  printf 'M9_SENTINEL_OPCODE=%s\n' "$sentinel"
  printf 'M9_MEASURED_RECORDS=%s\n' "$n_records"
  printf 'M9_MEASURED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$M9_WORK/measured.env"
assert_file "the measurement record was written" "$M9_WORK/measured.env"

finish
