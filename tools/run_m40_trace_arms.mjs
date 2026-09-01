// M40's trace arm — the PRIVATE half of the transaction whose PUBLIC half M40 executes.
//
//   node tools/run_m40_trace_arms.mjs <work-dir>           (or: just m40-trace-arms)
//
// ===========================================================================================
// WHY THIS EXISTS BESIDE `run_m39_trace_arms.mjs` RATHER THAN INSTEAD OF IT
// ===========================================================================================
//
// M39 traces `Parent.entry_point` — the MINIMAL nested call, whose whole point is that a failure is
// a failure of the nesting and of nothing else. That transaction enqueues no public call, so its
// container's `halves=2` join record has no second half and `joinRecordings` correctly refuses it
// on `count-mismatch`. `NESTED-CALLS.md` §6 says so in as many words.
//
// M40's transaction is `Parent.enqueue_calls_to_child_with_nested_first`: two private frames AND
// two enqueued public calls. This driver traces its private half into one container carrying
// `half=private halves=2 arm=split` under the SAME join identity the browser's public container
// carries — the outer frame's own `argsHash`. Two halves of one transaction, and the pair is what
// `joinRecordings` accepts.
//
// THE TAPE IS THE M40 ARM RUN's, NOT M39's. `~/.cache/aztec-m40-transaction/transaction.json` is
// the report of the run that ALSO produced the public container, so the two halves come from ONE
// browser execution of one transaction rather than from two runs that agree. A join identity
// derived from two different executions would be two transactions that happen to hash alike.
//
// The nested frame is `Parent.enqueue_call_to_child` — the PARENT calling ITSELF — so both frames
// name the parent artifact and the parent's address. That is read off the arm report rather than
// assumed: `run.nested[0].contractName` and `functionName` are what the executor recorded.

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const REPO = path.resolve(import.meta.dirname, '..');
const WORK = process.argv[2] ?? path.join(process.env.HOME, '.cache', 'aztec-m40-trace');
mkdirSync(WORK, { recursive: true });

function fail(message) {
  process.stderr.write(`run_m40_trace_arms: ${message}\n`);
  process.exit(2);
}

const PROBE =
  process.env.M40_PROBE ??
  path.join(process.env.HOME, '.cache', 'aztec-m38-private-trace', 'probe', 'bin', 'm38probe');
if (!existsSync(PROBE)) fail(`no probe at ${PROBE}. Remedy: verification/build_m38_private_trace_probe.sh`);

const TAPE_SOURCE =
  process.env.M40_TAPE_SOURCE ??
  path.join(process.env.HOME, '.cache', 'aztec-m40-transaction', 'transaction.json');
if (!existsSync(TAPE_SOURCE)) fail(`no M40 arm report at ${TAPE_SOURCE}. Remedy: just m40-arms`);

const report = JSON.parse(readFileSync(TAPE_SOURCE, 'utf8'));
const arm = report?.arms?.bothHalves?.report;
if (!arm) fail(`${TAPE_SOURCE} carries no arms.bothHalves.report`);
const run = arm.run;
if (!run) fail('the both-halves arm did not assemble a private frame');
if (run.outcome !== 'executed') fail(`the private half's outcome is '${run.outcome}', not 'executed'`);
if (!Array.isArray(run.nested) || run.nested.length !== 1) {
  fail(`expected exactly one nested private frame, got ${run.nested?.length}`);
}
if (!arm.publicHalf) fail('the both-halves arm ran no public half, so there is no second half to join');

// THE ARTIFACT ROOT IS THE ONE THE ARM RUN USED, ASSERTED RATHER THAN SEARCHED FOR AGAIN. Two
// nightly lines are installed here and the tape belongs to exactly one of them; replaying it into
// the other line's bytecode would diverge at the first oracle for a reason that reads as a tape
// defect.
const ROOTS = (process.env.M40_ARTIFACT_ROOTS ?? 'diffsim:spike:drift:probe-mt:orchestration').split(':');
const REL_PARENT = 'node_modules/@aztec/noir-test-contracts.js/artifacts/parent_contract-Parent.json';
function findUnder(rel) {
  const hit = ROOTS.map((r) => ({ root: r, file: path.join(REPO, r, rel) })).find((t) => existsSync(t.file));
  if (!hit) fail(`no ${rel} under any of: ${ROOTS.join(', ')}`);
  return hit;
}
const parent = findUnder(REL_PARENT);
if (parent.root !== report.assets.parent.root) {
  fail(
    `the arm run took its Parent artifact from '${report.assets.parent.root}' and this driver found ` +
      `'${parent.root}'; the tape belongs to one nightly line and replaying it into the other diverges`,
  );
}

