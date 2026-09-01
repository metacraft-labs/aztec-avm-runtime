#!/usr/bin/env bash
# e2e_both_halves_step_in_the_browser
#
# M40 verification: **both halves of one transaction step in Chromium, and the two containers the
# page downloaded are an explicit join the pinned reader opens.**
#
# ===========================================================================================
# WHAT IS NEW HERE AND WHAT IS NOT
# ===========================================================================================
#
# M38 and M39 step a private Aztec frame with the real Noir tracer, natively: the probe reads its
# artifacts with `std::fs` and writes its container with the Nim FFI writer, and neither of those
# can target wasm. So until now the half a page EXECUTED was stepped somewhere else.
#
# This check is about the page doing both. Two wasm modules and no third writer:
# `m40_private_trace.wasm` is `noir_tracer` built for wasm32 from the PUBLISHED `noir`, and the
# container is written by the page's own `ct_writer.wasm` through `ct_source_step`. The Noir tracer
# links no container writer on that path at all, which is why `JOIN-SHAPE.md` §2's facts 6 and 7 are
# untouched — asserted in §6 rather than asserted about.
#
# ===========================================================================================
# THE THREE THINGS THAT ARE MEASURED RATHER THAN ARGUED
# ===========================================================================================
#
#   1. **THE DIFFERENTIAL.** The wasm module and M38's native probe are two independent
#      implementations of the tape executor. They are compared position for position over the same
#      transaction and the same tape, through the pinned reader on the native side. Two
#      implementations agreeing is a stronger statement than one used twice.
#
#   2. **THE COLUMN REACHES THE CONTAINER.** The pinned reader renders a Path A container through
#      its legacy `events.log` decoder, whose `Step` record is `(path_id, line)` and has no column
#      field. Reading that absence as "the browser's container has no columns" would be a fact about
#      the READER stated as one about the container — this campaign's "an absence asked of a tree
#      that excludes the subject by construction". So the measurement is a DIGEST PAIR: the same
#      transaction written twice, differing only in whether the column was written.
#
#   3. **THE MODULE REACHED NO IMPORT.** It declares four wasm-bindgen placeholders. Every one is
#      satisfied with a function that records the call and then throws, so an empty `reachedImports`
#      is something the run says rather than something a build flag promises.

set -uo pipefail

TEST_NAME="e2e_both_halves_step_in_the_browser"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m23_chain.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m27_browser.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m38_private_trace.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m39_nested.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m40_transaction.sh"
m40_summary_on_abnormal_exit

m40_require_trace_arms

SUBJECT=bothHalves
CTPRINT="$(m38_ct_print)"
assert_file "the pinned ct-print is built" "$CTPRINT"

PUB_CT="$M40_WORK/$(m40_arm "$SUBJECT.publicDownload.file")"
PRIV_CT="$M40_WORK/$(m40_arm "$SUBJECT.privateDownload.file")"
NATIVE_CT="$(m40_trace privateHalf.container)"

# ===========================================================================================
echo "== 0. THE PRECONDITION: every field this check reads is PRESENT"
# ===========================================================================================
m38_absent \
  "publicDownload=$(m40_arm "$SUBJECT.publicDownload.file")" \
  "privateDownload=$(m40_arm "$SUBJECT.privateDownload.file")" \
  "privateSteps=$(m40_arm "$SUBJECT.report.privateContainer.report.steps")" \
  "privateSha=$(m40_arm "$SUBJECT.report.privateContainer.sha256")" \
  "droppedSha=$(m40_arm "columnsDropped.report.privateContainer.sha256")" \
  "reachedImports=$(m40_arm "$SUBJECT.report.privateContainer.reachedImports")" \
  "nativeContainer=$NATIVE_CT" \
  "nativeSteps=$(m40_trace privateHalf.steps)" \
  "joinId=$(m40_arm "$SUBJECT.report.joinId")"

