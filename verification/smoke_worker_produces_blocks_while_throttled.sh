#!/usr/bin/env bash
# smoke_worker_produces_blocks_while_throttled
#
# M32 verification: "strictly increasing timestamps under real throttling IN A WORKER, per DD-4's
# max(prevTimestamp + minBlockSpacingSeconds, floor(clock.nowMs() / 1000))".
#
# ===========================================================================================
# THIS RESULT COULD NOT BE INHERITED, AND SAYING WHY IS HALF THE CHECK
# ===========================================================================================
#
# M27's `smoke_browser_produces_block_on_real_timer` established exactly this property — on the MAIN
# THREAD. A worker's timers are scheduled by a different part of the renderer and throttle on a
# different schedule, so carrying M27's green across would be carrying a measurement of a different
# thing. It is re-taken here, in a worker, and the two mechanisms that might reach one are attempted
# and their answers RECORDED:
#
#   Emulation.setCPUThrottlingRate on the WORKER's own CDP target   -> refused by Chromium
#   Emulation.setCPUThrottlingRate on the page's target             -> accepted
#   Page.setWebLifecycleState('frozen')                             -> accepted
#
# The first is a genuine finding and it is asserted, because "we throttled the worker" would
# otherwise be a sentence nobody had checked. What actually reaches a dedicated worker is the
# document freeze.
#
# ===========================================================================================
# AND WHETHER IT REACHED THE WORKER IS MEASURED BY THE WORKER
# ===========================================================================================
#
# `CAMPAIGN-BRIEF.md`'s "both sides read, both sides zero" in its timing form: a run in which the
# freeze did NOT take effect produces a perfectly even chain, over which every monotonicity assertion
# passes. M27 closed that by requiring a wall-clock gap. This check requires that AND a gap in the
# WORKER's own monotonic clock — `producedAtMs`, stamped inside the worker when a block is sealed —
# because the wall clock is the host's and is the same clock either thread reads, while
# `producedAtMs` can only move if the worker's own timers stopped.
#
# Run: just verify-m32-throttled

TEST_NAME="smoke_worker_produces_blocks_while_throttled"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m32_worker.sh"

m32_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m32_require_arms

echo "== 0. the arm report carries what this check reads"

INTERVAL="$(m32_arm throttled intervalMs)"
FROZEN="$(m32_arm throttled frozenForMs)"
RATE="$(m32_arm throttled cpuThrottlingRate)"
APPLIED="$(m32_arm throttled throttle.applied)"
TARGETS="$(m32_arm throttled workerTargetCount)"
m32_absent \
  "throttled.intervalMs=$INTERVAL" "throttled.frozenForMs=$FROZEN" \
  "throttled.cpuThrottlingRate=$RATE" "throttled.throttle.applied=$APPLIED" \
  "throttled.workerTargetCount=$TARGETS"

echo "== 1. the chain ran a REAL timer, IN A WORKER"

note "interval ${INTERVAL} ms, frozen for ${FROZEN} ms, CPU throttling rate ${RATE}"
assert_eq "the ticker interval is the run's declared one — a real timer, not a fake clock" \
  "$(m32_run parameters.tickMs)" "$INTERVAL"
assert_ge "…and the page was frozen for at least two seconds" 2000 "$FROZEN"
assert_ge "…with the CPU throttled as well" 10 "$RATE"
assert_eq "the chain was hosted by exactly one worker target" "1" "$TARGETS"
assert_true "…and it is this repository's worker bundle" \
  str_has_sub "$(m32_arm throttled workerTargets)" '/worker.js'
assert_eq "no page error while it ran" "[]" "$(m32_arm throttled pageErrors)"
assert_eq "…and no console error" "[]" "$(m32_arm throttled consoleErrors)"
# THE MODULE IS ON THE OTHER THREAD, which is what makes this a worker measurement rather than
# M27's. The page did not fetch avm.wasm; the worker did.
assert_eq "the page did not fetch the module" "[]" "$(m32_arm throttled avmWasmRequests)"
assert_true "…the worker did" str_has_sub "$(m32_arm throttled workerAvmWasmRequests)" '/assets/avm.wasm'

echo "== 2. WHICH THROTTLING MECHANISMS REACH A WORKER — recorded, not assumed"

note "$APPLIED"
# THE FINDING: CPU throttling cannot be aimed at a dedicated worker over CDP at all. Asserted, so
# that the day Chromium changes it, this check says so rather than quietly using a mechanism nobody
# re-checked.
assert_true "Emulation.setCPUThrottlingRate on the WORKER's target was attempted" \
  str_has_sub "$APPLIED" 'worker.Emulation.setCPUThrottlingRate'
