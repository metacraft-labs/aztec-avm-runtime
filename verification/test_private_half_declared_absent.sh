#!/usr/bin/env bash
# test_private_half_declared_absent — L1 (Aztec-Live-Chain-Replay).
#
# "The recording states the private half is unavailable in principle.
#  Control: a locally-originated transaction with a private half does NOT carry that statement."
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY A STATEMENT AND NOT AN EMPTY FIELD, IN THE CAMPAIGN'S OWN WORDS.
#
# "Every deliverable here must declare that absence rather than render an empty frame — an empty
# frame is indistinguishable from a private half that failed to load, and the reader cannot tell
# which they are looking at."
#
# ─────────────────────────────────────────────────────────────────────────────
# AND WHY THE CONTROL IS THE WHOLE CHECK.
#
# A function that returns "unavailable in principle" for every input is a PRINTED LITERAL — this
# campaign's most-repeated defect, in the shape it takes when the subject is a declaration. Asked
# only about settled transactions it would be green forever. So §3 hands the same function
# upstream's own `PrivateExecutionResult.random(2)` — the ACIR, the partial witnesses and the
# nested private call tree that a PXE produces and never publishes — and the answer must be
# `available`, with counts that are not zero.
#
# §2 IS THE OTHER HALF OF THE NON-DEGENERACY, and it is why this milestone captured a SECOND
# fixture. `testnet_private_only_tx.json` is a real testnet transaction with NO public half at all
# and a private half whose EFFECTS the chain published: 12 note hashes, 15 nullifiers, 2 private
# logs. So "the chain carries the effects and not the execution" is measured over a transaction
# that HAS a private half, rather than over one whose private side was empty anyway — which is
# CAMPAIGN-BRIEF.md's "both sides read, both sides zero" family exactly.
#
# Run: just verify-l1-private

set -uo pipefail
TEST_NAME="test_private_half_declared_absent"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l1_settled_tx.sh"

echo "== $TEST_NAME"
l1_prepare

FIXTURE="$L1_FIXTURE_DIR/testnet_settled_tx.json"
PRIVATE_FIXTURE="$L1_FIXTURE_DIR/testnet_private_only_tx.json"

