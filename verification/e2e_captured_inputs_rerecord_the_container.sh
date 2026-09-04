#!/usr/bin/env bash
# e2e_captured_inputs_rerecord_the_container — L5 (Aztec-Live-Chain-Replay).
#
# "A transaction recorded from a live chain can be re-recorded OFFLINE, from committed inputs, byte
#  for byte — so a recorder change can be re-run over the same subject after the node has deleted
#  its body. Controls: a capture pointed at another class is REFUSED by name, and a capture with the
#  artifact removed produces a DIFFERENT container rather than the same one."
#
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# THE DEFECT THIS CHECK EXISTS FOR, STATED AS THE COST IT ALREADY IMPOSED.
# ═════════════════════════════════════════════════════════════════════════════════════════════════
#
# `getTxByHash` serves only the active tx pool and the pool deletes at the finalized tip, so a
# settled transaction is replayable for roughly an hour and then never again — `settled_transaction.ts`
# measures the horizon and `await_resolvable_transaction.mjs`'s header records the consequence:
# the published container `0x12525d6d…` (testnet block 63670) CANNOT be re-recorded, because the
# subject no longer exists to replay.
#
# That is not merely inconvenient. `deriveTraceArtifactId` hashes the RECORDER BUILD into the
# published URL, on purpose — "changing the recorder must change the URL so a stale artifact cannot
# outlive a bug fix". So **every recorder improvement is a re-record, never a re-upload**, and a
# transaction with no fixture is a transaction whose page is frozen at the recorder that made it.
# The Noir call tree landed in `255a61e` and could not be shown on the one page that had been
# checked all campaign, for exactly this reason and for no other.
#
# **SO THE ABSENT FIXTURE IS THE DEFECT, AND THIS IS THE CHECK THAT IT IS ABSENT NO LONGER.**
#
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# WHY TWO FIXTURES AND NOT ONE, WHICH IS THE PART THAT WAS MISSING.
# ═════════════════════════════════════════════════════════════════════════════════════════════════
#
# `settled_fixture.ts` already recorded the JSON-RPC transport, and that half was never the gap: it
# holds the transaction body, the block, and every per-slot hydration read the AVM discovered. A
# playback of it re-executes the transaction exactly.
#
# It does not reproduce the CONTAINER. `replay_settled_transaction.mjs` also resolves each
# contract's artifact off-chain, and in `--fixture` mode it deliberately names no chain — so the
# resolution falls back to whatever `@aztec/protocol-contracts` is installed at the moment the
# replay is run. The artifact decides the session's rung, whether columns are recordable, which
# source paths get interned, and therefore whether any Noir frame opens at all. A replay whose
# artifact came from today's `npm ci` is a replay of today's npm, and the difference would read as
# a recorder regression.
#
#   testnet_frame_tx.json            the JSON-RPC session — the half with the one-hour deadline
#   testnet_frame_tx_artifacts.json  the artifact candidates as the providers answered them
#   testnet_frame_tx_container.json  what the two of them together must produce
#
# **NOTHING IN THE ARTIFACT CAPTURE IS TRUSTED FOR BEING IN IT.** Playback feeds the recorded
# candidates through the same `verifyCandidate` the live run used, so `artifactHash`, the packed
# bytecode and the recomputed class id are re-proved offline against the class THIS FIXTURE'S OWN
# JSON-RPC recording answers. §4 is that assertion.
#
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# THE SUBJECT, AND WHAT IT IS AND IS NOT.
# ═════════════════════════════════════════════════════════════════════════════════════════════════
#
# testnet `0x194121a3…`, block 69040, captured 2026-09-04 while its body was still served. Two
# public call targets: FeeJuice at `0x…03`, whose artifact npm publishes and which records at rung
# 2 with 86 of its 108 steps positioned over 32 source files; and a third-party class
# `0x18e71511…` that nobody publishes, which records at rung 3 with 0 of 351 positioned.
#
# **THE TRANSACTION IS THEREFORE NOT `sourceLevel`, AND THAT IS RECORDED RATHER THAN ROUNDED UP.**
# `sourceLevel` is the AND over every contract — `e2e_resolved_contract_records_at_source_level`'s
# `mixed` arm is the check that it stays an AND — so one unprovable target makes the whole
# transaction false. This check asserts the mixture, both rungs, in one container, because a subject
# that resolved everything would let a bug that ignores the unresolved half pass unnoticed.
#
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# THE CONTROLS, AND WHY EACH ONE IS NOT OPTIONAL.
# ═════════════════════════════════════════════════════════════════════════════════════════════════
#
# §6 **A CAPTURE FOR THE WRONG SUBJECT IS REFUSED, NOT ANSWERED.** The class id in the capture is
#    edited to one the fixture never asks about. The replay must report the resolution FAILING with
#    `ArtifactCaptureMiss` named — because the dangerous answer is "no candidates", which is exactly
#    what an honest unpublished contract looks like. A recording pointed at the wrong inputs must
#    not be able to impersonate a correct recording of a contract nobody publishes.
#
# §7 **THE ARTIFACT IS LOAD-BEARING, DEMONSTRATED BY REMOVING IT.** With the FeeJuice candidate
#    deleted from the capture, the re-record must produce a container whose sha256 DIFFERS, whose
#    positioned-step count falls to zero and whose frame count drops. Without this arm every
#    assertion above is satisfied by a pipeline that ignores the capture entirely and got the right
#    answer from the installed package — which is precisely the coincidence this fixture exists to
#    stop depending on.
#
# §5 reads the re-recorded container back through the REFERENCE READER rather than believing the
#    driver's own log line, which is L3's rule and was earned: the writer produced bytes for three
#    containers `ct-print` then refused.
# ---------------------------------------------------------------------------

