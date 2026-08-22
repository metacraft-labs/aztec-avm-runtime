#!/usr/bin/env bash
# verify_avm_wasm_build — `cmake --preset wasm-avm && ninja` produces
# libvm2_sim.a and libworld_state_reference.a for wasm32-wasip1, from the M0
# nix shell.
#
# WHAT THIS CHECK IS FOR, AND WHAT IT REFUSES TO DO
#
# "It builds" is the weakest interesting statement and the easiest to fake, so
# every part of it is asserted separately:
#
#   * cmake's exit status AND ninja's exit status, each as its own assertion.
#     A count parsed out of a partial run is the defect this campaign's M2
#     review found, and M3's review reproduced it deliberately.
#   * The archives are asserted to be WASM objects, not merely to exist. A
#     native build left in the same directory would satisfy "the file is there".
#   * The set of archives is pinned as an IDENTITY. A tenth archive appearing is
#     as much a finding as one of the nine disappearing.
#   * The build is asserted to be -Werror-clean rather than warning-suppressed,
#     and that is measured rather than read off the flags: the patch's three
#     narrowing corrections are reverted in a sixth worktree and the build must
#     then FAIL, on exactly the four translation units the milestone names, each
#     under its own diagnostic. The spike this milestone replaces reached the
#     same green build with `add_compile_options(-Wno-error)`; nothing about a
#     successful build distinguishes the two except this experiment.
#
# `-Wfatal-errors` is on (src/CMakeLists.txt:16), so a failing translation unit
# emits exactly ONE `fatal error:` line and no `error:` line at all. Every
# diagnostic assertion below matches `fatal error:`, and the builds run under
# `ninja -k 0` so one run reports the whole failing set rather than the first
# of it.
#
# It writes $M6_WORK/measured.env, the single record every other M6 check reads.

set -uo pipefail

TEST_NAME=verify_avm_wasm_build
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_avm_wasm.sh"

require_nix

# ---------------------------------------------------------------------------
# The trees. Prepared from the patch FILES, in SERIES.md's order.
# ---------------------------------------------------------------------------
note "work directory: $M6_WORK"
m6_prepare_trees

assert_eq "the avm tree is $M6_BASE_REV + exactly four commits" \
  "4" "$(git -C "$M6_TREE_AVM" rev-list --count "$M6_BASE_REV..HEAD")"

# Identity, not count: the four commits are the four prepared patches, in order.
# git wraps a long `Subject:` across continuation lines, so it is unfolded with
# an RFC 5322 parser rather than with `sed`. A `head -1` here would compare the
# first half of one string against the whole of another and pass or fail for a
# reason that has nothing to do with the patches.
patch_subject() {
  python3 - "$1" <<'PY'
import email, re, sys
msg = email.message_from_bytes(open(sys.argv[1], "rb").read())
s = " ".join(str(msg["Subject"]).split())
print(re.sub(r"^\[PATCH[^\]]*\]\s*", "", s))
PY
}
EXPECTED_SUBJECTS=""
for p in "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4"; do
  EXPECTED_SUBJECTS="$EXPECTED_SUBJECTS$(patch_subject "$p")
"
done
ACTUAL_SUBJECTS="$(git -C "$M6_TREE_AVM" log --reverse --format=%s "$M6_BASE_REV..HEAD")
"
assert_eq "the four commits are the four prepared patches, in SERIES.md's order" \
  "$EXPECTED_SUBJECTS" "$ACTUAL_SUBJECTS"

# ---------------------------------------------------------------------------
# The M0 shell supplies the toolchain. Not "a wasi-sdk is installed somewhere".
# ---------------------------------------------------------------------------
SDK_PREFIX="$(m6_in_devshell 'printf "%s\n" "${WASI_SDK_PREFIX:-}"')"
assert_nix_store "the fork's dev shell exports WASI_SDK_PREFIX from the nix store" "$SDK_PREFIX"
SDK_VERSION="$(m6_in_devshell 'head -1 "$WASI_SDK_PREFIX/VERSION"')"
assert_prefix "and it is a wasi-sdk 33" "33." "$SDK_VERSION"

