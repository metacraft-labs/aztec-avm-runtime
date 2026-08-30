#!/usr/bin/env bash
# l2-mutations.sh — mutation-test L2's three checks.
#
# Same discipline as `l0-mutations.sh` and `l1-mutations.sh`, and for the same four recorded failure
# states:
#
#   1. a mutation that CRASHES has not exercised the assertion it was written for — so each arm
#      records WHICH assertions went red, not merely that the check failed;
#   2. a mutation SILENTLY UNDONE and printed as the arm's result — so every arm verifies after the
#      run that its mutation was still in the file;
#   3. a mutation that NEVER APPLIED and printed the result it predicted — so `sub` ABORTS,
#      restores and says so when its needle is not found;
#   4. a stale backup outliving its source — so the backup is wiped and re-taken every run, an
#      in-progress marker refuses a run that died mid-mutation, and the restore is verified by
#      digest.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE THREE ARMS THAT MATTER MOST HERE, because each attacks a claim that is otherwise decoration.
#
#   M6  makes `preStateBlockForControls` a NO-OP. The control then runs at the same block as the
#       subject, reproduces the effects, and §3 of the effects check goes red. THIS IS THE ARM THAT
#       TESTS THE CONTROL RATHER THAN THE SUBJECT — without it, "the control does not reproduce"
#       could be true because the control never ran.
#   M14 reports the roots as the UNSEEDED ones while leaving the seeding intact. §2 of the roots
#       check exists entirely for this: an EMPTY tree also differs from the chain, so every "the
#       roots differ" assertion in §1 stays green while the hydration does nothing. M14 fires
#       exactly the two §2 assertions and nothing else, which is what says §2 is load-bearing.
#       (M8 was written for this and could NOT reach §2 — with nothing seeded the AVM refuses and
#       the probe dies first. M8 is kept, labelled COARSE, because the honest record of an arm that
#       reddened for the wrong reason is worth more than a deleted one.)
#   M11 turns `collectHints` OFF in the encoder. Route 3's whole premise is that the AVM names its
#       own reads; with the flag off the loop discovers nothing. §4 and §5 of the routes check exist
#       for this and M11 is what says so.
#
# L2 MUTATES A FIXTURE AS WELL AS SOURCES (M13), for L1's reason: a committed recording is an
# artefact the checks rest on, and "this is a recording of a live chain" has to be able to go red.
# L2's fixture is the sharper case, because its per-slot witness responses are what the hydration
# reads — a corrupted one is a wrong VALUE seeded at a RIGHT slot, which is the exact shape of wrong
# answer `historical_state.ts` refuses to produce by coercion.
#
# Usage:
#   scratchpad/campaign/l2-mutations.sh                 every arm
#   scratchpad/campaign/l2-mutations.sh M3 M8           named arms
#   scratchpad/campaign/l2-mutations.sh --restore-previous   recover from a run that died

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${L2_MUTATION_WORK:-$HOME/.cache/aztec-l2-mutations}"
BACKUP="$WORK/backup"
MARKER="$WORK/IN-PROGRESS"
LOG="$WORK/log"

