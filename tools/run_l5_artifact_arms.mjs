#!/usr/bin/env node
// run_l5_artifact_arms.mjs — L5's arms: OFF-CHAIN ARTIFACT RESOLUTION, PROVED AND DISPROVED.
//
// Every arm here is OFFLINE. The classes come from `replay/fixtures/chain_contract_classes.json`
// — captured from both live chains, with the date and the two methods recorded — and the artifacts
// come from the installed `@aztec/protocol-contracts`. **Neither side is derived from the other,
// which is the property that keeps the verification non-circular:** an artifact is PROVED against
// numbers the chain served, so taking those numbers out of the artifact would prove nothing at all.
//
// The network measurements this milestone also rests on — `@aztec/protocol-contracts@5.0.0-rc.2`,
// and Aztecscan's two key shapes — are in `verify_l5_artifact_sources_live.sh`, which is NOT part
// of the offline floor and announces itself, for `verify-l4-net`'s reason.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE ARM THAT MATTERS MOST IS THE ONE THAT PASSES WHEN IT SHOULD NOT LOOK LIKE IT DOES.
//
// `uncommittedDebugSymbols` takes the artifact that has just been proved three ways, REPLACES its
// `debug_symbols` with a map that sends every pc to a different line, and offers it again. **It
// verifies.** All three checks — artifactHash, byte-equal bytecode, recomputed class id — pass over
// an artifact whose source mapping is a lie, because `computeArtifactHash`'s preimage is the
// private-function tree root, the utility-function tree root and the artifact metadata, and none of
// those is `debug_symbols` or `file_map`.
//
// That is not a defect in the resolver. It is the exact boundary of what the chain commits to, and
// it is why `ct.source-provenance` names the distributor and states the corroboration rather than
// saying "verified" and stopping. An arm that only ever showed the checks catching forgeries would
// leave a reader believing they catch this one.

import { readFileSync } from 'node:fs';
import { deflateRawSync, inflateRawSync } from 'node:zlib';

import {
  RUNG_BYTECODE_VALUE,
  buildSettledRecording,
  debugDigestOf,
  keyShapeOf,
  resolveContractArtifact,
  reviveBuffers,
  verifyCandidate,
} from '../replay/src/index.ts';
import { packageArtifactProvider } from '../replay/src/artifact_providers.ts';
import { ContractSourceMap, rungFor } from '../ct-host/src/source_map.ts';
import { artifactCrypto, installedProtocolContracts } from '../replay/tools/artifact_sources.mjs';

const FIXTURE = process.argv[2] ?? 'replay/fixtures/chain_contract_classes.json';
const chains = JSON.parse(readFileSync(FIXTURE, 'utf8')).chains;
const feeJuiceClass = asLike(chains['aztec-testnet'].contracts.feeJuice.class);
const tokenClass = asLike(chains['aztec-testnet'].contracts.thirdPartyToken.class);

function asLike(c) {
  return {
    id: c.id,
    artifactHash: c.artifactHash,
    privateFunctionsRoot: c.privateFunctionsRoot,
    packedBytecode: c.packedBytecode,
  };
}

const installed = installedProtocolContracts();
const feeJuiceRaw = installed.artifacts.FeeJuice;
const out = {
  fixture: FIXTURE,
  installedPackage: `${installed.packageName}@${installed.version}`,
  installedArtifacts: Object.keys(installed.artifacts),
};

const candidate = (distributor, origin, raw) => ({ distributor, origin, raw });
const staticProvider = (candidates) => async () => candidates;

