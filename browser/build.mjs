// The browser build: three entry points, code-split, with the chunk budgets enforced.
//
//   node browser/build.mjs            (or: just browser-build)
//
// ===========================================================================================
// WHAT WAS REUSED FROM UPSTREAM'S OWN BROWSER CONFIGURATION, AND WHERE THIS DIVERGES.
// ===========================================================================================
//
// The milestone's first deliverable is "upstream's own browser configuration reused as the
// starting point ... start from what they do and record any divergence". Upstream's is
// `aztec-packages/playground/vite.config.ts`. What was taken from it:
//
//   * THE CHUNK-SIZE VALIDATOR, shape and discipline both. Their plugin walks the output
//     directory after `writeBundle`, matches each file against a `{ pattern, maxSizeKB,
//     description }` list, collects VIOLATIONS and THROWS — the build fails, it does not warn.
//     Their limits carry a per-bump comment log ("AD: bumped from 1600 => 1680 as we now have a
//     20kb msgpack lib in bb.js"), which is the practice that makes a budget a decision rather
//     than a ratchet. `chunk-budgets.json` keeps both, as data.
//   * LAZY-LOADING THE TWO HEAVY THINGS. Their README claims 1.6 MB compressed with lazy-loaded
//     wasm and artifacts, and the mechanism at our pin is already in bb.js:
//     `barretenberg_wasm/fetch_code/browser/index.js` does `await import('./barretenberg.js')`.
//     Code splitting is what keeps that dynamic import a separate chunk instead of inlining 7.9 MB
//     into the entry.
//   * THE NODE-BUILTIN POLYFILL PROBLEM, and its answer's SHAPE: name the builtins, alias them,
//     do not let the bundler guess.
//
// DIVERGENCES, EACH WITH ITS REASON:
//
//   1. **esbuild, not vite.** Vite is not in this repository's toolchain and installing it would
//      add ~400 packages for a build with no dev server, no HMR, no JSX and no React. esbuild is
//      ALREADY INSTALLED HERE — `spike/node_modules/.bin/esbuild` and `diffsim/`'s — and the
//      design document's own §8.5 browser measurement (10.56 MB / 6.84 MB gzipped, the AVM at
//      115 KB) was taken with it, so keeping it makes this build comparable to the campaign's own
//      baseline instead of to a new one. Vite's production build is rollup, which splits the same
//      way; what would differ is the plugin API, not the artefact.
//   2. **The polyfill SET is different, and upstream's would not have been enough.** The
//      Playground polyfills `['buffer', 'path', 'process', 'net', 'tty']`. Measured on THIS
//      dependency graph, `esbuild --platform=browser` fails on `util` (37 files), `assert` (5) and
//      `tty` (1) — and `util` and `assert` are NOT in upstream's list. The brief's "the same
//      dependency set" is therefore true of the problem and not of the answer; only `tty` overlaps.
//      `path` and `net` never appear in our graph at all, because we do not import `@aztec/pxe`.
//   3. **The shims are this repository's own, from `browser-probe/shims/`**, rather than
//      `vite-plugin-node-polyfills`'. They were written for the spike's browser probe, they are
//      tracked, and they are three files totalling ELEVEN lines (4 + 5 + 2; this said twelve
//      until M27's review counted them). Reaching for a plugin whose
//      transitive closure is larger than the thing being polyfilled would be the wrong trade.
//   4. **One module is SUBSTITUTED, and it is DD-11 rather than packaging.** See below.
//
// ===========================================================================================
// THE SUBSTITUTION, AND WHY IT IS ONE FILE AND NOT A PACKAGE ALIAS.
// ===========================================================================================
//
// `@aztec/foundation/dest/crypto/poseidon/index.js` is redirected to `src/foundation_poseidon.ts`.
// ONE FILE. `@aztec/bb.js` stays in the graph, stays resolved from `dest/browser/`, and stays
// reachable — which is what keeps `verify_bb_js_browser_condition_honoured` a statement about
// something. What changes is that the public-only path no longer CALLS it, so its 7.9 MB chunk is
// never fetched. `verify_public_only_page_never_fetches_barretenberg` asserts that on the
// browser's own network log, because a bundler configuration is a claim about intent.
//
// Aliasing the whole of `@aztec/bb.js` away would have been easier and strictly worse: the check
// above would then be asserting an absence from a tree that excludes its subject by construction,
// which `CAMPAIGN-BRIEF.md` lists twice as a defect that shipped.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { gzipSync } from 'node:zlib';
import path from 'node:path';
import process from 'node:process';

