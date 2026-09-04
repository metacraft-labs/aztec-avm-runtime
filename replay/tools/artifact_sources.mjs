// artifact_sources.mjs — THE FILESYSTEM HALF OF L5's ARTIFACT RESOLUTION, AND IT IS IN A TOOL
// BECAUSE `replay/src` MAY NOT READ A FILE.
//
// `verify_browser_replay_dd9_clean` walks the import graph of the bundle L4 builds out of
// `replay/src`, and a `node:fs` import in that directory is a build failure four layers from the
// line that caused it. `artifact_providers.ts` therefore takes a package's artifacts as
// already-parsed JSON; this is what parses them, plus the binding of `ArtifactCrypto` to the
// `@aztec/stdlib` THIS TREE INSTALLS.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE INSTALLED PACKAGE IS A SOURCE AND IT IS THE DEFAULT, WHICH MAKES THE COMMON CASE OFFLINE.
//
// `replay/package.json` already depends on `@aztec/protocol-contracts` — declared for
// `protocolContractsHash` re-derivation, and its note says "L1 will need it for real". L5 is where
// that comes true. Reading the installed release means the recording path reaches no network for a
// protocol contract, which matters twice: `just verify-l3` is an OFFLINE floor, and a check that
// needs somebody else's registry is a check that goes red on somebody else's schedule.
//
// **AND THE INSTALLED RELEASE IS NOT TRUSTED FOR BEING INSTALLED.** It is offered as a candidate
// and it either reproduces the class's `artifactHash`, its `packedBytecode` and its class id, or it
// is rejected by name. Measured on 2026-09-01: the installed `5.3.0-nightly.20260819` reproduces
// the deployed FeeJuice exactly; `5.2.0` does too; `5.0.0-rc.2` does NOT, while shipping
// byte-identical bytecode. The install is a convenience about WHERE to look and never about
// whether the answer is right.

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadContractArtifact, parseDebugSymbols } from '@aztec/stdlib/abi';
import {
  computeArtifactHash,
  computeContractClassId,
  computePublicBytecodeCommitment,
} from '@aztec/stdlib/contract';
import { Fr } from '@aztec/foundation/curves/bn254';
import { sha256 } from '@aztec/foundation/crypto/sha256';

import {
  AZTECSCAN_BASE_URLS,
  aztecscanArtifactProvider,
  packageArtifactProvider,
  stdlibArtifactCrypto,
} from '../src/artifact_providers.ts';

const HERE = dirname(fileURLToPath(import.meta.url));

/**
 * `ArtifactCrypto`, bound to the functions this tree's `@aztec/stdlib` exports.
 *
 * One binding, exported once, so nothing in this repository can end up with two — which is the
 * failure `replay/package.json`'s note describes for `Fr` and which cost a milestone once already.
 */
export const artifactCrypto = stdlibArtifactCrypto({
  loadContractArtifact,
  computeArtifactHash,
  computePublicBytecodeCommitment,
  computeContractClassId,
  Fr,
  parseDebugSymbols,
  sha256,
});

/**
 * Read one npm package release's `artifacts/*.json` off disk.
 *
 * `.d.json.ts` siblings are excluded by extension rather than by a name filter: they are TypeScript
 * declaration files whose name ends in `.json.ts`, and a `endsWith('.json')` test lets them through
 * as artifacts that then fail to parse. That is a one-line trap and it is written down because the
 * failure it produces — "the package has 6 artifacts and 3 of them are broken" — reads like a
 * finding about npm.
 */
export function readPackageArtifacts(packageRoot, packageName) {
  const dir = join(packageRoot, 'artifacts');
  if (!existsSync(dir)) {
    throw new Error(`${packageName}: no artifacts/ under ${packageRoot}. This package release does `
      + 'not ship compiled contracts, so it cannot be an artifact source.');
  }
  const version = JSON.parse(readFileSync(join(packageRoot, 'package.json'), 'utf8')).version;
  const artifacts = {};
  for (const file of readdirSync(dir).sort()) {
    if (!file.endsWith('.json') || file.endsWith('.d.json.ts')) continue;
    artifacts[file.replace(/\.json$/, '')] = JSON.parse(readFileSync(join(dir, file), 'utf8'));
  }
  const count = Object.keys(artifacts).length;
  if (count === 0) {
    throw new Error(`${packageName}@${version}: artifacts/ holds no .json artifact. An artifact `
      + 'source that offers nothing is indistinguishable from one that was never asked, and a '
      + 'resolver over zero candidates reports "unresolved" for a reason that is about this tool.');
  }
  return { packageName, version, artifacts };
}

