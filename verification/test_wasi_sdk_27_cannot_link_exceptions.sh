#!/usr/bin/env bash
# test_wasi_sdk_27_cannot_link_exceptions
#
# M4 verification. The premise of the whole patch, established by execution
# against the toolchain upstream actually pins rather than by quoting its release
# notes: wasi-sdk 27's sysroot cannot link a C++ program that throws, with or
# without `-fwasm-exceptions`.
#
# Both toolchains are realised from `nix/wasi-sdk.nix` (recorded release-tarball
# hashes), so 27 is not "whatever happens to be installed" and the check has no
# way to silently not run: if either cannot be built, it dies.
#
# What is asserted:
#
#   THE MECHANISM   27's libc++abi contains cxa_noexception.cpp.o and does NOT
#                   contain cxa_exception.cpp.o or cxa_personality.cpp.o; its
#                   sysroot ships zero libunwind artefacts and has no `eh/`
#                   multilib. Absence is asserted as well as presence — "the
#                   no-exception build is there" is only half the statement.
#   THE FAILURE     linking probe/exc.cpp fails, with `-fwasm-exceptions` and
#                   without it, and the failure NAMES the missing runtime:
#                   __cxa_allocate_exception, __cxa_throw, __cxa_begin_catch,
#                   _Unwind_CallPersonality, __wasm_lpad_context.
#   RIGHT REASON    probe/noexc.cpp — the same program with the throw replaced by
#                   a return code — links AND RUNS under the very same toolchain
#                   and command line. Without this the failure above could be a
#                   broken invocation or a broken sysroot rather than a statement
#                   about exceptions.
#   THE CONTRAST    33's sysroot has the objects, the unwinder and the `eh/` /
#                   `noeh/` multilibs, and links the same probe/exc.cpp.
#
# Run: just verify-wasi27-cannot-link

TEST_NAME="test_wasi_sdk_27_cannot_link_exceptions"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_wasi33.sh"

require_nix

assert_file "the throwing probe is in the prepared contribution" "$M4_PROBE"
NOEXC="$M4_PATCH_DIR/probe/noexc.cpp"
assert_file "the non-throwing discriminator is beside it" "$NOEXC"
[ -f "$M4_PROBE" ] && [ -f "$NOEXC" ] || die "the probe sources are missing"

# A probe that does not actually throw and catch by type would make every
# assertion below vacuous.
SRC="$(cat "$M4_PROBE")"
assert_contains "the probe throws across a noinline boundary" "__attribute__((noinline))" "$SRC"
assert_contains "the probe throws" "throw AvmRevert" "$SRC"
assert_contains "the probe catches by type" "catch (const AvmRevert& e)" "$SRC"
# Comment lines are stripped first: this file's own header explains what it
# replaced, and matching the word there would make the assertion meaningless.
NSRC="$(grep -v '^[[:space:]]*//' "$NOEXC")"
assert_not_contains "the discriminator does NOT throw" "throw" "$NSRC"
assert_not_contains "the discriminator does NOT catch" "catch" "$NSRC"
assert_not_contains "the discriminator has no try block" "try" "$NSRC"

SDK27="$(m4_sdk 27)"
SDK33="$(m4_sdk 33)"
note "wasi-sdk 27: $SDK27"
note "wasi-sdk 33: $SDK33"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# The mechanism: what each sysroot does and does not ship.
# ---------------------------------------------------------------------------
abi_objects() { # <sdk> -> the cxa exception-handling object names it ships
  local sdk="$1" abi
  abi=$(ls "$sdk"/share/wasi-sysroot/lib/wasm32-wasip1/eh/libc++abi.a \
           "$sdk"/share/wasi-sysroot/lib/wasm32-wasip1/libc++abi.a 2>/dev/null | head -1)
  [ -n "$abi" ] || return 1
  "$sdk/bin/llvm-ar" t "$abi" 2>/dev/null
}

OBJ27="$(abi_objects "$SDK27")" || fail "wasi-sdk 27 ships no libc++abi.a for wasm32-wasip1"
OBJ33="$(abi_objects "$SDK33")" || fail "wasi-sdk 33 ships no libc++abi.a for wasm32-wasip1"

assert_contains "27's libc++abi is the NO-EXCEPTION build" "cxa_noexception.cpp.o" "$OBJ27"
assert_not_contains "27's libc++abi has no cxa_exception.cpp.o" "cxa_exception.cpp.o" "$OBJ27"
assert_not_contains "27's libc++abi has no cxa_personality.cpp.o" "cxa_personality.cpp.o" "$OBJ27"
assert_contains "33's eh/ libc++abi HAS cxa_exception.cpp.o" "cxa_exception.cpp.o" "$OBJ33"
assert_contains "33's eh/ libc++abi HAS cxa_personality.cpp.o" "cxa_personality.cpp.o" "$OBJ33"