const HERE = import.meta.dirname;
const REPO = path.resolve(HERE, '..');
const DIST = process.env.BROWSER_DIST ?? path.join(HERE, 'dist');
const ORCH = path.join(REPO, 'orchestration');

function fail(message) {
  process.stderr.write(`browser/build.mjs: ${message}\n`);
  process.exit(1);
}

// ---------------------------------------------------------------------------------------------
// esbuild. NOT installed under browser/ — it exists twice in this checkout already, and the
// campaign's reuse discipline says to look in the parallel subdirectory before installing.
// ---------------------------------------------------------------------------------------------
const ESBUILD_CANDIDATES = [
  path.join(REPO, 'spike/node_modules/.bin/esbuild'),
  path.join(REPO, 'diffsim/node_modules/.bin/esbuild'),
];
const ESBUILD = process.env.M27_ESBUILD ?? ESBUILD_CANDIDATES.find((c) => existsSync(c));
if (!ESBUILD) fail(`no esbuild at any of: ${ESBUILD_CANDIDATES.join(', ')}`);

if (!existsSync(path.join(ORCH, 'node_modules/@aztec/stdlib'))) {
  fail(`the orchestration's @aztec packages are not installed. Remedy: cd ${ORCH} && npm ci`);
}

// The shims, reused from the spike's browser probe. Asserted present rather than assumed: a
// missing alias target makes esbuild resolve the BUILTIN NAME as a bare package and fail with a
// message about npm, which reads like a dependency problem.
//
// THREE ARE REUSED and ONE IS M27'S. `util`, `assert` and `tty` were written for the spike's
// browser probe and are eleven lines between them; `module` is new, because `@aztec/blob-lib`'s
// KZG context reaches for `createRequire` and nothing in the spike's narrower graph did.
const SHIMS = {
  util: path.join(REPO, 'browser-probe/shims/util.js'),
  assert: path.join(REPO, 'browser-probe/shims/assert.js'),
  tty: path.join(REPO, 'browser-probe/shims/tty.js'),
  module: path.join(HERE, 'src/shims/module.js'),
};
for (const [name, file] of Object.entries(SHIMS)) {
  if (!existsSync(file)) fail(`the ${name} shim is missing: ${file}`);
}

// `Buffer` and `process` are referenced as GLOBALS by @aztec's compiled output, which is a
// different problem from an unresolved import: esbuild leaves a free identifier alone and the page
// dies at run time with `Buffer is not defined`. `--inject` supplies them.
const GLOBALS = path.join(HERE, 'src/globals.js');
if (!existsSync(GLOBALS)) fail(`the globals injection is missing: ${GLOBALS}`);

// ---------------------------------------------------------------------------------------------
// THE REDIRECT TABLE. Five modules, by ABSOLUTE PATH, and every one of them is DD-11.
//
// Absolute paths rather than a regex over the specifier, because the specifier is relative in
// every one of these modules' importers. Every entry's hit count is asserted NON-ZERO at the end
// of the build: a redirect that quietly stops matching is a build that quietly goes back to the
// eager, bb.js-calling graph, and the only thing that would notice is a number in a network log
// somebody has to read.
//
//   poseidon        -> ours, over avm.wasm's own export        (7.9 MB of proving wasm, never fetched)
//   grumpkin        -> ours, over avm.wasm's own export        (the SECOND route to the same wasm)
//   fee-juice       -> ours, six lines over UPSTREAM's lazy.js (534 KB artifact, fetched on demand)
//   class-registry  -> UPSTREAM's own lazy.js                  (998 KB artifact, never fetched here)
//   instance-registry -> UPSTREAM's own lazy.js                (427 KB artifact, never fetched here)
//
// The last two are a redirect from `index.js` to the `lazy.js` upstream ships beside it, and they
// are API-identical: both lazy modules `export *` the same event modules their eager siblings do,
// which is what makes the redirect safe rather than merely convenient.
// ---------------------------------------------------------------------------------------------
const PC = path.join(ORCH, 'node_modules/@aztec/protocol-contracts/dest');
const REDIRECTS = {
  [path.join(ORCH, 'node_modules/@aztec/foundation/dest/crypto/poseidon/index.js')]:
    path.join(HERE, 'src/foundation_poseidon.ts'),
  [path.join(PC, 'fee-juice/index.js')]: path.join(HERE, 'src/shims/protocol_fee_juice.ts'),
  [path.join(PC, 'class-registry/index.js')]: path.join(PC, 'class-registry/lazy.js'),
  [path.join(PC, 'instance-registry/index.js')]: path.join(PC, 'instance-registry/lazy.js'),
  [path.join(ORCH, 'node_modules/@aztec/foundation/dest/crypto/grumpkin/index.js')]:
    path.join(HERE, 'src/foundation_grumpkin.ts'),
};
for (const [target, replacement] of Object.entries(REDIRECTS)) {
  if (!existsSync(target)) {
    fail(`a module this build redirects does not exist: ${target}
      The redirects are DD-11: without them a public-only page downloads 7.9 MB of proving stack to
      compute a hash and 1,965 KB of contract artifacts it never opens. If a path moved, the
      redirect is silently not happening.`);
  }
  if (!existsSync(replacement)) fail(`a redirect target does not exist: ${replacement}`);
}

