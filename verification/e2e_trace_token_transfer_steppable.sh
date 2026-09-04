#!/usr/bin/env bash
# e2e_trace_token_transfer_steppable — M25.
#
#   verification/e2e_trace_token_transfer_steppable.sh   (or: just verify-trace-token-steppable)
#
# ============================================================================================
# THE ENTRY, AND THE TWO PIECES IT WAS WAITING ON.
# ============================================================================================
#
# *"A token transfer produces a .ct recording that steps instruction by instruction with call
# frames, side effects and gas intact."* Most of that was already asserted elsewhere:
# `e2e_browser_downloads_ct_container_and_ct_print_parses` reads the container the BROWSER
# downloaded through the pinned reader, asserts two call frames, the positioned/unpositioned
# invariant and rung 1; `test_browser_steps_are_executed_not_mapped` asserts the steps are EXECUTED
# and not mapped, over two contexts, with the container's own opcode histogram read back.
#
# Re-measured by the closeout pass on 2026-08-31, exactly two pieces were missing:
#
#   1. **per-step `l2Gas` / `daGas` asserted in the TOKEN container** — "they are written, and only
#      a synthetic container's values are checked" (`test_ct_container_roundtrip_ct_print`'s);
#   2. **the sender's balance leaf read back after the transfer**, on that transfer's own world
#      state. The closeout pass added a NODE-side read-back through the contract's own
#      `balance_of_public` and recorded that it does not close this: that is a different world
#      state, in a different process, over a different transaction.
#
# §2 and §3 are the first. §4 is the second. Neither is new capability; both are readings nobody
# had taken.
#
# ============================================================================================
# AND THE GAS IS READ OUT OF THE CONTAINER, NOT OUT OF THE ARM'S REPORT.
# ============================================================================================
#
# `CAMPAIGN-BRIEF.md` records M29's finding as *"a number read from the producer's own report
# instead of from what the producer produced"*: the drained records and the recording's own
# `distinctOpcodes` are both UPSTREAM of the writer, and a fabrication at the write site left every
# behavioural assertion green. So §2 parses `ct-print --full` — the pinned reader, over the bytes
# the browser downloaded — and §3 compares those values against the DRAINED records one step at a
# time, which makes it a differential across the writer rather than two readings of one side.
#
# Run: just verify-trace-token-steppable

TEST_NAME="e2e_trace_token_transfer_steppable"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"

m27_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m27_require_arms
m24_require_readers

WORK="$M27_WORK/m25-steppable"
rm -rf "$WORK"; mkdir -p "$WORK"

# ---------------------------------------------------------------------------
echo "== 0. the container the BROWSER downloaded, and the transaction that produced it"
# ---------------------------------------------------------------------------

DL_PATH="$(m27_arm download downloaded.0.path)"
DL_SHA="$(m27_arm download downloaded.0.sha256)"
EVENTS="$(m27_arm download recording.events)"
REVERT="$(m27_arm publicOnly transfer.revertCode)"
ARTIFACT_NAME="$(m27_arm publicOnly transfer.artifactName)"

for pair in "container=$DL_PATH" "sha=$DL_SHA" "events=$EVENTS" "revertCode=$REVERT" "artifact=$ARTIFACT_NAME"; do
  [ "${pair#*=}" != "MISSING" ] || die "the browser arms are missing ${pair%%=*} — every comparison
             below would be about an absent field. Re-run: M27_ARMS_REFRESH=1 just verify-m27"
done
assert_file "the container the browser downloaded is on disk" "$DL_PATH"
assert_eq "…and this check re-hashes it to the same digest the page held" "$DL_SHA" \
  "$(sha256sum "$DL_PATH" | cut -d' ' -f1)"
assert_eq "the transaction was the Token contract's" "Token" "$ARTIFACT_NAME"
# THE TRANSACTION DID SOMETHING. M29's deepest finding: a demo that reverted at its first
# instruction reported `processed`, and every floor in the milestone was satisfied by it.
assert_eq "…and it did not revert, so the gas and the balances below are a transfer's" "0" "$REVERT"
assert_ge "…and it executed a real number of instructions" 100 "$EVENTS"

# ---------------------------------------------------------------------------
echo "== 1. the pinned reader renders it, and the parse is over the READER's output"
# ---------------------------------------------------------------------------

READ="$(m24_ct_print "$M24_READERS/ct-print" "$DL_PATH")"
RC="$(printf '%s\n' "$READ" | head -1)"
printf '%s\n' "$READ" | tail -n +2 > "$WORK/full.json"
assert_eq "ct-print --full exits 0 over the container" "0" "$RC"
assert_ge "…producing a rendering rather than a stub" 500 "$(grep -c . "$WORK/full.json" || true)"

