#!/usr/bin/env node
// replay_settled_transaction.mjs — L2's driver: a settled transaction, re-executed.
//
// TWO MODES, AND THE SECOND IS WHY THE FIRST EXISTS.
//
//   --fixture <path>   play a recording back. NO NETWORK. This is the mode the checks run in.
//   --url <rpc> --capture <path>
//                      drive a LIVE node through `recordingFetch` and write the recording, so that
//                      every node call the replay made — including the per-slot hydration reads —
//                      is in the fixture and the check that comes after it is offline.
//
// The capture mode is the only honest way to build the fixture. L1's capture recorded the calls
// `fetchSettledTransaction` makes, which are known in advance; L2's hydration calls are NOT known in
// advance — the AVM discovers them — so the only list that can be right is the one produced by
// running the thing. `historical_state.ts` explains why that is the design and not a shortcut.
//
// AND THE HYDRATION READS GO THROUGH THE CLIENT, NOT THROUGH `fetch`. Both of them,
// `getPublicDataWitness` and `getNullifierMembershipWitness`, are already on L0's permitted fourteen
// and are members of the `MembershipWitnessSource` seam L0 declared for exactly this. So L2 needs no
// widening of the surface, no adapter, and no second wire path — and a recording made through the
// client is a recording upstream's own zod validates on every playback.

import { readFile, writeFile } from 'node:fs/promises';

import { defaultFetch } from '@aztec/foundation/json-rpc/client';
import { TxHash } from '@aztec/stdlib/tx/tx-hash';

import {
  createReplayNodeClient,
  encodeReplayInputs,
  fetchSettledTransaction,
  replaySettledTransaction,
} from '../src/index.ts';
import { COMPONENTS_VERSION_FIELDS } from '../src/pinned_protocol_version.ts';
import { createNodeAvmHost } from './node_avm_host.ts';
import {
  SETTLED_FIXTURE_FORMAT,
  fixtureFetch,
  loadSettledFixture,
  recordingFetch,
} from './settled_fixture.ts';

const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : fallback;
};

const fixturePath = arg('fixture');
const capturePath = arg('capture');
const modulePath = arg('module', process.env.AVM_WASM_PATH);
const json = argv.includes('--json');

if (!modulePath) {
  console.error('replay: --module <avm.wasm> (or AVM_WASM_PATH) is required. The shipped module is '
    + 'the one M9\'s observer patch is in; an unpatched build refuses the encoding by name.');
  process.exit(2);
}

let client;
let txHash;
let sink;
let url;

if (fixturePath) {
  const fixture = loadSettledFixture(JSON.parse(await readFile(fixturePath, 'utf8')), fixturePath);
  url = fixture.provenance.endpoint;
  txHash = fixture.provenance.txHash;
  client = createReplayNodeClient({ url, fetchImpl: fixtureFetch(fixture) });
} else {
  url = arg('url');
  if (!url) {
    console.error('replay: either --fixture <path> or --url <rpc> is required');
    process.exit(2);
  }
  sink = { calls: [], batchHeaders: {}, headerNames: COMPONENTS_VERSION_FIELDS.map(f => `x-aztec-${f.toLowerCase()}`) };
  client = createReplayNodeClient({ url, fetchImpl: recordingFetch(defaultFetch, sink) });
  txHash = arg('tx');
  if (!txHash) {
    // Walk back from the tip for a transaction whose BODY the node still serves. The horizon is a
    // finality lag, so `getBlockNumber('finalized')` bounds the search rather than a guessed depth.
    const tip = await client.getBlockNumber();
    const finalized = await client.getBlockNumber('finalized');
    console.error(`replay: tip ${tip}, finalized ${finalized} — ${tip - finalized} replayable block(s)`);
    search: for (let n = tip; n > finalized; n--) {
      const block = await client.getBlock(n, { includeTransactions: true });
      for (const effect of block?.body?.txEffects ?? []) {
        // FIRST IN ITS BLOCK ONLY. `IntraBlockPredecessorsUnavailable` is the refusal, and finding
        // out here rather than after a fetch keeps the recording free of a transaction it cannot use.
        if (effect !== block.body.txEffects[0]) continue;
        try { await client.fetchSettledTx(effect.txHash); } catch { continue; }
        txHash = effect.txHash.toString();
        break search;
      }
    }
    if (!txHash) {
      console.error('replay: no first-in-block transaction with a retained body above the finalized tip');
      process.exit(1);
    }
  }
}

console.error(`replay: ${txHash} via ${url}`);

const settled = await fetchSettledTransaction(client, TxHash.fromString(txHash), {
  pinToSettlingBlock: true,
});
const host = await createNodeAvmHost(modulePath);

const outcome = await replaySettledTransaction(host, client, settled, encodeReplayInputs, {
  onRound: (r) => console.error(
    `replay: round ${r.round} — ${r.queries} quer(y|ies) reported, ${r.added} leaf/leaves seeded, `
    + `${r.skipped.length} skipped`),
});

