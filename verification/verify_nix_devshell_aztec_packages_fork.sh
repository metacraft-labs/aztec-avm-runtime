#!/usr/bin/env bash
# verify_nix_devshell_aztec_packages_fork
#
# M0 verification: from inside metacraft-labs/aztec-packages' `nix develop`,
# the `wasm` CMake preset configures and `ninja numeric_objects` compiles real
# barretenberg C++ to wasm32-wasip1, with the toolchain coming from nix rather
# than from the host.
#
# It also asserts the two build gotchas M0 resolved IN THE SHELL rather than
# per-invocation:
#   1. scripts/remake-constants.sh invokes `clang-format-20` by that exact
#      versioned name during CMake configure and aborts the whole configure if
#      it is missing. The flake provides a writeShellScriptBin alias.
#   2. nixpkgs' cmake 4.x hard-errors on FetchContent'd dependencies declaring
#      cmake_minimum_required below 3.5, so the shell exports
#      CMAKE_POLICY_VERSION_MINIMUM=3.5.
#
# KNOWN UPSTREAM DEVIATION, asserted rather than papered over: upstream's
# `wasm` preset HARDCODES "WASI_SDK_PREFIX": "/opt/wasi-sdk" in its
# `environment` block. A CMake preset's `environment` map wins over the
# ambient environment, and `$env{WASI_SDK_PREFIX}` inside that same map
# resolves to the preset's own value — so the shell's WASI_SDK_PREFIX is
# ignored and a bare `cmake --preset wasm` fails with
# "Could not find the compiler specified in the environment variable CXX:
# /opt/wasi-sdk/bin/clang++". This check detects that hardcoding and supplies
# the five `-D` overrides that neutralise it (CMAKE_C_COMPILER,
# CMAKE_CXX_COMPILER, CMAKE_AR, CMAKE_RANLIB, CMAKE_SYSROOT). When the preset is fixed to use
# `$penv{WASI_SDK_PREFIX}` (M6/M10), the check notices and drops the overrides.
#
# Run: just verify-devshell-fork

TEST_NAME="verify_nix_devshell_aztec_packages_fork"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_nix
command -v python3 >/dev/null 2>&1 || die "python3 is required to read CMakePresets.json"

# The fork is a workspace-root sibling. If it is not, the M0 layout decision
# has been undone and every path below is wrong.
assert_dir "the fork is checked out as a workspace-root sibling" "$FORK_ROOT"
[ -d "$FORK_ROOT" ] || die "no fork at $FORK_ROOT"
assert_file "the fork carries its own flake.nix" "$FORK_ROOT/flake.nix"
assert_file "the fork carries its own flake.lock" "$FORK_ROOT/flake.lock"
assert_file "the fork carries its own nix/wasi-sdk.nix" "$FORK_ROOT/nix/wasi-sdk.nix"

CPP="$FORK_ROOT/barretenberg/cpp"
assert_file "the wasm preset exists" "$CPP/CMakePresets.json"
[ -f "$CPP/CMakePresets.json" ] || die "no CMakePresets.json at $CPP"

# ---- gotcha 1 + 2, and the shell's identity --------------------------------
PROBE='
  set -u
  emit() { printf "%s=%s\n" "$1" "$2"; }
  emit clang_format_20  "$(clang-format-20 --version 2>/dev/null | head -1)"
  emit clang_format_20_path "$(command -v clang-format-20 2>/dev/null)"
  emit cmake_policy_min "${CMAKE_POLICY_VERSION_MINIMUM:-}"
  emit cmake_version    "$(cmake --version 2>/dev/null | head -1)"
  emit ninja_path       "$(command -v ninja 2>/dev/null)"
  emit wasi_sdk_path    "${WASI_SDK_PATH:-}"
  emit wasi_sdk_version "$(head -1 "${WASI_SDK_PATH:-/nonexistent}/VERSION" 2>/dev/null)"
  emit wasi_triple      "$("${WASI_SDK_PATH:-/nonexistent}/bin/clang" --print-target-triple 2>/dev/null)"
'
PROBE_OUT="$(in_shell "$FORK_ROOT" "$PROBE")" || die "nix develop failed for $FORK_ROOT"
[ -n "$PROBE_OUT" ] || die "the dev-shell probe produced no output"
get() { printf '%s\n' "$PROBE_OUT" | sed -n "s/^$1=//p" | head -1; }

assert_contains "gotcha 1: clang-format-20 exists under that exact versioned name" \
  "clang-format version 20." "$(get clang_format_20)"
assert_nix_store "gotcha 1: the clang-format-20 alias comes from the flake" \
  "$(get clang_format_20_path)"
assert_eq "gotcha 2: CMAKE_POLICY_VERSION_MINIMUM is exported as 3.5" \
  "3.5" "$(get cmake_policy_min)"
assert_prefix "cmake is nixpkgs' cmake 4.x (the version gotcha 2 exists for)" \
  "cmake version 4." "$(get cmake_version)"
assert_nix_store "ninja resolves into the nix store" "$(get ninja_path)"
assert_prefix "wasi-sdk is release 33" "33." "$(get wasi_sdk_version)"
assert_eq "the wasi-sdk clang targets wasm32-wasip1" \
  "wasm32-unknown-wasip1" "$(get wasi_triple)"