assert_eq "27's sysroot ships no unwinder at all" \
  "0" "$(find "$SDK27/share/wasi-sysroot" -name 'libunwind*' 2>/dev/null | wc -l)"
assert_ge "33's sysroot ships an unwinder" 1 \
  "$(find "$SDK33/share/wasi-sysroot" -name 'libunwind*' 2>/dev/null | wc -l)"

assert_false "27 has no eh/ multilib variant" \
  test -d "$SDK27/share/wasi-sysroot/lib/wasm32-wasip1/eh"
assert_dir "33 ships the eh/ multilib variant" "$SDK33/share/wasi-sysroot/lib/wasm32-wasip1/eh"
assert_dir "33 ships the noeh/ multilib variant" "$SDK33/share/wasi-sysroot/lib/wasm32-wasip1/noeh"

# ---------------------------------------------------------------------------
# The failure, and that it is about exceptions and nothing else.
# ---------------------------------------------------------------------------
link() { # <sdk> <src> <out> <extra flags...> -> status; stderr captured to $WORK/<out>.log
  local sdk="$1" src="$2" out="$3"; shift 3
  "$sdk/bin/clang++" --target=wasm32-wasip1 -O2 "$@" "$src" -o "$WORK/$out" \
    >"$WORK/$out.log" 2>&1
}

link "$SDK27" "$M4_PROBE" exc27-fwasm.wasm -fwasm-exceptions
RC_27_FWASM=$?
link "$SDK27" "$M4_PROBE" exc27-plain.wasm
RC_27_PLAIN=$?

if [ "$RC_27_FWASM" -ne 0 ]; then
  pass "wasi-sdk 27 fails to link the throwing probe WITH -fwasm-exceptions  [exit $RC_27_FWASM]"
else
  fail "wasi-sdk 27 linked the throwing probe with -fwasm-exceptions — the premise is void"
fi
if [ "$RC_27_PLAIN" -ne 0 ]; then
  pass "wasi-sdk 27 fails to link the throwing probe WITHOUT -fwasm-exceptions  [exit $RC_27_PLAIN]"
else
  fail "wasi-sdk 27 linked the throwing probe without -fwasm-exceptions — the premise is void"
fi

# Fails for the RIGHT reason: the named pieces of the C++ exception runtime.
for sym in __cxa_allocate_exception __cxa_throw __cxa_begin_catch \
           _Unwind_CallPersonality __wasm_lpad_context; do
  assert_contains "the -fwasm-exceptions failure names $sym" \
    "undefined symbol: $sym" "$(cat "$WORK/exc27-fwasm.wasm.log")"
done
for sym in __cxa_allocate_exception __cxa_throw; do
  assert_contains "the plain failure names $sym too" \
    "undefined symbol: $sym" "$(cat "$WORK/exc27-plain.wasm.log")"
done

# ---------------------------------------------------------------------------
# The neighbouring condition that PASSES. Same toolchain, same command line.
# ---------------------------------------------------------------------------
link "$SDK27" "$NOEXC" noexc27.wasm -fwasm-exceptions
RC_27_NOEXC=$?
if [ "$RC_27_NOEXC" -eq 0 ]; then
  pass "wasi-sdk 27 links the SAME program without a throw — so it is exceptions, not the invocation"
else
  fail "wasi-sdk 27 could not link even the non-throwing program: $(head -3 "$WORK/noexc27.wasm.log")"
fi

if [ "$RC_27_NOEXC" -eq 0 ]; then
  NOEXC_OUT="$(m4_in_devshell 'wasmtime run "$1"' "$WORK/noexc27.wasm" 2>&1)"
  NOEXC_RC=$?
  assert_eq "the 27-built non-throwing module runs" "0" "$NOEXC_RC"
  assert_eq "and prints what the same control flow prints" "$M4_PROBE_EXPECTED" "$NOEXC_OUT"
fi

# ---------------------------------------------------------------------------
# The contrast: 33, same source, same probe.
# ---------------------------------------------------------------------------
link "$SDK33" "$M4_PROBE" exc33.wasm -fwasm-exceptions -mllvm -wasm-use-legacy-eh=false -lunwind
RC_33=$?
if [ "$RC_33" -eq 0 ]; then
  pass "wasi-sdk 33 links the same throwing probe"
else
  fail "wasi-sdk 33 failed to link the probe: $(head -3 "$WORK/exc33.wasm.log")"
fi

finish
