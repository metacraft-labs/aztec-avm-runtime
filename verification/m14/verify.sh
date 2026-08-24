#!/usr/bin/env bash
# Verification for: give the in-memory reference world state its archive tree.
#
# There is NO SKIP PATH here. Part B needs a second, unpatched checkout; without it this exits 2
# with a reason, never 0. That is deliberate and it is this campaign's own lesson: the prepared
# verify.sh for the execution-observer patch shipped with a branch that printed SKIPPED and exited 0.
#
# Three parts, and the second is the one a reviewer should read first:
#
#   A. THE GATE. Builds world_state_tests and runs MemoryMerkleDBEquivalenceTest.*, which
#      drives a real, file-backed world_state::WorldState and an in-memory MemoryMerkleDB
#      through the same operations. Seven cases at the base commit, twelve with the patch,
#      compared as NAME SETS rather than as counts so a rename cannot hide in a total. All
#      twelve pass, and every case that passed before still does.
#
#   B. NOTHING ELSE MOVES. vm2_tests declares 1,803 tests at this commit with and without the
#      patch, with an identical name set and an identical set of passes. Every other suite in
#      world_state_tests is unchanged by name; the only difference in that binary's case list
#      is the five cases the patch adds, taken as the difference of two sorted lists.
#
#   C. STILL DEPENDENCY-FREE. The module declaration is untouched and the patch adds exactly
#      one include, a constants header. No lmdb, no thread pool, no vm2, no ipc — which is what
#      keeps this component buildable for targets where the LMDB-backed WorldState is not.
#
# Part B needs BOTH checkouts and is the discriminator; with AZTEC alone it refuses rather than
# reporting a comparison it did not make.
#
# Usage:
#   AZTEC=/path/to/patched ./verify.sh                    # part A and C
#   AZTEC=/path/to/patched AZTEC_REF=/path/to/base ./verify.sh   # all three
#
# Environment:
#   AZTEC      aztec-packages checkout WITH the patch applied   (required)
#   AZTEC_REF  a second checkout at the base commit, WITHOUT it (required for part B)
#   BUILD      build directory name under barretenberg/cpp, default build-native
#   JOBS       ninja parallelism, default nproc
#
# Exit status: 0 everything expected holds; 1 an expectation failed; 2 it could not run.
set -u

AZTEC="${AZTEC:-}"
AZTEC_REF="${AZTEC_REF:-}"
BUILD="${BUILD:-build-native}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
SUITE="MemoryMerkleDBEquivalenceTest"

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*" >&2; fail=1; }
note() { printf '  --   %s\n' "$*"; }
cannot() { printf 'verify.sh: cannot run: %s\n' "$*" >&2; exit 2; }

[ -n "$AZTEC" ] && [ -d "$AZTEC/barretenberg/cpp" ] \
  || cannot "set AZTEC to an aztec-packages checkout with the patch applied"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

build_and_list() { # <checkout> <label>
  local root="$1" label="$2" cpp="$1/barretenberg/cpp"
  ( cd "$cpp" || exit 90
    if [ ! -f "$BUILD/build.ninja" ]; then
      cmake --preset default -B "$BUILD" -DAVM_TRANSPILER_LIB= \
        -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER >"$WORK/$label-configure.log" 2>&1 \
        || exit 91
    fi
    ninja -j "$JOBS" -C "$BUILD" world_state_tests vm2_tests >"$WORK/$label-build.log" 2>&1
  )
  local rc=$?
  [ "$rc" -eq 0 ] || { bad "$label: build failed (see $WORK/$label-build.log)"; return 1; }
  ok "$label: world_state_tests and vm2_tests built"
  "$cpp/$BUILD/bin/world_state_tests" --gtest_list_tests >"$WORK/$label-ws-list.txt" 2>/dev/null
  "$cpp/$BUILD/bin/vm2_tests"         --gtest_list_tests >"$WORK/$label-vm2-list.txt" 2>/dev/null
  return 0
}

# Full Suite.Case names out of a --gtest_list_tests transcript.
names() {
  awk '/^[A-Za-z0-9_\/]+\.$/ { s = $1; next }
       /^  [A-Za-z0-9_\/]+/  { gsub(/^  /, ""); sub(/[[:space:]].*$/, ""); print s $0 }' "$1" | sort
}
passes() {
  grep -oE '^\[       OK \] [A-Za-z0-9_\/]+\.[A-Za-z0-9_\/]+' "$1" | sed 's/^\[       OK \] //' | sort
}

