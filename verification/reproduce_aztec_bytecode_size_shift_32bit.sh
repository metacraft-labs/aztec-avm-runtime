#!/usr/bin/env bash
# M5 — the prepared contribution itself: its shape, its write-up, and whether its
# own script discriminates.
#
# THE NAME. The milestone's verification entry is called
# `reproduce_aztec_bytecode_size_shift_32bit` and describes "the directory's
# reproduce.sh". The directory carries a `verify.sh`, and deliberately:
# `upstream-bugs/CLAUDE.md`'s "Workflow — non-defect contributions" requires
# `PR.md` + `verify.sh` and reserves `ISSUE.md` + `reproduce.sh` for defects, and
# this plan's own `:upstream_patch_location:` already says all five Aztec patches
# are `PR.md` / `verify.sh`. The milestone's deliverable naming `ISSUE.md` is
# reconciled the same way M3 and M4 reconciled theirs — the test NAME is kept so
# it stays greppable, and this check asserts that no `ISSUE.md` and no
# `reproduce.sh` sit beside `PR.md`. The framing the milestone asks for — latent
# UB on a platform upstream does not target, not a live defect — is exactly what
# makes `PR.md` the right spelling.
#
# What this check does, beyond the shape:
#
#   * Re-derives PR.md's numbers from the measurement record and from the trees,
#     not from PR.md. Form checks pass over padded prose; a diffstat read out of
#     the patch does not.
#   * Asserts that the PATCH'S OWN COMMIT MESSAGE — the text that becomes the PR
#     body, and the artefact upstream actually reads — carries the same claims as
#     PR.md, and none of the ones both were corrected away from. M4's review found
#     PR.md corrected and the commit message still carrying the overstatement.
#   * Drives `verify.sh` and MEASURES its discriminating power with mutations that
#     each have to be rejected by their own message, not merely by a non-zero exit.
#     Including the two pairings a reviewer could get wrong by accident — the same
#     build handed in on both sides, and the two sides swapped — which used to be
#     recorded as a limitation of part D and are now failures in it.
#
# Requires the measurement record, so run it after the other three (or via
# `just verify-m5`). It does not skip if the record is missing: it dies.

TEST_NAME="reproduce_aztec_bytecode_size_shift_32bit"
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/lib_bytecode_shift.sh"

note "work directory: $M5_WORK"
m5_prepare_trees

UPSTREAM_BUGS="$WORKSPACE_ROOT/codetracer-specs/upstream-bugs"

# --------------------------------------------------------------------------
# 1. Shape.
# --------------------------------------------------------------------------
# The non-defect shape, as one predicate, so the mutations below can be run
# against it rather than against a restatement of it.
shape_ok() { # <dir>
  [ -f "$1/PR.md" ] && [ ! -e "$1/ISSUE.md" ] && [ ! -e "$1/reproduce.sh" ] \
    && [ -x "$1/verify.sh" ]
}

assert_dir "the contribution directory" "$M5_PATCH_DIR"
assert_true "it has the non-defect shape: PR.md + verify.sh, no ISSUE.md, no reproduce.sh" \
  shape_ok "$M5_PATCH_DIR"
assert_file "PR.md — the non-defect spelling" "$M5_PATCH_DIR/PR.md"
assert_false "no ISSUE.md beside it (that spelling is reserved for defects)" \
  test -e "$M5_PATCH_DIR/ISSUE.md"
assert_false "no reproduce.sh beside it (same reason)" \
  test -e "$M5_PATCH_DIR/reproduce.sh"
assert_file "verify.sh" "$M5_CONTRIB_VERIFY"
assert_true "verify.sh is executable" test -x "$M5_CONTRIB_VERIFY"
assert_file "the format-patch" "$M5_PATCH_FILE"
assert_file "repro/shift.c — the dependency-free reproduction" "$M5_PROBE_SHIFT_C"
assert_file "repro/first_field.cpp — the two expressions in barretenberg's uint256_t" "$M5_PROBE_FIRST_FIELD"
assert_file "repro/commitment_driver.cpp — upstream's own function" "$M5_PROBE_DRIVER"

assert_eq "exactly one directory for this patch" "1" \
  "$(find "$UPSTREAM_BUGS" -maxdepth 1 -type d -name 'aztec-*shift*' | wc -l)"
assert_true "SERIES.md indexes it" \
  grep -qF 'aztec-bytecode-size-shift-32bit' "$UPSTREAM_BUGS/SERIES.md"
