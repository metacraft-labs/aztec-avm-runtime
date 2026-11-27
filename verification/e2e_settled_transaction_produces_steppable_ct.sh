#!/usr/bin/env bash
# e2e_settled_transaction_produces_steppable_ct — L3 (Aztec-Live-Chain-Replay).
#
# "The container carries executed opcodes and resolved source positions.
#  Control: the step count equals the AVM's own executed-instruction statistic, and a synthesised
#  stream FAILS the same predicate."
#
# ─────────────────────────────────────────────────────────────────────────────
# ONE HALF OF THAT DESCRIPTION IS UNACHIEVABLE AND IS NOT ASSERTED. SAYING SO IS PART OF THE CHECK.
#
# "resolved source positions" CANNOT be delivered for a chain-fetched contract and this check must
# not pretend otherwise. `getContractClass` returns `ContractClassPublic`, which is exactly
# `{ id, privateFunctionsRoot, version, artifactHash, packedBytecode }` — no `debug_symbols`, no
# `file_map`, no source text — and `AztecNode` declares no method that serves any. So the ceiling is
# RUNG 3, `Line(pc)`, and §1 asserts the container declares 3 and carries program counters. A check
# that asserted "source positions" here would either be red for ever or would be satisfied by
# `line: 0` on every step, which is the worse of the two.
#
# ─────────────────────────────────────────────────────────────────────────────
# EVERYTHING IS READ OUT OF THE CONTAINER, THROUGH THE REFERENCE READER. M29's correction.
#
# Its words: a figure the producer reports about itself is "upstream of the one thing it could get
# wrong", and M29's own mutation M1 changed the opcodes that were WRITTEN while leaving the
# producer's self-report alone — every behavioural assertion passed. So the host's return value is
# used for ONE thing only, comparing it against what the reader found; every claim about the
# recording is made against `ct-print --full`'s decode.
#
# The reader has earned that role three times over on this milestone alone: it refused
# `columns: true` at rung 3, then a 23-character recording id, then a 36-character one that was
# UUID-SHAPED and not a UUIDv7. Each of those was BYTES the writer had happily produced.
#
# ─────────────────────────────────────────────────────────────────────────────
# TWO CONTROLS, AND THE SECOND IS THE ONE THAT MATTERS.
#
#   §3 THE COUNT PREDICATE. A stream whose length disagrees with the AVM's own
#      `total_instructions_executed` is REFUSED — `ExecutedStepsUnusable('count-disagreement')` —
#      along with the other two ways the stream can be unusable, each with its own discriminant.
#
#   §4 A SYNTHESISED STREAM OF THE *RIGHT LENGTH*. This is the sharp one, and it is the sibling
#      campaign's own shipped defect in its own shape: M27 wrote mapped pcs with a synthesised
#      opcode field and everything downstream was well-formed. A walked stream — pc = 0,1,2,… and a
#      constant opcode — has exactly 345 records, so it PASSES the count predicate in §3 and would
#      pass every assertion in §1 that is about shape. What catches it is comparing the container's
#      decoded `line` sequence against the AVM's OWN pcs, record for record. §4 builds that
#      container and shows the comparison failing over it in the same run as the real one.

set -uo pipefail
TEST_NAME="e2e_settled_transaction_produces_steppable_ct"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l2_replay.sh"

echo "== $TEST_NAME"
l3_prepare

# THROUGH THE ENVIRONMENT, NOT THROUGH THE HEREDOC. The probe body is `<<'EOS'` — quoted, so that a
# backtick or a `$` in JavaScript is not command substitution — which means a `$PATH_VAR` written
# inside it stays LITERAL. The first version of this check did exactly that and the probe wrote
# three files named `$PCS`, `$REAL_CT` and `$FAKE_CT` into its working directory, after which every
# assertion downstream failed on a missing file. `l0_probe` runs `node` in a subshell that inherits
# the environment, so exporting is the way across.
REAL_CT="$L2_WORK/probes/l3-real.ct"
FAKE_CT="$L2_WORK/probes/l3-synthesised.ct"
PCS="$L2_WORK/probes/l3-executed-pcs.txt"
# THE HEADER-ONLY CONTROL for §1's size claim: the same writer, the same configuration, closed with
# nothing recorded. See §1 for why the claim is now made against it rather than against a constant.
HEADER_CT="$L2_WORK/probes/l3-header-only.ct"
export REAL_CT FAKE_CT PCS HEADER_CT

