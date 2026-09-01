#!/usr/bin/env bash
# l5-mutations.sh — mutation-test L5's two checks.
#
# Same discipline and the same two red lines as `l0-` through `l3-mutations.sh`:
#
#   * A HANG ARM IS ONE WHOSE RECORDED rc IS 124. Every other non-zero code is a die-before-summary
#     wearing a hang's label — `Testing/Verification-Harness-Traps.md` §1 has the table.
#   * A MUTATION NOTHING CAN KILL IS A FACT ABOUT THE CODE. It is recorded as a survivor, kept, and
#     explained AT THE GUARD — never quietly dropped so the column reads 100%.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE ARMS THAT MATTER, EACH ATTACKING A CLAIM THAT IS OTHERWISE DECORATION.
#
#   A1  DELETES THE BYTECODE COMPARISON and is a DECLARED SURVIVOR, unkillable in principle: the
#       artifact hash's preimage runs through each function's bytecode, so a wrong bytecode is a
#       wrong artifact hash and killing this arm would need a sha256 collision. Kept, and the
#       reason it is kept is at the guard.
#   A2a DELETES THE artifactHash CHECK ALONE and is KILLED BY THE CLASS-ID CHECK — the decoy comes
#       back `class-id-mismatch` instead of `artifact-hash-mismatch`, because
#       `computeContractClassId`'s preimage includes the artifact hash. The finding is that checks
#       1 and 3 are not independent, which is why A2 exists.
#   A2  DELETES BOTH, which is what "our verification becomes the explorer's own" actually
#       requires: Aztecscan compares packed public bytecode and computes no artifact hash at all.
#       **This is the arm the whole milestone turns on** — §3's decoy, right bytecode under a wrong
#       artifact hash, must go from refused to ACCEPTED. A check that only asserted "the real
#       artifact verifies" stays green under it.
#   A3  MAKES `reviveBuffers` THE IDENTITY. The camelCase branch stops verifying, which is the
#       failure that reads exactly like "the explorer has no artifact for this class" — the shape
#       the research this milestone rests on got wrong on its first pass.
#   A5  COUNTS CORROBORATION OVER CANDIDATES RATHER THAN DISTRIBUTORS. Two releases of one registry
#       then read as corroboration, which is the single-source claim the recording exists to make
#       honestly.
#   A6  DECLARES THE RECORDING'S RUNG AS THE BEST CONTRACT'S RATHER THAN THE WORST. The `mixed`
#       arm's transaction — one proved contract, one not — starts reading as source-level, which is
#       the exact "partial rollout makes unresolved transactions look source-level" this milestone
#       is forbidden to ship.
#   A7  STAGES A POSITION ONLY WHERE ONE EXISTS instead of for every step, and is a DECLARED
#       SURVIVOR — `CtWriter.push` pads the skipped slots itself, which is a property its header
#       claims and nothing had exercised from a caller that tries to violate it.
#   A7b STAGES EACH POSITION ONE STEP LATE. Well-formed, every slot occupied, every count right,
#       `MappingRungDegraded` silent — and every line in the container belongs to the next step.
#       Only the record-for-record comparison in section 4b sees it.
#   A9  ROUNDS THE PER-CONTRACT RUNG UP: a contract with SOME steps positioned is declared rung 1.
#       The `partial` arm must catch it, and `CtWriter.close()` should refuse the container.
#
# Usage:
#   scratchpad/campaign/l5-mutations.sh                 every arm
#   scratchpad/campaign/l5-mutations.sh A2 A6           named arms
#   scratchpad/campaign/l5-mutations.sh --restore-previous   recover from a run that died

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${L5_MUTATION_WORK:-$HOME/.cache/aztec-l5-mutations}"
BACKUP="$WORK/backup"
MARKER="$WORK/IN-PROGRESS"
LOG="$WORK/log"

FILES=(
  "replay/src/artifact_resolution.ts"
  "replay/src/artifact_providers.ts"
  "replay/src/recording.ts"
)

mkdir -p "$WORK" "$LOG"

