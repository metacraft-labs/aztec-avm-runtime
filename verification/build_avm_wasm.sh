#!/usr/bin/env bash
# M6's reproducible entry point: build Aztec's AVM simulator (`vm2_sim`) and its
# in-memory reference world state (`world_state_reference`) for `wasm32-wasip1`.
#
#   verification/build_avm_wasm.sh [target...]        (or: just build-avm-wasm)
#
# It prepares a worktree of the fork at 233d8e0993 with the four prepared
# patches applied — the crypto_merkle_tree/LMDB split, the wasi-sdk 27 -> 33
# bump, the widen-before-shift portability fix, and the AVM_WASM build itself —
# configures the `wasm-avm` preset and builds. Everything runs inside the fork's
# own `nix develop`, which is what supplies wasi-sdk 33, cmake, ninja, node and
# the `clang-format-20` alias that barretenberg's configure-time
# `aztec_constants.hpp` codegen invokes by that exact versioned name.
#
# The build tree is $M6_WORK/avm (default $TMPDIR/aztec-m6-avm-wasm/avm), which
# is outside both repos so no artefact can land in a git status.
#
# This script is the implementation the M6 checks drive, not a separate copy of
# it: verify_avm_wasm_build.sh calls the same m6_configure / m6_build helpers,
# so "the entry point works" and "the check passed" cannot come apart.
#
# It does not skip. A missing patch, an unpreparable tree, a failed configure or
# a failed build is a non-zero exit with the reason on stderr.

set -uo pipefail

TEST_NAME=build_avm_wasm
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_avm_wasm.sh"

TARGETS=("$@")
[ "${#TARGETS[@]}" -gt 0 ] || TARGETS=(vm2_sim world_state_reference)

note "work directory: $M6_WORK"
m6_prepare_trees
note "tree: $M6_TREE_AVM ($(git -C "$M6_TREE_AVM" rev-parse --short HEAD), $M6_BASE_REV + 4 patches)"

m6_configure "$M6_TREE_AVM" wasm-avm build-wasm-avm
cfg=$?
if [ "$cfg" -ne 0 ]; then
  printf '%s: configure failed (exit %d) — see %s\n' \
    "$TEST_NAME" "$cfg" "$M6_TREE_AVM/m6-build-wasm-avm.log" >&2
  tail -30 "$M6_TREE_AVM/m6-build-wasm-avm.log" >&2
  exit "$cfg"
fi
note "configure: ok  ($(m6_log "$M6_TREE_AVM" build-wasm-avm | grep -m1 'exceptions probe' || echo 'no probe line'))"

m6_build "$M6_TREE_AVM" build-wasm-avm "${TARGETS[@]}"
bld=$?
if [ "$bld" -ne 0 ]; then
  printf '%s: build failed (exit %d) — see %s\n' \
    "$TEST_NAME" "$bld" "$M6_TREE_AVM/m6-build-wasm-avm-build.log" >&2
  grep -E '^FAILED:|fatal error:' "$M6_TREE_AVM/m6-build-wasm-avm-build.log" >&2
  exit "$bld"
fi

printf '%s: built %s for wasm32-wasip1\n' "$TEST_NAME" "${TARGETS[*]}"
printf '  archives: %s\n' "$(m6_archives "$M6_TREE_AVM" build-wasm-avm)"
printf '  %s\n' "$M6_TREE_AVM/barretenberg/cpp/build-wasm-avm/lib"
