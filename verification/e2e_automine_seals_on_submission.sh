#!/usr/bin/env bash
# e2e_automine_seals_on_submission — the flag, with its discriminator.
#
# The verification entry: "With automine on, submitting a transaction seals a block immediately
# rather than waiting for the tick."
#
# "IMMEDIATELY" IS A COMPARISON AND NOT AN OBSERVATION. A chain that produced a block on every
# submission whatever the flag said would satisfy any assertion made about the automine arm alone.
# So there are two arms differing in ONE thing — `automine: true` and `automine: false` — and every
# claim below is made in both directions:
#
#     automine on   submit -> the block number ADVANCES, the queue is EMPTY, the block carries the tx
#     automine off  submit -> the block number DOES NOT advance, the queue holds the tx
#                   then a tick -> the block number advances and the block carries the tx
#
# The third line matters as much as the first: without it, "automine off does not seal" is also
# true of a chain that cannot seal at all.
#
# THE BLOCK CARRIES THE TRANSACTION, which is a stronger claim than "a block was produced" and is
# the one that would catch an automine that sealed an EMPTY block on submission and left the
# transaction queued. `empty` is asserted false and the transaction count is asserted to be one.
#
# Run: just verify-chain-automine

TEST_NAME="e2e_automine_seals_on_submission"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit
m23_require_arms

echo "== automine ON: submitting seals"

assert_eq "the chain was at block 0 before the submission" "0" "$(m23_arm automine automineOn.before)"
assert_eq "…and at block 1 after it, with no tick in between" "1" "$(m23_arm automine automineOn.after)"
assert_eq "the queue is empty afterwards" "0" "$(m23_arm automine automineOn.pending)"
assert_eq "the sealed block carries the transaction" "1" "$(m23_arm automine automineOn.lastBlockTxs)"
assert_eq "…and reports itself NOT empty" "false" "$(m23_arm automine automineOn.lastBlockEmpty)"

echo "== automine OFF: the discriminator"

assert_eq "the chain was at block 0 before the submission" "0" "$(m23_arm automine automineOff.before)"
assert_eq "…and is STILL at block 0 after it" "0" "$(m23_arm automine automineOff.afterSubmit)"
assert_eq "…with the transaction sitting in the queue" "1" \
  "$(m23_arm automine automineOff.pendingAfterSubmit)"

echo "== and the same chain DOES produce it on the next block"
assert_eq "producing a block takes the chain to block 1" "1" "$(m23_arm automine automineOff.afterTick)"
assert_eq "…and that block carries the transaction" "1" "$(m23_arm automine automineOff.tickBlockTxs)"

echo "== the two arms differ in exactly one configuration field"
# READ OUT OF THE DRIVER'S SOURCE rather than restated, because a constant typed into a check looks
# like a measurement to the person typing it. The two `new AvmChain(...)` calls in the automine arm
# must differ only in `automine`.
DRIVER="$ORCH_SRC/chain_e2e_driver.ts"
assert_file "the driver is here" "$DRIVER"
ARM="$(awk '/^async function armAutomine/,/^\/\*\*$/' "$DRIVER")"
assert_ge "the automine arm's body was extracted" 20 "$(printf '%s\n' "$ARM" | grep -c .)"
assert_true "one arm configures automine: true" str_has_sub "$ARM" "automine: true"
assert_true "…and the other automine: false" str_has_sub "$ARM" "automine: false"
N_CFG="$(printf '%s\n' "$ARM" | grep -c 'intervalMs: 0, automine:' || true)"
assert_eq "and both configure the timer off, so the difference is automine alone" "2" "$N_CFG"

echo "== automine is not a second code path"
# The seal a submission triggers is THE SAME `produceBlock`, so an automined block is subject to
# every rule a ticked one is. That is asserted from the source: `submit` calls `produceBlock`, and
# there is no other sealing path.
CHAIN="$(cat "$ORCH_SRC/chain.ts")"
assert_true "submit() reaches produceBlock() when automine is set" \
  str_has_sub "$CHAIN" "if (this.config.automine) {
      await this.produceBlock();"
N_SEAL="$(grep -c 'await sealBlock(' "$ORCH_SRC/chain.ts" || true)"
assert_eq "and the chain seals in exactly one place" "1" "$N_SEAL"
assert_false "a needle for a second sealing helper finds nothing" \
  str_has_sub "$CHAIN" "sealBlockImmediately("

m23_finish