restore_all() {
  local f
  for f in "${FILES[@]}"; do
    [ -f "$BACKUP/$f" ] && cp "$BACKUP/$f" "$REPO/$f"
  done
  rm -f "$MARKER"
  # THE ARMS CACHE IS INVALIDATED TOO. Both checks re-run their arms only when a source is NEWER
  # than the cached JSON, and restoring a file with `cp` updates its mtime — but a mutation that
  # ran and was restored inside one second would leave a mutated arms file that the next arm's
  # freshness test believes. Deleting it is the only ordering-free answer.
  rm -f "${L5_WORK:-$HOME/.cache/aztec-l5-artifacts}/resolver-arms.json" \
        "${L5_WORK:-$HOME/.cache/aztec-l5-artifacts}/recording-arms.json"
}

if [ "${1:-}" = "--restore-previous" ]; then
  [ -d "$BACKUP" ] || { echo "no backup to restore from" >&2; exit 1; }
  restore_all
  echo "restored from $BACKUP"
  exit 0
fi

if [ -f "$MARKER" ]; then
  cat >&2 <<EOF
l5-mutations: a previous run died with mutations live ($MARKER).
Taking a fresh backup now would back up a MUTATED tree, which is the same defect with the sign
flipped. Run with --restore-previous first.
EOF
  exit 1
fi

rm -rf "$BACKUP"
for f in "${FILES[@]}"; do
  [ -f "$REPO/$f" ] || { echo "l5-mutations: missing $f" >&2; exit 1; }
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

