#!/usr/bin/env bash
# verify_cmake_split_native_neutral — M10
#
# The claim: with AVM_WASM off, every existing preset produces an identical
# target list, build graph and test results before and after the split.
#
# "Every existing preset" is 42 configure presets, most of which want a
# sanitizer runtime, a cross SDK or a toolchain this host does not have. Four of
# them sampled and reported as "every" would be exactly the class of claim this
# campaign keeps correcting, so the guard is settled two ways instead:
#
#   A. EXHAUSTIVELY, in CMake's own language. The module-guard region of
#      `src/CMakeLists.txt` is lifted verbatim out of each tree, every
#      `add_subdirectory` rewritten to a list append, and evaluated by a real
#      `cmake -P` over all 32 assignments of the five variables its conditions
#      reference. Every preset that exists — and every preset that could exist —
#      is one of those 32 rows. The check asserts the region's command vocabulary
#      and its variable set, because "32 rows is exhaustive" is only true while
#      both hold, and it runs a mutation control, because a table of identical
#      rows is also what an extractor that reads nothing produces.
#
#   B. CONCRETELY, on the two presets whose whole build graph can be compared
#      here: `default` (native) and `wasm`. Target graph, graph edges and the
#      compile database, per row.
#
# And then the part neither of those reaches. The patch is not only CMake: it
# changes THREE C++ SOURCE FILES that every native build compiles
# (`vm2/simulation/lib/indexed_memory_tree.hpp`,
# `vm2/simulation/gadgets/to_radix.cpp`,
# `world_state_reference/memory_merkle_db.hpp`), so identical compile commands do
# not make identical binaries and "test results are identical" has to be run.
# Part D builds and runs upstream's OWN `vm2_tests` and `world_state_tests` on
# both trees and compares them TEST BY NAME. Those two suites are chosen because
# they are the ones that cover the changed files: `vm2_tests` compiles
# `indexed_memory_tree.hpp` and `to_radix.cpp`, and `world_state_tests` carries
# upstream's seven `MemoryMerkleDBEquivalenceTest` cases over
# `memory_merkle_db.hpp`. The merkle-tree suites the contribution's own verify.sh
# runs touch none of the three.
#
# No skip path: a tree that cannot be prepared is `die`, every build's exit
# status is asserted separately from anything parsed out of its output, and
# `finish` fails the run if zero assertions were made.

TEST_NAME=verify_cmake_split_native_neutral
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/lib_avm_wasm.sh"
. "$(dirname "$0")/lib_m10_cmake_split.sh"

m6_prepare_trees
BEFORE="$M6_TREE_STACK3"   # patches 1,2,3 — the split's own "before"
AFTER="$M6_TREE_AVM"       # + the split

echo "== 0. preconditions =="
assert_file "the prepared patch is where SERIES.md indexes it" "$M10_PATCH"
assert_dir "the tree before the split is prepared" "$BEFORE"
assert_dir "the tree after the split is prepared" "$AFTER"
CL_BEFORE="$(m10_cmakelists "$BEFORE")"
CL_AFTER="$(m10_cmakelists "$AFTER")"
assert_file "src/CMakeLists.txt, before" "$CL_BEFORE"
assert_file "src/CMakeLists.txt, after" "$CL_AFTER"
assert_true "the two differ, so there is something to compare" \
  bash -c '! cmp -s "$1" "$2"' _ "$CL_BEFORE" "$CL_AFTER"
assert_eq "upstream declares 42 configure presets before the split" "42" "$(m10_preset_count "$BEFORE")"
assert_eq "and 43 after it" "43" "$(m10_preset_count "$AFTER")"
assert_eq "the one it adds is wasm-avm, and it adds only that" "wasm-avm" \
  "$(comm -13 <(m10_preset_names "$BEFORE" | tr ' ' '\n' | sort) \
              <(m10_preset_names "$AFTER"  | tr ' ' '\n' | sort) | tr '\n' ' ' | sed 's/ $//')"
