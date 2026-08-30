#!/usr/bin/env bash
# e2e_replay_matches_published_effects — L2 (Aztec-Live-Chain-Replay).
#
# "Re-execution reproduces the published revertCode, gas and side effects.
#  Control: a transaction replayed against the WRONG block's state does NOT match, and says so."
#
# ─────────────────────────────────────────────────────────────────────────────
# THE CONTROL IS THE WHOLE CHECK, AND IT IS THE ONE L2 NAMED AGAINST ITSELF.
#
# "A check that never exercises what it is named for" is this campaign's most-repeated defect. Here
# it has a precise shape: a replay that seeded its trees from the transaction's own PUBLISHED
# effects would reproduce those effects exactly, be green on every assertion in §1, and measure
# nothing at all — a comparison of a value with itself.
#
# So §3 runs the SAME loop with one thing changed: the pre-state is read at the SETTLING block
# instead of at its parent. Every read then returns the value the transaction ITSELF wrote, so the
# contract's read-modify-write increments an already-incremented counter and its assertion fails.
#
# THE CONTROL IS A MODE OF THE SUBJECT AND NOT A SECOND FUNCTION —
# `resolvePublicContractsUnguardedForControls` is the precedent and M32's review is the reason: a
# control that "was a SECOND EXPRESSION over a SECOND buffer constrained its own code and not the
# container's". `preStateBlockForControls` is one option on `replaySettledTransaction`: one loop,
# one seeding path, one comparison, one flag.
#
# AND THE CONTROL'S ANSWERS ARE CAPTURED FROM THE LIVE CHAIN, not synthesised. The capture runs the
# wrong-block loop as a second pass and records its calls, so the control plays back offline like
# everything else, over witnesses that are real answers at a real block. L1's fabricated probes are
# the precedent: a synthesised null proves our code turns null into a refusal; a captured one proves
# the chain says it.
#
# ─────────────────────────────────────────────────────────────────────────────
# §2 IS THE NON-DEGENERACY, and it is not decoration.
#
# "When an identity is asserted over data, assert that the data is not degenerate." A replay that
# executed one instruction and wrote nothing would satisfy "published effects reproduced" if the
# transaction had published nothing. So the subject is asserted to have DONE something: 345
# instructions, nine public data writes with non-zero slots, a non-zero fee, and a seed that was
# actually built (fifteen leaves) rather than an empty one.
#
# THE COMPARISON COUNT IS ASSERTED, NOT JUST THE FAILURE COUNT. "Zero mismatches" over zero
# comparisons is the vacuous green this campaign has shipped twice; `reproduced` already requires
# `comparisons.length > 0` in the module, and §1 pins the number so a comparison that silently
# stopped comparing would drop the count instead of staying green.
#
# Run: just verify-l2-effects

set -uo pipefail
TEST_NAME="e2e_replay_matches_published_effects"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l2_replay.sh"

echo "== $TEST_NAME"
l2_prepare

