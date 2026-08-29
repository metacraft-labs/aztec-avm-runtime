#!/usr/bin/env bash
# e2e_fetch_settled_transaction — L1 (Aztec-Live-Chain-Replay).
#
# "A known settled transaction is fetched with its block coordinates and contract artifacts.
#  Control: an unknown hash is refused by name."
#
# WHAT IS ACTUALLY BEING MEASURED, AND WHY IT IS NOT A NETWORK TEST.
#
# The subject is `fetchSettledTransaction`, driven over a fixture CAPTURED FROM A LIVE AZTEC
# TESTNET on 2026-08-29 — `replay/fixtures/testnet_settled_tx.json`, transaction
# 0x2090b63c… in block 60616, recorded at the JSON-RPC transport by
# `replay/tools/capture_settled_fixture.mjs`. Playing it back drives THE REAL
# `createAztecNodeClient` over THE REAL `AztecNodeApiSchema`, so upstream's zod validates every
# stored response on every run: this is not a mock of a node, it is a recording of one.
#
# THE CONTROL IS THE UNKNOWN HASH, AND IT IS A REAL NODE'S ANSWER. The capture asked the live node
# for a hash that does not exist and recorded its `null`, so §4 measures what the chain says rather
# than what this repository synthesises.
#
# AND THE CONTROL HAS ITS OWN CONTROL, WHICH IS THE HALF A WEAKER CHECK WOULD SKIP. A fixture that
# simply did not carry a request would ALSO produce "no transaction" if a miss answered `undefined`
# — a fact about our recording reported as a fact about the chain, which is the exact collapse L0's
# refusal classes exist to prevent. §5 asks for a call the fixture does not carry and asserts it is
# `FixtureMiss` inside `NodeUnreachable` and NOT `SettledTransactionNotFound`.
#
# §6 IS THE OTHER DIRECTION AGAIN: the fixture is validated by upstream's schema, demonstrated by
# corrupting one recorded response in memory and watching upstream refuse it — with the uncorrupted
# fixture answering correctly in the same process as the control. Without that, "the schema
# validates the fixture" is a mechanism nobody has seen run.
#
# Run: just verify-l1-fetch

set -uo pipefail
TEST_NAME="e2e_fetch_settled_transaction"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l1_settled_tx.sh"

echo "== $TEST_NAME"
l1_prepare

FIXTURE="$L1_FIXTURE_DIR/testnet_settled_tx.json"
PRIVATE_FIXTURE="$L1_FIXTURE_DIR/testnet_private_only_tx.json"

