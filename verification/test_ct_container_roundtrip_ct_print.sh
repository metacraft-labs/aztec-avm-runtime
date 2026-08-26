#!/usr/bin/env bash
# test_ct_container_roundtrip_ct_print
#
# M24 verification: a container written from the runtime parses under `ct-print --full`, and its
# DECODED CONTENT matches what was written.
#
# "PARSES" IS NOT THE CLAIM AND WOULD BE THE WEAK ONE. A reader that accepted anything would pass
# it, and so would a container carrying somebody else's events. What is asserted is the decoded
# content: the step count equals the events pushed, the value count equals five per step because
# `emit()` writes five variables, the metadata is the metadata this host supplied, and the path
# table has exactly the one path.
#
# AND `ct-print` IS ITSELF UNDER TEST HERE, IN BOTH DIRECTIONS. DD-7 records that a wasm-produced
# Path A container cannot be read by stock `ct-print`, because the Rust zstd frame compressor
# leaves every frame unpledged. That is a claim about a DIFFERENCE, so it is held as one:
# `build_ct_print.sh` builds the reader at `pins.json`'s `trace_format_nim` commit AND at its
# `control_commit` — the parent of the one-line fix — and both are run against the same bytes.
# Without the second, "our reader reads it" is satisfied by a container any reader would read, and
# the reason for pinning a special reader would be unevidenced.
#
# THE SYMPTOM IS ASSERTED, NOT JUST THE STATUS, and it is not the symptom §9.3 predicted: the
# pre-fix reader exits 1 with `chunk compressed data extends beyond events.log`, not with a
# `RangeDefect`. Pinning the text is what stops the pre-fix arm passing for some unrelated reason
# — a missing file, a bad argument — which would make the whole comparison meaningless.
#
# ===========================================================================
# EVERY ASSERTION ABOVE WAS SATISFIED OUT OF `events.log`, AND THE SPLIT STREAMS WERE NEVER READ.
#
# `codetracer_ct_print.nim` chooses its reader by whether the container carries `events.log` and
# diverts to the LEGACY combined-stream reader when it does. Its own comment gives the reason and
# names the consequence:
#
#   "the SECONDARY Rust `CtfsTraceWriter` now also default-emits the split streams, but
#    ADDITIVELY … and its `steps.dat` / `values.dat` / `events.dat` wire formats are NOT
#    v4-readable … Routing such a bundle through the v4 reader would yield an empty/garbled
#    event array. So ANY bundle that carries `events.log` is read via the legacy reader"
#
# Every container this runtime produces carries `events.log`. So the step count, the value count,
# the path, the program, the workdir, the call, the function, the five variable names and the
# first and last line were all decoded from ONE stream, and `steps.dat`, `values.dat`,
# `calls.dat` and `events.dat` were never opened. **This check reported green over a container in
# which all four were unreadable by the reference reader** — which is exactly what a Path A
# container at the OLD `trace_format` anchor was: every stream framed by a streaming zstd encoder,
# whose header omits the pledged content size that the v4 stream readers require, and three of the
# four then read back as ZERO RECORDS rather than refusing.
#
# So a third reader is built, from the SAME pinned revision, out of the same object store:
# `ct-split-probe` (`verification/ct_split_probe.nim`) opens the container through `openNewTrace`
# — the v4 split-stream reader `ct-print` declines to use here — and reports each stream's answer,
# an unreadable one as `ERR:<stream>: <reason>`. The block at the end of this file asserts the
# four counts against the arm report, pulls a real value record and a real call record, and
# compares every figure the two readers BOTH know against each other.
#
# Proved by mutation rather than declared: with `pins.json`'s `trace_format` set back to
# `9cbc127ef8` and the module rebuilt, this check goes RED and names the streams. The measured
# output is in the anchor-move log.
#
# ONE STREAM HAS NO COVERAGE HERE AND IT IS SAID PLAINLY: `events.dat` holds I/O events and this
# runtime records none, so it is empty in every container this check sees and reads back as zero
# whether or not its framing is right. The frame census below reports `frames=0` for it, which is
# a visible degenerate case rather than a silent pass; the call site is pinned upstream by
# `codetracer_ctfs`'s own `no_stream_writer_uses_the_streaming_zstd_api` census.
# ===========================================================================
#
# Run: just verify-ct-roundtrip

