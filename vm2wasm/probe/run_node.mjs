// Prove the module runs on V8 (the browser engine), not just wasmtime.
import { WASI } from 'node:wasi';
import { readFile } from 'node:fs/promises';

const wasi = new WASI({ version: 'preview1', args: ['avm'], env: {}, returnOnExit: true });
const bytes = await readFile(process.argv[2]);
const module = await WebAssembly.compile(bytes);
console.error('compiled ok; V8 accepted the module (incl. try_table exception handling)');
const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
const code = wasi.start(instance);
console.error('exit code', code);
