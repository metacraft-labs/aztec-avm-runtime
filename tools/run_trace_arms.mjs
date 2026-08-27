// The M25 source-mapping arms, measured ONCE and shared.
//
//   node tools/run_trace_arms.mjs --module <ct_writer.wasm> --artifact <contract.json> --work <dir>
//
// M20's convention, which M22, M23 and M24 all kept: several checks each deriving "the rung this
// contract reached" from their own run is how two checks come to disagree about a number nothing
// changed. This writes `<work>/trace.json` plus the containers, and the checks read it.
//
// A FRESH INSTANCE PER ARM. The module holds one global session; a leaked one puts the previous
// arm's events in this arm's container, which is a silent wrong answer rather than a crash.
//
// THE ARTIFACT IS A REAL AZTEC CONTRACT AND THAT IS THE POINT OF THE WHOLE FILE. Rung 1 is a claim
// about what `avm-transpiler` leaves in a shipped artifact, so it is settled against a shipped
// artifact — `@aztec/noir-test-contracts.js`'s `AvmTest`, at the `deletion_era` pin — and not
// against a fixture this repository authored. An authored fixture would prove that this resolver
// agrees with itself.
//
// `debug_symbols` is raw-DEFLATE + base64 + JSON (`noirc_artifacts/src/debug.rs:257`, mirrored by
// `@aztec/stdlib/abi`'s `parseDebugSymbols`). It is decoded here, in a TOOL, with `node:zlib` —
// deliberately not in `ct-host`, which has no npm dependencies and imports no Node module in its
// trace path, and must go on not doing either for M27 and M28.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { inflateRawSync } from 'node:zlib';
import process from 'node:process';

import {
  ADDRESS_LEN,
  OFF_ADDRESS,
  OFF_L2_GAS,
  OFF_RESERVED,
  RECORD_FIELD_BYTES,
  RECORD_RESERVED_BYTES,
  RECORD_SIZE,
  ContractSourceMap,
  CtWriter,
  MappingRungDegraded,
  ColumnAwarenessUnavailable,
  RUNG_BYTECODE,
  RUNG_FUNCTION,
  RUNG_SOURCE,
  SOURCE_MAPPING_EXPORTS,
  REQUIRED_EXPORTS,
  ALL_REQUIRED_EXPORTS,
  WRITER_PATH_A_PURE_RUST,
  instantiateCtWriter,
  lineColumnOf,
  lineLengths,
  locationsOf,
  resolveTracingConfig,
  rungFor,
} from '../ct-host/src/index.ts';

function arg(name, dflt) {
  const i = process.argv.indexOf(name);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : dflt;
}

const MODULE = arg('--module', 'ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm');
const ARTIFACT = arg('--artifact', '');
const WORK = arg('--work', `${process.env.HOME}/.cache/aztec-m25-trace`);
const RECORDING_ID = '01949fcc-7d92-7e9c-8000-0000000025c7';

mkdirSync(WORK, { recursive: true });
const moduleBytes = readFileSync(MODULE);

// A REAL full-width BN254 field element. Above 2^127, which is exactly the range Noir's
// `FieldElement::to_i128` panics on and M24's low-64 rendering silently truncated.
const FULL_WIDTH_ADDRESS = Uint8Array.from([
  0x2f, 0x1a, 0xbc, 0xde, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
  0xcc, 0xdd, 0xee, 0xff, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c,
]);
const FULL_WIDTH_HEX =
  '0x' + Array.from(FULL_WIDTH_ADDRESS, b => b.toString(16).padStart(2, '0')).join('');

function baseConfig(extra = {}) {
  return {
    program: 'aztec-avm',
    recordingId: RECORDING_ID,
    sourcePath: '/aztec/tx.avm',
    workdir: '/aztec',
    columns: false,
    ...extra,
  };
}

async function newWriter(config, opts = {}) {
  const instance = await instantiateCtWriter(moduleBytes);
  return new CtWriter(instance, config, opts);
}

