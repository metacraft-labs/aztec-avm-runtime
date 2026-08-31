// M38's arms: an Aztec private function stepped by the Noir tracer, four ways.
//
//   node tools/run_m38_trace_arms.mjs <work-dir> > <work-dir>/trace-arms.json
//
// Each arm runs `m38probe` — the native binary `verification/build_m38_private_trace_probe.sh`
// stages — over an installed Aztec contract artifact, replaying the oracle tape M35's own handler
// recorded in a browser. The four differ in ONE thing each, and each difference is a refusal the
// executor must make BY NAME:
//
//   replay     the whole tape of a frame that COMPLETED. Nothing refuses; the ceiling.
//   truncate   the same tape with its last entry dropped. The frame runs out of answers.
//   refuseAll  the same tape emptied. The FIRST oracle refuses.
//   transfer   a different, much larger circuit whose recording STOPPED at an oracle M35 does not
//              serve. The tape carries that call with no answer, and the executor must refuse it
//              rather than hand back a fabricated answer of length zero.
//
// The arms are mutations of the TAPE rather than of the executor, so the refusal path under test is
// the shipped one.
//
// ENVIRONMENT
//   M38_PROBE        the probe binary (default `<work>/probe/bin/m38probe`)
//   M38_TAPE_SOURCE  the M35 arm report (default `~/.cache/aztec-m35-private/private-execution.json`)
//   M38_ARTIFACT_ROOTS  colon-separated trees to look for the installed artifacts under

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import process from 'node:process';

const work = process.argv[2];
if (!work) {
  process.stderr.write('run_m38_trace_arms.mjs: no work directory given\n');
  process.exit(2);
}

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const probe = process.env.M38_PROBE || path.join(work, 'probe', 'bin', 'm38probe');
const tapeSource =
  process.env.M38_TAPE_SOURCE || path.join(homedir(), '.cache', 'aztec-m35-private', 'private-execution.json');

function die(message) {
  process.stderr.write(`run_m38_trace_arms.mjs: ${message}\n`);
  process.exit(1);
}

if (!existsSync(probe)) die(`no probe at ${probe} — run verification/build_m38_private_trace_probe.sh`);
if (!existsSync(tapeSource)) die(`no M35 arm report at ${tapeSource} — run \`just m35-arms\``);

// THE ARTIFACTS ARE THE INSTALLED ONES, FOUND THE WAY M35'S OWN RUNNER FINDS THEM: a search over
// the harness trees rather than a path typed here, so a tree that moves is a named failure rather
// than a silently different artifact.
const searchRoots = (process.env.M38_ARTIFACT_ROOTS || 'diffsim:spike:drift:probe-mt:orchestration')
  .split(':')
  .map((r) => path.join(repoRoot, r));

function findArtifact(rel) {
  for (const root of searchRoots) {
    const candidate = path.join(root, 'node_modules', rel);
    if (existsSync(candidate)) return { path: candidate, root: path.basename(root) };
  }
  die(`no ${rel} under any of ${searchRoots.join(', ')}`);
}

const oracleCheck = findArtifact(
  '@aztec/noir-test-contracts.js/artifacts/oracle_version_check_contract-OracleVersionCheck.json',
);
const token = findArtifact('@aztec/noir-contracts.js/artifacts/token_contract-Token.json');

const sha = (p) => createHash('sha256').update(readFileSync(p)).digest('hex');

const ARMS = [
  {
    name: 'replay',
    arm: 'replay',
    artifact: oracleCheck.path,
    function: 'private_function',
    tape_frame: 'arms.private.report.executes',
  },
  {
    name: 'truncate',
    arm: 'truncate',
    artifact: oracleCheck.path,
    function: 'private_function',
    tape_frame: 'arms.private.report.executes',
  },
  {
    name: 'refuseAll',
    arm: 'refuse-all',
    artifact: oracleCheck.path,
    function: 'private_function',
    tape_frame: 'arms.private.report.executes',
  },
  {
    name: 'transfer',
    arm: 'replay',
    artifact: token.path,
    function: 'transfer',
    tape_frame: 'arms.private.report.refuses',
  },
];

const arms = {};
for (const spec of ARMS) {
  const outDir = path.join(work, 'arms', spec.name);
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const specPath = path.join(work, `spec-${spec.name}.json`);
  writeFileSync(
    specPath,
    JSON.stringify(
      {
        arm: spec.arm,
        artifact: spec.artifact,
        function: spec.function,
        tape_source: tapeSource,
        tape_frame: spec.tape_frame,
        out_dir: outDir,
      },
      null,
      2,
    ),
  );
  let out;
  try {
    out = execFileSync(probe, [specPath], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  } catch (e) {
    die(`arm ${spec.name} exited ${e.status}: ${String(e.stderr ?? '').slice(-2000)}`);
  }
  // The probe prints one JSON document on stdout; anything before it is the dev shell's own
  // banner, which is why the parse starts at the first brace rather than at byte zero.
  const brace = out.indexOf('{');
  if (brace < 0) die(`arm ${spec.name} printed no JSON`);
  const report = JSON.parse(out.slice(brace));
  report.containerBytes = report.container && existsSync(report.container) ? readFileSync(report.container).length : 0;
  arms[spec.name] = report;
}

process.stdout.write(
  `${JSON.stringify(
    {
      measuredAt: new Date().toISOString(),
      probe: { path: probe, sha256: sha(probe) },
      tapeSource: { path: tapeSource, sha256: sha(tapeSource) },
      artifacts: {
        oracleCheck: { path: oracleCheck.path, root: oracleCheck.root, sha256: sha(oracleCheck.path) },
        token: { path: token.path, root: token.root, sha256: sha(token.path) },
      },
      arms,
    },
    null,
    2,
  )}\n`,
);
