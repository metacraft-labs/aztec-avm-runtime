#!/usr/bin/env bash
# verify_wasm_peak_memory_budget — M8.
#
# PEAK LINEAR MEMORY, REPORTED FROM INSIDE THE MODULE, AGAINST A RECORDED BUDGET.
#
# "From inside the module" is the load-bearing half. A host can report how much memory it handed
# out, which is a fact about the host's allocation policy; `__builtin_wasm_memory_size(0)` is what
# the guest itself has. wasm linear memory never shrinks, so the value at the end of the run IS the
# peak, and the value after each program makes "the heaviest corpus program" a measurement rather
# than a guess.
#
# THE MILESTONE'S OWN FIGURE IS SUPERSEDED AND THE FRAMING IS CORRECTED. Its verification entry says
# "measured 217 pages / 13.6 MiB". That was the vm2-wasm spike's driver, which ran every program
# TWICE — once plain and once with a step recorder materialising all 38,903 step records — and did
# not exist in this tree. This driver runs each program once and additionally drives the world state
# directly; it measures 173 pages / 11,072 KiB on V8. And "on the heaviest corpus program" does not
# discriminate: the spread across the seven programs is ONE page, because the footprint is dominated
# by the world state's 128+128 genesis prefill and the module's static data rather than by the
# program. Both facts are asserted below rather than left in prose.
#
# AND THE NUMBER IS NOT A PROPERTY OF THE MODULE ALONE, which is a finding rather than a caveat: it
# is one page lower under wasmtime than under node's WASI host. The cause is the WASI environment,
# copied into linear memory before `main` runs — node's host passes the whole of `process.env`
# through and wasmtime passes none. This check moves it in BOTH directions to establish that, rather
# than arguing it.

TEST_NAME="verify_wasm_peak_memory_budget"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m8_differential.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
m8_measured

V8_T="$(m8_v8_transcript)"
NATIVE_T="$(m8_native_transcript)"
WASM_BIN="$(m8_wasm_bin avm_differential)"
m8_require_artifacts "$V8_T" "$NATIVE_T" "$WASM_BIN"

PAGES="$(sed -n 's/^diag wasm.peakLinearMemoryPages //p' "$V8_T")"
KIB="$(sed -n 's/^diag wasm.peakLinearMemoryKiB //p' "$V8_T")"
[ -n "$PAGES" ] || die "the wasm transcript reports no peak linear memory"

# ---------------------------------------------------------------------------
echo "== 1. the measurement"
# ---------------------------------------------------------------------------
note "peak linear memory: $PAGES pages / $KIB KiB; budget $M8_PEAK_PAGE_BUDGET pages"
assert_eq "the peak is the value this milestone records" "$M8_MEASURED_PEAK_PAGES" "$PAGES"
assert_eq "…and its KiB figure" "$M8_MEASURED_PEAK_KIB" "$KIB"
assert_eq "the KiB figure is the page count times 64" "$((PAGES * 64))" "$KIB"
assert_true "the peak is within the recorded budget" test "$PAGES" -le "$M8_PEAK_PAGE_BUDGET"
note "margin: $((M8_PEAK_PAGE_BUDGET - PAGES)) pages / $(((M8_PEAK_PAGE_BUDGET - PAGES) * 64)) KiB"
# The budget is not the measurement. A budget equal to what was measured fails on any change and is
# therefore raised rather than read, which makes it decoration.
assert_true "the budget leaves headroom rather than being the measurement itself" \
  test "$M8_PEAK_PAGE_BUDGET" -gt "$PAGES"
assert_true "…but not so much headroom that it could not fail" \
  test "$M8_PEAK_PAGE_BUDGET" -lt "$((PAGES * 3))"

# It is reported from inside the module. Asserted from the driver source the patch adds, not from
# the fact that a number appeared.
assert_true "the driver reads the page count with __builtin_wasm_memory_size" \
  grep -q '__builtin_wasm_memory_size(0)' "$M8_PATCH_6"
assert_true "…under __wasm__, so there is deliberately no native counterpart" \
  grep -q '^+#ifdef __wasm__' "$M8_PATCH_6"
assert_eq "and the native transcript carries no peak-memory line at all" "0" \
  "$(grep -c 'peakLinearMemory' "$NATIVE_T" || true)"

# ---------------------------------------------------------------------------
echo "== 2. against the module's own declared memory limits"
# ---------------------------------------------------------------------------
LIMITS="$(python3 "$VERIFY_DIR/wasm_host/_wasm_memory_limits.py" "$WASM_BIN")"
[ -n "$LIMITS" ] || die "could not read the memory import of $WASM_BIN"
MIN="$(printf '%s' "$LIMITS" | awk '{print $3}')"
MAX="$(printf '%s' "$LIMITS" | awk '{print $4}')"
note "declared memory import: min=$MIN max=$MAX pages"
assert_true "the peak is at least the module's declared minimum" test "$PAGES" -ge "$MIN"
assert_true "…and below its declared maximum" test "$PAGES" -lt "$MAX"
assert_true "the module really did grow past its declared minimum, so the number is not the header" \
  test "$PAGES" -gt "$MIN"
