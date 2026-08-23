#!/usr/bin/env bash
# verify_cmake_split_enables_wasm_avm — M10
#
# The claim: with AVM_WASM on, the AVM group configures for wasm and the server
# group is excluded, with no server module reachable in the link closure.
#
# M6 established the closure against the PROVING stack. This is the other half
# and the one the split is actually about: the seven SERVER modules that shared
# the guard with the AVM's three. Four ways, because each is blind to something
# the next catches:
#
#   1. The build's own compile database. Not one translation unit under any of
#      the seven server modules' directories, and hundreds under the AVM group's
#      — which is the difference between "excluded" and "nothing was built at all".
#   2. CMake's own regenerated target graph, per module, WITH ITS SHAPE. Six of
#      the seven are not nodes at all; `ipc` survives as a `septagon` — cmake's
#      vocabulary for UNKNOWN_LIBRARY, a name some other target links against
#      that nothing here defines — and that is recorded rather than smoothed
#      over, because "absent" and "present but not built" are different facts.
#   3. `vm2_sim`'s transitive closure in that graph, pinned as an identity.
#   4. What ninja actually produced: the nine archives, as an identity, and no
#      archive belonging to any server module.
#
# THE ABSENCE IS NOT VACUOUS, and that is asserted rather than assumed: every one
# of the seven is required to be a real target in a native `default` configure of
# THE SAME TREE before its absence from the wasm one is claimed. A check that
# reports the absence of a name nobody ever defines is the vacuous version of
# this, and this campaign has shipped it once already.
#
# The build directory is removed and reconfigured by this check, so nothing it
# reads is state it did not produce.

TEST_NAME=verify_cmake_split_enables_wasm_avm
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/lib_avm_wasm.sh"
. "$(dirname "$0")/lib_m10_cmake_split.sh"

M10_SERVER_NATIVE_BUILD=build-m10-native-servercheck

m6_prepare_trees
TREE="$M6_TREE_AVM"

echo "== 0. the wasm-avm build, made here =="
assert_dir "the tree under test is prepared" "$TREE"
m6_configure "$TREE" wasm-avm "$M10_AVM_BUILD"; RC=$?
assert_eq "cmake --preset wasm-avm configures" "0" "$RC"
assert_contains "and the exceptions probe ran and passed" \
  "wasm C++ exceptions probe passed" "$(m6_log "$TREE" "$M10_AVM_BUILD")"
assert_eq "it is cross-compiling for wasm32" "wasm32" "$(m6_system_processor "$TREE" "$M10_AVM_BUILD")"
assert_eq "with AVM_WASM on" "ON" "$(m6_cache "$TREE" "$M10_AVM_BUILD" AVM_WASM)"

m6_build "$TREE" "$M10_AVM_BUILD" vm2_sim world_state_reference; RC=$?
assert_eq "ninja vm2_sim world_state_reference exits 0" "0" "$RC"
assert_eq "and nothing emitted a compiler diagnostic" "0" \
  "$(m6_build_log "$TREE" "$M10_AVM_BUILD" | grep -c 'error:')"
assert_file "libvm2_sim.a was produced" "$TREE/barretenberg/cpp/$M10_AVM_BUILD/lib/libvm2_sim.a"
assert_file "libworld_state_reference.a was produced" \
  "$TREE/barretenberg/cpp/$M10_AVM_BUILD/lib/libworld_state_reference.a"
assert_eq "the build produces exactly the nine AVM archives, as an identity" \
  "$M6_EXPECTED_ARCHIVES" "$(m6_archives "$TREE" "$M10_AVM_BUILD")"

echo
echo "== 1. the seven server modules are real targets in a native configure of this tree =="
# The scope assertion, first, because everything below is an absence.
m10_native_preset_configure "$TREE" default "$M10_SERVER_NATIVE_BUILD"; RC=$?
assert_eq "the same tree configures natively" "0" "$RC"
NATIVE_NODES="$(m6_graph_nodes "$TREE" "$M10_SERVER_NATIVE_BUILD")"
assert_ge "the native graph has nodes" 100 "$(printf '%s\n' "$NATIVE_NODES" | wc -l)"
SERVER_TARGETS=""
for m in $M10_SERVER_GROUP; do
  ts="$(m10_module_targets "$TREE" "$m")"
  assert_ge "$m declares at least one target of its own" 1 "$(printf '%s\n' "$ts" | grep -c .)"
  for t in $ts; do
    assert_eq "$m's target $t is real natively (so its absence below is a fact)" "1" \
      "$(m10_graph_has "$NATIVE_NODES" "$t")"
    SERVER_TARGETS="$SERVER_TARGETS $t"
  done
