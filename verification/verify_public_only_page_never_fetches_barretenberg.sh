#!/usr/bin/env bash
# verify_public_only_page_never_fetches_barretenberg
#
# M27's central check, and the milestone says how it must be made: "asserted on OBSERVED NETWORK
# REQUESTS, not on bundler configuration".
#
# ===========================================================================================
# WHY THAT DISTINCTION IS THE WHOLE POINT, AND WHAT IT COSTS TO HONOUR IT.
# ===========================================================================================
#
# A configuration assertion — "the bundler marks bb.js as an async chunk" — is a claim about
# INTENT. A request log is a claim about BEHAVIOUR. The difference is not pedantry here: this
# milestone found TWO separate routes from a public-only page to the 7.9 MB proving wasm, and the
# SECOND one was invisible to every configuration a bundler could express.
#
#   1. `@aztec/foundation`'s `poseidon2Hash`. Found by instrumenting `Barretenberg.initSingleton`
#      around a Form A run: 82 calls, four call sites, all enumerated, all closed by exporting
#      poseidon2 from `avm.wasm` and substituting the module.
#   2. `@aztec/stdlib`'s ADDRESS DERIVATION — `Grumpkin.add(Grumpkin.mul(G, preaddress), ivpkM)`.
#      Not on the first enumeration, because the run that produced it never built a contract
#      instance. It was found HERE, by this check, reading `Network.requestWillBeSent`: with
#      poseidon2 done, the page still fetched `chunks/barretenberg-*.js`.
#
# So the milestone's sentence is not a preference about test style. `CAMPAIGN-BRIEF.md`'s rule is
# "an absence claim is only as wide as the spellings you enumerated"; a network log does not care
# which spellings anybody thought of.
#
# ===========================================================================================
# AND THE ABSENCE HAS A CONTROL, IN THE SAME BROWSER, THROUGH THE SAME OBSERVER.
# ===========================================================================================
#
# `CAMPAIGN-BRIEF.md` records two shipped defects of the shape "an absence asked of a tree that
# excludes the subject by construction". An empty `barretenbergRequests` list is produced by all of:
# a page that correctly never fetched it; a page that fetched nothing at all; an observer attached
# after navigation; and a needle that matches nothing. The `provingControl` arm is a SECOND page,
# in the SAME browser, with the SAME observer and the SAME needle, whose only difference is that it
# calls `BarretenbergSync.initSingleton()` on purpose — and it must produce a NON-EMPTY list.
#
# Run: just verify-browser-no-barretenberg

TEST_NAME="verify_public_only_page_never_fetches_barretenberg"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"

m27_summary_on_abnormal_exit
m27_require_arms

note "chromium: $(m27_run chromium)"
note "module:   $(m27_run module.bytes) bytes, sha256 $(m27_run module.sha256 | cut -c1-16)…"

echo "== 1. the public-only page ran a real transaction — so its log is a log of something"

OUTCOME="$(m27_arm publicOnly transfer.outcome)"
BLOCK="$(m27_arm publicOnly transfer.blockNumber)"
NAMES="$(m27_arm publicOnly transfer.debugFunctionNames)"
MODULE_CALLS="$(m27_arm publicOnly transfer.moduleCalls)"
assert_eq "the transaction was PROCESSED, in a block" "processed" "$OUTCOME"
assert_eq "…and the block is block 1" "1" "$BLOCK"
assert_eq "…calling the Token contract's two public functions" \
  '["Token.transfer_in_public","Token.balance_of_public"]' "$NAMES"
assert_ge "…and it cost calls into avm.wasm, so the module really ran" 10 "$MODULE_CALLS"
assert_eq "…with no page error" "[]" "$(m27_arm publicOnly pageErrors)"
assert_eq "…and no console error" "[]" "$(m27_arm publicOnly consoleErrors)"

echo "== 2. THE ASSERTION: no request the browser made names barretenberg"

BB="$(m27_arm publicOnly barretenbergRequests)"
REQS="$(m27_arm publicOnly requestCount)"
ALL="$(m27_arm publicOnly requests)"
note "the page made $REQS request(s)"
assert_eq "the public-only page fetched NO barretenberg chunk" "[]" "$BB"
# NON-EMPTINESS, because `[]` is also what an observer that saw nothing reports.
assert_ge "…and the log is not empty: the observer saw the page load" 10 "$REQS"
assert_true "…including the document itself" str_has_sub "$ALL" '/index.html'

echo "== 3. …and it DID fetch avm.wasm and the contract artifact, lazily"

assert_eq "avm.wasm was fetched, exactly once" '["/assets/avm.wasm"]' \
  "$(m27_arm publicOnly avmWasmRequests)"
assert_eq "…and the Token artifact, exactly once" '["/assets/token_contract-Token.json"]' \
  "$(m27_arm publicOnly artifactRequests)"
# THE LAZY PROTOCOL-CONTRACT ARTIFACT. `FeeJuice.json` is 534 KB and is behind upstream's own
# `fee-juice/lazy.js` dynamic import; it appears in the log because funding a fee payer needs the
# storage layout, which is exactly what "loads lazily" means.
assert_true "…and the FeeJuice artifact arrived as a LAZY chunk, on demand" \
  str_has_sub "$ALL" '/chunks/FeeJuice-'
# AND THE TWO REGISTRIES DID NOT, which is what says the laziness is real rather than a rename.
assert_false "…while ContractClassRegistry (998 KB) was never fetched" \
  str_has_sub "$ALL" 'ContractClassRegistry'
assert_false "…and ContractInstanceRegistry (427 KB) was never fetched" \
  str_has_sub "$ALL" 'ContractInstanceRegistry'

echo "== 4. THE NEGATIVE CONTROL: the same observer, in a page that fetches it on purpose"

CTL_BB="$(m27_arm provingControl barretenbergRequests)"
CTL_REQS="$(m27_arm provingControl requestCount)"
CTL_FETCHED="$(m27_arm provingControl control.fetched)"
note "the control page made $CTL_REQS request(s); barretenberg: $CTL_BB"
assert_eq "the control page DID reach the proving stack" "true" "$CTL_FETCHED"
assert_false "…and its barretenberg list is NOT empty" str_has_line "$CTL_BB" '[]'
assert_true "…it names a barretenberg chunk" str_has_sub "$CTL_BB" 'barretenberg'
# The control and the subject differ in ONE thing. If the control's own transaction machinery had
# failed it would prove nothing about the subject, so its page is asserted healthy too.
assert_eq "…and the control page had no page error either" "[]" "$(m27_arm provingControl pageErrors)"

echo "== 5. the hashing really came from the module, and not from a lucky absence"

POS="$(m27_arm publicOnly transfer.poseidonCallsTotal)"
GRU="$(m27_arm publicOnly transfer.grumpkinCallsTotal)"
note "avm.wasm's poseidon2 was called $POS time(s); its grumpkin $GRU time(s)"
# THE PAIRED POSITIVE. "No barretenberg request" is satisfied by a page that hashed with bb.js and
# somehow did not fetch it — impossible, but the pairing is what makes the absence a MEASUREMENT:
# the hashes happened, and they happened HERE.
assert_ge "the page hashed with the MODULE's poseidon2, many times" 20 "$POS"
assert_eq "…and derived the contract address with the MODULE's grumpkin, twice" "2" "$GRU"

m27_finish
