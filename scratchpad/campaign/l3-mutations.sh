#!/usr/bin/env bash
# l3-mutations.sh — mutation-test L3's two checks.
#
# Same discipline as `l0-`, `l1-` and `l2-mutations.sh`. `CAMPAIGN-BRIEF.md` carries the two rules
# this harness exists to obey and that L2's found the hard way:
#
#   * A HANG ARM WRITTEN AS `await new Promise(() => {})` IS NOT A HANG ARM. No pending handle means
#     node's loop drains and the process exits 13 on "unsettled top-level await" — a
#     die-before-summary wearing a hang's label. Block on a live handle and ASSERT rc 124.
#   * A MUTATION NOTHING CAN KILL IS A FACT ABOUT THE CODE. Record it as a survivor, keep the arm,
#     and say why AT THE GUARD.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE ARMS THAT MATTER HERE, each attacking a claim that is otherwise decoration.
#
#   N4  makes the container's step `line` a COUNTER instead of the pc. Every count assertion stays
#       green — 345 steps, 345 instructions, the reader parses it — and what goes red is the
#       comparison of the container's line sequence against the AVM's own pcs. THIS IS THE ARM THE
#       SYNTHESISED-STREAM CONTROL EXISTS FOR, applied to the producer rather than to its input:
#       it is M27's shipped defect written into `recording.ts` directly.
#   N6  drops the root-divergence record. The container still carries block coordinates, still
#       parses, still steps — and is now STRICTLY MORE MISLEADING than one carrying neither, which
#       is L2's handoff and the whole reason that record is not optional.
#   N5  is a DECLARED SURVIVOR and is the most useful thing this harness found: the demo transaction
#       executes in ONE AVM context, so `recording.ts`'s frame reconstruction never runs and cannot
#       be tested over it. The gap is in the SUBJECT and is declared in the check.
#   N8  makes the provenance a CONSTANT: the control's container gets the subject's values. The
#       partition in §5 is what sees it — the fields that must differ stop differing while the ones
#       that must match still match, so a check asserting only "the fields are present" is green.
#
# Usage:
#   scratchpad/campaign/l3-mutations.sh                 every arm
#   scratchpad/campaign/l3-mutations.sh N4 N6           named arms
#   scratchpad/campaign/l3-mutations.sh --restore-previous   recover from a run that died

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${L3_MUTATION_WORK:-$HOME/.cache/aztec-l3-mutations}"
BACKUP="$WORK/backup"
MARKER="$WORK/IN-PROGRESS"
LOG="$WORK/log"

FILES=(
  "replay/src/recording.ts"
  "replay/src/replay_inputs.ts"
  "replay/src/replay_execution.ts"
  "replay/tools/node_avm_host.ts"
)

mkdir -p "$WORK" "$LOG"

restore_all() {
  local f
  for f in "${FILES[@]}"; do
    [ -f "$BACKUP/$f" ] && cp "$BACKUP/$f" "$REPO/$f"
  done
  rm -f "$MARKER"
}

if [ "${1:-}" = "--restore-previous" ]; then
  [ -d "$BACKUP" ] || { echo "no backup to restore from" >&2; exit 1; }
  restore_all
  echo "restored from $BACKUP"
  exit 0
fi

if [ -f "$MARKER" ]; then
  cat >&2 <<EOF
l3-mutations: a previous run died with mutations live ($MARKER).
Taking a fresh backup now would back up a MUTATED tree, which is the same defect with the sign
flipped. Run with --restore-previous first.
EOF
  exit 1
fi

rm -rf "$BACKUP"
for f in "${FILES[@]}"; do
  [ -f "$REPO/$f" ] || { echo "l3-mutations: missing $f" >&2; exit 1; }
  mkdir -p "$BACKUP/$(dirname "$f")"
  cp "$REPO/$f" "$BACKUP/$f"
done
digests() { ( cd "$REPO" && { command -v sha256sum >/dev/null 2>&1 && sha256sum "${FILES[@]}" || shasum -a 256 "${FILES[@]}"; } ); }
BEFORE="$(digests)"

trap 'restore_all' EXIT INT TERM HUP

