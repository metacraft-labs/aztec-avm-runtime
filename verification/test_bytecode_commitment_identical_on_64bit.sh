#!/usr/bin/env bash
# M5 — the native-neutrality evidence for the widen-before-shift patch.
#
# What this establishes, and how:
#
#   1. UPSTREAM'S OWN FUNCTIONS, not a re-implementation of one line. `vm2_sim` is
#      built from two worktrees of 233d8e0993 differing only by the patch, and
#      `repro/commitment_driver.cpp` — the file the contribution ships — is linked
#      against each tree's own libvm2_sim.a and run. It calls
#      compute_public_bytecode_first_field AND compute_public_bytecode_commitment,
#      the poseidon2 hash that is the consensus-critical value.
#
#   2. A DECOY, because "the results did not change" is satisfied by any patch that
#      leaves them alone — including one that fixes the expression to something
#      else wrong. A third tree carries the patch's own `+` line with the shift
#      count changed to 31, and the same driver must report a DIFFERENT commitment.
#      Without this, the comparison is a tautology. (M4's review found precisely
#      this hole in that milestone's checks.)
#
#   3. WHAT THE PATCH SETS, from the patch's own removed and added lines: the
#      expression the patched tree carries must be the `+` line character for
#      character, its shift count must be 32, and the widening must be INSIDE the
#      shift's left operand.
#
#   4. THE CODEGEN CLAIM, corrected by measurement. The milestone's Goal says the
#      change "produces identical codegen on 64-bit". It does not. The same
#      translation unit compiled from both sources with identical flags produces
#      objects that are not byte-identical: the patched function emits one more
#      instruction — 184 -> 185 — and it is the `shr` that materialises the high
#      word the truncating form cannot produce. The translation unit's whole .text
#      grows by 16 bytes out of 67,312, and no VALUE moves at all. This check
#      asserts the corrected version, in both directions.
#
# Every ninja and every binary has its EXIT STATUS asserted separately from
# anything parsed out of its output — a count read off a stale binary is the exact
# failure this campaign's M2 review found.
#
# Cost: three configures (~20 s each) and three `ninja vm2_sim` (~40 s each) from
# an empty $M5_WORK; afterwards ninja has nothing to do.

TEST_NAME="test_bytecode_commitment_identical_on_64bit"
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/lib_bytecode_shift.sh"

note "work directory: $M5_WORK"
m5_prepare_trees

# --------------------------------------------------------------------------
# 1. The patch is this patch, and it sets what it is supposed to set.
# --------------------------------------------------------------------------
minus_expr="$(m5_patch_expr minus)"
plus_expr="$(m5_patch_expr plus)"

assert_eq "the patch REMOVES upstream's shift-then-widen expression" \
  'uint256_t(DOM_SEP__PUBLIC_BYTECODE) + uint256_t(bytecode_size << 32)' "$minus_expr"
assert_eq "the patch ADDS the widen-then-shift expression" \
  'uint256_t(DOM_SEP__PUBLIC_BYTECODE) + (uint256_t(bytecode_size) << 32)' "$plus_expr"
assert_contains "the added expression widens BEFORE shifting" \
  '(uint256_t(bytecode_size) << 32)' "$plus_expr"
assert_not_contains "the added expression does not shift inside size_t" \
  'bytecode_size << 32' "$plus_expr"
# The shift count is the thing a wrong fix would get wrong, so it is asserted as a
# value rather than left inside the string comparison above.
plus_shift="$(printf '%s' "$plus_expr" | sed -n 's/.*<< \([0-9]*\).*/\1/p')"
assert_eq "the added expression shifts by exactly 32" "32" "$plus_shift"

base_tu="$M5_WORK/base/$M5_TU_REL"
patched_tu="$M5_WORK/patched/$M5_TU_REL"
assert_true "the unpatched tree carries the removed expression" \
  grep -qF "$minus_expr" "$base_tu"
assert_false "the unpatched tree does not already carry the added one" \
  grep -qF "$plus_expr" "$base_tu"
assert_true "the patched tree carries the added expression" \
  grep -qF "$plus_expr" "$patched_tu"
assert_false "the patched tree no longer carries the removed one" \
  grep -qF "$minus_expr" "$patched_tu"

