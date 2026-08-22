#!/usr/bin/env bash
# Shared machinery for the M7 checks — upstream's own vm2 test suite under wasm.
#
# M7 runs, where M6 only built. Everything it measures comes out of ONE worktree
# of the fork at 233d8e0993 carrying FIVE patches: the four of the AVM_WASM
# series that M6 established, plus M7's own `AVM_SIM_TESTS` overlay, which is
# OURS and is not part of the upstream series (verification/m7/).
#
#   avm7     233d8e0993 + patches 1-4 + the AVM_SIM_TESTS overlay.
#            Two build directories inside it, because the whole milestone is a
#            comparison between them:
#              build-wasm-avm     `wasm-avm` preset, -DAVM_SIM_TESTS=ON
#              build-native-avm   `default` preset,  -DAVM_SIM_TESTS=ON
#            The native one also builds upstream's OWN `vm2_tests` — the binary
#            with the proving stack and `dsl` in it — because that is the only
#            honest anchor for the exclusion list. A wasm pass rate quoted
#            against `vm2_sim_tests` alone is a pass rate against a suite we
#            chose the size of.
#
# Nothing here has a skip path. A tree that cannot be prepared, a build that
# fails, a runtime that is missing or a transcript with no test names in it is
# `die` or a failed assertion, never a printed SKIP.
#
# It reuses M6's machinery rather than re-implementing it: M6_WORK is pointed at
# $M7_WORK before lib_avm_wasm.sh is sourced, so m6_prepare_tree, m6_in_devshell,
# m6_configure, m6_build, m6_tree_or_die, m6_graph* and the compile-database
# readers all operate inside M7's own directory and cannot touch M6's evidence.
#
# Not to be executed directly: sourced by verification/verify_vm2_tests_*.sh and
# verification/verify_world_state_reference_tests_*.sh, AFTER lib.sh.

# Where M7's worktree and its two build directories live. About 12 GB with the
# native build (upstream's vm2_tests alone is 264 MB and the proving stack behind
# it is most of the tree), so a tmpfs /tmp is the wrong place: set M7_WORK.
M7_WORK="${M7_WORK:-${TMPDIR:-/tmp}/aztec-m7-vm2-tests}"

# M6's helpers keep their own name and their own variable; pointing that variable
# at M7's directory is what keeps the two milestones' trees apart.
M6_WORK="$M7_WORK"
export M6_WORK M7_WORK

# shellcheck source=lib_avm_wasm.sh
. "$VERIFY_DIR/lib_avm_wasm.sh"

# M7's own overlay: the fifth patch. Ours, not upstream's — SERIES.md indexes
# four, and this one is a downstream test target.
M7_PATCH_5="$REPO_ROOT/verification/m7/0001-test-vm2-AVM_SIM_TESTS-the-simulation-side-test-suit.patch"

M7_TREE_NAME=avm7
M7_WASM_BUILD=build-wasm-avm
M7_NATIVE_BUILD=build-native-avm

# The suite as measured. Pinned as identities, not minima: a test appearing is as
# much a finding as one disappearing, and this campaign has twice quoted a number
# that a set comparison would have caught.
M7_EXPECTED_SIM_TESTS=391
M7_EXPECTED_SIM_SUITES=60
M7_EXPECTED_ALL_TESTS=1803
M7_EXPECTED_EXCLUDED=1412

# The committed record of every excluded test, one row per test.
M7_EXCLUSIONS_TSV="$REPO_ROOT/fixtures/wasm-parity/vm2-tests-wasm-exclusions.tsv"
M7_INCLUDED_TXT="$REPO_ROOT/fixtures/wasm-parity/vm2-sim-tests-included.txt"

M7_NAMES="$VERIFY_DIR/wasm_host/_gtest_names.py"
M7_SUITE_SOURCES="$VERIFY_DIR/wasm_host/_gtest_suite_sources.py"
M7_EXCLUSIONS_PY="$VERIFY_DIR/wasm_host/_exclusions.py"
M7_MEMLIMITS="$VERIFY_DIR/wasm_host/_wasm_memory_limits.py"
M7_V8_HOST="$VERIFY_DIR/wasm_host/run_wasm_test_binary.mjs"

# A wasm guest that spins is a run that never ends; every execution is bounded.
M7_RUN_TIMEOUT="${M7_RUN_TIMEOUT:-900}"

export M7_PATCH_5 M7_TREE_NAME M7_WASM_BUILD M7_NATIVE_BUILD

