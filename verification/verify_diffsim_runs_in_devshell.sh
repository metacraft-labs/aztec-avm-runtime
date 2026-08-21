#!/usr/bin/env bash
# verify_diffsim_runs_in_devshell
#
# M0 verification: the TypeScript-versus-C++ differential harness — including
# the prebuilt NAPI AVM out of the @aztec/bb.js npm tarball — runs green inside
# the nix shell.
#
# VACUITY GUARD, deliberately explicit: diffsim's `npm test` invokes jest with
# `--passWithNoTests`. A jest run that discovers nothing therefore EXITS 0.
# Asserting on the exit status alone would be exactly the failure mode this
# campaign has already been bitten by ("6 passed" where nothing ran). So this
# check parses jest's summary and asserts FLOOR COUNTS of suites and tests, and
# that zero failed. If the harness stops discovering tests, the counts collapse
# and the check fails loudly.
#
# It also asserts that the C++ half is really in play: the three suites that
# drive the native NAPI AVM through cpp_vs_ts_public_tx_simulator must be
# among the PASSing ones, and the prebuilt nodejs_module.node must dlopen
# under nixpkgs' node (which is what the shell's LD_LIBRARY_PATH exists for).
#
# Run: just verify-diffsim

TEST_NAME="verify_diffsim_runs_in_devshell"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_nix

DIFFSIM="$REPO_ROOT/diffsim"
assert_dir "the differential harness is in the repo" "$DIFFSIM"
assert_file "diffsim has a package.json" "$DIFFSIM/package.json"
assert_dir "diffsim's dependencies are installed" "$DIFFSIM/node_modules"
[ -d "$DIFFSIM/node_modules" ] || die \
  "diffsim/node_modules is missing — run 'npm ci' in diffsim inside the dev shell first"

# Floors, not exact counts: the harness may legitimately gain tests. It may not
# silently lose them.
MIN_SUITES=43
MIN_TESTS=757

# ---- the prebuilt NAPI AVM loads under nixpkgs' node -----------------------
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  NAPI_DIR=amd64-linux ;;
  Linux-aarch64) NAPI_DIR=arm64-linux ;;
  Darwin-x86_64) NAPI_DIR=amd64-macos ;;
  Darwin-arm64)  NAPI_DIR=arm64-macos ;;
  *) die "unsupported host $(uname -s)-$(uname -m) for the prebuilt NAPI AVM" ;;
esac
NAPI="$DIFFSIM/node_modules/@aztec/bb.js/build/$NAPI_DIR/nodejs_module.node"
assert_file "the prebuilt NAPI AVM shipped in the npm tarball" "$NAPI"

NAPI_OUT="$(in_shell_status "$REPO_ROOT" "node -e '
  const m = { exports: {} };
  process.dlopen(m, process.argv[1]);
  const n = Object.keys(m.exports).length;
  console.log(\"napi_exports=\" + n);
' \"$NAPI\"")"
assert_contains "the prebuilt NAPI AVM dlopens under nixpkgs' node" \
  "napi_exports=" "$NAPI_OUT"
NAPI_EXPORTS="$(printf '%s\n' "$NAPI_OUT" | sed -n 's/^napi_exports=//p' | head -1)"
assert_ge "the NAPI AVM exposes native entry points" 1 "${NAPI_EXPORTS:-0}"

# ---- the suite itself ------------------------------------------------------
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
in_shell_status "$REPO_ROOT" "cd diffsim && npm test" > "$LOG" 2>&1
TEST_RC=$?

if [ "$TEST_RC" -eq 0 ]; then
  pass "diffsim's npm test exits 0 inside the dev shell"
else
  fail "diffsim's npm test failed (rc=$TEST_RC): $(tail -20 "$LOG")"
fi

SUITE_LINE="$(grep -E '^Test Suites:' "$LOG" | tail -1)"
TEST_LINE="$(grep -E '^Tests:' "$LOG" | tail -1)"

# The presence of the summary lines is itself the anti-vacuity check: jest
# with --passWithNoTests and nothing to run prints no such summary.
if [ -n "$SUITE_LINE" ]; then
  pass "jest printed a Test Suites summary  [$SUITE_LINE]"
else
  fail "jest printed no 'Test Suites:' summary — nothing ran (--passWithNoTests vacuity)"
fi
if [ -n "$TEST_LINE" ]; then
  pass "jest printed a Tests summary  [$TEST_LINE]"
else
  fail "jest printed no 'Tests:' summary — nothing ran (--passWithNoTests vacuity)"
fi

field() { # <summary-line> <label>  -> the integer preceding <label>
  printf '%s\n' "$1" | grep -oE "[0-9]+ $2" | head -1 | grep -oE '^[0-9]+'
}

SUITES_PASSED="$(field "$SUITE_LINE" passed)"
SUITES_FAILED="$(field "$SUITE_LINE" failed)"
TESTS_PASSED="$(field "$TEST_LINE" passed)"
TESTS_FAILED="$(field "$TEST_LINE" failed)"

assert_ge "test suites passed" "$MIN_SUITES" "${SUITES_PASSED:-0}"
assert_ge "tests passed" "$MIN_TESTS" "${TESTS_PASSED:-0}"
assert_eq "no test suite failed" "0" "${SUITES_FAILED:-0}"
assert_eq "no test failed" "0" "${TESTS_FAILED:-0}"

# ---- the C++ half is genuinely exercised -----------------------------------
# These four suites drive the native NAPI AVM through
# src/public/public_tx_simulator/cpp_vs_ts_public_tx_simulator.ts. If the
# harness ever degrades to TypeScript-only, the differential is meaningless
# and these lines disappear.
LOG_BODY="$(cat "$LOG")"
# opcode_spam.test.ts is deliberately NOT in this list: it is env-gated behind
# RUN_AVM_OPCODE_SPAM and is the one suite jest reports as skipped in a default
# run (43 passed + 1 skipped of 44).
for suite in \
  "src/public/public_processor/apps_tests/deployments.test.ts" \
  "src/public/public_processor/apps_tests/token.test.ts" \
  "src/public/public_tx_simulator/apps_tests/bench.test.ts"
do
  assert_contains "the C++-vs-TS suite $suite passed" "PASS $suite" "$LOG_BODY"
done

finish
