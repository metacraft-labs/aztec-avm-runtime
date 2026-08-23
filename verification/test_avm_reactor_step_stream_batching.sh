#!/usr/bin/env bash
# M12: step records cross the host boundary in batches, and a program with 38,903 steps produces a
# bounded number of boundary crossings.
#
# THE CROSSING COUNT IS AN IDENTITY, NOT A BOUND. `burn` executes M9's measured 38,903 instructions
# before it runs out of gas; drained at a batch size of B the stream costs exactly ceil(38903 / B)
# crossings, and that is asserted for four batch sizes rather than "fewer than 38,903". Four,
# because a single one would go green for an export that ignored the window and returned everything.
#
# AND THERE IS A ZERO-CROSSING PATH, which is the strongest form of the deliverable's own target.
# The whole stream is already inside the single `avm_simulate` result, under upstream's own
# `executionSteps` field on `TxSimulationResult`, so a host that wants all of it has all of it after
# ONE call. `avm_steps_batch` exists for the host that does not want to decode the whole result, or
# that wants to stream records into a trace writer as it goes (M24 and M25). Both are measured.
#
# PER-EVENT CROSSINGS ARE REJECTED ON MEASUREMENT, NOT ON ASSUMPTION. The rejected shape is driven
# through the SAME export — `avm_steps_batch(i, 1)` is one crossing per record — so the comparison
# is between two call patterns rather than between two APIs, and the encode and decode work is
# identical on both sides. What is left in the difference is the crossing itself.
#
# A TIMING MEASUREMENT ASSERTS ITS OWN PRECONDITIONS. `m9_require_idle_machine` runs first and exits
# 3 — a code of its own, distinct from 1 for a failed assertion — if the machine is still busy after
# its wait window. M11's re-run of M9 produced a timing "failure" that was a competing build; this
# refuses to report a number instead.

set -uo pipefail

TEST_NAME=test_avm_reactor_step_stream_batching
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m12_reactor.sh"

require_nix
m12_measured
note "tree: $M12_TREE"

m8_require_artifacts "$(m12_native_steps)"

# --- the crossing counts, at four batch sizes -------------------------------
# These are cheap and do not depend on the machine being idle, so they run before the timing
# precondition: a busy machine must not be able to stop the identity from being checked.
declare -A CROSSINGS
for batch in 1 512 4096 65536; do
  out="$M12_WORK/reactor.steps.$batch"
  err="$M12_WORK/reactor.steps.$batch.err"
  extra=""
  [ "$batch" = "$M12_STEP_BATCH" ] && extra="--all"
  m12_run_reactor steps "$out" "$err" "$M12_STEP_PROGRAM" "$batch" $extra
  rc=$?
  assert_eq "the step drain at batch $batch exits 0" 0 "$rc"
  if [ "$rc" -ne 0 ]; then
    note "stderr: $err"
    grep -v '^\[' "$err" | tail -10
    continue
  fi
  assert_eq "batch $batch: it finished" "1" "$(m12_field "$out" steps.done)"
  assert_eq "batch $batch: the module reports M9's $M12_STEP_COUNT step records" \
    "$M12_STEP_COUNT" "$(m12_field "$out" steps.count)"
  assert_eq "batch $batch: and the same number arrived inside the simulate result itself" \
    "$M12_STEP_COUNT" "$(m12_field "$out" steps.inResultCount)"
  assert_eq "batch $batch: which cost ZERO further crossings" 0 \
    "$(m12_field "$out" steps.crossingsForWholeStreamInResult)"
  expected=$(( (M12_STEP_COUNT + batch - 1) / batch ))
  assert_eq "batch $batch: exactly ceil($M12_STEP_COUNT / $batch) = $expected crossings" \
    "$expected" "$(m12_field "$out" steps.batched.crossings)"
  assert_eq "batch $batch: and every record was decoded" "$M12_STEP_COUNT" \
    "$(m12_field "$out" steps.batched.decoded)"
  assert_eq "batch $batch: reading past the end returns an empty batch, not a trap or a wrap" 0 \
    "$(m12_field "$out" steps.pastEnd.length)"
  # The far end of the range, which the review added because `from + count` is size_t on a 32-bit
  # target and `count` is a uint32 the HOST chooses: a count near 2^32 - from wrapped, and a wrapped
  # end below begin would have built a vector from a reversed range. Both arms must be a sane window.
  assert_eq "batch $batch: count=2^32-1 from the last record returns exactly the last record" 1 \
    "$(m12_field "$out" steps.hugeCountFromLast.length)"
  assert_eq "batch $batch: and count=2^32-1 from the start returns the whole stream, not a wrap" \
    "$M12_STEP_COUNT" "$(m12_field "$out" steps.hugeCountFromStart.length)"
  assert_eq "batch $batch: the host owns nothing at exit" 0 \
    "$(m12_field "$out" steps.ownedAllocationsAtExit)"
  CROSSINGS[$batch]="$(m12_field "$out" steps.batched.crossings)"