assert_eq "and it removes none" "" \
  "$(comm -23 <(m10_preset_names "$BEFORE" | tr ' ' '\n' | sort) \
              <(m10_preset_names "$AFTER"  | tr ' ' '\n' | sort) | tr '\n' ' ' | sed 's/ $//')"
note "42 presets, of which this host can configure a handful; part A covers all 42 by construction"

echo
echo "== A. the module guard, exhaustively =="

# The extraction is only faithful if the region contains nothing the rewrite
# would silently drop, and the enumeration is only exhaustive if the conditions
# reference nothing outside the five variables it enumerates. Both are asserted
# before a single row is compared.
for side in "before:$CL_BEFORE" "after:$CL_AFTER"; do
  label="${side%%:*}"; f="${side#*:}"
  cmds="$(m10_region_command_names "$f")"
  bad=0
  for c in $cmds; do
    case " $M10_REGION_COMMANDS " in *" $c "*) ;; *) bad=$((bad + 1)) ;; esac
  done
  assert_eq "$label: the region uses no command outside if/elseif/endif/set/add_subdirectory" "0" "$bad"
  note "$label: region commands = $cmds"
done
assert_eq "before: the region's conditions reference exactly four variables" \
  "BB_LITE FUZZING FUZZING_AVM WASM" "$(m10_region_condition_vars "$CL_BEFORE")"
assert_eq "after: exactly those four plus AVM_WASM, and nothing else" \
  "$M10_GUARD_VARS" "$(m10_region_condition_vars "$CL_AFTER")"

# And the region really is the block the milestone is about: all ten modules are
# inside it on both sides.
for m in $M10_ALL_TEN; do
  n_b=$(m10_region_raw "$CL_BEFORE" | grep -cE "add_subdirectory\(barretenberg/$m\)")
  n_a=$(m10_region_raw "$CL_AFTER"  | grep -cE "add_subdirectory\(barretenberg/$m\)")
  assert_ge "before: the region adds $m" 1 "$n_b"
  assert_ge "after: the region still adds $m" 1 "$n_a"
done

TBL_B="$M10_WORK/truth-before.tsv"
TBL_A="$M10_WORK/truth-after.tsv"
m10_truth_table "$CL_BEFORE" before >"$TBL_B"
m10_truth_table "$CL_AFTER"  after  >"$TBL_A"
assert_eq "the before table has one row per assignment of the five variables" "32" "$(wc -l <"$TBL_B")"
assert_eq "and so does the after table" "32" "$(wc -l <"$TBL_A")"

# Non-vacuity: the ordinary native row must carry all ten modules plus lmdblib
# and ipc-runtime. A table of empty rows compares equal to itself.
ROW_NATIVE_B="$(m10_table_row "$TBL_B" 00000)"
for m in $M10_ALL_TEN; do
  assert_contains "before: the ordinary native row carries $m" "$m" ",$ROW_NATIVE_B,"
done

# The mutation control. One `add_subdirectory` line deleted from a COPY of the
# patched file must move the table; otherwise "the tables agree" is a statement
# about an extractor that reads nothing.
MUT="$M10_WORK/mutant-CMakeLists.txt"
grep -v 'add_subdirectory(barretenberg/vm2)$' "$CL_AFTER" >"$MUT"
# Both of them: the AVM group's and the FUZZING_AVM block's. That is what makes
# the control move rows in two different parts of the table rather than one.
assert_eq "the mutant drops both add_subdirectory(barretenberg/vm2) lines" "2" \
  "$(( $(grep -c 'add_subdirectory(barretenberg/vm2)$' "$CL_AFTER") - $(grep -c 'add_subdirectory(barretenberg/vm2)$' "$MUT") ))"
assert_eq "and the patched file really had two of them" "2" \
  "$(grep -c 'add_subdirectory(barretenberg/vm2)$' "$CL_AFTER")"
