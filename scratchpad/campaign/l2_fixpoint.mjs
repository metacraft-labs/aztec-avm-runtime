#!/usr/bin/env node
// l2_fixpoint.mjs — SCRATCHPAD. The discovery loop.
//
// L2's milestone offers two routes and BOTH ARE BLOCKED BY THE ARTEFACT, measured rather than
// argued (see l2_spike.mjs and the milestone entry this produced):
//
//   route 1, per-read witnesses from the node: there is NO SEAM at which the AVM asks TypeScript
//     for a world-state read. Its `MemoryMerkleDB` lives inside the module; TS can only WRITE into
//     it. The one entry point that takes hints instead of a DB, `avm_simulate_with_hinted_dbs`,
//     constructs `const PublicSimulatorConfig config = {}` internally
//     (barretenberg/cpp/src/barretenberg/vm2/avm_sim_api.cpp:46, comment "Placeholder for future
//     use of config from inputs"), so it CANNOT collect execution steps and therefore cannot
//     produce a `.ct`.
//
//   route 2, seed the resident trees from the block's state reference: `MemoryMerkleDB` has no
//     root setter, no bulk import and no constructor from a StateReference
//     (barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp:213-260). The
//     only way to a root is to append every leaf, and at block 62639 that is 1,106,368 note hashes
//     and 33,808 public-data leaves whose VALUES the node does not serve in bulk — which is the
//     ingestion engine this campaign was told not to build.
//
// SO THERE IS A THIRD ROUTE AND IT IS THE ONE THE ARTEFACT ADMITS. `PublicSimulatorConfig` has
// `collectHints`, and with it on the AVM reports EVERY world-state query it made — tree id, value,
// and whether it found it. So: run, read what it asked for, answer those questions from the node
// AT THE SETTLING BLOCK'S PARENT, seed the answers, run again. Repeat until the query set stops
// growing. The AVM names its own reads; nothing here guesses them.
//
// This is demo-shaped ON PURPOSE and it is not an ingestion engine: it seeds exactly the leaves ONE
// transaction touches, discovered from that transaction's own execution.

import { readFile, writeFile } from 'node:fs/promises';

import { compileAvm, instantiateAvm } from '../../node-host/src/loader.ts';
import { stepCount } from '../../node-host/src/steps.ts';

import { AvmFastSimulationInputs, AvmTxHint, PublicSimulatorConfig, serializeWithMessagePack }
  from '@aztec/stdlib/avm';
import { ProtocolContractsList, ProtocolContractAddress } from '@aztec/protocol-contracts';
import { WorldStateRevision } from '@aztec/stdlib/world-state';
import { TxHash } from '@aztec/stdlib/tx/tx-hash';
import { Fr } from '@aztec/foundation/curves/bn254';
import { computePublicBytecodeCommitment } from '@aztec/stdlib/contract';
import { siloNullifier } from '@aztec/stdlib/hash';

import { createReplayNodeClient, fetchSettledTransaction } from '../../replay/src/index.ts';
import { fixtureFetch, loadSettledFixture } from '../../replay/tools/settled_fixture.ts';

const NULLIFIER_TREE = 0;
const PUBLIC_DATA_TREE = 2;

const fixturePath = process.argv[2] ?? 'replay/fixtures/testnet_settled_tx_refblock.json';
const raw = JSON.parse(await readFile(fixturePath, 'utf8'));
const fixture = loadSettledFixture(raw, fixturePath);
const url = fixture.provenance.endpoint;

const client = createReplayNodeClient({ url, fetchImpl: fixtureFetch(fixture) });
const settled = await fetchSettledTransaction(client, TxHash.fromString(fixture.provenance.txHash),
  { pinToSettlingBlock: true });
const parent = settled.l2BlockNumber - 1;
const eff = settled.txEffect.data;

console.log(`subject ${settled.txHash}`);
console.log(`block   ${settled.l2BlockNumber} (pre-state read at ${parent}), published revertCode ${settled.revertCode}`);
console.log(`gasUsed published: ${JSON.stringify(settled.tx.data.gasUsed)}`);

// ---- the node, raw. Reads at a block, which is the whole question -----------------------------
async function rpc(method, params) {
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await fetch(url, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(40000),
      });
      const j = await res.json();
      if (j.error) return { __error: j.error };
      return j.result;
    } catch (e) { await new Promise(s => setTimeout(s, 400)); }
  }
  return { __error: 'unreachable' };
}

// ---- the module -------------------------------------------------------------------------------
const compiled = await compileAvm(process.env.AVM_WASM_PATH ?? 'vm2wasm/avm.wasm');

