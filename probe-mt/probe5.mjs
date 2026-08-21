import { poseidon2Hash, poseidon2HashWithSeparator } from '@aztec/foundation/crypto/sync';
import { Fr } from '@aztec/foundation/curves/bn254';
const TARGET1 = '0x19f1a0c09db4cd026f686e9c8fb45501a9fefb4eb1b4c6c328a51343a0094eeb'; // native zero @ level 1
const TARGET2 = '0x14e4b977b2203b70e6ee1c2456eb7114d090fe4b907f631eecd0919fed432e7d'; // native zero @ level 2
const Z = Fr.ZERO;
const tries = {};
tries['poseidon2([0,0])'] = poseidon2Hash([Z,Z]).toString();
for (let s=0;s<48;s++) tries[`poseidon2([${s},0,0])`] = poseidon2Hash([new Fr(BigInt(s)),Z,Z]).toString();
try { for (let s=0;s<48;s++) tries[`sep(${s},[0,0])`] = poseidon2HashWithSeparator([Z,Z], s).toString(); } catch(e){ console.log('no sep fn', e.message); }
for (const [k,v] of Object.entries(tries)) if (v===TARGET1) console.log('LEVEL1 MATCH:', k);
console.log('candidates computed:', Object.keys(tries).length);
