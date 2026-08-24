#!/usr/bin/env bash
# verify_world_state_reference_extension_native_neutral
#
# Every existing consumer of `world_state_reference` builds and passes unchanged with the extension
# present. Three consumers, and they are enumerated from the fork rather than listed from memory:
# the vm2 adapter (`vm2/simulation/lib/memory_merkle_db.{hpp,cpp}`, reached by `vm2_tests`), the AVM
# fuzzer (`avm_fuzzer/common/interfaces/dbs.cpp`), and upstream's own `world_state` module and its
# tests.
#
# WHAT NEUTRALITY MEANS HERE, AND WHAT IT DOES NOT. It does NOT mean the binaries are identical:
# `world_state_reference` gained a member and a method, so anything linking it changes. It means the
# OBSERVABLE behaviour of upstream's own suites is identical — same tests, by NAME, same results, by
# name — and that the four StateReference trees produce the same values they did before, which is
# section B of test_reference_genesis_roots_versus_real_world_state and is re-asserted here from the
# same probe transcripts.
#
# THE DENOMINATORS ARE UPSTREAM'S AND ARE RE-DERIVED. `vm2_tests` declares 1,803 tests at this
# anchor — M7's denominator and M9's — and `world_state_tests` declares its own. Both are compared
# as NAME SETS and not as counts, because a count survives a rename.
#
# THE ONE THING THAT IS ALLOWED TO DIFFER is `world_state_tests`' own case list, which gains M14's
# five. That is asserted as a difference of two name sets, and every OTHER suite in that binary must
# be identical — so "the patch adds five cases to one suite" is measured rather than assumed.
#
# THE COMPILER CACHE CANNOT PRODUCE THIS RESULT SPURIOUSLY. It is content-addressed: the base and
# patched trees differ in three files, so those translation units and everything including them miss
# and are compiled. verify_compiler_cache_effective asserts that separately and measures it on this
# very pair of trees.
#
# Run: just verify-world-state-neutral

TEST_NAME="verify_world_state_reference_extension_native_neutral"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m14_world_state.sh"

m14_measured
for b in "$M14_BASE_VM2_TESTS" "$M14_EXT_VM2_TESTS" "$M14_BASE_WORLD_STATE_TESTS" "$M14_EXT_WORLD_STATE_TESTS"; do
  assert_file "built binary present" "$b"
  [ -x "$b" ] || die "missing $b — run 'just verify-block-level-audit'"
done

FORK_SHOW() { git -C "$FORK_ROOT" show "$M6_BASE_REV:$1" 2>/dev/null; }
RUNDIR="$M14_WORK/neutral"; mkdir -p "$RUNDIR"

run_gtest() { # <binary> <label> <args...>
  local bin="$1" label="$2"; shift 2
  m6_in_devshell '
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    bin="$1"; shift
    "$bin" "$@"
  ' "$bin" "$@" >"$RUNDIR/$label.out" 2>"$RUNDIR/$label.err"
  printf '%s' "$?" >"$RUNDIR/$label.rc"
}
rc_of() { cat "$RUNDIR/$1.rc" 2>/dev/null; }
# Full `Suite.Case` names out of a --gtest_list_tests transcript: suite headers end in `.`, cases are
# indented. Names are reassembled rather than counted, because a rename must be visible.
listed_of() {
  awk '/^[A-Za-z0-9_\/]+\.$/ { suite = $1; next }
       /^  [A-Za-z0-9_\/]+/  { gsub(/^  /, ""); sub(/[[:space:]].*$/, ""); print suite $0 }' \
    "$RUNDIR/$1.out" 2>/dev/null | sort
}
passed_of() {
  grep -oE '^\[       OK \] [A-Za-z0-9_\/]+\.[A-Za-z0-9_\/]+' "$RUNDIR/$1.out" 2>/dev/null \
    | sed 's/^\[       OK \] //' | sort
}

