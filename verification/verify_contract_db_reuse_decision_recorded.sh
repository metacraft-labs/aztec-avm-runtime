#!/usr/bin/env bash
# verify_contract_db_reuse_decision_recorded
#
# THE REUSE QUESTION IS THE MILESTONE, AND THIS IS THE CHECK THAT ANSWERS IT BY ENUMERATION.
#
# The choice was between three dispositions — ship `TestContractDB` as it is, upstream an in-memory
# store under `standalone/` beside `PureContractDB`, or write a browser-resident one of our own —
# and the answer is worth nothing without the enumeration that produced it. So this check does not
# read the answer out of a document and agree with it. It re-derives, FROM THE FORK AT THE ANCHOR on
# every run:
#
#   * every implementation of `ContractDBInterface` upstream has, by ONE regular expression over the
#     whole tree rather than from a list here. There are EIGHT. The milestone's own text names
#     three, and the one an enumeration of `vm2/` alone would miss — `FuzzerContractDB`, under
#     `avm_fuzzer/` — is the one that turned out to matter most, because it is the only place
#     upstream decodes a deployment log in C++;
#   * the specific facts that disqualify each candidate: that `TestContractDB::add_contracts` has an
#     empty body and its `get_debug_function_name` returns `nullopt` unconditionally; that
#     `avm_fuzzer`'s module is gated on `FUZZING_AVM` and declares `DEPENDENCIES vm2`; that
#     `cdb_ipc_client` links `barretenberg` and `ipc_runtime`; and that `PureContractDB` holds a
#     `ContractDBInterface&` and is therefore a decorator rather than a store.
#
# Only then is the write-up held to the enumeration: every implementation the regex found must be
# named in `CONTRACT-DB.md`, all three dispositions must be discussed, and the one taken must be
# stated.
#
# IT IS ALSO THE CHECK THAT BUILDS, and it records what it measured in $M13_WORK/measured.env for
# the other five. Two trees, two builds, statuses asserted SEPARATELY — a stale artefact from a
# previous run will happily produce a plausible transcript over a build that did not happen (M2's
# defect, M3's lesson) — and the build log is searched with a needle that cannot match
# `fatal error:` as a substring, because `-Wfatal-errors` makes a failed build emit exactly one such
# line and zero of the ones a naive grep looks for.
#
# The size and export measurements are here because they are consequences OF the decision: the
# reactor's raw store changed, so the export list, the import list and the artefact's size all had
# to be re-measured rather than inherited from M12.

TEST_NAME="verify_contract_db_reuse_decision_recorded"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m13_contract_db.sh"

require_work_dir "$M13_WORK" 8

ANCHOR="$M6_BASE_REV"
[ -e "$FORK_ROOT/.git" ] || die "no aztec-packages checkout at $FORK_ROOT"
git -C "$FORK_ROOT" rev-parse --verify --quiet "$ANCHOR^{commit}" >/dev/null \
  || die "the anchor $ANCHOR is not in $FORK_ROOT"

# ---------------------------------------------------------------------------
# 1. The enumeration, derived rather than declared.
# ---------------------------------------------------------------------------
impls="$(git -C "$FORK_ROOT" grep -nE "$M13_IMPL_REGEX" "$ANCHOR" \
  | sed "s|^$ANCHOR:||" \
  | sed -E 's|^([^:]+):[0-9]+:class ([A-Za-z_]+) .*|\2 \1|' \
  | LC_ALL=C sort)"
n_impls="$(printf '%s\n' "$impls" | grep -c . || true)"
assert_eq "the anchor carries exactly eight ContractDBInterface implementations" \
  "$M13_EXPECTED_IMPL_COUNT" "$n_impls"
assert_eq "and they are exactly the eight the decision enumerates" \
  "$M13_EXPECTED_IMPLS" "$impls"
printf '%s\n' "$impls" | while read -r cls path; do
  [ -n "$cls" ] && note "implementation: $cls  ($path)"
done

# The two the milestone's text does not name at all, called out so a reader of this output sees
# what the enumeration added.
assert_contains "the enumeration found the fuzzer's copy, which lives outside vm2/" \
  "FuzzerContractDB barretenberg/cpp/src/barretenberg/avm_fuzzer/" "$impls"