# The configure-time constants codegen invokes clang-format-20 by that exact
# versioned name and aborts the whole configure without it. It is the shell's
# job to supply it, so assert the shell does.
CF20="$(m6_in_devshell 'command -v clang-format-20 || true')"
assert_nix_store "the dev shell supplies clang-format-20 (the codegen calls it by that name)" "$CF20"

# ---------------------------------------------------------------------------
# Configure.
# ---------------------------------------------------------------------------
m6_configure "$M6_TREE_AVM" wasm-avm build-wasm-avm
CFG_RC=$?
assert_eq "cmake --preset wasm-avm exits 0" "0" "$CFG_RC"
CFG_LOG="$(m6_log "$M6_TREE_AVM" build-wasm-avm)"
assert_contains "the configure log records its own exit status" "### configure_rc=0" "$CFG_LOG"
assert_contains "the exceptions probe ran and passed at configure time" \
  "AVM_WASM: wasm C++ exceptions probe passed" "$CFG_LOG"
assert_contains "cmake reports it is compiling for WebAssembly" \
  "Compiling for WebAssembly." "$CFG_LOG"

# What the preset resolved. The toolchain must be the SHELL's, and the target
# must be wasm32 — asserted from CMake's own cache, not from the command line we
# think we passed.
assert_eq "the C++ compiler is the dev shell's wasi-sdk clang++" \
  "$SDK_PREFIX/bin/clang++" "$(m6_cache "$M6_TREE_AVM" build-wasm-avm CMAKE_CXX_COMPILER)"
assert_eq "the sysroot is the dev shell's wasi-sysroot" \
  "$SDK_PREFIX/share/wasi-sysroot" "$(m6_cache "$M6_TREE_AVM" build-wasm-avm CMAKE_SYSROOT)"
assert_eq "the target processor is wasm32, per CMake's own CMakeSystem.cmake" \
  "wasm32" "$(m6_system_processor "$M6_TREE_AVM" build-wasm-avm)"
assert_eq "through barretenberg's own wasm toolchain file" \
  "$M6_TREE_AVM/barretenberg/cpp/cmake/toolchains/wasm32-wasi.cmake" \
  "$(m6_cache "$M6_TREE_AVM" build-wasm-avm CMAKE_TOOLCHAIN_FILE)"
assert_eq "AVM_WASM is ON" "ON" "$(m6_cache "$M6_TREE_AVM" build-wasm-avm AVM_WASM)"
assert_eq "AVM (the proving-stack flag) is OFF" "OFF" "$(m6_cache "$M6_TREE_AVM" build-wasm-avm AVM)"
assert_eq "MULTITHREADING is OFF, inherited from the wasm preset" \
  "OFF" "$(m6_cache "$M6_TREE_AVM" build-wasm-avm MULTITHREADING)"
assert_eq "the exceptions probe's result is cached as supported" \
  "1" "$(m6_cache "$M6_TREE_AVM" build-wasm-avm BB_WASM_EXCEPTIONS_SUPPORTED)"

# ---------------------------------------------------------------------------
# The generated header. aztec_constants.hpp is not checked in; the configure
# regenerates it. Assert that by DELETING it and reconfiguring, rather than by
# observing that a file happens to be present.
# ---------------------------------------------------------------------------
CONSTANTS="$M6_TREE_AVM/barretenberg/cpp/src/barretenberg/aztec/aztec_constants.hpp"
assert_file "aztec_constants.hpp exists after the configure" "$CONSTANTS"
assert_eq "it is not tracked in the fork (it is generated, not committed)" \
  "" "$(git -C "$M6_TREE_AVM" ls-files -- barretenberg/cpp/src/barretenberg/aztec/aztec_constants.hpp)"
CONSTANTS_SHA_BEFORE="$(sha256sum "$CONSTANTS" | cut -d' ' -f1)"
rm -f "$CONSTANTS"
m6_configure "$M6_TREE_AVM" wasm-avm build-codegen-probe
CODEGEN_RC=$?
assert_eq "a configure with the header deleted still exits 0" "0" "$CODEGEN_RC"
assert_file "and regenerates aztec_constants.hpp" "$CONSTANTS"
assert_eq "byte-identically, so the codegen step is reproducible" \
  "$CONSTANTS_SHA_BEFORE" "$(sha256sum "$CONSTANTS" 2>/dev/null | cut -d' ' -f1)"