assert_eq "as patch 3 of 5" "3" \
  "$(grep -F 'aztec-bytecode-size-shift-32bit' "$UPSTREAM_BUGS/SERIES.md" \
     | grep '^| [0-9]' | sed -n 's/^| *\([0-9]*\) *|.*/\1/p')"

pr="$(cat "$M5_PATCH_DIR/PR.md")"
for field in '**Upstream project:**' '**Kind:**' '**Status:**' '**Base commit:**' \
             '**Patch:**' '**Order in the series:**' 'Suggested PR title:'; do
  assert_contains "PR.md carries the header field $field" "$field" "$pr"
done
assert_contains "PR.md says plainly that upstream has no live defect" \
  '**Not a live defect upstream**' "$pr"
assert_contains "PR.md has a 'Known limitations' section" '## Known limitations' "$pr"
assert_contains "PR.md records the downstream carry as the fallback" \
  '## If this is declined' "$pr"
assert_contains "PR.md discloses our own motive, at the end" \
  '## How we found it, and why we care' "$pr"
# The date moves whenever the search is re-run, and it must: the convention is to
# re-check before filing, so a date frozen at the first search would be evidence
# that nobody had. It was 2026-08-21 when this check was written and 2026-08-23
# after M11 re-ran every entry's search against issues AND pull requests.
assert_contains "PR.md records the prior-art search and its date" \
  'Search was 2026-08-23' "$pr"

# --------------------------------------------------------------------------
# 2. PR.md's numbers, re-derived rather than read.
# --------------------------------------------------------------------------
assert_contains "PR.md states the base commit the patch was generated against" \
  "$(m5_measured M5_BASE_REV)" "$pr"
diffstat="$(grep -oE '[0-9]+ insertions?\(\+\), [0-9]+ deletions?\(-\)' "$M5_PATCH_FILE" | head -1)"
assert_eq "the patch's own diffstat" "3 insertions(+), 1 deletion(-)" "$diffstat"
assert_contains "and PR.md quotes it" '+3 / −1' "$pr"
assert_eq "one file in the diff" "1" "$(grep -c '^--- a/' "$M5_PATCH_FILE")"

for n in "$(m5_measured M5_INSN_BEFORE)" "$(m5_measured M5_INSN_AFTER)" \
         "$(m5_measured M5_MAX_BYTECODE_BYTES)" "$(m5_measured M5_SCANNED_TUS)"; do
  assert_contains "PR.md quotes the measured value $n" "$n" "$pr"
