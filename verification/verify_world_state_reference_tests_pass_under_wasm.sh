#!/usr/bin/env bash
# M7: the in-memory world state and the standalone gadgets M13-M15 depend on,
# under wasm.
#
# THE DELIVERABLE IS MIS-SPECIFIED AND THIS CHECK SAYS SO BY MEASURING IT.
# It asks for "the world_state_reference and standalone/ unit tests". There is no
# world_state_reference TEST TARGET: the module is declared
# `barretenberg_module(world_state_reference crypto_merkle_tree aztec
# crypto_poseidon2)` with no TEST_SOURCE_FILES, it has no *.test.cpp of its own,
# and no `world_state_reference_tests` target exists in ANY configuration. That
# is asserted here rather than quietly reinterpreted.
#
# That is NOT the same as "the module is untested". Upstream tests its central
# component from the module NEXT DOOR: `world_state/memory_merkle_db.test.cpp`
# declares seven `MemoryMerkleDBEquivalenceTest` cases that drive an ephemeral
# file-backed `world_state::WorldState` and a `MemoryMerkleDB` through the same
# sequence and compare roots, sibling paths, low-leaf lookups, indexed-leaf
# preimages and leaf values. `world_state` is LMDB-backed and server-side, so
# that file is native-only and outside vm2's 1,803 -- but it exists, and the
# absence of a target is not the absence of coverage. Both are asserted below.
#
# What IS covered, and each half is separated because they are different claims:
#
#   * The named standalone tests -- pure_sha256, pure_keccakf1600, debug_log --
#     run and pass under wasm, by name and by count.
#   * The tree checks run and pass under wasm, by name and by count, over
#     fourteen suites and 73 tests.
#   * `world_state_reference` is in the wasm test binary: its archive is on the
#     link line and its symbols are in the artefact.
#   * `getMerkleTreeName`/`MerkleTreeId` -- world_state_reference's vocabulary --
#     reaches the tests through `vm2/simulation/interfaces/db.hpp`.
#
# And how far the reference world state's OWN in-memory trees are driven, which
# an earlier version of this check got wrong in the direction of understating it.
# `sparse_memory_tree.hpp` really does have exactly one consumer
# (`world_state_reference/memory_merkle_db.hpp`), vm2's adapter over that really
# does have exactly two (`vm2/testing/public_tx_simulation_tester.hpp` and
# `avm_fuzzer/`), and no `*.test.cpp` inside the target's globs mentions the
# tester. But the chain does not stop there: `vm2/testing/fixtures.cpp` is a
# SUPPORT translation unit that the AVM_SIM_TESTS overlay itself compiles into
# `vm2_sim_test_objects`, its `get_minimal_proving_inputs()` is NOT one of the two
# definitions `AVM_SIM_TESTS_WITHOUT_TRACEGEN` compiles out, it constructs a
# `PublicTxSimulationTester` (which holds a `simulation::MemoryMerkleDB` by
# value), and `simulation/lib/hinting_dbs.test.cpp` calls it from
# `HintingDBsMinimalTest`'s fixture constructor. So the reference trees ARE
# constructed, mutated, checkpointed and read by tests inside the 391, and that
# is asserted here rather than denied.
#
# What is still open, and stated as the narrower thing it is: nothing here
# COMPARES a tree root native versus wasm. M8 -- the native-versus-wasm
# differential including tree roots -- owns that, and Tier I of the fixture
# corpus carries the evidence for the spike's build rather than this one.
#
# It also records the one target-level exclusion: `crypto_merkle_tree_tests` IS a
# target in an AVM_WASM configure -- M6's patch adds it -- and it does NOT build
# for wasm. Measured, with the failing translation unit and its cause named.

set -uo pipefail

TEST_NAME=verify_world_state_reference_tests_pass_under_wasm
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_vm2_tests.sh"

require_nix
m7_measured
m7_require_artifacts "$M7_WASM_BIN"
SRC="$M7_TREE/barretenberg/cpp/src/barretenberg"
assert_dir "the source tree" "$SRC"

# --- world_state_reference declares no tests --------------------------------
WSR_CMAKE="$SRC/world_state_reference/CMakeLists.txt"
assert_file "world_state_reference's CMakeLists" "$WSR_CMAKE"
assert_eq "it declares no TEST_SOURCE_FILES" 0 \
  "$(grep -c 'TEST_SOURCE_FILES' "$WSR_CMAKE" || true)"