# ---------------------------------------------------------------------------
# m7_tree -> the prepared worktree, or die
#
# 233d8e0993 + the four series patches + M7's overlay, in that order, by
# `git am` with no -3: each must apply to what precedes it exactly.
# ---------------------------------------------------------------------------
m7_tree() {
  [ -f "$M7_PATCH_5" ] || die "M7's overlay patch is missing: $M7_PATCH_5"
  M7_TREE=$(m6_prepare_tree "$M7_TREE_NAME" \
    "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4" "$M7_PATCH_5")
  # A command substitution swallows `die`, so the tree can come back empty and
  # every later `git -C ""` would run in the CALLER's repository. M6 was bitten
  # by exactly this; the guard is not optional.
  m6_tree_or_die M7_TREE
  export M7_TREE
  printf '%s\n' "$M7_TREE"
}

m7_vm2_src() { printf '%s\n' "$M7_TREE/barretenberg/cpp/src/barretenberg/vm2"; }

# ---------------------------------------------------------------------------
# m7_build_wasm / m7_build_native
#
# Configure and build, returning non-zero if EITHER step failed. Callers assert
# the two statuses separately (a stale binary from a previous run will happily
# print a green summary over a build that did not happen — M2's defect, M3's
# lesson), so these record both in $M7_WORK/status.
# ---------------------------------------------------------------------------
m7_build_wasm() {
  m6_configure "$M7_TREE" wasm-avm "$M7_WASM_BUILD" -DAVM_SIM_TESTS=ON
  M7_WASM_CONFIGURE_RC=$?
  [ "$M7_WASM_CONFIGURE_RC" -eq 0 ] || return "$M7_WASM_CONFIGURE_RC"
  m6_build "$M7_TREE" "$M7_WASM_BUILD" vm2_sim_tests
  M7_WASM_BUILD_RC=$?
  return "$M7_WASM_BUILD_RC"
}

m7_build_native() {
  # FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER is load-bearing twice over.
  #
  # `cmake/gtest.cmake` declares GTest with FIND_PACKAGE_ARGS, so a native
  # configure prefers whatever `find_package(GTest)` turns up -- on this host, the
  # SYSTEM gtest 1.17.0 under /usr/lib, which is neither pinned nor present on a CI
  # runner, and which the freshly linked binary cannot even load without
  # LD_LIBRARY_PATH (`gtest_discover_tests` runs it at build time and the build
  # fails on `libgtest_main.so.1.17.0: cannot open shared object file`). Forcing
  # FetchContent makes the native build hermetic.
  #
  # And it makes the two sides of the parity comparison use the SAME gtest: a wasm
  # configure cannot find a package at all (CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY),
  # so it always builds googletest v1.13.0 from source. Without this the native run
  # would be on 1.17.0 and the wasm run on 1.13.0, which is a difference between the
  # two sides that nothing in the milestone wants.
  m6_native_configure "$M7_TREE" "$M7_NATIVE_BUILD" -DAVM_SIM_TESTS=ON \
    -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER
  M7_NATIVE_CONFIGURE_RC=$?
  [ "$M7_NATIVE_CONFIGURE_RC" -eq 0 ] || return "$M7_NATIVE_CONFIGURE_RC"
  m6_build "$M7_TREE" "$M7_NATIVE_BUILD" vm2_tests vm2_sim_tests
  M7_NATIVE_BUILD_RC=$?
  return "$M7_NATIVE_BUILD_RC"
}

m7_wasm_bin()   { printf '%s\n' "$M7_TREE/barretenberg/cpp/$M7_WASM_BUILD/bin/$1"; }
m7_native_bin() { printf '%s\n' "$M7_TREE/barretenberg/cpp/$M7_NATIVE_BUILD/bin/$1"; }

# ---------------------------------------------------------------------------
# m7_run_native <binary> <out-file> [args...]  -> exit status of the guest
#
# gtest discovery and the native binaries want the host libstdc++, the same fact
# M3, M4 and M6 all met.
# ---------------------------------------------------------------------------
m7_run_native() {
  local bin="$1" out="$2"; shift 2
  [ -x "$bin" ] || die "no native binary at $bin — nothing to run"
  m6_in_devshell '
    bin="$1"; t="$2"; shift 2
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    timeout --foreground --preserve-status -s KILL "$t" "$bin" "$@" 2>&1
  ' "$bin" "$M7_RUN_TIMEOUT" "$@" >"$out" 2>&1
}

