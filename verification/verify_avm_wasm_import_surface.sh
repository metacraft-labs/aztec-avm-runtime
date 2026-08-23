#!/usr/bin/env bash
# M12: `avm.wasm` imports exactly the WASI functions libc's startup and stdio need and nothing else
# — no filesystem beyond that, no sockets, no threads, and NO ORACLE OR FOREIGN-CALL SURFACE AT ALL,
# unlike the private ACVM/Brillig side.
#
# It is also the milestone's measurement of record: it writes $M12_WORK/measured.env and the
# transcripts every other M12 check reads rather than re-deriving, so no two checks can disagree
# about what was built.
#
# THE DELIVERABLE'S NUMBER WAS RE-MEASURED RATHER THAN INHERITED, AND IT SURVIVED.
#
# The milestone froze this surface at "eleven `wasi_snapshot_preview1` symbols" and named them.
# Measured on the artefact this milestone actually produces, that list is EXACTLY RIGHT: eleven WASI
# functions, those eleven. What the deliverable did not say is that there is a twelfth import —
# `env.memory`, the only non-WASI one — which exists because `src/CMakeLists.txt` links every wasm
# artefact with `-Wl,--import-memory`. Twelve in total, and the write-up now says so.
#
# M7's "18 functions plus one memory, 19 in total" is a different artefact and both numbers are
# right: `vm2_sim_tests` is a WASI *command* carrying gtest's own `main`, argv and environ handling,
# file output and an exit path. A reactor with no `main` needs less of wasi-libc than a command
# does. This check asserts BOTH modules' surfaces from the same tree, so the difference is measured
# here rather than reconciled in prose.
#
# What it asserts, and why in this shape:
#
#   * cmake's exit status and ninja's SEPARATELY from anything parsed out of either. M2's defect was
#     a green summary printed over a red build; M3's lesson was that only `ninja exits 0` names it.
#   * The target is ADDITIVE: with AVM_REACTOR left at its default on the same preset, the wasm
#     build declares no reactor target at all, and the option's default is read from the PATCH's own
#     added `option()` line rather than from a configured cache, which a preset could have set.
#   * The import list as an IDENTITY, not a count and not a bound.
#   * The export list as an IDENTITY, with the eight ContractDBInterface methods and the fourteen
#     LowLevelMerkleDBInterface methods named individually, and with every
#     HighLevelMerkleDBInterface method asserted ABSENT BY NAME — a count would go green for a build
#     that exposed it.
#   * TWO CONTROLS, ONE OPTION EACH, because one control cannot separate two options.
#     `avm-unpruned.wasm` adds `--export-dynamic`; `avm-nogc.wasm` adds `--no-gc-sections`. The
#     second exists because wasm-ld garbage-collects BY DEFAULT — its own `--help` says so, and the
#     check reads it from the linker — so a control that merely omits `--gc-sections` still
#     collects, and crediting the collector with what `--export-dynamic` did was this check's
#     second wrong answer. Measured: the export-dynamic control imports 15, the no-gc control 46.

set -uo pipefail

TEST_NAME=verify_avm_wasm_import_surface
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m12_reactor.sh"

require_nix
note "work directory: $M12_WORK"

# --- the tree ---------------------------------------------------------------
m12_tree >/dev/null
note "tree: $M12_TREE ($(git -C "$M12_TREE" rev-parse --short HEAD))"

assert_eq "the tree is $M6_BASE_REV + exactly nine patches" \
  9 "$(git -C "$M12_TREE" rev-list --count "$M6_BASE_REV..HEAD")"
assert_file "M12's overlay patch is the artefact under test" "$M12_PATCH_9"

# The option's DEFAULT comes from the patch, not from a cache. Asserting what the thing SETS,
# rather than only that something else is unchanged.
option_line="$(m6_patch_added "$M12_PATCH_9" 'cpp/CMakeLists.txt' | grep -F 'option(AVM_REACTOR')"
assert_contains "the overlay adds an option(AVM_REACTOR ...) line" "option(AVM_REACTOR" "$option_line"
assert_prefix "and its default is OFF" "OFF" \
  "$(printf '%s' "$option_line" | awk '{print $NF}' | tr -d ')')"