run_check() { # <check-name> <arm> [<timeout>]
  local check="$1" armname="$2" t="${3:-900}"
  local out="$LOG/$armname.$check.out"
  rm -f "${L5_WORK:-$HOME/.cache/aztec-l5-artifacts}/resolver-arms.json" \
        "${L5_WORK:-$HOME/.cache/aztec-l5-artifacts}/recording-arms.json"
  timeout "$t" "$REPO/verification/$check.sh" >"$out" 2>&1
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
  ARMS=(A1 A2a A2 A3 A4 A5 A6 A7 A7b A8 A9 AHANG ADIE)
fi

RESOLVE_CHECK=test_offchain_artifact_resolution_verified
RECORD_CHECK=e2e_resolved_contract_records_at_source_level

# ═══════════════════════════════════════════════════════════════════════════
# test_offchain_artifact_resolution_verified — the resolver
# ═══════════════════════════════════════════════════════════════════════════

if want A1; then
arm A1 "DECLARED SURVIVOR: the bytecode comparison is deleted"
sub replay/src/artifact_resolution.ts \
  '  if (!bytecode.equals(chainBytecode)) {' \
  '  if (false) {'
run_check "$RESOLVE_CHECK" A1
verify_mutation_survived replay/src/artifact_resolution.ts '  if (false) {'
cat <<'NOTE'
  DECLARED SURVIVOR, AND UNKILLABLE IN PRINCIPLE — L2's M5 shape, not L3's N5.

  Check 2 compares the artifact's `public_dispatch` bytes against the class's `packedBytecode`.
  Check 1 computes `computeArtifactHash`, whose preimage runs through
  `computeFunctionArtifactHash`, which hashes each function's BYTECODE. So an artifact whose
  bytecode differs necessarily has a different artifact hash: killing this arm needs two distinct
  byte strings with one sha256, and no input this harness can construct has that property.

  IT IS KEPT ANYWAY AND THE REASON IS NOT SENTIMENT. Check 2 is the DIRECT comparison and check 1
  is a claim about a preimage; when they disagree, check 2 refuses with two lengths in the message
  while check 1 refuses with two 32-byte hashes, and only the first tells a caller they fetched a
  different contract rather than a different release. Deleting it would lose nothing detectable
  and lose the sentence that makes a refusal actionable — which is a real cost with no assertion
  that can measure it, and that is exactly the kind of thing a declared survivor is for.
NOTE
restore_all
fi

if want A2a; then
arm A2a "THE artifactHash CHECK ALONE IS DELETED"
sub replay/src/artifact_resolution.ts \
  '  if (artifactHash !== contractClass.artifactHash) {' \
  '  if (false) {'
run_check "$RESOLVE_CHECK" A2a
verify_mutation_survived replay/src/artifact_resolution.ts '  if (false) {'
echo "  KILLED, AND BY THE OTHER HALF OF THE SAME COMMITMENT: the decoy is still refused, as"
echo "  \`class-id-mismatch\` rather than \`artifact-hash-mismatch\`, because computeContractClassId's"
echo "  preimage INCLUDES the artifact hash. The assertion written for it — the fault's NAME — goes"
echo "  red, which is the bar; and the finding is that check 1 and check 3 are not independent."
echo "  A2 removes both, which is what \"become the explorer's own check\" actually requires."
restore_all
fi

if want A2; then
arm A2 "BOTH artifactHash CHECKS ARE DELETED — our verification becomes the explorer's own"
# THE ARM THE MILESTONE TURNS ON. Aztecscan's verification compares packed public bytecode and
# never computes `artifactHash`; this removes BOTH places our resolver does, so what is left is
# exactly the explorer's check. §3's decoy — byte-identical bytecode under a different artifact
# hash, carrying whatever debug map its author liked — must go from refused to ACCEPTED.
#
# A2a above removes only the first and is killed by the second; the pair is what shows that the
# two are not independent and that removing one is not enough to reproduce the weaker check.
sub replay/src/artifact_resolution.ts \
  '  if (artifactHash !== contractClass.artifactHash) {' \
  '  if (false) {'
sub replay/src/artifact_resolution.ts \
  '  if (contractClassId !== contractClass.id) {' \
  '  if (false) {'
run_check "$RESOLVE_CHECK" A2
verify_mutation_survived replay/src/artifact_resolution.ts '  if (contractClassId !== contractClass.id) {
    return reject'
restore_all
fi

if want A3; then
arm A3 "reviveBuffers BECOMES THE IDENTITY — every camelCase artifact reads as unverified"
# The failure mode this produces is the dangerous one: not an error, a plausible absence. An
# explorer serving a perfectly good protocol artifact would be reported as serving nothing.
sub replay/src/artifact_resolution.ts \
  'export function reviveBuffers(value: unknown): unknown {' \
  'export function reviveBuffers(value: unknown): unknown { return value;'
run_check "$RESOLVE_CHECK" A3
verify_mutation_survived replay/src/artifact_resolution.ts 'unknown { return value;'
restore_all
fi

if want A4; then
arm A4 "AN UNRECOGNISED SHAPE BECOMES AN ABSENT ONE — the research's own first wrong answer"
sub replay/src/artifact_resolution.ts \
  "  if ('file_map' in r) return 'snake_case';" \
  "  if ('file_map' in r) return 'snake_case';
  if (true) return null;"
run_check "$RESOLVE_CHECK" A4
verify_mutation_survived replay/src/artifact_resolution.ts '  if (true) return null;'
restore_all
fi

if want A5; then
arm A5 "CORROBORATION IS COUNTED OVER CANDIDATES RATHER THAN DISTRIBUTORS"
# Two releases of one registry then read as two independent attestations, and the container's
# `corroboration=single-distributor` — the one honest thing it can say about unverified source
# text — becomes `corroborated`.
sub replay/src/artifact_resolution.ts \
  '  const agreeingDistributors = [
    ...new Set(verified.filter(v => v.debugDigest === chosen.debugDigest).map(v => v.distributor)),
  ].sort();' \
  '  const agreeingDistributors = verified
    .filter(v => v.debugDigest === chosen.debugDigest)
    .map(v => v.origin)
    .sort();'
run_check "$RESOLVE_CHECK" A5
verify_mutation_survived replay/src/artifact_resolution.ts '.map(v => v.origin)'
echo "  NOTE: over the OFFLINE arms this is exercised by the disagreeing/agreeing pair in section 6"
echo "  — a single provider offering one candidate cannot distinguish the two counting rules, which"
echo "  is exactly why those two arms offer TWO candidates each."
restore_all
fi

