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
#
# And one host fact that made the measurement depend on the machine:
#   * -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER : barretenberg declares gtest and
#     google-benchmark with FetchContent's FIND_PACKAGE_ARGS (cmake/gtest.cmake,
#     cmake/benchmark.cmake), so a host that offers a GTest package satisfies it
#     through find_package and compiles none of gtest's four translation units,
#     while a host without one fetches upstream's pinned v1.13.0 and compiles them.
#     Measured 2026-11-26 on the same tree and toolchain: 1,009 TUs with a nix
#     gtest on CMAKE_PREFIX_PATH, 1,013 without. NEVER makes every host build the
#     versions upstream pins.
#     https://cmake.org/cmake/help/latest/module/FetchContent.html#variable:FETCHCONTENT_TRY_FIND_PACKAGE_MODE
set -uo pipefail

tree="$1"

cd "$tree/barretenberg/cpp" || exit 90
export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"

if [ ! -d src/barretenberg/nodejs_module/node_modules ]; then
  # YARN_ENABLE_IMMUTABLE_INSTALLS: see m6_native_configure in
  # verification/lib_avm_wasm.sh for why this is set and what happens without
  # it. Short version: Yarn Berry turns immutable installs on by itself when $CI
  # is set, the dev shell's yarn 4.14.1 wants to migrate upstream's format-8
  # lockfile to format 9, and an immutable install refuses (YN0028) — so on a
  # runner this exits 92 and cmake below is never reached.
  ( cd src/barretenberg/nodejs_module \
      && YARN_ENABLE_IMMUTABLE_INSTALLS=false yarn install ) \
    || { echo "### yarn bootstrap FAILED in nodejs_module — cmake was never reached"; exit 92; }
fi

echo "### tree: $tree"
cmake --preset default -DAVM_TRANSPILER_LIB= -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER
rc=$?
echo "### configure_rc=$rc"
exit $rc
