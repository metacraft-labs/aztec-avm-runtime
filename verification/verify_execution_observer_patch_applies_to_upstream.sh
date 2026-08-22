#!/usr/bin/env bash
# verify_execution_observer_patch_applies_to_upstream
#
# The prepared patch applies cleanly to the stated base, and the result BUILDS AND PASSES
# UPSTREAM'S OWN AVM TESTS.
#
# "Applies cleanly" is not enough on its own and M3's review said why: a patch can be altered and
# still apply. So the resulting TREE HASH is pinned, and the `From` line is required to name the
# anchor. And "passes upstream's own tests" is a comparison rather than a green summary: the
# unpatched anchor is built and run in the same environment, and the two runs are compared PER TEST
# NAME. Equal counts survive a rename, a drop plus an addition, and a filter that matched nothing.
#
# The target is upstream's OWN `vm2_tests`, from upstream's OWN `default` preset, in a tree carrying
# the one patch under review and nothing else of ours. The prepared PR.md listed "vm2_tests was not
# run" as a limitation; it is run here, on both sides, and the limitation is closed.
#
# This check also carries the milestone's own outstanding task from M6, M7 and M8: the prepared
# `verify.sh` beside the patch shipped with a `SKIPPED` branch that exited 0 (line 79 — the fifth
# such branch in this campaign). Its replacement is asserted here to have no skip path, to name a
# distinct exit status for a precondition it cannot meet, and to fail when it asserted nothing.

set -uo pipefail
TEST_NAME=verify_execution_observer_patch_applies_to_upstream
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m9_observer.sh"

mkdir -p "$M9_WORK"
anchor="$(m8_anchor)"
assert_true "the anchor was read from pins.json" test -n "$anchor"

# ---------------------------------------------------------------------------
# The patch, as a file.
# ---------------------------------------------------------------------------
assert_file "the prepared patch exists" "$M9_OBSERVER_PATCH"
assert_dir "the write-up directory exists" "$M9_OBSERVER_DIR"
assert_file "PR.md is beside it" "$M9_OBSERVER_DIR/PR.md"
assert_file "and a verification script" "$M9_OBSERVER_DIR/verify.sh"
# upstream-bugs/CLAUDE.md reserves ISSUE.md + reproduce.sh for a DEFECT report. This is a feature
# contribution, so the pair must be PR.md + verify.sh and the other two must not exist.
assert_false "there is no ISSUE.md (this is not a defect report)" \
  test -f "$M9_OBSERVER_DIR/ISSUE.md"
assert_false "and no reproduce.sh" test -f "$M9_OBSERVER_DIR/reproduce.sh"

files="$(grep '^diff --git a/' "$M9_OBSERVER_PATCH" | sed 's|^diff --git a/||; s| b/.*$||' | LC_ALL=C sort)"
assert_eq "the patch touches seven files" "7" "$(printf '%s\n' "$files" | grep -c .)"
assert_eq "and every one of them is under barretenberg/cpp/src/barretenberg/vm2/" "7" \
  "$(printf '%s\n' "$files" | grep -c '^barretenberg/cpp/src/barretenberg/vm2/')"
assert_eq "three files are created" "3" "$(grep -c '^new file mode' "$M9_OBSERVER_PATCH")"
assert_eq "and none is deleted" "0" "$(grep -c '^deleted file mode' "$M9_OBSERVER_PATCH")"
added="$(grep -c '^+[^+]' "$M9_OBSERVER_PATCH")"
removed="$(grep -c '^-[^-]' "$M9_OBSERVER_PATCH")"
assert_eq "the diffstat line the patch carries is +148/-4" "1" \
  "$(grep -c '^ 7 files changed, 148 insertions(+), 4 deletions(-)$' "$M9_OBSERVER_PATCH")"
note "counted from the hunks: +$added / -$removed"
assert_eq "no test source is added or changed" "0" \
  "$(printf '%s\n' "$files" | grep -c '\.test\.cpp$')"