# ===========================================================================================
echo "== 1. THE PAGE DOWNLOADED TWO CONTAINERS AND THE PINNED READER OPENS BOTH"
# ===========================================================================================
assert_eq "the page downloaded exactly two containers" "2" "$(m40_arm "$SUBJECT.downloadedCount")"
assert_file "the public half's is on disk" "$PUB_CT"
assert_file "the private half's is on disk" "$PRIV_CT"
# THE BROWSER'S OWN DOWNLOAD MACHINERY WROTE THEM, so the bytes read back are bytes the page really
# handed over rather than ones a probe read out of a variable. The digests are the page's own,
# taken before the download, and the driver's, taken off disk.
assert_eq "the public container's bytes on disk are the ones the page reported" \
  "$(m40_arm "$SUBJECT.report.publicContainer.containerBytes")" \
  "$(m40_arm "$SUBJECT.publicDownload.bytes")"
assert_eq "and so are the private container's" \
  "$(m40_arm "$SUBJECT.report.privateContainer.containerBytes")" \
  "$(m40_arm "$SUBJECT.privateDownload.bytes")"
assert_eq "the private container's digest survived the download" \
  "$(m40_arm "$SUBJECT.report.privateContainer.sha256")" \
  "$(m40_arm "$SUBJECT.privateDownload.sha256")"

for ct in "$PUB_CT" "$PRIV_CT"; do
  "$CTPRINT" --full "$ct" >/dev/null 2>&1
  assert_eq "ct-print --full exits 0 over $(basename "$ct")" "0" "$?"
done
# AND THE READER CAN REFUSE, so an exit 0 is evidence. A 512-byte stub is refused; a HALVED copy is
# NOT — a `.ct` is a directory of independent streams and M27 recorded that halving does not make
# the reader refuse, which is why the stub is the control and the halved copy is a note.
STUB="$M40_WORK/reader-control.ct"
head -c 512 "$PRIV_CT" > "$STUB"
"$CTPRINT" --full "$STUB" >/dev/null 2>&1
assert_true "and refuses a 512-byte stub, so exit 0 above is a verdict" test "$?" -ne 0

# ===========================================================================================
echo "== 2. THE PRIVATE HALF, STEPPED IN THE PAGE"
# ===========================================================================================
PSTEPS="$(m38_num "$(m40_arm "$SUBJECT.report.privateContainer.report.steps")" 'browser steps')"
PCOLS="$(m38_num "$(m40_arm "$SUBJECT.report.privateContainer.report.stepsWithColumn")" 'browser steps with column')"
PFRAMES="$(m38_num "$(m40_arm "$SUBJECT.report.privateContainer.report.frameCount")" 'browser frames')"
PPATHS="$(m38_num "$(m40_arm "$SUBJECT.report.privateContainer.recording.pathsInterned")" 'paths interned')"
POPS="$(m38_num "$(m40_arm "$SUBJECT.report.privateContainer.opsReplayed")" 'ops replayed')"
PBYTES="$(m38_num "$(m40_arm "$SUBJECT.report.privateContainer.containerBytes")" 'private container bytes')"
NSTEPS="$(m38_num "$(m40_trace privateHalf.steps)" 'native steps')"
m38_require_num browserSteps="$PSTEPS" columns="$PCOLS" frames="$PFRAMES" paths="$PPATHS" \
  ops="$POPS" bytes="$PBYTES" nativeSteps="$NSTEPS"

assert_eq "the browser stepped both private frames" "2" "$PFRAMES"
assert_eq "the tracer errored on nothing" "[]" "$(m40_arm "$SUBJECT.report.privateContainer.report.traceErrors")"
assert_eq "and refused no oracle from the tape" "[]" \
  "$(m40_arm "$SUBJECT.report.privateContainer.report.refusedOracles")"
assert_eq "the recording finished" "ok" "$(m40_arm "$SUBJECT.report.privateContainer.report.finish")"

# THE IDENTITY, NOT A FLOOR. `TraceSink::start` emits one entry step per traced circuit, so the
# module's own step count is the native probe's plus one per frame — and the module's count is
# equal to the writer's, which is asserted inside `CtWriter.close` and read back here.
assert_eq "the browser's step count is the native probe's plus one entry step per frame" \
  "$((NSTEPS + PFRAMES))" "$PSTEPS"
