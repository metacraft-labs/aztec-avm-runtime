#!/usr/bin/env bash
# verify_wasm_build_uses_module_split_not_hack — the wasm build takes its
# merkle-tree dependency through M3's real module split, and contains no
# header-only `crypto_merkle_tree` variant and no stray `lmdb.h` on the include
# path.
#
# WHAT THE HACK WAS, EXACTLY
#
# The vm2-wasm spike got the same green wasm build three ways it should not
# have, and its own log calls the first of them "a spike hack, and the shape
# most likely to rot":
#
#   1. `crypto/merkle_tree/CMakeLists.txt` grew a `if(WASM AND AVM_WASM)` arm
#      declaring `barretenberg_module_with_sources(crypto_merkle_tree
#      DEPENDENCIES ecc numeric)` — the module's one non-test .cpp dropped, so
#      the lmdblib link edge vanishes.
#   2. `cpp/CMakeLists.txt` set `LMDB_INCLUDE` to a `shims/` directory holding a
#      copy of the stock `lmdb.h`, so `crypto/merkle_tree/types.hpp` could keep
#      including it. A duplicated third-party header, invisible in the
#      CMakeLists, going stale silently when the vendored LMDB revision moves.
#   3. `src/CMakeLists.txt` added `add_compile_options(-Wno-error)` under
#      AVM_WASM, so the four 32-bit narrowings became warnings instead of being
#      fixed.
#
# HOW THIS CHECK ESTABLISHES THEIR ABSENCE
#
# Not by grepping for three strings in one tree — that passes for any tree,
# including one where the hack was spelled differently. Every predicate is run
# against TWO trees: the AVM_WASM tree, where it must be FALSE, and a worktree
# of the spike's own `spike.patch`, where it must be TRUE. A predicate that
# cannot find the hack in the tree that has it is not evidence about the tree
# that does not.
#
# The positive half is asserted too, because "the hack is absent" is satisfied
# by a build that has no merkle tree at all: `crypto_merkle_tree` must be in
# vm2_sim's closure, as CMake's INTERFACE library, with the module's own
# CMakeLists byte-identical to what M3's split produces and untouched by this
# milestone's patch.

set -uo pipefail

TEST_NAME=verify_wasm_build_uses_module_split_not_hack
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_avm_wasm.sh"

require_nix
m6_prepare_trees
m6_prepare_spike_tree
m6_measured

AVM_CPP="$M6_TREE_AVM/barretenberg/cpp"
SPIKE_CPP="$M6_TREE_SPIKE/barretenberg/cpp"

# THE SCOPE OF EVERYTHING BELOW, ASSERTED BEFORE IT IS USED. Three of the
# absence claims in this file are read out of `build-wasm-avm`, which this check
# does NOT produce — verify_avm_wasm_build does, and m6_measured re-runs it only
# when there is no record. A `grep -c` over an archive that is not there is 0, a
# `find` over a directory that is not there is 0, and both assertions would then
# pass against a build tree holding nothing. That is the same defect as the
# ungenerated `targets.dot`, in the same file, so the artefacts are pinned here
# first and the absence claims below are statements about a build that exists.
assert_file "the AVM_WASM build tree is configured" "$AVM_CPP/build-wasm-avm/CMakeCache.txt"
assert_eq "and it holds exactly the nine archives whose contents this check reads" \
  "$M6_EXPECTED_ARCHIVES" "$(m6_archives "$M6_TREE_AVM" build-wasm-avm)"
for a in libvm2_sim.a libworld_state_reference.a; do
  assert_file "$a is on disk to be read" "$AVM_CPP/build-wasm-avm/lib/$a"
done

assert_file "the spike's own change set is committed in this repo" "$M6_SPIKE_PATCH"
assert_eq "the spike control tree is the base commit plus exactly it" \
  "1" "$(git -C "$M6_TREE_SPIKE" rev-list --count "$M6_BASE_REV..HEAD")"
assert_contains "and it is the vm2-wasm spike" "spike: vm2_sim compiled and executed on wasm32-wasip1" \
  "$(git -C "$M6_TREE_SPIKE" log -1 --format=%s)"