FILES=(
  "replay/src/replay_execution.ts"
  "replay/src/historical_state.ts"
  "replay/src/replay_inputs.ts"
  "replay/tools/node_avm_host.ts"
  "replay/fixtures/testnet_replay_tx.json"
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
l2-mutations: a previous run died with mutations live ($MARKER).
Taking a fresh backup now would back up a MUTATED tree, which is the same defect with the sign
flipped. Run with --restore-previous first.
EOF
  exit 1
fi

rm -rf "$BACKUP"
for f in "${FILES[@]}"; do
  [ -f "$REPO/$f" ] || { echo "l2-mutations: missing $f" >&2; exit 1; }
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
    timeout "${L2_MUTATION_TIMEOUT:-900}" "$REPO/verification/$check.sh" >"$out" 2>&1
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
  # MMISS IS NOT IN THE DEFAULT LIST, and that is L1's ordering rather than an omission. It is the
  # harness's own red line: it ABORTS the run with rc 2, so anything after it — including the
  # closing digest verification — never executes. A full run must end with "restore verified by
  # digest"; MMISS is run alone, on purpose, and prints no arm result of its own.
  ARMS=(M1 M2 M3 M4 M5 M6 M7 M8 M14 M9 M10 M11 M12 M13 MHANG MDIE)
fi

# ═══════════════════════════════════════════════════════════════════════════
# e2e_replay_matches_published_effects
# ═══════════════════════════════════════════════════════════════════════════

if want M1; then
arm M1 "THE COMPARISON ALWAYS MATCHES — a verdict that cannot say no"
sub replay/src/replay_execution.ts \
  '    comparisons.push({ field, published: pa, replayed: pb, matches: pa === pb });' \
  '    comparisons.push({ field, published: pa, replayed: pb, matches: true });'
run_check e2e_replay_matches_published_effects M1
verify_mutation_survived replay/src/replay_execution.ts 'matches: true });'
restore_all
fi

if want M2; then
arm M2 "THE COMPARISON STOPS COMPARING THE WRITES — the count DROPS, which is the red flag"
# CAMPAIGN-BRIEF.md: "a count that drops is a red flag, never 'fewer assertions were needed'." Here
# it is the COMPARISON count rather than the assertion count, and §1 pins it at 23 for exactly this.
sub replay/src/replay_execution.ts \
  '  for (let i = 0; i < Math.max(publishedWrites.length, replayedWrites.length); i += 1) {' \
  '  for (let i = 0; i < 0; i += 1) {'
run_check e2e_replay_matches_published_effects M2
verify_mutation_survived replay/src/replay_execution.ts 'for (let i = 0; i < 0; i += 1) {'
restore_all
fi

if want M3; then
arm M3 "THE PRE-STATE IS READ AT THE SETTLING BLOCK BY DEFAULT — the replay reads its own answer"
sub replay/src/replay_execution.ts \
  "  const parent = options.preStateBlockForControls === 'settling-block'" \
  "  const parent = options.preStateBlockForControls !== 'settling-block'"
run_check e2e_replay_matches_published_effects M3
verify_mutation_survived replay/src/replay_execution.ts \
  "options.preStateBlockForControls !== 'settling-block'"
restore_all
fi

if want M4; then
arm M4 "COARSE: the transaction's own nullifier is no longer excluded — it reddens by refusing the run"
sub replay/src/replay_execution.ts \
  '    nullifiers: new Set(settled.txEffect.data.nullifiers.map((n) => n.toString().toLowerCase())),' \
  '    nullifiers: new Set(),'
# HONEST LABEL: a replay whose own nullifier is already in the tree reverts, then refuses, and the
# probe dies before its sentinel. The exit-status assertion catches it, which is MDIE's statement.
# The BEHAVIOUR is still the one worth demonstrating — a replay failing precisely because the
# transaction succeeded — and it is demonstrated; what is not demonstrated is §1 seeing it.
run_check e2e_replay_matches_published_effects M4
verify_mutation_survived replay/src/replay_execution.ts 'nullifiers: new Set(),'
restore_all
fi

if want M5; then
arm M5 "SURVIVOR, RECORDED: \`reproduced\` no longer requires a comparison — and no check can see it"
sub replay/src/replay_execution.ts \
  '    reproduced: comparisons.length > 0 && matched === comparisons.length,' \
  '    reproduced: matched === comparisons.length,'
# THIS ARM SURVIVES, AND IT IS RECORDED AS A SURVIVOR RATHER THAN DELETED OR PAPERED OVER.
#
# `compareToPublishedEffects` pushes `revertCode`, `transactionFee` and the two length comparisons
# UNCONDITIONALLY, so `comparisons.length` is never zero for any input it can be given.
# `comparisons.length > 0` is therefore UNREACHABLE defence, and no test over any transaction — not
# even one with no public half, which still yields eighteen comparisons — can distinguish the two
# forms. A mutation nothing can kill is a fact about the code, not a gap in the check.
#
# It is KEPT for the reason it was written: if the comparison set ever becomes conditional on the
# public half being present, the guard becomes live and the vacuous green it prevents is the one
# this campaign has shipped twice. `replay_execution.ts` now says this at the guard, so the next
# reader does not have to re-derive it, and this arm is what stops the comment being a guess.
run_check e2e_replay_matches_published_effects M5
verify_mutation_survived replay/src/replay_execution.ts \
  'reproduced: matched === comparisons.length,'
echo "  EXPECTED SURVIVOR — see the note above this arm. rc=0 here is the recorded outcome."
restore_all
fi

if want M6; then
arm M6 "THE CONTROL'S OPTION IS A NO-OP — THE ARM THAT TESTS THE CONTROL AND NOT THE SUBJECT"
# Without this arm, "the control does not reproduce the published effects" could be true because
# the control never ran at a different block at all. With the option ignored, the control becomes a
# second run of the subject: it reproduces, and §3 and §4 go red while §1 and §2 stay green.
sub replay/src/replay_execution.ts \
  "    ? BlockNumber(settled.l2BlockNumber)
    : BlockNumber(settled.l2BlockNumber - 1);" \
  "    ? BlockNumber(settled.l2BlockNumber - 1)
    : BlockNumber(settled.l2BlockNumber - 1);"
run_check e2e_replay_matches_published_effects M6
verify_mutation_survived replay/src/replay_execution.ts \
  "    ? BlockNumber(settled.l2BlockNumber - 1)
    : BlockNumber(settled.l2BlockNumber - 1);"
restore_all
fi

# ═══════════════════════════════════════════════════════════════════════════
# verify_hydrated_roots_match_state_reference
# ═══════════════════════════════════════════════════════════════════════════

if want M7; then
arm M7 "THE ROOT COMPARISON ALWAYS SAYS 'DIFFERS' — a printed literal wearing a boolean's clothes"
sub replay/src/replay_execution.ts \
  '    return { tree, resident: residentRoot, chain: chainRoot, agrees: residentRoot === chainRoot };' \
  '    return { tree, resident: residentRoot, chain: chainRoot, agrees: false };'
run_check verify_hydrated_roots_match_state_reference M7
verify_mutation_survived replay/src/replay_execution.ts 'agrees: false };'
restore_all
fi

if want M8; then
arm M8 "COARSE: the seeding is a no-op — it reddens by REFUSING THE RUN, not by reaching §2"
# HONEST LABEL, in L1's N13 shape. The intent was to make §2's "the tree MOVED" fire. It does not:
# with nothing seeded the AVM refuses on the fee payer's balance, `replaySettledTransaction` throws
# `ModuleRefusedReplay`, and the probe dies before its sentinel — so what catches this is the
# exit-status assertion and the die-before-summary diagnostic, which is MDIE's statement rather than
# §2's. M14 below is the arm that actually reaches §2.
sub replay/tools/node_avm_host.ts \
  "        insertPublicDataLeaf(slot: Fr, value: Fr) {
          reactor.callWithBlob('avm_merkle_db_insert_indexed_leaves_public_data_tree', merkleDb,
            serializeWithMessagePack({ slot, value }));
        }," \
  "        insertPublicDataLeaf(_slot: Fr, _value: Fr) {
          // MUTATED: the seeding does nothing.
        },"