set -uo pipefail
TEST_NAME="e2e_captured_inputs_rerecord_the_container"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l2_replay.sh"

echo "== $TEST_NAME"
summary_on_abnormal_exit
l3_prepare

FIXTURE="$REPO_ROOT/replay/fixtures/testnet_frame_tx.json"
ARTIFACTS="$REPO_ROOT/replay/fixtures/testnet_frame_tx_artifacts.json"
EXPECTED="$REPO_ROOT/replay/fixtures/testnet_frame_tx_container.json"

WORK="${L5_RERECORD_WORK:-$HOME/.cache/aztec-l5-rerecord}"
mkdir -p "$WORK" || die "could not create $WORK"

j() { # <file> <python expr over d>
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {'d': d, 'len': len, 'sorted': sorted, 'sum': sum}))
PY
}

# ── §1 the inputs are committed, complete, and say what they are ────────────────────────────────
note "§1 the three committed inputs"

for f in "$FIXTURE" "$ARTIFACTS" "$EXPECTED"; do
  assert_file "…$(basename "$f") is on disk" "$f"
  assert_true "…and TRACKED, so this runs from a clean checkout" \
    git -C "$REPO_ROOT" ls-files --error-unmatch "replay/fixtures/$(basename "$f")"
done

assert_eq "the session fixture is a recorded JSON-RPC transport" \
  "replay-settled-transaction-fixture/1" "$(j "$FIXTURE" "d['format']")"
assert_eq "the artifact capture declares its own format" \
  "replay-artifact-candidates/1" "$(j "$ARTIFACTS" "d['format']")"
assert_eq "…and the two are recordings of THE SAME transaction" \
  "$(j "$FIXTURE" "d['provenance']['txHash']")" "$(j "$ARTIFACTS" "d['provenance']['txHash']")"
assert_eq "…which is the transaction the expectation is about" \
  "$(j "$FIXTURE" "d['provenance']['txHash']")" "$(j "$EXPECTED" "d['provenance']['tx']")"

