#!/usr/bin/env bash
# test_trace_writer_backpressure
#
# M24 verification: a transaction emitting far more events than one batch can hold writes a
# CORRECT container without unbounded host-side buffering.
#
# THERE ARE TWO HALVES AND THE SECOND IS THE ONE THAT IS EASY TO FAKE. "Without unbounded
# buffering" is satisfied by a host that drops events; "a correct container" is satisfied by a
# host that buffers everything. Both are asserted over the SAME run, and the event count in the
# container is compared against the count the host pushed.
#
# THE MEASUREMENT IS A RATIO, NOT A THRESHOLD. A bound like "under a megabyte" passes on a host
# that buffers linearly as long as the test is small enough, which is exactly how a scaling defect
# survives. The arms run drives 25,000 events and then 250,000 — TEN TIMES — at a QUARTER of the
# roundtrip arm's batch size, so a buffer that scaled with the event count would be forty times
# larger than the roundtrip's and cannot hide behind a wide bound.
#
# AND THE CROSSING COUNT IS AN IDENTITY, NOT A BOUND. `ceil(N / batch)` exactly, on both arms.
# A host that flushed early, late or twice would still produce a correct container and would still
# bound its buffer; the identity is what says the batching is the batching that was designed.
#
# THE MEMORY-GROWTH PATH IS ASSERTED TO HAVE BEEN EXERCISED. `WebAssembly.Memory.grow` DETACHES
# `memory.buffer`, killing every cached `DataView`. At 250,000 events it happens hundreds of
# times. A run in which it never happened would prove nothing about the host's handling of it, and
# `memoryGrowths` is counted so that "the code path exists" and "the code path ran" are different
# statements.
#
# Run: just verify-ct-backpressure

TEST_NAME="test_trace_writer_backpressure"
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

SMALL_N="$(m24_arm 'd["backpressure"]["smallEvents"]')"
LARGE_N="$(m24_arm 'd["backpressure"]["largeEvents"]')"
RATIO="$(m24_arm 'int(d["backpressure"]["ratio"])')"

# ---- the arms are what they claim to be ------------------------------------
assert_ge "the small arm drove a substantial number of events" "10000" "$SMALL_N"
assert_ge "the large arm drove far more" "200000" "$LARGE_N"
assert_eq "the large arm is exactly ten times the small one" "10" "$RATIO"
assert_ge "the large arm's event count is many batches' worth" "100" \
  "$(m24_arm 'd["backpressure"]["largeEvents"] // 1024')"

# ---- HALF ONE: the buffering is bounded, and the bound does not move --------
SMALL_BUF="$(m24_arm 'd["backpressure"]["smallBufferBytes"]')"
LARGE_BUF="$(m24_arm 'd["backpressure"]["largeBufferBytes"]')"
assert_eq "host-side buffering is IDENTICAL at ten times the events" "$SMALL_BUF" "$LARGE_BUF"
assert_eq "and it is exactly batchRecords x the record size" "65536" "$LARGE_BUF"
# NON-DEGENERACY: two zeros are equal too. A buffer of zero bytes would mean the batched path is
# not batching at all, and the equality above would still hold.
assert_ge "and it is not zero, so the equality is not two absences" "1024" "$LARGE_BUF"
# The roundtrip arm uses a DIFFERENT batch size, so "constant" is not "hardcoded".
assert_eq "the roundtrip arm's buffer differs, so the size follows batchRecords rather than a constant" \
  "32768" "$(m24_arm 'd["roundtrip"]["bufferBytes"]')"

# The heap. Reported and bounded loosely, because a JS heap measurement is noisy by nature and a
# tight bound here would be a flake generator. What it must NOT do is scale with the event count.
SMALL_HEAP="$(m24_arm 'd["backpressure"]["smallHeapDeltaBytes"]')"
LARGE_HEAP="$(m24_arm 'd["backpressure"]["largeHeapDeltaBytes"]')"
note "heap delta during ingest: small $SMALL_HEAP B, large $LARGE_HEAP B (10x the events)"
HEAP_RATIO_TENTHS="$(python3 -c '
import sys
s, l = int(sys.argv[1]), int(sys.argv[2])
print(int(round(10.0 * l / s)) if s > 0 else 999)' "$SMALL_HEAP" "$LARGE_HEAP")"
assert_true "the host heap does not scale with the event count (ratio well under 10x for 10x events)" \
  test "$HEAP_RATIO_TENTHS" -lt 40
note "heap delta ratio: ${HEAP_RATIO_TENTHS} tenths (a linear host would be about 100)"

# ---- the crossing count is an identity -------------------------------------
assert_eq "the small arm crossed exactly ceil(N / batch) times" \
  "$(m24_arm 'd["backpressure"]["smallExpectedCrossings"]')" \
  "$(m24_arm 'd["backpressure"]["smallCrossings"]')"
assert_eq "and so did the large arm" \
  "$(m24_arm 'd["backpressure"]["largeExpectedCrossings"]')" \
  "$(m24_arm 'd["backpressure"]["largeCrossings"]')"
assert_ge "the large arm really did cross many times, so the identity is not 1 == 1" "100" \
  "$(m24_arm 'd["backpressure"]["largeCrossings"]')"

# ---- the detach path was exercised -----------------------------------------
assert_ge "linear memory grew during the large recording, so the buffer-detach path RAN" "1" \
  "$(m24_arm 'd["backpressure"]["largeMemoryGrowths"]')"
assert_ge "and it happened many times, not once by luck" "10" \
  "$(m24_arm 'd["backpressure"]["largeMemoryGrowths"]')"

