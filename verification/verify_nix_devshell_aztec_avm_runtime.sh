#!/usr/bin/env bash
# verify_nix_devshell_aztec_avm_runtime
#
# M0 verification: `nix develop` in metacraft-labs/aztec-avm-runtime provides
# node 24, yarn-berry, wasi-sdk 33, wasmtime, binaryen, wabt, cmake, ninja and
# clang 20, and exports WASI_SDK_PATH, WASI_SDK_PREFIX and the LD_LIBRARY_PATH
# the prebuilt NAPI AVM needs.
#
# This asserts the VERSIONS and the VARIABLES the milestone names, not merely
# that `nix develop` exits 0. Every tool must additionally resolve into the nix
# store: the whole point of the shell is that the toolchain is not the host's.
#
# Run: just verify-devshell-runtime   (or: verification/verify_nix_devshell_aztec_avm_runtime.sh)

TEST_NAME="verify_nix_devshell_aztec_avm_runtime"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_nix
assert_file "flake.nix present" "$REPO_ROOT/flake.nix"
assert_file "flake.lock present" "$REPO_ROOT/flake.lock"
assert_file "nix/wasi-sdk.nix present (nixpkgs has no wasi-sdk attribute)" \
  "$REPO_ROOT/nix/wasi-sdk.nix"

# One shell entry, many facts. Entering `nix develop` repeatedly is the
# expensive part; the probe emits a key=value line per fact and the assertions
# below read them back.
PROBE='
  set -u
  emit() { printf "%s=%s\n" "$1" "$2"; }
  emit node_version    "$(node --version 2>/dev/null)"
  emit node_path       "$(command -v node 2>/dev/null)"
  emit yarn_version    "$(yarn --version 2>/dev/null)"
  emit yarn_path       "$(command -v yarn 2>/dev/null)"
  emit wasmtime_version "$(wasmtime --version 2>/dev/null | head -1)"
  emit wasmtime_path   "$(command -v wasmtime 2>/dev/null)"
  emit wasmopt_version "$(wasm-opt --version 2>/dev/null | head -1)"
  emit wasmopt_path    "$(command -v wasm-opt 2>/dev/null)"
  emit wasm2wat_version "$(wasm2wat --version 2>/dev/null | head -1)"
  emit wasm2wat_path   "$(command -v wasm2wat 2>/dev/null)"
  emit cmake_version   "$(cmake --version 2>/dev/null | head -1)"
  emit cmake_path      "$(command -v cmake 2>/dev/null)"
  emit ninja_version   "$(ninja --version 2>/dev/null | head -1)"
  emit ninja_path      "$(command -v ninja 2>/dev/null)"
  emit clang20_version "$(clang-20 --version 2>/dev/null | head -1)"
  emit clang20_path    "$(command -v clang-20 2>/dev/null)"
  emit hostcxx_version "$(c++ --version 2>/dev/null | head -1)"
  emit wasi_sdk_path   "${WASI_SDK_PATH:-}"
  emit wasi_sdk_prefix "${WASI_SDK_PREFIX:-}"
  emit wasi_sdk_version "$(head -1 "${WASI_SDK_PATH:-/nonexistent}/VERSION" 2>/dev/null)"
  emit wasi_clang_triple "$("${WASI_SDK_PATH:-/nonexistent}/bin/clang" --print-target-triple 2>/dev/null)"
  emit ld_library_path "${LD_LIBRARY_PATH:-}"
  emit libstdcxx       "$(ls "${LD_LIBRARY_PATH%%:*}"/libstdc++.so.6 2>/dev/null | head -1)"
'

PROBE_OUT="$(in_shell "$REPO_ROOT" "$PROBE")" || die "nix develop failed for $REPO_ROOT"
[ -n "$PROBE_OUT" ] || die "the dev-shell probe produced no output"

get() { printf '%s\n' "$PROBE_OUT" | sed -n "s/^$1=//p" | head -1; }

# ---- versions the milestone names -----------------------------------------
assert_prefix "node is v24"                     "v24."           "$(get node_version)"
assert_prefix "yarn-berry is 4.x"               "4."             "$(get yarn_version)"
assert_prefix "wasi-sdk is release 33"          "33."            "$(get wasi_sdk_version)"
assert_prefix "wasmtime is present"             "wasmtime "      "$(get wasmtime_version)"
assert_prefix "binaryen (wasm-opt) is present"  "wasm-opt versio" "$(get wasmopt_version)"
assert_true   "wabt (wasm2wat) reports a version" \
  bash -c "printf '%s' '$(get wasm2wat_version)' | grep -Eq '^[0-9]+\\.[0-9]+'"
assert_prefix "cmake is present"                "cmake version " "$(get cmake_version)"
assert_true   "ninja reports a version" \
  bash -c "printf '%s' '$(get ninja_version)' | grep -Eq '^[0-9]+\\.[0-9]+'"

# clang 20 is in the shell for NATIVE compilation. `clang` on PATH is
# deliberately wasi-sdk's (22.x, the wasm cross compiler), so the clang-20
# assertion names the versioned binary and the wrapped host c++ explicitly
# rather than whatever `clang` happens to resolve to.
assert_contains "clang 20 is available as clang-20" \
  "clang version 20." "$(get clang20_version)"
assert_contains "the host c++ driver is clang 20" \
  "clang version 20." "$(get hostcxx_version)"

# ---- exported variables the milestone names --------------------------------
WASI_PATH="$(get wasi_sdk_path)"
WASI_PREFIX="$(get wasi_sdk_prefix)"
assert_nix_store "WASI_SDK_PATH is exported and points into the nix store" "$WASI_PATH"
assert_nix_store "WASI_SDK_PREFIX is exported and points into the nix store" "$WASI_PREFIX"
assert_eq "WASI_SDK_PATH and WASI_SDK_PREFIX agree (both spellings are read by barretenberg)" \
  "$WASI_PATH" "$WASI_PREFIX"
assert_eq "the wasi-sdk clang targets wasm32-wasip1" \
  "wasm32-unknown-wasip1" "$(get wasi_clang_triple)"

# LD_LIBRARY_PATH exists specifically so @aztec/bb.js's prebuilt NAPI AVM
# (nodejs_module.node, linked against a distro libstdc++) loads under nixpkgs'
# node. Asserting the variable is non-empty proves nothing; assert the library
# it is there to supply is actually reachable through it.
LDLP="$(get ld_library_path)"
if [ "$(uname -s)" = "Linux" ]; then
  assert_nix_store "LD_LIBRARY_PATH is exported for the prebuilt NAPI AVM" "$LDLP"
  assert_file "libstdc++.so.6 is reachable through LD_LIBRARY_PATH" "$(get libstdcxx)"
else
  note "not Linux: LD_LIBRARY_PATH is intentionally empty on darwin"
fi

# ---- the toolchain is nix's, not the host's --------------------------------
for tool in node yarn wasmtime wasmopt wasm2wat cmake ninja clang20; do
  assert_nix_store "$tool resolves into the nix store" "$(get ${tool}_path)"
done

finish