function stepAt(pc, address) {
  return {
    contextId: 1,
    pc,
    opcode: pc % 200,
    l2Gas: BigInt(1000 + pc),
    daGas: BigInt(pc),
    contractAddress: address,
  };
}

// ---------------------------------------------------------------------------
// The artifact.
// ---------------------------------------------------------------------------

function loadArtifact(path) {
  const artifact = JSON.parse(readFileSync(path, 'utf8'));
  const dispatch = artifact.functions.find(f => f.name === 'public_dispatch');
  if (!dispatch) throw new Error(`${path} has no public_dispatch function`);
  const bytecode = Buffer.from(dispatch.bytecode, 'base64');
  const debugInfo = JSON.parse(
    inflateRawSync(Buffer.from(dispatch.debug_symbols, 'base64')).toString('utf8'),
  ).debug_infos[0];
  const files = new Map();
  for (const [id, entry] of Object.entries(artifact.file_map ?? {})) {
    files.set(Number(id), { path: entry.path, source: entry.source });
  }
  return { name: artifact.name, bytecodeLength: bytecode.length, debugInfo, files };
}

// strideCensus — the gaps between consecutive mapped pcs, as a distribution rather than a range.
//
// Reports the count of gaps, the extremes, and how many fall in the 4..9 band the document used to
// claim ALL of them did. A range is a claim about two numbers; a census is a claim about every one
// of them, and the difference is the whole reason this exists.
function strideCensus(keys) {
  const sorted = [...keys].sort((a, b) => a - b);
  const strides = [];
  for (let i = 1; i < sorted.length; i++) strides.push(sorted[i] - sorted[i - 1]);
  return {
    strideCount: strides.length,
    strideMin: strides.length ? Math.min(...strides) : 0,
    strideMax: strides.length ? Math.max(...strides) : 0,
    stridesInFourToNine: strides.filter(s => s >= 4 && s <= 9).length,
    // STRICTLY increasing is the property that makes "byte offsets" coherent; a repeated or
    // decreasing key would mean the map is not an ordering of the bytecode at all.
    strictlyIncreasing: strides.every(s => s > 0),
  };
}

const out = { module: MODULE, artifactPath: ARTIFACT };

// ---------------------------------------------------------------------------
// ARM: surface — the module's own answers about its source-mapping ABI.
// ---------------------------------------------------------------------------
{
  const instance = await instantiateCtWriter(moduleBytes);
  const ex = instance.exports;
  const exports = WebAssembly.Module.exports(await WebAssembly.compile(moduleBytes))
    .filter(e => e.kind === 'function')
    .map(e => e.name)
    .sort();
  out.surface = {
    recordSize: ex.ct_record_size(),
    positionSize: ex.ct_position_size(),
    // THE LAYOUT, DERIVED FROM THE OFFSETS RATHER THAN RESTATED.
    //
    // `RECORD_FIELD_BYTES` is a typed literal in `abi.ts`, sitting directly above the `OFF_*`
    // constants it is supposed to summarise — which is the exact shape that produced the defect
    // M25 fixed: `TRACE-ABI.md` §7 said 8 reserved and 56 used, `lib.rs`'s header said 56, the
    // layout said 4 and 60, and the only compile-time assertion pinned the TOTAL. `lib.rs` now
    // asserts its two constants against its own offsets; this recomputes the same two figures
    // from the HOST's offsets so the host's literal is compared to something rather than trusted,
    // and so §7's prose has a measurement to be checked against.
    recordFieldBytesDeclared: RECORD_FIELD_BYTES,
    recordReservedBytesDeclared: RECORD_RESERVED_BYTES,
    recordFieldBytesFromOffsets: 4 + 4 + 4 + 8 + 8 + (RECORD_SIZE - OFF_ADDRESS),
    recordReservedBytesFromOffsets: OFF_L2_GAS - OFF_RESERVED,
    writerKind: ex.ct_writer_kind(),
    exportedFunctions: exports.length,
    requiredExports: REQUIRED_EXPORTS.length,
    sourceMappingExports: SOURCE_MAPPING_EXPORTS.length,
    allRequiredExports: ALL_REQUIRED_EXPORTS.length,
    missingFromModule: ALL_REQUIRED_EXPORTS.filter(n => typeof ex[n] !== 'function'),
    // The residue, PRINTED rather than counted: exports the module has that no list names.
    unlistedExports: exports.filter(n => !ALL_REQUIRED_EXPORTS.includes(n)),
  };
}