// TWO PASSES, AND THE SPLIT IS DD-5 ITSELF RATHER THAN A BUNDLER DETAIL.
//
// The browser and testing entries are built with `platform: 'browser'`, where an unresolved Node
// builtin is a BUILD ERROR. The Node entry is built with `platform: 'node'`, because it genuinely
// imports `node:fs/promises` — that is what "Node may add conveniences (fs, process args)" means,
// and it is the only reason the two passes differ.
//
// Putting them in one pass was tried first and is what surfaced the point: with
// `platform: 'browser'` the whole build fails on `entry_node.ts`'s own import, which is the
// bundler saying DD-5's rule back at you. The two entry points cannot share a target, so they do
// not share a pass, and `verify_browser_entry_points_are_dd5_shaped` then compares their EXPORT
// SETS across the two artefacts rather than trusting that they were built the same way.
//
// M32 ADDS TWO ENTRIES TO THE SAME PASS, AND THE SAME PASS IS THE POINT. The worker hosts the same
// runtime the page does; building it in a pass of its own would give it a second copy of every
// shared chunk and make "the worker adds no capability the browser reference lacks" a comparison
// between two differently-built artefacts. In one pass esbuild's splitting puts the runtime in the
// chunks both entries already share, which is also why adding them moves no existing entry's eager
// total — measured, and recorded in `WORKER-NODE.md` §5.
//
// M33 ADDS ONE MORE, AND IT IS IN THE SAME PASS FOR THE SAME REASON PLUS ONE OF ITS OWN. The
// wallet entry is where a page opts INTO the wallet protocol boundary, and DD-11 is why it is not
// folded into `entry_browser.ts`: `WalletSchema` carries a value-reachable closure of 298 files
// and 31,205 lines through `@aztec/aztec.js`, and a page that attaches no wallet must not download
// a wallet protocol to be told so. Building it in the SAME pass is what lets
// `verify_provider_half_dd9_clean` compare its chunk set against the reference bundle's and name
// what is wallet-only — in a pass of its own the two would share nothing by construction and the
// comparison would be vacuous.
const BROWSER_ENTRIES = {
  browser: path.join(HERE, 'src/entry_browser.ts'),
  testing: path.join(HERE, 'src/entry_testing.ts'),
  demo: path.join(HERE, 'demo/main.ts'),
  worker: path.join(HERE, 'src/entry_worker.ts'),
  'worker-demo': path.join(HERE, 'demo/worker_main.ts'),
  wallet: path.join(HERE, 'src/entry_wallet.ts'),
  // M34. The wallet DEMO, in the same pass for the same reason `worker-demo` is: the page it drives
  // hosts the runtime AND the wallet at once, and a pass of its own would give it a second copy of
  // every shared chunk — which would also make "the wallet costs what the wallet entry says it
  // costs" a comparison between two differently-built artefacts.
  'wallet-demo': path.join(HERE, 'demo/wallet_main.ts'),
};
const NODE_ENTRIES = {
  node: path.join(HERE, 'src/entry_node.ts'),
};
for (const [name, file] of Object.entries({ ...BROWSER_ENTRIES, ...NODE_ENTRIES })) {
  if (!existsSync(file)) fail(`entry point ${name} is missing: ${file}`);
}
const NODE_DIST = path.join(DIST, 'node');

