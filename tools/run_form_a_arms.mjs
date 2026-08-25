// run_form_a_arms.mjs — run M20's Form A arms against a built `avm.wasm` and print JSON.
//
// One process, one module instantiation, every arm. The six M20 checks read the JSON this
// produces rather than each paying the instantiation cost, and — more to the point — rather than
// each producing its OWN measurement of the same thing, which is how two checks come to disagree
// about a number nobody changed.
//
// Usage: AVM_WASM_PATH=/path/to/avm.wasm node tools/run_form_a_arms.mjs > arms.json
//
// The module's own chatter goes to stderr, so stdout is JSON and nothing else.

import { compileAvm, instantiateAvm } from '../node-host/src/loader.ts';
import { runFormAArms } from '../orchestration/src/form_a_e2e_driver.ts';

const path = process.env.AVM_WASM_PATH;
if (!path) {
  console.error('AVM_WASM_PATH is not set; there is no module to run against.');
  process.exit(2);
}

const reactor = await instantiateAvm(await compileAvm(path));
const reports = await runFormAArms(reactor);
process.stdout.write(JSON.stringify({ module: path, arms: reports }, null, 2) + '\n');