PROBE="$(l2_imports)
$(cat <<'EOS'

import { writeFileSync } from 'node:fs';

const fixture = readL2Fixture();
const settled = await l2Settled(fixture);
const host = await createNodeAvmHost(L2_MODULE_PATH);

// ---- the two passes ---------------------------------------------------------
const hydrated = await replaySettledTransaction(host, l2Client(fixture), settled, encodeReplayInputs);
const pass = await recordingPass(host, settled, hydrated, encodeRecordingInputs);
const steps = pass.steps;

line('pass.steps', steps === null ? -1 : steps.length);
line('pass.instructionsExecuted', pass.instructionsExecuted);
line('pass.revertCode', pass.revertCode);
line('pass.reproduced', pass.verdict.reproduced ? 'yes' : 'no');
line('hydrated.instructionsExecuted', hydrated.instructionsExecuted);
line('hydrated.stepsAreNull', hydrated.steps === null ? 'yes' : 'no');

// THE AVM'S OWN PCs, WRITTEN OUT SO THE BASH HALF CAN COMPARE THEM TO THE CONTAINER'S LINES.
// They go to a file rather than through the transcript because there are 345 of them and a
// transcript is for facts, not for data.
// A TRAILING NEWLINE, because the bash half's reader emits one and a digest comparison that
// differed only by it would be red for a reason that has nothing to do with the claim. That is
// exactly how this assertion first failed.
writeFileSync(process.env.PCS, steps.map((s) => s.pc).join('\n') + '\n');
line('pcs.count', steps.length);
line('pcs.distinct', new Set(steps.map((s) => s.pc)).size);
line('pcs.sequential',
     steps.every((s, i) => s.pc === i) ? 'yes' : 'no');
line('pcs.first', steps[0].pc);
// THE DISCRIMINATOR AGAINST A WALK, measured rather than assumed. A synthesised walk has every
// consecutive gap equal to 1; an execution jumps. The first version of this check asserted that
// the stream REVISITS a pc, which is simply false for this subject — 345 records, 345 distinct
// pcs, because the program has no loop. That assertion was wrong about the program rather than
// about the recording, and is replaced by the one that actually separates an execution from a walk.
line('pcs.gapsOfOne', steps.slice(1).filter((s, i) => s.pc - steps[i].pc === 1).length);
line('pcs.gapsOther', steps.slice(1).filter((s, i) => s.pc - steps[i].pc !== 1).length);
line('pcs.backwardJumps', steps.slice(1).filter((s, i) => s.pc < steps[i].pc).length);
line('pcs.max', Math.max(...steps.map((s) => s.pc)));
line('opcodes.distinct', new Set(steps.map((s) => s.opcode)).size);
line('contexts.distinct', new Set(steps.map((s) => s.contextId)).size);

// ---- 1. THE REAL CONTAINER ---------------------------------------------------
const real = buildSettledRecording(await l3Writer(settled), settled, { ...hydrated, steps }, steps);
writeFileSync(process.env.REAL_CT, real.container);
line('real.bytes', real.bytes);
line('real.events', real.events);
line('real.steps', real.steps);
line('real.callsOpened', real.callsOpened);
line('real.logEvents', real.logEvents);
line('real.declaredRung', real.declaredRung);
line('real.distinctOpcodes', real.distinctOpcodes);
line('real.contexts', real.contexts);
line('real.stepsPositioned', real.stepsPositioned);
line('real.stepsUnpositioned', real.stepsUnpositioned);
line('real.rungValue', RUNG_BYTECODE_VALUE);

// ---- 1b. THE HEADER-ONLY CONTROL ---------------------------------------------
// What "a substantial container rather than a header" is measured against: the same writer, opened
// with the same configuration, closed without a single recorder event. `start` still writes its
// entry step, so this is the smallest container the writer produces for this transaction.
const header = (await l3Writer(settled)).close();
writeFileSync(process.env.HEADER_CT, header.container);
line('header.bytes', header.container.length);
line('header.events', header.events);

// ---- 3. THE THREE REFUSALS ---------------------------------------------------
// Each of the three ways the stream can be unusable, through the SAME function, with its own
// discriminant. `collection-off` is the one that must not collapse into `empty`: null means the
// configuration was wrong, and an empty array means the transaction did nothing.
const refusal = async (label, thunk) => {
  const r = await classify(label, thunk);
  if (r.error && r.error.fault !== undefined) line(`${label}.fault`, r.error.fault);
};
await refusal('nullStream', async () =>
  buildSettledRecording(await l3Writer(settled), settled, hydrated, null));
await refusal('emptyStream', async () =>
  buildSettledRecording(await l3Writer(settled), settled, hydrated, []));
await refusal('shortStream', async () =>
  buildSettledRecording(await l3Writer(settled), settled, hydrated, steps.slice(0, steps.length - 1)));
line('faults.declared', STEP_STREAM_FAULTS.join(','));

// ---- 4. THE CONTROL: A SYNTHESISED STREAM OF THE RIGHT LENGTH ----------------
// M27's own shipped defect, reproduced: a walk rather than an execution. The LENGTH is right, so it
// passes §3's count predicate; the pcs are 0,1,2,… and the opcode is a constant, so what catches it
// is the comparison against the AVM's own records.
const synthesised = steps.map((s, i) => ({
  contextId: s.contextId,
  contractAddress: s.contractAddress,
  pc: i,
  opcode: 1,
  gasUsed: s.gasUsed,
}));
line('synth.length', synthesised.length);
line('synth.sameLengthAsReal', synthesised.length === steps.length ? 'yes' : 'no');
line('synth.distinctOpcodes', new Set(synthesised.map((s) => s.opcode)).size);
const fake = buildSettledRecording(
  await l3Writer(settled), settled, { ...hydrated, steps: synthesised }, synthesised);
writeFileSync(process.env.FAKE_CT, fake.container);
line('synth.accepted', 'yes');
line('synth.bytes', fake.bytes);
line('synth.steps', fake.steps);
line('synth.distinctOpcodesWritten', fake.distinctOpcodes);

line('l2.done', 1);
EOS
)"