PROBE="$(l2_imports)
$(cat <<'EOS'

const fixture = readL2Fixture();
const settled = await l2Settled(fixture);
const host = await createNodeAvmHost(L2_MODULE_PATH);

line('subject.txHash', settled.txHash);
line('subject.l2BlockNumber', settled.l2BlockNumber);
line('subject.txIndexInBlock', settled.txIndexInBlock);
line('subject.publishedRevertCode', settled.revertCode);
line('subject.publishedFee', settled.txEffect.data.transactionFee.toString());
line('subject.publishedWrites', settled.txEffect.data.publicDataWrites.length);
line('subject.publishedNullifiers', settled.txEffect.data.nullifiers.length);
line('subject.contractBytecodeBytes', settled.contracts[0].packedBytecodeBytes);
line('subject.resolvedAsOf', settled.contracts[0].resolvedAsOf);

// ---- 1. THE SUBJECT: the pre-state at the PARENT block, which is correct ----
const real = await replaySettledTransaction(host, l2Client(fixture), settled, encodeReplayInputs);
line('real.preStateBlock', real.preStateBlock);
line('real.revertCode', real.revertCode);
line('real.reproduced', real.verdict.reproduced ? 'yes' : 'no');
line('real.matched', real.verdict.matched);
line('real.mismatched', real.verdict.mismatched);
line('real.comparisons', real.verdict.comparisons.length);
line('real.rounds', real.rounds.length);
line('real.seedNullifiers', real.seedSize.nullifiers);
line('real.seedPublicData', real.seedSize.publicData);
line('real.instructions', real.instructionsExecuted);

// The comparison's own fields, so "reproduced" is not one boolean standing for twenty-three facts.
const byField = new Map(real.verdict.comparisons.map((c) => [c.field, c]));
line('real.revertCodeMatched', byField.get('revertCode')?.matches ? 'yes' : 'no');
line('real.feeMatched', byField.get('transactionFee')?.matches ? 'yes' : 'no');
line('real.writeCountMatched', byField.get('publicDataWrites.length')?.matches ? 'yes' : 'no');
line('real.nullifier0Matched', byField.get('nullifiers[0]')?.matches ? 'yes' : 'no');
let slotFields = 0, valueFields = 0;
for (const c of real.verdict.comparisons) {
  if (/^publicDataWrites\[\d+\]\.leafSlot$/.test(c.field) && c.matches) slotFields += 1;
  if (/^publicDataWrites\[\d+\]\.value$/.test(c.field) && c.matches) valueFields += 1;
}
line('real.writeSlotsMatched', slotFields);
line('real.writeValuesMatched', valueFields);
// The replayed fee, read out of the comparison rather than off the effect, so the two readings can
// disagree.
line('real.replayedFee', byField.get('transactionFee')?.replayed ?? 'none');

// ---- 2. NON-DEGENERACY: the subject actually DID something -----------------
// The published write values, so "nine writes matched" is not nine zeros agreeing with nine zeros.
const publishedValues = settled.txEffect.data.publicDataWrites.map((w) => w.value.toString());
line('real.publishedNonZeroValues', publishedValues.filter((v) => BigInt(v) !== 0n).length);
line('real.publishedDistinctSlots',
     new Set(settled.txEffect.data.publicDataWrites.map((w) => w.leafSlot.toString())).size);
line('real.feeIsNonZero', BigInt(settled.txEffect.data.transactionFee.toString()) > 0n ? 'yes' : 'no');
// The seed was BUILT, not empty: a replay that seeded nothing and still matched would mean the
// transaction read nothing, and this one reads fifteen leaves.
line('real.seededLeaves', real.seed.seeded.length);
line('real.skippedWithReasons',
     real.rounds.flatMap((r) => r.skipped).every((s) => SEED_SKIP_REASONS.includes(s.reason)) ? 'yes' : 'no');
line('real.skippedCount', real.rounds.flatMap((r) => r.skipped).length);
// The AVM's own instruction count, which is a different number from the comparison count.
line('real.statsCount', real.instructionsExecuted);

// ---- 3. THE CONTROL: the WRONG block's state ------------------------------
// The same loop, the same seeding path, the same comparison. One option.
const control = await classify('control', () =>
  replaySettledTransaction(host, l2Client(fixture), settled, encodeReplayInputs,
    { preStateBlockForControls: 'settling-block' }));
if (control.outcome === 'returned') {
  const c = control.value;
  line('control.preStateBlock', c.preStateBlock);
  line('control.revertCode', c.revertCode);
  line('control.reproduced', c.verdict.reproduced ? 'yes' : 'no');
  line('control.matched', c.verdict.matched);
  line('control.mismatched', c.verdict.mismatched);
  line('control.comparisons', c.verdict.comparisons.length);
  line('control.instructions', c.instructionsExecuted);
  line('control.rounds', c.rounds.length);
  line('control.seedPublicData', c.seedSize.publicData);
  const cb = new Map(c.verdict.comparisons.map((x) => [x.field, x]));
  line('control.revertCodeMatched', cb.get('revertCode')?.matches ? 'yes' : 'no');
  line('control.feeMatched', cb.get('transactionFee')?.matches ? 'yes' : 'no');
  line('control.writeCountMatched', cb.get('publicDataWrites.length')?.matches ? 'yes' : 'no');
  // AND IT SAYS SO: every mismatch carries both sides, so a caller is told what differed rather
  // than only that something did.
  const first = c.verdict.comparisons.find((x) => !x.matches);
  line('control.firstMismatchField', first?.field ?? 'none');
  line('control.firstMismatchHasBothSides',
       first && first.published !== '(absent)' && first.published !== first.replayed ? 'yes' : 'no');
  line('control.blocksDiffer', c.preStateBlock === real.preStateBlock ? 'no' : 'yes');
  line('control.blockDelta', c.preStateBlock - real.preStateBlock);
} else {
  line('control.preStateBlock', -1);
  line('control.reproduced', 'threw');
  line('control.mismatched', -1);
}

// ---- 4. THE TWO RUNS ARE TWO RUNS ------------------------------------------
// Without this, §1 and §3 could both be reading one cached outcome.
line('both.sameHostObject', 'yes');
line('both.realIsReproduced', real.verdict.reproduced ? 'yes' : 'no');
line('both.controlIsNot',
     control.outcome === 'returned' && !control.value.verdict.reproduced ? 'yes' : 'no');

line('l2.done', 1);
EOS
)"

