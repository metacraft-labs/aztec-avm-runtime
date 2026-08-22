#!/usr/bin/env bash
# verify_wasm_link_closure_excludes_proving — the AVM's link closure contains the
# simulator, the in-memory world state and the primitives they need, and no part
# of the proving stack.
#
# MEASURED TWO INDEPENDENT WAYS, BECAUSE EITHER ALONE IS A DIFFERENT CLAIM
#
#   1. CMake's OWN target graph, regenerated from the configured build tree, and
#      the transitive closure of `vm2_sim` through it. This is the build system's
#      model of what links what.
#   2. What ninja ACTUALLY produced. `vm2_sim` and `world_state_reference` are
#      built in a build directory that is removed and reconfigured first, so the
#      set of archives on disk afterwards is exactly ninja's own answer to the
#      same question. A stale archive from an earlier, larger build cannot leak
#      in, which is the hazard this construction exists to remove.
#
# AND THE ABSENCE IS NOT VACUOUS. The `wasm-avm` preset inherits `wasm`, which
# configures the entire proving stack for `barretenberg.wasm`. So `honk`,
# `polynomials`, `srs`, `flavor`, `stdlib_circuit_builders`, `sumcheck`,
# `commitment_schemes`, `stdlib_honk_verifier`, `goblin_avm` and `ultra_honk` are
# all real static-library targets IN THIS VERY BUILD TREE. Each is asserted to
# exist there, and then asserted absent from vm2_sim's closure. "No honk archive"
# is therefore a statement about reachability, not about a name nobody defined.
#
# The symbol-level statement is made separately from the target-level one:
# `llvm-nm -u` over both archives reports zero undefined `mdb_*` and zero
# undefined proving-stack symbols, so the dependency list holds at link time and
# not only in CMake.

set -uo pipefail

TEST_NAME=verify_wasm_link_closure_excludes_proving
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_avm_wasm.sh"

require_nix
m6_prepare_trees
m6_measured   # runs verify_avm_wasm_build if there is no record; never invents one

BDIR=build-wasm-avm
CPP="$M6_TREE_AVM/barretenberg/cpp"
assert_file "the AVM_WASM build tree is configured" "$CPP/$BDIR/CMakeCache.txt"
assert_eq "and it is the AVM_WASM configuration" "ON" "$(m6_cache "$M6_TREE_AVM" "$BDIR" AVM_WASM)"

# ---------------------------------------------------------------------------
# 1. CMake's own graph.
# ---------------------------------------------------------------------------
m6_graph "$M6_TREE_AVM" "$BDIR" >/dev/null
GRAPH="$(m6_graph_edges_file "$M6_TREE_AVM" "$BDIR")"
assert_ge "CMake's target graph was regenerated from the configured tree" 500 "$(grep -c . "$GRAPH")"

CLOSURE="$(m6_graph_closure "$GRAPH" vm2_sim | tr '\n' ' ' | sed 's/ $//')"
assert_eq "vm2_sim's transitive closure is exactly the AVM set" "$M6_EXPECTED_CLOSURE" "$CLOSURE"

# The six the milestone names, plus the three crypto archives, called out
# individually so a reader can see them without parsing the identity above.
for t in vm2_sim world_state_reference ecc common numeric \
         crypto_poseidon2 crypto_sha256 crypto_keccak; do
  assert_contains "the closure contains $t" " $t " " $CLOSURE "
done
assert_contains "and crypto_merkle_tree, taken through M3's module rather than a stand-in" \
  " crypto_merkle_tree " " $CLOSURE "

# world_state_reference's own closure, so "the in-memory world state is in the
# artefact" is a statement about it and not only about vm2_sim dragging it in.
WSR_CLOSURE="$(m6_graph_closure "$GRAPH" world_state_reference | tr '\n' ' ' | sed 's/ $//')"
assert_eq "world_state_reference's closure is the trees and their hashes, nothing more" \
  "aztec common common_objects crypto_keccak crypto_keccak_objects crypto_merkle_tree crypto_poseidon2 crypto_poseidon2_objects crypto_sha256 crypto_sha256_objects ecc ecc_objects env env_objects libdeflate_static nlohmann_json numeric numeric_objects world_state_reference world_state_reference_objects" \
  "$WSR_CLOSURE"

# ---------------------------------------------------------------------------
# The absence, with its non-vacuity established first.
# ---------------------------------------------------------------------------
for m in $M6_FORBIDDEN_MODULES; do
  assert_eq "$m IS a static-library target in this very build tree" \
    "octagon" "$(m6_graph_shape "$M6_TREE_AVM" "$BDIR" "$m")"
  assert_not_contains "and it is not in vm2_sim's closure" " $m " " $CLOSURE "
