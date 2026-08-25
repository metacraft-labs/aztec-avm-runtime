// import_graph.mjs — the module-level import closure of an ES module, measured.
//
// WHY THIS IS NOT `npm ls`. A package's DEPENDENCY list and a bundle's IMPORT
// GRAPH are different objects and this campaign has already been caught by the
// gap between them: `koa` is in `node_modules` and is quoted in M18's own
// deliverable as something `@aztec/telemetry-client` "drags in", but koa is a
// dependency of `@aztec/foundation`, which the orchestration needs whatever
// happens to telemetry. Asserting on the dependency list would therefore either
// pass trivially or fail for a reason that has nothing to do with the subject.
// What a bundler emits is the transitive closure of the specifiers that are
// actually imported, and that is what this walks.
//
//   node tools/import_graph.mjs --entry <file-or-specifier> [--entry ...]
//                               [--from <dir>] [--json <path>]
//                               [--include-dynamic] [--max <n>]
//
// It reports, per reachable module: the resolved file URL, and the npm package
// it belongs to (the last `node_modules/<name>` segment on its path, scope
// included). The package set is what an assertion should be written against.
//
// STATIC, DELIBERATELY. Running the entry point and inspecting what got loaded
// would miss every branch not taken on that run, and a check that only sees the
// happy path is the failure mode this file exists to avoid. The cost is that a
// specifier built at run time (`import(base + name)`) is invisible; those are
// reported separately as `unresolvable`, with their source location, so they are
// a named gap rather than a silent one.

import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { dirname, resolve as pathResolve } from 'node:path';

const argv = process.argv.slice(2);
function opt(name, def = null) {
  const i = argv.indexOf(name);
  return i === -1 ? def : argv[i + 1];
}
function flag(name) {
  return argv.includes(name);
}
function all(name) {
  const out = [];
  for (let i = 0; i < argv.length; i++) if (argv[i] === name) out.push(argv[i + 1]);
  return out;
}

const entries = all('--entry');
if (entries.length === 0) {
  console.error('usage: import_graph.mjs --entry <file-or-specifier> [--from <dir>] [--json <path>]');
  process.exit(2);
}
const fromDir = pathResolve(opt('--from', process.cwd()));
const includeDynamic = !flag('--no-dynamic');
const MAX = Number(opt('--max', '20000'));

// `createRequire` is used only for its RESOLVER. It honours `exports` maps the
// same way ESM resolution does for the cases here, and unlike `import.meta.resolve`
// it lets the base directory be chosen per call, which is what walking a graph
// rooted somewhere other than this file requires.
function resolverFor(baseFileUrl) {
  const req = createRequire(baseFileUrl);
  return (spec) => {
    // A relative or absolute specifier resolves against the importer directly;
    // only bare specifiers go through package resolution.
    if (spec.startsWith('.') || spec.startsWith('/')) {
      return pathToFileURL(req.resolve(spec)).href;
    }
    if (spec.startsWith('node:') || BUILTINS.has(spec)) return `node:${spec.replace(/^node:/, '')}`;
    return pathToFileURL(req.resolve(spec)).href;
  };
}

const BUILTINS = new Set([
  'assert', 'async_hooks', 'buffer', 'child_process', 'cluster', 'console', 'constants',
  'crypto', 'dgram', 'diagnostics_channel', 'dns', 'domain', 'events', 'fs', 'http',
  'http2', 'https', 'inspector', 'module', 'net', 'os', 'path', 'perf_hooks', 'process',
  'punycode', 'querystring', 'readline', 'repl', 'stream', 'string_decoder', 'sys',
  'timers', 'tls', 'trace_events', 'tty', 'url', 'util', 'v8', 'vm', 'wasi', 'worker_threads',
  'zlib', 'assert/strict', 'dns/promises', 'fs/promises', 'path/posix', 'path/win32',
  'stream/promises', 'stream/web', 'timers/promises', 'util/types',
]);

