#!/usr/bin/env bash
# closeout-mutations.sh — the closeout pass's mutation matrix.
#
#   scratchpad/campaign/closeout-mutations.sh [arm...]        (default: all)
#   scratchpad/campaign/closeout-mutations.sh --restore-previous [arm...]
#   scratchpad/campaign/closeout-mutations.sh --demo-still-there
#
# ===========================================================================================
# WHAT THIS HARNESS INHERITS, each item a defect this campaign paid for
# ===========================================================================================
#
#  * **A SUBSTITUTION THAT DOES NOT FIND ITS NEEDLE ABORTS THE RUN** (M32's arm M2: `MUTATION MISS`
#    printed, the arm's predicted result produced by a second substitution, and the miss twelve
#    lines above the result in the same log).
#  * **THE MARKER IS WRITTEN BEFORE THE BACKUP** (M36 launched a harness twice in one second and
#    the second run backed up a mutated tree).
#  * **THE BACKUP'S TREE IS PINNED BY CONTENT** — a sha256 manifest taken before the first mutation
#    and verified after the last restore.
#  * **`still_there` FAILING RESTORES, VERIFIES AND EXITS 5** (M30: a mutation silently undone by a
#    rebuild, printed as the arm's result).
#  * **EVERY ARM READS *WHICH* ASSERTIONS WENT RED.** "The check failed" and "the check saw what I
#    broke" are different statements.
#  * **THE HANG ARM'S rc MUST BE 124.** Three wrong shapes are on record — rc 13 (`await new
#    Promise(() => {})`, no pending handle), rc 1 (an `await` in a synchronous function), and a
#    bound that never fires. The hang below is `setTimeout` at 1e9 ms, which keeps the loop alive.
#
# ===========================================================================================
# THE SUBJECTS ARE A DRIVER AND SEVEN CHECKS, SO EVERY ARM COSTS AN ARM RUN.
# ===========================================================================================
#
# Mutating `token_block_driver.ts` invalidates the shared arms (`lib_token_blocks.sh` compares the
# arms file's mtime against every file under `orchestration/src`), so each driver arm re-runs them
# — which is the point: the mutation has to reach the AVM, not just the JSON. Arms that mutate a
# CHECK or the SOURCE do not.
#
# TB_WORK IS THE HARNESS'S OWN, so a mutated arm run never overwrites the arms the real checks read.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

WORK="${CLOSEOUT_MUT_WORK:-$HOME/.cache/aztec-closeout-mut}"
BACKUP="$WORK/backup"
MARKER="$WORK/.in-progress"
MANIFEST="$WORK/manifest.sha256"
LOG="$WORK/mutations.log"

export TB_WORK="$WORK/arms"
export M21_WORK="$WORK/m21"

FILES=(
  "orchestration/src/token_block_driver.ts"
  "orchestration/src/settled_read_source.ts"
  "tools/run_token_block_arms.mjs"
  "verification/lib_token_blocks.sh"
  "verification/_avmtest_debug_logs.py"
  "verification/_token_blocks_shape.py"
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

mkdir -p "$WORK" "$TB_WORK" "$M21_WORK"

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "missing subject: $f" >&2; exit 2; }
done
# A BACKUP IS ONLY AS GOOD AS THE TREE IT WAS TAKEN FROM. Every subject here is tracked, so a
# working tree that is dirty in one of them means an earlier session left a mutation live and the
# backup would freeze it.
DIRTY="$(git status --porcelain -- "${FILES[@]}" | grep -v '^??' || true)"
if [ -n "$DIRTY" ]; then
  echo "REFUSING: a subject has uncommitted changes, so the backup would freeze them:" >&2
  echo "$DIRTY" >&2
  echo "(commit or stash first; --restore-previous if a run died mid-mutation)" >&2
  exit 2
fi

# The marker goes down FIRST — before the wipe and before the backup.
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

still_there() { # <file> <needle> <arm>
  if ! grep -qF -- "$2" "$1"; then
    echo "!! $3 DID NOT HOLD: the mutation is no longer in $1." | tee -a "$LOG" >&2
    echo "   An arm whose mutation was undone must FAIL, not print a result beside a diagnosis." >&2
    restore_all
    verify_restored || true
    exit 5
  fi
}