# The drained records the producing arm reported, one per line, for §3's differential.
python3 - "$M27_ARMS" > "$WORK/drained.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for r in d["arms"]["publicOnly"]["transfer"]["executed"]["records"]:
    print(r)
PY
assert_ge "the arm's drained records were extracted" 100 "$(grep -c . "$WORK/drained.txt" || true)"

STEPS="$(python3 "$VERIFY_DIR/_m25_container_steps.py" "$WORK/full.json" "$WORK/drained.txt")"
st() { printf '%s\n' "$STEPS" | awk -F'\t' -v k="$1" '$1 == k { print $2; exit }'; }

# ARITHMETIC OVER A VALUE THE SUBJECT PRODUCED NEEDS A GUARD, AND THIS ONE WAS BOUGHT BY A MUTATION
# ARM. `lib.sh` runs with `set -u`, and bash's `$(( ))` treats a bare word as a VARIABLE — so
# `$(( 1000 + EMPTY ))` over a leaf the tree does not hold is an "unbound variable" error that KILLS
# the check. Measured: arm C2 reported `46 assertion(s), 4 failure(s)` where the check has 53, a
# seven-assertion shrink caught only because M22's abnormal-exit trap printed a summary at all. That
# is `CAMPAIGN-BRIEF.md`'s silent-shrink family arriving through an arithmetic expansion. `num`
# substitutes a sentinel for anything that is not a number, and every site that uses it asserts
# NUMERICNESS first, so a non-numeric reading is a named failure rather than a smaller check.
num() { case "${1:-}" in ('' | *[!0-9]*) printf '%s' "${2:--1}" ;; (*) printf '%s' "$1" ;; esac; }
assert_eq "the container parsed" "ok" "$(st PARSE)"

# THE PARSER CAN COME BACK EMPTY, shown rather than assumed. A 512-byte stub is not a container;
# `ct-print` refuses it and the parser reports zero steps — which is what makes the 516 below a
# measurement instead of a number the parser always produces.
head -c 512 "$DL_PATH" > "$WORK/stub.ct"
STUB_READ="$(m24_ct_print "$M24_READERS/ct-print" "$WORK/stub.ct")"
printf '%s\n' "$STUB_READ" | tail -n +2 > "$WORK/stub.json"
assert_false "the reader REFUSES a 512-byte stub" test "$(printf '%s\n' "$STUB_READ" | head -1)" -eq 0
assert_eq "…and the parser then reports no steps at all" "0" \
  "$(python3 "$VERIFY_DIR/_m25_container_steps.py" "$WORK/stub.json" | awk -F'\t' '$1=="STEPS"{print $2}')"

# ---------------------------------------------------------------------------
echo "== 2. PER-STEP GAS, IN THE TOKEN CONTAINER — the first missing piece"
# ---------------------------------------------------------------------------

assert_eq "the container's Step records account for every event the recording declares" \
  "$EVENTS" "$(st STEPS)"
# The five interned variable names, as a SET. A container that lost one would still render.
assert_eq "every step carries the five variables the writer declares" \
  "contextId,contractAddress,daGas,l2Gas,opcode" "$(st VARNAMES)"
assert_eq "…and not one step is missing any of them" "0" "$(st INCOMPLETE)"
assert_eq "…with the first incomplete step named rather than counted" "none" "$(st INCOMPLETE_FIRST)"
# THE ID MAPPING IS ASSERTED RATHER THAN TRUSTED. Variable ids are assigned by order of first
# appearance; an off-by-one attributes every value to the wrong name and produces plausible
# integers, which is what the first draft of the parser did.
assert_eq "the variable ids map to the names the writer interned, in the writer's own order" \
  "0=contractAddress,1=opcode,2=contextId,3=l2Gas,4=daGas" "$(st VARIDS)"
assert_eq "…and the gas values are integers rather than rendered text" "int" "$(st GASKIND)"

L2_FIRST="$(st L2_FIRST)"; L2_LAST="$(st L2_LAST)"
note "l2Gas $L2_FIRST → $L2_LAST over $(st STEPS) step(s); daGas $(st DA_FIRST) → $(st DA_LAST)"

assert_ge "the first step already carries a non-zero l2Gas" 1 "$L2_FIRST"
assert_true "…and the last is larger, so gas was consumed across the stream" \
  test "$L2_LAST" -gt "$L2_FIRST"
# CUMULATIVE AND STRICTLY INCREASING. `gasUsed` is a running total, so a step that cost nothing
# would show a zero delta and a stream that had been fabricated from a counter would show a
# CONSTANT one. Neither is the case, and both directions are asserted.
assert_eq "l2Gas never goes down or stands still — every instruction cost something" "0" \
  "$(st L2_DELTA_NONPOSITIVE)"