note "growth during the run: $((PAGES - MIN)) pages / $(((PAGES - MIN) * 64)) KiB"

# ---------------------------------------------------------------------------
echo "== 3. per program: monotone, and the heaviest identified"
# ---------------------------------------------------------------------------
SEQ=""
PREV=0
MONOTONE=1
for prog in add revert loop sha256 poseidon2 storage burn; do
  v="$(sed -n "s/^diag wasm.peakLinearMemoryPages.after.$prog //p" "$V8_T")"
  assert_true "the transcript reports linear memory after program $prog" test -n "$v"
  [ -n "$v" ] || continue
  [ "$v" -ge "$PREV" ] || MONOTONE=0
  PREV="$v"
  SEQ="$SEQ $prog=$v"
done
note "per-program sequence:$SEQ"
assert_eq "linear memory never shrinks across the corpus (wasm memory cannot)" "1" "$MONOTONE"
assert_eq "the value after the last program is the whole-run peak" "$PAGES" "$PREV"

FIRST="$(sed -n 's/^diag wasm.peakLinearMemoryPages.after.add //p' "$V8_T")"
assert_true "the corpus spread is small — the footprint is the world state, not the program" \
  test "$((PAGES - FIRST))" -le 4
note "spread across the seven programs: $((PAGES - FIRST)) page(s)"
# And that is why "on the heaviest corpus program" does not discriminate. It is still identified,
# because the deliverable asks for it: it is the program after which the sequence last rose.
HEAVIEST="$(python3 - "$V8_T" <<'PY'
import sys
progs = ["add", "revert", "loop", "sha256", "poseidon2", "storage", "burn"]
vals = {}
for ln in open(sys.argv[1], encoding="utf-8"):
    if ln.startswith("diag wasm.peakLinearMemoryPages.after."):
        k, v = ln.split()[1], ln.split()[2]
        vals[k.rsplit(".", 1)[1]] = int(v)
seq = [vals[p] for p in progs if p in vals]
heaviest, prev = progs[0], seq[0]
for p, v in zip(progs[1:], seq[1:]):
    if v > prev:
        heaviest = p
    prev = v
print(heaviest)
PY
)"
note "heaviest corpus program, by measurement: $HEAVIEST"
assert_contains "the heaviest program is one of the seven" "$HEAVIEST" "add revert loop sha256 poseidon2 storage burn"
# The `burn` program is the largest WORKLOAD by far, and it is not the largest footprint. Stated as
# an assertion because it is the thing the milestone's own wording would have led a reader to
# assume.
BURN_INSTR="$(sed -n 's/^program\.burn\.stat\.total_instructions_executed //p' "$V8_T")"
ADD_INSTR="$(sed -n 's/^program\.add\.stat\.total_instructions_executed //p' "$V8_T")"
assert_true "burn executes thousands of times more instructions than add" \
  test "$BURN_INSTR" -gt "$((ADD_INSTR * 1000))"
assert_eq "…and yet adds no linear memory of its own" \
  "$(sed -n 's/^diag wasm.peakLinearMemoryPages.after.storage //p' "$V8_T")" \
  "$(sed -n 's/^diag wasm.peakLinearMemoryPages.after.burn //p' "$V8_T")"

# ---------------------------------------------------------------------------
echo "== 4. what the number depends on, established by moving it both ways"
# ---------------------------------------------------------------------------
# A one-page difference between two hosts is either a finding or an unexplained inconsistency. It
# is a finding, and the mechanism is demonstrated rather than argued: the WASI environment is copied
# into the guest's linear memory before `main`, so ADDING one to the host that passes none raises
# the peak, and REMOVING them from the host that passes all of them lowers it.
WT_T="$(m8_wasmtime_transcript)"
if [ ! -f "$WT_T" ]; then
  m8_run_wasmtime "$WASM_BIN" "$WT_T" "$(m8_wasmtime_stderr)"
  assert_eq "the wasmtime run needed for the comparison succeeded" "0" "$?"
fi
m8_require_artifacts "$WT_T"
WT_PAGES="$(sed -n 's/^diag wasm.peakLinearMemoryPages //p' "$WT_T")"
assert_eq "wasmtime measures one page less than node's WASI host" "1" "$((PAGES - WT_PAGES))"

MERGED="$M8_WORK/$(basename "$WASM_BIN").merged.wasm"
m8_require_artifacts "$MERGED"

