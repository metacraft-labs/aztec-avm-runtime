// Pair each writer module with each declared writer path and report what the host does.
//
//   node --experimental-strip-types verification/_writer_kind_probe.mjs \
//       <ct-host src/index.ts> <path-a module.wasm> <path-b module.wasm>
//
// The host is a PARAMETER so the mutation arm of `verify_declared_writer_path_matches_module` can
// point the same probe at a copy of `ct-host/src` with the comparison disabled. One probe for the
// subject and the mutant, so a difference between the two runs is the host's and cannot be the
// probe's.
//
// Every pair gets a FRESH instance. The module holds one global session, and an instance that a
// previous pair had opened would make the next pair's outcome depend on the order they ran in.
//
// Output, one tab-separated line per fact:
//
//   KIND     <module label> <ct_writer_kind() read straight off the module>
//   ALLOWED  <module label> <declared path> <events> <writerKind at close> <writerPath recorded>
//   REFUSED  <module label> <declared path> <error name> <declaredPath> <reportedKind> <message>
//   REUSE    <module label> <declared path> <ALLOWED events | REFUSED name>

import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const [, , hostIndex, modulePathA, modulePathB] = process.argv;
if (!hostIndex || !modulePathA || !modulePathB) {
  console.error('usage: _writer_kind_probe.mjs <ct-host index.ts> <path-a.wasm> <path-b.wasm>');
  process.exit(2);
}

const h = await import(pathToFileURL(hostIndex).href);
const modules = [
  ['path-a-module', readFileSync(modulePathA)],
  ['path-b-module', readFileSync(modulePathB)],
];
const paths = [h.WRITER_PATH_A_PURE_RUST, h.WRITER_PATH_B_NIM];

const base = {
  program: 'kind-probe',
  recordingId: '01949fcc-7d92-7e9c-8000-0000000041c1',
  sourcePath: '/aztec/tx.avm',
  workdir: '/aztec',
  columns: false,
};
const addr = new Uint8Array(32);
addr[0] = 0x41;

function record(instance, path) {
  const w = new h.CtWriter(instance, h.resolveTracingConfig(base, path), { batchRecords: 4 });
  for (let i = 0; i < 7; i++) {
    w.push({ contextId: 0, pc: i, opcode: i, l2Gas: 100n, daGas: 0n, contractAddress: addr });
  }
  return w.close();
}

const oneLine = (s) => String(s).replace(/[\t\n]+/g, ' ');

for (const [label, bytes] of modules) {
  const probe = await h.instantiateCtWriter(bytes);
  console.log(['KIND', label, probe.exports.ct_writer_kind()].join('\t'));
  for (const path of paths) {
    const instance = await h.instantiateCtWriter(bytes);
    try {
      const r = record(instance, path);
      console.log(['ALLOWED', label, path, r.events, r.writerKind, r.writerPath].join('\t'));
    } catch (e) {
      console.log([
        'REFUSED', label, path, e?.name ?? 'unknown',
        e?.declaredPath ?? '-', e?.reportedKind ?? '-', oneLine(e?.message ?? e),
      ].join('\t'));
      // THE REFUSAL LEFT THE INSTANCE AS IT FOUND IT. The same instance, declared correctly, must
      // record: a refusal that had already opened a session would make this throw
      // `CT_ERR_ALREADY_OPEN`, and one that had allocated would still pass — so this proves the
      // weaker and the useful thing, that nothing was opened before the refusal.
      const right = paths.find((p) => p !== path);
      try {
        const r = record(instance, right);
        console.log(['REUSE', label, right, 'ALLOWED', r.events].join('\t'));
      } catch (e2) {
        console.log(['REUSE', label, right, 'REFUSED', e2?.name ?? 'unknown'].join('\t'));
      }
    }
  }
}
console.log('PROBEDONE');
