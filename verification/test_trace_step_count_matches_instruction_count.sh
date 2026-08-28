#!/usr/bin/env bash
# test_trace_step_count_matches_instruction_count
#
# M25's entry, CARRIED TO M29 AND NOT DUPLICATED. M25's copy is retired in the same edit that adds
# this file, so no assertion is counted in two milestones — the error that once made M1 read 316
# against a true 141.
#
# ===========================================================================================
# WHY IT WAS `pending` FROM M25 UNTIL NOW.
# ===========================================================================================
#
# M25's own words: "the recorded step count equals the AVM's own executed-instruction statistic for
# the same transaction — which is `stats["total_instructions_executed"]`, behind
# `collect_statistics`, LOCATED BUT NOT YET DRIVEN". Nothing drove it because nothing recorded an
# executed stream: the steps in every container this repository produced were the artifact's own
# mapped program counters, and comparing a count of THOSE against an instruction count would have
# been comparing two unrelated numbers. M29 is the milestone that makes the two sides the same
# thing, which is why the entry moves here rather than being closed in place.
#
# ===========================================================================================
# THE IDENTITY, AND THE THREE WAYS IT IS READ.
# ===========================================================================================
#
# The number appears in four places and all four must agree:
#
#   1. `stats["total_instructions_executed"]` — the AVM's own counter, inside the module, computed
#      by code this campaign did not write;
#   2. `avm_steps_count()` — the length of the vector M9's observer filled;
#   3. the events the writer accepted — `ct_events_written()`, read off `ct_writer.wasm`;
#   4. the `"type": "Step"` records the PINNED READER emits from the finished container.
#
# 1 versus 2 is the AVM agreeing with itself and is the identity M25's entry names. 2 versus 3 is
# the producer not losing a record between the drain and the writer. 3 versus 4 is the container
# actually carrying them. A check that asserted only the first would be green over a container that
# had thrown half the stream away.
#
# ===========================================================================================
# AND THE COMPARISON IS SHOWN TO BE CAPABLE OF FAILING.
# ===========================================================================================
#
# An identity between four readings of one number is exactly the shape `CAMPAIGN-BRIEF.md` warns
# about — "a value compared with itself" — so two controls run beside it: the count M27 would have
# produced (64, its `DEMO_STEPS`) is required to DIFFER, and the reader's Step count over a
# TRUNCATED copy of the same container is required not to reproduce it.
#
# Run: just verify-m29-step-count

TEST_NAME="test_trace_step_count_matches_instruction_count"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m12_reactor.sh"
. "$VERIFY_DIR/lib_m29_steps.sh"

m29_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m29_require_arms
m24_require_readers
mkdir -p "$M29_WORK"

echo "== 1. the AVM's own statistic, and the stream it filled"

STAT="$(m27_arm publicOnly transfer.executed.instructionsExecuted)"
COUNT="$(m27_arm publicOnly transfer.executed.count)"
DECODED="$(m27_arm publicOnly transfer.executed.decoded)"
note "stats[total_instructions_executed] = $STAT; avm_steps_count() = $COUNT"

# NON-DEGENERACY FIRST, AND IT IS NOT A FORMALITY HERE. `m27_arm` prints `MISSING` for a path that
# is not there and `None` for a JSON null — which is what the host records when statistics were not
# collected — and every assertion in this file compares that value with another reading of the same
# number. Measured on this check's own first run: with the arm path wrong, `THE IDENTITY` and two
# of its neighbours reported `ok [MISSING]`, and CONTROL 2 below passed because `test 516 -eq
# MISSING` is a bash ERROR rather than a false comparison. Six assertions were failing and three
# more were vacuously green in the same run.
ABSENT="$(m29_absent "instructionsExecuted=$STAT" "count=$COUNT" "decoded=$DECODED")"
assert_eq "the AVM's statistic and the module's step count are both present" "" "$ABSENT"
[ -z "$ABSENT" ] || die "the arm report is missing $ABSENT; every comparison below would be between
             two absences, and CONTROL 2 would pass on a bash error. A failure, not a smaller check."
assert_ge "…and it is a real transaction's worth of instructions" 100 "$STAT"
assert_eq "THE IDENTITY: the drained step count equals the AVM's own statistic" "$STAT" "$COUNT"
assert_eq "…and every record the module counted was decoded by the host" "$COUNT" "$DECODED"

echo "== 2. …and nothing was lost between the drain and the writer"

EVENTS="$(m27_arm download recording.events)"
REC_EXECUTED="$(m27_arm download recording.executedSteps)"
REC_STAT="$(m27_arm download recording.instructionsExecuted)"
POSITIONED="$(m27_arm download recording.stepsPositioned)"
UNPOSITIONED="$(m27_arm download recording.stepsUnpositioned)"
note "the writer accepted $EVENTS event(s); $POSITIONED positioned / $UNPOSITIONED unpositioned"

assert_eq "the writer's own event count equals the executed step count" "$REC_EXECUTED" "$EVENTS"
assert_eq "…which is the AVM's statistic, carried into the recording" "$STAT" "$REC_STAT"
assert_eq "…and the same number the transfer arm measured" "$COUNT" "$REC_EXECUTED"
# The positioned/unpositioned split must account for every event. This is where a producer that
# dropped the steps it could not position would show up, and dropping them is the tempting mistake
# — it would make the rung declaration come out at 1.
assert_eq "…and positioned plus unpositioned accounts for every event" \
  "$EVENTS" "$((POSITIONED + UNPOSITIONED))"