OUT="$L2_WORK/probes/l3steppable.out"
L0_PROBE_TIMEOUT="${L0_PROBE_TIMEOUT:-900}" l0_run_probe l3steppable "$PROBE" "$OUT" l2.done
f() { l0_field "$OUT" "$1"; }
j() { l1_json "$L2_FIXTURE" "$1"; }

REAL_DECODE="$L2_WORK/probes/l3-real.decode.json"
FAKE_DECODE="$L2_WORK/probes/l3-synthesised.decode.json"

HEADER_DECODE="$L2_WORK/probes/l3-header-only.decode.json"

# The container's own decoded `line` sequence, one per RECORDER step, in order. The writer's entry
# step is excluded, after `l3_assert_entry_step` has found it (`DRIFT.md` D37).
container_lines() { # <decoded-json>
  l3_decode lines "$1"
}

# The AVM's pcs AS LINES. The writer records `Line(pc)`, and `Line(0)` is not a source line: the
# position space puts line 1 at the file's own base, so pc 0 resolves back as line 1, and every
# other pc round-trips unchanged. `test_ct_container_roundtrip_ct_print` measured the same clamp
# over the same writer; the legacy combined decode these assertions were written against reported
# the recorder's raw number without resolving it at all (`DRIFT.md` D37). The comparison stays
# record for record: only the pc-0 record is mapped, and §2 asserts there is exactly one.
pcs_as_lines() { # <pcs-file>
  awk '{ print ($1 < 1 ? 1 : $1) }' "$1"
}

# ---------------------------------------------------------------------------
echo "== 1. the container is real, and the REFERENCE READER says so"
# ---------------------------------------------------------------------------
assert_file "the container was written" "$REAL_CT"
l3_read_container "$REAL_CT" "$REAL_DECODE"
l3_assert_entry_step "$REAL_DECODE" 345
container_lines "$REAL_DECODE" >"$L2_WORK/probes/l3-real-lines.txt"