assert_eq "and the module has no test source of its own" 0 \
  "$(find "$SRC/world_state_reference" -name '*.test.cpp' | wc -l | tr -d ' ')"
# But "no target" is not "no coverage", and the difference is measured rather than
# left as an implication: upstream tests the module's central component from the
# module next door, natively.
WSR_UPSTREAM_TEST="$SRC/world_state/memory_merkle_db.test.cpp"
assert_file "upstream DOES test MemoryMerkleDB, from world_state/" "$WSR_UPSTREAM_TEST"
assert_ge "and it is that module's reference DB it drives" 1 \
  "$(grep -c 'world_state_reference/memory_merkle_db' "$WSR_UPSTREAM_TEST" || true)"
assert_eq "with seven equivalence cases against a real world_state::WorldState" 7 \
  "$(grep -c '^TEST_F(MemoryMerkleDBEquivalenceTest,' "$WSR_UPSTREAM_TEST" || true)"
# It is native-only, and why is asserted below, once the target lists are read.
WASM_TARGETS="$M7_WORK/wsr-wasm-targets.txt"
m6_ninja_targets "$M7_TREE" "$M7_WASM_BUILD" >"$WASM_TARGETS"
assert_ge "the wasm build declares a target list" 100 "$(wc -l <"$WASM_TARGETS" | tr -d ' ')"
assert_eq "there is no world_state_reference_tests target in the wasm build" 0 \
  "$(grep -c 'world_state_reference_tests' "$WASM_TARGETS" || true)"
NATIVE_TARGETS="$M7_WORK/wsr-native-targets.txt"
m6_ninja_targets "$M7_TREE" "$M7_NATIVE_BUILD" >"$NATIVE_TARGETS"
assert_ge "the native build declares a target list" 100 "$(wc -l <"$NATIVE_TARGETS" | tr -d ' ')"
assert_eq "nor in the native build — the target does not exist anywhere" 0 \
  "$(grep -c 'world_state_reference_tests' "$NATIVE_TARGETS" || true)"
# The absence is not vacuous: the same list DOES carry test targets.
assert_ge "while the native target list does carry vm2_tests" 1 \
  "$(grep -c '^bin/vm2_tests$' "$NATIVE_TARGETS")"
# And the reason upstream's MemoryMerkleDB test cannot be among the 391 is a
# target-level fact, not a property of the test: `world_state` is LMDB-backed and
# server-side, so `src/CMakeLists.txt` keeps it out of a wasm configure entirely.
assert_ge "world_state_tests IS a target natively" 1 \
  "$(grep -c '^bin/world_state_tests$' "$NATIVE_TARGETS" || true)"
assert_eq "and is not one under wasm, which is why its 7 cases are native-only" 0 \
  "$(grep -c '^bin/world_state_tests$' "$WASM_TARGETS" || true)"

# --- world_state_reference is nevertheless IN the wasm artefact -------------
WSR_ARCHIVE="$M7_TREE/barretenberg/cpp/$M7_WASM_BUILD/lib/libworld_state_reference.a"
assert_file "libworld_state_reference.a is built for wasm" "$WSR_ARCHIVE"
assert_eq "and every member of it is a WebAssembly object" "WASM" \
  "$(m6_archive_formats "$M7_TREE" "$M7_WASM_BUILD" libworld_state_reference.a)"
link_line="$(grep -A6 "^build bin/vm2_sim_tests" "$M7_TREE/barretenberg/cpp/$M7_WASM_BUILD/build.ninja" | tr ' ' '\n' | grep -E '\.a$' | LC_ALL=C sort -u)"
assert_ge "it is on the wasm test binary's link line" 1 \
  "$(printf '%s\n' "$link_line" | grep -c 'libworld_state_reference\.a$')"
wsr_syms="$(m6_in_devshell '"$WASI_SDK_PREFIX/bin/llvm-nm" "$1" 2>/dev/null | grep -c "MemoryMerkleDB"' \
  "$M7_WASM_BIN" 2>/dev/null | tail -1)"
assert_ge "and its MemoryMerkleDB symbols are in the artefact" 1 "$wsr_syms"
note "MemoryMerkleDB symbols in the wasm test binary: $wsr_syms"