done

# The bound the deliverable asks for, stated as the number it is.
assert_eq "at the shipped batch size of $M12_STEP_BATCH the whole 38,903-step stream is $(( (M12_STEP_COUNT + M12_STEP_BATCH - 1) / M12_STEP_BATCH )) crossings" \
  "$(( (M12_STEP_COUNT + M12_STEP_BATCH - 1) / M12_STEP_BATCH ))" "${CROSSINGS[$M12_STEP_BATCH]:-}"
# And batch size 1 IS the per-event shape, which is why its crossing count is the record count.
assert_eq "at batch size 1 the crossing count is the record count — that is the rejected shape" \
  "$M12_STEP_COUNT" "${CROSSINGS[1]:-}"

# --- the records themselves, PER RECORD against the driver -------------------
# A count agreeing is not the records agreeing. The driver's own `steps` mode printed all 38,903 of
# `burn`'s records natively; the reactor's host printed the same 38,903 through the msgpack ABI on
# V8. They are compared one by one.
STEPS_OUT="$M12_WORK/reactor.steps.$M12_STEP_BATCH"
if [ -f "$STEPS_OUT" ]; then
  assert_eq "the reactor printed all $M12_STEP_COUNT records" "$M12_STEP_COUNT" \
    "$(grep -c '^steps\.record\.[0-9]* ctx=' "$STEPS_OUT")"
  cmp_out="$M12_WORK/steps-record-compare.txt"
  python3 - "$(m12_native_steps)" "$STEPS_OUT" "$M12_STEP_PROGRAM" >"$cmp_out" <<'PY'
import sys
native, reactor, program = sys.argv[1], sys.argv[2], sys.argv[3]
def load(path, prefix):
    d = {}
    plen = len(prefix)
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line.startswith(prefix):
            continue
        key, _, value = line.partition(" ")
        idx = key[plen:]
        if idx.isdigit():
            d[int(idx)] = value
    return d
n = load(native, f"steps.{program}.")
r = load(reactor, "steps.record.")
print(f"nativeRecords {len(n)}")
print(f"reactorRecords {len(r)}")
mismatch = 0
for i in sorted(r):
    if i not in n:
        print(f"MISSING {i} {r[i]}")
        mismatch += 1
    elif n[i] != r[i]:
        print(f"DIFFER {i} native[{n[i]}] reactor[{r[i]}]")
        mismatch += 1
