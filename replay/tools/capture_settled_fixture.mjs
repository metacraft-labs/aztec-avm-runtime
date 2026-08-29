#!/usr/bin/env node
// capture_settled_fixture.mjs — L1's capture script, committed beside the fixtures it produced.
//
// "Fixtures captured from a live chain and committed, so the suite runs without a network, with the
//  capture script committed beside them."
//
// WHAT IT CAPTURES, AND WHY EACH PIECE IS THERE.
//
// It drives THE REAL `fetchSettledTransaction` against a live node through `recordingFetch`, so the
// recording is exactly the set of JSON-RPC calls the deliverable makes — not a list somebody
// guessed at. Then it adds four deliberate probes whose answers the checks need and which a
// successful fetch never makes:
//
//   * a FABRICATED transaction hash, so `e2e_fetch_settled_transaction`'s control ("an unknown hash
//     is refused by name") runs offline against a REAL NODE's real `null`, rather than against a
//     null this repository synthesised. The distinction matters: a synthesised null proves that our
//     code turns null into a refusal; a captured one proves that this is what the chain says.
//   * a FABRICATED contract address and a FABRICATED contract class id, for the same reason, in
//     `test_missing_contract_artifact_refused`.
//   * `getBlock(n)` WITHOUT `{ includeTransactions: true }`, because L0's live run found that this
//     answers a body-less block rather than an error, and a caller that did not notice would see an
//     empty block. That is now a captured artefact instead of a sentence in a log.
//
// EVERY FABRICATED VALUE IS DECLARED in `provenance.fabricatedProbes`, by name, with what it is
// for. An unlabelled fixture is the failure mode this campaign is built to avoid, and a fabricated
// datum sitting unlabelled beside real ones is the sharpest form of it.
//
// THE VERSION HEADERS ARE TAKEN TWICE, and `settled_fixture.ts`'s header says why: dRPC's proxy
// returns `x-aztec-*` on a single-object POST and strips them on the batch POST upstream's client
// always sends. The recording keeps what the CLIENT SAW as `onBatchPost` (empty, through a proxy)
// and the un-batched probe as `onSingleObjectPost`, labelled a reconstruction. A fixture that
// silently stored the second would pass a version check the live endpoint fails.
//
// Usage:
//   node replay/tools/capture_settled_fixture.mjs --url <rpc> --out <path> [--tx <hash>] [--search N]
//
// With no `--tx` it walks back from the tip until it finds a block with transactions and takes the
// first one whose body the node still serves — see `settled_transaction.ts` on `getTxByHash`'s
// retention horizon, which is why "recent" is not optional.

import { writeFileSync } from 'node:fs';

import { defaultFetch } from '@aztec/foundation/json-rpc/client';
import { TxHash } from '@aztec/stdlib/tx/tx-hash';
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { Fr } from '@aztec/foundation/curves/bn254';

import { createReplayNodeClient, fetchSettledTransaction } from '../src/index.ts';
import { SETTLED_FIXTURE_FORMAT, recordingFetch } from './settled_fixture.ts';
import { COMPONENTS_VERSION_FIELDS } from '../src/pinned_protocol_version.ts';

const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : fallback;
};

const url = arg('url', 'https://aztec-testnet.drpc.org');
const out = arg('out');
const chain = arg('chain', url.includes('testnet') ? 'aztec-testnet' : 'aztec-mainnet');
const searchDepth = Number(arg('search', 60));
if (!out) {
  console.error('capture_settled_fixture: --out <path> is required');
  process.exit(2);
}

const headerNames = COMPONENTS_VERSION_FIELDS.map((f) => `x-aztec-${f.toLowerCase()}`);
const sink = { calls: [], batchHeaders: {}, headerNames };
const client = createReplayNodeClient({ url, fetchImpl: recordingFetch(defaultFetch, sink) });

// ---- 1. what the node says about itself, and where the tip is -------------------------------
const nodeInfo = await client.getNodeInfo();
const tip = await client.getBlockNumber();
console.error(`capture: ${url} nodeVersion=${nodeInfo.nodeVersion} l1ChainId=${nodeInfo.l1ChainId} tip=${tip}`);