rm -rf "$M6_TREE_AVM/barretenberg/cpp/build-codegen-probe"

# ---------------------------------------------------------------------------
# Build.
# ---------------------------------------------------------------------------
m6_build "$M6_TREE_AVM" build-wasm-avm vm2_sim world_state_reference
BUILD_RC=$?
assert_eq "ninja vm2_sim world_state_reference exits 0" "0" "$BUILD_RC"
BUILD_LOG="$(m6_build_log "$M6_TREE_AVM" build-wasm-avm)"
assert_contains "the build log records its own exit status" "### ninja_rc=0" "$BUILD_LOG"
assert_eq "no translation unit failed" "0" "$(printf '%s\n' "$BUILD_LOG" | grep -c '^FAILED:')"
assert_eq "and none emitted a fatal diagnostic" \
  "0" "$(printf '%s\n' "$BUILD_LOG" | grep -c 'fatal error:')"

# ---------------------------------------------------------------------------
# What was produced. Identity of the archive set, and the archives are wasm.
# ---------------------------------------------------------------------------
ARCHIVES="$(m6_archives "$M6_TREE_AVM" build-wasm-avm)"
assert_eq "the build produces exactly the nine expected archives" \
  "$M6_EXPECTED_ARCHIVES" "$ARCHIVES"

for a in libvm2_sim.a libworld_state_reference.a; do
  assert_file "$a exists" "$M6_TREE_AVM/barretenberg/cpp/build-wasm-avm/lib/$a"
  assert_eq "every object in $a is a wasm object, and only that" \
    "WASM" "$(m6_archive_formats "$M6_TREE_AVM" build-wasm-avm "$a")"
done

VM2_BYTES=$(stat -c%s "$M6_TREE_AVM/barretenberg/cpp/build-wasm-avm/lib/libvm2_sim.a" 2>/dev/null)
WSR_BYTES=$(stat -c%s "$M6_TREE_AVM/barretenberg/cpp/build-wasm-avm/lib/libworld_state_reference.a" 2>/dev/null)
assert_ge "libvm2_sim.a is a real archive, not an empty one" 1000000 "$VM2_BYTES"
assert_ge "libworld_state_reference.a is a real archive, not an empty one" 50000 "$WSR_BYTES"

# world_state_reference is IN the artefact, not merely available: its own
# translation unit is a member of its archive.
WSR_MEMBERS="$(m6_in_devshell '"$WASI_SDK_PREFIX/bin/llvm-ar" t "$1"' \
  "$M6_TREE_AVM/barretenberg/cpp/build-wasm-avm/lib/libworld_state_reference.a" | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "libworld_state_reference.a holds exactly the world state's own two objects" \
  "memory_merkle_db.cpp.obj merkle_tree_id.cpp.obj" "$WSR_MEMBERS"

VM2_MEMBER_COUNT="$(m6_in_devshell '"$WASI_SDK_PREFIX/bin/llvm-ar" t "$1"' \
  "$M6_TREE_AVM/barretenberg/cpp/build-wasm-avm/lib/libvm2_sim.a" | grep -c '\.obj$')"
assert_eq "libvm2_sim.a holds one object per simulator translation unit" \
  "77" "$VM2_MEMBER_COUNT"

# ---------------------------------------------------------------------------
# The build is -Werror-clean, MEASURED. This is the part that separates it from
# the spike, which reached the same green build with -Wno-error.
# ---------------------------------------------------------------------------
TU_TOTAL="$(m6_tu_count "$M6_TREE_AVM" build-wasm-avm)"
TU_OWN="$(m6_own_tu_count "$M6_TREE_AVM" build-wasm-avm)"
assert_ge "the compile database has the build's translation units in it" 400 "$TU_TOTAL"
assert_ge "and barretenberg's own are most of them" 400 "$TU_OWN"
assert_eq "every one of barretenberg's own carries -Werror" \
  "$TU_OWN" "$(m6_flag_tu_count "$M6_TREE_AVM" build-wasm-avm -Werror own)"
assert_eq "and none carries -Wno-error (the spike's way of getting green)" \
  "0" "$(m6_flag_tu_count "$M6_TREE_AVM" build-wasm-avm -Wno-error all)"