# The evidence that makes the patch easy to accept: the width of the OTHER operand
# was reasoned about on the line above, and is untouched by the patch.
static_assert_line='static_assert(DOM_SEP__PUBLIC_BYTECODE <= UINT32_MAX, "Public bytecode domain separator must fit in 32 bits");'
assert_true "the function already carries the domain separator's static_assert (unpatched)" \
  grep -qF "$static_assert_line" "$base_tu"
assert_true "the patch leaves that static_assert in place" \
  grep -qF "$static_assert_line" "$patched_tu"

assert_eq "the patch touches exactly one file" "1" \
  "$(git -C "$M5_WORK/patched" show --name-only --format= HEAD | grep -c .)"
assert_eq "and it is contract_crypto.cpp" "$M5_TU_REL" \
  "$(git -C "$M5_WORK/patched" show --name-only --format= HEAD | head -1)"
assert_eq "the applied patch reproduces the fork branch's tree" \
  "$(git -C "$FORK_ROOT" rev-parse "$M5_PATCH_BRANCH^{tree}" 2>/dev/null)" \
  "$(git -C "$M5_WORK/patched" rev-parse 'HEAD^{tree}')"

# --------------------------------------------------------------------------
# 2. Configure and build all three trees.
# --------------------------------------------------------------------------
for tree in base patched decoy; do
  m5_native_configure "$M5_WORK/$tree"
  assert_eq "$tree: cmake --preset default exits 0" "0" "$?"
  assert_file "$tree: compile_commands.json" "$M5_WORK/$tree/barretenberg/cpp/build/compile_commands.json"
done

# The translation unit really is compiled by a native default build — otherwise
# "no native build is affected" would be true for an uninteresting reason.
tu_command="$(m5_tu_command "$M5_WORK/base")"
assert_eq "contract_crypto.cpp has exactly one native compile command" "0" "$?"
assert_contains "it is compiled into vm2_sim_objects" "vm2_sim_objects" "$tu_command"

assert_eq "the patch moves no compile flag for that TU" \
  "$(m5_tu_command "$M5_WORK/base"    | sed "s|$M5_WORK/base|TREE|g")" \
  "$(m5_tu_command "$M5_WORK/patched" | sed "s|$M5_WORK/patched|TREE|g")"

for tree in base patched decoy; do
  m5_native_build "$M5_WORK/$tree" vm2_sim
  assert_eq "$tree: ninja vm2_sim exits 0" "0" "$?"
  assert_file "$tree: libvm2_sim.a" "$M5_WORK/$tree/barretenberg/cpp/build/lib/libvm2_sim.a"
done

# --------------------------------------------------------------------------
# 3. Upstream's own functions, run from each tree.
# --------------------------------------------------------------------------
assert_file "the contribution's commitment driver" "$M5_PROBE_DRIVER"

> "$M5_WORK/driver-build.log"
build_and_run_driver() { # <tree-name>  -> binary at $M5_WORK/driver-<tree>
  local tree="$1" b libs cmd
  b="$M5_WORK/$tree/barretenberg/cpp/build"
  libs=""
  local lib
  for lib in vm2_sim crypto_poseidon2 ecc numeric common env \
             crypto_merkle_tree world_state_reference lmdblib; do
    libs="$libs --add $b/lib/lib$lib.a"
  done
  # barretenberg's own command line for contract_crypto.cpp, with the source
  # swapped for the driver, `-c` dropped so it links, and the tree's archives
  # appended. -Werror stays on: the driver has to be clean under the same
  # warnings the real translation unit is held to.
  cmd="$(m5_tu_cmd "$M5_WORK/$tree" --source "$M5_PROBE_DRIVER" \
          --output "$M5_WORK/driver-$tree" --drop-flag -c $libs --add -pthread)" || return 90
  { echo "### $tree"; echo "$cmd"; } >>"$M5_WORK/driver-build.log"
  bash -c "$cmd" >>"$M5_WORK/driver-build.log" 2>&1
}

for tree in base patched decoy; do
  build_and_run_driver "$tree"
  assert_eq "$tree: the commitment driver links against that tree's libvm2_sim.a" "0" "$?"
  "$M5_WORK/driver-$tree" >"$M5_WORK/driver-$tree.txt" 2>&1
  assert_eq "$tree: the commitment driver exits 0" "0" "$?"
done

base_lines="$(grep -c . "$M5_WORK/driver-base.txt")"
assert_eq "the driver emits 18 facts (9 sizes x first_field + commitment)" "18" "$base_lines"
assert_eq "9 commitments computed" "9" "$(grep -c '^commitment' "$M5_WORK/driver-base.txt")"