PROBE="$(l1_imports)
$(cat <<'EOS'

import { TxHash } from '@aztec/stdlib/tx/tx-hash';

const fixture = readFixture('testnet_settled_tx.json');
const client = fixtureClient(fixture);
const hash = TxHash.fromString(fixture.provenance.txHash);

// ---- THE FETCH, over a recording of a live chain ---------------------------
const settled = await fetchSettledTransaction(client, hash);

line('fetch.txHash', settled.txHash);
line('fetch.l2BlockNumber', settled.l2BlockNumber);
line('fetch.l2BlockHash', settled.l2BlockHash);
line('fetch.txIndexInBlock', settled.txIndexInBlock);
line('fetch.revertCode', settled.revertCode);
line('fetch.txIsUpstreamTx', settled.tx?.constructor?.name ?? 'none');
// THE HASH IS RE-DERIVED FROM THE Tx ITSELF, not read back off the request. A client that echoed
// its argument would satisfy `fetch.txHash`; this asks the deserialised transaction what it is.
line('fetch.txSelfReportedHash', settled.tx.txHash.toString());
line('fetch.effectSelfReportedHash', settled.txEffect.data.txHash.toString());

// ---- the block coordinates a replay re-executes against --------------------
const gv = settled.blockData.header.globalVariables;
line('block.gvBlockNumber', gv.blockNumber);
line('block.gvChainId', gv.chainId.toString());
line('block.gvVersion', gv.version.toString());
line('block.gvTimestamp', String(gv.timestamp));
line('block.gvFeePerDaGas', String(gv.gasFees.feePerDaGas));
line('block.gvFeePerL2Gas', String(gv.gasFees.feePerL2Gas));
const state = settled.blockData.header.state;
line('block.noteHashTreeRoot', state.partial.noteHashTree.root.toString());
line('block.nullifierTreeRoot', state.partial.nullifierTree.root.toString());
line('block.publicDataTreeRoot', state.partial.publicDataTree.root.toString());
line('block.l1ToL2MessageTreeRoot', state.l1ToL2MessageTree.root.toString());
line('block.archiveRoot', settled.blockData.archive.root.toString());
// A root of zero is a root that certifies nothing, and four zeros would satisfy every equality
// above if the provenance carried them too. Counted here so the comparison cannot be vacuous.
line('block.nonZeroRoots', [
  state.partial.noteHashTree.root,
  state.partial.nullifierTree.root,
  state.partial.publicDataTree.root,
  state.l1ToL2MessageTree.root,
  settled.blockData.archive.root,
].filter((r) => !r.isZero()).length);
// The trees are non-empty, which is what says this is a chain with history in it.
line('block.noteHashTreeSize', String(state.partial.noteHashTree.nextAvailableLeafIndex));

// ---- the contract artifacts -------------------------------------------------
line('contracts.count', settled.contracts.length);
line('contracts.allResolved', settled.contracts.every((c) => c.resolved) ? 'yes' : 'no');
line('contracts.addresses', settled.contracts.map((c) => c.address).join(','));
line('contracts.classIds', settled.contracts.map((c) => c.contractClassId).join(','));
line('contracts.bytecodeBytes', settled.contracts.map((c) => c.packedBytecodeBytes).join(','));
line('contracts.minBytecodeBytes', Math.min(...settled.contracts.map((c) => c.packedBytecodeBytes)));
// The bytecode is REAL BYTES and not a length somebody stored: read the buffer back off the class.
line('contracts.bufferBytes',
     settled.contracts.map((c) => c.contractClass.packedBytecode.length).join(','));
line('contracts.classIdMatchesInstance',
     settled.contracts.every((c) => c.contractClass.id.toString() === c.contractClassId) ? 'yes' : 'no');

// ---- the halves, declared ---------------------------------------------------
line('publicHalf.present', settled.publicHalf.present ? 'yes' : 'no');
line('publicHalf.enqueuedCalls', settled.publicHalf.enqueuedCalls);
line('publicHalf.targets', publicCallTargets(settled.tx).map((a) => a.toString()).join(','));
line('privateHalf.status', settled.privateHalf.status);

// ---- THE CONTROL: an unknown hash, refused by name -------------------------
// The node's own `null`, captured live. See the header.
const unknown = TxHash.fromString(fixture.provenance.fabricatedProbes.txHash);
const unknownResult = await classify('unknown', () => fetchSettledTransaction(client, unknown));
line('unknown.namesHash', unknownResult.error?.txHash === unknown.toString() ? 'yes' : 'no');
line('unknown.namesMethod', unknownResult.error?.method ?? 'none');
line('unknown.isNotFound', unknownResult.error instanceof SettledTransactionNotFound ? 'yes' : 'no');
line('unknown.isUnreachable', unknownResult.error instanceof NodeUnreachable ? 'yes' : 'no');

// ---- THE CONTROL'S CONTROL: a call the recording does not carry ------------
// This must NOT read as 'the chain does not have it'. Nothing was found or not found.
const miss = await classify('miss', () => client.getBlockData(999999));
line('miss.causeIsFixtureMiss', miss.error?.cause instanceof FixtureMiss ? 'yes' : 'no');
line('miss.causeNamesMethod', miss.error?.cause?.method ?? 'none');
line('miss.isNotFound', miss.error instanceof SettledTransactionNotFound ? 'yes' : 'no');

// ---- UPSTREAM'S SCHEMA IS WHAT VALIDATES THE FIXTURE ------------------------
// One recorded response replaced with a well-formed JSON object the schema cannot accept. The
// substitution is asserted to have FOUND its needle, because a mutation that never applied printing
// its predicted result is how this campaign has been fooled before.
const corrupted = edit(fixture, 'aztec_getTxEffect', [fixture.provenance.txHash],
                       { l2BlockNumber: 1, notAField: true });
line('corrupt.hits', corrupted.hits);
const corruptResult = await classify('corrupt',
  () => fixtureClient(corrupted.fixture).getTxEffect(hash));
line('corrupt.threw', corruptResult.error ? 'yes' : 'no');
line('corrupt.mentionsSchema',
     /zod|invalid|expected|parse/i.test(String(corruptResult.error?.message ?? '')) ? 'yes' : 'no');
// …and the SAME call over the UNCORRUPTED recording answers, in this same process. Without this the
// arm above would be satisfied by a client that refused everything.
const uncorrupted = await classify('uncorrupted', () => client.getTxEffect(hash));
line('uncorrupted.blockNumber', String(uncorrupted.value?.l2BlockNumber ?? 'none'));

// ---- THE `includeTransactions` CAVEAT, AS A CAPTURED ARTEFACT ---------------
// L0's live run found that `getBlock(n)` without the option answers a BODY-LESS block rather than
// an error. Both shapes are in the recording, so the difference is measured and not remembered.
// BOTH shapes go through `classify`, so "it did not throw" is a MEASURED outcome rather than a
// literal printed on a line the probe could only reach by not throwing.
const withOption = await classify('block.withOption',
  () => client.getBlock(settled.l2BlockNumber, { includeTransactions: true }));
const withoutOption = await classify('block.withoutOption', () => client.getBlock(settled.l2BlockNumber));
const withTx = withOption.value;
const without = withoutOption.value;
line('block.withOption.hasBody', withTx?.body ? 'yes' : 'no');
line('block.withOption.txEffects', withTx?.body?.txEffects?.length ?? 'none');
line('block.withOption.firstHash', withTx?.body?.txEffects?.[0]?.txHash?.toString() ?? 'none');
line('block.withoutOption.hasBody', without?.body ? 'yes' : 'no');
line('block.withoutOption.isDefined', without ? 'yes' : 'no');
// The two answers are the SAME BLOCK, so the difference is the option and nothing else.
line('block.sameBlock',
     withTx?.header?.globalVariables?.blockNumber === without?.header?.globalVariables?.blockNumber
       ? 'yes' : 'no');

// ---- THE SETTLING BLOCK IS ITS OWN REFUSAL ---------------------------------
// A transaction the chain HAS, whose settling block the node will not serve. Distinct from
// 'not found' on purpose: the transaction is there and the coordinates a replay needs are not.
const noBlock = edit(fixture, 'aztec_getBlockData', [settled.l2BlockNumber], null);
line('noBlock.hits', noBlock.hits);
const noBlockResult = await classify('noBlock',
  () => fetchSettledTransaction(fixtureClient(noBlock.fixture), hash));
line('noBlock.blockNumber', noBlockResult.error?.blockNumber ?? 'none');
line('noBlock.namesTx', noBlockResult.error?.txHash === fixture.provenance.txHash ? 'yes' : 'no');
line('noBlock.isNotFound', noBlockResult.error instanceof SettledTransactionNotFound ? 'yes' : 'no');
line('noBlock.isOwnClass', noBlockResult.error instanceof SettlingBlockUnavailable ? 'yes' : 'no');

// ---- THE VERSION HEADERS, BOTH RECORDED SHAPES -----------------------------
// The milestone's instruction: "the capture either uses a direct node or records that the version
// was unverifiable". Both halves are exercised here rather than asserted.
//
//   as captured (batch POST, which is the only shape upstream's client sends): NO headers, so
//   `assertProtocolVersion` refuses naming the absence — the live behaviour, reproduced offline;
//   as reconstructed (the un-batched probe): the headers ARE there and the very same client on the
//   very same recording accepts them — so the obstacle is the PROXY and not the version check.
const asCaptured = await classify('version.asCaptured', () => client.assertProtocolVersion());
line('version.asCaptured.field', asCaptured.error?.field ?? 'none');
const asSingle = fixtureClient(fixture, { headerSource: 'single-object-post' });
const reconstructed = await classify('version.reconstructed', () => asSingle.assertProtocolVersion());
line('version.reconstructed.fields',
     Object.keys(reconstructed.value ?? {}).sort().join(','));
line('version.reconstructed.matchesPin',
     reconstructed.value?.l2CircuitsVkTreeRoot === PINNED_PROTOCOL_VERSION.l2CircuitsVkTreeRoot
       ? 'yes' : 'no');

// ---- A FIXTURE WITHOUT PROVENANCE IS REFUSED, NOT LOADED -------------------
// The loader is the instrument that makes "fabricated or unlabelled fixtures" a failure rather than
// a possibility, so it is run rather than cited.
const stripped = JSON.parse(JSON.stringify(fixture));
delete stripped.provenance.capturedAt;
delete stripped.provenance.txHash;
const strippedResult = await classify('stripped', async () => loadSettledFixture(stripped, 'stripped'));
line('stripped.missingCount', strippedResult.error?.missing?.length ?? 'none');
line('stripped.missingNames', (strippedResult.error?.missing ?? []).join(','));
// …and the required-field list is not empty, so "nothing was missing" cannot be "nothing is checked".
line('provenance.requiredFieldCount', REQUIRED_PROVENANCE_FIELDS.length);
const reloaded = await classify('reloaded', async () => loadSettledFixture(JSON.parse(JSON.stringify(fixture)), 'intact'));

// ---- THE SECOND FIXTURE: a transaction with NO public half -----------------
// Declared, not an empty array. The same fetch, no throw.
const privateOnly = readFixture('testnet_private_only_tx.json');
const privateClient = fixtureClient(privateOnly);
const privateSettled = await fetchSettledTransaction(
  privateClient, TxHash.fromString(privateOnly.provenance.txHash));
line('privateOnly.txHash', privateSettled.txHash);
line('privateOnly.publicHalfPresent', privateSettled.publicHalf.present ? 'yes' : 'no');
line('privateOnly.enqueuedCalls', privateSettled.publicHalf.enqueuedCalls);
line('privateOnly.contracts', privateSettled.contracts.length);
line('privateOnly.reasonLength', privateSettled.publicHalf.reason.length);
line('privateOnly.reasonSaysNoPublicCalls',
     privateSettled.publicHalf.reason.includes('NO public calls') ? 'yes' : 'no');
line('privateOnly.blockNumber', privateSettled.l2BlockNumber);
// The two fixtures are two different transactions in two different blocks — so "the fetch works" is
// not a statement about one recording.
line('fixtures.distinctHashes', settled.txHash === privateSettled.txHash ? 'no' : 'yes');
line('fixtures.distinctBlocks', settled.l2BlockNumber === privateSettled.l2BlockNumber ? 'no' : 'yes');

line('l1.done', 1);
EOS
)"

