#!/usr/bin/env bash
# verify_wallet_protocol_is_upstreams
#
# M33 verification: "message types re-derived from the anchor and compared AS A SET. Controls: a
# fabricated type is rejected, and a real one is found, so the comparison is not vacuous."
#
# ===========================================================================================
# WHAT THIS CHECK IS FOR, AND WHY IT IS A SET COMPARISON RATHER THAN A COUNT
# ===========================================================================================
#
# M33's whole claim is that the runtime speaks Aztec's protocol rather than a paraphrase of it.
# The failure mode that would falsify that quietly is not a WRONG message type — a wrong type does
# not interoperate and somebody notices — it is a MISSING one, or an EXTRA one, or one whose string
# value drifted while its name stayed. A count sees none of those:
# `CAMPAIGN-BRIEF.md` records `_m32_doc_ops.py`, written to catch exactly the "same number, missing
# entry" shape, itself asking of the whole file instead of the row. So both directions are compared,
# by NAME and by VALUE, as sets.
#
# THE SOURCE OF TRUTH IS THE OBJECT STORE, NOT A WORKTREE. `m33_anchor_show` reads
# `yarn-project/wallet-sdk/src/types.ts` at `pins.json`'s `cpp` anchor with `git show`, which is
# M22's review's rule: a worktree is a thing somebody can move, and this campaign has been burned by
# a check that measured one.
#
# THE COMPARISON IS AGAINST THE BUNDLE, NOT AGAINST OUR SOURCE. `CAMPAIGN-BRIEF.md`: "ask WHICH
# artefact". `browser/dist/wallet.js` is what ships, so the members are read back out of it by
# importing it, and the vendored source is compared to the anchor separately (by `check-drift`, and
# byte-for-byte here as well, because a `local-edits: none` row is a DIRECTION and not a content
# pin).
#
# THE CONTROLS. Both directions of the set comparison have one:
#   * a FABRICATED member (`aztec-wallet-please-sign-everything`) added to the anchor's side must
#     make the comparison fail, naming it — otherwise "the sets are equal" is a statement about an
#     instrument that cannot see a difference;
#   * a REAL member removed from the bundle's side must fail too, naming it.
# Both are run, in-process, over the same comparer the assertion uses.
#
# Run: just verify-m33-protocol

TEST_NAME="verify_wallet_protocol_is_upstreams"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m33_wallet.sh"

m33_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m33_require_arms

WORK="$M33_WORK/protocol"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== 1. the anchor, and the file the protocol is declared in"

ANCHOR="$(m33_cpp_anchor)"
assert_ge "pins.json declares a cpp anchor commit" 40 "${#ANCHOR}"
assert_true "…and the fork checkout has that commit" \
  git -C "$FORK_ROOT" cat-file -e "$ANCHOR^{commit}"

UPSTREAM_TYPES="$WORK/upstream_types.ts"
m33_anchor_show "yarn-project/wallet-sdk/src/types.ts" > "$UPSTREAM_TYPES"
assert_ge "upstream's wallet-sdk types.ts is readable at the anchor" 150 \
  "$(wc -l < "$UPSTREAM_TYPES")"
assert_true "…and it is where WalletMessageType is declared" \
  str_has_sub "$(cat "$UPSTREAM_TYPES")" 'export enum WalletMessageType'

echo "== 2. the VENDORED copy is byte-identical to the anchor's"

# `check-drift` asserts only the DIRECTION of the comparison for a `local-edits: none` row: that the
# file differs from, or matches, upstream. It never pins WHAT the difference is. So the equality is
# taken here as well, over the header-stripped file, because this is the milestone whose subject is
# "the protocol is upstream's".
for f in types.ts crypto.ts emoji_alphabet.ts; do
  assert_file "the vendored $f exists" "$M33_VENDOR_DIR/$f"
  m33_anchor_show "yarn-project/wallet-sdk/src/$f" > "$WORK/anchor_$f"
  python3 "$VERIFY_DIR/_m33_protocol.py" strip-header "$M33_VENDOR_DIR/$f" > "$WORK/local_$f"
  assert_true "…and it is byte-identical to the anchor's, once the provenance header is stripped" \
    cmp -s "$WORK/anchor_$f" "$WORK/local_$f"
  assert_ge "…and it is not an empty comparison" 100 "$(wc -l < "$WORK/anchor_$f")"
done

echo "== 3. the members, re-derived from the anchor and from the BUILT bundle"

python3 "$VERIFY_DIR/_m33_protocol.py" derive "$UPSTREAM_TYPES" > "$WORK/upstream.json"
UPSTREAM_MEMBERS="$(python3 -c '
import json, sys
print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True, separators=(",", ":")))' "$WORK/upstream.json")"
assert_ge "the anchor declares a substantial number of message types" 11 \
  "$(python3 -c '
import json, sys
print(len(json.load(open(sys.argv[1]))))' "$WORK/upstream.json")"

BUNDLE_MEMBERS="$(m33_arm protocol.messageTypes)"
m33_absent "protocol.messageTypes=$BUNDLE_MEMBERS"
printf '%s\n' "$BUNDLE_MEMBERS" > "$WORK/bundle.json"

note "upstream: $UPSTREAM_MEMBERS"
note "bundle:   $BUNDLE_MEMBERS"

# The arm report is one reading; the bundle imported here is a second, taken by a different process.
DIRECT="$(m33_bundle_value 'm.WalletMessageType')"
assert_eq "the arm report's member map is what the bundle itself declares" \
  "$(python3 -c '
import json, sys
print(json.dumps(json.loads(sys.argv[1]), sort_keys=True, separators=(",", ":")))' "$BUNDLE_MEMBERS")" \
  "$(python3 -c '