rmSync(DIST, { recursive: true, force: true });
mkdirSync(DIST, { recursive: true });

// ---------------------------------------------------------------------------------------------
// The esbuild pass itself lives in `esbuild-driver.mjs`, because esbuild's CLI cannot load a plugin
// and the redirect table is one. The configuration crosses as JSON rather than as generated source:
// the first version templated the driver into a string and every backtick in every comment
// terminated the literal.
// ---------------------------------------------------------------------------------------------
const ESBUILD_PKG = path.resolve(path.dirname(ESBUILD), '../esbuild/lib/main.js');
if (!existsSync(ESBUILD_PKG)) fail(`esbuild's JS API is not where expected: ${ESBUILD_PKG}`);
const DRIVER = path.join(HERE, 'esbuild-driver.mjs');
if (!existsSync(DRIVER)) fail(`the esbuild driver is missing: ${DRIVER}`);

mkdirSync(NODE_DIST, { recursive: true });
const configFile = path.join(DIST, '.build-config.json');
writeFileSync(
  configFile,
  JSON.stringify(
    {
      esbuildModule: ESBUILD_PKG,
      dist: DIST,
      nodeDist: NODE_DIST,
      shims: SHIMS,
      globals: GLOBALS,
      redirects: REDIRECTS,
      browserEntries: Object.entries(BROWSER_ENTRIES).map(([name, file]) => ({ in: file, out: name })),
      nodeEntries: Object.entries(NODE_ENTRIES).map(([name, file]) => ({ in: file, out: name })),
    },
    null,
    2,
  ) + '\n',
);

try {
  execFileSync(process.execPath, [DRIVER, configFile], { stdio: 'inherit' });
} catch (e) {
  fail(`esbuild failed (exit ${e.status})`);
}

// ---------------------------------------------------------------------------------------------
// THE CHUNK BUDGETS. The Playground's validator, ported: walk the output, match each file against
// the recorded budgets, collect violations, and FAIL THE BUILD.
//
// TWO DIFFERENCES FROM THEIRS, both because of what this milestone's deliverable says.
//
//   * GZIPPED, not raw. The deliverable is "each chunk stays within its recorded gzipped budget",
//     and gzip is what a page actually downloads. Raw bytes are recorded too, because a raw number
//     is what a reader can reproduce with `ls`.
//   * EVERY FILE MUST BE COVERED BY SOME BUDGET. Theirs ends with a catch-all `/.*/ 5300 KB`,
//     which is a safety net; here an uncovered file is a FAILURE, because "the budget did not
//     catch it" and "nothing had a budget" are indistinguishable from the outside, and this
//     campaign has a recorded defect for exactly that shape.
// ---------------------------------------------------------------------------------------------
// The demo page's HTML, copied beside its script. It is COPIED rather than emitted so that the
// file a person reads and the file the browser loads are the same file — a generated HTML page is
// one more place for the demo and the harness to come apart.
for (const [source, target, script] of [
  ['demo/index.html', 'index.html', './demo.js'],
  ['demo/worker.html', 'worker.html', './worker-demo.js'],
  ['demo/wallet.html', 'wallet.html', './wallet-demo.js'],
]) {
  const page = readFileSync(path.join(HERE, source), 'utf8');
  if (!page.includes(script)) {
    fail(`${source} does not load ${script}; the copied page would be blank`);
  }
  writeFileSync(path.join(DIST, target), page);
}

// ---------------------------------------------------------------------------------------------
// THE REDIRECTS MUST HAVE FIRED, RE-CHECKED HERE BECAUSE THE PLUGIN'S OWN GUARD DOES NOT FAIL.
//
// `esbuild-driver.mjs`'s plugin pushes an error in `onEnd` when a redirect matched nothing. That
// error does NOT reject `esbuild.build()` — measured: a pass in which all five redirects fired zero
// times built successfully and reported no error, and the only thing that noticed was a check
// reading `substitution.json` afterwards. A guard that cannot fail the build is the shape this
// whole file exists to refuse, so the guard is re-run where the exit code belongs to us.
// ---------------------------------------------------------------------------------------------
const substitutions = JSON.parse(readFileSync(path.join(DIST, 'substitution.json'), 'utf8'));
const deadRedirects = [];
substitutions.passes.forEach((pass, i) => {
  for (const [target, n] of Object.entries(pass)) {
    if (n === 0) deadRedirects.push(`  pass ${i}: ${target}`);
  }
});
if (substitutions.passes.length !== 2) {
  fail(`expected two build passes to have run the redirect table, saw ${substitutions.passes.length}`);
}
if (deadRedirects.length) {
  fail(
    'these DD-11 redirects matched nothing. The build would ship the eager module, and the '
      + 'only thing that would notice is a megabyte in a network log:' + '\n'
      + deadRedirects.join('\n'),
  );
}

