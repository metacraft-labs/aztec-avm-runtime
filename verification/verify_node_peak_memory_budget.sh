#!/usr/bin/env bash
# verify_node_peak_memory_budget — M17.
#
# PEAK LINEAR MEMORY UNDER V8, DRIVING THE WHOLE CORPUS THROUGH THE NODE HOST, AGAINST A RECORDED
# BUDGET.
#
# THE MILESTONE'S OWN FIGURE IS THE SPIKE'S AND WAS ALREADY SUPERSEDED ONCE. Its verification entry
# says "measured 13.6 MiB". That is the vm2-wasm spike's driver, which ran every program twice —
# once plain and once with a step recorder materialising all 38,903 records — and M8 already
# corrected it for the differential driver, to 173 pages / 11,072 KiB reported from INSIDE the
# module. Neither number is this one, and saying so is the point: this measurement is of a host that
# runs all seven programs through ONE POOLED INSTANCE and holds each program's resident contract and
# merkle DBs, so its footprint is the corpus's rather than one program's. Measured: 199 pages /
# 12,736 KiB, which is below the milestone's 13.6 MiB and above M8's 11,072 KiB, and both
# comparisons are asserted so neither figure can be quoted as the other.
#
# "ON THE HEAVIEST CORPUS PROGRAM" IS A MEASUREMENT HERE, NOT A GUESS. wasm linear memory never
# shrinks, so the reading after each program is monotonic and the last is the peak; the per-program
# readings are what identify which program the growth is attributable to. M8 found the spread across
# its seven to be ONE page, because its footprint is dominated by the world state's genesis prefill;
# through this host it is thirty-two, because the host seeds a fresh pair of resident DBs per
# program. That difference is a fact about the two drivers and is asserted rather than reconciled in
# prose.
#
# Run: just verify-node-memory

TEST_NAME="verify_node_peak_memory_budget"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m17_node_host.sh"
. "$VERIFY_DIR/lib_m8_differential.sh"

m17_measured

# THIS CHECK PRODUCES ITS OWN READING RATHER THAN READING A NEIGHBOUR'S.
#
# An earlier version reused `node-host.transcript` when it was already on disk, which made the whole
# check a statement about a FILE rather than about the host: a mutation round that made the host
# report a constant page count went entirely undetected, because the check never re-ran it. Its own
# output file, produced on every invocation, is what makes the measurement live. It costs one run of
# the corpus — about forty seconds — and the alternative is a budget nothing can breach.
T="$(m17_out memory)"
m17_run transcript "$T" "$(m17_err memory)" \
  || die "the node host's transcript run failed: see $(m17_err memory)"
m8_require_artifacts "$T"
assert_eq "the transcript the peak is read from is complete rather than truncated" \
  "complete" "$(m17_completeness "$T" nodeHost)"

PAGES="$(m17_field "$T" nodeHost.peakPages)"
KIB="$(m17_field "$T" nodeHost.peakKiB)"
[ -n "$PAGES" ] || die "the node transcript reports no peak linear memory"

# ---------------------------------------------------------------------------
echo "== 1. the measurement"
# ---------------------------------------------------------------------------
note "peak: $PAGES pages / $KIB KiB; budget $M17_PEAK_PAGE_BUDGET pages"
assert_eq "the peak is the value this milestone records" "$M17_MEASURED_PEAK_PAGES" "$PAGES"
assert_eq "…and its KiB figure" "$M17_MEASURED_PEAK_KIB" "$KIB"
assert_eq "the KiB figure is the page count times 64" "$((PAGES * 64))" "$KIB"
assert_true "the peak is within the recorded budget" test "$PAGES" -le "$M17_PEAK_PAGE_BUDGET"
note "margin: $((M17_PEAK_PAGE_BUDGET - PAGES)) pages / $(((M17_PEAK_PAGE_BUDGET - PAGES) * 64)) KiB"
# The budget is not the measurement. A budget equal to what was measured fails on any change and is
# therefore raised rather than read, which makes it decoration.
assert_true "the budget leaves headroom rather than being the measurement itself" \
  test "$M17_PEAK_PAGE_BUDGET" -gt "$PAGES"
assert_true "…but not so much headroom that it could not fail" \
  test "$M17_PEAK_PAGE_BUDGET" -lt "$((PAGES * 2))"

# ---------------------------------------------------------------------------
echo "== 2. it starts at the module's declared minimum and grows from there"
# ---------------------------------------------------------------------------
assert_eq "the instance starts at the module's own declared minimum" \
  "$M17_DECLARED_MIN_PAGES" "$(m17_field "$T" nodeHost.pagesAtStart)"
assert_true "…and the peak is above it, so the reading is of a live instance" \
  test "$PAGES" -gt "$M17_DECLARED_MIN_PAGES"

# ---------------------------------------------------------------------------
echo "== 3. the per-program readings, so 'the heaviest' is measured"
# ---------------------------------------------------------------------------
PREV=0
N=0
HEAVIEST=""
for p in $M17_PROGRAMS; do
  v="$(m17_field "$T" "nodeHost.pagesAfter.$p")"
  assert_true "[$p] a page reading was taken" test -n "$v"
  # Monotonic, because linear memory never shrinks. A reading that went DOWN would mean the host
  # was reporting something other than the module's memory.
  assert_true "[$p] the reading never goes down, as linear memory cannot" test "$v" -ge "$PREV"
  if [ "$v" -gt "$PREV" ]; then HEAVIEST="$p"; fi
  PREV="$v"
  N=$((N + 1))
done
assert_eq "a reading was taken after every corpus program" "$M17_EXPECTED_PROGRAMS" "$N"
assert_eq "the last reading is the peak" "$PAGES" "$PREV"
note "the last program to grow the heap: ${HEAVIEST:-none}"
assert_true "some program grew it, so the readings are not one repeated constant" test -n "$HEAVIEST"

SPREAD="$(m17_field "$T" nodeHost.pageSpreadAcrossPrograms)"
note "spread across the seven programs: $SPREAD pages"
assert_true "the spread is a real one, so 'the heaviest program' discriminates here" test "$SPREAD" -gt 0

# ---------------------------------------------------------------------------
echo "== 4. the two other figures this must not be confused with"
# ---------------------------------------------------------------------------
# M8's, from inside the module, for the differential driver. Read out of M8's own library rather
# than restated, and asserted DIFFERENT, so neither can be quoted as the other.
assert_true "M8 records its own peak" test -n "$M8_MEASURED_PEAK_PAGES"
note "M8's differential driver, reported from inside the module: $M8_MEASURED_PEAK_PAGES pages"
assert_true "this milestone's peak is not M8's" test "$PAGES" -ne "$M8_MEASURED_PEAK_PAGES"
assert_true "…and is higher, because this host holds the corpus's resident DBs rather than one program's" \
  test "$PAGES" -gt "$M8_MEASURED_PEAK_PAGES"
# The milestone's own 13.6 MiB, which is the spike's. 13.6 MiB is 13926 KiB; the peak must be below
# it, which is the entry's claim, and must not be equal to it, which is the correction.
assert_true "the peak is below the milestone's stated 13.6 MiB" test "$KIB" -lt 13926
assert_true "…and is not that figure, which was the spike's double-run driver" test "$KIB" -ne 13926

finish