const globals = settled.blockData.header.globalVariables;
const config = {
  ...PublicSimulatorConfig.from({
    collectHints: true, collectStatistics: true, collectPublicInputs: true, collectDebugLogs: true,
  }),
  collectExecutionSteps: true,
};
const wsRevision = new WorldStateRevision(0, settled.l2BlockNumber, true);
const txHint = AvmTxHint.fromTx(settled.tx, globals.gasFees);
const inputBytes = serializeWithMessagePack(
  new AvmFastSimulationInputs(wsRevision, config, txHint, globals, ProtocolContractsList));

/** Everything seeded so far, keyed so a round can say what it ADDED. */
const seedNullifiers = new Map();   // hex -> Fr
const seedPublicData = new Map();   // slot hex -> { slot, value }

async function runOnce() {
  // A FRESH MODULE EVERY ROUND. The resident DB has no reset, and a round that reused the previous
  // round's tree would be measuring the union of two seedings against one execution.
  const reactor = await instantiateAvm(compiled);
  const contractDb = reactor.createContractDb();
  const merkleDb = reactor.createMerkleDb();

  for (const c of settled.contracts) {
    const cc = c.contractClass;
    reactor.callWithBlob('avm_contract_db_register_class', contractDb, serializeWithMessagePack({
      id: cc.id, artifactHash: cc.artifactHash, privateFunctionsRoot: cc.privateFunctionsRoot,
      packedBytecode: cc.packedBytecode,
      publicBytecodeCommitment: await computePublicBytecodeCommitment(cc.packedBytecode),
    }));
    const i = c.instance;
    reactor.callWithBlob('avm_contract_db_register_instance', contractDb, serializeWithMessagePack([
      i.address, {
        salt: i.salt, deployer: i.deployer, currentContractClassId: i.currentContractClassId,
        originalContractClassId: i.originalContractClassId,
        initializationHash: i.initializationHash, immutablesHash: i.immutablesHash,
        publicKeys: i.publicKeys,
      },
    ]));
  }
  for (const n of seedNullifiers.values()) {
    if (n === null) continue;
    reactor.callWithBlob('avm_merkle_db_insert_indexed_leaves_nullifier_tree', merkleDb,
      serializeWithMessagePack({ nullifier: n }));
  }
  for (const entry of seedPublicData.values()) {
    if (entry === null) continue;
    const { slot, value } = entry;
    reactor.callWithBlob('avm_merkle_db_insert_indexed_leaves_public_data_tree', merkleDb,
      serializeWithMessagePack({ slot, value }));
  }

  let outcome = null, threw = null;
  try {
    outcome = reactor.simulate(inputBytes, contractDb, merkleDb);
  } catch (err) {
    threw = err;
  }
  const steps = (() => { try { return stepCount(reactor); } catch { return -1; } })();
  return { reactor, outcome, threw, steps };
}

/** Every world-state question this run asked, as (treeId, value). The AVM's own report. */
function queriesFrom(outcome) {
  const hints = outcome?.result?.hints ?? {};
  const out = [];
  for (const h of hints.getPreviousValueIndexHints ?? []) {
    out.push({ treeId: Number(h.treeId), value: asHex(h.value), alreadyPresent: !!h.alreadyPresent });
  }
  return out;
}
function asHex(v) {
  if (typeof v === 'string') return v.toLowerCase();
  if (v instanceof Uint8Array) return '0x' + Buffer.from(v).toString('hex');
  if (v && typeof v === 'object' && typeof v.toString === 'function') return v.toString().toLowerCase();
  return String(v);
}

// The one nullifier a replay must NOT take from the chain: the transaction's OWN. It is in the
// TxEffect because the transaction emitted it, and seeding it would make the AVM's own duplicate
// check find it and revert — a replay failing because it succeeded.
const ownNullifiers = new Set(eff.nullifiers.map(n => n.toString().toLowerCase()));
// Its own writes are excluded for the mirror reason: what the transaction WROTE is not what it SAW.
const ownWriteSlots = new Set(eff.publicDataWrites.map(w => w.leafSlot.toString().toLowerCase()));