# world_state_reference's vocabulary reaches the tests through db.hpp.
assert_ge "vm2/simulation/interfaces/db.hpp takes MerkleTreeId from world_state_reference" 1 \
  "$(grep -c 'world_state_reference/merkle_tree_id' "$SRC/vm2/simulation/interfaces/db.hpp" || true)"

# --- THE REACHABILITY, measured ---------------------------------------------
# The in-memory trees are reachable only through PublicTxSimulationTester, and
# the question this section answers is whether anything in the 391 gets there.
# An earlier version of it stopped at `*.test.cpp` files that mention the tester
# by name, concluded "linked but not exercised", and was wrong: the bridge is a
# SUPPORT translation unit that this very overlay adds to the target.
assert_eq "sparse_memory_tree.hpp has exactly one consumer in the whole tree" \
  "world_state_reference/memory_merkle_db.hpp" \
  "$(cd "$SRC" && grep -rl 'sparse_memory_tree' . | sed 's|^\./||' | grep -v '^world_state_reference/sparse_memory_tree.hpp$' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
# Two consumers, not one: the AVM fuzzer's DB interfaces reach for it as well, and
# `avm_fuzzer/` is no more part of an AVM_WASM build than `integration_tests/` is.
assert_eq "and vm2's adapter over it has exactly two consumers, neither in the wasm target" \
  "avm_fuzzer/common/interfaces/dbs.hpp vm2/testing/public_tx_simulation_tester.hpp" \
  "$(cd "$SRC" && grep -rl 'simulation/lib/memory_merkle_db.hpp' . | sed 's|^\./||' | grep -v '^vm2/simulation/lib/memory_merkle_db\.\(hpp\|cpp\)$' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "and avm_fuzzer is not a target in the wasm build at all" 0 \
  "$(grep -c 'avm_fuzzer' "$WASM_TARGETS" || true)"
tester_users="$(cd "$SRC/vm2" && grep -rl 'public_tx_simulation_tester' --include='*.test.cpp' . | sed 's|^\./||' | LC_ALL=C sort)"
assert_ge "PublicTxSimulationTester has test users at all" 1 \
  "$(printf '%s\n' "$tester_users" | grep -c . )"
assert_eq "no *.test.cpp inside the target's globs names the tester directly" 0 \
  "$(printf '%s\n' "$tester_users" | grep -cE '^(simulation|common|tooling)/' || true)"
note "PublicTxSimulationTester's direct .test.cpp users (all excluded): $(printf '%s' "$tester_users" | tr '\n' ' ')"

# THE HOP THE EARLIER VERSION MISSED. Each link asserted separately, so a broken
# one names itself.
#
#   1. testing/fixtures.cpp uses the tester ...
assert_ge "vm2/testing/fixtures.cpp uses PublicTxSimulationTester" 1 \
  "$(grep -c 'public_tx_simulation_tester\|PublicTxSimulationTester' "$SRC/vm2/testing/fixtures.cpp" || true)"
#   2. ... it is a SUPPORT unit this overlay compiles into the test objects ...
assert_ge "the overlay's own CMake sweeps testing/*.cpp into VM2_SIM_TEST_SUPPORT_FILES" 1 \
  "$(grep -c 'file(GLOB VM2_SIM_TEST_SUPPORT_FILES testing/\*\.cpp)' "$SRC/vm2/CMakeLists.txt" || true)"
assert_ge "and ninja really builds fixtures.cpp into vm2_sim_test_objects" 1 \
  "$(grep -c 'vm2_sim_test_objects\.dir/testing/fixtures\.cpp\.obj' "$M7_TREE/barretenberg/cpp/$M7_WASM_BUILD/build.ninja" || true)"
#   3. ... AVM_SIM_TESTS_WITHOUT_TRACEGEN compiles out exactly two definitions,
#      and get_minimal_proving_inputs() is NOT one of them ...
assert_eq "AVM_SIM_TESTS_WITHOUT_TRACEGEN guards exactly two definitions" 2 \
  "$(grep -c '^#ifndef AVM_SIM_TESTS_WITHOUT_TRACEGEN$' "$SRC/vm2/testing/fixtures.cpp" || true)"
gmpi_syms="$(m6_in_devshell '"$WASI_SDK_PREFIX/bin/llvm-nm" "$1" 2>/dev/null | grep -c "get_minimal_proving_inputs"' \
  "$M7_WASM_BIN" 2>/dev/null | tail -1)"
