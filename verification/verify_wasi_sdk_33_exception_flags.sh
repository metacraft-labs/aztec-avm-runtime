#!/usr/bin/env bash
# verify_wasi_sdk_33_exception_flags
#
# M0 verification: the C++-exceptions-on-wasm flag recipe. The AVM signals
# reverts by THROWING, so this is load-bearing for the whole campaign.
#
#   $WASI_SDK_PATH/bin/clang++ --target=wasm32-wasip1 -O2 \
#       -fwasm-exceptions -mllvm -wasm-use-legacy-eh=false \
#       vm2wasm/probe/exc.cpp -lunwind -o exc.wasm
#
# Three things are asserted, the last two being NEGATIVE CONTROLS — without
# them "it compiled and ran" would not establish that either flag is needed:
#
#   POSITIVE  the module links, and an exception thrown across a `noinline`
#             boundary is caught BY TYPE and execution continues, on wasmtime
#             AND on V8 (node's `node:wasi`, i.e. the browser engine).
#   NEGATIVE  dropping -lunwind fails to LINK (the driver does not add it):
#             undefined __cpp_exception / __wasm_lpad_context /
#             _Unwind_RaiseException / _Unwind_CallPersonality.
#   NEGATIVE  dropping -mllvm -wasm-use-legacy-eh=false makes LLVM emit the
#             LEGACY `try` instruction instead of the standardised
#             `try_table`, and wasmtime refuses to compile the module
#             ("legacy_exceptions feature required for try instruction").
#
# CORRECTION TO THE CAMPAIGN LOG, asserted here rather than left as folklore:
# node 24 / V8 ACCEPTS the legacy-EH encoding. The earlier note (and
# vm2wasm/README.md) claims V8 rejects it; it does not, at least at node
# 24.19 / V8 13.x. wasmtime 47 is the runtime that rejects it. The check
# asserts both halves of that so the record stays honest and a future V8 that
# drops legacy EH shows up as a failure here rather than as a mystery.
#
# Run: just verify-exception-flags

TEST_NAME="verify_wasi_sdk_33_exception_flags"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_nix

PROBE_SRC="$REPO_ROOT/vm2wasm/probe/exc.cpp"
NODE_RUNNER="$REPO_ROOT/vm2wasm/probe/run_node.mjs"
assert_file "the exception probe source is in the repo" "$PROBE_SRC"
assert_file "the V8 runner is in the repo" "$NODE_RUNNER"
[ -f "$PROBE_SRC" ] && [ -f "$NODE_RUNNER" ] || die "the probe sources are missing"

# The probe must actually exercise a throw across a noinline boundary caught by
# type — otherwise a green run proves nothing about exception handling.
SRC="$(cat "$PROBE_SRC")"
assert_contains "the probe throws across a noinline boundary" "__attribute__((noinline))" "$SRC"
assert_contains "the probe throws" "throw AvmRevert" "$SRC"
assert_contains "the probe catches by type" "catch (const AvmRevert& e)" "$SRC"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

EXPECTED_STDOUT='opcode ok 1
reverted: out of gas
opcode ok 7
survived'

