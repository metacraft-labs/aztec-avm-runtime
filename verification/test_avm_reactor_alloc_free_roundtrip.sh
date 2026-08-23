#!/usr/bin/env bash
# M12: `avm_alloc` and `avm_free` round-trip arbitrary buffer sizes without leaking linear memory
# across repeated simulations.
#
# Two different claims, measured separately, because they fail differently:
#
#   THE ROUND TRIP. Thirteen sizes spanning the interesting boundaries — zero, one, the machine
#   word, a cache line either side, the wasm page either side, and a megabyte — each allocated,
#   written with a size-dependent pattern, read back byte for byte and freed. Zero is in the list
#   deliberately: a zero-size allocation must still return a distinct freeable pointer, because
#   returning null would make "allocation failed" and "you asked for nothing" the same answer.
#
#   THE ABSENCE OF A LEAK. Linear memory is measured from the host, in pages, across thirty-two
#   full simulations through ONE instance. A wasm memory never shrinks, so the sequence is
#   monotone by construction and the only thing worth asserting is that it stops growing — and that
#   the results stay identical while it does, because a simulation that started returning something
#   else would make a flat memory curve meaningless.
#
# A free-then-reallocate churn is measured before either: sixty-four one-megabyte allocations, each
# freed immediately. If `avm_free` did nothing the memory would grow by 64 MiB, which is a thousand
# pages — so this is the arm that would catch a `free` that is a no-op, and the round-trip arm above
# would not.

set -uo pipefail

TEST_NAME=test_avm_reactor_alloc_free_roundtrip
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m12_reactor.sh"

require_nix
m12_measured
note "tree: $M12_TREE"

OUT="$M12_WORK/reactor.alloc"
ERR="$M12_WORK/reactor.alloc.err"
m12_run_reactor alloc "$OUT" "$ERR"
run_rc=$?
assert_eq "the alloc/free run exits 0" 0 "$run_rc"
if [ "$run_rc" -ne 0 ]; then
  note "stderr: $ERR"
  grep -v '^\[' "$ERR" | tail -10
fi
assert_file "and produced a transcript" "$OUT"
assert_eq "which finished" "1" "$(m12_field "$OUT" alloc.done)"

# --- the round trip ---------------------------------------------------------
SIZES="0 1 7 8 63 64 65 1023 4096 65535 65536 65537 1048576"
assert_eq "thirteen sizes were exercised" 13 "$(m12_field "$OUT" alloc.sizes.count)"
for s in $SIZES; do
  assert_eq "avm_alloc($s) returned a non-null pointer" 1 "$(m12_field "$OUT" "alloc.$s.nonNull")"
  assert_eq "avm_alloc($s) returned a pointer distinct from every earlier one" 1 \
    "$(m12_field "$OUT" "alloc.$s.distinct")"
done
# The pattern read-back is asserted INSIDE the host, which throws on the first differing byte; the
# run's exit status is therefore the assertion, and it is stated here so a reader does not think
# the absence of a per-byte line means the bytes were not checked.
assert_eq "every buffer read back exactly what was written (the host throws on the first byte that does not)" \
  0 "$run_rc"
assert_eq "every allocation was freed" 1 "$(m12_field "$OUT" alloc.freedAll)"
assert_eq "and the host owns nothing at exit" 0 "$(m12_field "$OUT" alloc.ownedAllocationsAtExit)"

# --- the churn: sixty-four megabytes, allocated and freed --------------------
before="$(m12_field "$OUT" alloc.pagesBeforeChurn)"
after="$(m12_field "$OUT" alloc.pagesAfterChurn)"
assert_ge "linear memory was measurable before the churn" 1 "$before"
assert_eq "sixty-four megabytes allocated and freed one at a time grow linear memory by nothing" \
  "$before" "$after"
note "a no-op avm_free would have shown here as +1024 pages; it is $((after - before))"

# --- repeated simulations through one instance ------------------------------
rounds=32
identical=0
for i in $(seq 0 $((rounds - 1))); do
  [ "$(m12_field "$OUT" "alloc.sim.$i.identicalToFirst")" = "1" ] && identical=$((identical + 1))
done
assert_eq "all $rounds simulations through one instance produce the identical result" \
  "$rounds" "$identical"

pages_first="$(m12_field "$OUT" alloc.sim.1.pages)"
grew=0
shrank=0
prev=""
for i in $(seq 0 $((rounds - 1))); do
  p="$(m12_field "$OUT" "alloc.sim.$i.pages")"
  [ -n "$p" ] || fail "no page count recorded for simulation $i"
  if [ -n "$prev" ]; then
    [ "$p" -gt "$prev" ] && grew=$((grew + 1))
    [ "$p" -lt "$prev" ] && shrank=$((shrank + 1))
  fi
  prev="$p"
done
assert_eq "wasm linear memory never shrinks, and did not" 0 "$shrank"
# It grows at most once, between the first simulation and the second, which is the allocator
# reaching its high-water mark rather than a leak. "At most" and not "exactly": a build that reached
# the mark on the first simulation would grow zero times, and a check that demanded one would fail on
# the better outcome. The property that excludes a leak is the constancy asserted below — a leak
# grows at EVERY round — and this bound is what makes that constancy non-trivial.
assert_true "linear memory grows at most once across $rounds simulations (observed $grew)" \
  test "$grew" -le 1
constant=0
for i in $(seq 1 $((rounds - 1))); do
  [ "$(m12_field "$OUT" "alloc.sim.$i.pages")" = "$pages_first" ] && constant=$((constant + 1))
done
assert_eq "and is constant from the second simulation onward" "$((rounds - 1))" "$constant"
note "peak linear memory across $rounds simulations: $pages_first pages ($((pages_first * 64)) KiB)"

# The peak is within M9's recorded budget for a run with step records materialised, which is the
# nearest recorded figure and the one a regression would cross first.
assert_true "and within M9's recorded page budget of $M9_STEPS_PEAK_PAGE_BUDGET" \
  test "$pages_first" -le "$M9_STEPS_PEAK_PAGE_BUDGET"

finish
