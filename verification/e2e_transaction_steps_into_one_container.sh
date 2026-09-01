#!/usr/bin/env bash
# e2e_transaction_steps_into_one_container — a TRANSACTION's private half, both frames, in ONE `.ct`
# container the pinned reader parses, with the callee's frame nested inside the caller's and an
# explicit join record.
#
# ===========================================================================================
# WHAT MAKES THIS AN e2e RATHER THAN A COUNT
# ===========================================================================================
#
# Every figure is read back out of the CONTAINER through the pinned `ct-print`, never out of the
# probe's own report — M29's rule, earned by a check that read an opcode histogram out of the
# producer's report while the writer wrote fabricated opcodes. The probe's report is used only where
# the container cannot answer: how many opcodes the ACVM stepped, which is a fact about the
# execution rather than about the recording.
#
# THE DISCRIMINATORS, each here because its absence is a shape this campaign has shipped:
#
#   * THE STEP COUNT IS AN IDENTITY, NOT A FLOOR. `container == probe + frames` — `TraceSink::start`
#     emits one entry step per traced circuit, so a two-frame container carries two. M38 asserted
#     `probe + 1` over one frame; this is the same identity with the constant derived rather than
#     retyped, which is what says the extra steps are the entry steps and not two the recorder lost.
#   * THE NESTING IS THE FRAME LIST'S AND NOT THE WRITER'S. `parentOnly` runs the SAME frame with
#     the SAME tape and no child in the list, and its container must carry ZERO calls. Without that
#     arm, "one call and one return" is a number with nothing to compare it against and a writer
#     that emitted a Call per frame regardless would satisfy it.
#   * THE CHILD'S STEPS ARE INSIDE THE CALL AND THE PARENT'S ARE NOT. Asserted on the reader's own
#     `entry_step` / `exit_step` indices rather than on the order names appear in a listing — M26's
#     rule, which it earned because a container in which every frame is a sibling satisfies a
#     name-order assertion completely.
#   * THE SECOND FRAME ADDS. The transaction's container has strictly more steps, more distinct
#     positions and more interned paths than the one-frame control, so the step stream is not a
#     constant the writer produces whatever it is given.
#   * THE JOIN RECORD IS RECORDED, NOT INFERRED, AND ITS BYTES ARE THE GRAMMAR. The record read out
#     of the container is compared BYTE FOR BYTE against what `orchestration/src/trace_join.ts`
#     renders for the same four fields — not against a copy of itself — and the single-frame control
#     carries no record at all.
#   * THE REPLAY GUESSED NOTHING. A tape entry whose wire kind was not recorded is replayed by a
#     length guess, and that guess is what halted the first two-frame run. The probe reports when it
#     had to guess and this asserts the count is zero.
#
# Run: just verify-m39-container

TEST_NAME="e2e_transaction_steps_into_one_container"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# `lib_m23_chain.sh` first — `lib_m27_browser.sh` builds its export list from `M23_REQUIRED_EXPORTS`
# and dies on an unbound variable without it, before a single assertion.
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m38_private_trace.sh"
. "$VERIFY_DIR/lib_m39_nested.sh"
m39_summary_on_abnormal_exit

m39_require_trace_arms

CT_PRINT="$(m38_ct_print)"
[ -x "$CT_PRINT" ] || die "no pinned ct-print at $CT_PRINT.
             Remedy: verification/build_ct_print.sh (it needs the workspace dev shell for nim)"

TX_CT="$(m39_trace transaction.container)"
ONE_CT="$(m39_trace parentOnly.container)"
m38_absent transactionContainer="$TX_CT" parentOnlyContainer="$ONE_CT"
[ -s "$TX_CT" ] || die "no container at $TX_CT"
[ -s "$ONE_CT" ] || die "no container at $ONE_CT"

