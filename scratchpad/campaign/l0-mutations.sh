#!/usr/bin/env bash
# l0-mutations.sh — mutation-test L0's three checks.
#
# THE RULE THIS EXISTS FOR. "Mutation-test every check before declaring, including a HANG arm and a
# DIE-BEFORE-SUMMARY arm." And the four states CAMPAIGN-BRIEF.md records, every one of which has
# shipped in this campaign:
#
#   1. a mutation that CRASHES has not exercised the assertion it was written for — so each arm
#      records WHICH assertions went red, not merely that the check failed;
#   2. a mutation that is SILENTLY UNDONE and printed as the arm's result — so every arm verifies
#      after the run that its mutation was still in the file;
#   3. a mutation that NEVER APPLIED and printed the result it predicted — so `sub` ABORTS,
#      restores and says so when its needle is not found, rather than returning;
#   4. a stale backup outliving its source — so the backup is wiped and re-taken every run, an
#      in-progress marker refuses a run that died mid-mutation, and the restore is verified by
#      digest rather than assumed.
#
# The L0 sources are UNCOMMITTED by design (the implementation agent does not commit), so `git
# checkout --` cannot restore them and the harness owns its own copies. The digest check at the end
# is what makes that safe.
#
# Usage:
#   scratchpad/campaign/l0-mutations.sh                 every arm
#   scratchpad/campaign/l0-mutations.sh M3 M7           named arms
#   scratchpad/campaign/l0-mutations.sh --restore-previous   recover from a run that died

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${L0_MUTATION_WORK:-$HOME/.cache/aztec-l0-mutations}"
BACKUP="$WORK/backup"
MARKER="$WORK/IN-PROGRESS"
LOG="$WORK/log"

FILES=(
  "replay/src/strict_surface.ts"
  "replay/src/node_surface.ts"
  "replay/src/node_client.ts"
  "replay/src/pinned_protocol_version.ts"
  "verification/_l0_fake_node.mjs"
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
l0-mutations: a previous run died with mutations live ($MARKER).
Taking a fresh backup now would back up a MUTATED tree, which is the same defect with the sign
flipped. Run with --restore-previous first.
EOF
  exit 1
fi

# THE BACKUP IS WIPED AND RE-TAKEN EVERY RUN. `cp only if absent` is right within one run and wrong
# across sessions: M32's harness reverted two improvements made between runs, and the check then
# reported a field as MISSING, which read as a defect in the subject rather than in the instrument.
rm -rf "$BACKUP"
for f in "${FILES[@]}"; do
  [ -f "$REPO/$f" ] || { echo "l0-mutations: missing $f" >&2; exit 1; }
  mkdir -p "$BACKUP/$(dirname "$f")"
  cp "$REPO/$f" "$BACKUP/$f"
done
digests() { ( cd "$REPO" && { command -v sha256sum >/dev/null 2>&1 && sha256sum "${FILES[@]}" || shasum -a 256 "${FILES[@]}"; } ); }
BEFORE="$(digests)"

trap 'restore_all' EXIT INT TERM HUP

# sub <file> <needle> <replacement>
#
# A SUBSTITUTION THAT DOES NOT FIND ITS NEEDLE ABORTS THE RUN. M32's arm M2 printed
# `MUTATION MISS` and returned, the harness ran without `-e`, the arm rebuilt and reported the
# result it had predicted — over a subject it had never touched, with the miss twelve lines above
# the result in the same log.
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

# run_check <check> <arm> -> prints the summary line and the failing assertion names
run_check() { # <check-name> <arm>
  # THREE STATEMENTS, NOT ONE. `local a="$1" b="$a"` does not work: bash expands every word of the
  # command before `local` runs, so the second reference is to a variable that does not exist yet
  # and `set -u` kills the run. Met on this harness's first execution.
  local check="$1"
  local armname="$2"
  local out="$LOG/$armname.$check.out"
  timeout "${L0_MUTATION_TIMEOUT:-600}" "$REPO/verification/$check.sh" >"$out" 2>&1
  local rc=$?
  local summary
  summary="$(grep -E "^$check: [0-9]+ assertion" "$out" || true)"
  echo "  rc=$rc  ${summary:-<NO SUMMARY LINE — the check died before printing one>}"
  # WHICH assertions went red, not merely that it failed. "The check failed" and "the check saw
  # what I broke" are different statements and only the second is coverage.
  grep -E '^  FAIL ' "$out" | sed 's/^/    RED: /' | head -12
}

arm() { # <name> <description>
  echo ""
  echo "=== $1 — $2"
}

verify_mutation_survived() { # <file> <needle-that-must-still-be-there>
  if grep -qF -- "$2" "$REPO/$1"; then
    echo "  mutation still present after the run: yes"
  else
    echo "  MUTATION WAS UNDONE DURING THE RUN — the result above is not evidence" >&2
    exit 3
  fi
}

want() { case " ${ARMS[*]} " in (*" $1 "*) return 0 ;; esac; return 1; }
if [ "$#" -gt 0 ]; then ARMS=("$@"); else ARMS=(M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11); fi

# ---------------------------------------------------------------------------
if want M1; then
arm M1 "the guard stops trapping 'has' — probing becomes silent, which is the dangerous direction"
sub replay/src/strict_surface.ts \
  '    has(target, property) {
      if (typeof property === '"'"'symbol'"'"') {
        return Reflect.has(target, property);
      }
      if (!allowed.includes(property)) {
        throw new ReplayNodeSurfaceExceeded(property, allowed);
      }
      return Reflect.has(target, property);
    },' \
  '    has(target, property) {
      return Reflect.has(target, property);
    },'
