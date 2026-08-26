#!/usr/bin/env bash
# test_timestamps_strictly_monotonic_subsecond — DD-4's timestamp rule, under both hostile cases.
#
# The verification entry: "With a sub-second interval and with simulated timer throttling, block
# timestamps strictly increase and never repeat or regress."
#
# THE TWO CASES ARE THE SAME EXPERIMENT AND THAT IS THE POINT. A sub-second interval means the wall
# clock's SECOND does not change between blocks; a throttled browser tab means it jumps and then
# stalls. Both are "the wall clock did not move but a block was produced", which is exactly where
# `floor(now/1000)` repeats. Both are produced by CONTROLLING the clock rather than by waiting,
# because "the tab was throttled" is otherwise not reproducible — which is DD-4's third reason for
# injecting the clock in the first place.
#
# THE RULE IS `max(prev + minBlockSpacingSeconds, floor(now/1000))`, and with a spacing of 1 it is
# strictly increasing BY CONSTRUCTION. So this check does two different things: it measures the
# fifteen produced timestamps, and it exercises the rule DIRECTLY with the wall clock held still,
# because a measurement over one arm cannot distinguish "the rule is right" from "this run happened
# not to repeat".
#
# AND THE DEVIATION FROM THE WALL CLOCK IS ASSERTED TO BE DECLARED. The milestone requires it to be
# "declared rather than hidden", so every block carries `wallClockSeconds` and
# `wallClockDeviationSeconds` and the identity `timestamp - wallClockSeconds == deviation` is
# checked per block. A deviation field that did not equal the difference would be a declaration
# that lied, which is worse than none.
#
# THE NEGATIVE CONTROL IS `minBlockSpacingSeconds: 0`. The rule is not corrected for a caller who
# asks for zero — that is stated in `chain_clock.ts` — and the check exercises it, so "strictly
# increasing" is shown to be a property of the SPACING and not of the arithmetic being incapable of
# repeating.
#
# Run: just verify-chain-timestamps

TEST_NAME="test_timestamps_strictly_monotonic_subsecond"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit
m23_require_anchor
m23_require_arms

# ---------------------------------------------------------------------------
# PART 1 — the fifteen produced blocks
# ---------------------------------------------------------------------------
echo "== fifteen blocks over a sub-second interval and a throttle"

assert_eq "the arm produced fifteen blocks" "15" "$(m23_arm subSecondTimestamps count)"
assert_eq "their timestamps strictly increase" "true" \
  "$(m23_arm subSecondTimestamps strictlyIncreasing)"
assert_eq "…and none repeats" "false" "$(m23_arm subSecondTimestamps repeats)"

# The two halves are asserted SEPARATELY, because the arm's own booleans are computed by the driver
# and a check that only read them would be trusting the driver's arithmetic. The timestamps are
# re-derived here from the rows.
ROWS="$(python3 - "$M23_ARMS" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))["arms"]["subSecondTimestamps"]["rows"]
for r in rows:
    print("%s %s %s %s" % (r["advancedMs"], r["timestamp"], r["wall"], r["dev"]))
PY
)"
N_ROWS="$(printf '%s\n' "$ROWS" | grep -c .)"
assert_eq "fifteen rows were read back out of the run" "15" "$N_ROWS"

TS="$(printf '%s\n' "$ROWS" | awk '{print $2}')"
N_DISTINCT="$(printf '%s\n' "$TS" | sort -u | grep -c .)"
assert_eq "the fifteen timestamps are fifteen DISTINCT values" "15" "$N_DISTINCT"
SORTED="$(printf '%s\n' "$TS" | sort -n)"
assert_eq "…and they are already in increasing order" "$SORTED" "$TS"

echo "== the wall clock did NOT move for most of them, which is what makes this a test"
WALL="$(printf '%s\n' "$ROWS" | awk '{print $3}')"
N_WALL="$(printf '%s\n' "$WALL" | sort -u | grep -c .)"
# Ten blocks at 100 ms cross at most two second-boundaries, then a 30 s jump, then five with a
# stalled clock. So the wall-clock seconds take FAR fewer distinct values than the timestamps.
assert_true "the wall clock took fewer distinct values than the block timestamps" \
  test "$N_WALL" -lt "$N_DISTINCT"
assert_ge "…but it did move at least twice, so the arm is not a frozen clock" 2 "$N_WALL"

echo "== the deviation from the wall clock is DECLARED and equals the difference"
python3 - "$M23_ARMS" > "$M23_WORK/deviation.txt" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
bad = 0
seen = 0
for b in doc["arms"]["emptyBlocks"]["blocks"]:
    seen += 1
    if int(b["timestamp"]) - int(b["wallClockSeconds"]) != int(b["wallClockDeviationSeconds"]):
        bad += 1
print("seen %d bad %d" % (seen, bad))
PY
DEV="$(cat "$M23_WORK/deviation.txt")"
assert_eq "every empty block's declared deviation equals timestamp minus wall clock" \
  "seen 3 bad 0" "$DEV"

