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
# The module's REAL tests are upstream's, in the module next door:
# `world_state/memory_merkle_db.test.cpp` declares seven
# `MemoryMerkleDBEquivalenceTest` cases that drive an ephemeral file-backed
# `world_state::WorldState` and a `MemoryMerkleDB` through the same sequence and
# compare roots, sibling paths, low-leaf lookups, indexed-leaf preimages and leaf
# values. `world_state` is LMDB-backed and is not in a wasm configure, so the
# file cannot be built for wasm as written -- and THIS CHECK RUNS ALL SEVEN UNDER
# WASM ANYWAY, by splitting each case into its two halves without editing it
# (verification/m7/wsr/, lib_vm2_tests.sh's m7_wsr_*):
#
#   * natively, the upstream source is compiled with an overlay header that
#     forwards every `ws->` call to the REAL LMDB WorldState and records the call,
#     its arguments and its answer. That run is upstream's gate passing natively,
#     and its by-product is the transcript.
#   * under wasm (V8), the SAME upstream source is compiled with the overlay in
#     replay mode: no WorldState exists, each `ws->` call must be the next recorded
#     one with byte-identical arguments, and it returns the recorded LMDB answer.
#     So upstream's own sequences run against the wasm-built MemoryMerkleDB, and
#     upstream's own EXPECT_EQs compare it with what the real WorldState said.
#   * natively in replay mode, as the control.
#   * five mutation arms over the transcript (a root, a sibling path, a low-leaf
#     index, a recorded argument, a dropped call), each of which must turn exactly
#     its own case red under wasm and leave the other six green.
#
# The seven are run by name and by count, and the transcript is consumed whole.
#
# Also covered, each a separate claim:
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
# Roots ARE compared here, by upstream's gate: the wasm MemoryMerkleDB's roots
# against the native LMDB WorldState's, after every step of seven sequences.
# What stays M8's is the AVM-level differential -- the same transaction's tree
# roots out of the wasm simulator and the native one.
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
# Why it cannot be built for wasm AS WRITTEN is asserted below, once the target lists are read;
# that it is RUN under wasm regardless is the section "upstream's equivalence gate, split".
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
assert_eq "and is not one under wasm, which is why its 7 cases need the split below" 0 \
  "$(grep -c '^bin/world_state_tests$' "$WASM_TARGETS" || true)"

# --- world_state_reference is nevertheless IN the wasm artefact -------------
WSR_ARCHIVE="$M7_TREE/barretenberg/cpp/$M7_WASM_BUILD/lib/libworld_state_reference.a"
assert_file "libworld_state_reference.a is built for wasm" "$WSR_ARCHIVE"
assert_eq "and every member of it is a WebAssembly object" "WASM" \
  "$(m6_archive_formats "$M7_TREE" "$M7_WASM_BUILD" libworld_state_reference.a)"
link_line="$(grep -A6 "^build bin/vm2_sim_tests" "$M7_TREE/barretenberg/cpp/$M7_WASM_BUILD/build.ninja" | tr ' ' '\n' | grep -E '\.a$' | LC_ALL=C sort -u)"
assert_ge "it is on the wasm test binary's link line" 1 \
  "$(printf '%s\n' "$link_line" | grep -c 'libworld_state_reference\.a$')"
# Counted by namespace: vm2 has its own adapter class of the same name,
# bb::avm2::simulation::MemoryMerkleDB, and a bare "MemoryMerkleDB" match would be
# satisfied by the adapter alone. This module's class is bb::world_state's.
wsr_syms="$(m6_in_devshell '"$WASI_SDK_PREFIX/bin/llvm-nm" "$1" 2>/dev/null | grep -c "bb::world_state::MemoryMerkleDB::"' \
  "$M7_WASM_BIN" 2>/dev/null | tail -1)"
assert_ge "and its own bb::world_state::MemoryMerkleDB symbols are in the artefact" 1 "$wsr_syms"
note "bb::world_state::MemoryMerkleDB symbols in the wasm test binary: $wsr_syms"

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
note "the reference trees are exercised by the 391; upstream's own root comparison follows"

# --- upstream's equivalence gate, split, under wasm --------------------------
# The seven MemoryMerkleDBEquivalenceTest cases, compiled from the tree's own
# world_state/memory_merkle_db.test.cpp three times (see lib_vm2_tests.sh,
# "THE TRANSCRIPT SPLIT"). Upstream's source is not edited: the overlay is a
# header found first on the quote-include path.
WSR_TEST_REL="barretenberg/cpp/src/barretenberg/$M7_WSR_UPSTREAM_TEST"
assert_true "the source compiled is upstream's, unmodified by any patch on the M7 tree" \
  git -C "$M7_TREE" diff --quiet "$M6_BASE_REV" HEAD -- "$WSR_TEST_REL"
