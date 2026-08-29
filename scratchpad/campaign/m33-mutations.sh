#!/usr/bin/env bash
# m33-mutations.sh — M33's mutation matrix.
#
#   scratchpad/campaign/m33-mutations.sh [arm...]        (default: all)
#
# ===========================================================================================
# WHAT THIS HARNESS LEARNED FROM THE LAST THREE REVIEWS
# ===========================================================================================
#
#  * **A SUBSTITUTION THAT DOES NOT FIND ITS NEEDLE ABORTS THE RUN.** M32's arm M2 printed
#    `MUTATION MISS` and *returned*; the harness ran without `-e`, so the arm rebuilt, ran the
#    check, and reported the one failure it had predicted — produced by a SECOND substitution that
#    mutated only the CONTROL. It was recorded as "the most precise arm in the matrix" over a
#    subject it had never touched. Here `sub` restores, clears the marker and exits 3.
#  * **THE BACKUP IS WIPED AND RE-TAKEN EVERY RUN**, and an in-progress marker refuses a run
#    started over a tree an earlier session left mutated.
#  * **AND THE BACKUP'S OWN TREE IS CHECKED.** M32's remedy was `git status --porcelain` against
#    HEAD, which cannot work here: M33's files are staged and uncommitted by design (the
#    implementation agent does not commit). So the guard is a sha256 MANIFEST of the mutated file
#    set, taken before the first mutation and verified after the last restore. It is strictly
#    stronger than the HEAD comparison for this state, because it pins CONTENT rather than
#    tracked-ness.
#  * **EVERY ARM READS *WHICH* ASSERTIONS WENT RED**, not only that the check failed. "The check
#    failed" and "the check saw what I broke" are different statements and only the second is
#    coverage.
#  * **THERE IS A HANG ARM AND A DIE-BEFORE-SUMMARY ARM**, because a check that dies prints no
#    summary and reads as a SMALLER milestone rather than a red one, and a check that hangs prints
#    nothing at all.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

WORK="${M33_MUT_WORK:-$HOME/.cache/aztec-m33-mut}"
BACKUP="$WORK/backup"
MARKER="$WORK/.in-progress"
MANIFEST="$WORK/manifest.sha256"
LOG="$WORK/mutations.log"

FILES=(
  "browser/src/wallet/null_wallet.ts"
  "browser/src/wallet/port_connection_handler.ts"
  "browser/src/wallet/port_wallet_provider.ts"
  "browser/src/vendor/wallet_sdk/types.ts"
  "tools/run_wallet_arms.mjs"
  "WALLET-BOUNDARY.md"
)

if [ -f "$MARKER" ] && [ "${1:-}" != "--restore-previous" ]; then
  echo "REFUSING: $MARKER exists, so a previous run died with mutations live." >&2
  echo "Run with --restore-previous to restore from $BACKUP first." >&2
  exit 2
fi
if [ "${1:-}" = "--restore-previous" ]; then
  shift
  for f in "${FILES[@]}"; do
    [ -f "$BACKUP/$f" ] && cp "$BACKUP/$f" "$f"
  done
  rm -f "$MARKER"
  echo "restored from $BACKUP"
fi

mkdir -p "$WORK"
rm -rf "$BACKUP"
mkdir -p "$BACKUP"
: > "$MANIFEST"
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "missing subject: $f" >&2; exit 2; }
  mkdir -p "$BACKUP/$(dirname "$f")"
  cp "$f" "$BACKUP/$f"
  sha256sum "$f" >> "$MANIFEST"
done

restore_all() {
  for f in "${FILES[@]}"; do
    cp "$BACKUP/$f" "$f"
  done
  rm -f "$MARKER"
}

verify_restored() {
  if ! sha256sum -c --quiet "$MANIFEST" 2>/dev/null; then
    echo "!! THE RESTORE DID NOT REPRODUCE THE PRE-RUN CONTENT. Compare against $BACKUP." >&2
    return 1
  fi
  return 0
}

