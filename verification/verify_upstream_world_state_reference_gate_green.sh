#!/usr/bin/env bash
# verify_upstream_world_state_reference_gate_green — M8.
#
# THE FIDELITY GATE IS UPSTREAM'S, AND IT IS REUSED RATHER THAN REBUILT.
#
# The milestone asks for "upstream's `world_state_tests` reference-versus-real comparison run in our
# CI at the pinned commit, as the standing fidelity gate, rather than a dual-run harness of ours".
# That comparison exists and is precise:
# `barretenberg/cpp/src/barretenberg/world_state/memory_merkle_db.test.cpp`, whose own header says
# it "is the canonical-fidelity gate for MemoryMerkleDB". Seven `TEST_F(MemoryMerkleDBEquivalenceTest,
# …)` cases drive an ephemeral, FILE-BACKED `world_state::WorldState` and an in-memory
# `MemoryMerkleDB` through the same sequence and compare, after every step, roots, sibling paths,
# low-leaf lookups, indexed-leaf preimages and leaf values.
#
# So nothing here is a harness of ours. What this check does is: assert the gate is upstream's own
# and unmodified at the pinned anchor, assert it really is reference-versus-REAL rather than
# reference-versus-reference, RUN it, and assert its result per test rather than by a pass count.
#
# WHY IT IS NATIVE. `world_state` is LMDB-backed, so `bin/world_state_tests` exists in a native
# configure and not in a wasm one — asserted both ways below, which is also why these seven are
# outside M7's 391. The gate is therefore about the reference implementation's fidelity to the real
# one; that it behaves identically under wasm is what the rest of M8 measures.

TEST_NAME="verify_upstream_world_state_reference_gate_green"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m8_differential.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
m8_measured

ANCHOR="$(m8_anchor)"
GATE_IN_TREE="$M8_TREE/$M8_GATE_SOURCE"
m8_require_artifacts "$GATE_IN_TREE"

# ---------------------------------------------------------------------------
echo "== 1. the gate is upstream's own, unmodified at the pinned anchor"
# ---------------------------------------------------------------------------
UP_GATE="$M8_WORK/upstream-memory_merkle_db.test.cpp"
m8_upstream_file "$M8_GATE_SOURCE" "$UP_GATE"
assert_true "the gate source in the prepared tree is byte-identical to upstream at the anchor" \
  cmp -s "$UP_GATE" "$GATE_IN_TREE"
assert_eq "no patch in the series touches it" "0" \
  "$(git -C "$M8_TREE" log --oneline "$M6_BASE_REV..HEAD" -- "$M8_GATE_SOURCE" | grep -c . || true)"
assert_contains "upstream's own header calls it the canonical-fidelity gate" \
  "canonical-fidelity gate for MemoryMerkleDB" "$(cat "$UP_GATE")"

# It is reference-versus-REAL. Asserted from the source, because a comparison of the reference
# against another copy of the reference would be the one shape that makes the whole gate worthless.
assert_contains "it constructs a real, file-backed world_state::WorldState" \
  "std::make_unique<WorldState>" "$(cat "$UP_GATE")"
assert_contains "…on a real temporary directory" "random_temp_directory" "$(cat "$UP_GATE")"
assert_contains "…and an in-memory MemoryMerkleDB beside it" \
  "std::make_unique<MemoryMerkleDB>" "$(cat "$UP_GATE")"
for what in get_tree_info get_sibling_path find_low_leaf_index get_indexed_leaf get_leaf; do
  assert_contains "…and compares the two on $what" "ws->$what" "$(cat "$UP_GATE")"
done
assert_eq "the prefills it uses are the 128/128 MemoryMerkleDB defaults" "2" \
  "$(grep -cE 'constexpr size_t (NULLIFIER|PUBLIC_DATA)_PREFILL = 128;' "$UP_GATE" || true)"

# The seven cases, derived from the source rather than restated from a list only we maintain.
DECLARED="$M8_WORK/gate-declared.txt"
sed -n "s/^TEST_F($M8_GATE_SUITE, \([A-Za-z0-9_]*\)).*/\1/p" "$UP_GATE" | LC_ALL=C sort -u >"$DECLARED"
EXPECTED="$M8_WORK/gate-expected.txt"
printf '%s\n' $M8_GATE_TESTS | LC_ALL=C sort -u >"$EXPECTED"
assert_eq "upstream declares seven equivalence cases" "7" "$(grep -c . "$DECLARED" || true)"
assert_true "…and they are the seven this milestone names, by name" cmp -s "$DECLARED" "$EXPECTED"