assert_ge "…with a non-zero positioned count, so the split is not degenerate" 1 "$POSITIONED"

echo "== 3. …and the container really carries them, per the PINNED READER"

DL_PATH="$(m27_arm download downloaded.0.path)"
assert_file "the downloaded container is on disk" "$DL_PATH"
READ="$(m24_ct_print "$M24_READERS/ct-print" "$DL_PATH")"
RC="$(printf '%s\n' "$READ" | head -1)"
OUT="$(printf '%s\n' "$READ" | tail -n +2)"
STEP_RECORDS="$(printf '%s\n' "$OUT" | grep -c '"type": "Step"' || true)"
note "ct-print --full exited $RC and emitted $STEP_RECORDS Step record(s)"

assert_eq "ct-print --full reads the container" "0" "$RC"
assert_eq "…emitting one Step record per executed instruction" "$STAT" "$STEP_RECORDS"
# THE PRODUCER IS NAMED IN THE CONTAINER, so a reader can tell where the stream came from without
# being told. M29's fourth deliverable, and the other half of `ct_writer_kind()`.
assert_true "…and the container names its step producer" str_has_sub "$OUT" 'ct.step-producer'
assert_true "…as the AVM's own observation hook" str_has_sub "$OUT" 'avm-execution-observer'
PRODUCER_LINE="$(printf '%s\n' "$OUT" | grep -o 'avm-execution-observer steps=[^"]*' | head -1)"
note "the container's producer record: $PRODUCER_LINE"
assert_true "…with the executed-instruction statistic beside the record count" \
  str_has_sub "$PRODUCER_LINE" "steps=$STAT instructionsExecuted=$STAT"
assert_eq "…written by Path A, per ct_writer_kind()" "1" "$(m27_arm download recording.writerKind)"

echo "== 4. THE CONTROLS: the identity is capable of failing"

# CONTROL 1 — the number M27 would have produced. `DEMO_STEPS` was 64 and had nothing to do with an
# instruction count; if this check were comparing two constants, 64 would satisfy it too.
assert_false "M27's 64 synthesised steps are NOT the executed instruction count" test "$STAT" -eq 64

# CONTROL 2 — the reader's Step count must be a property of the CONTAINER and not of the reader.
#
# HALVING THE FILE IS NOT THE CONTROL, AND THAT WAS MEASURED RATHER THAN ASSUMED — twice, once by
# M27 and once here. A `.ct` is a directory of independent streams, so `ct-print --full` over a copy
# whose second half is missing still exits 0 AND STILL EMITS ALL 516 STEP RECORDS: the steps stream
# was in the half that survived. The halved copy is kept and its numbers are REPORTED, because a
# reader who assumes truncation is refused should see them, and because this is the arm that would
# have made this control vacuous if it had been the only one.
CTL_DIR="$M29_WORK/count-controls"
rm -rf "$CTL_DIR"; mkdir -p "$CTL_DIR"
DL_BYTES="$(stat -c %s "$DL_PATH")"
HALVED="$CTL_DIR/halved.ct"
head -c "$((DL_BYTES / 2))" "$DL_PATH" >"$HALVED"
assert_eq "the halved copy is half the container" "$((DL_BYTES / 2))" "$(stat -c %s "$HALVED")"
HALVED_READ="$(m24_ct_print "$M24_READERS/ct-print" "$HALVED")"
HALVED_STEPS="$(printf '%s\n' "$HALVED_READ" | tail -n +2 | grep -c '"type": "Step"' || true)"
note "the reader emits $HALVED_STEPS Step record(s) over a HALVED container (exit $(printf '%s\n' "$HALVED_READ" | head -1)) — not a control, a recorded fact about the format"

# THE CONTROL THAT DISCRIMINATES: a 512-byte stub is not a container, the reader refuses it, and the
# count it does not produce is the count asserted above.
STUB="$CTL_DIR/stub.ct"
head -c 512 "$DL_PATH" >"$STUB"
STUB_READ="$(m24_ct_print "$M24_READERS/ct-print" "$STUB")"
STUB_RC="$(printf '%s\n' "$STUB_READ" | head -1)"
STUB_STEPS="$(printf '%s\n' "$STUB_READ" | tail -n +2 | grep -c '"type": "Step"' || true)"
note "the reader exits $STUB_RC with $STUB_STEPS Step record(s) over a 512-byte stub"
assert_false "the reader REFUSES a 512-byte stub" test "$STUB_RC" -eq 0
assert_false "…and does not emit the executed count over it" test "$STUB_STEPS" -eq "$STAT"
assert_eq "…emitting none at all, so the 516 above came out of the container" "0" "$STUB_STEPS"

# CONTROL 3 — a DIFFERENT transaction has a different count, so the statistic is a property of the
# transaction rather than a constant the module always answers. The parity arm ran a different
# program through the same module in the same browser session.
PARITY_STAT="$(m27_arm nativeParity instructionsExecuted)"
note "the parity arm's own program reports $PARITY_STAT executed instruction(s)"
assert_true "another program's statistic is present" test "$PARITY_STAT" != "MISSING"
assert_false "…and it differs, so the statistic is not a constant" test "$PARITY_STAT" -eq "$STAT"

m29_finish