run_check verify_hydrated_roots_match_state_reference M8
verify_mutation_survived replay/tools/node_avm_host.ts 'MUTATED: the seeding does nothing.'
restore_all
fi

if want M9; then
arm M9 "THE DIVERGENCE REASON BECOMES A TOKEN — the sentence L3 has to render, gone"
sub replay/src/replay_execution.ts \
  "export const TREE_ROOTS_DIVERGE_REASON =
  'The resident merkle DB starts at genesis with 128 prefilled indexed leaves and is seeded with '" \
  "export const TREE_ROOTS_DIVERGE_REASON = 'roots differ'; const UNUSED_REASON =
  'The resident merkle DB starts at genesis with 128 prefilled indexed leaves and is seeded with '"
run_check verify_hydrated_roots_match_state_reference M9
verify_mutation_survived replay/src/replay_execution.ts "TREE_ROOTS_DIVERGE_REASON = 'roots differ'"
restore_all
fi

if want M14; then
arm M14 "THE ARM §2 REALLY EXISTS FOR: the roots are REPORTED as the unseeded ones"
# M8 could not reach §2 because a tree with nothing in it makes the AVM refuse. This one leaves the
# seeding intact — the replay runs, reproduces the effects, and §1 is entirely green — and changes
# only what `treeRoots()` REPORTS: the roots captured before any seeding happened.
#
# That is precisely the defect §2 was written for. "All four roots differ from the chain" is true of
# a genesis tree and true of a seeded one, so §1 cannot tell them apart; only the comparison against
# a fresh module's roots can, and only §2 makes it.
sub replay/tools/node_avm_host.ts \
  "        treeRoots() {
          return (reactor.callWithHandle(TREE_ROOTS_EXPORT, merkleDb) ?? {}) as Record<string, unknown>;
        }," \
  "        treeRoots() {
          // MUTATED: report the roots as they were BEFORE any seeding.
          return unseededRoots;
        },"
