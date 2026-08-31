#!/usr/bin/env bash
# test_unserved_private_oracle_refuses_by_name — an oracle the executor cannot serve refuses NAMING
# ITSELF, and the step loop stops rather than continuing over a fabricated value.
#
# THE RULE THIS CHECK EXISTS FOR, in one sentence: **a fabricated note or nullifier produces a
# transaction that looks valid**, and this is the milestone where violating that would be least
# visible — a replaying executor has an obvious wrong answer available for every call it cannot
# make, namely "no fields", and for a circuit expecting no fields that answer SUCCEEDS.
#
# THE CONTROL IS THE FIRST THING, not the last: a SERVED oracle answers and the loop proceeds. The
# guard is measured against a run that does the opposite, so "it refused" is not satisfied by an
# executor that refuses everything.
#
# THE FOUR ARMS, and each is a mutation of the TAPE rather than of the executor, so what is under
# test is the shipped refusal path:
#
#   replay     the whole tape of a frame that completed. Nothing refuses.  <- the control
#   truncate   the last entry dropped. The frame runs out of answers.
#   refuseAll  the tape emptied. The FIRST oracle refuses.
#   transfer   a recording that STOPPED at an oracle M35 does not serve. The tape carries that call
#              with no answer, and the executor must refuse rather than pad.
#
# Run: just verify-m38-refusals

TEST_NAME="test_unserved_private_oracle_refuses_by_name"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m38_private_trace.sh"
trap m38_summary_on_abnormal_exit EXIT

m38_require_arms

echo "== 1. THE CONTROL: A FULLY-SERVED FRAME REFUSES NOTHING AND RUNS TO THE END"
R_STEPS="$(m38_arm replay.steps)"
R_REFUSED="$(m38_arm replay.refusedOracles)"
R_RESULT="$(m38_arm replay.traceResult)"
R_LEDGER="$(m38_arm replay.oracleLedger)"
R_TAPE="$(m38_arm replay.tapeEntriesRecorded)"
m38_absent replaySteps="$R_STEPS" replayRefused="$R_REFUSED" replayResult="$R_RESULT" \
  replayLedger="$R_LEDGER" replayTape="$R_TAPE"
assert_eq "the fully-served arm refuses nothing" "[]" "$R_REFUSED"
assert_eq "and the recorder reports no error" "ok" "$R_RESULT"
assert_ge "and it produced a real number of steps" 10 "$(m38_num "$R_STEPS" 'replay steps')"
REPLAYED="$(printf '%s' "$R_LEDGER" | python3 -c '
import json, sys
print(sum(1 for e in json.load(sys.stdin) if e["outcome"] == "replayed"))')"
assert_eq "every recorded call was replayed" "$(m38_num "$R_TAPE" 'tape entries')" \
  "$(m38_num "$REPLAYED" 'replayed')"

echo "== 2. AN EMPTY TAPE: THE FIRST ORACLE REFUSES, BY NAME"
A_STEPS="$(m38_arm refuseAll.steps)"
A_REFUSED="$(m38_arm refuseAll.refusedOracles)"
A_LEDGER="$(m38_arm refuseAll.oracleLedger)"
m38_absent refuseAllSteps="$A_STEPS" refuseAllRefused="$A_REFUSED" refuseAllLedger="$A_LEDGER"
assert_eq "exactly one oracle was refused" "1" \
  "$(printf '%s' "$A_REFUSED" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
assert_eq "and it is the first oracle every #[aztec] contract calls" \
  '["aztec_misc_assertCompatibleOracleVersion"]' "$A_REFUSED"
assert_eq "nothing was replayed" "0" \
  "$(printf '%s' "$A_LEDGER" | python3 -c '
import json, sys
print(sum(1 for e in json.load(sys.stdin) if e["outcome"] == "replayed"))')"
# THE REFUSAL'S REASON NAMES THE COUNTS, not just the oracle. A refusal that says only "no" sends
# the reader to guess whether the tape was empty, wrong or exhausted.
A_REASON="$(printf '%s' "$A_LEDGER" | python3 -c '
import json, sys
print(next((e["reason"] for e in json.load(sys.stdin) if e["outcome"] == "refused"), "MISSING"))')"
m38_absent refuseAllReason="$A_REASON"
assert_true "and it says the tape was empty" str_has_sub "$A_REASON" 'tape holds 0 call(s)'

echo "== 3. A TRUNCATED TAPE: THE FRAME RUNS OUT PART-WAY, AND THE LOOP STOPS THERE"
T_STEPS="$(m38_arm truncate.steps)"
T_REFUSED="$(m38_arm truncate.refusedOracles)"
T_LEDGER="$(m38_arm truncate.oracleLedger)"
m38_absent truncateSteps="$T_STEPS" truncateRefused="$T_REFUSED" truncateLedger="$T_LEDGER"
assert_eq "the refusal names the oracle the tape ran out at" \
  '["aztec_prv_isExecutionInRevertiblePhase"]' "$T_REFUSED"
assert_eq "three of the four calls were replayed first" "3" \
  "$(printf '%s' "$T_LEDGER" | python3 -c '
import json, sys
print(sum(1 for e in json.load(sys.stdin) if e["outcome"] == "replayed"))')"

