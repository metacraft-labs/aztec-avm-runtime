#!/usr/bin/env bash
# e2e_ts_wasm_amm — M18.
#
#   verification/e2e_ts_wasm_amm.sh          (or: just verify-ts-wasm-amm)
#
# The verification entry: "AMM operations over the AMM and Token artifacts execute end to end
# through the combined TypeScript and wasm stack."
#
# ============================================================================================
# WHAT THE ENTRY SAID WAS LEFT, AND WHERE EACH PIECE IS.
# ============================================================================================
#
# Re-measured 2026-08-31, the entry's residue read: *"THREE Token instances plus the AMM, each with
# its own deployment and initialization nullifier and its own `constructor` and `set_minter` run,
# balance seeding for each, and each internal call enqueued with `sender` set to the AMM's own
# address."* Every one of those is executed below and asserted, and none of it is claimed in prose:
#
#   three Token instances + the AMM   four class/instance registrations, four DISTINCT addresses,
#                                     four DISTINCT contract-address nullifiers
#   its own `constructor`             four constructors, one block, all four `revertCode` 0, each
#                                     with a real instruction count
#   `set_minter`                      run against the liquidity token, with `is_minter` READ BACK
#                                     — 1 in the arm and 0 in the control, so the grant is a
#                                     measurement rather than a call that returned
#   balance seeding                   `_increase_public_balance`, self-sent by each token, exactly
#                                     as upstream's `amm_test.ts` does it
#   `sender` set to the AMM           the four `abi_only_self` entry points, and the CONTROL is
#                                     the same four with the USER as sender: all four refuse
#
# ============================================================================================
# THE ENTRY NAMES FOUR FUNCTIONS AND THIS CHECK RUNS FOUR.
# ============================================================================================
#
# `CAMPAIGN-BRIEF.md`'s rule — *"when a sentence names N subjects, count how many the check runs"* —
# and upstream's own `amm_test.ts` runs THREE of the four (`add_liquidity`, `swap_exact_tokens_for_
# tokens`, `remove_liquidity`). `_swap_tokens_for_exact_tokens` is the fourth and it is driven here.
# The set is not typed in either: the driver scans the AMM ARTIFACT for every public function
# declared `abi_only_self` and the check asserts that scan found four and that the four it drives
# are those four. A scan that came back empty would make "all of them" vacuously true, so the
# non-emptiness is asserted first — the first version of that scan DID come back empty, because
# `loadContractArtifact` does not carry `custom_attributes` through.
#
# ============================================================================================
# THE STATE IS THE POOL'S OWN, READ BACK THROUGH THE CONTRACTS' OWN VIEW FUNCTIONS.
# ============================================================================================
#
# Nothing here derives a storage slot. Every balance is `Token.balance_of_public(amm)` and every
# supply is `Token.total_supply()`, static-called in a LATER block, exactly as upstream reads them —
# and the numbers are asserted as DELTAS against a measured "before" and as the pool's own
# CONSTANT-PRODUCT INVARIANT, never as constants. A pinned reserve figure is a number nobody
# re-derives; `balance0 * balance1` not falling across a swap is a property of the contract.
#
# Run: just verify-ts-wasm-amm

TEST_NAME="e2e_ts_wasm_amm"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_token_blocks.sh"

tb_summary_on_abnormal_exit
tb_require_arms
tb_note_provenance

# ===========================================================================================
# ARITHMETIC OVER AN ACCESSOR'S OUTPUT NEEDS A GUARD, AND THE PROOF IS A REPRODUCTION.
# ===========================================================================================
#
# `lib.sh` runs with `set -u`, and bash's `$(( ))` treats a bare word as a VARIABLE — so
# `$(( MISSING * 3 ))` is `bash: MISSING: unbound variable` and the shell EXITS. Reproduced
# directly: `bash -c 'set -u; X=MISSING; echo "$(( X + 1 ))"; echo after'` prints the error and
# never prints `after`. Every accessor in this file returns `MISSING` for a field that is not
# there — deliberately, because two empty strings compare equal — so every arithmetic site below
# was one absent field away from KILLING the check instead of failing it. That is
# `CAMPAIGN-BRIEF.md`'s silent-shrink family, and this pass measured it in its own
# `e2e_trace_token_transfer_steppable`, where a mutation arm reported 46 assertions where the
# check has 53.
#
# `num` substitutes a sentinel for anything that is not a number, and the values it protects are
# asserted NUMERIC first — so an absent reading is a named failure and the count does not move.
#
# THE HELPERS ARE DECLARED HERE, AT THE TOP, AND THE FIRST FIX PUT THEM HALFWAY DOWN. The loop in
# PART 3 then ran with `num: command not found` three times and one arithmetic syntax error, and
# FOUR assertions of that loop vanished — 78 to 75 — which is the same silent shrink one level
# further in. A helper is only defined from its declaration onward.
num() { case "${1:-}" in ('' | *[!0-9]*) printf '%s' "${2:--1}" ;; (*) printf '%s' "$1" ;; esac; }
all_numeric() { # <value>… -> prints every value that is not a number, or nothing
  local v
  for v in "$@"; do case "$v" in ('' | *[!0-9]*) printf '%s ' "$v" ;; esac; done
}

