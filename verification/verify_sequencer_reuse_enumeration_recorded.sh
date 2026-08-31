#!/usr/bin/env bash
# verify_sequencer_reuse_enumeration_recorded — the enumeration, re-derived rather than read.
#
# The verification entry: "What upstream's sequencer and block builders already provide is
# enumerated, with each item marked reused or rejected-with-reason, before any loop code is
# written."
#
# THIS CHECK DOES NOT READ THE ANSWER OUT OF A DOCUMENT AND AGREE WITH IT. Every figure below is
# taken from the FORK at the pinned anchor on every run, and `CHAIN-LOOP.md` is then held to what
# was found. The reason is the campaign's own record: the PARALLEL-SUBDIRECTORY family, whose
# running count `CAMPAIGN-BRIEF.md` states once and this comment deliberately does not repeat —
# every miss was a directory beside the one being searched, including this one.
# RI-41 was `build`, with a rejection reason that did not survive checking, because
# `sequencer-client/` was enumerated and `sequencer-client/src/sequencer/automine/` was not.
#
# THE DECISIVE MEASUREMENT IS PER OPERATION, NOT PER PACKAGE. "It is a node component we cannot
# use" is exactly the assumption this plan has been wrong about, so `AutomineSequencer` is measured
# entry point by entry point: which of its seven public methods reach anvil cheat codes or the
# rollup publisher, and which do not. Six do; the seventh drains a queue.
#
# AND THE PARTS THAT WERE TAKEN ARE ASSERTED TO HAVE BEEN TAKEN. A rejection is only honest beside
# the reuse it did not prevent: `RunningPromise` and the `DateProvider` family are upstream's and
# are imported, not reimplemented, and that is checked in the source rather than described.
#
# Run: just verify-chain-enumeration

TEST_NAME="verify_sequencer_reuse_enumeration_recorded"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit
m23_require_anchor

DOC="$(cat "$M23_DOC")"
assert_file "CHAIN-LOOP.md exists" "$M23_DOC"
assert_ge "…and is a substantial document rather than a stub" 150 "$(printf '%s\n' "$DOC" | grep -c .)"

# ---------------------------------------------------------------------------
# PART 1 — the automine directory exists, and it is where RI-41 said it was
# ---------------------------------------------------------------------------
echo "== the subdirectory the first enumeration missed"

AUTOMINE_FILES="$(git -C "$FORK_ROOT" ls-tree -r --name-only "$M23_CPP_ANCHOR" \
  -- yarn-project/sequencer-client/src/sequencer/automine/ | grep -c . || true)"
assert_eq "sequencer-client/src/sequencer/automine/ has four files at the anchor" "4" "$AUTOMINE_FILES"

AUTOMINE_SRC="$(m23_anchor_file yarn-project/sequencer-client/src/sequencer/automine/automine_sequencer.ts)"
AUTOMINE_LINES="$(printf '%s\n' "$AUTOMINE_SRC" | grep -c .)"
assert_ge "automine_sequencer.ts is a substantial implementation" 700 "$AUTOMINE_LINES"
assert_true "…and it declares the AutomineSequencer class" str_has_sub "$AUTOMINE_SRC" "class AutomineSequencer"

# ---------------------------------------------------------------------------
# PART 2 — the per-operation L1 measurement, from the source
# ---------------------------------------------------------------------------
echo "== six of its seven public entry points reach L1, and the seventh drains a queue"

# The L1 vocabulary, by name. Each is a distinct mechanism, so finding one does not stand in for
# the others: cheat codes over an anvil RPC, and a publisher that sends transactions to the rollup.
for needle in \
  "ethCheatCodes.setNextBlockTimestamp" \
  "ethCheatCodes.lastBlockTimestamp" \
  "publisher.sendRequests" \
  "enqueueProposeCheckpoint" \
  "anvil_dropAllTransactions" \
  "evmMine()" \
  "markAsProven"