if want A8; then
arm A8 "THE PACKAGE PRE-FILTER BECOMES A CHECK — a candidate is dropped silently on length"
# The pre-filter is documented as failing OPEN. Making it fail CLOSED — dropping any shape it
# cannot measure — is the way a filter silently discards the right answer, and it is the one defect
# the arrangement could introduce.
sub replay/src/artifact_providers.ts \
  '        if (length !== null && length !== wanted) continue;' \
  '        if (length === null || length !== wanted) continue;
        if (name.length > 0) continue;'
run_check "$RESOLVE_CHECK" A8
verify_mutation_survived replay/src/artifact_providers.ts 'if (name.length > 0) continue;'
restore_all
fi

# ═══════════════════════════════════════════════════════════════════════════
# e2e_resolved_contract_records_at_source_level — the wiring
# ═══════════════════════════════════════════════════════════════════════════

if want A6; then
arm A6 "THE RECORDING'S RUNG BECOMES THE BEST CONTRACT'S RATHER THAN THE WORST"
# THE CONSTRAINT THE MILESTONE STATES IN WORDS. The `mixed` arm — one proved contract, one not —
# starts declaring rung 1 and `sourceLevel` follows, so a transaction half of whose steps are
# program counters is published as source-level.
sub replay/src/recording.ts \
  '      : Math.max(...contractRungs.map(c => c.rung)),' \
  '      : Math.min(...contractRungs.map(c => c.rung)),'
sub replay/src/recording.ts \
  '  const sourceLevel = contractRungs.length > 0
    && contractRungs.every(c => c.rung === RUNG_SOURCE_VALUE);' \
  '  const sourceLevel = contractRungs.length > 0
    && contractRungs.some(c => c.rung === RUNG_SOURCE_VALUE);'
run_check "$RECORD_CHECK" A6
verify_mutation_survived replay/src/recording.ts 'contractRungs.some(c => c.rung === RUNG_SOURCE_VALUE)'
restore_all
fi

if want A7; then
arm A7 "DECLARED SURVIVOR: the position argument is omitted for an unpositioned step"
sub replay/src/recording.ts \
  '      contractAddress: step.contractAddress,
    }, at);' \
  '      contractAddress: step.contractAddress,
    }, ...(at === undefined ? [] : [at]));'
run_check "$RECORD_CHECK" A7
verify_mutation_survived replay/src/recording.ts '...(at === undefined ? [] : [at])'
cat <<'NOTE'
  DECLARED SURVIVOR, AND THE REASON IS A GUARD IN `ct-host` RATHER THAN A GAP IN THE CHECK.

  This arm was WRITTEN expecting a kill: omit the argument for an unpositioned step and the two
  order-paired FIFOs should desynchronise, sliding every later step onto its predecessor's line.
  It survives because `CtWriter.push` will not let it happen — its condition is
  `if (position !== undefined || this.posFilled > 0)`, and inside it a `while` loop pads every slot
  the host skipped with a `line: 0` record before staging the current one. So a caller that has
  ever supplied one position cannot fail to occupy a slot afterwards, and a caller whose FIRST
  steps are unpositioned has the padding applied retroactively when the first real position
  arrives.

  **THE ARM IS THEREFORE EVIDENCE ABOUT `ct-host` AND NOT ABOUT `recording.ts`**, and it is kept
  for that: the header of `push` claims exactly this property ("a caller that passes some cannot
  desynchronise") and nothing had exercised the claim from a caller that tries. A7b is the arm that
  attacks the same seam in the one way the writer cannot defend against — supplying a position for
  the WRONG STEP, which is well-formed input the writer must trust.
NOTE
restore_all
fi

if want A7b; then
arm A7b "THE POSITION IS STAGED ONE STEP LATE — well-formed, and wrong"
# The writer cannot defend against this: every slot is occupied, the counts are right, the
# container parses, `stepsPositioned` is 64 and `MappingRungDegraded` never fires. Every assertion
# in section 2 stays green. What sees it is section 4b's record-for-record comparison of the
# container's decoded lines against the resolver's own answers — the one assertion here that is not
# a summary.
sub replay/src/recording.ts \
    '      contractAddress: step.contractAddress,
    }, at);' \
    '      contractAddress: step.contractAddress,
    }, positions[i + 1] ?? at);'
