#!/usr/bin/env bash
# m39-mutations.sh — M39's mutation matrix.
#
#   scratchpad/campaign/m39-mutations.sh [arm...]        (default: all)
#   scratchpad/campaign/m39-mutations.sh --restore-previous [arm...]
#   scratchpad/campaign/m39-mutations.sh --demo-still-there
#
# The skeleton is M38's, deliberately: the marker written BEFORE the backup, the sha256 manifest,
# `sub` aborting on a MISS, `still_there` exiting 5, and every arm reading WHICH assertions went red.
# Each of those is a defect this campaign has already paid for and none is worth a second
# implementation.
#
# THE SUBJECTS ARE THE HANDLER, THE EXECUTOR, THE PROBE, THE TRACE RUNNER AND THE LIBRARY. Mutating
# the probe or the runner invalidates the trace arms (`m39_trace_newer_inputs` watches both), and
# mutating the handler or the executor invalidates the BROWSER arms — so those arms re-run, which is
# the point: a mutation has to reach the ACVM, not just the JSON.
#
# `M39_TRACE_WORK` IS THE HARNESS'S OWN, so a mutated run never overwrites what the real checks read.
# `M39_WORK` is NOT: the browser arms are expensive and the arms that mutate the handler set
# `M39_ARMS_REFRESH=1` explicitly, which is what makes the mutation reach the page.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

WORK="${M39_MUT_WORK:-$HOME/.cache/aztec-m39-mut}"
BACKUP="$WORK/backup"
MARKER="$WORK/.in-progress"
MANIFEST="$WORK/manifest.sha256"
LOG="$WORK/mutations.log"

export M39_TRACE_WORK="$WORK/arms"
export M39_WORK="${M39_WORK:-$HOME/.cache/aztec-m39-nested}"

NOIR="$(cd "$REPO/.." && pwd)/noir"

# EVERY FILE ANY ARM MUTATES IS HERE, INCLUDING A CHECK. The first draft listed the four subjects
# and not `verify_foreign_call_executor_is_injectable.sh`, which arm M5 mutates — so M5's
# substitution survived the run, in the working tree, because `restore_all` only restores what the
# backup holds. That is "a mutated artefact outlived its restored source" with the arrow reversed,
# and the harness's own dirty-subject refusal is what surfaced it on the next run.
# EVERY FILE ANY ARM MUTATES IS HERE, INCLUDING THE ONES ARMS EDIT ONLY INCIDENTALLY. M38's own
# harness shipped with one subject missing from this list and that arm's substitution survived the
# run in the working tree, because `restore_all` restores only what the backup holds.
FILES=(
  "browser/src/wallet/private_oracles.ts"
  "browser/src/wallet/private_execution.ts"
  "verification/m38_private_trace_probe.rs"
  "verification/lib_m39_nested.sh"
  "tools/run_m39_trace_arms.mjs"
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

mkdir -p "$WORK" "$M39_TRACE_WORK"

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "missing subject: $f" >&2; exit 2; }
done
DIRTY="$(git status --porcelain -- "${FILES[@]}" | grep -v '^??' || true)"
if [ -n "$DIRTY" ]; then
  echo "REFUSING: a subject has uncommitted changes, so the backup would freeze them:" >&2
  echo "$DIRTY" >&2
  exit 2
fi

touch "$MARKER"
rm -rf "$BACKUP"
mkdir -p "$BACKUP"
: > "$MANIFEST"
for f in "${FILES[@]}"; do
  mkdir -p "$BACKUP/$(dirname "$f")"
  cp "$f" "$BACKUP/$f"
  sha256sum "$f" >> "$MANIFEST"
done

