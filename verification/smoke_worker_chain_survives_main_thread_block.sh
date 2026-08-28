#!/usr/bin/env bash
# smoke_worker_chain_survives_main_thread_block
#
# M32 verification: "a busy main thread does not stall block production. Control: the same load with
# the runtime ON the main thread DOES stall it, or the test is measuring nothing."
#
# ===========================================================================================
# THE CONTROL IS THE CHECK. WITHOUT IT THIS ASSERTS NOTHING.
# ===========================================================================================
#
# "The worker produced blocks while the main thread was busy" is satisfied by a chain that would
# have produced those blocks whatever the main thread was doing — which is every chain that has ever
# worked — and it is also satisfied by a run in which the main thread was never actually busy. So
# the page runs the SAME LOAD twice, in two separate pages, with two windows each:
#
#                     warm window        busy window
#   worker             blocks            blocks          <- production survives
#   main thread        blocks            ZERO            <- production stalls
#
# All four cells are assertions. The main-thread arm's WARM window is what says its zero is a stall
# rather than a broken chain; the worker arm's warm window is what says its busy-window count is a
# chain running rather than a backlog draining.
#
# AND THE WINDOWS ARE TIMED BY WHOEVER CAN TIME THEM. The page cannot time the busy window — being
# unable to run code is the point — so in the worker arm the edges are the WORKER's own
# `performance.now()` readings, carried on `NodeState.atMs`, taken from two `state()` calls the page
# posts without awaiting. `BlockSummary.producedAtMs` is on the same clock, so "produced during the
# window" is a comparison between two readings of one clock.
#
# ===========================================================================================
# THIS CHECK ALSO OWNS DD-5 FOR THE WORKER, AND THE RULE IS MECHANICAL
# ===========================================================================================
#
# "The worker adds no capability the browser reference lacks" is a deliverable with no verification
# entry of its own, so it lives here, in M27's own shape: `WORKER_PROTOCOL_BACKING` is a VALUE in
# the built worker bundle naming the symbol behind each operation, and the check requires
# `{ ops whose backing browser.js does not export } == WORKER_TESTING_OPS`, as a SET, in both
# directions. An undeclared capability fails; a declaration for something the reference does export
# fails too.
#
# Run: just verify-m32-mainthread

TEST_NAME="smoke_worker_chain_survives_main_thread_block"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m32_worker.sh"

m32_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v node >/dev/null 2>&1 || die "node is required"
m32_require_arms

echo "== 0. the arm report carries what this check reads"

W_WARM="$(m32_arm workerBlocked warmBlocks)"
W_BUSY="$(m32_arm workerBlocked busyBlocks)"
M_WARM="$(m32_arm mainBlocked warmBlocks)"
M_BUSY="$(m32_arm mainBlocked busyBlocks)"
W_SPUN="$(m32_arm workerBlocked spun)"
M_SPUN="$(m32_arm mainBlocked spun)"
W_BUSYMS="$(m32_arm workerBlocked busyActualMs)"
M_BUSYMS="$(m32_arm mainBlocked busyActualMs)"
W_WINDOW="$(m32_arm workerBlocked busyWindowMs)"
BOOT_TARGETS="$(m32_arm boot workerTargetCount)"
BOOT_OUTCOME="$(m32_arm boot transfer.outcome)"
m32_absent \
  "workerBlocked.warmBlocks=$W_WARM" "workerBlocked.busyBlocks=$W_BUSY" \
  "mainBlocked.warmBlocks=$M_WARM" "mainBlocked.busyBlocks=$M_BUSY" \
  "workerBlocked.spun=$W_SPUN" "mainBlocked.spun=$M_SPUN" \
  "workerBlocked.busyActualMs=$W_BUSYMS" "mainBlocked.busyActualMs=$M_BUSYMS" \
  "workerBlocked.busyWindowMs=$W_WINDOW" \
  "boot.workerTargetCount=$BOOT_TARGETS" "boot.transfer.outcome=$BOOT_OUTCOME"

echo "== 1. the node really is on another thread"

note "chromium $(m32_run chromium); module $(m32_run module.bytes) bytes; worker bundle $(m32_run workerBundle.bytes) bytes"
assert_eq "the page spawned exactly one worker target" "1" "$BOOT_TARGETS"
assert_true "…and it is this repository's worker bundle" \
  str_has_sub "$(m32_arm boot workerTargets)" '/worker.js'
