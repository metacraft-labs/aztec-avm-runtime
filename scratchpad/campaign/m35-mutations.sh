#!/usr/bin/env bash
# m35-mutations.sh — M35's mutation matrix.
#
#   scratchpad/campaign/m35-mutations.sh [arm...]        (default: all)
#
# ===========================================================================================
# WHAT THIS HARNESS INHERITS, AND THE ONE THING IT MAKES STRICTER
# ===========================================================================================
#
# It is M33's harness, which M34 already made stricter, with M35's arms. Everything it knew:
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
# **`still_there` FAILING RESTORES, VERIFIES AND EXITS 5**, which M34 made it do and this keeps: an
# arm whose mutation was undone must FAIL rather than print a result beside a diagnosis, and an arm
# that cannot be applied produces no number at all.
#
# **AND M35 ADDS A FOURTH SUBJECT TO THE BACKUP SET.** `PRIVATE-EXECUTION.md` is mutated by M9 the
# way M34 mutated its own write-up, so the document comparer is shown to report a stale figure rather
# than being trusted to.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

WORK="${M35_MUT_WORK:-$HOME/.cache/aztec-m35-mut}"
BACKUP="$WORK/backup"
MARKER="$WORK/.in-progress"
MANIFEST="$WORK/manifest.sha256"
LOG="$WORK/mutations.log"
ARMS_JSON="${M35_WORK:-$HOME/.cache/aztec-m35-private}/private-execution.json"

