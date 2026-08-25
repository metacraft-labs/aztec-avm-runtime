#!/usr/bin/env bash
# verify_differential_job_separate_failure_domain
#
# Failing the differential job does not fail the browser bundle build or the unit, app-test and
# world-state fidelity suites.
#
# WHY IT IS A REQUIREMENT. This job compares the shipped wasm AVM against an oracle that is
# DELIBERATELY out of date — sixty days and 2,012 commits behind upstream's tip (DRIFT.md D6, D15,
# and `just version-gap` prints the numbers). An oracle like that will eventually disagree for
# reasons that are facts about the oracle. When it does, everything else must stay green, or the
# whole tree becomes hostage to a pin nobody can move.
#
# THREE QUESTIONS, and the third is the one a comment cannot answer:
#   1. the workflow's own structure — no job depends on the differential job, and it depends on no
#      other, asserted against the PARSED YAML because a job named in a comment is not a job;
#   2. no shell pipeline in it can swallow a failure — `tee` under `bash -e {0}` cannot fail, which
#      is why every step here declares `shell: bash`;
#   3. the arm is GATED, so a default `npm test` neither runs it nor can be broken by it, measured
#      by running the suite without the gate and requiring zero tests and exit 0.
#
# Run: just verify-m19

TEST_NAME="verify_differential_job_separate_failure_domain"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m19_differential.sh"

WF="$REPO_ROOT/.github/workflows/avm-wasm.yml"
assert_file "the workflow is present" "$WF"
if command -v yq >/dev/null 2>&1; then YQ="yq"; else YQ="nix shell nixpkgs#yq-go --command yq"; fi

JOB="differential-oracle"
jobs="$($YQ -r '.jobs | keys | join(" ")' "$WF" 2>/dev/null)"
[ -n "$jobs" ] || die "the workflow could not be parsed"
assert_ge "the workflow declares several jobs, so the independence below is a real relation" 5 \
  "$(printf '%s\n' $jobs | wc -l)"
assert_contains "the differential job exists as a JOB, not as a comment" "$JOB" "$jobs"

# ---- 1. structural independence, both directions ---------------------------
needs="$($YQ -r ".jobs[\"$JOB\"].needs // \"\"" "$WF" 2>/dev/null)"
assert_eq "the differential job depends on no other job" "" "$needs"
dependents=""
for j in $jobs; do
  n="$($YQ -r ".jobs[\"$j\"].needs // \"\"" "$WF" 2>/dev/null)"
  case "$n" in *"$JOB"*) dependents="$dependents $j" ;; esac
done
assert_eq "no job depends on the differential job" "" "$dependents"
# The control: the relation is computed, not assumed absent. A job that IS named as a dependency
# anywhere would show up in this same loop, so the loop is asked a question it can answer.
all_needs="$(for j in $jobs; do $YQ -r ".jobs[\"$j\"].needs // \"\"" "$WF" 2>/dev/null; done)"
assert_eq "and no job in this workflow depends on any other, so the whole matrix is independent" "" \
  "$(printf '%s\n' "$all_needs" | grep -v '^$' | tr -d ' ' || true)"

# ---- 2. no step can swallow a failure --------------------------------------
# `tee` under GitHub's default `bash -e {0}` cannot fail: the pipeline's status is tee's. Every
# step that pipes must therefore declare `shell: bash`, which turns on pipefail.
piping="$($YQ -r ".jobs[\"$JOB\"].steps[] | select(.run != null) | select(.run | test(\"\\\\|\")) | .name" "$WF" 2>/dev/null)"
assert_ge "the differential job does pipe somewhere, so this question is not vacuous" 1 \
  "$(printf '%s\n' "$piping" | grep -c . || true)"
badshell=""
while IFS= read -r name; do
  [ -z "$name" ] && continue
  sh="$($YQ -r ".jobs[\"$JOB\"].steps[] | select(.name == \"$name\") | .shell // \"\"" "$WF" 2>/dev/null)"
  [ "$sh" = "bash" ] || badshell="$badshell [$name shell=${sh:-default}]"
done <<EOF
$piping
EOF
assert_eq "every piping step declares shell: bash, so a pipeline cannot report success" "" "$badshell"

# ---- 3. the gate: a default run neither executes the arm nor is broken by it -
[ -d "$DIFFSIM_DIR/node_modules/@aztec/native" ] \
  || die "diffsim's packages are not installed. Remedy: cd $DIFFSIM_DIR && npm ci"
require_work_dir "$M19_WORK" 1
ungated="$M19_WORK/ungated.log"
( cd "$DIFFSIM_DIR" && NODE_NO_WARNINGS=1 node --experimental-vm-modules ./node_modules/.bin/jest \
    --passWithNoTests "$M19_SUITE" ) >"$ungated" 2>&1
rc=$?
assert_eq "without RUN_THREE_WAY the arm's suite exits 0" "0" "$rc"
assert_eq "and runs no test at all" "" "$(m19_tests_passed "$ungated")"
assert_contains "reporting them as skipped rather than as passed" "skipped" "$(cat "$ungated")"

# And the pairing: WITH the gate it runs a real number of tests, so the gate is a gate rather than
# a permanently-off switch. Measured against the recorded count, not against zero.
m19_require_module
gated="$M19_WORK/gated.log"
m19_run_arm "$gated"
assert_eq "with RUN_THREE_WAY it exits 0" "0" "$?"
assert_eq "and runs the recorded number of tests" \
  "$(m19_json "$M19_COUNTS" 'd["testCounts"]["totalPassed"]')" "$(m19_tests_passed "$gated")"

# ---- 4. the arm's failure cannot reach the other suites --------------------
# The strongest available statement short of running every other suite twice: the arm's sources are
# reachable from NOTHING except its own test file, so no other suite can import a module whose
# failure it would inherit.
importers="$(cd "$REPO_ROOT/diffsim/src" && grep -rl "public_tx_simulator/differential/" . | sed 's|^\./||' | sort)"
assert_ge "something does import the arm, so this enumeration is not empty" 1 \
  "$(printf '%s\n' "$importers" | grep -c . )"
outside="$(printf '%s\n' "$importers" | grep -v '^differential/' | grep -v '^public/public_tx_simulator/differential/' || true)"
assert_eq "and nothing outside the arm's own directories imports it" "" "$outside"
assert_eq "the shipped package does not import it either" "0" \
  "$(cd "$REPO_ROOT" && grep -rl 'public_tx_simulator/differential/' orchestration/src node-host/src 2>/dev/null | wc -l)"

finish