# ---------------------------------------------------------------------------
echo "== 2. the target: native only, and that is measured both ways"
# ---------------------------------------------------------------------------
NATIVE_TARGETS="$M8_WORK/native-targets.txt"
WASM_TARGETS="$M8_WORK/wasm-targets.txt"
m6_ninja_targets "$M8_TREE" "$M8_NATIVE_BUILD" >"$NATIVE_TARGETS"
m6_ninja_targets "$M8_TREE" "$M8_WASM_BUILD" >"$WASM_TARGETS"
assert_ge "the native target list is real" 100 "$(grep -c . "$NATIVE_TARGETS" || true)"
assert_ge "the wasm target list is real" 100 "$(grep -c . "$WASM_TARGETS" || true)"
assert_ge "bin/world_state_tests is a native target" 1 \
  "$(grep -c '^bin/world_state_tests$' "$NATIVE_TARGETS" || true)"
assert_eq "bin/world_state_tests is NOT a wasm target" "0" \
  "$(grep -c '^bin/world_state_tests$' "$WASM_TARGETS" || true)"
# Not vacuous: the wasm list does carry the differential driver, so it is not simply short.
assert_ge "…and the wasm list is not empty of binaries: it carries bin/avm_differential" 1 \
  "$(grep -c '^bin/avm_differential$' "$WASM_TARGETS" || true)"
# WHY it is native-only, read out of the tree rather than guessed. It is NOT that lmdblib is
# missing from a wasm configure — M6 measured that `lmdblib` is a real target in any wasm configure,
# because `src/CMakeLists.txt` guards it with `if(NOT BB_LITE)` and not `NOT WASM`. The reason is
# one line further down: the `world_state/` subdirectory itself is only added when NOT WASM, so the
# `world_state_tests` target is never created there.
SRC_CMAKE="$M8_TREE/barretenberg/cpp/src/CMakeLists.txt"
assert_file "src/CMakeLists.txt is in the prepared tree" "$SRC_CMAKE"
assert_eq "world_state/ is added under exactly one guard, and it excludes WASM" "1" \
  "$(grep -B1 '^ *add_subdirectory(barretenberg/world_state)$' "$SRC_CMAKE" \
     | grep -c 'if(NOT FUZZING AND NOT WASM AND NOT BB_LITE)' || true)"
assert_ge "…while lmdblib IS added in any configure, so its presence is not the discriminator" 1 \
  "$(grep -c '^ *add_subdirectory(barretenberg/lmdblib)$' "$SRC_CMAKE" || true)"
assert_ge "…and lmdblib is consequently a target in the wasm build too" 1 \
  "$(grep -c 'liblmdblib\.a$' "$WASM_TARGETS" || true)"
assert_ge "…as it is in the native one" 1 \
  "$(grep -c 'liblmdblib\.a$' "$NATIVE_TARGETS" || true)"

GATE_BIN="$(m8_native_bin world_state_tests)"
m8_require_artifacts "$GATE_BIN"

# The gtest the gate runs on is the pinned, FetchContent'd one and not whatever the host has under
# /usr/lib. M7's build check found the native side silently taking the system gtest 1.17.0 while
# the wasm side used 1.13.0 — two different test frameworks on the two sides of a parity
# comparison. `FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER` forces one; it is asserted, not assumed.
assert_eq "the native configure was told never to find_package a dependency" "NEVER" \
  "$(m6_cache "$M8_TREE" "$M8_NATIVE_BUILD" FETCHCONTENT_TRY_FIND_PACKAGE_MODE)"
assert_ge "…so googletest is built from source in this tree" 1 \
  "$(grep -c 'libgtest\.a$' "$NATIVE_TARGETS" || true)"
assert_eq "…and the gate binary does not link a system libgtest" "0" \
  "$(ldd "$GATE_BIN" 2>/dev/null | grep -c 'libgtest' || true)"

# ---------------------------------------------------------------------------
echo "== 3. run it"
# ---------------------------------------------------------------------------
GATE_LOG="$M8_WORK/world-state-gate.log"
m7_run_native "$GATE_BIN" "$GATE_LOG" "--gtest_filter=$M8_GATE_SUITE.*"
GATE_RC=$?
# Exit status FIRST and separately from anything parsed out of the transcript. `green_summary_exit7`
# exists in this repo precisely because a binary can print a complete green summary and exit 7.
assert_eq "the gate exits 0" "0" "$GATE_RC"
m8_require_artifacts "$GATE_LOG"
assert_eq "gtest's own summary reports seven tests from one suite" "7" \
  "$(m7_summary_ran "$GATE_LOG")"
assert_eq "…from exactly one suite" "1" "$(m7_summary_suites "$GATE_LOG")"
assert_eq "gtest's own PASSED line reports seven" "7" "$(m7_summary_passed "$GATE_LOG")"
assert_eq "no test is reported as failed" "0" \
  "$(grep -c '^\[  FAILED  \]' "$GATE_LOG" || true)"