# THE assertion of this check.
if diff -u "$M5_WORK/driver-base.txt" "$M5_WORK/driver-patched.txt" >"$M5_WORK/driver.diff" 2>&1; then
  pass "unpatched and patched produce IDENTICAL first fields and commitments (18/18 lines)"
else
  fail "unpatched and patched differ — see $M5_WORK/driver.diff"
fi

# Pinned values, so a silent change on both sides at once is still a failure. The
# first is the one the source's own comment predicts:
#   "The maximum first field is currently: Fr<0x...16b480f8411f1> From: max fields
#    in bytes = 3000 * 31 = 16b48, Dom sep = f8411f1"
ff_93000="$(awk '$1=="first_field" && $2==93000 {print $3}' "$M5_WORK/driver-base.txt")"
assert_eq "first_field(93000) is the value the source's own comment states" \
  "00000000000000000000000000000000000000000000000000016b480f8411f1" "$ff_93000"
assert_true "and that value is quoted in the source's comment as Fr<0x...16b480f8411f1>" \
  grep -qF "Fr<0x${ff_93000}>" "$base_tu"
assert_eq "first_field(0) is the bare domain separator" \
  "000000000000000000000000000000000000000000000000000000000f8411f1" \
  "$(awk '$1=="first_field" && $2==0 {print $3}' "$M5_WORK/driver-base.txt")"

# 93000 is re-derived from the tree, not quoted.
max_fields="$(grep -E '^#define MAX_PACKED_PUBLIC_BYTECODE_SIZE_IN_FIELDS ' \
  "$M5_WORK/base/barretenberg/cpp/src/barretenberg/aztec/aztec_constants.hpp" | awk '{print $3}')"
assert_eq "MAX_PACKED_PUBLIC_BYTECODE_SIZE_IN_FIELDS, read from the tree" "3000" "$max_fields"
assert_eq "the largest bytecode a contract can carry, in bytes" "93000" "$(( max_fields * 31 ))"
dom_sep="$(grep -E '^#define DOM_SEP__PUBLIC_BYTECODE ' \
  "$M5_WORK/base/barretenberg/cpp/src/barretenberg/aztec/aztec_constants.hpp" | awk '{print $3}')"
assert_eq "DOM_SEP__PUBLIC_BYTECODE, read from the tree" "260313585UL" "$dom_sep"
# Upstream's own bound on the byte length, four orders of magnitude below 2^32.
assert_true "upstream itself bounds the byte length to 24 bits" \
  grep -qF 'static_assert(MAX_PACKED_PUBLIC_BYTECODE_SIZE_IN_FIELDS * 31 <= 0xffffff);' \
  "$M5_WORK/base/barretenberg/cpp/src/barretenberg/vm2/tracegen/bytecode_trace.cpp"

# --------------------------------------------------------------------------
# 4. The decoy: the comparison above is not a tautology.
# --------------------------------------------------------------------------
assert_true "the decoy tree carries the widening with the WRONG shift count" \
  grep -qF "${plus_expr/<< 32/<< 31}" "$M5_WORK/decoy/$M5_TU_REL"
if diff -q "$M5_WORK/driver-base.txt" "$M5_WORK/driver-decoy.txt" >/dev/null 2>&1; then
  fail "the decoy produces the SAME transcript as upstream — this comparison proves nothing"
else
  pass "the decoy (widened, shift 31) produces a DIFFERENT transcript"
fi
decoy_diff="$(diff "$M5_WORK/driver-base.txt" "$M5_WORK/driver-decoy.txt" | grep -c '^<')"
# size 0 is the one row a wrong shift count cannot change: 0 << n == 0.
assert_eq "the decoy diverges on 16 of the 18 rows (both rows for size 0 are 0 << n)" \
  "16" "$decoy_diff"
assert_eq "the decoy's commitment for size 3000 differs from upstream's" "differ" \
  "$( [ "$(awk '$1=="commitment" && $2==3000 {print $3}' "$M5_WORK/driver-base.txt")" \
     = "$(awk '$1=="commitment" && $2==3000 {print $3}' "$M5_WORK/driver-decoy.txt")" ] \
     && echo same || echo differ )"

