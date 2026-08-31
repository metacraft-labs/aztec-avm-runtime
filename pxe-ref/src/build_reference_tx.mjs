// build_reference_tx.mjs — UPSTREAM'S PXE, run as the reference half of M21's differential.
//
//   node pxe-ref/src/build_reference_tx.mjs <out.json>
//
// ============================================================================================
// WHAT THIS PRODUCES AND WHY IT IS A SEPARATE PROCESS.
// ============================================================================================
//
// `test_form_b_tx_matches_pxe_bytes` asks whether the `Tx` this runtime builds is byte-identical to
// the one PXE builds for the same request and inputs. Answering it needs BOTH producers, and they
// cannot live in one import graph: `@aztec/pxe` hard-depends on `@aztec/simulator`, which
// hard-depends on `@aztec/native` and `@aztec/world-state`, and DD-9 forbids all three anywhere
// near `orchestration/`. So this half runs here, in a tree nothing ships, and hands the other half
// a SERIALISED tail plus the transaction bytes it produced from it.
//
// Two upstream steps, in upstream's own order, both of them upstream's own functions:
//
//   1. `generateSimulatedProvingResult(privateExecutionResult, nameGetter, node)` — `@aztec/pxe`'s
//      own export from `@aztec/pxe/simulator`, and the step this repository does NOT have.
//   2. `new PrivateSimulationResult(…).toSimulatedTx()` — which this repository DOES have, as
//      `orchestration/src/form_b.ts`'s `txFromTail`, and which is therefore the thing under test.
//
// ============================================================================================
// THE INPUT IS THE SAME ONE `form_b.ts` BUILDS, AND IT IS BUILT THE SAME WAY.
// ============================================================================================
//
// `publicOnlyPrivateExecution` below is `orchestration/src/form_b.ts`'s function, copied here in
// full rather than imported — the two trees are two `@aztec/stdlib` INSTALLS, and a value
// constructed from one and handed to the other serialises as a plain object that the receiver
// either rejects or, worse, decodes into something plausible. Every value that crosses between the
// two processes crosses as BYTES.
//
// It is upstream's own shape twice over: `wallet-sdk/src/base-wallet/utils.ts:118-132` at the `cpp`
// anchor builds exactly this, and `form_b.ts` says so at the line it copies.
//
// ============================================================================================
// THE NODE IS A STUB THAT THROWS, AND THAT IS AN ASSERTION RATHER THAN A CONVENIENCE.
// ============================================================================================
//
// `generateSimulatedProvingResult`'s third parameter is an `AztecNode`, used by
// `verifyReadRequests` to resolve SETTLED note-hash and nullifier read requests. This execution has
// none, so a stub that throws turns "the node was not needed" into a measured fact: if upstream
// ever consults it for this input, this producer dies rather than quietly succeeding against a
// half-answered read.

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { Fr } from '@aztec/foundation/curves/bn254';
import { PrivateCircuitPublicInputs } from '@aztec/stdlib/kernel';
import { ChonkProof } from '@aztec/stdlib/proofs';
import {
  HashedValues,
  PrivateCallExecutionResult,
  PrivateExecutionResult,
  PrivateSimulationResult,
  Tx,
} from '@aztec/stdlib/tx';
import { generateSimulatedProvingResult } from '@aztec/pxe/simulator';

const out = process.argv[2];
if (!out) {
  console.error('usage: build_reference_tx.mjs <out.json>');
  process.exit(2);
}

const sha = b => createHash('sha256').update(b).digest('hex');

const TREE = path.resolve(import.meta.dirname, '..');
const installedVersion = name =>
  JSON.parse(readFileSync(path.join(TREE, 'node_modules', name, 'package.json'), 'utf8')).version;

/** `orchestration/src/form_b.ts`'s `publicOnlyPrivateExecution`, in upstream's own eleven-argument order. */
function publicOnlyPrivateExecution(circuitPublicInputs, firstNullifier, publicFunctionCalldata = []) {
  const entrypoint = new PrivateCallExecutionResult(
    new Uint8Array(0), // acir
    new Uint8Array(0), // vk
    new Map(), // partialWitness
    circuitPublicInputs,
    [], // noteHashLeafIndexMap
    new Map(), // newNotes
    [], // noteHashNullifierCounterMap
    [], // returnValues
    [], // nestedExecutionResults
    [], // contractClassLogs
    [], // offchainEffects
  );
  return new PrivateExecutionResult(entrypoint, firstNullifier, publicFunctionCalldata);
}

let nodeConsulted = 0;
const node = {
  findLeavesIndexes: async () => {
    nodeConsulted += 1;
    throw new Error('the reference producer consulted the node, which this input should not need');
  },
};

