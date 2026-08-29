#!/usr/bin/env bash
# e2e_discovery_keyexchange_session
#
# M33 verification: "full handshake against the null wallet. Control: a wrong appId/walletId is
# rejected."
#
# ===========================================================================================
# THE FIVE STAGES, AND WHAT WOULD MAKE EACH ONE A LIE
# ===========================================================================================
#
#   READY         the wallet announced itself           — a provider that skipped it would time out
#   DISCOVERY     the wallet answered, after approval   — a provider that assumed a wallet is there
#   KEY EXCHANGE  ECDH P-256 + HKDF -> AES-256-GCM      — the hard one, below
#   SESSION       a real call crossed, encrypted        — and came back refused BY NAME
#   DISCONNECT    the session ended, and stayed ended   — a call after it is refused, not pending
#
# **THE KEY EXCHANGE IS THE ONE THAT CAN LIE QUIETLY.** Two ends that never derived a shared secret
# still "work" if either end trusts the other's word for it. What makes it a measurement is that the
# verification hash is computed INDEPENDENTLY at both ends, from their own halves of the ECDH, and
# never crosses in a form either end takes on trust. So the assertion is that the two hashes are
# EQUAL — and the control that makes that equality mean something is a SECOND session, whose two
# hashes are equal to each other and DIFFERENT from the first pair. Without that,
# `provider === wallet` is satisfied by two constants.
#
# ===========================================================================================
# THE TWO CONTROLS THE MILESTONE NAMES, AND THE MUTATION DISCIPLINE BEHIND THEM
# ===========================================================================================
#
# A wrong `appId` and a wrong `walletId` are the two identity bindings the protocol has, and neither
# can be produced through the public surface — the genuine ends fill both fields correctly. So each
# control moves the binding on one side and READS THE FIELD BACK to prove the move took.
# `CAMPAIGN-BRIEF.md`'s fourth mutation state is *"a mutation that never applied and reported its
# predicted number anyway"*, so `mutationApplied` is asserted BEFORE the outcome is, and a control
# whose mutation did not apply fails on the mutation rather than passing on the outcome.
#
# AND THE TWO CONTROLS FAIL DIFFERENTLY, WHICH IS THE POINT:
#   * the wrong `appId` is refused by the HANDLER, which answers with a named error, so the call
#     REJECTS with the mismatch named;
#   * the wrong `walletId` is refused by the PROVIDER, which drops the response, so the call NEVER
#     SETTLES — and the evidence is the provider's refusal ledger, not the promise.
# A check that expected the same shape from both would be asserting a symmetry the protocol does not
# have.
#
# Run: just verify-m33-handshake

TEST_NAME="e2e_discovery_keyexchange_session"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m33_wallet.sh"

m33_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m33_require_arms

echo "== 0. the arm report carries what this check reads"

WALLET_ID="$(m33_arm handshake.walletInfo.id)"
WALLET_NAME="$(m33_arm handshake.walletInfo.name)"
P_HASH="$(m33_arm handshake.providerVerificationHash)"
W_HASH="$(m33_arm handshake.walletVerificationHash)"
HASHES_EQUAL="$(m33_arm handshake.hashesEqual)"
SESSION_ID="$(m33_arm handshake.sessionEstablished.sessionId)"
SESSION_APP="$(m33_arm handshake.sessionEstablished.appId)"
PENDING="$(m33_arm handshake.pendingDiscoveries)"
ELAPSED="$(m33_arm handshake.elapsedMs)"
m33_absent "handshake.walletInfo.id=$WALLET_ID" "handshake.walletInfo.name=$WALLET_NAME" \
  "handshake.providerVerificationHash=$P_HASH" "handshake.walletVerificationHash=$W_HASH" \
  "handshake.hashesEqual=$HASHES_EQUAL" "handshake.sessionEstablished.sessionId=$SESSION_ID" \
  "handshake.sessionEstablished.appId=$SESSION_APP" "handshake.pendingDiscoveries=$PENDING" \
  "handshake.elapsedMs=$ELAPSED"

echo "== 1. READY and DISCOVERY"

# The provider's first wait is for WALLET_READY, and it is bounded; reaching discovery at all is
# what says the announcement arrived.
assert_true "the wallet announced itself and answered discovery" \
  str_has_sub "$PENDING" '"appId":"m33-app"'
assert_eq "…and the wallet the provider discovered is the one that answered" \
  "m33-null-wallet" "$WALLET_ID"
assert_eq "…with the name it announced" "M33 null wallet" "$WALLET_NAME"
assert_eq "…and the session the WALLET established is bound to the appId DISCOVERY carried" \
  "m33-app" "$SESSION_APP"