echo "== 1. BOTH CONTAINERS ARE PARSED BY THE PINNED READER, AND BOTH DECLARE COLUMNS"
for arm in transaction parentOnly; do
  ct="$(m39_trace "$arm.container")"
  assert_true "the $arm container is readable by the pinned reader" \
    test "$(m39_container "$ct" steps)" != "UNREADABLE"
  assert_eq "and it declares column-aware steps" "true" "$(m39_container "$ct" columnAware)"
done
# THE READER CAN COME BACK EMPTY, so a positive step count is a measurement by an instrument that
# has been seen to produce zero. A 512-byte stub, which is M38's own control and its reason: a
# HALVED container still parses, because a `.ct` is a directory of independent streams.
#
# **AND IT ANSWERS ZERO RATHER THAN REFUSING, WHICH IS THE OPPOSITE OF WHAT THE FIRST DRAFT OF THIS
# LINE ASSERTED.** M38's own check records exactly that — *"the fact that it does NOT refuse one is
# recorded rather than assumed, because the first draft of that control asserted the opposite"* —
# and this file's first draft asserted the opposite again, one milestone later, and was caught by
# running it. Zero is the stronger control anyway: an instrument that refuses says nothing about
# what it counts, and one that counts zero over a stub is one whose 60 is a reading.
STUB="$(mktemp -d)/stub.ct"
head -c 512 "$TX_CT" > "$STUB"
assert_eq "the same reader answers ZERO steps over a 512-byte stub" "0" "$(m39_container "$STUB" steps)"
assert_true "and it does not refuse it, which is a property of this format rather than a guess" \
  test "$(m39_container "$STUB" steps)" != "UNREADABLE"
rm -rf "$(dirname "$STUB")"

echo "== 2. THE STEP COUNT IS AN IDENTITY: container = recorder + one entry step PER FRAME"
for arm in transaction parentOnly; do
  ct="$(m39_trace "$arm.container")"
  probe_steps="$(m39_trace "$arm.steps")"
  frames="$(m39_trace "$arm.frameCount")"
  container_steps="$(m39_container "$ct" steps)"
  m38_require_num "${arm}ProbeSteps=$probe_steps" "${arm}Frames=$frames" "${arm}ContainerSteps=$container_steps"
  assert_eq "$arm: the container carries the recorder's steps plus one entry step per frame" \
    "$(( probe_steps + frames ))" "$container_steps"
done
# AND THE PER-FRAME COUNTS SUM TO THE WHOLE, which a total alone cannot say: a two-frame report
# whose second frame recorded nothing has the same total as a one-frame one that recorded more.
F0="$(m39_trace transaction.frames.0.steps)"
F1="$(m39_trace transaction.frames.1.steps)"
TX_PROBE="$(m39_trace transaction.steps)"
m38_require_num f0="$F0" f1="$F1" txProbe="$TX_PROBE"
assert_eq "the two frames' step counts sum to the recorder's total" "$TX_PROBE" "$(( F0 + F1 ))"
assert_ge "and neither frame is empty — the first" 1 "$F0"
assert_ge "nor the second" 1 "$F1"

echo "== 3. EVERY STEP CARRIES A COLUMN, IN BOTH CONTAINERS"
for arm in transaction parentOnly; do
  ct="$(m39_trace "$arm.container")"
  s="$(m39_container "$ct" steps)"
  c="$(m39_container "$ct" withColumn)"
  m38_require_num "${arm}Steps=$s" "${arm}Cols=$c"
  assert_eq "$arm: every step in the container carries a column" "$s" "$c"
done

