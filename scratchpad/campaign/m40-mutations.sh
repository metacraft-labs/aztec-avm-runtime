#!/usr/bin/env bash
# m40-mutations.sh — M40's mutation matrix.
#
#   scratchpad/campaign/m40-mutations.sh [arm...]        (default: all)
#   scratchpad/campaign/m40-mutations.sh --restore-previous [arm...]
#   scratchpad/campaign/m40-mutations.sh --demo-still-there
#
# The skeleton is M38's and M39's, deliberately: the marker written BEFORE the backup, the sha256
# manifest, `sub` aborting on a MISS, `still_there` exiting 5, and every arm reading WHICH assertions
# went red. Each is a defect this campaign has already paid for and none is worth a second
# implementation.
#
# THE SUBJECTS ARE THE PUBLIC HALF, THE CONTAINER WRITER, THE TRACER MODULE AND THE TWO DRIVERS.
# Mutating the browser sources invalidates nothing by itself — `m40_require_arms` watches
# `browser/dist`, not `browser/src`, because the bundle is the artefact — so every browser arm
# rebuilds. Mutating `ct-writer/src/lib.rs` needs `ct_writer.wasm` rebuilt for the same reason, and
# mutating `verification/m40_private_trace_wasm.rs` moves the tracer build script's own content
# stamp, so that one rebuilds itself.
#
# `M40_WORK` and `M40_TRACE_WORK` are the harness's own, so a mutated run never overwrites what the
# real checks read.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

WORK="${M40_MUT_WORK:-$HOME/.cache/aztec-m40-mut}"
BACKUP="$WORK/backup"
MARKER="$WORK/.in-progress"
MANIFEST="$WORK/manifest.sha256"
LOG="$WORK/mutations.log"

CT_WRITER_WASM="ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm"