# The overlay's file set, as an identity.
patch_files="$(m6_patch_files "$M12_PATCH_9" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the overlay touches exactly five files" \
  "barretenberg/cpp/CMakeLists.txt barretenberg/cpp/src/barretenberg/vm2/CMakeLists.txt barretenberg/cpp/src/barretenberg/vm2/differential/avm_differential.cpp barretenberg/cpp/src/barretenberg/vm2/reactor/avm_msgpack_coverage.cpp barretenberg/cpp/src/barretenberg/vm2/reactor/avm_reactor.cpp" \
  "$patch_files"
assert_eq "and it creates exactly the two reactor sources" 2 \
  "$(grep -c '^new file mode' "$M12_PATCH_9")"

# The tree is base + nine COMMITS, which is what `m6_prepare_tree` counts — but a work directory
# prepared from an EARLIER version of the ninth patch has nine commits too, and would then be reused
# silently with the old CMakeLists in it. Asserted by content rather than by count, with the remedy
# in the message, because the failure it prevents otherwise reads as a missing build artefact.
assert_ge "the prepared tree carries THIS version of the overlay (else: rm -rf \$M12_WORK and re-run)" 1 \
  "$(grep -c 'avm-reactor-nogc\.wasm' "$M12_TREE/barretenberg/cpp/src/barretenberg/vm2/CMakeLists.txt" 2>/dev/null || echo 0)"

# The reactor touches NO file under vm2/simulation/**: the interpreter is upstream's and this
# milestone adds a boundary around it, not a change inside it.
assert_eq "the overlay changes nothing under vm2/simulation/" 0 \
  "$(m6_patch_files "$M12_PATCH_9" | grep -c '/vm2/simulation/')"

# --- ADDITIVE: the OFF side -------------------------------------------------
m12_configure_reactor_off "$M12_TREE"
off_rc=$?
assert_eq "wasm-avm configures with AVM_REACTOR left at its default" 0 "$off_rc"
off_targets="$(m6_ninja_targets "$M12_TREE" build-wasm-reactoroff)"
assert_eq "with the option off the wasm build declares no avm.wasm target" 0 \
  "$(printf '%s\n' "$off_targets" | grep -c '^bin/avm\.wasm$')"
assert_eq "and no avm-reactor-debug.wasm either" 0 \
  "$(printf '%s\n' "$off_targets" | grep -c 'avm-reactor-debug\.wasm')"
assert_eq "and no avm_msgpack_coverage" 0 \
  "$(printf '%s\n' "$off_targets" | grep -c 'avm_msgpack_coverage')"
assert_ge "while still declaring the differential driver it inherits" 1 \
  "$(printf '%s\n' "$off_targets" | grep -c '^bin/avm_differential$')"

# --- the wasm build ---------------------------------------------------------
# `barretenberg.wasm.gz` is built here as well: the size comparison this milestone commits to is
# against the proving stack, and it is measured FROM THIS TREE WITH THIS TOOLCHAIN rather than
# quoted from a figure captured somewhere else.
m12_build_wasm "$M12_TREE" barretenberg.wasm.gz
wasm_rc=$?
assert_eq "cmake --preset wasm-avm -DAVM_REACTOR=ON exits 0" 0 "${M12_WASM_CONFIGURE_RC:-99}"
assert_eq "ninja avm.wasm.gz, the two controls, avm_msgpack_coverage, avm_differential and barretenberg.wasm.gz exits 0" \
  0 "${M12_WASM_BUILD_RC:-99}"
if [ "$wasm_rc" -ne 0 ]; then
  note "build log: $M12_TREE/m6-$M12_WASM_BUILD-build.log"
  # `-Wfatal-errors` means a failing unit emits exactly one `fatal error:` line and no ordinary
  # `: error: ` line at all, so both are printed rather than only the one that happens to be zero.
  m6_build_log "$M12_TREE" "$M12_WASM_BUILD" | grep -E '^FAILED:|fatal error:' | head -20
fi

REACTOR="$(m12_wasm_bin avm.wasm)"
UNPRUNED="$(m12_wasm_bin avm-unpruned.wasm)"
DEBUGMOD="$(m12_wasm_bin avm-reactor-debug.wasm)"
m8_require_artifacts "$REACTOR" "$UNPRUNED" "$DEBUGMOD" "$(m12_wasm_bin avm.wasm.gz)" \
  "$(m12_wasm_bin avm-nogc.wasm)" \
  "$(m12_wasm_bin avm_msgpack_coverage)" "$(m12_wasm_bin avm_differential)"

