#!/usr/bin/env bash
# verify_client_uses_upstream_schema — L0 (Aztec-Live-Chain-Replay).
#
# "The request and response types are upstream's, re-derived from the anchor and compared as a set.
#  Control: a fabricated method name is rejected."
#
# WHAT "UPSTREAM'S TYPES" HAS TO MEAN TO BE CHECKABLE. A grep for `AztecNodeApiSchema` in our own
# source would be a citation counted as a dependency — the campaign's own words, and a defect it
# has shipped: a fixed-string search for a function's NAME, used to mean "this calls it", which
# prose satisfies. So this check never greps for the schema's name to establish that the schema is
# used. It measures four things the wire and the run can answer:
#
#   1. THE SET. `Object.keys(AztecNodeApiSchema)` at run time, out of the installed package,
#      against the method set derived from `export interface AztecNode` AT THE PINNED ANCHOR —
#      compared as a set, with the one declared difference asserted by name in both directions.
#   2. THE WIRE. The method names the node actually receives are `aztec_<name>`, which is
#      `createAztecNodeClient`'s namespacing and not something a hand-rolled client would produce.
#   3. THE PARSE. A response that is valid JSON and invalid against upstream's schema is REFUSED,
#      and a valid one comes back as upstream's CLASS instances rather than plain objects. Only a
#      zod-validating client does both. The control is the same server answering correctly.
#   4. THE ABSENCE. `replay/src` declares no schema of its own — no zod, no hand-written JSON-RPC
#      envelope — asserted over the tree with a scanner that is shown to be able to find a planted
#      occurrence, because an absence measured by a needle that cannot match is this campaign's
#      most-repeated defect.
#
# AND THE PIN IS RE-DERIVED, THREE WAYS. `live_chain.protocol_version` in pins.json, the literals
# in `replay/src/pinned_protocol_version.ts`, and `protocolContractsHash` / `getVKTreeRoot()` out of
# the packages `npm.current` names — which is what upstream's own `getVersions(undefined)` builds
# the pair from. A figure nobody re-derives rots, and this one decides whether a node's bytecode
# means anything.
#
# Run: just verify-l0-schema

set -uo pipefail
TEST_NAME="verify_client_uses_upstream_schema"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l0_node_client.sh"