# ---------------------------------------------------------------------------
# m7_run_v8 <wasm> <out-file> [args...]  -> exit status of the guest
#
# The SHIPPED binary, unmodified, on node's WASI. The host supplies `env.memory`
# read out of the module's own import section (M4's machinery) and nothing else;
# it cannot turn a failing run into a passing one, which is the property every
# check below depends on.
# ---------------------------------------------------------------------------
m7_run_v8() {
  local wasm="$1" out="$2"; shift 2
  [ -f "$wasm" ] || die "no wasm module at $wasm — nothing to run"
  m6_in_devshell '
    host="$1"; wasm="$2"; t="$3"; shift 3
    timeout --foreground --preserve-status -s KILL "$t" node "$host" "$wasm" "$@" 2>&1
  ' "$M7_V8_HOST" "$wasm" "$M7_RUN_TIMEOUT" "$@" >"$out" 2>&1
}

# ---------------------------------------------------------------------------
# m7_run_wasmtime <wasm> <out-file> [args...]  -> exit status of the guest
#
# THE SECOND RUNTIME, and it is not a formality: a result only one host reports
# is a result about that host.
#
# wasmtime cannot supply an imported memory from the command line, and the two
# ways round that are both closed here in ways worth stating rather than
# working around silently:
#
#   * wasmtime 21.0.2 (nixpkgs/nixos-24.05), which still has `-Sthreads` and
#     which M4's review used for exactly this, CANNOT LOAD THIS MODULE:
#     "exception refs not supported without the exception handling feature".
#     M6's build has real C++ exceptions, so that route died with M4.
#   * wasmtime 47 removed `-Sthreads` altogether.
#
# So the import is satisfied statically, with binaryen's `wasm-merge` and a
# two-line module that EXPORTS a memory — M4's other route. The limits come from
# the module's own import section (`_wasm_memory_limits.py`), never from a
# constant: a smaller memory fails instantiation for a reason that reads like a
# toolchain fault, and a larger one is a different module.
#
# The merged module is not byte-identical to the shipped one, so this is the
# cross-check and the V8 run over the unmodified artefact is the primary
# measurement. Both must agree, per test.
# ---------------------------------------------------------------------------
m7_run_wasmtime() {
  local wasm="$1" out="$2"; shift 2
  [ -f "$wasm" ] || die "no wasm module at $wasm — nothing to run"
  local limits mn mx
  limits="$(python3 "$M7_MEMLIMITS" "$wasm")" \
    || die "could not read the memory import of $wasm"
  mn="$(printf '%s' "$limits" | awk '{print $3}')"
  mx="$(printf '%s' "$limits" | awk '{print $4}')"
  [ -n "$mn" ] && [ -n "$mx" ] || die "unreadable memory limits for $wasm: [$limits]"
  local merged="$M7_WORK/$(basename "$wasm").merged.wasm"
  m6_in_devshell '
    wasm="$1"; merged="$2"; mn="$3"; mx="$4"; t="$5"; shift 5
    tmp="$(mktemp -d)"; trap "rm -rf $tmp" EXIT
    printf "(module (memory (export \"memory\") %s %s))\n" "$mn" "$mx" > "$tmp/envmem.wat"
    wat2wasm "$tmp/envmem.wat" -o "$tmp/envmem.wasm" || exit 90
    wasm-merge "$tmp/envmem.wasm" env "$wasm" main -o "$merged" \
      --rename-export-conflicts --enable-bulk-memory --enable-simd \
      --enable-mutable-globals --enable-sign-ext --enable-nontrapping-float-to-int \
      --enable-multivalue --enable-exception-handling --enable-reference-types \
      >/dev/null 2>&1 || exit 91
    timeout --foreground --preserve-status -s KILL "$t" wasmtime run --dir=. "$merged" "$@" 2>&1
  ' "$wasm" "$merged" "$mn" "$mx" "$M7_RUN_TIMEOUT" "$@" >"$out" 2>&1
}

# ---------------------------------------------------------------------------
# m7_names <list|ran|passed|failed> <file>
#
# The full test names in a gtest listing or transcript, sorted and unique. Dies
# rather than returning an empty set for the three modes where empty means the
# input was not what the caller thought: every comparison below is a SET
# comparison, and the empty set is a subset of everything.
# ---------------------------------------------------------------------------
m7_names() {
  local mode="$1" file="$2"
  [ -f "$file" ] || die "m7_names: no such file: $file"
  python3 "$M7_NAMES" "$mode" "$file" || {
    [ "$mode" = failed ] && return 0
    die "m7_names: $mode found no test names in $file"
  }
}

m7_count() { m7_names "$1" "$2" | wc -l | tr -d ' '; }