magic="$(head -c 4 "$REACTOR" | od -An -tx1 | tr -d ' \n')"
assert_eq "avm.wasm is a WebAssembly module by its own magic bytes" "0061736d" "$magic"

# --- the import surface, as an identity -------------------------------------
imports="$(m12_wasm_module_imports "$REACTOR")"
assert_eq "the module imports exactly $M12_EXPECTED_IMPORT_COUNT things" \
  "$M12_EXPECTED_IMPORT_COUNT" "$(printf '%s\n' "$imports" | grep -c .)"

wasi_imports="$(printf '%s\n' "$imports" | grep '^wasi_snapshot_preview1\.')"
non_wasi="$(printf '%s\n' "$imports" | grep -v '^wasi_snapshot_preview1\.')"

assert_eq "exactly $M12_EXPECTED_WASI_IMPORT_COUNT of them are wasi_snapshot_preview1 functions" \
  "$M12_EXPECTED_WASI_IMPORT_COUNT" "$(printf '%s\n' "$wasi_imports" | grep -c .)"
assert_eq "and they are exactly the eleven the milestone names" \
  "$(printf '%s\n' "$M12_EXPECTED_WASI_IMPORTS" | LC_ALL=C sort | tr '\n' ' ')" \
  "$(printf '%s\n' "$wasi_imports" | tr '\n' ' ')"

assert_eq "exactly one import is not WASI" 1 "$(printf '%s\n' "$non_wasi" | grep -c .)"
assert_eq "and it is env.memory — the twelfth import the deliverable did not name" \
  "$M12_EXPECTED_NON_WASI_IMPORT" "$non_wasi"

# The negative half, stated as names rather than as "nothing else". Each of these is a real WASI
# function that a module doing that thing WOULD import.
for forbidden in \
  sock_accept sock_recv sock_send sock_shutdown \
  path_open path_create_directory path_remove_directory path_unlink_file path_rename \
  fd_pwrite fd_pread fd_readdir fd_filestat_set_size \
  poll_oneoff sched_yield random_get proc_raise
do
  assert_eq "no wasi_snapshot_preview1.$forbidden import" 0 \
    "$(printf '%s\n' "$imports" | grep -cx "wasi_snapshot_preview1\.$forbidden")"
done
# Threads, which would arrive as a wasi-threads import and a SHARED memory.
assert_eq "no thread_spawn import" 0 "$(printf '%s\n' "$imports" | grep -c 'thread_spawn')"
assert_eq "no wasi_thread import module at all" 0 "$(printf '%s\n' "$imports" | grep -c '^wasi_threads\.')"
# And the foreign-call surface, which the private ACVM side has and this module does not: there is
# no imported DB callback, no oracle, and nothing under `env.` but the memory.
assert_eq "no env.* import other than the memory" 1 "$(printf '%s\n' "$imports" | grep -c '^env\.')"
for oracle in oracle foreign_call callback host_ contract_db merkle_db avm_host; do
  assert_eq "no import whose name mentions '$oracle'" 0 "$(printf '%s\n' "$imports" | grep -c "$oracle")"
done

limits="$(python3 "$M7_MEMLIMITS" "$REACTOR")"
assert_prefix "the memory import declares its own limits" "env memory " "$limits"
MEM_MIN="$(printf '%s' "$limits" | awk '{print $3}')"
assert_ge "and a minimum of at least 128 pages" 128 "$MEM_MIN"
assert_eq "the memory is not shared (this is not a threads build)" 0 \
  "$(printf '%s' "$limits" | awk '{print ($5 == "shared") ? 1 : 0}')"

# --- the export surface, as an identity -------------------------------------
exports="$(m12_wasm_module_exports "$REACTOR")"
assert_eq "the module exports exactly $M12_EXPECTED_EXPORT_COUNT names" \
  "$M12_EXPECTED_EXPORT_COUNT" "$(printf '%s\n' "$exports" | grep -c .)"
assert_eq "and the export list is exactly what the link line names" \
  "$(printf '%s\n' "$M12_EXPECTED_EXPORTS" | LC_ALL=C sort | tr '\n' ' ')" \
  "$(printf '%s\n' "$exports" | tr '\n' ' ')"

