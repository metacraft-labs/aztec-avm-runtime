#!/usr/bin/env node
// l2_spike.mjs — SCRATCHPAD. Can the AVM be made to re-execute a settled transaction at all?
//
// Not a deliverable and not a check. This is the "enumerate before building" step: drive the
// pieces that already exist over L2's own captured fixture and find out what actually happens,
// before writing a module that assumes it works.

import { readFile } from 'node:fs/promises';

import { compileAvm, instantiateAvm } from '../../node-host/src/loader.ts';
import { stepCount } from '../../node-host/src/steps.ts';

import { AvmFastSimulationInputs, AvmTxHint, PublicSimulatorConfig, serializeWithMessagePack }
  from '@aztec/stdlib/avm';
import { ProtocolContractsList, ProtocolContractAddress } from '@aztec/protocol-contracts';
import { WorldStateRevision } from '@aztec/stdlib/world-state';
import { TxHash } from '@aztec/stdlib/tx/tx-hash';
import { Fr } from '@aztec/foundation/curves/bn254';
import { computePublicBytecodeCommitment } from '@aztec/stdlib/contract';
import { computeFeePayerBalanceStorageSlot } from '@aztec/protocol-contracts/fee-juice';
import { computePublicDataTreeLeafSlot, siloNullifier } from '@aztec/stdlib/hash';

import { createReplayNodeClient, fetchSettledTransaction } from '../../replay/src/index.ts';
import { fixtureFetch, loadSettledFixture } from '../../replay/tools/settled_fixture.ts';

const fixturePath = process.argv[2] ?? 'replay/fixtures/testnet_settled_tx_refblock.json';
const fixture = loadSettledFixture(JSON.parse(await readFile(fixturePath, 'utf8')), fixturePath);

const client = createReplayNodeClient({
  url: fixture.provenance.endpoint,
  fetchImpl: fixtureFetch(fixture),
});

const settled = await fetchSettledTransaction(
  client,
  TxHash.fromString(fixture.provenance.txHash),
  { pinToSettlingBlock: true },
);

console.log('=== the subject ===');
console.log('tx        ', settled.txHash);
console.log('block     ', settled.l2BlockNumber, 'index', settled.txIndexInBlock);
console.log('revertCode', settled.revertCode);
console.log('publicHalf', settled.publicHalf.enqueuedCalls, 'teardown', settled.publicHalf.hasTeardown);
console.log('contracts ', settled.contracts.map(c => `${c.address} class ${c.contractClassId} ${c.packedBytecodeBytes}B asOf ${c.resolvedAsOf}`));
const eff = settled.txEffect.data;
console.log('published ', {
  noteHashes: eff.noteHashes.length,
  nullifiers: eff.nullifiers.length,
  publicDataWrites: eff.publicDataWrites.length,
  transactionFee: eff.transactionFee.toString(),
});
console.log('feePayer  ', settled.tx.data.feePayer.toString());
console.log('gasUsed   ', JSON.stringify(settled.tx.data.gasUsed ?? null));
console.log('publicDataWrites:');
for (const w of eff.publicDataWrites) {
  console.log('   ', w.leafSlot.toString(), '=', w.value.toString());
}
console.log('nullifiers:');
for (const n of eff.nullifiers) console.log('   ', n.toString());

// ---- the module ------------------------------------------------------------------------------
const compiled = await compileAvm(process.env.AVM_WASM_PATH ?? 'vm2wasm/avm.wasm');
const reactor = await instantiateAvm(compiled);
const contractDb = reactor.createContractDb();
const merkleDb = reactor.createMerkleDb();
console.log('\n=== module ===');
console.log('handles   ', { contractDb, merkleDb });
console.log('hasArchive', reactor.exportNames.includes('avm_merkle_db_update_archive'));

const roots = reactor.callWithHandle('avm_merkle_db_get_tree_roots', merkleDb);
const hex = v => (v instanceof Uint8Array ? '0x' + Buffer.from(v).toString('hex') : String(v));
console.log('genesis roots:');
for (const [k, v] of Object.entries(roots ?? {})) console.log('   ', k, hex(v?.root ?? v));

console.log('\nthe block SAID:');
for (const [k, v] of Object.entries(fixture.provenance.nodeReported.stateReference)) {
  console.log('   ', k, v);
}