# m7_summary_ran / m7_summary_passed <transcript>
#   gtest's OWN summary line, parsed separately from the per-test lines. The two
#   are different facts and this campaign has a fixture whose whole point is that
#   they can disagree (wasm_host/green_summary_exit7.cpp prints a full
#   "132 ran / 132 PASSED" and exits 7).
m7_summary_ran() {
  grep -oE '^\[==========\] [0-9]+ tests? from [0-9]+ test suites? ran' "$1" 2>/dev/null \
    | grep -oE '[0-9]+' | head -1
}
m7_summary_suites() {
  grep -oE '^\[==========\] [0-9]+ tests? from [0-9]+ test suites? ran' "$1" 2>/dev/null \
    | grep -oE '[0-9]+' | sed -n 2p
}
m7_summary_passed() {
  grep -oE '^\[  PASSED  \] [0-9]+ tests?' "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1
}

# m7_set_diff <a-file> <b-file> -> the symmetric difference, one name per line,
#   prefixed `<` for a-only and `>` for b-only. Sorting is forced to the C
#   locale, because python's sort and the shell's differ and `comm` then reports
#   "not in sorted order" and lies about the answer.
m7_set_diff() {
  local a b
  a="$(mktemp)"; b="$(mktemp)"
  LC_ALL=C sort -u "$1" >"$a"
  LC_ALL=C sort -u "$2" >"$b"
  LC_ALL=C comm -3 "$a" "$b" | sed -e 's/^\t/> /' -e 's/^\([^ \t]\)/< \1/'
  rm -f "$a" "$b"
}

# m7_set_equal <desc> <a-file> <b-file>
#   A per-test comparison, not a count. Equal counts survive a rename, or a drop
#   plus an addition; a name set does not. M3 and M4 both found this mattered.
m7_set_equal() {
  local desc="$1" a="$2" b="$3" d
  [ -s "$a" ] || { fail "$desc  (left set is empty: $a)"; return; }
  [ -s "$b" ] || { fail "$desc  (right set is empty: $b)"; return; }
  d="$(m7_set_diff "$a" "$b")"
  if [ -z "$d" ]; then
    pass "$desc  [$(LC_ALL=C sort -u "$a" | wc -l | tr -d ' ') names, identical]"
  else
    fail "$desc  differs by $(printf '%s\n' "$d" | wc -l | tr -d ' ') name(s): $(printf '%s' "$d" | head -5 | tr '\n' ' ')"
  fi
}

# ---------------------------------------------------------------------------
# m7_measured
#
# $M7_WORK/measured.env — the single record of what was built and run, written
# by verify_vm2_tests_build_for_wasm. Every other M7 check reads it, so no two
# can disagree about what was measured. If it is not there the build check is
# RUN to produce one; it is never invented, defaulted or skipped.
# ---------------------------------------------------------------------------
m7_measured() {
  if [ ! -f "$M7_WORK/measured.env" ]; then
    note "no measurement on record — running verify_vm2_tests_build_for_wasm to produce one"
    mkdir -p "$M7_WORK"
    "$VERIFY_DIR/verify_vm2_tests_build_for_wasm.sh" >"$M7_WORK/build-for-record.log" 2>&1 \
      || die "could not produce a measurement: see $M7_WORK/build-for-record.log"
  fi
  [ -f "$M7_WORK/measured.env" ] || die "measurement record missing at $M7_WORK/measured.env"
  # shellcheck disable=SC1090
  . "$M7_WORK/measured.env"
  # The record names artefacts in a tree this check did not build. Assert they
  # are THERE before anything is claimed about them — M6's review found four
  # assertions passing over a build directory that held nothing, because every
  # predicate returned 0 over a missing path.
  [ -n "${M7_TREE:-}" ] && [ -d "$M7_TREE" ] \
    || die "measurement names no tree, or a tree that is gone: [${M7_TREE:-}]"
  [ -f "$(m7_wasm_bin vm2_sim_tests)" ] \
    || die "the wasm vm2_sim_tests recorded in measured.env is not there: $(m7_wasm_bin vm2_sim_tests)"
}

# m7_tree_dirty -> the paths under barretenberg/ that differ from HEAD, EXCEPT
#   nodejs_module/. That one directory's CMakeLists runs `yarn --immutable` at
#   configure time and fails the whole native configure otherwise, so the native
#   side has to run a plain `yarn install` first, which rewrites `.yarnrc.yml`
#   and `yarn.lock`. M3, M6 and M7 all meet the same fact and all scope past that
#   directory AND PAST NOTHING ELSE.
m7_tree_dirty() {
  git -C "$M7_TREE" diff --name-only HEAD -- barretenberg \
    | grep -v '^barretenberg/cpp/src/barretenberg/nodejs_module/' \
    | tr '\n' ' ' | sed 's/ *$//'
}

# m7_require_artifacts <path...> — assert every named artefact exists before any
# predicate reads it, and die naming the first that does not.
m7_require_artifacts() {
  local p
  for p in "$@"; do
    [ -e "$p" ] || die "required artefact missing: $p"
  done
}
