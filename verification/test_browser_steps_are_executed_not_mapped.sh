#!/usr/bin/env bash
# test_browser_steps_are_executed_not_mapped
#
# M29's first entry: the step stream a page records is what the AVM EXECUTED, not a walk of the
# artifact's debug map.
#
# ===========================================================================================
# WHAT THIS IS ABOUT, IN ONE PARAGRAPH.
# ===========================================================================================
#
# M27's demo container carried 64 steps whose program counters were the artifact's own first 64
# MAPPED pcs and whose opcodes were the literal `(pc % 200) + 1`. M27 disclosed that rather than
# letting it pass. M29 deletes the synthesised path — not as a fallback, deleted — and drives M9's
# `ExecutionObserverInterface` through M12's `avm_steps_batch` and M24's `ct_ingest` instead.
#
# ===========================================================================================
# THE OPCODE HISTOGRAM IS THE DISCRIMINATOR, AND THE PC SEQUENCE IS THE SECOND ONE.
# ===========================================================================================
#
# A count cannot tell the two apart: 516 fabricated steps and 516 executed ones are both 516. What
# distinguishes them is (a) whether the opcodes satisfy the synthetic rule and (b) whether the pcs
# are a strictly increasing, pairwise distinct sequence — which is what sorting a map's keys
# produces and what an execution, with its jumps and loops and calls, does not.
#
# BOTH LIVE IN ONE FILE, `_m29_stream_verdict.py`, and this check runs it TWICE: once over the
# stream the browser recorded, and once over M27's synthesised stream reconstructed by
# `_m29_mapped_stream.py` from the same artifact. The first must come out `executed` and the second
# `mapped`. A discriminator that has never said `mapped` about anything is not a discriminator, and
# `CAMPAIGN-BRIEF.md` records four shipped defects of exactly that shape.
#
# ===========================================================================================
# AND THE OPCODES ARE CHECKED AGAINST UPSTREAM'S OWN TABLE.
# ===========================================================================================
#
# Every opcode in the stream must be a real `WireOpCode` — below `LAST_OPCODE_SENTINEL`, which M9
# derived by counting enumerators in upstream's `opcodes.hpp` and pinned at 68. The sentinel itself
# is legitimate exactly once (a `read_instruction` that threw), so it is counted rather than
# forbidden, and a stream that is ALL sentinel is the shape a transaction that never fetched any
# bytecode produces — which is what M27's demo was doing before M29 looked at it.
#
# Run: just verify-m29-executed

TEST_NAME="test_browser_steps_are_executed_not_mapped"
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

echo "== 1. the page drove the observation hook, and the two readings of the stream agree"

EXECUTED_COUNT="$(m27_arm publicOnly transfer.executed.count)"
EXECUTED_DECODED="$(m27_arm publicOnly transfer.executed.decoded)"
IN_RESULT="$(m27_arm publicOnly transfer.executed.inResult)"
MATCHES_RESULT="$(m27_arm publicOnly transfer.executed.drainedMatchesResult)"
CROSSINGS="$(m27_arm publicOnly transfer.executed.crossings)"
BATCH="$(m27_arm publicOnly transfer.executed.batchRecords)"
note "the page executed $EXECUTED_COUNT instruction(s), drained in $CROSSINGS crossing(s) of $BATCH"

# THE NON-EMPTINESS PARTNER, BEFORE ANY COMPARISON. Every value below is read from the arm report,
# and `m27_arm` prints `MISSING` for a path that is not there — so without this the comparisons are
# the `assert_eq "" ""` family. It is not hypothetical: this check's first run pointed five of them
# at `arms.publicOnly.executed` when the field is at `arms.publicOnly.transfer.executed`, and two
# of the five went GREEN comparing MISSING with MISSING.
ABSENT="$(m29_absent "count=$EXECUTED_COUNT" "decoded=$EXECUTED_DECODED" "inResult=$IN_RESULT" \
  "drainedMatchesResult=$MATCHES_RESULT" "crossings=$CROSSINGS" "batchRecords=$BATCH")"
assert_eq "every field of the executed stream is present in the arm report" "" "$ABSENT"
[ -z "$ABSENT" ] || die "the arm report has no executed stream ($ABSENT); every assertion below
             would be a comparison of absences. This is a failure, not a smaller milestone."