# (a) Give wasmtime a large environment: the peak must RISE.
BIGENV_OUT="$M8_WORK/peak-wasmtime-bigenv.txt"
m6_in_devshell '
  merged="$1"
  big="$(python3 -c "print(\"x\"*61000)")"
  wasmtime run --dir=. --env BIG="$big" "$merged" 2>/dev/null
' "$MERGED" >"$BIGENV_OUT" 2>/dev/null
BIGENV_PAGES="$(sed -n 's/^diag wasm.peakLinearMemoryPages //p' "$BIGENV_OUT")"
assert_true "the large-environment wasmtime run produced a transcript" test -n "$BIGENV_PAGES"
assert_true "a 61 KiB environment variable RAISES the peak under wasmtime" \
  test "${BIGENV_PAGES:-0}" -gt "$WT_PAGES"
note "wasmtime: $WT_PAGES pages with no environment, ${BIGENV_PAGES:-?} with a 61 KiB one"

# (b) Take the environment away from node's host: the peak must FALL.
MINENV_OUT="$M8_WORK/peak-v8-minenv.txt"
m6_in_devshell '
  host="$1"; wasm="$2"
  env -i PATH="$PATH" node "$host" "$wasm" 2>/dev/null
' "$M7_V8_HOST" "$WASM_BIN" >"$MINENV_OUT" 2>/dev/null
MINENV_PAGES="$(sed -n 's/^diag wasm.peakLinearMemoryPages //p' "$MINENV_OUT")"
assert_true "the minimal-environment node run produced a transcript" test -n "$MINENV_PAGES"
assert_true "stripping the environment LOWERS the peak under node's WASI host" \
  test "${MINENV_PAGES:-99999}" -lt "$PAGES"
note "node: $PAGES pages with the full environment, ${MINENV_PAGES:-?} with a minimal one"

# The AVM's own results are untouched by either, which is what makes this a memory finding rather
# than a correctness one.
assert_true "the AVM's results are identical under the minimal environment" \
  bash -c 'diff <(grep -v "^diag " "$1") <(grep -v "^diag " "$2") >/dev/null' bash "$MINENV_OUT" "$V8_T"

# ---------------------------------------------------------------------------
echo "== 5. negative controls"
# ---------------------------------------------------------------------------
# (1) A budget below the measurement must FAIL, or the budget assertion is decoration.
python3 "$M8_TRANSCRIPT_COMPARE" "$NATIVE_T" "$V8_T" "$((PAGES - 1))" \
  >"$M8_WORK/peak-under-budget.report" 2>/dev/null
assert_contains "control: a budget one page below the measurement is rejected" \
  "peak linear memory is within the recorded budget" \
  "$(grep '^FAIL' "$M8_WORK/peak-under-budget.report")"
# (2) …and the same run at the real budget is not, so the control moved only the budget.
python3 "$M8_TRANSCRIPT_COMPARE" "$NATIVE_T" "$V8_T" "$M8_PEAK_PAGE_BUDGET" \
  >"$M8_WORK/peak-at-budget.report" 2>/dev/null
assert_eq "control: the same run at the recorded budget has no failures" "0" \
  "$(grep -c '^FAIL' "$M8_WORK/peak-at-budget.report" || true)"
# (3) A transcript whose per-program sequence goes DOWN must be rejected: wasm memory cannot shrink,
#     so such a transcript did not come from this module.
SHRINK="$M8_WORK/peak-shrinking.transcript"
sed 's/^diag wasm.peakLinearMemoryPages.after.burn .*/diag wasm.peakLinearMemoryPages.after.burn 4/' \
  "$V8_T" >"$SHRINK"
python3 "$M8_TRANSCRIPT_COMPARE" "$NATIVE_T" "$SHRINK" "$M8_PEAK_PAGE_BUDGET" \
  >"$M8_WORK/peak-shrink.report" 2>/dev/null
assert_contains "control: a shrinking per-program sequence is rejected" \
  "linear memory never shrinks across the corpus" "$(grep '^FAIL' "$M8_WORK/peak-shrink.report")"
# (4) A KiB figure inconsistent with the page count must be rejected.
BADKIB="$M8_WORK/peak-badkib.transcript"
sed 's/^diag wasm.peakLinearMemoryKiB .*/diag wasm.peakLinearMemoryKiB 1/' "$V8_T" >"$BADKIB"
python3 "$M8_TRANSCRIPT_COMPARE" "$NATIVE_T" "$BADKIB" "$M8_PEAK_PAGE_BUDGET" \
  >"$M8_WORK/peak-badkib.report" 2>/dev/null
assert_contains "control: a KiB figure that is not 64x the page count is rejected" \
  "the KiB figure is the page count times 64" "$(grep '^FAIL' "$M8_WORK/peak-badkib.report")"

finish
