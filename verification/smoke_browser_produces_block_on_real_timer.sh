#!/usr/bin/env bash
# smoke_browser_produces_block_on_real_timer
#
# M27 verification: "a headless browser produces blocks on a real timer with strictly increasing
# timestamps, INCLUDING WHILE THE TAB IS THROTTLED".
#
# ===========================================================================================
# THE THROTTLING CLAUSE IS THE CHECK, AND IT IS TESTED RATHER THAN ASSERTED.
# ===========================================================================================
#
# The monotonicity rule is six lines:
#
#     nextBlockTimestamp = max(prev + minBlockSpacingSeconds, floor(clock.nowMs() / 1000))
#
# and asserting that formula against a chain that ran at a steady 250 ms is asserting almost
# nothing: the FIRST branch holds throughout, the second is never taken, and a runtime that
# ignored the wall clock entirely would pass. What makes the rule load-bearing is a tab whose
# timers STOP and then resume, because that is when the second branch takes over from the first —
# and DD-4's injected clock exists precisely so that a runtime does not have to assume even ticks.
#
# So the arm FREEZES the page. `Page.setWebLifecycleState('frozen')` is what Chromium does to a
# backgrounded tab it decides to stop paying for: timers stop entirely. `Emulation.setCPUThrottlingRate`
# runs alongside it, because a frozen tab and a merely slow tab are different failures.
#
# THE FREEZE MUST BE VISIBLE IN THE DATA OR THE ARM PROVED NOTHING. A run in which the freeze did
# not take effect produces a perfectly even chain, and every monotonicity assertion below would pass
# over it — which is `CAMPAIGN-BRIEF.md`'s "both sides read, both sides zero" in its timing form. So
# the check requires a WALL-CLOCK GAP across the freeze: some consecutive pair of blocks must be at
# least two seconds apart on the host clock, which no 250 ms interval produces.
#
# AND THE DECLARED DEVIATION IS ASSERTED WHERE IT IS NON-ZERO, which is M23's review's correction to
# its own check: a deviation field that is only ever compared while every term is zero is a field
# that could be the constant `0n`.
#
# Run: just verify-browser-real-timer

TEST_NAME="smoke_browser_produces_block_on_real_timer"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"

m27_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m27_require_arms

echo "== 1. the arm ran a REAL timer in a REAL browser, and froze it"

INTERVAL="$(m27_arm timer intervalMs)"
FROZEN="$(m27_arm timer frozenForMs)"
RATE="$(m27_arm timer cpuThrottlingRate)"
note "interval ${INTERVAL} ms, frozen for ${FROZEN} ms, CPU throttling rate ${RATE}"
assert_eq "the ticker interval is 250 ms — a real timer, not a fake clock" "250" "$INTERVAL"
assert_ge "…and the page was frozen for at least two seconds" 2000 "$FROZEN"
assert_ge "…with the CPU throttled as well" 10 "$RATE"
assert_eq "no page error while it ran" "[]" "$(m27_arm timer pageErrors)"
assert_eq "…and no console error" "[]" "$(m27_arm timer consoleErrors)"

echo "== 2. the blocks, read out of the run"

ROWS="$(python3 - "$M27_ARMS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
blocks = d["arms"]["timer"]["blocks"]
print("COUNT %d" % len(blocks))
prev_ts = None
prev_wall = None
strictly = True
maxgap = 0
nonzero_dev = 0
identity_ok = True
for b in blocks:
    ts = int(b["timestamp"]); wall = int(b["wallClockSeconds"]); dev = int(b["wallClockDeviationSeconds"])
    if prev_ts is not None and ts <= prev_ts:
        strictly = False
        print("NONMONOTONIC %d -> %d" % (prev_ts, ts))
    if prev_wall is not None:
        maxgap = max(maxgap, wall - prev_wall)
    if dev != 0:
        nonzero_dev += 1
    # The DECLARED deviation must equal the MEASURED one, per block.
    if ts - wall != dev:
        identity_ok = False
        print("BADDEV block %s: %d - %d != %d" % (b["number"], ts, wall, dev))
    prev_ts, prev_wall = ts, wall
print("STRICTLY %s" % ("yes" if strictly else "no"))
print("MAXWALLGAP %d" % maxgap)
print("NONZERODEV %d" % nonzero_dev)
print("IDENTITY %s" % ("yes" if identity_ok else "no"))
print("FIRSTTS %d" % int(blocks[0]["timestamp"]))
print("LASTTS %d" % int(blocks[-1]["timestamp"]))
print("NUMBERS %s" % ",".join(str(b["number"]) for b in blocks))
print("EMPTY %d" % sum(1 for b in blocks if b["empty"]))
PY
)"
COUNT="$(printf '%s\n' "$ROWS" | sed -n 's/^COUNT //p')"
note "$COUNT block(s): $(printf '%s\n' "$ROWS" | sed -n 's/^NUMBERS //p')"
assert_ge "the timer produced several blocks" 5 "$COUNT"
assert_eq "…numbered 1..N with no gap and no repeat" \
  "$(seq -s, 1 "$COUNT")" "$(printf '%s\n' "$ROWS" | sed -n 's/^NUMBERS //p')"
assert_eq "…and all of them empty, which is what produceEmptyBlocks means" \
  "$COUNT" "$(printf '%s\n' "$ROWS" | sed -n 's/^EMPTY //p')"

echo "== 3. THE ASSERTION: strictly increasing, across the freeze"

assert_eq "every timestamp is strictly greater than the one before it" "yes" \
  "$(printf '%s\n' "$ROWS" | sed -n 's/^STRICTLY //p')"
FIRST="$(printf '%s\n' "$ROWS" | sed -n 's/^FIRSTTS //p')"
LAST="$(printf '%s\n' "$ROWS" | sed -n 's/^LASTTS //p')"
assert_eq "…so the chain advanced exactly one second per block" \
  "$((COUNT - 1))" "$((LAST - FIRST))"
# THE TIMESTAMPS ARE WALL-CLOCK, not a counter from zero. A runtime that ignored the clock would
# produce 1, 2, 3… and satisfy everything above.
assert_ge "…and they are real epoch seconds rather than a counter" 1700000000 "$FIRST"

echo "== 4. THE FREEZE IS VISIBLE IN THE DATA — otherwise section 3 proved nothing"

MAXGAP="$(printf '%s\n' "$ROWS" | sed -n 's/^MAXWALLGAP //p')"
note "the largest wall-clock gap between consecutive blocks is ${MAXGAP}s"
# At a 250 ms interval consecutive blocks are 0 or 1 wall-clock seconds apart. A gap of two or more
# can only come from the timer having STOPPED, which is what the freeze does.
assert_ge "the host clock jumped by at least two seconds across the freeze" 2 "$MAXGAP"

echo "== 5. the DECLARED deviation is real, and is asserted where it is NON-ZERO"

assert_eq "every block's declared deviation equals timestamp - wallClockSeconds" "yes" \
  "$(printf '%s\n' "$ROWS" | sed -n 's/^IDENTITY //p')"
# M23's review's correction, kept: the identity above is `0 == 0` on a chain that never deviates,
# so at least one row must be non-degenerate for it to mean anything.
assert_ge "…and at least three blocks have a NON-ZERO deviation" 3 \
  "$(printf '%s\n' "$ROWS" | sed -n 's/^NONZERODEV //p')"

m27_finish