# AND THAT ASSERTION ALONE IS SATISFIED BY A FIELD THAT IS ALWAYS ZERO, which is how M23's review
# found it: on `emptyBlocks` the clock is advanced one second per block, so `timestamp`,
# `wallClockSeconds` and the deviation are 1/1/0, 2/2/0, 3/3/0 — both sides of the comparison are
# zero for every block, and replacing `timestamp - wallClockSeconds` with a constant `0n` passed
# the WHOLE milestone green: 491 assertions, zero failures, fourteen of fourteen. The vacuous
# comparison this campaign catalogues, by DATA rather than by key.
#
# The arm where the deviation is real is THIS one — a sub-second interval and a throttle are
# exactly the cases where the block timestamp leaves the wall clock behind — so the identity is
# asserted over its fifteen rows, WITH the non-emptiness partner the rule asks for: at least one
# row must have a NON-ZERO deviation, or the fifteen comparisons are fifteen zeros again.
SUB_DEV_BAD="$(printf '%s\n' "$ROWS" | awk '{ if ($2 - $3 != $4) n++ } END { print n + 0 }')"
SUB_DEV_NONZERO="$(printf '%s\n' "$ROWS" | awk '$4 != 0 { n++ } END { print n + 0 }')"
assert_eq "every sub-second block's declared deviation equals timestamp minus wall clock" \
  "0" "$SUB_DEV_BAD"
assert_ge "…and the deviation is NOT identically zero here, so that comparison has a subject" \
  10 "$SUB_DEV_NONZERO"

# ---------------------------------------------------------------------------
# PART 2 — the rule itself, exercised with the wall clock held completely still
# ---------------------------------------------------------------------------
echo "== the rule, exercised directly on a frozen clock"

RULE="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { ManualDateProvider, nextBlockTimestamp } from "./src/chain_clock.ts";
// A clock that NEVER moves. `floor(now/1000)` is the same number every time, so anything that
// increases here does so because of the spacing and for no other reason.
const frozen = new ManualDateProvider(1_700_000_000_000);
let t = 0n;
const spaced = [];
for (let i = 0; i < 5; i++) { t = nextBlockTimestamp(t, frozen, 1); spaced.push(t.toString()); }
// And the same with a spacing of ZERO, which the rule deliberately does not correct.
let z = 0n;
const zeroed = [];
for (let i = 0; i < 5; i++) { z = nextBlockTimestamp(z, frozen, 0); zeroed.push(z.toString()); }
// A clock that RUNS AHEAD of the spacing: the wall clock must win.
const ahead = new ManualDateProvider(2_000_000_000_000);
const won = nextBlockTimestamp(5n, ahead, 1).toString();
console.log(spaced.join(","));
console.log(zeroed.join(","));
console.log(won);
console.log(new Set(spaced).size, new Set(zeroed).size);
' 2>&1 | tail -4)"

SPACED="$(printf '%s\n' "$RULE" | sed -n 1p)"
ZEROED="$(printf '%s\n' "$RULE" | sed -n 2p)"
WON="$(printf '%s\n' "$RULE" | sed -n 3p)"
SIZES="$(printf '%s\n' "$RULE" | sed -n 4p)"

assert_true "the rule was exercised and produced values" test -n "$SPACED"
assert_eq "on a frozen clock with spacing 1 the timestamps are 1..5" \
  "1700000000,1700000001,1700000002,1700000003,1700000004" "$SPACED"
# THE NEGATIVE CONTROL: with spacing 0 the same frozen clock REPEATS. Without this, "strictly
# increasing" could be a property of the arithmetic rather than of the configured spacing.
assert_eq "…and with spacing 0 the SAME frozen clock repeats every time" \
  "1700000000,1700000000,1700000000,1700000000,1700000000" "$ZEROED"
assert_eq "five distinct with spacing 1, ONE distinct with spacing 0" "5 1" "$SIZES"
# THE OTHER DIRECTION: a wall clock ahead of the floor wins, so the rule is a `max` and not a
# counter that ignores the clock.
assert_eq "a wall clock ahead of prev+spacing wins" "2000000000" "$WON"

# ---------------------------------------------------------------------------
# PART 3 — the vocabulary is upstream's, not a parallel one
# ---------------------------------------------------------------------------
echo "== nowInSeconds IS floor(nowMs/1000), read out of the installed package"

DP="$(cat "$ORCH_DIR/node_modules/@aztec/foundation/dest/timer/date.js")"
assert_true "DateProvider.now() returns Date.now()" str_has_sub "$DP" "return Date.now();"
assert_true "…and nowInSeconds() is Math.floor(this.now() / 1000)" \
  str_has_sub "$DP" "return Math.floor(this.now() / 1000);"
assert_true "ManualDateProvider is in the installed package" str_has_sub "$DP" "class ManualDateProvider"
assert_false "a class the package does not have is not found by the same lookup" \
  str_has_sub "$DP" "class FrozenDateProvider"

m23_finish