assert_true "and unmodified in the working tree" git -C "$M7_TREE" diff --quiet HEAD -- "$WSR_TEST_REL"
WSR_CASES="$M7_WSR_OUT/cases.txt"
mkdir -p "$M7_WSR_OUT"
sed -n 's/^TEST_F(\(MemoryMerkleDBEquivalenceTest\), *\([A-Za-z0-9_]*\)).*/\1.\2/p' "$WSR_UPSTREAM_TEST" \
  | LC_ALL=C sort -u >"$WSR_CASES"
assert_eq "the case names are derived from that source: $M7_WSR_EXPECTED_CASES of them" \
  "$M7_WSR_EXPECTED_CASES" "$(wc -l <"$WSR_CASES" | tr -d ' ')"
assert_eq "the overlay shadows exactly the one header the test includes" \
  "barretenberg/world_state/world_state.hpp" \
  "$(cd "$M7_WSR_DIR/overlay" && find . -type f | sed 's|^\./||')"
assert_ge "and the test includes it" 1 \
  "$(grep -c '^#include "barretenberg/world_state/world_state.hpp"$' "$WSR_UPSTREAM_TEST" || true)"

for arm in native-record native-replay wasm-replay; do
  m7_wsr_build "$arm"
  assert_eq "the $arm build of the upstream test compiles and links" 0 $?
  assert_file "and produced its binary" "$(m7_wsr_bin "$arm")"
done
assert_eq "the wasm-replay binary is a WebAssembly module" "0061736d" \
  "$(head -c 4 "$(m7_wsr_bin wasm-replay)" | od -An -tx1 | tr -d ' \n')"
# Which side the real WorldState is on is read off the link lines and the artefacts, not assumed.
wsr_link() { grep '^### link:' "$M7_WSR_OUT/$1.build.log"; }
assert_contains "the recording links the LMDB-backed world_state" "lib/libworld_state.a" "$(wsr_link native-record)"
assert_contains "and liblmdb" "liblmdb.a" "$(wsr_link native-record)"
for arm in native-replay wasm-replay; do
  assert_not_contains "the $arm link line has no world_state library" "libworld_state.a" "$(wsr_link "$arm")"
  assert_not_contains "and no lmdb" "lmdb" "$(wsr_link "$arm")"
  assert_contains "but does link world_state_reference" "lib/libworld_state_reference.a" "$(wsr_link "$arm")"
done
wsr_wasm_ws="$(m6_in_devshell '"$WASI_SDK_PREFIX/bin/llvm-nm" -C "$1" 2>/dev/null | grep -c "bb::world_state::WorldState::"' \
  "$(m7_wsr_bin wasm-replay)" 2>/dev/null | tail -1)"
assert_eq "the wasm artefact holds no bb::world_state::WorldState symbol" 0 "${wsr_wasm_ws:-x}"
wsr_wasm_mem="$(m6_in_devshell '"$WASI_SDK_PREFIX/bin/llvm-nm" -C "$1" 2>/dev/null | grep -c "bb::world_state::MemoryMerkleDB::"' \
  "$(m7_wsr_bin wasm-replay)" 2>/dev/null | tail -1)"
assert_ge "and does hold the reference's bb::world_state::MemoryMerkleDB" 1 "${wsr_wasm_mem:-0}"
wsr_rec_ws="$(m6_in_devshell 'nm -C "$1" 2>/dev/null | grep -c "bb::world_state::WorldState::"' \
  "$(m7_wsr_bin native-record)" 2>/dev/null | tail -1)"
assert_ge "while the recording does hold the real WorldState" 1 "${wsr_rec_ws:-0}"

# wsr_verdict <arm> <log> <rc> -- the seven passed by name, and every recorded call consumed.
wsr_verdict() {
  local arm="$1" log="$2" rc="$3"
  assert_eq "$arm: the run exits 0" 0 "$rc"
  m7_names passed "$log" >"$log.passed"
  m7_set_equal "$arm: the passing set is the seven upstream cases" "$WSR_CASES" "$log.passed"
  assert_eq "$arm: gtest's own summary says $M7_WSR_EXPECTED_CASES passed" \
    "$M7_WSR_EXPECTED_CASES" "$(m7_summary_passed "$log")"
  assert_eq "$arm: nothing failed" 0 "$(m7_names failed "$log" | grep -c . || true)"
}

# 1. Record, natively, against the real LMDB WorldState.
WSR_TRANSCRIPT_FILE="$M7_WSR_OUT/transcript.tsv"
rm -f "$WSR_TRANSCRIPT_FILE"
m7_wsr_run native-record "$WSR_TRANSCRIPT_FILE" "$M7_WSR_OUT/native-record.log"
wsr_verdict native-record "$M7_WSR_OUT/native-record.log" $?
assert_file "the recording wrote a transcript" "$WSR_TRANSCRIPT_FILE"
wsr_records="$(wc -l <"$WSR_TRANSCRIPT_FILE" | tr -d ' ')"
assert_ge "with at least a hundred recorded WorldState calls" 100 "$wsr_records"
assert_eq "and every line is a five-field record" "$wsr_records" \
  "$(awk -F'\t' 'NF == 5' "$WSR_TRANSCRIPT_FILE" | wc -l | tr -d ' ')"