echo "== A. the consumers, enumerated from the fork =="
CONSUMERS="$(git -C "$FORK_ROOT" grep -l 'barretenberg/world_state_reference/memory_merkle_db.hpp' \
              "$M6_BASE_REV" -- '*.hpp' '*.cpp' 2>/dev/null | sed -E "s|^$M6_BASE_REV:||" | sort)"
assert_ge "at least three files include the reference's header at the anchor" 3 \
  "$(printf '%s\n' "$CONSUMERS" | grep -c .)"
for c in "barretenberg/cpp/src/barretenberg/vm2/simulation/lib/memory_merkle_db.hpp" \
         "barretenberg/cpp/src/barretenberg/world_state/memory_merkle_db.test.cpp"; do
  assert_contains "and among them is $c" "$c" "$CONSUMERS"
done
# The fuzzer reaches it through the vm2 adapter rather than directly, which is worth asserting
# because an enumeration that only followed the direct include would miss it — the M13 shape again.
assert_contains "the AVM fuzzer constructs the vm2 adapter over the reference" \
  "std::make_unique<simulation::MemoryMerkleDB>(" \
  "$(FORK_SHOW barretenberg/cpp/src/barretenberg/avm_fuzzer/common/interfaces/dbs.cpp)"

# The adapter reads FOUR named fields out of TreeRoots, which is why adding a fifth is additive.
ADAPTER_CPP="$(FORK_SHOW barretenberg/cpp/src/barretenberg/vm2/simulation/lib/memory_merkle_db.cpp)"
assert_contains "the adapter maps the reference's TreeRoots onto the AVM's TreeSnapshots" \
  "world_state::TreeRoots roots = inner_.get_tree_roots();" "$ADAPTER_CPP"
assert_eq "reading exactly four named fields" "4" \
  "$(printf '%s\n' "$ADAPTER_CPP" | grep -cE 'roots\.(l1_to_l2_message_tree|note_hash_tree|nullifier_tree|public_data_tree)\b')"
assert_eq "and none of them the archive" "0" "$(printf '%s\n' "$ADAPTER_CPP" | grep -c 'roots\.archive')"
assert_eq "M14's patch does not touch vm2 at all" "0" \
  "$(git -C "$M14_TREE" diff --name-only "$M6_BASE_REV" HEAD | grep -c '/vm2/')"
assert_eq "nor the fuzzer" "0" \
  "$(git -C "$M14_TREE" diff --name-only "$M6_BASE_REV" HEAD | grep -c '/avm_fuzzer/')"

echo
echo "== B. upstream's own vm2_tests: same names, same results =="
run_gtest "$M14_BASE_VM2_TESTS" vm2-list-base --gtest_list_tests
run_gtest "$M14_EXT_VM2_TESTS"  vm2-list-ext  --gtest_list_tests
assert_eq "the base listing exited 0" "0" "$(rc_of vm2-list-base)"
assert_eq "the patched listing exited 0" "0" "$(rc_of vm2-list-ext)"
V_BASE="$(listed_of vm2-list-base)"; V_EXT="$(listed_of vm2-list-ext)"
assert_eq "upstream's own denominator, re-derived on this run" "$M14_VM2_TESTS_DECLARED" \
  "$(printf '%s\n' "$V_BASE" | grep -c .)"
assert_eq "and the patched binary declares the same number" "$M14_VM2_TESTS_DECLARED" \
  "$(printf '%s\n' "$V_EXT" | grep -c .)"
assert_eq "the declared NAME SETS are identical (a count survives a rename)" \
  "$(printf '%s\n' "$V_BASE" | md5sum)" "$(printf '%s\n' "$V_EXT" | md5sum)"

run_gtest "$M14_BASE_VM2_TESTS" vm2-run-base
run_gtest "$M14_EXT_VM2_TESTS"  vm2-run-ext
assert_eq "upstream's own vm2_tests exits 0 at the anchor" "0" "$(rc_of vm2-run-base)"
assert_eq "and exits 0 with the extension" "0" "$(rc_of vm2-run-ext)"
P_BASE="$(passed_of vm2-run-base)"; P_EXT="$(passed_of vm2-run-ext)"
assert_ge "a substantial number of vm2 tests actually ran at the anchor" 1000 \
  "$(printf '%s\n' "$P_BASE" | grep -c .)"
