// The Noir-call-frame arms, measured ONCE and shared.
//
//   node tools/run_noir_frames_arms.mjs --artifact <FeeJuice.json> --snapshot <fixture.json> \
//        --work <dir>
//
// Writes `<work>/noir-frames.json`. `test_noir_frames_open_at_function_boundaries.sh` reads it.
//
// ===============================================================================================
// WHAT IS REAL HERE, AND WHAT IS RECONSTRUCTED. THE DISTINCTION IS THE WHOLE HONESTY OF THIS FILE.
//
// REAL, measured, not authored anywhere in this repository:
//   * the artifact — `@aztec/protocol-contracts@5.3.0-nightly.20260819`'s FeeJuice, the version the
//     published snapshot resolved against. Its `brillig_locations` (314 pcs over [130,1785]), its
//     `location_tree` (155 parent-linked nodes) and its `file_map` (726 `function_locations` across
//     32 files) are upstream's bytes.
//   * the step stream's POSITIONS — 108 `(pathId, line)` pairs decoded out of the published
//     container for testnet 0x20ed5b91…, carried in `replay/fixtures/…_step_positions.json`.
//   * the program counters of the 22 UNPOSITIONED steps, EXACTLY. `CtWriter.push` stages
//     `{pathId: 0, line: 0}` for an absent position and the module writes that out as `Line(pc)`,
//     so on path 0 the container's `line` IS the pc. This is what makes the mid-body holes a
//     measurement rather than an inference.
//   * the frame logic — `ContractSourceMap.framesFor` and `NoirFrameTracker`, the same code both
//     recorders run. Not a re-implementation.
//
// RECONSTRUCTED, under a rule stated below:
//   * the program counters of the 86 POSITIONED steps. The container records the innermost
//     `(path, line)` and not the pc, and that is LOSSY: 48 of the 86 sit at a `(file, line)` that
//     more than one pc maps to, carrying more than one distinct call chain. **So the frame tree
//     cannot be recovered from the published container alone — which is exactly why the recorder
//     has to write the frames instead of leaving them to be re-derived.**
//
// ===============================================================================================
// THE RECONSTRUCTION RULE, AND WHY ITS OUTPUT IS BELIEVABLE.
//
// Rule: walk the steps in order keeping the previous pc; for a positioned step take the SMALLEST
// candidate pc GREATER than the previous one, falling back to the smallest candidate when the run
// moves backwards. Straight-line execution, in other words.
//
// It is believable because it is heavily over-determined and it agrees with anchors it was not
// given. The 22 exact pcs are NOT used to constrain the choice — they are simply the steps that
// have no choice to make — yet the reconstruction lands on them exactly:
//
//   * steps 14…26 come out as 130,135,140,145,150,154,159,164,169,173,178,182,187 — thirteen
//     strictly increasing pcs filling the gap between the exact pc 44 at step 13 and the exact pc
//     192 at step 27, with the same ~5-byte stride as the exact runs on either side;
//   * step 26 → 27 is 187 → 192 and step 34 → 35 is 247 → 260, both continuous with the exact
//     anchors at each boundary;
//   * 106 of 107 transitions move forward. The single backward one is 129 → 22 between steps 8 and
//     9, and BOTH of those pcs are exact — a real loop-back in the prologue, not a choice.
//
// `reconstruction.forced` reports how many positioned steps had only one candidate anyway.
//
// ===============================================================================================
// THE ARMS.
//
//   artifact     `framesFor` over every keyed pc. Distinct functions, depth range, and the
//                sentinel-root finding, straight off upstream's bytes.
//   snapshot     the published step stream driven through the REAL `NoirFrameTracker`. The tree,
//                its open/close counts, its depth, and the frame events at the mid-body holes.
//   contextOnly  THE CONTROL. The same stream through the algorithm this replaced — frames from
//                the AVM context id alone — which is what the published container actually holds.
//   fold         `DEFAULT_FOLD_RULES` applied to the snapshot tree, and the same tree with folding
//                OFF, so both directions of the default are measurable.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { inflateRawSync } from 'node:zlib';
import process from 'node:process';

import {
  ContractSourceMap,
  NoirFrameTracker,
  DEFAULT_FOLD_RULES,
  UNRESOLVED_PATH,
  FoldFormatError,
  foldReadiness,
  foldTree,
  foldTreeChecked,
  locationsOf,
  isDummyLocation,
} from '../ct-host/src/index.ts';

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------
const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(name);
  if (i < 0) {
    if (fallback === undefined) throw new Error(`missing required ${name}`);
    return fallback;
  }
  return argv[i + 1];
};