assert_ge "so get_minimal_proving_inputs is DEFINED in the wasm artefact" 1 "$gmpi_syms"
sparse_syms="$(m6_in_devshell '"$WASI_SDK_PREFIX/bin/llvm-nm" "$1" 2>/dev/null | grep -c "SparseMemoryTree"' \
  "$M7_WASM_BIN" 2>/dev/null | tail -1)"
assert_ge "and so are the reference trees themselves" 1 "$sparse_syms"
note "wasm artefact: $gmpi_syms get_minimal_proving_inputs, $sparse_syms SparseMemoryTree symbol(s)"
#   4. ... the tester holds a MemoryMerkleDB BY VALUE, so constructing it builds
#      the reference trees ...
assert_ge "PublicTxSimulationTester holds a simulation::MemoryMerkleDB by value" 1 \
  "$(grep -c 'simulation::MemoryMerkleDB merkle_db_;' "$SRC/vm2/testing/public_tx_simulation_tester.hpp" || true)"
#   5. ... and a test source INSIDE the target calls it.
assert_ge "simulation/lib/hinting_dbs.test.cpp calls get_minimal_proving_inputs" 1 \
  "$(grep -c 'get_minimal_proving_inputs' "$SRC/vm2/simulation/lib/hinting_dbs.test.cpp" || true)"
assert_ge "from HintingDBsMinimalTest's fixture constructor" 1 \
  "$(grep -c 'HintingDBsTest(testing::get_minimal_proving_inputs())' "$SRC/vm2/simulation/lib/hinting_dbs.test.cpp" || true)"

# --- the standalone tests named in the deliverable --------------------------
OUT="$M7_WORK/wsr-v8.log"
m7_run_v8 "$M7_WASM_BIN" "$OUT"
assert_eq "the wasm suite exits 0" 0 $?
m7_names passed "$OUT" >"$M7_WORK/wsr-passed.txt"
assert_eq "with $M7_EXPECTED_SIM_TESTS tests passing" \
  "$M7_EXPECTED_SIM_TESTS" "$(wc -l <"$M7_WORK/wsr-passed.txt" | tr -d ' ')"

# suite -> declaring file, re-derived from the tree once, so `check_suite` can
# assert the MAPPING and not merely that a path exists. Asserting existence alone
# would pass for a suite declared somewhere else entirely.
SUITE_SOURCES="$M7_WORK/wsr-suite-sources.tsv"
python3 "$M7_SUITE_SOURCES" "$(m7_vm2_src)" >"$SUITE_SOURCES"
assert_ge "suite -> file mapping derived from the vm2 tree" 100 \
  "$(wc -l <"$SUITE_SOURCES" | tr -d ' ')"

check_suite() { # <suite> <expected count> <source file, relative to vm2/>
  local suite="$1" want="$2" rel="$3"
  assert_eq "$suite passes $want test(s) under wasm" "$want" \
    "$(grep -c "^$suite\." "$M7_WORK/wsr-passed.txt" || true)"
  assert_file "and its source is where the deliverable says" "$SRC/vm2/$rel"
  assert_eq "and that file really declares $suite" "$rel" \
    "$(awk -F'\t' -v s="$suite" '$1==s{print $2}' "$SUITE_SOURCES" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
}

# The three the deliverable names by file.
check_suite PureSha256Test              6 simulation/standalone/pure_sha256.test.cpp
check_suite PureKeccakSimulationTest    6 simulation/standalone/pure_keccakf1600.test.cpp
check_suite DebugLogSimulationTest      5 simulation/standalone/debug_log.test.cpp

# "the tree checks" — enumerated, because a phrase is not a set.
check_suite MerkleCheckSimulationTest                 7 simulation/gadgets/merkle_check.test.cpp
check_suite AvmSimulationIndexedTreeCheck             6 simulation/gadgets/indexed_tree_check.test.cpp
check_suite AvmSimulationNoteHashTree                 5 simulation/gadgets/note_hash_tree_check.test.cpp
check_suite AvmSimulationPublicDataTree               5 simulation/gadgets/public_data_tree_check.test.cpp
check_suite AvmSimulationL1ToL2MessageTree            1 simulation/gadgets/l1_to_l2_message_tree_check.test.cpp
check_suite AvmSimulationRetrievedBytecodesTreeCheck  4 simulation/gadgets/retrieved_bytecodes_tree_check.test.cpp
check_suite AvmSimulationWrittenPublicDataSlotsTreeCheck 5 simulation/gadgets/written_public_data_slots_tree_check.test.cpp
check_suite IndexedMemoryTree                         5 simulation/lib/indexed_memory_tree.test.cpp
check_suite AvmWrittenSlotsTree                       1 simulation/lib/written_slots_tree.test.cpp
check_suite AvmRetrievedBytecodesTree                 1 simulation/lib/retrieved_bytecodes_tree.test.cpp
check_suite HintingDBsMinimalTest                     2 simulation/lib/hinting_dbs.test.cpp
check_suite HintingDBsRandomInputTest                 5 simulation/lib/hinting_dbs.test.cpp
check_suite MockedHintingDBsTest                      8 simulation/lib/hinting_dbs.test.cpp
check_suite SideEffectTrackingDBTest                 18 simulation/lib/side_effect_tracking_db.test.cpp

