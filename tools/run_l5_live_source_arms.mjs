#!/usr/bin/env node
// run_l5_live_source_arms.mjs — THE TWO ARTIFACT SOURCES, MEASURED AGAINST THE REAL THING.
//
// **THIS REACHES THE NPM REGISTRY AND A BLOCK EXPLORER ON EVERY RUN AND IS NOT PART OF ANY FLOOR.**
// `verify-l4-net`'s rule, restated: a check that needs a live third party is a check that goes red
// on somebody else's schedule, and folding it into the offline floor makes the floor depend on
// somebody else's uptime.
//
// It exists because three of L5's load-bearing claims are about the world rather than about this
// repository, and a claim about the world that nothing re-takes rots:
//
//   1. **A REAL npm release is a decoy.** `@aztec/protocol-contracts@5.0.0-rc.2`'s `FeeJuice` ships
//      byte-identical public bytecode to the class deployed at `0x…03` under a DIFFERENT artifact
//      hash. The offline arms derive a decoy by renaming a contract; this one is not derived, it is
//      published, and anyone resolving by version string would have taken it.
//   2. **The explorer stores two key shapes**, and which shape you get depends on whether the class
//      was registered through `ContractClassRegistry` (third-party, snake_case) or is a protocol
//      contract the explorer imported from npm (camelCase, JSON-round-tripped).
//   3. **The explorer's own verification is weaker than ours**, measurably: its camelCase artifacts
//      do not reproduce the artifact hash it records for them until their JSON-serialised Buffers
//      are revived, and it records classes it has no artifact for at all.

import { readFileSync } from 'node:fs';
import { mkdtempSync, writeFileSync, createWriteStream } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

import { AZTECSCAN_BASE_URLS } from '../replay/src/artifact_providers.ts';
import { keyShapeOf, verifyCandidate, reviveBuffers } from '../replay/src/index.ts';
import { artifactCrypto, readPackageArtifacts } from '../replay/tools/artifact_sources.mjs';

const FIXTURE = process.argv[2] ?? 'replay/fixtures/chain_contract_classes.json';
const chains = JSON.parse(readFileSync(FIXTURE, 'utf8')).chains;
const feeJuice = chains['aztec-testnet'].contracts.feeJuice;
const token = chains['aztec-testnet'].contracts.thirdPartyToken;
const like = (c) => ({ id: c.id, artifactHash: c.artifactHash,
  privateFunctionsRoot: c.privateFunctionsRoot, packedBytecode: c.packedBytecode });

const TIMEOUT = 120_000;
const out = { fixture: FIXTURE };

// ---------------------------------------------------------------------------------------------
// ARM: npm — the published decoy, and the releases that do reproduce the class.
// ---------------------------------------------------------------------------------------------
const work = mkdtempSync(join(tmpdir(), 'l5-live-'));
const progress = (m) => console.error(`l5-live: ${m}`);
async function fetchRelease(pkg, version) {
  progress(`fetching ${pkg}@${version}`);
  const meta = await (await fetch(
    `https://registry.npmjs.org/${encodeURIComponent(pkg)}/${version}`,
    { signal: AbortSignal.timeout(TIMEOUT) })).json();
  const dir = join(work, `${pkg.replace(/[@/.]/g, '_')}-${version}`);
  execFileSync('mkdir', ['-p', dir]);
  const tgz = `${dir}.tgz`;
  const r = await fetch(meta.dist.tarball, { signal: AbortSignal.timeout(TIMEOUT) });
  await pipeline(Readable.fromWeb(r.body), createWriteStream(tgz));
  execFileSync('tar', ['xzf', tgz, '-C', dir, '--strip-components=1']);
  return readPackageArtifacts(dir, pkg);
}

out.npm = { releases: {} };
// THREE RELEASES AND THE SET IS FIXED, so the loop's membership is knowable and the COUNT is
// asserted rather than "at least one" — trap 4b, whose example was a loop over three trees that
// silently checked one.
const RELEASES = ['5.0.0-rc.2', '5.2.0', '5.3.0-nightly.20260819'];
for (const version of RELEASES) {
  const release = await fetchRelease('@aztec/protocol-contracts', version);
  progress(`verifying ${version}`);
  const raw = release.artifacts.FeeJuice;
  const dispatch = raw.functions.find(f => f.name === 'public_dispatch');
  const verdict = await verifyCandidate(
    { distributor: 'npm', origin: `npm:@aztec/protocol-contracts@${version} FeeJuice`, raw },
    like(feeJuice.class), artifactCrypto);
  out.npm.releases[version] = {
    verified: !('fault' in verdict),
    fault: 'fault' in verdict ? verdict.fault : null,
    artifactHash: 'fault' in verdict
      ? (await artifactCrypto.computeArtifactHash(artifactCrypto.loadContractArtifact(raw))).toString()
      : verdict.artifactHash,
    debugDigest: 'fault' in verdict ? null : verdict.debugDigest,
    // The half that makes it a DECOY rather than merely a mismatch.
    bytecodeBytes: Buffer.from(dispatch.bytecode, 'base64').length,
    bytecodeEqualsChain: Buffer.from(dispatch.bytecode, 'base64')
      .equals(Buffer.from(feeJuice.class.packedBytecode, 'base64')),
    debugSymbolsChars: dispatch.debug_symbols.length,
  };
}
out.npm.chainArtifactHash = feeJuice.class.artifactHash;
out.npm.chainBytecodeBytes = Buffer.from(feeJuice.class.packedBytecode, 'base64').length;