import json, sys
print(json.dumps(json.loads(sys.argv[1]), sort_keys=True, separators=(",", ":")))' "$DIRECT")"

echo "== 4. THE SET COMPARISON, in both directions"

CMP="$(python3 "$VERIFY_DIR/_m33_protocol.py" compare "$WORK/upstream.json" "$WORK/bundle.json")"
cmpf() { printf '%s\n' "$CMP" | sed -n "s/^$1\t//p"; }
note "compared $(cmpf SIZE) member(s)"
assert_ge "the comparison is over a non-empty set" 11 "$(cmpf SIZE)"
assert_eq "no message type upstream declares is missing from the bundle" "" "$(cmpf MISSING)"
assert_eq "…and the bundle declares no message type upstream does not" "" "$(cmpf EXTRA)"
assert_eq "…and every member's VALUE agrees, not only its name" "" "$(cmpf VALUE_DIFF)"

echo "== 5. THE CONTROLS — the comparer can say no, in both directions"

python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
d["PLEASE_SIGN_EVERYTHING"] = "aztec-wallet-please-sign-everything"
json.dump(d, open(sys.argv[2], "w"))' "$WORK/upstream.json" "$WORK/upstream_plus.json"
CTRL_A="$(python3 "$VERIFY_DIR/_m33_protocol.py" compare "$WORK/upstream_plus.json" "$WORK/bundle.json")"
ctrla() { printf '%s\n' "$CTRL_A" | sed -n "s/^$1\t//p"; }
assert_eq "a FABRICATED upstream member is reported missing from the bundle, by name" \
  "PLEASE_SIGN_EVERYTHING" "$(ctrla MISSING)"
assert_eq "…and nothing else moves with it" "" "$(ctrla EXTRA)"

python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
del d["SECURE_MESSAGE"]
json.dump(d, open(sys.argv[2], "w"))' "$WORK/bundle.json" "$WORK/bundle_minus.json"
CTRL_B="$(python3 "$VERIFY_DIR/_m33_protocol.py" compare "$WORK/upstream.json" "$WORK/bundle_minus.json")"
ctrlb() { printf '%s\n' "$CTRL_B" | sed -n "s/^$1\t//p"; }
assert_eq "a REAL member removed from the bundle is reported missing, by name" \
  "SECURE_MESSAGE" "$(ctrlb MISSING)"

python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
d["PING"] = "aztec-wallet-ping-but-ours"
json.dump(d, open(sys.argv[2], "w"))' "$WORK/bundle.json" "$WORK/bundle_drift.json"
CTRL_C="$(python3 "$VERIFY_DIR/_m33_protocol.py" compare "$WORK/upstream.json" "$WORK/bundle_drift.json")"
ctrlc() { printf '%s\n' "$CTRL_C" | sed -n "s/^$1\t//p"; }
assert_eq "a member whose NAME is right and whose VALUE drifted is caught" \
  "PING" "$(ctrlc VALUE_DIFF)"
assert_eq "…and it is not reported as missing, which would be the wrong diagnosis" "" "$(ctrlc MISSING)"

echo "== 6. the wire vocabulary is UPSTREAM'S in the arms too, not only in the enum"

# A declared enum nobody sends is a vocabulary, not a protocol. Every member below is asserted to
# have been OBSERVED on the wire by the arm run, through the fields the arms record.
HANDSHAKE_HASH="$(m33_arm handshake.providerVerificationHash)"
WALLET_HASH="$(m33_arm handshake.walletVerificationHash)"
SESSION="$(m33_arm handshake.sessionEstablished.sessionId)"
DISCOVERED="$(m33_arm handshake.walletInfo.id)"
DISCLOSED="$(m33_arm handshake.walletSideDisclosure.description)"
DISCONNECTED="$(m33_arm handshake.disconnect.after)"
m33_absent "handshake.providerVerificationHash=$HANDSHAKE_HASH" \
  "handshake.walletVerificationHash=$WALLET_HASH" \
  "handshake.sessionEstablished.sessionId=$SESSION" \
  "handshake.walletInfo.id=$DISCOVERED" \
  "handshake.walletSideDisclosure.description=$DISCLOSED" \
  "handshake.disconnect.after=$DISCONNECTED"

assert_eq "WALLET_READY reached the provider — otherwise connect() could not have proceeded" \
  "m33-null-wallet" "$DISCOVERED"
assert_ge "DISCOVERY/DISCOVERY_RESPONSE completed: a session id exists" 30 "${#SESSION}"
assert_ge "KEY_EXCHANGE completed: a 32-byte verification hash was derived" 64 "${#HANDSHAKE_HASH}"
# THE EXPECTED STRING IS READ OUT OF `orchestration/src/disclosure.ts`, NOT TYPED HERE.
# `CAMPAIGN-BRIEF.md`: "if a check needs a number that also exists in the thing under test, take it
# FROM the thing under test" — and the derivation is asserted to have found something, because
# `disclosure-line` prints `UNREADABLE` rather than empty when it cannot.
DECLARED_LINE="$(python3 "$VERIFY_DIR/_m33_protocol.py" disclosure-line "$REPO_ROOT/orchestration/src/disclosure.ts")"
assert_false "§8.4's line was READ from disclosure.ts, not guessed" \
  str_has_sub "$DECLARED_LINE" 'UNREADABLE'
assert_ge "…and it is a real sentence" 120 "${#DECLARED_LINE}"
assert_eq "SECURE_MESSAGE/SECURE_RESPONSE carried §8.4's disclosure to the wallet side" \
  "$DECLARED_LINE" "$DISCLOSED"
assert_eq "DISCONNECT ended the session" "true" "$DISCONNECTED"

m33_finish
