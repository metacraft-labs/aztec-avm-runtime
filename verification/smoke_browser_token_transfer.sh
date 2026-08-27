#!/usr/bin/env bash
# smoke_browser_token_transfer
#
# M27 verification: "a headless browser loads the bundle and executes a token transfer end to end".
#
# ===========================================================================================
# THE BLOCKER THIS SITS ON IS M26'S, AND M27 IS THE FIRST MILESTONE THAT COULD WRITE THIS CHECK.
# ===========================================================================================
#
# Every milestone from M22 to M25 recorded the same sentence: "a transaction that calls a REGISTERED
# CONTRACT needs a builder, and upstream's only one constructs a `NativeWorldStateService`" — the
# package DD-9 forbids. M26 vendored it (RI-72, 880 lines, `PROVENANCE.md` F20–F24). M26 BUILT the
# transaction; this RUNS it, in a page.
#
# ===========================================================================================
# WHAT "END TO END" HAS TO MEAN FOR THIS TO BE MORE THAN A SCREENSHOT.
# ===========================================================================================
#
# A check that asserted only "the page did not throw" would pass over a page that loaded the bundle
# and did nothing. So every link of the chain is asserted separately, and each one is read from the
# arm's report rather than from a constant:
#
#   the contract is REGISTERED       registeredClasses / registeredInstances, from the facade
#   the selector is ABI-DERIVED      `FunctionSelector.fromNameAndParameters`'s answer EQUALS
#                                    calldata field 0, which is what the AVM dispatches on
#   the function is NAMED            upstream's own `getDebugFunctionName` answers
#                                    `Token.transfer_in_public`, so the AVM had the debug symbols
#   the fee payer is FUNDED          at the LEAF slot, and it is the transaction's OWN fee payer
#   the AVM RAN                      calls into avm.wasm, counted at the boundary
#   the block ACCEPTED it            outcome `processed`, in a numbered block, and the block's
#                                    txHashes contain this transaction's hash
#   §8.4 travelled with it           simulated / protocolVersion / proving, off the receipt
#
# TWO SELECTORS, NOT ONE, because the transaction enqueues TWO different public calls and an
# assertion about the order of a one-element list cannot fail. That is M26's reason, kept.
#
# Run: just verify-browser-token-transfer

TEST_NAME="smoke_browser_token_transfer"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"

m27_summary_on_abnormal_exit
m27_require_arms

note "chromium: $(m27_run chromium)"
note "artifact: @aztec/noir-contracts.js Token, from $(m27_run artifact.root), $(m27_run artifact.bytes) bytes"
note "artifact search residue: $(m27_run artifact.search)"

echo "== 1. the page loaded the BUILT bundle and instantiated the module"

AT_OPEN_IMPORTS="$(m27_arm publicOnly transfer.atOpen.declaredImports)"
AT_OPEN_EXPORTS="$(m27_arm publicOnly transfer.atOpen.exports)"
AT_OPEN_BYTES="$(m27_arm publicOnly transfer.atOpen.moduleBytes)"
AT_OPEN_PAGES="$(m27_arm publicOnly transfer.atOpen.memoryPages)"
STREAMING="$(m27_arm publicOnly transfer.atOpen.streaming)"
assert_eq "the module the PAGE compiled is the one on disk, to the byte" \
  "$(m27_run module.bytes)" "$AT_OPEN_BYTES"
assert_eq "…and it exports fifty-five names" "55" "$AT_OPEN_EXPORTS"
assert_eq "…and declares thirteen imports (twelve WASI plus env.memory)" "13" \
  "$(printf '%s' "$AT_OPEN_IMPORTS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
assert_true "…including env.memory" str_has_sub "$AT_OPEN_IMPORTS" 'env.memory'
assert_true "…and it was compiled with compileStreaming" test "$STREAMING" = "true"
assert_ge "…on at least the declared minimum of 130 pages" 130 "$AT_OPEN_PAGES"

echo "== 2. the contract was REGISTERED through the facade"

assert_eq "one contract class registered" "1" "$(m27_arm publicOnly transfer.registeredClasses)"
assert_eq "…and one instance" "1" "$(m27_arm publicOnly transfer.registeredInstances)"
ADDR="$(m27_arm publicOnly transfer.contractAddress)"
assert_true "…at a derived address, not a placeholder" test "${#ADDR}" -eq 66
assert_false "…and the address is not zero" str_has_line "$ADDR" \
  '0x0000000000000000000000000000000000000000000000000000000000000000'

echo "== 3. the selectors are ABI-DERIVED and are what the AVM was handed"

