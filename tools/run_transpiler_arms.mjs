// The M31 transpiler arms, measured ONCE and shared by every check.
//
//   M31_MODULE=… M31_NATIVE=… M31_ARTIFACTS=… M31_CHROMIUM=… node tools/run_transpiler_arms.mjs <work-dir>
//
// M20's convention, kept by M22 through M30: several checks each launching their own browser to
// derive the same numbers is how two checks come to disagree about something nothing changed.
//
// ==========================================================================================
// FOUR ARMS, AND WHY EACH IS SEPARATE.
// ==========================================================================================
//
//   native    the upstream `avm-transpiler` BINARY run over every fixture, through its own
//             file-path entry point. This is the reference the identity claim is against, and
//             it is a separate process reading and writing real files — not a second call into
//             the same library, which would make "identical" a statement about one code path.
//   node      the wasm module driven from Node with every declared import satisfied by a
//             recorder that throws. It exists so the browser arm's result is not the only
//             reading: M30's review re-derived its zero in a third host for exactly this
//             reason.
//   browser   the same module, in Chromium, fetched over HTTP by a page with no bundler and no
//             generated glue. This is the arm the milestone is actually about.
//   rung      the debug map of the BROWSER'S output resolved to `(path, line, column)` through
//             `ct-host/src/source_map.ts` — M25's own resolver, unchanged — with three
//             controls, one of them produced by the transpiler itself.
//
// ==========================================================================================
// THE INPUT DIGEST IS TAKEN AT BOTH ENDS.
// ==========================================================================================
//
// M30's review found `x.sha256 === x.servedSha256` green over two digests of one file, taken by
// one process. Here the page hashes the bytes it FETCHED and this runner hashes the file on
// disk, and the two are reported separately so a check can compare values that were produced
// independently.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync,
} from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { inflateRawSync, inflateSync } from 'node:zlib';

import { CdpConnection, launchChromium, openPage, serveDirectory } from './browser_cdp.mjs';
import { ContractSourceMap, rungFor } from '../ct-host/src/source_map.ts';

const REPO = path.resolve(import.meta.dirname, '..');
const WORK = process.argv[2] ?? path.join(process.env.HOME, '.cache', 'aztec-m31-arms');
mkdirSync(WORK, { recursive: true });

function fail(message) {
  process.stderr.write(`run_transpiler_arms: ${message}\n`);
  process.exit(2);
}

const sha = (buf) => createHash('sha256').update(buf).digest('hex');
const shaFile = (file) => sha(readFileSync(file));

const MODULE = process.env.M31_MODULE;
if (!MODULE || !existsSync(MODULE)) {
  fail(`M31_MODULE is not set to an existing module (${MODULE}). Remedy: verification/build_avm_transpiler_wasm.sh`);
}
const NATIVE = process.env.M31_NATIVE;
if (!NATIVE || !existsSync(NATIVE)) {
  fail(`M31_NATIVE is not set to an existing binary (${NATIVE}). Remedy: verification/build_avm_transpiler_wasm.sh`);
}
const ARTIFACTS = process.env.M31_ARTIFACTS;
if (!ARTIFACTS || !existsSync(ARTIFACTS)) {
  fail(`M31_ARTIFACTS is not set to an existing directory (${ARTIFACTS})`);
}
const CHROMIUM = process.env.M31_CHROMIUM ?? '/usr/bin/chromium';
if (!existsSync(CHROMIUM)) fail(`no chromium at ${CHROMIUM}`);

const PAGE_DIR = path.join(REPO, 'verification/m31/page');
if (!existsSync(path.join(PAGE_DIR, 'index.html'))) fail(`no page at ${PAGE_DIR}`);
// REUSED FROM M30, UNCHANGED AND UNCOPIED IN THE REPOSITORY. It is copied into the served site
// at run time, and its digest is reported, so a check can say WHICH host module the page ran.
const HOST_MJS = path.join(REPO, 'verification/m30/page/wasm_host.mjs');
if (!existsSync(HOST_MJS)) fail(`no wasm host at ${HOST_MJS} (M30's, reused)`);

const fixtures = readdirSync(ARTIFACTS)
  .filter((f) => f.endsWith('.json'))
  .map((f) => f.replace(/\.json$/, ''))
  .sort();
if (fixtures.length === 0) fail(`no artifacts in ${ARTIFACTS}`);

