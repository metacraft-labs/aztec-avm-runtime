#!/usr/bin/env bash
# M7: upstream's own vm2 simulation test sources compile and link for
# wasm32-wasip1, in the AVM_WASM configuration, from the same sources the native
# `vm2_tests` target uses.
#
# It is also the milestone's measurement of record: it writes
# $M7_WORK/measured.env, which every other M7 check reads rather than
# re-deriving, so no two checks can disagree about what was built.
#
# What it asserts, and why in this shape:
#
#   * cmake's exit status and ninja's SEPARATELY from anything parsed out of
#     either. M2's defect was a green summary printed over a red build; M3's
#     lesson was that only `ninja exits 0` names it.
#   * The target is ADDITIVE: with -DAVM_SIM_TESTS=OFF on the same preset, the
#     wasm build declares no vm2_sim_tests target at all, and the option's
#     default is read from the PATCH's own added `option()` line rather than from
#     a configured cache, which a preset could have set.
#   * The artefact is a wasm module because its own magic bytes say so, and its
#     import surface is pinned as an identity: one non-WASI import (env.memory,
#     with the limits it declares) and 19 wasi_snapshot_preview1 functions.
#   * The link closure carries no proving-stack archive, asserted against a build
#     tree where all ten of them ARE real targets.
#   * The DISCRIMINATOR: the overlay's five narrowing corrections are reverted in
#     the same tree and the build must then FAIL, on exactly those five
#     translation units and nothing else for any other reason. `-Wfatal-errors`
#     is on, so each failing unit emits exactly ONE `fatal error:` line and no
#     `error:` line at all, and the build runs `ninja -k 0` so one run reports
#     the whole set.
#
# It also builds the NATIVE side — upstream's own `vm2_tests`, proving stack and
# `dsl` included, plus the native `vm2_sim_tests` — because that binary is the
# only honest anchor for the exclusion list, and a milestone that measured only
# the target it chose the size of would be quoting a pass rate against a silently
# reduced suite. That is the thing M7's deliverables forbid.

set -uo pipefail

TEST_NAME=verify_vm2_tests_build_for_wasm
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_vm2_tests.sh"

require_nix
note "work directory: $M7_WORK"

# --- the tree ---------------------------------------------------------------
m7_tree >/dev/null
note "tree: $M7_TREE ($(git -C "$M7_TREE" rev-parse --short HEAD))"

assert_eq "the tree is $M6_BASE_REV + exactly five patches" \
  5 "$(git -C "$M7_TREE" rev-list --count "$M6_BASE_REV..HEAD")"
assert_file "M7's overlay patch is the artefact under test" "$M7_PATCH_5"

# The option's DEFAULT comes from the patch, not from a cache. Asserting what the
# thing SETS, rather than only that something else is unchanged.
option_line="$(m6_patch_added "$M7_PATCH_5" 'cpp/CMakeLists.txt' | grep -F 'option(AVM_SIM_TESTS')"
assert_contains "the overlay adds an option(AVM_SIM_TESTS ...) line" "option(AVM_SIM_TESTS" "$option_line"
assert_prefix "and its default is OFF" "OFF" "$(printf '%s' "$option_line" | awk '{print $NF}' | tr -d ')')"

# The overlay's file set, as an identity.
patch_files="$(m6_patch_files "$M7_PATCH_5" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the overlay touches exactly nine files" \
  "barretenberg/cpp/CMakeLists.txt barretenberg/cpp/cmake/gtest.cmake barretenberg/cpp/src/barretenberg/vm2/CMakeLists.txt barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/indexed_tree_check.test.cpp barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/public_data_tree_check.test.cpp barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/update_check.test.cpp barretenberg/cpp/src/barretenberg/vm2/simulation/lib/call_stack_metadata_collector.test.cpp barretenberg/cpp/src/barretenberg/vm2/simulation/lib/hinting_dbs.test.cpp barretenberg/cpp/src/barretenberg/vm2/testing/fixtures.cpp" \
  "$patch_files"

# "The same source the native target uses" is the deliverable's own wording, so
# it is asserted rather than assumed: the overlay adds NO new test source file.
added_test_files="$(m6_patch_files "$M7_PATCH_5" | grep -c '\.test\.cpp$')"
assert_eq "the overlay adds no new test source file (it only edits five)" 5 "$added_test_files"
assert_eq "and it creates no file at all" 0 \
  "$(grep -c '^new file mode' "$M7_PATCH_5")"