// ---------------------------------------------------------------------------------------------
// ARM: the explorer — the route, the two shapes, and what its own verification is worth.
// ---------------------------------------------------------------------------------------------
const base = AZTECSCAN_BASE_URLS['aztec-testnet'];
out.explorer = { baseUrl: base };

// THE ROUTE EXISTS AND ITS 404 IS DISTINGUISHABLE FROM A MISSING ROUTE. Both are measured, because
// "the explorer has no artifact for this class" and "this URL is wrong" are different findings and
// a check that could not tell them apart would report the second as the first forever.
{
  progress('probing the explorer route');
  const held = await fetch(`${base}/l2/artifacts/${feeJuice.class.artifactHash}`,
    { signal: AbortSignal.timeout(TIMEOUT) });
  const heldBody = await held.text();
  const wrongRoute = await fetch(`${base}/artifacts/${feeJuice.class.artifactHash}`,
    { signal: AbortSignal.timeout(TIMEOUT) });
  const wrongBody = await wrongRoute.text();
  out.explorer.deployedFeeJuice = { status: held.status, bodyLength: heldBody.length };
  out.explorer.wrongRoute = {
    status: wrongRoute.status,
    isExpressNotFound: wrongBody.includes('Cannot GET'),
  };
}

// EVERY CLASS THE EXPLORER LISTS, AND EVERY ARTIFACT IT HOLDS, VERIFIED BY US.
{
  progress('listing the explorer contract classes');
  const classes = await (await fetch(`${base}/l2/contract-classes`,
    { signal: AbortSignal.timeout(TIMEOUT) })).json();
  const named = classes.filter(c => c.artifactContractName);
  out.explorer.classesListed = classes.length;
  out.explorer.classesWithAnArtifactName = named.length;
  out.explorer.artifacts = [];
  for (const c of named) {
    progress(`fetching artifact ${c.artifactContractName} ${c.contractClassId.slice(0, 12)}`);
    const r = await fetch(`${base}/l2/artifacts/${c.artifactHash}`,
      { signal: AbortSignal.timeout(TIMEOUT) });
    if (!r.ok) {
      out.explorer.artifacts.push({ name: c.artifactContractName, status: r.status });
      continue;
    }
    const raw = await r.json();
    const asServed = await verifyCandidate(
      { distributor: 'aztecscan', origin: `aztecscan ${c.artifactContractName}`, raw },
      { id: c.contractClassId, artifactHash: c.artifactHash,
        privateFunctionsRoot: c.privateFunctionsRoot,
        packedBytecode: Buffer.from(c.packedBytecode.data ?? c.packedBytecode).toString('base64') },
      artifactCrypto);
    // WHAT THE HASH WOULD BE WITHOUT THE REVIVAL, AND ONLY FOR THE SHAPE THE QUESTION IS ABOUT.
    //
    // Asking it of a snake_case payload is meaningless — a `NoirCompiledContract` is not a
    // `ContractArtifact` and `computeArtifactHash` over one answers a number about nothing — and
    // the first version of this arm asked it anyway, so all six artifacts reported
    // `revivalWasNeeded: true` and the measurement said nothing. It is `null` for snake_case now,
    // which is a THIRD state rather than a `false` that would read as "revival was not needed".
    let unrevivedHash = null;
    if (keyShapeOf(raw) === 'camelCase') {
      try {
        unrevivedHash = (await artifactCrypto.computeArtifactHash(raw)).toString();
      } catch { unrevivedHash = 'THREW'; }
    }
    out.explorer.artifacts.push({
      name: c.artifactContractName,
      contractClassId: c.contractClassId,
      recordedArtifactHash: c.artifactHash,
      shape: keyShapeOf(raw),
      verified: !('fault' in asServed),
      fault: 'fault' in asServed ? asServed.fault : null,
      unrevivedHash,
      revivalWasNeeded: unrevivedHash === null ? null : unrevivedHash !== c.artifactHash,
    });
  }
  // OUR TWO SUBJECTS, ASKED OF THE EXPLORER DIRECTLY.
  const tokenArtifact = await fetch(`${base}/l2/artifacts/${token.class.artifactHash}`,
    { signal: AbortSignal.timeout(TIMEOUT) });
  out.explorer.thirdPartyToken = { status: tokenArtifact.status };
  const tokenClass = await fetch(
    `${base}/l2/contract-classes/${token.class.id}/versions/1`,
    { signal: AbortSignal.timeout(TIMEOUT) });
  out.explorer.thirdPartyTokenClass = {
    status: tokenClass.status,
    artifactContractName: tokenClass.ok ? (await tokenClass.json()).artifactContractName : 'ERROR',
  };
}

console.log(JSON.stringify(out, null, 2));
