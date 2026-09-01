#!/usr/bin/env bash
# test_recording_declares_its_provenance — L3 (Aztec-Live-Chain-Replay).
#
# "Block, hash, node and protocol version are in the metadata.
#  Control: a locally-originated recording carries different provenance, so the field is measured
#  rather than constant."
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT "PROVENANCE" HAS TO MEAN HERE IS BIGGER THAN THE MILESTONE'S FOUR FIELDS, AND THE ADDITION IS
# L2's HANDOFF RATHER THAN A FLOURISH.
#
# L2: "a recording carrying the chain's state reference beside an execution that ran against a
# genesis-anchored tree would be exactly the wrong root that everything downstream believes. L3 must
# render this, not hide it."
#
# So a container that carried block coordinates and omitted the root divergence would be **strictly
# more misleading than one carrying neither**, because the coordinates invite the reader to believe
# the state matched. §3 asserts the divergence is in the container, all four trees, both sides.
#
# And two more the reader cannot infer: the private half's absence (L1's declaration, in the
# artefact rather than only in a log — the milestone's own wording), and the rung-3 ceiling with its
# proof.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE PROTOCOL VERSION IS THE PIN AND THE RECORD SAYS SO. THAT IS THE HONEST FORM.
#
# L0 established that both reachable endpoints are proxies which strip the `x-aztec-*` headers on
# the batch POST upstream's client always sends, so a replay never OBSERVES a version and
# `pins.json` keeps `network: UNESTABLISHED`. Writing the pin unlabelled would let a reader take it
# for what the node said. §2 asserts the label is there, not merely the value.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE CONTROL: A SECOND CONTAINER OF THE SAME TRANSACTION, REPLAYED AGAINST THE WRONG BLOCK.
#
# The milestone offers "a locally-originated recording". That would work and it needs the sibling
# campaign's browser path; there is a sharper one already in hand, and it is a MODE OF THE SUBJECT
# rather than a second producer — L2's `preStateBlockForControls`, one option.
#
# It is sharper because it splits the provenance record in two along exactly the line that matters:
#
#   * the fields that describe THE TRANSACTION — hash, block, block hash, index, node, protocol
#     version — must be IDENTICAL between the two containers, because it is the same transaction;
#   * the fields that describe THE EXECUTION — which block the pre-state was read at, the replayed
#     revert code, whether the published effects were reproduced — must DIFFER, because it is a
#     different execution.
#
# A constant would fail the second half. A field wired to the wrong source would fail the first.
# "Measured rather than constant" is not one assertion here; it is a partition.

set -uo pipefail
TEST_NAME="test_recording_declares_its_provenance"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l2_replay.sh"

echo "== $TEST_NAME"
l3_prepare

# See `e2e_settled_transaction_produces_steppable_ct` on why these cross by environment: the probe
# heredoc is quoted, so a `$VAR` inside it stays literal.
SUBJECT_CT="$L2_WORK/probes/l3-prov-subject.ct"
CONTROL_CT="$L2_WORK/probes/l3-prov-control.ct"
export SUBJECT_CT CONTROL_CT

