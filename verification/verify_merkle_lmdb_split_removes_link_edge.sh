#!/usr/bin/env bash
# verify_merkle_lmdb_split_removes_link_edge
#
# The deliverable: after the split, `crypto_merkle_tree` has no `lmdblib` link
# dependency, and a consumer that needs only the tree algorithms links no LMDB
# object.
#
# Checked three ways, from weakest to strongest evidence:
#
#   1. The CMakeLists text — `barretenberg_module(crypto_merkle_tree lmdblib)`
#      becomes `barretenberg_module(crypto_merkle_tree ecc)`, and the new
#      `crypto_merkle_tree_lmdb` module takes the `lmdblib` dependency.
#   2. CMake's OWN target dependency graph (`cmake --graphviz`) for each
#      configured build tree. This is the build system's answer rather than our
#      reading of the source: the *complete set* of targets with an edge to
#      `lmdblib` is compared before and after, so a new coupling smuggled in
#      elsewhere fails the check too.
#   3. The linked binaries. `crypto_merkle_tree_tests` after the split is
#      exactly "a consumer needing only the tree algorithms": before, its
#      executable contains LMDB's object code (`mdb_env_create` and friends);
#      after, it contains none, and the code has moved into
#      `crypto_merkle_tree_lmdb_tests`.
#
# It also asserts what the patch does NOT do, so this check cannot be read as
# claiming more than was measured:
#
#   * `src/CMakeLists.txt` adds `${LMDB_INCLUDE}` to a directory-scope
#     `include_directories()`, so `-I<lmdb>` is on EVERY translation unit's
#     command line both before and after. The patch removes the link edge and
#     the `#include` chain, not that global `-I`. That line is asserted to be
#     byte-identical in the two trees.
#   * `libvm2_sim.a` and `libworld_state_reference.a` contain zero undefined
#     `mdb_*` references before the patch as well as after. The edge that is
#     removed is a link-interface and compile-time-header edge, not emitted
#     symbol references, and this check asserts that reading rather than
#     implying a stronger one.
#
# Run: just verify-merkle-link-edge

TEST_NAME="verify_merkle_lmdb_split_removes_link_edge"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_merkle_lmdb.sh"

command -v nm >/dev/null 2>&1 || die "nm is required to read the linked binaries"

m3_prepare_trees
# Both trees must be configured and built for (2) and (3). m3_measured runs the
# neutrality check if that has not happened yet; it never fabricates a result.
m3_measured
assert_eq "the recorded before-build exited 0" 0 "${M3_BUILD_RC_BASE:--}"
assert_eq "the recorded after-build exited 0"  0 "${M3_BUILD_RC_PATCHED:--}"

SRC_BASE="$M3_WORK/base/barretenberg/cpp/src/barretenberg"
SRC_PATCHED="$M3_WORK/patched/barretenberg/cpp/src/barretenberg"
BB="$M3_WORK/base/barretenberg/cpp/build-native"
BP="$M3_WORK/patched/barretenberg/cpp/build-native"

# ---------------------------------------------------------------------------
# 1. The declaration
# ---------------------------------------------------------------------------
decl_before="$(cat "$SRC_BASE/crypto/merkle_tree/CMakeLists.txt" 2>/dev/null)"
decl_after="$(cat "$SRC_PATCHED/crypto/merkle_tree/CMakeLists.txt" 2>/dev/null)"
decl_lmdb="$(cat "$SRC_PATCHED/crypto/merkle_tree_lmdb/CMakeLists.txt" 2>/dev/null)"

assert_contains "before: crypto_merkle_tree declares a dependency on lmdblib" \
  "lmdblib" "$decl_before"
assert_not_contains "after: crypto_merkle_tree declares no dependency on lmdblib" \
  "lmdblib" "$decl_after"
assert_contains "after: crypto_merkle_tree depends on ecc instead" "ecc" "$decl_after"
assert_contains "after: the new module is crypto_merkle_tree_lmdb" \
  "crypto_merkle_tree_lmdb" "$decl_lmdb"
assert_contains "after: crypto_merkle_tree_lmdb is the one that takes lmdblib" \
  "lmdblib" "$decl_lmdb"

# ---------------------------------------------------------------------------
# 2. CMake's own dependency graph
# ---------------------------------------------------------------------------
graph_before="$(m3_graph "$M3_WORK/base")"    || fail "cmake --graphviz failed on the base tree"
graph_after="$(m3_graph "$M3_WORK/patched")"  || fail "cmake --graphviz failed on the patched tree"

assert_ge "the base dependency graph was produced and is non-trivial" 100 \
  "$(printf '%s\n' "$graph_before" | grep -c . )"
assert_ge "the patched dependency graph was produced and is non-trivial" 100 \
  "$(printf '%s\n' "$graph_after" | grep -c . )"

edges_to_lmdblib() { printf '%s\n' "$1" | grep -E ' -> lmdblib$' | sed 's| -> lmdblib||' | sort -u | tr '\n' ' '; }

before_lmdb_users="$(edges_to_lmdblib "$graph_before")"
after_lmdb_users="$(edges_to_lmdblib "$graph_after")"

