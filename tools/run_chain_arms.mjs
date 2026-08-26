// run_chain_arms.mjs — run M23's chain arms against a built `avm.wasm` and print JSON.
//
// One process, one module instantiation, every arm. The M23 checks read the JSON this produces
// rather than each paying the instantiation cost and — more to the point — rather than each
// producing its OWN measurement of the same chain. M20's `run_form_a_arms.mjs` and M22's
// `run_block_arms.mjs` are the same shape and the same reason.
//
// Usage: AVM_WASM_PATH=/path/to/avm.wasm node tools/run_chain_arms.mjs > chain.json
//
// IT NEEDS A MODULE WITH THE ARCHIVE. Every arm seals blocks. A module without
// `avm_merkle_db_update_archive` and `avm_merkle_db_get_archive_snapshot` is rejected HERE, with
// the command that builds one, rather than half way through an arm.

import { compileAvm, instantiateAvm } from '../node-host/src/loader.ts';
import { runChainArms } from '../orchestration/src/chain_e2e_driver.ts';

const path = process.env.AVM_WASM_PATH;
if (!path) {
  console.error('AVM_WASM_PATH is not set; there is no module to run against.');
  process.exit(2);
}

const reactor = await instantiateAvm(await compileAvm(path));
const required = ['avm_merkle_db_update_archive', 'avm_merkle_db_get_archive_snapshot'];
const missing = required.filter(n => !reactor.exportNames.includes(n));
if (missing.length > 0) {
  console.error(
    `the module at ${path} is missing ${missing.join(', ')}.\n`
      + 'M23 seals blocks, and a seal reads and writes the archive tree. Build a module from '
      + "M23's overlay stack — see `just avm-wasm-build-m23`.",
  );
  process.exit(3);
}

const arms = await runChainArms(reactor);
process.stdout.write(JSON.stringify({ module: path, exports: reactor.exportNames.length, arms }, null, 2) + '\n');
