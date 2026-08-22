#!/usr/bin/env bash
# M5 — the compiler's own opinion, on the real file.
#
# `contract_crypto.cpp` is compiled with barretenberg's OWN command line for it,
# retargeted at `wasm32-wasip1` and `-fsyntax-only`. Unpatched it produces exactly
# one diagnostic, `-Wshift-count-overflow`, at the line the patch touches; patched
# it produces none. The same command line for the NATIVE target produces none
# either way, which is what makes this a 32-bit statement rather than a general
# code smell.
#
# Two things are asserted that the milestone did not ask for, because without them
# the entry would claim more than was measured:
#
#   * Under barretenberg's own `-Werror`, the unpatched file is a hard error and
#     the patched one compiles. That is the discriminator, and it is why the
#     `AVM_WASM` patch later in the series depends on this one.
#
#   * `PR.md` says `contract_crypto.cpp:61` is the ONLY place in `vm2` that shifts
#     before widening. A grep is not evidence of that; the compiler is. All 249
#     non-test `vm2` translation units in the build's own `compile_commands.json`
#     are retargeted the same way, and exactly one carries the diagnostic — and,
#     stated rather than left to be discovered, FOUR OTHER FILES fail the same
#     wasm32 `-Werror` build for unrelated 32-bit narrowing warnings. This patch
#     removes one of five blockers, not five.
#
# Every compile runs on the BASE tree's command line, whichever source it is given,
# so the include paths, macros and standard level are the same on both sides and the
# one line is the only variable.
#
# Cost: two full scans of 249 translation units, about 2.5 minutes each. There is no
# way to skip them: the scan is what backs the "only place in vm2" claim, and a
# claim without its measurement is what this campaign keeps having to correct.

TEST_NAME="test_shift_count_overflow_diagnostic"
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/lib_bytecode_shift.sh"

note "work directory: $M5_WORK"
m5_prepare_trees
for tree in base patched; do
  m5_native_configure "$M5_WORK/$tree"
  assert_eq "$tree: cmake --preset default exits 0" "0" "$?"
done

sdk="$(m5_sdk)"
assert_prefix "the 32-bit toolchain is wasi-sdk 33, realised from the fork's flake" \
  "33." "$(head -1 "$sdk/VERSION")"

base_tu="$M5_WORK/base/$M5_TU_REL"
patched_tu="$M5_WORK/patched/$M5_TU_REL"

# --------------------------------------------------------------------------
# 1. The single translation unit, four ways.
# --------------------------------------------------------------------------
syntax_check() { # <native|wasm> <source> <werror|no-werror> <log>
  local mode="$1" src="$2" werror="$3" log="$4" cmd extra=()
  [ "$mode" = wasm ] && extra=(--wasm "$sdk")
  [ "$werror" = no-werror ] && extra+=(--drop-werror)
  # nixpkgs' cc wrapper appends -Wl,-dynamic-linker=... to every native
  # invocation. With -fsyntax-only nothing is linked, so under -Werror that
  # becomes a fatal -Wunused-command-line-argument about the WRAPPER, not about
  # the code. Silencing it is the only edit the native arm needs, and it is
  # narrow enough to name.
  [ "$mode" = native ] && extra+=(--add -Wno-unused-command-line-argument)
  cmd="$(m5_tu_cmd "$M5_WORK/base" "${extra[@]}" --source "$src" --syntax-only)" || return 90
  { echo "### $mode $werror $src"; echo "$cmd"; } >"$log"
  bash -c "$cmd" >>"$log" 2>&1
}

DIAG='warning: shift count >= width of type [-Wshift-count-overflow]'

syntax_check wasm "$base_tu" no-werror "$M5_WORK/diag-wasm-base.log"
assert_eq "wasm32, unpatched, warnings not fatal: clang still succeeds" "0" "$?"
assert_contains "and it emits -Wshift-count-overflow" "$DIAG" \
  "$(cat "$M5_WORK/diag-wasm-base.log")"
assert_contains "at contract_crypto.cpp:$M5_TU_LINE" \
  "contract_crypto.cpp:$M5_TU_LINE:" "$(grep -F "$DIAG" "$M5_WORK/diag-wasm-base.log")"
assert_eq "and it is the ONLY diagnostic that file produces for wasm32" "1" \
  "$(grep -c 'warning generated' "$M5_WORK/diag-wasm-base.log")"
