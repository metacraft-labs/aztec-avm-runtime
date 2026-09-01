// join_page.mjs — the compile -> transpile join, IN A TAB.
//
// This page is the acceptance vehicle for the milestone's first clause: a contract compiled in
// the browser, handed to the transpiler in the browser. Both halves have run in Chromium before
// and no check has ever passed one's output to the other — the transpiler has only ever been
// fed artifacts produced by a NATIVE `nargo`.
//
// It runs `join_stages.mjs` unchanged, which is the same module the Node probe drives. So a
// browser result that differed from the Node result would be a fact about the browser and not
// about the harness.
//
// FOUR ARMS, and three of them exist to make the first one falsifiable:
//
//   join          the real thing: compile, then transpile the object the compile returned
//   passthrough   a transpiler that echoes its input. Every name still matches, `ok` is still
//                 1, zero imports are still reached — ONLY the changed-bytecode assertion goes
//                 red. That is the arm for "a chain of agreements is not a result".
//   corrupt       the artifact is damaged between the two stages. The transpiler must REFUSE it
//                 by name rather than return something plausible.
//   wrongMode     compiled as a `program` rather than a `contract`. A program artifact has no
//                 `functions[]` at all, so the transpiler has nothing to work on — this is the
//                 arm that shows the compile MODE reaches the join, rather than any artifact
//                 doing.

import { compileContract, transpileContract, joinEvidence } from './join_stages.mjs';

const fetchBytes = async (url) => new Uint8Array(await (await fetch(url)).arrayBuffer());

async function run() {
  const compilerBytes = await fetchBytes(window.__COMPILER_URL__);
  const transpilerBytes = await fetchBytes(window.__TRANSPILER_URL__);
  const files = await (await fetch(window.__VFS_URL__)).json();
  const packageDir = window.__PACKAGE_DIR__;
  const mode = window.__MODE__ || 'contract';

  const result = {
    modules: {
      compilerBytes: compilerBytes.length,
      transpilerBytes: transpilerBytes.length,
    },
    vfsFiles: Object.keys(files).length,
    mode,
  };

  // ---- arm: join ------------------------------------------------------------------------
  const compiled = await compileContract(compilerBytes, { files, packageDir, mode });
  result.compile = {
    name: compiled.name,
    functionCount: compiled.functionCount,
    bytecodeBytes: compiled.bytecodeBytes,
    debugSymbolBytes: compiled.debugSymbolBytes,
    fileMapEntries: compiled.fileMapEntries,
    ms: compiled.ms,
    reachedImports: compiled.reachedImports,
    declaredImports: compiled.declaredImports,
  };

  const transpiled = await transpileContract(transpilerBytes, compiled.artifact);
  result.transpile = {
    inputBytes: transpiled.inputBytes,
    outputBytes: transpiled.outputBytes,
    functionCount: transpiled.functionCount,
    bytecodeBytes: transpiled.bytecodeBytes,
    ms: transpiled.ms,
    reachedImports: transpiled.reachedImports,
    declaredImports: transpiled.declaredImports,
  };
  result.join = joinEvidence(compiled, transpiled);

  // The transpiled artifact travels back to the harness as base64, so a later stage consumes
  // THE BYTES THE PAGE PRODUCED rather than a second transpile of the same input.
  const outJson = JSON.stringify(transpiled.transpiled);
  const outBytes = new TextEncoder().encode(outJson);
  let binary = '';
  for (let i = 0; i < outBytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, outBytes.subarray(i, i + 0x8000));
  }
  result.transpiledBase64 = btoa(binary);
  result.transpiledSha256 = Array.from(new Uint8Array(
    await crypto.subtle.digest('SHA-256', outBytes)))
    .map((b) => b.toString(16).padStart(2, '0')).join('');

  // ---- arm: passthrough -----------------------------------------------------------------
  // Not a different transpiler module — the SAME artifact, joined against ITSELF. That is
  // exactly what a module that returned its input would produce, and it isolates the one
  // assertion that can tell them apart.
  result.passthrough = joinEvidence(compiled, { transpiled: compiled.artifact });

  // ---- arm: corrupt ---------------------------------------------------------------------
  // One public function's bytecode is replaced by base64 that decodes to nothing a Program can
  // be read out of. The transpiler must say so.
  const damaged = JSON.parse(JSON.stringify(compiled.artifact));
  const victim = (damaged.functions ?? []).find((f) =>
    (f.custom_attributes ?? []).includes('public')) ?? damaged.functions[0];
  if (victim) victim.bytecode = btoa('not a program');
  try {
    await transpileContract(transpilerBytes, damaged);
    result.corrupt = { refused: false, message: 'the transpiler ACCEPTED a damaged artifact' };
  } catch (e) {
    result.corrupt = { refused: true, message: String(e.message).slice(0, 300) };
  }

  // ---- arm: wrongMode -------------------------------------------------------------------
  try {
    const asProgram = await compileContract(compilerBytes, { files, packageDir, mode: 'program' });
    result.wrongMode = {
      compiled: true,
      functionCount: asProgram.functionCount,
      hasFunctions: Array.isArray(asProgram.artifact.functions),
    };
  } catch (e) {
    // A contract crate has no `main`, so `program` is expected to REFUSE. Either way the arm
    // records what happened; the check below asserts it did not silently produce a contract.
    result.wrongMode = { compiled: false, message: String(e.message).slice(0, 300) };
  }

  return result;
}

window.__RUN__ = run().then((r) => { window.__RESULT__ = r; return 'ok'; })
  .catch((e) => {
    window.__RESULT__ = { fatal: String((e && e.stack) || e) };
    throw e;
  });
