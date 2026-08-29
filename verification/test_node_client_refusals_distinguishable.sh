#!/usr/bin/env bash
# test_node_client_refusals_distinguishable — L0 (Aztec-Live-Chain-Replay).
#
# "Unreachable node, absent transaction, and version mismatch give three distinct named refusals.
#  Control: a successful fetch returns."
#
# WHY THE THREE MUST NOT COLLAPSE. "Not found" and "the node is unreachable" are the pair the
# milestone names, and they are the pair a caller most needs kept apart: a replay that reports
# "no such transaction" when the truth is "the network is down" sends the next reader after a
# transaction hash that is perfectly good, and one that reports "unreachable" for a hash that was
# never on this chain sends them after the network. The third — a protocol-version mismatch — is
# worse than either, because every answer LOOKS fine and means something else.
#
# SO DISTINCTNESS IS MEASURED IN BOTH DIRECTIONS, which is the part a weaker check would skip.
# It is not enough that each arm throws its own class; each arm must also NOT throw either of the
# other two. Section 5 asserts all nine cells of that 3x3, so a refusal that widened to catch
# everything would fail even though every "the right class was thrown" assertion still passed.
#
# THE CONTROL IS A SUCCESSFUL FETCH, and it is stronger than "one call returned": the same client,
# against a node with the pinned headers, fetches a transaction through the same `fetchSettledTx`
# that produces the not-found refusal, and gets a `Tx`. Without it, every arm here is satisfied by
# a client that throws at everything — the campaign's most-repeated defect, in the shape it takes
# when the subject is a refusal.
#
# EVERY ARM IS EXECUTED, over a real HTTP server built out of upstream's own JSON-RPC server and
# upstream's own versioning middleware. Nothing here is read out of the source.
#
# Run: just verify-l0-refusals

set -uo pipefail
TEST_NAME="test_node_client_refusals_distinguishable"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l0_node_client.sh"

echo "== $TEST_NAME"
l0_prepare

