#!/usr/bin/env bash
# verify_native_wasm_transcripts_identical — M8.
#
# EVERY non-diagnostic line of the differential transcript, identical native versus wasm, on TWO
# wasm runtimes — and the wasm-only diagnostics ENUMERATED rather than filtered by a wildcard.
#
# The enumeration is the point. "identical apart from the wasm-specific lines", implemented as a
# `grep -v`, is a comparison whose scope nobody has measured: the same filter would swallow a value
# divergence on any line that happened to contain the pattern. So the driver prints every line that
# is allowed to differ with a `diag ` prefix, `wasm_host/_transcript_compare.py` carries a table of
# exactly which `diag` keys exist and on which side each may appear, and a key that is not in the
# table is a FAILURE naming the key.
#
# Two runtimes, because a result only one host reports is a result about that host. V8 runs the
# SHIPPED binary unmodified; wasmtime cannot supply an imported memory from the command line in any
# version, so M7's `wasm-merge` route is reused — which makes the merged module not byte-identical
# to the shipped one, which is why V8 is the primary measurement and wasmtime is the cross-check.
#
# COVERAGE: seven hand-assembled corpus programs plus one scripted world-state sequence. An
# integration check across two targets, not a breadth claim.

TEST_NAME="verify_native_wasm_transcripts_identical"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m8_differential.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
assert_file "the transcript comparator is present" "$M8_TRANSCRIPT_COMPARE"
m8_measured

NATIVE_T="$(m8_native_transcript)"
V8_T="$(m8_v8_transcript)"
WT_T="$(m8_wasmtime_transcript)"
WASM_BIN="$(m8_wasm_bin avm_differential)"
m8_require_artifacts "$NATIVE_T" "$V8_T" "$WASM_BIN"

# The truncation, refused before anything is compared, through lib.sh's ONE implementation. This
# check compares two transcripts line for line; a short one produces a diff that reads as a
# native-versus-wasm divergence, which is the exact misattribution M8 already made once with
# `revert-rerun.transcript` at 259 lines of 1,318.
require_complete_transcript "$NATIVE_T" avmDifferential.done "the native"
require_complete_transcript "$V8_T"     avmDifferential.done "the V8" "$NATIVE_T"

# ---------------------------------------------------------------------------
echo "== 1. native versus wasm on V8, the shipped binary unmodified"
# ---------------------------------------------------------------------------
python3 "$M8_TRANSCRIPT_COMPARE" "$NATIVE_T" "$V8_T" "$M8_PEAK_PAGE_BUDGET" \
  >"$M8_WORK/compare-v8.report" 2>"$M8_WORK/compare-v8.err"
assert_eq "the comparator ran" "0" "$?"
m8_report "$M8_WORK/compare-v8.report"
assert_eq "the comparison found no failures" "0" \
  "$(grep -c '^FAIL' "$M8_WORK/compare-v8.report" || true)"
assert_eq "the two transcripts carry the expected number of non-diagnostic lines" \
  "$M8_EXPECTED_ORDINARY_LINES" "$(m8_ordinary "$NATIVE_T" | grep -c . || true)"

# ---------------------------------------------------------------------------
echo "== 2. the second runtime"
# ---------------------------------------------------------------------------
# Both routes to wasmtime that M4 and M7 investigated are closed for this module, and that is
# measured rather than assumed: wasmtime 47 has no `-Sthreads` at all, and wasmtime 21.0.2 — the
# last release that had it — cannot load a module carrying real C++ exceptions. So the import is
# satisfied statically with `wasm-merge`, exactly as M7 does.
WT_DIRECT="$M8_WORK/wasmtime-direct.log"
m6_in_devshell '
  wasm="$1"
  wasmtime run --dir=. "$wasm" 2>&1
' "$WASM_BIN" >"$WT_DIRECT" 2>&1
assert_true "wasmtime cannot instantiate the shipped --import-memory module directly" test "$?" -ne 0
assert_contains "…and it says so by naming the memory import" "env::memory" "$(cat "$WT_DIRECT")"