done
note "the server group declares:$SERVER_TARGETS"
AVM_TARGETS=""
for m in $M10_AVM_GROUP; do
  ts="$(m10_module_targets "$TREE" "$m")"
  assert_ge "$m declares at least one target of its own" 1 "$(printf '%s\n' "$ts" | grep -c .)"
  for t in $ts; do
    assert_eq "and so is the AVM group's $t" "1" "$(m10_graph_has "$NATIVE_NODES" "$t")"
    AVM_TARGETS="$AVM_TARGETS $t"
  done
done
note "the AVM group declares:$AVM_TARGETS"

echo
echo "== 2. the compile database: what the wasm-avm build actually compiles =="
assert_ge "the AVM_WASM build compiles hundreds of translation units" 400 \
  "$(m6_tu_count "$TREE" "$M10_AVM_BUILD")"
# `vm2` and `world_state_reference` have sources; `aztec` is header-only, and that
# is asserted as the fact it is rather than expected to compile something.
for m in vm2 world_state_reference; do
  assert_ge "it compiles units under $m/" 1 \
    "$(m6_module_tu_count "$TREE" "$M10_AVM_BUILD" "/src/barretenberg/$m/")"
done
assert_eq "aztec is header-only, so it compiles none — and it is still a target" "0" \
  "$(m6_module_tu_count "$TREE" "$M10_AVM_BUILD" "/src/barretenberg/aztec/")"
for m in $M10_SERVER_GROUP; do
  assert_eq "it compiles NOTHING under $m/" "0" \
    "$(m6_module_tu_count "$TREE" "$M10_AVM_BUILD" "/src/barretenberg/$m/")"
done

echo
echo "== 3. CMake's own graph, per module, with the shape =="
WASM_NODES="$(m6_graph_nodes "$TREE" "$M10_AVM_BUILD")"
assert_ge "the wasm-avm graph has nodes" 20 "$(printf '%s\n' "$WASM_NODES" | wc -l)"
# Every target the seven server modules declare is either absent from this graph
# or present only as cmake's UNKNOWN_LIBRARY — a name something links against
# that nothing here defines. "Absent" and "present but not built" are different
# facts and the check reports which, per target, rather than collapsing them.
for t in $SERVER_TARGETS; do
  if [ "$(m10_graph_has "$WASM_NODES" "$t")" = "0" ]; then
    pass "$t is not a node in the AVM_WASM graph at all"
  else
    assert_eq "$t IS a node — and cmake's shape says it is an UNKNOWN library" \
      "septagon" "$(m6_graph_shape "$TREE" "$M10_AVM_BUILD" "$t")"
  fi
done
# `ipc` is the one that survives, and it is worth naming rather than leaving to
# the loop above, because M6 found it and it is a fact about upstream's graph.
assert_eq "ipc is that one, as an UNKNOWN library" \
  "septagon" "$(m6_graph_shape "$TREE" "$M10_AVM_BUILD" ipc)"
assert_eq "so nothing under ipc/ is compiled" "0" \
  "$(m6_module_tu_count "$TREE" "$M10_AVM_BUILD" "/src/barretenberg/ipc/")"
# The AVM group is there, and crypto_merkle_tree with it.
for t in aztec vm2_sim world_state_reference crypto_merkle_tree; do
  assert_eq "$t is a node in the AVM_WASM graph" "1" "$(m10_graph_has "$WASM_NODES" "$t")"
done

echo
echo "== 4. vm2_sim's transitive closure =="
EDGES="$(m6_graph_edges_file "$TREE" "$M10_AVM_BUILD")"
assert_file "the graph's edge list was generated" "$EDGES"
assert_ge "and it has edges" 10 "$(grep -c . "$EDGES")"
CLOSURE="$(m6_graph_closure "$EDGES" vm2_sim | tr '\n' ' ' | sed 's/ $//')"
assert_eq "vm2_sim's closure is exactly what M6 pinned" "$M6_EXPECTED_CLOSURE" "$CLOSURE"
for t in $SERVER_TARGETS; do
  assert_not_contains "no server target in vm2_sim's closure: $t" " $t " " $CLOSURE "
done

echo
echo "== 5. what ninja produced =="
ARCHIVES="$(m6_archives "$TREE" "$M10_AVM_BUILD")"
for t in $SERVER_TARGETS; do
  assert_not_contains "no lib$t.a was produced" "lib$t.a" " $ARCHIVES "
done
assert_not_contains "and no LMDB archive either" "liblmdblib.a" " $ARCHIVES "
assert_true "nothing landed in bin/ — this configuration links no executable" \
  bash -c '[ -z "$(ls -A "$1" 2>/dev/null)" ]' _ "$TREE/barretenberg/cpp/$M10_AVM_BUILD/bin"

# And at symbol level, because a dependency list is a statement about CMake and
# an undefined symbol is a statement about the artefact.
assert_eq "libvm2_sim.a references no LMDB symbol" "0" \
  "$(m6_undefined_mdb "$TREE" "$M10_AVM_BUILD" libvm2_sim.a)"