OUT="$L1_WORK/probes/fetch.out"
l0_run_probe fetch "$PROBE" "$OUT" l1.done
f() { l0_field "$OUT" "$1"; }
j() { l1_json "$FIXTURE" "$1"; }
p() { l1_json "$PRIVATE_FIXTURE" "$1"; }

# ---------------------------------------------------------------------------
echo "== 1. the fixture is a recording of a live chain, and says so"
#
# The deliverable: "Record provenance per fixture: which endpoint, which block, which transaction,
# when captured, and what the node reported." Read out of the file here and re-derived from the
# recorded RESPONSES by the probe below, so the two can disagree.
# ---------------------------------------------------------------------------
assert_eq "the fixture declares the format it is" "replay-settled-transaction-fixture/1" "$(j "d['format']")"
assert_eq "…the endpoint it was captured from" "https://aztec-testnet.drpc.org" "$(j "d['provenance']['endpoint']")"
assert_eq "…which chain that is" "aztec-testnet" "$(j "d['provenance']['chain']")"
assert_eq "…the L1 chain id, which is the field today's protocol pin CANNOT check" \
  "11155111" "$(j "d['provenance']['l1ChainId']")"
assert_eq "…the rollup the node named" "0xd73a91bdcf6891c7642f3e460036e1ef2cc23178" \
  "$(j "d['provenance']['l1RollupAddress']")"