echo "== 4. THE NESTING IS THE FRAME LIST'S, AND THE ONE-FRAME ARM IS WHAT SAYS SO"
TX_ENTRIES="$(m39_container "$TX_CT" callEntries)"
TX_EXITS="$(m39_container "$TX_CT" callExits)"
ONE_ENTRIES="$(m39_container "$ONE_CT" callEntries)"
ONE_EXITS="$(m39_container "$ONE_CT" callExits)"
m38_require_num txEntries="$TX_ENTRIES" txExits="$TX_EXITS" oneEntries="$ONE_ENTRIES" oneExits="$ONE_EXITS"
assert_eq "the transaction's container opens one frame" "1" "$TX_ENTRIES"
assert_eq "and closes it" "1" "$TX_EXITS"
assert_eq "the one-frame control opens none" "0" "$ONE_ENTRIES"
assert_eq "and closes none" "0" "$ONE_EXITS"
assert_eq "the frame the transaction opens is the CALLEE" \
  "$(m39_trace transaction.frames.1.function)" "$(m39_container "$TX_CT" callNames)"
# THE FRAME CARRIES THE CALLEE'S CONTRACT ADDRESS AS ITS ONE ARGUMENT, which is M26's rule for the
# public half and its reason: it is what makes a frame attributable without stepping into it. The
# expected value is the CHILD's address from the browser run, so a frame labelled with the parent's
# would fail even though both are real addresses.
CHILD_ADDR="$(m39_arm nested.report.child.address)"
m38_absent childAddress="$CHILD_ADDR"
assert_eq "and it carries the callee's contract address as its one call argument" \
  "contractAddress=$CHILD_ADDR" "$(m39_container "$TX_CT" callArgs)"
assert_true "which is not the caller's" \
  test "$CHILD_ADDR" != "$(m39_arm nested.report.parent.address)"

echo "== 5. THE CHILD'S STEPS ARE INSIDE THE CALL AND THE PARENT'S ARE NOT"
ENTRY_STEP="$(m39_container "$TX_CT" callEntryStep)"
EXIT_STEP="$(m39_container "$TX_CT" callExitStep)"
TX_STEPS="$(m39_container "$TX_CT" steps)"
m38_require_num entryStep="$ENTRY_STEP" exitStep="$EXIT_STEP" txSteps="$TX_STEPS"
assert_true "the frame opens after the caller has stepped" test "$ENTRY_STEP" -gt 0
assert_true "and closes after it opens" test "$EXIT_STEP" -gt "$ENTRY_STEP"
# THE SPAN IS THE CALLEE'S OWN STEP COUNT PLUS ITS ENTRY STEP, computed from the frame report rather
# than from the span itself — two producers for one number. A frame that opened and closed around
# nothing, or around the caller's steps, fails here while satisfying every count above.
assert_eq "and the span it brackets is exactly the callee's steps plus its entry step" \
  "$(( F1 + 1 ))" "$(( EXIT_STEP - ENTRY_STEP + 1 ))"
assert_eq "so the steps before the frame are the caller's own" "$(( F0 + 1 ))" "$ENTRY_STEP"
assert_eq "and the frame closes on the container's last step" "$(( TX_STEPS - 1 ))" "$EXIT_STEP"

echo "== 6. THE SECOND FRAME ADDS — THE STREAM IS NOT A CONSTANT"
for field in steps paths; do
  a="$(m39_container "$TX_CT" "$field")"
  b="$(m39_container "$ONE_CT" "$field")"
  m38_require_num "tx_$field=$a" "one_$field=$b"
  assert_true "the transaction's container has strictly more $field" test "$a" -gt "$b" ;