assert_true "…whose own network log this run could enable" \
  str_has_sub "$(m32_arm boot workerTargets)" '"network":"enabled"'
assert_eq "no page error while it ran" "[]" "$(m32_arm boot pageErrors)"
assert_eq "…and no console error" "[]" "$(m32_arm boot consoleErrors)"

# THE PAIR THAT SAYS THE RUNTIME IS ON THE OTHER THREAD, and it is a pair rather than one reading
# because either half alone is consistent with something else. The PAGE fetched the worker script
# and did NOT fetch the module; the WORKER fetched the module. A runtime that had quietly stayed on
# the page would have `avm.wasm` in the page's log.
assert_true "the PAGE fetched the worker script" \
  str_has_sub "$(m32_arm boot workerRequests)" '/worker.js'
assert_eq "…and the page did NOT fetch avm.wasm itself" "[]" "$(m32_arm boot avmWasmRequests)"
assert_true "…while the WORKER did" \
  str_has_sub "$(m32_arm boot workerAvmWasmRequests)" '/assets/avm.wasm'

# DD-11 TRAVELS WITH THE WORKER, and it is asked of the log that can answer it. Asking the PAGE's
# log would be an absence measured against a log from which the subject is excluded by construction
# — `CAMPAIGN-BRIEF.md` records that defect twice — because a worker's fetches are not in it. The
# non-emptiness beside it is what says this log is not empty for some other reason.
assert_ge "the worker's own network log is non-trivial" 8 "$(m32_arm boot workerRequestCount)"
assert_eq "…and the WORKER never fetched the barretenberg proving stack" "[]" \
  "$(m32_arm boot workerBarretenbergRequests)"

echo "== 2. and a real transaction executed on it"

assert_eq "the token transfer was processed" "processed" "$BOOT_OUTCOME"
assert_eq "…and did NOT revert" "0" "$(m32_arm boot transfer.revertCode)"
assert_eq "…in block 1" "1" "$(m32_arm boot transfer.blockNumber)"
STEPS="$(m32_arm boot transfer.executedSteps)"
STAT="$(m32_arm boot transfer.instructionsExecuted)"
assert_ge "…having executed a substantial number of instructions" 100 "$STEPS"
assert_eq "…and the drained step count equals the module's own statistic" "$STAT" "$STEPS"
assert_true "…dispatching to the two functions the artifact names" \
  str_has_sub "$(m32_arm boot transfer.debugFunctionNames)" 'Token.transfer_in_public'
assert_true "…including the view call" \
  str_has_sub "$(m32_arm boot transfer.debugFunctionNames)" 'Token.balance_of_public'

echo "== 3. the three subscriptions crossed the boundary"

assert_eq "the client subscribed to all three kinds" '["block","trace","tx"]' "$(m32_arm boot eventKinds)"
assert_ge "…and events actually arrived" 3 \
  "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(len(d["arms"]["boot"]["events"]))' "$M32_ARMS")"
assert_eq "…and the page — unlike the worker — has a document" "true" "$(m32_arm boot pageHasDocument)"

echo "== 4. the protocol, read out of the BUILT worker bundle"

# NOT OUT OF THE SOURCE. M27's rule for `NODE_CONVENIENCES`: a comment cannot be compared with a
# bundle, so `worker.js` exports its declarations and they are read back by importing it.
BUNDLE_PROTOCOL="$(m32_worker_bundle_value 'm.WORKER_PROTOCOL')"
BUNDLE_OFF="$(m32_worker_bundle_value 'Object.keys(m.WORKER_OFF_SCHEMA_OPS).sort()')"
BUNDLE_EXPOSED="$(m32_worker_bundle_value 'Object.keys(m.workerNode).sort()')"
BUNDLE_BACKING="$(m32_worker_bundle_value 'Object.keys(m.WORKER_PROTOCOL_BACKING).sort()')"
BUNDLE_TESTING="$(m32_worker_bundle_value 'm.WORKER_TESTING_OPS')"
assert_ge "the built worker bundle declares a protocol of some size" 15 \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$BUNDLE_PROTOCOL")"
# TWO ARTEFACTS, NOT TWO READINGS OF ONE. The page's copy comes from `worker-demo.js`, which esbuild
# built from the same source into a different output; the check's comes from `worker.js`. A build
# that shipped a stale worker would disagree here.
assert_eq "…and the page's client agrees with it, out of a different bundle" \
  "$BUNDLE_PROTOCOL" "$(m32_arm boot protocol)"
