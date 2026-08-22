#!/usr/bin/env bash
# M5 — the 32-bit half: the patched expression is right where `size_t` is 32 bits
# and the unpatched one is not.
#
# The 32-bit target is REAL EXECUTION, not an argument. `repro/first_field.cpp` —
# the file the contribution ships — is compiled twice from the same source with
# barretenberg's own command line for `contract_crypto.cpp`: once for this host
# (x86_64, `size_t` 64 bits) and once for `wasm32-wasip1` (`size_t` 32 bits, from
# the nix-pinned wasi-sdk 33), and both are RUN — the second on wasmtime. It uses
# barretenberg's own `uint256_t` and its own `DOM_SEP__PUBLIC_BYTECODE`, not
# stand-ins, and the two expressions in it are the patch's own `-` and `+` lines,
# asserted here character for character.
#
# `-m32` was tried as a second 32-bit target and does not work, for a reason that
# has nothing to do with this patch: barretenberg's `numeric/uint128/uint128_impl.hpp`
# fallback for platforms without a native 128-bit integer calls `BB_ASSERT` — which
# constructs an `std::ostringstream` — inside a `constexpr` function, which is
# ill-formed before C++23. That is a separate 32-bit portability blocker; it is
# recorded in PR.md as a known limitation rather than fixed here.
#
# Three forms are measured, not two, because "undefined behaviour" is not one
# outcome. The upstream expression verbatim (literal 32), the same expression with
# the shift count read from a `volatile` so a real `i32.shl` has to be emitted, and
# the patched expression. All three matter:
#
#   * the volatile form shows the MACHINE's answer — wasm masks the shift count to
#     its low five bits, so `<< 32` becomes `<< 0` — which is the mechanism PR.md
#     describes;
#   * the literal form shows what the OPTIMISER does with the same UB, and at -O2
#     the whole first field collapses to zero: the domain separator disappears too.
#
# Also asserted, so the probe cannot drift away from the real function: the
# probe's own 64-bit values equal the ones upstream's `compute_public_bytecode_first_field`
# produces, read from test_bytecode_commitment_identical_on_64bit's transcript.
#
# Every compile and every run has its exit status asserted separately from anything
# parsed out of its output.

TEST_NAME="test_bytecode_commitment_correct_on_32bit"
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/lib_bytecode_shift.sh"

note "work directory: $M5_WORK"
m5_prepare_trees
m5_native_configure "$M5_WORK/base"
assert_eq "base: cmake --preset default exits 0" "0" "$?"

sdk="$(m5_sdk)"
assert_nix_store "the 32-bit toolchain comes from the fork's flake, not from PATH" "$sdk"
assert_prefix "and it is wasi-sdk 33" "33." "$(head -1 "$sdk/VERSION")"

# --------------------------------------------------------------------------
# 1. The probe computes the patch's own two expressions, and nothing else.
# --------------------------------------------------------------------------
assert_file "the contribution's first-field probe" "$M5_PROBE_FIRST_FIELD"
minus_expr="$(m5_patch_expr minus)"
plus_expr="$(m5_patch_expr plus)"

probe_body() { # <function-name> -> the `return ...;` line's expression
  sed -n "/static uint256_t $1(size_t bytecode_size)/,/^}/p" "$M5_PROBE_FIRST_FIELD" \
    | grep -F 'return ' | head -1 | sed 's/^ *return //; s/;$//'
}
assert_eq "the probe's upstream_form IS the patch's removed expression" \
  "$minus_expr" "$(probe_body upstream_form)"
assert_eq "the probe's patched_form IS the patch's added expression" \
  "$plus_expr" "$(probe_body patched_form)"
assert_eq "the probe's volatile variant differs from the removed expression only in the shift count" \
  "${minus_expr/<< 32/<< volatile_shift}" "$(probe_body upstream_form_volatile)"
assert_true "the probe takes DOM_SEP__PUBLIC_BYTECODE from upstream's header, not from a copy" \
  grep -qF '#include "barretenberg/aztec/aztec_constants.hpp"' "$M5_PROBE_FIRST_FIELD"
assert_false "the probe does not define the domain separator itself" \
  grep -qE '^#define DOM_SEP__PUBLIC_BYTECODE' "$M5_PROBE_FIRST_FIELD"

# --------------------------------------------------------------------------
# 2. Build and run it for both targets.
# --------------------------------------------------------------------------
: >"$M5_WORK/first-field-build.log"
build_probe() { # <native|wasm> <source> <output>
  local mode="$1" src="$2" out="$3" cmd extra=()
  # -Werror is dropped for exactly one reason and it is the point of the whole
  # milestone: the upstream expression is what clang REFUSES to compile for
  # wasm32. test_shift_count_overflow_diagnostic asserts that refusal directly.
  if [ "$mode" = wasm ]; then
    extra=(--wasm "$sdk")
  fi
  cmd="$(m5_tu_cmd "$M5_WORK/base" "${extra[@]}" --source "$src" --output "$out" \
          --drop-flag -c --drop-werror)" || return 90
  { echo "### $mode $src"; echo "$cmd"; } >>"$M5_WORK/first-field-build.log"
  bash -c "$cmd" >>"$M5_WORK/first-field-build.log" 2>&1
}