// ---------------------------------------------------------------------------
// ARM: verdicts — `rungFor` over five artifact shapes, so each rung has a case.
//
// A ladder whose only exercised rung is the top one is a ladder with one step. Four of these five
// are DEGRADED shapes, and each degrades for a different, named reason.
// ---------------------------------------------------------------------------
if (ARTIFACT) {
  const real = loadArtifact(ARTIFACT);
  out.artifact = {
    name: real.name,
    bytecodeLength: real.bytecodeLength,
    fileCount: real.files.size,
    brilligFunctionIds: Object.keys(real.debugInfo.brillig_locations),
    mappedPcs: Object.keys(real.debugInfo.brillig_locations['0'] ?? {}).length,
    // `brillig_procedure_locs` is NOT re-keyed by the transpiler — recorded here so the residual
    // hole OQ-5's verdict names is a measurement rather than a sentence.
    procedureLocMax: Math.max(
      0,
      ...Object.values(real.debugInfo.brillig_procedure_locs?.['0'] ?? {}).flat().map(Number),
    ),
    // THE STRIDE CENSUS, ADDED BY M25'S REVIEW BECAUSE THE DOCUMENT STATED A RANGE NOTHING
    // RE-DERIVED AND THE RANGE WAS WRONG. SOURCE-MAPPING.md 2.2 said the keys advance "in strides
    // of 4-9"; the fifteen keys it prints two lines above contain a stride of 18 (772 -> 790), and
    // over the whole map the strides run to 410. The five figures beside it were all re-derived and
    // all correct — this was the one that was not, which is this campaign's "a figure nobody
    // re-derives rots" exactly.
    //
    // What actually carries the verdict is not the range but the SHAPE: sparse, strictly
    // increasing, and bounded above by the bytecode length. Those are asserted separately. This
    // block exists so the document can state a stride fact that is true and checked.
    ...strideCensus(Object.keys(real.debugInfo.brillig_locations['0'] ?? {}).map(Number)),
  };

  const verdicts = {};
  verdicts.real = rungFor(real.debugInfo, real.bytecodeLength, real.files);
  verdicts.noDebugInfo = rungFor(null, real.bytecodeLength, real.files);
  verdicts.emptyLocations = rungFor({ brillig_locations: { 0: {} } }, real.bytecodeLength, real.files);
  // A map still keyed by Brillig OPCODE INDEX would have a maximum far below the bytecode length;
  // one keyed past the end of the bytecode cannot be byte offsets at all. Both are wrong and only
  // the second is detectable from the artifact alone, so that is the one asserted.
  verdicts.keyedPastEnd = rungFor(
    { brillig_locations: { 0: { [String(real.bytecodeLength + 1)]: 1 } } },
    real.bytecodeLength,
    real.files,
  );
  verdicts.noSourceText = rungFor(real.debugInfo, real.bytecodeLength, new Map());
  out.verdicts = verdicts;

  // ---------------------------------------------------------------------------
  // ARM: rung1 — a real recording at rung 1, over the artifact's OWN pcs.
  //
  // The pcs are taken FROM the artifact rather than invented, which is the difference between
  // exercising the resolver and exercising a fixture: a pc this map does not know about would
  // produce `null` and the arm would pass by not resolving anything.
  // ---------------------------------------------------------------------------
  {
    const cfg = resolveTracingConfig(baseConfig({ columns: true, mappingRung: RUNG_SOURCE }), WRITER_PATH_A_PURE_RUST);
    const w = await newWriter(cfg, { batchRecords: 64 });
    const map = new ContractSourceMap(real.debugInfo, real.bytecodeLength, real.files, (p, ll) =>
      w.internPath(p, ll),
    );
    w.declareRung(FULL_WIDTH_ADDRESS, RUNG_SOURCE, map.verdict.reason);
    const pcs = Object.keys(real.debugInfo.brillig_locations['0'])
      .map(Number)
      .sort((a, b) => a - b)
      .slice(0, 200);
    const resolved = [];
    let unresolved = 0;
    for (const pc of pcs) {
      const pos = map.positionFor(pc);
      if (pos === null) {
        unresolved += 1;
        w.push(stepAt(pc, FULL_WIDTH_ADDRESS));
      } else {
        resolved.push({ pc, ...pos });
        w.push(stepAt(pc, FULL_WIDTH_ADDRESS), pos);
      }
    }
    let rec = null;
    let threw = null;
    try {
      rec = w.close();
      writeFileSync(`${WORK}/rung1.ct`, rec.container);
    } catch (e) {
      threw = { name: e?.constructor?.name ?? 'unknown', message: String(e?.message ?? e) };
    }
    out.rung1 = {
      verdict: map.verdict,
      pcsDriven: pcs.length,
      resolvedCount: resolved.length,
      unresolvedCount: unresolved,
      unrecognisedTreeNodes: map.unrecognisedTreeNodes,
      missingFileReferences: map.missingFileReferences,
      firstResolved: resolved.slice(0, 5),
      threw,
      container: rec ? `${WORK}/rung1.ct` : null,
      containerBytes: rec ? rec.container.length : 0,
      events: rec?.events ?? 0,
      mappingRung: rec?.mappingRung ?? null,
      rungsDeclared: rec?.rungsDeclared ?? 0,
      stepsPositioned: rec?.stepsPositioned ?? 0,
      stepsUnpositioned: rec?.stepsUnpositioned ?? 0,
      rungViolations: rec?.rungViolations ?? 0,
      pathsInterned: rec?.pathsInterned ?? 0,
      columnsRequested: rec?.columnsRequested ?? null,
      droppedColumnAwareness: rec?.droppedColumnAwareness ?? null,
      crossings: rec?.crossings ?? 0,
    };
  }

  // ---------------------------------------------------------------------------
  // ARM: degraded — the SAME rung-1 declaration with no positions supplied.
  //
  // This is the milestone's headline property and it is a POSITIVE test of a refusal: without it,
  // "never silently degrades" is a sentence in a document.
  // ---------------------------------------------------------------------------
  {
    const cfg = resolveTracingConfig(baseConfig({ mappingRung: RUNG_SOURCE }), WRITER_PATH_A_PURE_RUST);
    const w = await newWriter(cfg, { batchRecords: 64 });
    w.declareRung(FULL_WIDTH_ADDRESS, RUNG_SOURCE, 'claimed without resolving anything');
    for (const pc of [706, 715, 720]) w.push(stepAt(pc, FULL_WIDTH_ADDRESS));
    let threw = null;
    let rec = null;
    try {
      rec = w.close();
    } catch (e) {
      threw = {
        name: e?.constructor?.name ?? 'unknown',
        isMappingRungDegraded: e instanceof MappingRungDegraded,
        violations: e?.violations ?? null,
        firstViolationPc: e?.firstViolationPc ?? null,
        stepsPositioned: e?.stepsPositioned ?? null,
        stepsUnpositioned: e?.stepsUnpositioned ?? null,
        message: String(e?.message ?? e),
      };
    }
    out.degraded = { threw, closedAnyway: rec !== null };
  }

  // ---------------------------------------------------------------------------
  // ARM: rung3 — THE CONTROL FOR `degraded`.
  //
  // Identical steps, identical absence of positions, a rung-3 declaration instead of a rung-1 one.
  // It must close cleanly. Without this arm, `degraded`'s throw could be caused by anything about
  // an unpositioned step rather than by the declaration it contradicts.
  // ---------------------------------------------------------------------------
  {
    const cfg = resolveTracingConfig(baseConfig({ mappingRung: RUNG_BYTECODE }), WRITER_PATH_A_PURE_RUST);
    const w = await newWriter(cfg, { batchRecords: 64 });
    w.declareRung(FULL_WIDTH_ADDRESS, RUNG_BYTECODE, 'no artifact was supplied for this contract');
    for (const pc of [706, 715, 720]) w.push(stepAt(pc, FULL_WIDTH_ADDRESS));
    const rec = w.close();
    writeFileSync(`${WORK}/rung3.ct`, rec.container);
    out.rung3 = {
      container: `${WORK}/rung3.ct`,
      containerBytes: rec.container.length,
      events: rec.events,
      mappingRung: rec.mappingRung,
      rungsDeclared: rec.rungsDeclared,
      stepsPositioned: rec.stepsPositioned,
      stepsUnpositioned: rec.stepsUnpositioned,
      rungViolations: rec.rungViolations,
      crossings: rec.crossings,
    };
  }
}