# EVERY FILE ANY ARM MUTATES IS HERE. M38's harness shipped with one subject missing from this list
# and that arm's substitution survived the run in the working tree, because `restore_all` restores
# only what the backup holds.
FILES=(
  "browser/src/transaction_public_half.ts"
  "browser/src/private_half_container.ts"
  "ct-writer/src/lib.rs"
  "verification/m40_private_trace_wasm.rs"
  "tools/run_m40_transaction_arms.mjs"
  "tools/run_m40_trace_arms.mjs"
  "verification/lib_m40_transaction.sh"
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

EXTRA_ENV=()
run_check() { # <check>
  echo "--- $1" | tee -a "$LOG"
  ( cd "$REPO" && env M40_WORK="$WORK/browser" M40_TRACE_WORK="$WORK/trace" \
      "${EXTRA_ENV[@]}" direnv exec "$REPO" bash -c \
      "TMPDIR=\$HOME/.cache/aztec-verification-scratch verification/$1.sh" ) 2>&1 | tee -a "$LOG"
}

rebuild_bundle() {
  echo "--- rebuilding the browser bundle so the mutation reaches the page" | tee -a "$LOG"
  ( cd "$REPO" && direnv exec "$REPO" node browser/build.mjs ) >/dev/null 2>&1 \
    || { echo "!! the bundle build FAILED under the mutation" | tee -a "$LOG"; }
}
rebuild_ct_writer() {
  echo "--- rebuilding ct_writer.wasm so the mutation reaches the page" | tee -a "$LOG"
  ( cd "$REPO" && direnv exec "$REPO" verification/build_ct_writer_wasm.sh --force ) >/dev/null 2>&1 \
    || { echo "!! the ct_writer build FAILED under the mutation" | tee -a "$LOG"; }
}

if [ "${1:-}" = "--demo-still-there" ]; then
  : > "$LOG"
  echo "=== DEMO — still_there over a mutation that was silently undone" | tee -a "$LOG"
  sub verification/lib_m40_transaction.sh \
    'm40_arm() {' \
    'm40_arm() {  # ZZZ_M40_DEMO'
  cp "$BACKUP/verification/lib_m40_transaction.sh" verification/lib_m40_transaction.sh
  still_there verification/lib_m40_transaction.sh 'ZZZ_M40_DEMO' DEMO
  echo "UNREACHABLE: still_there returned instead of exiting 5" >&2
  exit 9
fi

ARMS=("$@")
[ ${#ARMS[@]} -eq 0 ] && ARMS=(P1 P2 P3 P4 P5 P6 P7 P8)

: > "$LOG"
echo "M40 mutation matrix, $(date -Is)" | tee -a "$LOG"

for arm in "${ARMS[@]}"; do
  touch "$MARKER"
  EXTRA_ENV=()
  case "$arm" in

    # ---------------------------------------------------------------------------------------
    P1) # THE CALLDATA IDENTITY IS NOT ENFORCED. The preimage is still read out of the execution
        # cache and still handed to the AVM; only the comparison against the hash the CIRCUIT
        # committed to is removed. So the subject arm is unchanged — a faithful preimage agrees with
        # its own hash — and the CONTROL arm stops refusing, which is the whole point: this is the
        # difference between "the identity holds" and "the identity is checked".
        # Predicted: §5's four corruptCalldata assertions go red, and nothing in §1..§4 moves.
      echo "" | tee -a "$LOG"; echo "=== P1 — the calldata hash comparison is removed" | tee -a "$LOG"
      sub browser/src/transaction_public_half.ts \
        '    if (rebuilt !== call.calldataHash) {' \
        '    if (false && rebuilt !== call.calldataHash) { // ZZZ_M40_P1'
      still_there browser/src/transaction_public_half.ts 'ZZZ_M40_P1' P1
      rebuild_bundle
      EXTRA_ENV=(M40_ARMS_REFRESH=1)
      run_check e2e_joined_public_half_executed
      ;;

    # ---------------------------------------------------------------------------------------
    P2) # THE INITIALIZATION NULLIFIER IS SEEDED WHATEVER THE ARTIFACT SAYS. `Child` declares no
        # initializer, so `assert_is_initialized_public` is in none of its public functions and this
        # puts a nullifier in the tree that no circuit asserts on. Everything still runs — which is
        # exactly why the decision is READ off the artifact and REPORTED rather than taken silently.
        # Predicted: §4's seeding pair goes red and the execution is otherwise unchanged.
      echo "" | tee -a "$LOG"; echo "=== P2 — the initialization nullifier is seeded unconditionally" | tee -a "$LOG"
      sub browser/src/transaction_public_half.ts \
        '  if (declaresInitializer) {' \
        '  if (true) { // ZZZ_M40_P2'
      still_there browser/src/transaction_public_half.ts 'ZZZ_M40_P2' P2
      rebuild_bundle
      EXTRA_ENV=(M40_ARMS_REFRESH=1)
      run_check e2e_joined_public_half_executed
      ;;

    # ---------------------------------------------------------------------------------------
    P3) # THE CLASS ID GOES BACK TO THE BASE64 TEXT. The defect the public half's own guard found,
        # put back — and it fails LOUDLY, at the guard, rather than producing a transaction that
        # looks fine, which is why the guard is there. Predicted: the public half refuses to run at
        # all, so §0's precondition names the absent fields and the check dies with a summary line.
      echo "" | tee -a "$LOG"; echo "=== P3 — the class id is the commitment of the artifact's base64 TEXT again" | tee -a "$LOG"
      sub browser/src/transaction_public_half.ts \
        "  if (typeof bytecode === 'string') return base64ToBytes(bytecode);" \
        "  if (typeof bytecode === 'string') return bytecode as never; // ZZZ_M40_P3"
      still_there browser/src/transaction_public_half.ts 'ZZZ_M40_P3' P3
      rebuild_bundle
      EXTRA_ENV=(M40_ARMS_REFRESH=1)
      run_check e2e_joined_public_half_executed
      ;;

    # ---------------------------------------------------------------------------------------
    P4) # `ct_source_step` IGNORES ITS COLUMN. The container keeps every step, every path and every
        # line; the only thing it loses is the column — and the pinned reader's Path A rendering
        # cannot see a column at all, so NOTHING that reads the container through it can notice.
        # This is the arm the digest pair exists for. Predicted: §4's "the two digests DIFFER" goes
        # red and nothing else does, because with the column dropped on BOTH sides the subject and
        # the control produce the same bytes.
      echo "" | tee -a "$LOG"; echo "=== P4 — ct_source_step ignores its column argument" | tee -a "$LOG"
      sub ct-writer/src/lib.rs \
        '    let col = if column == 0 { None } else { Some(Line(column as i64)) };' \
        '    let col: Option<Line> = { let _ = column; None }; // ZZZ_M40_P4'
      still_there ct-writer/src/lib.rs 'ZZZ_M40_P4' P4
      rebuild_ct_writer
      EXTRA_ENV=(M40_ARMS_REFRESH=1)
      run_check e2e_joined_private_public_trace
      ;;

    # ---------------------------------------------------------------------------------------
    P5) # THE TRACER MODULE EMITS NO `Call` OP FOR A NESTED FRAME. The container keeps all 66 steps
        # and loses the only thing that distinguishes the two frames — which matters here for M39's
        # own reason: the two frames' POSITION sets are identical, so a check asserting only step
        # counts and columns would stay green over this.
      echo "" | tee -a "$LOG"; echo "=== P5 — the nested frame's Call op is never emitted" | tee -a "$LOG"
      # BOTH THE CALL AND THE RETURN ARE DROPPED, so the container stays BALANCED and the frame
      # simply vanishes. The first draft dropped only the Call, and `ct_return` with no frame open
      # is `CT_ERR_NO_FRAME` — the writer's own guard, which threw before the container existed and
      # killed the arm at the check's precondition instead of at the frame assertions it was written
      # for. "The check failed" and "the check saw what I broke" are different statements.
      sub verification/m40_private_trace_wasm.rs \
        '                if c.function_id.0 == 0 {' \
        '                if true { // ZZZ_M40_P5'
      sub verification/m40_private_trace_wasm.rs \
        '                returns += 1;
                ops.push(Op::Return);' \
        '                returns += 1;
                if false { ops.push(Op::Return); }'
      still_there verification/m40_private_trace_wasm.rs 'ZZZ_M40_P5' P5
      EXTRA_ENV=(M40_ARMS_REFRESH=1)
      run_check e2e_joined_private_public_trace
      ;;

    # ---------------------------------------------------------------------------------------
    P6) # THE TRACER MODULE DROPS THE COLUMN ON THE WAY OUT — the state `MemorySink` shipped in
        # before M40, moved to the op list so the module still REPORTS 64 columns while emitting
        # none. That split is the point: the module's own `stepsWithColumn` stays right and the
        # container loses them, so a check reading only the module's report would pass.
        # Predicted: §2's column identity and §3's differential both go red.
      echo "" | tee -a "$LOG"; echo "=== P6 — the op list carries no column, while the report still counts them" | tee -a "$LOG"
      # THE NEEDLE IS THE THREE LINES THE FORMATTER PRODUCED, not the one-liner they were written
      # as. The first draft of this arm named the single-line form, `sub` reported MUTATION MISS and
      # the harness ABORTED rather than printing a result — which is the guard this campaign built
      # after M32's arm printed its predicted result over a subject it had never touched.
      sub verification/m40_private_trace_wasm.rs \
        '                ops.push(Op::Step {
                    path: s.path_id.0,
                    line: s.line.0,
                    column,
                });' \
        '                let _ = column; // ZZZ_M40_P6
                ops.push(Op::Step {
                    path: s.path_id.0,
                    line: s.line.0,
                    column: 0,
                });'
      still_there verification/m40_private_trace_wasm.rs 'ZZZ_M40_P6' P6
      EXTRA_ENV=(M40_ARMS_REFRESH=1)
      run_check e2e_joined_private_public_trace
      ;;

    # ---------------------------------------------------------------------------------------
    P7) # THE ARM RUN HANGS. A trap fires on exit; a process that never exits has no exit — so the
        # bound is the only thing between a hang and a sweep that stops. The bound is cut to 20 s and
        # the runner is given a LIVE TIMER, which is the only shape that is a hang: a promise with no
        # pending handle exits 13 and an `await` in a synchronous function exits 1, and this campaign
        # has written both by accident while meaning a hang. Predicted: `0 assertion(s), 1
        # failure(s)`, rc 124 or 137, the bound NAMED, and a summary line at column 0.
      echo "" | tee -a "$LOG"; echo "=== P7 — the browser arm run HANGS (bound cut to 20 s)" | tee -a "$LOG"
      sub tools/run_m40_transaction_arms.mjs \
        'const arms = {};' \
        'await new Promise((r) => setTimeout(r, 1e9)); // ZZZ_M40_P7
