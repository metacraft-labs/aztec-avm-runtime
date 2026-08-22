#!/usr/bin/env bash
# verify_observation_hook_overhead_budget
#
# Traced-versus-untraced overhead on the `burn` program, with all 38,903 step records materialised,
# on three hosts: native x86-64, node's WASI (V8) and wasmtime.
#
# THE MILESTONE'S OWN QUOTED NUMBERS ARE SUPERSEDED BY MEASUREMENT, and this check is where that is
# established. Its entry says "measured 2.3% native and 2.4% wasm". The wasm half holds. The native
# half does not: measured here at about +10% on the minimum and the median. The 2.3% belongs to the
# spike's 16-byte step record; the shipped `ExecutionStep` is 48 bytes on x86-64, of which 32 are
# the contract address, and the prepared PR.md already said +12% for exactly that reason. The
# native untraced loop is about 2.3x faster than the wasm one, so the same absolute per-record
# store is a much larger FRACTION of it — which is why one figure cannot serve for both targets and
# why this check carries two budgets.
#
# The overhead is dominated by what the reference collector STORES, not by the seam. The seam's own
# cost, with nothing attached, is test_observer_disabled_is_free's subject and is a different
# measurement entirely.
#
# The two arms are interleaved INSIDE ONE PROCESS rather than run as blocks, so a machine that gets
# busier halfway through cannot put the whole difference into whichever arm ran second. And the
# check asserts that the traced run is SLOWER: an observer that cost nothing while materialising
# 38,903 records would mean the records were not materialised, which is the way this check could
# most plausibly have passed for the wrong reason.

set -uo pipefail
TEST_NAME=verify_observation_hook_overhead_budget
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m9_observer.sh"

m9_measured
patched_bin="$(m9_native_bin "$M9_TREE")"
patched_wasm="$(m9_wasm_bin "$M9_TREE")"
m8_require_artifacts "$patched_bin" "$patched_wasm" "$(m9_steps_native)"

bench_dir="$M9_WORK/overhead"; rm -rf "$bench_dir"; mkdir -p "$bench_dir"

# The subject is a specific number of records, and it is asserted before any timing is quoted —
# "with all 38,903 step records materialised" is the deliverable's own wording.
assert_eq "burn executes $M9_STEPS_burn instructions" "$M9_STEPS_burn" \
  "$(m9_field "$(m9_steps_native)" steps.burn.instructionsExecuted)"
assert_eq "and the traced run materialises a record for every one" "$M9_STEPS_burn" \
  "$(m9_field "$(m9_steps_native)" steps.burn.count)"
assert_eq "burn is the heaviest program in the corpus by instruction count" "$M9_STEPS_burn" \
  "$(for p in $M9_PROGRAMS; do m9_field "$(m9_steps_native)" "steps.$p.instructionsExecuted"; done \
     | sort -n | tail -1)"

# What a record costs, from the tree rather than from prose: five fields, one of them a field
# element. That is the reason the enabled figure is what it is.
avm_io="$M9_TREE/barretenberg/cpp/src/barretenberg/vm2/common/avm_io.hpp"
assert_true "ExecutionStep carries the contract address, which is most of its size" \
  grep -q 'FF contract_address;' "$avm_io"
assert_eq "and it carries exactly five fields" "5" \
  "$(sed -n '/^struct ExecutionStep {/,/^};/p' "$avm_io" | grep -cE '^ +[A-Za-z_][A-Za-z0-9_:<>]* [a-z_]+;')"

run_arm() { # <label> <runner> <artefact> <report>
  local label="$1" runner="$2" art="$3" report="$4"
  local out="$bench_dir/$label.out" err="$bench_dir/$label.err"
  "$runner" "$art" "$out" "$err" benchsteps burn "$M9_BENCH_REPS_ENABLED"
  local rc=$?
  assert_eq "[$label] the interleaved timing run exited 0" "0" "$rc"
  [ "$rc" -eq 0 ] || die "[$label] the timing run failed — see $err"
  assert_eq "[$label] it ran to completion" "1" "$(m9_field "$out" benchsteps.done)"
  assert_eq "[$label] it timed burn" "burn" "$(m9_field "$out" benchsteps.program)"
  assert_eq "[$label] the binary carries the observer patch" "1" \
    "$(m9_field "$out" benchsteps.observerCompiledIn)"
  # The sink proves the traced results were consumed rather than optimised away: it accumulates
  # the step count of every traced run, so it cannot be zero and cannot be only the gas.
  local sink; sink="$(m9_field "$out" benchsteps.sink)"
  assert_ge "[$label] the timed results were consumed (the sink counted the materialised records)" \
    "$((M9_STEPS_burn * M9_BENCH_REPS_ENABLED))" "$sink"

  local tsv="$bench_dir/$label.tsv"
  { sed -n 's/^benchsteps\.off\.us\.[0-9]* /off\t/p' "$out"
    sed -n 's/^benchsteps\.on\.us\.[0-9]* /on\t/p' "$out"; } >"$tsv"
  assert_eq "[$label] $M9_BENCH_REPS_ENABLED untraced samples" "$M9_BENCH_REPS_ENABLED" \
    "$(grep -c '^off	' "$tsv" || true)"
  assert_eq "[$label] $M9_BENCH_REPS_ENABLED traced samples" "$M9_BENCH_REPS_ENABLED" \
    "$(grep -c '^on	' "$tsv" || true)"
  python3 "$M9_TIMING" --enabled "$tsv" "$5" "$label" >"$report" 2>"$bench_dir/$label.cmp.err"
  local crc=$?
  assert_eq "[$label] the timing comparator ran" "0" "$crc"
  [ "$crc" -eq 0 ] || die "[$label] comparator failed: $(head -3 "$bench_dir/$label.cmp.err")"
  m8_report "$report"
}

