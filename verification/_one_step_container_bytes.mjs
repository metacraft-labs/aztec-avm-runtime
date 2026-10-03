// The byte size of a ONE-step recording from a given writer module.
//
//   node verification/_one_step_container_bytes.mjs <ct_writer.wasm>
//
// A floor for "a container of substantial size" that is a property of the writer rather than a
// number someone picked. CTFS allocates in blocks and every container carries `meta.dat` and the
// stream members whatever it records, so even a recording of one step is tens of kilobytes; the
// figure moves whenever the container format does (container v5 gave small members no mapping
// block and a 516-step recording fell from over 100,000 bytes to 86,016). A recording that is not
// larger than this baseline from the SAME module recorded next to nothing, whatever its size.
//
// Prints one line: the container's length in bytes. Exits non-zero, naming the call, on any
// refusal, so a failure is never read as a small size.

import { readFileSync } from 'node:fs';

const [, , modulePath] = process.argv;
if (!modulePath) {
  console.error('usage: _one_step_container_bytes.mjs <ct_writer.wasm>');
  process.exit(2);
}
const { instance } = await WebAssembly.instantiate(readFileSync(modulePath), {});
const x = instance.exports;
const enc = new TextEncoder();
const mem = () => new Uint8Array(x.memory.buffer);
const push = (s) => {
  const b = enc.encode(s);
  const p = x.ct_alloc(b.length || 1);
  mem().set(b, p);
  return [p, b.length];
};
const lastError = () => {
  const p = x.ct_last_error_ptr();
  const n = x.ct_last_error_len();
  return n ? new TextDecoder().decode(mem().slice(p, p + n)) : '(no message)';
};
const must = (ok, what) => {
  if (!ok) {
    console.error(`${what} refused: ${lastError()}`);
    process.exit(1);
  }
};

const a = ['baseline', '01949fcc-7d92-7e9c-8000-0000000028b1', '/aztec/tx.avm', '/aztec'].map(push);
must(x.ct_writer_open(a[0][0], a[0][1], a[1][0], a[1][1], a[2][0], a[2][1], a[3][0], a[3][1], 0) === 0, 'ct_writer_open');
const [pp, pn] = push('/aztec/baseline.nr');
const id = x.ct_intern_path(pp, pn, 0, 0);
must(id >= 0, 'ct_intern_path');
must(x.ct_source_step(id, 1, 0) === 0, 'ct_source_step');
must(x.ct_writer_close() !== 0, 'ct_writer_close');
console.log(x.ct_container_len());
