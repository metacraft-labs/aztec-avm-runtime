#!/usr/bin/env bash
# verify_cmake_split_fuzzing_preset_unchanged — M10
#
# Two things, and they are different in kind.
#
# THE EVIDENCE. The patch's argument to upstream rests on a block upstream
# already wrote: `if(FUZZING_AVM) if(FUZZING) …`, eighty lines below the guard,
# which builds the AVM modules without `ipc`, `wsdb`, `cdb`, `avm` or
# `nodejs_module`. That block is upstream's own demonstration that the ten
# modules are not one thing, and this check MEASURES it from a real `fuzzing-avm`
# configure of the UNPATCHED tree rather than reading it off the CMakeLists.
#
# It also measures the thing three of our own documents got wrong. `PR.md`, the
# patch's commit message and the comment the patch adds to `src/CMakeLists.txt`
# all said the `FUZZING_AVM` block "already builds exactly this set on its own",
# where "this set" is the three-module AVM group. It does not: it builds FOUR
# modules, `world_state` among them, because the `fuzzing-avm` preset sets
# `MULTITHREADING=ON` and `MULTITHREADING=OFF` is precisely the reason the main
# guard's own comment gives for excluding `world_state` from a fuzzing build. The
# correct claim — the one the milestone's deliverable states and the one the
# corrected documents now make — is narrower and is still enough: the AVM modules
# stand there without the socket, database and node modules. This check asserts
# the four, asserts the `MULTITHREADING` values that explain them, and asserts
# that the three documents say the narrow thing rather than the false one.
#
# THE NEUTRALITY. `fuzzing`, `fuzzing-avm` and `fuzzing-avm-tooling` are
# configured on both trees and compared by target graph and compile database, and
# `avm_fuzzer` — the target the `FUZZING_AVM` block exists to produce, and one
# that compiles all three of the C++ files this patch changes — is BUILT on both.
# The `fuzzing` preset is the one place a build proves nothing, and the check says
# why with a measurement instead: not one of the three changed files is in that
# preset's compile database at all.
#
# No skip path. Every configure's and every build's exit status is asserted
# separately from anything parsed out of its output.

TEST_NAME=verify_cmake_split_fuzzing_preset_unchanged
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/lib_avm_wasm.sh"
. "$(dirname "$0")/lib_m10_cmake_split.sh"

m6_prepare_trees
BEFORE="$M6_TREE_STACK3"
AFTER="$M6_TREE_AVM"

echo "== 0. preconditions =="
assert_dir "the tree before the split is prepared" "$BEFORE"
assert_dir "the tree after the split is prepared" "$AFTER"
assert_file "PR.md is where the patch directory says" "$M10_PR_MD"
assert_file "the prepared patch" "$M10_PATCH"

echo
echo "== A. what the FUZZING_AVM block actually demonstrates =="

# Upstream's own text, read out of the UNPATCHED tree. The guard's comment is a
# statement about world_state, which is the whole of the patch's argument.
# Measuring upstream's own block on the `before` tree is only measuring upstream if
# the three prerequisite patches leave it alone. They do not leave the FILE alone —
# the merkle/LMDB split rewrites one line of BARRETENBERG_TARGET_OBJECTS, sixty
# lines below — so what is asserted is the thing that matters: the module-guard
# REGION is byte-identical to the pristine base, and the FUZZING_AVM block is
# inside that region.
assert_eq "the module-guard region is byte-identical to the pristine base" \
  "$(m10_region_raw "$(m10_cmakelists "$M6_TREE_BASE")" | md5sum)" \
  "$(m10_region_raw "$(m10_cmakelists "$BEFORE")" | md5sum)"
assert_ge "and it is not an empty region" 20 \
  "$(m10_region_raw "$(m10_cmakelists "$BEFORE")" | grep -c .)"
assert_contains "with the FUZZING_AVM block inside it" "if(FUZZING_AVM)" \
  "$(m10_region_raw "$(m10_cmakelists "$BEFORE")")"
GUARD_COMMENT="$(m10_region_raw "$(m10_cmakelists "$BEFORE")" \
  | grep -F 'Fuzzing preset cannot be built with world_state')"
