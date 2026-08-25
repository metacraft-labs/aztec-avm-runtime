#!/usr/bin/env bash
# Shared machinery for the M10 checks — the AVM-module / server-module CMake
# split and the `AVM_WASM` flag, the last of the five prepared patches and the
# only one with no purpose except ours.
#
# M10 reuses M6's worktrees and M6's dev-shell configure/build helpers verbatim
# (lib_avm_wasm.sh must be sourced first). The trees this milestone needs are
# already M6's:
#
#   base    233d8e0993, pristine.
#   stack3  + patches 1,2,3. The "before the split" side of every comparison:
#           it isolates THIS patch, holding the three prerequisites fixed.
#   avm     + patch 4 as well. The tree under test.
#
# What M10 adds is a way to answer the question its own deliverable asks and
# that no amount of preset-sampling can: "every existing preset produces an
# identical target list before and after the split". `barretenberg/cpp` declares
# FORTY-TWO configure presets, most of which need a toolchain, a sanitizer
# runtime or a cross SDK this host does not have. Sampling four of them and
# saying "every" would be the class of claim this campaign keeps correcting.
#
# So the module guard is instead settled EXHAUSTIVELY, in CMake's own language.
# `src/CMakeLists.txt`'s module-guard region — from the `if(NOT BB_LITE)` that
# adds `lmdblib` down to the line before `if(SMT)` — contains nothing but
# `if`/`elseif`/`else`/`endif`, `set` and `add_subdirectory`. It is lifted out of
# each tree verbatim, every `add_subdirectory(X …)` is rewritten to
# `list(APPEND BB_ADDED "X")`, and the result is evaluated by a real `cmake -P`
# over all 32 assignments of the five variables its conditions reference:
# FUZZING, WASM, BB_LITE, AVM_WASM and FUZZING_AVM. Every preset that exists, and
# every preset that could exist, is one of those 32 rows.
#
# Three things make that a measurement rather than a re-implementation:
#
#   * the region is CMake TEXT taken from the tree, not conditions retyped here;
#   * the checks assert that the region contains no command outside that
#     vocabulary, so nothing was silently dropped by the rewrite; and
#   * the checks assert that the set of variables the region's conditions
#     reference is EXACTLY those five, which is what makes 32 rows exhaustive
#     rather than merely numerous. A sixth variable would make the enumeration
#     incomplete and the check says so instead of quietly under-covering.
#
# A mutation control runs the extractor against a copy of the patched file with
# one `add_subdirectory` line deleted and requires the table to move, because a
# table of 32 identical rows is also what an extractor that reads nothing
# produces.
#
# Nothing here has a skip path. A tree that cannot be prepared, a toolchain that
# cannot be realised or a configure that fails is an assertion failure or `die`.
#
# Not to be executed directly: sourced by verification/verify_cmake_split_*.sh
# and verify_avm_wasm_module_split_patch_applies.sh, AFTER lib.sh and
# lib_avm_wasm.sh.

# M10's own scratch — extracted regions, generated cmake scripts, truth tables,
# test transcripts. The builds themselves live in the shared M6 worktrees, which
# is what "reuse M6's build" means here. Small; the trees are M6_WORK's 8 GB.
M10_WORK="${M10_WORK:-$HOME/.cache/aztec-m10-cmake-split}"
require_work_dir "$M10_WORK" 2

M10_PATCH_DIR="$M6_UPSTREAM_BUGS/aztec-avm-wasm-cmake"
M10_PATCH="$M6_PATCH_4"
M10_PR_MD="$M10_PATCH_DIR/PR.md"
M10_VERIFY_SH="$M10_PATCH_DIR/verify.sh"
M10_SERIES_MD="$M6_UPSTREAM_BUGS/SERIES.md"

# The ten modules upstream's single `if(NOT FUZZING AND NOT WASM AND NOT BB_LITE)`
# block excludes, and the two groups the patch splits them into. Sorted,
# space-separated, pinned as identities.
M10_ALL_TEN="avm aztec cdb ipc nodejs_module vm2 vm2_wsdb world_state world_state_reference wsdb"
M10_AVM_GROUP="aztec vm2 world_state_reference"
M10_SERVER_GROUP="avm cdb ipc nodejs_module vm2_wsdb world_state wsdb"