echo "== A. the equivalence gate, with the patch =="
build_and_list "$AZTEC" patched || exit 1
"$AZTEC/barretenberg/cpp/$BUILD/bin/world_state_tests" --gtest_filter="$SUITE.*" \
  >"$WORK/patched-gate.out" 2>"$WORK/patched-gate.err"
gate_rc=$?
[ "$gate_rc" -eq 0 ] && ok "the gate exits 0" || bad "the gate exited $gate_rc"
declared="$(names "$WORK/patched-ws-list.txt" | grep -c "^$SUITE\.")"
[ "$declared" -eq 12 ] && ok "it declares twelve cases [$declared]" \
                       || bad "expected twelve cases, got $declared"
passed="$(passes "$WORK/patched-gate.out" | grep -c "^$SUITE\." )"
[ "$passed" -eq 12 ] && ok "and all twelve passed [$passed]" \
                     || bad "expected twelve passes, got $passed"
failed="$(grep -c '^\[  FAILED  \]' "$WORK/patched-gate.out")"
[ "$failed" -eq 0 ] && ok "none failed" || bad "$failed case(s) failed"
for t in GenesisArchiveMatchesPublishedConstants UpdateArchiveMatchesWorldState \
         UpdateArchiveRejectsMismatchedStateReference ArchiveThroughTreeIdDispatch \
         ArchiveParticipatesInCheckpoints; do
  if passes "$WORK/patched-gate.out" | grep -qx "$SUITE\.$t"; then ok "passed: $t"; else bad "missing or failing: $t"; fi
done
# The gate really drives the real WorldState, not a second copy of the reference.
src="$AZTEC/barretenberg/cpp/src/barretenberg/world_state/memory_merkle_db.test.cpp"
grep -q 'ws = std::make_unique<WorldState>(' "$src" \
  && ok "the gate constructs a real WorldState" || bad "the gate does not construct a WorldState"
n_snap="$(grep -c 'check_snapshot(MerkleTreeId::' "$src")"
[ "$n_snap" -eq 5 ] && ok "and expect_roots_equal compares five snapshots [$n_snap]" \
                    || bad "expected five snapshot comparisons, got $n_snap"

echo
echo "== C. still the dependency-free component =="
cml="$AZTEC/barretenberg/cpp/src/barretenberg/world_state_reference/CMakeLists.txt"
grep -qx 'barretenberg_module(world_state_reference crypto_merkle_tree aztec crypto_poseidon2)' "$cml" \
  && ok "the module declaration is untouched" || bad "the module declaration changed"
hdr="$AZTEC/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp"
impl="$AZTEC/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.cpp"
for forbidden in lmdb thread_pool 'barretenberg/vm2/' ipc_runtime; do
  if grep -q "$forbidden" "$hdr" "$impl"; then bad "the component now mentions $forbidden"
  else ok "no dependency on $forbidden"; fi
done
grep -q 'DEFAULT_NULLIFIER_TREE_PREFILL = 2 \* MAX_NULLIFIERS_PER_TX' "$hdr" \
  && ok "the prefill is stated as the protocol constant" || bad "the prefill is still a literal"
grep -q 'GENESIS_ARCHIVE_ROOT' "$impl" \
  && bad "the genesis archive root is hardcoded rather than derived" \
  || ok "the genesis archive root is derived, not hardcoded"

if [ -z "$AZTEC_REF" ]; then
  echo
  echo "== B. REFUSED (not skipped) =="
  echo "verify.sh: part B needs AZTEC_REF, a checkout at the base commit WITHOUT the patch." >&2
  echo "verify.sh: 'nothing else moves' is a COMPARISON, and this run has nothing to compare" >&2
  echo "verify.sh: against, so it exits 2 rather than reporting a result it does not have." >&2
  exit 2
fi
[ -d "$AZTEC_REF/barretenberg/cpp" ] || cannot "AZTEC_REF is not an aztec-packages checkout"

echo
echo "== B. nothing else moves =="
build_and_list "$AZTEC_REF" base || exit 1
if grep -q 'archive_tree' "$AZTEC_REF/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp"; then
  cannot "AZTEC_REF appears to CARRY the patch; part B would compare a build with itself"
fi
ok "AZTEC_REF really is the unpatched tree"

