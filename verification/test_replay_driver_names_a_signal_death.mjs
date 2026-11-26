#!/usr/bin/env node
// A replay driver that is KILLED BY A SIGNAL must still leave a name on stderr.
//
// aztec-avm-runtime#24: 104 of 105 refused live transactions left nothing at all. The process
// died with SIGSEGV, wrote 0 bytes to stdout and named no error class, because nothing that
// runs inside a process can speak after that process takes a fatal signal. So the name has
// to come from OUTSIDE it. `replay/tools/runtime_crash_guard.mjs` is the driver's first
// import: it re-runs the driver as a child, and if the child dies by a signal it prints a
// `RuntimeCrashed:` line with `kind: 'runtime-crashed'` and the signal, then exits
// 128 + signo, the status a shell would have reported.
//
// `runtime-crashed` is the member blocktracer's `tools/chain/refusal-reasons.json` declares for
// "the replay driver died without declining" (blocktracer 0a3af843), and the kind uses its
// spelling.
//
// ARMS, all through the guard module itself, against a tiny entry script rather than the full
// driver (which would need a network or a fixture and avm.wasm):
//   1. the child takes SIGSEGV       -> RuntimeCrashed line, kind, signal, exit 139
//   2. the child exits 3, says no name -> exit 3, no RuntimeCrashed line: a plain failure is
//                                       not a crash, and the guard does not rename it
//   3. the child succeeds with output  -> stdout passes through byte for byte, exit 0
//   4. the driver's FIRST import is the guard, so the guard runs before anything else is
//      evaluated
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const guardUrl = pathToFileURL(join(root, 'replay/tools/runtime_crash_guard.mjs')).href;
const dir = mkdtempSync(join(tmpdir(), 'crash-guard-'));

const entry = (name, body) => {
  const file = join(dir, `${name}.mjs`);
  writeFileSync(file, `import ${JSON.stringify(guardUrl)};\n${body}\n`);
  return file;
};
// `ulimit -c 0`: arm 1 kills a process with SIGSEGV on purpose, and that must not leave a core.
const run = (file) => spawnSync('sh', ['-c', 'ulimit -c 0; exec "$0" "$@"', process.execPath, file],
  { encoding: 'utf8', timeout: 60_000 });

try {
  // 1. A signal death is named.
  const crash = run(entry('crash', `process.stdout.write('partial'); process.kill(process.pid, 'SIGSEGV');`));
  assert.equal(crash.status, 139, `a SIGSEGV child must surface as exit 139, got ${crash.status}/${crash.signal}\n${crash.stderr}`);
  assert.match(crash.stderr, /^RuntimeCrashed: .*SIGSEGV/m, `no RuntimeCrashed line:\n${crash.stderr}`);
  assert.match(crash.stderr, /kind: 'runtime-crashed'/);
  assert.match(crash.stderr, /signal: 'SIGSEGV'/);
  assert.equal(crash.stdout, 'partial', 'what the child wrote before dying must still reach stdout');
  console.log('arm 1: a child killed by SIGSEGV -> RuntimeCrashed, runtime-crashed, exit 139');

  // 2. An ordinary failure keeps its own status and is not renamed.
  const fail = run(entry('fail', `process.exit(3);`));
  assert.equal(fail.status, 3);
  assert.doesNotMatch(fail.stderr, /RuntimeCrashed/);
  console.log('arm 2: a child that exits 3 -> exit 3, not renamed');

  // 3. Success passes through untouched, once (the guard must not run the body twice).
  const ok = run(entry('ok', `process.stdout.write('{"report":1}\\n');`));
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(ok.stdout, '{"report":1}\n');
  console.log('arm 3: success -> stdout byte for byte, exit 0');

  // 4. The driver imports the guard before anything else.
  const driver = readFileSync(join(root, 'replay/tools/replay_settled_transaction.mjs'), 'utf8');
  const firstImport = driver.split('\n').find((l) => /^import\b/.test(l));
  assert.equal(firstImport, "import './runtime_crash_guard.mjs';",
    `the driver's first import must be the crash guard, got: ${firstImport}`);
  console.log('arm 4: the driver imports the guard first');
  console.log('PASS');
} finally {
  rmSync(dir, { recursive: true, force: true });
}