run_check "$RECORD_CHECK" A7b
verify_mutation_survived replay/src/recording.ts 'positions[i + 1] ?? at'
restore_all
fi

if want A9; then
arm A9 "THE PER-CONTRACT RUNG IS ROUNDED UP — SOME steps positioned is declared rung 1"
sub replay/src/recording.ts \
  '    } else if (row.steps > 0 && row.positioned === row.steps) {' \
  '    } else if (row.steps > 0 && row.positioned > 0) {'
run_check "$RECORD_CHECK" A9
verify_mutation_survived replay/src/recording.ts '} else if (row.steps > 0 && row.positioned > 0) {'
echo "  NOTE: the writer is expected to refuse the container here — a rung-1 declaration with an"
echo "  unpositioned step is a rungViolation and CtWriter.close() throws MappingRungDegraded. The"
echo "  arms report that as \`threw\`, and the check asserts \`threw\` is MISSING for every arm."
restore_all
fi

# ═══════════════════════════════════════════════════════════════════════════
# THE HARNESS'S OWN RED LINES
# ═══════════════════════════════════════════════════════════════════════════

if want AHANG; then
arm AHANG "A CHECK THAT HANGS — rc 124 AND NO SUMMARY LINE"
# A LIVE HANDLE, NOT AN UNSETTLED PROMISE, and inside an ASYNC function. The traps document's §1
# table: `await new Promise(() => {})` exits 13, an await in a sync function is a syntax error and
# exits 1, and only a pending timer makes `timeout` something to kill. `verifyCandidate` is async,
# which is the second half of the same trap.
sub replay/src/artifact_resolution.ts \
  '  const shape = keyShapeOf(candidate.raw);' \
  '  await new Promise((r) => setTimeout(r, 1e9));
  const shape = keyShapeOf(candidate.raw);'
run_check "$RESOLVE_CHECK" AHANG 30
verify_mutation_survived replay/src/artifact_resolution.ts 'setTimeout(r, 1e9));
  const shape = keyShapeOf(candidate.raw);'
echo "  THE rc IS THE ASSERTION. 124 is a hang; 13 is an unsettled top-level await; 1 is a syntax"
echo "  error. All three are missing a summary line and only one of them is this arm."
restore_all
fi

if want ADIE; then
arm ADIE "A CHECK THAT DIES BEFORE ITS SUMMARY — reads as a SMALLER milestone, not a red one"
sub replay/src/artifact_resolution.ts \
  'export function keyShapeOf(raw: unknown): ArtifactKeyShape | null {' \
  'export function keyShapeOf(raw: unknown): ArtifactKeyShape | null { throw new Error("MUTATED: died before the summary");'
run_check "$RESOLVE_CHECK" ADIE
verify_mutation_survived replay/src/artifact_resolution.ts 'MUTATED: died before the summary'
echo "  THE SUMMARY LINE IS THE ASSERTION. lib.sh's summary_on_abnormal_exit is installed by both"
echo "  L5 checks, so a die prints \`N assertion(s), M+1 failure(s)\` at column 0 and the sweep sees"
echo "  a FAILURE rather than an ABSENCE."
restore_all
fi

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== restore"
restore_all
AFTER="$(digests)"
if [ "$BEFORE" = "$AFTER" ]; then
  echo "restore verified by digest: the tree is byte-identical to how this run found it"
else
  echo "RESTORE FAILED — the tree does NOT match its pre-run digests" >&2
  printf '%s\n' "$BEFORE" >"$WORK/digests.before"
  printf '%s\n' "$AFTER" >"$WORK/digests.after"
  diff "$WORK/digests.before" "$WORK/digests.after" >&2
  exit 4
fi
