#!/usr/bin/env bash
# verify_compiler_cache_effective
#
# The dev shells now provide a compiler cache. This checks that it is ON THE COMPILER LAUNCHER PATH
# and not merely on PATH, because the second state is worse than having none: it looks solved.
#
# THAT WAS THE ACTUAL STATE BEFORE M14. `pkgs.ccache` was in the fork's devShell package list from
# M0. Nothing invoked it: barretenberg's CMake has no ccache integration of its own, and exactly one
# verification lib (M3's) passed `-DCMAKE_CXX_COMPILER_LAUNCHER` on the command line. The runtime
# repo's shell had no ccache at all. Meanwhile `m6_native_configure` deletes the build directory
# before every configure, so M6, M7, M9 and M10's native builds were cold on EVERY run — which is
# why M9's seventh check, which builds upstream's `vm2_tests` twice, killed three separate regression
# sweeps.
#
# THE FIVE THINGS ASSERTED, and why each is a count or an identity rather than a wish:
#
#   A. WIRING. Both shells export the same six variables. The launcher reaches CMakeCache.txt and
#      build.ninja, and it does NOT reach compile_commands.json — which matters because M6, M10 and
#      M13 read the compile database and M13 counts translation units out of it.
#
#   B. IT FIRES. Counters, not presence. A cold pass over a real barretenberg target with an EMPTY
#      private cache must be 100% misses; a warm pass with the BUILD DIRECTORY DELETED AGAIN must be
#      100% direct hits. Deleting the build directory is the point: it separates what the cache saves
#      from what ninja's incrementality saves.
#
#   C. IT CANNOT MASK A BASE-VERSUS-PATCHED DIFFERENCE. This is the one that protects M3-M10's
#      neutrality evidence. Compiled from M14's own two trees, which differ in exactly three files:
#      the miss count must equal the number of changed translation units, the hits must come from a
#      DIFFERENT absolute path than the one that populated them, and the resulting libraries must
#      differ.
#
#   D. IT CANNOT MASK A TOOLCHAIN DIFFERENCE. wasi-sdk 27 and 33 compiling the same bytes must MISS
#      and must produce different objects. Every binary in /nix/store has mtime 1970, so ccache's
#      `mtime` default would be discriminating two toolchains by SIZE; the shells set
#      `compiler_check` to `%compiler% --version` instead, and this measures that it is in force.
#
#   E. IT REACHES THE WASM SIDE. The same launcher, the same cache, the wasi-sdk clang.
#
# It uses a PRIVATE cache directory under $M14_WORK for every measurement, so nothing here depends on
# the state of the shared cache and nothing here disturbs it.
#
# Run: just verify-compiler-cache

TEST_NAME="verify_compiler_cache_effective"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m14_world_state.sh"

require_nix
command -v python3 >/dev/null 2>&1 || die "python3 is required"
require_work_dir "$M14_WORK" 8

CC_DIR="$M14_WORK/ccache-check"
SCRATCH="$M14_WORK/ccache-scratch"
rm -rf "$CC_DIR" "$SCRATCH"
mkdir -p "$CC_DIR" "$SCRATCH"

# The six exports, as the shells are supposed to make them.
# In C collation `CMAKE_CXX_…` sorts before `CMAKE_C_…` ('X' is 0x58, '_' is 0x5F), and the probe
# forces LC_ALL=C so this order is a property of the check rather than of the caller's environment.
EXPECTED_VARS="CCACHE_BASEDIR
CCACHE_COMPILERCHECK
CCACHE_DIR
CCACHE_MAXSIZE
CMAKE_CXX_COMPILER_LAUNCHER
CMAKE_C_COMPILER_LAUNCHER"