sub() { # <file> <from> <to>
  local f="$1" from="$2" to="$3"
  if ! grep -qF -- "$from" "$f"; then
    echo "MUTATION MISS in $f: '$from'" | tee -a "$LOG" >&2
    restore_all
    verify_restored || true
    echo "ABORTED: a substitution that does not apply must not be printed as an arm that behaved." >&2
    exit 3
  fi
  python3 - "$f" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
assert a in s
open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
}

# The mutation is asserted to be STILL THERE after the arm runs (M30's review's third state: a
# mutation silently undone and printed as the arm's result).
still_there() { # <file> <needle>
  grep -qF -- "$2" "$1"
}

rebuild() {
  direnv exec "$REPO" bash -c 'node browser/build.mjs' >> "$LOG" 2>&1
}

refresh_arms() { # <timeout-seconds>
  M33_ARMS_REFRESH=1 M33_ARMS_TIMEOUT="${1:-300}" \
    direnv exec "$REPO" bash -c "M33_ARMS_REFRESH=1 M33_ARMS_TIMEOUT=${1:-300} verification/$2.sh" \
    2>&1 | tee -a "$LOG"
}

run_check() { # <check> [env...]
  echo "--- $1" | tee -a "$LOG"
  ( cd "$REPO" && env "${@:2}" direnv exec "$REPO" bash -c "verification/$1.sh" ) 2>&1 | tee -a "$LOG"
}

arm_header() {
  echo "" | tee -a "$LOG"
  echo "=== $1" | tee -a "$LOG"
}