done
# PR.md writes byte counts with thousands separators; the record holds them raw.
commify() { printf '%s' "$1" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'; }
assert_contains "PR.md quotes the .text size before the patch" \
  "$(commify "$(m5_measured M5_TEXT_BEFORE)") bytes" "$pr"
assert_contains "PR.md quotes the .text size after it" \
  "$(commify "$(m5_measured M5_TEXT_AFTER)") bytes" "$pr"
assert_contains "and the commit message quotes the same figure" \
  "$(commify "$(m5_measured M5_TEXT_BEFORE)")" "$(sed -n '/^Subject:/,/^---$/p' "$M5_PATCH_FILE")"
assert_contains "PR.md quotes the first field the source's comment predicts" \
  "0x$(m5_measured M5_FF_93000 | sed 's/^0*//')" "$pr"
assert_contains "PR.md states the wasm32 / x86_64 agreement as 13 of 13" \
  '**13 of 13**' "$pr"
assert_contains "and the current form's as 0 of 13" '**0 of 13**' "$pr"
assert_contains "PR.md states that the patch removes one of five -Werror blockers" \
  "one of *five* reasons" "$pr"
assert_eq "and five is what was measured" "5" "$(m5_measured M5_WERROR_FAILURES_BEFORE)"
assert_eq "leaving four" "4" "$(m5_measured M5_WERROR_FAILURES_AFTER)"

# The three quotations PR.md makes from the tree, checked against the tree.
assert_true "poseidon2.cpp:46, as PR.md quotes it" \
  grep -qF 'const uint256_t iv = static_cast<uint256_t>(input_size) << 64;' \
  "$M5_WORK/base/barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/poseidon2.cpp"
assert_true "memory_trace.cpp:75, as PR.md quotes it" \
  grep -qF 'const uint64_t global_addr = (static_cast<uint64_t>(event.space_id) << 32) + event.addr;' \
  "$M5_WORK/base/barretenberg/cpp/src/barretenberg/vm2/tracegen/memory_trace.cpp"
assert_true "bytecode_trace.cpp's 24-bit static_assert, as PR.md quotes it" \
  grep -qF 'static_assert(MAX_PACKED_PUBLIC_BYTECODE_SIZE_IN_FIELDS * 31 <= 0xffffff);' \
  "$M5_WORK/base/barretenberg/cpp/src/barretenberg/vm2/tracegen/bytecode_trace.cpp"
assert_true "the CMake guard that excludes the AVM from the wasm build" \
  grep -qF 'if(NOT FUZZING AND NOT WASM AND NOT BB_LITE)' \
  "$M5_WORK/base/barretenberg/cpp/src/CMakeLists.txt"
# Every file PR.md names as still failing the wasm32 -Werror build must be one the
# scan actually named, so the limitation cannot drift from the measurement.
[ -f "$M5_WORK/scan-patched.txt" ] \
  || die "no $M5_WORK/scan-patched.txt — run test_shift_count_overflow_diagnostic first"
while read -r _ f _; do
  assert_contains "PR.md names $(basename "$f") among the four it does NOT fix" \
    "$(basename "$f")" "$pr"
done < <(grep -E '^other_warning_file ' "$M5_WORK/scan-patched.txt")

# --------------------------------------------------------------------------
# 3. The commit message is the PR body: it must say the same things.
# --------------------------------------------------------------------------
msg="$(sed -n '/^Subject:/,/^---$/p' "$M5_PATCH_FILE")"
assert_ge "the commit message is a real PR body, not a one-liner" 40 \
  "$(printf '%s\n' "$msg" | grep -c .)"
for forbidden in codetracer CodeTracer aztec-avm-runtime metacraft milestone; do
  assert_not_contains "the commit message does not mention '$forbidden'" "$forbidden" "$msg"
done
assert_contains "the commit message states there is no live defect" \
  'there is no live defect' "$msg"
assert_contains "…the same claim PR.md makes" 'Not a live defect upstream' "$pr"
assert_contains "the commit message carries the 13-of-13 / 0-of-13 measurement" \
  '13 of 13 and the current form on 0 of 13' "$msg"
assert_contains "the commit message quotes the sibling that gets it right" \
  'poseidon2.cpp:46' "$msg"
assert_contains "the commit message cites the static_assert about the OTHER operand" \
  'DOM_SEP__PUBLIC_BYTECODE <= UINT32_MAX' "$msg"
assert_contains "the commit message quotes the value the source comment predicts" \
  "0x$(m5_measured M5_FF_93000 | sed 's/^0*//')" "$msg"
assert_contains "the commit message states upstream's own 0xffffff bound" \
  '0xffffff' "$msg"

# The correction this milestone made, asserted in BOTH artefacts, because M4's
# review found exactly this: the prose corrected and the commit message not.
assert_not_contains "the commit message does not claim identical codegen" \
  'identical codegen' "$msg"
assert_contains "PR.md names the earlier draft's claim and corrects it" \
  'An earlier draft of this work claimed' "$pr"
assert_contains "the commit message states the +1 instruction instead" \
  'grows by one instruction' "$msg"
assert_contains "and the 16 bytes of .text" "16 bytes" "$msg"
assert_contains "PR.md states the same, as a table" '(**+1**)' "$pr"
assert_not_contains "neither artefact says 'Native impact: none' unqualified" \
  'Native impact: none.' "$msg"
assert_contains "the commit message qualifies it: no VALUE changes" \
  'Native impact: no value changes' "$msg"

# --------------------------------------------------------------------------
# 4. verify.sh works, and its exit status means something.
# --------------------------------------------------------------------------
run_verify() { # <patch-dir> <extra-env...> -> exit status; output in $M5_WORK/verify-out.txt
  local dir="$1"; shift
  m5_in_devshell '
    dir="$1"; shift
    export AZTEC='"$M5_WORK"'/base
    export BUILD='"$M5_WORK"'/base/barretenberg/cpp/build
    export PATCHED_BUILD='"$M5_WORK"'/patched/barretenberg/cpp/build
    "$@" "$dir/verify.sh"
  ' "$dir" env >"$M5_WORK/verify-out.txt" 2>&1
}

run_verify "$M5_PATCH_DIR"
verify_rc=$?
assert_eq "verify.sh exits 0 with every input present" "0" "$verify_rc"
verify_line="$(grep -E '^verify\.sh: [0-9]+ assertion' "$M5_WORK/verify-out.txt" | tail -1)"
assert_eq "and it makes 44 assertions across its five parts" "44" \
  "$(printf '%s' "$verify_line" | sed -n 's/^verify.sh: \([0-9]*\) assertion.*/\1/p')"
assert_eq "with no failures" "0" \
  "$(printf '%s' "$verify_line" | sed -n 's/.*, \([0-9]*\) failure.*/\1/p')"
for part in A B C D E; do
  assert_contains "part $part ran" "== part $part:" "$(cat "$M5_WORK/verify-out.txt")"
done
assert_contains "part D compared upstream's own commitment" \
  'IDENTICAL first fields and commitments, before and after' "$(cat "$M5_WORK/verify-out.txt")"
assert_contains "part C ran the wasm32 binary" \
  'the WIDENED form gives the same value on wasm32 as on the host' "$(cat "$M5_WORK/verify-out.txt")"

# There is no skip path: a missing input is exit 2 naming the variable, never 0.
m5_in_devshell '
  export AZTEC='"$M5_WORK"'/base
  export BUILD='"$M5_WORK"'/base/barretenberg/cpp/build
  unset PATCHED_BUILD
  "$1" D
' "$M5_CONTRIB_VERIFY" >"$M5_WORK/verify-nopatched.txt" 2>&1
assert_eq "a missing PATCHED_BUILD is exit 2, not 0" "2" "$?"
assert_contains "and it names the variable" "set PATCHED_BUILD" \
  "$(cat "$M5_WORK/verify-nopatched.txt")"
assert_not_contains "and never prints SKIPPED" "SKIPPED" "$(cat "$M5_WORK/verify-nopatched.txt")"

m5_in_devshell 'unset AZTEC BUILD PATCHED_BUILD; "$1" C' "$M5_CONTRIB_VERIFY" \
  >"$M5_WORK/verify-noaztec.txt" 2>&1
assert_eq "a missing AZTEC is exit 2 too" "2" "$?"
assert_contains "and it names that variable" "set AZTEC" "$(cat "$M5_WORK/verify-noaztec.txt")"

# --------------------------------------------------------------------------
# 5. Mutations. Each must be rejected BY ITS OWN MESSAGE.
# --------------------------------------------------------------------------
mutant="$M5_WORK/mutant"
new_mutant() { rm -rf "$mutant"; cp -r "$M5_PATCH_DIR" "$mutant"; }

# (a) The one that matters, and the analogue of M4's 34.0 decoy: a patch that
#     still applies cleanly, still touches one file, still widens — and shifts by
#     31. Everything that only checks "nothing else changed" goes green on it.
new_mutant
python3 - "$mutant/$(basename "$M5_PATCH_FILE")" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "+    return FF(uint256_t(DOM_SEP__PUBLIC_BYTECODE) + (uint256_t(bytecode_size) << 32));"
new = "+    return FF(uint256_t(DOM_SEP__PUBLIC_BYTECODE) + (uint256_t(bytecode_size) << 31));"
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new))
PY
run_verify "$mutant"
assert_false "a patch that widens but shifts by 31 is rejected" test "$?" -eq 0
assert_contains "…by the assertion that names the shift count" \
  'and it shifts by exactly 32  expected [32], got [31]' "$(cat "$M5_WORK/verify-out.txt")"

