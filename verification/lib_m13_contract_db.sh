#!/usr/bin/env bash
# Shared machinery for the M13 checks — the shippable contract DB and checkpoint coordination.
#
# WHAT M13 CHANGES, AND WHAT IT DOES NOT.
#
# ONE worktree of the fork at 233d8e0993 carrying TEN patches: M12's nine, plus M13's own overlay.
# The overlay adds `simulation::MemoryContractDB` and `simulation::CheckpointCoordinator` under
# `vm2/simulation/standalone/`, points the reactor at the first, exports the second, and adds a
# `contractdbinputs` mode to the differential driver. Two build directories inside the tree, the
# same two M12 uses:
#
#   build-wasm-avm     `wasm-avm` preset, -DAVM_REACTOR=ON -DAVM_DIFFERENTIAL=ON -DAVM_SIM_TESTS=ON
#                      -> bin/avm.wasm            the reactor, now with 49 exports
#                      -> bin/avm.wasm.gz
#                      -> bin/vm2_sim_tests       upstream's own suite, plus the store's unit tests
#   build-native-avm   `default` preset, the same options
#                      -> bin/avm_differential    produces the inputs, in `contractdbinputs` mode
#                      -> bin/vm2_sim_tests       the same suite natively
#
# M12'S TREE AND M13'S ARE DIFFERENT TREES, ON PURPOSE. M13's overlay changes the export list from
# thirty-nine names to forty-nine, and `verify_avm_wasm_import_surface` holds M12's artefact to
# thirty-nine as an IDENTITY. That check is right to: an export appearing is as much a finding as
# one disappearing. So M13 builds its own tree in its own work directory and M12's checks keep
# measuring M12's artefact. Both are re-run in the regression sweep and both pass, which is the only
# way "additive" means anything here.
#
# It reuses M12's machinery, which reuses M9's, M8's, M7's and M6's, rather than re-implementing any
# of it: M12_WORK is pointed at $M13_WORK before lib_m12_reactor.sh is sourced, and that file does
# the same for M9_WORK, so every tree, configure and build operates inside M13's own directory.
#
# Nothing here has a skip path. A tree that cannot be prepared, a build that fails, a runtime that
# is missing or a transcript with no lines in it is `die` or a failed assertion, never a printed
# SKIP.
#
# Not to be executed directly: sourced by verification/verify_*.sh and test_*.sh, AFTER lib.sh.

# MEASURED on 32 cores with a warm ccache: about 8 minutes and 1.2 GB from an empty $M13_WORK, the
# same shape as M12's, because it is the same two builds of the same tree plus one more translation
# unit. The 8 GB floor below is a precondition rather than a prediction. /tmp is usually a tmpfs and
# is the wrong place: set M13_WORK.
M13_WORK="${M13_WORK:-$HOME/.cache/aztec-m13-contractdb}"
M12_WORK="$M13_WORK"
export M13_WORK M12_WORK

# shellcheck source=lib_m12_reactor.sh
. "$VERIFY_DIR/lib_m12_reactor.sh"

# M13's own overlay: the tenth patch. Ours, a downstream target. It is written in Aztec's module and
# in a shape they could take — see CONTRACT-DB.md — but it has NOT been prepared as a sixth upstream
# contribution, because that needs a published branch and a sixth entry in carry/series.json, and
# this milestone opens no pull requests and pushes nothing.
M13_PATCH_10="$REPO_ROOT/verification/m13/0001-test-vm2-a-shippable-in-memory-contract-DB-and-a-che.patch"

M13_TREE_NAME=m13
M13_WASM_BUILD="$M12_WASM_BUILD"
M13_NATIVE_BUILD="$M12_NATIVE_BUILD"

# The write-up whose numbers the checks re-derive rather than trust.
M13_WRITEUP="$REPO_ROOT/CONTRACT-DB.md"

M13_HOST="$VERIFY_DIR/wasm_host/avm_contract_db_host.mjs"
M13_DECODER="$REPO_ROOT/diffsim/decode_deployment_logs.mjs"

