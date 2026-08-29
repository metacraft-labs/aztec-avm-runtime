// _m34_derive.mjs — derive dev accounts from a seed, over the BUILT bundle, in one process.
//
//   node verification/_m34_derive.mjs <dist> <avm.wasm> <seed> <count>
//
// It prints one JSON array of `{index, secret, partialAddress, publicKeysHash, address}` and
// nothing else, so a check can compare two INDEPENDENT PROCESSES.
//
// ===========================================================================================
// WHY THE MODULE HAS TO BE OPENED FIRST, AND WHY THAT IS THE POINT RATHER THAN A NUISANCE
// ===========================================================================================
//
// `deriveDevAccounts` reaches upstream's `deriveKeys` and `computeAddress`, whose hashes are
// poseidon2 and whose curve operations are grumpkin. Under this build's DD-11 redirect table both
// of those are `avm.wasm`'s, installed by `openAvmRuntime` — so `wallet.js` imported ALONE cannot
// derive anything, and that refusal is the redirect table working rather than a defect.
//
// So this opens a runtime out of `testing.js` first, which installs both, and then derives out of
// `wallet.js`. Both entry points come from the SAME esbuild pass, so they share the chunk the
// installation writes into; two separately-built bundles would not, and the derivation would refuse.
//
// TWO PROCESSES SHARE NO MODULE STATE, NO CACHE AND NO PRNG STREAM. That is what makes an equality
// across two invocations of this script a statement about the FUNCTION rather than about one
// process's memoisation — which a same-process comparison cannot distinguish.

import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { pathToFileURL } from 'node:url';

const [dist, wasm, seed, count] = process.argv.slice(2);
if (!dist || !wasm || !seed || !count) {
  process.stderr.write('usage: _m34_derive.mjs <dist> <avm.wasm> <seed> <count>\n');
  process.exit(2);
}

const T = await import(pathToFileURL(path.join(dist, 'testing.js')).href);
const W = await import(pathToFileURL(path.join(dist, 'wallet.js')).href);

const bytes = readFileSync(wasm);
const opened = await T.openAvmRuntime({
  moduleUrl: 'about:blank',
  clock: new T.DateProvider(),
  disclosureSink: () => {},
  // The module comes from disk rather than from a URL; the injected `fetch` is `openAvmRuntime`'s
  // own option and exists for exactly this.
  fetch: async () => new Response(bytes, { headers: { 'content-type': 'application/wasm' } }),
});

const accounts = await W.deriveDevAccounts(seed, Number(count));
process.stdout.write(
  JSON.stringify(
    accounts.map((a) => ({
      index: a.index,
      secret: a.secret.toString(),
      partialAddress: a.partialAddress.toString(),
      publicKeysHash: a.publicKeysHash.toString(),
      address: a.address.toString(),
    })),
  ) + '\n',
);
await opened.close();
process.exit(0);