m8_run_wasmtime "$WASM_BIN" "$WT_T" "$(m8_wasmtime_stderr)"
WT_RC=$?
assert_eq "the merged module runs to completion on wasmtime" "0" "$WT_RC"
m8_require_artifacts "$WT_T"
require_complete_transcript "$WT_T" avmDifferential.done "the wasmtime" "$NATIVE_T"
assert_eq "the wasmtime transcript ran to completion" "complete" \
  "$(transcript_completeness "$WT_T" avmDifferential.done)"

python3 "$M8_TRANSCRIPT_COMPARE" "$NATIVE_T" "$WT_T" "$M8_PEAK_PAGE_BUDGET" \
  >"$M8_WORK/compare-wasmtime.report" 2>/dev/null
assert_eq "the comparator ran against the wasmtime transcript" "0" "$?"
assert_eq "native versus wasm on wasmtime has no failures either" "0" \
  "$(grep -c '^FAIL' "$M8_WORK/compare-wasmtime.report" || true)"

# The two hosts against each other, per line. Every ORDINARY line must be identical: those are the
# AVM's own results and no host may move them.
assert_true "the V8 and wasmtime transcripts agree on every non-diagnostic line" \
  bash -c 'diff <(grep -v "^diag " "$1") <(grep -v "^diag " "$2") >/dev/null' bash "$V8_T" "$WT_T"
assert_eq "…and on the pointer width" "$(grep '^diag target.pointerBits' "$V8_T")" \
  "$(grep '^diag target.pointerBits' "$WT_T")"

# The diagnostics do NOT all agree, and the difference is measured rather than tolerated. Peak
# linear memory is one page lower on wasmtime, at every point in the run. The cause is the WASI
# ENVIRONMENT, which is copied into the guest's linear memory before `main`: node's host passes the
# whole of `process.env` through, wasmtime passes none. That is asserted by moving it in both
# directions further down, in verify_wasm_peak_memory_budget; here the claim is only that the
# difference is confined to those keys and is exactly one page.
DIAG_DIFF="$M8_WORK/host-diag.diff"
diff <(grep '^diag ' "$V8_T") <(grep '^diag ' "$WT_T") >"$DIAG_DIFF" || true
assert_eq "every diagnostic that differs between the hosts is a peak-memory one" "0" \
  "$(grep -E '^[<>]' "$DIAG_DIFF" | grep -vc 'peakLinearMemory' || true)"
V8_PEAK="$(sed -n 's/^diag wasm.peakLinearMemoryPages //p' "$V8_T")"
WT_PEAK="$(sed -n 's/^diag wasm.peakLinearMemoryPages //p' "$WT_T")"
assert_eq "the two hosts differ by exactly one 64 KiB page" "1" "$((V8_PEAK - WT_PEAK))"
assert_true "…and both are within the recorded budget" \
  bash -c 'test "$1" -le "$3" && test "$2" -le "$3"' bash "$V8_PEAK" "$WT_PEAK" "$M8_PEAK_PAGE_BUDGET"

# ---------------------------------------------------------------------------
echo "== 3. the enumeration, asserted rather than described"
# ---------------------------------------------------------------------------
assert_eq "the native transcript emits exactly one diagnostic" "1" \
  "$(grep -c '^diag ' "$NATIVE_T" || true)"
assert_eq "the wasm transcript emits exactly ten" "10" "$(grep -c '^diag ' "$V8_T" || true)"
assert_eq "and that is the whole of the difference: nothing else differs" "0" \
  "$(diff <(m8_ordinary "$NATIVE_T") <(m8_ordinary "$V8_T") | grep -c . || true)"
# Named, not counted.
for k in target.pointerBits wasm.peakLinearMemoryPages wasm.peakLinearMemoryKiB; do
  assert_true "the enumerated diagnostic $k is in the comparator's table" \
    grep -q "\"$k\"" "$M8_TRANSCRIPT_COMPARE"
done
# The table is a literal set of ten keys and the check against it is an exact set difference. Read
# out of the comparator itself rather than described: a prefix rule would be a wildcard wearing a
# different hat, and this milestone's own deliverable forbids one.
TABLE_KEYS="$(python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('tc', '$M8_TRANSCRIPT_COMPARE')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(' '.join(sorted(m.ENUMERATED_DIAGNOSTICS)))")"
assert_eq "the comparator enumerates exactly ten diagnostic keys" "10" \
  "$(printf '%s\n' $TABLE_KEYS | grep -c . || true)"
