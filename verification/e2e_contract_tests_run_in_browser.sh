#!/usr/bin/env bash
# e2e_contract_tests_run_in_browser
#
#   verification/e2e_contract_tests_run_in_browser.sh   (or: just verify-contract-tests-in-browser)
#
# ===========================================================================================
# WHAT IS UNDER TEST, AND WHY IT IS SMALL.
# ===========================================================================================
#
# "minimal support for executing javascript-based smart contract test suites in the browser."
#
# The subject is `browser/testkit/` — a test runner (`runner.js`) and one real Aztec contract test
# suite (`token.suite.js`) — running in a real headless tab against `browser/dist/testing.js` as
# `browser/build.mjs` emitted it. The testkit is NOT an entry point and does not go through the
# bundler: it is ES modules the page imports beside the shipped one. So a test runner existing costs
# the shipped artefact nothing, and M28's input count, the DD-5 entry-point shape and every chunk
# budget are untouched by it. That is the whole of "minimal", and it is checkable: §1 below asserts
# the testkit is absent from the bundle's module graph.
#
# The suite is a port of upstream's own smallest real contract test,
# `yarn-project/simulator/src/public/avm/apps_tests/token.test.ts` (vendored at
# `spike/src/public/avm/apps_tests/token.test.ts`, RI-24). Five of its six imports already reach a
# browser; the sixth is `NativeWorldStateService`, the LMDB NAPI addon, and this runtime replaced it
# with `ResidentMerkleWriteOperations` over `avm.wasm`. The port is a substitution of ONE object.
#
# ===========================================================================================
# THE DEFECT THIS CHECK IS SHAPED AROUND: A TEST THAT PASSES BECAUSE IT NEVER RAN.
# ===========================================================================================
#
# A green test report and a report from a suite that failed to load print the same way — an empty
# list of failures. This campaign has seventeen recorded instances of machinery that was present,
# correct and never called, plus a checker that printed `ok: 0/0 published files match` and exited 0
# while checking nothing. So NOTHING HERE ASSERTS THE ABSENCE OF FAILURES ALONE. Every green is
# joined to a count, and the count is asserted:
#
#   * the number of tests executed is asserted, and asserted NON-ZERO;
#   * `executed` and `completed` are asserted EQUAL, so a body that was entered and never returned
#     is red rather than silent;
#   * the number of expectations is asserted, and asserted non-zero;
#   * and four negative-control arms establish that the runner can report failure at all.
#
# ===========================================================================================
# THE FOUR CONTROLS, AND WHAT EACH ONE WOULD CATCH.
# ===========================================================================================
#
#   mutated     ONE constant in a COPY of the suite — the expected transferred amount, 5 -> 6.
#               Requires `status: failed`, EXACTLY ONE red test, and that red test to be the
#               balance one BY NAME with `expected 6` / `actual 5`. A runner that cannot report
#               failure has not been shown to work; a runner that reports failure by turning
#               everything red has not been shown to be discriminating, so the ten still-green
#               tests are asserted too. The driver asserts the mutation APPLIED — a `replace` that
#               matched nothing would serve the original and produce a green "fail arm", which is
#               the vacuous mutation arm this campaign names: an arm whose premise has moved
#               reports "could not be measured" forever while looking like coverage.
#   loadError   A suite URL that 404s. Must be `error` / `load-failed`. This is the arm that says a
#               suite which fails to load is a HARD FAILURE rather than an empty pass.
#   emptySuite  A suite that registers nothing. Must be `error` / `no-tests` — the
#               `0/0 … exited 0` shape, refused by name.
#   noExpect    Two tests, one of which asserts nothing. The silent one must be failed by name with
#               `no-expectations` AND the asserting one must still pass, so the rule is shown to be
#               discriminating rather than merely strict.
#
# ===========================================================================================
# AND THE FALSE PASS SPECIFIC TO THIS AREA: `ok` WHILE CARRYING ZERO STEPS.
# ===========================================================================================
#
# `outcome === 'processed'` is the BLOCK's verdict and is true of a transaction that reverted at
# instruction one — M29 measured exactly that. So §4 asserts the suite CONTAINS tests that measure
# the executed step stream, by name, and asserts that they passed. A suite that quietly dropped
# them would leave every other assertion here true.

TEST_NAME="e2e_contract_tests_run_in_browser"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is required"

