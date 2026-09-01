#!/usr/bin/env node
// run_l5_recording_arms.mjs — WHAT A RESOLVED ARTIFACT DOES TO A CONTAINER, AND WHAT IT MUST NOT DO
// TO A CONTAINER WHOSE CONTRACT DID NOT RESOLVE.
//
// Four arms, all through the REAL `CtWriter` and the REAL `buildSettledRecording`, differing in
// exactly one input — the `sources` argument — so every difference between the containers is
// attributable to the resolution and to nothing else.
//
//   `resolved`    one contract, artifact proved, every step at a mapped pc  -> rung 1, sourceLevel
//   `control`     THE SAME STEPS with `sources` omitted                     -> rung 3, sourceLevel false
//   `partial`     one step at a pc the artifact's map does not key          -> rung 2, sourceLevel false
//   `mixed`       two contracts, one proved and one not                     -> rungs 1 and 3, and the
//                                                                              TRANSACTION is NOT source level
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE STEP STREAM HERE IS SYNTHETIC AND THIS FILE SAYS SO RATHER THAN LETTING A READER ASSUME.
//
// `SOURCE-MAPPING.md` §6 records the trap in terms: until M29 every step this repository recorded
// was one of the artifact's own MAPPED program counters, so "the contract is rung 1 and every step
// is positioned" was true BY CONSTRUCTION and the whole `rungViolations` apparatus had never been
// exercised by anything but its own control. **These arms have the same property and it is
// deliberate**: their subject is the WIRING — that a proved artifact reaches `declareRung`, that
// positions are staged in lockstep, that an unresolved contract is untouched — and a wiring test
// wants an input it controls.
//
// It is NOT the milestone's evidence that a real chain execution reaches rung 1. That needs a
// settled transaction whose contracts resolve, inside the ~1-hour replayable window, and
// `replay/tools/await_resolvable_transaction.mjs` is what waits for one. The `partial` arm exists
// precisely because the by-construction property is a limitation: it plants a pc the map does not
// key, which is what a real execution supplies for free (127 of 516 on the browser demo's token
// transfer, §6's measurement), and shows the declaration falling to rung 2 rather than being
// rounded up.

import { readFileSync, writeFileSync } from 'node:fs';

import {
  RUNG_BYTECODE_VALUE,
  buildSettledRecording,
  packageArtifactProvider,
  recordingIdFor,
  resolveContractArtifact,
} from '../replay/src/index.ts';
import {
  ContractSourceMap,
  CtWriter,
  instantiateCtWriter,
  resolveTracingConfig,
  RUNG_SOURCE,
  WRITER_PATH_A_PURE_RUST,
} from '../ct-host/src/index.ts';
import { artifactCrypto, installedProtocolContracts } from '../replay/tools/artifact_sources.mjs';

const CT_WRITER = process.argv[2] ?? process.env.CT_WRITER_WASM_PATH;
const FIXTURE = process.argv[3] ?? 'replay/fixtures/chain_contract_classes.json';
const OUT_DIR = process.argv[4] ?? null;
if (!CT_WRITER) {
  console.error('run_l5_recording_arms: <aztec_ct_writer.wasm> (or $CT_WRITER_WASM_PATH) required');
  process.exit(2);
}
const writerBytes = readFileSync(CT_WRITER);
const chains = JSON.parse(readFileSync(FIXTURE, 'utf8')).chains;
const feeJuice = chains['aztec-testnet'].contracts.feeJuice;
const token = chains['aztec-testnet'].contracts.thirdPartyToken;
const like = (c) => ({ id: c.id, artifactHash: c.artifactHash,
  privateFunctionsRoot: c.privateFunctionsRoot, packedBytecode: c.packedBytecode });

const installed = installedProtocolContracts();
const resolution = await resolveContractArtifact(feeJuice.address, like(feeJuice.class),
  [packageArtifactProvider([installed])], artifactCrypto);
if (!resolution.resolved) {
  // A DEATH, NOT A SKIP. Every arm below is about what a resolved artifact does; with none, each
  // one would still run and each one would still pass, over an instrument that had stopped
  // resolving. That is trap 4 exactly.
  console.error(`run_l5_recording_arms: the FeeJuice artifact did not resolve, so no arm here has `
    + `a subject: ${resolution.reason}`);
  process.exit(3);
}
const artifact = resolution.artifact;
const mappedPcs = [...new Set(
  Object.values(artifact.debugInfo.brillig_locations).flatMap(o => Object.keys(o).map(Number)),
)].sort((a, b) => a - b);

// A pc the map DOES NOT key, found rather than assumed: the first integer inside the bytecode that
// no `brillig_locations` entry mentions. `assert`ed non-null below, because a map that keyed every
// byte would leave the `partial` arm with nothing to plant.
const unmappedPc = (() => {
  const keyed = new Set(mappedPcs);
  for (let pc = 0; pc < artifact.bytecode.length; pc++) if (!keyed.has(pc)) return pc;
  return null;
})();