# THE CAPTURE NAMES THE SCRIPT THAT TOOK IT, on L1's terms: a regeneration path that is wired up
# rather than described. Here it is wired up in the stronger sense — the script named is the one
# this check RUNS below.
assert_prefix "the artifact capture names the script that took it" \
  "replay/tools/replay_settled_transaction.mjs" "$(j "$ARTIFACTS" "d['provenance']['capturedBy']")"
assert_file "…and that script is on disk" "$REPO_ROOT/replay/tools/replay_settled_transaction.mjs"

# A capture holding no candidate at all would make every assertion below vacuous: the re-record
# would agree with an expectation that itself recorded nothing resolving.
assert_ge "the capture carries at least one candidate artifact" 1 \
  "$(j "$ARTIFACTS" "sum(len(c['candidates']) for c in d['classes'])")"
assert_eq "…for both of the transaction's public call targets" "2" \
  "$(j "$ARTIFACTS" "len(d['classes'])")"

# ── §2 the re-record, offline ───────────────────────────────────────────────────────────────────
note "§2 the re-record — no network, no installed package, committed inputs only"

rerecord() { # <artifacts-json> <ct-out> <sources-out> <log-out>
  ( cd "$REPO_ROOT" && timeout "${L5_RERECORD_TIMEOUT:-900}" node \
      replay/tools/replay_settled_transaction.mjs \
      --fixture "$FIXTURE" --artifacts "$1" \
      --module "$L2_MODULE" --ct-writer "$L3_CT_WRITER" \
      --ct "$2" --sources "$3" --json ) >"$4.json" 2>"$4"
  printf '%s\n' "$?"
}

RC="$(rerecord "$ARTIFACTS" "$WORK/rerecorded.ct" "$WORK/rerecorded.sources.json" "$WORK/rerecord.log")"
assert_eq "the offline re-record exited 0 (it reproduces the published effects)" "0" "$RC"
assert_file "…and wrote a container" "$WORK/rerecorded.ct"

# IT SAYS IT USED THE CAPTURE. Without this line the run could have resolved from the installed
# package and produced the same bytes by luck, which §7 then rules out for good.
assert_true "…and it resolved from the CAPTURE rather than from a registry or an install" \
  grep -q "NO NETWORK AND NO INSTALLED PACKAGE" "$WORK/rerecord.log"

# ── §3 byte-for-byte, against the committed expectation ─────────────────────────────────────────
note "§3 the container the committed inputs produce"

GOT_SHA="$(shasum -a 256 "$WORK/rerecorded.ct" | cut -d' ' -f1)"
assert_eq "the re-recorded container is BYTE-IDENTICAL to the one the live run wrote" \
  "$(j "$EXPECTED" "d['container']['sha256']")" "$GOT_SHA"
assert_eq "…and the same length" \
  "$(j "$EXPECTED" "d['container']['bytes']")" "$(wc -c <"$WORK/rerecorded.ct" | tr -d ' ')"

# THE SOURCE BUNDLE TOO. It is what a publisher serves as "sources available", so a re-record that
# reproduced the container and not the text would still not reproduce the page.
assert_eq "the source bundle is byte-identical as well" \
  "$(j "$EXPECTED" "d['sourceBundle']['sha256']")" \
  "$(shasum -a 256 "$WORK/rerecorded.sources.json" | cut -d' ' -f1)"
assert_eq "…carrying the same number of source files" \
  "$(j "$EXPECTED" "d['sourceBundle']['files']")" \
  "$(j "$WORK/rerecorded.sources.json" "sum(len(b['files']) for b in d['bundles'])")"

# ── §4 the shape of the recording, from the report the re-record printed ────────────────────────
note "§4 what the re-recorded container declares about itself"

R="$WORK/rerecord.log.json"
for field in events steps callsOpened declaredRung stepsPositioned stepsUnpositioned contexts; do
  assert_eq "…$field matches the expectation" \
    "$(j "$EXPECTED" "d['recording']['$field']")" "$(j "$R" "d['recording']['$field']")"
done