PROBE="$(l2_imports)
$(cat <<'EOS'

import { writeFileSync } from 'node:fs';

const fixture = readL2Fixture();
const settled = await l2Settled(fixture);
const host = await createNodeAvmHost(L2_MODULE_PATH);

// ---- the subject: the pre-state at the PARENT block, which is correct --------
const hydrated = await replaySettledTransaction(host, l2Client(fixture), settled, encodeReplayInputs);
const pass = await recordingPass(host, settled, hydrated, encodeRecordingInputs);
const subject = buildSettledRecording(
  await l3Writer(settled), settled, { ...hydrated, steps: pass.steps }, pass.steps);
writeFileSync(process.env.SUBJECT_CT, subject.container);

line('subject.bytes', subject.bytes);
line('subject.logEvents', subject.logEvents);
line('subject.declaredKeys', subject.metadataKeys.join(','));
line('subject.declaredKeyCount', subject.metadataKeys.length);
line('subject.producer', REPLAY_STEP_PRODUCER);
line('subject.preStateBlock', hydrated.preStateBlock);
line('subject.revertCode', hydrated.revertCode);
line('subject.reproduced', hydrated.verdict.reproduced ? 'yes' : 'no');

// The coordinates, read off the FETCH rather than off the container, so the two can disagree.
line('fetch.txHash', settled.txHash);
line('fetch.l2BlockNumber', settled.l2BlockNumber);
line('fetch.l2BlockHash', settled.l2BlockHash);
line('fetch.txIndexInBlock', settled.txIndexInBlock);
line('fetch.nodeUrl', settled.source.url);
line('fetch.resolvedAsOf', settled.contracts[0].resolvedAsOf);
line('fetch.privateHalfStatus', settled.privateHalf.status);
line('fetch.privateHalfOrigin', settled.privateHalf.origin);
line('roots.anyAgrees', hydrated.roots.anyAgrees ? 'yes' : 'no');
line('roots.declarations', hydrated.roots.declarations.length);
line('keys.rungCeilingLength', CHAIN_CONTRACT_RUNG_CEILING_REASON.length);

// ---- the control: the SAME transaction, replayed against the WRONG block -----
// One option on one function. A second producer would constrain the control's code, not this one's.
const wrong = await replaySettledTransaction(host, l2Client(fixture), settled, encodeReplayInputs,
  { preStateBlockForControls: 'settling-block' });
const wrongPass = await recordingPass(host, settled, wrong, encodeRecordingInputs);
const control = buildSettledRecording(
  await l3Writer(settled), settled, { ...wrong, steps: wrongPass.steps }, wrongPass.steps);
writeFileSync(process.env.CONTROL_CT, control.container);

line('control.preStateBlock', wrong.preStateBlock);
line('control.revertCode', wrong.revertCode);
line('control.reproduced', wrong.verdict.reproduced ? 'yes' : 'no');
line('control.steps', control.steps);
line('control.bytes', control.bytes);
line('control.declaredKeys', control.metadataKeys.join(','));

line('l2.done', 1);
EOS
)"

OUT="$L2_WORK/probes/l3prov.out"
L0_PROBE_TIMEOUT="${L0_PROBE_TIMEOUT:-900}" l0_run_probe l3prov "$PROBE" "$OUT" l2.done
f() { l0_field "$OUT" "$1"; }
j() { l1_json "$L2_FIXTURE" "$1"; }

SUBJ_DECODE="$L2_WORK/probes/l3-prov-subject.json"
CTRL_DECODE="$L2_WORK/probes/l3-prov-control.json"
l3_read_container "$SUBJECT_CT" "$SUBJ_DECODE"
l3_read_container "$CONTROL_CT" "$CTRL_DECODE"

# One TraceLogEvent's content, out of the DECODED CONTAINER. Everything below is read this way.
rec() { # <decoded-json> <metadata-key>
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for e in d["events"]:
    if e.get("metadata") == sys.argv[2]:
        print(e.get("content", ""))
        break
' "$1" "$2"
}
keys_in() { # <decoded-json>
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(",".join(sorted({e["metadata"] for e in d["events"]
                       if e.get("event_kind") == "elkTraceLogEvent" and "metadata" in e})))
' "$1"
}
# One `k=v` out of a provenance record, so a field is read by NAME and not by position.
field() { # <record> <key>
  printf '%s\n' "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1 == k { sub("^" k "=", ""); print; exit }'
}

SUBJ_PROV="$(rec "$SUBJ_DECODE" ct.chain-provenance)"
CTRL_PROV="$(rec "$CTRL_DECODE" ct.chain-provenance)"

# ---------------------------------------------------------------------------
echo "== 1. the container carries EXACTLY the declared metadata keys, both directions"
# ---------------------------------------------------------------------------
assert_ge "the subject container is a real one" 100000 "$(wc -c <"$SUBJECT_CT" | tr -d ' ')"
# SIX SINCE L5, AND THE SIXTH IS `ct.source-provenance`. The count is written here rather than
# read off the module for 4c's reason — a check whose expectation is derived from its subject
# cannot notice the subject changing — so adding a key is a red line until somebody writes the new
# number, which is the intended cost.
assert_eq "six metadata keys are declared by the module" "6" "$(f subject.declaredKeyCount)"
assert_eq "…and the container holds exactly those six, no more and no fewer" \
  "$(printf '%s\n' "$(f subject.declaredKeys)" | tr ',' '\n' | sort | paste -sd, -)" \
  "$(keys_in "$SUBJ_DECODE" | tr ',' '\n' | grep -v '^ct.mapping-rung$' | paste -sd, -)"
assert_eq "…which is what the writer reported it wrote" "6" "$(f subject.logEvents)"
# `ct.mapping-rung` is the WRITER's own record, emitted by `declareRung`, and is deliberately not in
# the module's declared set — it is not a key this module chooses to write.
assert_true "…plus the writer's own rung record, which this module does not own" \
  grep -q 'ct.mapping-rung' "$SUBJ_DECODE"