sub() { # <file> <needle> <replacement>
  local file="$REPO/$1" needle="$2" repl="$3"
  if ! grep -qF -- "$needle" "$file"; then
    echo "MUTATION MISS in $1: [$needle] is not in the file. ABORTING." >&2
    restore_all
    exit 2
  fi
  python3 - "$file" "$needle" "$repl" <<'PY'
import sys
path, needle, repl = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
if needle not in s:
    raise SystemExit('needle vanished between the grep and the write: %s' % needle)
open(path, 'w', encoding='utf-8').write(s.replace(needle, repl, 1))
PY
  touch "$MARKER"
}

run_check() { # <check-name> <arm> [<probe-timeout>]
  local check="$1" armname="$2" probe_timeout="${3:-600}"
  local out="$LOG/$armname.$check.out"
  L0_PROBE_TIMEOUT="$probe_timeout" \
    timeout "${L3_MUTATION_TIMEOUT:-900}" "$REPO/verification/$check.sh" >"$out" 2>&1
  local rc=$?
  local summary
  summary="$(grep -E "^$check: [0-9]+ assertion" "$out" || true)"
  echo "  rc=$rc  ${summary:-<NO SUMMARY LINE — the check died before printing one>}"
  grep -E '^  FAIL ' "$out" | sed 's/^/    RED: /' | head -12
}

arm() { echo ""; echo "=== $1 — $2"; }

verify_mutation_survived() { # <file> <needle-that-must-still-be-there>
  if grep -qF -- "$2" "$REPO/$1"; then
    echo "  mutation still present after the run: yes"
  else
    echo "  MUTATION WAS UNDONE DURING THE RUN — the result above is not evidence" >&2
    exit 3
  fi
}

want() { case " ${ARMS[*]} " in (*" $1 "*) return 0 ;; esac; return 1; }
if [ "$#" -gt 0 ]; then ARMS=("$@"); else
  # NMISS is not in the default list: it aborts with rc 2, so anything after it — including the
  # closing digest verification — never runs. A full run must end with "restore verified by digest".
  ARMS=(N1 N2 N3 N4 N5 N6 N7 N8 NHANG NDIE)
fi

# ═══════════════════════════════════════════════════════════════════════════
# e2e_settled_transaction_produces_steppable_ct
# ═══════════════════════════════════════════════════════════════════════════

if want N1; then
arm N1 "THE COUNT PREDICATE IS REMOVED — a container over a partial stream"
sub replay/src/recording.ts \
  '  if (outcome.instructionsExecuted !== steps.length) {' \
  '  if (false) {'
run_check e2e_settled_transaction_produces_steppable_ct N1
verify_mutation_survived replay/src/recording.ts '  if (false) {'
restore_all
fi

