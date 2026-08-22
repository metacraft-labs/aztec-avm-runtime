#!/usr/bin/env bash
# Inner half of m4_native_configure (verification/lib_wasi33.sh).
#
# Configures a NATIVE build of a fork worktree through barretenberg's own
# `default` preset, so the comparison exercises `CMakePresets.json` — one of the
# five files the wasi-sdk patch touches — rather than a hand-written cmake line
# that would route around it.
#
#   $1  tree directory (a worktree of the fork)
#
# Two environment facts are handled here rather than left to bite (both were
# already met in M3):
#   * nodejs_module's CMakeLists runs `yarn --immutable` at configure time and
#     fails the whole configure if node-addon-api cannot be resolved.
#   * -DAVM_TRANSPILER_LIB= : the transpiler is a Rust staticlib produced by a
#     separate bootstrap step; nothing here needs it.
set -uo pipefail

tree="$1"

cd "$tree/barretenberg/cpp" || exit 90
export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"

if [ ! -d src/barretenberg/nodejs_module/node_modules ]; then
  ( cd src/barretenberg/nodejs_module && yarn install ) || exit 92
fi

echo "### tree: $tree"
cmake --preset default -DAVM_TRANSPILER_LIB= -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
rc=$?
echo "### configure_rc=$rc"
exit $rc