run_check verify_node_client_surface_narrow M1
verify_mutation_survived replay/src/strict_surface.ts 'has(target, property) {
      return Reflect.has(target, property);'
restore_all
fi

# ---------------------------------------------------------------------------
if want M2; then
arm M2 "the guard stops trapping 'get' — the surface is a type again, and a type is erased"
sub replay/src/strict_surface.ts \
      '      if (!allowed.includes(property)) {
        throw new ReplayNodeSurfaceExceeded(property, allowed);
      }
      const value = Reflect.get(target, property, target);' \
      '      const value = Reflect.get(target, property, target);'
run_check verify_node_client_surface_narrow M2
verify_mutation_survived replay/src/strict_surface.ts 'const value = Reflect.get(target, property, target);'
restore_all
fi

# ---------------------------------------------------------------------------
if want M3; then
arm M3 "'not found' collapses into 'unreachable' — the exact conflation L0 forbids"
sub replay/src/node_client.ts \
  'export class SettledTransactionNotFound extends Error {' \
  'export class SettledTransactionNotFound extends NodeUnreachable {'
sub replay/src/node_client.ts \
  "  readonly kind = 'replay-transaction-not-found' as const;" \
  "  readonly kind = 'replay-node-unreachable' as const;"
run_check test_node_client_refusals_distinguishable M3
verify_mutation_survived replay/src/node_client.ts 'extends NodeUnreachable {'
restore_all
fi

# ---------------------------------------------------------------------------
if want M4; then
arm M4 "a streaming method is quietly permitted — the ingestion line moves and nobody said so"
sub replay/src/node_surface.ts "  'getNodeInfo'," "  'getBlocks',
  'getNodeInfo',"
run_check verify_node_client_surface_narrow M4
verify_mutation_survived replay/src/node_surface.ts "  'getBlocks',
  'getNodeInfo',"
restore_all
fi

# ---------------------------------------------------------------------------
if want M5; then
arm M5 "a refused method loses its group — an upstream method becomes unclassified"
sub replay/src/node_surface.ts "      'sendTx',
      'isValidTx'," "      'isValidTx',"
run_check verify_node_client_surface_narrow M5
verify_mutation_survived replay/src/node_surface.ts "    methods: [
      'isValidTx',"
restore_all
fi

# ---------------------------------------------------------------------------
if want M6; then
arm M6 "the pinned protocol version drifts off upstream's own producer"
sub replay/src/pinned_protocol_version.ts \
  "l2CircuitsVkTreeRoot: '0x2b3b6ea4412b9c8f6457a37f91a2870306f8641e07e16a49b68bda6f8bc02892'" \
  "l2CircuitsVkTreeRoot: '0x2b3b6ea4412b9c8f6457a37f91a2870306f8641e07e16a49b68bda6f8bc02893'"
