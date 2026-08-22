#!/usr/bin/env bash
# Inner half of m4_wasm_build (verification/lib_wasi33.sh). Runs INSIDE the bwrap
# namespace that has the chosen wasi-sdk bound at /opt/wasi-sdk, so barretenberg's
# `wasm` / `wasm-threads` presets can be invoked verbatim — including the
# unpatched ones, whose environment block hardcodes that path.
#
#   $1  tree directory (a worktree of the fork)
#   $2  CMake preset name (its binaryDir is build-<preset>)
#   $3+ ninja targets
#
# Prints its own status markers so a caller reading the log can tell a configure
# failure from a build failure, and exits with the failing command's status.
set -uo pipefail

tree="$1"; preset="$2"; shift 2

export WASI_SDK_PREFIX=/opt/wasi-sdk WASI_SDK_PATH=/opt/wasi-sdk

cd "$tree/barretenberg/cpp" || exit 90
echo "### tree: $tree"
echo "### sdk: $(head -1 /opt/wasi-sdk/VERSION)"

# -DAVM_TRANSPILER_LIB= : the transpiler is a Rust staticlib built by a separate
# bootstrap step and is not part of what this comparison measures.
cmake --preset "$preset" -DAVM_TRANSPILER_LIB= -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
rc=$?
echo "### configure_rc=$rc"
[ $rc -eq 0 ] || exit $rc

ninja -C "build-$preset" "$@"
rc=$?
echo "### ninja_rc=$rc"
exit $rc
