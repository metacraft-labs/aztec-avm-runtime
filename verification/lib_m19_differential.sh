#!/usr/bin/env bash
# lib_m19_differential.sh — shared machinery for the M19 checks.
#
# Not to be executed directly: sourced after lib.sh by verification/*.sh.
#
# M19 compares three AVM implementations on one transaction, so its checks need three things
# present before they can assert anything: a built `avm.wasm`, diffsim's installed `@aztec/*`
# packages (which carry the NAPI oracle), and the measured fixtures. All three are PRECONDITIONS
# that die with the command that fixes them. None of them is a skip.
#
# WHY THE PRECONDITIONS ARE SPELLED OUT AT THIS LENGTH. Four checks in this campaign once passed
# against an empty build directory, because every predicate returned 0 over a missing path. The
# three-way arm has the same shape of hazard in a worse form: with the module absent, the suite is
# a two-way differential wearing a three-way name, and it would be GREEN.

M19_WORK="${M19_WORK:-$HOME/.cache/aztec-m19-differential}"
export M19_WORK

DIFFSIM_DIR="$REPO_ROOT/diffsim"
M19_SUITE="src/differential"
M19_COUNTS="$REPO_ROOT/fixtures/three-way-arm-counts.json"
M19_LEDGER="$REPO_ROOT/fixtures/differential-wasm-divergences.json"
M19_ARM_COUNTS="$REPO_ROOT/fixtures/differential-arm-counts.json"
export DIFFSIM_DIR M19_SUITE M19_COUNTS M19_LEDGER M19_ARM_COUNTS

# The exports the arm calls. Named individually so a module missing one is reported as THAT rather
# than as a comparison failure fifty lines later.
M19_REQUIRED_EXPORTS='avm_simulate avm_contract_db_create avm_contract_db_register_class
avm_contract_db_register_instance avm_contract_db_create_checkpoint avm_contract_db_commit_checkpoint
avm_contract_db_revert_checkpoint avm_merkle_db_create avm_merkle_db_get_tree_roots
avm_merkle_db_insert_indexed_leaves_nullifier_tree avm_merkle_db_insert_indexed_leaves_public_data_tree
avm_merkle_db_append_leaves avm_merkle_db_create_checkpoint avm_merkle_db_commit_checkpoint
avm_merkle_db_revert_checkpoint'
export M19_REQUIRED_EXPORTS

# Find a built `avm.wasm`.
#
# In preference order: an explicit AVM_WASM_PATH, this milestone's own work directory, then the
# build trees M12/M17/M18 leave behind. Reusing a sibling milestone's build output is deliberate —
# the module takes tens of minutes to build and nothing here modifies it — but it is NOT trusted
# blind: `m19_require_module` asserts the exports the arm calls and prints the module's sha256, so
# a stale or wrong module is a named failure rather than a mysterious one.
m19_find_module() {
  local candidate
  if [ -n "${AVM_WASM_PATH:-}" ]; then
    printf '%s\n' "$AVM_WASM_PATH"
    return 0
  fi
  for candidate in \
    "$M19_WORK/avm.wasm" \
    "$HOME/.cache/aztec-m18-orchestration/m12/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "$HOME/.cache/aztec-m17-node-host/m12/barretenberg/cpp/build-wasm-avm/bin/avm.wasm" \
    "$HOME/.cache/aztec-m12-reactor/m12/barretenberg/cpp/build-wasm-avm/bin/avm.wasm"
  do
    [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

m19_require_module() {
  AVM_WASM_PATH="$(m19_find_module)" || die "no built avm.wasm was found.
             The three-way arm cannot run without the module, and a run without it would be a
             two-way differential under a three-way name.
             Remedy: just avm-wasm-build, then set AVM_WASM_PATH to
             barretenberg/cpp/build-wasm-avm/bin/avm.wasm"
  export AVM_WASM_PATH
  [ -s "$AVM_WASM_PATH" ] || die "the module at $AVM_WASM_PATH is empty"
  M19_MODULE_SHA="$(sha256sum "$AVM_WASM_PATH" | cut -d' ' -f1)"
  export M19_MODULE_SHA
}

# Every export name the module declares, one per line. Read from the binary with node's own
# WebAssembly.Module.exports so nothing here has to parse wasm.
m19_module_exports() {
  node -e '
const { readFileSync } = require("fs");
const m = new WebAssembly.Module(readFileSync(process.argv[1]));
for (const e of WebAssembly.Module.exports(m)) console.log(e.name);
' "$AVM_WASM_PATH"
}

m19_require_packages() {
  [ -d "$DIFFSIM_DIR/node_modules/@aztec/native" ] \
    || die "diffsim's @aztec/* packages are not installed, so the NAPI oracle cannot run and the
             comparison would have nothing to compare against.
             Remedy: cd $DIFFSIM_DIR && npm ci"
  [ -f "$M19_COUNTS" ] || die "the measured counts are missing: $M19_COUNTS
             Remedy: AVM_WASM_PATH=… tools/measure_three_way.py"
  [ -f "$M19_LEDGER" ] || die "the divergence ledger is missing: $M19_LEDGER
             Remedy: AVM_WASM_PATH=… tools/measure_three_way.py"
}

# Run the three-way arm. `$1` is a log file; any further arguments are `NAME=VALUE` environment
# entries (the fault injections). Returns jest's exit status.
m19_run_arm() { # <logfile> [ENV=VALUE...]
  local log="$1"; shift
  ( cd "$DIFFSIM_DIR" \
    && env NODE_NO_WARNINGS=1 RUN_THREE_WAY=1 AVM_WASM_PATH="$AVM_WASM_PATH" "$@" \
       node --experimental-vm-modules ./node_modules/.bin/jest "$M19_SUITE" ) >"$log" 2>&1
}

# jest's own summary line, parsed once. `Tests:  17 passed, 17 total`.
m19_tests_passed() { # <logfile>
  grep -oE '^Tests:.*' "$1" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | head -1
}
m19_tests_failed() { # <logfile>
  grep -oE '^Tests:.*' "$1" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' | head -1
}
m19_tests_total() { # <logfile>
  grep -oE '^Tests:.*' "$1" | grep -oE '[0-9]+ total' | grep -oE '[0-9]+' | head -1
}

m19_json() { # <file> <python-expression over `d`>
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))' "$1" "$2"
}