# ---------------------------------------------------------------------------
# THE ENUMERATION, as a pattern rather than as a list.
#
# The eight implementations of `ContractDBInterface` upstream has at the anchor are found by ONE
# regular expression over the whole fork, so a ninth appearing is a finding rather than something a
# hand-written list would hide. The milestone's own text names three of them; the enumeration finds
# eight, and `FuzzerContractDB` — under `avm_fuzzer/`, a barretenberg subdirectory rather than
# anything under `vm2/` — is the one an enumeration of `vm2/` alone would miss.
# ---------------------------------------------------------------------------
M13_IMPL_REGEX='class [A-Za-z_]+ (final )?: public ([A-Za-z0-9_]+::)*ContractDBInterface'

# The eight, as an IDENTITY: "class path" per line, sorted. Nine would fail this, and so would seven.
M13_EXPECTED_IMPLS="CdbIpcContractDB barretenberg/cpp/src/barretenberg/cdb/cdb_ipc_client.hpp
ContractDB barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/concrete_dbs.hpp
FuzzerContractDB barretenberg/cpp/src/barretenberg/avm_fuzzer/common/interfaces/dbs.hpp
HintedRawContractDB barretenberg/cpp/src/barretenberg/vm2/simulation/lib/raw_data_dbs.hpp
HintingContractsDB barretenberg/cpp/src/barretenberg/vm2/simulation/lib/hinting_dbs.hpp
MockContractDB barretenberg/cpp/src/barretenberg/vm2/simulation/testing/mock_dbs.hpp
PureContractDB barretenberg/cpp/src/barretenberg/vm2/simulation/standalone/concrete_dbs.hpp
TestContractDB barretenberg/cpp/src/barretenberg/vm2/testing/public_tx_simulation_tester.hpp"
M13_EXPECTED_IMPL_COUNT=8

# The eight ContractDBInterface methods, from the interface's own declaration rather than from here.
M13_CONTRACT_DB_METHODS="add_contracts
commit_checkpoint
create_checkpoint
get_bytecode_commitment
get_contract_class
get_contract_instance
get_debug_function_name
revert_checkpoint"

# ---------------------------------------------------------------------------
# The module surface after the overlay. M12's thirty-nine plus TEN, and the twelve imports
# UNCHANGED — which is the claim that matters: a contract DB with more surface must not have cost
# the artefact a single new host import.
# ---------------------------------------------------------------------------
M13_NEW_EXPORTS="avm_contract_db_get_checkpoint_id
avm_contract_db_register_debug_function_names
avm_coordinator_assert_lockstep
avm_coordinator_checkpoint_ids
avm_coordinator_commit_checkpoint
avm_coordinator_create
avm_coordinator_create_checkpoint
avm_coordinator_destroy
avm_coordinator_revert_checkpoint
avm_coordinator_simulate"
M13_NEW_EXPORT_COUNT=10
M13_EXPECTED_EXPORT_COUNT=49
M13_EXPECTED_IMPORT_COUNT="$M12_EXPECTED_IMPORT_COUNT"
M13_EXPECTED_WASI_IMPORT_COUNT="$M12_EXPECTED_WASI_IMPORT_COUNT"

# The size budget is M12's, unchanged and deliberately so: the artefact grew and it must still fit
# the budget the two link-option controls fail. The measured figures are recorded for drift, not
# asserted as identities — -Oz output moves with a toolchain bump.
M13_SIZE_BUDGET_RAW="${M13_SIZE_BUDGET_RAW:-$M12_SIZE_BUDGET_RAW}"
M13_SIZE_BUDGET_GZ="${M13_SIZE_BUDGET_GZ:-$M12_SIZE_BUDGET_GZ}"
M13_MEASURED_RAW=1591391
M13_MEASURED_GZ=357558
# M12's, from its own tree, for the delta.
M13_M12_MEASURED_RAW="$M12_MEASURED_RAW"
M13_M12_MEASURED_GZ="$M12_MEASURED_GZ"

# The seven corpus programs, and which of them succeed and which revert. Both outcomes are needed:
# a deploy/call/revert roundtrip whose corpus only ever succeeds proves half of it.
M13_PROGRAMS="$M12_PROGRAMS"
M13_EXPECTED_PROGRAMS="$M12_EXPECTED_PROGRAMS"
M13_SUCCEEDING_PROGRAMS="add loop poseidon2 sha256 storage"
M13_REVERTING_PROGRAMS="burn revert"

