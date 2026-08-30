// M36 SPIKE — the ladder with a real discovery source attached.
//
// Measures how far `Token.transfer`, `Token.mint_to_private` and `PrivateVoting.cast_vote` get once
// M36's nine oracles answer. Scratchpad; ships nothing.

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const REPO = path.resolve(import.meta.dirname, '../..');
const DIST = path.join(REPO, 'browser/dist');
const AVM_WASM = process.env.AVM_WASM_PATH;
if (!AVM_WASM || !existsSync(AVM_WASM)) {
  console.error(`AVM_WASM_PATH is not set (${AVM_WASM})`);
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
const stdlibAbi = await import(pathToFileURL(findUnder('node_modules/@aztec/stdlib/dest/abi/index.js')).href);
const stdlibContract = await import(pathToFileURL(findUnder('node_modules/@aztec/stdlib/dest/contract/index.js')).href);
const stdlibKeys = await import(pathToFileURL(findUnder('node_modules/@aztec/stdlib/dest/keys/index.js')).href);

const runtime = await testing.openAvmRuntime({
  moduleUrl: 'file:///avm.wasm',
  clock: new testing.DateProvider(),
  production: { intervalMs: 0, minBlockSpacingSeconds: 1 },
  fetch: async () => new Response(readFileSync(AVM_WASM), { headers: { 'content-type': 'application/wasm' } }),
});

await wallet.initPrivateExecution({
  acvmWasmUrl: readFileSync(findUnder('node_modules/@aztec/noir-acvm_js/web/acvm_js_bg.wasm')),
  noircAbiWasmUrl: readFileSync(findUnder('node_modules/@aztec/noir-noirc_abi/web/noirc_abi_wasm_bg.wasm')),
});

const artifacts = {
  Token: JSON.parse(readFileSync(findUnder('node_modules/@aztec/noir-contracts.js/artifacts/token_contract-Token.json',
    ['diffsim', 'spike', 'drift', 'probe-mt', 'orchestration']), 'utf8')),
  PrivateVoting: JSON.parse(readFileSync(findUnder('node_modules/@aztec/noir-contracts.js/artifacts/private_voting_contract-PrivateVoting.json',
    ['diffsim', 'spike', 'drift', 'probe-mt', 'orchestration']), 'utf8')),
  OracleVersionCheck: JSON.parse(readFileSync(findUnder('node_modules/@aztec/noir-test-contracts.js/artifacts/oracle_version_check_contract-OracleVersionCheck.json',
    ['diffsim', 'spike', 'drift', 'probe-mt', 'orchestration']), 'utf8')),
  NoteGetter: JSON.parse(readFileSync(findUnder('node_modules/@aztec/noir-test-contracts.js/artifacts/note_getter_contract-NoteGetter.json',
    ['diffsim', 'spike', 'drift', 'probe-mt', 'orchestration']), 'utf8')),
  TestLog: JSON.parse(readFileSync(findUnder('node_modules/@aztec/noir-test-contracts.js/artifacts/test_log_contract-TestLog.json',
    ['diffsim', 'spike', 'drift', 'probe-mt', 'orchestration']), 'utf8')),
};

// The wallet's deterministic accounts, and the tagging half built from them.
const accounts = await wallet.deriveDevAccounts(wallet.DEFAULT_DEV_WALLET_SEED, 2);
const taggingAccounts = [];
for (const a of accounts) {
  const derived = await stdlibKeys.deriveKeys(a.secret);
  const complete = await stdlibContract.CompleteAddress.fromPublicKeysAndPartialAddress(a.publicKeys, a.partialAddress);
  taggingAccounts.push({ address: a.address, completeAddress: complete, ivsk: derived.masterIncomingViewingSecretKey });
}

const deployer = accounts[0].address;
const loadedToken = stdlibAbi.loadContractArtifact(artifacts.Token);
const { contractInstance } = await testing.createContractClassAndInstance(
  [deployer, 'Tok', 'TOK', 18],
  deployer,
  loadedToken,
  27,
);
console.error('instance address = ' + contractInstance.address.toString());

const noteDb = new wallet.DevNoteDatabase();
const tagging = new wallet.DevTagging(taggingAccounts, accounts[0].address);
const ephemeral = new wallet.DeterministicEphemeralArrayService(wallet.toFieldValue(0x36n, 'ephemeral seed'));
await ephemeral.prime(64);

const discovery = {
  noteDb,
  tagging,
  ephemeral,
  contractInstance: (address) => (address.equals(contractInstance.address) ? contractInstance : undefined),
  anchorBlockNumber: 0,
  scopes: [],
  taggingProbeWindow: 4,
};

const common = {
  contractAddress: contractInstance.address.toString(),
  msgSender: accounts[0].address.toString(),
  chainId: 1n,
  version: 1n,
  entropySeed: 0x35n,
  discovery,
};

const recipient = accounts[1].address;
const rows = [];
for (const [name, fnName, args] of [
  ['NoteGetter', 'insert_note', [4242n]],
  ['NoteGetter', 'insert_packed_note', [1n, 2n]],
  ['TestLog', 'emit_raw_private_log', [0x1234n, 0x5678n]],
  ['Token', 'mint_to_private', [recipient.toString(), 1000n]],
  ['Token', 'transfer', [recipient.toString(), 10n]],
  ['PrivateVoting', 'cast_vote', [7n, 0n]],
  ['OracleVersionCheck', 'private_function', []],
]) {
  const report = await wallet.executePrivateFunction({
    ...common,
    artifact: artifacts[name],
    functionName: fnName,
    args,
  });
  rows.push({
    contract: report.contractName,
    fn: fnName,
    bytes: report.bytecodeBytes,
    outcome: report.outcome,
    stoppedAt: report.stoppedAtOracle,
    served: report.oraclesServed,
    refused: report.oraclesRefused,
    witness: report.solvedWitnessSize ?? null,
    hasDiscovery: report.hasDiscovery,
    servedSetSize: report.servedSetSize,
    ledger: report.oracleCalls.map((c) => `${c.outcome}:${c.oracle}`),
    errorChain: report.errorChain ?? null,
    createdNotes: report.effects.createdNotes.length,
    offchain: report.effects.offchainEffects.length,
    publicInputs: report.publicInputs ?? null,
  });
}

console.log(JSON.stringify({ ladder: rows, noteDbEvents: noteDb.events() }, null, 2));
await runtime.close();
