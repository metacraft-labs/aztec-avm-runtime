#!/usr/bin/env bash
# verify_avm_differential_exit_status — M8.
#
# `just avm-differential` exits ZERO on a clean run and NON-ZERO on an injected divergence, so it
# doubles as a regression check rather than as a report somebody has to read.
#
# The exit status is the whole subject here, so it is asserted for six separate runs and each
# failing one is additionally required to fail BY ITS OWN MESSAGE. A gate that exits 1 for the
# wrong reason is a gate that will exit 1 when the reason goes away.
#
# It also asserts the shape of the runner itself: no `SKIPPED` branch anywhere, a distinct exit
# status for "could not run" versus "diverged", and a refusal to report success on a comparison
# that asserted nothing. Four `verify.sh` scripts in this campaign shipped with a `SKIPPED` branch
# that exited 0; that is why this is checked and not assumed.

TEST_NAME="verify_avm_differential_exit_status"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m8_differential.sh"

RUNNER="$VERIFY_DIR/run_avm_differential.sh"
assert_file "the runner exists" "$RUNNER"
assert_true "…and is executable" test -x "$RUNNER"
[ -x "$RUNNER" ] || die "the runner is not executable: $RUNNER"

JUSTFILE="$REPO_ROOT/Justfile"
assert_file "the Justfile exists" "$JUSTFILE"

# ---------------------------------------------------------------------------
echo "== 1. the recipe exists and is the one that runs"
# ---------------------------------------------------------------------------
assert_true "the Justfile declares an avm-differential recipe" \
  grep -q '^avm-differential' "$JUSTFILE"
assert_true "…and it invokes the runner" \
  grep -q 'run_avm_differential.sh' "$JUSTFILE"
if command -v just >/dev/null 2>&1; then
  RECIPES="$(cd "$REPO_ROOT" && just --list 2>/dev/null)"
  assert_contains "just itself lists the recipe" "avm-differential" "$RECIPES"
else
  fail "just is not available, so the recipe could not be listed"
fi

# ---------------------------------------------------------------------------
echo "== 2. the runner has no skip path"
# ---------------------------------------------------------------------------
RUNNER_TEXT="$(cat "$RUNNER")"
assert_eq "the runner contains no SKIPPED branch" "0" "$(grep -c 'SKIPPED' "$RUNNER" || true)"
assert_eq "…and no 'skipping' message" "0" "$(grep -ci 'skipping' "$RUNNER" || true)"
assert_contains "it distinguishes 'could not run' from 'diverged' by exit status" \
  "2   an input is missing or a precondition cannot be met" "$RUNNER_TEXT"
assert_contains "…and it refuses to report success on a comparison that asserted nothing" \
  "made only \$DIFF_PASSES assertions" "$RUNNER_TEXT"
assert_true "every fatal path names its own exit status" \
  bash -c 'grep -qE "fatal [0-9] " "$1"' bash "$RUNNER"

# ---------------------------------------------------------------------------
echo "== 3. a clean run exits 0"
# ---------------------------------------------------------------------------
CLEAN_LOG="$M8_WORK/differential-clean.log"
mkdir -p "$M8_WORK"
( cd "$REPO_ROOT" && "$RUNNER" ) >"$CLEAN_LOG" 2>&1
CLEAN_RC=$?
assert_eq "a clean run exits 0" "0" "$CLEAN_RC"
[ "$CLEAN_RC" -eq 0 ] || tail -20 "$CLEAN_LOG" >&2
# Exit 0 is not by itself evidence that anything ran. The summary it prints is asserted separately.
assert_contains "…and it reports the native-versus-wasm comparison" \
  "native versus wasm" "$(cat "$CLEAN_LOG")"
assert_contains "…and the Tier D comparison" "wasm versus Tier D" "$(cat "$CLEAN_LOG")"
assert_contains "…and it says OK" "avm-differential: OK" "$(cat "$CLEAN_LOG")"
assert_eq "the native-versus-wasm comparison reported zero failures" "0" \
  "$(sed -n 's/^avm-differential: native versus wasm  — [0-9]* passed, \([0-9]*\) failed$/\1/p' "$CLEAN_LOG")"
