// The esbuild half of the browser build. Driven by `build.mjs`, which writes its configuration to
// a JSON file and runs this.
//
//   node browser/esbuild-driver.mjs <config.json>
//
// WHY IT IS A FILE AND NOT A STRING. esbuild's CLI cannot load a plugin, and the redirect table
// below is a plugin, so the build has to go through the JS API. The first version of this lived in
// a template literal inside `build.mjs` — and every backtick in every comment terminated the
// literal, twice, in ways that failed as a `SyntaxError` about an identifier four lines from the
// actual problem. A file has no such edges, and a plugin worth reading is worth putting somewhere
// it can be read.
//
// It imports esbuild by absolute path, from wherever `build.mjs` found one, so this repository adds
// no dependency of its own: `spike/node_modules` and `diffsim/node_modules` both already carry it.

import { writeFileSync } from 'node:fs';
import { readFileSync } from 'node:fs';
import process from 'node:process';

const configPath = process.argv[2];
if (!configPath) {
  process.stderr.write('esbuild-driver.mjs: no config file given\n');
  process.exit(2);
}
const config = JSON.parse(readFileSync(configPath, 'utf8'));
const esbuild = await import(config.esbuildModule);

// ---------------------------------------------------------------------------------------------
// THE DD-11 REDIRECT PLUGIN.
//
// Five modules are redirected, by absolute resolved path, and every one is a lazily-loaded or
// never-loaded megabyte. `build.mjs`'s header explains each. What this plugin adds is the property
// that makes the table trustworthy: EVERY ENTRY MUST FIRE. A redirect that quietly stops matching
// — because a package layout moved, or an importer changed its specifier — puts the eager,
// bb.js-calling graph back, and nothing downstream would notice except a number in a network log.
//
// THE FILTER IS NARROW ON PURPOSE. A universal `filter: /./` has to call `build.resolve` for every
// specifier in the graph, which takes over esbuild's own handling of the OPTIONAL
// `require('bufferutil')` and `require('utf-8-validate')` inside `ws`: esbuild warns and leaves
// them alone, while a plugin that resolves them turns them into fatal errors. Measured — the whole
// build failed on two optional native dependencies nothing calls. The filter names only the five
// directories the table can match.
// ---------------------------------------------------------------------------------------------
const FILTER = /(poseidon|grumpkin|fee-juice|class-registry|instance-registry)/;

function redirectPlugin(table, hitsOut) {
  const hits = Object.fromEntries(Object.keys(table).map((k) => [k, 0]));
  hitsOut.push(hits);
  return {
    name: 'dd11-redirects',
    setup(build) {
      build.onResolve({ filter: FILTER }, async (args) => {
        if (args.pluginData === 'seen' || args.namespace !== 'file') return null;
        const r = await build.resolve(args.path, {
          importer: args.importer,
          resolveDir: args.resolveDir,
          kind: args.kind,
          pluginData: 'seen',
        });
        // A resolution FAILURE is handed back to esbuild rather than reported, so this plugin
        // cannot turn a warning into an error for a specifier it has no opinion about.
        if (r.errors.length) return null;
        if (Object.prototype.hasOwnProperty.call(table, r.path)) {
          hits[r.path] += 1;
          return { path: table[r.path] };
        }
        return r;
      });
      build.onEnd((result) => {
        for (const [target, n] of Object.entries(hits)) {
          if (n === 0) {
            result.errors.push({
              text:
                `the DD-11 redirect for ${target} matched nothing. The build would ship the eager ` +
                'module, and the only thing that would notice is a megabyte in a network log.',
            });
          }
        }
      });
    },
  };
}

