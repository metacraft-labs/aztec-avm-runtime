#!/usr/bin/env bash
# l1-mutations.sh — mutation-test L1's three checks.
#
# Same discipline as `l0-mutations.sh`, and for the same four recorded failure states:
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
# L1 MUTATES A FIXTURE AS WELL AS SOURCES, and that is deliberate: a committed fixture is an
# artefact the checks rest on, so "the fixture is a recording of a live chain" has to be able to go
# red when the fixture stops being one. N8 drifts its declared provenance; N12 drifts a recorded
# response. The two fail different assertions, which is the point.
#
# Usage:
#   scratchpad/campaign/l1-mutations.sh                 every arm
#   scratchpad/campaign/l1-mutations.sh N3 N9           named arms
#   scratchpad/campaign/l1-mutations.sh --restore-previous   recover from a run that died

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${L1_MUTATION_WORK:-$HOME/.cache/aztec-l1-mutations}"
BACKUP="$WORK/backup"
MARKER="$WORK/IN-PROGRESS"
LOG="$WORK/log"

FILES=(
  "replay/src/settled_transaction.ts"
  "replay/src/private_half.ts"
  "replay/tools/settled_fixture.ts"
  "replay/fixtures/testnet_settled_tx.json"
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
l1-mutations: a previous run died with mutations live ($MARKER).
Taking a fresh backup now would back up a MUTATED tree, which is the same defect with the sign
flipped. Run with --restore-previous first.
EOF
  exit 1
fi

# A BACKUP IS ONLY AS GOOD AS THE TREE IT WAS TAKEN FROM. L1's sources are uncommitted by design, so
# `git status` cannot be the guard the way M32's review wanted it; the digest comparison at the end
# is, and the wipe-and-re-take is what stops a mutated tree becoming next run's baseline.
rm -rf "$BACKUP"
for f in "${FILES[@]}"; do
  [ -f "$REPO/$f" ] || { echo "l1-mutations: missing $f" >&2; exit 1; }
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

run_check() { # <check-name> <arm>
  local check="$1"
  local armname="$2"
  local out="$LOG/$armname.$check.out"
  timeout "${L1_MUTATION_TIMEOUT:-600}" "$REPO/verification/$check.sh" >"$out" 2>&1
  local rc=$?
  local summary
  summary="$(grep -E "^$check: [0-9]+ assertion" "$out" || true)"
  echo "  rc=$rc  ${summary:-<NO SUMMARY LINE — the check died before printing one>}"
  grep -E '^  FAIL ' "$out" | sed 's/^/    RED: /' | head -14
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
if [ "$#" -gt 0 ]; then ARMS=("$@"); else ARMS=(N1 N2 N3 N4 N5 N6 N7 N8 N11 N12 N13 N14 N15 N16 N9 N10); fi

# ---------------------------------------------------------------------------
if want N1; then
arm N1 "THE PRIMARY DELIVERABLE'S GUARD IS OFF — an unknown contract becomes a plausible value"
sub replay/src/settled_transaction.ts \
  '    if (options.refuseUnknown) {' \
  '    if (false && options.refuseUnknown) {'
run_check test_missing_contract_artifact_refused N1
verify_mutation_survived replay/src/settled_transaction.ts 'if (false && options.refuseUnknown)'
restore_all
fi

# ---------------------------------------------------------------------------
if want N2; then
arm N2 "the refusal stops NAMING THE ADDRESS — 'refused by name' becomes 'refused'"
sub replay/src/settled_transaction.ts \
  '      throw new MissingContractArtifact({
        address: addressText,' \
  '      throw new MissingContractArtifact({
        address: '"'"'a contract'"'"','
run_check test_missing_contract_artifact_refused N2
verify_mutation_survived replay/src/settled_transaction.ts "address: 'a contract',"
restore_all
fi

# ---------------------------------------------------------------------------
if want N3; then
arm N3 "ZERO-LENGTH BYTECODE IS ACCEPTED — the sibling campaign's own failure, re-introduced"
sub replay/src/settled_transaction.ts \
  '  if (bytes === 0) {
    return refuse('"'"'bytecode'"'"', classId);
  }' \
  '  if (false) {
    return refuse('"'"'bytecode'"'"', classId);
  }'
run_check test_missing_contract_artifact_refused N3
verify_mutation_survived replay/src/settled_transaction.ts '  if (false) {
    return refuse('"'"'bytecode'"'"', classId);'
restore_all
fi

# ---------------------------------------------------------------------------
if want N4; then
arm N4 "the private-half STATUS becomes a PRINTED LITERAL — one answer for every input"
# THE PRECISE ARM. N13 below removes the whole branch instead, and that one kills the probe — it
# reddens, but by refusing the run rather than by exercising the control's assertions. This one
# leaves every code path running and changes exactly one thing: the answer stops depending on the
# input. That is the campaign's most-repeated defect in its own shape, and this is the arm that
# says the control can see it.
sub replay/src/private_half.ts \
  '      status: PRIVATE_HALF_AVAILABLE,' \
  '      status: PRIVATE_HALF_UNAVAILABLE,'
run_check test_private_half_declared_absent N4
verify_mutation_survived replay/src/private_half.ts '      status: PRIVATE_HALF_UNAVAILABLE,
      origin: '"'"'locally-originated'"'"','
restore_all
fi

# ---------------------------------------------------------------------------
if want N13; then
arm N13 "the locally-originated branch is removed entirely — recorded as a COARSE arm, see the note"
# HONEST LABEL: this reddens by REFUSING THE RUN, not by exercising the control's assertions. With
# the branch gone, `declarePrivateHalf` reads `source.txEffect` off a locally-originated source,
# which is undefined, and the probe throws before it prints its sentinel — so what catches it is the
# exit-status assertion and the die-before-summary diagnostic, which is N10's statement and not this
# one's. N4 is the arm that says the control sees a constant answer.
sub replay/src/private_half.ts \
  "  if (source.origin === 'locally-originated') {" \
  '  if (false) {'
run_check test_private_half_declared_absent N13
verify_mutation_survived replay/src/private_half.ts '  if (false) {'
restore_all
fi

# ---------------------------------------------------------------------------
if want N5; then
arm N5 "the published effects stop being read off the TxEffect — the evidence becomes a constant"
sub replay/src/private_half.ts \
  '      privateLogs: effect.privateLogs.length,' \
  '      privateLogs: 0,'
run_check test_private_half_declared_absent N5
verify_mutation_survived replay/src/private_half.ts 'privateLogs: 0,'
restore_all
fi

# ---------------------------------------------------------------------------
if want N6; then
arm N6 "A FIXTURE MISS ANSWERS null — an incomplete recording starts reading as 'the chain does not have it'"
sub replay/tools/settled_fixture.ts \
  '        // THROWN, not returned. See the module header.
        throw new FixtureMiss(method, JSON.stringify(req?.params ?? []), table.size);' \
  '        return { jsonrpc: '"'"'2.0'"'"', id: req?.id, result: null };'
run_check e2e_fetch_settled_transaction N6
verify_mutation_survived replay/tools/settled_fixture.ts "return { jsonrpc: '2.0', id: req?.id, result: null };"
restore_all
fi

# ---------------------------------------------------------------------------
if want N7; then
arm N7 "a provenance field stops being required — an unlabelled fixture becomes loadable"
sub replay/tools/settled_fixture.ts \
  "  'capturedAt',
  'capturedBy'," \
  "  'capturedBy',"
run_check e2e_fetch_settled_transaction N7
verify_mutation_survived replay/tools/settled_fixture.ts "  'txHash',
  'l2BlockNumber',"
restore_all
fi

# ---------------------------------------------------------------------------
if want N8; then
arm N8 "THE FIXTURE'S DECLARED PROVENANCE DRIFTS from what its recorded responses say"
sub replay/fixtures/testnet_settled_tx.json \
  '"noteHashTreeRoot": "0x2f5662faff9daf0d49eedcc5ba8101329e5d0ee1bca8a4bcda6a8d98981ea02f"' \
  '"noteHashTreeRoot": "0x2f5662faff9daf0d49eedcc5ba8101329e5d0ee1bca8a4bcda6a8d98981ea000"'
run_check e2e_fetch_settled_transaction N8
verify_mutation_survived replay/fixtures/testnet_settled_tx.json '981ea000'
restore_all
fi

# ---------------------------------------------------------------------------
if want N11; then
arm N11 "the fetch SWALLOWS the refusal and returns a well-formed transaction with no contracts"
sub replay/src/settled_transaction.ts \
  '  const targets = publicCallTargets(tx);
  const contracts = await resolvePublicContracts(client, targets, {
    refuseUnknown: true,
    txHash: hashText,
  });' \
  '  const targets = publicCallTargets(tx);
  let contracts = [];
  try {
    contracts = await resolvePublicContracts(client, targets, {
      refuseUnknown: true,
      txHash: hashText,
    });
  } catch {
    contracts = [];
  }'
run_check test_missing_contract_artifact_refused N11
verify_mutation_survived replay/src/settled_transaction.ts 'let contracts = [];'
restore_all
fi

# ---------------------------------------------------------------------------
if want N12; then
arm N12 "A RECORDED RESPONSE DRIFTS — the contract's bytecode is no longer the bytes the chain sent"
sub replay/fixtures/testnet_settled_tx.json \
  '"packedBytecode": "JwACBAEoAAABBIBcJwAA' \
  '"packedBytecode": "JwACBAEoAAABBIBc'
run_check e2e_fetch_settled_transaction N12
verify_mutation_survived replay/fixtures/testnet_settled_tx.json '"packedBytecode": "JwACBAEoAAABBIBcBFwl'
restore_all
fi

# ---------------------------------------------------------------------------
if want N9; then
arm N9 "THE HANG ARM: contract resolution never returns, and the event loop stays alive"
# THE `setInterval` IS LOAD-BEARING AND IT IS THE M24 FINDING, MET AGAIN HERE. The obvious
# mutation — `await new Promise(() => {})` — is NOT a hang: node detects an unsettled top-level
# await the moment the event loop drains and exits **13** in under a second. Measured on this
# harness's first run of this arm, which reported rc=13 and no summary line: a die-before-summary
# wearing a hang's label, which is N10's statement and not this one's. A live timer keeps the loop
# from draining, so the probe really does sit there and the BOUND is what ends it.
sub replay/src/settled_transaction.ts \
  '  const instance = await client.getContract(address);' \
  '  await new Promise(() => { setInterval(() => {}, 1000); });
  const instance = await client.getContract(address);'
L0_PROBE_TIMEOUT=20 run_check test_missing_contract_artifact_refused N9
verify_mutation_survived replay/src/settled_transaction.ts 'setInterval(() => {}, 1000)'
restore_all
fi

# ---------------------------------------------------------------------------
if want N10; then
arm N10 "THE DIE-BEFORE-SUMMARY ARM: the fixture loader throws before the probe reaches its sentinel"
sub replay/tools/settled_fixture.ts \
  'export function loadSettledFixture(raw: unknown, source: string): SettledFixture {' \
  'export function loadSettledFixture(raw: unknown, source: string): SettledFixture {
  throw new Error("l1-mutations N10: the fixture loader refuses to load");'
run_check test_private_half_declared_absent N10
verify_mutation_survived replay/tools/settled_fixture.ts 'l1-mutations N10'
restore_all
fi

# ---------------------------------------------------------------------------
if want N14; then
arm N14 "the un-batched header reconstruction is emptied — the 'it is the proxy' half loses its evidence"
sub replay/fixtures/testnet_settled_tx.json \
  '"x-aztec-l2circuitsvktreeroot": "0x2b3b6ea4412b9c8f6457a37f91a2870306f8641e07e16a49b68bda6f8bc02892"' \
  '"x-aztec-l2circuitsvktreeroot": "0x0000000000000000000000000000000000000000000000000000000000000000"'
run_check e2e_fetch_settled_transaction N14
verify_mutation_survived replay/fixtures/testnet_settled_tx.json \
  '"x-aztec-l2circuitsvktreeroot": "0x0000000000000000000000000000000000000000000000000000000000000000"'
restore_all
fi

# ---------------------------------------------------------------------------
if want N15; then
arm N15 "the settling-block refusal COLLAPSES into 'not found' — the conflation L0 forbids, one layer up"
sub replay/src/settled_transaction.ts \
  "  readonly kind = 'replay-settling-block-unavailable' as const;" \
  "  readonly kind = 'replay-transaction-not-found' as const;"
run_check e2e_fetch_settled_transaction N15
verify_mutation_survived replay/src/settled_transaction.ts "  readonly kind = 'replay-transaction-not-found' as const;
  readonly blockNumber: number;"
restore_all
fi

# ---------------------------------------------------------------------------
if want N16; then
arm N16 "the DECLARED reference block claims the settling block while the wire still sends none"
# The prose-versus-measurement family, in a value rather than in a document. The declaration and the
# recorded wire call are read separately, so a limitation cannot be declared away.
sub replay/src/settled_transaction.ts \
  "export const CONTRACT_RESOLUTION_REFERENCE_BLOCK = 'latest' as const;" \
  "export const CONTRACT_RESOLUTION_REFERENCE_BLOCK = 'settling-block' as const;"
run_check test_missing_contract_artifact_refused N16
verify_mutation_survived replay/src/settled_transaction.ts "CONTRACT_RESOLUTION_REFERENCE_BLOCK = 'settling-block'"
restore_all
fi

# ---------------------------------------------------------------------------
if want NMISS; then
arm NMISS "THE HARNESS'S OWN RED LINE: a substitution whose needle is not there must ABORT"
# NOT in the default arm list, because it deliberately exits 2 and would end the run. Run it alone:
#   scratchpad/campaign/l1-mutations.sh NMISS
# Expected: `MUTATION MISS in replay/src/private_half.ts … ABORTING`, a restore, NO in-progress
# marker left, and NO arm result printed. That last part is the whole point — M32's arm M2 printed
# the result it had predicted over a subject it had never touched, with the miss twelve lines above
# it in the same log.
sub replay/src/private_half.ts \
  'a needle that is deliberately not in this file' \
  'this replacement must never be written'
run_check test_private_half_declared_absent NMISS
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