do
  assert_true "AutomineSequencer reaches $needle" str_has_sub "$AUTOMINE_SRC" "$needle"
done
# THE CONTROL for those seven needles: a call it does NOT make is not found by the same lookup.
assert_false "…and a cheat code it does not call is not found" \
  str_has_sub "$AUTOMINE_SRC" "ethCheatCodes.setNextBlockGasLimit"

# The seventh entry point is the one that does NOT reach L1, and it is measured as such.
assert_true "syncPoint() drains a SerialQueue and nothing else" \
  str_has_sub "$AUTOMINE_SRC" "return this.queue.syncPoint();"

# Its README states the requirement in terms, which is the strongest single piece of evidence.
AUTOMINE_README="$(m23_anchor_file yarn-project/sequencer-client/src/sequencer/automine/README.md)"
assert_true "its README requires a deployed rollup" \
  str_has_sub "$AUTOMINE_README" "the deployed rollup must have \`aztecTargetCommitteeSize == 0\`"
assert_true "…and describes warping as publishing an empty checkpoint at a slot" \
  str_has_sub "$AUTOMINE_README" "by publishing an empty checkpoint at the target slot"

echo "== and the document records that measurement rather than a generality"
assert_true "CHAIN-LOOP.md gives the verdict as cannot-reach-target" \
  str_has_sub "$DOC" "**DECISION: \`cannot-reach-target\`.**"
assert_true "…and names the seventh entry point as the one that does not reach L1" \
  str_has_sub "$DOC" "\`syncPoint()\`"
assert_true "…and quotes the README's own requirement" \
  str_has_sub "$DOC" "aztecTargetCommitteeSize == 0"

# ---------------------------------------------------------------------------
# PART 3 — the global-variable builder, and upstream's own substitution for it
# ---------------------------------------------------------------------------
echo "== the global-variable builder reaches L1, and upstream substitutes it itself"

GVB="$(m23_anchor_file yarn-project/sequencer-client/src/global_variable_builder/global_builder.ts)"
assert_true "the real builder wraps a RollupContract" str_has_sub "$GVB" "RollupContract"
assert_true "…and performs a live L1 read for the min fee" str_has_sub "$GVB" "getManaMinFeeAt"
assert_true "…and derives the timestamp from an L1 genesis time" str_has_sub "$GVB" "getTimestampForSlot"
assert_true "…using l1GenesisTime" str_has_sub "$GVB" "l1GenesisTime"

TXE_GVB="$(m23_anchor_file yarn-project/txe/src/state_machine/global_variable_builder.ts)"
assert_true "TXE substitutes it with a builder of its own" str_has_sub "$TXE_GVB" "TXEGlobalVariablesBuilder"
assert_false "…which performs no L1 read" str_has_sub "$TXE_GVB" "getManaMinFeeAt"
assert_false "…and wraps no rollup contract" str_has_sub "$TXE_GVB" "RollupContract"

echo "== and ours does the same, without inventing a slot"
CHAIN="$(cat "$ORCH_SRC/chain.ts")"
assert_true "the chain builds globals from upstream's own empty" \
  str_has_sub "$CHAIN" "const empty = GlobalVariables.empty();"
assert_true "…and leaves slotNumber at that value rather than fabricating one" \
  str_has_sub "$CHAIN" "\`slotNumber\` is deliberately left at \`empty()\`'s value"
assert_false "…and reaches no rollup contract" str_has_sub "$CHAIN" "RollupContract"
assert_false "…and no L1 client" str_has_sub "$CHAIN" "ViemPublicClient"

# ---------------------------------------------------------------------------
# PART 4 — the empty-block flag is upstream's shape
# ---------------------------------------------------------------------------
echo "== empty-block issuance follows upstream's own flag"

CONFIG="$(m23_anchor_file yarn-project/sequencer-client/src/config.ts)"
assert_true "upstream has a buildCheckpointIfEmpty flag" str_has_sub "$CONFIG" "buildCheckpointIfEmpty"
assert_true "…and a minTxsPerBlock gate" str_has_sub "$CONFIG" "minTxsPerBlock"