PROBE="$(l1_imports)
$(cat <<'EOS'

import { TxHash } from '@aztec/stdlib/tx/tx-hash';
import { PrivateExecutionResult } from '@aztec/stdlib/tx';

// ---- 1. THE SETTLED TRANSACTION: the statement, in the artefact -------------
// Read off the `SettledTransaction` the fetch produces, not off `declarePrivateHalf` in isolation:
// the deliverable is that the RECORDING states it, so the statement has to survive into the value a
// caller receives.
const privateOnly = readFixture('testnet_private_only_tx.json');
const settled = await fetchSettledTransaction(
  fixtureClient(privateOnly), TxHash.fromString(privateOnly.provenance.txHash));
const declared = settled.privateHalf;

line('settled.txHash', settled.txHash);
line('settled.status', declared.status);
line('settled.origin', declared.origin);
line('settled.reasonLength', declared.reason.length);
line('settled.reasonSaysInPrinciple', declared.reason.includes('IN PRINCIPLE') ? 'yes' : 'no');
line('settled.reasonSaysNotEmptyFrame', declared.reason.includes('empty frame') ? 'yes' : 'no');
line('settled.reasonIsTheDeclaredOne', declared.reason === PRIVATE_HALF_UNAVAILABLE_REASON ? 'yes' : 'no');
line('settled.hasExecutionField', 'execution' in declared ? 'yes' : 'no');
line('settled.hasPublishedEffects', 'publishedEffects' in declared ? 'yes' : 'no');

// ---- 2. WHAT THE CHAIN DID PUBLISH: effects, not execution ------------------
// The counts are read off the TxEffect. They are NOT zero, which is what makes the sentence above a
// statement about a transaction that had a private half rather than about one that had none.
line('effects.noteHashes', declared.publishedEffects.noteHashes);
line('effects.nullifiers', declared.publishedEffects.nullifiers);
line('effects.privateLogs', declared.publishedEffects.privateLogs);
line('effects.contractClassLogs', declared.publishedEffects.contractClassLogs);
line('effects.total',
     declared.publishedEffects.noteHashes + declared.publishedEffects.nullifiers
       + declared.publishedEffects.privateLogs);
// …and the counts are the TxEffect's own, re-read here rather than taken from the declaration.
line('effects.effectNoteHashes', settled.txEffect.data.noteHashes.length);
line('effects.effectNullifiers', settled.txEffect.data.nullifiers.length);
line('effects.effectPrivateLogs', settled.txEffect.data.privateLogs.length);
// This transaction has NO public half, so the private half is the whole of it — and there is still
// no execution to be had.
line('effects.publicHalfPresent', settled.publicHalf.present ? 'yes' : 'no');

// ---- 3. THE CONTROL: a locally-originated transaction WITH a private half ---
// Upstream's own generator. A PXE that ran this transaction has exactly this object; a chain does
// not publish it and never will.
const local = await PrivateExecutionResult.random(2);
const localDeclared = declarePrivateHalf({ origin: 'locally-originated', privateExecutionResult: local });
line('local.status', localDeclared.status);
line('local.origin', localDeclared.origin);
line('local.reasonIsTheOtherOne', localDeclared.reason === PRIVATE_HALF_AVAILABLE_REASON ? 'yes' : 'no');
line('local.doesNotCarryTheAbsenceStatement',
     localDeclared.reason === PRIVATE_HALF_UNAVAILABLE_REASON ? 'no' : 'yes');
line('local.hasExecutionField', 'execution' in localDeclared ? 'yes' : 'no');
line('local.hasPublishedEffects', 'publishedEffects' in localDeclared ? 'yes' : 'no');
line('local.privateCalls', localDeclared.execution.privateCalls);
line('local.acirBytes', localDeclared.execution.acirBytes);
line('local.partialWitnessEntries', localDeclared.execution.partialWitnessEntries);
// The measurement is the TREE's and not the entrypoint's: a walk that stopped at the top would
// report 1 for a result built with two levels of nesting.
line('local.entrypointNested', local.entrypoint.nestedExecutionResults.length);
line('local.measuredAgain', measureLocalPrivateExecution(local).privateCalls);

// ---- 4. THE TWO ANSWERS ARE TWO ANSWERS ------------------------------------
line('both.statusesDiffer', declared.status === localDeclared.status ? 'no' : 'yes');
line('both.reasonsDiffer', declared.reason === localDeclared.reason ? 'no' : 'yes');
line('both.originsDiffer', declared.origin === localDeclared.origin ? 'no' : 'yes');
line('both.declaredConstants', [PRIVATE_HALF_UNAVAILABLE, PRIVATE_HALF_AVAILABLE].join(','));

// ---- 5. THE OTHER FIXTURE SAYS THE SAME THING ------------------------------
// A transaction WITH a public half still has no private execution, so the statement is not a
// property of transactions that happen to be private-only.
const withPublic = readFixture('testnet_settled_tx.json');
const settledPublic = await fetchSettledTransaction(
  fixtureClient(withPublic), TxHash.fromString(withPublic.provenance.txHash));
line('public.status', settledPublic.privateHalf.status);
line('public.publicHalfPresent', settledPublic.publicHalf.present ? 'yes' : 'no');
line('public.reasonIsTheDeclaredOne',
     settledPublic.privateHalf.reason === PRIVATE_HALF_UNAVAILABLE_REASON ? 'yes' : 'no');
line('public.effectsTotal',
     settledPublic.privateHalf.publishedEffects.noteHashes
       + settledPublic.privateHalf.publishedEffects.nullifiers
       + settledPublic.privateHalf.publishedEffects.privateLogs);

line('l1.done', 1);
EOS
)"

OUT="$L1_WORK/probes/private.out"
l0_run_probe private "$PROBE" "$OUT" l1.done
f() { l0_field "$OUT" "$1"; }
p() { l1_json "$PRIVATE_FIXTURE" "$1"; }
j() { l1_json "$FIXTURE" "$1"; }

# ---------------------------------------------------------------------------
echo "== 1. the recording STATES that the private half is unavailable in principle"
# ---------------------------------------------------------------------------
assert_eq "the transaction is the one the fixture recorded" "$(p "d['provenance']['txHash']")" \
  "$(f settled.txHash)"
assert_eq "its private half is declared unavailable" "unavailable-in-principle" "$(f settled.status)"
assert_eq "…because it came off a chain" "settled-chain" "$(f settled.origin)"
assert_eq "…with the declared reason and not one assembled on the spot" "yes" \
  "$(f settled.reasonIsTheDeclaredOne)"
assert_ge "…which is a real sentence rather than a token" 200 "$(f settled.reasonLength)"
assert_eq "…saying IN PRINCIPLE, which is the distinction that matters" "yes" \
  "$(f settled.reasonSaysInPrinciple)"
assert_eq "…and saying why it is not an empty frame" "yes" "$(f settled.reasonSaysNotEmptyFrame)"
assert_eq "the declaration carries no execution field, because there is no execution" "no" \
  "$(f settled.hasExecutionField)"
assert_eq "…and does carry what the chain DID publish" "yes" "$(f settled.hasPublishedEffects)"

# ---------------------------------------------------------------------------
echo "== 2. and it is said over a transaction that HAD a private half"
#
# "When an identity is asserted over data, assert that the data is not degenerate." A private-half
# statement about a transaction with no private effects would be true and empty.
# ---------------------------------------------------------------------------
assert_eq "the note hashes the chain published" "$(p "d['provenance']['nodeReported']['publishedEffects']['noteHashes']")" \
  "$(f effects.noteHashes)"