assert_eq "the two off-schema operations are declared, by name" '["subscribe","takeContainer"]' "$BUNDLE_OFF"
assert_eq "…and the page's copy agrees" "$BUNDLE_OFF" "$(m32_arm boot offSchema)"
assert_eq "the exposed surface is the schema channel plus exactly those two" \
  '["call","subscribe","takeContainer"]' "$BUNDLE_EXPOSED"
# BOTH DIRECTIONS. `exposed − {call}` must EQUAL the declared exceptions: a third exception added
# without a declaration fails here, and a declaration for something not exposed fails too.
assert_eq "…so a third off-schema operation could not appear undeclared" "" \
  "$(python3 -c '
import json, sys
exposed = set(json.loads(sys.argv[1])) - {"call"}
declared = set(json.loads(sys.argv[2]))
print(" ".join(sorted(exposed ^ declared)))' "$BUNDLE_EXPOSED" "$BUNDLE_OFF")"
assert_eq "every operation, on the channel or off it, declares what backs it" "" \
  "$(python3 -c '
import json, sys
backing = set(json.loads(sys.argv[1]))
ops = set(json.loads(sys.argv[2])) | set(json.loads(sys.argv[3]))
print(" ".join(sorted(backing ^ ops)))' "$BUNDLE_BACKING" "$BUNDLE_PROTOCOL" "$BUNDLE_OFF")"

echo "== 5. DD-5: the worker adds no capability the browser reference lacks"

BROWSER_EXPORTS="$(m32_bundle_exports browser.js)"
TESTING_EXPORTS="$(m32_bundle_exports testing.js)"
assert_ge "the reference bundle's export set was read" 50 "$(printf '%s\n' "$BROWSER_EXPORTS" | grep -c . || true)"
assert_ge "…and the testing bundle's" 50 "$(printf '%s\n' "$TESTING_EXPORTS" | grep -c . || true)"

UNBACKED="$(python3 - "$BROWSER_EXPORTS" "$(m32_worker_bundle_value 'm.WORKER_PROTOCOL_BACKING')" <<'PY'
import json, sys
browser = set(l for l in sys.argv[1].split("\n") if l)
backing = json.loads(sys.argv[2])
print(" ".join(sorted(op for op, sym in backing.items() if sym not in browser)))
PY
)"
note "operations whose backing symbol browser.js does not export: ${UNBACKED:-(none)}"
# THE MECHANICAL RULE, AS A SET, IN BOTH DIRECTIONS.
assert_eq "the operations the reference does not back are EXACTLY the declared testing ones" \
  "$(python3 -c 'import json,sys; print(" ".join(json.loads(sys.argv[1])))' "$BUNDLE_TESTING")" \
  "$UNBACKED"
# AND THE RULE IS NOT VACUOUS: the declared set is non-empty, so "they are equal" is not "both are
# empty". `CAMPAIGN-BRIEF.md`'s "both sides read, both sides zero" in its set form.
assert_ge "…and that declared set is not empty, so the equality above is not two absences" 1 \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$BUNDLE_TESTING")"
assert_true "…the testing operation's backing IS exported by testing.js" \
  str_has_line "$TESTING_EXPORTS" "$(m32_worker_bundle_value 'm.WORKER_PROTOCOL_BACKING.runTokenTransfer')"
assert_false "…and is NOT exported by browser.js, which is why it is declared" \
  str_has_line "$BROWSER_EXPORTS" "$(m32_worker_bundle_value 'm.WORKER_PROTOCOL_BACKING.runTokenTransfer')"
assert_true "…while a reference-backed operation's symbol IS exported by browser.js" \
  str_has_line "$BROWSER_EXPORTS" "$(m32_worker_bundle_value 'm.WORKER_PROTOCOL_BACKING.submitExternal')"

echo "== 6. THE LOAD: both arms spun the main thread, and spun it for the same time"