assert_eq "recorded by exactly the seven cases" "$(cat "$WSR_CASES")" \
  "$(cut -f1 "$WSR_TRANSCRIPT_FILE" | LC_ALL=C sort -u)"
assert_eq "and the recorder's own per-case tally adds up to the transcript" "$wsr_records" \
  "$(sed -n 's/^\[wsr-record\] [^ ]* records=\([0-9]*\)$/\1/p' "$M7_WSR_OUT/native-record.log" | awk '{t += $1} END {print t + 0}')"
# Every kind of comparison upstream makes is in it, and every kind of mutation it drives.
for m in construct get_tree_info get_sibling_path find_low_leaf_index get_indexed_leaf get_leaf \
         append_leaves insert_indexed_leaves checkpoint commit_checkpoint revert_checkpoint; do
  assert_ge "the transcript records $m" 1 "$(cut -f3 "$WSR_TRANSCRIPT_FILE" | grep -cx "$m" || true)"
done
note "transcript: $wsr_records WorldState calls over $M7_WSR_EXPECTED_CASES cases"

# wsr_consumed <log> -- every case consumed all its records with no argument mismatch.
wsr_consumed() {
  local arm="$1" log="$2"
  assert_eq "$arm: all seven cases report their replay" "$M7_WSR_EXPECTED_CASES" \
    "$(grep -c '^\[wsr-replay\] ' "$log" || true)"
  assert_eq "$arm: each consumed every recorded call, with no argument mismatch" 0 \
    "$(grep '^\[wsr-replay\] ' "$log" | awk '{split($3,c,"="); split($4,r,"="); if (c[2] != r[2] || $5 != "args_mismatches=0") n++} END {print n + 0}')"
  assert_eq "$arm: and between them consumed the whole transcript" "$wsr_records" \
    "$(sed -n 's/^\[wsr-replay\] [^ ]* consumed=\([0-9]*\) .*/\1/p' "$log" | awk '{t += $1} END {print t + 0}')"
}

# 2. The control: the same replay, natively.
m7_wsr_run native-replay "$WSR_TRANSCRIPT_FILE" "$M7_WSR_OUT/native-replay.log"
wsr_verdict native-replay "$M7_WSR_OUT/native-replay.log" $?
wsr_consumed native-replay "$M7_WSR_OUT/native-replay.log"

# 3. THE SUBJECT: upstream's seven cases under wasm, against the real LMDB answers.
m7_wsr_run wasm-replay "$WSR_TRANSCRIPT_FILE" "$M7_WSR_OUT/wasm-replay.log"
wsr_verdict wasm-replay "$M7_WSR_OUT/wasm-replay.log" $?
wsr_consumed wasm-replay "$M7_WSR_OUT/wasm-replay.log"

# 4. Red first: each mutation must turn exactly its own case red under wasm, with upstream's
#    (or the replay's) own message, and leave the other six green.
wsr_mutant() { # <label> <expected message> <mode> <case> [<method> <n>]
  local label="$1" msg="$2" mode="$3" case="$4"; shift 4
  local t="$M7_WSR_OUT/mut-$label.tsv" log="$M7_WSR_OUT/mut-$label.log" rc
  python3 "$M7_WSR_DIR/_perturb.py" "$WSR_TRANSCRIPT_FILE" "$t" "$mode" \
    "MemoryMerkleDBEquivalenceTest.$case" "$@" >"$log.what" 2>&1
  rc=$?
  assert_eq "mutant $label: the perturbation hit a record ($(cat "$log.what"))" 0 "$rc"
  m7_wsr_run wasm-replay "$t" "$log"
  rc=$?
  assert_false "mutant $label: the wasm run goes red" test "$rc" -eq 0
  assert_eq "mutant $label: exactly MemoryMerkleDBEquivalenceTest.$case fails" \
    "MemoryMerkleDBEquivalenceTest.$case" "$(m7_names failed "$log" | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "mutant $label: the other six still pass" 6 "$(m7_names passed "$log" | grep -c . || true)"
  assert_contains "mutant $label: and says why" "$msg" "$(cat "$log")"
}
wsr_mutant root         "root mismatch for tree 0"         root      Checkpoints      get_tree_info 8
wsr_mutant sibling-path "sibling path mismatch for tree 0" answer    InsertNullifiers get_sibling_path 0
wsr_mutant low-leaf     "low leaf mismatch for tree 0"     answer    GenesisMatches   find_low_leaf_index 0
wsr_mutant input        "(append_leaves): the arguments differ from the recorded ones" \
                                                           args      Checkpoints      append_leaves 0
wsr_mutant dropped-call "after its 26 recorded calls"      drop-last MixedSequence
# And the unperturbed transcript is still green on the same binary, after all five.
m7_wsr_run wasm-replay "$WSR_TRANSCRIPT_FILE" "$M7_WSR_OUT/wasm-replay-after.log"
assert_eq "the unperturbed replay is green again after the mutants" 0 $?

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