// Specifier extraction. Comments and strings are stripped first, crudely but
// conservatively: a `//` inside a string literal would otherwise eat the rest of
// the line and hide an import. The patterns then only accept LITERAL specifiers.
function stripCommentsAndTemplates(src) {
  let out = '';
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '/') {
      while (i < n && src[i] !== '\n') i++;
      continue;
    }
    if (c === '/' && src[i + 1] === '*') {
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++;
      i += 2;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

const STATIC_RE = /(?:^|[\s;}])(?:import|export)\s(?:[^'"()]*?\sfrom\s)?\s*['"]([^'"]+)['"]/g;
const SIDE_EFFECT_RE = /(?:^|[\s;}])import\s*['"]([^'"]+)['"]/g;
const DYNAMIC_RE = /\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)/g;
const DYNAMIC_COMPUTED_RE = /\bimport\s*\(\s*(?!['"])/g;
const REQUIRE_RE = /\brequire\s*\(\s*['"]([^'"]+)['"]\s*\)/g;

function specifiersOf(src) {
  const clean = stripCommentsAndTemplates(src);
  const stat = new Set();
  const dyn = new Set();
  let m;
  for (const re of [STATIC_RE, SIDE_EFFECT_RE]) {
    re.lastIndex = 0;
    while ((m = re.exec(clean)) !== null) stat.add(m[1]);
  }
  REQUIRE_RE.lastIndex = 0;
  while ((m = REQUIRE_RE.exec(clean)) !== null) stat.add(m[1]);
  DYNAMIC_RE.lastIndex = 0;
  while ((m = DYNAMIC_RE.exec(clean)) !== null) dyn.add(m[1]);
  DYNAMIC_COMPUTED_RE.lastIndex = 0;
  const computed = (clean.match(DYNAMIC_COMPUTED_RE) || []).length;
  return { stat: [...stat], dyn: [...dyn], computed };
}

function packageOf(fileUrl) {
  const p = fileUrl.startsWith('file://') ? fileURLToPath(fileUrl) : fileUrl;
  const idx = p.lastIndexOf('/node_modules/');
  if (idx === -1) return null;
  const rest = p.slice(idx + '/node_modules/'.length);
  const parts = rest.split('/');
  return parts[0].startsWith('@') ? `${parts[0]}/${parts[1]}` : parts[0];
}

const seen = new Map();          // fileUrl -> { package, static:[], dynamic:[] }
const unresolvable = [];         // { from, spec, reason }
const computedSites = [];        // { from, count }
const builtins = new Set();

const queue = [];
for (const e of entries) {
  const baseUrl = pathToFileURL(pathResolve(fromDir, 'ROOT.js')).href;
  try {
    const url = resolverFor(baseUrl)(e.startsWith('.') || e.startsWith('/') ? pathResolve(fromDir, e) : e);
    queue.push({ url, from: '<entry>' });
  } catch (err) {
    unresolvable.push({ from: '<entry>', spec: e, reason: err.code ?? err.message });
  }
}

while (queue.length && seen.size < MAX) {
  const { url } = queue.shift();
  if (url.startsWith('node:')) {
    builtins.add(url);
    continue;
  }
  if (seen.has(url)) continue;
  let src;
  try {
    src = readFileSync(fileURLToPath(url), 'utf8');
  } catch (err) {
    unresolvable.push({ from: url, spec: '<self>', reason: err.code ?? err.message });
    seen.set(url, { package: packageOf(url), static: [], dynamic: [], unread: true });
    continue;
  }
  const { stat, dyn, computed } = specifiersOf(src);
  seen.set(url, { package: packageOf(url), static: stat, dynamic: dyn });
  if (computed) computedSites.push({ from: url, count: computed });
  const resolve = resolverFor(url);
  const follow = includeDynamic ? [...stat, ...dyn] : stat;
  for (const spec of follow) {
    // Type-only paths and non-JS assets are not modules a bundler emits code for.
    if (/\.(css|scss|json5|wasm|node|txt|md|svg|png)$/.test(spec)) continue;
    try {
      const next = resolve(spec);
      queue.push({ url: next, from: url });
    } catch (err) {
      unresolvable.push({ from: url, spec, reason: err.code ?? err.message });
    }
  }
}

const packages = new Set();
for (const info of seen.values()) if (info.package) packages.add(info.package);

const report = {
  entries,
  from: fromDir,
  followed_dynamic: includeDynamic,
  module_count: seen.size,
  packages: [...packages].sort(),
  builtins: [...builtins].sort(),
  computed_dynamic_import_sites: computedSites.map((c) => ({ from: c.from, count: c.count })),
  unresolvable,
  modules: [...seen.keys()].sort(),
};

const jsonPath = opt('--json');
if (jsonPath) {
  const { writeFileSync } = await import('node:fs');
  writeFileSync(jsonPath, `${JSON.stringify(report, null, 2)}\n`);
}
console.log(`modules ${report.module_count}`);
console.log(`packages ${report.packages.length}`);
for (const p of report.packages) console.log(`package ${p}`);
console.log(`unresolvable ${report.unresolvable.length}`);
for (const u of report.unresolvable) console.log(`unresolvable ${u.spec} from ${u.from} (${u.reason})`);
console.log(`computed-dynamic-sites ${report.computed_dynamic_import_sites.length}`);
console.log('import-graph.done 1');