assert_eq "…so every step's reading is distinct" "$(st STEPS)" "$(st L2_DISTINCT)"
assert_ge "…and the per-step costs are not one number repeated" 5 "$(st L2_DELTA_DISTINCT)"
assert_ge "…the cheapest instruction costing at least a unit" 1 "$(st L2_DELTA_MIN)"
assert_true "the per-step cost readings are numbers" \
  test "$(num "$(st L2_DELTA_MIN)" no)" != "no" -a "$(num "$(st L2_DELTA_MAX)" no)" != "no"
assert_true "…and the dearest costs far more than the cheapest, which is what an opcode table means" \
  test "$(num "$(st L2_DELTA_MAX)" 0)" -gt "$(( $(num "$(st L2_DELTA_MIN)" 0) * 10 ))"

# DA GAS IS THE OTHER DIMENSION AND IT BEHAVES DIFFERENTLY, which is why asserting it separately is
# not a repetition: most instructions cost no DA gas at all, so the sequence is non-decreasing with
# zeroes in it — and it MOVES, which is what says the field is not a constant the writer emitted.
assert_eq "daGas never goes down" "0" "$(st DA_DELTA_NEGATIVE)"
assert_true "…and it does move, so it is not a constant" test "$(st DA_LAST)" -gt "$(st DA_FIRST)"
assert_ge "…taking more than one value across the stream" 2 "$(st DA_DISTINCT)"
assert_ge "…while most steps cost no DA gas at all, which is the opposite of l2Gas" 1 \
  "$(st DA_DELTA_ZERO)"

# THE CALL FRAMES, from the same parse: two enqueued calls, two contexts, and the two are not the
# same size — which is what says they are two frames rather than one counted twice.
assert_eq "the steps fall into exactly two AVM contexts" "2" "$(st CONTEXT_COUNT)"
assert_eq "…which is the number of enqueued calls the transaction carried" \
  "$(m27_arm publicOnly transfer.enqueuedPublicCalls)" "$(st CONTEXT_COUNT)"
# ONE CALL FRAME PER ENQUEUED CALL, STILL — with the Noir function frames subtracted back out.
#
# `callsOpened` counts both kinds since the recorder began deriving frames from the artifact's
# inline call-stack chains. Subtracting rather than re-baselining is what keeps this assertion about
# what it was always about; `test_noir_frames_open_at_function_boundaries` is where the Noir tree
# itself is asserted.
TT_NOIRF="$(m27_arm download recording.noirFramesOpened)"
note "call frames: $(m27_arm download recording.callsOpened) total, $TT_NOIRF of them Noir functions"
assert_eq "…and the recording opened one AVM-context Call frame for each" "2" \
  "$(( $(m27_arm download recording.callsOpened) - TT_NOIRF ))"
CTX_SIZES="$(st CONTEXTS)"
note "contexts: $CTX_SIZES"
assert_eq "…and the two frames are different sizes, so neither is the other counted twice" "2" \
  "$(printf '%s' "$CTX_SIZES" | tr ',' '\n' | cut -d: -f2 | sort -u | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
echo "== 3. THE GAS IN THE CONTAINER IS THE AVM'S, not the writer's"
# ---------------------------------------------------------------------------
#
# Every value above comes from the pinned reader. This section compares them, one step at a time,
# against the records the page DRAINED out of the module — the other side of the writer. A writer
# that fabricated a gas column would satisfy §2 and fail here.

assert_eq "the container and the drained stream have the same number of records" \
  "$(st STEPS)" "$(st DRAINED)"
assert_eq "…and every one of them was compared" "$(st STEPS)" "$(st PAIRED)"
assert_eq "…with contextId, opcode, l2Gas, daGas and contractAddress agreeing on every step" "0" \
  "$(st MISMATCH)"
# THE COMPARER CAN REPORT A DISAGREEMENT. Pairing each container step with the NEXT drained record
# must produce mismatches; a comparer that always answered "agree" would report zero for that too.
assert_ge "…and the same comparer reports disagreements when the pairing is shifted by one" 100 \
  "$(st MISMATCH_SHIFTED)"

# ---------------------------------------------------------------------------
echo "== 4. THE BALANCE LEAF, on this transfer's own world state — the second piece"
# ---------------------------------------------------------------------------
#
# The leaf, not a view call: `balance_of_public` would be a second enqueued call and therefore a
# second thing that can fail, while the leaf is what the transfer moved. Addressed by upstream's own
# `computePublicDataTreeLeafSlot` over `deriveStorageSlotInMap`, read through `readPublicDataLeaf`,
# which compares the decoded slot against the requested one so a misspelled key cannot read empty.

