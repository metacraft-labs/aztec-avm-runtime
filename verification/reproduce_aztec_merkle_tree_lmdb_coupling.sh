#!/usr/bin/env bash
# reproduce_aztec_merkle_tree_lmdb_coupling
#
# Drives the prepared contribution's own script and asserts it discriminates:
# non-zero on the unpatched tree, zero on the patched one, so it doubles as a
# regression check.
#
# NOTE ON THE FILE NAME. The milestone text says "the directory's reproduce.sh".
# `upstream-bugs/CLAUDE.md` — "Workflow — non-defect contributions" — requires a
# **verify.sh** rather than a `reproduce.sh` for a refactor, because there is no
# defect to reproduce; what has to be established is that the change does what
# it claims and that nothing else moved. The directory therefore carries
# `verify.sh`, and this check drives that. The milestone entry is reworded to
# match rather than a second script being invented to satisfy the wording.
#
# The discriminator itself (`verify.sh --probe`) compiles one translation unit
# that includes every `crypto/merkle_tree` header `vm2_sim`,
# `world_state_reference` and `aztec` use, with the LMDB include directory
# removed from the command line:
#
#   unpatched : fatal error: 'lmdb.h' file not found     (exit 1)
#   patched   : compiles                                 (exit 0)
#
# Both directions are asserted here, and so is the *reason* the unpatched arm
# fails — a probe that failed for a missing msgpack header would also exit
# non-zero and would prove nothing.
#
# This check also runs `verify.sh` in full (build + all three test binaries)
# against the patched tree, so the script a reviewer would run is itself
# exercised end to end, exit status included.
#
# Run: just verify-merkle-reproduce

TEST_NAME="reproduce_aztec_merkle_tree_lmdb_coupling"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_merkle_lmdb.sh"

VERIFY_SH="$M3_PATCH_DIR/verify.sh"
PROBE_SRC="$M3_PATCH_DIR/probe/no_lmdb_probe.cpp"

assert_file "the contribution carries a verify.sh (not a reproduce.sh — see the note above)" \
  "$VERIFY_SH"
assert_false "and it carries no reproduce.sh, which the convention reserves for defects" \
  test -f "$M3_PATCH_DIR/reproduce.sh"
assert_file "the standalone discriminator source is present" "$PROBE_SRC"

# The probe must include the headers the deliverable names, or it is probing
# something else.
probe_src="$(cat "$PROBE_SRC" 2>/dev/null)"
for h in hash_path.hpp indexed_tree/indexed_leaf.hpp memory_tree.hpp response.hpp types.hpp; do
  assert_contains "the probe includes crypto/merkle_tree/$h" \
    "barretenberg/crypto/merkle_tree/$h" "$probe_src"
done
assert_contains "the probe names something from the vocabulary so the includes cannot be elided" \
  "TreeDBStats" "$probe_src"

m3_prepare_trees
# The probe reads fetched headers (msgpack, tracy, …) out of a configured build
# tree, so both trees must have been configured. m3_measured guarantees that,
# running the neutrality check if it has not run yet.
m3_measured

# ---------------------------------------------------------------------------
# The discriminator, both directions, by exit status
# ---------------------------------------------------------------------------
run_probe() { # <aztec-root> <log>   -> exit status of verify.sh
  local root="$1" log="$2"
  m3_in_devshell '
    export CXX="$(command -v clang++)"
    export AZTEC="$1"
    exec bash "$2" --probe
  ' "$root" "$VERIFY_SH" >"$log" 2>&1
}

run_probe "$M3_WORK/patched" "$M3_WORK/probe-patched.log"
rc_patched=$?
assert_eq "verify.sh --probe exits 0 on the PATCHED tree" 0 "$rc_patched"
assert_contains "and says the vocabulary compiles without the LMDB include dir" \
  "COMPILES without the LMDB include dir" "$(cat "$M3_WORK/probe-patched.log")"

run_probe "$M3_WORK/base" "$M3_WORK/probe-base.log"
rc_base=$?
assert_false "verify.sh --probe exits NON-ZERO on the UNPATCHED tree" test "$rc_base" -eq 0
base_out="$(cat "$M3_WORK/probe-base.log")"
assert_contains "and fails for the right reason: 'lmdb.h' file not found" \
  "'lmdb.h' file not found" "$base_out"
assert_contains "and the header that demands it is lmdblib/types.hpp" \
  "lmdblib/types.hpp" "$base_out"

# Both arms in one run: this is the invocation PR.md quotes.
m3_in_devshell '
  export CXX="$(command -v clang++)"
  export AZTEC="$1" AZTEC_REF="$2"
  exec bash "$3" --probe
' "$M3_WORK/patched" "$M3_WORK/base" "$VERIFY_SH" >"$M3_WORK/probe-both.log" 2>&1
rc_both=$?
assert_eq "with AZTEC_REF set, verify.sh --probe reports both arms and exits 0" 0 "$rc_both"
both_out="$(cat "$M3_WORK/probe-both.log")"
assert_contains "the transcript PR.md quotes: the patched arm compiles" \
  "patched : COMPILES without the LMDB include dir  (expected)" "$both_out"
assert_contains "the transcript PR.md quotes: the upstream arm fails" \
  "upstream: fails without the LMDB include dir  (expected)" "$both_out"
assert_contains "and it reports PROBE OK" "PROBE OK" "$both_out"

# ---------------------------------------------------------------------------
# The full script, end to end, on the patched tree
# ---------------------------------------------------------------------------
m3_in_devshell '
  export CXX="$(command -v clang++)"
  export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
  export AZTEC="$1" AZTEC_REF="$2"
  exec bash "$3"
' "$M3_WORK/patched" "$M3_WORK/base" "$VERIFY_SH" >"$M3_WORK/verify-full.log" 2>&1
rc_full=$?
assert_eq "verify.sh in full (build + all three test binaries) exits 0" 0 "$rc_full"
full_out="$(cat "$M3_WORK/verify-full.log")"
assert_contains "it reports its own success line" \
  "OK: native unchanged, and the tree vocabulary no longer needs LMDB" "$full_out"
# verify.sh column-pads the binary name, so match on the pair rather than on a
# literal run of spaces.
verify_reported() { # <binary> <count>
  printf '%s\n' "$full_out" | grep -qE "^[[:space:]]*$1[[:space:]]+ran=$2[[:space:]]+passed=$2[[:space:]]+expected=$2[[:space:]]+ok$"
}
assert_true "verify.sh measured crypto_merkle_tree_tests ran=36 passed=36 ok" \
  verify_reported crypto_merkle_tree_tests 36
assert_true "verify.sh measured crypto_merkle_tree_lmdb_tests ran=96 passed=96 ok" \
  verify_reported crypto_merkle_tree_lmdb_tests 96
assert_true "verify.sh measured world_state_tests ran=33 passed=33 ok" \
  verify_reported world_state_tests 33
[ "$rc_full" -eq 0 ] || note "see $M3_WORK/verify-full.log"

finish