CT_WORK="${CT_WORK:-$HOME/.cache/aztec-contract-tests}"
CT_ARMS="$CT_WORK/arms.json"
TESTKIT="$REPO_ROOT/browser/testkit"
DIST="$REPO_ROOT/browser/dist"

[ -d "$TESTKIT" ] || die "no $TESTKIT — this check's subject does not exist"

# ---------------------------------------------------------------------------
# The arm run. Refreshed when anything it measures is newer than the report.
# ---------------------------------------------------------------------------
ct_stale() {
  [ -s "$CT_ARMS" ] || { printf 'arms.json\n'; return 0; }
  find "$TESTKIT" "$REPO_ROOT/tools/run_contract_test_arms.mjs" "$REPO_ROOT/tools/browser_cdp.mjs" \
    -type f ! -name '.*' -newer "$CT_ARMS" -print -quit 2>/dev/null || true
  find "$DIST" -type f ! -name '.*' -newer "$CT_ARMS" -print -quit 2>/dev/null || true
}

CT_CHROMIUM="${CT_CHROMIUM:-${M27_CHROMIUM:-$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)}}"
[ -n "$CT_CHROMIUM" ] || die "no chromium. The suite runs in a real headless browser over the
             DevTools protocol; there is no substitute that would be evidence.
             Remedy: install chromium, or set CT_CHROMIUM."

AVM_WASM_PATH="${AVM_WASM_PATH:-$HOME/.cache/aztec-m27-browser/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm}"
[ -s "$AVM_WASM_PATH" ] || die "no avm.wasm at $AVM_WASM_PATH.
             Remedy: just avm-wasm-build-m27, or set AVM_WASM_PATH."
[ -s "$DIST/testing.js" ] || die "no built bundle at $DIST. Remedy: node browser/build.mjs"

mkdir -p "$CT_WORK"
CT_STALE="$(ct_stale)"
if [ -n "$CT_STALE" ] || [ "${CT_ARMS_REFRESH:-0}" = "1" ]; then
  note "running the contract-test arms in $("$CT_CHROMIUM" --version 2>/dev/null | head -1) (input newer: ${CT_STALE:-forced})"
  # THE FAILED RUN'S OWN REPORT IS KEPT. The driver records an arm's failure inside the JSON and
  # writes it; discarding the output on a non-zero exit throws away the only diagnostic. That is a
  # recorded defect of `m27_require_arms`, and this is the same remedy.
  if AVM_WASM_PATH="$AVM_WASM_PATH" CT_CHROMIUM="$CT_CHROMIUM" \
       timeout -s KILL "${CT_ARMS_TIMEOUT:-900}" \
       node "$REPO_ROOT/tools/run_contract_test_arms.mjs" "$CT_WORK" \
       >"$CT_ARMS.tmp.$$" 2>"$CT_WORK/arms.err.$$"; then
    mv -f "$CT_ARMS.tmp.$$" "$CT_ARMS" || die "the arm run succeeded but its report could not be installed at $CT_ARMS"
  else
    rc=$?
    mv -f "$CT_ARMS.tmp.$$" "$CT_WORK/arms-failed.json" 2>/dev/null || true
    die "the contract-test arm run failed (exit $rc).
             Report: $CT_WORK/arms-failed.json; stderr: $CT_WORK/arms.err.$$"
  fi
  # STILL STALE AFTER A REFRESH means the refresh did not take, and every assertion below would be
  # about the wrong artefact. `CAMPAIGN-BRIEF.md` calls this "a mutated artefact outlived its
  # restored source".
  STILL="$(ct_stale)"
  [ -z "$STILL" ] || die "the arm run did not refresh $CT_ARMS: '$STILL' is still newer than it"
fi
[ -s "$CT_ARMS" ] || die "the contract-test arm run produced no output"

# One field, dotted. Prints MISSING rather than empty, so an assertion against a typo'd path FAILS
# instead of comparing two absences.
ct() { # <dotted path>
  python3 - "$CT_ARMS" "$1" <<'PY'
import json, sys
node = json.load(open(sys.argv[1]))
for part in sys.argv[2].split('.'):
    if part == '':
        continue
    if isinstance(node, dict) and part in node:
        node = node[part]
    elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
        node = node[int(part)]
    else:
        print('MISSING'); sys.exit(0)
if node is None: print('MISSING')
elif isinstance(node, (list, dict)): print(json.dumps(node, separators=(',', ':'), sort_keys=True))
elif isinstance(node, bool): print('true' if node else 'false')
else: print(node)
PY
}

