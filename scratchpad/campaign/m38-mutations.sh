#!/usr/bin/env bash
# m38-mutations.sh — M38's mutation matrix.
#
#   scratchpad/campaign/m38-mutations.sh [arm...]        (default: all)
#   scratchpad/campaign/m38-mutations.sh --restore-previous [arm...]
#   scratchpad/campaign/m38-mutations.sh --demo-still-there
#
# The skeleton is `closeout-mutations.sh`'s, deliberately: the marker before the backup, the sha256
# manifest, `sub` aborting on a MISS, `still_there` exiting 5, and every arm reading WHICH assertions
# went red. Each of those is a defect this campaign has already paid for and none of them is worth a
# second implementation.
#
# THE SUBJECTS ARE THE PROBE, THE CLASSIFIER, THE ARM RUNNER AND THE TRACER'S OWN TEST. Mutating the
# probe or the runner invalidates the arms (`m38_arms_newer_inputs` watches both), so those arms
# re-run them — which is the point: the mutation has to reach the ACVM, not just the JSON.
#
# M38_WORK IS THE HARNESS'S OWN, so a mutated arm run never overwrites the arms the real checks read.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

WORK="${M38_MUT_WORK:-$HOME/.cache/aztec-m38-mut}"
BACKUP="$WORK/backup"
MARKER="$WORK/.in-progress"
MANIFEST="$WORK/manifest.sha256"
LOG="$WORK/mutations.log"

export M38_WORK="$WORK/arms"

NOIR="$(cd "$REPO/.." && pwd)/noir"

# EVERY FILE ANY ARM MUTATES IS HERE, INCLUDING A CHECK. The first draft listed the four subjects
# and not `verify_foreign_call_executor_is_injectable.sh`, which arm M5 mutates — so M5's
# substitution survived the run, in the working tree, because `restore_all` only restores what the
# backup holds. That is "a mutated artefact outlived its restored source" with the arrow reversed,
# and the harness's own dirty-subject refusal is what surfaced it on the next run.
FILES=(
  "verification/m38_private_trace_probe.rs"
  "verification/_m38_oracle_synchrony.py"
  "verification/lib_m38_private_trace.sh"
  "verification/verify_foreign_call_executor_is_injectable.sh"
  "tools/run_m38_trace_arms.mjs"
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

mkdir -p "$WORK" "$M38_WORK"

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
  ( cd "$REPO" && env M38_WORK="$M38_WORK" M38_ARMS_REFRESH="${M38_ARMS_REFRESH:-1}" \
      "${EXTRA_ENV[@]}" direnv exec "$REPO" bash -c \
      "TMPDIR=\$HOME/.cache/aztec-verification-scratch verification/$1.sh" ) 2>&1 | tee -a "$LOG"
}
EXTRA_ENV=()

if [ "${1:-}" = "--demo-still-there" ]; then
  : > "$LOG"
  echo "=== DEMO — still_there over a mutation that was silently undone" | tee -a "$LOG"
  sub verification/_m38_oracle_synchrony.py \
    'def method_name_of(' \
    'def method_name_of(  # ZZZ_M38_DEMO'
  cp "$BACKUP/verification/_m38_oracle_synchrony.py" verification/_m38_oracle_synchrony.py
  still_there verification/_m38_oracle_synchrony.py 'ZZZ_M38_DEMO' DEMO
  echo "UNREACHABLE: still_there returned instead of exiting 5" >&2
  exit 9
fi