// ---------------------------------------------------------------------------------------------
// ARM: shapes — BOTH spellings are read, and the assertion is that both were EXERCISED.
// ---------------------------------------------------------------------------------------------
//
// The camelCase form is produced exactly the way the explorer produces it: `loadContractArtifact`
// then a JSON round trip. That round trip is the whole trap — a `ContractArtifact`'s `bytecode` is
// a `Buffer` and JSON turns it into `{ type: 'Buffer', data: [...] }` — so this arm is the one that
// proves `reviveBuffers` is load-bearing rather than decorative.
{
  const camelRaw = JSON.parse(JSON.stringify(artifactCrypto.loadContractArtifact(feeJuiceRaw)));
  const snake = await verifyCandidate(
    candidate('npm', 'installed snake_case', feeJuiceRaw), feeJuiceClass, artifactCrypto);
  const camel = await verifyCandidate(
    candidate('explorer-shaped', 'loaded + JSON round-tripped camelCase', camelRaw),
    feeJuiceClass, artifactCrypto);
  // The same payload with revival SKIPPED, hashed directly. Not a resolver path — a measurement of
  // what the resolver would answer if `reviveBuffers` did nothing, which is the mutation arm's
  // subject stated as a number.
  const unrevivedHash = (await artifactCrypto.computeArtifactHash(camelRaw)).toString();
  const revivedHash = (await artifactCrypto.computeArtifactHash(reviveBuffers(camelRaw))).toString();
  out.shapes = {
    snakeShape: keyShapeOf(feeJuiceRaw),
    camelShape: keyShapeOf(camelRaw),
    unrecognisedShape: keyShapeOf({ functions: [], nothing: true }),
    snakeVerified: !('fault' in snake),
    camelVerified: !('fault' in camel),
    snakeFault: 'fault' in snake ? snake.fault : null,
    camelFault: 'fault' in camel ? camel.fault : null,
    // Equal, because both are the same artifact — which is the point: the SHAPE must not change the
    // verdict, and a resolver that read one spelling would report the other absent.
    snakeArtifactHash: 'fault' in snake ? null : snake.artifactHash,
    camelArtifactHash: 'fault' in camel ? null : camel.artifactHash,
    snakeDebugDigest: 'fault' in snake ? null : snake.debugDigest,
    camelDebugDigest: 'fault' in camel ? null : camel.debugDigest,
    unrevivedArtifactHash: unrevivedHash,
    revivedArtifactHash: revivedHash,
    revivalChangesTheHash: unrevivedHash !== revivedHash,
    chainArtifactHash: feeJuiceClass.artifactHash,
  };
}

// ---------------------------------------------------------------------------------------------
// ARM: unrecognisedShape — a payload neither branch places is REPORTED, not read as absence.
// ---------------------------------------------------------------------------------------------
{
  const r = await verifyCandidate(candidate('nowhere', 'a bare object', { hello: 'world' }),
    feeJuiceClass, artifactCrypto);
  // A REAL artifact with `public_dispatch` removed, rather than a hand-written stub: a stub fails
  // `loadContractArtifact` first and reports `unrecognised-key-shape`, so the arm would name a
  // fault it never reached — this campaign's "a check that never exercises the thing it is named
  // for", in three lines.
  const stripped = JSON.parse(JSON.stringify(feeJuiceRaw));
  stripped.functions = stripped.functions.filter(f => f.name !== 'public_dispatch');
  const noDispatch = await verifyCandidate(
    candidate('nowhere', 'FeeJuice with public_dispatch removed', stripped),
    feeJuiceClass, artifactCrypto);
  out.refusals = {
    bareObjectFault: 'fault' in r ? r.fault : null,
    bareObjectDetail: 'fault' in r ? r.detail : null,
    noDispatchFault: 'fault' in noDispatch ? noDispatch.fault : null,
    noDispatchDetail: 'fault' in noDispatch ? noDispatch.detail : null,
    functionsBefore: feeJuiceRaw.functions.length,
    functionsAfter: stripped.functions.length,
  };
}