sub replay/tools/node_avm_host.ts \
  "      const merkleDb = reactor.createMerkleDb();" \
  "      const merkleDb = reactor.createMerkleDb();
      const unseededRoots = (reactor.callWithHandle('avm_merkle_db_get_tree_roots', merkleDb) ?? {});"
run_check verify_hydrated_roots_match_state_reference M14
verify_mutation_survived replay/tools/node_avm_host.ts 'MUTATED: report the roots as they were BEFORE any seeding.'
restore_all
fi

# ═══════════════════════════════════════════════════════════════════════════
# verify_state_route_decided_on_measurement
# ═══════════════════════════════════════════════════════════════════════════

if want M10; then
arm M10 "A CLOSED ROUTE IS RE-DECLARED OPEN — the disposition drifts from what upstream says"
sub replay/src/historical_state.ts \
  "  'seed-from-state-reference': Object.freeze({
    verdict: 'closed' as const," \
  "  'seed-from-state-reference': Object.freeze({
    verdict: 'implemented' as const,"
run_check verify_state_route_decided_on_measurement M10
verify_mutation_survived replay/src/historical_state.ts "verdict: 'implemented' as const,
    because:
      'MemoryMerkleDB takes two prefill counts"
restore_all
fi

if want M11; then
arm M11 "collectHints IS TURNED OFF — route 3's premise removed, and the loop discovers nothing"
# §4 and §5 of the routes check exist for this arm. The encoder still runs, the AVM still executes,
# and the hydration loop simply never learns what to seed.
sub replay/src/replay_inputs.ts \
  '    collectHints: true,' \
  '    collectHints: false,'
run_check verify_state_route_decided_on_measurement M11
verify_mutation_survived replay/src/replay_inputs.ts 'collectHints: false,'
restore_all
fi

if want M12; then
arm M12 "A DISPOSITION CITES THE WRONG FILE — the citation stops being checkable"
sub replay/src/historical_state.ts \
  "    source: 'barretenberg/cpp/src/barretenberg/vm2/avm_sim_api.cpp:45-47'," \
  "    source: 'somewhere/in/upstream/probably.cpp',"
run_check verify_state_route_decided_on_measurement M12
verify_mutation_survived replay/src/historical_state.ts "source: 'somewhere/in/upstream/probably.cpp',"
restore_all
fi

# ═══════════════════════════════════════════════════════════════════════════
# THE FIXTURE IS AN ARTEFACT TOO
# ═══════════════════════════════════════════════════════════════════════════

if want M13; then
arm M13 "A RECORDED WITNESS RESPONSE IS CORRUPTED — a wrong VALUE seeded at a RIGHT slot"
# The sharpest shape available here, and the reason L1's harness mutates a fixture at all. The slot
# still matches, so `answerQueries` seeds it happily; only the arithmetic downstream disagrees.
python3 - "$REPO/replay/fixtures/testnet_replay_tx.json" <<'PY'
import json, sys
path = sys.argv[1]
d = json.load(open(path))
hits = 0
for call in d['calls']:
    if call['method'] != 'aztec_getPublicDataWitness':
        continue
    leaf = (call.get('result') or {}).get('leafPreimage', {}).get('leaf')
    if not leaf:
        continue
    v = leaf.get('value')
    if isinstance(v, str) and v.startswith('0x') and int(v, 16) != 0:
        leaf['value'] = '0x' + format(int(v, 16) + 1, '064x')
        hits += 1
        break
if hits == 0:
    raise SystemExit('MUTATION MISS: no non-zero public-data witness value in the fixture')
json.dump(d, open(path, 'w'), indent=2)
print('  corrupted one recorded public-data witness value (+1)')
PY
touch "$MARKER"
run_check e2e_replay_matches_published_effects M13
echo "  mutation still present after the run: $(python3 -c "
import json,sys
d=json.load(open('$REPO/replay/fixtures/testnet_replay_tx.json'))
b=json.load(open('$BACKUP/replay/fixtures/testnet_replay_tx.json'))
print('yes' if d!=b else 'NO — THE RESULT ABOVE IS NOT EVIDENCE')")"
restore_all
fi

# ═══════════════════════════════════════════════════════════════════════════
# THE HARNESS'S OWN RED LINES
# ═══════════════════════════════════════════════════════════════════════════

if want MHANG; then
arm MHANG "A CHECK THAT HANGS — rc 124 and NO SUMMARY LINE. A check that hangs never reddens"
# THE FIRST FORM OF THIS ARM WAS NOT A HANG AND IS RECORDED RATHER THAN QUIETLY FIXED.
# It was `await new Promise(() => {})`, which has NO pending handle, so node's event loop drains and
# the process EXITS 13 on "unsettled top-level await". The probe died before its summary and the arm
# printed a die-before-summary result under a hang's label — which is MDIE's statement, not this
# one's. L1's review hit the identical trap and recorded it; walking into it again is the reason the
# fix is a long TIMER: a pending timer is a live handle, so the loop does not drain, node does not
# exit, and `timeout` has something to kill. rc 124 is the difference between the two arms.
sub replay/src/replay_execution.ts \
  '  const seed = emptySeed();' \
  '  await new Promise((r) => setTimeout(r, 1e9)); const seed = emptySeed();'
# The probe bound is 20s for this arm so the demonstration costs 20 seconds and not ten minutes. The
# point is the SHAPE of the failure — rc 124, no summary — not its duration.
run_check e2e_replay_matches_published_effects MHANG 20
verify_mutation_survived replay/src/replay_execution.ts 'setTimeout(r, 1e9)); const seed'
restore_all
fi

if want MDIE; then
arm MDIE "A CHECK THAT DIES BEFORE ITS SUMMARY — reads as a SMALLER milestone, not a red one"
sub replay/src/historical_state.ts \
  'export function emptySeed(): ResidentSeed {' \
  'export function emptySeed(): ResidentSeed { throw new Error("MUTATED: died before the summary");'
run_check verify_hydrated_roots_match_state_reference MDIE
verify_mutation_survived replay/src/historical_state.ts 'MUTATED: died before the summary'
restore_all
fi

if want MMISS; then
arm MMISS "THE HARNESS'S OWN RED LINE — a needle that is not there must ABORT, not print a result"
echo "  (this arm is expected to abort the harness with rc 2; run it alone)"
sub replay/src/replay_execution.ts \
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