// ---- register the contract -------------------------------------------------------------------
for (const c of settled.contracts) {
  const cc = c.contractClass;
  const commitment = await computePublicBytecodeCommitment(cc.packedBytecode);
  reactor.callWithBlob('avm_contract_db_register_class', contractDb, serializeWithMessagePack({
    id: cc.id,
    artifactHash: cc.artifactHash,
    privateFunctionsRoot: cc.privateFunctionsRoot,
    packedBytecode: cc.packedBytecode,
    publicBytecodeCommitment: commitment,
  }));
  const inst = c.instance;
  reactor.callWithBlob('avm_contract_db_register_instance', contractDb, serializeWithMessagePack([
    inst.address,
    {
      salt: inst.salt,
      deployer: inst.deployer,
      currentContractClassId: inst.currentContractClassId,
      originalContractClassId: inst.originalContractClassId,
      initializationHash: inst.initializationHash,
      immutablesHash: inst.immutablesHash,
      publicKeys: inst.publicKeys,
    },
  ]));
  console.log(`registered ${c.address}`);
}

// ---- seed: the deployment nullifier ------------------------------------------------------------
// M29's finding: without the siloed contract-instance-registry nullifier the AVM executes exactly
// one instruction, because it decides a contract EXISTS by looking for its address nullifier.
const insertNullifier = n => reactor.callWithBlob(
  'avm_merkle_db_insert_indexed_leaves_nullifier_tree', merkleDb,
  serializeWithMessagePack({ nullifier: n }));
const insertPublicData = (slot, value) => reactor.callWithBlob(
  'avm_merkle_db_insert_indexed_leaves_public_data_tree', merkleDb,
  serializeWithMessagePack({ slot, value }));

for (const c of settled.contracts) {
  const siloed = await siloNullifier(ProtocolContractAddress.ContractInstanceRegistry,
    Fr.fromHexString(c.address));
  insertNullifier(siloed);
  console.log('seeded deployment nullifier', siloed.toString(), 'for', c.address);
  // THE INITIALIZATION NULLIFIER. Aztec's convention is siloNullifier(address, address): a
  // contract's `initialize` emits its own address as a nullifier under its own silo, and a public
  // function that requires initialization checks for it with NULLIFIEREXISTS. Without it the AVM
  // runs 181 instructions and REVERTs at pc 21817 — which is what the first run of this spike did.
  const init = await siloNullifier(Fr.fromHexString(c.address), Fr.fromHexString(c.address));
  insertNullifier(init);
  console.log('seeded initialization nullifier', init.toString());
}

// ---- seed: fee juice ---------------------------------------------------------------------------
const feePayer = settled.tx.data.feePayer;
const storageSlot = await computeFeePayerBalanceStorageSlot(feePayer);
const feeLeafSlot = await computePublicDataTreeLeafSlot(ProtocolContractAddress.FeeJuice, storageSlot);
console.log('\nfee payer  ', feePayer.toString());
console.log('fee leafSlot', feeLeafSlot.toString());

// ---- seed: the published write set, read at the PARENT block -----------------------------------
// What the transaction SAW at those slots is what the chain held one block earlier. The node can
// answer it per-slot, at a block, through a method already on the permitted fourteen.
const parent = settled.l2BlockNumber - 1;
console.log(`\n=== reading the pre-state at block ${parent} (LIVE) ===`);
const liveUrl = fixture.provenance.endpoint;
async function publicDataWitness(blockNumber, leafSlot) {
  const res = await fetch(liveUrl, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0', id: 1, method: 'aztec_getPublicDataWitness',
      params: [blockNumber, leafSlot.toString()],
    }),
    signal: AbortSignal.timeout(40000),
  });
  const j = await res.json();
  if (j.error) return { error: j.error };
  return j.result;
}

const preState = [];
for (const w of eff.publicDataWrites) {
  const wit = await publicDataWitness(parent, w.leafSlot);
  preState.push({ slot: w.leafSlot.toString(), after: w.value.toString(), witness: wit });
  const leaf = wit?.leafPreimage ?? wit?.leaf_preimage;
  console.log('  slot', w.leafSlot.toString().slice(0, 20) + '…',
    'after=', w.value.toString().slice(0, 24),
    'witness=', JSON.stringify(leaf ?? wit).slice(0, 200));
}
const feeWit = await publicDataWitness(parent, feeLeafSlot);
console.log('  feeJuice witness=', JSON.stringify(feeWit).slice(0, 400));

