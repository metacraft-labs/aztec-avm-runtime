// The poseidon2 / grumpkin differential, against @aztec/foundation — which is bb.js on this side.
//
//   AVM_WASM_PATH=… node browser/crypto_differential.mjs        (run from browser/)
//
// Driven by `test_browser_crypto_matches_bb_js`, which reads the `KEY<TAB>VALUE` lines below.
//
// IT LIVES HERE, BESIDE THE SOURCES IT COMPARES, AND IT HAS TO. Node resolves a bare `@aztec/*`
// specifier from the IMPORTING FILE'S location, not from the working directory, so a probe written
// into a scratch directory and run with `cd browser` fails on every import with
// `ERR_MODULE_NOT_FOUND` — measured, on the check's first run. `browser/node_modules` is the
// symlink that makes resolution work, so the probe is a tracked file next to it. That is the same
// arrangement `tools/run_*_arms.mjs` uses for the orchestration.
//
// WHY THE COMPARISON MATTERS: DD-11 is satisfied by taking poseidon2 and grumpkin out of `avm.wasm`
// instead of downloading 7.9 MB of proving stack for them, and that is only sound if the two agree
// EXACTLY. A poseidon wrong by one round constant produces a fee-juice leaf slot nobody reads — the
// funding "succeeds", the transaction then fails for insufficient funds, and the cause is four
// layers away.

// Run from browser/, so `@aztec/*` resolves through the orchestration's installed tree.
import { Fr, Fq } from '@aztec/foundation/curves/bn254';
import { Point } from '@aztec/foundation/curves/grumpkin';
import { poseidon2Hash, poseidon2HashWithSeparator, poseidon2Permutation } from '@aztec/foundation/crypto/poseidon';
import { Grumpkin } from '@aztec/foundation/crypto/grumpkin';
import { serializeWithMessagePack } from '@aztec/stdlib/avm';

const { compileAvm, instantiateAvm } = await import('../node-host/src/loader.ts');
const { createAvmPoseidon2 } = await import('./src/poseidon.ts');
const { createAvmGrumpkin } = await import('./src/grumpkin.ts');

const reactor = await instantiateAvm(await compileAvm(process.env.AVM_WASM_PATH));
const p = createAvmPoseidon2(reactor, (f) => serializeWithMessagePack(f));
const g = createAvmGrumpkin(reactor, (a) => serializeWithMessagePack(a));

const out = (k, v) => console.log(`${k}\t${v}`);

const corpus = [
  [],
  [new Fr(0n)],
  [new Fr(1n)],
  [new Fr(1n), new Fr(2n)],
  [new Fr(3n), new Fr(4n), new Fr(5n)],
  [new Fr(1n), new Fr(2n), new Fr(3n), new Fr(4n)],
  [new Fr(1n), new Fr(2n), new Fr(3n), new Fr(4n), new Fr(5n)],
  [Fr.random(), Fr.random(), Fr.random()],
  [new Fr((1n << 250n) + 12345n), new Fr(0n)],
];
let hashOk = 0, hashBad = 0;
for (const c of corpus) {
  const mine = p.hash(c).toString();
  const theirs = (await poseidon2Hash(c)).toString();
  if (mine === theirs) hashOk += 1;
  else { hashBad += 1; out('HASH-MISMATCH', `${c.length}\t${mine}\t${theirs}`); }
}
out('HASH-CORPUS', corpus.length);
out('HASH-OK', hashOk);
out('HASH-BAD', hashBad);

const st = [new Fr(1n), new Fr(2n), new Fr(3n), new Fr(4n)];
out('PERM-MATCH', JSON.stringify(p.permutation(st).map(String)) === JSON.stringify((await poseidon2Permutation(st)).map(String)));

const inp = [new Fr(11n), new Fr(22n)];
out('SEP-MATCH', p.hash([new Fr(7), ...inp]).toString() === (await poseidon2HashWithSeparator(inp, 7)).toString());
out('HASH-CONTROL-DISAGREES', p.hash([new Fr(1n)]).toString() !== (await poseidon2Hash([new Fr(2n)])).toString());

const G = Grumpkin.generator;
let mulOk = 0, mulBad = 0;
const scalars = [1n, 2n, 7n, 12345n, (1n << 200n) + 9n];
for (const s of scalars) {
  const scalar = new Fq(s);
  const mine = g.mul(G, scalar.toBuffer());
  const theirs = await Grumpkin.mul(G, scalar);
  if (mine.x.toString() === theirs.x.toString() && mine.y.toString() === theirs.y.toString()) mulOk += 1;
  else { mulBad += 1; out('MUL-MISMATCH', `${s}\t${mine}\t${theirs}`); }
}
out('MUL-CORPUS', scalars.length);
out('MUL-OK', mulOk);
out('MUL-BAD', mulBad);

const A = await Grumpkin.mul(G, new Fq(3n));
const B = await Grumpkin.mul(G, new Fq(5n));
const mineAdd = g.add(A, B);
const theirsAdd = await Grumpkin.add(A, B);
out('ADD-MATCH', mineAdd.x.toString() === theirsAdd.x.toString() && mineAdd.y.toString() === theirsAdd.y.toString());
out('MUL-CONTROL-DISAGREES', g.mul(G, new Fq(3n).toBuffer()).x.toString() !== (await Grumpkin.mul(G, new Fq(4n))).x.toString());

let refused = 'NOT-REFUSED';
try {
  g.add(new Point(new Fr(1n), new Fr(1n)), A);
} catch (e) {
  refused = String(e.message);
}
out('OFF-CURVE', refused);

out('POSEIDON-CALLS', p.calls);
out('GRUMPKIN-CALLS', g.calls);