MODULE="${AVM_WASM_PATH:-$HOME/.cache/aztec-m15-shapes/m13/barretenberg/cpp/build-wasm-avm/bin/avm.wasm}"

run_check() { # <check> [env...]
  echo "--- $1" | tee -a "$LOG"
  ( cd "$REPO" && env AVM_WASM_PATH="$MODULE" TB_WORK="$TB_WORK" M21_WORK="$M21_WORK" "${@:2}" \
      direnv exec "$REPO" bash -c \
      "TMPDIR=\$HOME/.cache/aztec-verification-scratch verification/$1.sh" ) 2>&1 | tee -a "$LOG"
}

arm_header() {
  echo "" | tee -a "$LOG"
  echo "=== $1" | tee -a "$LOG"
}

if [ "${1:-}" = "--demo-still-there" ]; then
  : > "$LOG"
  arm_header "DEMO — still_there over a mutation that was silently undone"
  sub verification/_avmtest_debug_logs.py \
    'CALL = re.compile(' \
    'CALL = re.compile(  # ZZZ_CLOSEOUT_DEMO'
  cp "$BACKUP/verification/_avmtest_debug_logs.py" verification/_avmtest_debug_logs.py
  still_there verification/_avmtest_debug_logs.py 'ZZZ_CLOSEOUT_DEMO' DEMO
  echo "UNREACHABLE: still_there returned instead of exiting 5" >&2
  exit 9
fi