RUNNER="
  set -u
  cd '$WORK'
  CXX=\"\$WASI_SDK_PATH/bin/clang++\"
  echo \"wasi_sdk_version=\$(head -1 \"\$WASI_SDK_PATH/VERSION\")\"
  echo \"wasmtime_version=\$(wasmtime --version | head -1)\"
  echo \"node_version=\$(node --version)\"

  echo '@@@ build_good'
  \"\$CXX\" --target=wasm32-wasip1 -O2 -fwasm-exceptions \\
      -mllvm -wasm-use-legacy-eh=false '$PROBE_SRC' -lunwind -o good.wasm 2>&1
  echo \"@@@ build_good_rc=\$?\"

  echo '@@@ wasmtime_good'
  wasmtime run good.wasm 2>&1
  echo \"@@@ wasmtime_good_rc=\$?\"

  echo '@@@ node_good'
  node --no-warnings '$NODE_RUNNER' good.wasm 2>/dev/null
  echo \"@@@ node_good_rc=\$?\"

  echo '@@@ node_good_stderr'
  node --no-warnings '$NODE_RUNNER' good.wasm 2>&1 >/dev/null
  echo \"@@@ node_good_stderr_rc=\$?\"

  echo '@@@ build_nounwind'
  \"\$CXX\" --target=wasm32-wasip1 -O2 -fwasm-exceptions \\
      -mllvm -wasm-use-legacy-eh=false '$PROBE_SRC' -o nounwind.wasm 2>&1
  echo \"@@@ build_nounwind_rc=\$?\"

  echo '@@@ build_legacy'
  \"\$CXX\" --target=wasm32-wasip1 -O2 -fwasm-exceptions \\
      '$PROBE_SRC' -lunwind -o legacy.wasm 2>&1
  echo \"@@@ build_legacy_rc=\$?\"

  echo '@@@ wasmtime_legacy'
  wasmtime run legacy.wasm 2>&1
  echo \"@@@ wasmtime_legacy_rc=\$?\"

  echo '@@@ node_legacy'
  node --no-warnings '$NODE_RUNNER' legacy.wasm 2>/dev/null
  echo \"@@@ node_legacy_rc=\$?\"
"

OUT="$(in_shell_status "$REPO_ROOT" "$RUNNER")"
[ -n "$OUT" ] || die "the probe runner produced no output"

# section <name> -> the lines between '@@@ <name>' and the next '@@@ '
section() {
  printf '%s\n' "$OUT" | awk -v want="@@@ $1" '
    $0 == want { grab = 1; next }
    /^@@@ / { grab = 0 }
    grab { print }'
}
rc_of() { printf '%s\n' "$OUT" | sed -n "s/^@@@ $1_rc=//p" | head -1; }
kv() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }

assert_prefix "the toolchain under test is wasi-sdk 33" "33." "$(kv wasi_sdk_version)"
note "runtimes: $(kv wasmtime_version), node $(kv node_version)"

# ---- POSITIVE --------------------------------------------------------------
assert_eq "the full flag recipe links" "0" "$(rc_of build_good)"
assert_eq "wasmtime runs the module" "0" "$(rc_of wasmtime_good)"
assert_eq "wasmtime: the throw is caught by type and execution continues" \
  "$EXPECTED_STDOUT" "$(section wasmtime_good)"
assert_eq "node/V8 runs the module" "0" "$(rc_of node_good)"
assert_eq "node/V8: the throw is caught by type and execution continues" \
  "$EXPECTED_STDOUT" "$(section node_good)"
assert_contains "node/V8 accepted the module at compile time" \
  "V8 accepted the module" "$(section node_good_stderr)"

# ---- NEGATIVE 1: -lunwind is not optional ----------------------------------
if [ "$(rc_of build_nounwind)" != "0" ]; then
  pass "omitting -lunwind fails to link"
else
  fail "omitting -lunwind unexpectedly linked — the negative control is void"
fi
NOUNWIND="$(section build_nounwind)"
assert_contains "the -lunwind failure names the unwinder symbols" \
  "undefined symbol: __cpp_exception" "$NOUNWIND"
assert_contains "the -lunwind failure names _Unwind_CallPersonality" \
  "_Unwind_CallPersonality" "$NOUNWIND"

# ---- NEGATIVE 2: legacy EH is what -wasm-use-legacy-eh=false avoids --------
assert_eq "omitting the legacy-eh flag still LINKS (the failure is at runtime)" \
  "0" "$(rc_of build_legacy)"
if [ "$(rc_of wasmtime_legacy)" != "0" ]; then
  pass "wasmtime rejects the legacy-EH module"
else
  fail "wasmtime accepted the legacy-EH module — the negative control is void"
fi
assert_contains "wasmtime names the legacy try instruction as the reason" \
  "legacy_exceptions feature required for try instruction" "$(section wasmtime_legacy)"
# The documented correction: V8 still supports legacy EH. If a future V8 drops
# it, this assertion fails and the note above must be revised.
assert_eq "node/V8 still ACCEPTS legacy EH (correcting the campaign log's claim)" \
  "0" "$(rc_of node_legacy)"

finish
