#!/usr/bin/env bash
# test_wasm_exceptions_configure_gate — configuring with a toolchain that cannot
# compile wasm exceptions fails at CONFIGURE time, with a message naming the
# required wasi-sdk version.
#
# WHAT THE GATE IS FOR
#
# wasi-sdk shipped a libc++abi built `-fno-exceptions` and no unwinder at all
# until 33. Such a sysroot accepts `-fwasm-exceptions` on the compile line
# without a word, and the failure surfaces only when the first target is linked
# — and then once per target, as `unable to find library -lunwind` or as a list
# of undefined `__cxa_*` symbols. A `check_cxx_source_compiles` at configure time
# turns that into one sentence that says what to install.
#
# WHAT THIS CHECK ASSERTS, AND WHY EACH PART IS SEPARATE
#
#   * exit status AND the specific failure mode. A configure can exit 1 for any
#     number of reasons; only the message and the recorded probe say it was the
#     gate. Both are asserted, and so is the error's LOCATION (cmake/arch.cmake).
#   * that removing ONLY the gate's `message(FATAL_ERROR ...)` block makes the
#     same toolchain configure successfully. This is the assertion that pins the
#     gate rather than something adjacent: without it, "27 fails to configure"
#     is compatible with 27 failing for a reason nobody has established.
#   * that the gate is SCOPED. The same toolchain on the plain `wasm` preset —
#     upstream's own configuration, `AVM_WASM` off — must still configure, or
#     the patch has broken every existing wasm build to protect one new one.
#   * that the premise is a property of the toolchains and not of CMake: the
#     probe program is linked directly with each SDK.

set -uo pipefail

TEST_NAME=test_wasm_exceptions_configure_gate
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_avm_wasm.sh"

require_nix
m6_prepare_trees

SDK33="$(m6_sdk 33)"
SDK27="$(m6_sdk 27)"
assert_prefix "the 33 toolchain says it is 33" "33." "$(head -1 "$SDK33/VERSION")"
assert_prefix "the 27 toolchain says it is 27" "27." "$(head -1 "$SDK27/VERSION")"

# ---------------------------------------------------------------------------
# The gate is in the patch that would be filed, and it is inside the AVM_WASM
# arm. Read from the patch's own added lines, not from the tree.
# ---------------------------------------------------------------------------
ARCH_ADDED="$(m6_patch_added "$M6_PATCH_4" 'cmake/arch.cmake')"
assert_contains "the patch adds a compile-and-link probe" "check_cxx_source_compiles" "$ARCH_ADDED"
assert_contains "the probe throws across a noinline boundary" "__attribute__((noinline))" "$ARCH_ADDED"
assert_contains "and catches by type" "catch (const Revert& r)" "$ARCH_ADDED"
assert_contains "the probe is compiled with the build's own exception flags" \
  "CMAKE_REQUIRED_FLAGS \"-fwasm-exceptions" "$ARCH_ADDED"
assert_contains "and linked with them, plus the unwinder" \
  "CMAKE_REQUIRED_LINK_OPTIONS" "$ARCH_ADDED"
assert_contains "a failed probe is a FATAL_ERROR" "message(FATAL_ERROR" "$ARCH_ADDED"
assert_contains "and the message names the required toolchain version" \
  "wasi-sdk 33.0 or newer" "$ARCH_ADDED"
assert_contains "a passed probe says so at configure time" \
  "wasm C++ exceptions probe passed" "$ARCH_ADDED"
# The else() arm — every other wasm build — is untouched.
assert_contains "the non-AVM_WASM arm still compiles -fno-exceptions" \
  "add_compile_options(-fno-exceptions)" "$(cat "$M6_TREE_AVM/barretenberg/cpp/cmake/arch.cmake")"

# ---------------------------------------------------------------------------
# The premise, established against the toolchains directly. If 27 could link a
# throwing program, the gate would be gating nothing.
# ---------------------------------------------------------------------------
PROBE_DIR="$M6_WORK/eh-probe"; mkdir -p "$PROBE_DIR"
cat >"$PROBE_DIR/probe.cpp" <<'EOF'
struct Revert { int code; };
__attribute__((noinline)) void raise(int code) { throw Revert{ code }; }
int main() {
    try { raise(7); } catch (const Revert& r) { return r.code == 7 ? 0 : 1; }
    return 2;
}
EOF
link_probe() { # <sdk> <out>
  "$1/bin/clang++" --target=wasm32-wasip1 -O2 -fwasm-exceptions \
    -mllvm -wasm-use-legacy-eh=false "$PROBE_DIR/probe.cpp" -lunwind \
    -o "$PROBE_DIR/$2" >"$PROBE_DIR/$2.log" 2>&1
}
link_probe "$SDK33" ok33.wasm; RC_P33=$?
link_probe "$SDK27" ok27.wasm; RC_P27=$?
assert_eq "wasi-sdk 33 links the throwing probe" "0" "$RC_P33"
if [ "$RC_P27" -ne 0 ]; then
  pass "wasi-sdk 27 does not  [exit $RC_P27]"