# THE MIXTURE, ASSERTED AS A MIXTURE. One contract proved and one not, in one container.
assert_eq "the transaction is NOT sourceLevel, because one target's artifact is unpublished" \
  "False" "$(j "$R" "d['recording']['sourceLevel']")"
assert_eq "…and it says so with TWO contract rungs, not one" "2" \
  "$(j "$R" "len(d['recording']['contractRungs'])")"
assert_eq "…the FeeJuice half records at rung 2" "2" \
  "$(j "$R" "[c['rung'] for c in d['recording']['contractRungs'] if c['resolved']][0]")"
assert_eq "…the unpublished half stays at the chain-fetched ceiling, rung 3" "3" \
  "$(j "$R" "[c['rung'] for c in d['recording']['contractRungs'] if not c['resolved']][0]")"

# THE ARTIFACT WAS RE-PROVED OFFLINE, not accepted for being in the file.
assert_eq "the captured artifact was VERIFIED against the class, not trusted" \
  "$(j "$EXPECTED" "[a['artifactHash'] for a in d['artifacts'] if a['resolved']][0]")" \
  "$(j "$R" "[a['artifactHash'] for a in d['artifacts'] if a['resolved']][0]")"
assert_eq "…and it is the same debug map, which artifactHash does NOT commit to" \
  "$(j "$EXPECTED" "[a['debugDigest'] for a in d['artifacts'] if a['resolved']][0]")" \
  "$(j "$R" "[a['debugDigest'] for a in d['artifacts'] if a['resolved']][0]")"

# ── §5 the reference reader, because the writer is not the standard ─────────────────────────────
note "§5 the container read back by ct-print"

l3_read_container "$WORK/rerecorded.ct" "$WORK/rerecorded.ctprint.txt"

assert_eq "…the reader finds exactly the step records the recording claims" \
  "$(j "$R" "d['recording']['steps']")" \
  "$(grep -c '"type": *"Step"' "$WORK/rerecorded.ctprint.txt" || true)"
# THE FRAMES, READ OUT OF THE CONTAINER — AND THE READER'S COUNT IS ONE HIGHER THAN THE WRITER'S.
#
# MEASURED, NOT ASSUMED, AND THE FIRST DRAFT OF THIS CHECK FAILED ON IT: `callsOpened` is
# `ct_calls_opened()`, the module's counter of `ct_call` invocations, and the container carries a
# SESSION ROOT CALL that nothing invoked `ct_call` for. Over this container: 47 `Call` records, of
# which exactly ONE has `"args": []` and `function_id: 0`, and 46 `Return` records. So the root is
# opened when the session opens, it never returns, and it is not one of the recording's frames.
#
# BOTH NUMBERS ARE ASSERTED AND THE RELATION BETWEEN THEM IS NAMED, rather than the expectation
# being edited to 47 until it went green. A consumer walking `Call` records to build a call tree —
# which is exactly what the view side does — meets that root first and must not count it as a Noir
# frame; that is a fact about this container format and it belongs in a check rather than in a
# surprise.
assert_eq "…every frame the recording opened also CLOSES — Return records equal callsOpened" \
  "$(j "$R" "d['recording']['callsOpened']")" \
  "$(grep -c '"type": *"Return"' "$WORK/rerecorded.ctprint.txt" || true)"
assert_eq "…and the Call records are those frames PLUS the session root, which never returns" \
  "$(( $(j "$R" "d['recording']['callsOpened']") + 1 ))" \
  "$(grep -c '"type": *"Call"' "$WORK/rerecorded.ctprint.txt" || true)"
assert_eq "…the root being the one Call with no arguments, and there is exactly one" "1" \
  "$(python3 -c "
import re, sys
txt = open(sys.argv[1]).read()
calls = re.findall(r'\"type\": \"Call\",\s*\"function_id\": (\d+),\s*\"args\": (\[\s*\]|\[)', txt)
print(sum(1 for f, a in calls if a.strip() == '[]'))
" "$WORK/rerecorded.ctprint.txt")"
assert_true "…the interned paths include the resolved contract's own Noir source" \
  grep -q "fee_juice_contract/src/main.nr" "$WORK/rerecorded.ctprint.txt"