echo "== $TEST_NAME"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v git >/dev/null 2>&1 || die "git is required"
[ -d "$FORK_ROOT" ] || die "the upstream fork is not at $FORK_ROOT; the anchor half of this check
     cannot run without its object store. Only \`git show <anchor>:<path>\` is used."
l0_prepare

CPP="$(l0_cpp_anchor)"
IFACE_SRC="$(l0_at_anchor "$L0_NODE_IFACE_PATH")"
assert_ge "AztecNode's own declaration was read at the anchor" 700 \
  "$(printf '%s\n' "$IFACE_SRC" | grep -c . || true)"
ANCHOR_SET="$(l0_members_of "$(l0_anchor_node_members "$IFACE_SRC")")"
assert_eq "the anchor's method set was derived and is fifty-five" "55" \
  "$(printf '%s\n' "$ANCHOR_SET" | grep -c . || true)"

ANCHOR_JS="$(printf '%s\n' "$ANCHOR_SET" | sed "s/^/  '/; s/$/',/")"

PROBE="$(l0_imports)
$(cat <<EOS

const ANCHOR_METHODS = [
$ANCHOR_JS
];
EOS
)
$(cat <<'EOS'

import http from 'node:http';
import { AztecNodeApiSchema } from '@aztec/stdlib/interfaces/client';
import { schemaHasMethod } from '@aztec/foundation/schemas';
import { Tx } from '@aztec/stdlib/tx';
import { BlockHeader } from '@aztec/stdlib/tx';
import { TxHash } from '@aztec/stdlib/tx/tx-hash';
import { Fr } from '@aztec/foundation/curves/bn254';
import { protocolContractsHash } from '@aztec/protocol-contracts';
import { getVKTreeRoot } from '@aztec/noir-protocol-circuits-types/vk-tree';

// ---- 1. THE SET, three derivations ----------------------------------------
const pkg = Object.keys(AztecNodeApiSchema).sort();
const anchor = [...ANCHOR_METHODS].sort();
line('set.packageCount', pkg.length);
line('set.anchorCount', anchor.length);
const anchorOnly = anchor.filter((m) => !pkg.includes(m));
const packageOnly = pkg.filter((m) => !anchor.includes(m));
line('set.anchorOnly', anchorOnly.join(',') || 'none');
line('set.packageOnly', packageOnly.join(',') || 'none');
line('set.declaredAnchorOnly', [...ANCHOR_ONLY_METHODS].join(',') || 'none');
line('set.declaredPackageOnly', [...PACKAGE_ONLY_METHODS].join(',') || 'none');
line('set.identicalExceptDeclared',
     anchorOnly.join(',') === [...ANCHOR_ONLY_METHODS].join(',')
       && packageOnly.join(',') === [...PACKAGE_ONLY_METHODS].join(',') ? 'yes' : 'no');
// Our fourteen are a subset of upstream's schema — so every permitted method has a schema entry
// and none of them is a name we invented.
const notInSchema = REPLAY_NODE_SURFACE.filter((m) => !pkg.includes(m));
line('set.permittedNotInSchema', notInSchema.join(',') || 'none');
// THE CONTROL FOR THE SUBSET TEST: a fabricated name is NOT in upstream's schema, asked with the
// same predicate. Without it, `notInSchema === none` is satisfied by a membership test that says
// yes to everything.
line('set.fabricatedInSchema', pkg.includes('aFabricatedMethodName') ? 'yes' : 'no');
line('set.schemaHasReal', schemaHasMethod(AztecNodeApiSchema, 'getTxByHash') ? 'yes' : 'no');
line('set.schemaHasFabricated',
     schemaHasMethod(AztecNodeApiSchema, 'aFabricatedMethodName') ? 'yes' : 'no');

// ---- 2. THE WIRE ----------------------------------------------------------
const node = await startFakeNode({ versions: PINNED_PROTOCOL_VERSION });
const client = createReplayNodeClient({ url: node.url });
const hash = TxHash.fromField(new Fr(24301n));
const tx = await client.fetchSettledTx(hash);
const header = (await client.getBlockData(1)).header;
line('wire.methods', node.wireMethods.join(','));
line('wire.allNamespaced', node.wireMethods.every((m) => m.startsWith('aztec_')) ? 'yes' : 'no');
line('wire.count', node.wireMethods.length);

// ---- 3. THE PARSE: upstream's classes come back, not plain objects ---------
// A hand-rolled client returns whatever `JSON.parse` produced. These are class instances only
// because upstream's zod schema reconstructed them.
line('parse.txIsUpstreamClass', tx instanceof Tx ? 'yes' : 'no');
line('parse.txCtor', tx?.constructor?.name ?? 'none');
line('parse.headerIsUpstreamClass', header instanceof BlockHeader ? 'yes' : 'no');
line('parse.plainObject', Object.getPrototypeOf(tx) === Object.prototype ? 'yes' : 'no');

// …and a response that is valid JSON and invalid against the schema is REFUSED. Served from a raw
// HTTP server rather than through upstream's own server, because upstream's server validates its
// OWN output and would refuse to emit it — the point here is the CLIENT's parse.
const serveResult = (result) => {
  const s = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      const calls = JSON.parse(body);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(calls.map((c) => ({ jsonrpc: '2.0', id: c.id, result }))));
    });
  });
  return new Promise((resolve) => s.listen(0, '127.0.0.1',
    () => resolve({ url: `http://127.0.0.1:${s.address().port}`, close: () => new Promise((r) => s.close(r)) })));
};

const bad = await serveResult('banana');
let badOutcome = 'returned';
try { await createReplayNodeClient({ url: bad.url, expectedProtocolVersion: {} }).getBlockNumber(); }
catch (e) { badOutcome = e?.constructor?.name ?? 'unknown'; }
line('parse.badRejected', badOutcome);
await bad.close();

// THE CONTROL FOR THE SAME HARNESS: a well-typed answer from the SAME raw server returns. Without
// it, `parse.badRejected` is satisfied by a client that cannot talk to that server at all.
const goodRaw = await serveResult(99);
let goodOutcome = 'threw';
try { goodOutcome = String(await createReplayNodeClient({ url: goodRaw.url, expectedProtocolVersion: {} }).getBlockNumber()); }
catch (e) { goodOutcome = `threw:${e?.constructor?.name}`; }
line('parse.goodAccepted', goodOutcome);
await goodRaw.close();