assert_ge "…with a substantial number of records rather than a stub" 100 "$EXECUTED_COUNT"
assert_eq "…and every record the module counted was decoded" "$EXECUTED_COUNT" "$EXECUTED_DECODED"
# THE ZERO-CROSSING PATH AND THE BATCHED ONE, COMPARED. The whole stream also arrives inside
# `TxSimulationResult.executionSteps`; the drain goes through `avm_steps_batch` because M12 built it
# for exactly this consumer. That the two agree PER RECORD is the host's own comparison, read here.
assert_eq "…the same number arrived inside the simulate result itself" "$EXECUTED_COUNT" "$IN_RESULT"
assert_eq "…and the drained records equal the in-result ones, record for record" "true" "$MATCHES_RESULT"
# `ceil(N / B)` — M12's identity, not a bound.
assert_eq "the drain cost exactly ceil(count / batch) crossings" \
  "$(( (EXECUTED_COUNT + BATCH - 1) / BATCH ))" "$CROSSINGS"

echo "== 2. THE DISCRIMINATOR: the recorded stream is executed"

REAL_PAIRS="$M29_WORK/real-pairs.tsv"
python3 - "$M27_ARMS" >"$REAL_PAIRS" <<'PY'
import json, re, sys
records = json.load(open(sys.argv[1]))['arms']['publicOnly']['transfer']['executed']['records']
pat = re.compile(r'^ctx=\d+ pc=(\d+) op=(\d+) ')
for r in records:
    m = pat.match(r)
    if m:
        print(f"{m.group(1)}\t{m.group(2)}")
PY
PAIRS_RC=$?
assert_eq "the arm's per-record transcript was extracted" "0" "$PAIRS_RC"
assert_ge "…and the extraction is not empty" 100 "$(grep -c . "$REAL_PAIRS" || true)"

REAL_VERDICT="$M29_WORK/real-verdict.tsv"
python3 "$VERIFY_DIR/_m29_stream_verdict.py" "$REAL_PAIRS" >"$REAL_VERDICT"
REAL_RC=$?
assert_eq "the verdict script ran over the recorded stream" "0" "$REAL_RC"
m29_field() { awk -F'\t' -v k="$2" '$1 == k { print $2; found = 1 } END { if (!found) print "MISSING" }' "$1"; }

REAL_PAIR_COUNT="$(m29_field "$REAL_VERDICT" pairs)"
REAL_RESIDUE="$(m29_field "$REAL_VERDICT" residue)"
REAL_DISTINCT_OPS="$(m29_field "$REAL_VERDICT" distinctOpcodes)"
REAL_SYNTH_MATCHES="$(m29_field "$REAL_VERDICT" syntheticRuleMatches)"
REAL_SYNTH_HOLDS="$(m29_field "$REAL_VERDICT" syntheticRuleHolds)"
REAL_INCREASING="$(m29_field "$REAL_VERDICT" pcsStrictlyIncreasing)"
REAL_DISTINCT_PCS="$(m29_field "$REAL_VERDICT" pcsAllDistinct)"
REAL_REVISITS="$(m29_field "$REAL_VERDICT" pcRevisits)"
REAL_BACKWARD="$(m29_field "$REAL_VERDICT" backwardJumps)"
REAL_MAXOP="$(m29_field "$REAL_VERDICT" maxOpcode)"
note "recorded stream: $REAL_PAIR_COUNT pair(s), $REAL_DISTINCT_OPS distinct opcode(s), \
$REAL_SYNTH_MATCHES synthetic-rule match(es), $REAL_REVISITS pc revisit(s), $REAL_BACKWARD backward jump(s)"

assert_eq "the verdict script placed every line it was given" "0" "$REAL_RESIDUE"
assert_eq "…over as many pairs as the module counted steps" "$EXECUTED_COUNT" "$REAL_PAIR_COUNT"
assert_eq "THE VERDICT: the recorded stream is EXECUTED" "executed" "$(m29_field "$REAL_VERDICT" verdict)"
assert_eq "…because the opcodes do NOT satisfy (pc % 200) + 1" "0" "$REAL_SYNTH_HOLDS"
assert_eq "…and the pcs are NOT a sorted walk of a map" "0" "$REAL_INCREASING"
assert_eq "…and they are not pairwise distinct either, because an execution revisits" "0" "$REAL_DISTINCT_PCS"
assert_ge "…revisiting at least one pc, which a map walk never does" 1 "$REAL_REVISITS"
assert_ge "…and jumping backwards at least once" 1 "$REAL_BACKWARD"
# A real interpreter uses many opcodes. One is what a constant produces, and a constant is what M24
# shipped before M25 and what a fabricated stream would look like if the rule were `opcode: 42`.
assert_ge "…with a real instruction mix rather than one opcode" 10 "$REAL_DISTINCT_OPS"