assert_eq "exactly one warning line" "1" \
  "$(grep -c ': warning: ' "$M5_WORK/diag-wasm-base.log")"
assert_contains "clang points at the shift count itself" \
  'bytecode_size << 32' "$(cat "$M5_WORK/diag-wasm-base.log")"

syntax_check wasm "$patched_tu" no-werror "$M5_WORK/diag-wasm-patched.log"
assert_eq "wasm32, patched: clang succeeds" "0" "$?"
assert_not_contains "and emits no -Wshift-count-overflow" "$DIAG" \
  "$(cat "$M5_WORK/diag-wasm-patched.log")"
assert_eq "in fact no warning at all" "0" \
  "$(grep -c ': warning: ' "$M5_WORK/diag-wasm-patched.log")"

# The discriminator: with barretenberg's own -Werror, which is on every one of its
# translation units, the unpatched file is a hard error and the patched one is not.
syntax_check wasm "$base_tu" werror "$M5_WORK/diag-wasm-base-werror.log"
werror_rc=$?
assert_false "wasm32 + -Werror, unpatched: clang FAILS" test "$werror_rc" -eq 0
assert_contains "and it fails on the shift count, not on something else" \
  'error: shift count >= width of type' "$(cat "$M5_WORK/diag-wasm-base-werror.log")"
assert_eq "with exactly one error and no second cause" "1" \
  "$(grep -c '^1 error generated' "$M5_WORK/diag-wasm-base-werror.log")"
# barretenberg compiles with -Wfatal-errors too, so it is the FIRST diagnostic
# that stops the build. Asserted, because "fatal error" and "error" are different
# strings and a check that grepped for the wrong one would report zero errors on
# a build that plainly failed.
assert_contains "and -Wfatal-errors makes it stop there" \
  'fatal error: shift count >= width of type' \
  "$(cat "$M5_WORK/diag-wasm-base-werror.log")"
syntax_check wasm "$patched_tu" werror "$M5_WORK/diag-wasm-patched-werror.log"
assert_eq "wasm32 + -Werror, patched: clang succeeds" "0" "$?"

# The control that makes it a 32-bit statement: natively there is nothing to see,
# on either side, under the same -Werror.
syntax_check native "$base_tu" werror "$M5_WORK/diag-native-base.log"
assert_eq "x86_64 + -Werror, unpatched: clang succeeds" "0" "$?"
assert_not_contains "no diagnostic natively — size_t is 64 bits here" "$DIAG" \
  "$(cat "$M5_WORK/diag-native-base.log")"
syntax_check native "$patched_tu" werror "$M5_WORK/diag-native-patched.log"
assert_eq "x86_64 + -Werror, patched: clang succeeds" "0" "$?"
assert_eq "and neither native compile emits a single warning" "0" \
  "$(cat "$M5_WORK/diag-native-base.log" "$M5_WORK/diag-native-patched.log" \
     | grep -c ': warning: ')"

# --------------------------------------------------------------------------
# 2. The "only place in vm2" claim, measured rather than grepped.
# --------------------------------------------------------------------------
[ -x "$M5_SCAN" ] || die "missing $M5_SCAN"

scan() { # <tree> -> report on stdout
  python3 "$M5_SCAN" "$M5_WORK/$1" "$sdk" >"$M5_WORK/scan-$1.txt" 2>"$M5_WORK/scan-$1.err"
}
scan_val() { grep -E "^$2 " "$M5_WORK/scan-$1.txt" | awk '{print $2}'; }

scan base
assert_eq "the wasm32 scan of the unpatched tree completes" "0" "$?"
scan patched
assert_eq "the wasm32 scan of the patched tree completes" "0" "$?"

assert_eq "249 non-test vm2 translation units scanned, unpatched" "249" "$(scan_val base scanned)"
assert_eq "the same 249 after the patch" "249" "$(scan_val patched scanned)"
assert_eq "exactly ONE of them carries -Wshift-count-overflow" "1" \
  "$(scan_val base shift_overflow_files)"
assert_eq "and it is contract_crypto.cpp, at line $M5_TU_LINE, column 77" \
  "$M5_TU_REL:$M5_TU_LINE:77" \
  "barretenberg/cpp/src/$(grep -E '^shift_overflow ' "$M5_WORK/scan-base.txt" | awk '{print $2}')"
