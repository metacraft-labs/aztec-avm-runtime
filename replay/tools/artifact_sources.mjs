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