base_vm2="$(names "$WORK/base-vm2-list.txt")"
patched_vm2="$(names "$WORK/patched-vm2-list.txt")"
n_base="$(printf '%s\n' "$base_vm2" | grep -c .)"
[ "$n_base" -ge 1000 ] && ok "vm2_tests declares $n_base tests at the base commit" \
                       || bad "vm2_tests declared only $n_base tests — is this the right target?"
if [ "$(printf '%s\n' "$base_vm2" | md5sum)" = "$(printf '%s\n' "$patched_vm2" | md5sum)" ]; then
  ok "and the patched binary declares the IDENTICAL name set"
else
  bad "the vm2_tests name set changed"
fi
for label in base patched; do
  root="$AZTEC_REF"; [ "$label" = patched ] && root="$AZTEC"
  "$root/barretenberg/cpp/$BUILD/bin/vm2_tests" >"$WORK/$label-vm2.out" 2>"$WORK/$label-vm2.err"
  echo "$?" >"$WORK/$label-vm2.rc"
done
for label in base patched; do
  rc="$(cat "$WORK/$label-vm2.rc")"
  [ "$rc" -eq 0 ] && ok "vm2_tests exits 0 ($label)" || bad "vm2_tests exited $rc ($label)"
done
if [ "$(passes "$WORK/base-vm2.out" | md5sum)" = "$(passes "$WORK/patched-vm2.out" | md5sum)" ]; then
  ok "the set of vm2 tests that PASS is identical, by name"
else
  bad "the set of vm2 tests that pass changed"
fi

base_ws="$(names "$WORK/base-ws-list.txt")"
patched_ws="$(names "$WORK/patched-ws-list.txt")"
added="$(comm -13 <(printf '%s\n' "$base_ws") <(printf '%s\n' "$patched_ws"))"
removed="$(comm -23 <(printf '%s\n' "$base_ws") <(printf '%s\n' "$patched_ws"))"
expected="$(printf '%s\n' \
  "$SUITE.ArchiveParticipatesInCheckpoints" \
  "$SUITE.ArchiveThroughTreeIdDispatch" \
  "$SUITE.GenesisArchiveMatchesPublishedConstants" \
  "$SUITE.UpdateArchiveMatchesWorldState" \
  "$SUITE.UpdateArchiveRejectsMismatchedStateReference" | sort)"
[ "$added" = "$expected" ] && ok "exactly the five new cases were added, by full name" \
                          || bad "unexpected additions: $(printf '%s' "$added" | tr '\n' ' ')"
[ -z "$removed" ] && ok "and nothing was removed" \
                  || bad "cases disappeared: $(printf '%s' "$removed" | tr '\n' ' ')"
other_base="$(printf '%s\n' "$base_ws" | grep -v "^$SUITE\.")"
other_patched="$(printf '%s\n' "$patched_ws" | grep -v "^$SUITE\.")"
n_other="$(printf '%s\n' "$other_base" | grep -c .)"
[ "$n_other" -ge 20 ] && ok "there are $n_other other cases in that binary to be neutral about" \
                      || bad "only $n_other other cases — the neutrality claim would be weak"
[ "$other_base" = "$other_patched" ] && ok "and every one of them is unchanged, by name" \
                                     || bad "another suite in world_state_tests changed"

"$AZTEC_REF/barretenberg/cpp/$BUILD/bin/world_state_tests" >"$WORK/base-ws.out" 2>&1; base_ws_rc=$?
"$AZTEC/barretenberg/cpp/$BUILD/bin/world_state_tests"     >"$WORK/patched-ws.out" 2>&1; patched_ws_rc=$?
[ "$base_ws_rc" -eq 0 ]    && ok "world_state_tests exits 0 at the base commit" || bad "base world_state_tests exited $base_ws_rc"
[ "$patched_ws_rc" -eq 0 ] && ok "and exits 0 with the patch" || bad "patched world_state_tests exited $patched_ws_rc"
base_pass="$(passes "$WORK/base-ws.out")"
patched_pass="$(passes "$WORK/patched-ws.out")"
if [ "$base_pass" = "$(comm -12 <(printf '%s\n' "$base_pass") <(printf '%s\n' "$patched_pass"))" ]; then
  ok "every case that passed at the base commit still passes"
else
  bad "a case that passed at the base commit no longer does"
fi

echo
if [ "$fail" -eq 0 ]; then echo "verify.sh: PASS"; else echo "verify.sh: FAIL" >&2; fi
exit "$fail"
