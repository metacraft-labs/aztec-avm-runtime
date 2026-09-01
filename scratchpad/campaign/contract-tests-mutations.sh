#!/usr/bin/env bash
# contract-tests-mutations.sh — the mutation matrix for `e2e_contract_tests_run_in_browser`.
#
#   bash scratchpad/campaign/contract-tests-mutations.sh
#
# SIX ARMS. Each plants ONE defect and requires the check to report it — and, crucially, requires
# the check to report it IN THE SECTION THAT OWNS IT. An arm that merely turns the check red proves
# the check is fragile, not that it is measuring the thing its section header claims.
#
# The failure mode this matrix is itself built against: an arm whose PREMISE HAS MOVED goes vacuous
# and reports "could not be measured" forever while looking like coverage. So every arm asserts its
# anchor string was FOUND before it runs, and an arm whose anchor is missing is a hard error here
# rather than a silent skip.
#
# Each arm gets its OWN work directory, so a mutant's arm report can never be read by a later arm.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/verification/e2e_contract_tests_run_in_browser.sh"
SCRATCH="${SCRATCH:-$HOME/.cache/aztec-contract-tests-mutations}"
mkdir -p "$SCRATCH"

: "${CT_CHROMIUM:?set CT_CHROMIUM to a chromium/chrome binary}"
: "${AVM_WASM_PATH:?set AVM_WASM_PATH to the barretenberg avm.wasm}"