# ---------------------------------------------------------------------------
# PART 0 — the arms are against the wasm module and the pinned artifacts
# ---------------------------------------------------------------------------

assert_eq "an arm that does not exist reads MISSING" "MISSING" "$(tb_arm noSuchAmmArm blocks)"
assert_eq "the arm ran against the AMM artifact" "AMM" "$(tb_arm amm ammArtifactName)"
assert_eq "…and the Token artifact" "Token" "$(tb_arm amm tokenArtifactName)"
assert_eq "the module the arms measured is the one this check found" \
  "$TB_MODULE_SHA" "$(tb_arm_meta module.sha256)"
assert_ge "it is a wasm AVM module with a real export surface" 40 "$(tb_arm_meta module.exports)"
# The digest of the artifact the arms actually read, compared against the file on disk. An
# `assert_prefix` against `""` would have matched anything, which is the first form on
# `CAMPAIGN-BRIEF.md`'s list; this is a comparison against a second measurement.
AMM_ARTIFACT_ROOT="$(tb_arm_meta artifacts.amm.root)"
AMM_ARTIFACT_FILE="$REPO_ROOT/$AMM_ARTIFACT_ROOT/node_modules/@aztec/noir-contracts.js/artifacts/amm_contract-AMM.json"
assert_file "the AMM artifact the arms named is on disk" "$AMM_ARTIFACT_FILE"
assert_eq "…and it is the file they hashed" \
  "$(sha256sum "$AMM_ARTIFACT_FILE" | cut -d' ' -f1)" "$(tb_arm_meta artifacts.amm.sha256)"

# ---------------------------------------------------------------------------
# PART 1 — FOUR CONTRACTS: three Tokens and the AMM, deployed and constructed
# ---------------------------------------------------------------------------

for who in token0 token1 liquidityToken amm; do
  assert_eq "$who: one contract class registered in the module's own store" \
    "1" "$(tb_arm amm "deployed.$who.classes")"
  assert_eq "$who: and one instance" "1" "$(tb_arm amm "deployed.$who.instances")"
done

# FOUR CONTRACTS AND NOT ONE REGISTERED FOUR TIMES. Without this, every assertion below is
# satisfied by a driver that deployed a single Token and called it under four names.
ADDRESSES="$(for who in token0 token1 liquidityToken amm; do tb_arm amm "deployed.$who.address"; done)"
assert_eq "the four addresses are four distinct addresses" "4" \
  "$(printf '%s\n' "$ADDRESSES" | sort -u | wc -l | tr -d ' ')"
NULLIFIERS="$(for who in token0 token1 liquidityToken amm; do tb_arm amm "deployed.$who.nullifier"; done)"
assert_eq "and the four contract-address nullifiers are four distinct nullifiers" "4" \
  "$(printf '%s\n' "$NULLIFIERS" | sort -u | wc -l | tr -d ' ')"

assert_eq "the four constructors are the four transactions of one block" \
  '["token0Ctor","token1Ctor","lpCtor","ammCtor"]' "$(tb_block amm constructors processed)"
assert_eq "none of the four constructors reverted" '{"token0Ctor":0,"token1Ctor":0,"lpCtor":0,"ammCtor":0}' \
  "$(tb_block amm constructors revertCodes)"
assert_eq "the module's own four-valued codes agree with upstream's collapsed ones" \
  '[0,0,0,0]' "$(tb_block amm constructors rawRevertCodes)"
