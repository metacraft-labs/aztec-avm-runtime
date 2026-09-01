// artifact_providers.ts — WHERE AN OFF-CHAIN ARTIFACT COMES FROM, AND THE ONE BINDING OF
// `ArtifactCrypto` TO UPSTREAM'S OWN FUNCTIONS.
//
// `artifact_resolution.ts` proves an artifact. This file is the two places one can be fetched from
// and the adapter that lets the prover use upstream's hashes rather than a second spelling of them.
// The split is the one `source_map.ts` already makes and for the same reason: the thing that
// DECIDES must be drivable from a fixture, so the thing that FETCHES cannot be inside it.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// NO `node:fs` HERE, AND THAT IS A CONSTRAINT RATHER THAN AN OVERSIGHT.
//
// L4 bundles `replay/src` into a browser page and `verify_browser_replay_dd9_clean` walks the
// import graph of what it built. A filesystem read in this directory is a build failure four layers
// away from the line that caused it. So the npm provider takes its artifacts as ALREADY-READ JSON
// — `replay/tools/artifact_sources.mjs` does the reading, in a tool, where a tool belongs — and the
// explorer provider uses `fetch`, which both hosts have.

import type {
  ArtifactCandidate,
  ArtifactCrypto,
  ArtifactProvider,
  ContractClassPublicLike,
} from './artifact_resolution.ts';

// ---------------------------------------------------------------------------------------------
// The binding to upstream
// ---------------------------------------------------------------------------------------------

/**
 * The exact upstream functions this campaign's verification is defined in terms of.
 *
 * Passed in rather than imported here for one reason that has already cost this repository a
 * milestone: `replay/` and `orchestration/` install DIFFERENT `@aztec/stdlib` lines, and an `Fr`
 * from the wrong install is not an `Fr` to the right one (`replay/package.json`'s note, and
 * `lib_m21_form_b.sh`). A caller that hands its own install's functions in cannot make that mistake
 * silently; an import here would make it for them.
 */
export interface StdlibBindings {
  loadContractArtifact: (raw: never) => unknown;
  computeArtifactHash: (artifact: never) => Promise<{ toString(): string }>;
  computePublicBytecodeCommitment: (bytecode: never) => Promise<{ toString(): string }>;
  computeContractClassId: (preimage: never) => Promise<{ toString(): string }>;
  Fr: { fromHexString(hex: string): unknown };
  parseDebugSymbols: (debugSymbols: string) => unknown[];
  sha256: (data: never) => Uint8Array;
}

/** Bind {@link ArtifactCrypto} to one install's functions. */
export function stdlibArtifactCrypto(bindings: StdlibBindings): ArtifactCrypto {
  return {
    loadContractArtifact: raw => bindings.loadContractArtifact(raw as never),
    computeArtifactHash: artifact => bindings.computeArtifactHash(artifact as never),
    computePublicBytecodeCommitment: bytecode =>
      bindings.computePublicBytecodeCommitment(bytecode as never),
    computeContractClassId: preimage => bindings.computeContractClassId(preimage as never),
    frFromHexString: hex => bindings.Fr.fromHexString(hex),
    parseDebugSymbols: symbols => bindings.parseDebugSymbols(symbols),
    sha256Hex: bytes =>
      [...bindings.sha256(Buffer.from(bytes) as never)]
        .map(b => b.toString(16).padStart(2, '0'))
        .join(''),
  };
}

// ---------------------------------------------------------------------------------------------
// Provider 1: a package's artifacts, already read
// ---------------------------------------------------------------------------------------------

/** One package release's artifacts, as `{ <contract name>: <parsed JSON> }`. */
export interface PackageArtifacts {
  /** `@aztec/protocol-contracts` */
  readonly packageName: string;
  /** `5.3.0-nightly.20260819` — RECORDED, NEVER TRUSTED. See `artifact_resolution.ts`'s header. */
  readonly version: string;
  readonly artifacts: Readonly<Record<string, unknown>>;
}

/**
 * Offer every artifact in every supplied release as a candidate.
 *
 * **EVERY ARTIFACT, NOT THE ONE WHOSE NAME LOOKS RIGHT.** A resolver that guessed `FeeJuice` from
 * the address would be resolving by convention; offering all of them and letting the three checks
 * choose means the answer is decided by `artifactHash` and by nothing else. The cost is bounded —
 * `@aztec/protocol-contracts` ships three contracts — and the bytecode-length pre-filter below
 * makes the common case one hash rather than three.
 */