build_probe native "$M5_PROBE_FIRST_FIELD" "$M5_WORK/first_field.native"
assert_eq "the probe compiles for the host" "0" "$?"
build_probe wasm "$M5_PROBE_FIRST_FIELD" "$M5_WORK/first_field.wasm"
assert_eq "the probe compiles for wasm32-wasip1" "0" "$?"

"$M5_WORK/first_field.native" >"$M5_WORK/first_field.native.txt" 2>&1
assert_eq "the host probe exits 0" "0" "$?"
m5_in_devshell 'wasmtime run "$1"' "$M5_WORK/first_field.wasm" \
  >"$M5_WORK/first_field.wasm.txt" 2>&1
assert_eq "the wasm32 probe runs to completion on wasmtime and exits 0" "0" "$?"

assert_eq "the host really has a 64-bit size_t" "8" \
  "$(awk '$1=="sizeof_size_t" {print $2}' "$M5_WORK/first_field.native.txt")"
assert_eq "wasm32 really has a 32-bit size_t" "4" \
  "$(awk '$1=="sizeof_size_t" {print $2}' "$M5_WORK/first_field.wasm.txt")"
assert_eq "both read the same domain separator out of upstream's header" \
  "260313585" "$(awk '$1=="dom_sep" {print $2}' "$M5_WORK/first_field.native.txt")"
assert_eq "…on wasm32 too" "260313585" \
  "$(awk '$1=="dom_sep" {print $2}' "$M5_WORK/first_field.wasm.txt")"

# The 64-bit run carries one extra size, 2^32, which does not fit a 32-bit size_t.
native_sizes="$(awk '$1=="ff" && $2=="patched" {print $3}' "$M5_WORK/first_field.native.txt" | wc -l)"
wasm_sizes="$(awk '$1=="ff" && $2=="patched" {print $3}' "$M5_WORK/first_field.wasm.txt" | wc -l)"
assert_eq "the host runs 14 sizes (13 shared plus 2^32)" "14" "$native_sizes"
assert_eq "wasm32 runs the 13 sizes a 32-bit size_t can hold" "13" "$wasm_sizes"

form() { # <transcript> <form> -> "<size> <value>" lines, 2^32 excluded
  awk -v f="$2" '$1=="ff" && $2==f && $3!=4294967296 {print $3, $4}' "$1"
}

# --------------------------------------------------------------------------
# 3. THE assertion: patched agrees across the two targets, upstream does not.
# --------------------------------------------------------------------------
if diff -u <(form "$M5_WORK/first_field.native.txt" patched) \
           <(form "$M5_WORK/first_field.wasm.txt"   patched) >"$M5_WORK/patched-forms.diff" 2>&1
then
  pass "patched form: wasm32 == x86_64 on all $wasm_sizes shared sizes"
else
  fail "patched form DIFFERS between the two targets — see $M5_WORK/patched-forms.diff"
fi

agree=0
while read -r size value; do
  wasm_value="$(awk -v s="$size" '$1=="ff" && $2=="upstream" && $3==s {print $4}' \
                 "$M5_WORK/first_field.wasm.txt")"
  [ "$value" = "$wasm_value" ] && agree=$((agree + 1))
done < <(form "$M5_WORK/first_field.native.txt" upstream)
assert_eq "upstream form: wasm32 agrees with x86_64 on NONE of the 13 sizes" "0" "$agree"

# What it actually produces, measured — not "undefined, therefore anything". Both
# outcomes below are pinned to the toolchain and optimisation level that produced
# them (wasi-sdk 33, and the -O3 barretenberg's own default preset uses).
zeros="$(awk '$1=="ff" && $2=="upstream" && $4 ~ /^0+$/' "$M5_WORK/first_field.wasm.txt" | wc -l)"
assert_eq "under the optimiser, the whole first field collapses to zero for every size" \
  "13" "$zeros"
note "the domain separator disappears with it: LLVM folds shl i32 %x, 32 to poison"

# The volatile variant shows the machine's own answer: i32.shl masks to five bits.
masked=0
while read -r size value; do
  expected="$(printf '%048d%016x' 0 "$(( 260313585 + size ))")"
  [ "$value" = "$expected" ] && masked=$((masked + 1))
done < <(awk '$1=="ff" && $2=="upstream_volatile" {print $3, $4}' "$M5_WORK/first_field.wasm.txt")
assert_eq "with a real i32.shl, all 13 sizes evaluate as DOM_SEP + (size << 0)" "13" "$masked"

# --------------------------------------------------------------------------
# 4. 64-bit is unaffected, and the divergence threshold is exactly 2^32.
# --------------------------------------------------------------------------
host_disagree=0
while read -r size value; do
  patched_value="$(awk -v s="$size" '$1=="ff" && $2=="patched" && $3==s {print $4}' \
                    "$M5_WORK/first_field.native.txt")"
  [ "$value" = "$patched_value" ] || host_disagree=$((host_disagree + 1))
