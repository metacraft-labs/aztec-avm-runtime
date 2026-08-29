#!/usr/bin/env bash
# test_null_wallet_refuses_by_name
#
# M33 verification: "every method refuses naming itself. Control: a permitted call reaches through,
# so the guard is measured rather than an absence."
#
# ===========================================================================================
# WHY THIS IS A DELIVERABLE AND NOT A PLACEHOLDER
# ===========================================================================================
#
# M33's insight is that the 68 oracles RI-65 records as unimplemented are WALLET responsibilities.
# That converts "the runtime is missing 68 oracles" into "the runtime has no wallet attached" — and
# the sentence is only worth anything if the seam it describes is EXERCISED. The campaign's standing
# rule is that a missing thing refuses BY NAME and never returns a plausible value, and it matters
# more here than anywhere else in the campaign: a fabricated note or nullifier produces a
# transaction that looks valid.
#
# ===========================================================================================
# THE METHOD LIST IS TAKEN FROM THE THING UNDER TEST, TWICE, BY TWO ROUTES
# ===========================================================================================
#
# `CAMPAIGN-BRIEF.md`: *"a constant you have just typed into a check looks like a measurement to the
# person typing it."* So the sixteen names are never typed here. They are read
#
#   * out of `NULL_WALLET_METHODS` in the BUILT bundle, which is `Object.keys(WalletSchema)`, and
#   * out of `@aztec/aztec.js`'s own `WalletSchema` in the installed package, independently,
#
# and the two are compared as SETS before anything else is asserted. Two readings that agree is a
# measurement; one reading is a copy.
#
# ===========================================================================================
# THE CONTROL RUNS THROUGH THE INSTRUMENT
# ===========================================================================================
#
# M32's review: *"a control has to run through the instrument, not beside it"* — its
# `zeroLengthControl` was a second expression over a second buffer and constrained only itself.
# Here the permitted call is not a different object: `served` is a map consulted by the SAME proxy
# that refuses, so the positive control exercises the same dispatch as the fifteen negatives, and it
# is exercised BOTH directly and across the encrypted boundary.
#
# Run: just verify-m33-null-wallet

TEST_NAME="test_null_wallet_refuses_by_name"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m33_wallet.sh"

m33_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m33_require_arms

WORK="$M33_WORK/null"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== 1. the method list, read twice by two routes and compared as a SET"

DECLARED="$(m33_arm refusalsDirect.declaredMethods)"
m33_absent "refusalsDirect.declaredMethods=$DECLARED"
printf '%s\n' "$DECLARED" > "$WORK/bundle_methods.json"

# Route two: `WalletSchema` itself, out of the installed `@aztec/aztec.js`, in a separate process.
SCHEMA_KEYS="$( cd "$REPO_ROOT/orchestration" && node --input-type=module -e "
const { WalletSchema } = await import('@aztec/aztec.js/wallet');
console.log(JSON.stringify(Object.keys(WalletSchema).sort()));
" 2>&1 )"
printf '%s\n' "$SCHEMA_KEYS" > "$WORK/schema_methods.json"
assert_false "upstream's WalletSchema was importable" str_has_sub "$SCHEMA_KEYS" 'Error'

N_DECLARED="$(python3 -c '
import json, sys
print(len(json.load(open(sys.argv[1]))))' "$WORK/bundle_methods.json")"
N_SCHEMA="$(python3 -c '
import json, sys
print(len(json.load(open(sys.argv[1]))))' "$WORK/schema_methods.json")"
note "the bundle declares $N_DECLARED method(s); WalletSchema has $N_SCHEMA"

assert_ge "the method list is a real protocol surface, not a stub" 15 "$N_DECLARED"
assert_eq "the bundle's method list IS WalletSchema's key set, read independently" \
  "$(python3 -c '
import json, sys
print(",".join(sorted(json.load(open(sys.argv[1])))))' "$WORK/schema_methods.json")" \
  "$(python3 -c '
import json, sys
print(",".join(sorted(json.load(open(sys.argv[1])))))' "$WORK/bundle_methods.json")"

# The fifteen methods plus `batch` — upstream derives `batch` from the other fifteen with
# `createBatchSchemas`, so its presence is what says the derivation was not dropped.
assert_true "…and it carries upstream's derived 'batch' method" \
  str_has_sub "$DECLARED" '"batch"'
assert_true "…and 'requestCapabilities', which is where §8.4's disclosure travels" \
  str_has_sub "$DECLARED" '"requestCapabilities"'

echo "== 2. EVERY method refuses, and every refusal NAMES ITSELF"

RESULTS="$(m33_arm refusalsDirect.results)"
m33_absent "refusalsDirect.results=$RESULTS"
printf '%s\n' "$RESULTS" > "$WORK/results.json"

REPORT="$(python3 "$VERIFY_DIR/_m33_refusals.py" "$WORK/bundle_methods.json" "$WORK/results.json")"
r() { printf '%s\n' "$REPORT" | sed -n "s/^$1\t//p"; }
note "checked $(r CHECKED) method(s)"

assert_eq "the refusal report covers every declared method" "$N_DECLARED" "$(r CHECKED)"
assert_eq "…none of them RESOLVED — a plausible default is the failure mode this exists to refuse" \
  "" "$(r RESOLVED)"
assert_eq "…every one rejected with WalletNotAttached" "" "$(r WRONG_ERROR)"
assert_eq "…and every message NAMES THE METHOD it refused" "" "$(r UNNAMED)"
assert_eq "…and states what is missing rather than only that something is" "" "$(r NO_REASON)"

