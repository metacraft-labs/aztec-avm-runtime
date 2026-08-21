// Dumps the native world state's genesis (block 0) state for every tree.
// This is the ORACLE the in-memory merkle trees must reproduce exactly.
// Run: node dump_genesis.mjs > genesis.json
import { NativeWorldStateService } from '@aztec/world-state';
import { MerkleTreeId, merkleTreeIds } from '@aztec/stdlib/trees';

const svc = await NativeWorldStateService.tmp();
const fork = await svc.fork();

const trees = {};
for (const id of merkleTreeIds()) {
  const info = await fork.getTreeInfo(id);
  trees[MerkleTreeId[id]] = {
    id,
    depth: info.depth,
    size: info.size.toString(),
    root: '0x' + Buffer.from(info.root).toString('hex'),
  };
}

const sr = await fork.getStateReference();
const out = {
  note: 'Genesis state of NativeWorldStateService.tmp() — the oracle for in-memory trees.',
  package: '@aztec/world-state',
  trees,
  stateReference: JSON.parse(JSON.stringify(sr)),
};

// Sibling path of leaf 0 in the (empty) note-hash tree: pins the zero-hash chain per level.
const sibPath = await fork.getSiblingPath(MerkleTreeId.NOTE_HASH_TREE, 0n);
out.noteHashZeroSiblingPath = sibPath.toFields().map(f => f.toString());

// The genesis prefill: 128 nullifier leaves + 128 public-data leaves, written by the protocol
// contracts at block 0. An in-memory tree that does not reproduce these EXACTLY will produce
// wrong roots for every transaction thereafter.
const dumpLeaves = async (treeId, n) => {
  const leaves = [];
  for (let i = 0n; i < BigInt(n); i++) {
    const pre = await fork.getLeafPreimage(treeId, i);
    leaves.push(pre === undefined ? null : JSON.parse(JSON.stringify(pre, (_k, v) => (typeof v === 'bigint' ? v.toString() : v))));
  }
  return leaves;
};
out.genesisPrefill = {
  NULLIFIER_TREE: await dumpLeaves(MerkleTreeId.NULLIFIER_TREE, 128),
  PUBLIC_DATA_TREE: await dumpLeaves(MerkleTreeId.PUBLIC_DATA_TREE, 128),
};

console.log(JSON.stringify(out, null, 2));
await svc.close();