ARMS=("$@")
[ ${#ARMS[@]} -eq 0 ] && ARMS=(M1 M2 M3 M4 M5 M6 M7 M8)

: > "$LOG"
echo "M38 mutation matrix, $(date -Is)" | tee -a "$LOG"

for arm in "${ARMS[@]}"; do
  touch "$MARKER"
  EXTRA_ENV=()
  case "$arm" in

    # ---------------------------------------------------------------------------------------
    M1) # THE FORBIDDEN FAILURE, MADE REAL. The executor pads a call the recording did not answer
        # with an EMPTY result instead of refusing — the exact fabricated-answer-of-length-zero this
        # milestone exists to prevent, and the one that SUCCEEDS for a circuit expecting no fields.
        # Predicted: `test_unserved_private_oracle_refuses_by_name` §4 goes red — the `transfer`
        # arm stops refusing `aztec_utl_getNotes`, and the browser/native agreement with it.
      echo "" | tee -a "$LOG"; echo "=== M1 — an unanswered call is padded instead of refused" | tee -a "$LOG"
      sub verification/m38_private_trace_probe.rs \
        'if entry.seq >= self.served_calls {' \
        'if false && entry.seq >= self.served_calls { // ZZZ_M38_M1'
      still_there verification/m38_private_trace_probe.rs 'ZZZ_M38_M1' M1
      run_check test_unserved_private_oracle_refuses_by_name
      ;;

    # ---------------------------------------------------------------------------------------
    M2) # THE TAPE IS MATCHED BY NAME ALONE, NOT BY INPUTS. `isExecutionInRevertiblePhase` is called
        # twice in one frame, so an executor that stopped comparing inputs would answer the second
        # with whatever the tape holds — invisible on this frame and catastrophic on one where the
        # two calls differ. Predicted: the truncate arm no longer refuses at the right place.
      echo "" | tee -a "$LOG"; echo "=== M2 — the executor stops comparing the recorded inputs" | tee -a "$LOG"
      sub verification/m38_private_trace_probe.rs \
        'if observed != recorded {' \
        'if false && observed != recorded { // ZZZ_M38_M2'
      still_there verification/m38_private_trace_probe.rs 'ZZZ_M38_M2' M2
      run_check test_unserved_private_oracle_refuses_by_name
      ;;

    # ---------------------------------------------------------------------------------------
    M3) # THE CLASSIFIER TREATS `async` AS SYNCHRONOUS. This is the enumeration's whole content: an
        # `async` handler cannot answer a synchronous Rust call, and a classifier that forgot the
        # declaration would report a boundary that is not there. Predicted:
        # `verify_private_oracle_synchrony_enumerated` §3 and §4 go red — the refusing frame stops
        # producing a `host-round-trip`, and `isNullifierPending` leaves the async set.
      echo "" | tee -a "$LOG"; echo "=== M3 — the classifier ignores the async declaration" | tee -a "$LOG"
      sub verification/_m38_oracle_synchrony.py \
        '                    if is_async or awaits:' \
        '                    if False and (is_async or awaits):  # ZZZ_M38_M3'
      still_there verification/_m38_oracle_synchrony.py 'ZZZ_M38_M3' M3
      run_check verify_private_oracle_synchrony_enumerated
      ;;

    # ---------------------------------------------------------------------------------------
    M4) # THE STEPS ARE FABRICATED AT THE WRITE SITE. M29's own shape, applied to the private half:
        # the recorder is handed a synthesised path instead of the artifact's, so the container's
        # steps are no longer the execution's. The probe's REPORT is untouched, so a check that read
        # its step count out of that report would stay green.
        # Predicted: `e2e_private_function_steps_into_ct_container` §3's "the first one is the
        # oracle the frame calls first", and §6's path predicate.
      echo "" | tee -a "$LOG"; echo "=== M4 — the container's step paths are synthesised" | tee -a "$LOG"
      # THE NEEDLE IS ONE LINE, AND THE FIRST DRAFT'S WAS TWO. `grep -F` treats a multi-line
      # pattern as an ALTERNATION, so the guard matched on the first line while python's
      # `assert a in s` did not — and `still_there` caught it, exited 5, and restored. That is the
      # "a substitution that never applied, printed as the arm's result" defect prevented, arriving
      # through rustfmt having wrapped the line since the needle was written.
      sub verification/m38_private_trace_probe.rs \
        'self.inner.register_step_with_column(path, line, column);' \
        'self.inner.register_step_with_column(std::path::Path::new("synthesised/main.nr"), line, column); // ZZZ_M38_M4'
      still_there verification/m38_private_trace_probe.rs 'ZZZ_M38_M4' M4
      run_check e2e_private_function_steps_into_ct_container
      ;;

    # ---------------------------------------------------------------------------------------
    M5) # THE SEAM'S DEFAULT BRANCH IS NOT THE DEFAULT ANY MORE. The subject is in `noir`, so this
        # arm edits the CHECK's view of it rather than the tracer: it points the runner at a
        # non-existent test name, which is what a suite that silently lost a test looks like.
        # Predicted: `verify_foreign_call_executor_is_injectable` §3 goes red on the run's own
        # reported names rather than on its exit status.
      echo "" | tee -a "$LOG"; echo "=== M5 — the executor suite reports fewer tests than it declares" | tee -a "$LOG"
      sub verification/verify_foreign_call_executor_is_injectable.sh \
        'cargo test -p noir_tracer --test test_foreign_call_executor -- --test-threads=1' \
        'cargo test -p noir_tracer --test test_foreign_call_executor -- --test-threads=1 the_default_executor # ZZZ_M38_M5'
      still_there verification/verify_foreign_call_executor_is_injectable.sh 'ZZZ_M38_M5' M5
      run_check verify_foreign_call_executor_is_injectable
      ;;

    # ---------------------------------------------------------------------------------------
    M6) # THE HANG. The arm runner waits on a timer that never fires, and the bound is cut to 20s.
        # rc MUST be 124: `await new Promise(() => {})` exits 13 on node's unsettled top-level
        # await, and an `await` in a sync function is a parse error at rc 1. Both are
        # die-before-summary arms wearing a hang's label.
        # Predicted: `0 assertion(s), 1 failure(s)` with the bound NAMED and a summary line at
        # column 0.
      echo "" | tee -a "$LOG"; echo "=== M6 — the arm run HANGS (bound cut to 20s)" | tee -a "$LOG"
      sub tools/run_m38_trace_arms.mjs \
        "const arms = {};" \
        "const arms = {}; // ZZZ_M38_M6