assert_eq "after the patch, none does" "0" "$(scan_val patched shift_overflow_files)"

# Stated rather than left for a reviewer to find: the patch does not make vm2
# compile for wasm32 under -Werror. It removes one of five reasons it does not.
assert_eq "5 of the 249 fail the wasm32 -Werror build before the patch" "5" \
  "$(scan_val base failed)"
assert_eq "4 after it — the four are unrelated 32-bit narrowing warnings" "4" \
  "$(scan_val patched failed)"
assert_eq "and those four are the same four before and after" \
  "$(grep -E '^failed_file ' "$M5_WORK/scan-patched.txt" | sort)" \
  "$(grep -E '^failed_file ' "$M5_WORK/scan-base.txt" | grep -v contract_crypto | sort)"
assert_eq "none of the four is a shift-count problem" "0" \
  "$(grep -E '^other_warning_file ' "$M5_WORK/scan-patched.txt" | grep -c 'shift-count')"
assert_eq "they are -Wshorten-64-to-32 and -Wsign-conversion" \
  "shorten-64-to-32 shorten-64-to-32 shorten-64-to-32 sign-conversion" \
  "$(grep -E '^other_warning_file ' "$M5_WORK/scan-patched.txt" | awk '{print $3}' | sort | tr '\n' ' ' | sed 's/ $//')"

# --------------------------------------------------------------------------
# 3. Negative controls for the scan itself.
# --------------------------------------------------------------------------
# A scan that reported "1 file" no matter what would pass everything above. The
# decoy tree carries the widening with the wrong shift count: the diagnostic must
# be GONE there too, because the expression is well formed — wrong, but well
# formed. That separates "the compiler stopped complaining" from "the value is
# right", which is the whole reason check 2 exists alongside this one.
m5_native_configure "$M5_WORK/decoy"
assert_eq "decoy: cmake --preset default exits 0" "0" "$?"
syntax_check wasm "$M5_WORK/decoy/$M5_TU_REL" werror "$M5_WORK/diag-wasm-decoy.log"
assert_eq "the decoy compiles cleanly for wasm32 under -Werror, though it is WRONG" "0" "$?"
note "a clean compile is necessary and not sufficient; check 2 is what rejects the decoy"

# And the converse: the scan can still see a diagnostic when there is one to see.
assert_eq "restricting the scan to the one file finds it" "1" \
  "$(python3 "$M5_SCAN" "$M5_WORK/base" "$sdk" --only contract_crypto \
     2>/dev/null | awk '$1=="shift_overflow_files" {print $2}')"
assert_eq "restricting it to a file that has no shift finds none" "0" \
  "$(python3 "$M5_SCAN" "$M5_WORK/base" "$sdk" --only simulation/gadgets/poseidon2.cpp \
     2>/dev/null | awk '$1=="shift_overflow_files" {print $2}')"

# The codebase's own neighbourhood convention, re-derived from the tree rather
# than quoted from PR.md: the two sibling gadgets that write the same idiom
# correctly, and which the scan therefore does not flag.
assert_true "poseidon2.cpp widens before shifting by 64" \
  grep -qF 'const uint256_t iv = static_cast<uint256_t>(input_size) << 64;' \
  "$M5_WORK/base/barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/poseidon2.cpp"
assert_true "memory_trace.cpp widens before shifting by 32" \
  grep -qF 'const uint64_t global_addr = (static_cast<uint64_t>(event.space_id) << 32) + event.addr;' \
  "$M5_WORK/base/barretenberg/cpp/src/barretenberg/vm2/tracegen/memory_trace.cpp"

m5_measure M5_SCANNED_TUS "$(scan_val base scanned)"
m5_measure M5_SHIFT_OVERFLOW_FILES_BEFORE "$(scan_val base shift_overflow_files)"
m5_measure M5_SHIFT_OVERFLOW_FILES_AFTER "$(scan_val patched shift_overflow_files)"
m5_measure M5_WERROR_FAILURES_BEFORE "$(scan_val base failed)"
m5_measure M5_WERROR_FAILURES_AFTER "$(scan_val patched failed)"
m5_measure M5_DIAG_LOCATION "$M5_TU_REL:$M5_TU_LINE:77"

finish