assert_eq "…the node version that answered" "5.2.0" "$(j "d['provenance']['nodeVersion']")"
assert_prefix "…when it was captured" "2026-08-29" "$(j "d['provenance']['capturedAt']")"
assert_eq "…and by what" "replay/tools/capture_settled_fixture.mjs" "$(j "d['provenance']['capturedBy']")"
assert_ge "the recording is not empty" 10 "$(j "len(d['calls'])")"
assert_ge "…and the chain tip at capture is at or past the settling block" \
  "$(j "d['provenance']['l2BlockNumber']")" "$(j "d['provenance']['chainTipAtCapture']")"

# EVERY FABRICATED VALUE IS LABELLED. An unlabelled fabricated datum beside real ones is the
# sharpest form of the failure mode this campaign is built to avoid.
assert_eq "the three fabricated probe values are declared as fabricated" "3" \
  "$(j "len([k for k in d['provenance']['fabricatedProbes'] if k != 'note'])")"
assert_contains "…with a note saying what they are for" "do NOT exist on this chain" \
  "$(j "d['provenance']['fabricatedProbes']['note']")"
# …and the node's own answer to each of them is `null` IN THE RECORDING, so §4's refusal is the
# chain's answer and not ours.
assert_eq "the live node's answer to the fabricated hash was recorded, and it is null" "None" \
  "$(j "[c['result'] for c in d['calls'] if c['method'] == 'aztec_getTxByHash' and c['params'] == [d['provenance']['fabricatedProbes']['txHash']]][0]")"