// ---------------------------------------------------------------------------------------------
// ARM: subject — the deployed FeeJuice, resolved against the installed package.
// ---------------------------------------------------------------------------------------------
{
  const resolution = await resolveContractArtifact(
    chains['aztec-testnet'].contracts.feeJuice.address,
    feeJuiceClass,
    [packageArtifactProvider([installed])],
    artifactCrypto,
  );
  out.subject = { resolved: resolution.resolved, reason: resolution.reason };
  if (resolution.resolved) {
    const a = resolution.artifact;
    const verdict = rungFor(a.debugInfo, a.bytecode.length, a.files);
    const paths = [];
    const map = new ContractSourceMap(a.debugInfo, a.bytecode.length, a.files,
      (p) => { paths.push(p); return paths.length - 1; });
    const mappedPcs = [...new Set(
      Object.values(a.debugInfo.brillig_locations).flatMap(o => Object.keys(o).map(Number)),
    )].sort((x, y) => x - y);
    let positioned = 0;
    for (const pc of mappedPcs) if (map.positionFor(pc) !== null) positioned += 1;
    const first = map.positionFor(mappedPcs[0]);
    Object.assign(out.subject, {
      origin: a.origin,
      shape: a.shape,
      artifactHash: a.artifactHash,
      contractClassId: a.contractClassId,
      chainClassId: feeJuiceClass.id,
      bytecodeBytes: a.bytecode.length,
      chainBytecodeBytes: Buffer.from(feeJuiceClass.packedBytecode, 'base64').length,
      sourceFiles: a.files.size,
      corroboration: resolution.corroboration,
      agreeingDistributors: resolution.agreeingDistributors,
      rung: verdict.rung,
      mappedPcs: verdict.mappedPcs,
      pcRange: verdict.pcRange,
      mappedPcsResolving: positioned,
      // TWO NUMBERS AND NOT ONE, because they differ and the difference is a fact about the
      // artifact rather than about this arm. `ContractSourceMap` interns once per FILE ID, and
      // several of the file ids in a Noir `file_map` name the same path — so the map reaches 12
      // file ids over 9 distinct paths. A single `pathsInterned` figure would be whichever of the
      // two the writer happened to produce, and the real `CtWriter.internPath` deduplicates by
      // path while this arm's injected one does not.
      fileIdsReached: paths.length,
      distinctPathsReached: new Set(paths).size,
      firstMappedPc: mappedPcs[0],
      firstPosition: first === null ? null
        : { path: paths[first.pathId], line: first.line, column: first.column },
      // The basename is asserted separately from the whole path: the whole path is an upstream CI
      // build path and could reasonably change, while "this pc is in fee_juice_contract's main.nr"
      // is the claim the milestone actually makes.
      firstPositionBasename: first === null ? null : paths[first.pathId].split('/').pop(),
      debugDigest: a.debugDigest,
    });
  }
}

// ---------------------------------------------------------------------------------------------
// ARM: decoy — RIGHT BYTECODE, WRONG ARTIFACT. The arm the third check exists for.
// ---------------------------------------------------------------------------------------------
//
// Derived rather than shipped: the installed FeeJuice with one *committed* field changed, leaving
// `public_dispatch.bytecode` untouched. `computeArtifactMetadataHash` reads the contract's name, so
// renaming it moves the artifact hash and moves nothing the AVM executes.
//
// **THIS IS THE SHAPE AZTECSCAN'S OWN CHECK ACCEPTS.** Its verification compares packed public
// bytecode and never computes `artifactHash`, so a decoy like this one is, to that check,
// indistinguishable from the real artifact — and it can carry any `debug_symbols` at all. The live
// check measures the same thing on a REAL example, `@aztec/protocol-contracts@5.0.0-rc.2`, whose
// FeeJuice ships byte-identical bytecode under a different artifact hash.
{
  const decoy = JSON.parse(JSON.stringify(feeJuiceRaw));
  decoy.name = `${decoy.name}Decoy`;
  const r = await verifyCandidate(candidate('forgery', 'renamed FeeJuice, same bytecode', decoy),
    feeJuiceClass, artifactCrypto);
  const decoyDispatch = decoy.functions.find(f => f.name === 'public_dispatch');
  const realDispatch = feeJuiceRaw.functions.find(f => f.name === 'public_dispatch');
  out.decoy = {
    fault: 'fault' in r ? r.fault : null,
    detail: 'fault' in r ? r.detail : null,
    // The two halves of the point, as numbers: the bytecode is identical, so a bytecode-only check
    // passes; the artifact hash is not, so ours does not.
    bytecodeIdenticalToReal: decoyDispatch.bytecode === realDispatch.bytecode,
    bytecodeIdenticalToChain:
      Buffer.from(decoyDispatch.bytecode, 'base64')
        .equals(Buffer.from(feeJuiceClass.packedBytecode, 'base64')),
    decoyArtifactHash: (await artifactCrypto.computeArtifactHash(
      artifactCrypto.loadContractArtifact(decoy))).toString(),
    chainArtifactHash: feeJuiceClass.artifactHash,
  };
}