# ── §6 CONTROL: a capture for a class this fixture never asks about is REFUSED ───────────────────
note "§6 control — a capture pointed at the wrong subject"

python3 - "$ARTIFACTS" "$WORK/wrong-class.artifacts.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# Every class id rewritten to one the recording never asks about. The candidates are left ALONE:
# the question is whether a lookup miss is refused, not whether a bad artifact is rejected — that
# is `verifyCandidate`'s job and it has its own checks.
# EACH ENTRY GETS A DISTINCT WRONG ID, so the capture keeps its SHAPE — two classes, the same
# candidates — and only the keys are wrong. Rewriting both to the same id would collapse them into
# one map entry, and then the control would also be testing deduplication.
for i, c in enumerate(d['classes']):
    wrong = '0x' + f'{i:02x}' + 'de' * 31
    c['contractClassId'] = wrong
    c['class']['id'] = wrong
json.dump(d, open(sys.argv[2], 'w'))
PY

RC="$(rerecord "$WORK/wrong-class.artifacts.json" "$WORK/wrong.ct" "$WORK/wrong.sources.json" "$WORK/wrong.log")"
assert_true "…the miss is named ArtifactCaptureMiss in the resolution" \
  grep -q "ArtifactCaptureMiss" "$WORK/wrong.log.json"
assert_eq "…and NOTHING is reported as proved, so it cannot pass as a correct recording" "0" \
  "$(j "$WORK/wrong.log.json" "len([a for a in d['artifacts'] if a['resolved']])")"
assert_true "…and the refusal says which classes the capture DOES carry" \
  grep -q "It holds 2 class(es)" "$WORK/wrong.log.json"
# THE CONTAINER IT PRODUCES IS NOT THE SUBJECT'S. Asserted so that "refused by name" cannot be
# satisfied by a run that printed the name and wrote the right bytes anyway.
assert_false "…and the container it wrote is NOT the expected one" \
  test "$(j "$EXPECTED" "d['container']['sha256']")" = \
       "$(shasum -a 256 "$WORK/wrong.ct" | cut -d' ' -f1)"

# ── §7 CONTROL: the artifact is load-bearing ────────────────────────────────────────────────────
note "§7 control — the same inputs with the artifact removed"

python3 - "$ARTIFACTS" "$WORK/no-artifact.artifacts.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# The class entries stay — so the miss guard does NOT fire and this measures the artifact's effect
# and not the guard's. Only the candidates go.
for c in d['classes']:
    c['candidates'] = []
json.dump(d, open(sys.argv[2], 'w'))
PY

RC="$(rerecord "$WORK/no-artifact.artifacts.json" "$WORK/bare.ct" "$WORK/bare.sources.json" "$WORK/bare.log")"
assert_eq "…the replay still runs and still reproduces the effects (execution needs no artifact)" \
  "0" "$RC"
assert_eq "…but nothing resolves" "0" \
  "$(j "$WORK/bare.log.json" "len([a for a in d['artifacts'] if a['resolved']])")"
assert_eq "…so no step is positioned at all" "0" \
  "$(j "$WORK/bare.log.json" "d['recording']['stepsPositioned']")"
assert_false "…and the container DIFFERS from the expected one" \
  test "$(j "$EXPECTED" "d['container']['sha256']")" = \
       "$(shasum -a 256 "$WORK/bare.ct" | cut -d' ' -f1)"
# THE FRAMES ARE THE POINT. The Noir call tree comes from the source map, so removing the artifact
# must remove the frames — which is what makes "the fixture carries the artifact" a claim about the
# published page and not about a JSON field.
assert_true "…and it opens FEWER frames, because the Noir call tree comes from the source map" \
  test "$(j "$WORK/bare.log.json" "d['recording']['callsOpened']")" -lt \
       "$(j "$EXPECTED" "d['recording']['callsOpened']")"

finish