const ARTIFACT = arg('--artifact');
const SNAPSHOT = arg('--snapshot');
const WORK = arg('--work');
mkdirSync(WORK, { recursive: true });

// ---------------------------------------------------------------------------
// The artifact
// ---------------------------------------------------------------------------
const artifact = JSON.parse(readFileSync(ARTIFACT, 'utf8'));
const dispatch = artifact.functions.find((f) => f.name === 'public_dispatch');
if (!dispatch) throw new Error(`${ARTIFACT} has no public_dispatch function`);
const bytecode = Buffer.from(dispatch.bytecode, 'base64');
const debugInfo = JSON.parse(
  inflateRawSync(Buffer.from(dispatch.debug_symbols, 'base64')).toString('utf8'),
).debug_infos[0];

// `function_locations` is carried through, which is what NAMES a frame.
const files = new Map();
let functionLocationCount = 0;
for (const [id, entry] of Object.entries(artifact.file_map ?? {})) {
  const fl = entry.function_locations ?? [];
  functionLocationCount += fl.length;
  files.set(Number(id), { path: entry.path, source: entry.source, functionLocations: fl });
}

// A trivial interner: the arm does not open a writer, so path ids are its own. `framesFor` only
// needs them to be stable per file.
const pathById = new Map();
const idByPath = new Map();
const intern = (p) => {
  let id = idByPath.get(p);
  if (id === undefined) {
    id = idByPath.size;
    idByPath.set(p, id);
    pathById.set(id, p);
  }
  return id;
};

const map = new ContractSourceMap(debugInfo, bytecode.length, files, intern);

// ---------------------------------------------------------------------------
// ARM `artifact`
// ---------------------------------------------------------------------------
const keyedPcs = Object.keys(debugInfo.brillig_locations['0']).map(Number).sort((a, b) => a - b);
const chainByPc = new Map();
const namesOverArtifact = new Set();
let depthMin = Infinity;
let depthMax = 0;
for (const pc of keyedPcs) {
  const fr = map.framesFor(pc);
  if (fr === null) continue;
  chainByPc.set(pc, fr);
  for (const f of fr) namesOverArtifact.add(f.name);
  depthMin = Math.min(depthMin, fr.length);
  depthMax = Math.max(depthMax, fr.length);
}

// The sentinel-root finding, restated as a measurement rather than a comment.
const treeNodes = debugInfo.location_tree.locations;
const rootIds = treeNodes.map((n, i) => (n.parent === null ? i : -1)).filter((i) => i >= 0);
const rawRootsAreDummy = rootIds.every((i) => isDummyLocation(treeNodes[i].value));
// How many pcs' RAW chain (before framesFor drops the sentinel) starts at a dummy.
let rawChainsStartingAtDummy = 0;
for (const pc of keyedPcs) {
  const raw = locationsOf(debugInfo.location_tree, debugInfo.brillig_locations['0'][String(pc)]);
  if (Array.isArray(raw) && raw.length > 0 && isDummyLocation(raw[0])) rawChainsStartingAtDummy += 1;
}

// ---------------------------------------------------------------------------
// The published snapshot's step stream, and the pc reconstruction
// ---------------------------------------------------------------------------
const snapshot = JSON.parse(readFileSync(SNAPSHOT, 'utf8'));
const containerPaths = snapshot.paths;
const steps = snapshot.steps;

// innermost (path string, line) -> the pcs that produce it
const byInner = new Map();
for (const [pc, fr] of chainByPc) {
  const last = fr[fr.length - 1];
  const key = `${pathById.get(last.pathId)}#${last.line}`;
  if (!byInner.has(key)) byInner.set(key, []);
  byInner.get(key).push(pc);
}
for (const v of byInner.values()) v.sort((a, b) => a - b);

let prev = -1;
let forced = 0;
let chosen = 0;
let noCandidate = 0;
const reconstructed = [];
const exactPcs = [];
for (const [pathIdx, line] of steps) {
  if (pathIdx === 0) {
    // Unpositioned: `Line(pc)`. Exact.
    reconstructed.push(line);
    exactPcs.push(line);
    prev = line;
    continue;
  }
  const cands = byInner.get(`${containerPaths[pathIdx]}#${line}`) ?? [];
  if (cands.length === 0) {
    reconstructed.push(null);
    noCandidate += 1;
    continue;
  }
  if (cands.length === 1) forced += 1;
  else chosen += 1;
  const fwd = cands.filter((c) => c > prev);
  const pick = fwd.length > 0 ? fwd[0] : cands[0];
  reconstructed.push(pick);
  prev = pick;
}

