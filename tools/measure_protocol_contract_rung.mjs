// Does a v6 protocol-contract artifact reach RUNG 1 — a real (path, line, column)
// per pc — through the SHIPPED code path? Measured against
// @aztec-labs/protocol-contracts@6.0.0, the release this tree installs.
//
// This is the control for the claim "source-level debugging is impossible for the
// live chain's transactions". That claim is about the CHAIN not publishing
// artifacts, and it is worth nothing unless the pipeline demonstrably reaches
// rung 1 when an artifact IS in hand.
import { readFileSync } from 'node:fs';
import { inflateRawSync } from 'node:zlib';
import { ContractSourceMap, rungFor } from '/Users/zahary/m/dev/.agent-wt/avm-v6/ct-host/src/source_map.ts';

const ROOT = '/Users/zahary/m/dev/.agent-wt/avm-v6/replay/node_modules/@aztec-labs/protocol-contracts/artifacts';
const RUNG = { 1: 'rung 1 (source)', 2: 'rung 2 (attribution)', 3: 'rung 3 (bytecode)' };

for (const name of ['FeeJuice', 'ContractInstanceRegistry', 'ContractClassRegistry']) {
  const art = JSON.parse(readFileSync(`${ROOT}/${name}.json`, 'utf8'));
  const fn = art.functions.find((f) => f.name === 'public_dispatch');
  if (!fn) { console.log(`${name}: no public_dispatch`); continue; }

  // `debug_symbols` is base64 of RAW DEFLATE, and the payload is
  // `{ debug_infos: [ … ] }` — one entry per function body. Measured rather than
  // assumed: gzip, zlib and brotli all refuse these bytes and `inflateRaw`
  // returns 13,744 bytes of JSON whose first brillig_location key is 130, which
  // is the pc SOURCE-MAPPING.md §7.3 already records for FeeJuice.
  const decoded = JSON.parse(inflateRawSync(Buffer.from(fn.debug_symbols, 'base64')).toString('utf8'));
  const debugInfo = decoded.debug_infos?.[0] ?? decoded;

  // The file map, with SOURCE TEXT — the member whose loss would drop every
  // protocol contract from rung 1 to rung 2 (SOURCE-MAPPING.md §7.4).
  const files = new Map();
  for (const [id, f] of Object.entries(art.file_map ?? {})) {
    files.set(Number(id), { path: f.path, source: f.source });
  }

  const bytecode = Buffer.from(fn.bytecode, 'base64');
  const paths = new Map();
  const map = new ContractSourceMap(debugInfo, bytecode.length, files,
    (p) => { if (!paths.has(p)) paths.set(p, paths.size + 1); return paths.get(p); });

  const v = rungFor(debugInfo, bytecode.length, files);
  const pcs = [...new Set(Object.values(debugInfo.brillig_locations ?? {})
    .flatMap((m) => Object.keys(m).map(Number)))].sort((a, b) => a - b);
  let positioned = 0;
  let first = null;
  for (const pc of pcs) {
    const p = map.positionFor(pc);
    if (p) { positioned += 1; if (!first) first = { pc, ...p }; }
  }
  const firstPath = first ? [...paths.entries()].find(([, id]) => id === first.pathId)?.[0] : null;

  console.log(`${name}:`);
  console.log(`  verdict        ${RUNG[v.rung] ?? v.rung}  (${v.mappedPcs} mapped pcs, range ${JSON.stringify(v.pcRange)})`);
  console.log(`  bytecode       ${bytecode.length} bytes`);
  console.log(`  file_map       ${files.size} files, ${[...files.values()].filter((f) => f.source).length} with source text`);
  console.log(`  pcs positioned ${positioned} / ${pcs.length}`);
  if (first) console.log(`  first position pc ${first.pc} -> ${firstPath} ${first.line}:${first.column}`);
  console.log(`  unrecognised tree nodes ${map.unrecognisedTreeNodes}, locations naming a missing file ${map.missingFileLocations ?? 'n/a'}`);
}