// ---- 4. A FABRICATED METHOD NAME IS REJECTED, at every layer ---------------
// (a) by the guard, before anything reaches the node;
let guardOutcome = 'answered';
try { void client['aFabricatedMethodName']; } catch (e) { guardOutcome = e?.kind ?? 'wrong-type'; }
line('fabricated.guard', guardOutcome);
// (b) by upstream's own client, which has no key for it;
const raw = createUnguardedNodeClientForControls(node.url);
line('fabricated.rawClient', typeof raw['aFabricatedMethodName']);
// (c) and on the wire: the node itself refuses `aztec_aFabricatedMethodName`.
const res = await fetch(node.url, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify([{ jsonrpc: '2.0', id: 1, method: 'aztec_aFabricatedMethodName', params: [] }]),
});
const answered = await res.json();
line('fabricated.wireIsError', Array.isArray(answered) && answered[0]?.error !== undefined ? 'yes' : 'no');
// …and the SAME wire request with a REAL method name is not an error, so (c) is measuring the name
// and not the request shape.
const res2 = await fetch(node.url, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify([{ jsonrpc: '2.0', id: 2, method: 'aztec_getBlockNumber', params: [] }]),
});
const answered2 = await res2.json();
line('fabricated.wireRealOk', Array.isArray(answered2) && answered2[0]?.result !== undefined ? 'yes' : 'no');

// ---- 5. THE PIN, re-derived from upstream's own producers ------------------
line('pin.moduleContractsHash', PINNED_PROTOCOL_VERSION.l2ProtocolContractsHash);
line('pin.moduleVkTreeRoot', PINNED_PROTOCOL_VERSION.l2CircuitsVkTreeRoot);
line('pin.upstreamContractsHash', protocolContractsHash.toString());
line('pin.upstreamVkTreeRoot', getVKTreeRoot().toString());
line('pin.network', PINNED_NETWORK);
line('pin.declaredFields', COMPONENTS_VERSION_FIELDS.filter(
  (f) => PINNED_PROTOCOL_VERSION[f] !== undefined).sort().join(','));
line('pin.allFields', [...COMPONENTS_VERSION_FIELDS].length);

// ---- 6. THE SEAM: the five witness queries are on the permitted surface ----
line('seam.queries', [...MEMBERSHIP_WITNESS_QUERIES].length);
line('seam.allPermitted',
     MEMBERSHIP_WITNESS_QUERIES.every((q) => REPLAY_NODE_SURFACE.includes(q)) ? 'yes' : 'no');
line('seam.allInSchema', MEMBERSHIP_WITNESS_QUERIES.every((q) => pkg.includes(q)) ? 'yes' : 'no');
line('seam.clientHasThem',
     MEMBERSHIP_WITNESS_QUERIES.every((q) => typeof client[q] === 'function') ? 'yes' : 'no');

await node.close();
line('l0.done', 1);
EOS
)"

OUT="$L0_WORK/probes/schema.out"
l0_run_probe schema "$PROBE" "$OUT"
f() { l0_field "$OUT" "$1"; }

# ---------------------------------------------------------------------------
echo "== 1. the method set is upstream's, compared as a SET"
# ---------------------------------------------------------------------------
assert_eq "the installed package's schema has fifty-five methods" "55" "$(f set.packageCount)"
assert_eq "…and so does the interface at the pinned anchor" "55" "$(f set.anchorCount)"
# THE PUBLISHED NIGHTLY IS NOT THE ANCHOR, AND THE DIFFERENCE IS EXACTLY ONE NAME. Nothing in this
# repository had ever measured that. It is asserted by name in both directions rather than
# tolerated as "close enough", so a bump that changes the delta reddens instead of widening it.
assert_eq "exactly one method is at the anchor and not in the published nightly" \
  "getL1ToL2MessageIndex" "$(f set.anchorOnly)"
assert_eq "…and exactly one is in the nightly and not at the anchor" \
  "getL1ToL2MessageCheckpoint" "$(f set.packageOnly)"
