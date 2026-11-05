// Standalone real-filesystem dependency adapter; no mocked objects or generated oracle.
// The unchanged RI25 test compares native bytes against this exact upstream fixture.
import { lstatSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import * as original from '../node_modules/@aztec/foundation/dest/testing/files/index.js';
import { isGenerateTestDataEnabled } from '../node_modules/@aztec/foundation/dest/testing/test_data.js';

const fixturePath = 'barretenberg/cpp/src/barretenberg/vm2/testing/minimal_tx.testdata.bin';
const fixtureSha = 'e030497fba43eda15395a1ac3f7974edb687ba78c39614667ef6b012704acdb2';
function originalFixture() {
  const path = process.env.AZTEC_AVM_MINIMAL_TX_TEST_DATA;
  if (!path || !path.startsWith('/')) throw new Error('Missing absolute original RI25 fixture dependency');
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('Original RI25 fixture must be a regular file');
  const bytes = readFileSync(path);
  if (bytes.length !== 188945 || createHash('sha256').update(bytes).digest('hex') !== fixtureSha) {
    throw new Error('Original RI25 fixture integrity mismatch');
  }
  return { path, bytes };
}
export function getPathToFile(path) {
  return path === fixturePath ? originalFixture().path : original.getPathToFile(path);
}
export function readTestData(path) {
  return path === fixturePath ? originalFixture().bytes : original.readTestData(path);
}
export function writeTestData(path, contents, raw = false) {
  if (path !== fixturePath) return original.writeTestData(path, contents, raw);
  if (isGenerateTestDataEnabled()) throw new Error('Generation of the pinned original RI25 fixture is forbidden');
  // Exact original generation-off behavior: no write and no path lookup.
}
// Every other original helper retains its original implementation and semantics.
export const updateInlineTestData = original.updateInlineTestData;
export const updateProtocolCircuitSampleInputs = original.updateProtocolCircuitSampleInputs;
