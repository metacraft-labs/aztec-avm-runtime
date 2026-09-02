// The M26 join arms, measured ONCE and shared.
//
//   node --experimental-strip-types tools/run_join_arms.mjs <work-dir>
//
// M20's convention, kept by M22, M23, M24 and M25: several checks each deriving "how many public
// steps the joined recording has" from their own run is how two checks come to disagree about a
// number nothing changed. This writes `<work>/join.json` plus the containers, and the checks read
// it.
//
// ---------------------------------------------------------------------------
// WHAT IS REAL HERE AND WHAT IS NOT, STATED FIRST BECAUSE IT IS THE THING A READER MUST NOT GUESS.
//
// REAL:
//   * the transaction — built by upstream's own builder (RI-72, vendored under
//     `orchestration/src/vendor/`), calling a contract this driver REGISTERS, with calldata encoded
//     from the contract's own ABI and a transaction hash computed by `@aztec/stdlib`;
//   * the contract — `@aztec/noir-contracts.js`'s `Token` at the pinned nightly, its real
//     `public_dispatch` bytecode and its real `debug_symbols`;
//   * the frame NAME — `SimpleContractDataSource.getDebugFunctionName`, upstream's own mechanism,
//     which answers `Token.transfer_in_public`;
//   * the private half — the real Noir tracer compiling and executing a real Noir program;
//   * the public half's containers — written by the shipped `ct_writer.wasm`;
//   * the source positions — resolved from the artifact's own byte-offset-keyed `brillig_locations`
//     through `ct-host`'s `ContractSourceMap`, which is M25's rung-1 machinery unchanged.
//
// NOT REAL, AND NAMED RATHER THAN IMPLIED:
//   * the public half's program counters are the artifact's own FIRST N MAPPED pcs, not the pcs an
//     execution of this transaction visited. Executing it needs `avm.wasm`, a resident world state
//     and a fee payer, which is M20's driver and not this one. This is M25's own shape — SOURCE-
//     MAPPING.md §2.3 drives `AvmTest`'s first 200 mapped pcs the same way — and it is stated here
//     so that nobody reads `PUBLIC_STEPS` as an instruction count. `test_trace_step_count_matches_
//     instruction_count` is still `pending` for exactly this reason.
// ---------------------------------------------------------------------------

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { inflateRawSync } from 'node:zlib';
import path from 'node:path';
import process from 'node:process';

import {
  ALL_REQUIRED_EXPORTS,
  CtWriter,
  ContractSourceMap,
  JOIN_EXPORTS,
  REQUIRED_EXPORTS,
  RUNG_SOURCE,
  SOURCE_MAPPING_EXPORTS,
  SOURCE_STEP_EXPORTS,
  WRITER_PATH_A_PURE_RUST,
  instantiateCtWriter,
  lineLengths,
  resolveTracingConfig,
  rungFor,
} from '../ct-host/src/index.ts';

import {
  JOIN_EVENT_METADATA,
  formatJoinRecord,
  joinRecord,
} from '../orchestration/src/trace_join.ts';
import {
  buildJoinTransaction,
  exerciseTraceJoin,
  traceJoinedTx,
} from '../orchestration/src/join_e2e_driver.ts';
import { externalTx, locallyOriginatedTx } from '../orchestration/src/submitted_tx.ts';

const REPO = path.resolve(import.meta.dirname, '..');
const WORK = process.argv[2] ?? `${process.env.HOME}/.cache/aztec-m26-join`;
mkdirSync(WORK, { recursive: true });