TEST_NAME="test_ct_container_roundtrip_ct_print"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m24_ct_writer.sh"
m24_summary_on_abnormal_exit

command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m24_require_arms
ARMS="$M24_ARMS"
assert_file "the arms run produced its report" "$ARMS"
m24_require_readers
READERS="$M24_READERS"
assert_dir "both ct-print readers were built" "$READERS"
assert_file "and the split-stream probe, from the same pinned revision" "$READERS/ct-split-probe"
assert_eq "the probe is built at the SAME revision as the reader, not some other tree" \
  "$(m24_pin trace_format_nim commit)" \
  "$(cat "$READERS/ct-split-probe.rev" 2>/dev/null | tr -d '[:space:]')"

CT="$(m24_arm 'd["roundtrip"]["file"]')"
assert_file "the roundtrip arm wrote a container" "$CT"
assert_ge "the container is a plausible size" "10000" "$(m24_arm 'd["roundtrip"]["containerBytes"]')"

# The events the host claims to have written. Read from the arm report, never restated here: a
# constant typed into a check looks like a measurement to the person typing it.
EVENTS="$(m24_arm 'd["roundtrip"]["events"]')"
REQUESTED="$(m24_arm 'd["roundtrip"]["requested"]')"
EXP_STEPS="$(m24_arm 'd["roundtrip"]["expectedSteps"]')"
EXP_VALUES="$(m24_arm 'd["roundtrip"]["expectedValues"]')"
assert_eq "the module accepted every event the host pushed" "$REQUESTED" "$EVENTS"
assert_eq "and the expected step count is that same number" "$EVENTS" "$EXP_STEPS"
assert_eq "the crossing count is exactly ceil(events / batch)" \
  "$(m24_arm 'd["roundtrip"]["expectedCrossings"]')" "$(m24_arm 'd["roundtrip"]["crossings"]')"

# ---------------------------------------------------------------------------
# THE READER AT THE PIN: it must read the container, and the content must be right.
# ---------------------------------------------------------------------------
OUT_FILE="$M24_WORK/roundtrip.ct-print.json"
m24_run_bounded "$M24_READER_TIMEOUT" "ct-print at the pin" \
  "$READERS/ct-print" --full "$CT" >"$OUT_FILE" 2>"$OUT_FILE.err"
rc_fixed=$?
assert_eq "ct-print at the pinned revision reads the container (exit 0)" "0" "$rc_fixed"
assert_ge "and produced a substantial amount of JSON" "1000" "$(wc -c <"$OUT_FILE" 2>/dev/null || echo 0)"

DECODED="$(python3 - "$OUT_FILE" <<'PY'
import json, sys
from collections import Counter
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("PROBLEM\t%s" % e); raise SystemExit(0)
c = Counter(e.get("type") for e in d.get("events", []))
print("PROGRAM\t%s" % d.get("metadata", {}).get("program", "MISSING"))
print("WORKDIR\t%s" % d.get("metadata", {}).get("workdir", "MISSING"))
print("PATHS\t%d" % len(d.get("paths", [])))
print("PATH0\t%s" % (d.get("paths") or ["MISSING"])[0])
for k in ("Step", "Value", "Path", "Function", "Call", "VariableName", "Type"):
    print("COUNT_%s\t%d" % (k, c.get(k, 0)))
