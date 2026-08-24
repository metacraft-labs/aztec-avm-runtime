// What THIS engine will and will not compile, and what the loader's gate does about it.
//
// It lives inside the package rather than beside the checks because it is part of the gate's own
// story and because the package is where `tsc -p tsconfig.json` already covers it.
//
// Run twice by `verify_node_v8_accepts_module`: once on the plain interpreter and once with
// `--no-experimental-wasm-legacy-eh`. The difference between the two runs IS the finding — the
// pinned V8 accepts the legacy exception encoding by default, so "avm.wasm loaded" is not on its
// own evidence that avm.wasm uses `try_table`.
//
// Usage: node engine-probe.ts <avm.wasm>

import { readFile } from 'node:fs/promises';
import process from 'node:process';

import {
  AvmToolchainRegression,
  LEGACY_EH_PROBE,
  TRY_TABLE_PROBE,
  assertExceptionSupport,
  engineAcceptsLegacyEh,
  engineAcceptsTryTable,
  sectionIds,
} from './loader.ts';

const lines: string[] = [];
const line = (k: string, v: string | number): void => {
  lines.push(`${k} ${v}`);
};

const wasmPath = process.argv[2];
if (!wasmPath) {
  process.stderr.write('usage: engine-probe.ts <avm.wasm>\n');
  process.exit(2);
}

line('engine.v8', process.versions.v8 ?? '(unknown)');
line('engine.node', process.version ?? '(unknown)');
line('engine.acceptsTryTable', engineAcceptsTryTable() ? 1 : 0);
line('engine.acceptsLegacyEh', engineAcceptsLegacyEh() ? 1 : 0);

// The compile error the engine gives for the encoding it refuses, so the refusal is identified by
// its cause rather than by "it did not load".
function compileError(bytes: Uint8Array): string {
  try {
    new WebAssembly.Module(bytes as unknown as BufferSource);
    return '(compiled)';
  } catch (e) {
    return (e as Error).message.replace(/\s+/g, ' ').slice(0, 120);
  }
}
line('engine.legacyProbeCompile', compileError(LEGACY_EH_PROBE));
line('engine.tryTableProbeCompile', compileError(TRY_TABLE_PROBE));

const bytes = await readFile(wasmPath);
line('module.compile', compileError(bytes));
line('module.hasTagSection', sectionIds(bytes).includes(13) ? 1 : 0);

// The gate's own verdict on the real module.
let gate = 'accepted';
try {
  assertExceptionSupport(bytes);
} catch (e) {
  gate = e instanceof AvmToolchainRegression ? 'toolchain-regression' : 'other';
}
line('gate.onRealModule', gate);

// THE NEGATIVE CONTROL FOR THE GATE. A minimal module with no tag section at all: exactly what a
// build with exceptions compiled out looks like from the outside. The gate must refuse it, or the
// green verdict above is a statement about nothing.
const NO_TAG_MODULE = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // header
  0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: [] -> [i32]
  0x03, 0x02, 0x01, 0x00, // function: one, of type 0
  0x07, 0x09, 0x01, 0x05, 0x70, 0x72, 0x6f, 0x62, 0x65, 0x00, 0x00, // export "probe"
  0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x01, 0x0b, // code: i32.const 1
]);
line('control.noTagModuleCompiles', WebAssembly.validate(NO_TAG_MODULE) ? 1 : 0);
line('control.noTagModuleHasTagSection', sectionIds(NO_TAG_MODULE).includes(13) ? 1 : 0);
let controlGate = 'accepted';
try {
  assertExceptionSupport(NO_TAG_MODULE);
} catch (e) {
  controlGate = e instanceof AvmToolchainRegression ? 'toolchain-regression' : 'other';
}
line('control.gateOnNoTagModule', controlGate);

line('probe.done', 1);
process.stdout.write(lines.join('\n') + '\n', () => process.exit(0));