echo "== 3. …and every opcode is a real WireOpCode"

# M9 derived `LAST_OPCODE_SENTINEL` by counting enumerators in upstream's `opcodes.hpp` and pinned
# it at 68. An opcode above it is not an instruction at all.
M29_SENTINEL=68
SENTINELS="$(awk -F'\t' -v s="$M29_SENTINEL" '$2 == s' "$REAL_PAIRS" | grep -c . || true)"
ABOVE="$(awk -F'\t' -v s="$M29_SENTINEL" '$2 > s' "$REAL_PAIRS" | grep -c . || true)"
note "$SENTINELS sentinel record(s), $ABOVE record(s) above the sentinel, max opcode $REAL_MAXOP"
assert_eq "no opcode is above M9's LAST_OPCODE_SENTINEL" "0" "$ABOVE"
# THE SENTINEL IS THE SHAPE M27's DEMO ACTUALLY HAD, and it is asserted absent rather than assumed:
# a transaction whose contract has no deployment nullifier executes exactly one instruction, at
# pc 0, with the sentinel opcode, and reports itself `processed`.
assert_eq "…and none of them is the sentinel, so no fetch threw" "0" "$SENTINELS"

echo "== 4. THE NEGATIVE CONTROL: the synthetic generator's own output must FAIL this check"

ARTIFACT="$(m27_run artifact.root)"
ARTIFACT_PATH="$REPO_ROOT/$ARTIFACT/node_modules/@aztec/noir-contracts.js/artifacts/token_contract-Token.json"
assert_file "the arm run named an artifact this check can find" "$ARTIFACT_PATH"

SYNTH_PAIRS="$M29_WORK/synthetic-pairs.tsv"
python3 "$VERIFY_DIR/_m29_mapped_stream.py" "$ARTIFACT_PATH" 64 >"$SYNTH_PAIRS" 2>"$M29_WORK/synthetic.err"
SYNTH_RC=$?
assert_eq "M27's synthesised stream was reconstructed from the same artifact" "0" "$SYNTH_RC"
assert_eq "…and it is 64 pairs, which is M27's DEMO_STEPS" "64" "$(grep -c . "$SYNTH_PAIRS" || true)"

SYNTH_VERDICT="$M29_WORK/synthetic-verdict.tsv"
python3 "$VERIFY_DIR/_m29_stream_verdict.py" "$SYNTH_PAIRS" >"$SYNTH_VERDICT"
SYNTH_VRC=$?
assert_eq "the SAME verdict script ran over it" "0" "$SYNTH_VRC"
note "synthetic stream verdict: $(m29_field "$SYNTH_VERDICT" verdict), \
$(m29_field "$SYNTH_VERDICT" distinctOpcodes) distinct opcode(s)"

assert_eq "THE CONTROL: the synthesised stream is MAPPED, so the predicate can say no" \
  "mapped" "$(m29_field "$SYNTH_VERDICT" verdict)"
# BOTH CONJUNCTS FIRE ON IT, which is what makes the two criteria independently exercised rather
# than one of them riding along — a conjunction whose negative case exercises one conjunct is a
# defect this campaign has shipped.
assert_eq "…its opcodes DO satisfy (pc % 200) + 1" "1" "$(m29_field "$SYNTH_VERDICT" syntheticRuleHolds)"
assert_eq "…and its pcs ARE strictly increasing" "1" "$(m29_field "$SYNTH_VERDICT" pcsStrictlyIncreasing)"
assert_eq "…and pairwise distinct" "1" "$(m29_field "$SYNTH_VERDICT" pcsAllDistinct)"
assert_eq "…with no pc revisited" "0" "$(m29_field "$SYNTH_VERDICT" pcRevisits)"
assert_eq "…and no backward jump" "0" "$(m29_field "$SYNTH_VERDICT" backwardJumps)"
# AND THE TWO STREAMS ARE GENUINELY DIFFERENT OBJECTS. Without this, both verdicts could be about
# the same file — the `assert_eq "" ""` family in its file-path form.
assert_false "the two streams are not the same file" cmp -s "$REAL_PAIRS" "$SYNTH_PAIRS"