echo "== A. wiring: both shells, and the launcher on the path CMake reads =="
# BOTH dev shells print a banner from their shellHook, ON STDOUT, so everything up to a sentinel is
# dropped — the machinery M4 built and M6, M9, M12 and M13 reuse. The first version of this check
# did not, and compared the banner line against a variable name. And LC_ALL=C, because the sort
# order of `CMAKE_CXX_COMPILER_LAUNCHER` against `CMAKE_C_COMPILER_LAUNCHER` differs between
# collations and an identity assertion cannot depend on the caller's locale.
CC_SENTINEL=$'\001M14CC'
shell_probe() { # <repo> <script>
  ( cd "$1" && nix develop --command bash -c "printf '%s\n' '$CC_SENTINEL'; export LC_ALL=C; $2" ) 2>/dev/null \
    | awk -v s="$CC_SENTINEL" 'seen { print } $0 == s { seen = 1 }'
}
for repo in "$FORK_ROOT" "$REPO_ROOT"; do
  name="$(basename "$repo")"
  ENVOUT="$(shell_probe "$repo" 'env | grep -E "^(CCACHE_[A-Z]+|CMAKE_C(XX)?_COMPILER_LAUNCHER)=" | sort')"
  GOT="$(printf '%s\n' "$ENVOUT" | cut -d= -f1 | LC_ALL=C sort)"
  assert_eq "$name: exactly these six variables are exported" "$EXPECTED_VARS" "$GOT"
  assert_eq "$name: the C launcher is ccache" "ccache" \
    "$(printf '%s\n' "$ENVOUT" | sed -n 's/^CMAKE_C_COMPILER_LAUNCHER=//p')"
  assert_eq "$name: the C++ launcher is ccache" "ccache" \
    "$(printf '%s\n' "$ENVOUT" | sed -n 's/^CMAKE_CXX_COMPILER_LAUNCHER=//p')"
  assert_eq "$name: compiler_check is NOT ccache's mtime default" "%compiler% --version" \
    "$(printf '%s\n' "$ENVOUT" | sed -n 's/^CCACHE_COMPILERCHECK=//p')"
  assert_eq "$name: base_dir is set, so two work directories share entries" "$HOME" \
    "$(printf '%s\n' "$ENVOUT" | sed -n 's/^CCACHE_BASEDIR=//p')"
  assert_nix_store "$name: and ccache itself comes from the flake" \
    "$(shell_probe "$repo" 'command -v ccache')"
done

# sloppiness must stay EMPTY: every relaxation licenses returning an object for a compile that was
# not quite the same one, which is exactly what the neutrality evidence cannot afford.
assert_eq "sloppiness is empty, so nothing is treated as close enough" "" \
  "$(shell_probe "$FORK_ROOT" 'ccache -p | sed -n "s/.*sloppiness = //p"' | tr -d ' ')"

# Upstream has no ccache integration of its own, so the env var is the whole mechanism. Asserted, so
# that if upstream adds one later this stops being a silent double-configuration.
assert_eq "barretenberg's own CMake still has no compiler-launcher setting" "0" \
  "$(git -C "$FORK_ROOT" grep -ciE 'ccache|COMPILER_LAUNCHER' "$M6_BASE_REV" -- \
       barretenberg/cpp/CMakeLists.txt barretenberg/cpp/CMakePresets.json 'barretenberg/cpp/cmake/*' 2>/dev/null \
     | awk -F: '{s+=$NF} END {print s+0}')"