assert_ge "a Token constructor executed a real dispatch" 1000 \
  "$(tb_block amm constructors instructionsPerSimulation.0)"
AMM_CTOR_STEPS="$(tb_block amm constructors instructionsPerSimulation.3)"
assert_ge "and the AMM's constructor executed one too" 100 "$AMM_CTOR_STEPS"

# ---------------------------------------------------------------------------
# PART 2 — THE FOUR `abi_only_self` PUBLIC FUNCTIONS, taken from the artifact
# ---------------------------------------------------------------------------

ONLY_SELF="$(tb_arm amm artifactOnlySelfPublicFunctions)"
assert_eq "the artifact scan found four public functions declared abi_only_self" "4" \
  "$(printf '%s' "$ONLY_SELF" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
assert_eq "…and the four this arm drives are exactly those four" \
  "$(printf '%s' "$(tb_arm amm internalFunctions)" | python3 -c 'import json,sys; print(json.dumps(sorted(json.load(sys.stdin)),separators=(",",":")))')" \
  "$ONLY_SELF"

# ---------------------------------------------------------------------------
# PART 3 — ALL FOUR EXECUTE, each in its own transaction, each doing real work
# ---------------------------------------------------------------------------

ADD_STEPS="$(tb_block amm addLiquidity instructionsPerSimulation.0)"
SWAP_IN_STEPS="$(tb_block amm swapExactIn instructionsPerSimulation.0)"
SWAP_OUT_STEPS="$(tb_block amm swapExactOut instructionsPerSimulation.0)"
REMOVE_STEPS="$(tb_block amm removeLiquidity instructionsPerSimulation.0)"

assert_eq "add_liquidity's public half did not revert" "0" "$(tb_block amm addLiquidity revertCodes.addLiquidity)"
assert_eq "swap_exact_tokens_for_tokens' public half did not revert" "0" \
  "$(tb_block amm swapExactIn revertCodes.swapExactIn)"
assert_eq "swap_tokens_for_exact_tokens' public half did not revert" "0" \
  "$(tb_block amm swapExactOut revertCodes.swapExactOut)"
assert_eq "remove_liquidity's public half did not revert" "0" \
  "$(tb_block amm removeLiquidity revertCodes.removeLiquidity)"