# ---------------------------------------------------------------------------
# HACK 1 — the header-only crypto_merkle_tree variant.
# ---------------------------------------------------------------------------
MT_AVM="$AVM_CPP/src/barretenberg/crypto/merkle_tree/CMakeLists.txt"
MT_SPIKE="$SPIKE_CPP/src/barretenberg/crypto/merkle_tree/CMakeLists.txt"
assert_eq "the spike declares a sources-dropped crypto_merkle_tree module" \
  "1" "$(grep -c 'barretenberg_module_with_sources(crypto_merkle_tree' "$MT_SPIKE")"
assert_eq "the AVM_WASM tree declares none" \
  "0" "$(grep -c 'barretenberg_module_with_sources(crypto_merkle_tree' "$MT_AVM")"
assert_eq "the spike's merkle_tree CMakeLists branches on AVM_WASM at all" \
  "1" "$(grep -c 'AVM_WASM' "$MT_SPIKE")"
assert_eq "the AVM_WASM tree's does not — the module is the same one native builds use" \
  "0" "$(grep -c 'AVM_WASM' "$MT_AVM")"

# And it is M3's module, unmodified by this milestone. Read from the patch files
# so the statement is about the artefacts that would be filed.
assert_eq "M3's patch is what creates the split module" \
  "1" "$(m6_patch_files "$M6_PATCH_1" | grep -c 'crypto/merkle_tree/CMakeLists.txt')"
assert_eq "and patch 4 does not touch that file at all" \
  "0" "$(m6_patch_files "$M6_PATCH_4" | grep -c 'crypto/merkle_tree/CMakeLists.txt')"
assert_eq "the module's CMakeLists in the AVM_WASM tree is exactly M3's" \
  "$(git -C "$M6_TREE_AVM" rev-parse "$(git -C "$M6_TREE_AVM" log --format=%H --reverse "$M6_BASE_REV..HEAD" | head -1):barretenberg/cpp/src/barretenberg/crypto/merkle_tree/CMakeLists.txt")" \
  "$(git -C "$M6_TREE_AVM" rev-parse "HEAD:barretenberg/cpp/src/barretenberg/crypto/merkle_tree/CMakeLists.txt")"

# What patch 4 DOES do about the module: one condition, in crypto/CMakeLists.txt.
CRYPTO_ADDED="$(m6_patch_added "$M6_PATCH_4" 'crypto/CMakeLists.txt')"
assert_contains "patch 4 admits crypto_merkle_tree to wasm by widening one condition" \
  "if (NOT WASM OR AVM_WASM)" "$CRYPTO_ADDED"
assert_contains "and leaves the LMDB half native-only" "if (NOT WASM)" "$CRYPTO_ADDED"
# What that condition does and does not do, from CMake's regenerated graph. Two
# different facts, kept apart because the cold run showed that lumping them
# together was wrong:
#   * `crypto_merkle_tree_lmdb` -- M3's LMDB half -- is a SEPTAGON here, cmake's
#     shape for UNKNOWN_LIBRARY: a name two bench targets link against that is
#     not a target in this configuration. The module directory is not added.
#   * `lmdblib` IS a real static-library target in a wasm configure. That is
#     upstream's doing, not this option's: `src/CMakeLists.txt` guards it with
#     `if(NOT BB_LITE)` and not with `NOT WASM`, and this patch adds and removes
#     no line mentioning it. It is not in vm2_sim's closure and is never built --
#     no `liblmdblib.a` is among the nine archives.
# The earlier version of this check asserted both were absent, and PASSED, because
# the graph had not been generated yet and a grep over a missing file counts 0.
# The accessors now die instead.
assert_eq "crypto_merkle_tree_lmdb is not a target in the AVM_WASM build" \
  "septagon" "$(m6_graph_shape "$M6_TREE_AVM" build-wasm-avm crypto_merkle_tree_lmdb)"
