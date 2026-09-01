// page.mjs — compile an Aztec contract in this tab, against the DEPLOYED compiler.
//
// ==========================================================================================
// WHAT THIS PAGE IS, AND WHAT IT DELIBERATELY IS NOT.
// ==========================================================================================
//
// It is not a test of a module this repository built. The `.wasm` it drives is fetched by URL
// from `https://ide.codetracer.com/assets/noir_wasm.wasm` — the artifact the product serves —
// and the page asserts its byte count before instantiating it, so "the deployed compiler" is a
// measurement rather than a label on a local file. Every import the module DECLARES is
// satisfied with a function that records the call and throws, so "the compile happened inside
// WebAssembly" is the empty `reachedImports` list rather than a claim about a build flag.
// (`wasm_host.mjs`, shared with M30's page, is where that shim lives.)
//
// THE THREE ARMS ARE THE POINT, AND THE ORDER IS THE ARGUMENT.
//
//   before   a `type = "contract"` package with NO aztec-nr in the tree. The compiler
//            RECOGNISES it and refuses with a positioned diagnostic:
//            `Attribute function 'public' is not in scope`. So the contract path works and
//            the library is what is missing.
//   refused  the vendored tree with ONE manifest put back the way upstream wrote it — the
//            aztec-nr manifest that declares `poseidon` and `sha256` as `git` dependencies.
//            `kind: "git-dependency-refused"`. This is the arm that makes the third one mean
//            something: without it, a green compile is equally consistent with the git
//            rewrite having been unnecessary.
//   after    the vendored tree, every dependency a `path`. A contract artifact.
//
// Two of the three arms are FAILURES, on purpose. A page that only shows the success has not
// shown that the vendoring is what produced it.

import { instantiateBare, vfsCompiler, sha256Hex } from './wasm_host.mjs';

const out = document.getElementById('out');
const status = document.getElementById('status');
const say = (s) => {
  out.textContent += s + '\n';
};

// The tree with NO aztec-nr at all: the state the brief describes as "the contract path works;
// only the library is missing". Held inline rather than fetched so this arm cannot be affected
// by what the vendoring step produced.
const BARE_CONTRACT = {
  'c/Nargo.toml': '[package]\nname = "c"\ntype = "contract"\nauthors = [""]\n\n[dependencies]\n',
  'c/src/main.nr': 'contract C {\n    #[public]\n    fn f() {}\n}\n',
};