assert_contains "the guard's own comment explains world_state, not vm2" \
  "world_state cannot compile with MULTITHREADING=OFF" "$GUARD_COMMENT"
assert_not_contains "and it says nothing about vm2" "vm2" "$GUARD_COMMENT"

# Configure fuzzing-avm on the unpatched tree and read the block's effect out of
# CMake's own target graph.
m10_native_preset_configure "$BEFORE" fuzzing-avm "$M10_FUZZ_AVM_BUILD"; RC=$?
assert_eq "the unpatched tree configures the fuzzing-avm preset" "0" "$RC"
assert_eq "and that preset really does set MULTITHREADING=ON" "ON" \
  "$(m6_cache "$BEFORE" "$M10_FUZZ_AVM_BUILD" MULTITHREADING)"
assert_eq "FUZZING is on there" "ON" "$(m6_cache "$BEFORE" "$M10_FUZZ_AVM_BUILD" FUZZING)"
assert_eq "and FUZZING_AVM is on there" "ON" "$(m6_cache "$BEFORE" "$M10_FUZZ_AVM_BUILD" FUZZING_AVM)"

FA_NODES="$(m6_graph_nodes "$BEFORE" "$M10_FUZZ_AVM_BUILD")"
assert_ge "the fuzzing-avm graph has nodes at all" 100 "$(printf '%s\n' "$FA_NODES" | wc -l)"
# The AVM group is there — as targets, one per module. `aztec` is header-only, so
# it appears as itself; `vm2` produces `vm2_sim` and `vm2`.
for t in aztec world_state_reference vm2_sim; do
  assert_eq "fuzzing-avm builds $t" "1" "$(m10_graph_has "$FA_NODES" "$t")"
done
# And so is world_state, which is the correction.
assert_eq "fuzzing-avm ALSO builds world_state — the block is four modules, not three" \
  "1" "$(m10_graph_has "$FA_NODES" world_state)"
assert_eq "avm_fuzzer, which is what the block exists for" "1" "$(m10_graph_has "$FA_NODES" avm_fuzzer)"
# The five it stands without. That is the argument, precisely stated — and the
# target names are derived from each module's own CMakeLists, because `avm`'s is
# `bb-avm-sim` and `wsdb`'s are `wsdb_ipc_client` and `aztec-wsdb`, and asserting
# the absence of a name nobody declares proves nothing.
# `ipc` is a node here as it is under wasm — cmake's UNKNOWN_LIBRARY, a name
# another target links against that nothing in this configuration defines. That is
# "not built", and it is reported as the fact it is rather than collapsed into
# "absent", so the assertion below is about the SHAPE and about the compile
# database rather than only about the node list.
for m in ipc wsdb vm2_wsdb cdb avm nodejs_module; do
  ts="$(m10_module_targets "$BEFORE" "$m")"
  assert_ge "$m declares targets of its own" 1 "$(printf '%s\n' "$ts" | grep -c .)"
  for t in $ts; do
    if [ "$(m10_graph_has "$FA_NODES" "$t")" = "0" ]; then
      pass "fuzzing-avm does not build $m's $t — not a node at all"
    else
      assert_eq "fuzzing-avm does not build $m's $t — it is an UNKNOWN library" \
        "septagon" "$(m6_graph_shape "$BEFORE" "$M10_FUZZ_AVM_BUILD" "$t")"
    fi
  done
  assert_eq "and it compiles nothing under $m/" "0" \
    "$(m6_module_tu_count "$BEFORE" "$M10_FUZZ_AVM_BUILD" "/src/barretenberg/$m/")"
done

# The contrast that explains world_state: the plain `fuzzing` preset, same tree,
# MULTITHREADING=OFF, and world_state absent.
m10_native_preset_configure "$BEFORE" fuzzing "$M10_FUZZ_BUILD"; RC=$?
assert_eq "the unpatched tree configures the fuzzing preset" "0" "$RC"
assert_eq "the fuzzing preset sets MULTITHREADING=OFF" "OFF" \
  "$(m6_cache "$BEFORE" "$M10_FUZZ_BUILD" MULTITHREADING)"
