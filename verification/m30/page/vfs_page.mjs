// vfs_page.mjs — the M30 page: a tree of Noir sources held in the browser, compiled and
// traced in-page.
//
// It installs `globalThis.vfsDemo` and sets `globalThis.vfsDemoReady`. `tools/run_vfs_arms.mjs`
// drives it through CDP; nothing here knows that, so the page a human opens and the page a
// check drives are the same page.
//
// ==========================================================================================
// THE RESOLVER DECIDES WHAT IS COMPILED **AND** WHAT IS TRACED.
// ==========================================================================================
//
// Two modules are loaded: `noir_wasm.wasm`, whose `nv_compile_vfs` reads `Nargo.toml` out of
// the virtual filesystem and answers with a PLAN plus a compiled artifact; and
// `noir_tracer_wasm.wasm`, whose `ct_trace_source_container` compiles and traces a set of
// source files and hands back a real `.ct`.
//
// The tracer is handed `plan.sources` and `plan.entry_point` — the resolver's answer — and
// nothing else. It is NOT handed the page's whole tree. That is the join between the two
// halves, and the arms below make it falsifiable rather than structural: editing a file the
// plan names changes both the artifact and the container, and editing a `.nr` file that is
// in the tree and NOT in the plan changes neither.
//
// What is NOT claimed: the tracer compiles the sources it is given a second time, with the
// debug instrumenter on, so the two halves do not share a compilation. What is asserted is
// that they agree about the program's FILES and its ROOT, which is the thing the resolver
// decides.

import { instantiateBare, sha256Hex, tracer, vfsCompiler } from './wasm_host.mjs';
import { TRACE_INPUTS, TRACE_RECORDING_ID, TREES, derivedExpectations } from './m30_vfs_trees.mjs';

/** How many times a wasm module has been instantiated in this page. */
let instantiations = 0;

async function fetchWasm(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`${url}: HTTP ${response.status}`);
  }
  return new Uint8Array(await response.arrayBuffer());
}