assert_eq "and the writer accepted every one of them" "$PSTEPS" \
  "$(m40_arm "$SUBJECT.report.privateContainer.recording.sourceSteps")"
assert_eq "which is also what the container reports as events" "$PSTEPS" \
  "$(m40_arm "$SUBJECT.report.privateContainer.recording.events")"
# EVERY STEP IS POSITIONED. A private frame's step comes from the artifact's own debug info; a step
# without a position would be the tracer failing to resolve one, not a rung degradation.
assert_eq "every step landed at a resolved source position" "$PSTEPS" \
  "$(m40_arm "$SUBJECT.report.privateContainer.recording.stepsPositioned")"
assert_eq "and none fell back" "0" \
  "$(m40_arm "$SUBJECT.report.privateContainer.recording.stepsUnpositioned")"
# THE TWO WITHOUT A COLUMN ARE THE FRAME-ENTRY STEPS, ONE PER FRAME, and that is derived rather
# than typed: `TraceSink::start` has no column to give.
assert_eq "every step but one per frame carries a column" "$((PSTEPS - PFRAMES))" "$PCOLS"
assert_ge "over a non-degenerate number of source files" 5 \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' \
      "$(m40_arm "$SUBJECT.report.privateContainer.report.stepPaths")")"
assert_ge "and a non-degenerate number of interned paths" 50 "$PPATHS"

# THE NESTING IS IN THE CONTAINER. One `Call` and one `Return`, and the call carries the caller's
# address as its one argument — M26's rule: a frame must be attributable without stepping into it.
assert_eq "the nested frame is a Call in the container" "1" \
  "$(m40_arm "$SUBJECT.report.privateContainer.recording.callsOpened")"
assert_eq "and it closed" "0" "$(m40_arm "$SUBJECT.report.privateContainer.recording.callDepthAtClose")"
assert_eq "the writer path is DD-7's Path A" "path-a-pure-rust" \
  "$(m40_arm "$SUBJECT.report.privateContainer.recording.writerPath")"
assert_eq "columns were requested of it" "true" \
  "$(m40_arm "$SUBJECT.report.privateContainer.recording.columnsRequested")"
assert_eq "and the writer dropped none" "false" \
  "$(m40_arm "$SUBJECT.report.privateContainer.recording.droppedColumnAwareness")"

# ===========================================================================================
echo "== 3. THE DIFFERENTIAL: THE WASM MODULE AND THE NATIVE PROBE WALKED THE SAME CIRCUIT"
# ===========================================================================================
#
# The left-hand side is this module's own `stepPositions`; the right-hand side is the NATIVE
# container decoded by the pinned reader. Two implementations, two writers, two decoders.
NATIVE_POS="$(m40_container "$NATIVE_CT" positions)"
BROWSER_POS="$(m40_arm "$SUBJECT.report.privateContainer.report.stepPositions" \
  | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))')"
assert_eq "the native container decodes through the SPLIT-stream reader" "split" \
  "$(m40_container "$NATIVE_CT" rendering)"
assert_eq "and the browser's through the low-level one, which is a fact about the WRITER PATH" \
  "lowlevel" "$(m40_container "$PRIV_CT" rendering)"
assert_eq "both hold the same number of steps" "$(printf '%s\n' "$NATIVE_POS" | grep -c .)" \
  "$(printf '%s\n' "$BROWSER_POS" | grep -c .)"
assert_ge "and it is not an empty comparison" 50 "$(printf '%s\n' "$NATIVE_POS" | grep -c .)"

# THE `(path, line)` SEQUENCES ARE IDENTICAL, IN ORDER. A set comparison would pass over two runs
# that visited the same lines in different orders, which is what a divergent replay produces.
NATIVE_PL="$(printf '%s\n' "$NATIVE_POS" | sed 's/:[^:]*$//')"
BROWSER_PL="$(printf '%s\n' "$BROWSER_POS" | sed 's/:[^:]*$//')"
assert_eq "the two step streams are the same (path, line) sequence" "$NATIVE_PL" "$BROWSER_PL"