done
# ===========================================================================================
# AND THE POSITION SET IS **THE SAME**, WHICH IS A MEASUREMENT AND NOT A FAILURE TO GROW.
# ===========================================================================================
#
# The first draft of this section asserted "strictly more distinct lines" and it is FALSE: both
# containers reach 22 distinct `(path, line)` pairs over the same 9 files, and the two SETS are
# equal. Measured rather than argued — `Child.value` is `input + chain_id + version`, so the callee's
# own arithmetic produces no positioned step of its own, and every position it visits is one the
# `#[aztec]` preamble already took the caller through.
#
# **So in this container the two frames are distinguishable BY FRAME and by nothing else.** That is
# `JOIN-SHAPE.md` §4's sentence — *"a private-half step and a public-half step are distinguishable by
# frame"* — arriving one level down, on two PRIVATE frames, and it is the reason the Call and Return
# are not decoration: without them a reader has 60 steps over 22 positions and no way to tell which
# frame it is in. Asserted as an EQUALITY of the sets so that a future callee which DOES add a
# position moves this line rather than passing it silently.
TX_LINES="$(m39_container "$TX_CT" distinctLines)"
ONE_LINES="$(m39_container "$ONE_CT" distinctLines)"
TX_FILES="$(m39_container "$TX_CT" distinctPaths)"
ONE_FILES="$(m39_container "$ONE_CT" distinctPaths)"
m38_require_num txLines="$TX_LINES" oneLines="$ONE_LINES" txFiles="$TX_FILES" oneFiles="$ONE_FILES"
assert_eq "the callee visits no source position the caller does not" "$ONE_LINES" "$TX_LINES"
assert_eq "nor any source file" "$ONE_FILES" "$TX_FILES"
# THE NON-DEGENERACY, because "the two sets are equal" is also true of two EMPTY ones.
assert_ge "and the shared position set is not empty" 10 "$TX_LINES"
assert_ge "across several files" 5 "$TX_FILES"
assert_true "and the callee's own opcodes were stepped, not skipped" \
  test "$(m38_num "$(m39_trace transaction.frames.1.opcodesStepped)" 'callee opcodes')" -gt 100

echo "== 7. THE JOIN RECORD IS RECORDED, AND ITS BYTES ARE THE TYPESCRIPT GRAMMAR'S"
TX_JOIN="$(m39_container "$TX_CT" join)"
TX_JOIN_N="$(m39_container "$TX_CT" joinCount)"
ONE_JOIN_N="$(m39_container "$ONE_CT" joinCount)"
m38_absent txJoin="$TX_JOIN"
m38_require_num txJoinCount="$TX_JOIN_N" oneJoinCount="$ONE_JOIN_N"
assert_eq "the transaction's container carries exactly one join record" "1" "$TX_JOIN_N"
assert_eq "and the one-frame control carries none" "0" "$ONE_JOIN_N"
JOIN_ID="$(m39_trace transaction.join.id)"
JOIN_HALF="$(m39_trace transaction.join.half)"
JOIN_HALVES="$(m39_trace transaction.join.halves)"
JOIN_ARM="$(m39_trace transaction.join.arm)"
m38_absent joinId="$JOIN_ID" joinHalf="$JOIN_HALF" joinHalves="$JOIN_HALVES" joinArm="$JOIN_ARM"
# THE GRAMMAR IS RENDERED BY THE TYPESCRIPT AND COMPARED AS BYTES, not read back out of a document
# and not compared against a copy of itself. `test_join_fallback_two_recordings` compares the Rust
# probe's rendering against the same function for the same reason.
TS_JOIN="$( cd "$REPO_ROOT/orchestration" && node --input-type=module -e "
import { joinRecord, formatJoinRecord } from './src/trace_join.ts';
process.stdout.write(formatJoinRecord(joinRecord(process.argv[1], process.argv[2], Number(process.argv[3]), process.argv[4])));
" -- "$JOIN_ID" "$JOIN_HALF" "$JOIN_HALVES" "$JOIN_ARM" 2>/dev/null | tail -1 )"
m38_absent tsJoin="$TS_JOIN"
assert_eq "the record in the container is byte-identical to the TypeScript grammar's" "$TS_JOIN" "$TX_JOIN"
assert_true "it declares the PRIVATE half of a TWO-half split" \
  str_has_sub "$TX_JOIN" "half=private halves=2 arm=split"