assert_eq "no CMake file is touched, so the patch is additive to every configuration" "0" \
  "$(printf '%s\n' "$files" | grep -ci 'CMakeLists.txt$')"

# ---------------------------------------------------------------------------
# It applies to the anchor ALONE, and the result is the reviewed change rather than merely a
# change that applies.
# ---------------------------------------------------------------------------
tree="$(m9_upstream_tree)"
assert_dir "the worktree exists" "$tree"
assert_eq "it is the anchor plus exactly one commit" "1" \
  "$(git -C "$tree" rev-list --count "$anchor..HEAD" 2>/dev/null)"
assert_eq "whose parent is the anchor itself" "$anchor" \
  "$(git -C "$tree" rev-parse HEAD^ 2>/dev/null)"
assert_eq "nothing under barretenberg/ is modified in it" "" "$(m9_tree_dirty "$tree")"
tree_hash="$(git -C "$tree" rev-parse HEAD^{tree} 2>/dev/null)"
assert_eq "the resulting TREE is the reviewed one (a patch can be altered and still apply)" \
  "50fa399631f572b17edc5d8dd9b34a6c23b9c228" "$tree_hash"
assert_eq "the commit touches the same seven files git am was given" "7" \
  "$(git -C "$tree" show --name-only --format= HEAD | grep -c .)"
assert_eq "and its file list matches the patch's" \
  "$(printf '%s\n' "$files" | tr '\n' ' ')" \
  "$(git -C "$tree" show --name-only --format= HEAD | LC_ALL=C sort | tr '\n' ' ')"

# The commit message is the PR body, and M4's and M5's reviews both found an overstatement
# surviving in it after PR.md had been corrected. It is asserted here, not only PR.md.
msg="$(git -C "$tree" log -1 --format=%B HEAD)"
assert_contains "the commit message says the fast loop emits no ExecutionEvents by design" \
  "deliberately emits no" "$msg"
assert_contains "and names the existing call-frame seam it copies" \
  "CallStackMetadataCollectorInterface" "$msg"
assert_contains "and gives the reason the hook takes a WireOpCode" "vector<Operand>" "$msg"
assert_not_contains "it does not claim the AVM has no observability" \
  "no way to observe" "$msg"
assert_contains "it discloses the msgpack key the result struct gains" "msgpack" "$msg"

# ---------------------------------------------------------------------------
# The build, and upstream's OWN tests, on both sides.
# ---------------------------------------------------------------------------
base="$(m9_upstream_base_tree)"
assert_dir "the unpatched anchor worktree exists" "$base"
assert_eq "it carries no commit beyond the anchor" "0" \
  "$(git -C "$base" rev-list --count "$anchor..HEAD" 2>/dev/null)"
assert_eq "and nothing under barretenberg/ is modified in it" "" "$(m9_tree_dirty "$base")"
assert_false "the unpatched tree really has no observer interface" \
  test -f "$base/barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/execution_observer.hpp"

note "building upstream's own vm2_tests, patched"
m9_build_upstream_vm2_tests "$tree"
assert_eq "the patched configure exited 0" "0" "${M9_UP_CONFIGURE_RC:-missing}"
assert_eq "the patched build of upstream's own vm2_tests exited 0" "0" "${M9_UP_BUILD_RC:-missing}"
note "building upstream's own vm2_tests, unpatched"
m9_build_upstream_vm2_tests "$base"
assert_eq "the unpatched configure exited 0" "0" "${M9_UP_CONFIGURE_RC:-missing}"
assert_eq "the unpatched build exited 0" "0" "${M9_UP_BUILD_RC:-missing}"

pbin="$(m9_up_bin "$tree" vm2_tests)"
bbin="$(m9_up_bin "$base" vm2_tests)"
m8_require_artifacts "$pbin" "$bbin"
assert_false "the two test binaries are not the same file" cmp -s "$pbin" "$bbin"