// ---- 2. the transaction ----------------------------------------------------------------------
let txHash = arg('tx');
let blockNumber;
if (txHash) {
  const effect = await client.fetchSettledTxEffect(TxHash.fromString(txHash));
  blockNumber = Number(effect.l2BlockNumber);
} else {
  // Walk back from the tip. The FIRST candidate whose body the node still serves wins, because
  // `getTxByHash` prunes and the effect does not — a hash read out of a block body is not a
  // promise that the transaction is still fetchable.
  search: for (let n = tip; n > tip - searchDepth; n--) {
    const block = await client.getBlock(n, { includeTransactions: true });
    const effects = block?.body?.txEffects ?? [];
    for (const effect of effects) {
      try {
        await client.fetchSettledTx(effect.txHash);
      } catch (err) {
        console.error(`capture: block ${n} tx ${effect.txHash.toString()} is pruned (${err.name}), skipping`);
        continue;
      }
      txHash = effect.txHash.toString();
      blockNumber = n;
      break search;
    }
  }
}
if (!txHash) {
  console.error(`capture: no fetchable transaction in the last ${searchDepth} blocks of ${url}`);
  process.exit(1);
}
console.error(`capture: transaction ${txHash} in block ${blockNumber}`);

// THE DELIVERABLE ITSELF, recorded by running it. Every call the fixture carries for the happy
// path is a call `fetchSettledTransaction` made, in the order it made it.
const settled = await fetchSettledTransaction(client, TxHash.fromString(txHash));

// ---- 3. the block, both ways -----------------------------------------------------------------
// With the option, so the fixture supports "find a recent block and read its transactions"; and
// WITHOUT it, so the body-less answer L0 met live is a captured artefact.
await client.getBlock(settled.l2BlockNumber, { includeTransactions: true });
await client.getBlock(settled.l2BlockNumber);

// ---- 4. the fabricated probes ----------------------------------------------------------------
// Values that do not exist on this chain, asked of the live node so its own refusal is on record.
const fabricatedTxHash = TxHash.fromField(new Fr(0xf1c71710n));
const fabricatedAddress = AztecAddress.fromFieldUnsafe(new Fr(0xf1c71710n));
const fabricatedClassId = new Fr(0xf1c71711n);
const probe = async (label, thunk) => {
  try {
    const value = await thunk();
    console.error(`capture: probe ${label} -> ${value === undefined ? 'undefined' : 'a value'}`);
  } catch (err) {
    console.error(`capture: probe ${label} threw ${err?.name ?? 'unknown'} (recorded anyway)`);
  }
};
await probe('getTxByHash(fabricated)', () => client.getTxByHash(fabricatedTxHash));
await probe('getTxEffect(fabricated)', () => client.getTxEffect(fabricatedTxHash));
await probe('getContract(fabricated)', () => client.getContract(fabricatedAddress));
await probe('getContractClass(fabricated)', () => client.getContractClass(fabricatedClassId));

// ---- 5. the un-batched header probe ----------------------------------------------------------
// Deliberately NOT through upstream's client: the whole point is that this is the shape upstream's
// client never sends. A raw single-object POST, and whatever headers come back.
const singlePostHeaders = {};
try {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'aztec_getBlockNumber', params: [] }),
  });
  for (const name of headerNames) {
    const value = res.headers.get(name);
    if (value !== null && value !== undefined) {
      singlePostHeaders[name] = value;
    }
  }
  await res.text();
} catch (err) {
  console.error(`capture: the un-batched header probe failed: ${err?.message ?? err}`);
}