TBL_M="$M10_WORK/truth-mutant.tsv"
m10_truth_table "$MUT" mutant >"$TBL_M"
assert_eq "the mutant table has 32 rows too" "32" "$(wc -l <"$TBL_M")"
assert_true "and the extractor SEES the deletion" \
  bash -c '! cmp -s "$1" "$2"' _ "$TBL_A" "$TBL_M"
assert_eq "the mutant loses vm2 from the ordinary native row and nothing else" \
  "vm2" "$(m10_set_diff "$(m10_table_row "$TBL_M" 00000)" "$(m10_table_row "$TBL_A" 00000)")"

# Now the comparison itself, row by row. The two rows that are allowed to differ
# are named in advance; every other row must be equal, and the differing ones
# must differ by exactly the AVM group and by nothing removed.
DIFFERING_EXPECTED="01010 01011"
differed=""
for F in 0 1; do for W in 0 1; do for L in 0 1; do for A in 0 1; do for V in 0 1; do
  k="$F$W$L$A$V"
  rb="$(m10_table_row "$TBL_B" "$k")"
  ra="$(m10_table_row "$TBL_A" "$k")"
  case " $DIFFERING_EXPECTED " in
    *" $k "*)
      assert_eq "row $k gains exactly the AVM group" "$M10_AVM_GROUP" "$(m10_set_diff "$rb" "$ra")"
      assert_eq "row $k loses nothing" "" "$(m10_set_diff "$ra" "$rb")"
      ;;
    *)
      assert_eq "row $k is unchanged by the split" "$rb" "$ra"
      ;;
  esac
  [ "$rb" = "$ra" ] || differed="$differed $k"
done; done; done; done; done
assert_eq "and the complete set of rows that move is those two" \
  "$DIFFERING_EXPECTED" "$(printf '%s' "${differed# }")"
note "the two rows that move are FUZZING=OFF WASM=ON BB_LITE=OFF AVM_WASM=ON, FUZZING_AVM either way"

# The 16 rows with AVM_WASM off, stated as its own number because that is the
# deliverable's sentence.
off_diff=0
for k in $(cut -f1 "$TBL_B"); do
  case "$k" in ???0?) [ "$(m10_table_row "$TBL_B" "$k")" = "$(m10_table_row "$TBL_A" "$k")" ] || off_diff=$((off_diff + 1)) ;; esac
done
assert_eq "with AVM_WASM OFF, not one of the sixteen assignments changes" "0" "$off_diff"

echo
echo "== B. the two presets whose whole graph can be compared here =="

# native `default`, AVM_WASM absent.
m10_native_preset_configure "$BEFORE" default "$M10_NATIVE_BUILD"; RC_NB=$?
assert_eq "the native default preset configures before the split" "0" "$RC_NB"
m10_native_preset_configure "$AFTER" default "$M10_NATIVE_BUILD"; RC_NA=$?
assert_eq "the native default preset configures after the split" "0" "$RC_NA"

for pair in "default:$M10_NATIVE_BUILD"; do
  preset="${pair%%:*}"; bdir="${pair#*:}"
  nb="$(m6_graph_nodes "$BEFORE" "$bdir")"
  na="$(m6_graph_nodes "$AFTER" "$bdir")"
  assert_ge "$preset: the before graph has thousands of nodes" 100 "$(printf '%s\n' "$nb" | wc -l)"
  m10_assert_same_lines "$preset: the target list is identical" "$nb" "$na"
  assert_eq "$preset: and so is the node count" \
    "$(printf '%s\n' "$nb" | wc -l)" "$(printf '%s\n' "$na" | wc -l)"
  eb="$(m6_graph "$BEFORE" "$bdir")"
  ea="$(m6_graph "$AFTER" "$bdir")"
  assert_ge "$preset: the before graph has edges" 100 "$(printf '%s\n' "$eb" | wc -l)"
  m10_assert_same_lines "$preset: the build graph's edges are identical" "$eb" "$ea"