assert_eq "…and to the fabricated contract address" "None" \
  "$(j "[c['result'] for c in d['calls'] if c['method'] == 'aztec_getContract' and c['params'] == [d['provenance']['fabricatedProbes']['contractAddress']]][0]")"

# THE PROXY CAVEAT, RECORDED IN BOTH SHAPES. The batch headers are what upstream's client SAW.
assert_eq "the headers upstream's client saw on its batch POST: none, because the endpoint proxies" \
  "0" "$(j "len(d['provenance']['versionHeaders']['onBatchPost'])")"
assert_eq "…while the deliberately un-batched probe got all five" "5" \
  "$(j "len(d['provenance']['versionHeaders']['onSingleObjectPost'])")"
assert_eq "…and the two protocol-level ones equal the pin, so the version WAS verifiable out of band" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["live_chain"]["protocol_version"]["l2CircuitsVkTreeRoot"])' "$REPO_ROOT/pins.json")" \
  "$(j "d['provenance']['versionHeaders']['onSingleObjectPost']['x-aztec-l2circuitsvktreeroot']")"
assert_eq "…and the second of them" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["live_chain"]["protocol_version"]["l2ProtocolContractsHash"])' "$REPO_ROOT/pins.json")" \
  "$(j "d['provenance']['versionHeaders']['onSingleObjectPost']['x-aztec-l2protocolcontractshash']")"
assert_contains "…with the reconstruction labelled as one, rather than passed off as what was seen" \
  "RECONSTRUCTION" "$(j "d['provenance']['versionHeaders']['note']")"

# ---------------------------------------------------------------------------
echo "== 2. a transaction hash becomes an upstream Tx and its block coordinates"
# ---------------------------------------------------------------------------
assert_eq "the transaction fetched is the one the fixture is a recording of" \
  "$(j "d['provenance']['txHash']")" "$(f fetch.txHash)"
assert_eq "…and the deserialised Tx agrees about its own hash" \
  "$(j "d['provenance']['txHash']")" "$(f fetch.txSelfReportedHash)"
assert_eq "…as does the TxEffect the chain published" \
  "$(j "d['provenance']['txHash']")" "$(f fetch.effectSelfReportedHash)"
assert_eq "what comes back is upstream's own Tx class" "Tx" "$(f fetch.txIsUpstreamTx)"
assert_eq "the settling block, from the effect" "$(j "d['provenance']['l2BlockNumber']")" \
  "$(f fetch.l2BlockNumber)"
assert_eq "…its hash" "$(j "d['provenance']['nodeReported']['l2BlockHash']")" "$(f fetch.l2BlockHash)"
assert_eq "…the index in that block" "$(j "d['provenance']['txIndexInBlock']")" \
  "$(f fetch.txIndexInBlock)"
assert_eq "…and the outcome the chain recorded" "$(j "d['provenance']['nodeReported']['revertCode']")" \
  "$(f fetch.revertCode)"

# ---------------------------------------------------------------------------
echo "== 3. getBlockData(n) gives the GlobalVariables and the StateReference"
#
# These are the two things L2 needs: `globalVariables` is what `encodeFastSimulationInputs` takes
# and what `AvmTxHint.fromTx` reads `gasFees` out of; `state` is what a hydrated tree's roots are
# compared against. Both are compared against the provenance, which was written by a DIFFERENT read
# in a different process.
# ---------------------------------------------------------------------------
assert_eq "the block's own number, inside its global variables" \
  "$(j "d['provenance']['nodeReported']['globalVariables']['blockNumber']")" "$(f block.gvBlockNumber)"
assert_eq "…the chain id" "$(j "d['provenance']['nodeReported']['globalVariables']['chainId']")" \
  "$(f block.gvChainId)"
assert_eq "…the rollup version" "$(j "d['provenance']['nodeReported']['globalVariables']['version']")" \
  "$(f block.gvVersion)"
