#!/usr/bin/env node
// A replay whose execution READ THE L1->L2 MESSAGE TREE must be refused BY NAME, not reported.
//
// `historical_state.ts` declares `L1_TO_L2_MESSAGE_TREE` in `UNANSWERABLE_TREES`: the tree is
// append-only, route 3 cannot place a leaf at index i without the i leaves before it, so the
// resident tree is EMPTY. Its own text says such a transaction "is refused by name rather than
// replayed against an absent leaf". Until this check that refusal could not fire: the AVM reports
// L1TOL2MSGEXISTS reads in the `getLeafValueHints` hint family, and the loop read only
// `getPreviousValueIndexHints` (the two indexed trees). The read came back 0, the contract's
// `assert` failed, and the replay reverted where the chain did not: a confident wrong replay.
//
// MEASURED on aztec-testnet (blocktracer rehearsal, 2026-11-26): 43 of 276 attempted
// transactions, all bridge-style claims on 0x02b76743… or 0x201aa740…, published revertCode 0
// and replayed revertCode 1 with 1 of 21 effects matching. The hint below is the one the AVM
// produced for 0x1a6bad63… in block 70,520: tree 3, index 6970, value 0, resident tree with
// nextAvailableLeafIndex 0. On chain, leaf 6970 was inserted at block 70,519, the parent.
//
// OFFLINE. A fake host plays the module back, so no avm.wasm and no network are needed. The
// loop, the seeding path and the refusal are the real code.
//
// ARMS:
//   1. a converged run whose hints read tree 3 at index 6970 -> L1ToL2MessageReadUnanswerable,
//      with its kind, the transaction, the block and the index; NOT an outcome.
//   2. the same run with no tree-3 read -> an outcome (the control: arm 1 is not a loop that
//      refuses everything).
//   3. `l1ToL2MessageReadsFrom` reads the hint family in either index spelling (number, bigint)
//      and ignores the other trees' leaf reads.
import assert from 'node:assert/strict';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const mod = (p) => import(pathToFileURL(join(root, p)).href);
const exec = await mod('replay/src/replay_execution.ts');
const { replaySettledTransaction } = exec;

const TX = '0x1a6bad634ce717dff304f440939fb5383d336bb585599ed70f1e6c9942ebe296';
const BLOCK = 70520;
const INDEX = 6970;

const zero32 = () => new Uint8Array(32);
const leafRead = (treeId, index) => ({
  hintKey: { root: zero32(), nextAvailableLeafIndex: 0 }, treeId, index, value: zero32(),
});

const root0 = { root: { toString: () => '0x01' } };
const settled = {
  txHash: TX, l2BlockNumber: BLOCK, txIndexInBlock: 0, revertCode: 0,
  txEffect: { data: { nullifiers: [], publicDataWrites: [], transactionFee: 0n } },
  contracts: [],
  blockData: { header: { state: {
    partial: { noteHashTree: root0, nullifierTree: root0, publicDataTree: root0 },
    l1ToL2MessageTree: root0,
  } } },
};
const source = {
  getPublicDataWitness: async () => undefined,
  getNullifierMembershipWitness: async () => undefined,
};
const hostReading = (leafValueHints) => ({
  freshInstance: async () => ({
    registerContractClass() {}, registerContractInstance() {},
    insertNullifier() {}, insertPublicDataLeaf() {},
    treeRoots: () => ({}),
    executedSteps: () => null,
    simulate: () => ({
      // What the module returned for 0x1a6bad63…: the claim's assert failed, so it reverted.
      revertCode: 1,
      result: {
        hints: { getPreviousValueIndexHints: [], getLeafValueHints: leafValueHints },
        publicTxEffect: { transactionFee: 0n, publicDataWrites: [], nullifiers: [] },
        stats: { total_instructions_executed: 91607 },
      },
    }),
  }),
});
const encode = () => new Uint8Array();

let failed = 0;
const arm = async (name, body) => {
  try { await body(); console.log(`ok   ${name}`); }
  catch (err) { failed += 1; console.log(`FAIL ${name}\n     ${String(err?.message ?? err).split('\n')[0]}`); }
};

await arm('1. a read of L1->L2 leaf 6970 is refused as L1ToL2MessageReadUnanswerable', async () => {
  let outcome;
  let thrown;
  try {
    outcome = await replaySettledTransaction(hostReading([leafRead(3, INDEX)]), source, settled, encode);
  } catch (err) { thrown = err; }
  assert.equal(outcome, undefined,
    `the loop REPORTED a replay (revertCode ${outcome?.revertCode}) over an L1->L2 read it cannot answer`);
  assert.equal(thrown?.name, 'L1ToL2MessageReadUnanswerable', `threw ${thrown?.name}: ${thrown?.message}`);
  assert.equal(thrown.kind, 'replay-l1-to-l2-message-read-unanswerable');
  assert.equal(thrown.txHash, TX);
  assert.equal(thrown.l2BlockNumber, BLOCK);
  assert.deepEqual(thrown.indexes, [INDEX]);
  assert.match(thrown.message, /6970/);
  assert.match(thrown.message, /L1->L2|L1-to-L2|L1TOL2MSGEXISTS/);
});

await arm('2. control: the same run without an L1->L2 read is reported, not refused', async () => {
  const outcome = await replaySettledTransaction(hostReading([]), source, settled, encode);
  assert.equal(outcome.revertCode, 1);
  assert.equal(outcome.rounds.length, 2);
});

await arm('3. l1ToL2MessageReadsFrom reads tree 3 only, either index spelling', async () => {
  assert.equal(typeof exec.l1ToL2MessageReadsFrom, 'function', 'l1ToL2MessageReadsFrom is not exported');
  const hints = { hints: { getLeafValueHints: [
    leafRead(3, 6970), { ...leafRead(3, 0), index: 6969n }, leafRead(1, 12), leafRead(3, 6970),
  ] } };
  assert.deepEqual(exec.l1ToL2MessageReadsFrom(hints), [6969, 6970]);
  assert.deepEqual(exec.l1ToL2MessageReadsFrom({}), []);
});

const index = await mod('replay/src/index.ts');
await arm('4. the class and the reader are exported from the package entry', async () => {
  assert.equal(typeof index.L1ToL2MessageReadUnanswerable, 'function');
  assert.equal(typeof index.l1ToL2MessageReadsFrom, 'function');
});

console.log(failed === 0 ? 'test_l1_to_l2_message_read_refuses_by_name: all arms pass'
  : `test_l1_to_l2_message_read_refuses_by_name: ${failed} arm(s) FAILED`);
process.exit(failed === 0 ? 0 : 1);