M9_BENCH_REPS_ENABLED="${M9_BENCH_REPS_ENABLED:-20}"

note "measuring traced versus untraced on three hosts"
run_arm native   m9_run_native   "$patched_bin"  "$bench_dir/native.report"   "$M9_ENABLED_BUDGET_NATIVE_PCT"
run_arm v8       m9_run_v8       "$patched_wasm" "$bench_dir/v8.report"       "$M9_ENABLED_BUDGET_WASM_PCT"
run_arm wasmtime m9_run_wasmtime "$patched_wasm" "$bench_dir/wasmtime.report" "$M9_ENABLED_BUDGET_WASM_PCT"

# ---------------------------------------------------------------------------
# The finding, asserted rather than narrated: the two targets do NOT agree, and the native figure
# is the larger one. A single budget for both would be wrong in one direction or the other.
# ---------------------------------------------------------------------------
pctof() { # <report> -> the median percentage the comparator measured, as an integer of tenths
  sed -n 's/^PASS\t\[[a-z0-9]*\] the traced overhead, as measured\t.*median \([+-][0-9.]*\)%.*/\1/p' "$1" \
    | head -1
}
n_pct="$(pctof "$bench_dir/native.report")"
v_pct="$(pctof "$bench_dir/v8.report")"
w_pct="$(pctof "$bench_dir/wasmtime.report")"
assert_true "the native overhead was read off the report" test -n "$n_pct"
assert_true "the V8 overhead was read off the report" test -n "$v_pct"
assert_true "the wasmtime overhead was read off the report" test -n "$w_pct"
note "measured medians: native $n_pct%  V8 $v_pct%  wasmtime $w_pct%"
bigger="$(python3 -c "import sys; print('1' if float(sys.argv[1]) > float(sys.argv[2]) * 2 else '0')" "$n_pct" "$v_pct")"
assert_eq "the native overhead is more than twice the wasm one, so one budget could not serve both" \
  "1" "$bigger"
superseded="$(python3 -c "import sys; print('1' if float(sys.argv[1]) > 5.0 else '0')" "$n_pct")"
assert_eq "the milestone's quoted 2.3% native is superseded: the measurement is above 5%" \
  "1" "$superseded"
confirmed="$(python3 -c "import sys; print('1' if float(sys.argv[1]) < 5.0 else '0')" "$v_pct")"
assert_eq "the milestone's quoted 2.4% wasm is confirmed: the measurement is below 5%" \
  "1" "$confirmed"

# ---------------------------------------------------------------------------
# The comparator's own discriminating power.
# ---------------------------------------------------------------------------
ctl="$bench_dir/controls"; mkdir -p "$ctl"
# A traced arm made 40% slower must breach the native budget.
awk -F'\t' 'BEGIN{OFS="\t"} $1=="on"{ $2 = int($2 * 1.40) } { print }' "$bench_dir/native.tsv" \
  >"$ctl/slow.tsv"
python3 "$M9_TIMING" --enabled "$ctl/slow.tsv" "$M9_ENABLED_BUDGET_NATIVE_PCT" native \
  >"$ctl/slow.report" 2>/dev/null
assert_eq "the comparator ran on the inflated samples" "0" "$?"
assert_true "a 40% traced overhead breaches the budget" \
  grep -q '^FAIL	\[native\] the traced overhead is within the' "$ctl/slow.report"

# A traced arm identical to the untraced one must ALSO fail: it would mean nothing was recorded.
grep '^off	' "$bench_dir/native.tsv" >"$ctl/free.tsv"
grep '^off	' "$bench_dir/native.tsv" | sed 's/^off/on/' >>"$ctl/free.tsv"
python3 "$M9_TIMING" --enabled "$ctl/free.tsv" "$M9_ENABLED_BUDGET_NATIVE_PCT" native \
  >"$ctl/free.report" 2>/dev/null
assert_eq "the comparator ran on the free samples" "0" "$?"
assert_true "a traced arm that costs NOTHING is rejected (the records would not have been made)" \
  grep -q '^FAIL	\[native\] the traced run is SLOWER' "$ctl/free.report"

# A budget equal to the measurement leaves no headroom and must be rejected.
rounded="$(python3 -c "import sys,math; print(max(1,math.ceil(float(sys.argv[1]))))" "$n_pct")"
python3 "$M9_TIMING" --enabled "$bench_dir/native.tsv" "$rounded" native \
  >"$ctl/tight.report" 2>/dev/null
assert_eq "the comparator ran on the tight budget" "0" "$?"
assert_true "a budget equal to the measurement is rejected for leaving no headroom" \
  grep -q '^FAIL	\[native\] the budget leaves headroom' "$ctl/tight.report"

# And a budget so large nothing could breach it is not a budget.
python3 "$M9_TIMING" --enabled "$bench_dir/native.tsv" 400 native >"$ctl/huge.report" 2>/dev/null
assert_eq "the comparator ran on the huge budget" "0" "$?"
assert_true "a 400% budget is rejected for being unable to fail" \
  grep -q '^FAIL	\[native\] the budget is small enough to be able to fail' "$ctl/huge.report"

finish
