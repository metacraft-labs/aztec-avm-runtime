// M36 SPIKE — the tier-2 ladder, re-run in Node against the BUILT bundle.
//
// Purpose: measure where `Token.transfer`, `Token.mint_to_private` and `PrivateVoting.cast_vote`
// stop, so that "does closing `aztec_utl_getContractInstance` unblock the campaign's headline
// capability" is answered by a MEASUREMENT rather than by a plan.
//
// Calibrated against the unmutated bundle FIRST (it must reproduce the shipped ladder — three stops
// at `aztec_utl_getContractInstance`), then re-run against a bundle in which that one oracle is
// served, so the two runs differ in exactly one oracle.
//
// This is a scratchpad instrument. It ships nothing and is not a check.

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const REPO = path.resolve(import.meta.dirname, '../..');
const DIST = path.join(REPO, 'browser/dist');

const AVM_WASM = process.env.AVM_WASM_PATH;
if (!AVM_WASM || !existsSync(AVM_WASM)) {
  console.error(`AVM_WASM_PATH is not set to an existing module (${AVM_WASM})`);
  process.exit(2);
}

const roots = ['orchestration', 'diffsim', 'spike', 'drift', 'probe-mt'];
function findUnder(rel, order = roots) {
  for (const r of order) {
    const f = path.join(REPO, r, rel);
    if (existsSync(f)) return f;
  }
  throw new Error(`no ${rel} under any of: ${order.join(', ')}`);
}

const testing = await import(pathToFileURL(path.join(DIST, 'testing.js')).href);
const wallet = await import(pathToFileURL(path.join(DIST, 'wallet.js')).href);

// The module's own poseidon2 and grumpkin, installed the way `openAvmRuntime` installs them: a
// private frame's function SELECTOR is a poseidon hash, so a process that has not installed one
// cannot even name the function it is about to execute.
// `openAvmRuntime` is the ONE place that installs the module's own poseidon2 and grumpkin with the
// bundle's OWN msgpack serialiser. A first draft of this spike reached for
// `@aztec/stdlib/dest/avm`'s `serializeWithMessagePack` out of `node_modules` and the module
// answered `avm_poseidon2_hash failed with status 1: std::bad_cast` — the same per-realm hazard
// `private_execution.ts` records for `Fr`, one layer down, in a serialiser rather than a class.
const runtime = await testing.openAvmRuntime({
  moduleUrl: 'file:///avm.wasm',
  clock: new testing.DateProvider(),
  production: { intervalMs: 0, minBlockSpacingSeconds: 1 },
  fetch: async () =>
    new Response(readFileSync(AVM_WASM), { headers: { 'content-type': 'application/wasm' } }),
});

await wallet.initPrivateExecution({
  acvmWasmUrl: readFileSync(findUnder('node_modules/@aztec/noir-acvm_js/web/acvm_js_bg.wasm')),
  noircAbiWasmUrl: readFileSync(findUnder('node_modules/@aztec/noir-noirc_abi/web/noirc_abi_wasm_bg.wasm')),
});

const artifacts = {
  Token: JSON.parse(
    readFileSync(findUnder('node_modules/@aztec/noir-contracts.js/artifacts/token_contract-Token.json', [
      'diffsim', 'spike', 'drift', 'probe-mt', 'orchestration',
    ]), 'utf8'),
  ),
  PrivateVoting: JSON.parse(
    readFileSync(findUnder('node_modules/@aztec/noir-contracts.js/artifacts/private_voting_contract-PrivateVoting.json', [
      'diffsim', 'spike', 'drift', 'probe-mt', 'orchestration',
    ]), 'utf8'),
  ),
  OracleVersionCheck: JSON.parse(
    readFileSync(findUnder('node_modules/@aztec/noir-test-contracts.js/artifacts/oracle_version_check_contract-OracleVersionCheck.json', [
      'diffsim', 'spike', 'drift', 'probe-mt', 'orchestration',
    ]), 'utf8'),
  ),
};

// SPIKE 2 — a REAL instance, whose address is DERIVED from it, so the circuit's own constraint on
// `get_contract_instance` can be satisfied rather than fabricated past.
const stdlibAbi = await import(pathToFileURL(findUnder('node_modules/@aztec/stdlib/dest/abi/index.js')).href);
const loadedToken = stdlibAbi.loadContractArtifact(artifacts.Token);
const deployerAddr = wallet.toAddressValue(0x333n, 'deployer');
const { contractInstance } = await testing.createContractClassAndInstance(
  [deployerAddr, 'Tok', 'TOK', 18],
  deployerAddr,
  loadedToken,
  27,
);
globalThis.__spikeInstance = contractInstance;
console.error('SPIKE instance address = ' + contractInstance.address.toString());

const common = {
  contractAddress: process.env.M36_SPIKE_REAL_ADDRESS === '1' ? contractInstance.address.toString() : 0x777n,
  msgSender: 0x333n,
  chainId: 1n,
  version: 1n,
  entropySeed: 0x35n,
};

const LADDER = [
  ['Token', 'transfer'],
  ['Token', 'mint_to_private'],
  ['PrivateVoting', 'cast_vote'],
  ['OracleVersionCheck', 'private_function'],
];

const rows = [];
for (const [name, fnName] of LADDER) {
  const doc = artifacts[name];
  let report;
  try {
    report = await wallet.executePrivateFunction({ ...common, artifact: doc, functionName: fnName, args: [] });
  } catch (e) {
    const declared = /declares (\d+) argument field\(s\)/.exec(String(e.message));
    if (!declared) throw e;
    report = await wallet.executePrivateFunction({
      ...common,
      artifact: doc,
      functionName: fnName,
      args: new Array(Number(declared[1])).fill(0n),
    });
  }
  rows.push({
    contract: report.contractName,
    fn: fnName,
    type: report.functionType,
    bytes: report.bytecodeBytes,
    args: report.argFields,
    outcome: report.outcome,
    stoppedAt: report.stoppedAtOracle,
    served: report.oraclesServed,
    refused: report.oraclesRefused,
    witness: report.solvedWitnessSize ?? null,
    // The whole ordered ledger, so "where does it stop NEXT" is readable rather than inferred.
    ledger: report.oracleCalls.map((c) => `${c.outcome}:${c.oracle}`),
    errorChain: report.errorChain ?? null,
  });
}

console.log(JSON.stringify({ ladder: rows }, null, 2));
await runtime.close();
