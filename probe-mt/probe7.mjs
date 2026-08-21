import { poseidon2Hash } from '@aztec/foundation/crypto/sync';
import { Fr } from '@aztec/foundation/curves/bn254';
const SEP = { MERKLE: 2982624097n, NULLIFIER: 1157584160n, PUBLIC_DATA: 3756303423n };
const hp = (sep) => (l,r) => poseidon2Hash([new Fr(sep), l, r]);
const zeroRoot = (sep, depth) => { let c=Fr.ZERO; for(let i=0;i<depth;i++) c=hp(sep)(c,c); return c.toString(); };
console.log('noteHash (MERKLE, d=42) :', zeroRoot(SEP.MERKLE,42));
console.log('   native               : 0x2590f2aab19dd791700b4a43d3f52bb88ef2409a3731da8e848663559202e4c6');
console.log('l1tol2   (MERKLE, d=36) :', zeroRoot(SEP.MERKLE,36));
console.log('   native               : 0x0fef6d80d31109ddb56d6b3f607cbc9c0af0bff3ea0d43e8f278983c64c11f7a');
// verify zero level 1
console.log('zero@level1             :', hp(SEP.MERKLE)(Fr.ZERO,Fr.ZERO).toString());
console.log('   native path[1]        : 0x19f1a0c09db4cd026f686e9c8fb45501a9fefb4eb1b4c6c328a51343a0094eeb');