assert_eq "every one carries -Wconversion" \
  "$TU_OWN" "$(m6_flag_tu_count "$M6_TREE_AVM" build-wasm-avm -Wconversion own)"
assert_eq "every one carries -Wsign-conversion" \
  "$TU_OWN" "$(m6_flag_tu_count "$M6_TREE_AVM" build-wasm-avm -Wsign-conversion own)"

# The exception flags, and the flag they replace. cmake/arch.cmake stops forcing
# -fno-exceptions under AVM_WASM, and that is what lets throw-to-revert survive;
# it is asserted here as an identity in BOTH directions, with the plain `wasm`
# preset of the SAME TREE as the control. Without the control, "0 TUs carry
# -fno-exceptions" is also true of a build that compiled nothing.
assert_eq "every one of barretenberg's own carries -fwasm-exceptions" \
  "$TU_OWN" "$(m6_flag_tu_count "$M6_TREE_AVM" build-wasm-avm -fwasm-exceptions own)"
assert_eq "and NONE carries -fno-exceptions" \
  "0" "$(m6_flag_tu_count "$M6_TREE_AVM" build-wasm-avm -fno-exceptions all)"
m6_configure "$M6_TREE_AVM" wasm build-wasm-control
assert_eq "the same tree's plain wasm preset configures" "0" "$?"
TU_CTRL="$(m6_own_tu_count "$M6_TREE_AVM" build-wasm-control)"
assert_ge "and compiles barretenberg's own sources" 400 "$TU_CTRL"
assert_eq "there, every one carries -fno-exceptions, exactly as before the patch" \
  "$TU_CTRL" "$(m6_flag_tu_count "$M6_TREE_AVM" build-wasm-control -fno-exceptions own)"
assert_eq "and none carries -fwasm-exceptions" \
  "0" "$(m6_flag_tu_count "$M6_TREE_AVM" build-wasm-control -fwasm-exceptions all)"
rm -rf "$M6_TREE_AVM/barretenberg/cpp/build-wasm-control"

# The two modules the milestone names are compiled, and how much of each.
assert_eq "the build compiles the AVM simulator's 77 translation units" \
  "77" "$(m6_module_tu_count "$M6_TREE_AVM" build-wasm-avm /vm2/)"
assert_eq "and the in-memory world state's 2" \
  "2" "$(m6_module_tu_count "$M6_TREE_AVM" build-wasm-avm /world_state_reference/)"

# The four translation units the milestone names are actually IN this build.
# Asserting that they compile clean is worthless if they are not compiled.
DB="$(m6_compile_db "$M6_TREE_AVM" build-wasm-avm)"
for tu in $M6_NARROWING_TUS; do
  assert_eq "the build compiles $tu" "1" \
    "$(python3 -c '
import json,sys
db=json.load(open(sys.argv[1])); n=sys.argv[2]
print(sum(1 for e in db if e["file"].endswith("/"+n)))' "$DB" "$tu")"
done

# ---------------------------------------------------------------------------
# THE DISCRIMINATOR. Revert the patch's three narrowing corrections and nothing
# else; the build must fail, on exactly those four units, each under its own
# flag. This is what makes "no warning is suppressed" a measurement.
# ---------------------------------------------------------------------------
m6_prepare_narrowing_control
for f in $M6_NARROWING_FIXES; do
  git -C "$M6_TREE_NOCAST" checkout HEAD^ -- "$f" \
    || fail "could not revert $f in the narrowing control tree"
done
REVERTED="$(git -C "$M6_TREE_NOCAST" diff --name-only HEAD | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the control tree differs from the AVM_WASM tree by exactly the three narrowing fixes" \
  "$(printf '%s\n' $M6_NARROWING_FIXES | sort | tr '\n' ' ' | sed 's/ $//')" "$REVERTED"

m6_configure "$M6_TREE_NOCAST" wasm-avm build-wasm-avm
assert_eq "the control tree still configures (the revert is a source change, not a build one)" \
  "0" "$?"
m6_build "$M6_TREE_NOCAST" build-wasm-avm vm2_sim world_state_reference
NOCAST_RC=$?
if [ "$NOCAST_RC" -ne 0 ]; then
  pass "with the narrowing fixes reverted, the wasm build FAILS  [exit $NOCAST_RC]"