# AND THE COLUMNS AGREE EVERYWHERE THE TRACER PRODUCED ONE. They differ at exactly the frame-entry
# steps, where the tracer emits NO column and a column-aware container's decoder answers 1 — so the
# difference count is FRAME COUNT, derived, and the disagreeing pairs are asserted to be that shape
# rather than merely counted.
COLDIFF="$(python3 -c '
import sys
native = sys.argv[1].splitlines()
browser = sys.argv[2].splitlines()
bad = []
for i, (a, b) in enumerate(zip(native, browser)):
    if a != b:
        bad.append((i, a.rsplit(":", 1)[1], b.rsplit(":", 1)[1]))
print(len(bad))
print(",".join("%s->%s" % (n, w) for _, n, w in bad))
' "$NATIVE_POS" "$BROWSER_POS")"
COLDIFF_N="$(printf '%s\n' "$COLDIFF" | sed -n '1p')"
COLDIFF_SHAPE="$(printf '%s\n' "$COLDIFF" | sed -n '2p')"
assert_eq "the columns differ at exactly one step per frame" "$PFRAMES" "$COLDIFF_N"
assert_eq "and every difference is 'the container says 1 where the tracer said none'" \
  "1->-,1->-" "$COLDIFF_SHAPE"

# ===========================================================================================
echo "== 4. THE COLUMN REACHES THE CONTAINER, AND THAT IS A DIGEST PAIR"
# ===========================================================================================
SUBJ_SHA="$(m40_arm "$SUBJECT.report.privateContainer.sha256")"
DROP_SHA="$(m40_arm "columnsDropped.report.privateContainer.sha256")"
assert_eq "the subject wrote the tracer's columns" "false" \
  "$(m40_arm "$SUBJECT.report.privateContainer.columnsDropped")"
assert_eq "the control dropped them" "true" \
  "$(m40_arm "columnsDropped.report.privateContainer.columnsDropped")"
# SAME OPS, SAME STEPS, SAME PATHS — one field changed.
assert_eq "the control replayed the same op list" "$POPS" \
  "$(m40_arm "columnsDropped.report.privateContainer.opsReplayed")"
assert_eq "and wrote the same number of steps" "$PSTEPS" \
  "$(m40_arm "columnsDropped.report.privateContainer.recording.sourceSteps")"
assert_eq "and the same number of container bytes, because a column is a DELTA opcode" \
  "$PBYTES" "$(m40_arm "columnsDropped.report.privateContainer.containerBytes")"
assert_true "and the two digests DIFFER, which is the column reaching the container" \
  test "$SUBJ_SHA" != "$DROP_SHA"
# The reader cannot see it, and that is stated as a fact about the READER.
assert_eq "the pinned reader's Path A rendering surfaces no column, which is why the pair exists" \
  "NOCOLUMNS" "$(m40_container "$PRIV_CT" withColumn)"
assert_ge "while it surfaces every one of the native container's" "$PCOLS" \
  "$(m40_container "$NATIVE_CT" withColumn)"

# ===========================================================================================
echo "== 5. THE JOIN: TWO HALVES, ONE IDENTITY, AND A REFUSAL FOR EITHER ALONE"
# ===========================================================================================
JOIN_ID="$(m40_arm "$SUBJECT.report.joinId")"
assert_eq "the join identity is the outer frame's own argsHash, which the circuit committed to" \
  "$(m40_arm "$SUBJECT.report.run.publicInputs.argsHash")" "$JOIN_ID"
assert_eq "the private container carries exactly one join record" "1" "$(m40_container "$PRIV_CT" joinCount)"
assert_eq "and so does the public one" "1" "$(m40_container "$PUB_CT" joinCount)"
PRIV_JOIN="$(m40_container "$PRIV_CT" join)"
PUB_JOIN="$(m40_container "$PUB_CT" join)"
assert_true "the private half declares itself the private half of two" \
  str_has_sub "$PRIV_JOIN" "half=private halves=2 arm=split"
assert_true "and the public half the public one" \
  str_has_sub "$PUB_JOIN" "half=public halves=2 arm=split"
assert_true "both under the transaction's own identity" str_has_sub "$PRIV_JOIN" "join=$JOIN_ID"
assert_true "both under the transaction's own identity (public)" str_has_sub "$PUB_JOIN" "join=$JOIN_ID"