# It is a REACTOR, not a command: `_initialize` and no `_start`.
assert_eq "it exports _initialize" 1 "$(printf '%s\n' "$exports" | grep -cx '_initialize')"
assert_eq "and does NOT export _start — it has no main" 0 "$(printf '%s\n' "$exports" | grep -cx '_start')"
# `__main_argc_argv` is deliberately NOT asserted with llvm-nm. MEASURED on this very tree,
# `llvm-nm | grep -c __main_argc_argv` is 0 for `vm2_sim_tests` TOO — a WASI *command* carrying
# gtest's own main — because the entry point is internalised once it is linked. M7's review
# recorded exactly that, and an assertion that reads 0 for both artefacts measures nothing. What
# discriminates a reactor from a command is the export table, and that IS asserted against the
# command from this same tree, further down.

# The two entry points the milestone names, and the memory pair.
for e in avm_simulate avm_simulate_with_hinted_dbs avm_alloc avm_free avm_steps_count avm_steps_batch; do
  assert_eq "the module exports $e" 1 "$(printf '%s\n' "$exports" | grep -cx "$e")"
done

# ContractDBInterface: the eight methods, named individually.
cdb_exported=0
while IFS= read -r m; do
  [ -n "$m" ] || continue
  if [ "$(printf '%s\n' "$exports" | grep -cx "$m")" = "1" ]; then
    cdb_exported=$((cdb_exported + 1))
  else
    fail "ContractDBInterface method not exported: $m"
  fi
done <<<"$M12_CONTRACT_DB_METHODS"
assert_eq "all EIGHT ContractDBInterface methods are exported" 8 "$cdb_exported"

# LowLevelMerkleDBInterface: the fourteen.
mdb_exported=0
while IFS= read -r m; do
  [ -n "$m" ] || continue
  if [ "$(printf '%s\n' "$exports" | grep -cx "$m")" = "1" ]; then
    mdb_exported=$((mdb_exported + 1))
  else
    fail "LowLevelMerkleDBInterface method not exported: $m"
  fi
done <<<"$M12_MERKLE_DB_METHODS"
assert_eq "all FOURTEEN LowLevelMerkleDBInterface methods are exported" 14 "$mdb_exported"

# HighLevelMerkleDBInterface: NOT exposed, asserted by name. It is internal to vm2 and
# `simulate_fast_internal` satisfies it itself with `PureMerkleDB`.
while IFS= read -r m; do
  [ -n "$m" ] || continue
  assert_eq "HighLevelMerkleDBInterface method '$m' is NOT exported" 0 \
    "$(printf '%s\n' "$exports" | grep -c "$m")"
done <<<"$M12_HIGH_LEVEL_METHODS"
# And the claim it rests on, re-derived from the fork at the anchor rather than from our copy.
HL_SRC="$M12_WORK/db.hpp"
m8_upstream_file barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/db.hpp "$HL_SRC"
assert_ge "upstream's own db.hpp declares HighLevelMerkleDBInterface" 1 \
  "$(grep -c 'class HighLevelMerkleDBInterface' "$HL_SRC")"
HELPER_SRC="$M12_WORK/simulation_helper.cpp"
m8_upstream_file barretenberg/cpp/src/barretenberg/vm2/simulation_helper.cpp "$HELPER_SRC"
assert_ge "and simulate_fast_internal builds a PureMerkleDB itself, so nothing of ours needs it" 1 \
  "$(grep -c 'PureMerkleDB' "$HELPER_SRC")"
assert_ge "the same function wraps whatever raw contract DB it is handed in PureContractDB" 1 \
  "$(grep -c 'PureContractDB contract_db(raw_contract_db)' "$HELPER_SRC")"

# --- CONTROL 1: the export list ---------------------------------------------
# Same sources, same objects, linked with `--export-dynamic`. Without this the export identity above
# is a statement about a flag rather than about an artefact. It is named for what it varies: the
# `--gc-sections` it also omits is a no-op, for the reason set out below.
unpruned_exports="$(m12_wasm_module_exports "$UNPRUNED")"
UNPRUNED_EXPORT_COUNT="$(printf '%s\n' "$unpruned_exports" | grep -c .)"
assert_eq "the unpruned control is a WebAssembly module too" "0061736d" \
  "$(head -c 4 "$UNPRUNED" | od -An -tx1 | tr -d ' \n')"