// ---------------------------------------------------------------------------------------------
// The synthetic settled transaction. Every field `buildSettledRecording` reads, and nothing else.
// ---------------------------------------------------------------------------------------------
const addressBytes = (hex) => {
  const h = (hex.startsWith('0x') ? hex.slice(2) : hex).padStart(64, '0');
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i++) out[i] = Number.parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return out;
};

function settledFor(addresses) {
  return {
    txHash: '0x12525d6d2a629f908a9d68aade391624eda2bfe38866d00c06233be7810e795f',
    l2BlockNumber: 63670,
    l2BlockHash: '0x0000000000000000000000000000000000000000000000000000000000000000',
    txIndexInBlock: 0,
    revertCode: 0,
    source: { url: 'synthetic://l5-recording-arms' },
    blockData: { header: { globalVariables: { timestamp: 1756700000n } } },
    contracts: addresses.map(a => ({ address: a, resolvedAsOf: 63670 })),
    privateHalf: { status: 'unavailable', origin: 'synthetic', reason: 'these arms exercise the '
      + 'public half\'s source mapping and declare the private half absent rather than omitting it' },
    txEffect: { data: {} },
  };
}

const outcome = (n) => ({
  instructionsExecuted: n,
  preStateBlock: 63669,
  revertCode: 0,
  verdict: { reproduced: true, matched: 0, mismatched: 0, comparisons: [] },
  roots: {
    declarations: [{ tree: 'noteHashTree', agrees: false, resident: '0x00', chain: '0x01' }],
    reason: 'synthetic arms: the roots are not compared',
    anyAgrees: false,
  },
  rounds: [],
  seedSize: { nullifiers: 0, publicData: 0 },
});

function stepsAt(pcs, address) {
  const bytes = addressBytes(address);
  return pcs.map((pc, i) => ({
    contextId: 0,
    pc,
    opcode: 1 + (i % 3),
    gasUsed: { l2Gas: 1000 + i, daGas: i },
    contractAddress: bytes,
  }));
}

async function openWriter(rung) {
  return new CtWriter(
    await instantiateCtWriter(writerBytes),
    resolveTracingConfig({
      program: 'aztec-live-chain-replay',
      recordingId: recordingIdFor('0x12525d6d2a629f908a9d68aade391624eda2bfe38866d00c06233be7810e795f', 1756700000n),
      sourcePath: '/aztec/l5.avm',
      workdir: '/aztec',
      mappingRung: rung,
      columns: rung === RUNG_SOURCE,
    }, WRITER_PATH_A_PURE_RUST),
    { batchRecords: 64 },
  );
}

/** Run one arm and report what the recording said about itself. */
async function arm(name, { rung, steps, addresses, withSource }) {
  const writer = await openWriter(rung);
  const interned = [];
  const map = new ContractSourceMap(artifact.debugInfo, artifact.bytecode.length, artifact.files,
    (p, ll) => { interned.push(p); return writer.internPath(p, ll); });
  const sources = withSource
    ? [{
      address: feeJuice.address,
      map,
      proof: resolution.reason,
      corroboration: resolution.corroboration,
      origin: artifact.origin,
    }]
    : [];

  // THE EXPECTATION, COMPUTED BEFORE THE CONTAINER IS WRITTEN AND FROM THE SAME RESOLVER.
  //
  // What this pins is the WRITER PATH — that the position staged beside step i is step i's, record
  // for record, across the batch boundary — and NOT the resolver, which produced both sides. It is
  // `smoke_browser_opens_and_steps_l3_container`'s shape: the strong assertion there is that the
  // engine's reported positions are the container's own program counters, record for record, and
  // the strong assertion here is that the container's reported lines are the resolver's own
  // answers, record for record. A mutation that skips a slot for an unpositioned step shifts every
  // later record onto its predecessor's line and nothing else in the report moves.
  // A SECOND map over the same artifact, whose `internPath` hands back the PATH rather than an id,
  // so the expectation is expressed in basenames the reader's own `paths` array can be compared
  // against. Two maps over one artifact agree on `(line, column)` by construction and differ only
  // in the ids they were handed, which is the whole reason this one exists rather than reusing the
  // first: an id is a fact about a writer and a path is a fact about the artifact.
  const namedPaths = [];
  const namingMap = new ContractSourceMap(artifact.debugInfo, artifact.bytecode.length,
    artifact.files, (p) => { namedPaths.push(p); return namedPaths.length - 1; });
  const traced = feeJuice.address.toLowerCase().replace(/^0x/, '').padStart(64, '0');
  const expected = steps.map((s) => {
    if (!withSource) return '-';
    const here = [...s.contractAddress].map(b => b.toString(16).padStart(2, '0')).join('');
    if (here !== traced) return '-';
    const pos = namingMap.positionFor(s.pc);
    if (pos === null) return '-';
    return `${namedPaths[pos.pathId].split('/').pop()}:${pos.line}:${pos.column}`;
  });
  let recording = null;
  let threw = null;
  try {
    recording = buildSettledRecording(writer, settledFor(addresses), outcome(steps.length),
      steps, sources);
  } catch (err) {
    threw = { name: err?.name ?? 'Error', message: String(err?.message).slice(0, 400) };
  }
  if (OUT_DIR && recording !== null) {
    writeFileSync(`${OUT_DIR}/${name}.ct`, recording.container);
  }
  return {
    threw,
    ...(recording === null ? {} : {
      bytes: recording.bytes,
      events: recording.events,
      steps: recording.steps,
      logEvents: recording.logEvents,
      declaredRung: recording.declaredRung,
      sourceLevel: recording.sourceLevel,
      stepsPositioned: recording.stepsPositioned,
      stepsUnpositioned: recording.stepsUnpositioned,
      contractRungs: recording.contractRungs.map(c => ({
        address: c.address, rung: c.rung, steps: c.steps, positioned: c.positioned,
        resolved: c.resolved, firstUnpositionedPc: c.firstUnpositionedPc,
        reasonHead: c.reason.slice(0, 120),
      })),
      pathsInterned: new Set(interned).size,
      metadataKeys: recording.metadataKeys,
      // `basename:line:column` per step, or `-` for a step this recording cannot position. The
      // check compares this against what the REFERENCE READER decodes out of the container, record
      // for record. See the comment above `expected`.
      expectedPositions: expected,
    }),
  };
}