# THE IDENTITY IS THE TRANSACTION'S OWN, not a minted one: a random id would make the join a fact
# about when the driver ran, and two runs of one transaction would not agree.
assert_eq "and the join identity is the transaction's own argsHash" \
  "$(m39_arm nested.report.run.publicInputs.argsHash)" "$JOIN_ID"
# AND `halves` IS WHY THE GRAMMAR HAS IT: a reader handed one half of a two-half join must be able
# to tell it from a whole recording. `joinRecordings` is asserted to REFUSE the container on its
# own, naming the ground, rather than joining a half to nothing.
REFUSAL="$( cd "$REPO_ROOT/orchestration" && node --input-type=module -e "
import { joinRecordings, parseJoinRecord } from './src/trace_join.ts';
const record = parseJoinRecord(process.argv[1]);
try {
  joinRecordings([{ label: 'private', container: new Uint8Array(0), record }]);
  process.stdout.write('JOINED');
} catch (e) { process.stdout.write(String(e.ground ?? e.message)); }
" -- "$TX_JOIN" 2>/dev/null | tail -1 )"
m38_absent refusal="$REFUSAL"
assert_eq "one half of a declared two-half join is refused on the count" "count-mismatch" "$REFUSAL"

echo "== 8. THE REPLAY GUESSED NOTHING, AND THE TAPE IS WHAT SAYS SO"
GUESSED="$(m39_trace transaction.oracleLedger | python3 -c '
import json, sys
d = sys.stdin.read().strip()
if not d.startswith("["):
    print("MISSING"); raise SystemExit(0)
print(sum(1 for e in json.loads(d) if "GUESSED" in e.get("reason", "")))')"
m38_require_num guessed="$GUESSED"
assert_eq "no output slot's wire kind was guessed from its length" "0" "$GUESSED"
# THE GUESS PATH STILL EXISTS AND IS STILL REACHABLE — the assertion above is about this tape, not
# about a code path that was deleted. A tape recorded before the kinds were written down replays
# through the fallback, and the probe says so per call rather than silently.
# THE TAPE ITSELF IS ASKED WHETHER EVERY SLOT CARRIES A KIND, rather than the source being grepped
# for the field's declaration. Three assertions here were `str_has_sub` over the very files that
# declare `inputKinds`, `outputKinds` and the fallback's diagnostic — names grepped in the files that
# declare those names, which cannot be less than true and which sit beside a real measurement
# reading as if they were one.
COVERAGE="$(m39_arm nested.report.run.tape | python3 -c '
import json, sys
d = sys.stdin.read().strip()
if not d.startswith("["):
    print("MISSING"); raise SystemExit(0)
slots = kinds = 0
for e in json.loads(d):
    for side in ("inputs", "outputs"):
        slots += len(e.get(side, []))
        kinds += len(e.get(side[:-1] + "Kinds", []))
print("%d %d" % (slots, kinds))')"
m38_absent kindCoverage="$COVERAGE"
TAPE_SLOTS="${COVERAGE%% *}"; TAPE_KINDS="${COVERAGE##* }"
m38_require_num tapeSlots="$TAPE_SLOTS" tapeKinds="$TAPE_KINDS"
assert_ge "the tape carries slots at all, so the coverage is over something" 10 "$TAPE_SLOTS"
assert_eq "and every one of them carries a recorded wire kind" "$TAPE_SLOTS" "$TAPE_KINDS"
# THE FALLBACK IS EXERCISED BY THE MUTATION MATRIX AND NOT BY THIS CHECK, and saying so is the point:
# `m39-mutations.sh` arm N5 makes the probe ignore the recorded kind, and the guessed count above
# goes 0 -> 5 with six document rows behind it. A check that greps for the fallback's diagnostic
# proves only that the diagnostic is spelled that way.
KINDS_SEEN="$(m39_arm nested.report.run.tape | python3 -c '
import json, sys
d = sys.stdin.read().strip()
if not d.startswith("["):
    print("MISSING"); raise SystemExit(0)