PROBE="$(l0_imports)
$(cat <<'EOS'

import { TxHash } from '@aztec/stdlib/tx/tx-hash';
import { Fr } from '@aztec/foundation/curves/bn254';

const hash = TxHash.fromField(new Fr(24301n));
const WRONG_ROOT = '0x' + 'de'.repeat(32);

// `classify` reduces a thrown value to ONE word, and the word is the error's own `kind`
// discriminant rather than a guess from its message. A value that is not one of ours reads
// `foreign:<constructor>`, and "nothing was thrown" reads `returned` — three answers that cannot
// be confused with each other, which is the property the whole check is about.
const classify = async (label, thunk) => {
  try {
    const value = await thunk();
    line(`${label}.outcome`, 'returned');
    line(`${label}.value`, value === undefined ? 'undefined' : typeof value);
    return { outcome: 'returned' };
  } catch (e) {
    const kind = e?.kind ?? `foreign:${e?.constructor?.name ?? 'unknown'}`;
    line(`${label}.outcome`, kind);
    line(`${label}.class`, e?.constructor?.name ?? 'none');
    return { outcome: kind, error: e };
  }
};

// ---- THE CONTROL: a node that is up, on the pinned protocol -----------------
const good = await startFakeNode({ versions: PINNED_PROTOCOL_VERSION });
const okClient = createReplayNodeClient({ url: good.url });

const control = await classify('control', () => okClient.fetchSettledTx(hash));
line('control.gotTx', control.outcome === 'returned' ? 'yes' : 'no');
line('control.blockNumber', await okClient.getBlockNumber());
const headers = await okClient.assertProtocolVersion();
line('control.headerFields', Object.keys(headers).sort().join(','));
line('control.headerMatchesPin',
     headers.l2CircuitsVkTreeRoot === PINNED_PROTOCOL_VERSION.l2CircuitsVkTreeRoot ? 'yes' : 'no');
line('control.nodeWasAsked', good.calls.length);

// ---- ARM 1: the node is not there ------------------------------------------
// The port is TAKEN AND RELEASED rather than picked, so this arm cannot fail on somebody else's
// machine for a reason that has nothing to do with its subject.
const deadPort = await unusedPort();
const deadUrl = `http://127.0.0.1:${deadPort}`;
const dead = createReplayNodeClient({ url: deadUrl });
const unreachable = await classify('unreachable', () => dead.fetchSettledTx(hash));
line('unreachable.namesUrl', unreachable.error?.url === deadUrl ? 'yes' : 'no');
line('unreachable.hasCause', unreachable.error?.cause !== undefined ? 'yes' : 'no');
// …and the same failure through a PLAIN permitted method, not only through the fetch helper, so
// the classification is the client's and not one helper's.
const unreachablePlain = await classify('unreachablePlain', () => dead.getBlockNumber());

// ---- ARM 2: the node is there and does not have it -------------------------
const absentNode = await startFakeNode({
  versions: PINNED_PROTOCOL_VERSION,
  handlers: { getTxByHash: () => undefined, getTxEffect: () => undefined },
});
const absentClient = createReplayNodeClient({ url: absentNode.url });
const absent = await classify('absent', () => absentClient.fetchSettledTx(hash));
line('absent.namesHash', absent.error?.txHash === hash.toString() ? 'yes' : 'no');
line('absent.namesMethod', absent.error?.method ?? 'none');
line('absent.namesUrl', absent.error?.url === absentNode.url ? 'yes' : 'no');
const absentEffect = await classify('absentEffect', () => absentClient.fetchSettledTxEffect(hash));
line('absentEffect.namesMethod', absentEffect.error?.method ?? 'none');
// THE NODE WAS REALLY ASKED. Without this, "not found" is indistinguishable from a client that
// answered locally and never went near the node — which is the shape that would also satisfy the
// unreachable arm.
line('absent.nodeWasAsked', absentNode.calls.filter((c) => c === 'getTxByHash').length);
// …and the raw pass-through still answers `undefined` rather than throwing, which is upstream's
// signature unchanged. The refusal is the ADAPTER's, at a named seam, not a rewrite of AztecNode.
const passthrough = await classify('passthrough', () => absentClient.getTxByHash(hash));

// ---- ARM 3: the node is there and is not speaking our protocol -------------
const wrongNode = await startFakeNode({
  versions: { ...PINNED_PROTOCOL_VERSION, l2CircuitsVkTreeRoot: WRONG_ROOT },
});
const wrongClient = createReplayNodeClient({ url: wrongNode.url });
const mismatch = await classify('mismatch', () => wrongClient.fetchSettledTx(hash));
line('mismatch.field', mismatch.error?.field ?? 'none');
line('mismatch.expected', mismatch.error?.expected ?? 'none');
line('mismatch.actual', mismatch.error?.actual ?? 'none');
line('mismatch.namesUrl', mismatch.error?.url === wrongNode.url ? 'yes' : 'no');
line('mismatch.causeIsUpstreams',
     mismatch.error?.cause?.name === 'ComponentsVersionsError' ? 'yes' : 'no');
// The mismatch fires on a PLAIN call too — upstream's handler runs on every response, so this is
// not something a caller has to remember to ask for.
const mismatchPlain = await classify('mismatchPlain', () => wrongClient.getBlockNumber());
// …and it fires on the OTHER pinned field as well, so "the check works" is not a statement about
// one field. A conjunction needs a negative case per conjunct.
const wrongOther = await startFakeNode({
  versions: { ...PINNED_PROTOCOL_VERSION, l2ProtocolContractsHash: WRONG_ROOT },
});
const otherMismatch = await classify('mismatchOther',
  () => createReplayNodeClient({ url: wrongOther.url }).getBlockNumber());
line('mismatchOther.field', otherMismatch.error?.field ?? 'none');

// ---- ARM 4: a node that will not say what protocol it speaks ---------------
// Upstream's per-call handler SKIPS an absent header, so this node passes every ordinary call.
// That is upstream's semantics and it is left alone; `assertProtocolVersion` is the strict one.
// Both halves are measured, because the limitation is worth stating rather than discovering.
const silentNode = await startFakeNode({ versions: {} });
const silentClient = createReplayNodeClient({ url: silentNode.url });
const silentCall = await classify('silentCall', () => silentClient.getBlockNumber());
const silentAssert = await classify('silentAssert', () => silentClient.assertProtocolVersion());
line('silentAssert.field', silentAssert.error?.field ?? 'none');

// ---- ARM 5: reachable, and answering nonsense ------------------------------
// An HTTP endpoint that is not a node at all. It must read as "unreachable" and not as "not
// found": nothing was found or not found, because no JSON-RPC answer came back.
const http = await import('node:http');
const junk = http.createServer((_req, res) => { res.writeHead(500); res.end('not a node'); });
await new Promise((r) => junk.listen(0, '127.0.0.1', r));
const junkUrl = `http://127.0.0.1:${junk.address().port}`;
const junkResult = await classify('junk', () => createReplayNodeClient({ url: junkUrl }).getBlockNumber());
line('junk.namesUrl', junkResult.error?.url === junkUrl ? 'yes' : 'no');
await new Promise((r) => junk.close(r));

// ---- THE 3x3: each arm throws its own class and NEITHER of the other two ----
const arms = { unreachable, absent, mismatch };
const kinds = {
  unreachable: 'replay-node-unreachable',
  absent: 'replay-transaction-not-found',
  mismatch: 'replay-protocol-version-mismatch',
};
const ctors = { unreachable: NodeUnreachable, absent: SettledTransactionNotFound, mismatch: ProtocolVersionMismatch };
let diagonal = 0, offDiagonal = 0;
for (const [arm, result] of Object.entries(arms)) {
  for (const [name, ctor] of Object.entries(ctors)) {
    const isInstance = result.error instanceof ctor;
    if (arm === name) { if (isInstance && result.outcome === kinds[name]) { diagonal += 1; } }
    else if (isInstance) { offDiagonal += 1; }
  }
}
line('matrix.diagonal', diagonal);
line('matrix.offDiagonal', offDiagonal);
line('matrix.distinctKinds', new Set(Object.values(arms).map((a) => a.outcome)).size);
// The four classes are four classes, not aliases: no two of them are the same constructor.
line('matrix.distinctCtors', new Set([NodeUnreachable, SettledTransactionNotFound,
                                      ProtocolVersionMismatch, ReplayNodeSurfaceExceeded]).size);
// …and every one of them is an Error, so a caller's `catch (e)` sees a stack.
line('matrix.allErrors', [NodeUnreachable, SettledTransactionNotFound, ProtocolVersionMismatch,
                          ReplayNodeSurfaceExceeded]
  .every((c) => Object.create(c.prototype) instanceof Error) ? 'yes' : 'no');

await good.close();
await absentNode.close();
await wrongNode.close();
await wrongOther.close();
await silentNode.close();
line('l0.done', 1);
EOS
)"