steps = [e for e in d.get("events", []) if e.get("type") == "Step"]
print("FIRSTLINE\t%s" % (steps[0].get("line") if steps else "MISSING"))
print("LASTLINE\t%s" % (steps[-1].get("line") if steps else "MISSING"))
names = sorted({e.get("name") for e in d.get("events", []) if e.get("type") == "VariableName"})
print("VARNAMES\t%s" % ",".join(str(n) for n in names))
PY
)" || die "the decoded container could not be summarised"
[ -n "$DECODED" ] || die "the container summary is empty"
assert_not_contains "the JSON ct-print produced is well formed" "PROBLEM" "$DECODED"

dv() { printf '%s\n' "$DECODED" | sed -n "s/^$1\t//p"; }

assert_eq "the decoded step count equals the events the host wrote" "$EXP_STEPS" "$(dv COUNT_Step)"
assert_eq "the decoded value count is five per step, which is what emit() writes" \
  "$EXP_VALUES" "$(dv COUNT_Value)"
assert_eq "there is exactly one path in the container" "1" "$(dv PATHS)"
assert_eq "one Path event, matching" "1" "$(dv COUNT_Path)"
assert_eq "the path is the source path the host configured" "/aztec/tx.avm" "$(dv PATH0)"
assert_eq "the program name is the one the host configured" "aztec-avm-runtime" "$(dv PROGRAM)"
assert_eq "the workdir is the one the host supplied (wasm has no current directory)" \
  "/aztec" "$(dv WORKDIR)"
assert_eq "the recording opens with exactly one Call frame" "1" "$(dv COUNT_Call)"
assert_eq "and exactly one Function" "1" "$(dv COUNT_Function)"
# The five variable names, as a SET and by name. A count of five would pass on five wrong names.
assert_eq "the five per-step variables are exactly the fields emit() records" \
  "contextId,contractAddressLow,daGas,l2Gas,opcode" "$(dv VARNAMES)"
# The pc of the first and last event, carried through the ABI, the module and the container.
assert_eq "the first step's line is the first event's pc" \
  "$(m24_arm 'd["roundtrip"]["firstPc"]')" "$(dv FIRSTLINE)"
assert_eq "the last step's line is the last event's pc" \
  "$(m24_arm 'd["roundtrip"]["lastPc"]')" "$(dv LASTLINE)"

# ---------------------------------------------------------------------------
# THE CONTROL: the SAME reader one commit earlier must NOT read it.
# ---------------------------------------------------------------------------
PRE_OUT="$M24_WORK/roundtrip.ct-print-pre.txt"
m24_run_bounded "$M24_READER_TIMEOUT" "ct-print before the fix" \
  "$READERS/ct-print-pre" --full "$CT" >"$PRE_OUT" 2>&1
rc_pre=$?
assert_eq "ct-print at the fix's PARENT refuses the container (exit 1)" "1" "$rc_pre"
# AND FOR THE REASON THAT IS STILL TRUE AFTER THE ANCHOR MOVED, WHICH IS NOT THE ONE IT WAS.
#
# `baea074` fixes TWO independent mismatches and its message names both: the Rust writer prefixes
# `events.log` with the 8-byte CodeTracer file header the Nim writer omits, and its chunks were
# streaming-encoder frames with no pledged content size. The `trace_format` move retired the
# SECOND — every frame pledges now, asserted stream by stream at the end of this file — and did
# not touch the first. So what the parent still refuses over is the HEADER PREFIX, and this
# assertion said "the unpledged-frame reason" until the anchor-move review renamed it. The
# message text is unchanged and is still what is pinned; only the cause it is attributed to moved.
assert_true "and refuses it for the events.log header-prefix reason, by its own words" \
  str_has_sub "$(cat "$PRE_OUT" 2>/dev/null)" 'chunk compressed data extends beyond events.log'
assert_false "the pre-fix reader produced no container JSON at all" \
  str_has_sub "$(cat "$PRE_OUT" 2>/dev/null)" '"metadata"'