assert_eq "lmdblib is one -- upstream guards it with NOT BB_LITE, not NOT WASM" \
  "octagon" "$(m6_graph_shape "$M6_TREE_AVM" build-wasm-avm lmdblib)"
assert_eq "and this patch adds no line mentioning it" \
  "0" "$(m6_patch_added "$M6_PATCH_4" | grep -c 'lmdblib')"
assert_eq "nor removes one" \
  "0" "$(m6_patch_removed "$M6_PATCH_4" | grep -c 'lmdblib')"
assert_eq "neither LMDB archive is ever produced by the AVM_WASM build" \
  "0" "$(m6_archives "$M6_TREE_AVM" build-wasm-avm | tr ' ' '\n' \
          | grep -cE '^lib(lmdblib|crypto_merkle_tree_lmdb)\.a$')"

# ---------------------------------------------------------------------------
# HACK 2 — the stray lmdb.h.
# ---------------------------------------------------------------------------
assert_eq "the spike puts a shims/ directory on LMDB_INCLUDE" \
  "1" "$(grep -c 'set(LMDB_INCLUDE .*shims' "$SPIKE_CPP/CMakeLists.txt")"
assert_eq "the AVM_WASM tree does not" \
  "0" "$(grep -c 'set(LMDB_INCLUDE' "$AVM_CPP/CMakeLists.txt")"
assert_eq "and patch 4 adds no LMDB_INCLUDE line anywhere" \
  "0" "$(m6_patch_added "$M6_PATCH_4" | grep -c 'LMDB_INCLUDE')"
assert_false "there is no shims/ directory in the fork worktree" test -d "$M6_TREE_AVM/shims"
assert_false "and none beside barretenberg/cpp" test -d "$AVM_CPP/../../shims"

# The measurement that matters: the build's OWN record of every -I it passed.
# In a native build M3 measured `-I<lmdb>` on 77 of 77 vm2 units before AND
# after the split, because a directory-scope include_directories() puts it
# there either way. In the wasm build it is not there at all, because
# cmake/lmdb.cmake is guarded off under WASM — so this is a stronger statement
# than M3's, and it is made from compile_commands.json rather than from CMake.
INCLUDES="$(m6_include_dirs "$M6_TREE_AVM" build-wasm-avm)"
NINC="$(printf '%s\n' "$INCLUDES" | grep -c .)"
assert_ge "the build passes -I directories to assert about" 5 "$NINC"
LMDB_DIRS=""
while IFS= read -r d; do
  [ -n "$d" ] || continue
  [ -f "$d/lmdb.h" ] && LMDB_DIRS="$LMDB_DIRS $d"
done <<<"$INCLUDES"
assert_eq "not one of the $NINC include directories contains an lmdb.h" "" "${LMDB_DIRS# }"
assert_eq "no include directory is named for lmdb either" \
  "0" "$(printf '%s\n' "$INCLUDES" | grep -ci 'lmdb')"
assert_eq "and no lmdb.h exists anywhere under the wasm build tree" \
  "0" "$(find "$AVM_CPP/build-wasm-avm" -name lmdb.h 2>/dev/null | wc -l)"
# Nor anywhere in the fork worktree except where FetchContent puts it. This used
# to exclude by BUILD-DIRECTORY NAME (`*/build-native*/*`), which made it a
# statement about how the directories happen to be called: M10 added
# `build-m10-native` and `build-m10-fuzzing-avm` and the assertion went red on two
# FetchContent copies that are exactly what it meant to allow. It now excludes by
# what the path IS — a `_deps` subtree — and the exclusion is MEASURED rather than
# assumed: the search must find some lmdb.h at all, and every one it finds must be
# under a `_deps`, so nothing is being waved through and nothing is inert.
LMDB_ALL="$(find "$M6_TREE_AVM" -name lmdb.h 2>/dev/null | sort)"
LMDB_N=$(printf '%s\n' "$LMDB_ALL" | grep -c . || true)
LMDB_DEPS=$(printf '%s\n' "$LMDB_ALL" | grep -c '/_deps/' || true)
assert_ge "the lmdb.h search is not inert — FetchContent has fetched one somewhere" 1 "$LMDB_N"
assert_eq "and every lmdb.h in the worktree is a FetchContent copy under a build tree's _deps" \
  "$LMDB_N" "$LMDB_DEPS"