# --- and therefore the reference trees ARE driven ---------------------------
# The two tests at the head of the chain asserted above are in the passing set,
# on this host and on wasmtime, so `world_state_reference`'s in-memory trees are
# constructed, mutated, checkpointed and read inside the 391 rather than merely
# linked. Named individually, because "HintingDBsMinimalTest passes 2" would also
# be satisfied by two different tests.
for t in HintingDBsMinimalTest.ContractDBCheckpoints HintingDBsMinimalTest.MerkleDBCheckpoints; do
  assert_ge "$t drives the reference world state and passes under wasm" 1 \
    "$(grep -cx "$t" "$M7_WORK/wsr-passed.txt" || true)"
done
# What is NOT established, stated as the narrower thing it is: no test here
# compares a tree ROOT native versus wasm. That is M8's.
note "the reference trees are exercised by the 391; comparing their roots native-vs-wasm is M8's"

# --- the one target-level exclusion -----------------------------------------
# M6's patch makes `crypto_merkle_tree_tests` a target in an AVM_WASM configure.
# It does not build. Asserted by building it, not by reading anything.
assert_ge "crypto_merkle_tree_tests IS a target in this wasm build" 1 \
  "$(grep -c '^bin/crypto_merkle_tree_tests$' "$WASM_TARGETS")"
# In a build directory of its OWN, configured here. Reusing the primary one would
# both pollute the artefact every other check reads and make the result depend on
# whatever state that directory happened to be in.
m6_configure "$M7_TREE" wasm-avm build-wasm-cmt -DAVM_SIM_TESTS=ON
assert_eq "a dedicated build directory configures" 0 $?
m6_build "$M7_TREE" build-wasm-cmt crypto_merkle_tree_tests
cmt_rc=$?
assert_false "and crypto_merkle_tree_tests does NOT build for wasm" test "$cmt_rc" -eq 0
cmtlog="$M7_TREE/m6-build-wasm-cmt-build.log"
assert_file "the failing build left a log" "$cmtlog"
assert_eq "exactly one translation unit fails" 1 \
  "$(grep -c '^FAILED:' "$cmtlog" || true)"
assert_eq "and -Wfatal-errors means no ordinary ': error: ' line at all" 0 \
  "$(grep -c ': error: ' "$cmtlog" || true)"
assert_contains "the failing unit is node_store/content_addressed_cache.test.cpp" \
  "content_addressed_cache.test.cpp" "$(cat "$cmtlog")"
assert_contains "failing on ThreadPool, which MULTITHREADING=OFF removes" \
  "use of undeclared identifier 'ThreadPool'" "$(cat "$cmtlog")"
assert_false "no crypto_merkle_tree_tests wasm binary is produced" \
  test -f "$M7_TREE/barretenberg/cpp/build-wasm-cmt/bin/crypto_merkle_tree_tests"
# Not vacuous: the same directory DOES build the AVM's own test binary.
m6_build "$M7_TREE" build-wasm-cmt vm2_sim_tests
assert_eq "while the same directory builds vm2_sim_tests fine" 0 $?
# The second, independent reason it is the wrong target for an AVM-only build.
assert_ge "it also links stdlib_poseidon2, which is proving-side" 1 \
  "$(grep -c 'crypto_merkle_tree_tests PRIVATE stdlib_poseidon2' "$SRC/crypto/merkle_tree/CMakeLists.txt" || true)"

# The primary artefact survived the failed build above.
assert_file "the vm2_sim_tests wasm binary is still there" "$M7_WASM_BIN"

finish