BUSY_PARAM="$(m32_run parameters.busyMs)"
WARM_PARAM="$(m32_run parameters.warmMs)"
TICK_PARAM="$(m32_run parameters.tickMs)"
note "interval ${TICK_PARAM} ms; warm window ${WARM_PARAM} ms; busy window ${BUSY_PARAM} ms"
assert_eq "the worker arm ran the declared busy duration" "$BUSY_PARAM" "$(m32_arm workerBlocked busyMs)"
assert_eq "…and the control ran the same one" "$BUSY_PARAM" "$(m32_arm mainBlocked busyMs)"
assert_eq "the two arms used the same block interval" \
  "$(m32_arm workerBlocked intervalMs)" "$(m32_arm mainBlocked intervalMs)"
assert_eq "…and the same warm window" \
  "$(m32_arm workerBlocked warmMs)" "$(m32_arm mainBlocked warmMs)"
# THE SPIN IS OBSERVABLE OR IT DID NOT HAPPEN. A busy loop whose accumulator nothing reads is a busy
# loop an optimiser may delete, and an arm measuring an unblocked main thread would report the
# worker's advantage over nothing at all.
assert_ge "the worker arm's page really spun" 1000000 "$W_SPUN"
assert_ge "…and so did the control's" 1000000 "$M_SPUN"
assert_true "the worker arm blocked for at least the declared time" \
  test "${W_BUSYMS%%.*}" -ge "$((BUSY_PARAM - 1))"
assert_true "…and so did the control" test "${M_BUSYMS%%.*}" -ge "$((BUSY_PARAM - 1))"

echo "== 7. THE MEASUREMENT: the worker keeps producing"

note "worker: ${W_WARM} block(s) warm, ${W_BUSY} block(s) busy (window ${W_WINDOW} ms)"
assert_ge "the worker's chain was producing before the main thread got busy" 3 "$W_WARM"
assert_ge "…and it went on producing while the main thread was busy" 3 "$W_BUSY"
assert_ge "…over a busy window that really was the declared length" "$((BUSY_PARAM - 200))" \
  "${W_WINDOW%%.*}"
assert_ge "…and the worker's total is at least the two windows together" "$((W_WARM + W_BUSY))" \
  "$(m32_arm workerBlocked totalBlocks)"

# ===========================================================================================
# A COUNT INSIDE A WINDOW IS NOT PRODUCTION DURING IT — M32'S REVIEW'S ADDITION.
# ===========================================================================================
#
# "16 blocks landed between these two readings" is also true of a chain that produced NOTHING for
# 3.7 seconds and then delivered sixteen in a burst when the thread came back — which is exactly
# what a backlog draining at the window's right-hand edge looks like, and it is the reading a
# sceptic should reach for first. The count cannot tell them apart; the SPACING can. Measured over
# this run: every consecutive pair inside the busy window is 251.6-252.3 ms apart, at a 250 ms
# ticker, so there is no stall inside the window at all.
#
# The warm window is the calibration and it is on the same clock, so this is a comparison between
# two stretches of the same chain rather than against a constant somebody chose.
#
# AND THE SPAN INCLUDES THE WINDOW'S OWN LEFT EDGE, WHICH THE FIRST VERSION OF THIS BLOCK DID NOT.
# Calibrated rather than reasoned about, and the calibration is why this paragraph exists: the arm
# report was doctored so that all sixteen busy-window blocks keep their COUNT and move into the last
# 200 ms before the window closes — a backlog draining, exactly the reading this block was written to
# rule out — and the check reported **82 assertions, 0 failures**. Measuring only the gaps BETWEEN
# in-window blocks makes a tight cluster look like perfect cadence; the 3.8-second stall that
# precedes it lies between the window OPENING and the first block, which nothing was looking at.
# With `busyOpen` as the first point the same doctored report gives a largest gap of 3,800 ms and the
# assertion fails. *A control that is not run is a control that is the wrong shape.*
_worker_window_spacing() { # <open-field> <close-field> -> "COUNT<TAB>MAXGAP"
  python3 - "$M32_ARMS" "$1" "$2" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))["arms"]["workerBlocked"]