assert_true "the unpruned control exports far more than $M12_EXPECTED_EXPORT_COUNT names" \
  test "$UNPRUNED_EXPORT_COUNT" -gt "$((M12_EXPECTED_EXPORT_COUNT * 4))"
note "unpruned control exports $UNPRUNED_EXPORT_COUNT names against the pruned module's $M12_EXPECTED_EXPORT_COUNT"
# ITS IMPORTS ARE NOT THE SAME, AND THAT IS THIS CHECK'S MOST USEFUL RESULT — BUT THE CAUSE IS NOT
# THE ONE THIS CHECK FIRST NAMED.
#
# Two corrections, in order. The first version of this assertion said "pruning changes exports, not
# imports", and that is simply false: measured, this control imports FIFTEEN, adding
# `fd_fdstat_set_flags`, `path_open` and `poll_oneoff`.
#
# The second version then credited `--gc-sections` with removing them. Measured, that is wrong too,
# and the linker says so itself: `wasm-ld --help` reads `--gc-sections  Enable garbage collection of
# unused sections (default)`. THE COLLECTOR IS ON IN BOTH MODULES. Omitting the flag from this
# control's link line changes nothing; what the control actually varies is `--export-dynamic`, which
# turns every `visibility("default")` symbol in the closure into a GC ROOT and therefore RETAINS the
# code that pulls those three WASI functions in.
#
# So the eleven-function surface is a consequence of the EXPLICIT EXPORT LIST — of NOT passing
# `--export-dynamic` — and, separately and far more strongly, of the collector running at all, which
# `avm-nogc.wasm` below is what measures. Two controls, one option each; the assertion below is
# worded as what was varied rather than as what was assumed.
unpruned_imports="$(m12_wasm_module_imports "$UNPRUNED")"
assert_eq "the --export-dynamic control imports fifteen, not twelve" 15 \
  "$(printf '%s\n' "$unpruned_imports" | grep -c .)"
assert_eq "the reactor's imports are a strict SUBSET of the control's — nothing appears from pruning" "" \
  "$(comm -23 <(printf '%s\n' "$imports") <(printf '%s\n' "$unpruned_imports") | tr '\n' ' ' | sed 's/ $//')"
PRUNED_AWAY="$(comm -13 <(printf '%s\n' "$imports") <(printf '%s\n' "$unpruned_imports") | sed 's/^wasi_snapshot_preview1\.//' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "and --export-dynamic re-roots exactly these three WASI functions back into the module" \
  "fd_fdstat_set_flags path_open poll_oneoff" "$PRUNED_AWAY"
for gone in path_open poll_oneoff; do
  assert_ge "the control DOES import $gone, so its absence from the reactor is a discrimination" 1 \
    "$(printf '%s\n' "$unpruned_imports" | grep -cx "wasi_snapshot_preview1\.$gone")"
done
note "the export list costs three imports as well as $((UNPRUNED_EXPORT_COUNT - M12_EXPECTED_EXPORT_COUNT)) exports: $PRUNED_AWAY"

# The linker's own statement of its default, read from the linker rather than assumed. Without this
# the paragraph above is a claim about wasm-ld and not a measurement of it.
# Matched against BOTH spellings on purpose: wasm-ld 33's help line reads
# `--gc-sections  Enable garbage collection of unused sections (defualt)` — upstream LLVM's own
# typo. A needle written from memory of what the text ought to say fails on what it does say, which
# is the same mistake as every other prefix match in this campaign, one level up.
LD_GC_HELP="$(m6_in_devshell '"$WASI_SDK_PREFIX/bin/wasm-ld" --help 2>&1 | grep -E "^ *--gc-sections" || true' 2>/dev/null | tail -1)"
assert_true "wasm-ld's own --help says garbage collection is its DEFAULT (however it spells it)" \
  grep -qE '\((default|defualt)\)' <<<"$LD_GC_HELP"
assert_contains "and the line is about --gc-sections" "--gc-sections" "$LD_GC_HELP"
note "wasm-ld: $LD_GC_HELP"