restore_all() {
  for f in "${FILES[@]}"; do cp "$BACKUP/$f" "$f"; done
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
    restore_all; verify_restored || true
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

still_there() { # <file> <needle> <arm>
  if ! grep -qF -- "$2" "$1"; then
    echo "!! $3 DID NOT HOLD: the mutation is no longer in $1." | tee -a "$LOG" >&2
    restore_all; verify_restored || true
    exit 5
  fi
}

run_check() { # <check>
  echo "--- $1" | tee -a "$LOG"
  ( cd "$REPO" && env M39_TRACE_WORK="$M39_TRACE_WORK" M39_TRACE_REFRESH="${M39_TRACE_REFRESH:-1}" \
      "${EXTRA_ENV[@]}" direnv exec "$REPO" bash -c \
      "TMPDIR=\$HOME/.cache/aztec-verification-scratch verification/$1.sh" ) 2>&1 | tee -a "$LOG"
}
EXTRA_ENV=()


# A BROWSER-ARM MUTATION MUST INVALIDATE THE BROWSER ARMS, and the bundle must be rebuilt for it to
# reach the page at all. `m39_require_arms` watches `browser/dist`, not `browser/src` — the bundle
# is the artefact — so a handler edit that is not rebuilt is a mutation that never applied, which is
# the fourth and worst state on this campaign's list.
rebuild_bundle() {
  echo "--- rebuilding the browser bundle so the mutation reaches the page" | tee -a "$LOG"
  ( cd "$REPO" && direnv exec "$REPO" node browser/build.mjs ) >/dev/null 2>&1 \
    || { echo "!! the bundle build FAILED under the mutation" | tee -a "$LOG"; }
}

if [ "${1:-}" = "--demo-still-there" ]; then
  : > "$LOG"
  echo "=== DEMO — still_there over a mutation that was silently undone" | tee -a "$LOG"
  sub verification/lib_m39_nested.sh \
    'm39_arm() {' \
    'm39_arm() {  # ZZZ_M39_DEMO'
  cp "$BACKUP/verification/lib_m39_nested.sh" verification/lib_m39_nested.sh
  still_there verification/lib_m39_nested.sh 'ZZZ_M39_DEMO' DEMO
  echo "UNREACHABLE: still_there returned instead of exiting 5" >&2
  exit 9
fi

ARMS=("$@")
[ ${#ARMS[@]} -eq 0 ] && ARMS=(N1 N2 N3 N4 N5 N6 N7 N8)

: > "$LOG"
echo "M39 mutation matrix, $(date -Is)" | tee -a "$LOG"

for arm in "${ARMS[@]}"; do
  touch "$MARKER"
  EXTRA_ENV=()
  case "$arm" in

    # ---------------------------------------------------------------------------------------
    N1) # THE EXECUTION CACHE GOES BACK TO BEING PER FRAME. This is the enumeration's first finding
        # made real, and its whole point is WHERE it fails: not at the nested call but on the opcode
        # AFTER it, when the caller reads the callee's return back out of a cache that no longer has
        # it. Predicted: `test_nested_private_call_is_served` §2 and §3 go red — the transaction
        # stops executing and the cross-frame crossing disappears from the ledgers.
      echo "" | tee -a "$LOG"; echo "=== N1 — the execution cache is per frame again" | tee -a "$LOG"
      sub browser/src/wallet/private_oracles.ts \
        '  const executionCache = shared.executionCache;' \
        '  const executionCache = new Map<string, Fr[]>(); // ZZZ_M39_N1'
      still_there browser/src/wallet/private_oracles.ts 'ZZZ_M39_N1' N1
      rebuild_bundle
      EXTRA_ENV=(M39_ARMS_REFRESH=1 M39_WORK="$WORK/browser")
      run_check test_nested_private_call_is_served
      ;;

    # ---------------------------------------------------------------------------------------
    N2) # THE CHILD IS HANDED THE TRANSACTION'S ORIGIN AS ITS `msgSender` INSTEAD OF ITS CALLER.
        # Upstream's `deriveCallContext` passes THIS frame's contract; the origin would let any
        # contract impersonate the caller of the frame above it. It is invisible in every count —
        # the child still executes, the counters still chain — and visible only in the value the
        # child returns, because `Child.value` reads the CONTEXT. Predicted: §4's crossed-value
        # assertion, and nothing else.
      echo "" | tee -a "$LOG"; echo "=== N2 — the child's msgSender is the tx origin, not its caller" | tee -a "$LOG"
      sub browser/src/wallet/private_oracles.ts \
        '            msgSender: contract,' \
        '            msgSender: contractAddress, // ZZZ_M39_N2'
      still_there browser/src/wallet/private_oracles.ts 'ZZZ_M39_N2' N2
      rebuild_bundle
      EXTRA_ENV=(M39_ARMS_REFRESH=1 M39_WORK="$WORK/browser")
      run_check test_nested_private_call_is_served
      ;;

    # ---------------------------------------------------------------------------------------
    N3) # THE WIRE REGROUPING FIRES FOR EVERY CONTRACT, not only for one compiled against an older
        # minor. A shim that cannot say no is not a shim, it is the wire — and the arm that proves
        # its necessity would still pass, because the arm that DISABLES it is a separate option.
        # Predicted: §6's "the shim fired exactly once" pair, on the control arm's count.
      echo "" | tee -a "$LOG"; echo "=== N3 — the wire shim fires unconditionally" | tee -a "$LOG"
      sub browser/src/wallet/private_execution.ts \
        '    if (!older) {' \
        '    if (false && !older) { // ZZZ_M39_N3'
      still_there browser/src/wallet/private_execution.ts 'ZZZ_M39_N3' N3
      rebuild_bundle
      EXTRA_ENV=(M39_ARMS_REFRESH=1 M39_WORK="$WORK/browser")
      run_check test_nested_private_call_is_served
      ;;

    # ---------------------------------------------------------------------------------------
    N4) # THE SELECTOR GOES BACK TO INCLUDING THE CONTEXT PARAMETER. The defect that was wrong from
        # the first frame ever executed here. Predicted: §8's pair goes red, and so does the
        # BOTH-HALVES arm — because that fixture passes a selector one contract must find another
        # by, which is the only reason anybody noticed.
      echo "" | tee -a "$LOG"; echo "=== N4 — the selector includes the context parameter again" | tee -a "$LOG"
      sub browser/src/wallet/private_execution.ts \
        "  const withoutContext = declared[0]?.name === 'inputs' ? declared.slice(1) : declared;" \
        "  const withoutContext = declared; // ZZZ_M39_N4"
      still_there browser/src/wallet/private_execution.ts 'ZZZ_M39_N4' N4
      rebuild_bundle
      EXTRA_ENV=(M39_ARMS_REFRESH=1 M39_WORK="$WORK/browser")
      run_check test_nested_private_call_is_served
      ;;

    # ---------------------------------------------------------------------------------------
    N5) # THE REPLAY GUESSES THE WIRE KIND AGAIN. The defect that halted the first two-frame run,
        # put back at the write site rather than at the tape's: the recorded kind is ignored and the
        # length decides. Predicted: the container arm dies at its precondition, because the trace
        # arm run itself fails — which is the die-before-summary path, and the summary line at
        # column 0 is what says the check is RED rather than absent.
      echo "" | tee -a "$LOG"; echo "=== N5 — the replay guesses the wire kind from the slot length" | tee -a "$LOG"
      sub verification/m38_private_trace_probe.rs \
        '            let recorded_kind = entry.output_kinds.get(slot_index).map(String::as_str);' \
        '            let recorded_kind: Option<&str> = None; // ZZZ_M39_N5'
      still_there verification/m38_private_trace_probe.rs 'ZZZ_M39_N5' N5
      run_check e2e_transaction_steps_into_one_container
      ;;

    # ---------------------------------------------------------------------------------------
    N6) # THE FRAME BRACKET IS NEVER OPENED. The container keeps every step and loses the only thing
        # that distinguishes the two frames — which §6 of the write-up is about, because the two
        # frames' POSITION sets are identical. A check that asserted only step counts and columns
        # would stay green over this.
      echo "" | tee -a "$LOG"; echo "=== N6 — the nested frame's Call is never written" | tee -a "$LOG"
      sub verification/m38_private_trace_probe.rs \
        '    if frame_spec.depth > 0 {' \
        '    if false && frame_spec.depth > 0 { // ZZZ_M39_N6'
      still_there verification/m38_private_trace_probe.rs 'ZZZ_M39_N6' N6
      run_check e2e_transaction_steps_into_one_container
      ;;

    # ---------------------------------------------------------------------------------------
    N7) # THE ARM RUN HANGS. A trap fires on exit; a process that never exits has no exit — so the
        # bound is the only thing between a hang and a sweep that stops. The bound is cut to 20 s and
        # the runner is given a live timer, which is the ONLY shape that is a hang: a promise with no
        # pending handle exits 13 and an `await` in a sync function exits 1, and this campaign has
        # written both by accident. Predicted: `0 assertion(s), 1 failure(s)`, rc 124 or 137 inside
        # the check, with the bound NAMED and a summary line at column 0.
      echo "" | tee -a "$LOG"; echo "=== N7 — the trace arm run HANGS (bound cut to 20 s)" | tee -a "$LOG"
      sub tools/run_m39_trace_arms.mjs \
        'const arms = {};' \
        'await new Promise((r) => setTimeout(r, 1e9)); // ZZZ_M39_N7
