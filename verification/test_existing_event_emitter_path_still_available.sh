#!/usr/bin/env bash
# test_existing_event_emitter_path_still_available
#
# THE NO-PATCH FALLBACK, EXERCISED RATHER THAN ASSUMED — and, on measurement, narrower than this
# milestone's own deliverable says it is.
#
# The deliverable reads: "`EventEmitterInterface<ExecutionEvent>` emitting one event per instruction
# from `Execution::execute` ... So step-level tracing is available today with no code change at
# hint-collection cost." The first clause is true. The second is not, as written, and the reason is
# in upstream's own source at the pinned anchor:
#
#   AvmSimAPI::simulate(collect_hints = true)
#     -> AvmSimulationHelper::simulate_for_hint_collection_internal
#        -> simulate_for_witgen_internal<NoopEventEmitter, NoopEventEmitter>
#           // "We use NoopEventEmitters here because we don't want to collect events."
#
# So the production entry point DISCARDS every ExecutionEvent it produces. The events materialise
# only in `AvmSimulationHelper::simulate_for_witgen(hints)`, which runs a SECOND full simulation
# over the hinted DBs. The fallback therefore costs hint collection AND a re-simulation, and it
# reaches the events through a public method that `AvmSimAPI` does not call.
#
# All of that is asserted from the fork AT THE ANCHOR, live, on every run — never from our copy of
# it — and then the fallback is RUN: `collect_hints = true`, then `simulate_for_witgen`, on all
# eight programs, on both targets.
#
# And then the comparison that makes this worth more than a fallback demonstration: the 39,086
# records upstream's own seam produces are compared FIELD FOR FIELD against the 39,086 the new
# fast-path observer produces. Context id, pc, opcode, cumulative l2 and da gas, contract address.
# If the two seams disagreed about any instruction, the patch would be wrong.

set -uo pipefail
TEST_NAME=test_existing_event_emitter_path_still_available
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

m9_measured
mkdir -p "$M9_WORK"

# ---------------------------------------------------------------------------
# The three seams, read live out of the fork at the anchor. Not out of the measured tree, which
# carries six of our patches, and not out of prose.
# ---------------------------------------------------------------------------
up="$M9_WORK/upstream"; mkdir -p "$up"
m8_upstream_file barretenberg/cpp/src/barretenberg/vm2/simulation_helper.cpp "$up/simulation_helper.cpp"
m8_upstream_file barretenberg/cpp/src/barretenberg/vm2/simulation_helper.hpp "$up/simulation_helper.hpp"
m8_upstream_file barretenberg/cpp/src/barretenberg/vm2/avm_sim_api.cpp "$up/avm_sim_api.cpp"
m8_upstream_file barretenberg/cpp/src/barretenberg/vm2/simulation/standalone/hybrid_execution.cpp \
  "$up/hybrid_execution.cpp"
m8_upstream_file barretenberg/cpp/src/barretenberg/vm2/simulation/standalone/hybrid_execution.hpp \
  "$up/hybrid_execution.hpp"
m8_upstream_file barretenberg/cpp/src/barretenberg/vm2/common/avm_io.hpp "$up/avm_io.hpp"
m8_upstream_file barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/call_stack_metadata_collector.hpp \
  "$up/call_stack_metadata_collector.hpp"

# Seam 1: call-frame granularity, and the shape the new interface copies.
assert_true "upstream has a CallStackMetadataCollectorInterface" \
  grep -q 'class CallStackMetadataCollectorInterface' "$up/call_stack_metadata_collector.hpp"
assert_true "gated by PublicSimulatorConfig::collect_call_metadata" \
  grep -q 'bool collect_call_metadata' "$up/avm_io.hpp"
# Seam 3: a count, not a trace.
assert_true "and a collect_statistics flag" grep -q 'bool collect_statistics' "$up/avm_io.hpp"
assert_true "whose only per-instruction output is a COUNT" \
  grep -q 'total_instructions_executed' "$up/simulation_helper.cpp"
# Seam 2's emitter itself.
assert_true "and an EventEmitterInterface<ExecutionEvent> in the witgen path" \
  grep -q 'DefaultEventEmitter<ExecutionEvent> execution_emitter;' "$up/simulation_helper.cpp"
# The AVM is NOT unobservable today, and this check exists partly so no write-up can say it is.
# Counted rather than asserted three times over, so "three seams" is a number this check produced.
seams=0
grep -q 'class CallStackMetadataCollectorInterface' "$up/call_stack_metadata_collector.hpp" && seams=$((seams + 1))
grep -q 'DefaultEventEmitter<ExecutionEvent> execution_emitter;' "$up/simulation_helper.cpp" && seams=$((seams + 1))
grep -q 'bool collect_statistics' "$up/avm_io.hpp" && seams=$((seams + 1))
assert_eq "upstream at the anchor already has three observation seams, and this check names them" \
  "3" "$seams"

