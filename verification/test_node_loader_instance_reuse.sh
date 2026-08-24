#!/usr/bin/env bash
# test_node_loader_instance_reuse — M17.
#
# MANY SIMULATIONS THROUGH ONE POOLED INSTANCE PRODUCE IDENTICAL RESULTS TO RUNNING EACH IN A FRESH
# INSTANCE, WITH NO LINEAR-MEMORY GROWTH ACROSS RUNS.
#
# Two claims, and they need different evidence.
#
#   IDENTICAL RESULTS is a comparison, so both arms are run and compared element by element: the
#   whole corpus N times through ONE pooled instance, and the whole corpus N times each in a fresh
#   instance. A result that drifted after the first transaction — a static the module forgot to
#   reset, a DB handle recycled where it should not be — shows up as a mismatch and not as a
#   plausible number.
#
#   NO LINEAR-MEMORY GROWTH is a measurement of the module's own memory, and it is taken after each
#   round rather than once at the end. wasm linear memory never shrinks, so the reading after the
#   last round IS the peak; the reading after the FIRST round is what makes "no growth across runs"
#   a statement about reuse rather than about the module's static footprint.
#
# AND THE MODULE IS COMPILED ONCE. That is the deliverable's own words — "so a block of
# transactions does not recompile the module per transaction" — and it is measured as a count from
# the cache rather than inferred from wall time: the fresh-instance arm goes through the SAME cache,
# so its instantiations are cache hits and the compilation count stays at one for all of them.
#
# Run: just verify-node-pool

TEST_NAME="test_node_loader_instance_reuse"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m17_node_host.sh"

m17_measured

M17_POOL_ROUNDS="${M17_POOL_ROUNDS:-4}"

# ---------------------------------------------------------------------------
echo "== 1. the run"
# ---------------------------------------------------------------------------
m17_run pool "$(m17_out pool)" "$(m17_err pool)" "$M17_POOL_ROUNDS"
RC=$?
assert_eq "the pool probe exits 0" 0 "$RC"
assert_eq "…and its transcript is complete rather than truncated" \
  "complete" "$(m17_completeness "$(m17_out pool)" pool)"
T="$(m17_out pool)"
f() { m17_field "$T" "$1"; }

# ---------------------------------------------------------------------------
echo "== 2. both arms ran, and ran the same work"
# ---------------------------------------------------------------------------
WANT="$((M17_POOL_ROUNDS * M17_EXPECTED_PROGRAMS))"
assert_eq "the probe ran the rounds it was asked for" "$M17_POOL_ROUNDS" "$(f pool.rounds)"
assert_eq "the pooled arm produced a result per program per round" "$WANT" "$(f pool.pooledResults)"
assert_eq "the fresh arm produced the same number" "$WANT" "$(f pool.freshResults)"
# Non-emptiness before the comparison: two empty arms agree with each other.
assert_ge "and that is more than one transaction, or 'across runs' means nothing" 8 "$WANT"

# ---------------------------------------------------------------------------
echo "== 3. identical results"
# ---------------------------------------------------------------------------
assert_eq "every pooled result equals the fresh-instance result for the same program and round" \
  "0" "$(f pool.mismatches)"
# The two arms are genuinely two — one instance against `rounds * programs` instances — and the
# discrimination between a live instance and a dead one is the trap probe's pool arm, where a
# poisoned instance and a fresh one come back as retired 1 / created 2.
#
# ONE instance for every acquisition, and the acquisitions are per SIMULATION, so this is a
# statement about the pool rather than about how many times it was asked. A mutation round made the
# pool retire its instance on every acquisition; with one acquisition around the whole loop that
# still reported "one instance created", and the probe was restructured because of it.
assert_eq "the pooled arm used exactly one instance across every acquisition" "1" "$(f pool.instancesCreated)"
assert_true "…and it was acquired once per simulation, so the reuse is exercised" \
  test "$(f pool.instancesReused)" -ge "$WANT"
assert_eq "…and none of them was retired, because none of them trapped" "0" "$(f pool.instancesRetired)"
assert_true "…and the fresh arm made many, so the two arms are not the same arm" \
  test "$(f pool.moduleCacheHits)" -ge "$WANT"

# ---------------------------------------------------------------------------
echo "== 4. no linear-memory growth across runs"
# ---------------------------------------------------------------------------
note "pages after the first round: $(f pool.pagesFirstRound); after the last: $(f pool.pagesLastRound)"
assert_eq "linear memory does not grow across rounds through one instance" \
  "0" "$(f pool.pageGrowthAcrossRounds)"
# The reading is a real one: it must be at least the module's declared minimum, and strictly more
# than it, or "no growth" would be true of an instance that never ran anything.
assert_ge "the page reading is at least the module's declared minimum" \
  "$M17_DECLARED_MIN_PAGES" "$(f pool.pagesFirstRound)"
assert_true "…and strictly more, so the simulations did allocate and the reading is live" \
  test "$(f pool.pagesFirstRound)" -gt "$M17_DECLARED_MIN_PAGES"

# ---------------------------------------------------------------------------
echo "== 5. the module is compiled once"
# ---------------------------------------------------------------------------
assert_eq "one compilation for both arms together" "1" "$(f pool.moduleCompilations)"
note "module cache: 1 compilation, $(f pool.moduleCacheHits) hit(s) across $((WANT + 1)) acquisitions"
assert_true "…and the cache served every other acquisition" test "$(f pool.moduleCacheHits)" -ge "$WANT"

# ---------------------------------------------------------------------------
echo "== 6. the pool's own safety rule is in the code, not only in this run"
# ---------------------------------------------------------------------------
POOL_TS="$(cat "$M17_PKG/src/pool.ts")"
assert_contains "a poisoned instance is retired rather than handed out" \
  "if (this.instance && this.instance.poisoned)" "$POOL_TS"
assert_contains "…and acquisition is refused rather than re-entered" \
  "InstancePool.acquire is not re-entrant" "$POOL_TS"
assert_contains "the DB handles are deliberately not pooled" "The DB handles are NOT pooled" "$POOL_TS"

finish