assert_true "…and Chromium refused it: it is a page-only operation" \
  str_has_sub "$APPLIED" 'only supported for pages, not workers'
# The keys come back sorted by `m32_arm`, so the needles are per-mechanism rather than a whole row:
# an `ok:true` matched anywhere in the list would be satisfied by a DIFFERENT mechanism's success,
# which is the "anchor the needle to the row" family. The per-mechanism verdict is extracted by name.
_verdict() { python3 -c '
import json, sys
row = next((r for r in json.loads(sys.argv[1]) if r["mechanism"] == sys.argv[2]), None)
print("MISSING" if row is None else ("ok" if row.get("ok") else "refused"))' "$APPLIED" "$1"; }
assert_eq "the page's own CPU throttle WAS accepted" "ok" \
  "$(_verdict page.Emulation.setCPUThrottlingRate)"
assert_eq "…and so was the document freeze, which is what reaches a dedicated worker" "ok" \
  "$(_verdict 'Page.setWebLifecycleState frozen')"
assert_eq "…while the worker-target throttle was refused" "refused" \
  "$(_verdict worker.Emulation.setCPUThrottlingRate)"
assert_eq "…three mechanisms were attempted in all" "3" \
  "$(python3 -c '
import json, sys
print(len(json.loads(sys.argv[1])))' "$APPLIED")"

echo "== 3. the blocks, read out of the run"

ROWS="$(python3 - "$M32_ARMS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
blocks = d["arms"]["throttled"]["blocks"]
print("COUNT %d" % len(blocks))
prev_ts = prev_wall = prev_prod = None
strictly = True
maxgap = 0
maxprodgap = 0.0
nonzero_dev = 0
identity_ok = True
for b in blocks:
    ts = int(b["timestamp"]); wall = int(b["wallClockSeconds"]); dev = int(b["wallClockDeviationSeconds"])
    prod = float(b["producedAtMs"])
    if prev_ts is not None and ts <= prev_ts:
        strictly = False
        print("NONMONOTONIC %d -> %d" % (prev_ts, ts))
    if prev_wall is not None:
        maxgap = max(maxgap, wall - prev_wall)
    if prev_prod is not None:
        maxprodgap = max(maxprodgap, prod - prev_prod)
    if dev != 0:
        nonzero_dev += 1
    if ts - wall != dev:
        identity_ok = False
        print("BADDEV block %s: %d - %d != %d" % (b["number"], ts, wall, dev))
    prev_ts, prev_wall, prev_prod = ts, wall, prod
print("STRICTLY %s" % ("yes" if strictly else "no"))
print("MAXWALLGAP %d" % maxgap)
print("MAXPRODGAP %d" % int(maxprodgap))
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
assert_ge "the timer produced several blocks" 8 "$COUNT"
assert_eq "…numbered 1..N with no gap and no repeat" \
  "$(seq -s, 1 "$COUNT")" "$(printf '%s\n' "$ROWS" | sed -n 's/^NUMBERS //p')"
assert_eq "…and all of them empty, which is what produceEmptyBlocks means" \
  "$COUNT" "$(printf '%s\n' "$ROWS" | sed -n 's/^EMPTY //p')"

echo "== 4. THE ASSERTION: strictly increasing, across the freeze, in a worker"

assert_eq "every timestamp is strictly greater than the one before it" "yes" \
  "$(printf '%s\n' "$ROWS" | sed -n 's/^STRICTLY //p')"
FIRST="$(printf '%s\n' "$ROWS" | sed -n 's/^FIRSTTS //p')"
LAST="$(printf '%s\n' "$ROWS" | sed -n 's/^LASTTS //p')"
assert_eq "…so the chain advanced exactly one second per block" \
  "$((COUNT - 1))" "$((LAST - FIRST))"
# WALL-CLOCK SECONDS, not a counter from zero. A runtime that ignored the injected clock would
# produce 1, 2, 3… and satisfy everything above.
assert_ge "…and they are real epoch seconds rather than a counter" 1700000000 "$FIRST"

echo "== 5. THE FREEZE REACHED THE WORKER — measured on the WORKER's own clock"

MAXPROD="$(printf '%s\n' "$ROWS" | sed -n 's/^MAXPRODGAP //p')"
MAXGAP="$(printf '%s\n' "$ROWS" | sed -n 's/^MAXWALLGAP //p')"
note "largest gap between consecutive blocks: ${MAXPROD} ms on the worker's own clock, ${MAXGAP}s on the host clock"
# ===========================================================================================
# THIS IS THE ASSERTION THAT MAKES §4 MEAN ANYTHING, AND IT IS THE ONE M32 COULD NOT INHERIT.
# ===========================================================================================
# `producedAtMs` is `performance.now()` INSIDE the worker at the moment a block is sealed. At a
# 250 ms interval consecutive blocks are about 250 ms apart on it. A gap of two seconds can only come
# from the worker's own timers having stopped — which is what a document freeze does to a dedicated
# worker, and which is the fact this milestone had to establish rather than assume.
assert_ge "the WORKER's own clock shows its timers stopped for at least two seconds" 2000 "$MAXPROD"
# …AND THE HOST CLOCK AGREES, which is M27's assertion, kept: the two are different clocks and a gap
# in only one of them would be a story about the instrument.
assert_ge "…and the host clock jumped by at least two seconds across the same freeze" 2 "$MAXGAP"
# NON-DEGENERACY: the ordinary cadence must be much shorter than the gap, or "a two-second gap" is
# just what this chain does.
TYPICAL="$(python3 - "$M32_ARMS" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))["arms"]["throttled"]["blocks"]
gaps = sorted(b[i]["producedAtMs"] - b[i - 1]["producedAtMs"] for i in range(1, len(b)))
print(int(gaps[len(gaps) // 2]))
PY
)"
note "the median gap between consecutive blocks is ${TYPICAL} ms"
assert_true "…and the freeze's gap is many times the median one" \
  test "$MAXPROD" -gt "$((TYPICAL * 4))"
assert_true "…while the median itself is about the ticker's interval" \
  test "$TYPICAL" -lt "$((INTERVAL * 3))"

echo "== 6. the DECLARED deviation is real, and is asserted where it is NON-ZERO"

assert_eq "every block's declared deviation equals timestamp - wallClockSeconds" "yes" \
  "$(printf '%s\n' "$ROWS" | sed -n 's/^IDENTITY //p')"
# M23's review's correction, kept: the identity above is `0 == 0` on a chain that never deviates, so
# at least one row must be non-degenerate for it to mean anything.
assert_ge "…and at least three blocks have a NON-ZERO deviation" 3 \
  "$(printf '%s\n' "$ROWS" | sed -n 's/^NONZERODEV //p')"
# AND THE RULE'S SECOND BRANCH TOOK OVER. Before the freeze the chain runs ahead of the wall clock
# and the deviation GROWS; the freeze lets the wall clock catch up and it SHRINKS. A runtime that
# ignored `clock.nowInSeconds()` would have a deviation that only ever grows.
assert_ge "…and the deviation SHRANK somewhere, which is the rule's second branch taking over" 1 \
  "$(python3 - "$M32_ARMS" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))["arms"]["throttled"]["blocks"]
print(sum(1 for i in range(1, len(b))
          if int(b[i]["wallClockDeviationSeconds"]) < int(b[i - 1]["wallClockDeviationSeconds"])))
PY
)"

echo "== 7. production RESUMED after the freeze, and the page saw it"

assert_ge "the block subscription delivered events to the page across the freeze" 8 \
  "$(m32_arm throttled events)"
# THE OTHER HALF OF §5. A gap proves the timers stopped; this proves they started again. A chain
# that froze and never came back would satisfy every assertion above.
AFTER_GAP="$(python3 - "$M32_ARMS" <<'PYX'
import json, sys
b = json.load(open(sys.argv[1]))["arms"]["throttled"]["blocks"]
gaps = [(b[i]["producedAtMs"] - b[i - 1]["producedAtMs"], i) for i in range(1, len(b))]
_, at = max(gaps)
print(len(b) - at)
PYX
)"
note "${AFTER_GAP} block(s) were produced after the freeze's gap"
assert_ge "…and the chain went on producing afterwards" 8 "$AFTER_GAP"

echo "== 8. WORKER-NODE.md §6's derived figures, compared AGAINST THE DOCUMENT"

assert_file "the write-up exists" "$M32_DOC"
DOC="$(cat "$M32_DOC")"
row_for() { printf '%s\n' "$DOC" | grep -F "$1" | head -1; }
REFUSAL_ROW="$(row_for "on the **worker's own** CDP target")"
assert_true "§6 has a row for the worker-target throttle" test -n "$REFUSAL_ROW"
assert_true "…and it records the refusal Chromium actually gave" \
  str_has_sub "$REFUSAL_ROW" 'only supported for pages, not workers'
FREEZE_ROW="$(row_for 'setWebLifecycleState')"
assert_true "§6 has a row for the freeze" test -n "$FREEZE_ROW"
assert_true "…recording that it was accepted" str_has_sub "$FREEZE_ROW" 'accepted'
GAP_ROW="$(row_for 'gap of **at least')"
assert_true "§6 states the gap the check requires, on its own line" test -n "$GAP_ROW"
assert_true "…and it is the bound this check asserts" str_has_word "$GAP_ROW" "two"

m32_finish