/** The installed `@aztec/protocol-contracts`, resolved from this file rather than from `cwd`. */
export function installedProtocolContracts() {
  return readPackageArtifacts(
    join(HERE, '..', 'node_modules', '@aztec', 'protocol-contracts'),
    '@aztec/protocol-contracts',
  );
}

/**
 * Upstream's `ContractClassPublic` as `ContractClassPublicLike` — four strings, one of them base64.
 *
 * THE CONVERSION IS HERE AND NOT IN `replay/src` because it is the one place that touches
 * upstream's `Fr` and `Buffer` classes, and L0's invariant is that nothing in `replay/src` declares
 * a wire type. `artifact_resolution.ts` reads strings, so it can be driven from a fixture with no
 * `@aztec` install at all — which is what makes the arms run offline.
 */
export function contractClassPublicLike(contractClass) {
  return {
    id: contractClass.id.toString(),
    artifactHash: contractClass.artifactHash.toString(),
    privateFunctionsRoot: contractClass.privateFunctionsRoot.toString(),
    packedBytecode: Buffer.from(contractClass.packedBytecode).toString('base64'),
  };
}

/**
 * The provider list a live-chain recording uses, and why it is exactly these two.
 *
 * 1. **The installed `@aztec/protocol-contracts`.** Offline, and it is the only source that serves
 *    the FeeJuice class deployed at `0x…03` — Aztecscan's `/l2/artifacts/0x1a57ff2a…` answered 404
 *    on both of its deployments on 2026-09-01, because a protocol contract is deployed at genesis
 *    and never registered through `ContractClassRegistry`, so the explorer has no class row for it.
 * 2. **Aztecscan, when a chain is named.** The only source for a THIRD-PARTY class, and the one
 *    whose `snake_case` artifacts verified exactly when driven over its three testnet `Train`
 *    classes. It is a candidate generator and not an authority — see the provider's own doc.
 *
 * `chain` may be omitted, and then the resolver is offline and says so by having asked one source.
 */
export function liveChainProviders({ chain, fetchImpl, extraReleases = [] } = {}) {
  const providers = [
    packageArtifactProvider([installedProtocolContracts(), ...extraReleases]),
  ];
  const base = chain === undefined ? undefined : AZTECSCAN_BASE_URLS[chain];
  if (chain !== undefined && base === undefined) {
    throw new Error(`no Aztecscan deployment is known for chain '${chain}'. Known: `
      + `${Object.keys(AZTECSCAN_BASE_URLS).join(', ')}. Refusing to guess a base URL: a wrong one `
      + 'answers 404 for every class, which is indistinguishable from an explorer that verifies '
      + 'nothing.');
  }
  if (base !== undefined) providers.push(aztecscanArtifactProvider({ baseUrl: base, fetchImpl }));
  return providers;
}