ARMS=("$@")
[ ${#ARMS[@]} -eq 0 ] && ARMS=(M1 M2 M3 M4 M5 M6 M7 M8 M9 M10)

: > "$LOG"
echo "closeout mutation matrix, $(date -Is), module $MODULE" | tee -a "$LOG"

for arm in "${ARMS[@]}"; do
  touch "$MARKER"
  case "$arm" in

    # ---------------------------------------------------------------------------------------
    M1) # THE DEBUG-LOG FLAG STOPS BEING THE VARIABLE. `openWorld` collects unconditionally, so the
        # control arm — the same transaction with the flag off — surfaces the logs too.
        # Predicted: exactly `test_debug_log_events_surface`'s "with the flag off the SAME
        # transaction returns none". Everything else, including the message and field comparisons,
        # stays green, because the SUBJECT arm is unchanged.
      arm_header "M1 — collectDebugLogs is forced on, so the control cannot discriminate"
      sub orchestration/src/token_block_driver.ts \
        '    ...(opts.collectDebugLogs === true ? { collectDebugLogs: true } : {}),' \
        '    collectDebugLogs: true,'
      still_there orchestration/src/token_block_driver.ts 'collectDebugLogs: true,' M1
      run_check test_debug_log_events_surface
      ;;

    # ---------------------------------------------------------------------------------------
    M2) # A SURFACED MESSAGE IS FABRICATED. The driver rewrites the first debug log's message on
        # the way out, which is the "a producer's report about itself is not its output" shape: the
        # transaction still runs, still executes 575 instructions, and still returns six logs.
        # Predicted: the message comparison against the CONTRACT'S OWN SOURCE, and the multi-line
        # positional assertion beside it if the order shifts. The field comparison stays green,
        # which is what says the two comparisons are independent.
      arm_header "M2 — one surfaced debug message is rewritten between the AVM and the report"
      sub orchestration/src/token_block_driver.ts \
        "      message: String(d.message ?? '')," \
        "      message: String(d.message ?? '').replace('just text', 'fabricated'),"
      still_there orchestration/src/token_block_driver.ts "replace('just text', 'fabricated')" M2
      run_check test_debug_log_events_surface
      ;;

    # ---------------------------------------------------------------------------------------
    M3) # THE MINT IS NEVER SUBMITTED, whatever the arm asked for — so the SUBJECT becomes the
        # control and every balance is zero. This is the mutation the whole token pair rests on: if
        # it passed, "the final state is right" would be a property of the reader.
        # Predicted, in BOTH token checks: the balance comparisons, the "two transactions in one
        # block" assertions, and the transfer's revert code. The constructor assertions stay green.
      arm_header "M3 — the mint transaction is never submitted, so the subject becomes its own control"
      sub orchestration/src/token_block_driver.ts \
        '    if (opts.expectMint) {' \
        '    if (false) {'
      still_there orchestration/src/token_block_driver.ts '    if (false) {' M3
      run_check e2e_block_token_flows
      run_check e2e_ts_wasm_token_transfer
      ;;

    # ---------------------------------------------------------------------------------------
    M4) # THE DEPLOYMENT NEVER TRAVELS. The two vendored helpers are not called, so the subject arm
        # becomes the control and the published contract is not callable in either block.
        # Predicted: `e2e_block_deployments_through_processor`'s same-block and later-block calls,
        # their return values and the instruction-count identity. The CONTROL's own assertions stay
        # green — which is what says the arm and its control are two measurements.
      # RE-AIMED AFTER ITS FIRST RUN, WHICH IS THE "A MUTATION THAT CRASHES HAS NOT EXERCISED THE
      # ASSERTION IT WAS WRITTEN FOR" STATE. The first form emptied the CLASS loop and left the
      # INSTANCE loop alone, so the transaction carried an instance whose class nothing knew, the
      # arm run exited 1, and the check died at its precondition with `0 assertion(s), 1
      # failure(s)` — the die-before-summary path working, and not one assertion of the section
      # the arm was written for ever ran. This form drops the whole `deploy` attachment, which is
      # exactly what makes the subject its own control.
      arm_header "M4 — the deployment is not attached to the transaction at all"
      sub orchestration/src/token_block_driver.ts \
        '            ? { deploy: { classes: [contractClass], instances: [contractInstance] } }' \
        '            ? {}'
      still_there orchestration/src/token_block_driver.ts '            ? {}' M4
      run_check e2e_block_deployments_through_processor
      ;;

    # ---------------------------------------------------------------------------------------
    M5) # THE TEARDOWN CALL IS DROPPED. Every phase arm then has two phases instead of three.
        # Predicted: the teardown read-back in the all-succeed arm, the "AND THE TEARDOWN STILL RAN"
        # assertion in the app-revert arm, and the teardown arm's own module revert code — which
        # goes from 2 (TEARDOWN) to 0, so the "three different module codes" assertion falls too.
        # The SETUP arm is untouched, which is what says the three phases are distinguished.
      arm_header "M5 — the teardown call is never enqueued, so the third phase does not exist"
      sub orchestration/src/token_block_driver.ts \
        '          plan.teardownCall,' \
        '          undefined,'
      still_there orchestration/src/token_block_driver.ts '          undefined,' M5
      run_check e2e_ts_wasm_phase_revert_semantics
      ;;

    # ---------------------------------------------------------------------------------------
    M6) # THE TWO GAS ALLOCATIONS BECOME ONE. The "unused gas is refunded" equality is then true by
        # construction — two runs of the same thing — which is the campaign's own "a value compared
        # with itself" in its gas-shaped disguise.
        # Predicted: EXACTLY the non-degeneracy guard that the two allocations differ. The equality
        # itself stays green, and that is the finding: the guard is the only thing standing between
        # this arm and a vacuous pass.
      # THIS ARM FOUND A DEFECT IN THE DRIVER ON ITS FIRST RUN AND THE NEEDLE MOVED WITH THE FIX.
      # The allocations used to be declared TWICE — once in the `args` and once in the returned
      # `gasAllocations` — so mutating the call left the report still claiming they differed and
      # the check's non-degeneracy guard stayed GREEN over an equality that had become a tautology:
      # 38 assertions, 0 failures. One declaration now, used at both sites, and this arm reaches
      # both. (The first form's needle is gone, and `sub` correctly aborted the run rather than
      # printing a result — which is the harness working.)
      arm_header "M6 — both gas arms allocate the same amount, so the refund equality is a tautology"
      sub orchestration/src/token_block_driver.ts \
        "    const GAS_LARGE = { l2: 8_000_000, da: 800_000 };" \
        "    const GAS_LARGE = { l2: 2_000_000, da: 200_000 };"
      still_there orchestration/src/token_block_driver.ts 'const GAS_LARGE = { l2: 2_000_000, da: 200_000 };' M6
      run_check e2e_ts_wasm_nested_call_fork_merge
      ;;

    # ---------------------------------------------------------------------------------------
    M7) # THE SETTLED-READ SOURCE ANSWERS AN INDEX FOR EVERYTHING. A note hash nobody appended comes
        # back settled, which is the direction that makes a transaction pass a check it should fail.
        # Predicted: `test_settled_read_request_verification`'s "before the append" and "a hash that
        # was never appended" assertions, and the two "the answers differ" ones. The NULLIFIER arm
        # stays green, which says the two trees are two measurements.
      arm_header "M7 — the note-hash index answers 0 for every value, settled or not"
      sub orchestration/src/settled_read_source.ts \
        '      return values.map((v) => this.noteHashIndex.get(v.toBigInt().toString()));' \
        '      return values.map(() => 0n);'
      still_there orchestration/src/settled_read_source.ts 'return values.map(() => 0n);' M7
      run_check test_settled_read_request_verification
      ;;

    # ---------------------------------------------------------------------------------------
    M8) # A HANG. The arms tool waits on a live timer, so the process never exits and `timeout` has
        # something to kill. The bound is lowered to 20 s through the environment variable
        # `lib_token_blocks.sh` reads, because a bound nobody has seen fire is a bound nobody has
        # seen work — and waiting half an hour to see it is not a test anybody runs.
        # Predicted: rc 124 from `timeout`, `tb_require_arms` dying with the word HANG in it, and —
        # the part that matters — a SUMMARY LINE AT COLUMN 0 with one failure. A check that dies
        # silently reads to a sweep as a check that is not there.
      arm_header "M8 — the arm run HANGS; the bound must fire, and the check must still report"
      sub tools/run_token_block_arms.mjs \
        'const reactor = await instantiateAvm(await compileAvm(modulePath));' \
        'await new Promise((r) => setTimeout(r, 1e9)); // ZZZ_CLOSEOUT_HANG