# (b) A patch that also touches another file.
new_mutant
cat >>"$mutant/$(basename "$M5_PATCH_FILE")" <<'EOF'
diff --git a/barretenberg/cpp/src/barretenberg/vm2/simulation/lib/contract_crypto.hpp b/barretenberg/cpp/src/barretenberg/vm2/simulation/lib/contract_crypto.hpp
--- a/barretenberg/cpp/src/barretenberg/vm2/simulation/lib/contract_crypto.hpp
+++ b/barretenberg/cpp/src/barretenberg/vm2/simulation/lib/contract_crypto.hpp
@@ -1,2 +1,3 @@
 #pragma once
+// unrelated
EOF
run_verify "$mutant"
assert_false "a patch that also touches the header is rejected" test "$?" -eq 0
assert_contains "…by the one-file assertion" \
  'the patch touches exactly one file  expected [1], got [2]' "$(cat "$M5_WORK/verify-out.txt")"

# (c) An ISSUE.md or a reproduce.sh dropped beside PR.md — the shape this
#     milestone reconciled. Asserted here rather than in verify.sh, because it is
#     a convention of ours and not something an upstream reviewer would run.
new_mutant
: >"$mutant/reproduce.sh"
assert_false "a reproduce.sh dropped beside PR.md is rejected by the shape predicate" \
  shape_ok "$mutant"