F_NODES="$(m6_graph_nodes "$BEFORE" "$M10_FUZZ_BUILD")"
for t in world_state aztec world_state_reference vm2_sim; do
  assert_eq "the plain fuzzing preset builds no $t" "0" "$(m10_graph_has "$F_NODES" "$t")"
done

# The three documents. The false form must be gone from all three and the narrow
# form present, because a corrected PR.md beside a stale commit message is a
# defect this campaign has shipped three times.
PATCH_MSG="$(sed -n '1,/^---$/p' "$M10_PATCH")"
PATCH_ADDED_COMMENT="$(m6_patch_added "$M10_PATCH" 'src/CMakeLists.txt')"
assert_contains "the patch's src/CMakeLists.txt hunk does discuss the FUZZING_AVM block" \
  "FUZZING_AVM block" "$PATCH_ADDED_COMMENT"
for pair in "PR.md:$(cat "$M10_PR_MD")" "the commit message:$PATCH_MSG" "the added comment:$PATCH_ADDED_COMMENT"; do
  label="${pair%%:*}"; body="${pair#*:}"
  assert_not_contains "$label no longer says the block builds exactly this set" \
    "exactly this set" "$body"
  assert_not_contains "$label no longer says it builds exactly that set" \
    "exactly that set" "$body"
done
# Prose wraps, so the claim is matched against a whitespace-collapsed copy of
# each document rather than against a single line of it.
flat() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }
NARROW='without `ipc`, `wsdb`, `cdb`, `avm` or `nodejs_module`'
# `world_state` is a PREFIX of `world_state_reference`, which is one of the three
# AVM-group modules and is quoted in this very window, so `assert_contains
# "world_state"` cannot fail for the reason it names — it is satisfied by the AVM
# group alone, and would pass on a PR.md from which the four-module correction had
# been deleted entirely. What is asserted is a STANDALONE `world_state`: the name
# not followed by another identifier character.
assert_ge "PR.md names world_state ITSELF — the fourth module, not just world_state_reference" 1 \
  "$(grep -A12 'FUZZING_AVM' "$M10_PR_MD" | head -40 \
     | grep -oE 'world_state([^_a-zA-Z0-9]|$)' | grep -c .)"
assert_contains "PR.md states the narrow claim — without ipc, wsdb, cdb, avm or nodejs_module" \
  "$NARROW" "$(flat "$(cat "$M10_PR_MD")")"
assert_contains "and the commit message states it too" "$NARROW" "$(flat "$PATCH_MSG")"
assert_contains "PR.md explains world_state by MULTITHREADING=ON" \
  "MULTITHREADING=ON" "$(flat "$(cat "$M10_PR_MD")")"
assert_contains "and so does the comment the patch adds to src/CMakeLists.txt" \
  "MULTITHREADING=ON" "$(flat "$PATCH_ADDED_COMMENT")"

echo
echo "== B. the fuzzing presets configure and build exactly as before =="

for preset in fuzzing fuzzing-avm fuzzing-avm-tooling; do
  case "$preset" in
    fuzzing)             bdir="$M10_FUZZ_BUILD" ;;
    fuzzing-avm)         bdir="$M10_FUZZ_AVM_BUILD" ;;
    fuzzing-avm-tooling) bdir="$M10_FUZZ_TOOLING_BUILD" ;;
  esac
  # `before` was configured above for the first two; do it for the third, and
  # configure `after` for all three. Either way an assertion is made, so the
  # assertion count does not depend on which parts ran earlier.
  if [ -f "$BEFORE/barretenberg/cpp/$bdir/CMakeCache.txt" ]; then
    pass "$preset was configured before the split by part A  [$bdir]"
  else
    m10_native_preset_configure "$BEFORE" "$preset" "$bdir"; rc=$?
    assert_eq "$preset configures before the split" "0" "$rc"
  fi
  m10_native_preset_configure "$AFTER" "$preset" "$bdir"; rc=$?
  assert_eq "$preset configures after the split" "0" "$rc"

  nb="$(m6_graph_nodes "$BEFORE" "$bdir")"
  na="$(m6_graph_nodes "$AFTER" "$bdir")"
  assert_ge "$preset: the before graph is non-empty" 100 "$(printf '%s\n' "$nb" | wc -l)"
  m10_assert_same_lines "$preset: the target list is identical" "$nb" "$na"
  eb="$(m6_graph "$BEFORE" "$bdir")"
  ea="$(m6_graph "$AFTER" "$bdir")"
  assert_ge "$preset: the before graph has edges" 100 "$(printf '%s\n' "$eb" | wc -l)"
  m10_assert_same_lines "$preset: the graph's edges are identical" "$eb" "$ea"

  cmpout="$(python3 "$VERIFY_DIR/_db_compare.py" \
    "$(m6_compile_db "$BEFORE" "$bdir")" "$BEFORE" "$bdir" \
    "$(m6_compile_db "$AFTER" "$bdir")" "$AFTER" "$bdir")"
  rows="$(printf '%s\n' "$cmpout" | sed -n 's/^rows_a=//p')"
  assert_ge "$preset: it compiles hundreds of translation units" 200 "${rows:-0}"
  assert_eq "$preset: both sides compile the same number" "$rows" \
    "$(printf '%s\n' "$cmpout" | sed -n 's/^rows_b=//p')"
  assert_eq "$preset: over the same set of files" "yes" \
    "$(printf '%s\n' "$cmpout" | sed -n 's/^keys_equal=//p')"
  assert_eq "$preset: and not one command line differs" "0" \
    "$(printf '%s\n' "$cmpout" | sed -n 's/^differing_rows=//p')"