# --- ADDITIVE: the OFF side -------------------------------------------------
m6_configure "$M7_TREE" wasm-avm build-wasm-simoff
off_rc=$?
assert_eq "wasm-avm configures with AVM_SIM_TESTS left at its default" 0 "$off_rc"
off_targets="$(m6_ninja_targets "$M7_TREE" build-wasm-simoff | grep -c 'vm2_sim_tests')"
assert_eq "with the option OFF the wasm build declares no vm2_sim_tests target" 0 "$off_targets"
assert_eq "and no vm2_sim_test_objects either" 0 \
  "$(m6_ninja_targets "$M7_TREE" build-wasm-simoff | grep -c 'vm2_sim_test_objects')"

# --- the wasm build ---------------------------------------------------------
m7_build_wasm
wasm_rc=$?
assert_eq "cmake --preset wasm-avm -DAVM_SIM_TESTS=ON exits 0" 0 "${M7_WASM_CONFIGURE_RC:-99}"
assert_eq "ninja vm2_sim_tests exits 0" 0 "${M7_WASM_BUILD_RC:-99}"
if [ "$wasm_rc" -ne 0 ]; then
  note "build log: $M7_TREE/m6-$M7_WASM_BUILD-build.log"
  m6_build_log "$M7_TREE" "$M7_WASM_BUILD" | grep -E '^FAILED:|fatal error:' | head -20
fi

WASM_BIN="$(m7_wasm_bin vm2_sim_tests)"
assert_file "the wasm test binary is produced" "$WASM_BIN"
m7_require_artifacts "$WASM_BIN"

magic="$(head -c 4 "$WASM_BIN" | od -An -tx1 | tr -d ' \n')"
assert_eq "and it is a WebAssembly module by its own magic bytes" "0061736d" "$magic"

