#!/usr/bin/env bash
# test_fake_clock_hundred_blocks — DD-4's first reason, made measurable.
#
# The verification entry: "A hundred blocks are produced on a fake clock with no wall-clock
# waiting, and the chain state is identical to a real-timer run."
#
# THE COMPARISON IS THE ASSERTION AND THE SECOND ARM IS WHAT MAKES IT ONE. A hundred blocks on a
# fake clock, on its own, proves only that a hundred blocks can be produced quickly — a runtime
# whose fake path bypassed the module entirely would pass that. What this measures is that the fake
# ticker and UPSTREAM'S OWN `RunningPromise` produce the same chain: the same block count, the same
# final timestamp, and the same ARCHIVE ROOT, which is a hash over every header in the chain and
# therefore over every block's number, timestamp and state reference.
#
# THE VARIED THING IS THE TICKER, NOT THE CLOCK. Both arms use a `ManualDateProvider` advanced one
# second per block, so a difference in the result is attributable to the tick source and to nothing
# else. Varying both would make a divergence unattributable, which is the shape M8's differential
# had to be built around.
#
# "NO WALL-CLOCK WAITING" IS MEASURED, not asserted. The fake arm's elapsed milliseconds are
# recorded and required to be far below what a real one-second interval would cost. The bound is
# deliberately loose — this is not a timing benchmark and a loaded box must not turn it red — but
# it is not vacuous either: a hundred seconds is 100,000 ms and the fake arm is required to be
# under 30,000, which no fake-clock run approaches and no real-clock run at a one-second interval
# could reach.
#
# Run: just verify-chain-fake-clock

TEST_NAME="test_fake_clock_hundred_blocks"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit
m23_require_arms

echo "== a hundred blocks on a fake clock and a fake ticker"

FAKE_BLOCKS="$(m23_arm hundredBlocks fake.blocks)"
FAKE_TS="$(m23_arm hundredBlocks fake.lastTimestamp)"
FAKE_ARCHIVE="$(m23_arm hundredBlocks fake.archive)"
FAKE_MS="$(m23_arm hundredBlocks fake.elapsedMs)"

assert_eq "the fake arm produced a hundred blocks" "100" "$FAKE_BLOCKS"
assert_eq "…and its last timestamp is 100, one per block" "100" "$FAKE_TS"
assert_true "…and its archive root is a field element rather than MISSING" test "${#FAKE_ARCHIVE}" -eq 66

echo "== and a hundred on upstream's own RunningPromise"

REAL_BLOCKS="$(m23_arm hundredBlocks real.blocks)"
REAL_TS="$(m23_arm hundredBlocks real.lastTimestamp)"
REAL_ARCHIVE="$(m23_arm hundredBlocks real.archive)"
REAL_TICKS="$(m23_arm hundredBlocks real.ticks)"
REAL_MS="$(m23_arm hundredBlocks real.elapsedMs)"

assert_eq "the real-timer arm produced a hundred blocks" "100" "$REAL_BLOCKS"
assert_eq "…driven by a hundred ticks of RunningPromise" "100" "$REAL_TICKS"
assert_true "…and its archive root is a field element" test "${#REAL_ARCHIVE}" -eq 66

echo "== THE COMPARISON: the two chains are the same chain"
assert_eq "the same block count" "$FAKE_BLOCKS" "$REAL_BLOCKS"
assert_eq "the same final timestamp" "$FAKE_TS" "$REAL_TS"
assert_eq "the same ARCHIVE ROOT, which commits to every header in the chain" \
  "$FAKE_ARCHIVE" "$REAL_ARCHIVE"
assert_eq "and the arm agrees that they are identical" "true" "$(m23_arm hundredBlocks identical)"

# NOT A TAUTOLOGY: the root reached after a hundred blocks must differ from the one after three, or
# "the same archive root" would be satisfied by a chain that never moved.
THREE="$(m23_arm emptyBlocks blocks.2.archiveAfter.root)"
assert_true "…and that root is not the three-block chain's, so the value is not a constant" \
  test "$FAKE_ARCHIVE" != "$THREE"
GENESIS="$(m23_arm archiveIdentity genesisRoot)"
assert_true "…nor the genesis root" test "$FAKE_ARCHIVE" != "$GENESIS"

echo "== no wall-clock waiting"
assert_true "the fake arm's elapsed time was recorded" test "$FAKE_MS" -ge 0
assert_true "the fake arm took far less than a hundred one-second intervals" test "$FAKE_MS" -lt 30000
assert_true "the real arm's elapsed time was recorded too" test "$REAL_MS" -ge 0

echo "== the fake ticker has no timer of any kind, and that is structural"
TICKER="$(cat "$ORCH_SRC/chain_clock.ts")"
# `ManualTicker`'s body, extracted, must contain no timer call. The extraction is asserted to have
# found something, because an empty extraction contains no timer call either.
MANUAL="$(awk '/^export class ManualTicker/,/^}/' "$ORCH_SRC/chain_clock.ts")"
assert_ge "the ManualTicker class body was extracted" 20 "$(printf '%s\n' "$MANUAL" | grep -c .)"
assert_false "ManualTicker calls no setTimeout" str_has_sub "$MANUAL" "setTimeout("
assert_false "ManualTicker calls no setInterval" str_has_sub "$MANUAL" "setInterval("
assert_false "ManualTicker calls no Date.now" str_has_sub "$MANUAL" "Date.now("
# THE CONTROL for that extraction: the class that DOES hold a timer is the one that holds upstream's
# `RunningPromise`, and the file says so.
assert_true "RunningPromiseTicker holds upstream's RunningPromise" \
  str_has_sub "$TICKER" "new RunningPromise("
assert_true "…imported from @aztec/foundation/running-promise" \
  str_has_sub "$TICKER" "from '@aztec/foundation/running-promise'"

m23_finish
