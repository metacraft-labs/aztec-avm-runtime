// M39's trace arms — a TRANSACTION's private half stepped into ONE `.ct` container.
//
//   node tools/run_m39_trace_arms.mjs <work-dir> > <work-dir>/transaction-trace.json
//
// ===========================================================================================
// WHAT IS DIFFERENT FROM M38'S ARMS, WHICH IS ONE THING
// ===========================================================================================
//
// M38 stepped a FRAME. This steps a TRANSACTION: `Parent.entry_point` and the `Child.value` it
// called, into one container, the child's frame nested inside the parent's. The probe is M38's
// own, unchanged except for the frame list it grew — a spec with no `frames` still describes one
// frame and still produces a byte-identical container, which was measured across all five of M38's
// arms before this file existed.
//
// The tapes come from `~/.cache/aztec-m39-nested/nested.json`, which is a real transaction executed
// in Chromium: the parent's tape at `arms.nested.report.run` and the child's at
// `arms.nested.report.run.nested.0`. **A transaction's tape is per FRAME because a circuit is per
// frame** — the tracer steps one circuit at a time, and which tape belongs to which circuit is what
// a flattened tape throws away.
//
// ===========================================================================================
// THE ARMS
// ===========================================================================================
//
//   transaction   both frames, in pre-order, depth 0 then depth 1. The ceiling.
//   parentOnly    the SAME parent frame alone, with no child in the list. Its steps must be the
//                 parent's exactly, and the container must carry NO call and NO return — which is
//                 what says the two calls in the `transaction` arm are the nesting and not
//                 something the writer does on its own.
//
// `parentOnly` is not a spare: without it, "the container has one Call and one Return" is a number
// with nothing to compare it against, and a writer that emitted a Call per frame regardless would
// satisfy it.

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const REPO = path.resolve(import.meta.dirname, '..');
const WORK = process.argv[2] ?? path.join(process.env.HOME, '.cache', 'aztec-m39-trace');
mkdirSync(WORK, { recursive: true });

function fail(message) {
  process.stderr.write(`run_m39_trace_arms: ${message}\n`);
  process.exit(2);
}

const PROBE = process.env.M39_PROBE ?? path.join(process.env.HOME, '.cache', 'aztec-m38-private-trace', 'probe/bin/m38probe');
if (!existsSync(PROBE)) fail(`no probe at ${PROBE}. Remedy: just m38-probe-build`);

const TAPE_SOURCE =
  process.env.M39_TAPE_SOURCE ?? path.join(process.env.HOME, '.cache', 'aztec-m39-nested', 'nested.json');
if (!existsSync(TAPE_SOURCE)) fail(`no nested-call arm report at ${TAPE_SOURCE}. Remedy: just m39-arms`);

const ROOTS = (process.env.M39_ARTIFACT_ROOTS ?? 'diffsim:spike:drift:probe-mt:orchestration').split(':');
function findUnder(rel) {
  for (const root of ROOTS) {
    const file = path.join(REPO, root, rel);
    if (existsSync(file)) return { root, file };
  }
  fail(`no ${rel} under any of: ${ROOTS.join(', ')}`);
}

// THE ARTIFACTS ARE THE ONES THE PAGE EXECUTED, and which nightly line they came from is read back
// out of the arm report rather than assumed here — the report records the root and the version per
// asset for exactly this reason, and a probe stepping a different artifact from the one that
// produced the tape would replay answers into bytecode that never asked for them.
const armReport = JSON.parse(readFileSync(TAPE_SOURCE, 'utf8'));
const nestedArm = armReport?.arms?.nested;
if (!nestedArm?.report?.run) {
  fail(`${TAPE_SOURCE} carries no arms.nested.report.run; the nested-call arm did not produce a run`);
}
const run = nestedArm.report.run;
if (run.outcome !== 'executed') {
  fail(`the nested-call arm's transaction did not execute (outcome=${run.outcome}); there is nothing to step`);
}
if (!Array.isArray(run.nested) || run.nested.length !== 1) {
  fail(`expected exactly one nested frame in the arm report, got ${run.nested?.length ?? 'none'}`);
}
const childReport = run.nested[0];

const expectedParentRoot = armReport.assets?.parent?.root;
const parentArtifact = findUnder('node_modules/@aztec/noir-test-contracts.js/artifacts/parent_contract-Parent.json');
const childArtifact = findUnder('node_modules/@aztec/noir-test-contracts.js/artifacts/child_contract-Child.json');
if (expectedParentRoot && parentArtifact.root !== expectedParentRoot) {
  fail(
    `the arm report's parent artifact came from '${expectedParentRoot}' and this search found ` +
      `'${parentArtifact.root}'. Replaying one line's tape into another line's bytecode is the ` +
      `wire-shape gap PRIVATE-EXECUTION.md section 3b records, arriving through a search order.`,
  );
}