else
  fail "wasi-sdk 27 linked a throwing program — the gate has nothing to gate"
fi
assert_contains "and its failure is about the unwinder it does not ship" \
  "unable to find library -lunwind" "$(cat "$PROBE_DIR/ok27.wasm.log")"
assert_eq "27's sysroot really ships no unwinder" \
  "0" "$(find "$SDK27/share/wasi-sysroot" -name 'libunwind*' 2>/dev/null | wc -l)"
assert_ge "33's does" 1 "$(find "$SDK33/share/wasi-sysroot" -name 'libunwind*' 2>/dev/null | wc -l)"
assert_true "and the probe 33 produced runs, catching the throw" \
  bash -c "cd '$PROBE_DIR' && nix develop '$FORK_ROOT' --command wasmtime run ok33.wasm"

# ---------------------------------------------------------------------------
# The positive arm: 33, AVM_WASM on. Configures, and says the probe passed.
# ---------------------------------------------------------------------------
m6_configure_with_prefix "$SDK33" "$M6_TREE_AVM" wasm-avm build-gate33
RC_G33=$?
LOG_G33="$(m6_log "$M6_TREE_AVM" build-gate33)"
assert_eq "with wasi-sdk 33 the AVM_WASM configure exits 0" "0" "$RC_G33"
assert_contains "and reports the probe passed" \
  "AVM_WASM: wasm C++ exceptions probe passed" "$LOG_G33"
assert_not_contains "with no CMake error" "CMake Error" "$LOG_G33"
assert_eq "the probe's result is cached as supported" \
  "1" "$(m6_cache "$M6_TREE_AVM" build-gate33 BB_WASM_EXCEPTIONS_SUPPORTED)"

# ---------------------------------------------------------------------------
# The negative arm: 27, AVM_WASM on. Fails, at configure, naming the version.
# ---------------------------------------------------------------------------
m6_configure_with_prefix "$SDK27" "$M6_TREE_AVM" wasm-avm build-gate27
RC_G27=$?
LOG_G27="$(m6_log "$M6_TREE_AVM" build-gate27)"
if [ "$RC_G27" -ne 0 ]; then
  pass "with wasi-sdk 27 the AVM_WASM configure fails  [exit $RC_G27]"
else
  fail "wasi-sdk 27 configured an AVM_WASM build"
fi
assert_contains "the failure is a CMake error in cmake/arch.cmake" \
  "CMake Error at cmake/arch.cmake" "$LOG_G27"
assert_contains "it says which option asked for exceptions" "AVM_WASM is ON" "$LOG_G27"
assert_contains "it names the required wasi-sdk version" "wasi-sdk 33.0 or newer" "$LOG_G27"
assert_contains "it names the toolchain that failed" "$SDK27/bin/clang++" "$LOG_G27"
assert_contains "and its sysroot" "$SDK27/share/wasi-sysroot" "$LOG_G27"
assert_contains "it tells the reader the variable to move" "WASI_SDK_PREFIX" "$LOG_G27"
assert_contains "and that leaving the option off costs them nothing" \
  "leave AVM_WASM OFF" "$LOG_G27"
assert_contains "cmake stopped at configure" "Configuring incomplete, errors occurred!" "$LOG_G27"
assert_not_contains "and never reported the probe passing" \
  "exceptions probe passed" "$LOG_G27"

# It failed at CONFIGURE, not at build: no ninja file was written, so no
# translation unit was ever compiled.
assert_false "no build.ninja was produced" \
  test -f "$M6_TREE_AVM/barretenberg/cpp/build-gate27/build.ninja"
assert_eq "and no object file was produced" \
  "0" "$(find "$M6_TREE_AVM/barretenberg/cpp/build-gate27" -name '*.obj' 2>/dev/null | wc -l)"

# The specific failure mode, from CMake's own record of the probe. Counts and a
# message can both be right while the probe measured something else entirely;
# the recorded command line is what says it did not.
CFGLOG="$M6_TREE_AVM/barretenberg/cpp/build-gate27/CMakeFiles/CMakeConfigureLog.yaml"
assert_file "cmake recorded the probe" "$CFGLOG"
assert_contains "under the gate's own variable" "BB_WASM_EXCEPTIONS_SUPPORTED" "$(cat "$CFGLOG")"
assert_contains "the probe was compiled with -fwasm-exceptions" \
  "-fwasm-exceptions" "$(cat "$CFGLOG")"