export function packageArtifactProvider(
  releases: readonly PackageArtifacts[],
): ArtifactProvider {
  return async (contractClass: ContractClassPublicLike) => {
    const wanted = Buffer.from(contractClass.packedBytecode, 'base64').length;
    const out: ArtifactCandidate[] = [];
    for (const release of releases) {
      for (const [name, raw] of Object.entries(release.artifacts)) {
        // A CHEAP PRE-FILTER AND NOT A CHECK. It skips artifacts whose public bytecode cannot be
        // this class's; anything it lets through is still verified three ways. Skipping on LENGTH
        // is safe in the direction that matters — a wrong length is certainly a wrong artifact —
        // and the pre-filter is written to FAIL OPEN: a shape it cannot measure is offered rather
        // than dropped, because a filter that silently discards the right answer is the one defect
        // this arrangement could introduce.
        const length = publicDispatchLength(raw);
        if (length !== null && length !== wanted) continue;
        out.push({
          distributor: 'npm',
          origin: `npm:${release.packageName}@${release.version} ${name}`,
          raw,
        });
      }
    }
    return out;
  };
}

/** The candidate's `public_dispatch` byte length, or `null` when the shape does not admit one. */
function publicDispatchLength(raw: unknown): number | null {
  if (raw === null || typeof raw !== 'object') return null;
  const fns = (raw as { functions?: unknown }).functions;
  if (!Array.isArray(fns)) return null;
  const dispatch = fns.find(f => (f as { name?: string })?.name === 'public_dispatch') as
    { bytecode?: unknown } | undefined;
  if (dispatch === undefined) return null;
  const bytecode = dispatch.bytecode;
  if (Buffer.isBuffer(bytecode)) return bytecode.length;
  if (typeof bytecode === 'string') return Buffer.from(bytecode, 'base64').length;
  const asJsonBuffer = bytecode as { type?: string; data?: unknown[] } | null;
  if (asJsonBuffer?.type === 'Buffer' && Array.isArray(asJsonBuffer.data)) {
    return asJsonBuffer.data.length;
  }
  return null;
}

// ---------------------------------------------------------------------------------------------
// Provider 2: a block explorer, keyed by the commitment itself
// ---------------------------------------------------------------------------------------------

/**
 * The Aztecscan artifact endpoint, and it is keyed by `artifactHash` — which is the right key.
 *
 * `GET {base}/l2/artifacts/{artifactHash}`. Measured 2026-09-01 on both deployments:
 *
 *   * the route EXISTS — a hash it does not hold answers **404 with an empty body**, while a route
 *     it does not have answers 404 with Express's `Cannot GET …` page. Those are distinguishable
 *     and this provider distinguishes them, because "the explorer has no artifact for this class"
 *     and "this URL is wrong" are different findings and the second one is a bug in us;
 *   * third-party artifacts come back `snake_case`, protocol artifacts `camelCase` — the two shapes
 *     `verifyCandidate` handles;
 *   * **an explorer artifact is a CANDIDATE and not an answer.** Aztecscan's own verification
 *     compares packed public bytecode; it never checks `artifactHash`. Of the six artifacts it
 *     served on testnet at that date, the three `snake_case` ones verified exactly and the three
 *     `camelCase` ones did not until their JSON-serialised Buffers were revived. Trusting the
 *     explorer's own verdict would have taken all six; verifying takes what verifies.
 */
export function aztecscanArtifactProvider(options: {
  readonly baseUrl: string;
  readonly fetchImpl?: typeof fetch;
  readonly timeoutMs?: number;
}): ArtifactProvider {
  const fetchImpl = options.fetchImpl ?? fetch;
  const timeoutMs = options.timeoutMs ?? 60_000;
  return async (contractClass: ContractClassPublicLike) => {
    const url = `${options.baseUrl.replace(/\/+$/, '')}/l2/artifacts/${contractClass.artifactHash}`;
    const response = await fetchImpl(url, { signal: AbortSignal.timeout(timeoutMs) });
    if (!response.ok) {
      const body = await response.text();
      if (body.includes('Cannot GET')) {
        // THE ROUTE ITSELF IS GONE. Raised rather than returned as "no candidates", because a
        // renamed endpoint is indistinguishable from an explorer that verifies nothing, and the
        // second one is a fact about the chain while the first is a fact about this code.
        throw new Error(
          `${url} answered ${response.status} with an Express route-not-found page. The endpoint `
          + 'has moved; this is not "the explorer holds no artifact for this class", which that '
          + 'deployment reports as a 404 with an EMPTY body.');
      }
      return [];
    }
    const raw: unknown = await response.json();
    return [{
      distributor: 'aztecscan',
      origin: `aztecscan:${options.baseUrl} /l2/artifacts/${contractClass.artifactHash}`,
      raw,
    }];
  };
}

/** The two deployments, so a caller picks a chain rather than typing a URL. */
export const AZTECSCAN_BASE_URLS = {
  'aztec-testnet': 'https://api.testnet.aztecscan.xyz/v1/temporary-api-key',
  'aztec-mainnet': 'https://api.aztecscan.xyz/v1/temporary-api-key',
} as const;