# The unit tests the overlay adds to upstream's own `vm2_sim_tests` binary, by name. Asserted as an
# identity so a test quietly disappearing is a failure.
M13_UNIT_TESTS="CheckpointCoordinatorTest.DetectsADesynchronisationInjectedBehindItsBack
CheckpointCoordinatorTest.DrivesBothStacksAndReportsThemEqual
CheckpointCoordinatorTest.RefusesToUnderflowEitherStack
CheckpointCoordinatorTest.TheContractDbItHandsOutIsTheDecorator
MemoryContractDBTest.AddContractsAndExplicitRegistrationAgree
MemoryContractDBTest.AddContractsDecodesPublishedEventLogs
MemoryContractDBTest.CheckpointIdsFollowTheMerkleDbVocabulary
MemoryContractDBTest.DebugNamesArriveAsUpstreamHints
MemoryContractDBTest.ExplicitRegistrationServesAllFourGetters
MemoryContractDBTest.LookupsMissBeforeAnythingIsRegistered
MemoryContractDBTest.RevertUndoesRegistrationsAndCommitKeepsThem
MemoryContractDBTest.UnderflowThrowsRatherThanSilentlyDoingNothing"
M13_UNIT_TEST_COUNT=12

export M13_PATCH_10 M13_TREE_NAME M13_HOST M13_DECODER M13_WRITEUP

# ---------------------------------------------------------------------------
# m13_tree -> the prepared worktree, or die.
#
# 233d8e0993 + M12's nine + M13's overlay, in that order, by `git am` with no -3: each must apply to
# what precedes it exactly.
# ---------------------------------------------------------------------------
m13_tree() {
  m9_require_patches
  [ -f "$M12_PATCH_9" ] || die "M12's overlay patch is missing: $M12_PATCH_9"
  [ -f "$M13_PATCH_10" ] || die "M13's overlay patch is missing: $M13_PATCH_10"
  M13_TREE=$(m6_prepare_tree "$M13_TREE_NAME" \
    "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4" \
    "$M9_OBSERVER_PATCH" "$M7_PATCH_5" "$M8_PATCH_6" "$M9_PATCH_7" "$M12_PATCH_9" "$M13_PATCH_10")
  # A command substitution swallows `die`, so the tree can come back empty and every later
  # `git -C ""` would run in the CALLER's repository. M6 was bitten by exactly this.
  m6_tree_or_die M13_TREE
  export M13_TREE
  printf '%s\n' "$M13_TREE"
}

m13_build_wasm() { # <tree>
  local tree="$1"
  m6_configure "$tree" wasm-avm "$M13_WASM_BUILD" -DAVM_DIFFERENTIAL=ON -DAVM_REACTOR=ON -DAVM_SIM_TESTS=ON
  M13_WASM_CONFIGURE_RC=$?
  [ "$M13_WASM_CONFIGURE_RC" -eq 0 ] || return "$M13_WASM_CONFIGURE_RC"
  m6_build "$tree" "$M13_WASM_BUILD" avm.wasm.gz avm-unpruned.wasm.gz avm-nogc.wasm.gz vm2_sim_tests
  M13_WASM_BUILD_RC=$?
  return "$M13_WASM_BUILD_RC"
}

m13_build_native() { # <tree>
  local tree="$1"
  # FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER for the reason M7 recorded and M8, M9 and M12 repeat:
  # cmake/gtest.cmake declares GTest with FIND_PACKAGE_ARGS, so a native configure otherwise prefers
  # whatever find_package(GTest) turns up.
  m6_native_configure "$tree" "$M13_NATIVE_BUILD" -DAVM_DIFFERENTIAL=ON -DAVM_REACTOR=ON -DAVM_SIM_TESTS=ON \
    -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER
  M13_NATIVE_CONFIGURE_RC=$?
  [ "$M13_NATIVE_CONFIGURE_RC" -eq 0 ] || return "$M13_NATIVE_CONFIGURE_RC"
  m6_build "$tree" "$M13_NATIVE_BUILD" avm_differential vm2_sim_tests
  M13_NATIVE_BUILD_RC=$?
  return "$M13_NATIVE_BUILD_RC"
}

