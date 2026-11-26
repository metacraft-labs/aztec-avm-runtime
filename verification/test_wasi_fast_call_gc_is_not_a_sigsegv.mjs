#!/usr/bin/env node
// A GC triggered INSIDE node:wasi's `fd_write` Fast API callback must not kill the process.
//
// THE DEFECT (aztec-avm-runtime#24). On node 22.23.2 (V8 12.4.254.21-node.56; nixpkgs
// `nodejs_22`, which is what blocktracer's follower runs) `node::wasi::WASI::FdWrite` is
// reached as a V8 FAST API CALL. uvwasi allocates its iovec array through node's
// `NgLibMemoryManager`, which reports the bytes with
// `Isolate::AdjustAmountOfExternalAllocatedMemory`. Past V8's external-memory pressure limit
// that report runs a full mark-compact synchronously, with the fast-call frame still on the
// stack, and the GC's stack walk faults in `InnerPointerToCodeCache::GetCacheEntry`: exit 139,
// nothing on stdout, no error class. In the replay driver this happened in the step pass, when
// avm.wasm logs through `fd_write`, on 104 of 105 refused live transactions.
//
// THE SUBJECT IS NOT avm.wasm. It is a 151-byte module that imports only `fd_write` and calls
// it with a large `iovs_len`, so uvwasi's allocation is the one that crosses the limit. That
// keeps the test about the mechanism, offline, and independent of any Aztec artefact.
// Source, for review (wabt `wat2wasm`, sha256 ef67a70d…):
//
//   (module
//     (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
//     (memory (export "memory") 1024)
//     (func (export "_start"))
//     (func (export "write") (param $fd i32) (param $n i32) (param $times i32) (result i32)
//       (local $i i32) (local $r i32)
//       (loop $l
//         (local.set $r (call $fd_write (local.get $fd) (i32.const 0) (local.get $n) (i32.const 62914560)))
//         (local.set $i (i32.add (local.get $i) (i32.const 1)))
//         (br_if $l (i32.lt_u (local.get $i) (local.get $times))))
//       (local.get $r)))
//
// TWO ARMS, AND THE FIRST ONE IS WHAT KEEPS THE SECOND FROM BEING VACUOUS:
//
//   control  the probe WITHOUT importing node-host's loader. It MUST die by SIGSEGV on the
//            engine under test. If it does not, this engine does not have the defect (node
//            24.14.1 does not, measured) and a green treatment arm would prove nothing, so the
//            test says NOT MEASURABLE and exits 77 rather than passing.
//   loader   the same probe after `import '…/node-host/src/loader.ts'`, which is what every
//            avm.wasm instantiation in this repository goes through. It must exit 0.
//
// Run it against the affected engine:
//   NODE_UNDER_TEST=/nix/store/…-nodejs-22.23.2/bin/node node verification/test_wasi_fast_call_gc_is_not_a_sigsegv.mjs
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const nodeUnderTest = process.env.NODE_UNDER_TEST ?? process.execPath;
const loaderUrl = pathToFileURL(join(root, 'node-host/src/loader.ts')).href;

const WASM_B64 = 'AGFzbQEAAAABEwNgBH9/f38Bf2AAAGADf39/AX8CIwEWd2FzaV9zbmFwc2hvdF9wcmV2aWV3MQhmZF93cml0ZQAAAwMCAQIFBAEAgAgHGwMGbWVtb3J5AgAGX3N0YXJ0AAEFd3JpdGUAAgorAgIACyYBAn8DQCAAQQAgAUGAgIAeEAAhBCADQQFqIQMgAyACSQ0ACyAECw==';

const probe = (withLoader) => `
${withLoader ? `await import(${JSON.stringify(loaderUrl)});` : ''}
const { WASI } = await import('node:wasi');
const wasi = new WASI({ version: 'preview1', returnOnExit: true });
const mod = new WebAssembly.Module(Buffer.from(${JSON.stringify(WASM_B64)}, 'base64'));
const inst = new WebAssembly.Instance(mod, wasi.getImportObject());
wasi.start(inst);
// Tier the import call up first: the fast path is what optimised code takes.
for (let i = 0; i < 20; i++) inst.exports.write(1, 1, 10000);
const keep = [];
for (let round = 0; round < 30; round++) {
  keep.push(new Array(1e5).fill({ round }));     // something for a mark-compact to walk
  inst.exports.write(1, 2000000, 1);             // 2M iovecs: uvwasi mallocs ~32 MB
}
process.stderr.write('probe survived\\n');
`;

const dir = mkdtempSync(join(tmpdir(), 'wasi-fast-call-gc-'));
const run = (name, withLoader) => {
  const file = join(dir, `${name}.mjs`);
  writeFileSync(file, probe(withLoader));
  const r = spawnSync(nodeUnderTest, [file], {
    stdio: ['ignore', 'ignore', 'pipe'], encoding: 'utf8', timeout: 240_000,
  });
  return { status: r.status, signal: r.signal, err: r.stderr ?? '' };
};

try {
  const version = spawnSync(nodeUnderTest, ['-p', 'process.version + " V8 " + process.versions.v8'],
    { encoding: 'utf8' }).stdout.trim();
  console.log(`engine under test: ${nodeUnderTest} (${version})`);

  const control = run('control', false);
  console.log(`control (no loader): status ${control.status}, signal ${control.signal}`);
  if (control.signal !== 'SIGSEGV') {
    assert.match(control.err, /probe survived/,
      `the control neither crashed nor survived: ${control.err.slice(-400)}`);
    console.log('NOT MEASURABLE: this engine survives a GC inside the fd_write fast call, so the '
      + 'loader arm cannot tell a fix from no fix here. Run with NODE_UNDER_TEST=<node 22.23.2>.');
    process.exit(77);
  }

  const treated = run('loader', true);
  console.log(`loader arm: status ${treated.status}, signal ${treated.signal}`);
  assert.equal(treated.signal, null,
    `node-host's loader did not keep fd_write off the fast-call path: the probe was killed by `
    + `${treated.signal}`);
  assert.equal(treated.status, 0, `probe failed: ${treated.err.slice(-400)}`);
  assert.match(treated.err, /probe survived/);
  console.log('PASS: control dies by SIGSEGV, the same probe under node-host\'s loader survives');
} finally {
  rmSync(dir, { recursive: true, force: true });
}