// ---- SEED the pre-state ------------------------------------------------------------------------
// The witness carries the leaf preimage AT THAT BLOCK, so `leafPreimage.leaf.value` is what the
// chain held at that slot one block before the transaction ran. A leaf whose `slot` does NOT equal
// the one asked for is the tree answering with the PREDECESSOR — the slot was empty — and seeding
// its value would put the wrong number at the right slot, which is the shape of wrong answer that
// looks like a clean read. So it is checked and skipped, and the skip is counted.
let seeded = 0, absent = 0;
for (const entry of [...preState.map(p => ({ slot: p.slot, wit: p.witness })),
                     { slot: feeLeafSlot.toString(), wit: feeWit }]) {
  const leaf = entry.wit?.leafPreimage?.leaf;
  if (!leaf) { console.log('  NO WITNESS for', entry.slot); absent++; continue; }
  if (leaf.slot.toLowerCase() !== entry.slot.toLowerCase()) {
    console.log('  slot ABSENT at parent (witness names', leaf.slot.slice(0,18) + '…):', entry.slot.slice(0,18) + '…');
    absent++; continue;
  }
  insertPublicData(Fr.fromHexString(leaf.slot), Fr.fromHexString(leaf.value));
  seeded++;
}
console.log(`seeded ${seeded} public-data leaves, ${absent} absent at the parent block`);

await import('node:fs').then(fs => fs.writeFileSync(
  'scratchpad/campaign/l2-prestate.json',
  JSON.stringify({ parent, preState, feeLeafSlot: feeLeafSlot.toString(), feeWit }, null, 2)));

// ---- encode and simulate -------------------------------------------------------------------
const globals = settled.blockData.header.globalVariables;
const config = {
  ...PublicSimulatorConfig.from({
    collectHints: true, collectDebugLogs: true, collectStatistics: true, collectPublicInputs: true,
  }),
  collectExecutionSteps: true,
};
const wsRevision = new WorldStateRevision(0, settled.l2BlockNumber, true);
const txHint = AvmTxHint.fromTx(settled.tx, globals.gasFees);
const inputs = new AvmFastSimulationInputs(wsRevision, config, txHint, globals, ProtocolContractsList);
const bytes = serializeWithMessagePack(inputs);
console.log('\n=== simulate ===');
console.log('input bytes', bytes.length);

let outcome;
try {
  outcome = reactor.simulate(bytes, contractDb, merkleDb);
} catch (err) {
  console.log('simulate THREW', err?.name, String(err?.message).slice(0, 400));
  process.exit(1);
}
console.log('revertCode ', outcome.revertCode);
console.log('steps      ', stepCount(reactor));
const result = outcome.result;
if (result && typeof result === 'object') {
  const keys = Object.keys(result);
  console.log('result keys', keys.slice(0, 40));
  const stats = result.stats ?? result.statistics;
  if (stats) console.log('stats      ', JSON.stringify(stats).slice(0, 500));
}
console.log('errorMessage', reactor.errorMessage?.() ?? '(none)');

// ---- what did it ASK for? ----------------------------------------------------------------------
const hints = result?.hints;
console.log('\n=== hints ===');
if (hints && typeof hints === 'object') {
  for (const [k, v] of Object.entries(hints)) {
    console.log(' ', k, Array.isArray(v) ? `[${v.length}]` : typeof v);
  }
  const dump = (name) => {
    const arr = hints[name];
    if (!Array.isArray(arr) || arr.length === 0) return;
    console.log(`\n-- ${name} (${arr.length}) --`);
    for (const h of arr.slice(0, 40)) console.log('   ', JSON.stringify(h, (k, val) =>
      val instanceof Uint8Array ? '0x' + Buffer.from(val).toString('hex') : (typeof val === 'bigint' ? String(val) : val)).slice(0, 300));
  };
  for (const k of Object.keys(hints)) dump(k);
}

// ---- where did it revert? ----------------------------------------------------------------------
import { drainSteps, formatStep } from '../../node-host/src/steps.ts';
const drained = drainSteps(reactor, 4096);
console.log(`\n=== executed steps: ${drained.steps.length} (crossings ${drained.crossings}) ===`);
for (const s of drained.steps.slice(-30)) console.log(`   ctx=${s.contextId} pc=${s.pc} op=${s.opcode} l2=${s.gasUsed.l2Gas} da=${s.gasUsed.daGas}`);
console.log('\nopcode histogram (last 60):');
const h = new Map();
for (const s of drained.steps) h.set(s.opcode, (h.get(s.opcode) ?? 0) + 1);
console.log([...h.entries()].sort((a,b)=>b[1]-a[1]).slice(0,25).map(([o,c])=>`${o}:${c}`).join(' '));