assert_eq "so none is in the fork's own sources" "0" "$((LMDB_N - LMDB_DEPS))"

# The consequence, at symbol level.
for a in libvm2_sim.a libworld_state_reference.a; do
  assert_eq "$a has zero undefined mdb_* references" \
    "0" "$(m6_undefined_mdb "$M6_TREE_AVM" build-wasm-avm "$a")"
done

# ---------------------------------------------------------------------------
# HACK 3 — -Wno-error. The spike demoted the four narrowings; M6 fixes them.
# ---------------------------------------------------------------------------
assert_eq "the spike adds an add_compile_options(-Wno-error) under AVM_WASM" \
  "1" "$(grep -c '^ *add_compile_options(-Wno-error)' "$SPIKE_CPP/src/CMakeLists.txt")"
assert_eq "the AVM_WASM tree adds none" \
  "0" "$(grep -c '^ *add_compile_options(-Wno-error)' "$AVM_CPP/src/CMakeLists.txt")"
assert_eq "and patch 4 adds no -Wno-error line at all" \
  "0" "$(m6_patch_added "$M6_PATCH_4" | grep -c 'Wno-error')"
assert_eq "measured from the build's own command lines: zero units carry -Wno-error" \
  "0" "$(m6_flag_tu_count "$M6_TREE_AVM" build-wasm-avm -Wno-error all)"
TU_OWN="$(m6_own_tu_count "$M6_TREE_AVM" build-wasm-avm)"
assert_eq "and all $TU_OWN of barretenberg's own carry -Werror" \
  "$TU_OWN" "$(m6_flag_tu_count "$M6_TREE_AVM" build-wasm-avm -Werror own)"
assert_eq "the spike's src/CMakeLists.txt differs from the AVM_WASM tree's" \
  "yes" "$([ "$(md5sum <"$SPIKE_CPP/src/CMakeLists.txt" | cut -d' ' -f1)" \
           != "$(md5sum <"$AVM_CPP/src/CMakeLists.txt" | cut -d' ' -f1)" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# THE POSITIVE HALF. "The hack is absent" is also true of a build with no merkle
# tree in it, so the module must be shown to be there, as what M3 made it.
# ---------------------------------------------------------------------------
GRAPH="$(m6_graph_edges_file "$M6_TREE_AVM" build-wasm-avm)"
CLOSURE="$(m6_graph_closure "$GRAPH" vm2_sim | tr '\n' ' ' | sed 's/ $//')"
assert_contains "crypto_merkle_tree is in vm2_sim's link closure" " crypto_merkle_tree " " $CLOSURE "
assert_eq "as CMake's INTERFACE library, which is what M3's split makes it" \
  "pentagon" "$(m6_graph_shape "$M6_TREE_AVM" build-wasm-avm crypto_merkle_tree)"
assert_contains "and so is aztec, the header-only module that binds the hash policies" \
  " aztec " " $CLOSURE "

# The five merkle_tree headers vm2_sim and world_state_reference actually use,
# re-derived from the tree rather than quoted from M3's write-up. If a sixth
# appears, the split's scope has moved and this milestone should know.
MT_HEADERS="$(grep -rhoE '#include "barretenberg/crypto/merkle_tree/[^"]+"' \
  "$AVM_CPP/src/barretenberg/vm2" "$AVM_CPP/src/barretenberg/world_state_reference" 2>/dev/null \
  | sed 's|.*merkle_tree/||; s|"$||' | sort -u | tr '\n' ' ' | sed 's/ $//')"
assert_eq "vm2 and world_state_reference use exactly M3's five merkle_tree headers" \
  "hash_path.hpp indexed_tree/indexed_leaf.hpp memory_tree.hpp response.hpp types.hpp" \
  "$MT_HEADERS"

finish
