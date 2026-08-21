#!/usr/bin/env bash
# Shared machinery for the M3 checks — the prepared upstream patch that splits
# `crypto_merkle_tree` from its LMDB backend.
#
# All four M3 checks measure the same two trees:
#
#   base     — the fork at the patch's base commit, 233d8e0993, unmodified.
#   patched  — the same commit with the prepared format-patch applied by `git am`.
#
# The patched tree is produced FROM THE PATCH FILE, not from the local commit,
# because the patch file is what would be filed upstream. The local commit is
# then used as a cross-check: the two must have the same tree hash.
#
# Building barretenberg twice is expensive the first time (~15 min for the two
# trees on 32 cores, with a cold ccache) and close to free afterwards, because
# both trees and both build directories are kept under $M3_WORK and ninja and
# ccache make a re-run incremental. Nothing here has a skip path: if a tree
# cannot be prepared or a build fails, the caller's assertion fails.
#
# Not to be executed directly: sourced by verification/*merkle_lmdb*.sh, AFTER
# lib.sh (it uses FORK_ROOT, WORKSPACE_ROOT, die).

# The commit the patch is generated against, and the local commit that carries
# the same change. Both are asserted, not assumed.
M3_BASE_REV=233d8e0993
M3_SPLIT_REV=d15ada03646a7af28ab4a275901909d41877f381

# The prepared upstream contribution. Named `-split`, not `-coupling`: see the
# M3 notes in the milestone file for the reconciliation.
M3_PATCH_DIR="$WORKSPACE_ROOT/codetracer-specs/upstream-bugs/aztec-merkle-tree-lmdb-split"
M3_PATCH_FILE="$M3_PATCH_DIR/0001-refactor-crypto-split-crypto_merkle_tree-from-its-LMD.patch"

# Where the two worktrees and their build directories live. Deliberately outside
# both repos so no build artefact can land in a git status.
M3_WORK="${M3_WORK:-${TMPDIR:-/tmp}/aztec-m3-merkle-lmdb}"

# Targets built in BOTH trees. `crypto_merkle_tree` itself is not in the list:
# after the split it is an INTERFACE library and has no ninja target at all,
# which is one of the patch's stated limitations.
M3_COMMON_TARGETS="crypto_merkle_tree_tests world_state world_state_tests world_state_reference vm2_sim"
# Only the patched tree has this one; it is where the LMDB half of the suite went.
M3_PATCHED_EXTRA_TARGETS="crypto_merkle_tree_lmdb_tests"

export M3_BASE_REV M3_SPLIT_REV M3_PATCH_DIR M3_PATCH_FILE M3_WORK

# ---------------------------------------------------------------------------
# m3_in_devshell <script-text> [args...]
#
# Runs a script inside the fork's own `nix develop`. The fork's shell is the
# reproducible definition of the toolchain; running the build outside it would
# make the numbers depend on whatever the host happens to have.
#
# Returns the script's exit status. stdout/stderr pass through.
# ---------------------------------------------------------------------------
m3_in_devshell() {
  local script="$1"; shift
  ( cd "$FORK_ROOT" && nix develop --command bash -euo pipefail -c "$script" bash "$@" )
}

# ---------------------------------------------------------------------------
# m3_prepare_trees
#
# Idempotently materialises $M3_WORK/base and $M3_WORK/patched. Dies (does not
# "skip") on any failure, because every M3 measurement is made on these trees.
# ---------------------------------------------------------------------------
m3_prepare_trees() {
  command -v git >/dev/null 2>&1 || die "git is required"
  command -v nix >/dev/null 2>&1 || die "nix is required (the build runs in the fork's dev shell)"
  [ -d "$FORK_ROOT/.git" ] || [ -f "$FORK_ROOT/.git" ] || die "no aztec-packages checkout at $FORK_ROOT"
  [ -f "$M3_PATCH_FILE" ] || die "the prepared patch is missing: $M3_PATCH_FILE"

  git -C "$FORK_ROOT" rev-parse --verify --quiet "$M3_BASE_REV^{commit}" >/dev/null \
    || die "base commit $M3_BASE_REV is not in $FORK_ROOT"

  mkdir -p "$M3_WORK"

  if [ ! -d "$M3_WORK/base/.git" ] && [ ! -f "$M3_WORK/base/.git" ]; then
    git -C "$FORK_ROOT" worktree add --detach "$M3_WORK/base" "$M3_BASE_REV" >/dev/null 2>&1 \
      || die "could not create the base worktree at $M3_WORK/base"
  fi
  [ "$(git -C "$M3_WORK/base" rev-parse HEAD)" = "$(git -C "$FORK_ROOT" rev-parse "$M3_BASE_REV")" ] \
    || die "$M3_WORK/base is not at $M3_BASE_REV — remove it and re-run"

  if [ ! -d "$M3_WORK/patched/.git" ] && [ ! -f "$M3_WORK/patched/.git" ]; then
    git -C "$FORK_ROOT" worktree add --detach "$M3_WORK/patched" "$M3_BASE_REV" >/dev/null 2>&1 \
      || die "could not create the patched worktree at $M3_WORK/patched"
    # -3 is deliberately NOT passed: the patch must apply to this base exactly.
    if ! git -C "$M3_WORK/patched" am "$M3_PATCH_FILE" >"$M3_WORK/am.log" 2>&1; then
      git -C "$M3_WORK/patched" am --abort >/dev/null 2>&1 || true
      die "git am of $(basename "$M3_PATCH_FILE") failed on $M3_BASE_REV — see $M3_WORK/am.log"
    fi
  fi
}