assert_ge "…over a real number of assertions" 20 \
  "$(sed -n 's/^avm-differential: native versus wasm  — \([0-9]*\) passed.*$/\1/p' "$CLEAN_LOG")"
assert_eq "the Tier D comparison reported zero failures" "0" \
  "$(sed -n 's/^avm-differential: wasm versus Tier D — [0-9]* passed, \([0-9]*\) failed$/\1/p' "$CLEAN_LOG")"
assert_ge "…over a real number of assertions" 100 \
  "$(sed -n 's/^avm-differential: wasm versus Tier D — \([0-9]*\) passed.*$/\1/p' "$CLEAN_LOG")"
# The coverage statement travels with the result, which is this milestone's own deliverable.
assert_contains "the run states its own coverage" \
  "seven hand-assembled corpus programs compared field for field" "$(cat "$CLEAN_LOG")"
assert_contains "…and says what it is not" "NOT a breadth claim" "$(cat "$CLEAN_LOG")"
assert_contains "…naming the two instruments it must not be quoted as" "M7" "$(cat "$CLEAN_LOG")"
assert_contains "…and the other one" "M19" "$(cat "$CLEAN_LOG")"

# ---------------------------------------------------------------------------
echo "== 4. every injected divergence exits non-zero, each by its own message"
# ---------------------------------------------------------------------------
# The five modes are not variations on one mutation: a wrong ROOT, an unenumerated DIAGNOSTIC, the
# same artefact handed in twice, the two sides SWAPPED and a TRUNCATED run each fail through a
# different assertion, and each is required to.
inject_case() { # <mode> <expected message fragment>
  local mode="$1" want="$2" log="$M8_WORK/differential-inject-$1.log" rc
  ( cd "$REPO_ROOT" && AVM_DIFF_INJECT="$mode" "$RUNNER" ) >"$log" 2>&1
  rc=$?
  assert_eq "injection '$mode' exits 1 (a divergence, not a broken run)" "1" "$rc"
  assert_contains "injection '$mode' reports a DIVERGENCE" "avm-differential: DIVERGENCE" "$(cat "$log")"
  assert_contains "injection '$mode' is caught by its own message" "$want" "$(cat "$log")"
}

inject_case root     "every non-diagnostic line is identical native versus wasm"
inject_case diag     "key the transcripts emit is enumerated here"
inject_case same     "the wasm target is 32-bit"
inject_case swap     "the native target is 64-bit"
inject_case truncate "wasm transcript ran to completion"

# The root injection must ALSO be caught by the Tier D half, because that half is the one that
# knows what the right answer is rather than only that the two sides agree.
assert_contains "injection 'root' is caught by the Tier D comparison as well" \
  "NULLIFIER_TREE root matches the real WorldState" \
  "$(cat "$M8_WORK/differential-inject-root.log")"

# ---------------------------------------------------------------------------
echo "== 5. a precondition that cannot be met is exit 2, not exit 0 and not exit 1"
# ---------------------------------------------------------------------------
BAD_LOG="$M8_WORK/differential-badmode.log"
( cd "$REPO_ROOT" && AVM_DIFF_INJECT=nonsense "$RUNNER" ) >"$BAD_LOG" 2>&1
assert_eq "an unknown injection mode is exit 2" "2" "$?"
assert_contains "…and it names the variable and the modes it accepts" "AVM_DIFF_INJECT" \
  "$(cat "$BAD_LOG")"

# A missing input, exercised by pointing the runner at a work directory it cannot use.
MISSING_LOG="$M8_WORK/differential-missing.log"
( cd "$REPO_ROOT" && M8_WORK=/proc/nonexistent-m8-work "$RUNNER" ) >"$MISSING_LOG" 2>&1
MISSING_RC=$?
assert_true "an unusable work directory does not exit 0" test "$MISSING_RC" -ne 0
assert_true "…and it does not exit 1 either, so 'broken' and 'diverged' stay distinct" \
  test "$MISSING_RC" -ne 1

finish