// ---- 6. write ---------------------------------------------------------------------------------
const fixture = {
  format: SETTLED_FIXTURE_FORMAT,
  provenance: {
    endpoint: url,
    chain,
    l1ChainId: nodeInfo.l1ChainId,
    rollupVersion: nodeInfo.rollupVersion,
    l1RollupAddress: nodeInfo.l1ContractAddresses.rollupAddress.toString(),
    nodeVersion: nodeInfo.nodeVersion,
    capturedAt: new Date().toISOString(),
    capturedBy: 'replay/tools/capture_settled_fixture.mjs',
    txHash: settled.txHash,
    l2BlockNumber: settled.l2BlockNumber,
    txIndexInBlock: settled.txIndexInBlock,
    chainTipAtCapture: tip,
    nodeReported: {
      revertCode: settled.revertCode,
      l2BlockHash: settled.l2BlockHash,
      transactionFee: settled.txEffect.data.transactionFee.toString(),
      enqueuedPublicCalls: settled.publicHalf.enqueuedCalls,
      hasTeardown: settled.publicHalf.hasTeardown,
      publicCallTargets: settled.contracts.map((c) => c.address),
      contracts: settled.contracts.map((c) => ({
        address: c.address,
        contractClassId: c.contractClassId,
        originalContractClassId: c.originalContractClassId,
        packedBytecodeBytes: c.packedBytecodeBytes,
      })),
      publishedEffects: {
        noteHashes: settled.txEffect.data.noteHashes.length,
        nullifiers: settled.txEffect.data.nullifiers.length,
        privateLogs: settled.txEffect.data.privateLogs.length,
        publicLogs: settled.txEffect.data.publicLogs.length,
        publicDataWrites: settled.txEffect.data.publicDataWrites.length,
        contractClassLogs: settled.txEffect.data.contractClassLogs.length,
        l2ToL1Msgs: settled.txEffect.data.l2ToL1Msgs.length,
      },
      globalVariables: {
        blockNumber: settled.blockData.header.globalVariables.blockNumber,
        timestamp: String(settled.blockData.header.globalVariables.timestamp),
        chainId: settled.blockData.header.globalVariables.chainId.toString(),
        version: settled.blockData.header.globalVariables.version.toString(),
        feePerDaGas: String(settled.blockData.header.globalVariables.gasFees.feePerDaGas),
        feePerL2Gas: String(settled.blockData.header.globalVariables.gasFees.feePerL2Gas),
      },
      stateReference: {
        noteHashTreeRoot: settled.blockData.header.state.partial.noteHashTree.root.toString(),
        nullifierTreeRoot: settled.blockData.header.state.partial.nullifierTree.root.toString(),
        publicDataTreeRoot: settled.blockData.header.state.partial.publicDataTree.root.toString(),
        l1ToL2MessageTreeRoot: settled.blockData.header.state.l1ToL2MessageTree.root.toString(),
        archiveRoot: settled.blockData.archive.root.toString(),
      },
    },
    fabricatedProbes: {
      note:
        'These three values do NOT exist on this chain. They were asked of the live node so that '
        + "its own 'not found' answers are on the record and the refusal checks run offline "
        + 'against a real node answer rather than a synthesised null. Nothing else in this file is '
        + 'fabricated.',
      txHash: fabricatedTxHash.toString(),
      contractAddress: fabricatedAddress.toString(),
      contractClassId: fabricatedClassId.toString(),
    },
    versionHeaders: {
      onBatchPost: sink.batchHeaders,
      onSingleObjectPost: singlePostHeaders,
      note:
        'onBatchPost is what upstream\'s client SAW, on the batch (array) POST it always sends. '
        + 'onSingleObjectPost is a deliberately un-batched probe taken in the same run and is a '
        + 'RECONSTRUCTION, never what the client saw. Through a proxying RPC provider the first is '
        + 'empty and the second carries the pinned protocol values, which is why '
        + 'assertProtocolVersion refuses such an endpoint naming the absence. Playing back the '
        + 'first reproduces that refusal offline; playing back the second measures that the '
        + 'obstacle is the proxy and not the version check.',
    },
  },
  calls: sink.calls,
};

writeFileSync(out, `${JSON.stringify(fixture, null, 2)}\n`);
console.error(
  `capture: wrote ${out} — ${sink.calls.length} recorded call(s), `
    + `${Object.keys(sink.batchHeaders).length} batch header(s), `
    + `${Object.keys(singlePostHeaders).length} single-post header(s)`,
);