if want N2; then
arm N2 "A NULL STREAM BECOMES AN EMPTY ONE — the two states collapse into one"
# `null` means the configuration was wrong; `[]` means the transaction did nothing. Collapsing them
# is how a misconfigured run reads as an empty transaction.
sub replay/src/recording.ts \
  "  if (steps === null) {
    throw new ExecutedStepsUnusable('collection-off', settled.txHash," \
  "  if (steps === null) {
    throw new ExecutedStepsUnusable('empty', settled.txHash,"
run_check e2e_settled_transaction_produces_steppable_ct N2
verify_mutation_survived replay/src/recording.ts "    throw new ExecutedStepsUnusable('empty', settled.txHash,
      'stepsFromOutcome returned null');"
restore_all
fi

if want N3; then
arm N3 "THE RUNG IS DECLARED AS 1 — a debugger that says it has your source and does not"
sub replay/src/recording.ts \
  'export const RUNG_BYTECODE_VALUE = 3;' \
  'export const RUNG_BYTECODE_VALUE = 1;'
run_check e2e_settled_transaction_produces_steppable_ct N3
verify_mutation_survived replay/src/recording.ts 'export const RUNG_BYTECODE_VALUE = 1;'
restore_all
fi

if want N4; then
arm N4 "THE STEP LINE BECOMES A COUNTER — M27's shipped defect, in the producer"
# THE ARM THE SYNTHESISED-STREAM CONTROL EXISTS FOR. Every count assertion stays green: 345 steps,
# 345 instructions, the reader parses it happily. What goes red is the comparison of the container's
# line sequence against the AVM's OWN pcs — which is the only assertion that can tell an execution
# from a walk.
sub replay/src/recording.ts \
  '  for (const step of steps) {
    if (stack.length === 0 || stack[stack.length - 1] !== step.contextId) {' \
  '  let mutatedPc = 0;
  for (const step of steps) {
    if (stack.length === 0 || stack[stack.length - 1] !== step.contextId) {'
sub replay/src/recording.ts \
  '      pc: step.pc,
      opcode: step.opcode,' \
  '      pc: mutatedPc++,
      opcode: step.opcode,'
run_check e2e_settled_transaction_produces_steppable_ct N4
verify_mutation_survived replay/src/recording.ts 'pc: mutatedPc++,'
restore_all
fi

if want N5; then
arm N5 "SURVIVOR OVER THIS SUBJECT: the frames stop following the AVM's context ids"
sub replay/src/recording.ts \
  '    if (stack.length === 0 || stack[stack.length - 1] !== step.contextId) {' \
  '    if (stack.length === 0) {'
# THIS ARM SURVIVES, AND FOR A DIFFERENT REASON FROM L2's M5 — WHICH IS WHY IT IS KEPT AND LABELLED.
#
# M5 was unkillable IN PRINCIPLE: the guard it removed is unreachable for any input. This one is
# unkillable OVER THIS SUBJECT: the demo transaction executes in a SINGLE AVM context, so the
# frame-reconstruction branch never runs and removing it changes nothing. The container has one
# `enqueued-call-0` frame either way.
#
# So the frame logic in `recording.ts` — open on a new context id, unwind on a return to one already
# on the stack — IS NOT EXERCISED BY ANY CHECK IN THIS REPOSITORY. That is a real gap and it is a
# gap in the SUBJECT, not in the check: it needs a transaction whose public half makes a nested
# call. `e2e_settled_transaction_produces_steppable_ct` §2 now asserts `contexts.distinct` is 1 and
# says so, so the gap is declared in the check rather than discovered by the next reader.
run_check e2e_settled_transaction_produces_steppable_ct N5
verify_mutation_survived replay/src/recording.ts '    if (stack.length === 0) {
      const known = stack.lastIndexOf(step.contextId);'
echo "  EXPECTED SURVIVOR over this subject — see the note above this arm. A transaction with a"
echo "  NESTED public call is what would kill it, and none is in the fixture set."
restore_all
fi

# ═══════════════════════════════════════════════════════════════════════════
# test_recording_declares_its_provenance
# ═══════════════════════════════════════════════════════════════════════════

if want N6; then
arm N6 "THE ROOT DIVERGENCE RECORD IS DROPPED — L2's handoff, silently un-honoured"
# The container still carries block coordinates, still parses, still steps. It is now STRICTLY MORE
# MISLEADING than one carrying neither, because the coordinates invite the reader to believe the
# state matched. That is the whole reason this record is not optional.
sub replay/src/recording.ts \
  '  writer.logEvent(RECORDING_METADATA_KEYS.rootDivergence,' \
  '  if (false) writer.logEvent(RECORDING_METADATA_KEYS.rootDivergence,'
run_check test_recording_declares_its_provenance N6
verify_mutation_survived replay/src/recording.ts 'if (false) writer.logEvent(RECORDING_METADATA_KEYS.rootDivergence,'
restore_all
fi

if want N7; then
arm N7 "THE PROTOCOL VERSION LOSES ITS LABEL — the pin readable as what the node said"
sub replay/src/recording.ts \
  "      'protocolVersionSource=pins.json (this repository\\'s PIN, not a value observed from the node '" \
  "      'protocolVersionSourceRemoved=yes (this repository\\'s PIN, not a value observed from the node '"
run_check test_recording_declares_its_provenance N7
verify_mutation_survived replay/src/recording.ts 'protocolVersionSourceRemoved=yes'
restore_all
fi

if want N8; then
arm N8 "THE EXECUTION HALF OF THE PROVENANCE BECOMES A CONSTANT"
# The partition in §5 is what sees this. The fields that describe THE TRANSACTION still match
# between the two containers; the fields that describe THE EXECUTION stop differing. A check that
# only asserted "the fields are present" would be green.
sub replay/src/recording.ts \
  '      `preStateReadAtBlock=${outcome.preStateBlock}`,' \
  '      `preStateReadAtBlock=${settled.l2BlockNumber - 1}`,'
sub replay/src/recording.ts \
  '      `replayedRevertCode=${outcome.revertCode}`,' \
  '      `replayedRevertCode=${settled.revertCode}`,'
sub replay/src/recording.ts \
  '      `publishedEffectsReproduced=${outcome.verdict.reproduced}`,' \
  '      `publishedEffectsReproduced=true`,'
run_check test_recording_declares_its_provenance N8
verify_mutation_survived replay/src/recording.ts 'publishedEffectsReproduced=true`,'
restore_all
fi

# ═══════════════════════════════════════════════════════════════════════════
# THE HARNESS'S OWN RED LINES
# ═══════════════════════════════════════════════════════════════════════════

if want NHANG; then
arm NHANG "A CHECK THAT HANGS — rc 124 AND NO SUMMARY LINE"
# A LIVE HANDLE, NOT AN UNSETTLED PROMISE. See CAMPAIGN-BRIEF.md: `await new Promise(() => {})` has
# no pending handle, so node's loop drains and the process exits 13 on "unsettled top-level await" —
# a die-before-summary wearing a hang's label, which is NDIE's statement and not this one's. A timer
# is a live handle, so the loop does not drain and `timeout` has something to kill.
#
# AND THE TARGET HAS TO BE AN ASYNC FUNCTION, WHICH IS THE SECOND HALF OF THE SAME TRAP.
# This arm's first form put the await inside `buildSettledRecording`, which is SYNCHRONOUS — so it
# was not a hang either, it was a SYNTAX ERROR, and the probe died at parse with rc 1. Three
# distinct ways to write a hang arm that is not one: an unsettled promise (rc 13), an await in a
# sync function (rc 1), and a bound that never fires. Only rc 124 is a hang.
sub replay/src/replay_execution.ts \
  '  const instance = await host.freshInstance();
  await applySeed(instance, settled, hydrated.seed);' \
  '  await new Promise((r) => setTimeout(r, 1e9));
  const instance = await host.freshInstance();
  await applySeed(instance, settled, hydrated.seed);'
run_check e2e_settled_transaction_produces_steppable_ct NHANG 20
verify_mutation_survived replay/src/replay_execution.ts 'setTimeout(r, 1e9));
  const instance = await host.freshInstance();'
restore_all
fi

if want NDIE; then
arm NDIE "A CHECK THAT DIES BEFORE ITS SUMMARY — reads as a SMALLER milestone, not a red one"
sub replay/src/recording.ts \
  'export function recordingIdFor(txHash: string, blockTimestampSeconds: bigint | number): string {' \
  'export function recordingIdFor(txHash: string, blockTimestampSeconds: bigint | number): string { throw new Error("MUTATED: died before the summary");'
run_check test_recording_declares_its_provenance NDIE
verify_mutation_survived replay/src/recording.ts 'MUTATED: died before the summary'
restore_all
fi

if want NMISS; then
arm NMISS "THE HARNESS'S OWN RED LINE — a needle that is not there must ABORT, not print a result"
echo "  (this arm is expected to abort the harness with rc 2; run it alone)"
sub replay/src/recording.ts \
  'a needle that is deliberately not present anywhere in this file' \
  'unreachable'
echo "  IF YOU SEE THIS LINE, THE MISS GUARD DID NOT FIRE" >&2
exit 9
fi

# ---------------------------------------------------------------------------
restore_all
AFTER="$(digests)"
echo ""
if [ "$BEFORE" = "$AFTER" ]; then
  echo "restore verified by digest: every mutated file is byte-identical to its backup"
else
  echo "RESTORE FAILED — the tree does not match the backup:" >&2
  diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") >&2
  exit 4
fi
echo "logs in $LOG"