# ---------------------------------------------------------------------------
# m3_build <tree-dir> <target...>
#
# Configures (once) and builds. Returns ninja's / cmake's exit status verbatim —
# callers assert on it. The full log is left at <tree-dir>/m3-build.log.
#
# Two environment facts are handled here rather than left to bite:
#   * nixpkgs' mkShell puts the GCC stdenv wrapper first, so CMake picks g++
#     unless told otherwise, and barretenberg does not compile with gcc 15.
#   * nodejs_module's CMakeLists runs `yarn --immutable` at configure time and
#     fails the whole configure if node-addon-api cannot be resolved.
# ---------------------------------------------------------------------------
m3_build() {
  local tree="$1"; shift
  local log="$tree/m3-build.log"
  m3_in_devshell '
    tree="$1"; shift
    cd "$tree/barretenberg/cpp"
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    if [ ! -d src/barretenberg/nodejs_module/node_modules ]; then
      ( cd src/barretenberg/nodejs_module && yarn install )
    fi
    if [ ! -f build-native/build.ninja ]; then
      cmake -B build-native -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DENABLE_PIC=ON \
        -DAVM=OFF -DAVM_TRANSPILER_LIB= \
        -DCMAKE_C_COMPILER="$(command -v clang)" \
        -DCMAKE_CXX_COMPILER="$(command -v clang++)" \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    fi
    ninja -C build-native "$@"
  ' "$tree" "$@" >"$log" 2>&1
}

# ---------------------------------------------------------------------------
# m3_run_gtest <build-dir> <binary-name> <out-file>
#
# Runs a gtest binary and prints "<exit-status> <ran> <passed>" on stdout.
# `ran` / `passed` are `-` when the summary lines are absent, so a binary that
# dies before printing them cannot be mistaken for one that ran zero tests.
# ---------------------------------------------------------------------------
m3_run_gtest() {
  local bdir="$1" bin="$2" out="$3"
  local status ran passed
  ( export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"; "$bdir/bin/$bin" ) >"$out" 2>&1
  status=$?
  ran=$(grep -oE '^\[==========\] [0-9]+ tests? from [0-9]+ test suites? ran' "$out" \
        | grep -oE '[0-9]+' | head -1)
  passed=$(grep -oE '^\[  PASSED  \] [0-9]+ tests?' "$out" | grep -oE '[0-9]+' | head -1)
  printf '%s %s %s\n' "$status" "${ran:--}" "${passed:--}"
}

# ---------------------------------------------------------------------------
# m3_gtest_names <build-dir> <binary-name>
#
# The binary's full "Suite.Test" list, sorted. Used to prove the split moved
# tests rather than renaming or dropping them — a stronger statement than the
# counts, which two compensating changes could keep equal.
# ---------------------------------------------------------------------------
m3_gtest_names() {
  local bdir="$1" bin="$2"
  ( export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"; "$bdir/bin/$bin" --gtest_list_tests ) 2>/dev/null \
  | awk '
      /^[A-Za-z_][A-Za-z0-9_\/]*\.$/ { suite=$1; next }
      /^  [A-Za-z_]/ { name=$1; if (suite != "") print suite name }
    ' | sort
}

# ---------------------------------------------------------------------------
# m3_graph <tree-dir>
#
# Regenerates CMake's own target dependency graph for an already-configured
# build tree and prints its edges as "<from> -> <to>", one per line. This is
# the build system's own answer to "what links what", rather than our reading
# of the CMakeLists text, which is why the link-edge check uses it.
#
# Returns non-zero if cmake fails, and prints nothing — the caller's set
# comparison then fails, which is the intended outcome.
# ---------------------------------------------------------------------------
m3_graph() {
  local tree="$1"
  local bdir="$tree/barretenberg/cpp/build-native"
  local out="$tree/m3-graph"
  [ -f "$bdir/CMakeCache.txt" ] || return 1
  rm -rf "$out"; mkdir -p "$out"
  m3_in_devshell '
    bdir="$1"; out="$2"
    cd "$bdir" && cmake --graphviz="$out/targets.dot" . >/dev/null
  ' "$bdir" "$out" >/dev/null 2>&1 || return 1
  [ -f "$out/targets.dot" ] || return 1
  # cmake annotates every edge with a "// <from> -> <to>" comment.
  grep -oE '// [A-Za-z0-9_:.-]+ -> [A-Za-z0-9_:.-]+$' "$out/targets.dot" \
    | sed 's|^// ||' | sort -u
}

# ---------------------------------------------------------------------------
# m3_measured
#
# Reads $M3_WORK/measured.env — the single record of what was actually built
# and run, written by verify_merkle_lmdb_split_native_neutral. Every other M3
# check that quotes a number reads it from here, so no two checks can disagree
# about what was measured and `PR.md`'s table is checked against a measurement
# rather than against itself.
#
# If the record is not there, the neutrality check is RUN to produce it. It is
# never invented, defaulted or skipped: if it cannot be produced, the caller
# dies rather than passing on absent evidence.
# ---------------------------------------------------------------------------
m3_measured() {
  if [ ! -f "$M3_WORK/measured.env" ]; then
    note "no measurement on record — running verify_merkle_lmdb_split_native_neutral to produce one"
    "$VERIFY_DIR/verify_merkle_lmdb_split_native_neutral.sh" >"$M3_WORK/neutral-for-record.log" 2>&1 \
      || die "could not produce a measurement: see $M3_WORK/neutral-for-record.log"
  fi
  [ -f "$M3_WORK/measured.env" ] || die "measurement record missing at $M3_WORK/measured.env"
  # shellcheck disable=SC1090
  . "$M3_WORK/measured.env"
}