# The two readers differ by ONE COMMIT, and that is the claim. Asserted from pins.json and from
# git, so a control_commit that drifted away from being the fix's parent is a failure.
FIX="$(m24_pin trace_format_nim commit)"
CONTROL="$(m24_pin trace_format_nim control_commit)"
assert_true "pins.json declares the reader commit" str_has_re "$FIX" '^[0-9a-f]{40}$'
assert_true "pins.json declares its control commit" str_has_re "$CONTROL" '^[0-9a-f]{40}$'
NIM_REPO="$WORKSPACE_ROOT/codetracer-trace-format-nim"
assert_dir "the trace-format-nim checkout is present" "$NIM_REPO"
assert_eq "the control commit IS the reader commit's parent — a one-commit difference" \
  "$CONTROL" "$(git -C "$NIM_REPO" rev-parse "$FIX^" 2>/dev/null || echo MISSING)"
assert_eq "the built reader is the pinned revision" "$FIX" \
  "$(cat "$READERS/ct-print.rev" 2>/dev/null | tr -d '[:space:]')"
assert_eq "the built control is the pinned control revision" "$CONTROL" \
  "$(cat "$READERS/ct-print-pre.rev" 2>/dev/null | tr -d '[:space:]')"
assert_true "the one commit between them is the reader fix, by its subject" \
  str_has_sub "$(git -C "$NIM_REPO" log -1 --format=%s "$FIX" 2>/dev/null)" \
  'read an events.log written by the Rust CtfsTraceWriter'
assert_ge "and it adds the unknown-size frame decompressor" "1" \
  "$(git -C "$NIM_REPO" show "$FIX" 2>/dev/null | grep -c '^+.*decompressFrameOfUnknownSize' || true)"

# BOTH PINNED COMMITS ARE PUBLISHED. See `m24_published_refcount` in lib_m24_ct_writer.sh: M24
# pinned this reader — and its control — to commits that existed only on a local branch on one
# machine. `build_ct_print.sh` builds both out of this object store, so it succeeded here and
# would have failed in CI and in any other checkout, with every assertion above still green. The
# instrument's own negative control lives in `verify_ct_writer_wasm_zero_imports`.
assert_ge "the pinned reader commit is reachable from a PUBLISHED remote ref" "1" \
  "$(m24_published_refcount "$NIM_REPO" "$FIX")"
assert_ge "and so is the control commit the difference is measured against" "1" \
  "$(m24_published_refcount "$NIM_REPO" "$CONTROL")"

# ---------------------------------------------------------------------------
# THE CONTROL FOR THE CONTROL: the pre-fix reader is not simply broken.
#
# Without this, "ct-print-pre exits 1" is satisfied by a binary that exits 1 on everything, and
# the one-commit story would be unevidenced. A container the OLD reader CAN read is the answer,
# and there is one to hand: `ctfnim-wt-wasm`'s own fixture, or failing that the pre-fix reader's
# response to `--help`, which must not be the unpledged-frame error.
# ---------------------------------------------------------------------------
help_out="$(m24_run_bounded 60 "ct-print-pre --help" "$READERS/ct-print-pre" --help 2>&1)"
assert_false "the pre-fix reader is not simply broken: --help is not the frame error" \
  str_has_sub "$help_out" 'chunk compressed data extends beyond events.log'
assert_ge "and it printed something" "10" "$(printf '%s' "$help_out" | wc -c)"
missing_out="$(m24_run_bounded 60 "ct-print-pre on a missing file" \
  "$READERS/ct-print-pre" --full "$M24_WORK/definitely-not-here.ct" 2>&1)"
assert_false "and a MISSING file gives it a different complaint, so exit 1 is not its only mode" \
  str_has_sub "$missing_out" 'chunk compressed data extends beyond events.log'

# ---------------------------------------------------------------------------
# THE TWO ABIs PRODUCE THE SAME CONTAINER. M15's phrasing: the choice is about cost, not
# semantics — and here that is a byte comparison rather than a design intention.
# ---------------------------------------------------------------------------
assert_eq "the same events through both ABIs produce byte-identical containers" "true" \
  "$(m24_arm 'd["equivalence"]["identical"]')"