// The first 64 mapped pcs: enough to cross the writer's batch boundary (`batchRecords: 64`) so the
// position side channel is exercised across a flush, which is where an order-paired FIFO breaks.
const subjectPcs = mappedPcs.slice(0, 64);

const out = {
  ctWriter: CT_WRITER,
  artifact: {
    origin: artifact.origin, artifactHash: artifact.artifactHash,
    bytecodeBytes: artifact.bytecode.length, sourceFiles: artifact.files.size,
    mappedPcs: mappedPcs.length, firstMappedPc: mappedPcs[0], unmappedPcFound: unmappedPc,
  },
  arms: {},
};

out.arms.resolved = await arm('resolved',
  { rung: RUNG_SOURCE, steps: stepsAt(subjectPcs, feeJuice.address),
    addresses: [feeJuice.address], withSource: true });

// THE CONTROL: byte-for-byte the same steps, the same writer configuration is NOT used — a rung-1
// session with nothing positioned is refused by `CtWriter.close()`, which is the guard working —
// so the control opens where an unresolved recording opens, at rung 3, which is the comparison the
// milestone is about: what this transaction WOULD have produced before L5.
out.arms.control = await arm('control',
  { rung: RUNG_BYTECODE_VALUE, steps: stepsAt(subjectPcs, feeJuice.address),
    addresses: [feeJuice.address], withSource: false });

// THE UNMAPPED PC GOES IN THE MIDDLE, AND ITS POSITION IN THE STREAM IS LOAD-BEARING.
//
// The first version of this arm put it LAST, and a mutation that stages a position only where one
// exists — instead of occupying the slot with a `line: 0` record — SURVIVED, because a skipped
// slot at the tail shifts nothing after it. With the gap at index 31 every later step takes its
// predecessor's line, which is the desynchronisation `CtWriter.push`'s header warns about and the
// reason the writer stages a placeholder rather than trusting the caller. An arm that cannot
// observe the defect it is named for is not an arm.
const PARTIAL_GAP_INDEX = 31;
out.arms.partial = await arm('partial', {
  rung: RUNG_SOURCE,
  steps: stepsAt([
    ...subjectPcs.slice(0, PARTIAL_GAP_INDEX),
    unmappedPc,
    ...subjectPcs.slice(PARTIAL_GAP_INDEX, 63),
  ], feeJuice.address),
  addresses: [feeJuice.address],
  withSource: true,
});
out.partialGapIndex = PARTIAL_GAP_INDEX;

// MIXED: the two contracts INTERLEAVED, not concatenated, for the same reason. Concatenated, every
// unpositioned step is at the tail and a skipped slot costs nothing; interleaved, the token's
// unpositioned steps sit between FeeJuice's positioned ones and a desynchronisation is visible in
// the very next record.
const interleaved = [];
{
  const fj = stepsAt(subjectPcs.slice(0, 32), feeJuice.address);
  const tk = stepsAt(subjectPcs.slice(0, 32), token.address);
  for (let i = 0; i < 32; i++) { interleaved.push(fj[i]); interleaved.push(tk[i]); }
}
out.arms.mixed = await arm('mixed', {
  rung: RUNG_SOURCE,
  steps: interleaved,
  addresses: [feeJuice.address, token.address],
  withSource: true,
});

console.log(JSON.stringify(out, null, 2));