XFER_SEL="$(m27_arm publicOnly transfer.transferSelector)"
BAL_SEL="$(m27_arm publicOnly transfer.balanceSelector)"
CALLDATA_SEL="$(m27_arm publicOnly transfer.calldataSelectors)"
CALLDATA_FIELDS="$(m27_arm publicOnly transfer.calldataFields)"
note "transfer_in_public -> $XFER_SEL, balance_of_public -> $BAL_SEL"
assert_true "the transfer selector is a real 4-byte selector" test "${#XFER_SEL}" -eq 10
assert_true "…and the balance selector too" test "${#BAL_SEL}" -eq 10
assert_false "…and the two differ" test "$XFER_SEL" = "$BAL_SEL"
# THE JOIN: calldata field 0 of each enqueued call, padded to a field, IS the ABI selector. This is
# the assertion that says the AVM dispatches on what the ABI derived rather than on something the
# driver typed in.
XFER_FIELD="0x$(printf '%064s' "${XFER_SEL#0x}" | tr ' ' '0')"
BAL_FIELD="0x$(printf '%064s' "${BAL_SEL#0x}" | tr ' ' '0')"
assert_eq "the two enqueued calls' calldata selectors ARE the two ABI selectors, in order" \
  "[\"$XFER_FIELD\",\"$BAL_FIELD\"]" "$CALLDATA_SEL"
assert_eq "…with real arguments behind them: five fields and two" "[5,2]" "$CALLDATA_FIELDS"
assert_eq "…and two enqueued public calls, so the order above is a claim about two things" \
  "2" "$(m27_arm publicOnly transfer.enqueuedPublicCalls)"

echo "== 4. the functions are NAMED by upstream's own mechanism"

assert_eq "the frame names come from SimpleContractDataSource.getDebugFunctionName" \
  '["Token.transfer_in_public","Token.balance_of_public"]' \
  "$(m27_arm publicOnly transfer.debugFunctionNames)"
assert_eq "…and the artifact is the Token contract" "Token" "$(m27_arm publicOnly transfer.artifactName)"

echo "== 5. the fee payer was funded AT THE LEAF SLOT, and it is the transaction's own"

FEE_PAYER="$(m27_arm publicOnly transfer.feePayer)"
LEAF="$(m27_arm publicOnly transfer.fundedLeafSlot)"
note "fee payer $FEE_PAYER funded at leaf slot $LEAF"
assert_true "the funded leaf slot is a field element" test "${#LEAF}" -eq 66
# The two slots `fee_juice.ts` warns about at length. Funding the STORAGE slot instead of the LEAF
# slot puts a number in the tree that nothing reads and the transaction then fails for insufficient
# funds with the funding "done" — so the outcome below is what makes this assertion mean something.
assert_false "…and it is not the fee payer's address, i.e. not the storage slot by accident" \
  test "$LEAF" = "$FEE_PAYER"

echo "== 6. THE AVM RAN, AND THE BLOCK TOOK IT"

TXHASH="$(m27_arm publicOnly transfer.txHash)"
BLOCK_HASHES="$(m27_arm publicOnly transfer.blockTxHashes)"
assert_eq "the transaction was PROCESSED" "processed" "$(m27_arm publicOnly transfer.outcome)"
assert_eq "…in block 1" "1" "$(m27_arm publicOnly transfer.blockNumber)"
assert_true "…and the block's transaction list contains this transaction" \
  str_has_sub "$BLOCK_HASHES" "$TXHASH"
assert_ge "…and executing it cost calls into avm.wasm" 10 "$(m27_arm publicOnly transfer.moduleCalls)"
# The module's own logging reached the page's `fd_write`, which is the AVM talking rather than the
# host: a run in which the AVM did nothing produces no lines.
assert_ge "…and the AVM's own vinfo logging reached the page" 5 \
  "$(m27_arm publicOnly transfer.wasiCalls.fd_write)"

echo "== 7. §8.4 travelled with the receipt"

assert_eq "the receipt says simulated" "true" "$(m27_arm publicOnly transfer.simulated)"
assert_eq "…and proving: none" "none" "$(m27_arm publicOnly transfer.proving)"
assert_eq "…and names the pinned protocol version" \
  "$(python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))
print(p["npm"]["deletion_era"]["version"])' "$REPO_ROOT/pins.json")" \
  "$(m27_arm publicOnly transfer.protocolVersion)"
# The disclosure line itself, in the page's own log.
assert_true "…and the runtime disclosed, in the page" \
  str_has_sub "$(m27_arm publicOnly status.log)" 'disclosure'

echo "== 8. the page was healthy while doing it"

assert_eq "no page error" "[]" "$(m27_arm publicOnly pageErrors)"
assert_eq "…and no console error" "[]" "$(m27_arm publicOnly consoleErrors)"
assert_eq "…and the module never called proc_exit, i.e. never aborted" "0" \
  "$(m27_arm publicOnly transfer.wasiCalls.proc_exit)"

m27_finish