# ---------------------------------------------------------------------------
echo "== 2. block, hash, node and PROTOCOL VERSION are in the metadata"
#
# Every value compared against the FETCH and, where the fixture has it, against the fixture's own
# recorded provenance — three readings of coordinates that must agree.
# ---------------------------------------------------------------------------
assert_ge "the provenance record is a real record" 200 "${#SUBJ_PROV}"
assert_eq "the transaction hash is in the metadata" "$(f fetch.txHash)" \
  "$(field "$SUBJ_PROV" txHash)"
assert_eq "…and it is the one the fixture recorded" "$(j "d['provenance']['txHash']")" \
  "$(field "$SUBJ_PROV" txHash)"
assert_eq "the block NUMBER is in the metadata" "$(f fetch.l2BlockNumber)" \
  "$(field "$SUBJ_PROV" l2BlockNumber)"
assert_eq "…and it is the fixture's" "$(j "d['provenance']['l2BlockNumber']")" \
  "$(field "$SUBJ_PROV" l2BlockNumber)"
assert_eq "the block HASH is in the metadata, which is a different field from the number" \
  "$(f fetch.l2BlockHash)" "$(field "$SUBJ_PROV" l2BlockHash)"
assert_eq "…and it is the fixture's" "$(j "d['provenance']['nodeReported']['l2BlockHash']")" \
  "$(field "$SUBJ_PROV" l2BlockHash)"
assert_eq "the transaction's index in its block is there" "$(f fetch.txIndexInBlock)" \
  "$(field "$SUBJ_PROV" txIndexInBlock)"
assert_eq "the NODE URL is there" "$(f fetch.nodeUrl)" "$(field "$SUBJ_PROV" nodeUrl)"
assert_eq "…and it is the endpoint the fixture was captured from" \
  "$(j "d['provenance']['endpoint']")" "$(field "$SUBJ_PROV" nodeUrl)"

# THE PROTOCOL VERSION, AND ITS LABEL. The label is the assertion that matters.
assert_eq "the pinned l2ProtocolContractsHash is in the metadata" \
  "$(python3 -c 'import json;print(json.load(open("pins.json"))["live_chain"]["protocol_version"]["l2ProtocolContractsHash"])')" \
  "$(field "$SUBJ_PROV" protocolVersion.l2ProtocolContractsHash)"
assert_eq "…and the pinned l2CircuitsVkTreeRoot" \
  "$(python3 -c 'import json;print(json.load(open("pins.json"))["live_chain"]["protocol_version"]["l2CircuitsVkTreeRoot"])')" \
  "$(field "$SUBJ_PROV" protocolVersion.l2CircuitsVkTreeRoot)"
assert_contains "…LABELLED AS THE PIN rather than as something the node said" \
  "protocolVersionSource=pins.json" "$SUBJ_PROV"
assert_contains "…with the reason: the reachable endpoints are proxies that strip the headers" \
  "strip the version headers" "$SUBJ_PROV"

# The execution coordinates, which a recording of a REPLAY needs and a recording of a live run
# would not have.
assert_eq "which block the pre-state was read at is in the metadata" "$(f subject.preStateBlock)" \
  "$(field "$SUBJ_PROV" preStateReadAtBlock)"
assert_eq "…which is the settling block's parent" \
  "$(( $(f fetch.l2BlockNumber) - 1 ))" "$(field "$SUBJ_PROV" preStateReadAtBlock)"
assert_eq "the contracts' reference block is there" "$(f fetch.resolvedAsOf)" \
  "$(field "$SUBJ_PROV" contractsResolvedAsOf)"
assert_eq "both revert codes are there — the chain's" "0" \
  "$(field "$SUBJ_PROV" publishedRevertCode)"
assert_eq "…and the replay's" "$(f subject.revertCode)" \
  "$(field "$SUBJ_PROV" replayedRevertCode)"
assert_eq "…and whether the published effects were reproduced" "true" \
  "$(field "$SUBJ_PROV" publishedEffectsReproduced)"