const sha = (f) => createHash('sha256').update(readFileSync(f)).digest('hex');

const FRAME_PARENT = {
  artifact: parentArtifact.file,
  function: run.functionName,
  tape_frame: 'arms.nested.report.run',
  depth: 0,
  contract_address: run.publicInputs.contractAddress,
};
const FRAME_CHILD = {
  artifact: childArtifact.file,
  function: childReport.functionName,
  tape_frame: 'arms.nested.report.run.nested.0',
  depth: 1,
  contract_address: childReport.publicInputs.contractAddress,
};

// THE JOIN IDENTITY IS DERIVED FROM THE TRANSACTION, NOT MINTED. It is the parent frame's own
// `argsHash` — a value the CIRCUIT committed to — so two runs of the same transaction produce the
// same identity and two different transactions cannot collide. A random id would make the join a
// fact about when the driver ran.
const JOIN_ID = run.publicInputs.argsHash;

const ARMS = [
  {
    name: 'transaction',
    frames: [FRAME_PARENT, FRAME_CHILD],
    // `halves: 2` and `arm: split` because this is the PRIVATE half of a two-container recording —
    // OQ-7's shipped fallback. Declaring `halves: 1` over a container that is one of two is the
    // exact confusion `JOIN-SHAPE.md` §4 put `halves` in the record to prevent.
    join: { id: JOIN_ID, half: 'private', halves: 2, arm: 'split' },
  },
  { name: 'parentOnly', frames: [FRAME_PARENT] },
];

const arms = {};
let exitCode = 0;
for (const arm of ARMS) {
  const outDir = path.join(WORK, 'arms', arm.name);
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const spec = {
    arm: 'replay',
    tape_source: TAPE_SOURCE,
    out_dir: outDir,
    program: `${run.contractName}.${run.functionName}`,
    frames: arm.frames,
    // `parentOnly` carries NO join, deliberately: it is a control over one frame and not a half of
    // anything, and a record claiming otherwise would be the inference this grammar exists to
    // refuse. It is also what makes "the transaction arm's container carries a join record" a
    // measurement rather than a property of the writer.
    ...(arm.join ? { join: arm.join } : {}),
  };
  const specPath = path.join(WORK, `spec-${arm.name}.json`);
  writeFileSync(specPath, JSON.stringify(spec, null, 2) + '\n');
  try {
    // THE PROBE'S BANNER IS NOT ITS OUTPUT. The dev shell prints a line before the program runs, so
    // the JSON is parsed from the first `{` — M38's own rule, for M38's own reason.
    const raw = execFileSync(PROBE, [specPath], { maxBuffer: 64 * 1024 * 1024 }).toString();
    const report = JSON.parse(raw.slice(raw.indexOf('{')));
    report.containerBytes = report.container ? statSync(report.container).size : null;
    arms[arm.name] = report;
  } catch (e) {
    exitCode = 1;
    arms[arm.name] = { error: String(e?.message ?? e).slice(0, 4000) };
  }
}

const out = {
  measuredAt: new Date().toISOString(),
  probe: { path: PROBE, sha256: sha(PROBE) },
  tapeSource: { path: TAPE_SOURCE, sha256: sha(TAPE_SOURCE) },
  transaction: {
    contractName: run.contractName,
    functionName: run.functionName,
    outcome: run.outcome,
    wireCompatApplied: run.wireCompatApplied,
    parentOracleCalls: run.oracleCalls.length,
    childOracleCalls: childReport.oracleCalls.length,
    parentCounters: [run.publicInputs.startSideEffectCounter, run.publicInputs.endSideEffectCounter],
    childCounters: [childReport.publicInputs.startSideEffectCounter, childReport.publicInputs.endSideEffectCounter],
    returnsHashesEqual: run.publicInputs.returnsHash === childReport.publicInputs.returnsHash,
  },
  artifacts: {
    parent: { root: parentArtifact.root, sha256: sha(parentArtifact.file), bytes: statSync(parentArtifact.file).size },
    child: { root: childArtifact.root, sha256: sha(childArtifact.file), bytes: statSync(childArtifact.file).size },
  },
  arms,
};
process.stdout.write(JSON.stringify(out, null, 2) + '\n');
process.exit(exitCode);