# The requestId is the sessionId: the same identifier threads discovery, key exchange and every
# secure message, which is what makes the three stages one session rather than three exchanges.
assert_true "…and the discovery requestId IS the session id" \
  str_has_sub "$PENDING" "\"requestId\":\"$SESSION_ID\""
# THE ELAPSED TIME IS A NOTE AND NOT AN ASSERTION. `assert_ge … 0 "$ELAPSED"` was written here
# first and it is `CAMPAIGN-BRIEF.md`'s purest family: a wall-clock duration is never negative, so
# the assertion could not fail. What CAN be asserted about "every wait is bounded" is the bounds
# themselves, read out of the BUILT bundle — a bound of zero is no bound at all, and the ordering
# is a design decision (`KEY_EXCHANGE_TIMEOUT_MS` is deliberately the shortest, because a long
# window there helps a MITM).
note "the handshake took ${ELAPSED} ms"
READY_MS="$(m33_bundle_value 'm.READY_TIMEOUT_MS')"
DISC_MS="$(m33_bundle_value 'm.DISCOVERY_TIMEOUT_MS')"
KX_MS="$(m33_bundle_value 'm.KEY_EXCHANGE_TIMEOUT_MS')"
assert_ge "the bundle declares a positive readiness bound" 1 "$READY_MS"
assert_ge "…a positive discovery bound" 1 "$DISC_MS"
assert_ge "…and a positive key-exchange bound" 1 "$KX_MS"
assert_true "…and key exchange is the SHORTEST of the three, which is the MITM decision" \
  test "$KX_MS" -lt "$READY_MS" -a "$KX_MS" -lt "$DISC_MS"
assert_true "…while discovery is the longest, because it may need a human at the wallet end" \
  test "$DISC_MS" -gt "$READY_MS"

echo "== 2. KEY EXCHANGE — both ends derived the same secret, independently"

assert_eq "the two verification hashes agree" "true" "$HASHES_EQUAL"
assert_eq "…and they are the same string, compared here rather than taken from the arm's boolean" \
  "$P_HASH" "$W_HASH"
assert_eq "…and it is a 32-byte hash, not an empty string agreeing with an empty string" \
  "64" "${#P_HASH}"
assert_true "…of hex" str_has_re "$P_HASH" '^[0-9a-f]{64}$'

# THE CONTROL THAT MAKES THE EQUALITY A MEASUREMENT. Two further sessions, each with its own
# ephemeral ECDH pair: equal within a session, different across sessions. Two constants would pass
# the equality above and fail this.
S0P="$(m33_arm verificationHash.sessions.0.provider)"
S0W="$(m33_arm verificationHash.sessions.0.wallet)"
S1P="$(m33_arm verificationHash.sessions.1.provider)"
S1W="$(m33_arm verificationHash.sessions.1.wallet)"
ACROSS="$(m33_arm verificationHash.equalAcrossSessions)"
m33_absent "verificationHash.sessions.0.provider=$S0P" "verificationHash.sessions.0.wallet=$S0W" \
  "verificationHash.sessions.1.provider=$S1P" "verificationHash.sessions.1.wallet=$S1W" \
  "verificationHash.equalAcrossSessions=$ACROSS"
assert_eq "session 0's two ends agree" "$S0P" "$S0W"
assert_eq "session 1's two ends agree" "$S1P" "$S1W"
assert_eq "…and the two SESSIONS do not, so the hash is derived and not a constant" "false" "$ACROSS"
assert_false "…demonstrated on the strings themselves" test "$S0P" = "$S1P"
assert_ge "…both of them real hashes" 64 "${#S0P}"
assert_ge "…both of them real hashes" 64 "${#S1P}"

echo "== 3. SESSION — a call crossed the encrypted channel and came back"

CALL_ERR="$(m33_arm handshake.chainInfoCall.rejected.message)"
DISCLOSED="$(m33_arm handshake.walletSideDisclosure.description)"
DISCLOSED_NAME="$(m33_arm handshake.walletSideDisclosure.name)"
DISCLOSED_VERSION="$(m33_arm handshake.walletSideDisclosure.version)"
m33_absent "handshake.chainInfoCall.rejected.message=$CALL_ERR" \
  "handshake.walletSideDisclosure.description=$DISCLOSED" \
  "handshake.walletSideDisclosure.name=$DISCLOSED_NAME" \
  "handshake.walletSideDisclosure.version=$DISCLOSED_VERSION"

assert_true "a wallet call crossed the session and came back refused BY NAME" \
  str_has_sub "$CALL_ERR" "WalletNotAttached"