assert_nix_store "WASI_SDK_PATH points into the nix store, not at a host install" \
  "$(get wasi_sdk_path)"
# The upstream preset's hardcoded prefix must NOT exist on this host: if it
# did, a green build would prove nothing about the nix toolchain.
assert_false "no host wasi-sdk at /opt/wasi-sdk shadows the nix one" \
  test -e /opt/wasi-sdk

# ---- does the preset still hardcode /opt/wasi-sdk? -------------------------
PRESET_PREFIX="$(python3 - "$CPP/CMakePresets.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for p in d.get("configurePresets", []):
    if p.get("name") == "wasm":
        print(p.get("environment", {}).get("WASI_SDK_PREFIX", ""))
        break
PY
)"
OVERRIDES=""
if [ "$PRESET_PREFIX" = '$penv{WASI_SDK_PREFIX}' ]; then
  note "the wasm preset honours the ambient WASI_SDK_PREFIX; no overrides needed"
  pass "the wasm preset reads WASI_SDK_PREFIX from the environment"
else
  assert_eq "the wasm preset still hardcodes the upstream wasi-sdk prefix (see header)" \
    "/opt/wasi-sdk" "$PRESET_PREFIX"
  OVERRIDES='
    -DCMAKE_C_COMPILER="$WASI_SDK_PATH/bin/clang"
    -DCMAKE_CXX_COMPILER="$WASI_SDK_PATH/bin/clang++"
    -DCMAKE_AR="$WASI_SDK_PATH/bin/llvm-ar"
    -DCMAKE_RANLIB="$WASI_SDK_PATH/bin/llvm-ranlib"
    -DCMAKE_SYSROOT="$WASI_SDK_PATH/share/wasi-sysroot"'
fi

# ---- configure + compile ---------------------------------------------------
BUILD="build-wasm"   # the preset's own binaryDir; matched by barretenberg/cpp/.gitignore
OBJDIR="$CPP/$BUILD/src/barretenberg/numeric/CMakeFiles/numeric_objects.dir"
# Force a real compile every run: a stale .obj from a previous invocation would
# make "ninja succeeded" mean nothing.
rm -f "$OBJDIR"/uintx/uintx.cpp.obj "$OBJDIR"/random/engine.cpp.obj 2>/dev/null

CONFIGURE_OUT="$(in_shell_status "$FORK_ROOT" "cd barretenberg/cpp && cmake --preset wasm $(printf '%s' "$OVERRIDES" | tr -d '\n')")"
CONFIGURE_RC=$?
if [ "$CONFIGURE_RC" -eq 0 ]; then
  pass "cmake --preset wasm configures from inside the dev shell"
else
  fail "cmake --preset wasm failed (rc=$CONFIGURE_RC): $(printf '%s' "$CONFIGURE_OUT" | tail -12)"
fi
assert_contains "the configure wrote the preset's build tree" \
  "$BUILD" "$CONFIGURE_OUT"

# The configure must have picked the nix wasi-sdk compiler, not something else
# that happens to be able to emit wasm.
CACHE="$CPP/$BUILD/CMakeCache.txt"
assert_file "the configure produced a CMake cache" "$CACHE"
if [ -f "$CACHE" ]; then
  CACHED_CXX="$(sed -n 's/^CMAKE_CXX_COMPILER:[^=]*=//p' "$CACHE" | head -1)"
  assert_prefix "the cached C++ compiler is the nix wasi-sdk clang++" \
    "$(get wasi_sdk_path)/bin/clang++" "$CACHED_CXX"
fi

BUILD_OUT="$(in_shell_status "$FORK_ROOT" "cd barretenberg/cpp && ninja -C $BUILD numeric_objects")"
BUILD_RC=$?
if [ "$BUILD_RC" -eq 0 ]; then
  pass "ninja numeric_objects compiles real barretenberg C++"
else
  fail "ninja numeric_objects failed (rc=$BUILD_RC): $(printf '%s' "$BUILD_OUT" | tail -15)"
fi
assert_contains "ninja actually compiled (not a no-op re-run)" \
  "Building CXX object" "$BUILD_OUT"

# ---- the output really is wasm32 -------------------------------------------
# `ninja exited 0` says nothing about the object format. Check the WebAssembly
# magic number ("\0asm" + version 1) on the emitted objects directly.
for obj in "$OBJDIR/uintx/uintx.cpp.obj" "$OBJDIR/random/engine.cpp.obj"; do
  assert_file "numeric_objects emitted $(basename "$obj")" "$obj"
  if [ -f "$obj" ]; then
    MAGIC="$(head -c 8 "$obj" | od -An -tx1 | tr -d ' \n')"
    assert_eq "$(basename "$obj") carries the WebAssembly magic number" \
      "0061736d01000000" "$MAGIC"
  fi
done

# Belt and braces: ask the toolchain's own objdump what it thinks the file is.
OBJDUMP_OUT="$(in_shell_status "$FORK_ROOT" \
  "\$WASI_SDK_PATH/bin/llvm-objdump -h '$OBJDIR/uintx/uintx.cpp.obj'")"
assert_contains "llvm-objdump reports wasm object format" "file format wasm" "$OBJDUMP_OUT"
assert_contains "the object has a CODE section (it is not an empty stub)" \
  "CODE" "$OBJDUMP_OUT"

finish