assert_eq "…which is what node_surface.ts declares, in the first direction" \
  "$(f set.anchorOnly)" "$(f set.declaredAnchorOnly)"
assert_eq "…and in the second" "$(f set.packageOnly)" "$(f set.declaredPackageOnly)"
assert_eq "…so the two sets are identical apart from the declared difference" "yes" \
  "$(f set.identicalExceptDeclared)"
assert_eq "every permitted method has an entry in upstream's schema" "none" \
  "$(f set.permittedNotInSchema)"
assert_eq "…while a fabricated name does not, so the membership test discriminates" "no" \
  "$(f set.fabricatedInSchema)"
assert_eq "upstream's own schemaHasMethod says yes to a real method" "yes" "$(f set.schemaHasReal)"
assert_eq "…and no to a fabricated one" "no" "$(f set.schemaHasFabricated)"

# ---------------------------------------------------------------------------
echo "== 2. the wire: upstream's namespacing, observed at the node"
# ---------------------------------------------------------------------------
assert_ge "the node recorded the JSON-RPC method names it was sent" 2 "$(f wire.count)"
assert_eq "…and every one of them is namespaced aztec_, which is createAztecNodeClient's doing" \
  "yes" "$(f wire.allNamespaced)"
assert_contains "…including the transaction lookup" "aztec_getTxByHash" "$(f wire.methods)"
assert_contains "…and the block lookup" "aztec_getBlockData" "$(f wire.methods)"

# ---------------------------------------------------------------------------
echo "== 3. the parse: upstream's schema reconstructs upstream's types"
# ---------------------------------------------------------------------------
assert_eq "what comes back for getTxByHash is upstream's Tx class" "yes" "$(f parse.txIsUpstreamClass)"
assert_eq "…by name" "Tx" "$(f parse.txCtor)"
assert_eq "…and getBlockData's header is upstream's BlockHeader" "yes" \
  "$(f parse.headerIsUpstreamClass)"
assert_eq "…so it is not the plain object JSON.parse would have produced" "no" \
  "$(f parse.plainObject)"
assert_prefix "a response that is valid JSON and invalid against the schema is REFUSED" \
  "\$ZodError" "\$$(f parse.badRejected)"
assert_eq "…and the SAME raw server answering correctly is accepted, so the harness works" "99" \
  "$(f parse.goodAccepted)"

# ---------------------------------------------------------------------------
echo "== 4. THE CONTROL: a fabricated method name is rejected at every layer"
# ---------------------------------------------------------------------------
assert_eq "the guard refuses it before it reaches the node" "replay-node-surface-exceeded" \
  "$(f fabricated.guard)"
assert_eq "upstream's own client has no such member" "undefined" "$(f fabricated.rawClient)"
assert_eq "…and the node refuses it on the wire" "yes" "$(f fabricated.wireIsError)"
assert_eq "…while the same request shape with a REAL name is answered, so it is the name that is refused" \
  "yes" "$(f fabricated.wireRealOk)"

# ---------------------------------------------------------------------------
echo "== 5. the pinned protocol version, re-derived three ways"
#
# pins.json is the declaration; `pinned_protocol_version.ts` is the witness the browser can read;
# the packages are upstream. All three must agree or the client is checking nodes against a number
# nobody produces.
# ---------------------------------------------------------------------------
PIN_CONTRACTS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["live_chain"]["protocol_version"]["l2ProtocolContractsHash"])' "$REPO_ROOT/pins.json")"
PIN_VK="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["live_chain"]["protocol_version"]["l2CircuitsVkTreeRoot"])' "$REPO_ROOT/pins.json")"
assert_prefix "pins.json declares a protocol contracts hash" "0x" "$PIN_CONTRACTS"
assert_prefix "…and a circuits vk tree root" "0x" "$PIN_VK"
assert_eq "the module's literal equals pins.json's, for the contracts hash" "$PIN_CONTRACTS" \
  "$(f pin.moduleContractsHash)"
assert_eq "…and for the vk tree root" "$PIN_VK" "$(f pin.moduleVkTreeRoot)"
assert_eq "…and upstream's own protocolContractsHash equals it" "$PIN_CONTRACTS" \
  "$(f pin.upstreamContractsHash)"