assert_true "…naming the method" str_has_sub "$CALL_ERR" "'getChainInfo'"
# THE ROUND TRIP IS WHAT IS BEING ASSERTED, and the refusal is the evidence: a message that never
# reached the wallet would have hung and been reported as an ArmTimeout instead.
assert_false "…rather than timing out, which is what a channel that did not carry would do" \
  str_has_sub "$CALL_ERR" "ArmTimeout"

echo "== 4. §8.4 CROSSED THE BOUNDARY, in upstream's own field"

DECLARED_LINE="$(python3 "$VERIFY_DIR/_m33_protocol.py" disclosure-line "$REPO_ROOT/orchestration/src/disclosure.ts")"
assert_false "§8.4's line was READ from disclosure.ts rather than typed here" \
  str_has_sub "$DECLARED_LINE" 'UNREADABLE'
assert_eq "the wallet can report the disclosure it was told, verbatim" "$DECLARED_LINE" "$DISCLOSED"
assert_true "…and it says the chain is simulated" str_has_sub "$DISCLOSED" "SIMULATED"
assert_true "…and that it produces no proofs" str_has_sub "$DISCLOSED" "NO PROOFS"
assert_eq "…and the app name the wallet recorded is this runtime's" \
  "$(m33_arm handshake.simulatedAppName)" "$DISCLOSED_NAME"
assert_eq "…at the pinned protocol version, which pins.json is the authority for" \
  "$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["npm"]["deletion_era"]["version"])' "$REPO_ROOT/pins.json")" \
  "$DISCLOSED_VERSION"

# The manifest is upstream's `AppCapabilities` shape, not ours: version literal '1.0', a `metadata`
# object, a `capabilities` array. A paraphrase would not be refused by `AppCapabilitiesSchema`,
# which is what parsed it on the wallet side before the dispatch that refused.
MANIFEST="$(m33_arm handshake.manifestSent)"
m33_absent "handshake.manifestSent=$MANIFEST"
assert_true "the manifest is upstream's AppCapabilities shape — version '1.0'" \
  str_has_sub "$MANIFEST" '"version":"1.0"'
assert_true "…with a metadata object" str_has_sub "$MANIFEST" '"metadata"'
assert_true "…and a capabilities array, empty because M33 asks for nothing" \
  str_has_sub "$MANIFEST" '"capabilities":[]'

echo "== 5. DISCONNECT — and a call afterwards is refused rather than left pending"

BEFORE="$(m33_arm handshake.disconnect.before)"
AFTER="$(m33_arm handshake.disconnect.after)"
POST_CALL="$(m33_arm handshake.disconnect.call.rejected.name)"
POST_MSG="$(m33_arm handshake.disconnect.call.rejected.message)"
m33_absent "handshake.disconnect.before=$BEFORE" "handshake.disconnect.after=$AFTER" \
  "handshake.disconnect.call.rejected.name=$POST_CALL" \
  "handshake.disconnect.call.rejected.message=$POST_MSG"
assert_eq "the session was live before disconnect()" "false" "$BEFORE"
assert_eq "…and closed after it" "true" "$AFTER"
assert_eq "…and a call made afterwards is refused BY NAME" "WalletDisconnected" "$POST_CALL"
assert_true "…saying so" str_has_sub "$POST_MSG" "the channel is closed"

echo "== 6. CONTROL A — a SECURE_MESSAGE with the wrong appId is refused, and the refusal names both"

A_APPLIED="$(m33_arm wrongAppId.mutationApplied)"
A_BOUND="$(m33_arm wrongAppId.boundAppId)"
A_GOOD="$(m33_arm wrongAppId.good.rejected.message)"
A_BAD="$(m33_arm wrongAppId.bad.rejected.message)"
A_REFUSALS="$(m33_arm wrongAppId.handlerRefusals)"
A_SESSION_APP="$(m33_arm wrongAppId.sessionAppId)"
m33_absent "wrongAppId.mutationApplied=$A_APPLIED" "wrongAppId.boundAppId=$A_BOUND" \
  "wrongAppId.good.rejected.message=$A_GOOD" "wrongAppId.bad.rejected.message=$A_BAD" \
  "wrongAppId.handlerRefusals=$A_REFUSALS" "wrongAppId.sessionAppId=$A_SESSION_APP"

# THE MUTATION FIRST. A control whose mutation did not apply must fail on the mutation.
assert_eq "the control's mutation APPLIED — read back from the field, not predicted" "true" "$A_APPLIED"
assert_eq "…and the session had been bound to the right appId before it" "the-right-app" "$A_BOUND"
assert_eq "…which is still what the WALLET's session says" '["the-right-app"]' "$A_SESSION_APP"

