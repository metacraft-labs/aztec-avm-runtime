// Drive a `ct_writer.wasm` module through one fixed event sequence and write out what it produced.
//
//   node verification/ct_writer_drive.mjs <module.wasm> <out-dir>
//
// This is the NODE wrapper. The drive itself — the event sequence, the expectations, every call —
// is `ct_writer_drive_core.mjs`, which imports nothing and is loaded unchanged by a real page in
// `tools/m41_browser_writer.mjs`. One driver, both writers, both hosts: if each arm had its own,
// a difference a check found could be the driver's rather than the writer's.
//
// THE MODULE IS INSTANTIATED AGAINST A LITERAL `{}`. Not against an import object that happens to
// be empty — against the literal, so a module that grew an import fails here with a LinkError
// rather than being quietly satisfied. That is the browser's condition, and it is what
// `verify_nim_writer_module_is_zero_import` measures; instantiating that way here too means every
// run of every check that uses this file re-establishes it.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

import { driveWriter, EXPECTED_STEPS, DRIVEN_STEP_COUNT } from './ct_writer_drive_core.mjs';

const [, , modulePath, outDir, compactThresholdArg] = process.argv;
if (!modulePath || !outDir) {
  console.error('usage: ct_writer_drive.mjs <module.wasm> <out-dir> [compact-threshold]');
  process.exit(2);
}

// CCP-6. ABSENT MEANS ZERO, which means the full profile always — so every existing caller, which
// passes two arguments, drives exactly the container it drove before this argument existed. A
// non-zero value asks for container version 6 / profile 1, which the replay engine pinned in
// BlockTracer's `client/hydrate/engine-pin.txt` cannot read; it is for the check that measures the
// emission and for nothing that publishes.
let compactThreshold = 0n;
if (compactThresholdArg !== undefined) {
  if (!/^[0-9]+$/.test(compactThresholdArg)) {
    console.error(`compact-threshold must be a non-negative integer, got [${compactThresholdArg}]`);
    process.exit(2);
  }
  compactThreshold = BigInt(compactThresholdArg);
}

const bytes = readFileSync(modulePath);
const { instance } = await WebAssembly.instantiate(bytes, {});

let result;
try {
  result = driveWriter(instance.exports, { compactThreshold });
} catch (e) {
  console.error(`driving ${modulePath} failed: ${e.message}`);
  process.exit(1);
}

const { report, container } = result;
report.module = modulePath;
report.host = 'node';
report.expectedSteps = EXPECTED_STEPS;
report.drivenStepCount = DRIVEN_STEP_COUNT;

mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, 'container.ct'), container);
writeFileSync(join(outDir, 'report.json'), `${JSON.stringify(report, null, 2)}\n`);
console.log(
  `drove ${modulePath}: kind=${report.writerKind}, ${container.length} container bytes, ` +
    `v${report.containerVersion} profile=${report.containerProfile}, ` +
    `compactThreshold=${report.compactThreshold}`,
);