FILES=(
  "browser/src/wallet/private_oracles.ts"
  "browser/src/wallet/private_execution.ts"
  "browser/demo/wallet_main.ts"
  "PRIVATE-EXECUTION.md"
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
echo "M35 mutation matrix, $(date -Is)" | tee -a "$LOG"

for arm in "${ARMS[@]}"; do
  touch "$MARKER"
  case "$arm" in

    # ---------------------------------------------------------------------------------------
    M1) # THE ARM THIS WHOLE MILESTONE IS ABOUT. An unimplemented oracle returns instead of
        # refusing — the plausible default, in the one place where it would settle rather than
        # fail. Predicted: test_unimplemented_oracle_refuses_by_name §1 reports RESOLVED for every
        # refused oracle, and §5's real ACIR frame stops being a refusal.
      arm_header "M1 — an unimplemented oracle returns a plausible value instead of refusing"
      sub browser/src/wallet/private_oracles.ts \
        '      record(oracle, '"'"'refused'"'"', reason);
      throw new OracleUnimplemented(oracle, reason);' \
        '      record(oracle, '"'"'refused'"'"', reason);
      return undefined;'
      rebuild
      still_there browser/src/wallet/private_oracles.ts 'return undefined;' M1
      run_check test_unimplemented_oracle_refuses_by_name M35_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M2) # THE ORACLE VERSION STOPS BEING CHECKED. The bytecode's declared version is recorded and
        # the major disagreement no longer throws — the fourth deliverable, made silent.
        # Predicted: coverage §6 loses the contract version it reads back.
      arm_header "M2 — the oracle version assertion stops being an assertion"
      sub browser/src/wallet/private_oracles.ts \
        '      contractVersion = { major, minor };' \
        '      contractVersion = { major: major + 1, minor };'
      rebuild
      still_there browser/src/wallet/private_oracles.ts 'major: major + 1' M2
      run_check verify_oracle_coverage_is_measured M35_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M3) # AMBIENT ENTROPY, in the one served oracle that would otherwise read it. `getRandomField`
        # is a counter hashed with a seed; this makes it read the clock instead. The STRUCTURAL
        # half of the milestone (a partition, a count) cannot see it — only the behavioural triple
        # can, which is the arm that says the triple is load-bearing.
      arm_header "M3 — getRandomField reads an ambient value instead of the seed"
      # THE FIRST VERSION OF THIS ARM USED `Date.now()` AND DID NOT FIRE — 69 / 0, the arm's own
      # subject untouched. Eight poseidon2 calls through `avm.wasm` take well under a millisecond, so
      # both draws landed in the same tick and the two seeds still agreed. A clock is the WRONG
      # ambient source for this mutation precisely because it is coarse; `Math.random()` is the one
      # `DEV-WALLET.md` section 1 names, and it differs between two calls by construction. Recorded
      # because "the arm reddened for the wrong reason" and "the arm did not redden" are both states
      # this matrix exists to distinguish, and this was the second.
      sub browser/src/wallet/private_oracles.ts \
        '      const field = await poseidon2HashWithSeparator([options.entropySeed, new Fr(BigInt(index))], 0);' \
        '      const field = await poseidon2HashWithSeparator([options.entropySeed, new Fr(BigInt(index) + BigInt(Math.floor(Math.random() * 1e15)))], 0);'
      rebuild
      still_there browser/src/wallet/private_oracles.ts 'Math.random()' M3
      run_check test_unimplemented_oracle_refuses_by_name M35_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M4) # AN IMPLEMENTED ORACLE STOPS BEING EXERCISED while staying declared implemented. This is
        # the arm for the assertion a COUNT cannot give: "implemented" has to mean "observed to
        # answer", and the exercised SET is what says so.
      arm_header "M4 — a declared-implemented oracle is no longer exercised by the surface arm"
      sub browser/demo/wallet_main.ts \
        "  h.emitOffchainEffect([F(1n), F(2n)]);" \
        "  void F;"
      rebuild
      still_there browser/demo/wallet_main.ts '  void F;' M4
      run_check verify_oracle_coverage_is_measured M35_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M5) # AN ORACLE FALLS OUT OF THE SURFACE ALTOGETHER, and every internal consistency check still
        # agrees with itself. `ORACLE_NAMES` stops being the registry's key set and becomes a subset
        # of it, so `implemented + refusing` still sums, the two sets are still disjoint, every
        # refusal still has a reason, and the handler still carries one method per NAME — while one
        # oracle a contract can call is served by nothing at all. That is "the number is right and an
        # entry is missing", which is the shape M32's review found in a document and this arm asks of
        # a surface. Predicted: coverage §3's total, its handler-method count, and §4's
        # union-IS-the-registry with the missing name reported.
        #
        # THE FIRST VERSION OF THIS ARM ADDED A REFUSED ORACLE TO THE IMPLEMENTED LIST, and it never
        # reached the check: `assertOracleSurfaceMatchesDeclaration` refuses a non-disjoint partition
        # at CONSTRUCTION, so the page arm threw, the arm run exited 1, and the check died at
        # `m35_require_arms` with **0 assertion(s), 1 failure(s)** — the die-before-summary path
        # working, and not one assertion of the section the arm was written for. That is M34's M5
        # exactly, one milestone later. The guard being unfalsifiable from outside is the right
        # outcome for the guard and the wrong shape for an arm, so the arm moved to the property the
        # guard cannot see.
      arm_header "M5 — one registry oracle falls out of the surface, consistently"
      sub browser/src/wallet/private_oracles.ts \
        'Object.freeze(Object.keys(ORACLE_REGISTRY).sort());' \
        "Object.freeze(Object.keys(ORACLE_REGISTRY).sort().filter(n => n !== 'aztec_utl_getNotes'));"
      rebuild
      still_there browser/src/wallet/private_oracles.ts "filter(n => n !== 'aztec_utl_getNotes')" M5
      run_check verify_oracle_coverage_is_measured M35_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M6) # THE REFUSAL STOPS NAMING ITSELF. It still refuses — so a smoke test that only asked
        # "did it throw" would be green — and the message no longer says which oracle. That is the
        # failure-that-cannot-name-its-subject family, which M34's first browser run produced three
        # of in one afternoon.
      arm_header "M6 — the refusal throws without naming the oracle"
      sub browser/src/wallet/private_oracles.ts \
        'does not serve the oracle '"'"'${oracle}'"'"'' \
        'does not serve the oracle '"'"'(withheld)'"'"''
      rebuild
      still_there browser/src/wallet/private_oracles.ts "(withheld)" M6
      run_check test_unimplemented_oracle_refuses_by_name M35_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M7) # THE HANG, BOUNDED AND NAMED. The ACVM is pointed at a URL that does not exist, so the
        # page's fetch never resolves into a module and the arm run waits. The point is not that it
        # fails: it is that it fails INSIDE A BOUND with the step named, rather than sitting at zero
        # bytes of output while a sweep queues behind it. A trap cannot reach a process that never
        # exits, which is M23's review's finding.
      # THIS ARM TOOK THREE SHAPES BEFORE IT WAS A HANG, AND THE TWO IT DISCARDED ARE THE FINDING.
      #
      #  1. **A URL the served site does not have.** The server answers 404 in milliseconds and
      #     Chromium reports `HTTP status code is not ok`; the arm produced `0 assertion(s),
      #     1 failure(s)` — the shape a hang produces — in three minutes rather than never.
      #  2. **A promise that never settles.** V8 collects it and CDP answers
      #     `{"code":-32000,"message":"Promise was collected"}` in seconds, so the runner exits 1 and
      #     again the summary is indistinguishable from a hang's.
      #
      # Both are "the check failed" rather than "the check saw what I broke", and in both cases only
      # the log said which. A hang has to be a renderer that does not return: a spin, which is the
      # one arm of M24's three declared hangs that actually hung.
      arm_header "M7 — THE HANG: the page's renderer never returns"
      sub browser/demo/wallet_main.ts \
        '  await requirePrivateAssets();' \
        '  for (;;) { /* the hang arm: a renderer that never returns */ }'
      rebuild
      still_there browser/demo/wallet_main.ts 'the hang arm: a renderer that never returns' M7
      # THE BOUND IS SHORTENED FOR THIS ARM AND NOTHING ELSE. The point is that the wait ENDS inside a
      # bound with the bound NAMED — not that a matrix takes half an hour to say so.
      run_check e2e_private_function_executes_in_browser M35_ARMS_REFRESH=1 M35_ARMS_TIMEOUT=90
      ;;

    # ---------------------------------------------------------------------------------------
    M8) # DIE BEFORE THE SUMMARY. The arm report is hollowed, so every field the check reads is
        # absent. `m35_absent` names them all in ONE assertion and dies; the abnormal-exit trap
        # prints a summary line, so the milestone reads RED rather than SMALLER.
        #
        # THE ORDERING IS THE WHOLE ARM. M30's review's third mutation state is "a mutation silently
        # undone and printed as the arm's result": the bundle must be brought CURRENT before the
        # cache is hollowed, or the first check rebuilds, the fresh bundle is newer than the hollow,
        # and the harness re-measures over it. Hence the `rebuild` and the `sleep` above the write,
        # and the second `still_there` below the run.
      arm_header "M8 — DIE BEFORE THE SUMMARY: the arm report is hollowed"
      rebuild
      sleep 1
      python3 - "$ARMS_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['arms'] = {'private': {}, 'surface': {}, 'lazy': {}}
