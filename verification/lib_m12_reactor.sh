#!/usr/bin/env bash
# Shared machinery for the M12 checks — the standalone `avm.wasm` reactor and its host ABI.
#
# WHAT M12 MEASURES, AND WHAT IT DOES NOT.
#
# ONE worktree of the fork at 233d8e0993 carrying NINE patches: the four of the AVM_WASM series
# that M6 established, the prepared per-instruction observation hook, M7's `AVM_SIM_TESTS` overlay,
# M8's `AVM_DIFFERENTIAL` overlay, M9's step/timing modes, and M12's own `AVM_REACTOR` overlay. Two
# build directories inside it:
#
#   build-wasm-avm     `wasm-avm` preset, -DAVM_REACTOR=ON -DAVM_DIFFERENTIAL=ON
#                      -> bin/avm.wasm            the shipped reactor, stripped
#                      -> bin/avm.wasm.gz         gzip -9 -n of it, produced by the build
#                      -> bin/avm-reactor-debug.wasm     the linker's output, unstripped
#                      -> bin/avm-unpruned.wasm[.gz]     CONTROL 1: same objects, linked with
#                                                        --export-dynamic. It isolates the EXPORT
#                                                        LIST, not the collector — see below
#                      -> bin/avm-nogc.wasm[.gz]         CONTROL 2: same objects, same explicit
#                                                        export list, -Wl,--no-gc-sections. This is
#                                                        the one that isolates --gc-sections
#                      -> bin/barretenberg.wasm.gz       the proving stack, from the SAME tree and
#                                                        the SAME toolchain, as the size comparison
#                      -> bin/avm_msgpack_coverage       the schema enumeration, for wasm32
#                      -> bin/avm_differential           the driver, for its `reactorinputs` mode
#   build-native-avm   `default` preset, the same two options
#                      -> bin/avm_differential           the transcript this milestone compares to
#                      -> bin/avm_msgpack_coverage       the same enumeration, for x86-64
#
# COVERAGE, so that no number from here can be quoted as another milestone's. The transcript half
# is the SAME SEVEN hand-assembled corpus programs M8 compares, driven this time THROUGH the
# reactor's msgpack ABI from JavaScript instead of from C++ inside the same process. That is an
# integration check across a boundary, not a breadth claim: breadth is M7's 391 upstream tests,
# semantics is M19's 77-comparison oracle, and the per-record step agreement is M9's 39,086.
#
# Nothing here has a skip path. A tree that cannot be prepared, a build that fails, a runtime that
# is missing or a transcript with no lines in it is `die` or a failed assertion, never a printed
# SKIP.
#
# It reuses M9's machinery, which reuses M8's, M7's and M6's, rather than re-implementing any of
# them: M9_WORK is pointed at $M12_WORK before lib_m9_observer.sh is sourced, and that file does
# the same for M8_WORK, M7_WORK and M6_WORK, so every tree, configure, build and compile-database
# reader operates inside M12's own directory and cannot touch another milestone's evidence.
#
# Not to be executed directly: sourced by verification/verify_*.sh and test_*.sh, AFTER lib.sh.

# MEASURED, and the measurement's own caveat stated with it. From an empty $M12_WORK on 32 cores,
# TWICE: 7 min 50 s and 7 min 46 s, 1.2 GB — 531 MB in build-wasm-avm, 166 MB in build-native-avm,
# 90 MB in the reactor-off configure. Both runs had a WARM ccache holding these objects, so that is
# a warm-ccache figure and not a from-nothing one; the first build of barretenberg's proving stack
# for wasm in this campaign took about nine minutes on its own. The 8 GB floor below is a
# precondition rather than a prediction. /tmp is usually a tmpfs and is the wrong place: set
# M12_WORK.
M12_WORK="${M12_WORK:-$HOME/.cache/aztec-m12-reactor}"
M9_WORK="$M12_WORK"
export M12_WORK M9_WORK

# shellcheck source=lib_m9_observer.sh
. "$VERIFY_DIR/lib_m9_observer.sh"