# The gtest both sides use is the pinned FetchContent one, not the host's. M7's build check found
# the two sides of a parity comparison running gtest 1.17.0 and 1.13.0.
for label in patched:$tree unpatched:$base; do
  t="${label#*:}"; n="${label%%:*}"
  assert_eq "[$n] gtest came from FetchContent rather than from the host" "NEVER" \
    "$(m6_cache "$t" "$M9_UP_BUILD" FETCHCONTENT_TRY_FIND_PACKAGE_MODE)"
  assert_dir "[$n] and the fetched gtest source is in the build tree" \
    "$t/barretenberg/cpp/$M9_UP_BUILD/_deps/gtest-src"
done

# --gtest_list_tests first: the DECLARED set, which a run cannot shrink without being noticed.
plist="$M9_WORK/m9up.list"; blist="$M9_WORK/m9upbase.list"
m9_run_native "$pbin" "$plist" "$M9_WORK/m9up.list.err" --gtest_list_tests
assert_eq "the patched listing exited 0" "0" "$?"
m9_run_native "$bbin" "$blist" "$M9_WORK/m9upbase.list.err" --gtest_list_tests
assert_eq "the unpatched listing exited 0" "0" "$?"
pnames="$(m7_names list "$plist")"
bnames="$(m7_names list "$blist")"
assert_eq "upstream's own binary declares 1,803 tests, which is M7's denominator" "1803" \
  "$(printf '%s\n' "$pnames" | grep -c .)"
assert_eq "and the unpatched one declares the same number" "1803" \
  "$(printf '%s\n' "$bnames" | grep -c .)"
assert_eq "the declared test NAME SETS are identical (a count survives a rename)" \
  "$(printf '%s\n' "$pnames" | md5sum)" "$(printf '%s\n' "$bnames" | md5sum)"
# The denominator is not just large, it covers the thing the patch touches. Both sides of the AVM
# are named: the simulation side, whose fast loop the hook lives in, and the constraining/tracegen
# side, which the patch does not touch and which would notice if the result struct broke msgpack.
assert_ge "the declared set covers the AVM's own SIMULATION tests" 50 \
  "$(printf '%s\n' "$pnames" | grep -c '^AvmSimulation')"
assert_ge "and its constraining/tracegen tests" 50 \
  "$(printf '%s\n' "$pnames" | grep -cE '^[A-Za-z0-9_]*(Constraining|TraceGen)')"
assert_ge "and its end-to-end integration tests" 1 \
  "$(printf '%s\n' "$pnames" | grep -c '^AvmCompleteness\.')"

# The runs. Exit status asserted separately from anything parsed out of the transcript — a binary
# that prints a full green summary and then exits non-zero is a fixture this campaign already has.
prun="$M9_WORK/m9up.run"; brun="$M9_WORK/m9upbase.run"
m9_run_native "$pbin" "$prun" "$M9_WORK/m9up.run.err"
prc=$?
m9_run_native "$bbin" "$brun" "$M9_WORK/m9upbase.run.err"
brc=$?
assert_eq "the patched run of upstream's own vm2_tests exited 0" "0" "$prc"
assert_eq "the unpatched run exited 0" "0" "$brc"

for label in patched:$prun unpatched:$brun; do
  n="${label%%:*}"; f="${label#*:}"
  assert_eq "[$n] gtest reports 1,800 tests from 215 suites ran (three are DISABLED)" "1" \
    "$(grep -c '^\[==========\] 1800 tests from 215 test suites ran' "$f" || true)"
  assert_eq "[$n] 1,798 passed" "1" "$(grep -c '^\[  PASSED  \] 1798 tests\.$' "$f" || true)"
  assert_eq "[$n] and nothing failed" "0" "$(grep -c '^\[  FAILED  \] [0-9]* tests\?, listed below' "$f" || true)"
  assert_eq "[$n] two are skipped by upstream's own suite" "1" \
    "$(grep -c '^\[  SKIPPED \] 2 tests, listed below' "$f" || true)"
