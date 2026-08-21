import { poseidon2Hash } from '@aztec/foundation/crypto/sync';
import { Fr } from '@aztec/foundation/curves/bn254';
let cur = Fr.ZERO;
const target = {
 '0x2590f2aab19dd791700b4a43d3f52bb88ef2409a3731da8e848663559202e4c6':'NATIVE noteHash(empty)',
 '0x0fef6d80d31109ddb56d6b3f607cbc9c0af0bff3ea0d43e8f278983c64c11f7a':'NATIVE l1tol2(empty)',
 '0x2ac5dda169f6bb3b9ca09bbac34e14c94d1654597db740153a1288d859a8a30a':'TS h=42',
 '0x0d582c10ff8115413aa5b70564fdd2f3cefe1f33a1e43a47bc495081e91e73e5':'TS h=36',
};
for (let h=0; h<=45; h++){
  const s = cur.toString();
  if (target[s]) console.log(`height ${h}: ${s}   <-- ${target[s]}`);
  cur = poseidon2Hash([cur, cur]);
}