# M12's own overlay: the ninth patch. Ours, a downstream target, never filed upstream.
M12_PATCH_9="$REPO_ROOT/verification/m12/0001-test-vm2-AVM_REACTOR-a-standalone-avm.wasm-reactor-a.patch"

M12_TREE_NAME=m12
M12_WASM_BUILD=build-wasm-avm
M12_NATIVE_BUILD=build-native-avm

# The write-up whose numbers the checks re-derive rather than trust.
M12_WRITEUP="$REPO_ROOT/REACTOR-ABI.md"

M12_HOST="$VERIFY_DIR/wasm_host/avm_reactor_host.mjs"

# ---------------------------------------------------------------------------
# The module's surface, as IDENTITIES. A name appearing is as much a finding as one disappearing.
# ---------------------------------------------------------------------------

# The eleven WASI functions, sorted. THE DELIVERABLE'S LIST IS RIGHT FOR THIS ARTEFACT and was
# re-measured rather than inherited: `avm.wasm` imports exactly these and nothing else. M7's
# "18 functions plus one memory" is a DIFFERENT artefact — `vm2_sim_tests`, a WASI *command* with
# gtest's own `main`, argv handling, file output and an exit path, which pulls more of wasi-libc
# than a reactor with no `main` needs.
M12_EXPECTED_WASI_IMPORTS="wasi_snapshot_preview1.clock_time_get
wasi_snapshot_preview1.environ_get
wasi_snapshot_preview1.environ_sizes_get
wasi_snapshot_preview1.fd_close
wasi_snapshot_preview1.fd_fdstat_get
wasi_snapshot_preview1.fd_prestat_dir_name
wasi_snapshot_preview1.fd_prestat_get
wasi_snapshot_preview1.fd_read
wasi_snapshot_preview1.fd_seek
wasi_snapshot_preview1.fd_write
wasi_snapshot_preview1.proc_exit"

# The twelfth import, which the deliverable did not mention and which is the only non-WASI one.
# It exists because `src/CMakeLists.txt` links every wasm artefact with `-Wl,--import-memory`.
M12_EXPECTED_NON_WASI_IMPORT="env.memory"

# The eight ContractDBInterface methods, named for the interface exactly.
M12_CONTRACT_DB_METHODS="avm_contract_db_add_contracts
avm_contract_db_commit_checkpoint
avm_contract_db_create_checkpoint
avm_contract_db_get_bytecode_commitment
avm_contract_db_get_contract_class
avm_contract_db_get_contract_instance
avm_contract_db_get_debug_function_name
avm_contract_db_revert_checkpoint"

# The fourteen LowLevelMerkleDBInterface methods.
M12_MERKLE_DB_METHODS="avm_merkle_db_append_leaves
avm_merkle_db_commit_checkpoint
avm_merkle_db_create_checkpoint
avm_merkle_db_get_checkpoint_id
avm_merkle_db_get_leaf_preimage_nullifier_tree
avm_merkle_db_get_leaf_preimage_public_data_tree
avm_merkle_db_get_leaf_value
avm_merkle_db_get_low_indexed_leaf
avm_merkle_db_get_sibling_path
avm_merkle_db_get_tree_roots
avm_merkle_db_insert_indexed_leaves_nullifier_tree
avm_merkle_db_insert_indexed_leaves_public_data_tree
avm_merkle_db_pad_tree
avm_merkle_db_revert_checkpoint"

# HighLevelMerkleDBInterface's methods. NOT exposed, and asserted absent BY NAME rather than by a
# count: it is internal to vm2 and `simulate_fast_internal` satisfies it itself with `PureMerkleDB`.
# A check that only counted exports would go green for a build that exposed it.
#
# FIFTEEN of its nineteen. The four omitted are `create_checkpoint`, `commit_checkpoint`,
# `revert_checkpoint` and `get_checkpoint_id`, which BOTH interfaces declare and which are exported
# for the low-level one; listing those as forbidden would make the check contradict itself.
M12_HIGH_LEVEL_METHODS="get_tree_state
storage_read
storage_write
was_storage_written
nullifier_exists
siloed_nullifier_exists
nullifier_write
siloed_nullifier_write
note_hash_exists
note_hash_write
siloed_note_hash_write
unique_note_hash_write
l1_to_l2_msg_exists
pad_trees
as_unconstrained"

