#!/usr/bin/env node
// Run the actual CLI in a fresh process: importing its crypto dependency here
// could initialize a singleton and hide a missing initialization in the CLI.
// The fixture contains real historical node responses and a non-empty compressed
// proof. The negative control removes a recorded witness; it invents no answer.
// The child uses an empty HOME/CRS directory and the upstream-supported missing
// native-binary setting, exercising the real WASM crypto backend. A preload
// denies HTTP(S) fetches solely to prove the offline boundary; node responses,
// proof decoding, hashing and AVM execution still use their real implementations.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const fixturePath = join(root, 'replay/fixtures/testnet_replay_tx_proof.json');
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
const module = process.env.AVM_WASM_PATH ?? process.env.L2_MODULE;
assert.ok(module, 'AVM_WASM_PATH must name the execution-observer AVM module');
const body = fixture.calls.find((call) => call.method.endsWith('_getTxByHash')).result;
assert.ok(Buffer.from(body.chonkProof, 'base64').length > 30000,
          'the regression subject must carry a real non-empty compressed proof');

const temp = mkdtempSync(join(tmpdir(), 'aztec-offline-proof-'));
const guard = join(temp, 'deny-network.mjs');
writeFileSync(guard, `
const fetchOriginal = globalThis.fetch;
globalThis.fetch = (input, init) => {
  const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
  if (url.protocol === 'http:' || url.protocol === 'https:') {
    throw new Error('offline replay attempted network fetch: ' + url);
  }
  return fetchOriginal(input, init);
};
`);
const replay = (path) => spawnSync(process.execPath, ['--experimental-wasm-exnref',
  '--import', pathToFileURL(guard).href,
  join(root, 'replay/tools/replay_settled_transaction.mjs'),
  '--fixture', path, '--module', module, '--json'], {
  cwd: root, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
  env: { ...process.env, HOME: temp, CRS_PATH: join(temp, 'crs'),
    BB_BINARY_PATH: join(temp, 'no-native-bb'), HARDWARE_CONCURRENCY: '2' },
});
try {
  const actual = replay(fixturePath);
  assert.equal(actual.status, 0, actual.stderr);
  const report = JSON.parse(actual.stdout);
  assert.equal(report.txHash, '0x0a807e4e9909fc66ceeb52e4192406077a06ce378ab9e00717555fbd41b50592');
  assert.equal(report.instructionsExecuted, 459);
  assert.equal(report.verdict.reproduced, true);
  assert.equal(report.verdict.mismatched, 0);
  const incomplete = structuredClone(fixture);
  incomplete.calls = incomplete.calls.filter((call) => !call.method.endsWith('_getPublicDataWitness'));
  assert.ok(incomplete.calls.length < fixture.calls.length, 'the control must remove a witness');
  const path = join(temp, 'incomplete.json');
  writeFileSync(path, JSON.stringify(incomplete));
  const missing = replay(path);
  assert.notEqual(missing.status, 0, 'missing state must fail playback');
  assert.match(missing.stderr, /FixtureMiss/);
  assert.doesNotMatch(missing.stderr, /First call BarretenbergSync/);
  console.log('offline compressed-proof replay: empty crypto cache and denied network; 459 instructions reproduce; missing witness refuses by name');
} finally {
  rmSync(temp, { recursive: true, force: true });
}