# "A SUBSTANTIAL CONTAINER RATHER THAN A HEADER", MEASURED AGAINST A HEADER. This was a constant,
# `>= 100000` bytes, set over the legacy container. The split container the pinned writer emits is
# ALLOCATED IN 4096-BYTE BLOCKS (`_m41_container_diff.py` records the same caution), and over it a
# constant cannot make the distinction at all: this 345-step container is 77,824 bytes, and so is
# L5's 64-step control container. So the claim is made against what it is about: the same writer,
# with the same configuration, closed with nothing recorded. The real container must be strictly
# larger than that one, and — the part bytes alone never established — its streams must carry the
# steps that the header-only one does not. Lowering the constant would have been a loosening; this
# is the same claim with its control measured in the same run (`DRIFT.md` D37).
assert_file "the header-only control container was written" "$HEADER_CT"
assert_eq "…by a writer that accepted no recorder event" "0" "$(f header.events)"
assert_eq "…and it is the size the writer reported" "$(f header.bytes)" \
  "$(wc -c <"$HEADER_CT" | tr -d ' ')"
timeout "${L3_READER_TIMEOUT:-300}" "$L3_READER" --full "$HEADER_CT" >"$HEADER_DECODE" 2>&1
assert_eq "the reference reader reads the header-only control too" "0" "$?"
assert_false "…and printed no refusal over it" grep -qE '^Error:' "$HEADER_DECODE"
l3_assert_entry_step "$HEADER_DECODE" 0
assert_ge "…and it is a substantial container rather than a header: strictly larger than the
     header-only container the same writer closes" \
  "$(( $(wc -c <"$HEADER_CT" | tr -d ' ') + 1 ))" "$(wc -c <"$REAL_CT" | tr -d ' ')"
assert_eq "…the size the writer reported" "$(f real.bytes)" "$(wc -c <"$REAL_CT" | tr -d ' ')"
# THE STREAMS, read by the split-stream probe rather than by the JSON reader: steps.dat holds the
# entry step plus the recorder's 345 in the real container and the entry step alone in the control,
# and the real one was really inflated to answer.
if [ -x "$L3_CTPRINT_WORK/ct-split-probe" ]; then
  REAL_SPLIT="$("$L3_CTPRINT_WORK/ct-split-probe" "$REAL_CT" 2>&1)"
  HEADER_SPLIT="$("$L3_CTPRINT_WORK/ct-split-probe" "$HEADER_CT" 2>&1)"
  sv_real() { printf '%s\n' "$REAL_SPLIT" | sed -n "s/^$1"$'\t'"//p"; }
  sv_header() { printf '%s\n' "$HEADER_SPLIT" | sed -n "s/^$1"$'\t'"//p"; }
  assert_eq "the split-stream reader opens the real container" "ok" "$(sv_real OPEN)"
  assert_eq "…and its steps.dat carries 346 steps: the recorder's 345 and the entry step" "346" \
    "$(sv_real STEP_COUNT)"
  assert_ge "…decoded by inflating at least one steps.dat chunk" 1 \
    "$(sv_real EXEC_CHUNK_DECOMPRESSIONS)"
  assert_eq "the header-only control's steps.dat carries the entry step alone" "1" \
    "$(sv_header STEP_COUNT)"
else
  die "no ct-split-probe at $L3_CTPRINT_WORK/ct-split-probe, and §1's size claim reads the step
     stream through it. Remedy: just ct-print-build."
fi

REAL_STEPS="$(l3_decode check "$REAL_DECODE" | sed -n 's/^RECORDER_STEPS\t//p')"
assert_eq "THE READER FINDS 345 STEP EVENTS IN THE CONTAINER" "345" "$REAL_STEPS"
assert_eq "…which is what the writer reported, so the two readings agree" "$(f real.steps)" \
  "$REAL_STEPS"

# THE PREDICATE THE MILESTONE NAMES: the step count equals the AVM's OWN statistic.
assert_eq "THE STEP COUNT EQUALS THE AVM'S OWN executed-instruction statistic" \
  "$(f pass.instructionsExecuted)" "$REAL_STEPS"
assert_eq "…and that statistic is the one the hydration pass measured too" \
  "$(f hydrated.instructionsExecuted)" "$(f pass.instructionsExecuted)"