assert_eq "…the timestamp" "$(j "d['provenance']['nodeReported']['globalVariables']['timestamp']")" \
  "$(f block.gvTimestamp)"
assert_eq "…and the gas fees AvmTxHint.fromTx reads" \
  "$(j "d['provenance']['nodeReported']['globalVariables']['feePerL2Gas']")" "$(f block.gvFeePerL2Gas)"
assert_eq "the state reference: the note hash tree root" \
  "$(j "d['provenance']['nodeReported']['stateReference']['noteHashTreeRoot']")" "$(f block.noteHashTreeRoot)"
assert_eq "…the nullifier tree root" \
  "$(j "d['provenance']['nodeReported']['stateReference']['nullifierTreeRoot']")" "$(f block.nullifierTreeRoot)"
assert_eq "…the public data tree root" \
  "$(j "d['provenance']['nodeReported']['stateReference']['publicDataTreeRoot']")" "$(f block.publicDataTreeRoot)"
assert_eq "…the L1-to-L2 message tree root" \
  "$(j "d['provenance']['nodeReported']['stateReference']['l1ToL2MessageTreeRoot']")" "$(f block.l1ToL2MessageTreeRoot)"
assert_eq "…and the archive root" \
  "$(j "d['provenance']['nodeReported']['stateReference']['archiveRoot']")" "$(f block.archiveRoot)"
# NOT VACUOUS: five equalities over five zeros would pass every one of the above.
assert_eq "none of the five roots is zero, so the comparisons above are not five zeros agreeing" \
  "5" "$(f block.nonZeroRoots)"
assert_ge "…and the note hash tree has real history in it" 1000 "$(f block.noteHashTreeSize)"

# ---------------------------------------------------------------------------
echo "== 4. the contract artifacts, resolved through getContract / getContractClass"
# ---------------------------------------------------------------------------
assert_eq "every contract the public half calls was resolved" "yes" "$(f contracts.allResolved)"
assert_eq "…and there is the number of them the capture recorded" \
  "$(j "len(d['provenance']['nodeReported']['contracts'])")" "$(f contracts.count)"
assert_eq "…at the addresses the chain named" \
  "$(j "','.join(c['address'] for c in d['provenance']['nodeReported']['contracts'])")" \
  "$(f contracts.addresses)"
assert_eq "…running the class ids the chain named" \
  "$(j "','.join(c['contractClassId'] for c in d['provenance']['nodeReported']['contracts'])")" \
  "$(f contracts.classIds)"
assert_eq "…with the bytecode the chain published" \
  "$(j "','.join(str(c['packedBytecodeBytes']) for c in d['provenance']['nodeReported']['contracts'])")" \
  "$(f contracts.bytecodeBytes)"
# THE BYTES ARE THERE, not just a number beside them. This is the assertion the whole next check is
# about: an artefact that resolves with zero bytes is the sibling campaign's own failure.
assert_eq "…and the byte counts are the buffers' own lengths, read back off the class" \
  "$(f contracts.bytecodeBytes)" "$(f contracts.bufferBytes)"
assert_ge "…every one of which is real bytecode rather than an empty artefact" 1000 \
  "$(f contracts.minBytecodeBytes)"
assert_eq "the class the node returned is the class the instance says it runs" "yes" \
  "$(f contracts.classIdMatchesInstance)"
assert_eq "the public half is declared present, with the call count the chain recorded" \
  "$(j "d['provenance']['nodeReported']['enqueuedPublicCalls']")" "$(f publicHalf.enqueuedCalls)"
assert_eq "…and it says so" "yes" "$(f publicHalf.present)"
assert_eq "…over the addresses upstream's own accessor enumerates" \
  "$(j "','.join(d['provenance']['nodeReported']['publicCallTargets'])")" "$(f publicHalf.targets)"

# ---------------------------------------------------------------------------
echo "== 5. THE CONTROL: an unknown hash is refused by name"
# ---------------------------------------------------------------------------
assert_eq "a hash the live node answered 'null' for is refused" "replay-transaction-not-found" \
  "$(f unknown.outcome)"
assert_eq "…by L0's own class" "SettledTransactionNotFound" "$(f unknown.class)"
assert_eq "…naming the hash it was asked about" "yes" "$(f unknown.namesHash)"
assert_eq "…and which question was asked" "getTxByHash" "$(f unknown.namesMethod)"
assert_eq "…and it is that class" "yes" "$(f unknown.isNotFound)"
assert_eq "…and NOT the unreachable one" "no" "$(f unknown.isUnreachable)"