ARMS=("$@")
[ ${#ARMS[@]} -eq 0 ] && ARMS=(M1 M2 M3 M4 M5 M6 M7 M8)

: > "$LOG"
echo "M33 mutation matrix, $(date -Is)" | tee -a "$LOG"

for arm in "${ARMS[@]}"; do
  touch "$MARKER"
  case "$arm" in

    # ---------------------------------------------------------------------------------------
    M1) # The null wallet answers instead of refusing — the plausible default the seam exists to
        # refuse. Predicted: test_null_wallet_refuses_by_name goes red on RESOLVED.
      arm_header "M1 — a method returns a plausible default instead of refusing"
      sub browser/src/wallet/null_wallet.ts \
        '      return (..._args: unknown[]) => {
        refusals.push({ method: name, seq: seq++ });
        return Promise.reject(new WalletNotAttached(name, reason));
      };' \
        '      return (..._args: unknown[]) => {
        refusals.push({ method: name, seq: seq++ });
        return Promise.resolve(name === "getAccounts" ? [] : undefined);
      };'
      rebuild
      still_there browser/src/wallet/null_wallet.ts 'Promise.resolve(name === "getAccounts"' \
        || { echo "M1 UNDONE before the run" | tee -a "$LOG"; }
      M33_ARMS_REFRESH=1 run_check test_null_wallet_refuses_by_name M33_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M2) # The handler stops binding appId. Predicted: e2e_discovery_keyexchange_session §6 goes red
        # on the mismatch assertions and on the handler's refusal ledger.
      arm_header "M2 — the session stops binding appId (upstream's own weaker behaviour)"
      sub browser/src/wallet/port_connection_handler.ts \
        '    if (appId !== session.appId) {' \
        '    if (false && appId !== session.appId) {'
      rebuild
      still_there browser/src/wallet/port_connection_handler.ts 'if (false && appId !== session.appId)' \
        || { echo "M2 UNDONE before the run" | tee -a "$LOG"; }
      run_check e2e_discovery_keyexchange_session M33_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M3) # The provider stops checking walletId. Predicted: §7 goes red — the call SETTLES instead of
        # timing out, and the refusal ledger is empty.
      arm_header "M3 — the provider accepts a response from a wallet it did not discover"
      sub browser/src/wallet/port_wallet_provider.ts \
        '    if (response.walletId !== this.walletId) {' \
        '    if (false && response.walletId !== this.walletId) {'
      rebuild
      still_there browser/src/wallet/port_wallet_provider.ts 'if (false && response.walletId !== this.walletId)' \
        || { echo "M3 UNDONE before the run" | tee -a "$LOG"; }
      run_check e2e_discovery_keyexchange_session M33_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M4) # A message type's VALUE drifts in the vendored copy — the failure a NAME-only comparison
        # cannot see. Predicted: verify_wallet_protocol_is_upstreams goes red on the byte-identity
        # assertion AND on VALUE_DIFF, and NOT on MISSING.
      arm_header "M4 — one message type's wire value drifts from upstream's"
      sub browser/src/vendor/wallet_sdk/types.ts \
        "  PING = 'aztec-wallet-ping'," \
        "  PING = 'aztec-wallet-ping-but-ours',"
      rebuild
      still_there browser/src/vendor/wallet_sdk/types.ts 'aztec-wallet-ping-but-ours' \
        || { echo "M4 UNDONE before the run" | tee -a "$LOG"; }
      run_check verify_wallet_protocol_is_upstreams M33_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M5) # §8.4 stops crossing: the handler no longer records the manifest. Predicted:
        # e2e_discovery_keyexchange_session §4 goes red, and so does the protocol check's §6.
      arm_header "M5 — the wallet is no longer TOLD (the disclosure is not recorded)"
      sub browser/src/wallet/port_connection_handler.ts \
        '      if (manifest?.metadata) {
        this.disclosedApp = { ...manifest.metadata };
      }' \
        '      if (false && manifest?.metadata) {
        this.disclosedApp = { ...manifest!.metadata };
      }'
      rebuild
      still_there browser/src/wallet/port_connection_handler.ts 'if (false && manifest?.metadata)' \
        || { echo "M5 UNDONE before the run" | tee -a "$LOG"; }
      run_check e2e_discovery_keyexchange_session M33_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M6) # THE HANG. The wallet never announces itself AND the provider's bound is removed, so
        # `connect()` waits for ever. Predicted: the arm run is killed at its own bound and
        # `m33_require_arms` DIES with a named failure — 0 assertions, 1 failure, WITH a summary
        # line from the abnormal-exit trap.
      arm_header "M6 — THE HANG: no WALLET_READY, and the handshake bound removed"
      sub browser/src/wallet/port_connection_handler.ts \
        "    this.port.postMessage({ type: WalletMessageType.WALLET_READY });" \
        "    void WalletMessageType.WALLET_READY;"
      sub browser/src/wallet/port_wallet_provider.ts \
        '      const timer = setTimeout(() => {' \
        '      const timer = setTimeout(() => { if (1) return;'
      rebuild
      still_there browser/src/wallet/port_wallet_provider.ts 'setTimeout(() => { if (1) return;' \
        || { echo "M6 UNDONE before the run" | tee -a "$LOG"; }
      run_check e2e_discovery_keyexchange_session M33_ARMS_REFRESH=1 M33_ARMS_TIMEOUT=25
      # WHICH BOUND FIRED IS PART OF THE ARM'S RESULT, not a detail. "The check failed" and "the
      # check saw what I broke" are different statements.
      echo "--- the arm run's own stderr (this is where the bound names itself):" | tee -a "$LOG"
      head -20 "${M33_WORK:-$HOME/.cache/aztec-m33-wallet}/wallet.stderr" 2>/dev/null | tee -a "$LOG"
      ;;

    # ---------------------------------------------------------------------------------------
    M7) # DIE BEFORE THE SUMMARY. The arm report is hollowed AFTER it is produced, so every field
        # the check reads is MISSING; `m33_absent` names them all in one assertion and dies.
        # Predicted: a SMALL assertion count, 1 failure, and a SUMMARY LINE from the trap — and the
        # arm asserts the hollow is STILL THERE after the run, because M30's review found an arm
        # whose mutation the harness silently re-measured away.
      arm_header "M7 — die before the summary: the arm report is hollow"
      ARMS_FILE="${M33_WORK:-$HOME/.cache/aztec-m33-wallet}/wallet.json"
      # BRING THE CACHE'S PRODUCER CURRENT BEFORE MUTATING THE CACHE. M30's review's finding, and
      # this arm reproduced it on its first run: the PRECEDING arm's `restore_all` leaves the
      # sources newer than `browser/dist`, so `m27_require_bundle` rebuilds, the fresh bundle is
      # newer than the report this arm just hollowed, and `m33_require_arms` helpfully re-measures
      # over the hollow — printing 63/0 with nothing saying the mutation had been undone. So the
      # bundle is rebuilt FIRST, then the arms, then the hollow.
      rebuild
      direnv exec "$REPO" bash -c 'node tools/run_wallet_arms.mjs "$HOME/.cache/aztec-m33-wallet" > "$HOME/.cache/aztec-m33-wallet/wallet.json"' >> "$LOG" 2>&1
      python3 - "$ARMS_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["arms"] = {"handshake": {}}