/**
 * One case: a first nullifier and some public calldata in, a tail and a transaction out.
 *
 * `inlined` is the form TXE and `wallet-sdk` use instead of `toSimulatedTx` — `Tx.create` with an
 * EMPTY `contractClassLogFields` — which `form_b.ts` records as a live divergence. It is produced
 * here so the check can compare the two rather than quote the sentence.
 */
async function buildCase(label, firstNullifier, argFields) {
  const calldata = argFields === null ? [] : [await HashedValues.fromArgs(argFields.map(n => new Fr(n)))];
  const privateResult = publicOnlyPrivateExecution(PrivateCircuitPublicInputs.empty(), new Fr(firstNullifier), calldata);
  const proving = await generateSimulatedProvingResult(privateResult, async () => 'reference', node);
  const tailBuffer = proving.publicInputs.toBuffer();
  const tx = await new PrivateSimulationResult(privateResult, proving.publicInputs).toSimulatedTx();
  const txBuffer = tx.toBuffer();
  const inlined = await Tx.create({
    data: proving.publicInputs,
    chonkProof: ChonkProof.empty(),
    contractClassLogFields: [],
    publicFunctionCalldata: privateResult.publicFunctionCalldata,
  });
  const inlinedBuffer = inlined.toBuffer();
  return {
    label,
    firstNullifier: new Fr(firstNullifier).toString(),
    publicCalldataCount: calldata.length,
    // THE INPUT, AS VALUES. The other half of the differential rebuilds its own
    // `PrivateExecutionResult` from these rather than receiving one: two `@aztec/stdlib` installs
    // in one process is a wrong answer and not a slow one, so the INPUTS cross as values and the
    // OUTPUTS cross as bytes.
    publicCalldataArgFields: argFields === null ? [] : argFields.map(n => n.toString()),
    tail: {
      class: proving.publicInputs.constructor.name,
      bytes: tailBuffer.length,
      sha256: sha(tailBuffer),
      hex: tailBuffer.toString('hex'),
    },
    tx: {
      class: tx.constructor.name,
      bytes: txBuffer.length,
      sha256: sha(txBuffer),
      hash: (await tx.getTxHash()).toString(),
    },
    // The TXE / wallet-sdk shape, measured rather than described.
    inlined: {
      bytes: inlinedBuffer.length,
      sha256: sha(inlinedBuffer),
      hash: (await inlined.getTxHash()).toString(),
      equalsToSimulatedTx: inlinedBuffer.equals(txBuffer),
    },
  };
}

// THE EMPTY TAIL, so "the tail PXE produced" can be shown to be something rather than the default.
const emptyTail = (await import('@aztec/stdlib/kernel')).PrivateKernelTailCircuitPublicInputs.empty().toBuffer();

const cases = {
  // Two cases, differing only in the first nullifier, so "byte-identical" cannot be a property of
  // one constant. The seed values are `e2e_form_b_local_tx_roundtrip`'s own reasoning: small values
  // collide with the resident nullifier tree's genesis prefill, so both are well past it.
  primary: await buildCase('primary', 1007n, [11n, 22n, 33n]),
  variant: await buildCase('variant', 2009n, [11n, 22n, 33n]),
  // A third case with NO public calldata, so a seam that dropped the calldata is visible.
  noCalldata: await buildCase('noCalldata', 1007n, null),
};

// THE PAIRED POSITIVE FOR `nodeConsulted`. A counter wired to nothing reads zero, and so does a
// stub nobody could have called. It is called deliberately here, AFTER every case has been built,
// so the zero above is a measurement by an instrument that has been seen to move.
const nodeConsultedDuringCases = nodeConsulted;
let nodeProbe = 'NOT-THROWN';
try {
  await node.findLeavesIndexes();
} catch (e) {
  nodeProbe = `threw:${e instanceof Error ? e.message : String(e)}`;
}

writeFileSync(
  out,
  JSON.stringify(
    {
      measuredAt: new Date().toISOString(),
      producer: '@aztec/pxe/simulator generateSimulatedProvingResult + @aztec/stdlib toSimulatedTx',
      // READ OFF DISK. `import('@aztec/pxe/package.json')` is ERR_PACKAGE_PATH_NOT_EXPORTED — the
      // package's own `exports` map does not expose it, which is npm's default and not an oversight.
      pxeVersion: installedVersion('@aztec/pxe'),
      stdlibVersion: installedVersion('@aztec/stdlib'),
      node: process.version,
      nodeConsulted: nodeConsultedDuringCases,
      nodeConsultedAfterProbe: nodeConsulted,
      nodeProbe,
      emptyTailSha256: sha(emptyTail),
      cases,
    },
    null,
    2,
  ) + '\n',
);
console.error(`wrote ${out}`);