# The complete export list, sorted: the two toolchain exports plus the thirty-seven this module
# names in its own link line.
M12_EXPECTED_EXPORTS="_initialize
avm_abi_version
avm_alloc
avm_contract_db_add_contracts
avm_contract_db_commit_checkpoint
avm_contract_db_create
avm_contract_db_create_checkpoint
avm_contract_db_destroy
avm_contract_db_get_bytecode_commitment
avm_contract_db_get_contract_class
avm_contract_db_get_contract_instance
avm_contract_db_get_debug_function_name
avm_contract_db_register_class
avm_contract_db_register_instance
avm_contract_db_revert_checkpoint
avm_free
avm_merkle_db_append_leaves
avm_merkle_db_commit_checkpoint
avm_merkle_db_create
avm_merkle_db_create_checkpoint
avm_merkle_db_destroy
avm_merkle_db_get_checkpoint_id
avm_merkle_db_get_leaf_preimage_nullifier_tree
avm_merkle_db_get_leaf_preimage_public_data_tree
avm_merkle_db_get_leaf_value
avm_merkle_db_get_low_indexed_leaf
avm_merkle_db_get_sibling_path
avm_merkle_db_get_tree_roots
avm_merkle_db_insert_indexed_leaves_nullifier_tree
avm_merkle_db_insert_indexed_leaves_public_data_tree
avm_merkle_db_pad_tree
avm_merkle_db_revert_checkpoint
avm_result_len
avm_result_ptr
avm_simulate
avm_simulate_with_hinted_dbs
avm_steps_batch
avm_steps_count
memory"

M12_EXPECTED_EXPORT_COUNT=39
M12_EXPECTED_IMPORT_COUNT=12
M12_EXPECTED_WASI_IMPORT_COUNT=11

# ---------------------------------------------------------------------------
# The size budget.
#
# MEASURED: 1,565,773 bytes raw and 350,104 gzipped, stripped, with the observation hook compiled
# in. The milestone's stated 1,259,737 / 272,661 predates the hook AND this artefact's msgpack ABI
# and resident-DB surface, so the budget is re-derived here rather than inherited.
#
# The budget is deliberately NOT the measurement — a budget equal to the measurement fails on any
# change at all and therefore gets raised rather than read — and it is deliberately not a round
# number pulled out of the air either. It is chosen so that THE UNPRUNED CONTROL FAILS IT: the same
# objects linked with `--export-dynamic` and without `--gc-sections` are 1,917,464 / 418,853, above
# both budgets. A budget that the control passes would be a budget that does not notice the link
# options going away.
M12_SIZE_BUDGET_RAW="${M12_SIZE_BUDGET_RAW:-1800000}"
M12_SIZE_BUDGET_GZ="${M12_SIZE_BUDGET_GZ:-400000}"

# The measurements themselves, recorded so a drift toward the budget is visible before it is a
# failure. Not asserted as identities: -Oz output moves with a toolchain bump and pinning it would
# make this check fail on a correct build.
M12_MEASURED_RAW=1565773
M12_MEASURED_GZ=350104
M12_MEASURED_UNPRUNED_RAW=1917464
M12_MEASURED_UNPRUNED_GZ=418853
# CONTROL 2 — the collector genuinely off. Measured on this host.
M12_MEASURED_NOGC_RAW=2716029
M12_MEASURED_NOGC_GZ=617489
M12_MEASURED_NOGC_WASI_IMPORTS=45

# The proving stack, for the size comparison. It is recorded with a TOLERANCE and never asserted as
# an identity or required to appear verbatim in the write-up, because it is NOT REPRODUCIBLE:
# measured, two builds of the same tree with the same toolchain in two different work directories
# produce a `barretenberg.wasm` of the same size (18,017,075) that differs in 64 bytes, which gzip
# turns into 4,046,715 against 4,046,721. `avm.wasm` itself IS byte-identical across those two
# builds, so this is a property of the comparison artefact and not of the module under test — but a
# check that pinned the figure failed on a correct build, which is exactly what the drift bounds
# above exist to avoid.
M12_MEASURED_BARRETENBERG_GZ=4046715
M12_BARRETENBERG_GZ_TOLERANCE_PCT=1