# One arm's test outcomes, as `status<TAB>reason<TAB>name` lines.
ct_tests() { # <arm>
  python3 - "$CT_ARMS" "$1" <<'PY'
import json, sys
arm = json.load(open(sys.argv[1])).get('arms', {}).get(sys.argv[2])
if arm is None or arm.get('report') is None:
    print('MISSING\tMISSING\tMISSING'); sys.exit(0)
for t in arm['report'].get('tests', []):
    print(f"{t['status']}\t{t.get('reason', '-')}\t{t['name']}")
PY
}

note "chromium: $(ct chromium)"
note "avm.wasm: $(ct avmWasm.bytes) bytes, sha256 $(ct avmWasm.sha256)"
note "artifact: Token from $(ct artifact.root), $(ct artifact.bytes) bytes; search residue $(ct artifact.search)"
note "shipped testing.js: $(ct shipped.testingJsBytes) bytes, sha256 $(ct shipped.testingJsSha256)"

echo "== 1. the testkit costs the shipped bundle nothing"

# THE "minimal" CLAIM, AS A MEASUREMENT. If the testkit were an entry point or an import of one, it
# would be in the bundle's module graph, M28's input count would have moved, and the chunk budgets
# would be about different bytes. It is not, and the metafile is the instrument.
META="$DIST/meta.json"
assert_file "the bundle metafile exists to be read" "$META"
TESTKIT_INPUTS="$(python3 - "$META" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print(sum(1 for k in m.get('inputs', {}) if 'browser/testkit/' in k))
PY
)"
assert_eq "the shipped module graph reaches the testkit 0 times" 0 "$TESTKIT_INPUTS"
# THE NON-EMPTINESS PARTNER, because `0` over an empty metafile is not a measurement.
TOTAL_INPUTS="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("inputs", {})))' "$META")"
assert_true "…and that zero was taken over a graph with inputs in it ($TOTAL_INPUTS)" test "$TOTAL_INPUTS" -gt 100

echo "== 2. the suite ran, in a tab, against the SHIPPED module"

assert_eq "the page fetched the shipped testing.js exactly once" 1 "$(ct arms.pass.fetchedTesting)"
assert_eq "…and avm.wasm exactly once" 1 "$(ct arms.pass.fetchedAvmWasm)"
assert_eq "the page threw nothing" "[]" "$(ct arms.pass.pageErrors)"
assert_eq "…and logged no console error" "[]" "$(ct arms.pass.consoleErrors)"

echo "== 3. the counts, and the counts are the point"

PASS_STATUS="$(ct arms.pass.report.status)"
PASS_TOTAL="$(ct arms.pass.report.total)"
PASS_EXEC="$(ct arms.pass.report.executed)"
PASS_DONE="$(ct arms.pass.report.completed)"
PASS_PASSED="$(ct arms.pass.report.passed)"
PASS_FAILED="$(ct arms.pass.report.failed)"
PASS_ASSERTIONS="$(ct arms.pass.report.assertions)"

assert_eq "the suite reports ok" "ok" "$PASS_STATUS"
# NON-ZERO FIRST, THEN THE EXACT NUMBER. `assert_eq 11` alone would go green if the suite shrank to
# 11 trivial tests, but it would ALSO have gone green at 0 if the constant were wrong — the
# non-emptiness partner is what makes the exact figure a floor rather than a coincidence.
assert_true "the suite executed a non-zero number of tests" test "$PASS_EXEC" -gt 0
assert_eq "…eleven of them" 11 "$PASS_TOTAL"
assert_eq "…every registered test was entered" "$PASS_TOTAL" "$PASS_EXEC"
# `executed == completed` is the suspended-body check. A body that was entered and never came back
# is invisible to a count of failures.
assert_eq "…and every entered body came back" "$PASS_EXEC" "$PASS_DONE"
assert_eq "all eleven passed" 11 "$PASS_PASSED"
assert_eq "…none failed" 0 "$PASS_FAILED"
assert_true "the suite made a non-zero number of expectations" test "$PASS_ASSERTIONS" -gt 0
assert_eq "…thirty-one of them" 31 "$PASS_ASSERTIONS"

echo "== 4. the tests that refuse the zero-step false pass are PRESENT and green"