// ------------------------------------------------------------------------------------------
// ARM 1 — the native binary, over real files, as a separate process.
// ------------------------------------------------------------------------------------------
const nativeDir = path.join(WORK, 'native');
rmSync(nativeDir, { recursive: true, force: true });
mkdirSync(nativeDir, { recursive: true });

const nativeArm = {};
for (const name of fixtures) {
  const input = path.join(ARTIFACTS, `${name}.json`);
  const output = path.join(nativeDir, `${name}.out.json`);
  const t0 = process.hrtime.bigint();
  let status = 'ok';
  try {
    execFileSync(NATIVE, [input, output], { stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (err) {
    status = `failed: ${String(err.message).slice(0, 200)}`;
  }
  const t1 = process.hrtime.bigint();
  nativeArm[name] = {
    status,
    inputSha256: shaFile(input),
    inputBytes: statSync(input).size,
    outputExists: existsSync(output),
    outputBytes: existsSync(output) ? statSync(output).size : 0,
    outputSha256: existsSync(output) ? shaFile(output) : null,
    ms: Number(t1 - t0) / 1e6,
  };
}

// ------------------------------------------------------------------------------------------
// ARM 2 — the same module in Node, with every import a throwing recorder.
// ------------------------------------------------------------------------------------------
async function nodeArm() {
  const bytes = readFileSync(MODULE);
  const mod = await WebAssembly.compile(bytes);
  const declared = WebAssembly.Module.imports(mod).map(({ module: m, name }) => `${m}.${name}`);
  const reached = [];
  const importObject = {};
  for (const { module: m, name } of WebAssembly.Module.imports(mod)) {
    importObject[m] ??= {};
    importObject[m][name] = () => {
      reached.push(`${m}.${name}`);
      throw new Error(`the module reached ${m}.${name}`);
    };
  }
  const { exports } = await WebAssembly.instantiate(mod, importObject);
  const view = (ptr, len) => new Uint8Array(exports.memory.buffer, ptr, len);

  const results = {};
  for (const name of fixtures) {
    const input = readFileSync(path.join(ARTIFACTS, `${name}.json`));
    const inPtr = exports.avmt_alloc(input.length);
    view(inPtr, input.length).set(input);
    const t0 = process.hrtime.bigint();
    const outPtr = exports.avmt_transpile(inPtr, input.length);
    const t1 = process.hrtime.bigint();
    const len = exports.avmt_result_len();
    const ok = exports.avmt_ok();
    const out = Buffer.from(view(outPtr, len).slice());
    exports.avmt_free(outPtr, len);
    exports.avmt_free(inPtr, input.length);
    writeFileSync(path.join(WORK, `node-${name}.out.json`), out);
    results[name] = {
      ok, outputBytes: out.length, outputSha256: sha(out), ms: Number(t1 - t0) / 1e6,
    };
  }
  // `avmt_ok` before any call is -1: an answer that cannot be mistaken for either outcome.
  return { declaredImports: declared, reachedImports: reached, results };
}

// ------------------------------------------------------------------------------------------
// ARM 3 — the browser.
// ------------------------------------------------------------------------------------------
const SITE = path.join(WORK, 'site');
rmSync(SITE, { recursive: true, force: true });
mkdirSync(path.join(SITE, 'assets/artifacts'), { recursive: true });
for (const name of readdirSync(PAGE_DIR)) {
  if (name.startsWith('.')) continue;
  const src = path.join(PAGE_DIR, name);
  if (statSync(src).isDirectory()) continue;
  copyFileSync(src, path.join(SITE, name));
}
copyFileSync(HOST_MJS, path.join(SITE, 'wasm_host.mjs'));
copyFileSync(MODULE, path.join(SITE, 'assets/avm_transpiler_wasm.wasm'));
for (const name of fixtures) {
  copyFileSync(path.join(ARTIFACTS, `${name}.json`), path.join(SITE, `assets/artifacts/${name}.json`));
}
writeFileSync(path.join(SITE, 'assets/fixtures.json'), JSON.stringify(fixtures));

const EVAL_MS = Number(process.env.M31_EVAL_MS ?? 600_000);
const LOAD_MS = Number(process.env.M31_LOAD_MS ?? 180_000);

const arms = { native: nativeArm };
let exitCode = 0;
let server;
let conn;
let child;
let stderrChunks = [];

try {
  arms.node = await nodeArm();

  server = await serveDirectory(SITE);
  const launched = await launchChromium(CHROMIUM, { userDataDir: path.join(WORK, 'chrome-profile') });
  child = launched.child;
  stderrChunks = launched.stderrChunks;
  conn = await CdpConnection.connect(launched.endpoint, EVAL_MS);

  const page = await openPage(conn, `${server.origin}/index.html`, { loadTimeoutMs: LOAD_MS });
  const ready = await page.eval(
    'new Promise((resolve) => { const t = setInterval(() => {'
      + ' if (globalThis.avmtDemoReady === true) { clearInterval(t); resolve("ready"); }'
      + ' if (globalThis.avmtDemoError) { clearInterval(t); resolve("error: " + globalThis.avmtDemoError); }'
      + ' }, 50); })',
    LOAD_MS,
  );
  if (ready !== 'ready') throw new Error(`the page did not become ready: ${ready}`);

  const modules = await page.eval('window.avmtDemo.modules', EVAL_MS);
  const contracts = await page.eval('window.avmtDemo.transpileArms()', EVAL_MS);
  const refusals = await page.eval('window.avmtDemo.refusalArms()', EVAL_MS);
  // Read AFTER every transpile, so an import reached during one is in the list.
  const reached = await page.eval('window.avmtDemo.reachedImports()', EVAL_MS);
  const instantiations = await page.eval('window.avmtDemo.instantiations()', EVAL_MS);

  for (const [name, r] of Object.entries(contracts)) {
    writeFileSync(path.join(WORK, `browser-${name}.out.json`), Buffer.from(r.outputBase64, 'base64'));
  }

  arms.browser = {
    modules,
    contracts,
    refusals,
    reachedImports: reached,
    instantiations,
    navigations: page.requests.filter((r) => r.url.endsWith('/index.html')).length,
    wasmRequests: page.requests.filter((r) => r.url.endsWith('.wasm')).length,
    requests: page.requests.map((r) => r.url.replace(server.origin, '')),
    consoleErrors: page.console.filter((c) => c.level === 'error').map((c) => c.text),
    pageErrors: [...page.errors],
  };
  await page.close();
} catch (err) {
  exitCode = 1;
  arms.error = { message: String(err && err.message ? err.message : err), stack: String(err && err.stack) };
} finally {
  conn?.close();
  child?.kill('SIGTERM');
  if (child) setTimeout(() => child.kill('SIGKILL'), 2000).unref?.();
  await server?.close();
}

// ------------------------------------------------------------------------------------------
// ARM 4 — the rung, over the BROWSER'S OUTPUT.
//
// "Read it from the artefact" is not enough on its own; this campaign's own rule is to ask
// WHICH artefact. The rung is computed from the bytes that came out of the page, decoded here,
// and never from anything the page said about them.
// ------------------------------------------------------------------------------------------
function decodeDebugSymbols(b64) {
  const raw = Buffer.from(b64, 'base64');
  let text;
  try { text = inflateRawSync(raw).toString('utf8'); } catch { text = inflateSync(raw).toString('utf8'); }
  return JSON.parse(text);
}

function fileMapOf(artifact) {
  const files = new Map();
  for (const [id, entry] of Object.entries(artifact.file_map ?? {})) {
    files.set(Number(id), { path: entry.path, source: entry.source });
  }
  return files;
}

function avmFunctions(artifact) {
  return (artifact.functions ?? []).filter((f) => (f.custom_attributes ?? []).includes('abi_public'));
}

function rungArm() {
  const out = { contracts: {}, controls: {} };
  if (!arms.browser) return { ...out, unavailable: 'the browser arm did not run' };

  for (const name of fixtures) {
    const file = path.join(WORK, `browser-${name}.out.json`);
    if (!existsSync(file)) continue;
    const artifact = JSON.parse(readFileSync(file, 'utf8'));
    const files = fileMapOf(artifact);
    const perFn = {};
    for (const fn of avmFunctions(artifact)) {
      const debugInfo = decodeDebugSymbols(fn.debug_symbols).debug_infos[0];
      const bytecodeLength = Buffer.from(fn.bytecode, 'base64').length;
      const paths = [];
      const map = new ContractSourceMap(debugInfo, bytecodeLength, files, (p) => {
        const i = paths.indexOf(p);
        return i >= 0 ? i : paths.push(p) - 1;
      });
      const pcs = Object.values(debugInfo.brillig_locations ?? {})
        .flatMap((m) => Object.keys(m).map(Number))
        .sort((a, b) => a - b);
      const positions = pcs.map((pc) => map.positionFor(pc));
      const resolved = positions.filter((p) => p !== null);
      perFn[fn.name] = {
        rung: map.verdict.rung,
        reason: map.verdict.reason,
        mappedPcs: map.verdict.mappedPcs,
        pcRange: map.verdict.pcRange,
        bytecodeLength,
        pcCount: pcs.length,
        // The KEY LIST, not just its range. `verify_transpiler_rung1_mapping_survives` compares
        // it against the input's as a SET: a range comparison says only that two intervals do not
        // overlap, and for a program whose Brillig index space happens to reach into the AVM byte
        // space that is false while the re-keying is perfectly correct. Measured: `branches` has
        // 56 Brillig opcodes and AVM offsets in [64, 489], so 22 input indices sit inside the
        // output's RANGE and none of them is the same ENTRY.
        pcKeys: pcs,
        // THE OTHER KEY SPACE IN THE SAME `DebugInfo`, reported because the milestone's first
        // draft said no fixture had one and TWO of the seven do. `brillig_procedure_locs` is
        // `SOURCE-MAPPING.md` §2.4's residual hole 1 — `patch_debug_info_pcs` re-keys
        // `brillig_locations` and leaves this map alone — and §2.4 argued it from a value RANGE
        // over `AvmTest`. `branches` and `reverting` carry one entry each and it comes through
        // byte-identical to the input's, which is the hole demonstrated exactly. Reported as data
        // so `verify_transpiler_rung1_mapping_survives` can assert it rather than describe it.
        procedureLocs: JSON.stringify(debugInfo.brillig_procedure_locs ?? {}),
        positioned: resolved.length,
        unpositioned: positions.length - resolved.length,
        distinctLines: [...new Set(resolved.map((p) => p.line))].sort((a, b) => a - b),
        paths,
        firstThree: resolved.slice(0, 3).map((p) => ({ path: paths[p.pathId], line: p.line, column: p.column })),
        unrecognisedTreeNodes: map.unrecognisedTreeNodes,
        missingFileReferences: map.missingFileReferences,
      };
    }
    // The INPUT's own keys, so "re-keyed" is a comparison of two key sets rather than a claim.
    const input = JSON.parse(readFileSync(path.join(ARTIFACTS, `${name}.json`), 'utf8'));
    const inputKeys = {};
    const inputProcedureLocs = {};
    for (const fn of avmFunctions(input)) {
      const di = decodeDebugSymbols(fn.debug_symbols).debug_infos[0];
      inputKeys[fn.name] = Object.values(di.brillig_locations ?? {})
        .flatMap((m) => Object.keys(m).map(Number))
        .sort((a, b) => a - b);
      inputProcedureLocs[fn.name] = JSON.stringify(di.brillig_procedure_locs ?? {});
    }
    out.contracts[name] = { functions: perFn, inputKeys, inputProcedureLocs };
  }

  // ---- control A: the map NOT re-keyed ---------------------------------------------------
  //
  // The exact failure the milestone is about — a build that loses `patch_debug_info_pcs`. The
  // input's Brillig-index map is spliced into the transpiled artifact's AVM bytecode length, and
  // the resolver is asked about the AVM pcs the executor will actually present. A correctly
  // re-keyed map answers all of them; this one answers none, and the number is the control.
  {
    const artifact = JSON.parse(readFileSync(path.join(WORK, 'browser-counter.out.json'), 'utf8'));
    const input = JSON.parse(readFileSync(path.join(ARTIFACTS, 'counter.json'), 'utf8'));
    const files = fileMapOf(artifact);
    const fn = avmFunctions(artifact).find((f) => f.name === 'public_dispatch');
    const src = avmFunctions(input).find((f) => f.name === 'public_dispatch');
    const good = decodeDebugSymbols(fn.debug_symbols).debug_infos[0];
    const stale = decodeDebugSymbols(src.debug_symbols).debug_infos[0];
    const bytecodeLength = Buffer.from(fn.bytecode, 'base64').length;
    const avmPcs = Object.values(good.brillig_locations ?? {})
      .flatMap((m) => Object.keys(m).map(Number)).sort((a, b) => a - b);
    const staleMap = new ContractSourceMap(stale, bytecodeLength, files, () => 0);
    const goodMap = new ContractSourceMap(good, bytecodeLength, files, () => 0);
    out.controls.notRekeyed = {
      avmPcs: avmPcs.length,
      positionedByTheRealMap: avmPcs.filter((pc) => goodMap.positionFor(pc) !== null).length,
      positionedByTheStaleMap: avmPcs.filter((pc) => staleMap.positionFor(pc) !== null).length,
      staleRung: staleMap.verdict.rung,
      staleKeyRange: staleMap.verdict.pcRange,
    };
  }

  // ---- control B: a rung-3 artifact the TRANSPILER ITSELF produced ------------------------
  //
  // `private_only` has no `abi_public` function, so `create_revert_dispatch_fn` appends a
  // `public_dispatch` with no debug info at all. It must be LABELLED rung 3, not accepted.
  {
    const artifact = JSON.parse(readFileSync(path.join(WORK, 'browser-private_only.out.json'), 'utf8'));
    const fn = avmFunctions(artifact).find((f) => f.name === 'public_dispatch');
    const di = decodeDebugSymbols(fn.debug_symbols).debug_infos[0] ?? null;
    const bytecodeLength = Buffer.from(fn.bytecode, 'base64').length;
    const verdict = rungFor(di, bytecodeLength, fileMapOf(artifact));
    out.controls.appendedRevertDispatch = {
      present: true,
      bytecodeLength,
      debugInfos: decodeDebugSymbols(fn.debug_symbols).debug_infos.length,
      rung: verdict.rung,
      reason: verdict.reason,
      mappedPcs: verdict.mappedPcs,
    };
  }

  // ---- control C: debug symbols removed altogether ----------------------------------------
  {
    const artifact = JSON.parse(readFileSync(path.join(WORK, 'browser-counter.out.json'), 'utf8'));
    const fn = avmFunctions(artifact).find((f) => f.name === 'public_dispatch');
    const bytecodeLength = Buffer.from(fn.bytecode, 'base64').length;
    const verdict = rungFor(null, bytecodeLength, fileMapOf(artifact));
    out.controls.noDebugSymbols = { rung: verdict.rung, reason: verdict.reason, mappedPcs: verdict.mappedPcs };
  }

  return out;
}

try {
  arms.rung = rungArm();
} catch (err) {
  // RECORDED, NOT FATAL, and the distinction is a finding. A `throw` here used to set
  // `exitCode = 1`, which made `m31_require_arms` refuse the whole report — so a mutation that
  // broke the TRANSPILER took down the IDENTITY check as a precondition failure with zero
  // assertions, instead of letting it report the seven digest mismatches it exists for. That is
  // "a mutation that reddens has not exercised the assertion it was written for", caused by the
  // runner rather than by the check. The rung arm's failure is an assertion's business:
  // `verify_transpiler_rung1_mapping_survives` §0 asserts `arms.rungError` is MISSING, so it goes
  // red for its own reason and nothing else does.
  arms.rungError = { message: String(err && err.message ? err.message : err), stack: String(err && err.stack) };
}

// ------------------------------------------------------------------------------------------
// ARM 5 — REGISTER AND EXECUTE, over the bytes the BROWSER produced.
//
// The artifact handed to the driver is `browser-<fixture>.out.json`, written above from the
// page's base64 — not the native binary's output and not a second transpile here. The identity
// arm is what says those are the same bytes; this arm is what says the AVM runs them.
//
// It is skipped, LOUDLY and by name, when no `avm.wasm` carrying M27's crypto exports is
// available: `AVM_WASM_PATH` or M27's own build output. A skip that reported nothing would read
// as an arm that passed.
// ------------------------------------------------------------------------------------------
async function executeArm() {
  const candidates = [
    process.env.AVM_WASM_PATH,
    path.join(process.env.HOME, '.cache/aztec-m27-browser/avm.wasm'),
    path.join(process.env.HOME, '.cache/aztec-m27-browser/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm'),
  ].filter(Boolean);
  const avmWasm = candidates.find((c) => existsSync(c));
  if (!avmWasm) {
    return {
      available: false,
      reason: `no avm.wasm found; looked at ${candidates.join(', ')}. Remedy: just avm-wasm-build-m27, or set AVM_WASM_PATH`,
      contracts: {},
    };
  }
  const { compileAvm, instantiateAvm } = await import('../node-host/src/loader.ts');
  const { runTranspiledContract } = await import('../orchestration/src/transpiled_contract_driver.ts');
  const reactor = await instantiateAvm(await compileAvm(avmWasm));

  const contracts = {};
  let seed = 3100;
  // FOUR CONTRACTS AND NOT TWO, AND THE REASON IS THE CAMPAIGN'S OWN. `instructionsExecuted` is
  // the field that says the transaction DID something, and a field that is the same number for
  // every input is indistinguishable from a constant. `branches` and `memory` have visibly
  // different bytecode lengths from `counter`, so the check can require the counts to differ
  // rather than merely to be large.
  for (const name of ['counter', 'reverting', 'branches', 'memory']) {
    const file = path.join(WORK, `browser-${name}.out.json`);
    if (!existsSync(file)) {
      contracts[name] = { error: `no browser output at ${file}` };
      continue;
    }
    const bytes = readFileSync(file);
    try {
      contracts[name] = await runTranspiledContract(reactor, JSON.parse(bytes.toString('utf8')), {
        fixture: name,
        artifactSha256: sha(bytes),
        bytecodeProvenance:
          'transpiled by avm_transpiler_wasm.wasm inside Chromium; carried out of the page as base64; '
          + 'executed here in Node against the same avm.wasm a page would fetch',
        seed: (seed += 100),
      });
    } catch (err) {
      contracts[name] = { error: String(err && err.message ? err.message : err), stack: String(err && err.stack).slice(0, 1200) };
    }
  }
  return { available: true, avmWasm, avmWasmSha256: shaFile(avmWasm), exports: reactor.exportNames.length, contracts };
}

try {
  arms.execute = await executeArm();
} catch (err) {
  arms.execute = { available: false, reason: `the execute arm threw: ${String(err && err.message ? err.message : err)}`, contracts: {} };
}

// ------------------------------------------------------------------------------------------
// The comparison, computed here so every check reads the same verdict.
// ------------------------------------------------------------------------------------------
const identity = {};
for (const name of fixtures) {
  const nat = nativeArm[name];
  const nod = arms.node?.results?.[name];
  const bro = arms.browser?.contracts?.[name];
  identity[name] = {
    nativeSha256: nat?.outputSha256 ?? null,
    nodeSha256: nod?.outputSha256 ?? null,
    browserSha256: bro?.outputSha256 ?? null,
    nativeBytes: nat?.outputBytes ?? 0,
    browserBytes: bro?.outputBytes ?? 0,
    identicalNodeVsNative: !!(nat?.outputSha256 && nod?.outputSha256 === nat.outputSha256),
    identicalBrowserVsNative: !!(nat?.outputSha256 && bro?.outputSha256 === nat.outputSha256),
    browserOk: bro?.ok ?? null,
  };
}

const out = {
  measuredAt: new Date().toISOString(),
  chromium: (() => { try { return execFileSync(CHROMIUM, ['--version'], { encoding: 'utf8' }).trim(); } catch { return 'unknown'; } })(),
  node: process.version,
  module: { path: MODULE, bytes: statSync(MODULE).size, sha256: shaFile(MODULE) },
  native: { path: NATIVE, bytes: statSync(NATIVE).size, sha256: shaFile(NATIVE) },
  wasmHost: { path: HOST_MJS, sha256: shaFile(HOST_MJS), servedSha256: shaFile(path.join(SITE, 'wasm_host.mjs')) },
  fixtures,
  artifactsDir: ARTIFACTS,
  artifactSha256: Object.fromEntries(fixtures.map((n) => [n, shaFile(path.join(ARTIFACTS, `${n}.json`))])),
  site: SITE,
  serverRequests: server?.requests ?? [],
  browserStderrLines: stderrChunks.join('').split('\n').filter(Boolean).length,
  identity,
  arms,
};
process.stdout.write(JSON.stringify(out, null, 2) + '\n');
writeFileSync(path.join(WORK, 'transpiler-last.json'), JSON.stringify(out, null, 2) + '\n');
process.exit(exitCode);