# --------------------------------------------------------------------------
# 5. Codegen: identical values, NOT identical instructions.
# --------------------------------------------------------------------------
cg="$M5_WORK/codegen"
mkdir -p "$cg"
[ -x "$VERIFY_DIR/wasm_host/_codegen_compare.py" ] || die "missing _codegen_compare.py"

# Both sources are copied to the SAME path under $cg before compiling, so the two
# objects cannot differ merely because __FILE__ or the debug path differs; the only
# variable is the one line.
compile_tu() { # <source> <output.o>
  local cmd
  cp "$1" "$cg/tu.cpp" || return 90
  cmd="$(m5_tu_cmd "$M5_WORK/base" --source "$cg/tu.cpp" --output "$2")" || return 90
  { echo "### $1 -> $2"; echo "$cmd"; } >>"$cg/compile.log"
  bash -c "$cmd" >>"$cg/compile.log" 2>&1
}

: >"$cg/compile.log"
compile_tu "$base_tu" "$cg/before.o"
assert_eq "the unpatched TU compiles natively with the tree's own command line" "0" "$?"
compile_tu "$patched_tu" "$cg/after.o"
assert_eq "the patched TU compiles natively with the SAME command line" "0" "$?"

m5_in_devshell '"$1" "$2" "$3" "$4"' \
  "$VERIFY_DIR/wasm_host/_codegen_compare.py" compute_public_bytecode_first_field \
  "$cg/before.o" "$cg/after.o" >"$cg/report.txt" 2>&1
assert_eq "the codegen comparison runs" "0" "$?"

assert_eq "the two objects are NOT byte-identical (the Goal's 'identical codegen' is wrong)" \
  "no" "$(grep -E '^identical_objects ' "$cg/report.txt" | awk '{print $2}')"
before_text="$(awk '$1=="text_bytes" && $2=="before" {print $3}' "$cg/report.txt")"
after_text="$(awk '$1=="text_bytes" && $2=="after" {print $3}' "$cg/report.txt")"
assert_eq "the whole translation unit's .text grows by 16 bytes, and by 16 only" \
  "16" "$(( after_text - before_text ))"
assert_eq "which is 0.02% of it" "67312" "$before_text"
before_insn="$(awk '$1=="insn" && $2=="before" {print $3}' "$cg/report.txt")"
after_insn="$(awk '$1=="insn" && $2=="after" {print $3}' "$cg/report.txt")"
assert_ge "the function has a body to compare" 100 "$before_insn"
assert_eq "the patched function emits exactly one more instruction" \
  "$(( before_insn + 1 ))" "$after_insn"
mnemonic_count() { # <before|after> <mnemonic>
  local n
  n="$(awk -v w="$1" -v m="$2" '$1=="mnemonic" && $2==w && $3==m {print $4}' "$cg/report.txt")"
  printf '%s\n' "${n:-0}"
}
assert_eq "the extra instruction is the high-word materialisation: no 'shr' before" \
  "0" "$(mnemonic_count before shr)"
assert_eq "exactly one 'shr' after" "1" "$(mnemonic_count after shr)"
assert_eq "the 64-bit shift itself is unchanged: one 'shl' on both sides" \
  "$(mnemonic_count before shl)" "$(mnemonic_count after shl)"

# --------------------------------------------------------------------------
# The measurement record the write-up's numbers are re-derived from.
# --------------------------------------------------------------------------
: >"$M5_MEASURED"
m5_measure M5_BASE_REV "$M5_BASE_REV"
m5_measure M5_PATCHED_TREE "$(git -C "$M5_WORK/patched" rev-parse 'HEAD^{tree}')"
m5_measure M5_DRIVER_LINES "$base_lines"
m5_measure M5_DRIVER_IDENTICAL yes
m5_measure M5_DECOY_DIVERGENT_ROWS "$decoy_diff"
m5_measure M5_FF_93000 "$ff_93000"
m5_measure M5_MAX_BYTECODE_BYTES "$(( max_fields * 31 ))"
m5_measure M5_TEXT_BEFORE "$before_text"
m5_measure M5_TEXT_AFTER "$after_text"
m5_measure M5_INSN_BEFORE "$before_insn"
m5_measure M5_INSN_AFTER "$after_insn"
m5_measure M5_NATIVE_CLANG "$("$(m5_tu_command "$M5_WORK/base" | awk '{print $1}')" --version | head -1)"

finish