# The step corpus for the batching measurement. `burn` runs out of gas after M9's measured 38,903
# instructions; the identity is M9's and is quoted from there rather than re-derived here.
M12_STEP_PROGRAM=burn
M12_STEP_COUNT=38903
M12_STEP_BATCH="${M12_STEP_BATCH:-4096}"

# The seven corpus programs, in the order the driver emits them.
M12_PROGRAMS="add revert loop sha256 poseidon2 storage burn"
M12_EXPECTED_PROGRAMS=7

# The msgpack enumeration, as an identity.
M12_EXPECTED_MSGPACK_CHECKS=42
M12_EXPECTED_MSGPACK_OURS=1
M12_OUR_ONLY_TYPE=AvmReactorError

export M12_PATCH_9 M12_TREE_NAME M12_WASM_BUILD M12_NATIVE_BUILD M12_HOST

# ---------------------------------------------------------------------------
# m12_tree -> the prepared worktree, or die.
#
# 233d8e0993 + the four series patches + the observer patch + M7's, M8's, M9's and M12's overlays,
# in that order, by `git am` with no -3: each must apply to what precedes it exactly.
# ---------------------------------------------------------------------------
m12_tree() {
  m9_require_patches
  [ -f "$M12_PATCH_9" ] || die "M12's overlay patch is missing: $M12_PATCH_9"
  M12_TREE=$(m6_prepare_tree "$M12_TREE_NAME" \
    "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4" \
    "$M9_OBSERVER_PATCH" "$M7_PATCH_5" "$M8_PATCH_6" "$M9_PATCH_7" "$M12_PATCH_9")
  # A command substitution swallows `die`, so the tree can come back empty and every later
  # `git -C ""` would run in the CALLER's repository. M6 was bitten by exactly this.
  m6_tree_or_die M12_TREE
  export M12_TREE
  printf '%s\n' "$M12_TREE"
}

# ---------------------------------------------------------------------------
# Builds. Configure and build return non-zero if EITHER step failed, and callers assert the two
# statuses SEPARATELY: a stale artefact from a previous run will happily produce a plausible
# transcript over a build that did not happen (M2's defect, M3's lesson).
# ---------------------------------------------------------------------------
m12_build_wasm() { # <tree> [extra targets...]
  local tree="$1"; shift
  # AVM_SIM_TESTS=ON as well, because this milestone re-measures M7's import surface BESIDE its own:
  # `vm2_sim_tests` is the WASI *command* whose 18-plus-a-memory the deliverable's "eleven" was
  # confused with, and comparing the two from one tree is what settles it.
  m6_configure "$tree" wasm-avm "$M12_WASM_BUILD" -DAVM_DIFFERENTIAL=ON -DAVM_REACTOR=ON -DAVM_SIM_TESTS=ON
  M12_WASM_CONFIGURE_RC=$?
  [ "$M12_WASM_CONFIGURE_RC" -eq 0 ] || return "$M12_WASM_CONFIGURE_RC"
  m6_build "$tree" "$M12_WASM_BUILD" avm.wasm.gz avm-unpruned.wasm.gz avm-nogc.wasm.gz avm_msgpack_coverage avm_differential vm2_sim_tests "$@"
  M12_WASM_BUILD_RC=$?
  return "$M12_WASM_BUILD_RC"
}

# The same wasm preset with AVM_REACTOR left at its default. The additive check: with the option
# off, the build declares no reactor target at all.
m12_configure_reactor_off() { # <tree>
  m6_configure "$1" wasm-avm build-wasm-reactoroff -DAVM_DIFFERENTIAL=ON
  return $?
}