# --- CONTROL 2: the collector genuinely off ---------------------------------
# Same objects, same explicit export list, `-Wl,--no-gc-sections`. This is the one that isolates
# `--gc-sections`, and it is a much larger effect than the export list's: forty-five WASI functions.
NOGC="$(m12_wasm_bin avm-nogc.wasm)"
assert_file "the no-gc control was built" "$NOGC"
nogc_imports="$(m12_wasm_module_imports "$NOGC")"
NOGC_WASI="$(printf '%s\n' "$nogc_imports" | grep -c '^wasi_snapshot_preview1\.')"
assert_eq "with the collector off the SAME sources import $M12_MEASURED_NOGC_WASI_IMPORTS WASI functions" \
  "$M12_MEASURED_NOGC_WASI_IMPORTS" "$NOGC_WASI"
assert_true "which is far more than the --export-dynamic control's fifteen" \
  test "$NOGC_WASI" -gt 15
# Named, not counted: the whole filesystem and socket surface comes back.
for back in path_open path_create_directory path_unlink_file fd_readdir sock_accept sock_send poll_oneoff random_get; do
  assert_ge "the no-gc control DOES import $back" 1 \
    "$(printf '%s\n' "$nogc_imports" | grep -cx "wasi_snapshot_preview1\.$back")"
done
assert_eq "and its export list is still the thirty-nine the link line names — only the collector changed" \
  "$M12_EXPECTED_EXPORT_COUNT" "$(m12_wasm_module_exports "$NOGC" | grep -c .)"
note "no-gc control: $NOGC_WASI WASI imports against the reactor's $M12_EXPECTED_WASI_IMPORT_COUNT, with the same 39 exports"

# --- the OTHER artefact in this tree, so M7's number and this one are measured together ---------
SIMTESTS="$M12_TREE/barretenberg/cpp/$M12_WASM_BUILD/bin/vm2_sim_tests"
assert_file "the same tree also builds upstream's own wasm test COMMAND" "$SIMTESTS"
if [ -f "$SIMTESTS" ]; then
  simtests_imports="$(m12_wasm_module_imports "$SIMTESTS")"
  SIMTESTS_WASI="$(printf '%s\n' "$simtests_imports" | grep -c '^wasi_snapshot_preview1\.')"
  assert_eq "vm2_sim_tests, the COMMAND, imports 18 WASI functions — M7's number, re-measured" \
    18 "$SIMTESTS_WASI"
  assert_eq "and 19 imports in total, against the reactor's 12" \
    19 "$(printf '%s\n' "$simtests_imports" | grep -c .)"
  assert_true "the command's WASI surface is strictly larger than the reactor's" \
    test "$SIMTESTS_WASI" -gt "$M12_EXPECTED_WASI_IMPORT_COUNT"
  # And the seven the command needs and the reactor does not, named rather than counted.
  extra="$(comm -13 <(printf '%s\n' "$wasi_imports") <(printf '%s\n' "$simtests_imports" | grep '^wasi_snapshot_preview1\.') | sed 's/^wasi_snapshot_preview1\.//' | tr '\n' ' ' | sed 's/ $//')"
  note "the command imports these and the reactor does not: $extra"
  assert_eq "the reactor imports nothing the command does not" "" \
    "$(comm -23 <(printf '%s\n' "$wasi_imports") <(printf '%s\n' "$simtests_imports" | grep '^wasi_snapshot_preview1\.') | tr '\n' ' ' | sed 's/ $//')"
  # THE DISCRIMINATION that llvm-nm could not make. The command exports `_start` and no
  # `_initialize`; the reactor is the other way round. Asserted on the command from this same tree,
  # so "it is a reactor and not a command" is a comparison rather than a property of one artefact.
  simtests_exports="$(m12_wasm_module_exports "$SIMTESTS")"
  assert_eq "the COMMAND exports _start, which is what makes the reactor's absence of it a discrimination" \
    1 "$(printf '%s\n' "$simtests_exports" | grep -cx '_start')"
  assert_eq "and the command exports no _initialize" 0 \
    "$(printf '%s\n' "$simtests_exports" | grep -cx '_initialize')"
else
  fail "vm2_sim_tests was not produced, so M7's number cannot be re-measured beside this one"
fi

# --- the native side and the transcripts every other check reads ------------
m12_build_native "$M12_TREE"
native_rc=$?
assert_eq "cmake --preset default -DAVM_REACTOR=ON exits 0" 0 "${M12_NATIVE_CONFIGURE_RC:-99}"
assert_eq "ninja avm_differential avm_msgpack_coverage exits 0 natively" 0 "${M12_NATIVE_BUILD_RC:-99}"
if [ "$native_rc" -ne 0 ]; then
  m6_build_log "$M12_TREE" "$M12_NATIVE_BUILD" | grep -E '^FAILED:|fatal error:| error: ' | head -20
