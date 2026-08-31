// run_token_block_arms.mjs — run the closeout arms against a built `avm.wasm` and print JSON.
//
//   AVM_WASM_PATH=/path/to/avm.wasm node tools/run_token_block_arms.mjs > token-blocks.json
//
// One process, one module instantiation, every arm — M20's convention, kept by M22, M23, M24, M25
// and M26: several checks each deriving "the balance after the transfer" from their own run is how
// two checks come to disagree about a number nothing changed.
//
// THE ARTIFACT SEARCH LIVES HERE AND ITS RESIDUE IS REPORTED. This tree carries two `@aztec`
// nightly lines installed at once and they are not interchangeable, so the search crosses several
// `node_modules` roots and prints every root it tried. M27's own search, unchanged in shape.

import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { compileAvm, instantiateAvm } from '../node-host/src/loader.ts';
import { runTokenBlockArms } from '../orchestration/src/token_block_driver.ts';

const REPO = path.resolve(import.meta.dirname, '..');

const modulePath = process.env.AVM_WASM_PATH;
if (!modulePath) {
  console.error('AVM_WASM_PATH is not set; there is no module to run against.');
  process.exit(2);
}

/** Roots that may carry a published `@aztec` artifact package, in the order M27 searches them. */
const ARTIFACT_ROOTS = ['diffsim', 'spike', 'drift', 'probe-mt', 'orchestration'];

function findArtifact(relative) {
  const tried = [];
  for (const root of ARTIFACT_ROOTS) {
    const file = path.join(REPO, root, 'node_modules', relative);
    tried.push(path.relative(REPO, file));
    if (existsSync(file)) return { root, file, tried };
  }
  return { root: null, file: null, tried };
}

const token = findArtifact('@aztec/noir-contracts.js/artifacts/token_contract-Token.json');
const avmTest = findArtifact('@aztec/noir-test-contracts.js/artifacts/avm_test_contract-AvmTest.json');
const child = findArtifact('@aztec/noir-test-contracts.js/artifacts/child_contract-Child.json');
for (const [name, hit] of [['Token', token], ['AvmTest', avmTest], ['Child', child]]) {
  if (hit.file === null) {
    console.error(`no ${name} artifact under any of:\n  ${hit.tried.join('\n  ')}`);
    process.exit(3);
  }
}

const sha = f => createHash('sha256').update(readFileSync(f)).digest('hex');

const reactor = await instantiateAvm(await compileAvm(modulePath));

// EVERY EXPORT THIS DRIVER NEEDS, CHECKED HERE RATHER THAN HALF WAY THROUGH AN ARM. A module
// without the contract-DB registration exports cannot register a contract at all, and the arms
// would then report a transaction that reverted at instruction one — which reads as `processed`.
const required = [
  'avm_simulate',
  'avm_contract_db_register_class',
  'avm_contract_db_register_instance',
  'avm_merkle_db_insert_indexed_leaves_nullifier_tree',
  'avm_merkle_db_insert_indexed_leaves_public_data_tree',
];
const missing = required.filter(n => !reactor.exportNames.includes(n));
if (missing.length > 0) {
  console.error(
    `the module at ${modulePath} is missing ${missing.join(', ')}.\n`
      + 'These arms register real contracts and run them. Build a module from M13\'s overlay stack '
      + '— see `just avm-wasm-build-m23`.',
  );
  process.exit(4);
}

const arms = await runTokenBlockArms(reactor, {
  token: JSON.parse(readFileSync(token.file, 'utf8')),
  avmTest: JSON.parse(readFileSync(avmTest.file, 'utf8')),
  child: JSON.parse(readFileSync(child.file, 'utf8')),
});

process.stdout.write(
  JSON.stringify(
    {
      measuredAt: new Date().toISOString(),
      module: { path: modulePath, sha256: sha(modulePath), exports: reactor.exportNames.length },
      artifacts: {
        token: { root: token.root, sha256: sha(token.file) },
        avmTest: { root: avmTest.root, sha256: sha(avmTest.file) },
        child: { root: child.root, sha256: sha(child.file) },
      },
      arms,
    },
    null,
    2,
  ) + '\n',
);
