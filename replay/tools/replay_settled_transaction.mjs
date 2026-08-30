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
  RUNG_BYTECODE_VALUE,
  buildSettledRecording,
  createReplayNodeClient,
  encodeRecordingInputs,
  encodeReplayInputs,
  fetchSettledTransaction,
  recordingIdFor,
  recordingPass,
  replaySettledTransaction,
} from '../src/index.ts';
import { CtWriter, instantiateCtWriter, resolveTracingConfig, WRITER_PATH_A_PURE_RUST }
  from '../../ct-host/src/index.ts';
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
const ctOut = arg('ct');
const ctWriterPath = arg('ct-writer', process.env.CT_WRITER_WASM_PATH
  ?? 'ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm');
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

// ---- L3: THE RECORDING --------------------------------------------------------------------------
// Written BEFORE the wrong-block control pass, deliberately: the control re-runs the loop and would
// leave `outcome` describing an execution nobody wants a container of.
let recording = null;
if (ctOut) {
  const writerBytes = await readFile(ctWriterPath);
  // THE SESSION IS OPENED AT RUNG 3 AND THE MODULE IS TOLD SO TWICE — here, and again per contract
  // through `declareRung`. `recording.ts` explains why 3 is a ceiling and not a shortfall: an Aztec
  // node serves no debug symbols and no file map, so there is nothing to position a pc with.
  const writer = new CtWriter(
    await instantiateCtWriter(writerBytes),
    resolveTracingConfig({
      program: 'aztec-live-chain-replay',
      recordingId: recordingIdFor(settled.txHash,
        settled.blockData.header.globalVariables.timestamp),
      sourcePath: `/aztec/${settled.txHash}.avm`,
      workdir: '/aztec',
      mappingRung: RUNG_BYTECODE_VALUE,
      // COLUMNS OFF, AND THE ARTEFACT REFUSED THEM BEFORE THIS COMMENT EXISTED.
      // The first draft copied `columns: true` from the browser path, which is at rung 1 and has
      // real source columns. `resolveTracingConfig` threw `ColumnAwarenessUnavailable`: "enabling
      // column mode would advertise breakpoint-sharp columns over positions that are program
      // counters." That is M24's guard catching this milestone in exactly the dishonesty this
      // milestone is otherwise built to avoid, and it is recorded rather than quietly corrected.
      columns: false,
    }, WRITER_PATH_A_PURE_RUST),
    { batchRecords: 64 },
  );
  // THE STEP PASS. The hydration pass ran with `collectHints` on and therefore produced NO step
  // stream — see RECORDING_PASS_REASON. This runs the same seed again with the flags the other way
  // round, and REFUSES if the two passes do not describe the same execution.
  const pass = await recordingPass(host, settled, outcome, encodeRecordingInputs);
  console.error(`replay: step pass — ${pass.steps?.length ?? 'NULL'} step(s), revertCode `
    + `${pass.revertCode}, ${pass.verdict.matched}/${pass.verdict.comparisons.length} matched, `
    + 'and it agrees with the hydration pass');
  recording = buildSettledRecording(writer, settled, { ...outcome, steps: pass.steps }, pass.steps);
  await writeFile(ctOut, recording.container);
  console.error(`replay: wrote ${ctOut} — ${recording.bytes} bytes, ${recording.events} event(s), `
    + `${recording.steps} step(s), ${recording.callsOpened} frame(s), `
    + `${recording.logEvents} log event(s), rung ${recording.declaredRung}`);
}

// ---- THE CONTROL'S DATA, CAPTURED AS A REAL CHAIN ANSWER ----------------------------------------
// `e2e_replay_matches_published_effects`'s control replays against the WRONG block's state — the
// SETTLING block instead of its parent — so every read returns the value the transaction itself
// wrote and the comparison must fail. That control has to run OFFLINE like everything else, so its
// answers are captured here, from the live node, in the same run.
//
// IT IS A SECOND PASS AND NOT A SECOND FUNCTION. The loop is re-run with
// `preStateBlockForControls: 'settling-block'`, so what gets recorded is exactly the set of calls
// the control will make — the same discovery, at the other block. Listing the slots by hand would
// be a guess about what the control asks for, which is the mistake `historical_state.ts` exists to
// stop being made about the subject.
//
// L1's precedent: its fabricated probes are asked OF THE LIVE NODE so that its own answers are on
// record, rather than synthesised. Same here, with nothing fabricated at all — every one of these
// is a real witness at a real block.
if (capturePath) {
  console.error('replay: capturing the wrong-block control\'s answers (pre-state at the SETTLING '
    + 'block, which is what the control replays against)');
  try {
    await replaySettledTransaction(host, client, settled, encodeReplayInputs, {
      preStateBlockForControls: 'settling-block',
      onRound: (r) => console.error(
        `replay: [control] round ${r.round} — ${r.queries} reported, ${r.added} seeded`),
    });
    console.error('replay: [control] the wrong-block run CONVERGED — its calls are recorded');
  } catch (err) {
    // A control that refuses is still a control, and its calls are still recorded. What must not
    // happen is the capture aborting: the subject's own recording is already complete by this
    // point, and losing it because the control threw would be the tail wagging the dog.
    console.error(`replay: [control] the wrong-block run ended with ${err?.name ?? 'an error'} — `
      + 'recorded anyway, which is what the control is for');
  }
}

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
  steps: outcome.steps?.length ?? null,
  recording: recording === null ? null : {
    bytes: recording.bytes, events: recording.events, steps: recording.steps,
    callsOpened: recording.callsOpened, logEvents: recording.logEvents,
    declaredRung: recording.declaredRung, distinctOpcodes: recording.distinctOpcodes,
    contexts: recording.contexts, stepsPositioned: recording.stepsPositioned,
    stepsUnpositioned: recording.stepsUnpositioned,
  },
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
