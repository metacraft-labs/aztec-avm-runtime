#!/usr/bin/env bash
# m34-mutations.sh — M34's mutation matrix.
#
#   scratchpad/campaign/m34-mutations.sh [arm...]        (default: all)
#
# ===========================================================================================
# WHAT THIS HARNESS INHERITS, AND THE ONE THING IT MAKES STRICTER
# ===========================================================================================
#
# It is M33's harness with M34's arms. Everything it already knew:
#
#  * **A SUBSTITUTION THAT DOES NOT FIND ITS NEEDLE ABORTS THE RUN.** M32's arm M2 printed
#    `MUTATION MISS` and *returned*; the harness ran without `-e`, so the arm rebuilt, ran the
#    check, and reported the one failure it had predicted — produced by a SECOND substitution that
#    mutated only the CONTROL. Recorded as "the most precise arm in the matrix" over a subject it
#    had never touched.
#  * **THE BACKUP IS WIPED AND RE-TAKEN EVERY RUN**, and an in-progress marker refuses a run started
#    over a tree an earlier session left mutated.
#  * **THE BACKUP'S OWN TREE IS PINNED BY CONTENT** — a sha256 manifest taken before the first
#    mutation and verified after the last restore — because M34's files are uncommitted by design
#    and a `git status` comparison against HEAD cannot see them.
#  * **EVERY ARM READS *WHICH* ASSERTIONS WENT RED.** "The check failed" and "the check saw what I
#    broke" are different statements and only the second is coverage.
#
# **AND THE ONE THING THAT IS STRICTER HERE.** M33's `still_there` guard *diagnosed* an undone
# mutation and let the run continue; M33's review measured the state it exists for — the arm
# printing `67 / 0, exit 0` beside the diagnosis — and recorded that as one notch weaker than
# `CAMPAIGN-BRIEF.md` asks, which is *"fail naming the cause instead of printing a result"*. It is
# the FIFTH appearance of that family. Here `still_there` failing **restores, verifies and exits 5**.
# An arm that cannot be applied produces no number at all.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

WORK="${M34_MUT_WORK:-$HOME/.cache/aztec-m34-mut}"
BACKUP="$WORK/backup"
MARKER="$WORK/.in-progress"
MANIFEST="$WORK/manifest.sha256"
LOG="$WORK/mutations.log"
ARMS_JSON="${M34_WORK:-$HOME/.cache/aztec-m34-wallet}/wallet-transfer.json"