# THE GRAMMAR IS COMPARED AS BYTES against what `orchestration/src/trace_join.ts` renders, rather
# than each side against its own copy of a format string. Field order, spacing and the constant
# `reason` are load-bearing and three producers spell them independently.
RENDERED="$(cd "$REPO_ROOT/orchestration" && node --input-type=module -e '
import { formatJoinRecord, joinRecord } from "./src/trace_join.ts";
process.stdout.write(formatJoinRecord(joinRecord(process.argv[1], process.argv[2], 2, "split")));
' "$JOIN_ID" private 2>/dev/null)"
assert_eq "the private half's record is byte-identical to what the join grammar renders" \
  "$RENDERED" "$PRIV_JOIN"
RENDERED_PUB="$(cd "$REPO_ROOT/orchestration" && node --input-type=module -e '
import { formatJoinRecord, joinRecord } from "./src/trace_join.ts";
process.stdout.write(formatJoinRecord(joinRecord(process.argv[1], process.argv[2], 2, "split")));
' "$JOIN_ID" public 2>/dev/null)"
assert_eq "and so is the public half's" "$RENDERED_PUB" "$PUB_JOIN"

# AND `joinRecordings` ACCEPTS THE PAIR, over the CONTAINERS the browser downloaded, with each
# record parsed back out by the pinned reader rather than taken from a producer's report.
JOINED="$(cd "$REPO_ROOT/orchestration" && node --input-type=module -e '
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { joinRecordings, parseJoinRecord } from "./src/trace_join.ts";
const [ctprint, priv, pub] = process.argv.slice(1);
const half = (label, file) => {
  const doc = JSON.parse(execFileSync(ctprint, ["--full", file], { encoding: "utf8", maxBuffer: 1 << 28 }));
  const ev = (doc.events ?? []).find((e) => e.metadata === "ct.trace-join");
  const content = ev?.content ?? ev?.text;
  return { label, container: new Uint8Array(readFileSync(file)), record: content ? parseJoinRecord(content) : undefined };
};
const halves = [half("private", priv), half("public", pub)];
const joined = joinRecordings(halves);
console.log(JSON.stringify({ joinId: joined.joinId, arm: joined.arm, order: joined.order }));
let ground = "NOT REFUSED";
try { joinRecordings([halves[0]]); } catch (e) { ground = e.ground; }
console.log(ground);
' "$CTPRINT" "$PRIV_CT" "$PUB_CT" 2>&1)"
JOINED_OK="$(printf '%s\n' "$JOINED" | sed -n '1p')"
ONE_HALF="$(printf '%s\n' "$JOINED" | sed -n '2p')"
assert_eq "the two containers JOIN, in the private-then-public order the grammar declares" \
  "{\"joinId\":\"$JOIN_ID\",\"arm\":\"split\",\"order\":[\"private\",\"public\"]}" "$JOINED_OK"
# THE REFUSAL IS PRODUCED. Without it, "the join works" is an assertion over a function that has
# never been seen to say no — and `halves` is in the grammar precisely so an incomplete join is a
# refusal rather than a smaller answer.
assert_eq "and one half alone is refused on count-mismatch" "count-mismatch" "$ONE_HALF"

# ===========================================================================================
echo "== 6. THE MODULE: PUBLISHED, IMPORT-FREE IN PRACTICE, AND OQ-7 UNTOUCHED"
# ===========================================================================================
DECLARED="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' \
  "$(m40_arm "$SUBJECT.report.privateContainer.declaredImports")")"
assert_ge "the module DECLARES imports, so 'reached none' is not a vacuous statement" 1 "$DECLARED"
assert_eq "and it reached NONE of them: nothing in the tracer crossed back into JavaScript" "[]" \
  "$(m40_arm "$SUBJECT.report.privateContainer.reachedImports")"