lo, hi = a[sys.argv[2]], a[sys.argv[3]]
at = [b["producedAtMs"] for b in a["blocks"] if lo < b["producedAtMs"] <= hi]
# THE WINDOW'S OPENING IS THE FIRST POINT. A stall that happens before the first block in the
# window is invisible to a between-blocks measurement, and that is the whole of a backlog drain.
points = [lo] + at
gaps = [points[i + 1] - points[i] for i in range(len(points) - 1)]
print("%d\t%d" % (len(gaps), int(max(gaps)) if gaps else -1))
PY
}
BUSY_SPACING="$(_worker_window_spacing busyOpenAtMs busyCloseAtMs)"
WARM_SPACING="$(_worker_window_spacing warmOpenAtMs warmCloseAtMs)"
BUSY_GAPS="${BUSY_SPACING%%$'\t'*}"; BUSY_MAXGAP="${BUSY_SPACING##*$'\t'}"
WARM_GAPS="${WARM_SPACING%%$'\t'*}"; WARM_MAXGAP="${WARM_SPACING##*$'\t'}"
note "consecutive spacing: ${BUSY_GAPS} gap(s) in the busy window, largest ${BUSY_MAXGAP} ms; \
${WARM_GAPS} gap(s) warm, largest ${WARM_MAXGAP} ms"
# NON-DEGENERACY FIRST. With fewer than two blocks in the window there are no gaps, `max` has
# nothing to take and the helper prints -1 — which must be a failure and not a vacuous pass.
assert_ge "the busy window holds enough blocks to have spacing at all" 3 "$BUSY_GAPS"
assert_true "…and NO interval from the window OPENING onward is more than three ticker intervals, \
so the count is production DURING the spin rather than a backlog draining at its edge" \
  test "$BUSY_MAXGAP" -lt "$((TICK_PARAM * 3))"
# THE PAIR. The busy window's worst spacing must be of the same order as the warm window's, which
# is what says the spin cost the chain nothing rather than merely not stopping it.
assert_true "…and its worst spacing is within twice the warm window's" \
  test "$BUSY_MAXGAP" -le "$((WARM_MAXGAP * 2))"

echo "== 8. THE CONTROL: the same load on the main thread DOES stall"

note "main thread: ${M_WARM} block(s) warm, ${M_BUSY} block(s) busy"
# THE WARM WINDOW IS WHAT MAKES THE ZERO MEAN SOMETHING. A main-thread arm that produced nothing in
# either window would be a broken chain reported as a stalled one.
assert_ge "the main-thread chain WAS producing before the spin" 3 "$M_WARM"
assert_eq "…and produced NOTHING while the main thread was blocked" "0" "$M_BUSY"
# AND THE STRONGEST FORM OF THE SAME FACT: the LAST block the main-thread chain produced was
# produced BEFORE the busy window opened. A count of zero inside a window is a summary; this is the
# window's whole right-hand side, and it fails if a single block slipped through.
M_LAST="$(m32_arm mainBlocked lastBlockAtMs)"
M_BUSY_OPEN="$(m32_arm mainBlocked busyOpenAtMs)"
assert_true "…and its LAST block predates the moment the spin began" \
  test "${M_LAST%%.*}" -lt "${M_BUSY_OPEN%%.*}"
assert_ge "…over a busy window that really was the declared length" "$((BUSY_PARAM - 200))" \
  "$(m32_arm mainBlocked busyWindowMs | cut -d. -f1)"

echo "== 9. the two arms read together — the discriminator"

assert_ge "the worker produced strictly more blocks under the spin than the main thread did" 3 \
  "$((W_BUSY - M_BUSY))"
# AND THE TWO ARMS AGREE ABOUT EVERYTHING ELSE, which is what makes the difference attributable.
# Their warm windows are within a block of each other; if they were not, the arms are not the same
# load and the busy-window difference could be anything.
assert_true "…while their warm windows agree to within one block" \
  test "$(( W_WARM > M_WARM ? W_WARM - M_WARM : M_WARM - W_WARM ))" -le 2

echo "== 10. THE REJECTION IS RE-MEASURED, NOT QUOTED"