new_mutant
cp "$mutant/PR.md" "$mutant/ISSUE.md"
assert_false "an ISSUE.md dropped beside PR.md is rejected too" shape_ok "$mutant"
new_mutant
rm -f "$mutant/verify.sh"
assert_false "and so is a directory with no verify.sh at all" shape_ok "$mutant"

# (d) The probe made vacuous: first_field.cpp with BOTH forms widened, so the
#     wasm32/x86_64 comparison can no longer see a difference. This is the
#     equivalent of M3's "discriminator made vacuous" mutation.
new_mutant
python3 - "$mutant/repro/first_field.cpp" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "return uint256_t(DOM_SEP__PUBLIC_BYTECODE) + uint256_t(bytecode_size << 32);"
new = "return uint256_t(DOM_SEP__PUBLIC_BYTECODE) + (uint256_t(bytecode_size) << 32);"
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new))
PY
run_verify "$mutant"
assert_false "a probe whose 'upstream' form is secretly the patched one is rejected" \
  test "$?" -eq 0
assert_contains "…by the assertion tying the probe to the patch's own removed line" \
  "the probe's upstream_form is the patch's removed expression" \
  "$(grep 'FAIL' "$M5_WORK/verify-out.txt")"
assert_contains "…and by the agreement count, which is no longer 0" \
  'agrees with the host on none of the 13 sizes  expected [0], got [13]' \
  "$(cat "$M5_WORK/verify-out.txt")"

# (e) The same tree supplied on both sides of part D's comparison, and the two
#     sides swapped. Part D compares two binaries; handed one binary twice it
#     still reports "IDENTICAL", which is true and worthless — the strongest
#     claim in PR.md resting on no comparison at all. M5 recorded that as a
#     limitation rather than a pass. The review closed it instead: part D now
#     reads each build's own contract_crypto.cpp out of its own compile database
#     and asserts it carries the patch's removed / added line, so a side that is
#     not that side is named before anything is compared.
m5_in_devshell '
  export AZTEC='"$M5_WORK"'/base
  export BUILD='"$M5_WORK"'/base/barretenberg/cpp/build
  export PATCHED_BUILD='"$M5_WORK"'/base/barretenberg/cpp/build
  "$1" D
' "$M5_CONTRIB_VERIFY" >"$M5_WORK/verify-same-tree.txt" 2>&1
same_rc=$?
assert_false "part D given the SAME tree on both sides is rejected, not reported green" \
  test "$same_rc" -eq 0
assert_contains "…by the assertion naming which side is not the side it claims to be" \
  'PATCHED_BUILD is not a patched tree' "$(cat "$M5_WORK/verify-same-tree.txt")"
note "it still prints 'IDENTICAL' — it is; the point is that saying so now costs a failure"
assert_contains "and the comparison itself still ran, so the failure is the pairing" \
  'IDENTICAL first fields and commitments' "$(cat "$M5_WORK/verify-same-tree.txt")"

# The reversed pairing, which the implementation never tried: the patched tree
# handed in as the unpatched side.
m5_in_devshell '
  export AZTEC='"$M5_WORK"'/base
  export BUILD='"$M5_WORK"'/patched/barretenberg/cpp/build
  export PATCHED_BUILD='"$M5_WORK"'/base/barretenberg/cpp/build
  "$1" D
' "$M5_CONTRIB_VERIFY" >"$M5_WORK/verify-swapped.txt" 2>&1
assert_false "part D with the two sides SWAPPED is rejected too" test "$?" -eq 0
assert_contains "…and both sides are named" \
  'BUILD is not the unpatched tree' "$(cat "$M5_WORK/verify-swapped.txt")"

assert_eq "and check 1's decoy — a tree that IS patched, wrongly — diverges on 16 of 18 rows" \
  "16" "$(m5_measured M5_DECOY_DIVERGENT_ROWS)"

rm -rf "$mutant"
finish