const arms = {};'
      still_there tools/run_m39_trace_arms.mjs 'ZZZ_M39_N7' N7
      EXTRA_ENV=(M39_TRACE_TIMEOUT=20)
      run_check e2e_transaction_steps_into_one_container
      ;;

    # ---------------------------------------------------------------------------------------
    N8) # THE ARM REPORT IS TRUNCATED — a report that cannot be parsed at all, which is the second
        # of the three spellings of absence `m38_absent` knows and the one a guard that looked only
        # for a missing KEY passes over. Predicted: `0 assertion(s), 1 failure(s)` with the
        # abnormal-exit trap turning a `die` into a RED milestone rather than a smaller one.
      echo "" | tee -a "$LOG"; echo "=== N8 — the trace arm report is truncated" | tee -a "$LOG"
      sub tools/run_m39_trace_arms.mjs \
        "process.stdout.write(JSON.stringify(out, null, 2) + '\n');" \
        "process.stdout.write('{\"truncat' + String.fromCharCode(0)); // ZZZ_M39_N8
process.exit(0);"
      still_there tools/run_m39_trace_arms.mjs 'ZZZ_M39_N8' N8
      run_check e2e_transaction_steps_into_one_container
      ;;

    *) echo "unknown arm $arm" >&2; restore_all; exit 2 ;;
  esac
  restore_all
  verify_restored || exit 6
  # THE BUNDLE IS REBUILT AFTER A BROWSER ARM TOO. Restoring the SOURCE leaves the mutated BUNDLE on
  # disk, and `browser/dist` is what every later arm and every later check reads — "a mutated
  # artefact outlived its restored source", which is the first entry on this campaign's own list.
  case "$arm" in N1|N2|N3|N4) rebuild_bundle ;; esac
done

echo "" | tee -a "$LOG"
echo "HARNESS: restored; manifest verified" | tee -a "$LOG"
echo "log: $LOG"