echo
echo "== B. it fires: cold is all misses, warm is all direct hits, build directory deleted between =="
# The two trees are the audit's. This check does not prepare or build a tree of its own: the
# neutrality control in section D needs the SAME pair every other M14 check measured, and a pair
# this check made for itself would not be that pair.
m14_measured
assert_dir "the audit's base tree is present" "$M14_BASE_TREE"
assert_dir "the audit's patched tree is present" "$M14_TREE"
CACHE_RESULT="$SCRATCH/coldwarm.txt"
m6_in_devshell '
  tree="$1"; cc="$2"; out="$3"
  export CCACHE_DIR="$cc"
  cd "$tree/barretenberg/cpp" || exit 90
  export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
  : >"$out"
  for pass in cold warm; do
    ccache -z >/dev/null
    rm -rf build-cachecheck
    cmake --preset default -B build-cachecheck -DAVM_TRANSPILER_LIB= \
      -DCMAKE_C_COMPILER="$(command -v clang)" -DCMAKE_CXX_COMPILER="$(command -v clang++)" \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER >/dev/null 2>&1
    echo "${pass}_configure_rc=$?" >>"$out"
    s=$(date +%s)
    ninja -C build-cachecheck world_state_reference_objects crypto_merkle_tree_objects >/dev/null 2>&1
    echo "${pass}_build_rc=$?" >>"$out"
    echo "${pass}_seconds=$(( $(date +%s) - s ))" >>"$out"
    ccache -s | awk -v p="$pass" "
      /^Cacheable calls:/ { print p \"_cacheable=\" \$3 }
      /^  Hits:/          { if (!h++) print p \"_hits=\" \$2 }
      /^    Direct:/      { if (!d++) print p \"_direct=\" \$2 }
      /^  Misses:/        { if (!m++) print p \"_misses=\" \$2 }" >>"$out"
  done
  echo "cache_launcher_in_cmakecache=$(grep -c COMPILER_LAUNCHER build-cachecheck/CMakeCache.txt)" >>"$out"
  echo "launcher_in_build_ninja=$(grep -c "^  LAUNCHER = ccache" build-cachecheck/build.ninja)" >>"$out"
  python3 - build-cachecheck/compile_commands.json >>"$out" <<PY
import json, re, sys
db = json.load(open(sys.argv[1]))
print("compdb_entries=%d" % len(db))
print("compdb_invoking_ccache=%d" % sum(1 for e in db if re.search(r"(^|/)ccache(\s|$)", e["command"])))
print("compdb_distinct_argv0=%d" % len({e["command"].split()[0] for e in db}))
PY
' "$M14_BASE_TREE" "$CC_DIR" "$CACHE_RESULT" >"$SCRATCH/coldwarm.log" 2>&1
CW_RC=$?
assert_eq "the cold/warm measurement ran" "0" "$CW_RC"
[ -f "$CACHE_RESULT" ] || die "no cold/warm result — see $SCRATCH/coldwarm.log"
k() { m14_key "$CACHE_RESULT" "$1"; }

assert_eq "the cold configure exited 0" "0" "$(k cold_configure_rc)"
assert_eq "the cold build exited 0" "0" "$(k cold_build_rc)"
assert_eq "the warm configure exited 0" "0" "$(k warm_configure_rc)"
assert_eq "the warm build exited 0" "0" "$(k warm_build_rc)"

COLD_CACHEABLE="$(k cold_cacheable)"; COLD_MISSES="$(k cold_misses)"; COLD_HITS="$(k cold_hits)"
WARM_CACHEABLE="$(k warm_cacheable)"; WARM_MISSES="$(k warm_misses)"; WARM_HITS="$(k warm_hits)"
# The two targets are `world_state_reference_objects` and `crypto_merkle_tree_objects` — eighteen
# translation units, chosen so the run is a few seconds and so the CHANGED header is included by
# exactly one of them, which is what makes section D's miss count an exact 1 rather than a number
# somebody has to derive from depfiles. The HEADLINE cold/warm figure is not this one: it was
# measured on upstream's own `vm2_tests`, 639 translation units, 327 s cold against 9 s warm with
# the build directory deleted between the passes, and it is recorded in the Justfile and in the
# milestone. This check re-measures the SHAPE cheaply enough to run every time.
assert_ge "the cold pass compiled a real number of translation units" 15 "$COLD_CACHEABLE"
assert_eq "and every one of them MISSED — the private cache really was empty" \
  "$COLD_CACHEABLE" "$COLD_MISSES"
assert_eq "with no hits at all" "0" "$COLD_HITS"
assert_eq "the warm pass offered the cache the same number of compiles" "$COLD_CACHEABLE" "$WARM_CACHEABLE"
assert_eq "and every one of them HIT" "$WARM_CACHEABLE" "$WARM_HITS"
assert_eq "all of them by the direct-mode path" "$WARM_HITS" "$(k warm_direct)"
assert_eq "with no misses at all" "0" "$WARM_MISSES"
note "cold ${COLD_CACHEABLE} compiles in $(k cold_seconds)s; warm $(k warm_seconds)s, build directory deleted in between"

echo
echo "== C. and it does not leak into the compile database, which three milestones read =="
assert_eq "the launcher IS in CMakeCache.txt" "2" "$(k cache_launcher_in_cmakecache)"
assert_ge "and IS in build.ninja" 1 "$(k launcher_in_build_ninja)"
assert_ge "the compile database has entries" 500 "$(k compdb_entries)"
assert_eq "and NOT ONE of them invokes ccache" "0" "$(k compdb_invoking_ccache)"
assert_eq "there are exactly two distinct compilers in it, the C and C++ drivers" "2" \
  "$(k compdb_distinct_argv0)"
note "a bare grep for 'ccache' in that file returns thousands of lines, because the work directory is named aztec-m14-*; the needle is the invoked program, not the substring"

echo
echo "== D. THE NEUTRALITY CONTROL: two trees that differ cannot share an object =="
# M14's own base and patched trees. They differ in three files; two of them are in the component
# under test and one is a test source. Compiled with the SAME warm private cache, from a DIFFERENT
# absolute path than the one that populated it.
NEUTRAL="$SCRATCH/neutral.txt"
m6_in_devshell '
  base="$1"; ext="$2"; cc="$3"; out="$4"
  export CCACHE_DIR="$cc"
  export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
  : >"$out"
  cd "$ext/barretenberg/cpp" || exit 90
  ccache -z >/dev/null
  rm -rf build-cachecheck
  cmake --preset default -B build-cachecheck -DAVM_TRANSPILER_LIB= \
    -DCMAKE_C_COMPILER="$(command -v clang)" -DCMAKE_CXX_COMPILER="$(command -v clang++)" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER >/dev/null 2>&1
  echo "ext_configure_rc=$?" >>"$out"
  ninja -C build-cachecheck world_state_reference_objects crypto_merkle_tree_objects >/dev/null 2>&1
  echo "ext_build_rc=$?" >>"$out"
  ccache -s | awk "
    /^Cacheable calls:/ { print \"ext_cacheable=\" \$3 }
    /^  Hits:/          { if (!h++) print \"ext_hits=\" \$2 }
    /^  Misses:/        { if (!m++) print \"ext_misses=\" \$2 }" >>"$out"
  # The OBJECTS, not a library: `*_objects` targets produce no archive. Two of them, and the pair is
  # the point — the object of the translation unit the patch changes must DIFFER between the trees,
  # and the object of one it does not touch must be BYTE-IDENTICAL, which is the cross-directory
  # hit proven at the artefact rather than at the counter.
  d=CMakeFiles/world_state_reference_objects.dir
  for arm in base ext; do
    root="$base"; [ "$arm" = ext ] && root="$ext"
    od="$root/barretenberg/cpp/build-cachecheck/src/barretenberg/world_state_reference/$d"
    echo "${arm}_changed_obj_sha=$(sha256sum "$od/memory_merkle_db.cpp.o" | cut -d" " -f1)" >>"$out"
    echo "${arm}_changed_obj_bytes=$(stat -Lc%s "$od/memory_merkle_db.cpp.o")" >>"$out"
    echo "${arm}_untouched_obj_sha=$(sha256sum "$od/merkle_tree_id.cpp.o" | cut -d" " -f1)" >>"$out"
  done
' "$M14_BASE_TREE" "$M14_TREE" "$CC_DIR" "$NEUTRAL" >"$SCRATCH/neutral.log" 2>&1
N_RC=$?
assert_eq "the neutrality measurement ran" "0" "$N_RC"
[ -f "$NEUTRAL" ] || die "no neutrality result — see $SCRATCH/neutral.log"
n() { m14_key "$NEUTRAL" "$1"; }
assert_eq "the patched configure exited 0" "0" "$(n ext_configure_rc)"
assert_eq "the patched build exited 0" "0" "$(n ext_build_rc)"

# How many translation units the two trees genuinely differ in, derived from the diff rather than
# typed: the changed .cpp itself, plus every .cpp that includes a changed header. For this component
# that is memory_merkle_db.cpp alone in the targets built here.
CHANGED_CPP="$(git -C "$M14_TREE" diff --name-only "$M6_BASE_REV" HEAD \
                 -- 'barretenberg/cpp/src/barretenberg/world_state_reference/*' | grep -c '\.cpp$')"
CHANGED_HPP="$(git -C "$M14_TREE" diff --name-only "$M6_BASE_REV" HEAD \
                 -- 'barretenberg/cpp/src/barretenberg/world_state_reference/*' | grep -c '\.hpp$')"
assert_eq "the patch changes one .cpp in this component" "1" "$CHANGED_CPP"
assert_eq "and one .hpp" "1" "$CHANGED_HPP"
assert_eq "so exactly one translation unit in these targets MISSED" "1" "$(n ext_misses)"
assert_eq "and every other compile was served from the base tree's entries" \
  "$(( $(n ext_cacheable) - 1 ))" "$(n ext_hits)"
assert_ge "which is a real number of cross-directory hits" 12 "$(n ext_hits)"
note "the hits came from a different absolute path than the one that populated them: CCACHE_BASEDIR is what makes that possible, and CONTENT is what still decides"

BASE_SHA="$(n base_changed_obj_sha)"; EXT_SHA="$(n ext_changed_obj_sha)"
BASE_UNTOUCHED="$(n base_untouched_obj_sha)"; EXT_UNTOUCHED="$(n ext_untouched_obj_sha)"
# BOTH digests on each side, and their LENGTHS, in one assertion each. The untouched pair is
# included here rather than left to the equality below on purpose: `sha256sum` of a file that is not
# there prints nothing, so two absent objects would satisfy "byte-identical across them" and satisfy
# "not the same object as the changed one" as well. That is the shape M14's own review named — a
# comparison two empty strings pass — and this is where it could still have occurred, because
# `*_objects` targets produce no archive and the pair below is read out of the object directory.
assert_eq "both objects on the base side are real 64-hex digests, not two absences" "64:64" \
  "${#BASE_SHA}:${#BASE_UNTOUCHED}"
assert_eq "and both on the patched side" "64:64" "${#EXT_SHA}:${#EXT_UNTOUCHED}"
assert_false "the object of the CHANGED translation unit differs between the trees" \
  test "$BASE_SHA" = "$EXT_SHA"
assert_eq "while the object of an UNTOUCHED one is byte-identical across them" \
  "$BASE_UNTOUCHED" "$EXT_UNTOUCHED"
assert_false "and those two are not the same object as each other, so the pair is not one file twice" \
  test "$BASE_SHA" = "$BASE_UNTOUCHED"
note "changed object: base $(n base_changed_obj_bytes) bytes, patched $(n ext_changed_obj_bytes) bytes; the claim is on the DIGEST because two different binaries can share a length — upstream's own vm2_tests is 264,319,040 bytes from both trees and differs by sha256"

echo
echo "== E. two toolchains compiling the same bytes must MISS =="
TOOL="$SCRATCH/toolchain.txt"
m6_in_devshell '
  cc="$1"; work="$2"; out="$3"
  export CCACHE_DIR="$cc"
  s27=$(nix build --no-link --print-out-paths "'"$FORK_ROOT"'#wasi-sdk-27" 2>/dev/null)
  s33=$(nix build --no-link --print-out-paths "'"$FORK_ROOT"'#wasi-sdk" 2>/dev/null)
  : >"$out"
  echo "sdk27_version=$(head -1 "$s27/VERSION")" >>"$out"
  echo "sdk33_version=$(head -1 "$s33/VERSION")" >>"$out"
  mkdir -p "$work/tool" && cd "$work/tool" || exit 90
  printf "int probe(){return 7;}\n" > a.cpp
  ccache -z >/dev/null
  ccache "$s33/bin/clang++" --target=wasm32-wasip1 --sysroot="$s33/share/wasi-sysroot" -O2 -c a.cpp -o a33.o 2>/dev/null
  echo "first33_rc=$?" >>"$out"
  ccache "$s33/bin/clang++" --target=wasm32-wasip1 --sysroot="$s33/share/wasi-sysroot" -O2 -c a.cpp -o a33b.o 2>/dev/null
  echo "second33_rc=$?" >>"$out"
  ccache "$s27/bin/clang++" --target=wasm32-wasi --sysroot="$s27/share/wasi-sysroot" -O2 -c a.cpp -o a27.o 2>/dev/null
  echo "sdk27_rc=$?" >>"$out"
  ccache -s | awk "
    /^Cacheable calls:/ { print \"cacheable=\" \$3 }
    /^  Hits:/          { if (!h++) print \"hits=\" \$2 }
    /^  Misses:/        { if (!m++) print \"misses=\" \$2 }" >>"$out"
  echo "sha33=$(sha256sum a33.o | cut -d" " -f1)" >>"$out"
  echo "sha33b=$(sha256sum a33b.o | cut -d" " -f1)" >>"$out"
  echo "sha27=$(sha256sum a27.o | cut -d" " -f1)" >>"$out"
  # -L, because bin/clang++ is a SYMLINK to clang: a bare stat reports five bytes, the length of
  # the link target string, and the note below read "5 vs 5" before this was fixed.
  echo "size33=$(stat -Lc%s "$s33/bin/clang++")" >>"$out"
  echo "size27=$(stat -Lc%s "$s27/bin/clang++")" >>"$out"
' "$CC_DIR" "$SCRATCH" "$TOOL" >"$SCRATCH/toolchain.log" 2>&1
T_RC=$?
assert_eq "the toolchain measurement ran" "0" "$T_RC"
[ -f "$TOOL" ] || die "no toolchain result — see $SCRATCH/toolchain.log"
t() { m14_key "$TOOL" "$1"; }
assert_prefix "wasi-sdk 27 is really release 27" "27." "$(t sdk27_version)"
assert_prefix "wasi-sdk 33 is really release 33" "33." "$(t sdk33_version)"
assert_eq "the first wasm compile succeeded" "0" "$(t first33_rc)"
assert_eq "the second, identical, succeeded" "0" "$(t second33_rc)"
assert_eq "the wasi-sdk 27 compile succeeded" "0" "$(t sdk27_rc)"
assert_eq "the same toolchain on the same bytes HIT once" "1" "$(t hits)"
assert_eq "and the other two compiles MISSED" "2" "$(t misses)"
assert_eq "the repeated compile produced the same object" "$(t sha33)" "$(t sha33b)"
assert_false "and the other toolchain produced a different one" test "$(t sha33)" = "$(t sha27)"
note "this is what compiler_check must catch, and mtime could not have been trusted to: both clang++ binaries have mtime 1970 in /nix/store, so mtime discriminates them only by size ($(t size27) vs $(t size33))"

echo
echo "== F. the wasm side is the same cache and the same ccache binary =="
# Section E's three compiles are wasi-sdk clang++ invocations through `ccache`, and they were
# accounted for in the SAME private cache directory the native passes used. That is the wasm half of
# "wired so both the native and the wasm/wasi-sdk builds use it", measured rather than assumed.
assert_eq "all three wasm compiles were cacheable calls in this cache" "3" "$(t cacheable)"
assert_eq "and they account for every hit and miss recorded in it" "3" \
  "$(( $(t hits) + $(t misses) ))"
assert_eq "ccache resolves to one binary in both shells" \
  "$(shell_probe "$FORK_ROOT" 'command -v ccache')" "$(shell_probe "$REPO_ROOT" 'command -v ccache')"

rm -rf "$M14_BASE_TREE/barretenberg/cpp/build-cachecheck" "$M14_TREE/barretenberg/cpp/build-cachecheck" 2>/dev/null

finish