const reactor = await instantiateAvm(await compileAvm(modulePath));'
      still_there tools/run_token_block_arms.mjs 'ZZZ_CLOSEOUT_HANG' M8
      rm -f "$TB_WORK/token-blocks.json"
      run_check test_debug_log_events_surface TB_ARMS_BOUND_S=20 TB_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M9) # A BLOCK IS RENAMED, so the arms file is WELL-FORMED and the arm this check reads is not
        # the arm it names. This is the accessor's `MISSING` path, and it is the one that decides
        # whether a check whose subject moved goes red as itself or quietly asserts about nothing.
        # Predicted: the block-label assertion FIRST, by name, and then every field of that block.
      arm_header "M9 — one block is renamed; the check must fail on the LABEL, not on nothing"
      sub orchestration/src/token_block_driver.ts \
        "    blocks.push(await runOneBlock(reactor, world, tester, 'mintAndTransfer', blockTwoPlans));" \
        "    blocks.push(await runOneBlock(reactor, world, tester, 'mintAndTransferRENAMED', blockTwoPlans));"
      still_there orchestration/src/token_block_driver.ts 'mintAndTransferRENAMED' M9
      run_check e2e_block_token_flows
      ;;

    # ---------------------------------------------------------------------------------------
    M10) # DIE BEFORE THE SUMMARY. The arms tool exits 0 having printed a TRUNCATED object, so the
        # file is non-empty and the staleness test is satisfied. Before this pass added
        # `tb_require_arms_shape` the accessors then threw one at a time and the check reported
        # THIRTY-FIVE failures — loud, but a broken-check shape rather than a run-did-not-happen
        # one, and the two have different remedies.
        # Predicted now: ONE named refusal from the precondition, `0 assertion(s), 1 failure(s)`,
        # and a summary line at column 0 — because a check that dies silently reads to a sweep as a
        # check that is not there, which is the shape that cost this campaign 283 assertions once.
      arm_header "M10 — the arms file is truncated JSON; the precondition must refuse it by name"
      sub tools/run_token_block_arms.mjs \
        'process.stdout.write(' \
        'process.stdout.write("{ \"arms\": {"); // ZZZ_CLOSEOUT_TRUNCATE
if (true) process.exit(0);
process.stdout.write('
      still_there tools/run_token_block_arms.mjs 'ZZZ_CLOSEOUT_TRUNCATE' M10
      rm -f "$TB_WORK/token-blocks.json"
      run_check e2e_block_token_flows TB_ARMS_REFRESH=1
      ;;

    *) echo "unknown arm: $arm" >&2 ;;
  esac
  restore_all
  verify_restored || exit 6
done

echo "" | tee -a "$LOG"
echo "all requested arms complete; tree restored and verified against $MANIFEST" | tee -a "$LOG"
