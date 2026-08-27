// Serve the built browser demo, for a person rather than for a check.
//
//   node tools/serve_browser_demo.mjs <site-dir>     (or: just browser-serve)
//
// The same server the checks use — `serveDirectory` in `browser_cdp.mjs` — so the demo a person
// clicks is served with the same `Content-Type`s the harness saw, `application/wasm` included.
// A demo that worked under a different server from the one the checks used would be a demo whose
// green checks say nothing about it.

import { existsSync } from 'node:fs';
import process from 'node:process';

import { serveDirectory } from './browser_cdp.mjs';

const site = process.argv[2];
if (!site || !existsSync(site)) {
  process.stderr.write(
    `serve_browser_demo: no site directory at ${site}.\n` +
      'Remedy: just browser-build && just browser-arms — the arms run assembles the site from the\n' +
      'built bundle plus avm.wasm, ct_writer.wasm and the Token artifact.\n',
  );
  process.exit(2);
}
const server = await serveDirectory(site);
process.stdout.write(`aztec-avm-runtime demo: ${server.origin}\n`);
process.stdout.write('Ctrl-C to stop.\n');