const budgetsFile = path.join(HERE, 'chunk-budgets.json');
if (!existsSync(budgetsFile)) fail(`the chunk budgets are missing: ${budgetsFile}`);
const budgetDoc = JSON.parse(readFileSync(budgetsFile, 'utf8'));
const budgets = budgetDoc.budgets;
const entryBudgets = budgetDoc.entryBudgets;
if (!Array.isArray(budgets) || budgets.length === 0) fail('chunk-budgets.json declares no budgets');
if (!Array.isArray(entryBudgets) || entryBudgets.length === 0) {
  fail('chunk-budgets.json declares no entryBudgets, so nothing constrains what a page loads eagerly');
}

function walk(dir, base = '') {
  const out = [];
  for (const name of readdirSync(dir).sort()) {
    if (name.startsWith('.')) continue;
    const full = path.join(dir, name);
    const rel = base ? `${base}/${name}` : name;
    if (statSync(full).isDirectory()) out.push(...walk(full, rel));
    else out.push({ rel, full, size: statSync(full).size });
  }
  return out;
}

const OUTPUT_EXT = /\.(js|css|map)$/;
const files = walk(DIST).filter((f) => OUTPUT_EXT.test(f.rel));
if (files.length === 0) fail('the build produced no output files to measure');

const measured = [];
const violations = [];
const uncovered = [];
for (const f of files) {
  const gzip = gzipSync(readFileSync(f.full), { level: 9 }).length;
  const row = { file: f.rel, bytes: f.size, gzipBytes: gzip, gzipKB: +(gzip / 1024).toFixed(2), budget: null };
  const budget = budgets.find((b) => new RegExp(b.pattern).test(f.rel));
  if (!budget) {
    uncovered.push(f.rel);
  } else {
    row.budget = budget.name;
    row.maxGzipKB = budget.maxGzipKB;
    if (row.gzipKB > budget.maxGzipKB) {
      violations.push(
        `  ${f.rel}: ${row.gzipKB} KB gzipped exceeds ${budget.maxGzipKB} KB (${budget.name} — ${budget.description})`,
      );
    }
  }
  measured.push(row);
}

// ---------------------------------------------------------------------------------------------
// THE EAGER SET PER ENTRY POINT — the number DD-11 is actually about.
//
// A per-file budget cannot see the regression that matters here. Every individual chunk can stay
// exactly its recorded size while a lazily-loaded megabyte MOVES INTO the eager set, because a
// dynamic import becoming a static one changes which chunks a page fetches and not how big any of
// them is. So the closure of an entry point's STATIC imports is computed from the metafile and
// budgeted separately.
//
// `import-statement` and `require-call` are eager; `dynamic-import` is exactly the edge that makes
// a chunk lazy and is where the walk stops. That distinction is the whole mechanism, so it is read
// off the metafile rather than inferred from a file name.
// ---------------------------------------------------------------------------------------------
const gzipOf = new Map(measured.map((r) => [r.file, r.gzipBytes]));
const metas = [
  { meta: JSON.parse(readFileSync(path.join(DIST, 'meta.json'), 'utf8')), prefix: '' },
  { meta: JSON.parse(readFileSync(path.join(NODE_DIST, 'meta.json'), 'utf8')), prefix: 'node/' },
];
const outputs = new Map();
for (const { meta, prefix } of metas) {
  for (const [name, out] of Object.entries(meta.outputs)) {
    const rel = prefix + path.relative(prefix ? NODE_DIST : DIST, path.resolve(REPO, name));
    outputs.set(rel, out);
  }
}

const unresolvedEagerEdges = new Set();