PASS_TESTS="$(ct_tests pass)"
# A suite that quietly dropped these would leave every assertion in §3 true, because §3 is about
# counts and these are about which measurements were taken.
assert_contains "a test measures the executed step stream" \
  "the AVM actually ran > produced a non-trivial executed step stream" "$PASS_TESTS"
assert_contains "…and it passed" \
  "passed	-	the AVM actually ran > produced a non-trivial executed step stream" "$PASS_TESTS"
assert_contains "a test compares the drained count against the module's own statistic" \
  "passed	-	the AVM actually ran > agrees with the module about how many instructions it executed" "$PASS_TESTS"
assert_contains "a test requires more than one call context" \
  "passed	-	the AVM actually ran > executed across more than one call context" "$PASS_TESTS"
assert_contains "a test asserts the transaction did not revert" \
  "passed	-	Token contract, in this tab > does not revert" "$PASS_TESTS"
assert_contains "a test asserts the balance moved" \
  "passed	-	Token contract, in this tab > moves the balance: sender 1000 -> 995, receiver EMPTY -> 5" "$PASS_TESTS"

echo "== 5. the fail demonstration — mutated, and DISCRIMINATING"

assert_eq "the mutation's premise still exists in the suite source" "true" "$(ct mutation.applied)"
assert_eq "…and the mutant differs from it" "true" "$(ct mutation.changed)"
assert_eq "the mutated suite reports failed, not ok" "failed" "$(ct arms.mutated.report.status)"
assert_eq "…over the same eleven tests" 11 "$(ct arms.mutated.report.total)"
assert_eq "…with exactly one red" 1 "$(ct arms.mutated.report.failed)"
assert_eq "…and the other ten still green" 10 "$(ct arms.mutated.report.passed)"

MUT_TESTS="$(ct_tests mutated)"
assert_contains "the red one is the balance test, by name" \
  "failed	expectation	Token contract, in this tab > moves the balance" "$MUT_TESTS"
# THE DIFF ITSELF, so "it went red" cannot be satisfied by going red for another reason.
MUT_RED="$(python3 - "$CT_ARMS" <<'PY'
import json, sys
tests = json.load(open(sys.argv[1]))['arms']['mutated']['report']['tests']
red = [t for t in tests if t['status'] != 'passed']
print('|'.join(f"{t.get('matcher','-')}:{t.get('expected','-')}:{t.get('actual','-')}" for t in red) or 'NONE')
PY
)"
assert_eq "…and it went red on the mutated constant, not on something else" 'toBe:"6":"5"' "$MUT_RED"

echo "== 6. a suite that cannot load is a HARD FAILURE, not an empty pass"

assert_eq "a 404 suite reports error" "error" "$(ct arms.loadError.report.status)"
assert_eq "…named load-failed" "load-failed" "$(ct arms.loadError.report.reason)"
assert_eq "…with zero tests, which is NOT reported as ok" 0 "$(ct arms.loadError.report.total)"
assert_contains "…and it names the module it could not fetch" "no_such_suite.js" "$(ct arms.loadError.report.message)"

echo "== 7. a suite that registers nothing is refused by name"

assert_eq "an empty suite reports error" "error" "$(ct arms.emptySuite.report.status)"
assert_eq "…named no-tests" "no-tests" "$(ct arms.emptySuite.report.reason)"
assert_contains "…and says why an empty suite is not a pass" \
  "An empty suite is a failure to load, not a pass." "$(ct arms.emptySuite.report.message)"

echo "== 8. a test that asserts nothing fails, and its asserting sibling still passes"

NOEXPECT_TESTS="$(ct_tests noExpect)"
assert_eq "the no-expectation arm reports failed" "failed" "$(ct arms.noExpect.report.status)"
assert_eq "…two tests" 2 "$(ct arms.noExpect.report.total)"
assert_contains "the silent test is failed, by name, with no-expectations" \
  "failed	no-expectations	control > asserts nothing at all" "$NOEXPECT_TESTS"
# THE DISCRIMINATION PARTNER. A runner that failed every test would satisfy the line above.
assert_contains "…and the asserting one still passes, so the rule is not merely strict" \
  "passed	-	control > asserts something" "$NOEXPECT_TESTS"
assert_eq "…exactly one of the two is red" 1 "$(ct arms.noExpect.report.failed)"

finish
