#!/usr/bin/env bash
# test_wasi_sdk_33_catches_inside_wasm
#
# M4 verification, the other half of test_wasi_sdk_27_cannot_link_exceptions: the
# same probe, compiled with wasi-sdk 33 and the three flags the working
# configuration needs, throws across a `noinline` boundary, unwinds and is CAUGHT
# BY TYPE inside the wasm module — on wasmtime AND on V8 (node's `node:wasi`), so
# the argument covers the browser engine and not only the standalone runtime.
#
# Each of the three flags carries its recorded failure mode, and each is asserted
# by its SPECIFIC failure rather than by "the build broke":
#
#   -fwasm-exceptions            without it the throw/catch is compiled as
#                                unsupported and the link fails.
#   -lunwind                     without it the link fails on __cpp_exception,
#                                __wasm_lpad_context, _Unwind_RaiseException and
#                                _Unwind_CallPersonality — clang does not add it.
#   -mllvm -wasm-use-legacy-eh=false
#                                without it LLVM emits the LEGACY `try`
#                                instruction instead of the standardised
#                                `try_table`, and wasmtime refuses the module with
#                                "legacy_exceptions feature required for try
#                                instruction". The encoding is read out of the two
#                                artefacts as well, so the claim rests on the
#                                bytes and not only on one runtime's opinion.
#
# RECORDED CORRECTION, asserted rather than left as folklore: node 24 / V8 still
# ACCEPTS the legacy-EH encoding. wasmtime 47 is the runtime that rejects it. Both
# halves are asserted, so a future V8 that drops legacy EH shows up here as a
# failure rather than as a mystery.
#
# This overlaps M0's verify_wasi_sdk_33_exception_flags on purpose — M0 asserts
# the flag recipe this repo's own build depends on; M4 asserts the same recipe as
# the evidence attached to an upstream patch, adds the two remaining named
# symbols, and reads the instruction encoding out of the artefacts.
#
# Run: just verify-wasi33-catches

TEST_NAME="test_wasi_sdk_33_catches_inside_wasm"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_wasi33.sh"

require_nix

assert_file "the throwing probe is in the prepared contribution" "$M4_PROBE"
[ -f "$M4_PROBE" ] || die "the probe source is missing"

SRC="$(cat "$M4_PROBE")"
assert_contains "the probe throws across a noinline boundary" "__attribute__((noinline))" "$SRC"
assert_contains "the probe throws" "throw AvmRevert" "$SRC"
assert_contains "the probe catches by type" "catch (const AvmRevert& e)" "$SRC"

SDK33="$(m4_sdk 33)"
note "wasi-sdk 33: $SDK33  ($(head -1 "$SDK33/VERSION"))"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

link() { # <out> <flags...>
  local out="$1"; shift
  "$SDK33/bin/clang++" --target=wasm32-wasip1 -O2 "$@" "$M4_PROBE" -o "$WORK/$out" \
    >"$WORK/$out.log" 2>&1
}

# ---------------------------------------------------------------------------
# POSITIVE: the full recipe links, runs, and catches.
# ---------------------------------------------------------------------------
link good.wasm -fwasm-exceptions -mllvm -wasm-use-legacy-eh=false -lunwind
RC_GOOD=$?
assert_eq "the full flag recipe links" "0" "$RC_GOOD"
[ "$RC_GOOD" -eq 0 ] || die "cannot continue: $(head -5 "$WORK/good.wasm.log")"

WT_OUT="$(m4_in_devshell 'wasmtime run "$1" 2>&1' "$WORK/good.wasm")"
WT_RC=$?
assert_eq "wasmtime runs the module" "0" "$WT_RC"
assert_eq "wasmtime: the throw is caught BY TYPE and execution continues" \
  "$M4_PROBE_EXPECTED" "$WT_OUT"

V8_OUT="$(m4_in_devshell 'node --no-warnings "$1" "$2" 2>/dev/null' \
            "$REPO_ROOT/vm2wasm/probe/run_node.mjs" "$WORK/good.wasm")"
V8_RC=$?
assert_eq "node/V8 runs the module" "0" "$V8_RC"
assert_eq "node/V8: the throw is caught BY TYPE and execution continues" \
  "$M4_PROBE_EXPECTED" "$V8_OUT"

# ---------------------------------------------------------------------------
# NEGATIVE 1: -lunwind is not optional, and the failure names the unwinder.
# ---------------------------------------------------------------------------
link nounwind.wasm -fwasm-exceptions -mllvm -wasm-use-legacy-eh=false
RC_NOUNWIND=$?
if [ "$RC_NOUNWIND" -ne 0 ]; then
  pass "omitting -lunwind fails to link  [exit $RC_NOUNWIND]"
else
  fail "omitting -lunwind unexpectedly linked — the negative control is void"
fi
NOUNWIND_LOG="$(cat "$WORK/nounwind.wasm.log")"
for sym in __cpp_exception __wasm_lpad_context _Unwind_RaiseException _Unwind_CallPersonality; do
  assert_contains "the -lunwind failure names $sym" "undefined symbol: $sym" "$NOUNWIND_LOG"
done