json.dump(d, open(sys.argv[1], 'w'), indent=2)
PY
      touch "$ARMS_JSON"
      still_there "$ARMS_JSON" '"private": {}' M8
      run_check e2e_private_function_executes_in_browser
      still_there "$ARMS_JSON" '"private": {}' M8
      echo "M8 held: the hollow survived the run" | tee -a "$LOG"
      ;;

    # ---------------------------------------------------------------------------------------
    M9) # A figure in the write-up is made stale. Predicted: coverage §8 names the figure AND the
        # row, and its own perturbation control still runs — which is the state M34's review found
        # a hard-coded literal turning into a `die`.
      arm_header "M9 — a figure in PRIVATE-EXECUTION.md is made stale"
      sub PRIVATE-EXECUTION.md \
        '| `Token.transfer` bytecode | **76,875** bytes |' \
        '| `Token.transfer` bytecode | **76,874** bytes |'
      still_there PRIVATE-EXECUTION.md '**76,874** bytes' M9
      run_check verify_oracle_coverage_is_measured
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
M35_ARMS_REFRESH=1 direnv exec "$REPO" bash -c \
  'TMPDIR=$HOME/.cache/aztec-verification-scratch M35_ARMS_REFRESH=1 verification/verify_oracle_coverage_is_measured.sh' \
  >> "$LOG" 2>&1
echo "" | tee -a "$LOG"
echo "restored, rebuilt and the arms re-measured; the matrix is in $LOG" | tee -a "$LOG"