let round = 0;
let last = null;
const log = [];
for (;;) {
  round += 1;
  const run = await runOnce();
  last = run;
  const queries = run.outcome ? queriesFrom(run.outcome) : [];
  const revert = run.outcome?.revertCode;
  console.log(`\n=== round ${round} === steps=${run.steps} revertCode=${revert ?? '(threw)'}`
    + (run.threw ? ` threw=${run.threw.name}: ${String(run.threw.message).slice(0, 120)}` : '')
    + ` queries=${queries.length} seeded=${seedNullifiers.size}N/${seedPublicData.size}P`);

  // Answer every question this round asked that is not already seeded.
  let added = 0;
  for (const q of queries) {
    if (q.treeId === NULLIFIER_TREE) {
      if (seedNullifiers.has(q.value) || ownNullifiers.has(q.value)) continue;
      const wit = await rpc('aztec_getNullifierMembershipWitness', [parent, q.value]);
      if (!wit || wit.__error || wit === null) {
        console.log(`   nullifier ${q.value.slice(0, 18)}… ABSENT on chain at ${parent}`
          + (wit?.__error ? ` (${JSON.stringify(wit.__error).slice(0, 100)})` : ''));
        seedNullifiers.set(q.value, null); // remembered as answered-absent, so the loop terminates
        continue;
      }
      seedNullifiers.set(q.value, Fr.fromHexString(q.value));
      added += 1;
      console.log(`   nullifier ${q.value.slice(0, 18)}… PRESENT on chain -> seeded`);
    } else if (q.treeId === PUBLIC_DATA_TREE) {
      if (seedPublicData.has(q.value) || ownWriteSlots.has(q.value)) continue;
      const wit = await rpc('aztec_getPublicDataWitness', [parent, q.value]);
      const leaf = wit?.leafPreimage?.leaf;
      if (!leaf) {
        console.log(`   slot ${q.value.slice(0, 18)}… NO WITNESS at ${parent}`);
        seedPublicData.set(q.value, null);
        continue;
      }
      if (leaf.slot.toLowerCase() !== q.value) {
        console.log(`   slot ${q.value.slice(0, 18)}… EMPTY at ${parent} (witness names ${leaf.slot.slice(0, 14)}…)`);
        seedPublicData.set(q.value, null);
        continue;
      }
      seedPublicData.set(q.value, { slot: Fr.fromHexString(leaf.slot), value: Fr.fromHexString(leaf.value) });
      added += 1;
      console.log(`   slot ${q.value.slice(0, 18)}… = ${leaf.value} -> seeded`);
    }
  }
  // The transaction's own writes ARE reads too: a read-modify-write reads before it writes. Seed
  // them from the parent block on the first round so the loop does not need a round per slot.
  if (round === 1) {
    for (const w of eff.publicDataWrites) {
      const slot = w.leafSlot.toString().toLowerCase();
      if (seedPublicData.has(slot)) continue;
      const wit = await rpc('aztec_getPublicDataWitness', [parent, slot]);
      const leaf = wit?.leafPreimage?.leaf;
      if (leaf && leaf.slot.toLowerCase() === slot) {
        seedPublicData.set(slot, { slot: Fr.fromHexString(leaf.slot), value: Fr.fromHexString(leaf.value) });
        added += 1;
      } else {
        seedPublicData.set(slot, null);
      }
    }
    // And the contract's deployment nullifier, which is how the AVM decides a contract exists.
    for (const c of settled.contracts) {
      const dep = await siloNullifier(ProtocolContractAddress.ContractInstanceRegistry, Fr.fromHexString(c.address));
      const key = dep.toString().toLowerCase();
      if (!seedNullifiers.has(key)) { seedNullifiers.set(key, dep); added += 1; }
    }
    console.log(`   round 1 also seeded the write set's pre-images and the deployment nullifier`);
  }
  log.push({ round, steps: run.steps, revertCode: revert ?? null, queries: queries.length, added,
             seededNullifiers: [...seedNullifiers.keys()], seededSlots: [...seedPublicData.keys()] });

  const seededSomething = [...seedPublicData.values()].filter(Boolean).length
    + [...seedNullifiers.values()].filter(Boolean).length;
  if (added === 0) {
    console.log(`\nFIXPOINT after ${round} round(s): the AVM asked for nothing new. `
      + `${seededSomething} leaves seeded.`);
    break;
  }
  if (round >= 12) { console.log('\nGAVE UP at 12 rounds — the query set is still growing.'); break; }
}

// ---- the comparison ---------------------------------------------------------------------------
console.log('\n=== replay vs the chain ===');
const r = last.outcome?.result;
console.log('published revertCode', settled.revertCode, '   replayed', last.outcome?.revertCode ?? '(threw)');
console.log('published gasUsed   ', JSON.stringify(settled.tx.data.gasUsed));
console.log('replayed  gasUsed   ', JSON.stringify(r?.gasUsed, (k, v) => typeof v === 'bigint' ? String(v) : v));
console.log('replayed  steps     ', last.steps);
console.log('replayed  stats     ', JSON.stringify(r?.stats));
const te = r?.publicTxEffect;
if (te) {
  const j = JSON.stringify(te, (k, v) => v instanceof Uint8Array ? '0x' + Buffer.from(v).toString('hex')
    : (typeof v === 'bigint' ? String(v) : v));
  console.log('replayed  publicTxEffect keys', Object.keys(te));
  await writeFile('scratchpad/campaign/l2-replay-effect.json', j);
}
await writeFile('scratchpad/campaign/l2-fixpoint-log.json', JSON.stringify(log, null, 2));
console.log('\npublished publicDataWrites', eff.publicDataWrites.length, 'nullifiers', eff.nullifiers.length);