# What the FUZZING_AVM block adds when FUZZING is also on. FOUR modules, not
# three: it carries `world_state` as well, because the `fuzzing-avm` preset sets
# MULTITHREADING=ON and MULTITHREADING=OFF is the whole reason the main guard's
# comment gives for excluding `world_state` from a fuzzing build. That is the
# precise form of the evidence — the AVM modules stand there without `ipc`,
# `wsdb`, `cdb`, `avm` or `nodejs_module` — and it is NOT the stronger "already
# builds exactly this set", which three documents said and which is false.
M10_FUZZING_AVM_GROUP="aztec vm2 world_state world_state_reference"

# The five variables the module-guard region's conditions reference. Asserted as
# an identity against the region itself; the 32-row enumeration is exhaustive
# only for as long as this holds.
M10_GUARD_VARS="AVM_WASM BB_LITE FUZZING FUZZING_AVM WASM"

# The commands the region is allowed to contain. Asserted, so the rewrite cannot
# have dropped something it did not understand.
M10_REGION_COMMANDS="add_subdirectory elseif endif if set"

# Build directories, all inside the shared M6 worktrees. Named for this milestone
# so they cannot collide with M6's, M7's, M8's or M9's.
M10_NATIVE_BUILD=build-m10-native
M10_WASM_BUILD=build-m10-wasm
M10_AVM_BUILD=build-m10-wasm-avm
M10_FUZZ_BUILD=build-m10-fuzzing
M10_FUZZ_AVM_BUILD=build-m10-fuzzing-avm
M10_FUZZ_TOOLING_BUILD=build-m10-fuzzing-avm-tooling

export M10_WORK M10_PATCH_DIR M10_PATCH

# ---------------------------------------------------------------------------
# m10_cmakelists <tree> -> the path of that tree's src/CMakeLists.txt
# ---------------------------------------------------------------------------
m10_cmakelists() { printf '%s\n' "$1/barretenberg/cpp/src/CMakeLists.txt"; }

# ---------------------------------------------------------------------------
# m10_region_raw <cmakelists> -> the module-guard region, verbatim
#
# Delimited by two landmarks that exist in every version of the file this
# campaign has seen: the `if(NOT BB_LITE)` guarding `lmdblib` (start) and
# `if(SMT)` (end, exclusive). DIES if either is missing or out of order, rather
# than returning an empty region — an empty region makes every downstream
# comparison pass for the wrong reason, which is this campaign's most-repeated
# defect.
# ---------------------------------------------------------------------------
m10_region_raw() {
  local f="$1" s e
  [ -f "$f" ] || die "no src/CMakeLists.txt at $f"
  s=$(grep -n 'add_subdirectory(barretenberg/lmdblib)' "$f" | head -1 | cut -d: -f1)
  e=$(grep -n '^if(SMT)$' "$f" | head -1 | cut -d: -f1)
  case "${s:-}${e:-}" in
    *[!0-9]*|'') die "could not locate the module-guard region in $f (lmdblib=${s:-none} SMT=${e:-none})" ;;
  esac
  [ "$s" -gt 1 ] && [ "$e" -gt "$s" ] \
    || die "the module-guard landmarks in $f are out of order (lmdblib=$s SMT=$e)"
  sed -n "$((s - 1)),$((e - 1))p" "$f"
}