EMITTED="$(grep '^diag ' "$V8_T" | awk '{print $2}' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "…and they are exactly the keys the wasm transcript emits" \
  "$(printf '%s\n' $TABLE_KEYS | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')" "$EMITTED"

# ---------------------------------------------------------------------------
echo "== 4. the committed transcripts, so the comparison cannot drift silently"
# ---------------------------------------------------------------------------
# Both transcripts are checked in, the way M7 checked in its 391 test names. They are compared on
# their ORDINARY lines byte for byte — and on their diagnostic KEY set, not on the diagnostic
# values, because peak linear memory is measurably a function of the host's WASI environment and a
# byte comparison of the whole file would be a comparison of whoever ran it last. That limitation is
# asserted rather than left implicit: the key sets must be equal and the values must not be
# required to be.
COMMITTED_NATIVE="$REPO_ROOT/fixtures/wasm-parity/avm-differential-native.results"
COMMITTED_WASM="$REPO_ROOT/fixtures/wasm-parity/avm-differential-wasm-v8.results"
assert_file "the native transcript is committed" "$COMMITTED_NATIVE"
assert_file "the wasm transcript is committed" "$COMMITTED_WASM"
m8_require_artifacts "$COMMITTED_NATIVE" "$COMMITTED_WASM"
assert_true "this run's native transcript reproduces the committed one, line for line" \
  bash -c 'diff <(grep -v "^diag " "$1") <(grep -v "^diag " "$2") >/dev/null' bash \
  "$COMMITTED_NATIVE" "$NATIVE_T"
assert_true "this run's wasm transcript reproduces the committed one, line for line" \
  bash -c 'diff <(grep -v "^diag " "$1") <(grep -v "^diag " "$2") >/dev/null' bash \
  "$COMMITTED_WASM" "$V8_T"
assert_eq "the committed wasm transcript declares the same diagnostic keys as this run" \
  "$(grep '^diag ' "$COMMITTED_WASM" | awk '{print $2}' | LC_ALL=C sort | tr '\n' ' ')" \
  "$(grep '^diag ' "$V8_T" | awk '{print $2}' | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "the committed native transcript carries the same one diagnostic key" \
  "$(grep '^diag ' "$COMMITTED_NATIVE" | awk '{print $2}' | LC_ALL=C sort | tr '\n' ' ')" \
  "$(grep '^diag ' "$NATIVE_T" | awk '{print $2}' | LC_ALL=C sort | tr '\n' ' ')"
# And the committed pair is itself a valid differential, so what is checked in is the thing this
# check is about rather than two files that merely exist.
python3 "$M8_TRANSCRIPT_COMPARE" "$COMMITTED_NATIVE" "$COMMITTED_WASM" "$M8_PEAK_PAGE_BUDGET" \
  >"$M8_WORK/compare-committed.report" 2>/dev/null
assert_eq "the committed pair passes the same comparison with no failures" "0" \
  "$(grep -c '^FAIL' "$M8_WORK/compare-committed.report" || true)"
assert_ge "…over the same number of assertions" 30 \
  "$(grep -c '^PASS' "$M8_WORK/compare-committed.report" || true)"
# Control: a committed copy with one line changed must be rejected, so the comparison above is
# against the file and not a tautology.
DRIFTED="$M8_WORK/committed-drifted.results"
sed 's/^tierD\.step2\.NOTE_HASH_TREE .*/tierD.step2.NOTE_HASH_TREE 0x0000000000000000000000000000000000000000000000000000000000000000 size=4/' \
  "$COMMITTED_WASM" >"$DRIFTED"
assert_false "control: a committed transcript with one line changed no longer reproduces" \
  bash -c 'diff <(grep -v "^diag " "$1") <(grep -v "^diag " "$2") >/dev/null' bash "$DRIFTED" "$V8_T"

# ---------------------------------------------------------------------------
echo "== 5. negative controls, each required to be rejected by its OWN message"
# ---------------------------------------------------------------------------
# (1) A divergence on an ordinary line.
INJ1="$M8_WORK/inject-ordinary.transcript"
sed 's/^program\.sha256\.txFee .*/program.sha256.txFee 0x0000000000000000000000000000000000000000000000000000000000000001/' \
  "$V8_T" >"$INJ1"
assert_false "control: the injected copy differs from the original" cmp -s "$INJ1" "$V8_T"
python3 "$M8_TRANSCRIPT_COMPARE" "$NATIVE_T" "$INJ1" "$M8_PEAK_PAGE_BUDGET" \
  >"$M8_WORK/compare-inj1.report" 2>/dev/null
assert_contains "control: a single changed ordinary line is rejected, by the per-line comparison" \
  "every non-diagnostic line is identical native versus wasm" \
  "$(grep '^FAIL' "$M8_WORK/compare-inj1.report")"
assert_contains "control: …and the failure names the line that moved" "program.sha256.txFee" \
  "$(grep '^FAIL' "$M8_WORK/compare-inj1.report")"

# (2) An UNENUMERATED diagnostic. This is the control that separates enumeration from filtering: a
#     `grep -v '^diag '` comparison would pass this happily.
INJ2="$M8_WORK/inject-diag.transcript"
{ head -3 "$V8_T"; echo "diag wasm.somethingNobodyEnumerated 1"; tail -n +4 "$V8_T"; } >"$INJ2"
python3 "$M8_TRANSCRIPT_COMPARE" "$NATIVE_T" "$INJ2" "$M8_PEAK_PAGE_BUDGET" \
  >"$M8_WORK/compare-inj2.report" 2>/dev/null
assert_contains "control: a diagnostic key nobody enumerated is rejected" \
  "every \`diag\` key the transcripts emit is enumerated here" \
  "$(grep '^FAIL' "$M8_WORK/compare-inj2.report")"
assert_contains "control: …naming the key" "wasm.somethingNobodyEnumerated" \
  "$(grep '^FAIL' "$M8_WORK/compare-inj2.report")"

# (3) THE ONE THAT MATTERS: the same transcript handed in on both sides. Comparing an artefact
#     with itself reports IDENTICAL, which is true and worthless — M5's review found exactly this
#     shape passing. The discriminator is the pointer width, which the two targets cannot share.
python3 "$M8_TRANSCRIPT_COMPARE" "$NATIVE_T" "$NATIVE_T" "$M8_PEAK_PAGE_BUDGET" \
  >"$M8_WORK/compare-same.report" 2>/dev/null
assert_ge "control: the same transcript on both sides is REJECTED" 1 \
  "$(grep -c '^FAIL' "$M8_WORK/compare-same.report" || true)"
assert_contains "control: …because the right-hand side is not a 32-bit target" \
  "the wasm target is 32-bit" "$(grep '^FAIL' "$M8_WORK/compare-same.report")"
# And the reverse pairing, which nobody tries: the wasm transcript on both sides.
python3 "$M8_TRANSCRIPT_COMPARE" "$V8_T" "$V8_T" "$M8_PEAK_PAGE_BUDGET" \
  >"$M8_WORK/compare-same2.report" 2>/dev/null
assert_contains "control: the wasm transcript on both sides is rejected too" \
  "the native target is 64-bit" "$(grep '^FAIL' "$M8_WORK/compare-same2.report")"

# (4) The sides SWAPPED. Also never tried by the implementation until it was written down.
python3 "$M8_TRANSCRIPT_COMPARE" "$V8_T" "$NATIVE_T" "$M8_PEAK_PAGE_BUDGET" \
  >"$M8_WORK/compare-swapped.report" 2>/dev/null
assert_ge "control: the two sides swapped is rejected" 1 \
  "$(grep -c '^FAIL' "$M8_WORK/compare-swapped.report" || true)"

# (5) A truncated transcript, whose surviving lines are an identical PREFIX.
INJ5="$M8_WORK/inject-truncated.transcript"
head -n 900 "$V8_T" >"$INJ5"
python3 "$M8_TRANSCRIPT_COMPARE" "$NATIVE_T" "$INJ5" "$M8_PEAK_PAGE_BUDGET" \
  >"$M8_WORK/compare-inj5.report" 2>/dev/null
assert_contains "control: a truncated transcript is rejected by the completion assertion" \
  "wasm transcript ran to completion" "$(grep '^FAIL' "$M8_WORK/compare-inj5.report")"

finish