OUT="$L0_WORK/probes/refusals.out"
l0_run_probe refusals "$PROBE" "$OUT"
f() { l0_field "$OUT" "$1"; }

# ---------------------------------------------------------------------------
echo "== 1. THE CONTROL: a successful fetch returns"
#
# First, and deliberately first: every assertion below it is about a throw, and a client that threw
# at everything would satisfy all of them.
# ---------------------------------------------------------------------------
assert_eq "a settled transaction is fetched from a node that has it" "returned" "$(f control.outcome)"
assert_eq "…and what comes back is an object, not undefined" "object" "$(f control.value)"
assert_eq "…so the fetch helper that produces 'not found' can also produce a transaction" "yes" \
  "$(f control.gotTx)"
assert_eq "…and an ordinary permitted call answers too" "174" "$(f control.blockNumber)"
assert_ge "…and the node was really asked" 2 "$(f control.nodeWasAsked)"

# THE VERSION MECHANISM IS LIVE, not merely non-failing. If the node sent no headers, upstream's
# handler would skip every field and the mismatch arm below would be measuring nothing.
assert_eq "the node's protocol-version headers were observed, both pinned fields" \
  "l2CircuitsVkTreeRoot,l2ProtocolContractsHash" "$(f control.headerFields)"
assert_eq "…and they are the values pins.json pins" "yes" "$(f control.headerMatchesPin)"

# ---------------------------------------------------------------------------
echo "== 2. an unreachable node"
# ---------------------------------------------------------------------------
assert_eq "a node that is not listening produces the unreachable refusal" \
  "replay-node-unreachable" "$(f unreachable.outcome)"
assert_eq "…by its own class" "NodeUnreachable" "$(f unreachable.class)"
assert_eq "…naming the url it could not reach" "yes" "$(f unreachable.namesUrl)"
assert_eq "…and carrying the underlying transport failure as its cause" "yes" \
  "$(f unreachable.hasCause)"
assert_eq "…and the same through a plain permitted method, so it is the client's classification" \
  "replay-node-unreachable" "$(f unreachablePlain.outcome)"
assert_eq "an HTTP endpoint that is not a node reads as unreachable, not as 'not found'" \
  "replay-node-unreachable" "$(f junk.outcome)"
assert_eq "…and names the url" "yes" "$(f junk.namesUrl)"