echo "== 5. the synthesised producer is DELETED, not kept as a fallback"

CT_DOWNLOAD="$(cat "$BROWSER_SRC/ct_download.ts")"
# The rule itself, as an expression. Its absence from the whole browser source tree is what
# "deleted, not kept as a fallback" means, and it is asserted over the tree rather than over the one
# file, because a fallback moved one file sideways is still a fallback.
#
# COMMENTS ARE STRIPPED FIRST, AND THE STRIPPING IS ITSELF ASSERTED. "A citation is the opposite of
# a dependency" — this file's own header quotes the rule, `ct_download.ts` explains at length that
# it used to compute it, and a needle that cannot tell a sentence from an expression counts both.
# The campaign has the mirror of this defect on record (a census that counted its own remedy as
# remaining exposure), so the stripper's effect is measured rather than trusted: the count BEFORE
# stripping is non-zero, which is what says the stripping did something.
SYNTH_RULE_ALL="$(grep -rn '% 200) + 1' "$BROWSER_SRC" "$BROWSER_DIR/demo" | grep -c . || true)"
SYNTH_RULE_SITES="$(grep -rn '% 200) + 1' "$BROWSER_SRC" "$BROWSER_DIR/demo" \
  | grep -v ':[[:space:]]*\(//\|\*\)' | grep -c . || true)"
note "the synthetic rule appears $SYNTH_RULE_ALL time(s) in the browser sources, $SYNTH_RULE_SITES of them outside a comment"
assert_ge "the rule is still WRITTEN DOWN somewhere, so the stripper has something to strip" 1 "$SYNTH_RULE_ALL"
assert_eq "no browser source COMPUTES an opcode as (pc % 200) + 1" "0" "$SYNTH_RULE_SITES"
# AND THE BUILT BUNDLE, because a source that no longer says it and a bundle that still does is
# exactly the stale-artefact shape.
BUNDLE_SITES="$(grep -rl '% 200' "$BROWSER_DIST" 2>/dev/null | grep -c . || true)"
assert_eq "…and neither does any file of the built bundle" "0" "$BUNDLE_SITES"
assert_true "the recorder REFUSES rather than substituting when there is no executed stream" \
  str_has_sub "$CT_DOWNLOAD" 'throw new ExecutedStepsUnavailable'
assert_true "…and the refusal names the option that would have produced one" \
  str_has_sub "$CT_DOWNLOAD" 'openAvmRuntime({ collectExecutionSteps: true })'
assert_true "…and the option is off by default, so an ordinary page pays no observer overhead" \
  str_has_sub "$(cat "$BROWSER_SRC/runtime.ts")" 'options.collectExecutionSteps === true'

echo "== 6. and the container the page downloaded carries the same stream"

REC_EXECUTED="$(m27_arm download recording.executedSteps)"
REC_EVENTS="$(m27_arm download recording.events)"
REC_PRODUCER="$(m27_arm download recording.stepProducer)"
REC_DISTINCT="$(m27_arm download recording.distinctOpcodes)"
REC_CONTEXTS="$(m27_arm download recording.contexts)"
note "the container carries $REC_EVENTS event(s) from $REC_PRODUCER, \
$REC_DISTINCT distinct opcode(s) across $REC_CONTEXTS context(s)"

assert_eq "the container's event count is the executed instruction count" "$REC_EXECUTED" "$REC_EVENTS"
assert_eq "…and it is the number the page's own drain reported" "$EXECUTED_COUNT" "$REC_EXECUTED"
assert_eq "…written by the AVM's observation hook, named in the recording" \
  "avm-execution-observer" "$REC_PRODUCER"
assert_eq "…with the same opcode variety the raw stream had" "$REAL_DISTINCT_OPS" "$REC_DISTINCT"
assert_ge "…across at least the transaction's two enqueued calls" 2 "$REC_CONTEXTS"

echo "== 7. THE OPCODES THAT ARE ACTUALLY IN THE CONTAINER, READ BACK BY THE REFERENCE READER"