# Per test, by name, never by count: an equal count survives a rename or a drop plus an addition.
OK_NAMES="$M8_WORK/gate-ok.txt"
m8_gtest_ok_names "$GATE_LOG" | sed "s/^$M8_GATE_SUITE\.//" >"$OK_NAMES"
assert_true "the seven tests that passed are the seven upstream declares, per test" \
  cmp -s "$OK_NAMES" "$DECLARED"
while read -r t; do
  assert_true "$M8_GATE_SUITE.$t passed" grep -q "^\[       OK \] $M8_GATE_SUITE\.$t" "$GATE_LOG"
done <"$DECLARED"

# ---------------------------------------------------------------------------
echo "== 4. negative controls"
# ---------------------------------------------------------------------------
# (1) gtest exits 0 when a filter matches NOTHING. That is the exact way this check could report a
#     green gate having run no comparison at all, so it is exercised rather than reasoned about.
EMPTY_LOG="$M8_WORK/world-state-gate-empty.log"
m7_run_native "$GATE_BIN" "$EMPTY_LOG" "--gtest_filter=NoSuchSuite.NoSuchTest"
EMPTY_RC=$?
assert_eq "control: a filter matching nothing still exits 0" "0" "$EMPTY_RC"
assert_eq "control: …and it is the ran-count assertion that catches it, not the exit status" "0" \
  "$(m7_summary_ran "$EMPTY_LOG")"
assert_eq "control: …and no test name is reported OK" "0" "$(m8_gtest_ok_names "$EMPTY_LOG" | grep -c . || true)"

# (2) A subset filter must run FEWER than seven, so the count above is a property of the filter we
#     used and not a constant the binary always prints.
ONE_LOG="$M8_WORK/world-state-gate-one.log"
m7_run_native "$GATE_BIN" "$ONE_LOG" "--gtest_filter=$M8_GATE_SUITE.GenesisMatches"
assert_eq "control: a one-test filter exits 0" "0" "$?"
assert_eq "control: …and runs exactly one" "1" "$(m7_summary_ran "$ONE_LOG")"

# (3) The whole binary carries much more than these seven, so "7 ran" is a statement about the
#     filter and the suite rather than about a small binary.
ALL_LIST="$M8_WORK/world-state-all.list"
m7_run_native "$GATE_BIN" "$ALL_LIST" "--gtest_list_tests"
assert_eq "control: the gate binary lists its tests" "0" "$?"
ALL_COUNT="$(m7_names list "$ALL_LIST" | grep -c . || true)"
assert_ge "control: world_state_tests declares far more than the seven" 25 "$ALL_COUNT"
assert_eq "control: and exactly seven of them are the equivalence gate" "7" \
  "$(m7_names list "$ALL_LIST" | grep -c "^$M8_GATE_SUITE\." || true)"

# ---------------------------------------------------------------------------
echo "== 5. it is wired into our CI, at the pinned commit"
# ---------------------------------------------------------------------------
WORKFLOW="$REPO_ROOT/.github/workflows/avm-wasm.yml"
assert_file "the CI workflow exists" "$WORKFLOW"
WF="$(cat "$WORKFLOW")"
assert_contains "…and it declares a job for the M8 differential" "native-vs-wasm-differential" "$WF"
assert_contains "…which runs this milestone's checks" "just verify-m8" "$WF"
assert_contains "…and asserts the series base commit before building" "$M6_BASE_REV" "$WF"
assert_contains "…and names M8's overlay among the patches it requires" \
  "verification/m8/0001-test-vm2-AVM_DIFFERENTIAL" "$WF"
# Parsed, not grepped, wherever a YAML parser can be had — a job declared at the wrong indentation
# is a string match and not a job. The string assertions above stand either way, so this adds
# discrimination rather than being the only thing holding the claim up.
YAML_JOBS=""
if python3 -c "import yaml" >/dev/null 2>&1; then
  YAML_JOBS="$(python3 -c "import yaml;print(' '.join(yaml.safe_load(open('$WORKFLOW'))['jobs']))" 2>/dev/null)"
elif command -v yq >/dev/null 2>&1; then
  YAML_JOBS="$(yq -r '.jobs | keys | join(" ")' "$WORKFLOW" 2>/dev/null)"
elif command -v nix >/dev/null 2>&1; then
  YAML_JOBS="$(nix shell nixpkgs#yq-go --command yq -r '.jobs | keys | join(" ")' "$WORKFLOW" 2>/dev/null)"