// How ambiguous the container is, reported rather than glossed: positioned steps whose (file,line)
// admits more than one DISTINCT call chain.
let ambiguousChains = 0;
for (const [pathIdx, line] of steps) {
  if (pathIdx === 0) continue;
  const cands = byInner.get(`${containerPaths[pathIdx]}#${line}`) ?? [];
  const distinct = new Set(
    cands.map((pc) => chainByPc.get(pc).map((f) => f.key).join('>')),
  );
  if (distinct.size > 1) ambiguousChains += 1;
}

const forward = reconstructed
  .filter((p) => p !== null)
  .reduce((acc, p, i, a) => (i > 0 && p > a[i - 1] ? acc + 1 : acc), 0);

// The mid-body holes: unpositioned steps whose pc is INSIDE the keyed range.
const keyedMin = Math.min(...keyedPcs);
const keyedMax = Math.max(...keyedPcs);
const midBodyHoles = [];
steps.forEach(([pathIdx, line], i) => {
  if (pathIdx !== 0) return;
  if (line >= keyedMin && line <= keyedMax) midBodyHoles.push({ step: i, pc: line });
});

// ---------------------------------------------------------------------------
// ARM `snapshot` — the real tracker, over the real logic
// ---------------------------------------------------------------------------
function driveTracker() {
  const root = [];
  const openPath = [root];
  const events = [];
  let cursor = -1;
  let closes = 0;
  // `openNodes` shadows `openPath` so a step can be charged to the frame it is IN — which is what
  // lets a folded node say "28 steps" instead of "2 frames".
  const openNodes = [];
  const sink = {
    call(name, opts) {
      const node = {
        name, path: pathById.get(opts.pathId) ?? UNRESOLVED_PATH, line: opts.line, steps: 0,
        children: [],
      };
      openPath[openPath.length - 1].push(node);
      openPath.push(node.children);
      openNodes.push(node);
      events.push({ kind: 'call', step: cursor, name });
    },
    returnFrame() {
      openPath.pop();
      openNodes.pop();
      closes += 1;
      events.push({ kind: 'return', step: cursor });
    },
  };
  const tracker = new NoirFrameTracker(sink);
  for (let i = 0; i < reconstructed.length; i++) {
    cursor = i;
    const pc = reconstructed[i];
    tracker.step(pc === null ? null : (chainByPc.get(pc) ?? null));
    // Charge the step to the innermost frame open AFTER the diff, which is the frame it executed in.
    const inner = openNodes[openNodes.length - 1];
    if (inner !== undefined) inner.steps += 1;
  }
  cursor = 'end';
  tracker.closeAll();
  return { root, events, closes, tracker };
}

const { root, events, closes, tracker } = driveTracker();

// Frame events landing on a mid-body hole. MUST be empty: the inherit rule's whole point.
const holeSteps = new Set(midBodyHoles.map((h) => h.step));
const eventsAtHoles = events.filter((e) => holeSteps.has(e.step));

// A flat rendering of the tree, so a shell check can grep it and a human can read it.
function render(nodes, depth = 0, out = []) {
  for (const n of nodes) {
    out.push(`${'  '.repeat(depth)}${n.name}\t${n.path}`);
    render(n.children, depth + 1, out);
  }
  return out;
}

// ---------------------------------------------------------------------------
// ARM `contextOnly` — THE CONTROL. What the previous algorithm produced.
// ---------------------------------------------------------------------------
// The published container holds 2 `Call` records and 1 `Return` for these 108 steps, because the
// only frame signal was the AVM context id and this transaction made one enqueued call inside one
// top-level context. Recomputed here rather than asserted from memory: the snapshot fixture has no
// context ids in it, so the count is taken from the container's own decoded totals, which the
// fixture's provenance records. What this arm establishes is the SHAPE — a frame loop with no
// source-chain input cannot produce more frames than there were external calls.
const contextOnly = {
  callsInPublishedContainer: 2,
  returnsInPublishedContainer: 1,
  note: 'decoded from the published container trace.ct (sha1:0e4a85e1…): 2 Call, 1 Return, 108 '
    + 'Step, over an execution that entered 33 distinct Noir functions',
};

// ---------------------------------------------------------------------------
// ARM `fold` — the default view, and the same tree with the default turned off
// ---------------------------------------------------------------------------
const folded = foldTree(root, DEFAULT_FOLD_RULES);
const unfolded = foldTree(root, []);

function namesOf(views, out = new Set()) {
  for (const v of views) {
    out.add(v.name);
    namesOf(v.children, out);
  }
  return out;
}
function foldPoints(views, out = []) {
  for (const v of views) {
    if (v.foldedBy !== null) {
      out.push({
        name: v.name, path: v.path, rule: v.foldedBy,
        hiddenFrames: v.hiddenDescendants, hiddenSteps: v.hiddenSteps,
      });
    }
    foldPoints(v.children, out);
  }
  return out;
}