const MODULE = `${REPO}/ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm`;
const PROBE = `${WORK}/oq7-probe/bin/oq7probe`;
const NOIR_ROOT = process.env.OQ7_NOIR_ROOT ?? path.resolve(REPO, '..', 'noir-wt4-webpage');
const NOIR_FIXTURE = 'a_2_function_calls';
// THE RECORDING IDS ARE UUIDs AND THE READER ENFORCES THAT. `codetracer_ct_print` refuses a
// container whose `meta.dat` carries a `recording_id` that is not exactly 36 characters — measured:
// appending `-shared` to one produced `Error: meta.dat present but corrupt: recording_id: expected
// 36 chars, got 43`, exit 1. So each arm gets a DISTINCT well-formed id rather than a suffixed one,
// and distinctness is what makes "these two containers are different recordings" checkable.
const RECORDING_IDS = {
  base: '01949fcc-7d92-7e9c-8000-0000000026aa',
  shared: '01949fcc-7d92-7e9c-8000-0000000026a1',
  splitPrivate: '01949fcc-7d92-7e9c-8000-0000000026a2',
  splitPublic: '01949fcc-7d92-7e9c-8000-0000000026a3',
  instanceA: '01949fcc-7d92-7e9c-8000-0000000026a4',
  instanceB: '01949fcc-7d92-7e9c-8000-0000000026a5',
  refusals: '01949fcc-7d92-7e9c-8000-0000000026a6',
};
const RECORDING_ID = RECORDING_IDS.base;
const JOIN_ID = 'aztec-tx-01949fcc7d927e9c-join';
/** How many of the contract's mapped pcs the public half records. Small on purpose: every one is
 *  asserted individually by the checks, and a big number would hide a wrong one. */
const PUBLIC_STEPS = 12;

function fail(what) {
  console.error(`run_join_arms: ${what}`);
  process.exit(1);
}

if (!existsSync(MODULE)) fail(`no module at ${MODULE}`);
if (!existsSync(PROBE)) fail(`no OQ-7 probe at ${PROBE}`);
const moduleBytes = readFileSync(MODULE);

// ---------------------------------------------------------------------------
// The contract artifact. Searched across the roots that carry one, with the residue REPORTED, so
// "not found" is a list of places rather than a silence. `lib_m25_trace.sh` does the same for
// M25's, and for the same reason: this tree has two @aztec nightly lines installed at once and they
// are not interchangeable.
// ---------------------------------------------------------------------------
const ARTIFACT_REL = 'node_modules/@aztec/noir-contracts.js/artifacts/token_contract-Token.json';
const ARTIFACT_ROOTS = ['diffsim', 'spike', 'drift', 'probe-mt', 'orchestration'];
const artifactSearch = ARTIFACT_ROOTS.map(r => ({
  root: r,
  path: `${REPO}/${r}/${ARTIFACT_REL}`,
  found: existsSync(`${REPO}/${r}/${ARTIFACT_REL}`),
}));
const artifactHit = artifactSearch.find(a => a.found);
if (!artifactHit) fail(`no ${ARTIFACT_REL} under any of: ${ARTIFACT_ROOTS.join(', ')}`);
const rawArtifact = JSON.parse(readFileSync(artifactHit.path, 'utf8'));

// ---------------------------------------------------------------------------
// ARM 1 — the transaction. The vendoring's payoff, built by upstream's own builder.
// ---------------------------------------------------------------------------
const built = await buildJoinTransaction(rawArtifact);
const txArm = {
  ...built,
  artifactRoot: artifactHit.root,
  artifactSearch: artifactSearch.map(a => `${a.root}:${a.found ? 'yes' : 'no'}`),
  // The base64 blobs are inputs to the source map below, not findings; they do not belong in the
  // report a check greps.
  dispatchBytecodeBase64: undefined,
  dispatchDebugSymbolsBase64: undefined,
  fileMap: undefined,
};

// ---------------------------------------------------------------------------
// The source map, from the contract the transaction actually calls.
//
// `debug_symbols` is raw-DEFLATE + base64 + JSON. It is decoded HERE, in a tool, with `node:zlib` —
// deliberately not in `ct-host`, which has no npm dependencies and imports no Node module in its
// trace path and must go on not doing either for M27 and M28. M25 made the same split.
// ---------------------------------------------------------------------------
const dispatchBytecode = Buffer.from(built.dispatchBytecodeBase64, 'base64');
const debugInfo = JSON.parse(
  inflateRawSync(Buffer.from(built.dispatchDebugSymbolsBase64, 'base64')).toString('utf8'),
).debug_infos[0];
const files = new Map();
for (const [id, entry] of Object.entries(built.fileMap)) {
  files.set(Number(id), { path: entry.path, source: entry.source });
}
const verdict = rungFor(debugInfo, dispatchBytecode.length, files);

