// _fallback_adapter_probe.mjs — reproduce the kv-store adapter break, and localise it.
//
// M16's price includes "a kv-store adapter refresh, because the March-2026 package fails
// `TypeError: this.nodes.get is not a function` against the June-2026 store". This reproduces it
// and — the part the milestone text does not say — establishes WHICH HALF of the store surface
// moved, because that is what decides how large the refresh is.
//
// The probe prints three markers on stdout before it can fail, so a caller can tell an import
// error, a construction error and the read failure apart. A check that only asserted "it exits
// non-zero" would pass if the package were not installed at all.
//
//   imported=1      the package and the store both resolved
//   constructed=1   `newTree` ran: the tree's metadata WRITE path works against this store
//   read_attempted=1 the failing call is about to be made
//
// Then it appends a leaf, which reads a node, which is where it dies. Exit status is node's own
// uncaught-exception 1; the message goes to stderr. Nothing is caught here on purpose: a caught
// exception re-thrown by us would be our message and not the package's.

import { Fr } from '@aztec/foundation/curves/bn254';
import { NOTE_HASH_TREE_HEIGHT } from '@aztec/constants';
import { openTmpStore } from '@aztec/kv-store/lmdb-v2';
import { Poseidon, StandardTree, newTree } from '@aztec/merkle-tree';

console.log('imported=1');
const store = await openTmpStore('m16-fallback-adapter');
const tree = await newTree(StandardTree, store, new Poseidon(), 'note_hash', Fr, NOTE_HASH_TREE_HEIGHT);
console.log('constructed=1');
console.log('empty_root=0x' + tree.getRoot(true).toString('hex'));
console.log('read_attempted=1');
await tree.appendLeaves([new Fr(42n)]);
// Unreachable against the June-2026 store. If it IS reached, the adapter no longer needs
// refreshing and this line is the finding.
console.log('appended=1');
console.log('root_after=0x' + tree.getRoot(true).toString('hex'));
await store.close();