# ===========================================================================================
# "IT DOES NOT BUILD HERE" IS A CLAIM AND NEEDS THE SAME EVIDENCE AS ANY OTHER.
# ===========================================================================================
#
# `WORKER-NODE.md` §1 rejects `@aztec/foundation/transport` — 787 lines of upstream request/response,
# broadcast and transferable machinery whose own `Socket` docstring names browser MessagePorts — as
# `cannot-reach-target`, on the ground that it leaves four unresolved Node builtins in a browser
# build. That is exactly the kind of sentence `CAMPAIGN-BRIEF.md` says goes stale: M26 recorded "this
# environment does not build it" about something that builds. So it is BUILT, here, on every run,
# with the same four shims the real build applies, and the errors are counted.
#
# THE CONTROL IS THE ACCEPTED TRANSPORT. `comlink` through the same esbuild with the same flags must
# produce ZERO errors, so "four errors" is a measurement by an instrument that can also report none.
M32_PROBE="$M32_WORK/reuse-probe"
rm -rf "$M32_PROBE"; mkdir -p "$M32_PROBE"
m27_require_esbuild
_m32_probe_errors() { # <import line> <out name> -> prints one line per unresolved builtin
  printf '%s\n' "$1" > "$BROWSER_DIR/.m32-probe.ts"
  ( cd "$BROWSER_DIR" && "$M27_ESBUILD" --bundle --platform=browser --format=esm --log-limit=0 \
      --alias:util=../browser-probe/shims/util.js \
      --alias:assert=../browser-probe/shims/assert.js \
      --alias:tty=../browser-probe/shims/tty.js \
      --alias:module=./src/shims/module.js \
      --outfile="$M32_PROBE/$2.js" .m32-probe.ts ) > "$M32_PROBE/$2.log" 2>&1
  rm -f "$BROWSER_DIR/.m32-probe.ts"
  grep -oE 'Could not resolve "[a-z_]+"' "$M32_PROBE/$2.log" | sed 's/Could not resolve //' | tr -d '"' | sort || true
}
TRANSPORT_ERRORS="$(_m32_probe_errors \
  "import { TransportClient, TransportServer, Transfer } from '@aztec/foundation/transport'; export const x = [TransportClient, TransportServer, Transfer].length;" \
  transport)"
COMLINK_ERRORS="$(_m32_probe_errors \
  "import * as C from 'comlink'; export const x = Object.keys(C).length;" comlink)"
TRANSPORT_ERROR_COUNT="$(printf '%s\n' "$TRANSPORT_ERRORS" | grep -c . || true)"
note "foundation/transport unresolved builtins: $(printf '%s' "$TRANSPORT_ERRORS" | tr '\n' ' ')"
assert_eq "the rejected transport leaves exactly four unresolved Node builtins" "4" "$TRANSPORT_ERROR_COUNT"
assert_eq "…three of them 'events'" "3" \
  "$(printf '%s\n' "$TRANSPORT_ERRORS" | grep -c '^events$' || true)"
assert_eq "…and one 'worker_threads'" "1" \
  "$(printf '%s\n' "$TRANSPORT_ERRORS" | grep -c '^worker_threads$' || true)"
# THE CONTROL: the same instrument, over the transport that WAS taken, reports none.
assert_eq "the transport that WAS taken builds for the browser with none" "0" \
  "$(printf '%s\n' "$COMLINK_ERRORS" | grep -c . || true)"
assert_true "…and it produced a module rather than nothing" test -s "$M32_PROBE/comlink.js"
# AND THE BARREL IS THE ONLY DOOR: no wildcard subpath, so the browser-safe half cannot be taken
# alone. Read out of the installed package rather than asserted.
assert_eq "@aztec/foundation exposes ./transport as a barrel and no wildcard subpath" "0" \
  "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(len([k for k in d["exports"] if "*" in k]))' "$ORCH_DIR/node_modules/@aztec/foundation/package.json")"
assert_ge "…and that barrel re-exports the node sockets" 1 \
  "$(grep -c "node/index.js" "$ORCH_DIR/node_modules/@aztec/foundation/dest/transport/index.js" || true)"

echo "== 11. WORKER-NODE.md's DERIVED figures, re-derived and compared AGAINST THE DOCUMENT"

# ===========================================================================================
# ONLY THE DERIVED ONES. THE RECORDED RUN IS LABELLED AND NOT ASSERTED.
# ===========================================================================================
#
# M27's §8 timer table is the precedent and it is the right one: a block count under a four-second
# spin is a property of the scheduler at the moment it was taken, and a check that pinned it would
# fail on a faster box for no reason anybody could act on. What IS pinned is the PARAMETERS, the
# protocol and the PATTERN — and the pattern's load-bearing cell, the main thread's zero, is
# asserted in §8 against the run rather than against the prose.
assert_file "the write-up exists" "$M32_DOC"
DOC="$(cat "$M32_DOC")"
row_for() { printf '%s\n' "$DOC" | grep -F "$1" | head -1; }