await new Promise((r) => setTimeout(r, 1e9));"
      still_there tools/run_m38_trace_arms.mjs 'ZZZ_M38_M6' M6
      EXTRA_ENV=(M38_ARMS_TIMEOUT=20)
      run_check e2e_private_function_steps_into_ct_container
      ;;

    # ---------------------------------------------------------------------------------------
    M7) # DIE BEFORE SUMMARY. The arm runner writes a truncated report, so the check's precondition
        # refuses. Predicted: `0 assertion(s), 1 failure(s)` — the abnormal-exit trap turning a
        # `die` into a RED milestone rather than a smaller one.
      echo "" | tee -a "$LOG"; echo "=== M7 — the arm report is truncated" | tee -a "$LOG"
      sub tools/run_m38_trace_arms.mjs \
        "process.stdout.write(" \
        "process.stdout.write('{\"truncat' + String.fromCharCode(0)); // ZZZ_M38_M7
process.exit(0);
process.stdout.write("
      still_there tools/run_m38_trace_arms.mjs 'ZZZ_M38_M7' M7
      run_check test_unserved_private_oracle_refuses_by_name
      ;;

    # ---------------------------------------------------------------------------------------
    M8) # THE STALENESS PREDICATE STOPS WATCHING ITS OWN PRODUCER. `m38_arms_newer_inputs` watches
        # the probe binary and the tape; without the tape a report measured against an OLD recording
        # is believed. This arm is expected to be a SURVIVOR under `M38_ARMS_REFRESH=1`, which is
        # how the other arms run — recorded rather than dropped, because a green arm in a harness
        # whose contract is "every arm red" reads as a defect in the harness.
      echo "" | tee -a "$LOG"; echo "=== M8 — the staleness predicate stops watching the tape (EXPECTED SURVIVOR under REFRESH=1)" | tee -a "$LOG"
      sub verification/lib_m38_private_trace.sh \
        '  find "$M38_TAPE_SOURCE" -newer "$M38_ARMS" -print -quit 2>/dev/null || true' \
        '  : # ZZZ_M38_M8'
      still_there verification/lib_m38_private_trace.sh 'ZZZ_M38_M8' M8
      M38_ARMS_REFRESH=0 run_check e2e_private_function_steps_into_ct_container
      ;;

    *) echo "unknown arm $arm" >&2; restore_all; exit 2 ;;
  esac
  restore_all
  verify_restored || exit 6
done

echo "" | tee -a "$LOG"
echo "HARNESS: restored; manifest verified" | tee -a "$LOG"
grep -c 'MUTATION MISS' "$LOG" >/dev/null 2>&1 && true
echo "log: $LOG"