# ===========================================================================================
# THIS SECTION EXISTS BECAUSE A MUTATION FOUND ITS ABSENCE, AND THE ABSENCE WAS THE WHOLE POINT.
# ===========================================================================================
#
# Everything above section 6 reads the stream the PAGE DRAINED, and section 6 reads numbers the
# RECORDER reports about itself. Both are upstream of the writer. Mutation M1 put M27's
# `opcode: (pc % 200) + 1` back into `recordAndDownload` — changing what is WRITTEN and leaving
# what was DRAINED alone — and this check reported *42 assertions, 1 failure*, the one failure
# being a grep of the source tree. Every behavioural assertion passed over a container full of
# fabricated opcodes.
#
# That is `CAMPAIGN-BRIEF.md`'s "anything asserted must be read from the artefact, never printed as
# a constant by the thing under test", in its exact shape. So the opcodes come out of the CONTAINER
# now, through the pinned reader, and the histogram is compared against the drained stream's.
DL_PATH="$(m27_arm download downloaded.0.path)"
assert_file "the downloaded container is on disk" "$DL_PATH"
CT_JSON="$M29_WORK/container.json"
m24_ct_print "$M24_READERS/ct-print" "$DL_PATH" | tail -n +2 >"$CT_JSON"
assert_ge "…and the reader produced a document to read" 500 "$(grep -c . "$CT_JSON" || true)"

CONTAINER_OPS="$M29_WORK/container-opcodes.tsv"
python3 "$VERIFY_DIR/_m29_container_opcodes.py" "$CT_JSON" histogram >"$CONTAINER_OPS" 2>"$M29_WORK/container-opcodes.err"
CONTAINER_RC=$?
assert_eq "the container's opcode values were extracted through the reader" "0" "$CONTAINER_RC"
CONTAINER_ROWS="$(grep -c . "$CONTAINER_OPS" || true)"
CONTAINER_TOTAL="$(awk -F'\t' '{ n += $2 } END { print n + 0 }' "$CONTAINER_OPS")"
note "the container carries $CONTAINER_TOTAL opcode value(s) over $CONTAINER_ROWS distinct opcode(s)"
assert_ge "…and the extraction is not empty" 1 "$CONTAINER_ROWS"
assert_eq "…one opcode value per written event" "$REC_EVENTS" "$CONTAINER_TOTAL"

# THE HISTOGRAM IDENTITY. Built from the drained records by this check, compared against the one
# read out of the container. This is what M1 breaks and nothing else did.
DRAINED_OPS="$M29_WORK/drained-opcodes.tsv"
awk -F'\t' '{ h[$2]++ } END { for (op in h) print op "\t" h[op] }' "$REAL_PAIRS" | sort -n >"$DRAINED_OPS"
sort -n -o "$CONTAINER_OPS" "$CONTAINER_OPS"
assert_ge "the drained histogram is non-empty too" 1 "$(grep -c . "$DRAINED_OPS" || true)"
assert_true "THE CONTAINER'S OPCODE HISTOGRAM IS THE DRAINED STREAM'S, opcode for opcode" \
  cmp -s "$DRAINED_OPS" "$CONTAINER_OPS"

# AND THE COMPARISON CAN FAIL. One opcode moved in a copy of the container's histogram must be
# reported — otherwise `cmp -s` over two files this check just wrote is a comparison of a thing
# with itself, which is the most degenerate shape on the campaign's list.
CTL="$M29_WORK/container-opcodes-control.tsv"
awk -F'\t' 'NR == 1 { print $1 "\t" ($2 + 1); next } { print }' "$CONTAINER_OPS" >"$CTL"
assert_false "…and one altered count in a copy of it IS reported" cmp -s "$DRAINED_OPS" "$CTL"

# THE SYNTHETIC HISTOGRAM IS NOT THIS ONE. The negative control from section 4, applied to the
# container: M27's rule over the SAME pcs the execution visited produces a different multiset, and
# the check would rather say so than rely on the two happening to differ.
SYNTH_FROM_REAL="$M29_WORK/synthetic-from-real.tsv"
awk -F'\t' '{ h[($1 % 200) + 1]++ } END { for (op in h) print op "\t" h[op] }' "$REAL_PAIRS" | sort -n >"$SYNTH_FROM_REAL"
assert_ge "the synthetic rule over the executed pcs yields a histogram at all" 1 \
  "$(grep -c . "$SYNTH_FROM_REAL" || true)"
assert_false "…and it is NOT the histogram the container carries" cmp -s "$SYNTH_FROM_REAL" "$CONTAINER_OPS"

m29_finish