# The import surface, as an identity. M7's deliverable calls it "the existing
# eleven-import WASI surface"; measured, it is 19 WASI functions plus the one
# memory. Stated rather than rounded to the number the deliverable expected.
imports="$(m6_in_devshell '
  node -e "
    const fs=require(\"fs\");
    const m=new WebAssembly.Module(fs.readFileSync(process.argv[1]));
    for (const i of WebAssembly.Module.imports(m)) console.log(i.module+\".\"+i.name);
  " "$1"' "$WASM_BIN" 2>/dev/null | LC_ALL=C sort)"
assert_eq "exactly one non-WASI import" 1 \
  "$(printf '%s\n' "$imports" | grep -vc '^wasi_snapshot_preview1\.')"
assert_eq "and it is env.memory" "env.memory" \
  "$(printf '%s\n' "$imports" | grep -v '^wasi_snapshot_preview1\.')"
WASI_IMPORTS="$(printf '%s\n' "$imports" | grep -c '^wasi_snapshot_preview1\.')"
# M7's deliverable calls this "the existing eleven-import WASI surface". Measured, it is 18
# functions plus the one memory -- 19 imports in total. Stated rather than rounded to the
# number the deliverable expected.
assert_eq "the WASI surface is 18 functions" 18 "$WASI_IMPORTS"
assert_eq "19 imports in total" 19 "$(printf '%s\n' "$imports" | grep -c .)"

limits="$(python3 "$M7_MEMLIMITS" "$WASM_BIN")"
assert_prefix "the memory import declares its own limits" "env memory " "$limits"
MEM_MIN="$(printf '%s' "$limits" | awk '{print $3}')"
assert_ge "and a minimum of at least 128 pages" 128 "$MEM_MIN"

exports="$(m6_in_devshell '
  node -e "
    const fs=require(\"fs\");
    const m=new WebAssembly.Module(fs.readFileSync(process.argv[1]));
    for (const e of WebAssembly.Module.exports(m)) console.log(e.name);
  " "$1"' "$WASM_BIN" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the module exports exactly _start and memory" "_start memory" "$exports"

# gtest's OWN main is in the artefact, pulled from libgtest_main.a rather than
# replaced by a bespoke runner. `llvm-nm` is NOT the way to see it: the wasm entry
# point is `__main_argc_argv` (wasi-sdk's clang renames `int main(int, char**)`),
# and once it is linked it is internalised, so nm reports neither name in either
# the working binary or the broken one -- a count of zero there would have been
# the vacuous version of this assertion, and the first run of this check made
# exactly that mistake. What DOES separate them is gtest_main.cc's own string:
# present when the archive member was pulled, absent when it was not (measured:
# 1 here, 0 in the `noentry` control, which is 146,735 bytes smaller).
entry="$(grep -c 'Running main() from' "$WASM_BIN" || true)"
assert_eq "gtest's own main is in the artefact (its banner string is present)" 1 "$entry"

# --- the link closure carries no proving stack ------------------------------
link_line="$(grep -A6 "^build bin/vm2_sim_tests" "$M7_TREE/barretenberg/cpp/$M7_WASM_BUILD/build.ninja" | tr ' ' '\n' | grep -E '\.a$' | LC_ALL=C sort -u)"
assert_ge "the wasm test binary links at least eight archives" 8 "$(printf '%s\n' "$link_line" | wc -l | tr -d ' ')"
WASM_TARGETS="$M7_WORK/wasm-targets.txt"
mkdir -p "$M7_WORK"
m6_ninja_targets "$M7_TREE" "$M7_WASM_BUILD" >"$WASM_TARGETS"
assert_ge "the wasm build declares a target list" 100 "$(wc -l <"$WASM_TARGETS" | tr -d ' ')"
assert_ge "and vm2_sim_tests is one of them" 1 "$(grep -c '^bin/vm2_sim_tests$' "$WASM_TARGETS")"
for m in $M6_FORBIDDEN_MODULES; do
  # The absence is not vacuous: each is a real target IN THIS BUILD TREE, since
  # `wasm-avm` inherits `wasm`.
  assert_ge "proving module '$m' IS a target in this very build tree" 1 \
    "$(grep -c "^lib/lib$m\.a$" "$WASM_TARGETS")"
  assert_eq "and lib$m.a is not on vm2_sim_tests' link line" 0 \
    "$(printf '%s\n' "$link_line" | grep -c "/lib$m\.a$")"
done
assert_eq "no LMDB archive on the link line" 0 "$(printf '%s\n' "$link_line" | grep -ci lmdb)"
assert_ge "libworld_state_reference.a IS on it" 1 \
  "$(printf '%s\n' "$link_line" | grep -c 'libworld_state_reference\.a$')"
assert_ge "libvm2_sim.a IS on it" 1 "$(printf '%s\n' "$link_line" | grep -c 'libvm2_sim\.a$')"

# --- the native side --------------------------------------------------------
m7_build_native
native_rc=$?
assert_eq "cmake --preset default -DAVM_SIM_TESTS=ON exits 0" 0 "${M7_NATIVE_CONFIGURE_RC:-99}"
assert_eq "ninja vm2_tests vm2_sim_tests exits 0 natively" 0 "${M7_NATIVE_BUILD_RC:-99}"
if [ "$native_rc" -ne 0 ]; then
  m6_build_log "$M7_TREE" "$M7_NATIVE_BUILD" | grep -E '^FAILED:|error:' | head -20
fi
assert_file "upstream's own native vm2_tests is produced" "$(m7_native_bin vm2_tests)"
assert_file "and the native vm2_sim_tests beside it" "$(m7_native_bin vm2_sim_tests)"

# Upstream's binary is the one with the proving stack in it; that is the whole
# reason it cannot be the wasm one, so it is asserted rather than narrated.
native_link="$(grep -A6 "^build bin/vm2_tests" "$M7_TREE/barretenberg/cpp/$M7_NATIVE_BUILD/build.ninja" | tr ' ' '\n' | grep -E '\.a$' | LC_ALL=C sort -u)"
for m in sumcheck stdlib_honk_verifier goblin_avm dsl; do
  assert_ge "native vm2_tests links lib$m.a" 1 "$(printf '%s\n' "$native_link" | grep -c "/lib$m\.a$")"
done

# --- THE DISCRIMINATOR: revert the five narrowing corrections ---------------
# Without them the wasm build must FAIL, on exactly those five translation units
# and nothing else. A check that only shows the patched tree building is green
# for a patch that changed nothing relevant.
NARROWED_FILES="barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/indexed_tree_check.test.cpp
barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/public_data_tree_check.test.cpp
barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/update_check.test.cpp
barretenberg/cpp/src/barretenberg/vm2/simulation/lib/call_stack_metadata_collector.test.cpp
barretenberg/cpp/src/barretenberg/vm2/simulation/lib/hinting_dbs.test.cpp"

m6_reset_tree "$M7_TREE_NAME"
for f in $NARROWED_FILES; do
  git -C "$M7_TREE" checkout "HEAD^" -- "$f" 2>/dev/null \
    || die "could not revert $f in $M7_TREE"
done
reverted="$(git -C "$M7_TREE" diff --name-only HEAD -- barretenberg | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "exactly the five test sources are reverted, and nothing else" \
  "$(printf '%s\n' $NARROWED_FILES | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" "$reverted"

m6_build "$M7_TREE" "$M7_WASM_BUILD" vm2_sim_tests
revert_rc=$?
assert_false "with the narrowing corrections reverted the wasm build FAILS" test "$revert_rc" -eq 0
rlog="$M7_TREE/m6-$M7_WASM_BUILD-build.log"
# `-Wfatal-errors` means each failing unit emits exactly one `fatal error:` line
# and no ordinary diagnostic at all: `<file>:<line>:<col>: error: ` counts ZERO on
# a build that plainly failed. (` error: ` on its own is a substring of
# `fatal error: `, so it is not the discriminator -- it counts 5 here.)
assert_eq "-Wfatal-errors means no ordinary ': error: ' line is emitted at all" 0 \
  "$(grep -c ': error: ' "$rlog" 2>/dev/null || true)"
failed_edges="$(grep -c '^FAILED:' "$rlog" 2>/dev/null || true)"
assert_eq "exactly five build edges fail" 5 "$failed_edges"
# Anchored on `src/barretenberg/vm2/` and NOT on a leading `/barretenberg/cpp/src/...`, because the
# form of the path in a compiler diagnostic is not ours to assume. From M14 the dev shells put
# ccache on the compiler launcher path with CCACHE_BASEDIR=$HOME, and ccache rewrites an absolute
# source path to one relative to the compile's working directory BEFORE handing it to the compiler:
# what was `/home/…/barretenberg/cpp/src/barretenberg/vm2/x.test.cpp:1:2: fatal error` is now
# `../src/barretenberg/vm2/x.test.cpp:1:2: fatal error`. The absolute form no longer occurs, this
# extraction returned the empty list, and the assertion below failed on a build that had in fact
# failed in exactly the five places it was supposed to. Both forms contain `src/barretenberg/vm2/`.
fatal_files="$(grep -oE 'src/barretenberg/vm2/[^: ]+\.test\.cpp:[0-9]+:[0-9]+: fatal error' "$rlog" \
  | sed -E 's|^src/barretenberg/||; s|:[0-9]+:[0-9]+: fatal error$||' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
assert_eq "and they are exactly the five the overlay corrects" \
  "vm2/simulation/gadgets/indexed_tree_check.test.cpp vm2/simulation/gadgets/public_data_tree_check.test.cpp vm2/simulation/gadgets/update_check.test.cpp vm2/simulation/lib/call_stack_metadata_collector.test.cpp vm2/simulation/lib/hinting_dbs.test.cpp" \
  "$fatal_files"
assert_eq "every failure is a narrowing diagnostic and nothing failed for any other reason" 5 \
  "$(grep -cE 'fatal error: implicit conversion (loses integer precision|changes signedness)' "$rlog" 2>/dev/null || true)"

# Put the tree back and rebuild, so the artefact every other check reads is the
# patched one. `checkout HEAD --`, not `checkout --`: reverting with
# `checkout HEAD^ --` staged the old content, so restoring from the index would
# restore the mutation. (M6's machinery met the same trap.)
m6_reset_tree "$M7_TREE_NAME"
assert_eq "the tree is clean again after the experiment" "" "$(m7_tree_dirty)"
m6_build "$M7_TREE" "$M7_WASM_BUILD" vm2_sim_tests
assert_eq "and the wasm build is green again" 0 $?
assert_file "the wasm test binary is back" "$WASM_BIN"

# --- the record -------------------------------------------------------------
mkdir -p "$M7_WORK"
cat >"$M7_WORK/measured.env" <<EOF
# Written by $TEST_NAME on $(date -u +%Y-%m-%dT%H:%M:%SZ). Read by every other
# M7 check, so no two of them can disagree about what was built.
M7_TREE=$M7_TREE
M7_WASM_BIN=$WASM_BIN
M7_NATIVE_VM2_TESTS=$(m7_native_bin vm2_tests)
M7_NATIVE_SIM_TESTS=$(m7_native_bin vm2_sim_tests)
M7_WASM_BIN_BYTES=$(stat -c %s "$WASM_BIN")
M7_WASI_IMPORTS=$WASI_IMPORTS
M7_MEM_MIN=$MEM_MIN
EOF
note "measurement written to $M7_WORK/measured.env"
note "wasm binary: $(stat -c %s "$WASM_BIN") bytes; native vm2_tests: $(stat -c %s "$(m7_native_bin vm2_tests)") bytes"

finish