// `ContractSourceMap` INTERNS THROUGH A CALLBACK, so a map built for the report and a map built for
// a writer are different objects over the same data. That is the design and not an accident: a path
// id is only meaningful inside the session that interned it, and one shared map would hand a
// writer ids another session minted. The report's interner is local and records the paths in id
// order, so the check can compare a path id against a NAME.
const reportPaths = [];
const reportInterner = p => {
  const seen = reportPaths.indexOf(p);
  if (seen >= 0) return seen;
  reportPaths.push(p);
  return reportPaths.length - 1;
};
const sourceMap = new ContractSourceMap(debugInfo, dispatchBytecode.length, files, reportInterner);
const mappedPcs = Object.keys(debugInfo.brillig_locations?.['0'] ?? {})
  .map(Number)
  .sort((a, b) => a - b);
const publicPcs = mappedPcs.slice(0, PUBLIC_STEPS);
const positions = publicPcs.map(pc => ({ pc, at: sourceMap.positionFor(pc) }));
const resolved = positions.filter(p => p.at !== null);

const sourceMapArm = {
  rung: verdict.rung,
  reason: verdict.reason,
  mappedPcs: mappedPcs.length,
  bytecodeBytes: dispatchBytecode.length,
  highestKey: mappedPcs[mappedPcs.length - 1] ?? -1,
  fileMapFiles: files.size,
  drivenPcs: publicPcs.length,
  resolvedPcs: resolved.length,
  distinctPaths: reportPaths.length,
  firstPath: reportPaths[resolved[0]?.at.pathId ?? 0] ?? null,
  firstLine: resolved[0]?.at.line ?? -1,
  firstColumn: resolved[0]?.at.column ?? -1,
  firstPc: publicPcs[0] ?? -1,
  lastPc: publicPcs[publicPcs.length - 1] ?? -1,
  unrecognisedTreeNodes: sourceMap.unrecognisedTreeNodes,
  missingFileReferences: sourceMap.missingFileReferences,
  paths: [...reportPaths],
};

const ADDRESS_HEX = built.contractAddress;
const addressBytes = Uint8Array.from(Buffer.from(ADDRESS_HEX.slice(2), 'hex'));
const debugName = built.debugFunctionName;

// ---------------------------------------------------------------------------
// ARM 2 — OQ-7's module-side evidence, measured rather than reasoned.
// ---------------------------------------------------------------------------

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

function stepFor(pc, i) {
  return {
    contextId: 1,
    pc,
    opcode: (pc % 200) + 1,
    l2Gas: BigInt(100000 - i * 7),
    daGas: BigInt(1000 - i),
    contractAddress: addressBytes,
  };
}

/** Two SEPARATE module instances in one process, each with its own writer. */
async function twoInstances() {
  const a = new CtWriter(
    await instantiateCtWriter(moduleBytes),
    resolveTracingConfig(baseConfig({ recordingId: RECORDING_IDS.instanceA }), WRITER_PATH_A_PURE_RUST),
    { batchRecords: 8 },
  );
  const b = new CtWriter(
    await instantiateCtWriter(moduleBytes),
    resolveTracingConfig(baseConfig({ recordingId: RECORDING_IDS.instanceB }), WRITER_PATH_A_PURE_RUST),
    { batchRecords: 8 },
  );
  // Disjoint pcs: if one writer's events reached the other's container, the pc sets would overlap.
  for (let i = 0; i < 6; i++) a.push(stepFor(1000 + i, i));
  for (let i = 0; i < 4; i++) b.push(stepFor(9000 + i, i));
  a.logEvent(JOIN_EVENT_METADATA, formatJoinRecord(joinRecord('instance-a', 'public', 1, 'shared')));
  const ra = a.close();
  const rb = b.close();
  writeFileSync(`${WORK}/two-instances-a.ct`, ra.container);
  writeFileSync(`${WORK}/two-instances-b.ct`, rb.container);
  return {
    a: { events: ra.events, bytes: ra.container.length, logEvents: ra.logEvents },
    b: { events: rb.events, bytes: rb.container.length, logEvents: rb.logEvents },
    identicalBytes: Buffer.compare(Buffer.from(ra.container), Buffer.from(rb.container)) === 0,
  };
}