# ONE FIGURE PER ROW, EACH ROW NAMING ITS SUBJECT — and the first version of this block is why.
# The three parameters were one sentence; it wraps at 100 columns; `row_for` returns the first
# matching LINE, and "busy window **4000 ms**" had wrapped onto the next one. The assertion went red
# for a reason with nothing to do with its subject, which is the cheap direction of
# `CAMPAIGN-BRIEF.md`'s "a needle that spanned a line break" — but a needle that stops matching the
# day somebody reflows a paragraph is a needle that gets deleted rather than fixed. §3 is a table.
for pair in "| block interval |:$TICK_PARAM" "| warm window |:$WARM_PARAM" "| busy window |:$BUSY_PARAM"; do
  needle="${pair%%:*}"; value="${pair##*:}"
  row="$(row_for "$needle")"
  assert_true "§3 has a row for '${needle}'" test -n "$row"
  assert_true "…and it names the value the run used (${value} ms)" str_has_sub "$row" "**$value ms**"
done

PROTO_ROW="$(row_for 'operations** on the schema channel')"
assert_true "§2 states the protocol's size on its own line" test -n "$PROTO_ROW"
assert_true "…and it is the size the built bundle declares" str_has_sub "$PROTO_ROW" \
  "**$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$BUNDLE_PROTOCOL") operations**"
# EVERY OPERATION NAMED, not a count only: a document that lost an operation from the list while
# keeping the number would pass a size comparison.
#
# ASKED OF §2'S LIST, NOT OF THE FILE — M32's REVIEW'S CORRECTION, and the sentence above is what
# made it worth looking for. The first form asked whether `` `name` `` occurred ANYWHERE in
# `WORKER-NODE.md`; measured, deleting `containerBufferState` from §2's list left the residue EMPTY,
# because §4 mentions the operation in prose. That is `CAMPAIGN-BRIEF.md`'s "anchor the needle to the
# row, not to the file", in the check whose own comment claims the property. It is one bullet now,
# and the region's own SIZE is asserted so "both residues are empty" cannot be "the region is".
DOC_OPS_REGION="$(python3 "$VERIFY_DIR/_m32_doc_ops.py" "$BUNDLE_PROTOCOL" "$M32_DOC" region)"
assert_ge "§2's operation list was found as a region rather than searched for file-wide" 3 \
  "$DOC_OPS_REGION"
assert_eq "…and every operation the bundle declares is named in THAT LIST" "" \
  "$(python3 "$VERIFY_DIR/_m32_doc_ops.py" "$BUNDLE_PROTOCOL" "$M32_DOC" missing)"
# AND THE OTHER DIRECTION, which nothing covered: an operation the document lists and the bundle
# does not declare — a name left behind when one is renamed or dropped — reads exactly like a
# correct list until somebody counts.
assert_eq "…and the list names nothing the bundle does not declare" "" \
  "$(python3 "$VERIFY_DIR/_m32_doc_ops.py" "$BUNDLE_PROTOCOL" "$M32_DOC" extra)"
SUB_ROW="$(row_for 'subscriptions** —')"
assert_true "§2 states the subscription count on its own line" test -n "$SUB_ROW"
assert_true "…and it is the number the bundle declares" str_has_sub "$SUB_ROW" \
  "**$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$(m32_worker_bundle_value 'm.WORKER_SUBSCRIPTIONS')") subscriptions**"

REJECT_ROW="$(row_for 'unresolved Node builtins')"
assert_true "§1 states the rejection's measurement on one line" test -n "$REJECT_ROW"
# NOT `str_has_word … 4`: the same row spells the split as `×3` and `×1`, so a bare digit needle
# for the TOTAL is satisfied by one of the parts.
assert_true "…and it is the count this run just took" \
  str_has_sub "$REJECT_ROW" "**$TRANSPORT_ERROR_COUNT unresolved Node builtins"
assert_true "…naming the builtin that is not shimmed anywhere in this build" \
  str_has_sub "$REJECT_ROW" 'events'

DD5_ROW="$(row_for 'that set is **exactly')"
assert_true "§2 states which operations the reference does not back" test -n "$DD5_ROW"
assert_true "…and it names the one the measurement found" str_has_sub "$DD5_ROW" "$UNBACKED"

m32_finish