assert_eq "…the nullifiers" "$(p "d['provenance']['nodeReported']['publishedEffects']['nullifiers']")" \
  "$(f effects.nullifiers)"
assert_eq "…and the private logs" "$(p "d['provenance']['nodeReported']['publishedEffects']['privateLogs']")" \
  "$(f effects.privateLogs)"
assert_ge "…which together are NOT zero, so this transaction really had a private half" 20 \
  "$(f effects.total)"
assert_ge "…and the private logs alone are non-zero" 1 "$(f effects.privateLogs)"
# The declaration's counts are the TxEffect's own, re-read from the effect rather than from the
# declaration: two readings, so a declaration that made its numbers up would disagree.
assert_eq "the declared note-hash count is the effect's" "$(f effects.effectNoteHashes)" \
  "$(f effects.noteHashes)"
assert_eq "…the nullifier count" "$(f effects.effectNullifiers)" "$(f effects.nullifiers)"
assert_eq "…and the private-log count" "$(f effects.effectPrivateLogs)" "$(f effects.privateLogs)"
assert_eq "this transaction has NO public half, so the private half is the whole of it" "no" \
  "$(f effects.publicHalfPresent)"

# ---------------------------------------------------------------------------
echo "== 3. THE CONTROL: a locally-originated transaction does NOT carry that statement"
#
# Upstream's own `PrivateExecutionResult.random(2)`, through the same function. Without this,
# every assertion above is satisfied by a function that returns one sentence for every input.
# ---------------------------------------------------------------------------
assert_eq "a private half that IS in hand is declared available" "available" "$(f local.status)"
assert_eq "…and locally originated" "locally-originated" "$(f local.origin)"
assert_eq "…with the OTHER reason" "yes" "$(f local.reasonIsTheOtherOne)"
assert_eq "…and it does NOT carry the absence statement, which is the control's own sentence" "yes" \
  "$(f local.doesNotCarryTheAbsenceStatement)"
assert_eq "it carries the execution instead" "yes" "$(f local.hasExecutionField)"
assert_eq "…and no published-effects field, because nothing was published" "no" \
  "$(f local.hasPublishedEffects)"
# NON-DEGENERATE IN THE OTHER DIRECTION TOO: 'available' with three zeros beside it would be as
# empty a statement as the one this check exists to prevent.
assert_ge "the private execution has calls in it" 2 "$(f local.privateCalls)"
assert_ge "…ACIR bytes" 1 "$(f local.acirBytes)"
assert_ge "…and partial-witness entries" 1 "$(f local.partialWitnessEntries)"
# THE WALK IS THE TREE'S, NOT THE ENTRYPOINT'S. A measurement that stopped at the top would report
# 1 here whatever the nesting is.
assert_ge "the entrypoint really has nested calls under it" 1 "$(f local.entrypointNested)"
assert_ge "…and the count exceeds one, so the walk descended" 2 "$(f local.measuredAgain)"
assert_eq "…and re-measuring gives the same number" "$(f local.privateCalls)" "$(f local.measuredAgain)"

# ---------------------------------------------------------------------------
echo "== 4. the two answers are two answers"
# ---------------------------------------------------------------------------
assert_eq "the statuses differ" "yes" "$(f both.statusesDiffer)"
assert_eq "…the reasons differ" "yes" "$(f both.reasonsDiffer)"
assert_eq "…and the origins differ" "yes" "$(f both.originsDiffer)"
assert_eq "the two declared statuses are the two the module names" \
  "unavailable-in-principle,available" "$(f both.declaredConstants)"

# ---------------------------------------------------------------------------
echo "== 5. the statement is not a property of private-only transactions"
#
# The other fixture has a public half, real bytecode and a replayable AVM path — and still no
# private execution. So the declaration follows from where the transaction came from and not from
# whether it happened to do anything public.
# ---------------------------------------------------------------------------
assert_eq "a settled transaction WITH a public half says the same thing" "unavailable-in-principle" \
  "$(f public.status)"
assert_eq "…and it really does have a public half" "yes" "$(f public.publicHalfPresent)"
assert_eq "…with the same declared reason" "yes" "$(f public.reasonIsTheDeclaredOne)"
assert_eq "…and its own published effects, which are a different number" \
  "$(j "d['provenance']['nodeReported']['publishedEffects']['noteHashes'] + d['provenance']['nodeReported']['publishedEffects']['nullifiers'] + d['provenance']['nodeReported']['publishedEffects']['privateLogs']")" \
  "$(f public.effectsTotal)"
assert_eq "…different from the other fixture's, so the field is measured and not constant" "yes" \
  "$(if [ "$(f public.effectsTotal)" = "$(f effects.total)" ]; then echo no; else echo yes; fi)"

finish