assert_eq "the two containers are the same length" \
  "$(m24_arm 'd["equivalence"]["batchedBytes"]')" "$(m24_arm 'd["equivalence"]["perEventBytes"]')"
# NON-DEGENERACY: an identity over two empty containers is the M23 shape. Both must be substantial
# and the crossing counts must genuinely differ, or "identical" means "both did nothing".
assert_ge "and they are not two empty containers" "10000" \
  "$(m24_arm 'd["equivalence"]["batchedBytes"]')"
assert_eq "the per-event arm really did cross once per event" \
  "$(m24_arm 'd["equivalence"]["events"]')" "$(m24_arm 'd["equivalence"]["perEventCrossings"]')"
assert_true "and the batched arm crossed far fewer times, so the arms are not the same run" \
  test "$(m24_arm 'd["equivalence"]["batchedCrossings"]')" -lt "$(m24_arm 'd["equivalence"]["perEventCrossings"]')"

# Both of those containers must READ, too — an identity between two unreadable files proves
# nothing about either.
for side in batched perEvent; do
  f="$(m24_arm "d[\"equivalence\"][\"${side}File\"]")"
  assert_file "the $side equivalence container exists" "$f"
  m24_run_bounded "$M24_READER_TIMEOUT" "ct-print on the $side container" \
    "$READERS/ct-print" --full "$f" >/dev/null 2>&1
  assert_eq "ct-print reads the $side equivalence container" "0" "$?"
done

# ---------------------------------------------------------------------------
# The container is a CTFS container by its own magic, read from the bytes.
# ---------------------------------------------------------------------------
MAGIC="$(python3 -c '
import sys
b = open(sys.argv[1], "rb").read(6)
print(" ".join("%02x" % x for x in b))' "$CT")"
assert_eq "the container carries the CTFS magic and version" "c0 de 72 ac e2 03" "$MAGIC"

# ===========================================================================
# THE SPLIT STREAMS, THROUGH THE REFERENCE READER. See this file's header for why nothing above
# reaches them.
# ===========================================================================
SPLIT="$(m24_split_probe "$CT")" || die "the split-stream probe could not be run"
[ -n "$SPLIT" ] || die "the split-stream probe printed nothing"
sv() { printf '%s\n' "$SPLIT" | sed -n "s/^$1"$'\t'"//p"; }

assert_eq "the split-stream probe ran to the end (a partial read is not a small answer)" \
  "ok" "$(sv DONE)"
assert_eq "the v4 split-stream reader opens the container" "ok" "$(sv OPEN)"

# --- steps.dat -------------------------------------------------------------
assert_eq "steps.dat DECODES, and its step count is the events the host wrote" \
  "$EXP_STEPS" "$(sv STEP_COUNT)"
assert_eq "and the exec stream was really opened rather than answered from somewhere else" \
  "true" "$(sv EXEC_LOADED)"
assert_ge "and at least one steps.dat zstd chunk was inflated to answer" "1" \
  "$(sv EXEC_CHUNK_DECOMPRESSIONS)"
# CONTENT, not a count: the position of the first and last step, decoded out of steps.dat, is the
# pc the host pushed. Read from the arm report on one side and from the compressed stream on the
# other, so neither side is a constant typed here.
assert_eq "the first step's position, out of steps.dat, is the first event's pc" \
  "$(m24_arm 'd["roundtrip"]["firstPc"]')" "$(sv STEP0_GLI)"
assert_eq "and the last step's position is the last event's pc" \
  "$(m24_arm 'd["roundtrip"]["lastPc"]')" "$(sv STEPLAST_GLI)"