FILES=(
  "browser/src/wallet/dev_wallet.ts"
  "browser/src/wallet/dev_keys.ts"
  "browser/demo/wallet_main.ts"
  "DEV-WALLET.md"
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

# THE MUTATION IS ASSERTED TO BE STILL THERE, AND ITS ABSENCE ENDS THE RUN. See the header.
still_there() { # <file-or-report> <needle> <arm>
  if ! grep -qF -- "$2" "$1"; then
    echo "!! $3 DID NOT HOLD: the mutation is no longer in $1." | tee -a "$LOG" >&2
    echo "   An arm whose mutation was undone must FAIL, not print a result beside a diagnosis." >&2
    restore_all
    verify_restored || true
    exit 5
  fi
}

rebuild() {
  direnv exec "$REPO" bash -c 'node browser/build.mjs' >> "$LOG" 2>&1
}

run_check() { # <check> [env...]
  echo "--- $1" | tee -a "$LOG"
  ( cd "$REPO" && env "${@:2}" direnv exec "$REPO" bash -c "TMPDIR=\$HOME/.cache/aztec-verification-scratch verification/$1.sh" ) 2>&1 | tee -a "$LOG"
}

arm_header() {
  echo "" | tee -a "$LOG"
  echo "=== $1" | tee -a "$LOG"
}

ARMS=("$@")
[ ${#ARMS[@]} -eq 0 ] && ARMS=(M1 M2 M3 M4 M5 M6 M7 M8 M9)

: > "$LOG"
echo "M34 mutation matrix, $(date -Is)" | tee -a "$LOG"

for arm in "${ARMS[@]}"; do
  touch "$MARKER"
  case "$arm" in

    # ---------------------------------------------------------------------------------------
    M1) # The wallet answers instead of refusing — the plausible default the whole campaign
        # refuses, and it matters most in a wallet because a fabricated note LOOKS valid.
        # Predicted: e2e_wallet_public_transfer §6 reports RESOLVED for every refused method.
      arm_header "M1 — an unserved method returns a plausible default instead of refusing"
      sub browser/src/wallet/dev_wallet.ts \
        '        record(name, '"'"'refused'"'"', reason);
        return Promise.reject(new DevWalletRefused(name, reason));' \
        '        record(name, '"'"'refused'"'"', reason);
        return Promise.resolve(undefined);'
      rebuild
      still_there browser/src/wallet/dev_wallet.ts 'return Promise.resolve(undefined);' M1
      run_check e2e_wallet_public_transfer M34_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M2) # The signing decision stops being recorded. The wallet still authorizes; nothing says so.
        # Predicted: e2e §4 loses `authorized`, and the trace check loses the record AND its
        # control's set difference.
      arm_header "M2 — the wallet authorizes but does not RECORD the signing decision"
      sub browser/src/wallet/dev_wallet.ts \
        "      record(
        'sendTx',
        'authorized'," \
        "      void 0 && record(
        'sendTx',
        'authorized',"
      rebuild
      still_there browser/src/wallet/dev_wallet.ts "void 0 && record(" M2
      run_check verify_wallet_decisions_appear_in_trace M34_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M3) # AMBIENT RANDOMNESS, in a spelling the SOURCE SCAN does not enumerate. This is the arm
        # that says the behavioural half of test_wallet_keys_deterministic is load-bearing: the
        # structural half lists seven spellings and `Date.now` is not one of them, deliberately, so
        # only the cross-process comparison can see this.
      arm_header "M3 — the derivation reads an ambient value the spelling census does not name"
      sub browser/src/wallet/dev_keys.ts \
        '    const secret = await poseidon2HashWithSeparator([s, new Fr(index)], DEV_ACCOUNT_SEPARATOR);' \
        '    const secret = await poseidon2HashWithSeparator([s, new Fr(index + Date.now())], DEV_ACCOUNT_SEPARATOR);'
      rebuild
      still_there browser/src/wallet/dev_keys.ts 'index + Date.now()' M3
      run_check test_wallet_keys_deterministic M34_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M4) # The decisions stop reaching the CONTAINER while still existing in the wallet's report.
        # This is the arm that says the trace check reads the artefact and not the producer's
        # report about itself — M29's review's rule, and the one M34's fifth deliverable rests on.
      arm_header "M4 — the decisions stay in the wallet's report and never reach the container"
      sub browser/demo/wallet_main.ts \
        '      ...decisions.map(d => ({ metadata: WALLET_DECISION_METADATA, content: renderWalletDecision(d) })),' \
        '      ...[].map(d => ({ metadata: WALLET_DECISION_METADATA, content: renderWalletDecision(d) })),'
      rebuild
      still_there browser/demo/wallet_main.ts '...[].map(d => ({ metadata: WALLET_DECISION_METADATA' M4
      run_check verify_wallet_decisions_appear_in_trace M34_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M5) # THE LEDGER SAYS THE WALLET REGISTERED THE CLASS AND THE NODE'S OWN COUNT SAYS IT DID NOT.
        # Predicted: test_deployment_through_wallet §1's `registered=1`.
        #
        # THE FIRST VERSION OF THIS ARM WAS THE WRONG SHAPE AND THE RULE IS THE BRIEF'S OWN. It
        # skipped the host call entirely (`const registered = 1 - 1;`), which means the class never
        # reaches the module, the transaction cannot execute, the ARM RUN exits 1 and the check dies
        # at `m34_require_arms` — `0 assertion(s), 1 failure(s)`, the die-before-summary path
        # working, and *not one assertion of the section this arm was written for*. "The check
        # failed" and "the check saw what I broke" are different statements. So the write still
        # happens and only the RECORD lies, which is also the more dangerous defect of the two.
      arm_header "M5 — the wallet registers the class and records that it did not"
      sub browser/src/wallet/dev_wallet.ts \
        '        `artifact=${name} classId=${contractClass.id.toString()} registered=${registered} `' \
        '        `artifact=${name} classId=${contractClass.id.toString()} registered=0 `'
      rebuild
      still_there browser/src/wallet/dev_wallet.ts 'registered=0 `' M5
      run_check test_deployment_through_wallet M34_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M6) # The direct store write stops being LABELLED. It still works — which is exactly the
        # arrangement the deliverable forbids: "not a silent alternative".
      arm_header "M6 — the dev shortcut still works and stops being named a shortcut"
      sub browser/demo/wallet_main.ts \
        "  say('[DEV SHORTCUT] inserted the contract-address nullifier directly into the nullifier tree');" \
        "  say('inserted the contract-address nullifier directly into the nullifier tree');"
      sub browser/demo/wallet_main.ts \
        "  say('[DEV SHORTCUT] inserted the public initialization nullifier directly');" \
        "  say('inserted the public initialization nullifier directly');"
      rebuild
      still_there browser/demo/wallet_main.ts "say('inserted the public initialization nullifier directly');" M6
      run_check test_deployment_through_wallet M34_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M7) # THE HANG, BOUNDED AND NAMED. The wallet never announces readiness, so the provider's
        # first wait runs out. The point is not that it fails: it is that it fails INSIDE A BOUND
        # with the STEP NAMED, rather than sitting at zero bytes of output while a sweep queues
        # behind it — M23's review's finding, which a trap cannot reach because a process that
        # never exits has no exit.
      arm_header "M7 — THE HANG: the wallet never posts WALLET_READY"
      sub browser/demo/wallet_main.ts \
        '  handler.start();
  const provider = new PortWalletProvider(port1, { chainInfo: { chainId: 1, version: 1 } });' \
        '  void handler;
  const provider = new PortWalletProvider(port1, { chainInfo: { chainId: 1, version: 1 } });'
      rebuild
      still_there browser/demo/wallet_main.ts '  void handler;' M7
      run_check e2e_wallet_public_transfer M34_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M8) # DIE BEFORE THE SUMMARY. The arm report is hollowed, so every field the check reads is
        # absent. `m34_absent` names them all in ONE assertion and dies; the abnormal-exit trap
        # prints a summary line, so the milestone reads RED rather than SMALLER.
        #
        # THE ORDERING IS THE WHOLE ARM. M30's review's third mutation state is "a mutation
        # silently undone and printed as the arm's result": the bundle must be brought CURRENT
        # before the cache is hollowed, or the first check rebuilds, the fresh bundle is newer than
        # the hollow, and the harness re-measures over it.
      arm_header "M8 — DIE BEFORE THE SUMMARY: the arm report is hollowed"
      rebuild
      sleep 1
      python3 - "$ARMS_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['arms'] = {'transfer': {}, 'declined': {}, 'refusals': {}, 'keys': {},
             'record': {}, 'suppressed': {}, 'shortcut': {}}