echo "== 6. AND THE CONTROL'S OWN CONTROL: a gap in the recording is not an answer"
#
# Without this, an incomplete fixture would read as a chain that does not have the transaction —
# a fact about our recording reported as a fact about the chain.
assert_eq "a call the recording does not carry reads as unreachable, not as 'not found'" \
  "replay-node-unreachable" "$(f miss.outcome)"
assert_eq "…and it is not the not-found class" "no" "$(f miss.isNotFound)"
assert_eq "…with the fixture miss itself as the cause" "yes" "$(f miss.causeIsFixtureMiss)"
assert_eq "…naming the method the recording lacks" "aztec_getBlockData" "$(f miss.causeNamesMethod)"

# ---------------------------------------------------------------------------
echo "== 7. upstream's schema is what validates the fixture, demonstrated in both directions"
# ---------------------------------------------------------------------------
assert_eq "the corruption found its needle, so the arm below ran over a changed recording" "1" \
  "$(f corrupt.hits)"
assert_eq "a recorded response the schema cannot accept is REFUSED rather than returned" "yes" \
  "$(f corrupt.threw)"
assert_eq "…and the refusal is upstream's validation talking" "yes" "$(f corrupt.mentionsSchema)"
assert_eq "…while the SAME call over the intact recording answers, in the same process" "returned" \
  "$(f uncorrupted.outcome)"
assert_eq "…with the block number the chain published" "$(j "d['provenance']['l2BlockNumber']")" \
  "$(f uncorrupted.blockNumber)"

# ---------------------------------------------------------------------------
echo "== 7b. the settling block is its own refusal, not 'not found'"
#
# The chain HAS this transaction and has said where it settled; what is missing is the block whose
# GlobalVariables the AVM needs and whose StateReference L2 compares hydrated roots against.
# Collapsing this into not-found would send a reader after the transaction hash.
# ---------------------------------------------------------------------------
assert_eq "the substitution found its needle" "1" "$(f noBlock.hits)"
assert_eq "a settling block the node will not serve is refused" "replay-settling-block-unavailable" \
  "$(f noBlock.outcome)"
assert_eq "…by its own class" "SettlingBlockUnavailable" "$(f noBlock.class)"
assert_eq "…and it IS that class" "yes" "$(f noBlock.isOwnClass)"
assert_eq "…naming the block the effect pointed at" "$(j "d['provenance']['l2BlockNumber']")" \
  "$(f noBlock.blockNumber)"
assert_eq "…and the transaction that pointed there" "yes" "$(f noBlock.namesTx)"
assert_eq "…and it is NOT the not-found refusal" "no" "$(f noBlock.isNotFound)"

# ---------------------------------------------------------------------------
echo "== 7c. the version headers, in both shapes the capture recorded"
#
# The milestone's own instruction: the capture either uses a direct node or RECORDS THAT THE
# VERSION WAS UNVERIFIABLE. Both halves are run here rather than described. The first reproduces
# the live refusal offline; the second is what makes it a fact about the proxy rather than about
# this repository's version check.
# ---------------------------------------------------------------------------
assert_eq "played back as captured, assertProtocolVersion REFUSES — the live behaviour, offline" \
  "replay-protocol-version-mismatch" "$(f version.asCaptured.outcome)"
assert_eq "…naming the absence rather than inventing a field" "absent" "$(f version.asCaptured.field)"
assert_eq "played back with the un-batched probe's headers, the SAME client accepts" "returned" \
  "$(f version.reconstructed.outcome)"
assert_eq "…observing ALL FIVE ComponentsVersions fields, not only the two that are pinned" \
  "l1ChainId,l1RollupAddress,l2CircuitsVkTreeRoot,l2ProtocolContractsHash,rollupVersion" \
  "$(f version.reconstructed.fields)"
assert_eq "…with the protocol-level one equal to the pin, so the obstacle is the PROXY and not the check" \
  "yes" "$(f version.reconstructed.matchesPin)"
# AND THE THREE THAT ARE OBSERVED AND NOT PINNED ARE THE THREE `pins.json` SAYS ARE MISSING.
# `pin_discrimination_measured` records that today's pin cannot tell mainnet from testnet; this is
# that statement with the data beside it — the node advertises `l1ChainId` on every un-batched
# response and nothing compares it, because no deployment is pinned.
assert_eq "the node advertises the L1 chain id the pin does not carry" "11155111" \
  "$(j "d['provenance']['versionHeaders']['onSingleObjectPost']['x-aztec-l1chainid']")"
