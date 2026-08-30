#!/usr/bin/env bash
# e2e_replay_block_range — L4 (Aztec-Live-Chain-Replay).
#
# "Every public transaction in a real block is replayed with a per-transaction outcome.
#  Control: an unreplayable transaction is isolated and named, and the range still completes."
#
# ════════════════════════════════════════════════════════════════════════════════════════════════
# THIS CHECK NEEDS A LIVE AZTEC NODE ON EVERY RUN. IT IS NOT PART OF THE OFFLINE FLOOR.
# ════════════════════════════════════════════════════════════════════════════════════════════════
#
# `just verify-l4-net`, never `just verify-l4`. `verify-l1`'s header states the rule: "a check that
# needs a live testnet is a check that goes red on somebody else's schedule."
#
# **AND IT IS WORSE THAN L1's CAPTURE IN ONE RESPECT, WHICH IS WHY NO FIXTURE FIXES IT.** The
# subject here is THE REPLAYABLE WINDOW, and the window is a property of the chain at the moment it
# is read: its two ends are `getBlockNumber('finalized') + 1` and `getBlockNumber()`, and the
# transactions in it are whatever the chain happened to contain. A recording of one would be a
# recording of a MOMENT, and asserting over it later would be asserting that a past minute is still
# happening.
#
# The three wrong resolutions, named here and in the Justfile so they are not re-proposed:
#   1. FOLD IT INTO THE FLOOR — makes an offline floor depend on a third party's uptime.
#   2. SKIP WHEN THE NETWORK IS DOWN — a skipped check reads as a smaller milestone rather than a
#      red one, which is this campaign's most-repeated defect wearing a friendlier word.
#   3. PIN A WINDOW FIXTURE — asserts over a moment that has passed.
#
# ════════════════════════════════════════════════════════════════════════════════════════════════
# AND A WINDOW WITH NO TRANSACTIONS IS A FACT ABOUT THE CHAIN, NOT A PASS AND NOT A FAILURE OF THIS
# CODE — SO IT IS A NAMED DEATH RATHER THAN EITHER.
# ════════════════════════════════════════════════════════════════════════════════════════════════
#
# Measured: testnet's window held 3 transactions and mainnet's held 1 on 2026-08-30, and testnet's
# rate varies — 258 transactions across 600 blocks in one range, 26 across 300 in another. A run
# that finds zero can happen. Asserting "at least one transaction was replayed" over an empty window
# would be red for a reason that has nothing to do with this repository; passing would be the
# vacuous green this campaign has shipped twice. `die` naming it is the third option and the honest
# one.

set -uo pipefail
TEST_NAME="e2e_replay_block_range"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l2_replay.sh"

echo "== $TEST_NAME"
echo "   THIS CHECK REACHES A LIVE AZTEC NODE. It is not part of the offline floor."
l2_prepare

URL="${L4_RANGE_URL:-https://aztec-testnet.drpc.org}"
REPORT="$L2_WORK/probes/l4-range.json"
CONTROL="$L2_WORK/probes/l4-range-control.json"
DRIVER="$REPO_ROOT/replay/tools/replay_window.mjs"

assert_file "the range driver is committed" "$DRIVER"
assert_true "…and TRACKED" git -C "$REPO_ROOT" ls-files --error-unmatch "replay/tools/replay_window.mjs"

run_range() { # <outfile> <extra-args...>
  local out="$1"; shift
  ( cd "$REPO_ROOT/replay" \
    && AVM_WASM_PATH="$L2_MODULE" timeout "${L4_RANGE_TIMEOUT:-900}" \
       node tools/replay_window.mjs --url "$URL" --module "$L2_MODULE" --json "$@" ) >"$out" 2>"$out.err"
  local rc=$?
  if [ ! -s "$out" ]; then
    die "the range driver produced no report (rc $rc). Its stderr:
$(tail -15 "$out.err")"
  fi
  printf '%s\n' "$rc"
}