done

# Per test name, on both sides, which is the assertion that survives a rename or a swap.
pok="$(m7_names passed "$prun")"; bok="$(m7_names passed "$brun")"
pran="$(m7_names ran "$prun")"; bran="$(m7_names ran "$brun")"
assert_eq "1,800 tests RAN in the patched binary" "1800" "$(printf '%s\n' "$pran" | grep -c .)"
assert_eq "and 1,800 in the unpatched one" "1800" "$(printf '%s\n' "$bran" | grep -c .)"
assert_eq "the sets of tests that RAN are identical" \
  "$(printf '%s\n' "$pran" | md5sum)" "$(printf '%s\n' "$bran" | md5sum)"
assert_eq "the sets of tests that PASSED are identical" \
  "$(printf '%s\n' "$pok" | md5sum)" "$(printf '%s\n' "$bok" | md5sum)"
assert_eq "1,798 passed on the patched side, per name" "1798" "$(printf '%s\n' "$pok" | grep -c .)"

# A filter that matches nothing still exits 0 in gtest, which is exactly how a check like this can
# report a green suite having compared nothing. Both halves are exercised.
none="$M9_WORK/m9up.none"
m9_run_native "$pbin" "$none" "$M9_WORK/m9up.none.err" --gtest_filter=NoSuchSuite.NoSuchTest
assert_eq "a filter matching nothing still exits 0 — which is why the ran-count is asserted" "0" "$?"
assert_eq "and it ran zero tests" "1" \
  "$(grep -c '^\[==========\] 0 tests from 0 test suites ran' "$none" || true)"
one="$M9_WORK/m9up.one"
m9_run_native "$pbin" "$one" "$M9_WORK/m9up.one.err" '--gtest_filter=AvmSimulation*'
assert_eq "a real filter exits 0 too" "0" "$?"
ran_subset="$(m7_names ran "$one" | grep -c . || true)"
assert_ge "and runs a non-empty subset of the simulation tests" 50 "$ran_subset"
assert_true "which is a PROPER subset of the whole binary, so the filter selects rather than passes everything" \
  test "$ran_subset" -lt 1800

# The environment precondition, stated because it is real and because it was found the hard way:
# fourteen of these tests need the bn254 CRS and fail with a message about it if it is absent. It
# is asserted present BEFORE the runs are believed, rather than the failures being tolerated.
assert_file "the bn254 CRS the proving-side tests need is present" "$HOME/.bb-crs/bn254_g1_compressed.dat"
assert_eq "so no test failed for want of it" "0" \
  "$(grep -c 'bn254 g1 data not found' "$prun" || true)"

# ---------------------------------------------------------------------------
# The write-up, and the skip path this milestone owns.
# ---------------------------------------------------------------------------
vsh="$M9_OBSERVER_DIR/verify.sh"
vcpp="$M9_OBSERVER_DIR/verify/verify_observer.cpp"
assert_file "the verification driver is beside it" "$vcpp"
assert_true "verify.sh is executable" test -x "$vsh"
assert_true "verify.sh parses" bash -n "$vsh"
assert_eq "verify.sh has no SKIPPED branch — the defect this milestone owns" "0" \
  "$(grep -c 'SKIPPED' "$vsh" || true)"
assert_eq "and prints no skipping message at run time in any spelling" "0" \
  "$(grep -cE '^[[:space:]]*(echo|printf)[^#]*[Ss]kip' "$vsh" || true)"
assert_eq "and offers no flag that leaves a part out" "0" \
  "$(grep -c -- '--functional-only' "$vsh" || true)"
assert_true "a precondition it cannot meet is a DISTINCT exit status, not 0 and not 1" \
  grep -q 'precondition() { echo "verify.sh: cannot run' "$vsh"