OUT="$L2_WORK/probes/l2effects.out"
L0_PROBE_TIMEOUT="${L0_PROBE_TIMEOUT:-600}" l0_run_probe l2effects "$PROBE" "$OUT" l2.done
f() { l0_field "$OUT" "$1"; }
j() { l1_json "$L2_FIXTURE" "$1"; }

# ---------------------------------------------------------------------------
echo "== 1. the subject: re-execution reproduces what the chain published"
# ---------------------------------------------------------------------------
assert_eq "the transaction is the one the fixture recorded" "$(j "d['provenance']['txHash']")" \
  "$(f subject.txHash)"
assert_eq "…settled in the block the fixture recorded" "$(j "d['provenance']['l2BlockNumber']")" \
  "$(f subject.l2BlockNumber)"
assert_eq "…and it is FIRST in its block, which is the only case this route can answer" "0" \
  "$(f subject.txIndexInBlock)"
assert_eq "the pre-state was read at the PARENT block, not the settling one" \
  "$(( $(f subject.l2BlockNumber) - 1 ))" "$(f real.preStateBlock)"

assert_eq "the replayed revertCode is the published one" "$(f subject.publishedRevertCode)" \
  "$(f real.revertCode)"
assert_eq "…and the published one is 0, so this is a transaction that SUCCEEDED" "0" \
  "$(f subject.publishedRevertCode)"
assert_eq "the published effects are reproduced" "yes" "$(f real.reproduced)"
assert_eq "…with zero mismatches" "0" "$(f real.mismatched)"
assert_eq "…over 23 comparisons, pinned so a comparison that stopped comparing DROPS the count" \
  "23" "$(f real.comparisons)"
assert_eq "…and 23 of them matched" "23" "$(f real.matched)"

assert_eq "the revertCode comparison specifically matched" "yes" "$(f real.revertCodeMatched)"
assert_eq "…the transaction fee" "yes" "$(f real.feeMatched)"
assert_eq "…the write COUNT" "yes" "$(f real.writeCountMatched)"
assert_eq "…and the single nullifier" "yes" "$(f real.nullifier0Matched)"
assert_eq "every published write's leaf SLOT matched" "$(f subject.publishedWrites)" \
  "$(f real.writeSlotsMatched)"
assert_eq "…and every published write's VALUE matched" "$(f subject.publishedWrites)" \
  "$(f real.writeValuesMatched)"
assert_eq "the replayed fee is the published fee, read from the comparison's own two sides" \
  "$(f subject.publishedFee)" "$(f real.replayedFee)"
assert_eq "…which is the fee the fixture's provenance recorded from the node" \
  "$(j "d['provenance']['nodeReported']['transactionFee']")" "$(f subject.publishedFee)"

# ---------------------------------------------------------------------------
echo "== 2. and the subject is not degenerate — it DID something"
#
# Every assertion above is satisfied by a transaction that did nothing, if the chain also published
# nothing. This section is what stops that reading.
# ---------------------------------------------------------------------------
assert_eq "the chain published nine public data writes" "9" "$(f subject.publishedWrites)"
assert_eq "…and the fixture's provenance agrees, which is a second reading" \
  "$(j "d['provenance']['nodeReported']['publishedEffects']['publicDataWrites']")" \
  "$(f subject.publishedWrites)"