assert_eq "the set of vm2 tests that PASS is identical, by name" \
  "$(printf '%s\n' "$P_BASE" | md5sum)" "$(printf '%s\n' "$P_EXT" | md5sum)"
assert_eq "no vm2 test failed at the anchor" "0" "$(grep -c '^\[  FAILED  \]' "$RUNDIR/vm2-run-base.out")"
assert_eq "and none failed with the extension" "0" "$(grep -c '^\[  FAILED  \]' "$RUNDIR/vm2-run-ext.out")"

echo
echo "== C. upstream's own world_state_tests: the equivalence suite grows by five and NOTHING else moves =="
run_gtest "$M14_BASE_WORLD_STATE_TESTS" ws-list-base --gtest_list_tests
run_gtest "$M14_EXT_WORLD_STATE_TESTS"  ws-list-ext  --gtest_list_tests
assert_eq "the base listing exited 0" "0" "$(rc_of ws-list-base)"
assert_eq "the patched listing exited 0" "0" "$(rc_of ws-list-ext)"
W_BASE="$(listed_of ws-list-base)"; W_EXT="$(listed_of ws-list-ext)"
assert_ge "world_state_tests declares a real suite at the anchor" 30 \
  "$(printf '%s\n' "$W_BASE" | grep -c .)"
ADDED="$(comm -13 <(printf '%s\n' "$W_BASE") <(printf '%s\n' "$W_EXT"))"
REMOVED="$(comm -23 <(printf '%s\n' "$W_BASE") <(printf '%s\n' "$W_EXT"))"
EXPECTED_ADDED="$(for t in $M14_NEW_GATE_TESTS; do printf '%s.%s\n' "$M14_GATE_SUITE" "$t"; done | sort)"
assert_eq "exactly the five new cases were added, by full name" "$EXPECTED_ADDED" "$ADDED"
assert_eq "and nothing was removed" "" "$REMOVED"
OTHER_BASE="$(printf '%s\n' "$W_BASE" | grep -v "^$M14_GATE_SUITE\.")"
OTHER_EXT="$(printf '%s\n' "$W_EXT" | grep -v "^$M14_GATE_SUITE\.")"
assert_ge "there are other suites in that binary to be neutral about" 20 \
  "$(printf '%s\n' "$OTHER_BASE" | grep -c .)"
assert_eq "and every one of them is unchanged, by name" "$OTHER_BASE" "$OTHER_EXT"

run_gtest "$M14_BASE_WORLD_STATE_TESTS" ws-run-base
run_gtest "$M14_EXT_WORLD_STATE_TESTS"  ws-run-ext
assert_eq "world_state_tests exits 0 at the anchor" "0" "$(rc_of ws-run-base)"
assert_eq "and exits 0 with the extension" "0" "$(rc_of ws-run-ext)"
WP_BASE="$(passed_of ws-run-base)"; WP_EXT="$(passed_of ws-run-ext)"
assert_eq "everything declared at the anchor passed" \
  "$(printf '%s\n' "$W_BASE" | grep -c .)" "$(printf '%s\n' "$WP_BASE" | grep -c .)"
assert_eq "everything declared with the extension passed" \
  "$(printf '%s\n' "$W_EXT" | grep -c .)" "$(printf '%s\n' "$WP_EXT" | grep -c .)"
assert_eq "and every case that passed at the anchor still passes" "$WP_BASE" \
  "$(comm -12 <(printf '%s\n' "$WP_BASE") <(printf '%s\n' "$WP_EXT"))"
assert_eq "no world_state test failed at the anchor" "0" "$(grep -c '^\[  FAILED  \]' "$RUNDIR/ws-run-base.out")"
assert_eq "and none failed with the extension" "0" "$(grep -c '^\[  FAILED  \]' "$RUNDIR/ws-run-ext.out")"

