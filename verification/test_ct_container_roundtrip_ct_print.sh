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
assert_true "and refuses it for the unpledged-frame reason, by its own words" \
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

m24_finish