# ---------------------------------------------------------------------------
# 2. Why each candidate is or is not fit to ship — every fact re-derived from the fork.
# ---------------------------------------------------------------------------
tester_cpp="barretenberg/cpp/src/barretenberg/vm2/testing/public_tx_simulation_tester.cpp"

# `TestContractDB::add_contracts` — an empty body. Read as the lines between its signature and the
# closing brace, so "it does nothing" is a measurement of the body and not of a comment.
add_contracts_body="$(git -C "$FORK_ROOT" show "$ANCHOR:$tester_cpp" \
  | awk '/^void TestContractDB::add_contracts/ { inbody = 1; next }
         inbody && /^\{$/ { next }
         inbody && /^\}/ { exit }
         inbody { print }' \
  | grep -vE '^\s*(//.*)?$' | wc -l)"
assert_eq "TestContractDB::add_contracts has an empty body — deliverable 2 is unimplementable against it" \
  "0" "$add_contracts_body"

debug_name_body="$(git -C "$FORK_ROOT" show "$ANCHOR:$tester_cpp" \
  | awk '/^std::optional<std::string> TestContractDB::get_debug_function_name/ { inbody = 1; next }
         inbody && /^\{$/ { next }
         inbody && /^\}/ { exit }
         inbody { print }' \
  | grep -vE '^\s*(//.*)?$' | sed -E 's/^\s+//;s/\s+$//' | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "TestContractDB::get_debug_function_name returns nullopt unconditionally — deliverable 3 too" \
  "return std::nullopt;" "$debug_name_body"

# `FuzzerContractDB` implements BOTH, which is why it had to be enumerated — and it is still not
# shippable, for a build-graph reason rather than a behavioural one.
fuzzer_cmake="$(git -C "$FORK_ROOT" show "$ANCHOR:barretenberg/cpp/src/barretenberg/avm_fuzzer/CMakeLists.txt")"
assert_contains "the fuzzer's module is gated on FUZZING_AVM" "if(FUZZING_AVM)" "$fuzzer_cmake"
# The dependency is matched on a WORD boundary: `DEPENDENCIES vm2` as a bare substring is also a
# prefix of `DEPENDENCIES vm2_sim`, which is the opposite claim, and the description says which one
# this is.
assert_eq "and declares DEPENDENCIES vm2 — the proving vm2, not vm2_sim" "1" \
  "$(printf '%s\n' "$fuzzer_cmake" | grep -cE '(^|[^[:alnum:]_])DEPENDENCIES[[:space:]]+vm2([^[:alnum:]_]|$)' || true)"

# `CdbIpcContractDB` — upstream's shippable raw one, and it cannot reach wasm.
# Both link edges are read out of the `target_link_libraries(cdb_ipc_client ...)` BLOCK rather than
# out of the whole file: `barretenberg` is also a path component of every include directory that
# file names, so a bare substring match would hold for a CMakeLists that linked nothing at all.
cdb_cmake="$(git -C "$FORK_ROOT" show "$ANCHOR:barretenberg/cpp/src/barretenberg/cdb/CMakeLists.txt")"
# An empty block makes both assertions below fail rather than pass, so it needs no third assertion
# of its own.
cdb_link_block="$(printf '%s\n' "$cdb_cmake" \
  | awk '/^target_link_libraries\(/ { inblock = 1 } inblock { print } inblock && /^\)/ { exit }')"
assert_eq "cdb_ipc_client links barretenberg" "1" \
  "$(printf '%s\n' "$cdb_link_block" | grep -cE '^[[:space:]]*barretenberg[[:space:]]*$' || true)"
assert_eq "cdb_ipc_client links ipc_runtime" "1" \
  "$(printf '%s\n' "$cdb_link_block" | grep -cE '^[[:space:]]*ipc_runtime[[:space:]]*$' || true)"
# The store it fronts is TypeScript, and that is a fact about upstream's product rather than a
# characterisation: the IPC server implements the same eight methods over `PublicContractsDB`.
cdb_server="$(git -C "$FORK_ROOT" show "$ANCHOR:yarn-project/simulator/src/public/cdb_ipc_server.ts" 2>/dev/null)"
served=0
for m in getContractInstance getContractClass getBytecodeCommitment getDebugFunctionName \
         addContracts createCheckpoint commitCheckpoint revertCheckpoint; do
  case "$cdb_server" in
    *"async $m("*|*" $m("*) served=$((served + 1)) ;;
  esac
done
assert_eq "upstream's shippable raw contract DB is the TypeScript PublicContractsDB, reached over IPC — all eight methods" \
  "8" "$served"

# `HintedRawContractDB` is raw, in-memory and already inside `avm.wasm` — the candidate that looks
# like the answer until you read what it is for. Its `add_contracts` is a documented no-op, so it
# cannot be populated by execution either; it replays a previous hint-collecting run.
raw_dbs_cpp="$(git -C "$FORK_ROOT" show \
  "$ANCHOR:barretenberg/cpp/src/barretenberg/vm2/simulation/lib/raw_data_dbs.cpp" 2>/dev/null)"
assert_contains "HintedRawContractDB::add_contracts is a declared no-op — it cannot be populated by execution" \
  'debug("add_contracts called (no-op in hinted mode)")' "$raw_dbs_cpp"
assert_contains "and its parameter is marked unused, so that is the implementation and not a stub to fill in" \
  "add_contracts([[maybe_unused]] const ContractDeploymentData&" "$raw_dbs_cpp"

# `PureContractDB` is a decorator: it HOLDS a ContractDBInterface&.
pure_hpp="$(git -C "$FORK_ROOT" show "$ANCHOR:barretenberg/cpp/src/barretenberg/vm2/simulation/standalone/concrete_dbs.hpp")"
assert_contains "PureContractDB holds a ContractDBInterface& — a decorator, not a store" \
  "ContractDBInterface& raw_contract_db;" "$pure_hpp"
# And `standalone/` had no raw store at the anchor: the only ContractDBInterface there is the
# decorator itself.
standalone_impls="$(printf '%s\n' "$impls" | grep -c 'simulation/standalone/' || true)"
assert_eq "standalone/ carried exactly one ContractDBInterface at the anchor, and it is the decorator" \
  "1" "$standalone_impls"

# ---------------------------------------------------------------------------
# 3. The decision, as it stands in the tree.
# ---------------------------------------------------------------------------
assert_file "the decision is written down" "$M13_WRITEUP"
writeup="$(cat "$M13_WRITEUP" 2>/dev/null)"
named=0
for cls in $(printf '%s\n' "$impls" | awk '{print $1}'); do
  if str_has_word "$writeup" "$cls"; then
    named=$((named + 1))
  else
    fail "CONTRACT-DB.md does not name the implementation $cls"
  fi
done
assert_eq "every implementation the enumeration found is named in the write-up" \
  "$M13_EXPECTED_IMPL_COUNT" "$named"
for phrase in "ship TestContractDB as it is" "upstream an in-memory store" "write one of our own"; do
  assert_contains "the write-up discusses the disposition: $phrase" "$phrase" "$writeup"
done
assert_contains "the write-up states which disposition was taken" "DECISION: upstream it" "$writeup"

# The overlay puts both new files beside the decorator that needs them.
patch_body="$(cat "$M13_PATCH_10")"
assert_contains "the overlay adds the store beside the decorator" \
  "vm2/simulation/standalone/memory_contract_db.hpp" "$patch_body"
assert_contains "the overlay adds the coordinator beside it" \
  "vm2/simulation/standalone/checkpoint_coordinator.hpp" "$patch_body"

# ---------------------------------------------------------------------------
# 4. Build both trees.
# ---------------------------------------------------------------------------
# NOT a command substitution: `m13_tree` exports M13_TREE, and a subshell would export it into
# itself and leave the caller with nothing — every later `git -C ""` would then run in THIS
# repository. M6 was bitten by exactly that.
m13_tree >/dev/null
m6_tree_or_die M13_TREE
tree="$M13_TREE"
note "tree: $M13_TREE"
assert_eq "the tree is the anchor plus ten patches" "10" \
  "$(git -C "$M13_TREE" rev-list --count "$M6_BASE_REV..HEAD" 2>/dev/null)"

m13_build_wasm "$tree"
assert_eq "the wasm configure succeeded" "0" "${M13_WASM_CONFIGURE_RC:-missing}"
assert_eq "the wasm build succeeded" "0" "${M13_WASM_BUILD_RC:-missing}"
wasm_log="$(m6_build_log "$tree" "$M13_WASM_BUILD")"
# ' error: ' with the leading space cannot match `fatal error:`; `-Wfatal-errors` means a failing
# build emits exactly one `fatal error:` line and zero plain ones, so counting the wrong needle
# reports zero errors for a build that failed.
assert_eq "the wasm build emitted no diagnostics of either spelling" "0" \
  "$(printf '%s\n' "$wasm_log" | grep -cE '(^|[^a-z])(fatal )?error: ' || true)"

m13_build_native "$tree"
assert_eq "the native configure succeeded" "0" "${M13_NATIVE_CONFIGURE_RC:-missing}"
assert_eq "the native build succeeded" "0" "${M13_NATIVE_BUILD_RC:-missing}"
native_log="$(m6_build_log "$tree" "$M13_NATIVE_BUILD")"
assert_eq "the native build emitted no diagnostics of either spelling" "0" \
  "$(printf '%s\n' "$native_log" | grep -cE '(^|[^a-z])(fatal )?error: ' || true)"

m8_require_artifacts "$(m13_wasm_bin avm.wasm)" "$(m13_wasm_bin avm.wasm.gz)" \
  "$(m13_wasm_bin vm2_sim_tests)" "$(m13_native_bin avm_differential)" "$(m13_native_bin vm2_sim_tests)"

# The reactor no longer links vm2/testing/ — read off the build's own compile database rather than
# off the CMake source, because what matters is what was compiled INTO the target.
reactor_tus="$(python3 - "$M13_TREE/barretenberg/cpp/$M13_WASM_BUILD/compile_commands.json" <<'PY'
import json, sys
# Object files only. CMake's precompiled-header stub (`cmake_pch.hxx.cxx` -> `.pch`) is compiled
# into the same target directory and is not a translation unit of the program; counting it made
# this assertion read 2 for a module built from one source.
db = json.load(open(sys.argv[1]))
tus = sorted({e["file"] for e in db
              if "avm-reactor-debug.wasm.dir" in e.get("output", "")
              and e.get("output", "").endswith((".o", ".obj"))})
print("\n".join(tus))
PY
)"
assert_eq "the reactor is ONE translation unit — vm2/testing/ has left its link closure" "1" \
  "$(printf '%s\n' "$reactor_tus" | grep -c . || true)"