// ---------------------------------------------------------------------------
// ARM: columnGate — the DD-7 gate, now a function of the rung.
// ---------------------------------------------------------------------------
{
  const gate = {};
  for (const [label, rung] of [
    ['rung1', RUNG_SOURCE],
    ['rung2', RUNG_FUNCTION],
    ['rung3', RUNG_BYTECODE],
    ['unset', undefined],
    // A rung smuggled past the erased type. The gate is a value comparison, so this must NOT
    // become rung 1 — it must fall to the pessimistic end.
    ['stringOne', '1'],
    ['four', 4],
  ]) {
    try {
      const cfg = resolveTracingConfig(
        baseConfig({ columns: true, mappingRung: rung }),
        WRITER_PATH_A_PURE_RUST,
      );
      gate[label] = { threw: false, resolvedRung: cfg.mappingRung, columns: cfg.columns };
    } catch (e) {
      gate[label] = {
        threw: true,
        kind: e?.constructor?.name ?? 'unknown',
        isColumnAwarenessUnavailable: e instanceof ColumnAwarenessUnavailable,
        rung: e?.mappingRung ?? null,
        message: String(e?.message ?? e),
      };
    }
  }
  // …and the same rungs with columns OFF, so a refusal above is attributable to the COLUMN request
  // rather than to the rung on its own.
  const noColumns = {};
  for (const [label, rung] of [['rung1', RUNG_SOURCE], ['rung3', RUNG_BYTECODE]]) {
    const cfg = resolveTracingConfig(baseConfig({ columns: false, mappingRung: rung }), WRITER_PATH_A_PURE_RUST);
    noColumns[label] = { resolvedRung: cfg.mappingRung, columns: cfg.columns };
  }
  out.columnGate = { withColumns: gate, withoutColumns: noColumns };
}

