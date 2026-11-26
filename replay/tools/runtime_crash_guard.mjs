// runtime_crash_guard.mjs: a driver killed by a signal still names what happened.
//
// THE FIRST IMPORT OF `replay_settled_transaction.mjs`, AND IT HAS TO BE. A process that takes
// SIGSEGV cannot say anything afterwards. No handler in JavaScript runs, and Node refuses
// listeners for SIGSEGV, SIGBUS, SIGFPE and SIGILL. aztec-avm-runtime#24 measured what that
// costs: 104 of 105 refused live transactions died with exit 139, 0 bytes on stdout and no
// error class on stderr, so the caller had nothing to file them under. The name therefore has
// to come from a process that did NOT die, which is this module in the parent.
//
// HOW. Unsupervised, this module re-runs the same entry point, with the same node flags and the
// same arguments, as a child that inherits stdin, stdout and stderr, and it waits. Then:
//
//   child killed by a signal -> `RuntimeCrashed: …` with kind 'runtime-crashed' and the signal,
//                               then exit 128 + signo, which is the status a shell reports for
//                               that death, so a caller that reads the status sees what it saw
//                               before.
//   child exited with N      -> exit N, and say nothing. A refusal the driver named is already
//                               on stderr, and a plain non-zero exit is not a crash.
//
// `runtime-crashed` is blocktracer's member for "the replay driver died without declining"
// (`tools/chain/refusal-reasons.json`, blocktracer 0a3af843), and `kind` uses its spelling.
//
// WHY `spawnSync` AND NOT `spawn` + top-level await. Node evaluates the importing module's
// LATER imports while an earlier one is suspended at a top-level await (measured). An async
// guard would therefore evaluate the whole driver graph (bb.js, @aztec stdlib) in the parent as
// well as in the child. `spawnSync` blocks before any later import is evaluated, so the parent
// only pays for parsing the graph.
//
// WHAT IT DOES NOT DO. It does not forward a signal sent to the PARENT'S PID alone. A process
// group or cgroup kill (Ctrl-C, systemd's default KillMode=control-group) reaches both
// processes. blocktracer's `lib/replay.mjs` never kills a replay.
import { spawnSync } from 'node:child_process';
import { constants } from 'node:os';
import { inspect } from 'node:util';

const SUPERVISED = 'AZTEC_REPLAY_DRIVER_SUPERVISED';

if (process.env[SUPERVISED] !== '1') {
  const child = spawnSync(process.execPath, [...process.execArgv, ...process.argv.slice(1)], {
    stdio: 'inherit',
    env: { ...process.env, [SUPERVISED]: '1' },
  });
  if (child.error) throw child.error;
  if (child.signal) {
    const signo = constants.signals[child.signal] ?? 0;
    const exitStatus = 128 + signo;
    process.stderr.write(
      `RuntimeCrashed: the replay driver was killed by ${child.signal} (signal ${signo}) before it `
      + 'reported or named a refusal. The transaction was not declined by the runtime; the '
      + 'process running it died, and a runtime that did not crash would replay it.\n'
      + `${inspect({ kind: 'runtime-crashed', signal: child.signal, exitStatus })}\n`);
    process.exit(exitStatus);
  }
  process.exit(child.status ?? 1);
}