// ---------------------------------------------------------------------------------------------
// THE ANCHOR-VERSUS-PIN GAP, and why it is a SEPARATE plugin from the DD-11 redirects.
//
// The DD-11 table is keyed by RESOLVED ABSOLUTE PATH and applies to whoever imports it, because a
// megabyte fetched by anybody is the thing it exists to stop. This one is keyed by SPECIFIER and is
// conditioned on the IMPORTER: only `browser/src/vendor/pxe/`'s files — the oracle wire layer
// vendored from the `cpp` anchor — get the compatibility shim, and every other importer of the same
// subpath keeps the installed module untouched. `build.mjs`'s `ANCHOR_PIN_GAP` block records what
// the unscoped version cost.
//
// EVERY ENTRY MUST FIRE, the same discipline the redirect table carries: a shim that stops matching
// means the vendored file is resolving to a module without the symbol, which is a build error today
// and would be a silent `undefined` the day esbuild stops checking named exports.
// ---------------------------------------------------------------------------------------------
function anchorPinGapPlugin(table, hitsOut) {
  const entries = Object.entries(table ?? {});
  const hits = Object.fromEntries(entries.map(([spec]) => [spec, 0]));
  hitsOut.push(hits);
  return {
    name: 'anchor-pin-gap',
    setup(build) {
      for (const [spec, entry] of entries) {
        build.onResolve({ filter: new RegExp('^' + spec.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$') }, (args) => {
          if (args.importer && args.importer.startsWith(entry.importerPrefix)) {
            hits[spec] += 1;
            return { path: entry.target };
          }
          return null;
        });
      }
      build.onEnd((result) => {
        for (const [spec, n] of Object.entries(hits)) {
          if (n === 0) {
            result.errors.push({
              text:
                `the anchor-versus-pin shim for ${spec} matched nothing. Either the vendored file that ` +
                'needs it has gone, or the specifier moved — and the symbol the shim supplies is one the ' +
                'installed pin does not export.',
            });
          }
        }
      });
    },
  };
}

const common = {
  bundle: true,
  splitting: true,
  format: 'esm',
  target: 'es2022',
  metafile: true,
  minify: true,
  sourcemap: false,
  legalComments: 'none',
  logLevel: 'warning',
  chunkNames: 'chunks/[name]-[hash]',
};

const hitsPerPass = [];

const browserResult = await esbuild.build({
  ...common,
  entryPoints: config.browserEntries,
  platform: 'browser',
  outdir: config.dist,
  // THE SHIMS AND THE GLOBALS BELONG TO THE BROWSER PASS ONLY, and both halves of that were found
  // by importing the built Node bundle rather than by reasoning about it.
  //
  //   * Aliasing `util` into the NODE pass replaces the real one with twelve lines that have no
  //     `inherits`, and bundled pino's `inherits(SonicBoom, EventEmitter)` becomes
  //     `TypeError: jH is not a function` at module-evaluation time.
  //   * Injecting our `process` into the NODE pass replaces the real one, and pino's
  //     `process.hrtime.bigint()` becomes `Cannot read properties of undefined (reading 'bigint')`.
  //
  // Both are the same mistake: a shim is a stand-in for a platform that is ABSENT, and in Node the
  // platform is present. Neither would have been noticed by a check that read the source.
  alias: { ...config.shims, ...(config.packageAliases ?? {}) },
  // THE GLOBALS ARE INJECTED INTO THE BROWSER PASS ONLY. Node HAS `Buffer` and `process`; giving it
  // ours replaces the real `process` with a stand-in, and the Node bundle then dies at import time
  // in bundled pino with `Cannot read properties of undefined (reading 'bigint')` — `process.hrtime`
  // is not something a browser shim has any business answering for. Measured, by importing the
  // built artefact.
  inject: [config.globals],
  define: { 'process.env.NODE_ENV': '"production"', global: 'globalThis' },
  plugins: [redirectPlugin(config.redirects, hitsPerPass), anchorPinGapPlugin(config.anchorPinGap, [])],
});
writeFileSync(`${config.dist}/meta.json`, JSON.stringify(browserResult.metafile, null, 2) + '\n');

// The Node pass. platform "node" externalises the builtins; everything else is identical,
// INCLUDING the redirect table — so the Node entry is the browser one plus its declared
// conveniences and not a differently-built runtime. DD-5 is easier to believe when the two
// artefacts come out of the same configuration with one field changed.
//
// THE BANNER IS NOT DECORATION. `format: 'esm'` on `platform: 'node'` leaves CommonJS dependencies
// calling `require`, which does not exist in an ES module: esbuild emits a shim that throws
// `Dynamic require of "node:os" is not supported`, and the bundle dies at IMPORT time. Measured —
// `verify_browser_entry_points_are_dd5_shaped` could not read the Node entry's export set at all
// until this was here, which is the useful way to find it, because that check imports the built
// artefact rather than reading its source.
const nodeResult = await esbuild.build({
  ...common,
  // ONLY THE LOGGING STACK IS EXTERNAL, AND THE LIST IS THE END OF A CHAIN OF FAILURES THAT ONLY
  // IMPORTING THE ARTEFACT COULD HAVE PRODUCED.
  //
  // `pino` and its transports are CommonJS, and `thread-stream` resolves its worker as
  // `__dirname + '/lib/worker.js'`. Bundled, that points into `dist/node/` and does not exist — so
  // importing the Node entry read its 91 exports and THEN exited 1 from a `process.nextTick` throw.
  // Node resolves them perfectly well itself; they are the only packages here that reach for a file
  // beside themselves.
  //
  // `packages: 'external'` was tried first and is WRONG for a different reason: it externalises
  // `@aztec/*` too, and the DD-11 redirect table then matches nothing in this pass — the Node entry
  // would resolve `@aztec/foundation`'s eager poseidon at run time and the redirects' own
  // fired-at-least-once guard would be silently vacuous. The narrow list keeps both properties.
  external: ['pino', 'pino-abstract-transport', 'pino-pretty', 'thread-stream', 'sonic-boom'],
  entryPoints: config.nodeEntries,
  platform: 'node',
  outdir: config.nodeDist,
  define: { 'process.env.NODE_ENV': '"production"' },
  // THE BANNER IS THE CJS COMPATIBILITY LAYER AN ESM NODE BUNDLE NEEDS, AND ALL THREE NAMES WERE
  // FOUND BY IMPORTING THE ARTEFACT — one failure at a time, which is the point of importing it.
  //
  //   `require`     `Dynamic require of "node:os" is not supported`
  //   `__dirname`   `ReferenceError: __dirname is not defined in ES module scope`
  //   `__filename`  the same, from the same packages
  //
  // They come from bundled CommonJS dependencies (pino and its transitive set), not from anything
  // this repository wrote. `format: 'esm'` plus `platform: 'node'` is a combination esbuild expects
  // the caller to complete, and this is the completion.
  banner: {
    js: [
      "import { createRequire as __nodeCreateRequire } from 'node:module';",
      "import { fileURLToPath as __nodeFileURLToPath } from 'node:url';",
      "import { dirname as __nodeDirname } from 'node:path';",
      'const require = __nodeCreateRequire(import.meta.url);',
      'const __filename = __nodeFileURLToPath(import.meta.url);',
      'const __dirname = __nodeDirname(__filename);',
    ].join('\n'),
  },
  plugins: [redirectPlugin(config.redirects, hitsPerPass)],
});
writeFileSync(`${config.nodeDist}/meta.json`, JSON.stringify(nodeResult.metafile, null, 2) + '\n');

writeFileSync(
  `${config.dist}/substitution.json`,
  JSON.stringify({ filter: String(FILTER), passes: hitsPerPass }, null, 2) + '\n',
);