# Exactly one `exit 0`, and it is the last line of the success banner. Anything else would be a
# path that reports success without having compared anything — which is the whole defect.
assert_eq "verify.sh has exactly one unconditional 'exit 0'" "1" \
  "$(grep -cE '^[[:space:]]*exit 0[[:space:]]*$' "$vsh" || true)"
assert_eq "and it is preceded by the success banner rather than by a message about a missing input" \
  "1" "$(grep -B4 -E '^[[:space:]]*exit 0[[:space:]]*$' "$vsh" | grep -c 'own noise when disabled' || true)"
assert_true "the second tree is REQUIRED, not optional" \
  grep -q 'set AZTEC_REF to an UNPATCHED checkout' "$vsh"
assert_true "and the two sides are asserted to be different builds before they are compared" \
  grep -q 'the two binaries are byte-identical' "$vsh"
assert_true "the timing comparison is an EQUIVALENCE test rather than a small-number claim" \
  grep -q 'The claim part B makes is EQUIVALENCE' "$vsh"
assert_true "with a bootstrap confidence interval rather than a point estimate" \
  grep -q 'bootstrap' "$vsh"
assert_true "calibrated by a same-bytes control that must pass the same test" \
  grep -q 'two copies of the SAME binary do not come out equivalent' "$vsh"
assert_true "and refuses to report a comparison it does not have the samples for" \
  grep -q 'not enough samples to compare' "$vsh"
assert_false "it does not rewrite its own driver with sed to build against the unpatched tree" \
  grep -qE "^sed -e 's/config\.collect_execution_steps" "$vsh"
assert_true "the driver selects the API with __has_include instead" \
  grep -q '__has_include("barretenberg/vm2/simulation/interfaces/execution_observer.hpp")' "$vcpp"
assert_true "the driver refuses to report success having asserted nothing" \
  grep -q 'asserted nothing' "$vcpp"
assert_true "it exercises both exceptional-halt shapes" grep -q 'program_oob' "$vcpp"
assert_true "and compares its records against upstream's own ExecutionEvent seam" \
  grep -q 'simulate_for_witgen' "$vcpp"

pr="$M9_OBSERVER_DIR/PR.md"
assert_true "PR.md names all three seams the AVM already has" \
  grep -q 'three observation seams' "$pr"
assert_true "and does not claim the AVM is unobservable" bash -c "! grep -qi 'no observability' '$pr'"
assert_true "PR.md states the correction this milestone measured: the hint-collecting entry point discards the events" \
  grep -q 'NoopEventEmitter' "$pr"
assert_true "and that reaching them needs a second simulation" \
  grep -q 'simulate_for_witgen' "$pr"
assert_true "PR.md quotes the ENABLED cost with a number" grep -qE '\+1[0-9](\.[0-9])?%' "$pr"
assert_true "and separates it per target, because native and wasm differ by more than 3x" \
  grep -q 'wasm32' "$pr"
assert_true "PR.md discloses the msgpack key the result struct gains" grep -q 'msgpack' "$pr"
assert_true "PR.md records that upstream's own vm2_tests WAS run" grep -q '1,798' "$pr"
assert_false "so the 'vm2_tests was not run' limitation is gone" \
  grep -q '\*\*`vm2_tests` was not run.\*\*' "$pr"
assert_true "PR.md dates its prior-art search so it can be re-run before filing" \
  grep -qE 'Search was 202[0-9]-[0-9]{2}-[0-9]{2}' "$pr"
assert_true "and says plainly that it is not filed" grep -q 'not filed' "$pr"

# SERIES.md must agree with the measurement rather than with the older figure.
series="$M6_UPSTREAM_BUGS/SERIES.md"
assert_file "SERIES.md exists" "$series"
assert_true "SERIES.md still indexes this patch as the fourth" \
  grep -q 'aztec-execution-observer-hook' "$series"
assert_true "and its neutrality row names upstream's own vm2_tests result" \
  grep -q '1,798' "$series"

finish