print(f"mismatches {mismatch}")
PY
  assert_eq "the native driver printed the same $M12_STEP_COUNT records" "$M12_STEP_COUNT" \
    "$(m12_field "$cmp_out" nativeRecords)"
  assert_eq "and the reactor's" "$M12_STEP_COUNT" "$(m12_field "$cmp_out" reactorRecords)"
  assert_eq "every record agrees, field for field, across the boundary" 0 \
    "$(m12_field "$cmp_out" mismatches)"
  if [ "$(m12_field "$cmp_out" mismatches)" != "0" ]; then
    grep -E '^(DIFFER|MISSING)' "$cmp_out" | head -5
  fi

  # THE COMPARATOR'S OWN DISCRIMINATING POWER. A per-record comparison that reports zero on a
  # corrupted input is not a comparison. One record is altered and the same comparator must find it.
  corrupt="$M12_WORK/reactor.steps.corrupt"
  sed 's/^steps\.record\.17 ctx=1 /steps.record.17 ctx=9 /' "$STEPS_OUT" >"$corrupt"
  assert_true "the control input really differs from the transcript" \
    test "$(sha256sum <"$corrupt" | awk '{print $1}')" != "$(sha256sum <"$STEPS_OUT" | awk '{print $1}')"
  python3 - "$(m12_native_steps)" "$corrupt" "$M12_STEP_PROGRAM" >"$M12_WORK/steps-record-control.txt" <<'PY'
import sys
native, reactor, program = sys.argv[1], sys.argv[2], sys.argv[3]
def load(path, prefix):
    d = {}
    plen = len(prefix)
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line.startswith(prefix):
            continue
        key, _, value = line.partition(" ")
        idx = key[plen:]
        if idx.isdigit():
            d[int(idx)] = value
    return d
n = load(native, f"steps.{program}.")
r = load(reactor, "steps.record.")
print("mismatches " + str(sum(1 for i in r if i not in n or n[i] != r[i])))
PY
  assert_eq "and the same comparator reports exactly one mismatch on a single altered record" 1 \
    "$(m12_field "$M12_WORK/steps-record-control.txt" mismatches)"
else
  fail "the $M12_STEP_BATCH-batch run produced no transcript, so the per-record comparison could not run"
fi

# --- the timing, with its own precondition ----------------------------------
# Exit 3 if the machine is busy. A number measured beside somebody else's build is not a number
# about this code, and reporting one anyway is what M9's review found and fixed.
m9_require_idle_machine

TIMED="$M12_WORK/reactor.steps.timed"
m12_run_reactor steps "$TIMED" "$M12_WORK/reactor.steps.timed.err" "$M12_STEP_PROGRAM" "$M12_STEP_BATCH"
timed_rc=$?
assert_eq "the timed drain exits 0" 0 "$timed_rc"

batched_us="$(m12_field "$TIMED" steps.batched.us)"
per_event_us="$(m12_field "$TIMED" steps.perEvent.us)"
assert_ge "the batched arm produced a timing" 1 "$batched_us"
assert_ge "and the per-event arm too" 1 "$per_event_us"
# Three repetitions of each arm were taken; the minimum of each is what is compared. Each
# repetition is printed so a reader can see the spread rather than take the point estimate on faith.
for i in 0 1 2; do
  note "batched rep $i: $(m12_field "$TIMED" "steps.batched.us.$i") us; per-event rep $i: $(m12_field "$TIMED" "steps.perEvent.us.$i") us"
done
assert_true "per-event crossings are SLOWER than batched ones ($per_event_us us against $batched_us)" \
  test "$per_event_us" -gt "$batched_us"
ratio_x100=$(( per_event_us * 100 / batched_us ))
extra_crossings=$(( M12_STEP_COUNT - CROSSINGS[$M12_STEP_BATCH] ))
per_crossing_ns=$(( (per_event_us - batched_us) * 1000 / extra_crossings ))
note "per-event is ${ratio_x100}/100 times the batched cost over $extra_crossings extra crossings"
note "which puts the marginal cost of one boundary crossing at about ${per_crossing_ns} ns"
# The honest bound: the ratio is not larger because BOTH arms encode and decode all 38,903 records,
# and that work dominates. What the difference isolates is the crossing, and it is asserted to be a
# real, positive, per-crossing cost rather than noise.
assert_ge "the marginal per-crossing cost is a real number of nanoseconds, not zero" 1 "$per_crossing_ns"

finish