async function run() {
  const result = {
    module: {},
    arms: {},
    startedAt: new Date().toISOString(),
  };

  status.textContent = 'fetching the deployed compiler…';
  const moduleUrl = window.__MODULE_URL__;
  const response = await fetch(moduleUrl);
  if (!response.ok) throw new Error(`${moduleUrl} answered ${response.status}`);
  const wasmBytes = new Uint8Array(await response.arrayBuffer());
  result.module = {
    url: moduleUrl,
    bytes: wasmBytes.length,
    sha256: await sha256Hex(wasmBytes),
    contentType: response.headers.get('content-type'),
  };
  say(`module ${result.module.url}`);
  say(`       ${result.module.bytes} bytes, sha256 ${result.module.sha256}`);

  status.textContent = 'instantiating…';
  const host = await instantiateBare(wasmBytes, 'noir_wasm');
  const compiler = vfsCompiler(host);
  result.module.declaredImports = host.declaredImports.length;

  const arm = (name, request) => {
    const before = host.reachedImports.length;
    const t0 = performance.now();
    const res = compiler.run(request);
    const ms = Math.round(performance.now() - t0);
    const record = {
      ok: res.ok,
      ms,
      stage: res.stage ?? null,
      kind: res.kind ?? null,
      message: res.message ?? null,
      manifest: res.manifest ?? null,
      line: res.line ?? null,
      column: res.column ?? null,
      importsReachedByThisArm: host.reachedImports.length - before,
      files: Object.keys(request.files).length,
    };
    if (res.plan) {
      record.plan = {
        packages: res.plan.packages.length,
        packageNames: res.plan.packages.map((p) => p.name).sort(),
        sources: res.plan.sources.length,
        package_type: res.plan.package_type,
        entry_point: res.plan.entry_point,
      };
    }
    if (res.diagnostics && res.diagnostics.length) {
      record.diagnostics = res.diagnostics.map((d) => ({
        message: d.message,
        file: d.file,
        line: d.line,
        column: d.column,
        severity: d.severity,
      }));
    }
    if (res.artifact) {
      const a = res.artifact;
      const json = JSON.stringify(a);
      record.artifact = {
        name: a.name,
        noir_version: a.noir_version,
        jsonBytes: new TextEncoder().encode(json).length,
        fileMapEntries: Object.keys(a.file_map ?? {}).length,
        functions: (a.functions ?? []).length,
        functionNames: (a.functions ?? []).map((f) => f.name).sort(),
        // The bytecode is base64 in the artifact; its DECODED length is what a deployer ships.
        bytecodeBytes: (a.functions ?? []).reduce(
          (n, f) => n + Math.floor(((f.bytecode ?? '').length * 3) / 4),
          0,
        ),
        abiParameters: (a.functions ?? []).reduce((n, f) => n + (f.abi?.parameters?.length ?? 0), 0),
        publicFunctions: (a.functions ?? []).filter((f) =>
          (f.custom_attributes ?? []).includes('abi_public'),
        ).length,
        privateFunctions: (a.functions ?? []).filter((f) =>
          (f.custom_attributes ?? []).includes('abi_private'),
        ).length,
        unconstrained: (a.functions ?? []).filter((f) => f.is_unconstrained).length,
      };
      record.warnings = (res.warnings ?? []).length;
    }
    result.arms[name] = record;
    say(
      `arm ${name}: ok=${record.ok} kind=${record.kind ?? '-'} ${ms} ms` +
        (record.artifact ? ` -> "${record.artifact.name}" ${record.artifact.functions} functions` : ''),
    );
    return record;
  };

  // ---- arm "before": the contract path without the library -------------------------------
  status.textContent = 'arm 1/3 — a contract with no aztec-nr…';
  arm('before', { files: BARE_CONTRACT, package_dir: 'c', mode: 'contract' });

  // ---- the vendored tree -----------------------------------------------------------------
  status.textContent = 'fetching the vendored tree…';
  const vfsResponse = await fetch(window.__VFS_URL__);
  const vfsText = await vfsResponse.text();
  const files = JSON.parse(vfsText);
  result.vfs = {
    url: window.__VFS_URL__,
    files: Object.keys(files).length,
    jsonBytes: new TextEncoder().encode(vfsText).length,
    sourceBytes: Object.values(files).reduce((n, s) => n + new TextEncoder().encode(s).length, 0),
    transferBytes: Number(vfsResponse.headers.get('content-length') ?? -1),
  };
  say(`vfs    ${result.vfs.files} files, ${result.vfs.sourceBytes} source bytes`);

  // ---- arm "refused": one manifest put back the way upstream wrote it ---------------------
  status.textContent = 'arm 2/3 — the same tree with the git dependency restored…';
  const withGit = { ...files };
  const gitManifestPath = window.__GIT_MANIFEST_PATH__;
  if (!(gitManifestPath in withGit)) throw new Error(`${gitManifestPath} is not in the tree`);
  withGit[gitManifestPath] = window.__GIT_MANIFEST_TEXT__;
  arm('refused', { files: withGit, package_dir: window.__PACKAGE_DIR__, mode: 'contract' });

  // ---- arm "after": the vendored tree ----------------------------------------------------
  status.textContent = 'arm 3/3 — the vendored tree…';
  arm('after', { files, package_dir: window.__PACKAGE_DIR__, mode: 'contract' });

  // The module-wide record: over ALL THREE arms, nothing was asked of JavaScript.
  result.module.reachedImports = host.reachedImports;

  result.finishedAt = new Date().toISOString();
  window.__RESULT__ = result;
  status.textContent = 'done';
  say('');
  say(JSON.stringify(result, null, 2));
  return result;
}

window.__RUN__ = run().catch((err) => {
  status.textContent = 'FAILED';
  say(`FAILED: ${err && err.stack ? err.stack : err}`);
  window.__RESULT__ = { failed: String(err) };
  throw err;
});
