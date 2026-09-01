// join_node_probe.mjs — drive the compile->transpile join in Node, over the SAME stage module
// the page uses. Node first because it iterates in seconds and a browser arm does not; the
// browser arm is what the milestone is accepted on, and it runs `join_stages.mjs` unchanged.
//
// Inputs, all by environment so nothing is re-derived here:
//   JOIN_COMPILER    noir_wasm.wasm         (the contract-debug revision, 9d4e40a6)
//   JOIN_TRANSPILER  avm_transpiler_wasm.wasm
//   JOIN_VFS         the vendored package tree, `{path: source}` JSON
//   JOIN_MODE        compile mode; default `contract`
//   JOIN_OUT         where to write the transpiled artifact, so a later stage consumes THIS one

import { readFileSync, writeFileSync } from 'node:fs';
import { compileContract, transpileContract, joinEvidence } from './join_stages.mjs';

const need = (name) => {
  const v = process.env[name];
  if (!v) {
    console.error(`SKIP: ${name} is not set. This is a skip, not a pass.`);
    process.exit(2);
  }
  return v;
};

const compilerPath = need('JOIN_COMPILER');
const transpilerPath = need('JOIN_TRANSPILER');
const vfsPath = need('JOIN_VFS');
const mode = process.env.JOIN_MODE || 'contract';

const files = JSON.parse(readFileSync(vfsPath, 'utf8'));
const packageDir = process.env.JOIN_PACKAGE_DIR || 'contract';

let failures = 0;
const ok = (m) => console.log(`  [OK]     ${m}`);
const bad = (m) => { console.log(`  [FAILED] ${m}`); failures++; };

console.log(`=== the compile -> transpile join, in Node (mode=${mode}) ===`);
console.log(`  vfs: ${Object.keys(files).length} files, ${readFileSync(vfsPath).length} JSON bytes`);

// ---- stage 1a ---------------------------------------------------------------------------
const compiled = await compileContract(readFileSync(compilerPath), { files, packageDir, mode });
console.log(`  COMPILE  ${compiled.name}: ${compiled.functionCount} functions, ` +
  `${compiled.bytecodeBytes} bytecode bytes, ${compiled.ms} ms`);

if (compiled.functionCount > 0) ok(`the compile produced ${compiled.functionCount} functions`);
else bad('the compile produced NO functions');
if (compiled.bytecodeBytes > 0) ok(`and ${compiled.bytecodeBytes} bytes of bytecode`);
else bad('and ZERO bytes of bytecode — an artifact with no code in it');
if (compiled.reachedImports.length === 0) {
  ok(`the compile reached 0 of its ${compiled.declaredImports} declared wasm imports`);
} else {
  bad(`the compile reached ${compiled.reachedImports.join(', ')}`);
}

// ---- stage 1b — THE JOIN ----------------------------------------------------------------
// `compiled.artifact` is the object the compiler returned. Nothing is re-read from disk here.
const transpiled = await transpileContract(readFileSync(transpilerPath), compiled.artifact);
console.log(`  TRANSPILE in ${transpiled.inputBytes} bytes -> out ${transpiled.outputBytes}, ` +
  `${transpiled.functionCount} functions, ${transpiled.ms} ms`);

if (transpiled.reachedImports.length === 0) {
  ok(`the transpile reached 0 of its ${transpiled.declaredImports} declared wasm imports`);
} else {
  bad(`the transpile reached ${transpiled.reachedImports.join(', ')}`);
}

const evidence = joinEvidence(compiled, transpiled);
console.log(`  JOIN     names match=${evidence.namesMatch}, ` +
  `${evidence.changedFunctions.length} functions' bytecode CHANGED, ` +
  `${evidence.identicalFunctions.length} unchanged`);

if (evidence.namesMatch) {
  ok(`the transpiled artifact carries the same ${evidence.functionsAfter} function names`);
} else {
  bad(`function names diverged: ${evidence.functionsBefore} in, ${evidence.functionsAfter} out`);
}
// THE ANTI-PASSTHROUGH ASSERTION. A transpiler that returned its input unchanged would satisfy
// every check above this line: same names, same count, `ok == 1`, zero imports reached. Only a
// bytecode that MOVED distinguishes a transpile from an echo.
if (evidence.changedFunctions.length > 0) {
  ok(`and ${evidence.changedFunctions.length} of them have DIFFERENT bytecode — ` +
     `so this is a transpile and not a passthrough`);
  console.log(`           changed: ${evidence.changedFunctions.slice(0, 6).join(', ')}` +
    (evidence.changedFunctions.length > 6 ? ', ...' : ''));
} else {
  bad('NO function\'s bytecode changed — the transpiler echoed the artifact back');
}

if (process.env.JOIN_OUT) {
  writeFileSync(process.env.JOIN_OUT, JSON.stringify(transpiled.transpiled));
  console.log(`  wrote the transpiled artifact to ${process.env.JOIN_OUT}`);
}

console.log(failures === 0
  ? `\nRESULT: OK — a browser-shaped compile fed the browser transpiler, ${evidence.changedFunctions.length} functions transpiled`
  : `\nRESULT: FAILED — ${failures} check(s)`);
process.exit(failures === 0 ? 0 : 1);