// ---------------------------------------------------------------------------------------------
// ARM: uncommittedDebugSymbols — THE ARM THAT PASSES, AND WHY THE PROVENANCE RECORD EXISTS.
// ---------------------------------------------------------------------------------------------
//
// Same artifact, same bytecode, same name, same everything `artifactHash` commits to — with the
// `debug_symbols` of `public_dispatch` rewritten so that every pc maps to the FIRST location in the
// tree instead of its own. All three checks pass. The resolver reports `resolved: true`. The only
// thing that differs is `debugDigest`, which is exactly the number corroboration is counted on.
{
  const tampered = JSON.parse(JSON.stringify(feeJuiceRaw));
  const dispatch = tampered.functions.find(f => f.name === 'public_dispatch');
  const decoded = JSON.parse(
    inflateRawSync(Buffer.from(dispatch.debug_symbols, 'base64')).toString('utf8'));
  const info = decoded.debug_infos[0];
  for (const fnId of Object.keys(info.brillig_locations)) {
    for (const pc of Object.keys(info.brillig_locations[fnId])) {
      info.brillig_locations[fnId][pc] = 0;
    }
  }
  dispatch.debug_symbols = deflateRawSync(Buffer.from(JSON.stringify(decoded), 'utf8'))
    .toString('base64');

  const honest = await verifyCandidate(
    candidate('npm', 'installed', feeJuiceRaw), feeJuiceClass, artifactCrypto);
  const lying = await verifyCandidate(
    candidate('a-second-registry', 'same artifact, rewritten debug_symbols', tampered),
    feeJuiceClass, artifactCrypto);

  out.uncommitted = {
    honestVerified: !('fault' in honest),
    tamperedVerified: !('fault' in lying),
    tamperedFault: 'fault' in lying ? lying.fault : null,
    sameArtifactHash: !('fault' in lying) && lying.artifactHash === honest.artifactHash,
    sameClassId: !('fault' in lying) && lying.contractClassId === honest.contractClassId,
    differentDebugDigest: !('fault' in lying) && lying.debugDigest !== honest.debugDigest,
    honestDebugDigest: 'fault' in honest ? null : honest.debugDigest,
    tamperedDebugDigest: 'fault' in lying ? null : lying.debugDigest,
  };

  // And what the resolver DOES with two verifying candidates that disagree about the source: it
  // reports `single-distributor` — because no two distributors agree — and names the other digest
  // in the reason rather than dropping it.
  const disagreeing = await resolveContractArtifact(
    chains['aztec-testnet'].contracts.feeJuice.address, feeJuiceClass,
    [staticProvider([
      candidate('npm', 'installed', feeJuiceRaw),
      candidate('a-second-registry', 'same artifact, rewritten debug_symbols', tampered),
    ])],
    artifactCrypto,
  );
  out.uncommitted.disagreeingResolved = disagreeing.resolved;
  out.uncommitted.disagreeingCorroboration = disagreeing.resolved ? disagreeing.corroboration : null;
  out.uncommitted.disagreeingAgreeing = disagreeing.resolved ? disagreeing.agreeing.length : 0;
  out.uncommitted.disagreeingReason = disagreeing.reason;

  // The control for that: the SAME artifact offered by two distributors agrees, so it corroborates.
  const agreeing = await resolveContractArtifact(
    chains['aztec-testnet'].contracts.feeJuice.address, feeJuiceClass,
    [staticProvider([
      candidate('npm', 'installed', feeJuiceRaw),
      candidate('a-second-registry', 'the same bytes, independently served', feeJuiceRaw),
    ])],
    artifactCrypto,
  );
  out.uncommitted.agreeingCorroboration = agreeing.resolved ? agreeing.corroboration : null;
  out.uncommitted.agreeingDistributors = agreeing.resolved ? agreeing.agreeingDistributors : [];
}

// ---------------------------------------------------------------------------------------------
// ARM: requireCorroboration — the strict policy is CODE and this runs it.
// ---------------------------------------------------------------------------------------------
{
  const strict = await resolveContractArtifact(
    chains['aztec-testnet'].contracts.feeJuice.address, feeJuiceClass,
    [packageArtifactProvider([installed])], artifactCrypto, { requireCorroboration: true });
  out.strict = { resolved: strict.resolved, reason: strict.reason };
}

// ---------------------------------------------------------------------------------------------
// ARM: control — the third-party token class, over the same providers.
// ---------------------------------------------------------------------------------------------
//
// **THE CONTROL IS THE SAME RESOLVER OVER A DIFFERENT SUBJECT, NOT A SECOND EXPRESSION.** Without
// it, every assertion above is satisfied by a resolver that says `resolved: true` to everything.
{
  const r = await resolveContractArtifact(
    chains['aztec-testnet'].contracts.thirdPartyToken.address, tokenClass,
    [packageArtifactProvider([installed])], artifactCrypto);
  out.control = {
    resolved: r.resolved,
    candidatesConsidered: r.resolved ? null : r.candidatesConsidered,
    reason: r.reason,
    chainClassId: tokenClass.id,
    chainBytecodeBytes: Buffer.from(tokenClass.packedBytecode, 'base64').length,
  };
}

console.log(JSON.stringify(out, null, 2));