j() { python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
cur = d
for k in sys.argv[2].split("."):
    cur = cur[int(k)] if isinstance(cur, list) else cur.get(k)
    if cur is None: break
print("" if cur is None else cur)
' "$1" "$2"; }

# ---------------------------------------------------------------------------
echo "== 1. the window is READ, not chosen"
# ---------------------------------------------------------------------------
RC="$(run_range "$REPORT")"
assert_file "the range produced a report" "$REPORT"

TIP="$(j "$REPORT" window.tip)"
FIN="$(j "$REPORT" window.finalized)"
FROM="$(j "$REPORT" window.from)"
TO="$(j "$REPORT" window.to)"
BLOCKS="$(j "$REPORT" window.blocks)"

assert_ge "the chain answered with a real tip" 1000 "$TIP"
assert_ge "…and a finalized tip" 1000 "$FIN"
assert_true "…which is BELOW the tip, so there is a window at all" test "$FIN" -lt "$TIP"
assert_eq "the range STARTS one block above the finalized tip" "$(( FIN + 1 ))" "$FROM"
assert_eq "…and ENDS at the tip" "$TIP" "$TO"
assert_eq "…so its length is the finality lag" "$(( TIP - FIN ))" "$BLOCKS"
assert_ge "…which is a real window rather than a single block" 5 "$BLOCKS"

TXS="$(j "$REPORT" transactions)"
ROWS="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["outcomes"]))' "$REPORT")"
if [ "$TXS" -eq 0 ]; then
  die "the replayable window ($FROM..$TO, $BLOCKS blocks) held NO transactions.
     THAT IS A FACT ABOUT THE CHAIN AND NOT A FAILURE OF THIS CODE, and it is a death rather than
     a pass because every assertion below would be vacuous over an empty table. Measured on
     2026-08-30: testnet's window held 3 and mainnet's held 1, and testnet's rate varies by an
     order of magnitude between ranges. Re-run, or point --url at a busier chain."
fi
assert_ge "the window held at least one transaction" 1 "$TXS"
assert_eq "…and every one of them has a row in the table" "$TXS" "$ROWS"

# ---------------------------------------------------------------------------
echo "== 2. every row carries a DISCRIMINANT from the closed set, and the replayed ones reproduced"
# ---------------------------------------------------------------------------
KINDS="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(" ".join(sorted({o["kind"] for o in d["outcomes"]})))
' "$REPORT")"
DECLARED="below-finalized failed no-public-half not-first-in-block replayed"
assert_true "every row's kind is one the module declares" bash -c "
  for k in $KINDS; do case ' $DECLARED ' in *\" \$k \"*) ;; *) exit 1 ;; esac; done"
assert_eq "…and no row is missing a kind" "0" \
  "$(python3 -c 'import json,sys; print(sum(1 for o in json.load(open(sys.argv[1]))["outcomes"] if not o.get("kind")))' "$REPORT")"
assert_eq "…nor a detail saying why" "0" \
  "$(python3 -c 'import json,sys; print(sum(1 for o in json.load(open(sys.argv[1]))["outcomes"] if not o.get("detail")))' "$REPORT")"

REPLAYED="$(j "$REPORT" byKind.replayed)"
assert_ge "at least one transaction was actually REPLAYED" 1 "$REPLAYED"
assert_eq "every replayed row reproduced the chain's published effects" "$REPLAYED" \
  "$(python3 -c 'import json,sys; print(sum(1 for o in json.load(open(sys.argv[1]))["outcomes"] if o["kind"]=="replayed" and o["reproduced"] is True))' "$REPORT")"
assert_eq "…and every replayed row's revert code matches the chain's" "$REPLAYED" \
  "$(python3 -c 'import json,sys; print(sum(1 for o in json.load(open(sys.argv[1]))["outcomes"] if o["kind"]=="replayed" and o["publishedRevertCode"]==o["replayedRevertCode"]))' "$REPORT")"
# NON-DEGENERACY: a replay that executed nothing would also "reproduce" a transaction that did
# nothing. Every replayed row must have run a real program.
assert_eq "…and every replayed row executed a real program" "$REPLAYED" \
  "$(python3 -c 'import json,sys; print(sum(1 for o in json.load(open(sys.argv[1]))["outcomes"] if o["kind"]=="replayed" and (o["instructionsExecuted"] or 0) >= 100))' "$REPORT")"
assert_eq "the driver exited 0, because every replayable transaction reproduced" "0" "$RC"

# THE RATE THE MILESTONE ASKS FOR, and where the time went.
assert_ge "a rate was recorded" 1 \
  "$(python3 -c 'import json,sys; print(1 if json.load(open(sys.argv[1]))["transactionsPerMinute"] > 0 else 0)' "$REPORT")"
assert_ge "…and the time is attributed to enumeration and replay" 1 \
  "$(python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["timing"]; print(1 if t["enumerateMs"]>0 and t["replayMs"]>0 else 0)' "$REPORT")"
note "window $FROM..$TO ($BLOCKS blocks), $TXS transaction(s), $REPLAYED replayed, $(j "$REPORT" transactionsPerMinute) tx/min"

# ---------------------------------------------------------------------------
echo "== 3. THE CONTROL: an unreplayable transaction is ISOLATED AND NAMED, and the range completes"
#
# A HEALTHY WINDOW CONTAINS NO FAILURES AT ALL — §2's rows are all `replayed` — so "isolation works"
# would be a sentence about code nothing had exercised. The control reaches BELOW the finalized tip,
# where the node has pruned every transaction body, and the assertion is not merely that those rows
# appear: it is that THE REPLAYABLE ROWS ABOVE THE TIP STILL REPLAY IN THE SAME RUN.
# ---------------------------------------------------------------------------
CRC="$(run_range "$CONTROL" --reach-below-finalized 40)"
assert_file "the control produced a report" "$CONTROL"

C_BLOCKS="$(j "$CONTROL" window.blocks)"
C_FIN="$(j "$CONTROL" window.finalized)"
C_FROM="$(j "$CONTROL" window.from)"
assert_true "the control's range reaches BELOW the finalized tip" test "$C_FROM" -le "$C_FIN"
assert_ge "…by the 40 blocks it was asked for" 40 "$(( C_FIN - C_FROM + 1 ))"
assert_true "…so it is a wider range than the subject's" test "$C_BLOCKS" -gt "$BLOCKS"

C_BELOW="$(j "$CONTROL" byKind.below-finalized)"
C_REPLAYED="$(j "$CONTROL" byKind.replayed)"
assert_ge "UNREPLAYABLE transactions appear, and are named below-finalized" 1 "$C_BELOW"
assert_eq "…every one of them naming WHY, in the row" "$C_BELOW" \
  "$(python3 -c 'import json,sys; print(sum(1 for o in json.load(open(sys.argv[1]))["outcomes"] if o["kind"]=="below-finalized" and "pruned" in o["detail"]))' "$CONTROL")"
# `.get`, NOT `[...]`. `JSON.stringify` OMITS a field whose value is `undefined` rather than
# emitting `null`, so a refused row has no `reproduced` KEY AT ALL — and reading it with `[...]`
# raised KeyError, which the shell turned into an empty comparison rather than a diagnosis. The
# claim is the same and it is now readable: a refused row must not carry a reproduction verdict.
assert_eq "…and none of them pretending to have been replayed" "0" \
  "$(python3 -c 'import json,sys; print(sum(1 for o in json.load(open(sys.argv[1]))["outcomes"] if o["kind"]=="below-finalized" and o.get("reproduced") is not None))' "$CONTROL")"
assert_eq "…nor an instruction count, nor a replayed revert code" "0" \
  "$(python3 -c 'import json,sys; print(sum(1 for o in json.load(open(sys.argv[1]))["outcomes"] if o["kind"]=="below-finalized" and (o.get("instructionsExecuted") is not None or o.get("replayedRevertCode") is not None)))' "$CONTROL")"

# THE ISOLATION ITSELF: the range COMPLETED and the good rows are still good.
assert_ge "THE RANGE STILL COMPLETED, with replayable rows beside the refused ones" 1 "$C_REPLAYED"
assert_eq "…and every one of those still reproduced" "$C_REPLAYED" \
  "$(python3 -c 'import json,sys; print(sum(1 for o in json.load(open(sys.argv[1]))["outcomes"] if o["kind"]=="replayed" and o["reproduced"] is True))' "$CONTROL")"
assert_eq "…so the driver still exits 0: a refused row is not a failed range" "0" "$CRC"
assert_true "the control's table is LONGER than the subject's, by the refused rows" \
  test "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["outcomes"]))' "$CONTROL")" -gt "$ROWS"

finish