function toHex(bytes) {
  return Array.from(bytes.subarray(0, 8))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

async function boot() {
  const compilerBytes = await fetchWasm('./assets/noir_wasm.wasm');
  const tracerBytes = await fetchWasm('./assets/noir_tracer_wasm.wasm');

  const compilerHost = await instantiateBare(compilerBytes, 'noir_wasm');
  instantiations += 1;
  const tracerHost = await instantiateBare(tracerBytes, 'noir_tracer_wasm');
  instantiations += 1;

  const compiler = vfsCompiler(compilerHost);
  const trace = tracer(tracerHost);

  const modules = {
    compiler: {
      bytes: compilerBytes.length,
      sha256: await sha256Hex(compilerBytes),
      declaredImports: compilerHost.declaredImports.length,
      // The MODULE names of every declared import, deduplicated. A `wasm32-unknown-unknown`
      // module can only touch a file or a socket through an import, so this list is what
      // makes "it did not fetch" a property of the artefact rather than of the source.
      declaredImportModules: [...new Set(compilerHost.declaredImports.map((i) => i.split('.')[0]))].sort(),
      exportsNv: Object.keys(compilerHost.exports).filter((n) => n.startsWith('nv_')).sort(),
    },
    tracer: {
      bytes: tracerBytes.length,
      sha256: await sha256Hex(tracerBytes),
      declaredImports: tracerHost.declaredImports.length,
      declaredImportModules: [...new Set(tracerHost.declaredImports.map((i) => i.split('.')[0]))].sort(),
      exportsCt: Object.keys(tracerHost.exports).filter((n) => n.startsWith('ct_')).sort(),
    },
  };

  function compileTree(name, mode = 'program') {
    const tree = TREES[name];
    if (!tree) {
      throw new Error(`vfsDemo: no tree named ${name}`);
    }
    const started = performance.now();
    const response = compiler.run({ files: tree.files, package_dir: tree.packageDir, mode });
    return {
      name,
      mode,
      ms: Math.round(performance.now() - started),
      // The whole envelope, minus the artifact's bulk: an artifact is hundreds of kilobytes
      // and a check reads its shape, not its bytes.
      ok: response.ok,
      stage: response.stage ?? null,
      kind: response.kind ?? null,
      message: response.message ?? null,
      manifest: response.manifest ?? null,
      line: response.line ?? null,
      column: response.column ?? null,
      // A boolean beside the value, because a JSON `null` and a missing key read the same
      // way through a dotted-path reader and "there is no plan" is a thing a check asserts.
      planPresent: response.plan !== undefined && response.plan !== null,
      plan: response.plan ?? null,
      diagnostics: response.diagnostics ?? [],
      warnings: response.warnings ?? [],
      artifact: response.artifact
        ? {
            present: true,
            keys: Object.keys(response.artifact).sort(),
            bytecodeLength: response.artifact.bytecode?.length ?? 0,
            bytecode: response.artifact.bytecode ?? null,
            hash: response.artifact.hash ?? null,
            abiParameters: (response.artifact.abi?.parameters ?? []).map((p) => p.name),
            fileMapPaths: Object.values(response.artifact.file_map ?? {})
              .map((f) => f.path)
              .sort(),
            debugSymbolsLength: response.artifact.debug_symbols?.length ?? 0,
          }
        : { present: false },
      // The tree the page actually held, so a check can say the decoys were present.
      treePaths: Object.keys(tree.files).sort(),
    };
  }

  /**
   * Compile a tree AND trace the program the plan describes, in one turn.
   *
   * The tracer is given `plan.sources` — reduced to the `path -> source` map the tree holds
   * — and `plan.entry_point`. Nothing else crosses.
   */
  function compileAndTrace(name) {
    const compiled = compileTree(name);
    if (!compiled.ok) {
      return { ...compiled, traced: null };
    }
    const tree = TREES[name];
    const files = {};
    for (const path of compiled.plan.sources) {
      files[path] = tree.files[path];
    }
    const started = performance.now();
    const result = trace.traceToContainer({
      files,
      entry_point: compiled.plan.entry_point,
      inputs: TRACE_INPUTS,
      inputs_are_json: false,
      package: compiled.plan.packages[0].name,
      recording_id: TRACE_RECORDING_ID,
    });
    return {
      ...compiled,
      traced: {
        ms: Math.round(performance.now() - started),
        // What the tracer was handed, so a check can compare it with the plan rather than
        // trust the sentence above.
        handedFiles: Object.keys(files).sort(),
        handedEntryPoint: compiled.plan.entry_point,
        containerBytes: result.ct.length,
        containerSha256Promise: sha256Hex(result.ct),
        containerHead: toHex(result.ct),
        columnAware: result.container.column_aware,
        droppedColumnAwareness: result.container.dropped_column_awareness,
        recordingId: result.container.recording_id,
        events: result.trace.events?.length ?? 0,
        paths: (result.trace.paths ?? []).slice().sort(),
      },
    };
  }

  async function settle(arm) {
    if (arm.traced) {
      arm.traced.containerSha256 = await arm.traced.containerSha256Promise;
      delete arm.traced.containerSha256Promise;
    }
    return arm;
  }

  globalThis.vfsDemo = {
    modules,
    expectations: derivedExpectations(),

    /** Resolve or compile one named tree. */
    compile(name, mode) {
      return compileTree(name, mode);
    },

    /** The imports either module has CALLED so far. Empty is the interesting answer. */
    reachedImports() {
      return {
        compiler: compilerHost.reachedImports.slice(),
        tracer: tracerHost.reachedImports.slice(),
        instantiations,
      };
    },

    /**
     * The whole compile side, in one page load: the multi-file tree, its two edits, and
     * the four controls.
     */
    compileArms() {
      const arms = {};
      for (const name of [
        'multifile',
        'multifileDependencyEdited',
        'multifileDecoyAdded',
        'multifileDecoyAddedUnderSrc',
        'declaredEntry',
        'declaredEntryMissing',
        'missingDependencyManifest',
        'missingDependencySource',
        'missingLocalModule',
        'typeErrorInDependency',
        'typeErrorInDependencyMoved',
        'gitDependency',
        'gitDependencyMoved',
        'gitDependencyNoTag',
      ]) {
        arms[name] = compileTree(name);
      }
      // The plan alone, with no compile, so `resolve` is exercised in its own right.
      arms.multifileResolveOnly = compileTree('multifile', 'resolve');
      return arms;
    },

    /**
     * EDIT, RECOMPILE, RE-TRACE — five passes, ONE page load, ONE module instantiation.
     *
     * A  the tree as authored
     * B  `src/util.nr` edited: `x * 2` -> `x * 3`
     * A2 the edit reverted — must reproduce A byte for byte
     * D  a `.nr` file ADDED outside `src/` — must also reproduce A byte for byte
     * E  `src/util.nr` edited to something that does not compile — must be refused with a
     *    position and produce no container, and A3 after it must still reproduce A
     */
    async traceArms() {
      const a = await settle(compileAndTrace('traceA'));
      const b = await settle(compileAndTrace('traceB'));
      const a2 = await settle(compileAndTrace('traceA'));
      const d = await settle(compileAndTrace('traceDecoyAdded'));
      const e = await settle(compileAndTrace('traceBroken'));
      const a3 = await settle(compileAndTrace('traceA'));
      return {
        a,
        b,
        a2,
        d,
        e,
        a3,
        instantiations,
        reachedImports: {
          compiler: compilerHost.reachedImports.slice(),
          tracer: tracerHost.reachedImports.slice(),
        },
      };
    },
  };

  globalThis.vfsDemoReady = true;
  const status = document.getElementById('status');
  if (status) {
    status.textContent = `ready — compiler ${modules.compiler.bytes} B, tracer ${modules.tracer.bytes} B`;
  }
}

boot().catch((err) => {
  globalThis.vfsDemoError = String(err && err.stack ? err.stack : err);
  const status = document.getElementById('status');
  if (status) {
    status.textContent = `failed: ${err}`;
  }
});