function eagerClosure(entry) {
  const seen = new Set();
  const stack = [entry];
  while (stack.length) {
    const cur = stack.pop();
    if (seen.has(cur)) continue;
    seen.add(cur);
    const out = outputs.get(cur);
    // A KEY THAT DOES NOT RESOLVE IS THE RESIDUE, AND IT IS PRINTED RATHER THAN SKIPPED. Silently
    // dropping an edge undercounts the eager total in the direction that reads as good news, which
    // is the scanner shape CAMPAIGN-BRIEF.md names. The entry itself missing is already a `fail()`
    // below; anything else reached from it that this build did not emit is a real inconsistency.
    if (!out) {
      if (cur !== entry) unresolvedEagerEdges.add(`${entry} -> ${cur}`);
      continue;
    }
    const prefix = cur.startsWith('node/') ? 'node/' : '';
    for (const imp of out.imports ?? []) {
      if (imp.kind === 'dynamic-import') continue;
      // An EXTERNAL import is a Node builtin the Node pass left alone. It is not a file this build
      // produced and it costs a page nothing, because a page never loads this entry point.
      if (imp.external) continue;
      const rel = prefix + path.relative(prefix ? NODE_DIST : DIST, path.resolve(REPO, imp.path));
      stack.push(rel);
    }
  }
  return [...seen].sort();
}

const eager = [];
const eagerViolations = [];
for (const b of entryBudgets) {
  if (!outputs.has(b.entry)) {
    fail(`entryBudgets names ${b.entry}, which the build did not produce. The budget would pass by
      measuring nothing, which is the shape this whole file exists to refuse.`);
  }
  const files = eagerClosure(b.entry);
  const missing = files.filter((f) => !gzipOf.has(f));
  if (missing.length) fail(`the eager closure of ${b.entry} names files with no measured size: ${missing.join(', ')}`);
  const gzipBytes = files.reduce((a, f) => a + gzipOf.get(f), 0);
  const gzipKB = +(gzipBytes / 1024).toFixed(2);
  eager.push({ name: b.name, entry: b.entry, files, gzipBytes, gzipKB, maxGzipKB: b.maxGzipKB });
  if (gzipKB > b.maxGzipKB) {
    eagerViolations.push(
      `  ${b.entry}: ${gzipKB} KB gzipped eagerly exceeds ${b.maxGzipKB} KB (${b.name} — ${b.description})`,
    );
  }
}

if (unresolvedEagerEdges.size) {
  fail('these eager-closure edges name an output this build did not emit, so the eager totals above\n'
    + '      would be undercounts:\n  ' + [...unresolvedEagerEdges].join('\n  '));
}

measured.sort((a, b) => b.gzipBytes - a.gzipBytes);
const report = {
  measuredAt: null,
  totalBytes: measured.reduce((a, b) => a + b.bytes, 0),
  totalGzipBytes: measured.reduce((a, b) => a + b.gzipBytes, 0),
  files: measured,
  eager,
  uncovered,
  violations: [...violations, ...eagerViolations],
};
writeFileSync(path.join(DIST, 'chunks.json'), JSON.stringify(report, null, 2) + '\n');

process.stdout.write('\nchunk sizes (gzipped / budget):\n');
for (const row of measured) {
  process.stdout.write(
    `  ${row.file.padEnd(34)} ${String(row.gzipKB).padStart(9)} KB` +
      (row.budget ? ` / ${String(row.maxGzipKB).padStart(7)} KB  ${row.budget}` : '   NO BUDGET') +
      '\n',
  );
}
process.stdout.write(
  `  ${'TOTAL'.padEnd(34)} ${String(+(report.totalGzipBytes / 1024).toFixed(2)).padStart(9)} KB gzipped, ` +
    `${(report.totalBytes / 1024 / 1024).toFixed(2)} MB raw\n\n`,
);

if (uncovered.length) {
  fail(`these output files are covered by no budget, so nothing constrains them:\n  ${uncovered.join('\n  ')}`);
}
process.stdout.write('eager set per entry point (gzipped / budget):\n');
for (const row of eager) {
  process.stdout.write(
    `  ${row.entry.padEnd(34)} ${String(row.gzipKB).padStart(9)} KB / ${String(row.maxGzipKB).padStart(7)} KB` +
      `  (${row.files.length} file(s))\n`,
  );
}
process.stdout.write('\n');

if (violations.length || eagerViolations.length) {
  fail(
    `chunk budget exceeded — this is a BUILD FAILURE, not a warning:\n${[...violations, ...eagerViolations].join('\n')}`,
  );
}
process.stdout.write('browser/build.mjs: all chunks within their recorded gzipped budgets\n');