kinds = {k for e in json.loads(d) for k in list(e.get("outputKinds", [])) + list(e.get("inputKinds", []))}
print(",".join(sorted(kinds)) or "NONE")')"
m38_absent kindsSeen="$KINDS_SEEN"
# BOTH SPELLINGS APPEAR ON THIS TRANSACTION'S TAPE, which is what makes the distinction a
# measurement rather than a field nobody exercises: if every slot were a `single`, recording the
# kind and guessing by length would agree everywhere and the fix would be untested.
assert_eq "and this transaction's tape carries both wire kinds" "array,single" "$KINDS_SEEN"

echo "== 9. THE TRACE COMPLETED, AND THE ORACLE LEDGER IS BOTH FRAMES' IN ORDER"
assert_eq "no frame reported a trace error" "[]" "$(m39_trace transaction.traceErrors)"
assert_eq "and the writer finished the container" "ok" "$(m39_trace transaction.finish)"
assert_eq "the trace result is ok across every frame" "ok" "$(m39_trace transaction.traceResult)"
LEDGER_LEN="$(m39_trace transaction.oracleLedger | python3 -c 'import json,sys; d=sys.stdin.read().strip(); print(len(json.loads(d)) if d.startswith("[") else "MISSING")')"
PARENT_CALLS="$(m39_trace_top transaction.parentOracleCalls)"
CHILD_CALLS="$(m39_trace_top transaction.childOracleCalls)"
m38_require_num ledgerLen="$LEDGER_LEN" parentCalls="$PARENT_CALLS" childCalls="$CHILD_CALLS"
assert_eq "every recorded oracle call of both frames was replayed" \
  "$(( PARENT_CALLS + CHILD_CALLS ))" "$LEDGER_LEN"
assert_eq "and nothing was refused" "[]" "$(m39_trace transaction.refusedOracles)"
# THE BROWSER RUN AND THE NATIVE REPLAY AGREE ON THE TRANSACTION'S SHAPE, which is the property that
# makes the container a recording OF that transaction rather than of a second execution.
assert_eq "the replay's frame count is the browser run's" "2" "$(m39_trace transaction.frameCount)"
assert_eq "and its depth is the browser run's" "1" "$(m39_trace transaction.maxDepth)"
assert_eq "the two returns hashes agreed in the browser, which is why one tape replays into two" \
  "true" "$(m39_trace_top transaction.returnsHashesEqual)"

echo "== 10. EVERY CONTAINER FIGURE NESTED-CALLS.md STATES IS READ BACK OUT OF THE CONTAINER"
# THE FIGURES COMPARED HERE COME FROM THE CONTAINER, NOT FROM THE PROBE'S REPORT — the same rule the
# rest of this check follows, applied to the document. `_m38_doc_figures.py` walks LINES and takes
# the Nth bold figure on the row a needle names, because `str_has_re` is bash's `=~` and its `.`
# matches a newline, so the obvious spelling of "anchor the needle to the row" is not anchored.
[ -s "$M39_DOC" ] || die "there is no write-up at $M39_DOC"
TX_S="$(m39_container "$TX_CT" steps)";        ONE_S="$(m39_container "$ONE_CT" steps)"
TX_C="$(m39_container "$TX_CT" withColumn)";   ONE_C="$(m39_container "$ONE_CT" withColumn)"
TX_L="$(m39_container "$TX_CT" distinctLines)"; ONE_L="$(m39_container "$ONE_CT" distinctLines)"
TX_F="$(m39_container "$TX_CT" distinctPaths)"; ONE_F="$(m39_container "$ONE_CT" distinctPaths)"
TX_P="$(m39_container "$TX_CT" paths)";        ONE_P="$(m39_container "$ONE_CT" paths)"
TX_CA="$(m39_container "$TX_CT" calls)";       ONE_CA="$(m39_container "$ONE_CT" calls)"
TX_B="$(stat -c %s "$TX_CT")";                 ONE_B="$(stat -c %s "$ONE_CT")"
TX_RS="$(m39_trace transaction.steps)";        ONE_RS="$(m39_trace parentOnly.steps)"
TX_FR="$(m39_trace transaction.frameCount)";   ONE_FR="$(m39_trace parentOnly.frameCount)"
m38_absent txSteps="$TX_S" oneSteps="$ONE_S" txCols="$TX_C" oneCols="$ONE_C" txLines="$TX_L" \
  oneLines="$ONE_L" txFiles="$TX_F" oneFiles="$ONE_F" txPaths="$TX_P" onePaths="$ONE_P" \
  txCalls="$TX_CA" oneCalls="$ONE_CA" txBytes="$TX_B" oneBytes="$ONE_B" \
  txRecorded="$TX_RS" oneRecorded="$ONE_RS" txFrames="$TX_FR" oneFrames="$ONE_FR"
# BOTH COLUMNS OF EVERY ROW. M38's review found that thirteen of a write-up's twenty-six table
# figures — every second column of one table — were stated and compared by NOTHING, under a header
# claiming all of them were re-derived on every run. The index is the 0-based bold figure ON the row.
m38_assert_doc "NESTED-CALLS.md section 4" "$M39_DOC" \
  "frames in the container|0|$TX_FR"                  "frames in the container|1|$ONE_FR" \
  "steps the recorder wrote|0|$TX_RS"                 "steps the recorder wrote|1|$ONE_RS" \
  "\`Step\` events the pinned reader reads|0|$TX_S"   "\`Step\` events the pinned reader reads|1|$ONE_S" \
  "carrying a COLUMN|0|$TX_C"                         "carrying a COLUMN|1|$ONE_C" \
  "\`Call\` records|0|$TX_CA"                         "\`Call\` records|1|$ONE_CA" \
  "distinct \`(path, line)\` positions|0|$TX_L"       "distinct \`(path, line)\` positions|1|$ONE_L" \
  "distinct source files stepped|0|$TX_F"             "distinct source files stepped|1|$ONE_F" \
  "paths the container interns|0|$TX_P"               "paths the container interns|1|$ONE_P" \
  "container bytes|0|$TX_B"                           "container bytes|1|$ONE_B"
# AND THE PROSE FIGURES UNDER THE TABLE, which are the half nothing compares unless it is told to.
m38_assert_doc "NESTED-CALLS.md section 4 prose and section 5b" "$M39_DOC" \
  "Both containers reach|0|$TX_L"                     "Both containers reach|1|$TX_F" \
  "opcodes that halt was|0|$(m38_num "$(m39_trace transaction.frames.0.acirOpcodes)" 'caller acir')"
assert_true "and the write-up states the identity rather than the two numbers" \
  str_has_sub "$(cat "$M39_DOC")" 'container = probe + frames'
# THE COMPARER IS CALIBRATED HERE TOO, over THIS document, rather than trusted because another check
# calibrated it over another one. Both of its refusals are exercised: a figure that disagrees is
# reported as BAD naming both sides, and a needle that names no row is reported as MISSING. Without
# these, "no figure disagrees" is a sentence a comparer whose needles had all stopped matching would
# also produce — which is this campaign's most repeated shape.
assert_true "a wrong expected value over THIS document is reported as BAD, naming both sides" \
  str_has_sub "$(m38_doc_figures "$M39_DOC" "\`Step\` events the pinned reader reads|0|999999")" \
    "expected 999999"
assert_true "and a needle that names no row in it is reported as MISSING" \
  str_has_sub "$(m38_doc_figures "$M39_DOC" "a row this document does not have|0|1")" \
    "no row carries that needle"
assert_true "and a needle that names TWO rows is refused rather than matched to the first" \
  str_has_sub "$(m38_doc_figures "$M39_DOC" "derived|0|1")" "rows carry that needle"

m39_finish
