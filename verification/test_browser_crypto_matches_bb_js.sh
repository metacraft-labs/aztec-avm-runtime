#!/usr/bin/env bash
# test_browser_crypto_matches_bb_js
#
# The differential that makes M27's thirteenth overlay usable rather than plausible.
#
# ===========================================================================================
# WHY THIS EXISTS.
# ===========================================================================================
#
# DD-11 is satisfied by taking poseidon2 and grumpkin out of `avm.wasm` instead of downloading
# 7.9 MB of proving stack for them. That is only sound if the two agree with bb.js EXACTLY. A
# poseidon wrong by one round constant produces a fee-juice leaf slot nobody reads: the funding
# "succeeds", the transaction then fails for insufficient funds, and the cause is four layers away.
# A grumpkin wrong by anything produces a contract address that is not the contract's address.
#
# So both are run against `@aztec/foundation`'s own implementations — which ARE bb.js on this side
# of the boundary — in ONE process, over a corpus, with the results compared as strings.
#
# ===========================================================================================
# THE CORPUS IS CHOSEN, AND THE CONTROLS ARE WHAT MAKE THE AGREEMENT A MEASUREMENT.
# ===========================================================================================
#
# Poseidon2: the EMPTY input (a sponge's edge case), zero, one, and the lengths the four measured
# call sites use — 2, 3, 4, 5 — plus random vectors and a near-modulus value. Grumpkin: small
# scalars, a large one, and an addition of two derived points.
#
# THREE CONTROLS, because "they matched" and "the comparison compared nothing" look identical:
#   * a PERTURBED input must DISAGREE, for each primitive;
#   * an OFF-CURVE point must be REFUSED by the module, by name, rather than silently answered;
#   * the module's call counter must be NON-ZERO, so the answers came from the module.
#
# Run: just verify-browser-crypto

TEST_NAME="test_browser_crypto_matches_bb_js"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"

m27_summary_on_abnormal_exit
m27_require_module
m27_require_packages

echo "== the module under test"
note "module: $AVM_WASM_PATH"
note "$M27_MODULE_EXPORT_COUNT exports, $M27_MODULE_BYTES bytes, sha256 ${M27_MODULE_SHA:0:16}…"
assert_eq "it exports fifty-five names — M27's thirteenth overlay, not M23's twelve" "55" \
  "$M27_MODULE_EXPORT_COUNT"
for e in avm_poseidon2_hash avm_poseidon2_permutation avm_grumpkin_mul avm_grumpkin_add; do
  assert_true "…including $e" str_has_line "$(m27_module_exports "$AVM_WASM_PATH")" "$e"
done

echo "== the differential, run in one process against @aztec/foundation (i.e. bb.js)"

# THE PROBE IS A TRACKED FILE UNDER `browser/`, AND IT HAS TO BE.
#
# Node resolves a bare `@aztec/*` specifier from the IMPORTING FILE'S location, not from the working
# directory. A probe written into `$M27_WORK` and run with `cd browser` therefore fails on every
# import with `ERR_MODULE_NOT_FOUND` — measured, on this check's first run. `browser/` is where the
# `node_modules` symlink is, so that is where the probe lives, beside the sources it compares. It is
# the same arrangement `tools/run_*_arms.mjs` uses for the orchestration.
PROBE="$BROWSER_DIR/crypto_differential.mjs"
assert_file "the differential probe sits beside the sources it compares" "$PROBE"
assert_true "…and is tracked" git -C "$REPO_ROOT" ls-files --error-unmatch "browser/crypto_differential.mjs"
mkdir -p "$M27_WORK"

M27_DIFF_TIMEOUT="${M27_DIFF_TIMEOUT:-300}"
RESULT="$( cd "$BROWSER_DIR" && env NODE_NO_WARNINGS=1 AVM_WASM_PATH="$AVM_WASM_PATH" \
  timeout -s KILL "$M27_DIFF_TIMEOUT" node "$PROBE" 2>"$M27_WORK/crypto-differential.stderr" )"
RC=$?
if [ "$RC" -eq 137 ] || [ "$RC" -eq 124 ]; then
  die "the crypto differential did not finish within ${M27_DIFF_TIMEOUT}s and was killed"
fi
[ "$RC" -eq 0 ] || die "the crypto differential failed (exit $RC); see $M27_WORK/crypto-differential.stderr"

field() { printf '%s\n' "$RESULT" | sed -n "s/^$1\t//p"; }

echo "== poseidon2"
note "$(field HASH-CORPUS) input(s) compared"
assert_ge "the hash corpus is substantial" 8 "$(field HASH-CORPUS)"
assert_eq "every input hashes identically to bb.js" "$(field HASH-CORPUS)" "$(field HASH-OK)"
assert_eq "…with no mismatch" "0" "$(field HASH-BAD)"
assert_eq "the permutation agrees too" "true" "$(field PERM-MATCH)"
assert_eq "…and the domain-separated hash" "true" "$(field SEP-MATCH)"
assert_eq "CONTROL: a different input DISAGREES, so the comparison compares something" "true" \
  "$(field HASH-CONTROL-DISAGREES)"

echo "== grumpkin"
note "$(field MUL-CORPUS) scalar(s) compared"
assert_ge "the multiply corpus is substantial" 5 "$(field MUL-CORPUS)"
assert_eq "every scalar multiplies identically to bb.js" "$(field MUL-CORPUS)" "$(field MUL-OK)"
assert_eq "…with no mismatch" "0" "$(field MUL-BAD)"
assert_eq "point addition agrees" "true" "$(field ADD-MATCH)"
assert_eq "CONTROL: a different scalar DISAGREES" "true" "$(field MUL-CONTROL-DISAGREES)"
assert_true "CONTROL: an OFF-CURVE point is refused by the module, by name" \
  str_has_sub "$(field OFF-CURVE)" 'not on the grumpkin curve'

echo "== and the answers came from the MODULE"
assert_ge "avm.wasm's poseidon2 was called" 10 "$(field POSEIDON-CALLS)"
assert_ge "…and its grumpkin" 6 "$(field GRUMPKIN-CALLS)"

m27_finish