assert_contains "and that translation unit is the reactor itself" "reactor/avm_reactor.cpp" "$reactor_tus"
assert_eq "no vm2/testing/ translation unit is compiled into the reactor" "0" \
  "$(printf '%s\n' "$reactor_tus" | grep -c '/vm2/testing/' || true)"

# ---------------------------------------------------------------------------
# 5. The consequences of the decision, measured.
# ---------------------------------------------------------------------------
exports="$(m12_wasm_module_exports "$(m13_wasm_bin avm.wasm)")"
imports="$(m12_wasm_module_imports "$(m13_wasm_bin avm.wasm)")"
assert_eq "the reactor exports forty-nine names" "$M13_EXPECTED_EXPORT_COUNT" \
  "$(printf '%s\n' "$exports" | grep -c . || true)"
missing_new=0
for sym in $M13_NEW_EXPORTS; do
  if str_has_line "$exports" "$sym"; then :; else
    fail "the reactor does not export $sym"
    missing_new=$((missing_new + 1))
  fi
done
assert_eq "all ten of M13's exports are present, by name" "0" "$missing_new"
# M12's thirty-nine are all still there: this is additive, and "additive" is an identity rather than
# a count.
dropped=0
for sym in $M12_EXPECTED_EXPORTS; do
  str_has_line "$exports" "$sym" || { fail "M12's export $sym is gone"; dropped=$((dropped + 1)); }
