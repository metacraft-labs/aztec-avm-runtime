import { poseidon2Hash } from '@aztec/foundation/crypto/sync';
import { Fr } from '@aztec/foundation/curves/bn254';
import { NativeWorldStateService } from '@aztec/world-state';
import { MerkleTreeId } from '@aztec/stdlib/trees';
const ws = await NativeWorldStateService.tmp();
const fork = await ws.fork();
for (const id of [MerkleTreeId.NOTE_HASH_TREE, MerkleTreeId.NULLIFIER_TREE, MerkleTreeId.PUBLIC_DATA_TREE, MerkleTreeId.L1_TO_L2_MESSAGE_TREE, MerkleTreeId.ARCHIVE]) {
  const info = await fork.getTreeInfo(id);
  console.log(MerkleTreeId[id], 'depth=', info.depth, 'size=', info.size, 'root=', new Fr(info.root).toString());
}
await ws.close();