# ---------------------------------------------------------------------------
echo "== 2. it carries EXECUTED opcodes and PROGRAM COUNTERS — not source positions, which cannot exist here"
# ---------------------------------------------------------------------------
assert_eq "the rung is declared as 3, BYTECODE" "3" "$(f real.declaredRung)"
assert_eq "…which is the module's own constant" "$(f real.rungValue)" "$(f real.declaredRung)"
RUNG_EVENTS="$(l3_decode log-count "$REAL_DECODE" ct.mapping-rung)"
assert_eq "…and the container carries a rung declaration per contract" "1" "$RUNG_EVENTS"
assert_true "…whose text says 3" \
  grep -q 'rung=3' "$REAL_DECODE"

# EVERY STEP IS UNPOSITIONED, and that is the honest state at rung 3 rather than a shortfall.
assert_eq "no step carries a resolved source position, because none can exist" "0" \
  "$(f real.stepsPositioned)"
assert_eq "…all 345 are unpositioned" "345" "$(f real.stepsUnpositioned)"

# THE LINES ARE THE AVM'S OWN PROGRAM COUNTERS, record for record.
assert_file "the AVM's executed pcs were written out" "$PCS"
assert_eq "the clamp maps exactly ONE record — the AVM executed pc 0 exactly once" "1" \
  "$(grep -cx '0' "$PCS" || true)"
assert_eq "the container's line sequence IS the AVM's executed pc sequence, record for record" \
  "$(pcs_as_lines "$PCS" | shasum -a 256 | cut -c1-64)" \
  "$(shasum -a 256 <"$L2_WORK/probes/l3-real-lines.txt" | cut -c1-64)"
assert_eq "…over 345 records" "345" "$(wc -l <"$L2_WORK/probes/l3-real-lines.txt" | tr -d ' ')"

# NON-DEGENERACY: pcs that are a WALK would also compare equal to a walked file. These say the
# subject's pcs are an execution.
assert_eq "the executed pcs are NOT sequential, so this is an execution and not a walk" "no" \
  "$(f pcs.sequential)"
assert_ge "…they reach a real program's depth" 20000 "$(f pcs.max)"
assert_ge "…and the gaps between consecutive pcs are mostly NOT one, which a walk's all are" 200 \
  "$(f pcs.gapsOther)"
assert_ge "…including backward jumps, which a walk never has" 1 "$(f pcs.backwardJumps)"
assert_eq "…while 345 records visit 345 distinct pcs, so this program has no loop — stated because
     the first version of this check asserted the opposite and was wrong about the program" \
  "$(f pcs.count)" "$(f pcs.distinct)"
assert_ge "the stream carries many distinct opcodes, not one" 20 "$(f opcodes.distinct)"
assert_eq "…and the writer wrote that same number" "$(f opcodes.distinct)" "$(f real.distinctOpcodes)"

# The frames are the AVM's own context ids.
assert_eq "this module opened ONE frame — the enqueued call" "1" "$(f real.callsOpened)"
# TWO `Function` events, though: `<toplevel>` is the WRITER's own implicit frame and is not one this
# module opened. The two numbers are different facts and asserting either for the other would be a
# check that passes for the wrong reason.
# The frames are read as the call records the container OPENS, in stream order: the legacy decode
# emitted one `Function` event per interned frame, the split one a `call_entry` per call. For this
# recording the two are the same list, the root first.
FRAME_NAMES="$(l3_decode frames "$REAL_DECODE")"
assert_eq "…named for what they are" "<toplevel>,enqueued-call-0" "$FRAME_NAMES"

# A DECLARED GAP, NOT A SILENT ONE. This transaction executes in a SINGLE AVM context, so
# `recording.ts`'s frame reconstruction — open on a new context id, unwind on a return to one
# already on the stack — NEVER RUNS over it. Mutation N5 removes that branch entirely and this
# check stays green, which is how the gap was found. It is a gap in the SUBJECT: killing N5 needs a
# settled transaction whose public half makes a NESTED call, and none is in the fixture set.
# Asserted rather than left implicit, so the next reader is told rather than having to discover it.
assert_eq "the subject executes in ONE context, so frame reconstruction is NOT exercised here" "1" \
  "$(f contexts.distinct)"
assert_eq "…which the writer's own count agrees with" "$(f contexts.distinct)" "$(f real.contexts)"