# --- values.dat ------------------------------------------------------------
assert_eq "values.dat DECODES, one value record per step" "$EXP_STEPS" "$(sv VALUE_COUNT)"
assert_eq "and the value stream was really opened" "true" "$(sv VALUE_LOADED)"
# A COUNT IS NOT A READ: `values.idx` is uncompressed, so a container whose `values.dat` frames
# are unreadable still reports the right count. Pulling step 0's record is what exercises the
# compressed stream, and the names come back out of `varnames.dat` with it.
assert_eq "step 0's record carries the five variables emit() writes" "5" "$(sv VALUES0_COUNT)"
assert_eq "by name, decoded from the split streams rather than from events.log" \
  "contextId,contractAddressLow,daGas,l2Gas,opcode" "$(sv VALUES0_NAMES)"
assert_ge "with real CBOR bytes behind them, not five empty records" "1" "$(sv VALUES0_BYTES)"

# --- calls.dat -------------------------------------------------------------
assert_eq "calls.dat DECODES, and the call stream was really opened" "true" "$(sv CALL_LOADED)"
assert_eq "the recording's one frame is there" "1" "$(sv CALL_COUNT)"
assert_eq "it opens at the first step" "0" "$(sv CALL0_ENTRY_STEP)"
assert_eq "and closes at the last, so the frame spans the recording" \
  "$((EXP_STEPS - 1))" "$(sv CALL0_EXIT_STEP)"
assert_eq "at depth 0, because it is the only frame" "0" "$(sv CALL0_DEPTH)"

# --- events.dat ------------------------------------------------------------
# DECLARED AS UNCOVERED RATHER THAN ASSERTED VACUOUSLY. This runtime records no I/O events, so
# `events.dat` is empty and reads back as zero whichever way it is framed. The reachability is
# asserted; the count is not evidence about framing and is not offered as any.
assert_eq "events.dat is reachable by the reader" "true" "$(sv IOEVENT_LOADED)"
assert_eq "and holds the zero I/O events this runtime records" "0" "$(sv IOEVENT_COUNT)"

# --- the frame pledge, measured off the container bytes ---------------------
#
# THE CAUSE, NOT THE SYMPTOM. Every assertion above fails when a frame does not pledge, but it
# fails as "zero records" or as a decode error, and neither names the defect. This walks each
# stream frame by frame and asks the header directly, so a red line here says which stream and
# how many frames.
assert_true "every steps.dat frame pledges its content size" \
  str_has_re "$(sv PLEDGE_steps.dat)" '^frames=[1-9][0-9]* pledged=[1-9][0-9]* unpledged=0$'
assert_true "every values.dat frame pledges its content size" \
  str_has_re "$(sv PLEDGE_values.dat)" '^frames=[1-9][0-9]* pledged=[1-9][0-9]* unpledged=0$'
assert_true "every calls.dat frame pledges its content size" \
  str_has_re "$(sv PLEDGE_calls.dat)" '^frames=[1-9][0-9]* pledged=[1-9][0-9]* unpledged=0$'
# NON-DEGENERACY on the census itself: `frames=0 pledged=0 unpledged=0` satisfies "no unpledged
# frames" and means nothing was looked at. The patterns above require a non-zero frame count, and
# these two assert the counts are the ones the reader actually inflated.
assert_ge "the steps.dat census walked at least as many frames as the reader inflated" \
  "$(sv EXEC_CHUNK_DECOMPRESSIONS)" \
  "$(printf '%s' "$(sv PLEDGE_steps.dat)" | sed -n 's/^frames=\([0-9]*\).*/\1/p')"
assert_eq "and events.dat is empty rather than unreadable, which is why it proves nothing" \
  "frames=0 pledged=0 unpledged=0" "$(sv PLEDGE_events.dat)"