// ---- the report -------------------------------------------------------------------------------
const report = {
  txHash: settled.txHash,
  l2BlockNumber: settled.l2BlockNumber,
  preStateReadAt: settled.l2BlockNumber - 1,
  txIndexInBlock: settled.txIndexInBlock,
  contractReferenceBlock: settled.contracts[0]?.resolvedAsOf ?? null,
  rounds: outcome.rounds.length,
  seedSize: outcome.seedSize,
  instructionsExecuted: outcome.instructionsExecuted,
  published: { revertCode: settled.revertCode },
  replayed: { revertCode: outcome.revertCode },
  verdict: {
    reproduced: outcome.verdict.reproduced,
    matched: outcome.verdict.matched,
    mismatched: outcome.verdict.mismatched,
  },
  mismatches: outcome.verdict.comparisons.filter(c => !c.matches),
  roots: outcome.roots.declarations,
  rootsAnyAgree: outcome.roots.anyAgrees,
  skipped: outcome.rounds.flatMap(r => r.skipped.map(s => ({ value: s.value, reason: s.reason }))),
};

if (json) {
  console.log(JSON.stringify(report, null, 2));
} else {
  console.log(`\ntransaction ${report.txHash}`);
  console.log(`block ${report.l2BlockNumber} (index ${report.txIndexInBlock}), `
    + `pre-state read at ${report.preStateReadAt}, contracts resolved as of ${report.contractReferenceBlock}`);
  console.log(`hydration: ${report.rounds} round(s), `
    + `${report.seedSize.nullifiers} nullifier(s) + ${report.seedSize.publicData} public-data leaf/leaves seeded`);
  console.log(`executed:  ${report.instructionsExecuted} instruction(s)`);
  console.log(`revertCode: published ${report.published.revertCode}, replayed ${report.replayed.revertCode}`);
  console.log(`published effects reproduced: ${report.verdict.reproduced ? 'YES' : 'NO'} `
    + `(${report.verdict.matched} matched, ${report.verdict.mismatched} mismatched)`);
  for (const m of report.mismatches) {
    console.log(`   MISMATCH ${m.field}: published ${m.published} replayed ${m.replayed}`);
  }
  console.log('\ntree roots — EXPECTED TO DIFFER, and the reason travels with the outcome:');
  for (const d of report.roots) {
    console.log(`   ${d.tree.padEnd(20)} resident ${d.resident.slice(0, 18)}…  chain ${d.chain.slice(0, 18)}…  ${d.agrees ? 'AGREES' : 'differs'}`);
  }
}

if (capturePath) {
  const nodeInfo = await client.getNodeInfo();
  const fixture = {
    format: SETTLED_FIXTURE_FORMAT,
    provenance: {
      endpoint: url,
      chain: url.includes('testnet') ? 'aztec-testnet' : 'aztec-mainnet',
      l1ChainId: nodeInfo.l1ChainId,
      rollupVersion: nodeInfo.rollupVersion,
      l1RollupAddress: nodeInfo.l1ContractAddresses.rollupAddress.toString(),
      nodeVersion: nodeInfo.nodeVersion,
      capturedAt: new Date().toISOString(),
      capturedBy: 'replay/tools/replay_settled_transaction.mjs --capture',
      txHash: settled.txHash,
      l2BlockNumber: settled.l2BlockNumber,
      txIndexInBlock: settled.txIndexInBlock,
      chainTipAtCapture: await client.getBlockNumber(),
      contractReferenceBlock: settled.contracts[0]?.resolvedAsOf ?? 'latest',
      contractReferenceBlockRequested: 'settling-block',
      replayReport: report,
      nodeReported: {
        revertCode: settled.revertCode,
        l2BlockHash: settled.l2BlockHash,
        transactionFee: settled.txEffect.data.transactionFee.toString(),
        enqueuedPublicCalls: settled.publicHalf.enqueuedCalls,
        hasTeardown: settled.publicHalf.hasTeardown,
        publicCallTargets: settled.contracts.map(c => c.address),
        contracts: settled.contracts.map(c => ({
          address: c.address, contractClassId: c.contractClassId,
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
        note: 'This L2 recording contains NO fabricated values. Every call in it is a call the '
          + 'replay itself made against a live node. L1\'s fixtures carry deliberate probes for '
          + 'their refusal controls; this one does not, and says so rather than leaving the field out.',
      },
      versionHeaders: {
        onBatchPost: sink.batchHeaders,
        onSingleObjectPost: {},
        note: 'onBatchPost is what upstream\'s client SAW. This capture does not take the un-batched '
          + 'reconstruction L1\'s does — see pins.json live_chain: the proxy strips the headers on '
          + 'the batch POST upstream always sends, which is measured there and not re-measured here.',
      },
    },
    calls: sink.calls,
  };
  await writeFile(capturePath, `${JSON.stringify(fixture, null, 2)}\n`);
  console.error(`replay: wrote ${capturePath} — ${sink.calls.length} recorded call(s)`);
}

process.exit(outcome.verdict.reproduced ? 0 : 1);