# ---------------------------------------------------------------------------
echo "== 3. THE THREE WAYS THE STREAM CAN BE UNUSABLE ARE REFUSED, EACH BY NAME"
#
# A container is not written over any of them. The distinction between the first two is the one
# that matters: `null` means the configuration was wrong; `[]` means the transaction did nothing.
# ---------------------------------------------------------------------------
assert_eq "a NULL stream is refused" "replay-executed-steps-unusable" "$(f nullStream.outcome)"
assert_eq "…naming collection-off, not 'empty'" "collection-off" "$(f nullStream.fault)"
assert_eq "an EMPTY stream is refused" "replay-executed-steps-unusable" "$(f emptyStream.outcome)"
assert_eq "…naming empty" "empty" "$(f emptyStream.fault)"
assert_eq "A STREAM ONE RECORD SHORT IS REFUSED — the count predicate, from the other side" \
  "replay-executed-steps-unusable" "$(f shortStream.outcome)"
assert_eq "…naming count-disagreement" "count-disagreement" "$(f shortStream.fault)"
assert_eq "the three faults are the three the module declares" \
  "collection-off,empty,count-disagreement" "$(f faults.declared)"
# …and the hydration pass really does produce a null stream, so `collection-off` is a state this
# repository reaches rather than one it only names. That is L3's whole two-pass reason.
assert_eq "the hydration pass's own stream IS null, which is why there are two passes" "yes" \
  "$(f hydrated.stepsAreNull)"

# ---------------------------------------------------------------------------
echo "== 4. THE CONTROL: A SYNTHESISED STREAM OF THE RIGHT LENGTH PASSES §3 AND FAILS THE COMPARISON"
#
# The sibling campaign's own shipped defect: mapped pcs with a synthesised opcode, and everything
# downstream well-formed. A walk of 345 records satisfies the count predicate exactly.
# ---------------------------------------------------------------------------
assert_eq "the synthesised stream has the SAME length as the real one" "yes" \
  "$(f synth.sameLengthAsReal)"
assert_eq "…so it is ACCEPTED by the count predicate, which is the point of the control" "yes" \
  "$(f synth.accepted)"
assert_eq "…and produces a container" "345" "$(f synth.steps)"
assert_eq "…with ONE distinct opcode, which is what 'synthesised' looks like" "1" \
  "$(f synth.distinctOpcodesWritten)"

assert_file "the synthesised container was written" "$FAKE_CT"
l3_read_container "$FAKE_CT" "$FAKE_DECODE"
l3_assert_entry_step "$FAKE_DECODE" 345
container_lines "$FAKE_DECODE" >"$L2_WORK/probes/l3-fake-lines.txt"
# THE READER PARSES IT TOO — which is exactly why the reader is not enough on its own.
assert_eq "the reference reader parses the synthesised container as happily as the real one" \
  "345" \
  "$(l3_decode check "$FAKE_DECODE" | sed -n 's/^RECORDER_STEPS\t//p')"

assert_false "BUT ITS LINE SEQUENCE IS NOT THE AVM'S PCs — the comparison §2 makes, failing" \
  test "$(pcs_as_lines "$PCS" | shasum -a 256 | cut -c1-64)" = "$(shasum -a 256 <"$L2_WORK/probes/l3-fake-lines.txt" | cut -c1-64)"
# A WALK 0, 1, 2, … READS BACK 1, 1, 2, …: the same `Line(0)` clamp as the real stream's first
# record, and nothing else moved. The expectation is the walk put through that clamp.
assert_eq "…because it is a WALK: 0, 1, 2, …, read back through the Line(0) clamp" \
  "$(printf '%s\n' 0 1 2 3 4 | pcs_as_lines /dev/stdin)" \
  "$(head -5 "$L2_WORK/probes/l3-fake-lines.txt")"
assert_false "…which the real container's first five lines are not" \
  test "$(head -5 "$L2_WORK/probes/l3-real-lines.txt")" = "$(head -5 "$L2_WORK/probes/l3-fake-lines.txt")"
# BYTE CONTENT, NOT BYTE COUNT. Both containers are 77,824 bytes: the split container is allocated
# in 4096-byte blocks, so two recordings of 345 steps land in the same number of blocks however
# different their records are (§1, `DRIFT.md` D37). That the two are different BYTES is what this
# was for, and it is compared byte for byte.
assert_false "…and the two containers differ in bytes as well" \
  cmp -s "$REAL_CT" "$FAKE_CT"

finish