# The pair. The good call reached the wallet (its refusal is the wallet's); the bad call did not.
assert_true "before the mutation the call reached the WALLET and was refused by the null wallet" \
  str_has_sub "$A_GOOD" "WalletNotAttached"
assert_false "…after it, the call never reaches the wallet" str_has_sub "$A_BAD" "WalletNotAttached"
assert_true "…it is refused at the BOUNDARY, naming the mismatch" str_has_sub "$A_BAD" "appId mismatch"
assert_true "…naming what the session is bound to" str_has_sub "$A_BAD" "the-right-app"
assert_true "…and what arrived" str_has_sub "$A_BAD" "the-wrong-app"
assert_true "…and the handler's own ledger records it as an app-id-mismatch" \
  str_has_sub "$A_REFUSALS" '"kind":"app-id-mismatch"'
assert_eq "…exactly once, so the good call did not also trip it" "1" \
  "$(python3 -c '
import json, sys
print(len(json.loads(sys.argv[1])))' "$A_REFUSALS")"

echo "== 7. CONTROL B — a SECURE_RESPONSE with the wrong walletId is dropped, and NEVER SETTLES"

B_APPLIED="$(m33_arm wrongWalletId.mutationApplied)"
B_BOUND="$(m33_arm wrongWalletId.boundWalletId)"
B_GOOD="$(m33_arm wrongWalletId.good.rejected.message)"
B_TIMEOUT="$(m33_arm wrongWalletId.outcome.timedOut.message)"
B_ADDED="$(m33_arm wrongWalletId.refusalsAdded)"
B_REFUSALS="$(m33_arm wrongWalletId.providerRefusals)"
m33_absent "wrongWalletId.mutationApplied=$B_APPLIED" "wrongWalletId.boundWalletId=$B_BOUND" \
  "wrongWalletId.good.rejected.message=$B_GOOD" "wrongWalletId.outcome.timedOut.message=$B_TIMEOUT" \
  "wrongWalletId.refusalsAdded=$B_ADDED" "wrongWalletId.providerRefusals=$B_REFUSALS"

assert_eq "the control's mutation APPLIED" "true" "$B_APPLIED"
assert_eq "…and the session had been bound to the discovered walletId" "m33-null-wallet" "$B_BOUND"
assert_true "before it, the call round-tripped and was refused by the null wallet" \
  str_has_sub "$B_GOOD" "WalletNotAttached"
# THE SHAPE IS DIFFERENT FROM CONTROL A ON PURPOSE: a dropped response leaves the promise pending.
assert_true "after it, the call NEVER SETTLES — the response is dropped, not answered" \
  str_has_sub "$B_TIMEOUT" "ArmTimeout"
assert_eq "…and the provider recorded exactly one refusal for it" "1" "$B_ADDED"
assert_true "…as a wrong-wallet-id" str_has_sub "$B_REFUSALS" '"kind":"wrong-wallet-id"'
assert_true "…naming the id that arrived" str_has_sub "$B_REFUSALS" "m33-null-wallet"
assert_true "…and the one the session expects" str_has_sub "$B_REFUSALS" "somebody-else"

echo "== 8. CONTROL C — key exchange without an approved discovery is refused, and the wait is BOUNDED"

C_OUT="$(m33_arm noApproval.outcome.rejected.name)"
C_MSG="$(m33_arm noApproval.outcome.rejected.message)"
C_PENDING="$(m33_arm noApproval.pendingAtWallet)"
C_ACTIVE="$(m33_arm noApproval.activeAtWallet)"
m33_absent "noApproval.outcome.rejected.name=$C_OUT" "noApproval.outcome.rejected.message=$C_MSG" \
  "noApproval.pendingAtWallet=$C_PENDING" "noApproval.activeAtWallet=$C_ACTIVE"

# THE HANG ARM. `CAMPAIGN-BRIEF.md`: "every subprocess a check waits on needs a bound, and exceeding
# it must be a NAMED failure rather than a hang." A wallet that never approves is the protocol's own
# hang, and this is the arm that proves the bound fires and names its step.
assert_eq "an un-approved discovery does not hang: it fails by NAME" \
  "WalletHandshakeTimeout" "$C_OUT"
assert_true "…naming the STEP that timed out" str_has_sub "$C_MSG" "'discovery'"
assert_true "…and the bound it exceeded" str_has_sub "$C_MSG" "within 2000 ms"
assert_true "…while the request is still sitting at the wallet, un-approved" \
  str_has_sub "$C_PENDING" '"status":"pending"'
assert_eq "…and NO session was established" "0" "$C_ACTIVE"

m33_finish