fi
if [ -n "$YAML_JOBS" ]; then
  assert_contains "the workflow parses as YAML and declares the M8 job as a job" \
    "native-vs-wasm-differential" "$YAML_JOBS"
  assert_contains "…alongside M7's, which it must not have displaced" \
    "vm2-suite-under-wasm" "$YAML_JOBS"
else
  fail "no YAML parser was available, so the workflow's structure could not be asserted"
fi
# Reality, not a sentence in a comment.
#
# This assertion used to be `assert_contains "has never run" "$WF"` — a claim about
# whether GitHub had ever executed the job, settled by grepping a YAML comment for
# some words. That is the same class of vacuity the M10 review found in
# `assert_contains "world_state"`: the text it reads is under our own control, so it
# goes green whenever someone writes the right sentence and red whenever someone
# rewords it, and in neither case has it looked at the thing it names. M11 reworded
# the comment while fixing the workflow and the assertion went red without anything
# about the subject having changed.
#
# It is answerable now. `upstream-bugs/` is published, so this workflow CAN run, and
# whether it HAS is a fact the GitHub API will state. The assertion is that the
# repository's own claim and the API agree — which fails in BOTH directions (a
# workflow that has run while the comment still says it has not, and a comment
# claiming success the API does not show) and does not go red merely because the
# work succeeded.
if ! command -v gh >/dev/null 2>&1; then
  die "gh is not on PATH; the workflow's run history cannot be established, and a
     comment in the YAML is not a substitute for it"
fi
if ! gh auth status >/dev/null 2>&1; then
  die "gh is not authenticated; the workflow's run history cannot be established"
fi
WF_RUNS_JSON="$(gh run list --repo metacraft-labs/aztec-avm-runtime \
                  --workflow avm-wasm.yml --limit 100 \
                  --json conclusion,status 2>/dev/null)" \
  || die "could not query the workflow's run history from GitHub"
WF_SUCCESSES="$(printf '%s' "$WF_RUNS_JSON" | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
print(sum(1 for r in rows if r.get("conclusion") == "success"))' 2>/dev/null)"
case "$WF_SUCCESSES" in
  ''|*[!0-9]*) die "could not count the successful runs (got: $WF_SUCCESSES)" ;;
esac
# THE PREDICATE IS COMPUTED WITHOUT A PIPE, AND THAT IS NOT STYLE.
#
# This was `if printf '%s' "$WF" | grep -q "has never run"`, and `lib.sh` sets `pipefail`. `grep -q`
# exits at its FIRST match; `printf` is then still writing, gets SIGPIPE, and the pipeline's status
# becomes 141 rather than grep's 0 — so the `if` takes the ELSE branch and the claim reads
# "has-run" no matter what the file says.
#
# It was latent for eight milestones because it depends on SIZE. While `avm-wasm.yml` was under the
# 64 KiB pipe buffer, `printf` finished before `grep` exited and there was no SIGPIPE. M20's CI
# diagnosis grew the file from 59,102 bytes to 96,423, it crossed the buffer, and this assertion
# went red claiming the workflow said it had run — while the workflow says "has never run" NINE
# times. Reproduced in all three directions: with pipefail at 96 KiB the pipeline exits 141 and the
# claim is has-run; without pipefail it is never-run; with pipefail at the 59 KiB version it is
# never-run.
#
# `case` is a builtin pattern match: no pipeline, no subshell, no buffer, no size dependence.
#
# The predicate's own controls, both directions, so it cannot go back to being unable to say "no".
# Written as ASSERTIONS rather than as bare `fail` guards: a control that prints nothing when it
# passes is a control nobody can audit, and it does not appear in the count either.
claim_of() { # <text> -> never-run | has-run, by the SAME predicate as above
  case "$1" in
    *"has never run"*) printf 'never-run\n' ;;
    *)                 printf 'has-run\n' ;;
  esac
}
assert_eq "control: the claim predicate recognises the phrase it looks for" "never-run" \
  "$(claim_of "a workflow comment that says this job has never run")"
assert_eq "control: and does NOT match text that lacks it" "has-run" \
  "$(claim_of "a workflow comment that says nothing of the sort")"
WF_CLAIM="$(claim_of "$WF")"
assert_ge "the workflow is large enough that a piped predicate would have been size-dependent" \
  65536 "$(wc -c < "$WORKFLOW")"
if [ "$WF_SUCCESSES" -eq 0 ]; then WF_REALITY="never-run"; else WF_REALITY="has-run"; fi
note "GitHub reports $WF_SUCCESSES successful run(s) of avm-wasm.yml"
assert_eq "the workflow's recorded state agrees with its actual run history on GitHub" \
  "$WF_REALITY" "$WF_CLAIM"

finish