done
assert_eq "every one of M12's thirty-nine exports survives" "0" "$dropped"

# THE IMPORT SURFACE IS UNCHANGED. This is the claim that matters: a bigger contract DB must not
# have cost the artefact one new host import. By name, not by count.
assert_eq "the import surface is still twelve" "$M13_EXPECTED_IMPORT_COUNT" \
  "$(printf '%s\n' "$imports" | grep -c . || true)"
assert_eq "and it is the same twelve, name for name" \
  "$(printf '%s\n%s\n' "$M12_EXPECTED_NON_WASI_IMPORT" "$M12_EXPECTED_WASI_IMPORTS" | LC_ALL=C sort)" \
  "$imports"

raw_size="$(stat -c %s "$(m13_wasm_bin avm.wasm)" 2>/dev/null)"
gz_size="$(stat -c %s "$(m13_wasm_bin avm.wasm.gz)" 2>/dev/null)"
note "avm.wasm: $raw_size raw, $gz_size gzipped (M12's tree: $M13_M12_MEASURED_RAW / $M13_M12_MEASURED_GZ)"
if [ -n "$raw_size" ] && [ "$raw_size" -le "$M13_SIZE_BUDGET_RAW" ]; then
  pass "the reactor is within the raw budget  [$raw_size <= $M13_SIZE_BUDGET_RAW]"