// ---------------------------------------------------------------------------
// ARM: fieldRendering — OQ-4, written out so a READER can be asked what it decoded.
//
// The container is what the check runs `ct-print` over. Asserting the hex string here would be
// asserting that this file agrees with itself.
// ---------------------------------------------------------------------------
{
  const cfg = resolveTracingConfig(baseConfig(), WRITER_PATH_A_PURE_RUST);
  const w = await newWriter(cfg, { batchRecords: 8 });
  w.push(stepAt(11, FULL_WIDTH_ADDRESS));
  const rec = w.close();
  writeFileSync(`${WORK}/field.ct`, rec.container);
  out.fieldRendering = {
    container: `${WORK}/field.ct`,
    containerBytes: rec.container.length,
    expectedHex: FULL_WIDTH_HEX,
    expectedHexLength: FULL_WIDTH_HEX.length,
    // What M24 recorded for the same address, kept so the replacement is a delta and not a claim.
    m24LowSixtyFour: (() => {
      let low = 0n;
      for (let i = 0; i < 8; i++) low |= BigInt(FULL_WIDTH_ADDRESS[31 - i]) << BigInt(8 * i);
      return low.toString();
    })(),
  };
}

// ---------------------------------------------------------------------------
// ARM: desync — more positions than steps must be refused, not absorbed.
// ---------------------------------------------------------------------------
{
  const cfg = resolveTracingConfig(baseConfig({ mappingRung: RUNG_SOURCE }), WRITER_PATH_A_PURE_RUST);
  const w = await newWriter(cfg, { batchRecords: 64 });
  const id = w.internPath('/aztec/token.nr', lineLengths('a\nbb\nccc\n'));
  w.push(stepAt(1, FULL_WIDTH_ADDRESS), { pathId: id, line: 1, column: 1 });
  w.flush();
  // One extra position, handed straight to the module with no step behind it.
  const ex = w['ex'];
  const ptr = ex.ct_alloc(16);
  const view = new DataView(ex.memory.buffer);
  view.setUint32(ptr + 0, id, true);
  view.setUint32(ptr + 4, 9, true);
  view.setUint32(ptr + 8, 1, true);
  view.setUint32(ptr + 12, 0, true);
  const accepted = ex.ct_positions(ptr, 16);
  let threw = null;
  try {
    w.close();
  } catch (e) {
    threw = { name: e?.constructor?.name ?? 'unknown', message: String(e?.message ?? e) };
  }
  out.desync = { accepted, pendingBeforeClose: 1, threw };
}