JOB="$(m23_anchor_file yarn-project/sequencer-client/src/sequencer/checkpoint_proposal_job.ts)"
assert_true "…and the decision combines them at one site" \
  str_has_sub "$JOB" "this.config.buildCheckpointIfEmpty"
assert_true "…as forceCreate" str_has_sub "$JOB" "forceCreate:"

assert_true "CHAIN-LOOP.md records that our default is FLIPPED and why" \
  str_has_sub "$DOC" "with the default flipped"
PROD="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { DEFAULT_BLOCK_PRODUCTION } from "./src/chain.ts";
console.log(JSON.stringify(DEFAULT_BLOCK_PRODUCTION));
' 2>&1 | tail -1)"
assert_true "…and the shipped default really does produce empty blocks" \
  str_has_sub "$PROD" '"produceEmptyBlocks":true'
assert_true "…with automine OFF by default, which upstream's flag also is" \
  str_has_sub "$PROD" '"automine":false'

# ---------------------------------------------------------------------------
# PART 5 — what WAS reused is reused, in the source
# ---------------------------------------------------------------------------
echo "== the parts that were taken are imported, not reimplemented"

CLOCK="$(cat "$ORCH_SRC/chain_clock.ts")"
assert_true "RunningPromise is imported from @aztec/foundation" \
  str_has_line "$CLOCK" "import { RunningPromise } from '@aztec/foundation/running-promise';"
assert_true "the DateProvider family is imported from @aztec/foundation" \
  str_has_line "$CLOCK" "import { DateProvider, ManualDateProvider, TestDateProvider } from '@aztec/foundation/timer';"
# NOTHING OF OURS REIMPLEMENTS EITHER. `class RunningPromise` and `class DateProvider` must not be
# declared anywhere in the shipped source; the control is that the same scan finds our own classes.
for cls in RunningPromise DateProvider TestDateProvider ManualDateProvider; do
  HITS="$(grep -rn -E "^\s*(export )?class $cls\b" "$ORCH_SRC" "$REPO_ROOT/node-host/src" || true)"
  assert_eq "no class $cls is declared by us" "" "$HITS"
done
assert_true "…and the same scan DOES find our RunningPromiseTicker, so it is not scanning nothing" \
  test -n "$(grep -rn -E '^\s*export class RunningPromiseTicker\b' "$ORCH_SRC" || true)"

echo "== the block loop and the header are upstream's, called"
assert_true "the chain calls M22's assembleBlock" str_has_sub "$CHAIN" "await assembleBlock(processor,"
assert_true "…and M22's sealBlock" str_has_sub "$CHAIN" "await sealBlock(guarded, globals)"
# And nothing in `chain.ts` re-implements the loop. The needles are upstream's own, with the
# vendored file as the control that they work.
for needle in "hasPublicCalls()" "ForkCheckpoint.new(" "revertToCheckpoint("; do
  assert_false "chain.ts does not contain $needle" str_has_sub "$CHAIN" "$needle"
done
VENDORED="$ORCH_SRC/vendor/public_processor/public_processor.ts"
assert_true "…and the vendored processor does, so the needles work" \
  grep -qF 'hasPublicCalls()' "$VENDORED"

# ---------------------------------------------------------------------------
# PART 6 — the enumeration is a TABLE with a verdict per row
# ---------------------------------------------------------------------------
echo "== every enumerated item carries a verdict"

# Each row of section 1's table must end in a verdict word. Extracted and counted rather than
# eyeballed; the count is asserted so a table that lost its rows fails.
ROWS="$(awk '/^## 1\. Upstream/,/^### `AutomineSequencer`/' "$M23_DOC" | grep -c '^| ' || true)"
assert_ge "the enumeration table has a row per item" 10 "$ROWS"
VERDICTS="$(awk '/^## 1\. Upstream/,/^### `AutomineSequencer`/' "$M23_DOC" \
  | grep '^| ' | grep -cE '\*\*(REUSED|REJECTED|REFERENCE|SHAPE REUSED)' || true)"