else
  fail "the reactor is over the raw budget  [$raw_size > $M13_SIZE_BUDGET_RAW]"
fi
if [ -n "$gz_size" ] && [ "$gz_size" -le "$M13_SIZE_BUDGET_GZ" ]; then
  pass "the reactor is within the gzipped budget  [$gz_size <= $M13_SIZE_BUDGET_GZ]"
else
  fail "the reactor is over the gzipped budget  [$gz_size > $M13_SIZE_BUDGET_GZ]"
fi
# The delta is REPORTED and required to be the sign the write-up states. It is not asserted as a
# number: -Oz output moves with a toolchain bump and pinning it would fail a correct build.
delta=$((raw_size - M13_M12_MEASURED_RAW))
note "raw delta against M12's artefact: $delta bytes"
if [ "$delta" -gt 0 ]; then
  pass "the artefact grew, which is what the write-up says: the store, the coordinator and ten exports cost more than vm2/testing/ saved"
else
  fail "the artefact did not grow — the write-up's account of the size is wrong and must be corrected rather than the check loosened"
fi
# Digit-grouping commas are stripped before the search, so the write-up can read as prose while
# still being held to the exact byte counts this run measured.
writeup_digits="$(printf '%s' "$writeup" | tr -d ,)"
assert_contains "the write-up reports the measured raw size" "$raw_size" "$writeup_digits"
assert_contains "the write-up reports the measured gzipped size" "$gz_size" "$writeup_digits"

# ---------------------------------------------------------------------------
# 6. Native neutrality: upstream's own suite, with and without the overlay's tests.
#
# The totals are compared to EACH OTHER rather than to a number written here, so no magic constant
# can go stale: the binary is listed twice, once whole and once with the two new suites filtered
# out, and the difference must be exactly the twelve tests the overlay adds.
# ---------------------------------------------------------------------------
# Run inside the fork's dev shell, as M7's runners do: the binary links what the shell provides and
# a check that only works on a host where those happen to be present is a check that will fail on a
# CI runner for a reason that says nothing about the tests.
native_tests="$(m13_native_bin vm2_sim_tests)"
gtest_list() { # [extra args...]
  m6_in_devshell 'bin="$1"; shift; "$bin" --gtest_list_tests "$@" 2>/dev/null' "$native_tests" "$@"
}
all_list="$(gtest_list | grep -cE '^  [A-Za-z]' || true)"
without_list="$(gtest_list --gtest_filter='-MemoryContractDBTest.*:CheckpointCoordinatorTest.*' \
  | grep -cE '^  [A-Za-z]' || true)"
note "vm2_sim_tests: $all_list tests, $without_list without the overlay's"
assert_ge "the binary carries a meaningful number of upstream tests" "300" "$without_list"
assert_eq "the overlay adds exactly twelve tests to upstream's own binary" \
  "$M13_UNIT_TEST_COUNT" "$((all_list - without_list))"