done
assert_eq "no LMDB target is in the closure either" \
  "0" "$(printf '%s\n' $CLOSURE | grep -cE '^(lmdblib|crypto_merkle_tree_lmdb)$')"
assert_eq "and no server module (world_state, ipc, wsdb, cdb, nodejs_module)" \
  "0" "$(printf '%s\n' $CLOSURE | grep -cE '^(world_state|ipc|wsdb|vm2_wsdb|cdb|nodejs_module)$')"

# The server modules are not merely out of the closure: the AVM_WASM build never
# ADDS them. `src/CMakeLists.txt` puts them behind `NOT WASM`, which the option
# does not widen, so they are not targets in this configuration at all. `ipc`
# survives as a septagon — an UNKNOWN library some other target names — and that
# is stated rather than smoothed over, because "absent" and "present but not
# built" are different facts.
NODES="$(m6_graph_nodes "$M6_TREE_AVM" "$BDIR")"
for m in world_state wsdb vm2_wsdb cdb nodejs_module; do
  assert_eq "$m is not a node in the AVM_WASM build's graph at all" \
    "" "$(m6_graph_shape "$M6_TREE_AVM" "$BDIR" "$m")"
done
assert_eq "ipc is a node, but only as an UNKNOWN library nothing in the closure reaches" \
  "septagon" "$(m6_graph_shape "$M6_TREE_AVM" "$BDIR" ipc)"
# And the three the milestone says the build DOES add.
for m in aztec world_state_reference vm2_sim; do
  assert_contains "the build adds $m" "
$m" "
$NODES"
done

# ---------------------------------------------------------------------------
# 2. What ninja actually produced, from a build directory made fresh first.
# ---------------------------------------------------------------------------
m6_configure "$M6_TREE_AVM" wasm-avm build-closure
assert_eq "a fresh AVM_WASM build directory configures" "0" "$?"
assert_eq "and starts with no archives at all" "" "$(m6_archives "$M6_TREE_AVM" build-closure)"
m6_build "$M6_TREE_AVM" build-closure vm2_sim world_state_reference
BRC=$?
assert_eq "ninja builds the two targets and exits 0" "0" "$BRC"
assert_eq "and everything it had to build is exactly the nine archives" \
  "$M6_EXPECTED_ARCHIVES" "$(m6_archives "$M6_TREE_AVM" build-closure)"
assert_eq "no proving-stack archive was needed" \
  "0" "$(m6_archives "$M6_TREE_AVM" build-closure | tr ' ' '\n' \
          | grep -cE '^lib(honk|polynomials|srs|flavor|stdlib_circuit_builders|sumcheck|commitment_schemes|stdlib_honk_verifier|goblin_avm|ultra_honk)\.a$')"
assert_eq "and no barretenberg.wasm or bb executable was produced" \
  "0" "$(find "$CPP/build-closure/bin" -type f 2>/dev/null | wc -l)"

# ---------------------------------------------------------------------------
# The same claim at symbol level.
# ---------------------------------------------------------------------------
nm_u() { m6_in_devshell '"$WASI_SDK_PREFIX/bin/llvm-nm" -u "$1" 2>/dev/null' "$1"; }
demangled_u() {
  m6_in_devshell '"$WASI_SDK_PREFIX/bin/llvm-nm" -u "$1" 2>/dev/null | sed "s/^ *U //" | "$WASI_SDK_PREFIX/bin/llvm-cxxfilt"' "$1"
}

for a in libvm2_sim.a libworld_state_reference.a; do
  P="$CPP/build-closure/lib/$a"
  assert_file "$a is on disk" "$P"
  U="$(nm_u "$P")"
  assert_ge "$a has undefined symbols to report on (it is a real archive)" 50 \
    "$(printf '%s\n' "$U" | grep -c .)"
  assert_eq "$a has zero undefined mdb_* references" "0" \
    "$(printf '%s\n' "$U" | grep -c 'mdb_')"
  D="$(demangled_u "$P")"
  assert_eq "$a references no proving-stack symbol" "0" \
    "$(printf '%s\n' "$D" | grep -icE 'honk|sumcheck|Polynomial<|srs::|CircuitBuilder|Goblin')"
done

# Real C++ exceptions really are in the artefact. Under -fno-exceptions and the
# BB_NO_EXCEPTIONS shim this count is zero, which is the whole reason the
# AVM_WASM arm of arch.cmake exists.
CXA="$(nm_u "$CPP/build-closure/lib/libvm2_sim.a" | grep -c '__cxa_throw')"
assert_ge "libvm2_sim.a carries real __cxa_throw references, so throw-to-revert survives" 1 "$CXA"
note "libvm2_sim.a: $CXA undefined __cxa_throw references"

rm -rf "$CPP/build-closure"

finish