# Seam 2, and the gap. `HybridExecution::execute` emits nothing, by design and by its own comment.
assert_true "the fast loop's header says it exists to remove overhead" \
  grep -qi 'overrides the execution loop' "$up/hybrid_execution.hpp"
assert_eq "the fast loop emits no ExecutionEvent at all at the anchor" "0" \
  "$(grep -c 'ExecutionEvent' "$up/hybrid_execution.cpp" || true)"
assert_true "while AvmSimAPI::simulate dispatches to it whenever collect_hints is false" \
  grep -q 'if (inputs.config.collect_hints)' "$up/avm_sim_api.cpp"
assert_true "and to the hint-collecting path otherwise" \
  grep -q 'simulate_for_hint_collection_internal' "$up/avm_sim_api.cpp"

# THE CORRECTION. The hint-collecting path instantiates the witgen template with NoopEventEmitters,
# so the events it produces are thrown away.
hint_body="$(sed -n '/^TxSimulationResult AvmSimulationHelper::simulate_for_hint_collection_internal/,/^}/p' \
  "$up/simulation_helper.cpp")"
assert_true "the hint-collecting path was located in upstream's own source" test -n "$hint_body"
assert_contains "it instantiates the witgen template with NoopEventEmitters" \
  "simulate_for_witgen_internal<NoopEventEmitter, NoopEventEmitter>" "$hint_body"
assert_contains "and says so: it does not want to collect events" \
  "we don't want to collect events" "$hint_body"
# Where they DO materialise: a second, separate simulation.
witgen_body="$(sed -n '/^EventsContainer AvmSimulationHelper::simulate_for_witgen/,/^}/p' \
  "$up/simulation_helper.cpp")"
assert_true "simulate_for_witgen was located" test -n "$witgen_body"
assert_contains "it instantiates the same template with real EventEmitters" \
  "simulate_for_witgen_internal<EventEmitter, DeduplicatingEventEmitter>" "$witgen_body"
assert_contains "over the HINTED databases, i.e. a second simulation" "HintedRawContractDB" "$witgen_body"
assert_true "and it is public, so a caller can reach it" \
  grep -q 'simulation::EventsContainer simulate_for_witgen(const ExecutionHints& hints);' \
  "$up/simulation_helper.hpp"
assert_eq "AvmSimAPI never calls it, so the production entry point cannot return the events" "0" \
  "$(grep -c 'simulate_for_witgen(' "$up/avm_sim_api.cpp" || true)"

# ---------------------------------------------------------------------------
# Now run it. Both targets.
# ---------------------------------------------------------------------------
native_bin="$(m9_native_bin "$M9_TREE")"
wasm_bin="$(m9_wasm_bin "$M9_TREE")"
m8_require_artifacts "$native_bin" "$wasm_bin" "$(m9_steps_native)" "$(m9_steps_v8)"

m9_run_native "$native_bin" "$(m9_events_native)" "$(m9_events_native_err)" events
assert_eq "the native fallback run exited 0" "0" "$?"
m9_run_v8 "$wasm_bin" "$(m9_events_v8)" "$(m9_events_v8_err)" events
assert_eq "the V8 fallback run exited 0" "0" "$?"
m8_require_artifacts "$(m9_events_native)" "$(m9_events_v8)"

for label in native v8; do
  case "$label" in
    native) e="$(m9_events_native)" ;;
    v8)     e="$(m9_events_v8)" ;;
  esac
  # The RUN's completeness, not the AVM's behaviour: a transcript missing its terminal sentinel is
  # a truncated run, and this says so with the line count rather than leaving the next reader to
  # infer it from "oob emitted no events".
  #
  # THE ASSERTION WAS NOT ENOUGH, AND THAT WAS OPEN SINCE M24. This is the second of the two checks
  # `m9_completeness` was wired into only as a REPORT. An `assert_eq … complete` names the
  # truncation, which is better than nothing — but it does not STOP the loop below, so the
  # per-program comparisons still run against a short transcript and still emit
  # "[v8] oob: upstream's own seam emitted one event per instruction, expected [3], got []". At
  # every sighting since M24 this file has contributed exactly that one misattributing red beside
  # the eleven in `test_observer_fires_on_exceptional_halt`. A precondition that reports and does
  # not refuse is a precondition the next reader still has to argue with.
  #
  # The `die` comes first; the assertion is kept because the two ask different questions (see the
  # note in `test_observer_fires_on_exceptional_halt`) and because it is the one that would notice
  # a transcript arriving whole with the sentinel set to 0.
  require_complete_transcript "$e" avmEvents.done "[$label] the fallback event"
  assert_eq "[$label] the fallback transcript is complete rather than truncated" \
    "complete" "$(m9_completeness "$e" avmEvents.done)"
  assert_eq "[$label] it states its coverage" \
    "eight-hand-assembled-programs-per-record-the-upstream-ExecutionEvent-seam" \
    "$(m9_field "$e" avmEvents.coverage)"
  for prog in $M9_PROGRAMS; do
    want="$(m9_expect_steps "$prog")"
    assert_eq "[$label] $prog: upstream's own seam emitted one event per instruction" "$want" \
      "$(m9_field "$e" "events.$prog.count")"
  done
