// join_stages.mjs — the four stages, as ONE module that runs unchanged in Node and in a page.
//
// This file exists because the campaign's four capabilities have each been demonstrated in
// isolation and never against each other. Every stage here takes the PREVIOUS stage's output as
// its literal input — no re-fetch, no re-derivation from a fixture, no "an equivalent artifact
// compiled natively". A stage that reconstructed its own input would make the join unfalsifiable,
// which is the whole thing this file is built to avoid.
//
//   COMPILE    noir_wasm.wasm        VFS  ->  ContractArtifact
//   TRANSPILE  avm_transpiler_wasm   that artifact  ->  transpiled artifact
//   EXECUTE    (runtime)             that transpiled artifact  ->  a run
//   TRACE      (writer)              that run  ->  a container
//
// HOST-AGNOSTIC ON PURPOSE. `wasm_host.mjs` is handed BYTES; where the bytes came from is the
// caller's business. So the Node probe and the browser arm execute the same lines, and a browser
// result cannot differ from a Node result because the harness differed.

import { instantiateBare, vfsCompiler } from '../m30/page/wasm_host.mjs';

/** Base64 -> byte length, without materialising the bytes. */
export function base64Bytes(b64) {
  if (!b64) return 0;
  let n = Math.floor((b64.length * 3) / 4);
  if (b64.endsWith('==')) n -= 2;
  else if (b64.endsWith('=')) n -= 1;
  return n;
}

/**
 * STAGE 1a — COMPILE. A package tree in memory becomes a contract artifact.
 *
 * `mode` is the caller's: `contract` for the public loop, `contract-debug` when the artifact has
 * to be steppable later. Those are two different modules' worth of capability and the caller says
 * which it wants rather than this function guessing.
 */
export async function compileContract(compilerBytes, { files, packageDir, mode }) {
  const host = await instantiateBare(compilerBytes, 'noir_wasm');
  const started = Date.now();
  const response = vfsCompiler(host).run({ files, package_dir: packageDir, mode });
  const ms = Date.now() - started;

  if (!response.ok) {
    const where = [response.stage, response.kind].filter(Boolean).join('/');
    throw new Error(`compile refused (${where}): ${response.message}`);
  }
  const artifact = response.artifact;
  if (!artifact) throw new Error('the compile reported ok and produced no artifact');

  const functions = artifact.functions ?? [];
  return {
    artifact,
    ms,
    reachedImports: host.reachedImports,
    declaredImports: host.declaredImports.length,
    // Measured off the artifact, never off the request.
    name: artifact.name,
    functionCount: functions.length,
    bytecodeBytes: functions.reduce((n, f) => n + base64Bytes(f.bytecode), 0),
    debugSymbolBytes: functions.reduce((n, f) => n + base64Bytes(f.debug_symbols), 0),
    publicFunctions: functions.filter((f) =>
      (f.custom_attributes ?? []).includes('public')).length,
    fileMapEntries: Object.keys(artifact.file_map ?? {}).length,
  };
}

/**
 * STAGE 1b — TRANSPILE. THE JOIN THIS FILE EXISTS FOR.
 *
 * `artifact` is the OBJECT stage 1a returned. It is serialised here and nowhere else, so the
 * bytes the transpiler reads are a function of what the compiler produced and of nothing else.
 * Passing a path, a fixture name or a re-read file would each let a native artifact stand in for
 * a browser one without the harness being able to tell.
 */
export async function transpileContract(transpilerBytes, artifact) {
  const host = await instantiateBare(transpilerBytes, 'avm_transpiler_wasm');
  const json = JSON.stringify(artifact);
  const started = Date.now();

  const encoded = new TextEncoder().encode(json);
  const inPtr = host.exports.avmt_alloc(encoded.length);
  new Uint8Array(host.exports.memory.buffer, inPtr, encoded.length).set(encoded);
  const outPtr = host.exports.avmt_transpile(inPtr, encoded.length);
  const ok = host.exports.avmt_ok();
  const len = host.exports.avmt_result_len();
  const bytes = new Uint8Array(host.exports.memory.buffer, outPtr, len).slice();
  host.exports.avmt_free(outPtr, len);
  host.exports.avmt_free(inPtr, encoded.length);
  const ms = Date.now() - started;

  const text = new TextDecoder().decode(bytes);
  // `ok` is THREE-valued and the -1 is load-bearing: a host that read `avmt_ok` without calling
  // `avmt_transpile` would otherwise see a 0 and report "the transpiler refused it", which is a
  // different and much more alarming sentence than "nothing was transpiled".
  if (ok === -1) throw new Error('avmt_ok() is -1: avmt_transpile was never called');
  if (ok !== 1) throw new Error(`the transpiler REFUSED the artifact: ${text.slice(0, 400)}`);

  const transpiled = JSON.parse(text);
  const functions = transpiled.functions ?? [];
  // An AVM function is one the transpiler rewrote; upstream marks them by name in
  // `custom_attributes`. Counting them is how "it transpiled something" is distinguished from
  // "it echoed the artifact back", which a passthrough would otherwise satisfy.
  const avmFunctions = functions.filter((f) =>
    (f.custom_attributes ?? []).some((a) => String(a).toLowerCase().includes('public')));

  return {
    transpiled,
    ms,
    inputBytes: encoded.length,
    outputBytes: bytes.length,
    reachedImports: host.reachedImports,
    declaredImports: host.declaredImports.length,
    functionCount: functions.length,
    avmFunctionCount: avmFunctions.length,
    bytecodeBytes: functions.reduce((n, f) => n + base64Bytes(f.bytecode), 0),
  };
}

/**
 * The property that makes the join CHECKABLE rather than merely sequential.
 *
 * A transpiled artifact is the compiled one with the public functions' bytecode REPLACED by AVM
 * bytecode. So: the function lists must correspond one-for-one by name, and at least one
 * function's bytecode must have CHANGED. Both halves are needed and they fail differently —
 * a passthrough keeps every name and changes nothing; a transpiler fed the wrong artifact
 * changes bytes and loses the names.
 */
export function joinEvidence(compiled, transpiled) {
  const before = new Map((compiled.artifact.functions ?? []).map((f) => [f.name, f.bytecode]));
  const after = new Map((transpiled.transpiled.functions ?? []).map((f) => [f.name, f.bytecode]));

  const namesBefore = [...before.keys()].sort();
  const namesAfter = [...after.keys()].sort();
  const changed = [];
  const identical = [];
  for (const name of namesBefore) {
    if (!after.has(name)) continue;
    if (after.get(name) === before.get(name)) identical.push(name);
    else changed.push(name);
  }
  return {
    namesMatch: JSON.stringify(namesBefore) === JSON.stringify(namesAfter),
    functionsBefore: namesBefore.length,
    functionsAfter: namesAfter.length,
    changedFunctions: changed.sort(),
    identicalFunctions: identical.sort(),
  };
}