m13_wasm_bin()   { printf '%s\n' "$M13_TREE/barretenberg/cpp/$M13_WASM_BUILD/bin/$1"; }
m13_native_bin() { printf '%s\n' "$M13_TREE/barretenberg/cpp/$M13_NATIVE_BUILD/bin/$1"; }

m13_inputs()          { printf '%s\n' "$M13_WORK/contractdb-inputs.txt"; }
m13_upstream_decode() { printf '%s\n' "$M13_WORK/upstream-decode.txt"; }

# ---------------------------------------------------------------------------
# m13_run_host <mode> <stdout> <stderr> [args...]
#
# Drives `avm.wasm` from node through wasm_host/avm_contract_db_host.mjs. stdout and stderr are kept
# APART, for M8's reason and M9's — `common/log.cpp` sets `bb_log_level = VERBOSE` unconditionally
# under `__wasm__`, so the AVM narrates on fd 2 — and here fd 2 is ALSO evidence: the frame labels
# `TxExecution::get_debug_function_name` produces are on it.
# ---------------------------------------------------------------------------
m13_run_host() {
  local mode="$1" out="$2" err="$3"; shift 3
  local wasm; wasm="$(m13_wasm_bin avm.wasm)"
  [ -f "$wasm" ] || die "no reactor module at $wasm — nothing to run"
  [ -f "$(m13_inputs)" ] || die "no contract DB inputs at $(m13_inputs)"
  m6_in_devshell '
    host="$1"; wasm="$2"; inputs="$3"; mode="$4"; t="$5"; err="$6"; shift 6
    timeout --foreground --preserve-status -s KILL "$t" node "$host" "$wasm" "$inputs" "$mode" "$@" 2>"$err"
  ' "$M13_HOST" "$wasm" "$(m13_inputs)" "$mode" "$M7_RUN_TIMEOUT" "$err" "$@" >"$out"
}

# m13_field <file> <key> -> the value of a `<key> <value>` line, or the empty string.
m13_field() {
  [ -f "$1" ] || die "m13_field: no such file: $1"
  awk -v k="$2" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' "$1"
}

# m13_assert_field <description> <file> <key> <expected>
m13_assert_field() {
  local desc="$1" file="$2" key="$3" want="$4"
  assert_eq "$desc" "$want" "$(m13_field "$file" "$key")"
}

# ---------------------------------------------------------------------------
# m13_measured
#
# $M13_WORK/measured.env — the single record of what was built and run, written by
# verify_contract_db_reuse_decision_recorded, which is the check that builds. Every other M13 check
# reads it. If it is not there that check is RUN to produce one; it is never invented, defaulted or
# skipped. And every artefact the record NAMES is asserted present before any predicate reads it —
# M6's review found four assertions passing over a build directory that held nothing, because every
# predicate returned 0 over a missing path.
# ---------------------------------------------------------------------------
m13_measured() {
  if [ ! -f "$M13_WORK/measured.env" ]; then
    note "no measurement on record — running verify_contract_db_reuse_decision_recorded to produce one"
    mkdir -p "$M13_WORK"
    "$VERIFY_DIR/verify_contract_db_reuse_decision_recorded.sh" >"$M13_WORK/build-for-record.log" 2>&1 \
      || die "could not produce a measurement: see $M13_WORK/build-for-record.log"
  fi
  [ -f "$M13_WORK/measured.env" ] || die "measurement record missing at $M13_WORK/measured.env"
  # shellcheck disable=SC1090
  . "$M13_WORK/measured.env"
  [ -n "${M13_TREE:-}" ] && [ -d "$M13_TREE" ] \
    || die "measurement names no tree, or a tree that is gone: [${M13_TREE:-}]"
  m8_require_artifacts "$(m13_wasm_bin avm.wasm)" "$(m13_wasm_bin avm.wasm.gz)" \
    "$(m13_wasm_bin vm2_sim_tests)" \
    "$(m13_native_bin avm_differential)" "$(m13_native_bin vm2_sim_tests)" \
    "$(m13_inputs)"
}