const arms = {};'
      still_there tools/run_m40_transaction_arms.mjs 'ZZZ_M40_P7' P7
      EXTRA_ENV=(M40_ARMS_REFRESH=1 M40_ARMS_TIMEOUT=20)
      run_check e2e_joined_public_half_executed
      ;;

    # ---------------------------------------------------------------------------------------
    P8) # THE ARM REPORT IS TRUNCATED — a report that cannot be parsed at all, which is the second of
        # the three spellings of absence `m38_absent` knows and the one a guard looking only for a
        # missing KEY passes over. Predicted: `0 assertion(s), 1 failure(s)` with the abnormal-exit
        # trap turning a `die` into a RED milestone rather than a smaller one.
      echo "" | tee -a "$LOG"; echo "=== P8 — the browser arm report is truncated" | tee -a "$LOG"
      sub tools/run_m40_transaction_arms.mjs \
        "process.stdout.write(JSON.stringify(out, null, 2) + '\n');" \
        "process.stdout.write('{\"truncat' + String.fromCharCode(0)); // ZZZ_M40_P8
process.exit(0);"
      still_there tools/run_m40_transaction_arms.mjs 'ZZZ_M40_P8' P8
      EXTRA_ENV=(M40_ARMS_REFRESH=1)
      run_check e2e_joined_public_half_executed
      ;;

    *) echo "unknown arm $arm" >&2; restore_all; exit 2 ;;
  esac
  restore_all
  verify_restored || exit 6
  # THE ARTEFACTS ARE REBUILT AFTER THE ARM TOO. Restoring the SOURCE leaves the mutated BUNDLE or
  # the mutated MODULE on disk, and those are what every later arm and every later check read — "a
  # mutated artefact outlived its restored source", the first entry on this campaign's own list.
  case "$arm" in P1|P2|P3) rebuild_bundle ;; P4) rebuild_ct_writer ;; esac
done

echo "" | tee -a "$LOG"
echo "HARNESS: restored; manifest verified" | tee -a "$LOG"
echo "log: $LOG"
