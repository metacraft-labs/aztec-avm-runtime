#!/usr/bin/env node
// build_browser_bundle.mjs — L4: the replay client, bundled for a browser.
//
// ================================================================================================
// ITS OWN PASS, AND THAT IS A CONTENTION DECISION AS MUCH AS A TECHNICAL ONE.
// ================================================================================================
//
// `browser/build.mjs` builds seven entries in ONE esbuild pass, and its comments explain why each
// was added there rather than beside it: same-pass splitting is what lets one entry's cost be
// compared against another's. **This bundle is deliberately NOT in that pass, for two reasons.**
//
//   1. IT WOULD MOVE EVERY FIGURE IN `BROWSER-PACKAGING.md`. esbuild's splitting is a function of
//      which entries reach which module, so adding one moves every chunk boundary — that document
//      records it happening three times (M29, M32, M33), each time with a table of re-derived
//      numbers. Doing it from a different campaign, while that campaign is being worked on, is the
//      repository-contention hazard this campaign's own milestone file warns about.
//   2. THE COMPARISON THAT JUSTIFIES SAME-PASS DOES NOT APPLY. `wallet` is in the shared pass so
//      `verify_provider_half_dd9_clean` can compare its chunk set against the reference bundle's.
//      Nothing compares the replay client against the reference bundle: it is a different
//      campaign's artefact with a different npm pin, and a shared-chunk comparison between them
//      would be meaningless rather than merely absent.
//
// ================================================================================================
// AND THE PIN IS THE REASON IT COULD NOT SHARE THE PASS EVEN IF IT WANTED TO.
// ================================================================================================
//
// `browser/build.mjs` resolves `@aztec/*` through `orchestration/node_modules` — `pins.json`'s
// `deletion_era` line (5.0.0-nightly.20260626). `replay/` is on `npm.current`
// (5.3.0-nightly.20260819), because L0 established that a client talking to a LIVE chain belongs on
// the line that corresponds to the `cpp` anchor. Building replay through the shared pass would link
// it against the OTHER install, and `replay/package.json` records what that costs:
// `serializeWithMessagePack` recognises an `Fr` by the class object of its own install, so a value
// built in one and serialised by the other goes out as a plain object.
//
// So this pass resolves from `replay/`, and `replay/node_modules` is the only `@aztec` root in the
// graph — which `verify_browser_replay_dd9_clean` asserts rather than assumes.
//
// ================================================================================================
// THE SHIMS ARE REUSED, NOT REWRITTEN.
// ================================================================================================
//
// `@aztec/foundation` and `@aztec/stdlib` import `util`, `assert`, `path`, `fs` and `module` for
// `inspect`, `strict` and `createRequire`. `--platform=browser` makes each one a BUILD ERROR, which
// is the bundler saying DD-5's rule back at you. The shims that answer them already exist in this
// repository — `browser-probe/shims/` and `browser/src/shims/module.js` — and are aliased here
// rather than copied. TWO OF `browser/build.mjs`'S SHIMS ARE DELIBERATELY NOT USED:
// `foundation_promise.ts` and the fee-juice one exist to paper over symbols that are missing on the
// `deletion_era` line and present on `current`. This bundle is on `current`, so it needs neither —
// and needing neither is a small confirmation that the pin is the one intended.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, rmSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPLAY = path.resolve(HERE, '..');
const REPO = path.resolve(REPLAY, '..');

const fail = (m) => { console.error(`build-replay-browser-bundle: ${m}`); process.exit(1); };

// esbuild is NOT installed under replay/ — it exists in this checkout already, and adding a third
// copy for one build is how a repository comes to have three esbuild versions. `browser/build.mjs`
// makes the same choice and looks in the same two places.
const ESBUILD = [
  path.join(REPO, 'spike/node_modules/.bin/esbuild'),
  path.join(REPO, 'diffsim/node_modules/.bin/esbuild'),
].find(existsSync);
if (!ESBUILD) fail('no esbuild in spike/ or diffsim/ node_modules. Remedy: npm ci in one of them.');

if (!existsSync(path.join(REPLAY, 'node_modules/@aztec/stdlib'))) {
  fail(`replay's @aztec packages are not installed. Remedy: cd ${REPLAY} && npm ci`);
}

// Asserted present rather than assumed: a missing alias target makes esbuild resolve the BUILTIN
// NAME as a bare package and fail with a message about npm, which reads like a dependency problem.
const SHIMS = {
  util: path.join(REPO, 'browser-probe/shims/util.js'),
  assert: path.join(REPO, 'browser-probe/shims/assert.js'),
  tty: path.join(REPO, 'browser-probe/shims/tty.js'),
  fs: path.join(REPO, 'browser-probe/shims/fs.js'),
  path: path.join(REPO, 'browser-probe/shims/path.js'),
  module: path.join(REPO, 'browser/src/shims/module.js'),
};
for (const [name, file] of Object.entries(SHIMS)) {
  if (!existsSync(file)) fail(`the shim for '${name}' does not exist: ${file}`);
}

const DIST = path.join(REPLAY, 'dist-browser');
rmSync(DIST, { recursive: true, force: true });
mkdirSync(DIST, { recursive: true });

const OUT = path.join(DIST, 'replay.js');
const META = path.join(DIST, 'meta.json');

const args = [
  path.join(REPLAY, 'src/index.ts'),
  '--bundle',
  '--format=esm',
  '--platform=browser',
  '--minify',
  `--outfile=${OUT}`,
  `--metafile=${META}`,
  ...Object.entries(SHIMS).map(([n, f]) => `--alias:${n}=${f}`),
];

try {
  execFileSync(ESBUILD, args, { stdio: ['ignore', 'inherit', 'inherit'], cwd: REPLAY });
} catch {
  fail('esbuild failed — its output is above');
}

if (!existsSync(OUT)) fail(`esbuild reported success and ${OUT} is not there`);
console.log(`build-replay-browser-bundle: ${OUT} — ${statSync(OUT).size} bytes, metafile at ${META}`);