m12_build_native() { # <tree>
  local tree="$1"
  # FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER for the reason M7 recorded and M8 and M9 repeat:
  # cmake/gtest.cmake declares GTest with FIND_PACKAGE_ARGS, so a native configure otherwise
  # prefers whatever find_package(GTest) turns up.
  m6_native_configure "$tree" "$M12_NATIVE_BUILD" -DAVM_DIFFERENTIAL=ON -DAVM_REACTOR=ON \
    -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER
  M12_NATIVE_CONFIGURE_RC=$?
  [ "$M12_NATIVE_CONFIGURE_RC" -eq 0 ] || return "$M12_NATIVE_CONFIGURE_RC"
  m6_build "$tree" "$M12_NATIVE_BUILD" avm_differential avm_msgpack_coverage
  M12_NATIVE_BUILD_RC=$?
  return "$M12_NATIVE_BUILD_RC"
}

m12_wasm_bin()   { printf '%s\n' "$M12_TREE/barretenberg/cpp/$M12_WASM_BUILD/bin/$1"; }
m12_native_bin() { printf '%s\n' "$M12_TREE/barretenberg/cpp/$M12_NATIVE_BUILD/bin/$1"; }

# The transcripts and blobs. Written by verify_avm_wasm_import_surface (the check that BUILDS) and
# read by everything else, so no two checks can disagree about what was measured.
m12_reactor_inputs()    { printf '%s\n' "$M12_WORK/reactor-inputs.txt"; }
m12_native_transcript() { printf '%s\n' "$M12_WORK/native.transcript"; }
m12_reactor_transcript(){ printf '%s\n' "$M12_WORK/reactor.transcript"; }
m12_reactor_hinted()    { printf '%s\n' "$M12_WORK/reactor.hinted"; }
m12_reactor_iface()     { printf '%s\n' "$M12_WORK/reactor.iface"; }
m12_native_coverage()   { printf '%s\n' "$M12_WORK/native.coverage"; }
m12_wasm_coverage()     { printf '%s\n' "$M12_WORK/wasm.coverage"; }
m12_native_steps()      { printf '%s\n' "$M12_WORK/native.steps"; }

# ---------------------------------------------------------------------------
# m12_run_reactor <mode> <output> <stderr> [args...]
#
# Drives `avm.wasm` from node through the host in wasm_host/. stdout and stderr are kept APART,
# for M8's reason and M9's: `common/log.cpp` sets `bb_log_level = VERBOSE` unconditionally under
# `__wasm__`, so the AVM narrates its own progress on fd 2 and a merged stream would make every
# comparison a comparison of log levels.
# ---------------------------------------------------------------------------
m12_run_reactor() {
  local mode="$1" out="$2" err="$3"; shift 3
  local wasm; wasm="$(m12_wasm_bin avm.wasm)"
  [ -f "$wasm" ] || die "no reactor module at $wasm — nothing to run"
  [ -f "$(m12_reactor_inputs)" ] || die "no reactor inputs at $(m12_reactor_inputs)"
  m6_in_devshell '
    host="$1"; wasm="$2"; inputs="$3"; mode="$4"; t="$5"; err="$6"; shift 6
    timeout --foreground --preserve-status -s KILL "$t" node "$host" "$wasm" "$inputs" "$mode" "$@" 2>"$err"
  ' "$M12_HOST" "$wasm" "$(m12_reactor_inputs)" "$mode" "$M7_RUN_TIMEOUT" "$err" "$@" >"$out"
}