# THE MODULE IS BUILT FROM A PUBLISHED COMMIT. *A pin that is not published is not a pin, it is a
# local file* — and this module is the one thing in M40 a fresh clone would have to rebuild.
NOIR_ROOT="$(cd "$REPO_ROOT/.." && pwd)/noir"
assert_dir "the Noir checkout is beside this one" "$NOIR_ROOT"
NOIR_HEAD="$(git -C "$NOIR_ROOT" rev-parse HEAD 2>/dev/null)"
assert_true "its HEAD is readable" test -n "$NOIR_HEAD"
assert_eq "and it is on the branch that ships" "codetracer" \
  "$(git -C "$NOIR_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
assert_ge "its HEAD is contained in at least one published remote ref" 1 \
  "$(git -C "$NOIR_ROOT" for-each-ref --contains "$NOIR_HEAD" --format='%(refname)' refs/remotes 2>/dev/null | grep -c .)"

# AND `wasm/webpage` IS STILL UNPUBLISHED, which is `JOIN-SHAPE.md` §2 fact 7 and the fact OQ-7's
# whole verdict rests on. M40 steps a private half in a browser WITHOUT that branch, so the check
# that would notice it being reopened is run here too rather than left to M26's.
WT="$(cd "$REPO_ROOT/.." && pwd)/noir-wt4-webpage"
if [ -e "$WT/.git" ]; then
  WT_HEAD="$(git -C "$WT" rev-parse HEAD 2>/dev/null)"
  assert_eq "OQ-7's fact 7 still holds: wasm/webpage is in ZERO published remote refs" "0" \
    "$(git -C "$WT" for-each-ref --contains "$WT_HEAD" --format='%(refname)' refs/remotes 2>/dev/null | grep -c .)"
  assert_eq "and that worktree carries exactly its one pre-existing edit" "1" \
    "$(git -C "$WT" status --porcelain 2>/dev/null | grep -c .)"
else
  note "no noir-wt4-webpage worktree beside this repository; OQ-7's fact 7 is M26's check's to make"
fi
# NOTHING M40 SHIPS NAMES THAT WORKTREE. A grep over M40's own files, which is the half a
# publication check cannot make.
assert_eq "no M40 file reaches for the unpublished worktree" "0" \
  "$(grep -l 'noir-wt4-webpage' \
       "$REPO_ROOT/verification/build_m40_private_trace_wasm.sh" \
       "$REPO_ROOT/verification/m40_private_trace_wasm.rs" \
       "$REPO_ROOT/verification/lib_m40_transaction.sh" \
       "$REPO_ROOT/tools/run_m40_transaction_arms.mjs" \
       "$REPO_ROOT/tools/run_m40_trace_arms.mjs" \
       "$REPO_ROOT/browser/src/private_half_container.ts" 2>/dev/null \
     | xargs -r -n1 basename | grep -cv '^build_m40_private_trace_wasm.sh$' || true)"

# ===========================================================================================
echo "== 7. BOTH-HALVES.md sections 3 and 4 ARE RE-DERIVED FROM THIS RUN"
# ===========================================================================================
assert_file "the write-up exists" "$M40_DOC"
m38_assert_doc "BOTH-HALVES.md sections 3 and 4" "$M40_DOC" \
  "steps the browser's tracer produced|0|$PSTEPS" \
  "of those, carrying a COLUMN|0|$PCOLS" \
  "private frames in the container|0|$PFRAMES" \
  "ops replayed into the writer|0|$POPS" \
  "paths the private container interns|0|$PPATHS" \
  "the private half's container bytes|0|$PBYTES" \
  "steps the NATIVE probe produced|0|$NSTEPS" \
  "column differences between them|0|$COLDIFF_N" \
  "imports the tracer module declares|0|$DECLARED"

# THE COMPARER IS CALIBRATED OVER THIS DOCUMENT, both ways, because a document comparer that has
# never been shown to say `BAD` is a comparer nobody has run.
CAL="$(m38_doc_figures "$M40_DOC" "steps the browser's tracer produced|0|999999")"
assert_true "a wrong expected figure is reported as BAD" str_has_sub "$CAL" "BAD"
CAL2="$(m38_doc_figures "$M40_DOC" "a row this document does not carry|0|1")"
assert_true "and a needle no row carries is reported as MISSING" str_has_sub "$CAL2" "MISSING"

m40_finish
