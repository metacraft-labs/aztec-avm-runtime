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
# both repos so no build artefact can land in a git status, and under $HOME rather
# than /tmp, which is usually a small tmpfs: M9's review exhausted a /tmp quota
# mid-build and the checks reported it as a hundred unrelated failed assertions
# instead of one precondition. require_work_dir turns that back into one line.
M3_WORK="${M3_WORK:-$HOME/.cache/aztec-m3-merkle-lmdb}"
require_work_dir "$M3_WORK" 4

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
# UPSTREAM'S LMDB SCRATCH DIRECTORY, WHICH THIS CHECK USED TO INHERIT RATHER THAN PRODUCE.
#
# `crypto/merkle_tree/fixtures.hpp` and `lmdblib/fixtures.hpp` both hardcode
# `/tmp/lmdb/<random_uint32>` as the directory a persisted-tree test runs in. That is upstream's
# path, not ours, and NOTHING here used to touch it — so every run of these binaries inherited
# whatever every previous run had left there. Two measurements say that is not benign:
#
#   * the suite LEAKS. Measured over three consecutive runs of
#     `PersistedContentAddressedAppendOnlyTreeTest.*`, `/tmp/lmdb` went 0 -> 1 -> 2 -> 3 entries:
#     one abandoned directory per run, forever, with nothing to notice it.
#   * on 2026-08-24 this check failed with `crypto_merkle_tree_lmdb_tests` and
#     `crypto_merkle_tree_tests` aborting (exit 134 / 135, glibc `corrupted size vs. prev_size`),
#     on BOTH the base and the patched tree — so not the patch — with 797 leftover directories
#     and 355 MB in `/tmp/lmdb`. It was reproduced once in isolation, the first failure being an
#     `unwind_block` that returned success=false. Free space was measured and REFUTED as the cause
#     (/tmp never below 6,424 MB; the suite's own peak use of `/tmp/lmdb` is 165 MB), as was
#     machine load (32 cores idle, 53 GB available). After the leftovers were removed the test
#     passed five consecutive times.
#
# A FOURTH candidate cause was raised in review and is refuted by ARITHMETIC rather than left open:
# the obvious mechanism by which leftovers could matter is a NAME COLLISION — a fixture reopening a
# directory a previous run left populated, which would show up as exactly the stale tree state that
# `unwind_block` returning success=false looks like. It is not that. Both fixtures name the
# directory `random_temp_directory()` -> `numeric::get_randomness().get_random_uint32()`, and
# `get_randomness()` is barretenberg's CSPRNG-backed `RandomEngine` (getrandom(2) into a 1 MiB
# thread-local buffer), NOT the deterministic `get_debug_randomness()` the same header also binds.
# The names are therefore genuinely random over 2^32, so with the 797 leftovers that were present
# the chance of any one test colliding is about 1.9e-7. A seeded PRNG would have made this the
# answer; a CSPRNG makes it not the answer. The reported failure mode is glibc heap corruption
# (`corrupted size vs. prev_size`) on the BASE tree — upstream's own code — which is where a cause
# would have to be found, under ASAN or valgrind, and that is not this milestone's to do.
#
# The causal link is NOT established and this comment does not claim one. What is established is
# that the check depended on state it did not produce, and that is fixed here rather than argued
# about: the scratch is taken fresh, the number of abandoned directories found is REPORTED as a
# measurement, and the number this run leaks is reported too. Both are assertions in
# verify_merkle_lmdb_split_native_neutral, so the leak stays visible instead of accumulating for
# another eight hundred runs.
#
# Taking it is safe because the directory is exclusively these binaries' own scratch — every entry
# is a random-named LMDB environment created by a fixture's SetUp and deleted by its TearDown — and
# because M3 holds its work directory under `flock`, so two M3 runs cannot be here at once.
# ---------------------------------------------------------------------------
M3_LMDB_SCRATCH="${M3_LMDB_SCRATCH:-/tmp/lmdb}"
M3_LMDB_ABANDONED_FOUND=
# The bound the neutrality check holds the leak to. MEASURED: ten abandoned directories across the
# five binary runs the check makes, i.e. two per run. The bound is TWENTY and is deliberately not
# the measurement — a budget equal to what was measured fails on any change and therefore gets
# raised rather than read — while a suite that started leaking per TEST would produce about three
# hundred and thirty and blow through it on the first run.
M3_LMDB_LEAK_BOUND="${M3_LMDB_LEAK_BOUND:-20}"
export M3_LMDB_SCRATCH M3_LMDB_LEAK_BOUND

m3_lmdb_entries() {
  ls -1 "$M3_LMDB_SCRATCH" 2>/dev/null | wc -l | tr -d '[:space:]'
}

m3_take_lmdb_scratch() {
  M3_LMDB_ABANDONED_FOUND="$(m3_lmdb_entries)"
  if [ "${M3_LMDB_ABANDONED_FOUND:-0}" -gt 0 ]; then
    local aside="$M3_LMDB_SCRATCH.abandoned.$$"
    mv "$M3_LMDB_SCRATCH" "$aside" 2>/dev/null \
      || die "cannot take upstream's LMDB scratch directory $M3_LMDB_SCRATCH aside"
    rm -rf "$aside"
  fi
  mkdir -p "$M3_LMDB_SCRATCH" \
    || die "cannot create upstream's LMDB scratch directory $M3_LMDB_SCRATCH"
}

# ---------------------------------------------------------------------------
# m3_failure_mode <exit-status> <out-file> -> ONE token naming HOW the run failed.
#
# "exits 0" is a true statement about a run and says nothing about which kind of wrong it was, and
# this campaign has now twice spent an afternoon on the difference. A gtest binary that ABORTS
# (SIGABRT out of glibc's heap checker) and one that runs to completion with failing EXPECTs both
# come back non-zero; the first is an environment or memory-corruption problem and the second is a
# statement about the code under test. One token separates them at the point of measurement.
# ---------------------------------------------------------------------------
m3_failure_mode() {
  local status="$1" out="$2" sig name first
  if [ "$status" -eq 0 ]; then printf 'clean\n'; return 0; fi
  if [ "$status" -gt 128 ]; then
    sig=$((status - 128))
    name="$(kill -l "$sig" 2>/dev/null || printf '%s' "$sig")"
    if grep -qE 'corrupted size vs\. prev_size|malloc\(\): |free\(\): |double free|Aborted' "$out" 2>/dev/null; then
      printf 'signal-%s-after-heap-corruption\n' "$name"
    else
      printf 'signal-%s\n' "$name"
    fi
    return 0
  fi
  first="$(grep -m1 '^\[  FAILED  \] [A-Za-z]' "$out" 2>/dev/null | awk '{print $4}')"
  if [ -n "$first" ]; then printf 'gtest-failed:%s\n' "$first"; return 0; fi
  printf 'exit-%s\n' "$status"
}

# ---------------------------------------------------------------------------
# m3_run_gtest <build-dir> <binary-name> <out-file>
#
# Runs a gtest binary and prints "<exit-status> <ran> <passed> <failure-mode>" on stdout.
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
  printf '%s %s %s %s\n' "$status" "${ran:--}" "${passed:--}" "$(m3_failure_mode "$status" "$out")"
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