done

# The compile database, structurally. `_db_compare.py` rather than a diff,
# because M6 measured what a diff says about this patch on the wasm side: 1,078
# changed lines meaning "two tokens swapped".
DBB="$(m6_compile_db "$BEFORE" "$M10_NATIVE_BUILD")"
DBA="$(m6_compile_db "$AFTER" "$M10_NATIVE_BUILD")"
assert_file "the before compile database exists" "$DBB"
assert_file "the after compile database exists" "$DBA"
CMP_NATIVE="$(python3 "$VERIFY_DIR/_db_compare.py" \
  "$DBB" "$BEFORE" "$M10_NATIVE_BUILD" "$DBA" "$AFTER" "$M10_NATIVE_BUILD")"
printf '%s\n' "$CMP_NATIVE" | sed 's/^/    /'
rows_a=$(printf '%s\n' "$CMP_NATIVE" | sed -n 's/^rows_a=//p')
rows_b=$(printf '%s\n' "$CMP_NATIVE" | sed -n 's/^rows_b=//p')
assert_ge "the native build compiles hundreds of translation units" 500 "${rows_a:-0}"
assert_eq "both sides compile the same number of them" "$rows_a" "$rows_b"
assert_eq "over the same set of files" "yes" "$(printf '%s\n' "$CMP_NATIVE" | sed -n 's/^keys_equal=//p')"
assert_eq "and not one native compile command differs" "0" \
  "$(printf '%s\n' "$CMP_NATIVE" | sed -n 's/^differing_rows=//p')"

# the `wasm` preset, with AVM_WASM off — the one place a difference is expected
# and is stated rather than rounded away.
m6_configure "$BEFORE" wasm "$M10_WASM_BUILD"; RC_WB=$?
assert_eq "the plain wasm preset configures before the split" "0" "$RC_WB"
m6_configure "$AFTER" wasm "$M10_WASM_BUILD"; RC_WA=$?
assert_eq "the plain wasm preset configures after the split" "0" "$RC_WA"
wnb="$(m6_graph_nodes "$BEFORE" "$M10_WASM_BUILD")"
wna="$(m6_graph_nodes "$AFTER" "$M10_WASM_BUILD")"
assert_ge "the wasm graph has nodes" 100 "$(printf '%s\n' "$wnb" | wc -l)"
m10_assert_same_lines "wasm: the target list is identical" "$wnb" "$wna"
assert_eq "wasm: none of the AVM group is a node on either side" "0" \
  "$( { printf '%s\n' "$wnb"; printf '%s\n' "$wna"; } | grep -cxE 'aztec|vm2_sim|world_state_reference')"

CMP_WASM="$(python3 "$VERIFY_DIR/_db_compare.py" \
  "$(m6_compile_db "$BEFORE" "$M10_WASM_BUILD")" "$BEFORE" "$M10_WASM_BUILD" \
  "$(m6_compile_db "$AFTER" "$M10_WASM_BUILD")" "$AFTER" "$M10_WASM_BUILD")"
printf '%s\n' "$CMP_WASM" | sed 's/^/    /'
w_rows=$(printf '%s\n' "$CMP_WASM" | sed -n 's/^rows_a=//p')
w_diff=$(printf '%s\n' "$CMP_WASM" | sed -n 's/^differing_rows=//p')
w_mset=$(printf '%s\n' "$CMP_WASM" | sed -n 's/^multiset_equal_rows=//p')
w_addrm=$(printf '%s\n' "$CMP_WASM" | sed -n 's/^added_or_removed=//p')
w_sigs=$(printf '%s\n' "$CMP_WASM" | grep -c '^signature ')
assert_eq "wasm: both sides compile the same set of files" "yes" \
  "$(printf '%s\n' "$CMP_WASM" | sed -n 's/^keys_equal=//p')"