done

# The fallback is target-independent too: the two runs agree line for line on everything that is
# not a diagnostic.
n_ord="$M9_WORK/native.events.ordinary"; w_ord="$M9_WORK/wasm-v8.events.ordinary"
m9_ordinary "$(m9_events_native)" >"$n_ord"
m9_ordinary "$(m9_events_v8)" >"$w_ord"
assert_ge "the fallback transcript is not empty" 1000 "$(wc -l <"$n_ord")"
assert_true "the fallback transcript is identical native versus wasm" cmp -s "$n_ord" "$w_ord"
assert_eq "and it carries the recorded number of event records" "$M9_EXPECTED_EVENT_RECORDS" \
  "$(m9_event_record_count "$(m9_events_native)")"

# ---------------------------------------------------------------------------
# The comparison: the new seam against upstream's, record for record.
# ---------------------------------------------------------------------------
python3 "$M9_RECORDS_COMPARE" "$(m9_steps_native)" "$(m9_events_native)" \
  >"$M9_WORK/records-compare.tsv" 2>"$M9_WORK/records-compare.err"
rc=$?
assert_eq "the record comparator ran" "0" "$rc"
[ "$rc" -eq 0 ] || die "the record comparator failed: $(head -3 "$M9_WORK/records-compare.err")"
m8_report "$M9_WORK/records-compare.tsv"

# And on the wasm side too, which is a different fact.
python3 "$M9_RECORDS_COMPARE" "$(m9_steps_v8)" "$(m9_events_v8)" \
  >"$M9_WORK/records-compare-wasm.tsv" 2>/dev/null
assert_eq "the record comparator ran on the wasm transcripts" "0" "$?"
assert_eq "no failure in the wasm record comparison" "0" \
  "$(grep -c '^FAIL' "$M9_WORK/records-compare-wasm.tsv" || true)"
assert_ge "the wasm record comparison made assertions" 25 \
  "$(grep -c . "$M9_WORK/records-compare-wasm.tsv" || true)"

# ---------------------------------------------------------------------------
# Negative controls: the comparator must be able to see a disagreement.
# ---------------------------------------------------------------------------
ctl="$M9_WORK/records-controls"; rm -rf "$ctl"; mkdir -p "$ctl"
sed '0,/^events\.burn\.20000 /s/\(^events\.burn\.20000 ctx=[0-9]* pc=\)[0-9]*/\17777/' \
  "$(m9_events_native)" >"$ctl/flipped.events"
assert_false "the flipped control differs from the original" \
  cmp -s "$ctl/flipped.events" "$(m9_events_native)"
python3 "$M9_RECORDS_COMPARE" "$(m9_steps_native)" "$ctl/flipped.events" \
  >"$ctl/flipped.tsv" 2>/dev/null
assert_true "one disagreeing record is rejected, naming it" \
  grep -q '^FAIL	every record is identical field for field' "$ctl/flipped.tsv"

grep -v '^events\.burn\.38902 ' "$(m9_events_native)" >"$ctl/dropped.events"
python3 "$M9_RECORDS_COMPARE" "$(m9_steps_native)" "$ctl/dropped.events" \
  >"$ctl/dropped.tsv" 2>/dev/null
assert_true "a single MISSING event is rejected, and by the set comparison rather than the count" \
  grep -q '^FAIL	no instruction is observed by the new seam and not by upstream' "$ctl/dropped.tsv"

: >"$ctl/empty.events"
python3 "$M9_RECORDS_COMPARE" "$(m9_steps_native)" "$ctl/empty.events" >"$ctl/empty.tsv" 2>/dev/null
assert_eq "an empty side makes the comparator exit 3 rather than agree with nothing" "3" "$?"
assert_eq "and it produced no PASS rows" "0" "$(grep -c '^PASS' "$ctl/empty.tsv" || true)"

finish