echo
echo "== D. the four StateReference trees are bit-for-bit what they were =="
for key in l1_to_l2_message_tree note_hash_tree nullifier_tree public_data_tree; do
  assert_eq "$key root unchanged by the extension" \
    "$(m14_key "$M14_PROBE_BASE" "genesis.$key.root")" "$(m14_key "$M14_PROBE_EXT" "genesis.$key.root")"
  assert_eq "$key size unchanged by the extension" \
    "$(m14_key "$M14_PROBE_BASE" "genesis.$key.size")" "$(m14_key "$M14_PROBE_EXT" "genesis.$key.size")"
done
assert_eq "the checkpoint id sequence starts where it did" \
  "$(m14_key "$M14_PROBE_BASE" genesis_checkpoint_id)" "$(m14_key "$M14_PROBE_EXT" genesis_checkpoint_id)"

echo
echo "== E. and it remains a wasm-capable, dependency-free module =="
# The whole reason the reference exists in this campaign is that it reaches wasm32-wasip1. An
# extension that pulled in lmdb, a thread pool or vm2 would be neutral natively and useless to us.
CMAKE_BASE="$(FORK_SHOW barretenberg/cpp/src/barretenberg/world_state_reference/CMakeLists.txt)"
CMAKE_EXT="$(cat "$M14_TREE/barretenberg/cpp/src/barretenberg/world_state_reference/CMakeLists.txt" 2>/dev/null)"
assert_eq "the module declaration is untouched" "$CMAKE_BASE" "$CMAKE_EXT"
assert_contains "and it still declares no lmdblib" \
  "barretenberg_module(world_state_reference crypto_merkle_tree aztec crypto_poseidon2)" "$CMAKE_EXT"
INC_BASE="$(FORK_SHOW barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp | grep -E '^#include' | sort)"
INC_EXT="$(grep -E '^#include' "$M14_TREE/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp" | sort)"
ADDED_INC="$(comm -13 <(printf '%s\n' "$INC_BASE") <(printf '%s\n' "$INC_EXT"))"
assert_eq "the extension adds exactly one include, and it is a constants header" \
  '#include "barretenberg/aztec/aztec_constants.hpp"' "$ADDED_INC"
# CODE lines only. The first form of this searched every added line and failed on three COMMENT
# lines — the class doc naming `vm2`, and two references to `world_state/fork.hpp` and
# `world_state/memory_merkle_db.test.cpp` — which are the patch explaining itself, not dependencies.
# A check that forbids a word in prose is a check that will be satisfied by deleting the
# explanation, which is the wrong incentive. Comment lines and blank lines are dropped, and what is
# left is the code.
ADDED_CODE="$(git -C "$M14_TREE" diff "$M6_BASE_REV" HEAD -- \
                barretenberg/cpp/src/barretenberg/world_state_reference/ \
              | grep -E '^\+' | grep -v '^+++' | sed 's/^+//' \
              | grep -vE '^[[:space:]]*(//|\*|/\*)' | grep -vE '^[[:space:]]*$')"
assert_ge "the patch adds real code to the component, so this is not vacuous" 30 \
  "$(printf '%s\n' "$ADDED_CODE" | grep -c .)"
for forbidden in lmdb thread_pool ThreadPool 'barretenberg/vm2' 'world_state/' ipc_runtime Signal; do
  assert_eq "no new dependency on $forbidden in the added CODE" "0" \
    "$(printf '%s\n' "$ADDED_CODE" | grep -cF "$forbidden")"
done
# And the three comment lines that DO name them are asserted to be comments, so the exemption above
# is bounded rather than a hole.
assert_eq "the only added lines naming vm2 or world_state/ are comments" "3" \
  "$(git -C "$M14_TREE" diff "$M6_BASE_REV" HEAD -- \
       barretenberg/cpp/src/barretenberg/world_state_reference/ \
     | grep -E '^\+' | grep -v '^+++' | grep -cE 'vm2|world_state/')"

finish