# --- THE TWO READERS MUST AGREE, AND NEITHER MAY BE ZERO --------------------
#
# The legacy decode above and the split decode here are two independent reads of the same bytes.
# Comparing them is what makes each one a check on the other. The non-degeneracy is already
# established: `COUNT_Step` is asserted equal to `$EXP_STEPS`, which comes from the arm report.
assert_eq "events.log and steps.dat agree on the step count" "$(dv COUNT_Step)" "$(sv STEP_COUNT)"
assert_eq "events.log and calls.dat agree on the call count" "$(dv COUNT_Call)" "$(sv CALL_COUNT)"
# THE PRODUCT IS GUARDED, AND THE MUTATION IS WHY.
#
# With the anchor put back to `9cbc127ef8`, `VALUE_COUNT` reads
# `ERR:values.dat: cannot determine decompressed size for value chunk` — and
# `$(( ERR:… * ERR:… ))` is a bash arithmetic SYNTAX ERROR, which killed the check outright.
# 21 assertions had already gone red and named the streams, so the mutation was detected; what it
# also did was stop the seven assertions below it from running at all. M22's abnormal-exit trap
# printed the summary, so it read as 76 rather than as silence — but "a check that dies partway
# reads as a smaller check" is the shape this campaign has met four times, and a check must not
# have that shape in the very run it was written to survive. Non-numeric input produces a loud
# value that FAILS the comparison instead of ending the process.
V_RECORDS="$(sv VALUE_COUNT)"
V_PER_STEP="$(sv VALUES0_COUNT)"
if str_has_re "$V_RECORDS" '^[0-9]+$' && str_has_re "$V_PER_STEP" '^[0-9]+$'; then
  V_TOTAL="$(( V_RECORDS * V_PER_STEP ))"
else
  V_TOTAL="UNREADABLE [$V_RECORDS] x [$V_PER_STEP]"
fi
assert_eq "events.log and values.dat agree on the total value count" \
  "$(dv COUNT_Value)" "$V_TOTAL"
assert_eq "and on the variable names, as a set" "$(dv VARNAMES)" "$(sv VALUES0_NAMES)"
assert_eq "and on the first step's line" "$(dv FIRSTLINE)" "$(sv STEP0_GLI)"
assert_eq "and on the last step's line" "$(dv LASTLINE)" "$(sv STEPLAST_GLI)"
assert_eq "and on the one source path" "$(dv PATH0)" "$(sv PATH0)"

# --- THE INSTRUMENT'S OWN CONTROL ------------------------------------------
#
# Every assertion above is satisfied by a probe that cannot see a problem. Asked of a file that is
# not a CTFS container, it must report the streams as UNREADABLE rather than as zero — and asked
# of a file that is not there at all, it must say so against OPEN. Without these, "steps.dat
# decodes" is a statement about the probe.
NOT_A_CONTAINER="$M24_WORK/not-a-container.bin"
mkdir -p "$M24_WORK" || die "could not create $M24_WORK"
head -c 4096 /dev/urandom >"$NOT_A_CONTAINER" 2>/dev/null || die "could not write $NOT_A_CONTAINER"
CTRL="$(m24_split_probe "$NOT_A_CONTAINER")"
cv() { printf '%s\n' "$CTRL" | sed -n "s/^$1"$'\t'"//p"; }
assert_true "CONTROL: over a file that is not a container, steps.dat is reported UNREADABLE" \
  str_has_sub "$(cv STEP_COUNT)" 'ERR:steps.dat:'
assert_true "CONTROL: and so is values.dat" str_has_sub "$(cv VALUE_COUNT)" 'ERR:values.dat:'
assert_true "CONTROL: and so is calls.dat" str_has_sub "$(cv CALL_COUNT)" 'ERR:calls.dat:'
assert_false "CONTROL: and it does NOT report a step count there" \
  str_has_re "$(cv STEP_COUNT)" '^[0-9]+$'
MISSING_OUT="$(m24_split_probe "$M24_WORK/definitely-not-here.ct")"
assert_true "CONTROL: a missing file is reported against OPEN, not as an empty container" \
  str_has_sub "$(printf '%s\n' "$MISSING_OUT" | sed -n "s/^OPEN"$'\t'"//p")" 'ERR:no such file'

m24_finish