# ---------------------------------------------------------------------------
echo "== 3. L2'S HANDOFF: the root divergence is IN the container, not only in a log"
#
# A container carrying block coordinates and omitting this would be STRICTLY MORE MISLEADING than
# one carrying neither, because the coordinates invite the reader to believe the state matched.
# ---------------------------------------------------------------------------
DIV="$(rec "$SUBJ_DECODE" ct.merkle-root-divergence)"
assert_ge "the divergence record is a real record" 400 "${#DIV}"
assert_eq "no tree agreed, which is what the replay measured" "no" "$(f roots.anyAgrees)"
assert_contains "the note hash tree is named, and DIFFERS" "noteHashTree:DIFFERS" "$DIV"
assert_contains "…the nullifier tree" "nullifierTree:DIFFERS" "$DIV"
assert_contains "…the public data tree" "publicDataTree:DIFFERS" "$DIV"
assert_contains "…and the L1-to-L2 message tree" "l1ToL2MessageTree:DIFFERS" "$DIV"
assert_eq "…which is all four the state reference names" "4" "$(f roots.declarations)"
assert_eq "the record carries no AGREES, because none did" "0" \
  "$(printf '%s' "$DIV" | grep -o 'AGREES' | wc -l | tr -d ' ')"
# BOTH SIDES, so a reader can see what the roots are as well as that they differ.
assert_eq "each tree carries a resident root AND a chain root" "4" \
  "$(printf '%s' "$DIV" | grep -o 'resident=0x[0-9a-f]\{64\}' | wc -l | tr -d ' ')"
assert_eq "…four chain roots too" "4" \
  "$(printf '%s' "$DIV" | grep -o 'chain=0x[0-9a-f]\{64\}' | wc -l | tr -d ' ')"
assert_contains "…and the chain's public-data root is the fixture's" \
  "$(j "d['provenance']['nodeReported']['stateReference']['publicDataTreeRoot']")" "$DIV"
assert_contains "the REASON travels with it, so a consumer cannot render the roots without it" \
  "BY CONSTRUCTION" "$DIV"
assert_contains "…including the warning in the milestone's own words" \
  "everything downstream believes" "$DIV"

# ---------------------------------------------------------------------------
echo "== 4. and the two other things a reader cannot infer"
# ---------------------------------------------------------------------------
PRIV="$(rec "$SUBJ_DECODE" ct.private-half)"
assert_contains "the private half is declared unavailable IN THE ARTEFACT, not only in a log" \
  "status=$(f fetch.privateHalfStatus)" "$PRIV"
assert_eq "…and its status is 'unavailable-in-principle'" "unavailable-in-principle" \
  "$(f fetch.privateHalfStatus)"
assert_contains "…originating from a settled chain" "origin=$(f fetch.privateHalfOrigin)" "$PRIV"
assert_contains "…with the reason, which says IN PRINCIPLE and not merely unfetched" \
  "IN PRINCIPLE" "$PRIV"

CEIL="$(rec "$SUBJ_DECODE" ct.source-mapping-ceiling)"
assert_eq "the rung-3 ceiling's reason is in the container, whole" "$(f keys.rungCeilingLength)" \
  "${#CEIL}"
assert_contains "…naming the type that makes it a ceiling" "ContractClassPublic" "$CEIL"
assert_contains "…and upstream's own words about the artifact being fetched OFFCHAIN" \
  "OFFCHAIN FETCHED ARTIFACT" "$CEIL"
# L5 CHANGED THIS REASON'S LAST SENTENCE AND THE CHANGE IS ASSERTED, because the sentence it
# replaced — "that resolution is not built here" — is the one two other repositories quoted as a
# ceiling on the product. The reason now says the resolution IS built and that it was RUN for this
# contract and proved nothing, which is a different and stronger claim: this transaction's contract
# is at rung 3 because nobody publishes its artifact, not because nobody looked.
assert_contains "…and that the off-chain resolution EXISTS and was run" \
  "THAT OFF-CHAIN RESOLUTION IS BUILT" "$CEIL"
assert_contains "…naming the module that does it" "replay/src/artifact_resolution.ts" "$CEIL"
assert_not_contains "…and no longer claiming the resolution is unbuilt" \
  "is not built here" "$CEIL"

# ---------------------------------------------------------------------------
echo "== 4b. L5: ct.source-provenance is written even when NOTHING resolved"
#
# THE KEY IS UNCONDITIONAL AND THIS IS THE ARM THAT SAYS SO. A record that appeared only on
# source-level recordings would make its own absence ambiguous — a reader could not distinguish a
# transaction whose artifacts were never looked for from one whose artifacts were looked for and
# not found, and telling those apart is the whole subject of L5. This fixture's contract is the
# third-party token, which no registry publishes, so this is the NOT-FOUND case and it must speak.
# ---------------------------------------------------------------------------
SRCPROV="$(rec "$SUBJ_DECODE" ct.source-provenance)"
assert_ge "the source-provenance record is a real record" 200 "${#SRCPROV}"
assert_contains "…and it says this transaction is NOT source level" "sourceLevel=false" "$SRCPROV"
assert_contains "…over one contract" "contracts=1" "$SRCPROV"
assert_contains "…of which zero resolved" "resolved=0" "$SRCPROV"
assert_contains "…naming the contract and saying no artifact was proved for it" \
  "artifact=NONE-PROVED" "$SRCPROV"