json.dump(d, open(sys.argv[1], 'w'), indent=2)
PY
      touch "$ARMS_JSON"
      still_there "$ARMS_JSON" '"transfer": {}' M8
      run_check e2e_wallet_public_transfer
      still_there "$ARMS_JSON" '"transfer": {}' M8
      echo "M8 held: the hollow survived the run" | tee -a "$LOG"
      ;;

    # ---------------------------------------------------------------------------------------
    M9) # A figure in the write-up is made stale. Predicted: e2e §8 names the figure AND the row.
      arm_header "M9 — a figure in DEV-WALLET.md is made stale"
      sub DEV-WALLET.md \
        '| executed AVM steps | **516** |' \
        '| executed AVM steps | **515** |'
      still_there DEV-WALLET.md '| executed AVM steps | **515** |' M9
      run_check e2e_wallet_public_transfer
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
M34_ARMS_REFRESH=1 direnv exec "$REPO" bash -c \
  'TMPDIR=$HOME/.cache/aztec-verification-scratch M34_ARMS_REFRESH=1 verification/e2e_wallet_public_transfer.sh' \
  >> "$LOG" 2>&1
echo "" | tee -a "$LOG"
echo "restored, rebuilt and the arms re-measured; the matrix is in $LOG" | tee -a "$LOG"