assert_eq "…which is the fixture's own declared chain id" "$(j "d['provenance']['l1ChainId']")" \
  "$(j "d['provenance']['versionHeaders']['onSingleObjectPost']['x-aztec-l1chainid']")"
assert_eq "…and pins.json still declares no network-level expectation to compare it against" \
  "UNESTABLISHED" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["live_chain"]["network"])' "$REPO_ROOT/pins.json")"
assert_eq "…so the three unpinned fields are exactly the ones pins.json names" \
  "l1ChainId l1RollupAddress rollupVersion" \
  "$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["live_chain"]["pin_discrimination_measured"]["differ_across_both_chains"]))' "$REPO_ROOT/pins.json")"

# ---------------------------------------------------------------------------
echo "== 8. a fixture without complete provenance is refused rather than loaded"
# ---------------------------------------------------------------------------
assert_eq "removing two provenance fields makes the loader refuse" "replay-malformed-fixture" \
  "$(f stripped.outcome)"
assert_eq "…naming both of them rather than dying on the first" "2" "$(f stripped.missingCount)"
assert_eq "…by name" "provenance.capturedAt,provenance.txHash" "$(f stripped.missingNames)"
assert_ge "…out of a required set that is not empty" 12 "$(f provenance.requiredFieldCount)"
assert_eq "…and the intact fixture loads, so the loader is not one that refuses everything" \
  "returned" "$(f reloaded.outcome)"

# ---------------------------------------------------------------------------
echo "== 9. getBlock needs { includeTransactions: true }, as a captured artefact"
#
# L0's live run found this and recorded it for L1. It is a fact about the node, so it is measured
# from the recording rather than repeated: without the option the node answers a BODY-LESS block
# and does NOT error, so a caller that did not notice would see an empty block.
# ---------------------------------------------------------------------------
assert_eq "with the option, the block carries a body" "yes" "$(f block.withOption.hasBody)"
assert_eq "…containing the transaction" "1" "$(f block.withOption.txEffects)"
assert_eq "…which is the one this fixture is about" "$(j "d['provenance']['txHash']")" \
  "$(f block.withOption.firstHash)"
assert_eq "…and the call itself returned rather than throwing" "returned" "$(f block.withOption.outcome)"
assert_eq "without the option, the node still answers" "yes" "$(f block.withoutOption.isDefined)"
assert_eq "…and does NOT error — measured, which is what makes it a trap" "returned" \
  "$(f block.withoutOption.outcome)"
assert_eq "…but there is no body, which is the trap" "no" "$(f block.withoutOption.hasBody)"
assert_eq "…and it is the same block both ways, so the option is the only difference" "yes" \
  "$(f block.sameBlock)"

# ---------------------------------------------------------------------------
echo "== 10. the second fixture: a settled transaction with NO public half"
#
# Declared, not an empty array — for the same reason the private half is declared rather than left
# blank. This is also what makes §4's 'every contract resolved' a measurement: the same code path
# over a transaction with nothing to resolve does not report success by having nothing to fail on.
# ---------------------------------------------------------------------------
assert_eq "it is the transaction that fixture is a recording of" "$(p "d['provenance']['txHash']")" \
  "$(f privateOnly.txHash)"
assert_eq "…in its own block" "$(p "d['provenance']['l2BlockNumber']")" "$(f privateOnly.blockNumber)"
assert_eq "the public half is declared ABSENT" "no" "$(f privateOnly.publicHalfPresent)"
assert_eq "…with the enqueued-call count the chain recorded" \
  "$(p "d['provenance']['nodeReported']['enqueuedPublicCalls']")" "$(f privateOnly.enqueuedCalls)"
assert_eq "…and no contracts to resolve" "0" "$(f privateOnly.contracts)"
assert_eq "…said in a sentence rather than by an empty array" "yes" \
  "$(f privateOnly.reasonSaysNoPublicCalls)"
assert_ge "…and the sentence is a real one" 100 "$(f privateOnly.reasonLength)"
assert_eq "the two fixtures are two different transactions" "yes" "$(f fixtures.distinctHashes)"
assert_eq "…in two different blocks" "yes" "$(f fixtures.distinctBlocks)"

finish