# THE LADDER, WHICH IS THE MEASUREMENT RATHER THAN THE ARMS' LABELS. Fewer answers, fewer steps —
# strictly, and in the order the tapes shrink. A step count alone says nothing; three counts in a
# known order say the loop STOPPED at the refusal rather than continuing past it.
A_N="$(m38_num "$A_STEPS" 'refuseAll steps')"
T_N="$(m38_num "$T_STEPS" 'truncate steps')"
R_N="$(m38_num "$R_STEPS" 'replay steps')"
assert_true "an empty tape stops sooner than a truncated one" test "$A_N" -lt "$T_N"
assert_true "and a truncated one sooner than the whole tape" test "$T_N" -lt "$R_N"
# AND IT STOPPED RATHER THAN NEVER STARTING. The steps before the refusal are recorded, which is
# what distinguishes "the loop halted here" from "the loop never ran".
assert_ge "even the empty-tape arm recorded the steps it took BEFORE the refusal" 1 "$A_N"

echo "== 4. THE ARM THAT MATTERS: A CALL THE RECORDING ITSELF DID NOT ANSWER"
# `Token.transfer`'s recording STOPS at `aztec_utl_getNotes`. That call is ON the tape — it was made
# — with empty `outputs`, which is indistinguishable from a void oracle by the tape alone. The
# executor is told how many calls the recording ANSWERED and refuses everything past that prefix.
# Without this arm the `served_calls` gate is a fail-safe branch nothing executes, which is a
# property of dead code.
X_REFUSED="$(m38_arm transfer.refusedOracles)"
X_LEDGER="$(m38_arm transfer.oracleLedger)"
X_TAPE="$(m38_arm transfer.tapeEntriesRecorded)"
X_SERVED="$(m38_arm transfer.servedCallsInRecording)"
X_STEPS="$(m38_arm transfer.steps)"
m38_absent transferRefused="$X_REFUSED" transferLedger="$X_LEDGER" transferTape="$X_TAPE" \
  transferServed="$X_SERVED" transferSteps="$X_STEPS"
assert_eq "the tape carries one more call than the recording answered" \
  "$(( $(m38_num "$X_SERVED" 'transfer served') + 1 ))" "$(m38_num "$X_TAPE" 'transfer tape')"
assert_eq "and the executor refuses exactly that one, by name" '["aztec_utl_getNotes"]' "$X_REFUSED"
X_REASON="$(printf '%s' "$X_LEDGER" | python3 -c '
import json, sys
print(next((e["reason"] for e in json.load(sys.stdin) if e["outcome"] == "refused"), "MISSING"))')"
m38_absent transferReason="$X_REASON"
assert_true "naming the served prefix rather than the tape length" \
  str_has_sub "$X_REASON" "the recording answered $X_SERVED call(s)"

# THE SAME NAME ON BOTH SIDES OF A BOUNDARY THAT CANNOT BE CROSSED AT RUN TIME. M35's browser run
# stopped at this oracle; the Rust replay stops at it too. Read out of the M35 report rather than
# typed, so the two are compared instead of one being asserted twice.
M35_STOP="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["arms"]["private"]["report"]["refuses"].get("stoppedAtOracle", "MISSING"))' \
  "$M38_TAPE_SOURCE")"
m38_absent m35Stop="$M35_STOP"
assert_eq "the browser run and the native replay stop at the SAME oracle" \
  "[\"$M35_STOP\"]" "$X_REFUSED"
assert_ge "and the replay got a real distance before it did" 20 "$(m38_num "$X_STEPS" 'transfer steps')"

echo "== 5. THE EXECUTOR IMPLEMENTS NO ORACLE, WHICH IS WHAT MAKES THE ANSWERS M35'S"
# A replaying executor that had grown a special case for one oracle would satisfy every assertion
# above while no longer replaying. The scan is over the probe's own source, comment-stripped, so a
# name in the header does not count as an implementation — this campaign's "a citation is the
# opposite of a dependency", which it has now got wrong in both directions.
CODE="$(python3 - "$M38_PROBE_SRC" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf8').read()
out, i, n, quote = [], 0, len(src), None
while i < n:
    c = src[i]
    if quote:
        out.append(c)
        if c == '\\' and i + 1 < n:
            out.append(src[i+1]); i += 2; continue
        if c == quote: quote = None
        i += 1; continue
    if c in '"\'':
        quote = c; out.append(c); i += 1; continue
    if c == '/' and i + 1 < n and src[i+1] == '/':
        while i < n and src[i] != '\n': i += 1
        continue
    out.append(c); i += 1
print(''.join(out))
PY
)"
assert_ge "the stripper left code behind" 4000 "$(m38_num "${#CODE}" 'stripped probe size')"
assert_true "and it removed the header prose" \
  test "${#CODE}" -lt "$(wc -c < "$M38_PROBE_SRC")"
for oracle in getContractInstance setCapsule notifyCreatedNote getNotes siloNullifier poseidon2; do
  assert_false "the probe's CODE does not implement $oracle" str_has_sub "$CODE" "$oracle"
done
# THE PAIRED POSITIVE. A scan whose needles all answer "absent" is equally satisfied by a scanner
# that cannot see anything; this name IS in the code and must be found.
assert_true "while the scanner can find what IS there" str_has_sub "$CODE" 'TapeExecutor'

m38_finish