missing_unit=0
listed="$(gtest_list | awk '/^[A-Za-z].*\.$/ { suite = $1; next } /^  [A-Za-z]/ { print suite $1 }')"
for tn in $M13_UNIT_TESTS; do
  str_has_line "$listed" "$tn" || { fail "the overlay's test $tn is not in the binary"; missing_unit=$((missing_unit + 1)); }
done
assert_eq "all twelve of the overlay's tests are present, by name" "0" "$missing_unit"

m6_in_devshell 'bin="$1"; err="$2"; "$bin" 2>"$err"' \
  "$native_tests" "$M13_WORK/vm2_sim_tests.native.err" >"$M13_WORK/vm2_sim_tests.native.out"
native_rc=$?
assert_eq "upstream's own vm2_sim_tests passes natively with the overlay applied" "0" "$native_rc"
passed_line="$(grep -E '^\[  PASSED  \] [0-9]+ tests?\.' "$M13_WORK/vm2_sim_tests.native.out" | tail -1)"
failed_line="$(grep -cE '^\[  FAILED  \]' "$M13_WORK/vm2_sim_tests.native.out" || true)"
assert_eq "and reports no failures" "0" "$failed_line"
assert_eq "the number that passed is the number the binary carries" \
  "$all_list" "$(printf '%s' "$passed_line" | sed -E 's/.*\] ([0-9]+) tests?\..*/\1/')"

# ---------------------------------------------------------------------------
# 7. The inputs, produced once here and read by every other M13 check.
# ---------------------------------------------------------------------------
names_file="$M13_WORK/debug-names.txt"
python3 - "$REPO_ROOT/fixtures/contracts/artifacts.json" >"$names_file" <<'PY'
import json, sys
# The names come from the SIX compiled Noir artifacts the M2 corpus names, derived by rule rather
# than typed: the alphabetically first called public function of each, plus Token's second, which
# makes seven — one per corpus program. `fixtures/contracts/artifacts.json` is itself generated by
# `diffsim/check_contract_artifacts.mjs` from the artifacts, so nothing here is hand-written.
d = json.load(open(sys.argv[1]))["artifacts"]
order = ["Token", "AMM", "AvmTest", "AvmGadgetsTest", "StorageProofTest", "PublicFnsWithEmitRepro"]
names = ["%s::%s" % (a, sorted(d[a]["calledPublicFunctions"])[0]) for a in order]
names.append("Token::%s" % sorted(d["Token"]["calledPublicFunctions"])[1])
print("\n".join(names))
PY
assert_eq "seven debug function names were derived from the contract artifacts" "7" \
  "$(grep -c . "$names_file" || true)"

m6_in_devshell '
  bin="$1"; names="$2"; out="$3"; err="$4"
  "$bin" contractdbinputs "$names" >"$out" 2>"$err"
' "$(m13_native_bin avm_differential)" "$names_file" "$(m13_inputs)" "$M13_WORK/contractdb-inputs.err" >/dev/null
inputs_rc=$?
assert_eq "the driver produced the contract DB inputs" "0" "$inputs_rc"
assert_file "the inputs file exists" "$(m13_inputs)"
m13_assert_field "the inputs declare seven programs" "$(m13_inputs)" "contractDbInputs.programs.count" "7"
m13_assert_field "the inputs ran to completion" "$(m13_inputs)" "contractDbInputs.done" "1"
assert_eq "the names in the inputs came from the artifacts file, not from the driver's fallback" \
  "$names_file" "$(m13_field "$(m13_inputs)" "contractDbInputs.debugNames.source")"

cat >"$M13_WORK/measured.env" <<EOF
M13_TREE='$M13_TREE'
M13_MEASURED_RAW_SIZE='$raw_size'
M13_MEASURED_GZ_SIZE='$gz_size'
M13_MEASURED_EXPORTS='$(printf '%s\n' "$exports" | grep -c . || true)'
M13_MEASURED_NATIVE_TESTS='$all_list'
M13_NAMES_FILE='$names_file'
EOF
assert_file "the measurement record was written" "$M13_WORK/measured.env"

finish