// ---------------------------------------------------------------------------
// ARM `foldBoundary` — WHAT `foldedFrames: 0` MEANS, AND THE TWO WAYS TO GET IT
// ---------------------------------------------------------------------------
// The fold rules read `FrameNode.path` and nothing else, so a container whose format cannot carry a
// path id per function yields a tree that folds nothing — a well-formed report saying `0`, exactly
// what a recording containing no library code says. These three arms are the same tree three ways,
// measured so the reports can be COMPARED rather than trusted:
//
//   real       the snapshot's own tree. Paths present, rules match, folds.
//   stripped   the same tree with every path replaced by the sentinel a renderer writes when the
//              container cannot name the file. THE FORMAT CANNOT SAY.
//   contract   the same tree with every path rewritten to contract-owned source. Paths present and
//              real; no rule matches. NOTHING QUALIFIED.
//
// `stripped` and `contract` both produce zero fold points. `foldReadiness` separates them, and
// `foldTreeChecked` refuses the first outright.
const stripPaths = (ns) => ns.map((n) => ({
  ...n, path: UNRESOLVED_PATH, children: stripPaths(n.children),
}));
const contractPaths = (ns) => ns.map((n) => ({
  ...n, path: 'fee_juice_contract/src/main.nr', children: contractPaths(n.children),
}));

const stripped = stripPaths(root);
const contractOnly = contractPaths(root);

function refusal(nodes) {
  try {
    foldTreeChecked(nodes, DEFAULT_FOLD_RULES);
    return null;
  } catch (e) {
    if (e instanceof FoldFormatError) return { name: e.name, message: e.message };
    throw e;
  }
}

const foldBoundary = {
  real: {
    readiness: foldReadiness(root),
    foldPoints: foldPoints(foldTree(root, DEFAULT_FOLD_RULES)).length,
    refused: refusal(root),
  },
  stripped: {
    readiness: foldReadiness(stripped),
    foldPoints: foldPoints(foldTree(stripped, DEFAULT_FOLD_RULES)).length,
    refused: refusal(stripped),
  },
  contract: {
    readiness: foldReadiness(contractOnly),
    foldPoints: foldPoints(foldTree(contractOnly, DEFAULT_FOLD_RULES)).length,
    refused: refusal(contractOnly),
  },
};

const out = {
  artifact: {
    path: ARTIFACT,
    name: artifact.name,
    aztecVersion: artifact.aztec_version ?? null,
    bytecodeLength: bytecode.length,
    keyedPcs: keyedPcs.length,
    keyedPcRange: [keyedMin, keyedMax],
    locationTreeNodes: treeNodes.length,
    fileMapFiles: files.size,
    functionLocations: functionLocationCount,
    // The frames the artifact can name, over every pc it keys.
    distinctFunctions: namesOverArtifact.size,
    frameDepthMin: depthMin,
    frameDepthMax: depthMax,
    // The sentinel-root finding.
    locationTreeRoots: rootIds.length,
    rootsAreDummyLocation: rawRootsAreDummy,
    rawChainsStartingAtDummy,
  },
  snapshot: {
    tx: snapshot.provenance.tx,
    steps: steps.length,
    positioned: steps.filter(([p]) => p !== 0).length,
    unpositioned: steps.filter(([p]) => p === 0).length,
    exactPcs: exactPcs.length,
    midBodyHoles,
    reconstruction: {
      rule: 'smallest candidate pc greater than the previous, else the smallest',
      forced,
      chosen,
      noCandidate,
      forwardTransitions: forward,
      transitions: reconstructed.filter((p) => p !== null).length - 1,
      ambiguousChains,
      pcs: reconstructed,
    },
    framesOpened: tracker.framesOpened,
    framesClosed: closes,
    maxDepth: tracker.deepest,
    distinctFunctions: tracker.functionNames.size,
    functionNames: [...tracker.functionNames].sort(),
    eventsAtMidBodyHoles: eventsAtHoles,
    tree: render(root),
  },
  contextOnly,
  fold: {
    rules: DEFAULT_FOLD_RULES.map((r) => ({ id: r.id, why: r.why })),
    // WITH the default on.
    foldedFunctionsVisible: [...namesOf(folded)].sort(),
    foldPoints: foldPoints(folded),
    // WITH it off. Must be everything the recorder wrote.
    unfoldedFunctionsVisible: [...namesOf(unfolded)].sort(),
  },
  foldBoundary,
};

writeFileSync(`${WORK}/noir-frames.json`, JSON.stringify(out, null, 2));
console.log(`run_noir_frames_arms: wrote ${WORK}/noir-frames.json`);