assert_contains "and it failed on the missing unwinder" \
  "wasm-ld: error: unable to find library -lunwind" "$(cat "$CFGLOG")"

# ---------------------------------------------------------------------------
# THE ASSERTION THAT PINS THE GATE. Remove only the FATAL_ERROR block; the same
# toolchain then configures. Nothing else about the tree changes.
# ---------------------------------------------------------------------------
m6_reset_tree nogate
NOGATE=$(m6_prepare_tree nogate "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4")
# The substitution swallows `die`, so an unpreparable tree arrives here as the
# empty string and `git -C ""` below runs in the CALLER's repository. Guard it,
# exactly as m6_prepare_trees does.
m6_tree_or_die NOGATE
python3 - "$NOGATE/barretenberg/cpp/cmake/arch.cmake" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
# Delete exactly the `if(NOT BB_WASM_EXCEPTIONS_SUPPORTED) ... endif()` block.
out, n = re.subn(r"\n *if\(NOT BB_WASM_EXCEPTIONS_SUPPORTED\).*?\n *endif\(\)\n",
                 "\n", s, flags=re.S)
assert n == 1, f"expected exactly one gate block, found {n}"
open(p, "w").write(out)
PY
GATE_EDIT=$?
assert_eq "the control removes exactly one FATAL_ERROR block and nothing else" "0" "$GATE_EDIT"
assert_eq "the control tree differs from the AVM_WASM tree by one file" \
  "barretenberg/cpp/cmake/arch.cmake" \
  "$(git -C "$NOGATE" diff --name-only HEAD | tr '\n' ' ' | sed 's/ $//')"
assert_eq "and by removing the FATAL_ERROR, nothing else" \
  "0" "$(git -C "$NOGATE" diff HEAD | grep -E '^\+' | grep -vE '^\+\+\+' | grep -c .)"
assert_contains "the probe itself is still there" "check_cxx_source_compiles" \
  "$(cat "$NOGATE/barretenberg/cpp/cmake/arch.cmake")"

m6_configure_with_prefix "$SDK27" "$NOGATE" wasm-avm build-gate27
RC_NOGATE=$?
LOG_NOGATE="$(m6_log "$NOGATE" build-gate27)"
assert_eq "without the FATAL_ERROR, wasi-sdk 27 configures an AVM_WASM build successfully" \
  "0" "$RC_NOGATE"
assert_contains "having failed the same probe" "BB_WASM_EXCEPTIONS_SUPPORTED" \
  "$(cat "$NOGATE/barretenberg/cpp/build-gate27/CMakeFiles/CMakeConfigureLog.yaml" 2>/dev/null)"
assert_eq "so the exit-1 above was the gate and nothing else" \
  "yes" "$([ "$RC_G27" -ne 0 ] && [ "$RC_NOGATE" -eq 0 ] && echo yes || echo no)"
m6_reset_tree nogate

# ---------------------------------------------------------------------------
# SCOPE. The same toolchain, upstream's own `wasm` preset, AVM_WASM off. This
# must still work, or the patch has broken every existing wasm build.
# ---------------------------------------------------------------------------
m6_configure_with_prefix "$SDK27" "$M6_TREE_AVM" wasm build-gate27-plain
RC_PLAIN=$?
LOG_PLAIN="$(m6_log "$M6_TREE_AVM" build-gate27-plain)"
assert_eq "wasi-sdk 27 still configures the plain wasm preset with the patch applied" \
  "0" "$RC_PLAIN"
assert_not_contains "the gate does not fire there" "AVM_WASM is ON" "$LOG_PLAIN"
assert_not_contains "nor does the probe run there" "exceptions probe" "$LOG_PLAIN"
assert_eq "the probe variable is not even in that cache" \
  "" "$(m6_cache "$M6_TREE_AVM" build-gate27-plain BB_WASM_EXCEPTIONS_SUPPORTED)"
assert_eq "and AVM_WASM is OFF there" \
  "OFF" "$(m6_cache "$M6_TREE_AVM" build-gate27-plain AVM_WASM)"

rm -rf "$M6_TREE_AVM/barretenberg/cpp/build-gate33" \
       "$M6_TREE_AVM/barretenberg/cpp/build-gate27" \
       "$M6_TREE_AVM/barretenberg/cpp/build-gate27-plain" \
       "$NOGATE/barretenberg/cpp/build-gate27"

finish