# The complete set on each side, asserted exactly. Pinning the whole set is what
# makes this resistant to a coupling reappearing somewhere else.
assert_eq "before: exactly these targets link lmdblib" \
  "crypto_merkle_tree crypto_merkle_tree_tests lmdblib_tests nodejs_module " \
  "$before_lmdb_users"
assert_eq "after: exactly these targets link lmdblib" \
  "crypto_merkle_tree_lmdb crypto_merkle_tree_lmdb_tests lmdblib_tests nodejs_module " \
  "$after_lmdb_users"

# Exact-line matching, so "crypto_merkle_tree -> lmdblib" can never be satisfied
# by "crypto_merkle_tree_lmdb -> lmdblib".
edge_before() { printf '%s\n' "$graph_before" | grep -qxF "$1"; }
edge_after()  { printf '%s\n' "$graph_after"  | grep -qxF "$1"; }

assert_true  "before: the graph carries [crypto_merkle_tree -> lmdblib]" \
  edge_before "crypto_merkle_tree -> lmdblib"
assert_false "after:  [crypto_merkle_tree -> lmdblib] is gone" \
  edge_after "crypto_merkle_tree -> lmdblib"
assert_true  "after:  the LMDB dependency moved to [crypto_merkle_tree_lmdb -> lmdblib]" \
  edge_after "crypto_merkle_tree_lmdb -> lmdblib"

# The consumers named in the deliverable keep their dependency on the tree
# vocabulary on both sides — the split changed what is *underneath* them, not
# what they ask for.
for consumer in vm2_sim world_state_reference aztec world_state; do
  assert_true "before: [$consumer -> crypto_merkle_tree]" \
    edge_before "$consumer -> crypto_merkle_tree"
  assert_true "after:  [$consumer -> crypto_merkle_tree]" \
    edge_after "$consumer -> crypto_merkle_tree"
done
# world_state genuinely needs the store, and says so explicitly after the split.
assert_true  "after: world_state takes an explicit crypto_merkle_tree_lmdb dependency" \
  edge_after "world_state -> crypto_merkle_tree_lmdb"
assert_false "after: vm2_sim does not depend on crypto_merkle_tree_lmdb" \
  edge_after "vm2_sim -> crypto_merkle_tree_lmdb"
assert_false "after: world_state_reference does not depend on crypto_merkle_tree_lmdb" \
  edge_after "world_state_reference -> crypto_merkle_tree_lmdb"

# ---------------------------------------------------------------------------
# 3. The linked binaries — "links no LMDB object"
# ---------------------------------------------------------------------------
mdb_syms() { nm -C "$1" 2>/dev/null | grep -c ' mdb_' ; }
# Note: no `grep -q` in a pipe from nm — lib.sh sets `pipefail`, and grep -q's
# early exit makes nm die of SIGPIPE, which would fail the pipeline whatever the
# symbol table says.
has_sym() {
  local out; out="$(nm -C "$1" 2>/dev/null)"
  case "$out" in *" T mdb_env_create"*) return 0 ;; esac
  return 1
}

n_before="$(mdb_syms "$BB/bin/crypto_merkle_tree_tests")"
n_after="$(mdb_syms "$BP/bin/crypto_merkle_tree_tests")"
n_after_lmdb="$(mdb_syms "$BP/bin/crypto_merkle_tree_lmdb_tests")"

assert_ge "before: crypto_merkle_tree_tests contains LMDB object code" 1 "$n_before"
assert_true "before: it defines mdb_env_create" has_sym "$BB/bin/crypto_merkle_tree_tests"
assert_eq "after: crypto_merkle_tree_tests contains NO LMDB object code" 0 "$n_after"
assert_false "after: it does not define mdb_env_create" has_sym "$BP/bin/crypto_merkle_tree_tests"
assert_eq "after: the LMDB object code is in crypto_merkle_tree_lmdb_tests instead" \
  "$n_before" "$n_after_lmdb"
assert_true "after: crypto_merkle_tree_lmdb_tests defines mdb_env_create" \
  has_sym "$BP/bin/crypto_merkle_tree_lmdb_tests"

# ---------------------------------------------------------------------------
# 4. What the patch does NOT do — asserted, so the claim cannot inflate
# ---------------------------------------------------------------------------
inc_before="$(grep -n 'LMDB_INCLUDE' "$M3_WORK/base/barretenberg/cpp/src/CMakeLists.txt")"
inc_after="$(grep -n 'LMDB_INCLUDE' "$M3_WORK/patched/barretenberg/cpp/src/CMakeLists.txt")"
assert_contains "the LMDB include dir is added by a global include_directories() before" \
  "include_directories" "$inc_before"
assert_eq "the patch leaves that global include_directories() line untouched" \
  "$inc_before" "$inc_after"

undef_mdb() { nm -u "$1" 2>/dev/null | grep -c 'mdb_' ; }
for lib in libvm2_sim.a libworld_state_reference.a; do
  assert_eq "before: $lib has no undefined mdb_* references (the edge was never symbolic)" \
    0 "$(undef_mdb "$BB/lib/$lib")"
  assert_eq "after:  $lib has no undefined mdb_* references" \
    0 "$(undef_mdb "$BP/lib/$lib")"
done

finish