done < <(form "$M5_WORK/first_field.native.txt" upstream)
assert_eq "on the host the two forms agree on every one of the 13 reachable sizes" \
  "0" "$host_disagree"

ff32_upstream="$(awk '$1=="ff" && $2=="upstream"  && $3==4294967296 {print $4}' "$M5_WORK/first_field.native.txt")"
ff32_patched="$( awk '$1=="ff" && $2=="patched"   && $3==4294967296 {print $4}' "$M5_WORK/first_field.native.txt")"
assert_eq "at 2^32 the upstream form truncates in size_t and leaves the bare separator" \
  "000000000000000000000000000000000000000000000000000000000f8411f1" "$ff32_upstream"
assert_eq "at 2^32 the widened form does not truncate" \
  "000000000000000000000000000000000000000000000001000000000f8411f1" "$ff32_patched"
note "so the change can only widen the set of inputs handled correctly, and 2^32 is"
note "four orders of magnitude above upstream's own bound of 0xffffff bytes"

# --------------------------------------------------------------------------
# 5. The probe is not drifting away from the real function.
# --------------------------------------------------------------------------
driver="$M5_WORK/driver-base.txt"
if [ -f "$driver" ]; then
  tied=0; checked=0
  while read -r size value; do
    probe_value="$(awk -v s="$size" '$1=="ff" && $2=="patched" && $3==s {print $4}' \
                    "$M5_WORK/first_field.native.txt")"
    [ -n "$probe_value" ] || continue
    checked=$((checked + 1))
    [ "$value" = "$probe_value" ] && tied=$((tied + 1))
  done < <(awk '$1=="first_field" {print $2, $3}' "$driver")
  assert_ge "the probe and upstream's real function share sizes to compare" 9 "$checked"
  assert_eq "and they agree on every one of them" "$checked" "$tied"
else
  fail "no $driver — run test_bytecode_commitment_identical_on_64bit first; this check will not claim the probe matches upstream's function without comparing them"
fi

# --------------------------------------------------------------------------
# 6. The negative control: a wrong widening is caught on wasm32 too.
# --------------------------------------------------------------------------
# Everything above would also pass for a probe whose "patched" form is wrong in a
# way that happens to be target-independent. The decoy makes that explicit: the
# same probe with the widened shift count changed to 31 must disagree with the
# 64-bit reference.
decoy_src="$M5_WORK/first_field_decoy.cpp"
M5_OLD="$plus_expr" M5_NEW="${plus_expr/<< 32/<< 31}" \
  python3 -c 'import os,sys
old, new = os.environ["M5_OLD"], os.environ["M5_NEW"]
text = open(sys.argv[1]).read()
assert text.count(old) == 1, "the probe must carry the added expression exactly once"
open(sys.argv[2], "w").write(text.replace(old, new))' "$M5_PROBE_FIRST_FIELD" "$decoy_src"
assert_eq "the decoy probe is written from the real one by changing 32 to 31" "0" "$?"
assert_true "the decoy probe carries the wrong shift count" \
  grep -qF "${plus_expr/<< 32/<< 31}" "$decoy_src"
build_probe wasm "$decoy_src" "$M5_WORK/first_field_decoy.wasm"
assert_eq "the decoy probe compiles for wasm32" "0" "$?"
m5_in_devshell 'wasmtime run "$1"' "$M5_WORK/first_field_decoy.wasm" \
  >"$M5_WORK/first_field_decoy.wasm.txt" 2>&1
assert_eq "the decoy probe runs and exits 0 — it is wrong, not broken" "0" "$?"
if diff -q <(form "$M5_WORK/first_field.native.txt" patched) \
           <(form "$M5_WORK/first_field_decoy.wasm.txt" patched) >/dev/null 2>&1; then
  fail "the decoy (widened, shift 31) matches the 64-bit reference — this comparison proves nothing"
else
  pass "the decoy (widened, shift 31) does NOT match the 64-bit reference"
fi
decoy_agree="$(comm -12 \
  <(form "$M5_WORK/first_field.native.txt" patched | sort) \
  <(form "$M5_WORK/first_field_decoy.wasm.txt" patched | sort) | grep -c .)"
assert_eq "and it agrees on only the one size a shift count cannot change, 0" "1" "$decoy_agree"

m5_measure M5_WASI_SDK "$(head -1 "$sdk/VERSION")"
m5_measure M5_WASM_SIZEOF_SIZE_T 4
m5_measure M5_SHARED_SIZES "$wasm_sizes"
m5_measure M5_UPSTREAM_AGREEING_SIZES "$agree"
m5_measure M5_WASM_UPSTREAM_ZEROS "$zeros"
m5_measure M5_WASM_VOLATILE_MASKED "$masked"
m5_measure M5_FF_2POW32_UPSTREAM "$ff32_upstream"
m5_measure M5_FF_2POW32_PATCHED "$ff32_patched"

finish