fi
m8_require_artifacts "$(m12_native_bin avm_differential)" "$(m12_native_bin avm_msgpack_coverage)"

mkdir -p "$M12_WORK"
m9_run_native "$(m12_native_bin avm_differential)" "$(m12_native_transcript)" "$M12_WORK/native.transcript.err"
assert_eq "the native driver's default transcript runs" 0 $?
assert_ge "and carries the seven programs' result lines" 140 \
  "$(grep -c '^program\.' "$(m12_native_transcript)")"

m9_run_native "$(m12_native_bin avm_differential)" "$(m12_reactor_inputs)" "$M12_WORK/reactor-inputs.err" reactorinputs
assert_eq "the native driver's reactorinputs mode runs" 0 $?
assert_eq "and declares the seven corpus programs" "$M12_EXPECTED_PROGRAMS" \
  "$(m12_field "$(m12_reactor_inputs)" reactorInputs.programs.count)"
assert_eq "and it finished" "1" "$(m12_field "$(m12_reactor_inputs)" reactorInputs.done)"

m9_run_native "$(m12_native_bin avm_differential)" "$(m12_native_steps)" "$M12_WORK/native.steps.err" steps
assert_eq "the native driver's steps mode runs" 0 $?
assert_eq "and records M9's $M12_STEP_COUNT instructions for $M12_STEP_PROGRAM" "$M12_STEP_COUNT" \
  "$(grep -c "^steps\.$M12_STEP_PROGRAM\.[0-9]* ctx=" "$(m12_native_steps)")"

# --- the record -------------------------------------------------------------
RAW_BYTES=$(stat -c %s "$REACTOR")
GZ_BYTES=$(stat -c %s "$(m12_wasm_bin avm.wasm.gz)")
UNPRUNED_RAW=$(stat -c %s "$UNPRUNED")
UNPRUNED_GZ=$(stat -c %s "$(m12_wasm_bin avm-unpruned.wasm.gz)")
NOGC_RAW=$(stat -c %s "$NOGC")
NOGC_GZ=$(stat -c %s "$(m12_wasm_bin avm-nogc.wasm.gz)")
DEBUG_BYTES=$(stat -c %s "$DEBUGMOD")
BB_GZ=$(stat -c %s "$(m12_wasm_bin barretenberg.wasm.gz)" 2>/dev/null || echo 0)

cat >"$M12_WORK/measured.env" <<EOF
# Written by $TEST_NAME on $(date -u +%Y-%m-%dT%H:%M:%SZ). Read by every other M12 check, so no
# two of them can disagree about what was built.
M12_TREE=$M12_TREE
M12_REACTOR=$REACTOR
M12_RAW_BYTES=$RAW_BYTES
M12_GZ_BYTES=$GZ_BYTES
M12_UNPRUNED_RAW_BYTES=$UNPRUNED_RAW
M12_UNPRUNED_GZ_BYTES=$UNPRUNED_GZ
M12_NOGC_RAW_BYTES=$NOGC_RAW
M12_NOGC_GZ_BYTES=$NOGC_GZ
M12_NOGC_WASI_IMPORTS=$NOGC_WASI
M12_DEBUG_BYTES=$DEBUG_BYTES
M12_BARRETENBERG_GZ_BYTES=$BB_GZ
M12_IMPORT_COUNT=$(printf '%s\n' "$imports" | grep -c .)
M12_WASI_IMPORT_COUNT=$(printf '%s\n' "$wasi_imports" | grep -c .)
M12_EXPORT_COUNT=$(printf '%s\n' "$exports" | grep -c .)
M12_UNPRUNED_EXPORT_COUNT=$UNPRUNED_EXPORT_COUNT
M12_SIMTESTS_WASI_IMPORTS=${SIMTESTS_WASI:-0}
M12_MEM_MIN=$MEM_MIN
EOF
note "measurement written to $M12_WORK/measured.env"
note "avm.wasm: $RAW_BYTES bytes raw, $GZ_BYTES gzipped; --export-dynamic control $UNPRUNED_RAW / $UNPRUNED_GZ; --no-gc-sections control $NOGC_RAW / $NOGC_GZ; barretenberg.wasm.gz $BB_GZ"

finish