// =================================================================================================
// THE ARTIFACT CAPTURE — THE HALF OF A REPLAY THAT THE JSON-RPC FIXTURE DOES NOT HOLD
// =================================================================================================
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// WHY THIS EXISTS, AND IT IS THE DEFECT THAT COST THIS CAMPAIGN A CONTAINER.
//
// `settled_fixture.ts` records the JSON-RPC transport, so a captured fixture holds the transaction
// BODY — the one thing a node serves for about an hour and then deletes. That is the part with a
// deadline and it was already solved.
//
// It is not the whole of what a source-level re-record consumes. `replay_settled_transaction.mjs`
// resolves each contract's artifact through `liveChainProviders`, and in `--fixture` mode it passes
// `chain: undefined` on purpose — reaching an explorer from an offline check would make the floor
// depend on somebody else's uptime. The consequence, stated plainly because it was discovered
// rather than declared: **a fixture playback resolves whatever the CURRENTLY INSTALLED
// `@aztec/protocol-contracts` happens to hold, and nothing else.** So
//
//   * a transaction against a THIRD-PARTY class re-records with no artifact at all, which drops the
//     session from rung 1 to rung 3, drops the columns, drops the source positions, and therefore
//     drops every Noir frame — the container is not the same container, and the difference reads as
//     a recorder regression rather than as a missing input;
//   * even for a protocol class, `npm ci` in a fresh worktree resolves the version in
//     `package.json` TODAY. The recording that produced the published container named
//     `npm:@aztec/protocol-contracts@5.3.0-nightly.20260819 FeeJuice`; a re-record a month later
//     against a different nightly either fails `artifact-hash-mismatch` or silently proves a
//     different debug map, and `debugDigest` is exactly the field `artifactHash` does not commit to.
//
// A fixture that cannot reproduce its own container is a fixture that has never been used, and the
// campaign brief's rule is that such a thing is not a fixture.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// WHAT IS CAPTURED: THE CANDIDATES, NOT THE VERDICT.
//
// The recorded unit is the `ArtifactCandidate` — `{distributor, origin, raw}` — exactly as the
// provider answered it, INCLUDING the ones that went on to be rejected. Three consequences, and
// each is the reason for the choice:
//
//   1. **A captured artifact is not trusted for being captured.** Playback feeds the same raw
//      payloads through the same `verifyCandidate`, so `artifactHash`, `packedBytecode` and the
//      recomputed class id are re-proved offline against the class the fixture's own JSON-RPC
//      recording answers. A tampered capture fails by name. This mirrors `artifact_sources.mjs`'s
//      standing rule that the installed release "is not trusted for being installed".
//   2. **The rejections are evidence.** `resolveContractArtifact` keeps every rejection because
//      "three providers answered nothing" and "three providers each answered the wrong release" are
//      different facts. Dropping the rejected candidates from the capture would make a replayed
//      resolution report a cleaner world than the live one did.
//   3. **`corroboration` survives.** It is derived from how many DISTINCT distributors attest the
//      same `debugDigest`. Capturing only the winner would turn `corroborated` into
//      `single-distributor` on every playback — a measurement quietly downgraded by the act of
//      recording it.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// A MISS THROWS, FOR `settled_fixture.ts`'s REASON EXACTLY.
//
// A captured provider asked for a class it does not carry must NOT answer "no candidates". That
// answer is indistinguishable from "nobody on earth publishes this artifact", which is the sentence
// a transaction page prints — a fact about our recording served as a fact about the world. So it
// throws `ArtifactCaptureMiss`, and `resolveContractArtifact` records the throw as a
// `provider-error` candidate with the message attached, which is visible in the report rather than
// silently absent from it.

/** The format tag. A capture that does not carry this exact string is refused, never guessed at. */
export const ARTIFACT_CAPTURE_FORMAT = 'replay-artifact-candidates/1';

/** Raised when a captured provider is asked for a class the capture does not carry. */
export class ArtifactCaptureMiss extends Error {
  constructor(message) {
    super(message);
    this.name = 'ArtifactCaptureMiss';
  }
}

/**
 * Wrap a provider so that everything it answers is kept, keyed by the class it was asked about.
 *
 * The recorded shape is the provider's own return value and not a summary of it: the point is that
 * playback can hand `verifyCandidate` the identical bytes. `raw` goes through `JSON.stringify` on
 * the way out, which is lossless for every shape either shipped provider produces — the npm
 * provider reads parsed JSON off disk and the Aztecscan provider returns `response.json()`, so
 * neither ever holds a live `Buffer` at this layer. (`verifyCandidate` is where Buffers appear, via
 * `loadContractArtifact` or `reviveBuffers`, and that runs identically on both sides.)
 */
export function recordingArtifactProvider(provider, sink) {
  return async (contractClass) => {
    const candidates = await provider(contractClass);
    const bucket = sink.byClassId[contractClass.id] ?? (sink.byClassId[contractClass.id] = {
      class: {
        id: contractClass.id,
        artifactHash: contractClass.artifactHash,
        privateFunctionsRoot: contractClass.privateFunctionsRoot,
        packedBytecode: contractClass.packedBytecode,
      },
      candidates: [],
    });
    for (const c of candidates) {
      bucket.candidates.push({ distributor: c.distributor, origin: c.origin, raw: c.raw });
    }
    return candidates;
  };
}

/** A fresh sink for {@link recordingArtifactProvider}. */
export function artifactCaptureSink() {
  return { byClassId: {} };
}

/**
 * Turn a sink into the committed document, with its provenance.
 *
 * `capturedAt` and `txHash` are here for the same reason `FixtureProvenance` requires every field:
 * an unlabelled capture beside a labelled fixture is the failure mode this repository is shaped to
 * avoid, and an artifact capture is the more tempting one to leave unlabelled because it looks like
 * a cache.
 */