# ---- HALF TWO: the container is CORRECT ------------------------------------
CT="$(m24_arm 'd["backpressure"]["largeFile"]')"
assert_file "the large arm wrote a container" "$CT"
assert_ge "and it is large, in proportion to its events" "5000000" \
  "$(m24_arm 'd["backpressure"]["largeContainerBytes"]')"

OUT="$M24_WORK/backpressure.ct-print.json"
m24_run_bounded "$M24_READER_TIMEOUT" "ct-print on the backpressure container" \
  "$READERS/ct-print" --full "$CT" >"$OUT" 2>"$OUT.err"
assert_eq "ct-print reads the 250,000-event container (exit 0)" "0" "$?"

SUMMARY="$(python3 - "$OUT" <<'PY'
import json, sys
from collections import Counter
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("PROBLEM\t%s" % e); raise SystemExit(0)
c = Counter(e.get("type") for e in d.get("events", []))
print("STEPS\t%d" % c.get("Step", 0))
print("VALUES\t%d" % c.get("Value", 0))
print("PATHS\t%d" % len(d.get("paths", [])))
steps = [e for e in d.get("events", []) if e.get("type") == "Step"]
lines = {e.get("line") for e in steps}
print("DISTINCTLINES\t%d" % len(lines))
print("PROGRAM\t%s" % d.get("metadata", {}).get("program", "MISSING"))
PY
)" || die "the backpressure container could not be summarised"
[ -n "$SUMMARY" ] || die "the container summary is empty"
assert_not_contains "the JSON is well formed" "PROBLEM" "$SUMMARY"

sv() { printf '%s\n' "$SUMMARY" | sed -n "s/^$1\t//p"; }

# EVERY EVENT IS IN THE CONTAINER. This is the half that a dropping host would fail, and it is
# compared against the number the HOST pushed rather than against a constant typed here.
assert_eq "every one of the events pushed is a Step in the container" "$LARGE_N" "$(sv STEPS)"
assert_eq "and each carries its five variables" "$((LARGE_N * 5))" "$(sv VALUES)"
assert_eq "one path, as configured" "1" "$(sv PATHS)"
assert_eq "and the metadata survived a container this size" "aztec-avm-runtime" "$(sv PROGRAM)"
# NOT ALL THE SAME STEP. A host that wrote one event 250,000 times would satisfy every count
# above; the pcs the driver generates cycle over 4,093 values, so the distinct line count is a
# statement about the DATA reaching the writer and not just about its volume.
assert_ge "the steps carry many distinct pcs, so the data reached the writer and not just the count" \
  "4000" "$(sv DISTINCTLINES)"

# ---- the module refuses a malformed batch rather than mis-reading it --------
# Backpressure is where a host is most likely to hand over a partial buffer, so the refusals are
# exercised here rather than left to the Rust unit tests.
REFUSALS="$(m24_require_bounded 300 "the malformed-batch probe" node --experimental-strip-types -e '
import { readFileSync } from "node:fs";
const m = await import(process.argv[1] + "/src/index.ts");
const bytes = readFileSync(process.argv[2]);
const inst = await m.instantiateCtWriter(bytes);
const ex = inst.exports;
const enc = new TextEncoder();
const put = (s) => { const b = enc.encode(s); const p = ex.ct_alloc(b.length || 1); new Uint8Array(ex.memory.buffer).set(b, p); return [p, b.length]; };
const [pp, pl] = put("p"); const [rp, rl] = put("01949fcc-7d92-7e9c-8000-00000000dead");
const [sp, sl] = put("/a/b"); const [wp, wl] = put("/a");
console.log("OPEN\t" + ex.ct_writer_open(pp, pl, rp, rl, sp, sl, wp, wl, 0));
const buf = ex.ct_alloc(m.RECORD_SIZE * 2);
console.log("SHORT\t" + ex.ct_ingest(buf, m.RECORD_SIZE - 1));
console.log("EMPTY\t" + ex.ct_ingest(buf, 0));
const u8 = new Uint8Array(ex.memory.buffer);
u8.fill(0, buf, buf + m.RECORD_SIZE);
u8[buf + m.OFF_RESERVED] = 1;
console.log("DIRTY\t" + ex.ct_ingest(buf, m.RECORD_SIZE));
u8[buf + m.OFF_RESERVED] = 0;
console.log("CLEAN\t" + ex.ct_ingest(buf, m.RECORD_SIZE));
console.log("EVENTS\t" + ex.ct_events_written());
' "$M24_HOST" "$(m24_module)")" || die "the malformed-batch probe failed"

TAB=$'\t'
assert_true "the module opened for the malformed-batch probe" \
  str_has_line_re "$REFUSALS" "^OPEN${TAB}0\$"
assert_true "a buffer that is not a whole number of records is REFUSED (CT_ERR_BAD_LENGTH)" \
  str_has_line_re "$REFUSALS" "^SHORT${TAB}-4\$"
assert_true "an empty batch is accepted as zero records rather than refused" \
  str_has_line_re "$REFUSALS" "^EMPTY${TAB}0\$"
assert_true "a record with a non-zero reserved word is REFUSED (CT_ERR_RESERVED_NOT_ZERO)" \
  str_has_line_re "$REFUSALS" "^DIRTY${TAB}-6\$"
# THE CONTROL: the same buffer with the reserved word cleared is ACCEPTED. Without it, every
# refusal above is satisfied by a module that refuses every batch.
assert_true "THE CONTROL: the same buffer with the reserved word cleared is ACCEPTED" \
  str_has_line_re "$REFUSALS" "^CLEAN${TAB}1\$"
assert_true "and exactly one event was written, so the refusals did not also write" \
  str_has_line_re "$REFUSALS" "^EVENTS${TAB}1\$"

m24_finish