# ---------------------------------------------------------------------------
# m10_region <cmakelists> -> the region rewritten for `cmake -P`
#
# `add_subdirectory(<first-arg> …)` becomes `list(APPEND BB_ADDED "<label>")`,
# where <label> is the first argument with a leading `barretenberg/` stripped and
# `$` replaced by `@` so a `${CMAKE_SOURCE_DIR}` path stays an inert label rather
# than expanding to something different in `cmake -P`. Nothing else is touched.
# ---------------------------------------------------------------------------
m10_region() {
  m10_region_raw "$1" | awk '
    /^[ \t]*add_subdirectory\(/ {
      line = $0
      sub(/^[ \t]*add_subdirectory\(/, "", line)
      split(line, a, /[ )]/)
      lbl = a[1]
      gsub(/\$/, "@", lbl)
      sub(/^barretenberg\//, "", lbl)
      printf("list(APPEND BB_ADDED \"%s\")\n", lbl)
      next
    }
    { print }'
}

# m10_region_command_names <cmakelists> -> the distinct CMake commands in the
# region, sorted and space-separated. The rewrite is only faithful if this is a
# subset of M10_REGION_COMMANDS.
#
# The scan is deliberately NOT anchored to the start of a line and NOT
# case-sensitive. CMake command names are case-INSENSITIVE, so an `IF(` or an
# `Include(` is a command this region is not allowed to contain, and a second
# command on the same line is one too — an anchored, lowercase-only scan would
# report neither, which turns "the region uses no command outside this vocabulary"
# into a claim about how upstream happens to have typed it.
m10_region_command_names() {
  m10_region_raw "$1" \
    | sed -e 's/#.*$//' \
    | grep -oiE '[A-Za-z_][A-Za-z0-9_]*[ \t]*\(' \
    | tr -d ' \t(' | tr 'A-Z' 'a-z' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# m10_region_condition_vars <cmakelists> -> the identifiers the region's
# `if()`/`elseif()` conditions reference, sorted and space-separated, minus any
# variable the region `set()`s itself (BB_BUILD_AVM_MODULES is internal to the
# patch and is not an input).
m10_region_condition_vars() {
  local raw; raw="$(m10_region_raw "$1")"
  local internal
  internal="$(printf '%s\n' "$raw" | sed -nE 's/^[ \t]*set\(([A-Za-z_][A-Za-z0-9_]*).*/\1/p' | sort -u)"
  printf '%s\n' "$raw" \
    | sed -e 's/#.*$//' \
    | grep -E '^[ \t]*(if|elseif)\(' \
    | sed -E 's/^[ \t]*(if|elseif)\(//; s/\)[ \t]*$//' \
    | tr ' ' '\n' \
    | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' \
    | grep -vxE 'NOT|AND|OR|ON|OFF|TRUE|FALSE|STREQUAL|MATCHES|EQUAL|DEFINED' \
    | { if [ -n "$internal" ]; then grep -vxF "$internal"; else cat; fi; } \
    | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# ---------------------------------------------------------------------------
# m10_truth_table <cmakelists> [<label>]
#
# One row per assignment of the five guard variables, on stdout:
#
#     FWLAV<TAB>module,module,…
#
# where FWLAV is FUZZING WASM BB_LITE AVM_WASM FUZZING_AVM as 0/1 and the module
# list is sorted. Evaluated by `cmake -P` over the region lifted from the tree,
# so the conditions are upstream's own text and not a transcription of it.
#
# `cmake` is taken from the fork's dev shell, like every other tool in this
# campaign, so the answer does not depend on what happens to be installed.
# ---------------------------------------------------------------------------
m10_truth_table() {
  local f="$1" label="${2:-$(basename "$(dirname "$(dirname "$(dirname "$(dirname "$f")")")")")}"
  local d="$M10_WORK/table-$label"
  rm -rf "$d"; mkdir -p "$d"
  m10_region "$f" >"$d/region.cmake"
  [ -s "$d/region.cmake" ] || die "the extracted region for $label is empty"

  local F W L A V
  for F in 0 1; do for W in 0 1; do for L in 0 1; do for A in 0 1; do for V in 0 1; do
    {
      printf 'set(FUZZING %s)\n'      "$([ "$F" = 1 ] && echo ON || echo OFF)"
      printf 'set(WASM %s)\n'         "$([ "$W" = 1 ] && echo ON || echo OFF)"
      printf 'set(BB_LITE %s)\n'      "$([ "$L" = 1 ] && echo ON || echo OFF)"
      printf 'set(AVM_WASM %s)\n'     "$([ "$A" = 1 ] && echo ON || echo OFF)"
      printf 'set(FUZZING_AVM %s)\n'  "$([ "$V" = 1 ] && echo ON || echo OFF)"
      echo 'set(BB_ADDED "")'
      cat "$d/region.cmake"
      echo 'list(SORT BB_ADDED)'
      echo 'list(JOIN BB_ADDED "," BB_OUT)'
      echo 'message("${BB_OUT}")'
    } >"$d/run-$F$W$L$A$V.cmake"
  done; done; done; done; done

  m6_in_devshell '
    d="$1"
    for f in "$d"/run-?????.cmake; do
      k="${f##*/run-}"; k="${k%.cmake}"
      printf "%s\t%s\n" "$k" "$(cmake -P "$f" 2>&1)"
    done
  ' "$d"
}

# ---------------------------------------------------------------------------
# m10_assert_same_lines <description> <a> <b>
#
# Two newline-separated sets are equal. Reports the SIZE of the symmetric
# difference and the first few members of it, not a hash: a check whose failure
# message is two md5 sums tells a reader that something moved and nothing about
# what. Both sides are asserted non-empty by the caller before this is used —
# two empty sets are equal.
# ---------------------------------------------------------------------------
m10_assert_same_lines() {
  local desc="$1" a="$2" b="$3" only_a only_b n
  only_a="$(comm -23 <(printf '%s\n' "$a" | sort -u) <(printf '%s\n' "$b" | sort -u))"
  only_b="$(comm -13 <(printf '%s\n' "$a" | sort -u) <(printf '%s\n' "$b" | sort -u))"
  n=$(( $(printf '%s' "$only_a" | grep -c . || true) + $(printf '%s' "$only_b" | grep -c . || true) ))
  if [ "$n" -eq 0 ]; then
    pass "$desc  [$(printf '%s\n' "$a" | sort -u | grep -c .) identical]"
  else
    fail "$desc  $n differ; only before: $(printf '%s' "$only_a" | tr '\n' ' ' | cut -c1-200); only after: $(printf '%s' "$only_b" | tr '\n' ' ' | cut -c1-200)"
  fi
}

# m10_table_row <table-file> <FWLAV> -> that row's module list
m10_table_row() { awk -F'\t' -v k="$2" '$1 == k { print $2 }' "$1"; }

# m10_set_diff <a-csv> <b-csv> -> the entries in <b> that are not in <a>, sorted
# and space-separated. Used to name what a differing row gained and lost, rather
# than reporting that it differs.
m10_set_diff() {
  comm -13 <(printf '%s\n' "$1" | tr ',' '\n' | sed '/^$/d' | sort) \
           <(printf '%s\n' "$2" | tr ',' '\n' | sed '/^$/d' | sort) \
    | tr '\n' ' ' | sed 's/ $//'
}

# ---------------------------------------------------------------------------
# m10_native_preset_configure <tree> <preset> <build-dir> [extra cmake args...]
#
# m6_native_configure generalised to any preset. Two environment facts are
# handled here for the reasons M3, M4 and M6 each recorded: `nodejs_module`'s
# CMakeLists runs `yarn --immutable` at configure time and fails the WHOLE
# configure when node-addon-api cannot be resolved, and gtest discovery wants the
# host libstdc++ on LD_LIBRARY_PATH.
#
# The compilers are passed explicitly because three of the fuzzing presets set
# `CC=clang-20` / `CXX=clang++-20` in their `environment` block, and the dev
# shell provides `clang-20` but not `clang++-20`. A command-line
# CMAKE_CXX_COMPILER wins over the environment, so the preset is still exercised
# verbatim in every respect that this milestone is about — the cache variables
# that drive the module guard.
# ---------------------------------------------------------------------------
m10_native_preset_configure() {
  local tree="$1" preset="$2" bdir="$3"; shift 3
  local log="$tree/m10-$bdir.log"
  m6_in_devshell '
    tree="$1"; preset="$2"; bdir="$3"; shift 3
    cd "$tree/barretenberg/cpp" || exit 90
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    if [ ! -d src/barretenberg/nodejs_module/node_modules ]; then
      ( cd src/barretenberg/nodejs_module && yarn install ) || exit 92
    fi
    rm -rf "$bdir"
    cmake --preset "$preset" -B "$bdir" -DAVM_TRANSPILER_LIB= \
      -DCMAKE_C_COMPILER="$(command -v clang)" -DCMAKE_CXX_COMPILER="$(command -v clang++)" \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER "$@"
    rc=$?
    echo "### configure_rc=$rc"
    exit $rc
  ' "$tree" "$preset" "$bdir" "$@" >"$log" 2>&1
}

# m10_preset_names <tree> -> every configure preset the tree declares, sorted
m10_preset_names() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(" ".join(sorted(p["name"] for p in d["configurePresets"])))' \
    "$1/barretenberg/cpp/CMakePresets.json"
}

# m10_preset_count <tree> -> how many there are
m10_preset_count() { m10_preset_names "$1" | wc -w | tr -d ' '; }

# ---------------------------------------------------------------------------
# m10_module_targets <tree> <build-dir> <module> -> 1 if the module contributes a
# target to that configured build, 0 otherwise.
#
# Read from CMake's own regenerated target graph rather than from the CMakeLists
# text. DIES through m6_graph_nodes if the graph cannot be generated.
# ---------------------------------------------------------------------------
m10_graph_has() { # <nodes-blob> <name>
  str_has_line "$1" "$2" && echo 1 || echo 0
}

# ---------------------------------------------------------------------------
# m10_module_targets <tree> <module> -> the target names that module declares
#
# DERIVED from the module's own CMakeLists.txt rather than transcribed here,
# because the mapping is not obvious and a transcription would age: the `avm`
# module's target is `bb-avm-sim`, `wsdb` declares `wsdb_ipc_client` and
# `aztec-wsdb`, `cdb` declares `cdb_ipc_client`, `vm2_wsdb` declares
# `wsdb_ipc_merkle_db`, and `vm2` declares both `vm2_sim` and `vm2`. A check that
# asserted the absence of a target name nobody ever declares would be the vacuous
# version of every assertion below.
# ---------------------------------------------------------------------------
m10_module_targets() {
  local f="$1/barretenberg/cpp/src/barretenberg/$2/CMakeLists.txt"
  [ -f "$f" ] || die "no CMakeLists.txt for module $2 under $1"
  sed -e 's/#.*$//' "$f" | tr '\n' ' ' \
    | grep -oE '(barretenberg_module_with_sources|barretenberg_module|add_library|add_executable)\([[:space:]]*[A-Za-z0-9_.-]+' \
    | sed -E 's/^[a-z_]+\([[:space:]]*//' \
    | sort -u
}

# ---------------------------------------------------------------------------
# m10_gtest_names <binary-path> -> the declared test names, "Suite.Case" per line
#
# Run through the dev shell so the host libstdc++ is on LD_LIBRARY_PATH. Names,
# not counts: equal counts survive a rename or a drop-plus-addition (M3's
# lesson), and this is the comparison that establishes native neutrality for the
# three source files the patch changes.
# ---------------------------------------------------------------------------
m10_gtest_names() {
  local bin="$1"
  [ -x "$bin" ] || die "no test binary at $bin — there is nothing to list"
  m6_in_devshell '
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    "$1" --gtest_list_tests 2>/dev/null
  ' "$bin" \
  | awk '
      /^[^ ].*\.$/ { suite = $1; next }
      /^  [^ ]/    { name = $1; sub(/#.*/, "", name); if (suite != "") print suite name }
    ' | sed 's/[[:space:]]*$//' | sort -u
}

# m10_gtest_run <binary> <stdout-file> <stderr-file> [args...] -> exit status
#
# stdout and stderr are kept APART. common/log.cpp sets bb_log_level = VERBOSE
# under __wasm__ and INFO otherwise, and M8 spent a run discovering what a merged
# stream does to a comparison; these are native binaries, but the rule is the
# rule.
m10_gtest_run() {
  local bin="$1" out="$2" err="$3"; shift 3
  [ -x "$bin" ] || die "no test binary at $bin — there is nothing to run"
  m6_in_devshell '
    bin="$1"; err="$2"; shift 2
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    "$bin" "$@" 2>"$err"
  ' "$bin" "$err" "$@" >"$out"
}

# m10_gtest_passed <stdout-file> -> the "[       OK ]" test names, sorted
m10_gtest_passed() {
  grep -oE '^\[       OK \] [^ ]+' "$1" 2>/dev/null | sed 's/^\[       OK \] //' | sort -u
}

# m10_gtest_ran <stdout-file> -> the number gtest says ran, or "-"
m10_gtest_ran() {
  grep -oE '[0-9]+ tests? from [0-9]+ test suites? ran' "$1" 2>/dev/null \
    | grep -oE '^[0-9]+' | tail -1 || true
}