BACKUPS=()
restore() {
  local i
  for ((i = 0; i < ${#BACKUPS[@]}; i += 2)); do
    cp -f "${BACKUPS[i+1]}" "${BACKUPS[i]}"
  done
  BACKUPS=()
}
trap 'restore' EXIT INT TERM

mutate() { # <file> <from> <to>
  local file="$1" from="$2" to="$3"
  local backup="$SCRATCH/$(basename "$file").orig.$$"
  cp -f "$file" "$backup"
  BACKUPS+=("$file" "$backup")
  # THE ANCHOR CHECK. A `replace` that matched nothing serves the original and produces a green
  # "mutation arm" — coverage that measures nothing. This is the defect the matrix exists to avoid
  # having itself.
  if ! grep -qF -- "$from" "$file"; then
    printf 'VACUOUS ARM: anchor not found in %s:\n  %s\n' "$file" "$from" >&2
    return 2
  fi
  python3 - "$file" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert a in s
open(p, 'w').write(s.replace(a, b, 1))
PY
}

TOTAL=0
GOOD=0
run_arm() { # <name> <expected-section-substring> <file> <from> <to>
  local name="$1" expect_section="$2" file="$3" from="$4" to="$5"
  # ONLY_ARM runs one arm. It does NOT change the totals line's meaning: a filtered run reports
  # what it ran, so a partial run cannot be mistaken for a full green matrix.
  if [ -n "${ONLY_ARM:-}" ] && [ "$name" != "$ONLY_ARM" ]; then return; fi
  TOTAL=$((TOTAL + 1))
  printf '\n=== arm: %s\n' "$name"
  if ! mutate "$file" "$from" "$to"; then
    printf 'arm %s: VACUOUS — its premise has moved. Fix the anchor.\n' "$name" >&2
    restore
    return
  fi
  local work="$SCRATCH/$name"
  rm -rf "$work"; mkdir -p "$work"
  local log="$SCRATCH/$name.log"
  CT_WORK="$work" CT_ARMS_REFRESH=1 CT_CHROMIUM="$CT_CHROMIUM" AVM_WASM_PATH="$AVM_WASM_PATH" \
    bash "$CHECK" >"$log" 2>&1
  local rc=$?
  restore

  if [ "$rc" -eq 0 ]; then
    printf 'arm %s: MISS — the check PASSED over a planted defect (exit 0). See %s\n' "$name" "$log" >&2
    return
  fi
  # WHICH assertion went red, not merely that one did.
  local reds
  reds="$(grep -c '^  FAIL' "$log" 2>/dev/null || printf '0')"
  if ! grep -qF -- "$expect_section" "$log"; then
    printf 'arm %s: WRONG RED — the check failed (%s red) but not on the expected assertion:\n  %s\nSee %s\n' \
      "$name" "$reds" "$expect_section" "$log" >&2
    grep '^  FAIL' "$log" | head -5 >&2
    return
  fi
  printf 'arm %s: HIT — %s assertion(s) red, including the one it owns.\n' "$name" "$reds"
  grep '^  FAIL' "$log" | head -4
  GOOD=$((GOOD + 1))
}

RUNNER="$REPO/browser/testkit/runner.js"
SUITE="$REPO/browser/testkit/token.suite.js"
DRIVER="$REPO/tools/run_contract_test_arms.mjs"

# ---------------------------------------------------------------------------------------------
# 1. THE EMPTY SUITE BECOMES A PASS. This is the `ok: 0/0 … exited 0` defect, planted.
#
#    THE EXPECTED RED IS THE `reason`, NOT THE `status`, and that attribution was CORRECTED by
#    running this arm. Removing the `total === 0` branch does not make the runner report `ok`: the
#    `intact` guard at the end of `runSuite` requires `assertions > 0` and independently reports
#    `error` / `incomplete`. So the STATUS assertion is owned by the second guard and survives this
#    mutation, while the REASON assertion — `no-tests` — is what this branch uniquely owns. Two
#    independent guards against the same false pass is a good property; pointing a mutation arm at
#    the one the mutation does not reach is how an arm comes to report WRONG RED forever.
run_arm 'empty-suite-passes' \
  'FAIL …named no-tests' \
  "$RUNNER" \
  "  if (base.total === 0) {" \
  "  if (false) {"

# 2. A TEST THAT ASSERTS NOTHING BECOMES A PASS.
run_arm 'no-expectation-passes' \
  'FAIL the silent test is failed, by name, with no-expectations' \
  "$RUNNER" \
  "      if (made === 0) {" \
  "      if (false) {"

# 3. A SUITE THAT FAILS TO LOAD IS SWALLOWED INTO AN EMPTY PASS.
run_arm 'load-failure-swallowed' \
  'FAIL a 404 suite reports error' \
  "$RUNNER" \
  "    return { ...base, status: 'error', reason: 'load-failed', message: messageOf(err), ms: Date.now() - started };" \
  "    return { ...base, status: 'ok', reason: 'load-failed', message: messageOf(err), ms: Date.now() - started };"

# 4. `expect` STOPS COUNTING. Every test still passes; the assertion tally collapses. This is the
#    arm for "assert the count of tests executed, and assert that count is non-zero" — one level
#    down, at the expectation.
run_arm 'expect-stops-counting' \
  'FAIL …thirty-one of them' \
  "$RUNNER" \
  "  const counter = { n: 0, bump() { this.n += 1; } };" \
  "  const counter = { n: 0, bump() { /* mutated: stops counting */ } };"

# 5. THE STEP-STREAM TEST IS DROPPED FROM THE SUITE. Every count in §3 stays consistent — ten of
#    ten pass — and only §4, which names the measurement, can see it.
run_arm 'step-stream-test-dropped' \
  'FAIL a test measures the executed step stream' \
  "$SUITE" \
  "    it('produced a non-trivial executed step stream', ({ expect }) => {" \
  "    if (false) it('produced a non-trivial executed step stream', ({ expect }) => {"

# 6. THE MUTATION ARM GOES VACUOUS — the driver's `replace` matches nothing, so the "fail
#    demonstration" runs the ORIGINAL suite and reports green. The check must notice that its own
#    negative control stopped being one.
run_arm 'mutation-arm-vacuous' \
  "FAIL the mutation's premise still exists in the suite source" \
  "$DRIVER" \
  "const MUTATION_FROM = \"const EXPECTED_TRANSFERRED = '5';\";" \
  "const MUTATION_FROM = \"const THIS_ANCHOR_NO_LONGER_EXISTS = '5';\";"

printf '\n=== matrix: %d/%d arms hit their own assertion\n' "$GOOD" "$TOTAL"
[ "$GOOD" -eq "$TOTAL" ] || exit 1