# ---------------------------------------------------------------------------
# NEGATIVE 2: -fwasm-exceptions is not optional either. Without it clang selects
# the `noeh/` multilib, which puts wasi-sdk 33 in exactly wasi-sdk 27's position:
# the same undefined C++ exception runtime. So the flag is what reaches the
# exception-enabled sysroot, and the bump alone would not have been enough.
# ---------------------------------------------------------------------------
link noeh.wasm
RC_NOEH=$?
if [ "$RC_NOEH" -ne 0 ]; then
  pass "omitting -fwasm-exceptions fails to link  [exit $RC_NOEH]"
else
  fail "omitting -fwasm-exceptions unexpectedly linked — the negative control is void"
fi
NOEH_LOG="$(cat "$WORK/noeh.wasm.log")"
for sym in __cxa_allocate_exception __cxa_throw; do
  assert_contains "the noeh/ multilib fails on $sym, exactly as 27 does" \
    "undefined symbol: $sym" "$NOEH_LOG"
done
# Only the THROW side is undefined: without -fwasm-exceptions the catch handlers
# emit no landing pad and no __cxa_begin_catch reference at all. Asserted, because
# it is the same shape as the hazard the patch is about — the recovery path
# disappears silently and only the throw side complains.
assert_not_contains "and the catch side is simply gone (no __cxa_begin_catch reference)" \
  "undefined symbol: __cxa_begin_catch" "$NOEH_LOG"
# And with -lunwind it fails EARLIER and differently: the noeh/ multilib has no
# unwinder to link at all. Asserted so the two failure modes are not conflated.
link noeh-unwind.wasm -lunwind
assert_false "the noeh/ multilib has no libunwind to link either" test -f "$WORK/noeh-unwind.wasm"
assert_contains "and lld says exactly that" \
  "unable to find library -lunwind" "$(cat "$WORK/noeh-unwind.wasm.log")"

# ---------------------------------------------------------------------------
# NEGATIVE 3: legacy EH. It LINKS — the failure is at runtime, on one runtime and
# not the other, which is the whole reason the flag is easy to miss.
# ---------------------------------------------------------------------------
link legacy.wasm -fwasm-exceptions -lunwind
RC_LEGACY=$?
assert_eq "omitting -wasm-use-legacy-eh=false still LINKS" "0" "$RC_LEGACY"

# Read the encoding out of the two artefacts, so this rests on the emitted bytes
# rather than on a runtime's error message alone.
GOOD_WAT="$(m4_in_devshell 'wasm2wat --enable-all "$1" 2>/dev/null | grep -cE "^[[:space:]]*try_table"' "$WORK/good.wasm")"
LEGACY_TRY="$(m4_in_devshell 'wasm2wat --enable-all "$1" 2>/dev/null | grep -cE "^[[:space:]]*try([[:space:]]|$)"' "$WORK/legacy.wasm")"
# Pinned, not merely non-zero: the toolchain comes from a recorded release hash and
# the flags are fixed, so these counts are reproducible, and pinning them is what
# makes "the encoding is read out of the artefacts" mean the encoding and not just
# "some instruction was found".
assert_eq "the flagged module emits the standardised try_table" "21" "$GOOD_WAT"
assert_eq "the unflagged module emits the LEGACY try instruction" "5" "$LEGACY_TRY"
# And the assertion that actually explains why one runs and the other does not: with
# the flag there is NO legacy `try` anywhere in the module. (The converse does not
# hold and must not be asserted — the unflagged module carries 16 `try_table`
# instructions as well, from the prebuilt `eh/` multilib objects it links; only the
# translation unit clang compiles here follows the flag. Measured, not assumed.)
LEGACY_IN_GOOD="$(m4_in_devshell 'wasm2wat --enable-all "$1" 2>/dev/null | grep -cE "^[[:space:]]*try([[:space:]]|$)"' "$WORK/good.wasm")"
assert_eq "and the flagged module emits no legacy try at all — which is why it runs" "0" "$LEGACY_IN_GOOD"

WT_LEGACY_OUT="$(m4_in_devshell 'wasmtime run "$1" 2>&1' "$WORK/legacy.wasm")"
WT_LEGACY_RC=$?
if [ "$WT_LEGACY_RC" -ne 0 ]; then
  pass "wasmtime rejects the legacy-EH module  [exit $WT_LEGACY_RC]"
else
  fail "wasmtime accepted the legacy-EH module — the negative control is void"
fi
assert_contains "wasmtime names the legacy try instruction as the reason" \
  "legacy_exceptions feature required for try instruction" "$WT_LEGACY_OUT"

V8_LEGACY_OUT="$(m4_in_devshell 'node --no-warnings "$1" "$2" 2>/dev/null' \
                   "$REPO_ROOT/vm2wasm/probe/run_node.mjs" "$WORK/legacy.wasm")"
V8_LEGACY_RC=$?
assert_eq "node/V8 still ACCEPTS legacy EH (the recorded correction)" "0" "$V8_LEGACY_RC"
assert_eq "and catches correctly under it too" "$M4_PROBE_EXPECTED" "$V8_LEGACY_OUT"

finish