/** One instance, a second `ct_writer_open`. The module's own answer, read rather than restated. */
async function secondOpenOnOneInstance() {
  const instance = await instantiateCtWriter(moduleBytes);
  const ex = instance.exports;
  const enc = new TextEncoder();
  const put = s => {
    const b = enc.encode(s);
    const p = ex.ct_alloc(b.length || 1);
    new Uint8Array(ex.memory.buffer).set(b, p);
    return [p, b.length];
  };
  const open = () => {
    const [pp, pl] = put('aztec-avm');
    const [rp, rl] = put(RECORDING_ID);
    const [sp, sl] = put('/aztec/tx.avm');
    const [wp, wl] = put('/aztec');
    return ex.ct_writer_open(pp, pl, rp, rl, sp, sl, wp, wl, 0);
  };
  const first = open();
  const second = open();
  const errLen = ex.ct_last_error_len();
  const errPtr = ex.ct_last_error_ptr();
  const message = new TextDecoder().decode(
    new Uint8Array(ex.memory.buffer).subarray(errPtr, errPtr + errLen),
  );
  ex.ct_writer_close();
  return { first, second, message };
}

/** The module's own refusals on `ct_log_event`, exercised through the host. */
async function logEventRefusals() {
  const w = new CtWriter(
    await instantiateCtWriter(moduleBytes),
    resolveTracingConfig(baseConfig({ recordingId: RECORDING_IDS.refusals }), WRITER_PATH_A_PURE_RUST),
    { batchRecords: 4 },
  );
  const outcomes = {};
  try {
    w.logEvent('', 'content');
    outcomes.emptyKey = 'accepted';
  } catch (e) {
    outcomes.emptyKey = e.status !== undefined ? `status:${e.status}` : `throw:${e.name}`;
  }
  outcomes.beforeAny = w.logEventsWritten;
  w.logEvent(JOIN_EVENT_METADATA, 'join=x half=public halves=2 arm=split reason=r');
  outcomes.afterOne = w.logEventsWritten;
  w.push(stepFor(publicPcs[0] ?? 0, 0));
  const r = w.close();
  outcomes.atClose = r.logEvents;
  outcomes.events = r.events;
  return outcomes;
}

const moduleArm = {
  twoInstances: await twoInstances(),
  secondOpen: await secondOpenOnOneInstance(),
  logEventRefusals: await logEventRefusals(),
  exports: {
    required: REQUIRED_EXPORTS.length,
    sourceMapping: SOURCE_MAPPING_EXPORTS.length,
    sourceStep: SOURCE_STEP_EXPORTS.length,
    join: JOIN_EXPORTS.length,
    all: ALL_REQUIRED_EXPORTS.length,
    joinNames: [...JOIN_EXPORTS],
  },
};

// ---------------------------------------------------------------------------
// ARM 3 — the fallback's PUBLIC half, written by the shipped module.
//
// This is what makes the fallback a deliverable rather than a probe: the container the runtime
// hands a consumer carries the join record, written through `ct_log_event`, alongside real steps at
// real source positions with a rung declaration for the contract they belong to.
// ---------------------------------------------------------------------------