// THE FRAME LIST, READ OFF THE RUN. `contractName`/`functionName` are what the executor recorded,
// so a fixture whose nesting changed moves the spec rather than being replayed into the wrong
// bytecode under an unchanged constant.
const OUTER_FN = run.functionName;
const INNER_FN = run.nested[0].functionName;
const PARENT_ADDR = String(arm.parent.address);
const JOIN_ID = String(arm.joinId);
if (!JOIN_ID.startsWith('0x')) fail(`the arm report carries no join identity (joinId=${JOIN_ID})`);
if (JOIN_ID !== String(run.publicInputs.argsHash)) {
  fail(
    `the arm's joinId ${JOIN_ID} is not the outer frame's argsHash ${run.publicInputs.argsHash}; the two ` +
      'halves would be filed under an identity the circuit did not commit to',
  );
}

const FRAMES = [
  {
    artifact: parent.file,
    function: OUTER_FN,
    tape_frame: 'arms.bothHalves.report.run',
    depth: 0,
    contract_address: PARENT_ADDR,
  },
  {
    // THE SELF-CALL. `enqueue_calls_to_child_with_nested_first` calls `self.address`, so the nested
    // frame's artifact and address are the PARENT's. Asserted below rather than assumed.
    artifact: parent.file,
    function: INNER_FN,
    tape_frame: 'arms.bothHalves.report.run.nested.0',
    depth: 1,
    contract_address: String(run.nested[0].publicInputs?.contractAddress ?? PARENT_ADDR),
  },
];
if (FRAMES[1].contract_address !== PARENT_ADDR) {
  fail(
    `the nested frame ran at ${FRAMES[1].contract_address} and the outer one at ${PARENT_ADDR}; this ` +
      'fixture is a self-call and a second address means the spec would name the wrong artifact',
  );
}

const OUT_DIR = path.join(WORK, 'arms', 'privateHalf');
rmSync(OUT_DIR, { recursive: true, force: true });
mkdirSync(OUT_DIR, { recursive: true });

const spec = {
  arm: 'replay',
  tape_source: TAPE_SOURCE,
  out_dir: OUT_DIR,
  program: `${run.contractName}.${OUTER_FN}`,
  frames: FRAMES,
  join: { id: JOIN_ID, half: 'private', halves: 2, arm: 'split' },
};
const specFile = path.join(WORK, 'spec-privateHalf.json');
writeFileSync(specFile, JSON.stringify(spec, null, 2) + '\n');

let probeOut;
try {
  probeOut = execFileSync(PROBE, [specFile], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
} catch (e) {
  process.stderr.write(String(e.stdout ?? '') + String(e.stderr ?? ''));
  fail(`the probe exited ${e.status}`);
}
// The probe may print a banner before its JSON; the report begins at the first `{`.
const brace = probeOut.indexOf('{');
if (brace < 0) fail(`the probe printed no JSON:\n${probeOut.slice(0, 400)}`);
const probeReport = JSON.parse(probeOut.slice(brace));

const container = probeReport.container;
if (!container || !existsSync(container)) fail(`the probe reported no container (${container})`);
probeReport.containerBytes = statSync(container).size;

const sha = (f) => createHash('sha256').update(readFileSync(f)).digest('hex');

const publicContainer = arm.publicContainer;
const downloaded = report.arms.bothHalves.downloadedFile
  ? path.join(path.dirname(TAPE_SOURCE), report.arms.bothHalves.downloadedFile)
  : null;

const out = {
  measuredAt: new Date().toISOString(),
  probe: { path: PROBE, sha256: sha(PROBE) },
  tapeSource: { path: TAPE_SOURCE, sha256: sha(TAPE_SOURCE) },
  transaction: {
    contractName: run.contractName,
    functionName: OUTER_FN,
    nestedFunctionName: INNER_FN,
    outcome: run.outcome,
    joinId: JOIN_ID,
    outerOracleCalls: run.oracleCalls.length,
    nestedOracleCalls: run.nested[0].oracleCalls.length,
    enqueuedPublicCalls: arm.enqueued.length,
  },
  privateHalf: probeReport,
  publicHalf: {
    containerBytes: publicContainer?.containerBytes ?? null,
    joinRecord: publicContainer?.joinRecord ?? null,
    downloadedFile: downloaded,
    downloadedBytes: downloaded && existsSync(downloaded) ? statSync(downloaded).size : null,
    downloadedSha256: downloaded && existsSync(downloaded) ? sha(downloaded) : null,
    executedSteps: arm.publicHalf.executed?.count ?? null,
    revertCode: arm.publicHalf.revertCode,
  },
};
writeFileSync(path.join(WORK, 'joined-transaction.json'), JSON.stringify(out, null, 2) + '\n');
process.stdout.write(JSON.stringify(out, null, 2) + '\n');
process.exit(0);