else
  fail "with the narrowing fixes reverted, the wasm build still succeeded — the -Werror claim is void"
fi
NOCAST_LOG="$(m6_build_log "$M6_TREE_NOCAST" build-wasm-avm)"
NOCAST_FAILED="$(printf '%s\n' "$NOCAST_LOG" | grep '^FAILED:' \
  | grep -oE '[A-Za-z0-9_]+\.cpp\.obj' | sed 's/\.obj$//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
assert_eq "exactly four build edges failed" \
  "4" "$(printf '%s\n' "$NOCAST_LOG" | grep -c '^FAILED:')"
assert_eq "and it fails on exactly the four translation units the milestone names" \
  "memory_merkle_db.cpp retrieved_bytecodes_tree_check.cpp to_radix.cpp written_public_data_slots_tree_check.cpp" \
  "$NOCAST_FAILED"

# Each for its OWN reason. A count of four failures is satisfied by four
# failures for the wrong reason; the flag and the file are what pin it.
assert_contains "memory_merkle_db.hpp:108 narrows index_t under -Wshorten-64-to-32" \
  "memory_merkle_db.hpp:108:42: fatal error: implicit conversion loses integer precision" "$NOCAST_LOG"
assert_contains "retrieved_bytecodes_tree_check.cpp:20 does too" \
  "retrieved_bytecodes_tree_check.cpp:20:47: fatal error: implicit conversion loses integer precision" "$NOCAST_LOG"
assert_contains "written_public_data_slots_tree_check.cpp:27 does too" \
  "written_public_data_slots_tree_check.cpp:27:47: fatal error: implicit conversion loses integer precision" "$NOCAST_LOG"
assert_contains "to_radix.cpp:53 changes signedness under -Wsign-conversion" \
  "to_radix.cpp:53:37: fatal error: implicit conversion changes signedness" "$NOCAST_LOG"
assert_eq "three of the four are -Wshorten-64-to-32" \
  "3" "$(printf '%s\n' "$NOCAST_LOG" | grep -c '\[-Wshorten-64-to-32\]')"
assert_eq "and one is -Wsign-conversion" \
  "1" "$(printf '%s\n' "$NOCAST_LOG" | grep -c '\[-Wsign-conversion\]')"
assert_eq "nothing else in the build failed for any other reason" \
  "4" "$(printf '%s\n' "$NOCAST_LOG" | grep -c 'fatal error:')"

m6_reset_tree nocast

# ---------------------------------------------------------------------------
# The entry point the milestone asks for exists and is the code path this check
# just exercised, not a second copy of it.
# ---------------------------------------------------------------------------
assert_file "the reproducible entry point exists" "$VERIFY_DIR/build_avm_wasm.sh"
assert_true "and is executable" test -x "$VERIFY_DIR/build_avm_wasm.sh"
assert_contains "it drives the same m6_configure helper this check used" \
  "m6_configure" "$(cat "$VERIFY_DIR/build_avm_wasm.sh")"
assert_contains "the Justfile exposes it" \
  "build_avm_wasm.sh" "$(cat "$REPO_ROOT/Justfile")"

# ---------------------------------------------------------------------------
# The record.
# ---------------------------------------------------------------------------
{
  printf 'M6_AVM_TREE=%s\n' "$M6_TREE_AVM"
  printf 'M6_STACK3_TREE=%s\n' "$M6_TREE_STACK3"
  printf 'M6_BASE_TREE=%s\n' "$M6_TREE_BASE"
  printf 'M6_SDK_PREFIX=%s\n' "$SDK_PREFIX"
  printf 'M6_SDK_VERSION=%s\n' "$SDK_VERSION"
  printf 'M6_ARCHIVES="%s"\n' "$ARCHIVES"
  printf 'M6_VM2_BYTES=%s\n' "$VM2_BYTES"
  printf 'M6_WSR_BYTES=%s\n' "$WSR_BYTES"
  printf 'M6_TU_TOTAL=%s\n' "$TU_TOTAL"
  printf 'M6_VM2_MEMBERS=%s\n' "$VM2_MEMBER_COUNT"
} >"$M6_WORK/measured.env"
note "measurement recorded at $M6_WORK/measured.env"

finish