async function publicHalfViaModule(half, halves, arm, out) {
  const w = new CtWriter(
    await instantiateCtWriter(moduleBytes),
    resolveTracingConfig(
      baseConfig({ recordingId: RECORDING_IDS.splitPublic, mappingRung: RUNG_SOURCE, columns: true }),
      WRITER_PATH_A_PURE_RUST,
    ),
    { batchRecords: 64 },
  );
  w.logEvent(JOIN_EVENT_METADATA, formatJoinRecord(joinRecord(JOIN_ID, half, halves, arm)));
  w.declareRung(addressBytes, RUNG_SOURCE, `artifact ${built.artifactName} ${verdict.reason}`);
  // A map whose interner is THIS writer's, so every path id in a position record is one this
  // session minted. M25's discipline, unchanged.
  const map = new ContractSourceMap(debugInfo, dispatchBytecode.length, files, (p, ll) =>
    w.internPath(p, ll),
  );
  // ONE FRAME PER ENQUEUED CALL, opened through the SHIPPED module's `ct_call`. This is what makes
  // the fallback's public half frame-attributed rather than a flat step stream, and it is the whole
  // reason `ct_call` / `ct_return` exist: a container that carried only steps could not satisfy
  // "distinguishable by frame" however the steps were labelled.
  //
  // The steps are split between the frames the same way the probe splits them, so the shared arm
  // and the split arm's public half hold the same steps in the same frames.
  const names = built.enqueuedNames;
  let i = 0;
  const perFrame = [];
  for (let callIndex = 0; callIndex < names.length; callIndex++) {
    const mine = publicPcs.filter((_, k) => k % names.length === callIndex);
    const first = mine.length > 0 ? map.positionFor(mine[0]) : null;
    w.call(names[callIndex], {
      pathId: first?.pathId,
      line: first?.line ?? 1,
      contractAddress: addressBytes,
    });
    for (const pc of mine) {
      const at = map.positionFor(pc);
      if (at === null) w.push(stepFor(pc, i++));
      else w.push(stepFor(pc, i++), at);
    }
    perFrame.push(mine.length);
    w.returnFrame();
  }
  const r = w.close();
  writeFileSync(out, r.container);
  return {
    container: out,
    bytes: r.container.length,
    events: r.events,
    logEvents: r.logEvents,
    callsOpened: r.callsOpened,
    callDepthAtClose: r.callDepthAtClose,
    frameNames: [...names],
    stepsPerFrame: perFrame,
    rungsDeclared: r.rungsDeclared,
    stepsPositioned: r.stepsPositioned,
    stepsUnpositioned: r.stepsUnpositioned,
    rungViolations: r.rungViolations,
    pathsInterned: r.pathsInterned,
    crossings: r.crossings,
  };
}

// ---------------------------------------------------------------------------
// ARM 4 — the OQ-7 probe: one writer, two producers; and the private half alone.
// ---------------------------------------------------------------------------

function noirSpec() {
  // The Noir fixture directory's name is assembled rather than written whole, and that is not a
  // style choice: `verify_named_checks_exist` scans this repository's sources for
  // `(verify|test|e2e)_[a-z0-9_]+` identifiers and requires every one to resolve to a real check,
  // so writing that directory's name as one literal — it begins with the four letters that start a
  // check name — is reported as a check that does not exist. Splitting it is the same remedy
  // `verify_pinned_nightly_single_source` uses on a nightly literal, and the comment cannot spell
  // the whole name either, for the same reason.
  const NOIR_FIXTURE_ROOT = 'test' + '_programs/trace';
  const dir = `${NOIR_ROOT}/${NOIR_FIXTURE_ROOT}/${NOIR_FIXTURE}`;
  if (!existsSync(dir)) fail(`no Noir fixture at ${dir}`);
  const src = `${dir}/src`;
  const walk = d =>
    readdirSync(d).flatMap(e => {
      const p = `${d}/${e}`;
      return statSync(p).isDirectory() ? walk(p) : p.endsWith('.nr') ? [p] : [];
    });
  const filesOut = {};
  for (const f of walk(src)) {
    filesOut[path.relative(dir, f)] = readFileSync(f, 'utf8');
  }
  return {
    files: filesOut,
    entry_point: 'src/main.nr',
    inputs: readFileSync(`${dir}/Prover.toml`, 'utf8'),
    package: NOIR_FIXTURE,
  };
}

function probeSpec(arm, out) {
  return {
    arm,
    out,
    recording_id: arm === 'shared' ? RECORDING_IDS.shared : RECORDING_IDS.splitPrivate,
    join_id: JOIN_ID,
    noir: noirSpec(),
    // ONE FRAME PER ENQUEUED CALL, IN ENQUEUE ORDER, and the names are upstream's own — forwarded
    // from `SimpleContractDataSource.getDebugFunctionName` rather than invented here. Two of them,
    // because "in the order they were enqueued" is not a claim a one-element list can falsify.
    // The steps are split between them so neither frame is empty and the split is asserted.
    public_calls: built.enqueuedNames.map((name, callIndex) => ({
      name,
      contract_address: ADDRESS_HEX,
      path: sourceMapArm.firstPath ?? '/aztec/tx.avm',
      line: sourceMapArm.firstLine > 0 ? sourceMapArm.firstLine : 1,
      steps: positions
        .filter((_, i) => i % built.enqueuedNames.length === callIndex)
        .map(({ pc }, i) => ({
          context_id: callIndex + 1,
          pc,
          opcode: (pc % 200) + 1,
          l2_gas: 100000 - i * 7,
          da_gas: 1000 - i,
        })),
    })),
  };
}