# m12_wasm_module_imports <module.wasm> -> "<module>.<name>" per line, sorted.
# m12_wasm_module_exports <module.wasm> -> export names, sorted.
#
# Read through V8's own module reflection rather than by parsing the binary, because what matters
# is what an engine sees when it links the module.
m12_wasm_module_imports() {
  [ -f "$1" ] || die "no wasm module at $1 — its import surface cannot be read"
  m6_in_devshell '
    node -e "
      const fs=require(\"fs\");
      const m=new WebAssembly.Module(fs.readFileSync(process.argv[1]));
      for (const i of WebAssembly.Module.imports(m)) console.log(i.module+\".\"+i.name);
    " "$1"' "$1" 2>/dev/null | LC_ALL=C sort
}

m12_wasm_module_exports() {
  [ -f "$1" ] || die "no wasm module at $1 — its export surface cannot be read"
  m6_in_devshell '
    node -e "
      const fs=require(\"fs\");
      const m=new WebAssembly.Module(fs.readFileSync(process.argv[1]));
      for (const e of WebAssembly.Module.exports(m)) console.log(e.name);
    " "$1"' "$1" 2>/dev/null | LC_ALL=C sort
}

# m12_field <file> <key> -> the value of a `<key> <value>` line, or the empty string.
m12_field() {
  [ -f "$1" ] || die "m12_field: no such file: $1"
  awk -v k="$2" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' "$1"
}

# m12_compare_keyed <expected-file> <actual-file> <prefix> -> mismatching keys, one per line
#
# Every `<prefix>*` key the ACTUAL file carries must be present in the expected file with the same
# value. Keys the expected file has and the actual does not are not a mismatch: the driver's
# transcript carries lines the reactor's ABI has no counterpart for (`.beforeDeploy`,
# `.afterDeploy`, `.afterSimulate` are the tester's own DB, not the simulation's result), and those
# are enumerated in the write-up rather than silently dropped by a wildcard here.
m12_compare_keyed() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
def load(p):
    d = {}
    for line in open(p, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line:
            continue
        k, _, v = line.partition(" ")
        d[k] = v
    return d
expected, actual, prefix = load(sys.argv[1]), load(sys.argv[2]), sys.argv[3]
keys = [k for k in actual if k.startswith(prefix)]
if not keys:
    print(f"NO-KEYS\t{prefix}\tthe actual transcript carries no {prefix}* line at all")
    sys.exit(0)
for k in sorted(keys):
    if k not in expected:
        print(f"{k}\t<ABSENT>\t{actual[k]}")
    elif expected[k] != actual[k]:
        print(f"{k}\t{expected[k]}\t{actual[k]}")
PY
}

# ---------------------------------------------------------------------------
# m12_measured
#
# $M12_WORK/measured.env — the single record of what was built and run, written by
# verify_avm_wasm_import_surface, which is the check that builds. Every other M12 check reads it.
# If it is not there that check is RUN to produce one; it is never invented, defaulted or skipped.
# And every artefact the record NAMES is asserted present before any predicate reads it — M6's
# review found four assertions passing over a build directory that held nothing, because every
# predicate returned 0 over a missing path.
# ---------------------------------------------------------------------------
m12_measured() {
  if [ ! -f "$M12_WORK/measured.env" ]; then
    note "no measurement on record — running verify_avm_wasm_import_surface to produce one"
    mkdir -p "$M12_WORK"
    "$VERIFY_DIR/verify_avm_wasm_import_surface.sh" >"$M12_WORK/build-for-record.log" 2>&1 \
      || die "could not produce a measurement: see $M12_WORK/build-for-record.log"
  fi
  [ -f "$M12_WORK/measured.env" ] || die "measurement record missing at $M12_WORK/measured.env"
  # shellcheck disable=SC1090
  . "$M12_WORK/measured.env"
  [ -n "${M12_TREE:-}" ] && [ -d "$M12_TREE" ] \
    || die "measurement names no tree, or a tree that is gone: [${M12_TREE:-}]"
  m8_require_artifacts "$(m12_wasm_bin avm.wasm)" "$(m12_wasm_bin avm.wasm.gz)" \
    "$(m12_wasm_bin avm-unpruned.wasm)" "$(m12_wasm_bin avm-nogc.wasm)" \
    "$(m12_wasm_bin avm-reactor-debug.wasm)" \
    "$(m12_native_bin avm_differential)" "$(m12_reactor_inputs)" "$(m12_native_transcript)"
}

# m12_tree_dirty — the paths under barretenberg/ that differ from HEAD, EXCEPT nodejs_module/,
# whose CMakeLists runs `yarn --immutable` at configure time and forces a plain `yarn install`
# first. M3, M6, M7, M8 and M9 all scope past that directory AND PAST NOTHING ELSE.
m12_tree_dirty() {
  git -C "$M12_TREE" diff --name-only HEAD -- barretenberg \
    | grep -v '^barretenberg/cpp/src/barretenberg/nodejs_module/' \
    | tr '\n' ' ' | sed 's/ *$//'
}