assert_eq "libworld_state_reference.a references no LMDB symbol" "0" \
  "$(m6_undefined_mdb "$TREE" "$M10_AVM_BUILD" libworld_state_reference.a)"
UNDEF="$(m6_in_devshell '
  "$WASI_SDK_PREFIX/bin/llvm-nm" -u "$1" 2>/dev/null | sed "s/^ *U //" \
    | "$WASI_SDK_PREFIX/bin/llvm-cxxfilt"' \
  "$TREE/barretenberg/cpp/$M10_AVM_BUILD/lib/libvm2_sim.a")"
assert_ge "libvm2_sim.a has undefined symbols to look through at all" 1000 \
  "$(printf '%s\n' "$UNDEF" | grep -c .)"
for ns in 'bb::wsdb' 'bb::nodejs_module' 'bb::cdb' 'bb::ipc' 'lmdb'; do
  assert_eq "and none of them is $ns" "0" "$(printf '%s\n' "$UNDEF" | grep -cF "$ns")"
done

# `bb::world_state::` is NOT a discriminator and an earlier version of this check
# used it as one. The namespace is SHARED: `world_state_reference` — which is in
# the AVM group — declares `bb::world_state::MemoryMerkleDB` and the world-state
# vocabulary (`MerkleTreeId` and friends) in it, and the server `world_state`
# module lives there too. So the statement worth making is the positive one, and
# it is stronger: every `bb::world_state::` symbol the AVM reaches is a
# `MemoryMerkleDB` member, and every one of them is DEFINED by
# libworld_state_reference.a in this same build. Nothing is left over for a
# server module to supply.
WS_UNDEF="$(printf '%s\n' "$UNDEF" | grep -F 'bb::world_state::' | sort -u)"
assert_ge "libvm2_sim.a does reach the world-state vocabulary" 1 \
  "$(printf '%s\n' "$WS_UNDEF" | grep -c .)"
assert_eq "and every one of those symbols is a MemoryMerkleDB member" "0" \
  "$(printf '%s\n' "$WS_UNDEF" | grep -vc 'MemoryMerkleDB' || true)"
WSR_DEF="$(m6_in_devshell '
  "$WASI_SDK_PREFIX/bin/llvm-nm" --defined-only "$1" 2>/dev/null | awk "{print \$NF}" \
    | "$WASI_SDK_PREFIX/bin/llvm-cxxfilt"' \
  "$TREE/barretenberg/cpp/$M10_AVM_BUILD/lib/libworld_state_reference.a" | sort -u)"
assert_ge "libworld_state_reference.a defines symbols at all" 10 \
  "$(printf '%s\n' "$WSR_DEF" | grep -c .)"
LEFTOVER="$(comm -23 <(printf '%s\n' "$WS_UNDEF") <(printf '%s\n' "$WSR_DEF") | grep -c . || true)"
assert_eq "and the in-memory reference world state defines all of them" "0" "$LEFTOVER"
# Real exceptions, which is the other thing this configuration turns on.
assert_ge "libvm2_sim.a carries real __cxa_throw references" 1 \
  "$(printf '%s\n' "$UNDEF" | grep -c '__cxa_throw')"

echo
echo "== 6. and the three documents say what this part measured =="
# This check was rewritten around a finding — `bb::world_state::` is not a
# discriminator — and the three upstream-facing documents went on carrying the
# claim it disproved ("zero `bb::world_state::` symbols") for a further milestone,
# because nothing asserted it. The measurement is pinned here first, so the figure
# the documents quote is this run's and not a transcription, and then each document
# is required to be free of the false form and to carry the positive one.
WS_N="$(printf '%s\n' "$WS_UNDEF" | grep -c .)"
assert_eq "libvm2_sim.a reaches exactly fourteen bb::world_state:: symbols, not zero" "14" "$WS_N"
M10_MSG="$(sed -n '1,/^---$/p' "$M10_PATCH")"
for pair in "PR.md:$(cat "$M10_PR_MD")" "SERIES.md:$(cat "$M10_SERIES_MD")" "the commit message:$M10_MSG"; do
  label="${pair%%:*}"
  body="$(printf '%s' "${pair#*:}" | tr '\n' ' ' | tr -s ' ')"
  assert_not_contains "$label does not claim zero bb::world_state:: symbols" \
    'zero `bb::world_state::` symbols' "$body"
  assert_not_contains "$label does not claim it as a numeral either" \
    '**0** `bb::world_state::`' "$body"
  assert_contains "$label states the measured form — all of them MemoryMerkleDB members" \
    'MemoryMerkleDB' "$body"
  assert_contains "$label names what defines them in the same build" \
    'libworld_state_reference.a' "$body"
done

finish