assert_ge "wasm: hundreds of translation units" 400 "${w_rows:-0}"
assert_eq "wasm: EVERY command line differs — and it is a transposition, not a change" \
  "$w_rows" "$w_diff"
assert_eq "wasm: every differing row has an equal flag multiset" "$w_diff" "$w_mset"
assert_eq "wasm: not one flag is added or removed" "0" "$w_addrm"
assert_eq "wasm: and one difference signature covers all of them" "1" "$w_sigs"
note "$(printf '%s\n' "$CMP_WASM" | grep '^signature ')"

echo
echo "== C. test results, on the two suites that cover the three changed files =="

# The three source files the patch changes, re-derived from the patch rather
# than restated, so this part cannot be about the wrong files.
CHANGED="$(m6_patch_files "$M10_PATCH" | grep -E '\.(cpp|hpp)$' | sed 's|.*/src/barretenberg/||' | sort)"
assert_eq "the patch changes exactly three C++ sources" "3" "$(printf '%s\n' "$CHANGED" | wc -l)"
assert_eq "and they are the ones this part is chosen to cover" \
  "vm2/simulation/gadgets/to_radix.cpp
vm2/simulation/lib/indexed_memory_tree.hpp
world_state_reference/memory_merkle_db.hpp" "$CHANGED"

for tgt in world_state_tests vm2_tests; do
  for side in "before:$BEFORE" "after:$AFTER"; do
    label="${side%%:*}"; tree="${side#*:}"
    m6_build "$tree" "$M10_NATIVE_BUILD" "$tgt"; rc=$?
    assert_eq "$tgt builds $label the split" "0" "$rc"
    assert_eq "$tgt: no compiler diagnostic at all $label the split" "0" \
      "$(m6_build_log "$tree" "$M10_NATIVE_BUILD" | grep -c 'error:')"
    assert_file "$tgt exists $label the split" "$tree/barretenberg/cpp/$M10_NATIVE_BUILD/bin/$tgt"
  done

  bb="$BEFORE/barretenberg/cpp/$M10_NATIVE_BUILD/bin/$tgt"
  ba="$AFTER/barretenberg/cpp/$M10_NATIVE_BUILD/bin/$tgt"
  nb="$(m10_gtest_names "$bb")"
  na="$(m10_gtest_names "$ba")"
  assert_ge "$tgt declares tests before the split" 20 "$(printf '%s\n' "$nb" | wc -l)"
  m10_assert_same_lines "$tgt declares the same tests, BY NAME, after the split" "$nb" "$na"
  assert_eq "$tgt: and the same number of them" \
    "$(printf '%s\n' "$nb" | wc -l)" "$(printf '%s\n' "$na" | wc -l)"

  ob="$M10_WORK/$tgt-before.out"; eb="$M10_WORK/$tgt-before.err"
  oa="$M10_WORK/$tgt-after.out";  ea="$M10_WORK/$tgt-after.err"
  m10_gtest_run "$bb" "$ob" "$eb"; rcb=$?
  m10_gtest_run "$ba" "$oa" "$ea"; rca=$?
  assert_eq "$tgt exits 0 before the split" "0" "$rcb"
  assert_eq "$tgt exits 0 after the split" "0" "$rca"
  ranb="$(m10_gtest_ran "$ob")"; rana="$(m10_gtest_ran "$oa")"
  assert_ge "$tgt actually ran tests before the split" 20 "${ranb:-0}"
  assert_eq "$tgt runs the same number after the split" "$ranb" "$rana"
  pb="$(m10_gtest_passed "$ob")"; pa="$(m10_gtest_passed "$oa")"
  assert_ge "$tgt passed tests before the split" 20 "$(printf '%s\n' "$pb" | wc -l)"
  m10_assert_same_lines "$tgt: the set of tests that PASS is identical by name" "$pb" "$pa"
  note "$tgt: $ranb ran, $(printf '%s\n' "$pb" | wc -l) passed, identical name sets"
done

finish