SEEDED="$(m27_arm publicOnly transfer.balances.seeded)"
MOVED="$(m27_arm publicOnly transfer.balances.transferred)"
SENDER_LEAF="$(m27_arm publicOnly transfer.balances.senderLeaf)"
RECEIVER_LEAF="$(m27_arm publicOnly transfer.balances.receiverLeaf)"
BEFORE_S="$(m27_arm publicOnly transfer.balances.before.sender)"
BEFORE_R="$(m27_arm publicOnly transfer.balances.before.receiver)"
AFTER_S="$(m27_arm publicOnly transfer.balances.after.sender)"
AFTER_R="$(m27_arm publicOnly transfer.balances.after.receiver)"

ABSENT=""
for pair in "seeded=$SEEDED" "transferred=$MOVED" "senderLeaf=$SENDER_LEAF" \
            "receiverLeaf=$RECEIVER_LEAF" "before.sender=$BEFORE_S" "before.receiver=$BEFORE_R" \
            "after.sender=$AFTER_S" "after.receiver=$AFTER_R"; do
  [ "${pair#*=}" = "MISSING" ] && ABSENT="$ABSENT ${pair%%=*}"
done
[ -z "$ABSENT" ] || die "the arm reports no balance read-back:$ABSENT
             The page's own driver writes it; re-run with M27_ARMS_REFRESH=1."
assert_eq "the arm carries every balance field this section reads" "" "$ABSENT"
note "sender leaf $BEFORE_S → $AFTER_S; receiver leaf $BEFORE_R → $AFTER_R (moved $MOVED)"

assert_prefix "the sender's balance leaf is a field value" "0x" "$SENDER_LEAF"
assert_true "…and the receiver's is a different leaf" test "$SENDER_LEAF" != "$RECEIVER_LEAF"
assert_true "the amounts are the demo's own and not zero" test "$MOVED" -gt 0
assert_true "…with less transferred than seeded, so the sender keeps something" \
  test "$MOVED" -lt "$SEEDED"

assert_eq "BEFORE the transfer the sender's leaf holds exactly what was seeded" "$SEEDED" "$BEFORE_S"
# THE RECIPIENT'S LEAF IS NOT SEEDED, and that is what makes its after-reading evidence of arrival
# rather than of the seeding. `EMPTY` and not `MISSING`: the driver maps an absent leaf to a value
# the reporter cannot produce, so "the tree has no such leaf" and "the field is not in the report"
# are two different words.
assert_eq "…and the receiver has no leaf at all" "EMPTY" "$BEFORE_R"
assert_true "both after-readings are numbers, so the arithmetic below is over values and not words" \
  test "$(num "$AFTER_S" no)" != "no"
assert_eq "AFTER the transfer the sender's leaf holds seeded minus transferred" \
  "$(( $(num "$SEEDED" 0) - $(num "$MOVED" 0) ))" "$AFTER_S"
assert_eq "…and the receiver's holds exactly the transferred amount" "$MOVED" "$AFTER_R"
assert_true "…so the receiver's leaf came into existence, which the before-reading is what shows" \
  test "$AFTER_R" != "EMPTY"
# THE CONSERVATION LAW. Two leaves and one amount: a runtime that credited without debiting, or
# debited twice, satisfies neither of the two assertions above on its own but is caught by the sum.
assert_true "…and so is the receiver's, which is what makes the conservation law an addition" \
  test "$(num "$AFTER_R" no)" != "no"
assert_eq "…and the two leaves together still hold what was seeded" "$SEEDED" \
  "$(( $(num "$AFTER_S" 0) + $(num "$AFTER_R" 0) ))"
assert_true "…while the sender's reading actually moved" test "$AFTER_S" != "$BEFORE_S"

# ---------------------------------------------------------------------------
echo "== 5. …and it is a recording, at SOURCE level, of what the page produced"
# ---------------------------------------------------------------------------

POS="$(m27_arm download recording.stepsPositioned)"
UNPOS="$(m27_arm download recording.stepsUnpositioned)"
assert_eq "positioned and unpositioned account for every step" "$EVENTS" \
  "$(( $(num "$POS" 0) + $(num "$UNPOS" 0) ))"
assert_ge "…and a real number of them carry a source position" 1 "$POS"
assert_eq "the artifact itself earns rung 1, the source rung" "1" "$(m27_arm download recording.rung)"
assert_true "the reader names the AVM dispatch macro's own source" \
  str_has_sub "$(cat "$WORK/full.json")" 'macros/dispatch.nr'
assert_true "…and the state variable the transfer writes through" \
  str_has_sub "$(cat "$WORK/full.json")" 'public_mutable.nr'

m27_finish