# A REVERT CODE OF ZERO IS TRUE OF A TRANSACTION THAT DID NOTHING. M29's finding: a demo that
# reverted at instruction one reported `processed`. Each of the four is asserted to have executed
# far more instructions than a plain view call, and the four counts are asserted to DIFFER — a
# counter wired to a constant satisfies four floors and not four distinct values.
VIEW_STEPS="$(tb_block amm poolBefore instructionsPerSimulation.0)"
assert_ge "a plain balance view executes a real dispatch too, which is the yardstick" 100 "$VIEW_STEPS"
for pair in "add:$ADD_STEPS" "swapExactIn:$SWAP_IN_STEPS" "swapExactOut:$SWAP_OUT_STEPS" "remove:$REMOVE_STEPS"; do
  assert_true "${pair%%:*} executed more instructions than a view call, so it is not a stub" \
    test "$(num "${pair#*:}" 0)" -gt "$(( $(num "$VIEW_STEPS" 0) * 3 ))"
done
assert_eq "the four instruction counts are four distinct values" "4" \
  "$(printf '%s\n%s\n%s\n%s\n' "$ADD_STEPS" "$SWAP_IN_STEPS" "$SWAP_OUT_STEPS" "$REMOVE_STEPS" | sort -u | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
# PART 4 — THE POOL'S STATE, read back through the contracts' own view functions
# ---------------------------------------------------------------------------

amm_ret() { # <block> <index> — the single return value of one static read, unquoted
  tb_block amm "$1" "returnValues.$2" | python3 -c '
import json,sys
try:
    v = json.load(sys.stdin)
except Exception:
    print("MISSING"); raise SystemExit(0)
print(v[0] if isinstance(v, list) and len(v) == 1 else "MISSING")
'
}

BEFORE_T0="$(amm_ret poolBefore 0)"; BEFORE_T1="$(amm_ret poolBefore 1)"; BEFORE_LP="$(amm_ret poolBefore 2)"
assert_eq "the pool starts empty in both tokens and the liquidity supply is zero" "0 0 0" \
  "$BEFORE_T0 $BEFORE_T1 $BEFORE_LP"

AMOUNT0_MAX="$(tb_arm amm amounts.amount0Max)"
AMOUNT1_MAX="$(tb_arm amm amounts.amount1Max)"
SWAP_IN="$(tb_arm amm amounts.swapAmountIn)"
SWAP_OUT_MIN="$(tb_arm amm amounts.swapAmountOutMin)"
EXACT_OUT="$(tb_arm amm amounts.exactOutAmountOut)"
EXACT_IN_MAX="$(tb_arm amm amounts.exactOutAmountInMax)"
LIQ_REMOVED="$(tb_arm amm amounts.liquidityToRemove)"

ADD_T0="$(amm_ret poolAfterAdd 0)"; ADD_T1="$(amm_ret poolAfterAdd 1)"
ADD_LP="$(amm_ret poolAfterAdd 2)"; ADD_LOCKED="$(amm_ret poolAfterAdd 3)"
IN_T0="$(amm_ret poolAfterSwapIn 0)"; IN_T1="$(amm_ret poolAfterSwapIn 1)"
OUT_T0="$(amm_ret poolAfterSwapOut 0)"; OUT_T1="$(amm_ret poolAfterSwapOut 1)"
REM_T0="$(amm_ret poolAfterRemove 0)"; REM_T1="$(amm_ret poolAfterRemove 1)"; REM_LP="$(amm_ret poolAfterRemove 2)"

# EVERY VALUE THAT ENTERS AN ARITHMETIC EXPRESSION BELOW IS A NUMBER, asserted before the first one
# does, and asserted where all of them are already READ. The first form of this assertion named
# variables that had not been assigned yet — `set -u` killed the SUBSHELL the command substitution
# runs in, the parent carried on with an empty string, and `assert_eq "" ""` passed. An assertion
# that cannot fail, created while fixing an instance of the family it belongs to.
NON_NUMERIC="$(all_numeric "$BEFORE_T0" "$BEFORE_T1" "$BEFORE_LP" "$ADD_T0" "$ADD_T1" "$ADD_LP" \
  "$ADD_LOCKED" "$IN_T0" "$IN_T1" "$OUT_T0" "$OUT_T1" "$REM_T0" "$REM_T1" "$REM_LP" \
  "$AMOUNT0_MAX" "$AMOUNT1_MAX" "$SWAP_IN" "$SWAP_OUT_MIN" "$EXACT_OUT" "$EXACT_IN_MAX" "$LIQ_REMOVED")"
assert_eq "every balance, supply and amount this section computes with is a number" "" "$NON_NUMERIC"
# …AND THE CENSUS CAN REPORT ONE. A value the accessor really does produce for an absent field is
# run through the same predicate, so the empty list above is a measurement.
assert_eq "…and the same predicate names a non-number when it sees one" "MISSING " \
  "$(all_numeric "$(amm_ret poolAfterAdd 99)")"

assert_eq "after add_liquidity the pool holds the full token0 deposit" "$AMOUNT0_MAX" "$ADD_T0"
assert_eq "…and the full token1 deposit" "$AMOUNT1_MAX" "$ADD_T1"
assert_true "…and liquidity tokens were minted" test "$ADD_LP" -gt 0
# `_add_liquidity`'s zero-supply branch mints MINIMUM_LIQUIDITY to the zero address to lock it.
# That mint is a CROSS-CONTRACT call the AMM made into the liquidity token, and it is the only
# reason a public balance exists at an address nobody sent anything to.
assert_true "…including a locked minimum at the zero address" test "$ADD_LOCKED" -gt 0
assert_true "…which is a fraction of the supply rather than the whole of it" \
  test "$ADD_LOCKED" -lt "$ADD_LP"

assert_eq "the exact-in swap moved exactly the input amount into the pool" \
  "$(( $(num "$ADD_T0" 0) + $(num "$SWAP_IN" 0) ))" "$IN_T0"
assert_true "…and took token1 out of it" test "$IN_T1" -lt "$ADD_T1"
assert_true "…at least the minimum the caller demanded" test "$(( $(num "$ADD_T1" 0) - $(num "$IN_T1" 0) ))" -ge "$(num "$SWAP_OUT_MIN" 0)"
# THE CONSTANT-PRODUCT INVARIANT. A pool that handed out more than the curve allows would satisfy
# every assertion above; this is the contract's own property and it is computed from the read-back
# reserves rather than pinned.
assert_true "the constant-product invariant did not fall across the exact-in swap" \
  test "$(( $(num "$IN_T0" 0) * $(num "$IN_T1" 0) ))" -ge "$(( $(num "$ADD_T0" 0) * $(num "$ADD_T1" 0) ))"

assert_eq "the exact-out swap took exactly the requested amount of token0 out" \
  "$(( $(num "$IN_T0" 0) - $(num "$EXACT_OUT" 0) ))" "$OUT_T0"
assert_true "…and put token1 in" test "$OUT_T1" -gt "$IN_T1"
assert_true "…no more than the maximum the caller allowed, so the change was refunded" \
  test "$(( $(num "$OUT_T1" 0) - $(num "$IN_T1" 0) ))" -le "$(num "$EXACT_IN_MAX" 0)"
assert_true "the constant-product invariant did not fall across the exact-out swap either" \
  test "$(( $(num "$OUT_T0" 0) * $(num "$OUT_T1" 0) ))" -ge "$(( $(num "$IN_T0" 0) * $(num "$IN_T1" 0) ))"

assert_eq "remove_liquidity burned exactly the liquidity the caller sent in" \
  "$(( $(num "$ADD_LP" 0) - $(num "$LIQ_REMOVED" 0) ))" "$REM_LP"
assert_true "…and paid token0 out of the pool" test "$REM_T0" -lt "$OUT_T0"
assert_true "…and token1 with it" test "$REM_T1" -lt "$OUT_T1"

# ---------------------------------------------------------------------------
# PART 5 — THE PARTIAL-NOTE SEEDING, which is upstream's own workaround and is a fact here
# ---------------------------------------------------------------------------

SEEDED="$(tb_arm amm seededNotes)"
assert_eq "eight partial-note validity commitments were seeded — one per finalize the AMM makes" \
  "8" "$(printf '%s' "$SEEDED" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
assert_eq "…and the eight siloed nullifiers are eight distinct leaves" "8" \
  "$(printf '%s' "$SEEDED" | python3 -c 'import json,sys; print(len({n["siloed"] for n in json.load(sys.stdin)}))')"
# THE COMMITMENT IS NOT THE NOTE. If `poseidon2HashWithSeparator` were the identity — or if the
# separator had been dropped — every validity commitment would equal its own note commitment and
# the seeding would be writing the wrong leaf while looking correct.
assert_eq "every validity commitment differs from the note commitment it was derived from" "0" \
  "$(printf '%s' "$SEEDED" | python3 -c 'import json,sys; print(sum(1 for n in json.load(sys.stdin) if n["validityCommitment"] == n["noteCommitment"]))')"
assert_eq "…and every siloed leaf differs from the commitment it siloes" "0" \
  "$(printf '%s' "$SEEDED" | python3 -c 'import json,sys; print(sum(1 for n in json.load(sys.stdin) if n["siloed"] == n["validityCommitment"]))')"

# ---------------------------------------------------------------------------
# PART 6 — CONTROL ONE: `#[only_self]` refuses a non-self sender, for ALL FOUR
# ---------------------------------------------------------------------------
#
# The arm and this control differ in ONE field: the `sender` on the four AMM calls. The two
# `_increase_public_balance` calls stay self-sent in both, so what is isolated is the AMM's own
# `#[only_self]` and not the token's.

assert_eq "in the arm the four internal calls are sent by the AMM itself" \
  "$(tb_arm amm ammAddress)" "$(tb_arm amm selfSender)"
assert_eq "in the control they are sent by the user" \
  "$(tb_arm ammNotSelfSent user)" "$(tb_arm ammNotSelfSent selfSender)"
assert_true "…and the user is not the AMM, so the two arms really differ" \
  test "$(tb_arm ammNotSelfSent user)" != "$(tb_arm ammNotSelfSent ammAddress)"

for pair in "addLiquidity:addLiquidity" "swapExactIn:swapExactIn" "swapExactOut:swapExactOut" "removeLiquidity:removeLiquidity"; do
  assert_eq "with a foreign sender, ${pair%%:*} reverts" "1" \
    "$(tb_block ammNotSelfSent "${pair%%:*}" "revertCodes.${pair#*:}")"
done
# The refusal is the AMM's and not the token's: the two `_increase_public_balance` calls in the very
# same transaction returned normally, and the third call is the one carrying a revert payload.
assert_eq "the two self-sent token transfers in that transaction still returned normally" \
  '[[],[]]' \
  "$(tb_block ammNotSelfSent addLiquidity returnValues | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[:2],separators=(",",":")))')"
REFUSALS="$(for b in addLiquidity swapExactIn swapExactOut removeLiquidity; do
  tb_block ammNotSelfSent "$b" returnValues | python3 -c 'import json,sys; v=json.load(sys.stdin); print(v[-1][0] if v and v[-1] else "EMPTY")'
done)"
assert_eq "each of the four refusals carries the AVM's own revert payload" "0" \
  "$(printf '%s\n' "$REFUSALS" | grep -c '^EMPTY$' || true)"
assert_eq "and the four payloads are four DISTINCT values — four refusals, not one repeated" "4" \
  "$(printf '%s\n' "$REFUSALS" | sort -u | wc -l | tr -d ' ')"
assert_eq "the arm's own add_liquidity carries no revert payload, which is what makes those four a signal" \
  '[[],[],[]]' "$(tb_block amm addLiquidity returnValues)"
assert_eq "the control's pool is still empty after its add_liquidity" "0 0 0" \
  "$(tb_block ammNotSelfSent poolAfterAdd returnValues | python3 -c 'import json,sys; print(" ".join(x[0] for x in json.load(sys.stdin)[:3]))')"
assert_eq "and its four constructors still succeeded, so the reverts are about the sender" \
  '{"token0Ctor":0,"token1Ctor":0,"lpCtor":0,"ammCtor":0}' \
  "$(tb_block ammNotSelfSent constructors revertCodes)"

# ---------------------------------------------------------------------------
# PART 7 — CONTROL TWO: without the minter grant there is no pool at all
# ---------------------------------------------------------------------------

assert_eq "the arm granted the AMM the liquidity token's minter role, read back off the token" \
  "1" "$(amm_ret minterCheck 0)"
assert_eq "the control ran the same transaction with approve=false" "0" \
  "$(tb_block ammNoMinter minterCheck returnValues.0 | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')"
assert_eq "…both set_minter transactions succeeded, so the difference is the grant and not the call" \
  "0 0" "$(tb_block amm setMinter revertCodes.setMinter) $(tb_block ammNoMinter setMinter revertCodes.setMinter)"
assert_eq "without the grant, add_liquidity reverts" "1" \
  "$(tb_block ammNoMinter addLiquidity revertCodes.addLiquidity)"
assert_eq "…and no liquidity is minted" "0" \
  "$(tb_block ammNoMinter poolAfterAdd returnValues.2 | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')"
# TWO CONTROLS, TWO CAUSES. If both reverted with the same payload the pair would be one control
# run twice, and "the sender" and "the grant" would be indistinguishable.
NOMINTER_PAYLOAD="$(tb_block ammNoMinter addLiquidity returnValues | python3 -c 'import json,sys; v=json.load(sys.stdin); print(v[-1][0] if v and v[-1] else "EMPTY")')"
assert_true "…for a DIFFERENT reason from the foreign-sender control's" \
  test "$NOMINTER_PAYLOAD" != "$(printf '%s\n' "$REFUSALS" | head -1)"
assert_eq "and its four constructors still succeeded too" \
  '{"token0Ctor":0,"token1Ctor":0,"lpCtor":0,"ammCtor":0}' \
  "$(tb_block ammNoMinter constructors revertCodes)"

# ---------------------------------------------------------------------------
# PART 8 — THROUGH THE ORCHESTRATION, with the vendored builder off the world state
# ---------------------------------------------------------------------------

assert_eq "the vendored transaction builder read no world state during the whole AMM arm" "[]" \
  "$(tb_arm amm merkleTouches)"
assert_prefix "…and the tripwire is armed: touching it through the builder's own field throws" \
  "threw:" "$(tb_arm amm merkleTripwireControl)"
assert_eq "…recording exactly the one deliberate observation" "1" \
  "$(tb_arm amm merkleTouchesAfterControl)"

finish