run_check verify_client_uses_upstream_schema M6
verify_mutation_survived replay/src/pinned_protocol_version.ts 'bc02893'
restore_all
fi

# ---------------------------------------------------------------------------
if want M7; then
arm M7 "the version expectation is never handed to upstream's client — the check silently stops happening"
sub replay/src/node_client.ts \
  'const raw: AztecNode = createAztecNodeClient(url, expected, wrappedFetch);' \
  'const raw: AztecNode = createAztecNodeClient(url, {}, wrappedFetch);'
run_check test_node_client_refusals_distinguishable M7
verify_mutation_survived replay/src/node_client.ts 'createAztecNodeClient(url, {}, wrappedFetch)'
restore_all
fi

# ---------------------------------------------------------------------------
if want M8; then
arm M8 "the version mismatch stops being NAMED — upstream's error is rethrown unclassified"
# The PRECISE version arm. M11 below removes the headers instead, and that one kills the probe —
# which reddens, but by refusing the run rather than by exercising the mismatch assertions. This
# one leaves everything running and changes exactly one thing: the refusal loses its name.
sub replay/src/node_client.ts \
  '    if (isComponentsVersionsError(err)) {' \
  '    if (false && isComponentsVersionsError(err)) {'
run_check test_node_client_refusals_distinguishable M8
verify_mutation_survived replay/src/node_client.ts 'if (false && isComponentsVersionsError(err))'
restore_all
fi

# ---------------------------------------------------------------------------
if want M11; then
arm M11 "the node stops emitting version headers — recorded as a COARSE arm, see the note"
# HONEST LABEL: this one reddens by refusing the run, not by exercising the mismatch assertions.
# `assertProtocolVersion` is strict about silence, so the CONTROL section throws and the probe dies
# before the mismatch arms are reached — the check's exit-status assertion and its `die` diagnostic
# are what catch it. That is a real property (a node that will not say what it speaks is refused,
# loudly, with the field named `absent`), and it is NOT the same statement as "the mismatch
# assertions saw this". M8 is the arm that makes that statement.
sub verification/_l0_fake_node.mjs \
  '    middlewares.push(getVersioningMiddleware(opts.versions));' \
  '    middlewares.push(async (_ctx, next) => { await next(); });'
run_check test_node_client_refusals_distinguishable M11
verify_mutation_survived verification/_l0_fake_node.mjs 'async (_ctx, next) => { await next(); }'
restore_all
fi

# ---------------------------------------------------------------------------
if want M9; then
arm M9 "THE HANG ARM: the node accepts the connection and never answers"
sub verification/_l0_fake_node.mjs \
  '      calls.push(name);' \
  '      calls.push(name); await new Promise(() => {});'
L0_PROBE_TIMEOUT=20 run_check test_node_client_refusals_distinguishable M9
verify_mutation_survived verification/_l0_fake_node.mjs 'await new Promise(() => {})'
restore_all
fi

# ---------------------------------------------------------------------------
if want M10; then
arm M10 "THE DIE-BEFORE-SUMMARY ARM: the probe throws before it reaches its sentinel"
sub verification/_l0_fake_node.mjs \
  'export async function startFakeNode(opts = {}) {' \
  'export async function startFakeNode(opts = {}) {
  throw new Error("l0-mutations M10: the fake node refuses to start");'
run_check test_node_client_refusals_distinguishable M10
verify_mutation_survived verification/_l0_fake_node.mjs 'l0-mutations M10'
restore_all
fi

# ---------------------------------------------------------------------------
restore_all
AFTER="$(digests)"
echo ""
if [ "$BEFORE" = "$AFTER" ]; then
  echo "restore verified by digest: every mutated file is byte-identical to its pre-run state"
else
  echo "RESTORE FAILED — the tree does not match its pre-run digests" >&2
  diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") >&2
  exit 4
fi
echo "logs in $LOG"