assert_ge "…of which several carry NON-ZERO values, so nine zeros are not agreeing with nine zeros" \
  4 "$(f real.publishedNonZeroValues)"
assert_eq "…at nine DISTINCT slots" "9" "$(f real.publishedDistinctSlots)"
assert_eq "the transaction fee is non-zero" "yes" "$(f real.feeIsNonZero)"
assert_ge "the AVM executed a real program, not a sentinel" 300 "$(f real.instructions)"
assert_eq "…345 instructions, the AVM's own statistic" "345" "$(f real.statsCount)"
assert_ge "the contract had real bytecode behind it" 20000 "$(f subject.contractBytecodeBytes)"
assert_eq "…resolved as of the SETTLING block, which is L2's own requirement" \
  "$(f subject.l2BlockNumber)" "$(f subject.resolvedAsOf)"

assert_ge "the hydration seeded a real tree rather than an empty one" 14 "$(f real.seededLeaves)"
assert_eq "…four nullifiers" "4" "$(f real.seedNullifiers)"
assert_eq "…and eleven public-data leaves" "11" "$(f real.seedPublicData)"
assert_eq "…in six rounds, so the loop DISCOVERED state rather than being handed it" "6" \
  "$(f real.rounds)"
assert_ge "…and it skipped some queries too, so the skip path is exercised" 1 \
  "$(f real.skippedCount)"
assert_eq "…every skip carrying one of the declared reasons" "yes" "$(f real.skippedWithReasons)"

# ---------------------------------------------------------------------------
echo "== 3. THE CONTROL: replayed against the WRONG block's state, it does NOT match"
#
# The same loop with one option changed. Without this, §1 is satisfied by a replay that seeded its
# trees from the answer — a comparison of a value with itself.
# ---------------------------------------------------------------------------
assert_eq "the control ran and returned rather than throwing" "returned" "$(f control.outcome)"
assert_eq "…reading its pre-state at the SETTLING block" "$(f subject.l2BlockNumber)" \
  "$(f control.preStateBlock)"
assert_eq "…which is a DIFFERENT block from the subject's" "yes" "$(f control.blocksDiffer)"
assert_eq "…by exactly one" "1" "$(f control.blockDelta)"

assert_eq "THE CONTROL DOES NOT REPRODUCE THE PUBLISHED EFFECTS" "no" "$(f control.reproduced)"
assert_ge "…with many mismatches and not one" 20 "$(f control.mismatched)"
assert_eq "…over the same 23 comparisons, so the two runs are comparable" "23" \
  "$(f control.comparisons)"
assert_eq "the control's revertCode does NOT match" "no" "$(f control.revertCodeMatched)"
assert_eq "…and the transaction REVERTED, because it read its own post-state" "1" \
  "$(f control.revertCode)"
assert_eq "…its fee does not match either" "no" "$(f control.feeMatched)"
assert_eq "…nor its write count" "no" "$(f control.writeCountMatched)"

# "and SAYS SO" is the deliverable's own words: a failure that names what differed.
assert_eq "the control NAMES what differed first" "revertCode" "$(f control.firstMismatchField)"
assert_eq "…and carries both sides of it, so a reader is told what, not only that" "yes" \
  "$(f control.firstMismatchHasBothSides)"

# The control is a DIFFERENT execution and not a cached one: it runs fewer instructions and settles
# in fewer rounds, because it reverts earlier and therefore asks fewer questions.
assert_eq "the control executed a different number of instructions" "254" \
  "$(f control.instructions)"
assert_false "…which is not the subject's count" \
  test "$(f control.instructions)" = "$(f real.instructions)"
assert_eq "…and converged in fewer rounds" "3" "$(f control.rounds)"

# ---------------------------------------------------------------------------
echo "== 4. the two runs are two runs"
# ---------------------------------------------------------------------------
assert_eq "the real run reproduced" "yes" "$(f both.realIsReproduced)"
assert_eq "…and the control did not" "yes" "$(f both.controlIsNot)"
assert_false "…so the two verdicts are not one value read twice" \
  test "$(f real.mismatched)" = "$(f control.mismatched)"

finish