// ---------------------------------------------------------------------------
// ARM: unit — the two pure functions, on inputs whose answers are checkable by hand.
// ---------------------------------------------------------------------------
{
  const src = 'let a = 1;\nlet bb = 22;\n\nlet ccc = 333;\n';
  out.unit = {
    lineLengths: lineLengths(src),
    // Offsets chosen at the start of each line and mid-line, so a column error of one shows.
    at0: lineColumnOf(src, 0),
    at4: lineColumnOf(src, 4),
    at11: lineColumnOf(src, 11),
    at24: lineColumnOf(src, 24),
    atEnd: lineColumnOf(src, src.length),
    // Past the end is clamped rather than throwing: a debug span pointing outside a file is an
    // artifact defect, and a resolver that throws on one loses the whole recording.
    pastEnd: lineColumnOf(src, src.length + 1000),
    // Non-ASCII: Noir's span is a BYTE offset and a JS string is UTF-16, so byte offset 2 lands
    // AFTER the two-byte 'é' — column 2. Both answers are computed rather than described, because
    // upstream's own TypeScript resolver (`simulator/src/common/errors.ts:120-127`) uses
    // `substring` and would answer the other one, and "these differ" is a measurement.
    utf8: lineColumnOf('é = 1;\n', 2),
    utf8NaiveUtf16Column: 'é = 1;\n'.substring(0, 2).length + 1,
    treeUnrecognised: locationsOf({ nope: 1 }, 0),
    treeEmpty: locationsOf(null, 0),
    treeOutOfRange: locationsOf({ locations: [{ parent: null, value: { span: { start: 0, end: 0 }, file: 0 } }] }, 99),
    treeChain: locationsOf(
      {
        locations: [
          { parent: null, value: { span: { start: 0, end: 1 }, file: 7 } },
          { parent: 0, value: { span: { start: 5, end: 9 }, file: 8 } },
        ],
      },
      1,
    ),
  };
}

writeFileSync(`${WORK}/trace.json`, JSON.stringify(out, null, 2));
console.log(`run_trace_arms: wrote ${WORK}/trace.json`);