# THE CAVEAT TRAVELS WITH THE CONTAINER. A container is published, downloaded and opened by a
# debugger that has never seen this repository; a source-level claim whose caveat lives in a source
# comment is a source-level claim with no caveat.
assert_contains "…and it states what artifactHash does NOT commit to, in the artefact itself" \
  "does NOT commit to debug_symbols or file_map" "$SRCPROV"

PROD="$(rec "$SUBJ_DECODE" ct.step-producer)"
assert_prefix "the producer names itself" "$(f subject.producer)" "$PROD"
assert_contains "…with the step count" "steps=345" "$PROD"

# ---------------------------------------------------------------------------
echo "== 5. THE CONTROL: the same transaction against the WRONG block — a PARTITION, not one field"
#
# Fields describing THE TRANSACTION must be identical; fields describing THE EXECUTION must differ.
# A constant fails the second half; a field wired to the wrong source fails the first.
# ---------------------------------------------------------------------------
assert_ge "the control container is a real one too" 50000 "$(wc -c <"$CONTROL_CT" | tr -d ' ')"
assert_eq "…and the reference reader parses it" "$(f control.declaredKeys)" \
  "$(f subject.declaredKeys)"

# — the half that must be IDENTICAL —
assert_eq "the transaction hash is the SAME in both, because it is the same transaction" \
  "$(field "$SUBJ_PROV" txHash)" "$(field "$CTRL_PROV" txHash)"
assert_eq "…the block number" "$(field "$SUBJ_PROV" l2BlockNumber)" \
  "$(field "$CTRL_PROV" l2BlockNumber)"
assert_eq "…the block hash" "$(field "$SUBJ_PROV" l2BlockHash)" \
  "$(field "$CTRL_PROV" l2BlockHash)"
assert_eq "…the node url" "$(field "$SUBJ_PROV" nodeUrl)" "$(field "$CTRL_PROV" nodeUrl)"
assert_eq "…the protocol version pin" \
  "$(field "$SUBJ_PROV" protocolVersion.l2CircuitsVkTreeRoot)" \
  "$(field "$CTRL_PROV" protocolVersion.l2CircuitsVkTreeRoot)"
assert_eq "…and the chain's own published revert code, which no replay can move" \
  "$(field "$SUBJ_PROV" publishedRevertCode)" "$(field "$CTRL_PROV" publishedRevertCode)"

# — the half that must DIFFER —
assert_false "THE PRE-STATE BLOCK DIFFERS, which is the whole of what the control changed" \
  test "$(field "$SUBJ_PROV" preStateReadAtBlock)" = "$(field "$CTRL_PROV" preStateReadAtBlock)"
assert_eq "…the control read it at the SETTLING block" "$(f fetch.l2BlockNumber)" \
  "$(field "$CTRL_PROV" preStateReadAtBlock)"
assert_false "the REPLAYED revert code differs, so the field is measured and not constant" \
  test "$(field "$SUBJ_PROV" replayedRevertCode)" = "$(field "$CTRL_PROV" replayedRevertCode)"
assert_eq "…the control REVERTED where the chain succeeded" "1" \
  "$(field "$CTRL_PROV" replayedRevertCode)"
assert_eq "…and says its effects were NOT reproduced" "false" \
  "$(field "$CTRL_PROV" publishedEffectsReproduced)"
assert_false "…which is the opposite of the subject's" \
  test "$(field "$SUBJ_PROV" publishedEffectsReproduced)" \
     = "$(field "$CTRL_PROV" publishedEffectsReproduced)"

# The two containers really are two recordings and not one file read twice.
assert_false "the two containers differ in size, so these are two recordings" \
  test "$(wc -c <"$SUBJECT_CT" | tr -d ' ')" = "$(wc -c <"$CONTROL_CT" | tr -d ' ')"
assert_false "…and in step count, because the control's execution halted earlier" \
  test "345" = "$(f control.steps)"
assert_eq "…at 254 instructions" "254" "$(f control.steps)"

finish