json.dump(d, open(sys.argv[1], "w"))
PY
      touch "$ARMS_FILE"
      run_check e2e_discovery_keyexchange_session
      if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d["arms"] == {"handshake": {}} else 1)' "$ARMS_FILE"; then
        echo "M7 held: the report is still hollow after the run" | tee -a "$LOG"
      else
        # AND IT FAILS RATHER THAN PRINTING A RESULT. `CAMPAIGN-BRIEF.md`'s remedy for M30's third
        # state is "assert after the run that the mutation is STILL THERE — if it is not, FAIL
        # naming the cause instead of printing a result". The first version diagnosed and carried
        # on, so the log carried the arm's green number and the diagnosis side by side. Measured by
        # M33's review, which reproduced the race deliberately: with the bundle touched newer than
        # the hollowed report the check reports 67 assertions, 0 failures, exit 0 — a fully green
        # arm over a mutation that had been undone. A reader skimming the matrix sees the 67.
        echo "M7 DID NOT HOLD: the report was re-measured under the arm" | tee -a "$LOG"
        echo "   The result printed above is NOT this arm's result: the mutation was undone before" \
             "the check read it. Do not record it." | tee -a "$LOG" >&2
        restore_all
        verify_restored || true
        exit 5
      fi
      M33_ARMS_REFRESH=1 direnv exec "$REPO" bash -c 'M33_ARMS_REFRESH=1 verification/verify_wallet_protocol_is_upstreams.sh' >> "$LOG" 2>&1
      ;;

    # ---------------------------------------------------------------------------------------
    M8) # A DOCUMENT FIGURE ROTS. Predicted: verify_provider_half_dd9_clean §9 goes red naming the
        # figure and its subject line — the instrument M27's review had to write after eleven
        # figures rotted unnoticed.
      arm_header "M8 — a figure in WALLET-BOUNDARY.md is made stale"
      sub WALLET-BOUNDARY.md \
        '| provider half (`extension/provider`, `iframe/provider`, `types`, `manager`, `crypto`) | **408** | **47,330** | 9 | **no** |' \
        '| provider half (`extension/provider`, `iframe/provider`, `types`, `manager`, `crypto`) | **407** | **47,330** | 9 | **no** |'
      still_there WALLET-BOUNDARY.md '| **407** |' \
        || { echo "M8 UNDONE before the run" | tee -a "$LOG"; }
      run_check verify_provider_half_dd9_clean
      ;;

    *)
      echo "unknown arm: $arm" >&2
      restore_all
      exit 2
      ;;
  esac

  restore_all
  verify_restored || exit 4
done

rebuild
echo "" | tee -a "$LOG"
echo "restored and rebuilt; the matrix is in $LOG" | tee -a "$LOG"
