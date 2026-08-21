import { poseidon2Hash } from '@aztec/foundation/crypto/sync';
import { Fr } from '@aztec/foundation/curves/bn254';
import { NativeWorldStateService } from '@aztec/world-state';
import { MerkleTreeId } from '@aztec/stdlib/trees';
const ws = await NativeWorldStateService.tmp();
const fork = await ws.fork();
const sp = await fork.getSiblingPath(MerkleTreeId.NOTE_HASH_TREE, 0n);
const path = sp.toFields().map(f=>f.toString());
// TS zero hashes
const zeros=[]; let cur=Fr.ZERO;
for(let i=0;i<45;i++){zeros.push(cur.toString()); cur=poseidon2Hash([cur,cur]);}
console.log('native sibling path length:', path.length);
let mismatch=-1;
for(let i=0;i<path.length;i++){ if(path[i]!==zeros[i]){mismatch=i;break;} }
console.log('first mismatch vs zero-hash chain at level:', mismatch);
console.log('path[0..3]:', path.slice(0,3));
console.log('zero[0..3]:', zeros.slice(0,3));
console.log('path[last]:', path[path.length-1], ' zero[41]:', zeros[41]);
// recompute root from leaf 0 = 0 and the path
let node = Fr.ZERO;
for (let i=0;i<path.length;i++){ node = poseidon2Hash([node, Fr.fromString(path[i])]); }
console.log('recomputed root from path:', node.toString());
const info = await fork.getTreeInfo(MerkleTreeId.NOTE_HASH_TREE);
console.log('native reported root      :', new Fr(info.root).toString());
await ws.close();