export function artifactCaptureDocument(sink, provenance) {
  const classes = Object.entries(sink.byClassId).map(([id, v]) => ({
    contractClassId: id,
    class: v.class,
    candidates: v.candidates,
  }));
  return {
    format: ARTIFACT_CAPTURE_FORMAT,
    provenance: {
      ...provenance,
      capturedBy: 'replay/tools/replay_settled_transaction.mjs --artifacts',
      note:
        'Candidate artifacts as the providers answered them at capture time, INCLUDING candidates '
        + 'that were rejected. Playback re-verifies every one of them through the same '
        + '`verifyCandidate`; nothing here is trusted for being in this file. See '
        + '`artifact_sources.mjs` for why the candidates and not the verdict are what is stored.',
    },
    classes,
  };
}

/** Parse and check a capture document, refusing anything whose shape is not the declared one. */
export function loadArtifactCapture(parsed, path) {
  const bad = (why) => {
    throw new Error(`${path}: ${why}. An artifact capture whose shape is not the declared one is `
      + 'refused rather than partially read: a capture read as empty is indistinguishable from a '
      + 'world in which nobody publishes these artifacts.');
  };
  if (parsed === null || typeof parsed !== 'object') bad('not a JSON object');
  if (parsed.format !== ARTIFACT_CAPTURE_FORMAT) {
    bad(`format is ${JSON.stringify(parsed.format)}, expected ${JSON.stringify(ARTIFACT_CAPTURE_FORMAT)}`);
  }
  if (!Array.isArray(parsed.classes)) bad('there is no `classes` array');
  for (const entry of parsed.classes) {
    if (typeof entry?.contractClassId !== 'string') bad('a class entry has no `contractClassId`');
    if (!Array.isArray(entry.candidates)) bad(`class ${entry.contractClassId} has no candidate array`);
  }
  if (typeof parsed.provenance?.capturedAt !== 'string') bad('provenance.capturedAt is missing');
  return parsed;
}

/**
 * The provider list for a playback: one provider per recorded distributor, in the recorded order.
 *
 * **ONE PROVIDER PER DISTRIBUTOR, NOT ONE PROVIDER FOR EVERYTHING.** `corroboration` counts
 * distinct distributors, and collapsing every candidate into a single provider would not change
 * that count — but the ORDER providers are asked in decides which verified candidate wins, and
 * `resolveContractArtifact`'s winner is "the first verified candidate". Replaying the distributors
 * separately, in their captured order, reproduces the same winner and therefore the same
 * `debugDigest`, which is the field that decides what source text the container interns.
 *
 * A `provider-error` pseudo-candidate is NOT replayed as a candidate — it was never one. It is
 * re-raised as the error it recorded, so a playback of a run in which the explorer was down
 * reports the explorer being down rather than reporting an explorer that held nothing.
 */
export function capturedArtifactProviders(capture) {
  const byClassId = new Map(capture.classes.map(c => [c.contractClassId, c]));
  const distributors = [...new Set(capture.classes.flatMap(
    c => c.candidates.map(x => x.distributor)))];
  // A CAPTURE IN WHICH NOTHING WAS OFFERED STILL GETS ONE PROVIDER, and the reason is the miss
  // check below. `[]` providers would mean the guard never runs, so a capture taken for a
  // DIFFERENT transaction would replay as "0 candidates considered" — which is what an honest
  // unresolvable class looks like. A recording pointed at the wrong subject must not be able to
  // impersonate a correct recording of an unpublished contract.
  if (distributors.length === 0) distributors.push('none-offered');
  return distributors.map(distributor => async (contractClass) => {
    const entry = byClassId.get(contractClass.id);
    if (entry === undefined) {
      throw new ArtifactCaptureMiss(
        `this artifact capture carries no candidates for class ${contractClass.id}. It holds `
        + `${byClassId.size} class(es): ${[...byClassId.keys()].join(', ')}. REFUSED rather than `
        + 'answered as "no artifact": an incomplete capture reported as an empty world would make '
        + 'the recording declare rung 3 for a contract whose artifact was proved when it was '
        + 'captured, and the container would differ from the published one for a reason that has '
        + 'nothing to do with the chain.');
    }
    const mine = entry.candidates.filter(c => c.distributor === distributor);
    const failure = mine.find(c => c.distributor === 'provider-error');
    if (failure !== undefined) throw new Error(failure.origin);
    return mine.map(c => ({ distributor: c.distributor, origin: c.origin, raw: c.raw }));
  });
}