# ---------------------------------------------------------------------------
echo "== 3. an absent transaction"
# ---------------------------------------------------------------------------
assert_eq "a hash the node does not have produces the not-found refusal" \
  "replay-transaction-not-found" "$(f absent.outcome)"
assert_eq "…by its own class" "SettledTransactionNotFound" "$(f absent.class)"
assert_eq "…naming the hash" "yes" "$(f absent.namesHash)"
assert_eq "…naming the method that asked" "getTxByHash" "$(f absent.namesMethod)"
assert_eq "…and the node it asked" "yes" "$(f absent.namesUrl)"
assert_ge "…and the node really was asked, so this is its answer and not a local one" 1 \
  "$(f absent.nodeWasAsked)"
assert_eq "the effect lookup refuses the same way and names ITS method" \
  "replay-transaction-not-found" "$(f absentEffect.outcome)"
assert_eq "…so the two lookups are distinguishable from each other" "getTxEffect" \
  "$(f absentEffect.namesMethod)"
# The pass-through keeps upstream's signature. The refusal is the adapter's, at a named seam.
assert_eq "the raw getTxByHash still answers undefined, which is upstream's signature unchanged" \
  "returned" "$(f passthrough.outcome)"
assert_eq "…and that answer is undefined" "undefined" "$(f passthrough.value)"

# ---------------------------------------------------------------------------
echo "== 4. a protocol-version mismatch"
# ---------------------------------------------------------------------------
assert_eq "a node on a different protocol produces the version refusal" \
  "replay-protocol-version-mismatch" "$(f mismatch.outcome)"
assert_eq "…by its own class" "ProtocolVersionMismatch" "$(f mismatch.class)"
assert_eq "…naming the field that disagrees" "l2CircuitsVkTreeRoot" "$(f mismatch.field)"
assert_eq "…the value pins.json pins" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["live_chain"]["protocol_version"]["l2CircuitsVkTreeRoot"])' "$REPO_ROOT/pins.json")" \
  "$(f mismatch.expected)"
assert_eq "…and what the node actually said" "0x$(printf 'de%.0s' $(seq 32))" "$(f mismatch.actual)"
assert_eq "…and the node it was talking to" "yes" "$(f mismatch.namesUrl)"
assert_eq "…with upstream's own ComponentsVersionsError as its cause" "yes" \
  "$(f mismatch.causeIsUpstreams)"
assert_eq "the mismatch fires on an ordinary call too, not only on the fetch helper" \
  "replay-protocol-version-mismatch" "$(f mismatchPlain.outcome)"
# A NEGATIVE CASE PER CONJUNCT: the pin has two fields and both must be able to fail.
assert_eq "the OTHER pinned field can fail too" "replay-protocol-version-mismatch" \
  "$(f mismatchOther.outcome)"
assert_eq "…and it is named" "l2ProtocolContractsHash" "$(f mismatchOther.field)"

echo "== 5. a node that will not say what protocol it speaks"
# Stated as a measurement rather than left to be discovered: upstream's per-call handler skips an
# absent header, so an ordinary call succeeds; `assertProtocolVersion` is strict and refuses.
assert_eq "an ordinary call to a node that sends no version headers succeeds — upstream's semantics" \
  "returned" "$(f silentCall.outcome)"
assert_eq "…while assertProtocolVersion refuses it, because an unverifiable version is not a verified one" \
  "replay-protocol-version-mismatch" "$(f silentAssert.outcome)"
assert_eq "…naming the absence rather than inventing a field" "absent" "$(f silentAssert.field)"

# ---------------------------------------------------------------------------
echo "== 6. the 3x3: each refusal is itself and is NEITHER of the other two"
#
# This is the half that says the three do not collapse. Every "the right class was thrown"
# assertion above would still pass if one class had widened to catch everything.
# ---------------------------------------------------------------------------
assert_eq "each of the three arms threw its own class" "3" "$(f matrix.diagonal)"
assert_eq "…and not one of them is an instance of either of the other two" "0" \
  "$(f matrix.offDiagonal)"
assert_eq "…so the three outcomes are three distinct kinds" "3" "$(f matrix.distinctKinds)"
assert_eq "the four refusal classes are four classes, not aliases" "4" "$(f matrix.distinctCtors)"
assert_eq "…and every one of them is an Error, so a caller's catch sees a stack" "yes" \
  "$(f matrix.allErrors)"

finish