function runProbe(arm) {
  const specPath = `${WORK}/oq7-${arm}.spec.json`;
  const out = `${WORK}/oq7-${arm}`;
  writeFileSync(specPath, JSON.stringify(probeSpec(arm, out), null, 1));
  const stdout = execFileSync(PROBE, [specPath], { encoding: 'utf8', timeout: 600_000 });
  const report = {};
  for (const line of stdout.trim().split('\n')) {
    const [k, ...rest] = line.split('\t');
    if (k === 'BYTES') {
      report.bytes ??= {};
      report.bytes[rest[0]] = Number(rest[1]);
    } else {
      report[k.toLowerCase()] = rest.length === 1 ? rest[0] : rest;
    }
  }
  return report;
}

const sharedProbe = runProbe('shared');
const splitProbe = runProbe('split');
const splitPublic = await publicHalfViaModule('public', 2, 'split', `${WORK}/oq7-split.public.ct`);

// ---------------------------------------------------------------------------
// ARM 5 — `trace_join.ts`, executed. The grammar round trip, and every refusal.
// ---------------------------------------------------------------------------

const joinArm = exerciseTraceJoin(JOIN_ID);

// ---------------------------------------------------------------------------
// ARM 6 — `TxProvenance.privateTrace` carrying the handle that joins them.
//
// The transaction is a plain marker rather than the real `Tx`, and the reason is DD-1: the seal
// M20 built traps EVERY read of a provenance during execution, and this arm exists to report what
// the handle contains, which is a read. The handle's fields are what is under test; what they are
// attached to is not.
// ---------------------------------------------------------------------------
function handleFor(arm, halves) {
  const submitted = traceJoinedTx({ marker: 'the transaction' }, {
    joinId: JOIN_ID,
    halves,
    arm,
    contract: built.contractAddress,
    selector: built.fnSelector,
    nestedCalls: 0,
    publicCalls: built.enqueuedPublicCalls,
    simulator: 'noir-tracer',
  });
  const p = submitted.provenance;
  return {
    kind: p.kind,
    hasTrace: p.privateTrace !== undefined,
    id: p.privateTrace?.id ?? 'MISSING',
    join: p.privateTrace?.join ?? 'MISSING',
    halves: p.privateTrace?.halves ?? -1,
    arm: p.privateTrace?.arm ?? 'MISSING',
    summaryContract: p.privateExecution?.contract ?? 'MISSING',
    summaryPublicCalls: p.privateExecution?.publicCalls ?? -1,
    summarySimulator: p.privateExecution?.simulator ?? 'MISSING',
  };
}
const provenanceArm = {
  split: handleFor('split', 2),
  shared: handleFor('shared', 1),
  // THE CONTROL: M20's discriminant-only local constructor carries no trace at all, so "the field
  // is there" is a property of the path that produced it rather than of the type.
  discriminantOnly: (() => {
    const p = locallyOriginatedTx({ marker: 'the transaction' }).provenance;
    return { kind: p.kind, hasTrace: p.privateTrace !== undefined };
  })(),
  external: (() => {
    const p = externalTx({ marker: 'the transaction' }).provenance;
    return { kind: p.kind, hasTrace: p.privateTrace !== undefined };
  })(),
};

// ---------------------------------------------------------------------------
writeFileSync(
  `${WORK}/join.json`,
  JSON.stringify(
    {
      config: {
        node: process.version,
        module: MODULE,
        moduleBytes: moduleBytes.length,
        probe: PROBE,
        noirRoot: NOIR_ROOT,
        noirFixture: NOIR_FIXTURE,
        joinId: JOIN_ID,
        publicSteps: PUBLIC_STEPS,
        recordingIds: RECORDING_IDS,
      },
      tx: txArm,
      sourceMap: sourceMapArm,
      module: moduleArm,
      shared: sharedProbe,
      split: { private: splitProbe, public: splitPublic },
      join: joinArm,
      provenance: provenanceArm,
    },
    null,
    1,
  ),
);
console.log(`run_join_arms: ${WORK}/join.json`);
