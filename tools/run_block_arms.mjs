// run_block_arms.mjs — run M22's block arms against a built `avm.wasm` and print JSON.
//
// One process, one module instantiation, every arm. The three M22 checks read the JSON this
// produces rather than each paying the instantiation cost and — more to the point — rather than
// each producing its OWN measurement of the same block, which is how two checks come to disagree
// about a number nobody changed. M20's `run_form_a_arms.mjs` is the same shape and the same
// reason.
//
// Usage: AVM_WASM_PATH=/path/to/avm.wasm node tools/run_block_arms.mjs > blocks.json
//
// The module's own chatter goes to stderr, so stdout is JSON and nothing else.

import { compileAvm, instantiateAvm } from '../node-host/src/loader.ts';
import { runBlockArms } from '../orchestration/src/block_e2e_driver.ts';

const path = process.env.AVM_WASM_PATH;
if (!path) {
  console.error('AVM_WASM_PATH is not set; there is no module to run against.');
  process.exit(2);
}

const reactor = await instantiateAvm(await compileAvm(path));
const arms = await runBlockArms(reactor);
process.stdout.write(JSON.stringify({ module: path, arms }, null, 2) + '\n');