assert_ge "…and at least ten of them carry a bolded verdict" 10 "$VERDICTS"
assert_true "…and at least one is a rejection with the tag the inventory requires" \
  str_has_sub "$DOC" "cannot-reach-target"

# ---------------------------------------------------------------------------
# PART 7 — the inventory agrees, and its decisions are no longer `open`
# ---------------------------------------------------------------------------
echo "== the inventory entries this enumeration was due to settle are settled"

INV="$REPO_ROOT/REUSE-INVENTORY.md"
# ONE EXTRACTOR, used by the subject below and by the control at the bottom of this section.
_ri_decision() { # <id> -> that entry's `decision:` value, or nothing
  awk -v id="$1" '
    $0 ~ "^### " id " — " {inside=1; next}
    inside && /^### RI-/ {inside=0}
    inside && /^- decision:/ {sub(/^- decision:[ ]*/,""); print; inside=0}
  ' "$INV"
}
for pair in "RI-39 replace" "RI-40 replace" "RI-41 build"; do
  id="${pair%% *}"; want="${pair#* }"
  got="$(_ri_decision "$id")"
  assert_eq "$id's decision is $want" "$want" "$got"
  conf="$(awk -v id="$id" '
    $0 ~ "^### " id " — " {inside=1; next}
    inside && /^### RI-/ {inside=0}
    inside && /^- confidence:/ {sub(/^- confidence:[ ]*/,""); print; inside=0}
  ' "$INV")"
  assert_eq "…and its confidence is measured" "measured" "$conf"
done
# THE CONTROL for that extractor: an id the inventory does not have yields nothing.
#
# TWO THINGS WERE WRONG WITH THIS CONTROL AND BOTH ARE THIS CAMPAIGN'S OWN RECORDED SHAPES.
#
#   1. The id was TYPED (`RI-999`). `REUSE-INVENTORY.md` is at RI-101 and grows every milestone;
#      M36 created RI-98 and RI-99 and thereby silently retired a `RI-99` control in a check it
#      never touched, which had been catching a real defect since M2. Derived from the inventory
#      now, one past its highest id, with the derived value ASSERTED absent — the assertion that
#      goes red on the day the namespace reaches it.
#   2. It was a SECOND, SHORTER awk than the extractor it controls: the subject has three rules and
#      this had two, missing `inside && /^### RI-/ {inside=0}`. "A control has to run through the
#      instrument, not beside it" — the same defect M34's review found in `test_wallet_keys_
#      deterministic`. The extractor is one function now, called for the real ids above and for the
#      derived absent one here, so an extractor that stopped extracting fails both.
ABSENT_RI="RI-$(awk 'match($0, /^### RI-([0-9]+)[^0-9]/, m) { if (m[1]+0 > hi) hi = m[1]+0 } END { print hi + 1 }' "$INV")"
assert_true "the derived absent inventory id was computed from the inventory rather than typed" \
  str_has_re "$ABSENT_RI" '^RI-[0-9]+$'
if grep -q "^### $ABSENT_RI — " "$INV"; then
  fail "the derived id $ABSENT_RI is PRESENT in the inventory, so the control below would be vacuous"
else
  pass "the derived id $ABSENT_RI really is absent, so the control can fail  [$ABSENT_RI]"
fi
MISSING="$(_ri_decision "$ABSENT_RI")"
assert_eq "…and an id the inventory does not define yields nothing" "" "$MISSING"
# …and the same extractor, on a real id, still answers — so the empty result above is a reading
# rather than an extractor that has stopped extracting.
assert_eq "…while the same extractor still answers for a real id" "replace" "$(_ri_decision RI-39)"

m23_finish
