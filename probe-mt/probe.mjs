import { NativeWorldStateService } from '@aztec/world-state';
import { MerkleTreeId } from '@aztec/stdlib/trees';
import { NOTE_HASH_TREE_HEIGHT, NULLIFIER_TREE_HEIGHT, PUBLIC_DATA_TREE_HEIGHT, L1_TO_L2_MSG_TREE_HEIGHT, ARCHIVE_HEIGHT } from '@aztec/constants';
import { Fr } from '@aztec/foundation/curves/bn254';
import { openTmpStore } from '@aztec/kv-store/lmdb-v2';
import { Poseidon, StandardTree, newTree } from '@aztec/merkle-tree';

const ws = await NativeWorldStateService.tmp();
const fork = await ws.fork();
const sr = await fork.getStateReference();
console.log('NATIVE empty state reference:');
console.log('  noteHash   root=', sr.partial.noteHashTree.root.toString(), 'next=', sr.partial.noteHashTree.nextAvailableLeafIndex);
console.log('  nullifier  root=', sr.partial.nullifierTree.root.toString(), 'next=', sr.partial.nullifierTree.nextAvailableLeafIndex);
console.log('  publicData root=', sr.partial.publicDataTree.root.toString(), 'next=', sr.partial.publicDataTree.nextAvailableLeafIndex);
console.log('  l1tol2     root=', sr.l1ToL2MessageTree.root.toString(), 'next=', sr.l1ToL2MessageTree.nextAvailableLeafIndex);
console.log('  heights:', {NOTE_HASH_TREE_HEIGHT, NULLIFIER_TREE_HEIGHT, PUBLIC_DATA_TREE_HEIGHT, L1_TO_L2_MSG_TREE_HEIGHT, ARCHIVE_HEIGHT});

// Now the deleted pure-TS merkle tree
const store = await openTmpStore('mt-probe');
const hasher = new Poseidon();
const tsNoteHash = await newTree(StandardTree, store, hasher, 'note_hash', Fr, NOTE_HASH_TREE_HEIGHT);
console.log('\nTS  StandardTree note-hash empty root=', tsNoteHash.getRoot(true).toString('hex'));
const tsL1 = await newTree(StandardTree, store, hasher, 'l1tol2', Fr, L1_TO_L2_MSG_TREE_HEIGHT);
console.log('TS  StandardTree l1->l2   empty root=', tsL1.getRoot(true).toString('hex'));

// append a leaf to both and compare
await fork.appendLeaves(MerkleTreeId.NOTE_HASH_TREE, [new Fr(42n)]);
const sr2 = await fork.getStateReference();
await tsNoteHash.appendLeaves([new Fr(42n)]);
console.log('\nafter appending Fr(42):');
console.log('  NATIVE noteHash root=', sr2.partial.noteHashTree.root.toString());
console.log('  TS     noteHash root= 0x' + tsNoteHash.getRoot(true).toString('hex'));
await ws.close();
await store.close();