# THE LEDGER IS A SECOND READING OF THE SAME EVENT. The refusal messages come from the exceptions;
# the ledger comes from the object's own bookkeeping. Two independent records of one set.
LEDGER="$(m33_arm refusalsDirect.ledger)"
m33_absent "refusalsDirect.ledger=$LEDGER"
assert_eq "the wallet's own refusal ledger lists exactly the methods that were called" \
  "$(python3 -c '
import json, sys
print(",".join(sorted(json.load(open(sys.argv[1])))))' "$WORK/bundle_methods.json")" \
  "$(python3 -c '
import json, sys
print(",".join(sorted(json.loads(sys.argv[1]))))' "$LEDGER")"
assert_eq "…and it served nothing" "[]" "$(m33_arm refusalsDirect.serves)"

echo "== 3. a NON-method is not made to look like one"

# A proxy that returns a function for every property makes the object THENABLE, and the first
# `await` on it hangs for ever. That is a hang the campaign has a rule about, and it is the reason
# the proxy's `get` returns `undefined` for anything the schema does not declare.
assert_eq "'then' is undefined, so the wallet is not accidentally thenable" \
  "undefined" "$(m33_arm refusalsDirect.notAMethod.then)"
assert_eq "'toJSON' is undefined too" "undefined" "$(m33_arm refusalsDirect.notAMethod.toJSON)"
assert_eq "…and an invented name is undefined rather than a refusing function" \
  "undefined" "$(m33_arm refusalsDirect.notAMethod.nonsense)"
assert_eq "…while the enumerable key set IS the declared method set" \
  "$(python3 -c '
import json, sys
print(",".join(sorted(json.load(open(sys.argv[1])))))' "$WORK/bundle_methods.json")" \
  "$(python3 -c '
import json, sys
print(",".join(sorted(json.loads(sys.argv[1]))))' "$(m33_arm refusalsDirect.ownKeys)")"

echo "== 4. THE CONTROL — a permitted call reaches through, on the same object"

SERVED_DIRECT="$(m33_arm served.direct.resolved)"
SERVED_ANSWER="$(m33_arm served.answer)"
SERVED_REFUSED="$(m33_arm served.directRefused.rejected.name)"
m33_absent "served.direct.resolved=$SERVED_DIRECT" "served.answer=$SERVED_ANSWER" \
  "served.directRefused.rejected.name=$SERVED_REFUSED"

assert_eq "a SERVED method returns the served value" "$SERVED_ANSWER" "$SERVED_DIRECT"
assert_eq "…while an unserved one on the SAME object still refuses by name" \
  "WalletNotAttached" "$SERVED_REFUSED"
assert_eq "…and the object's own ledgers separate the two" "[\"getChainInfo\"]" \
  "$(m33_arm served.serves)"
assert_eq "…in both directions" "[\"getAccounts\"]" "$(m33_arm served.refusals)"

echo "== 5. …and it reaches through the ENCRYPTED BOUNDARY too, not only the object"

WIRE_OK="$(m33_arm served.overWire.resolved)"
WIRE_REFUSED="$(m33_arm served.overWireRefused.rejected.message)"
m33_absent "served.overWire.resolved=$WIRE_OK" "served.overWireRefused.rejected.message=$WIRE_REFUSED"

# The served value crosses the AES-GCM channel, is re-parsed by upstream's own return-type codec,
# and comes back equal. A control that stopped at the dispatch would not have shown that.
assert_eq "the served value survives encryption, transport and upstream's own return codec" \
  "$SERVED_ANSWER" "$WIRE_OK"
assert_true "…and the unserved one is refused ACROSS the boundary, still naming itself" \
  str_has_sub "$WIRE_REFUSED" "WalletNotAttached"
assert_true "…naming the method" str_has_sub "$WIRE_REFUSED" "'getAccounts'"

echo "== 6. the refusal reaches a caller that went through the whole handshake"

HS_REFUSAL="$(m33_arm handshake.chainInfoCall.rejected.message)"
HS_DISCLOSE="$(m33_arm handshake.disclosed.refusedWith)"
m33_absent "handshake.chainInfoCall.rejected.message=$HS_REFUSAL" \
  "handshake.disclosed.refusedWith=$HS_DISCLOSE"
assert_true "a call on a fully-established session is refused by name" \
  str_has_sub "$HS_REFUSAL" "WalletNotAttached"
assert_true "…naming 'getChainInfo'" str_has_sub "$HS_REFUSAL" "'getChainInfo'"
assert_true "…and so is requestCapabilities, which is the §8.4 carrier" \
  str_has_sub "$HS_DISCLOSE" "'requestCapabilities'"

# THE SEAM IS EXERCISED AND EMPTY, AND BOTH HALVES OF THAT ARE ASSERTED: the disclosure crossed
# (recorded on the wallet side) even though the call that carried it was refused.
assert_ge "…and the wallet was TOLD anyway: the disclosure is recorded on its side" 120 \
  "$(printf '%s' "$(m33_arm handshake.walletSideDisclosure.description)" | wc -c)"

echo "== 7. the source declares no method list of its own"

# The one way this could rot is somebody typing the sixteen names into `null_wallet.ts`. The file is
# asserted to derive them, and asserted NOT to carry a literal list.
NULL_SRC="$(cat "$M33_NULL_SRC")"
assert_true "the null wallet derives its method list from WalletSchema" \
  str_has_sub "$NULL_SRC" 'Object.keys(WalletSchema)'
for m in getChainInfo getAccounts simulateTx sendTx createAuthWit; do
  assert_false "…and does not carry a literal '$m'" str_has_sub "$NULL_SRC" "'$m'"
done
assert_true "…while the check's own needle can match a string that IS in that file" \
  str_has_sub "$NULL_SRC" "'WalletNotAttached'"

m33_finish