assert_eq "…and upstream's own getVKTreeRoot() equals it" "$PIN_VK" "$(f pin.upstreamVkTreeRoot)"
# The two are DIFFERENT values, so the four assertions above are not one value compared with itself
# four times — the campaign's most degenerate assertion shape, written by an author who had read
# the rule that day.
assert_true "…and the two pinned values are different from each other" \
  test "$PIN_CONTRACTS" != "$PIN_VK"
assert_eq "the pin is a PARTIAL ComponentsVersions: two of five fields" \
  "l2CircuitsVkTreeRoot,l2ProtocolContractsHash" "$(f pin.declaredFields)"
assert_eq "…of the five upstream declares" "5" "$(f pin.allFields)"
# The network is UNESTABLISHED in both places, which is a recorded measurement and not a default.
assert_eq "pins.json records the network as unestablished" "UNESTABLISHED" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["live_chain"]["network"])' "$REPO_ROOT/pins.json")"
assert_eq "…and so does the module" "UNESTABLISHED" "$(f pin.network)"
assert_ge "…with the endpoints that were probed recorded, rather than summarised" 3 \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["live_chain"]["probed_endpoints"]))' "$REPO_ROOT/pins.json")"

# ---------------------------------------------------------------------------
echo "== 6. replay/src declares no schema of its own"
#
# THE SCANNER IS SHOWN TO BE ABLE TO MATCH BEFORE ITS ZEROES ARE BELIEVED. Every assertion here is
# an absence, and an absence measured by a needle that cannot match is this campaign's
# most-repeated defect. Each needle is run against a planted copy first.
# ---------------------------------------------------------------------------
scan() { grep -rIl -- "$2" "$1" 2>/dev/null | wc -l | tr -d '[:space:]'; }
PLANT_DIR="$L0_WORK/plant"
rm -rf "$PLANT_DIR"; mkdir -p "$PLANT_DIR"
cp "$L0_SRC/node_client.ts" "$PLANT_DIR/node_client.ts"
{
  # SINGLE-QUOTED, and that is not cosmetic: the first draft planted `from "zod"` while the needle
  # is `from 'zod'`, and the control went red — which is the control working. A fixed-string grep
  # is only as wide as the spelling it was given, so the plant must be spelled the way the needle
  # is, and both quotings are scanned for below.
  printf "import { z } from 'zod';\n"
  printf 'import { z as z2 } from "zod";\n'
  printf 'const OurOwnSchema = z.object({ blockNumber: z.number() });\n'
  printf 'const envelope = { jsonrpc: "2.0", id: 1, method: "aztec_getBlockNumber" };\n'
} >>"$PLANT_DIR/node_client.ts"

for needle in "z.object(" "from 'zod'" 'from "zod"' "jsonrpc"; do
  assert_ge "the scanner CAN find [$needle] — it is planted in a copy" 1 "$(scan "$PLANT_DIR" "$needle")"
  assert_eq "…and replay/src does not declare [$needle]" "0" "$(scan "$L0_SRC" "$needle")"
done
rm -rf "$PLANT_DIR"

# And the positive half, so section 6 is not "replay/src contains nothing": the sources DO import
# upstream's schema module, and the count is a measurement rather than a name grep standing in for
# a property — sections 1 to 4 are what establish that it is USED.
assert_ge "replay/src imports upstream's own client interfaces module" 2 \
  "$(grep -rIl -- "@aztec/stdlib/interfaces/client" "$L0_SRC" | wc -l | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
echo "== 7. the shared membership-witness seam"
#
# Declared in L0 so L2 and the sibling campaign's M35 do not discover the collision after both are
# written. Asserted here because the seam is part of what the surface must not foreclose.
# ---------------------------------------------------------------------------
assert_eq "the seam names five witness queries" "5" "$(f seam.queries)"
assert_eq "…every one of which is on the permitted surface" "yes" "$(f seam.allPermitted)"
assert_eq "…and in upstream's schema" "yes" "$(f seam.allInSchema)"
assert_eq "…and answerable on a live client, so a replay satisfies the interface without an adapter" \
  "yes" "$(f seam.clientHasThem)"

finish
