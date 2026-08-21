// Run a wasm32-wasi command module under Node's WASI, forwarding argv.
// Usage: node run_wasm.mjs <module.wasm> [args...]
import { WASI } from 'node:wasi';
import { readFile } from 'node:fs/promises';

const [, , modulePath, ...rest] = process.argv;
const wasi = new WASI({
  version: 'preview1',
  args: [modulePath, ...rest],
  env: {},
  returnOnExit: true,
});
const module = await WebAssembly.compile(await readFile(modulePath));
const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
process.exitCode = wasi.start(instance);