done

# The plain `fuzzing` preset cannot be affected by this patch and that is a
# measurement rather than an argument: it compiles nothing at all from any of the
# ten modules, so neither the CMake change nor the three source changes reach it.
for m in $M10_ALL_TEN; do
  assert_eq "the fuzzing preset compiles nothing under $m/" "0" \
    "$(m6_module_tu_count "$BEFORE" "$M10_FUZZ_BUILD" "/src/barretenberg/$m/")"
done
assert_ge "while it does compile hundreds of other units" 200 \
  "$(m6_tu_count "$BEFORE" "$M10_FUZZ_BUILD")"

# And fuzzing-avm compiles the two changed translation units, which is what makes
# the build below a real statement about them. (`indexed_memory_tree.hpp` is a
# header; its diagnostics are reported in the gadget units that include it, and
# those are counted here as part of vm2/.)
for f in vm2/simulation/gadgets/to_radix.cpp world_state_reference/memory_merkle_db.cpp; do
  assert_ge "fuzzing-avm does compile $f" 1 \
    "$(m6_module_tu_count "$BEFORE" "$M10_FUZZ_AVM_BUILD" "$f")"
done
assert_ge "and it compiles the vm2 module the split moves" 50 \
  "$(m6_module_tu_count "$BEFORE" "$M10_FUZZ_AVM_BUILD" "/src/barretenberg/vm2/")"

echo
echo "== C. avm_fuzzer builds on both sides =="

for side in "before:$BEFORE" "after:$AFTER"; do
  label="${side%%:*}"; tree="${side#*:}"
  m6_build "$tree" "$M10_FUZZ_AVM_BUILD" avm_fuzzer world_state world_state_reference; rc=$?
  assert_eq "avm_fuzzer and both world states build $label the split" "0" "$rc"
  assert_eq "no compiler diagnostic $label the split" "0" \
    "$(m6_build_log "$tree" "$M10_FUZZ_AVM_BUILD" | grep -c 'error:')"
  for a in libavm_fuzzer.a libworld_state.a libworld_state_reference.a libvm2_sim.a; do
    assert_file "$a exists $label the split" \
      "$tree/barretenberg/cpp/$M10_FUZZ_AVM_BUILD/lib/$a"
  done
done

AR_B="$(m6_archives "$BEFORE" "$M10_FUZZ_AVM_BUILD" | tr ' ' '\n' | sort)"
AR_A="$(m6_archives "$AFTER" "$M10_FUZZ_AVM_BUILD" | tr ' ' '\n' | sort)"
assert_ge "the fuzzing-avm build produces archives" 10 "$(printf '%s\n' "$AR_B" | grep -c .)"
m10_assert_same_lines "and the same set of them on both sides" "$AR_B" "$AR_A"
note "libworld_state.a is in there: the FUZZING_AVM block really does carry the server world state"

finish
