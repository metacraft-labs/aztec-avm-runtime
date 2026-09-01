// artifact_resolution.ts — L5: THE OFF-CHAIN ARTIFACT, FETCHED AND *PROVED* TO BE THE ONE THE
// CHAIN COMMITTED TO.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// WHAT THIS CLOSES, AND WHY THE THING IT CLOSES WAS NEVER A DEFECT.
//
// `recording.ts`'s header states — correctly, and with upstream's own declarations quoted — that an
// Aztec node serves `{ id, privateFunctionsRoot, version, artifactHash, packedBytecode }` and
// nothing else, so **a chain-fetched contract cannot exceed rung 3 FROM THE NODE ALONE**. That
// sentence is still true and this module does not contradict it. What it does is take the escape
// hatch upstream itself names in `artifactHash`'s doc comment — *"intended to be used by clients to
// verify that an OFFCHAIN FETCHED ARTIFACT matches a registered class"* — and build the offchain
// fetch, with the verification that makes it safe.
//
// **THE CHAIN HOLDS A COMMITMENT TO THE ARTIFACT. THIS MODULE PRODUCES A PREIMAGE AND PROVES IT.**
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE THREE CHECKS, AND WHY ALL THREE RUN RATHER THAN THE CHEAPEST ONE.
//
// A candidate artifact is accepted only if ALL of:
//
//   1. **`computeArtifactHash(candidate)` equals the class's `artifactHash`.** The commitment
//      upstream says this field is for.
//   2. **The candidate's `public_dispatch` bytecode is BYTE-EQUAL to the class's
//      `packedBytecode`.** Direct, cheap, and it is the thing the AVM will actually execute.
//   3. **`computeContractClassId({ artifactHash, privateFunctionsRoot, publicBytecodeCommitment })`
//      equals the class's `id`.** The class id is the chain's identity for the code; recomputing it
//      binds (1) and (2) together into the single number the transaction's contract instance names.
//
// **CHECK 2 ALONE IS WHAT AZTECSCAN DOES, AND IT IS NOT ENOUGH — MEASURED, ON THIS EXACT
// CONTRACT.** `@aztec/protocol-contracts@5.0.0-rc.2`'s `FeeJuice` has bytecode BYTE-IDENTICAL to
// the class deployed at address `0x…03` on both testnet and mainnet, and a DIFFERENT
// `artifactHash` (`0x1df228ba…` against the deployed `0x1a57ff2a…`), a different class id
// (`0x2719c550…` against `0x1f85d8b9…`), and different `debug_symbols` (2,968 base64 characters
// against 2,964). A bytecode-only check accepts it. Check 1 and check 3 reject it, and the arms run
// carries it as an arm for exactly that reason: **the wrong debug map over the right bytecode is
// the failure that produces confident wrong line numbers**, which is the one this whole campaign
// exists not to ship.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE VERSION STRING IS NOT EVIDENCE, AND THE NODE'S OWN IS NOT EITHER.
//
// `nodeVersion` on both reachable endpoints reads `5.2.0`. That happens to be a version whose
// `@aztec/protocol-contracts` reproduces the deployed FeeJuice — and `5.3.0-nightly.20260819`, the
// line this package installs, reproduces it too, while `5.0.0-rc.2` does not. **All three ship the
// same bytecode.** So a resolver that picked a package by the node's version string would be right
// here by luck and wrong the moment either side moved, and would have no way to notice. Versions
// are therefore CANDIDATE GENERATORS ONLY: every candidate goes through the same three checks, and
// what is accepted is accepted because of the hashes and not because of where it came from.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// TWO KEY SHAPES BEHIND ONE ENDPOINT, AND A THIRD PROBLEM UNDERNEATH THEM.
//
// An artifact arrives in one of two spellings and this module handles both, ASSERTS that it handles
// both, and refuses a third rather than reading an unfamiliar shape as an absent one:
//
//   `snake_case`   `NoirCompiledContract` — `file_map`, `functions[].debug_symbols`,
//                  `bytecode` as base64. This is what npm ships and what Aztecscan stores for
//                  THIRD-PARTY contracts. `loadContractArtifact` converts it.
//   `camelCase`    `ContractArtifact` — `fileMap`, `functions[].debugSymbols`, `bytecode` as a
//                  Buffer. This is what Aztecscan stores for PROTOCOL contracts.
//
// **AND THE camelCase SHAPE ARRIVES OVER JSON, WHICH BREAKS IT.** A `ContractArtifact`'s
// `bytecode` is a `Buffer`; `JSON.stringify` turns that into `{ type: 'Buffer', data: [...] }` and
// `JSON.parse` leaves it that way. `computeArtifactHash` over the un-revived object answers a
// DIFFERENT HASH — measured on Aztecscan's stored `FeeJuice`: `0x1f9c94f6…` un-revived,
// `0x1df228ba…` revived, and the second is the correct answer for that artifact. So the shape
// question is not "which spelling of the keys" but "which spelling, and are the values still what
// their types say they are". {@link reviveBuffers} is that second half, and without it the
// camelCase branch would report every protocol artifact as failing verification — an absence that
// looks exactly like "the explorer has nothing".
//
// *(Measured 2026-09-01: Aztecscan's stored camelCase `FeeJuice` is byte-for-byte
// `JSON.stringify(loadContractArtifact(npm 5.0.0-rc.2's FeeJuice.json))`. The explorer's protocol
// artifacts come from the same npm packages, round-tripped through JSON.)*
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// WHAT `artifactHash` DOES **NOT** COMMIT TO, AND THE DECISION TAKEN ABOUT IT.
//
// `computeArtifactHash`'s own doc comment gives the preimage: the private-function tree root, the
// utility-function tree root, and `computeArtifactMetadataHash`. **Neither `debug_symbols` nor
// `file_map` is in it.** So the three checks above prove the BYTECODE is the deployed code and
// prove the artifact is the registered one — and the SOURCE TEXT rides along uncommitted.
//
// The consequence is bounded rather than unbounded, and the bound is worth stating because it is
// what makes rung 1 defensible at all: a `brillig_locations` map is keyed by AVM byte offset into
// bytecode this module has just proved byte-equal to the chain's, so a map that pointed anywhere
// else is DETECTABLE — `rungFor` refuses a map whose highest key reaches past the bytecode, and
// `ContractSourceMap.positionFor` answers `null` rather than rounding. What is NOT detectable is a
// `file_map` whose text is wrong for a mapping that is otherwise in range.
//
// **SO THE RECORDING STATES WHICH CASE IT IS, AND {@link SOURCE_CORROBORATION} IS THAT STATEMENT.**
// Two independent DISTRIBUTORS agreeing on the (debug_symbols, file_map) digest is
// `corroborated`; one distributor is `single-distributor`, however many of its releases agree.
// Rung 1 is permitted in both, because refusing it in the second would discard a verified mapping
// over verified bytecode and leave the product with a capability that resolves nothing — but the
// container SAYS which, in `ct.source-provenance`, and `requireCorroboration` exists so the strict
// policy is executable code rather than a paragraph. **The dishonest option — claiming source level
// and not saying where the text came from — is the one that is not available.**

import type { ContractClassPublic } from '@aztec/stdlib/contract';

import type { DebugInfoLike, SourceFile } from '../../ct-host/src/source_map.ts';

// ---------------------------------------------------------------------------------------------
// The shapes
// ---------------------------------------------------------------------------------------------

/**
 * The two spellings an artifact arrives in, named as a closed set.
 *
 * DECLARED AS A SET rather than tested with `'file_map' in raw`, so a check can assert that BOTH
 * are exercised. The research this milestone rests on got its first answer wrong by testing one
 * spelling and reading its absence as the absence of the artifact.
 */
export const ARTIFACT_KEY_SHAPES = ['snake_case', 'camelCase'] as const;
export type ArtifactKeyShape = (typeof ARTIFACT_KEY_SHAPES)[number];

/** Every way a candidate can fail, named rather than collapsed into a boolean. */
export const VERIFICATION_FAULTS = [
  'unrecognised-key-shape',
  'no-public-dispatch',
  'artifact-hash-mismatch',
  'bytecode-mismatch',
  'class-id-mismatch',
  'undecodable-debug-symbols',
] as const;
export type VerificationFault = (typeof VERIFICATION_FAULTS)[number];

/**
 * How well the SOURCE TEXT — the half `artifactHash` does not commit to — is attested.
 *
 * `corroborated` needs two independent DISTRIBUTORS, not two releases: `@aztec/protocol-contracts`
 * at `5.2.0` and at `5.3.0-nightly.20260819` agree byte-for-byte on the digest, and they are one
 * registry's account of itself.
 */
export const SOURCE_CORROBORATION = ['corroborated', 'single-distributor'] as const;
export type SourceCorroboration = (typeof SOURCE_CORROBORATION)[number];

/** One artifact, from one place, before anything has been checked about it. */
export interface ArtifactCandidate {
  /** The distributor, for corroboration counting: `npm`, `aztecscan`, … */
  readonly distributor: string;
  /** The exact provenance, for the record: `npm:@aztec/protocol-contracts@5.3.0-nightly.20260819`. */
  readonly origin: string;
  /** The parsed JSON, in whichever shape it arrived. */
  readonly raw: unknown;
}

/** A candidate that failed, with the reason it failed. Kept, never discarded — see the resolver. */
export interface RejectedCandidate {
  readonly distributor: string;
  readonly origin: string;
  readonly fault: VerificationFault;
  readonly detail: string;
}

/** A candidate that passed all three checks. */
export interface VerifiedArtifact {
  readonly distributor: string;
  readonly origin: string;
  readonly shape: ArtifactKeyShape;
  /** `computeArtifactHash` over the candidate — equal to the class's, or this object would not exist. */
  readonly artifactHash: string;
  /** Recomputed from the artifact's own bytecode and the class's `privateFunctionsRoot`. */
  readonly contractClassId: string;
  /** The `public_dispatch` bytecode, byte-equal to the class's `packedBytecode`. */
  readonly bytecode: Uint8Array;
  /** Decoded through upstream's own `parseDebugSymbols`, never a second spelling of it. */
  readonly debugInfo: DebugInfoLike;
  /** `fileId -> { path, source }`, the input rung 1 needs and rung 2 does not have. */
  readonly files: ReadonlyMap<number, SourceFile>;
  /**
   * A digest over exactly the two things `artifactHash` does NOT commit to.
   *
   * This is the number corroboration is counted on, and it is deliberately NOT `artifactHash`:
   * two artifacts with different `artifactHash`es can carry identical debug info, and two with the
   * same `artifactHash` cannot carry different debug info without one of them being a forgery this
   * module would not have accepted anyway.
   */
  readonly debugDigest: string;
}

/** A contract's artifact, resolved and proved, or not resolved and saying why. */
export type ArtifactResolution =
  | {
      readonly resolved: true;
      readonly address: string;
      readonly contractClassId: string;
      readonly artifact: VerifiedArtifact;
      /** Every verified candidate, in the order the providers answered. */
      readonly agreeing: readonly VerifiedArtifact[];
      readonly corroboration: SourceCorroboration;
      /** Distinct distributors whose verified artifacts share {@link VerifiedArtifact.debugDigest}. */
      readonly agreeingDistributors: readonly string[];
      readonly rejected: readonly RejectedCandidate[];
      readonly reason: string;
    }
  | {
      readonly resolved: false;
      readonly address: string;
      readonly contractClassId: string;
      readonly rejected: readonly RejectedCandidate[];
      readonly candidatesConsidered: number;
      readonly reason: string;
    };

/**
 * A source of candidate artifacts for one contract class.
 *
 * INJECTED rather than imported, for `settled_transaction.ts`'s reason and for one more: a provider
 * that reaches a network is a provider a check cannot run offline, and every check in this campaign
 * that needed somebody else's uptime has been a check that went red on somebody else's schedule.
 * The shipped providers are below; the arms run drives the same resolver over fixed candidates.
 */
export type ArtifactProvider = (
  contractClass: ContractClassPublicLike,
) => Promise<readonly ArtifactCandidate[]>;

/**
 * The half of `ContractClassPublic` this module reads, as plain strings.
 *
 * STRUCTURAL, so the resolver can be driven from a fixture without constructing upstream's `Fr`s —
 * and so `replay/src` continues to declare no wire type of its own, which is L0's invariant.
 */
export interface ContractClassPublicLike {
  readonly id: string;
  readonly artifactHash: string;
  readonly privateFunctionsRoot: string;
  /** base64, exactly as `getContractClass` answers it. */
  readonly packedBytecode: string;
}

// ---------------------------------------------------------------------------------------------
// The shape normalisation
// ---------------------------------------------------------------------------------------------

/**
 * Turn `{ type: 'Buffer', data: [...] }` back into a `Buffer`, recursively.
 *
 * See the module header: without this, every camelCase artifact fetched over JSON hashes to the
 * wrong value and the whole explorer branch reports a clean, plausible, wrong "not verified".
 */
export function reviveBuffers(value: unknown): unknown {
  if (value === null || typeof value !== 'object') return value;
  const asRecord = value as Record<string, unknown>;
  if (asRecord.type === 'Buffer' && Array.isArray(asRecord.data)) {
    return Buffer.from(asRecord.data as number[]);
  }
  if (Array.isArray(value)) return value.map(reviveBuffers);
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(asRecord)) out[k] = reviveBuffers(v);
  return out;
}

/** Which spelling this is, or `null` for a shape neither branch recognises. */
export function keyShapeOf(raw: unknown): ArtifactKeyShape | null {
  if (raw === null || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  if (!Array.isArray(r.functions)) return null;
  // The DISCRIMINANT IS `file_map` / `fileMap` AND NOT the functions' own key, because a contract
  // with no source at all has an empty `file_map` and the functions still carry `debug_symbols`.
  if ('file_map' in r) return 'snake_case';
  if ('fileMap' in r) return 'camelCase';
  return null;
}

// ---------------------------------------------------------------------------------------------
// The verification
// ---------------------------------------------------------------------------------------------

/** The three functions this module needs out of `@aztec/stdlib`, injected so a check can drive it. */
export interface ArtifactCrypto {
  loadContractArtifact: (raw: unknown) => unknown;
  computeArtifactHash: (artifact: unknown) => Promise<{ toString(): string }>;
  computePublicBytecodeCommitment: (bytecode: Buffer) => Promise<{ toString(): string }>;
  computeContractClassId: (preimage: {
    artifactHash: unknown;
    privateFunctionsRoot: unknown;
    publicBytecodeCommitment: unknown;
  }) => Promise<{ toString(): string }>;
  frFromHexString: (hex: string) => unknown;
  parseDebugSymbols: (debugSymbols: string) => unknown[];
  sha256Hex: (bytes: Uint8Array) => string;
}

/**
 * Verify one candidate against one class. Returns the artifact, or the fault that stopped it.
 *
 * EVERY FAULT IS NAMED AND NONE IS A BOOLEAN, because "this candidate did not verify" is the answer
 * a caller can do nothing with: an artifact-hash mismatch means the wrong RELEASE, a bytecode
 * mismatch means the wrong CONTRACT, and an unrecognised shape means the resolver has stopped
 * reading its input — three different things to do about it.
 */
export async function verifyCandidate(
  candidate: ArtifactCandidate,
  contractClass: ContractClassPublicLike,
  crypto: ArtifactCrypto,
): Promise<VerifiedArtifact | RejectedCandidate> {
  const reject = (fault: VerificationFault, detail: string): RejectedCandidate => ({
    distributor: candidate.distributor,
    origin: candidate.origin,
    fault,
    detail,
  });

  const shape = keyShapeOf(candidate.raw);
  if (shape === null) {
    return reject('unrecognised-key-shape',
      'the payload has neither a `file_map` (NoirCompiledContract) nor a `fileMap` '
      + '(ContractArtifact) beside a `functions` array, so it is not an artifact this resolver '
      + 'knows how to read. REPORTED rather than treated as "no artifact": an unrecognised shape '
      + 'and an absent one are the same value and only one of them is a fact about the contract.');
  }

  // snake_case goes through upstream's own loader; camelCase is already loaded and needs its
  // Buffers back. Both end at the same `ContractArtifact`, which is the point of doing it here
  // rather than in each provider.
  let artifact: Record<string, unknown>;
  try {
    artifact = (shape === 'snake_case'
      ? crypto.loadContractArtifact(candidate.raw)
      : reviveBuffers(candidate.raw)) as Record<string, unknown>;
  } catch (err) {
    return reject('unrecognised-key-shape',
      `loading the ${shape} payload threw ${(err as Error)?.name ?? 'an error'}: `
      + `${String((err as Error)?.message).slice(0, 200)}`);
  }

  const functions = (artifact.functions ?? []) as { name?: string; bytecode?: unknown;
    debugSymbols?: string }[];
  const dispatch = functions.find(f => f.name === 'public_dispatch');
  if (dispatch === undefined) {
    return reject('no-public-dispatch',
      `the artifact declares ${functions.length} function(s) and none is \`public_dispatch\`, so `
      + 'it carries no public bytecode to compare against the class\'s `packedBytecode`');
  }

  const bytecode = Buffer.isBuffer(dispatch.bytecode)
    ? dispatch.bytecode
    : Buffer.from(String(dispatch.bytecode), 'base64');
  const chainBytecode = Buffer.from(contractClass.packedBytecode, 'base64');
  if (!bytecode.equals(chainBytecode)) {
    return reject('bytecode-mismatch',
      `the artifact's public_dispatch is ${bytecode.length} byte(s) and the class's `
      + `packedBytecode is ${chainBytecode.length}; they are not the same code`);
  }

  const artifactHash = (await crypto.computeArtifactHash(artifact)).toString();
  if (artifactHash !== contractClass.artifactHash) {
    return reject('artifact-hash-mismatch',
      `computeArtifactHash answers ${artifactHash} and the class commits to `
      + `${contractClass.artifactHash}. THE BYTECODE MATCHED AND THIS DID NOT, which is the case `
      + 'a bytecode-only check accepts: a different release of the same contract, with a '
      + 'different debug map over identical code.');
  }

  const publicBytecodeCommitment = await crypto.computePublicBytecodeCommitment(bytecode);
  const contractClassId = (await crypto.computeContractClassId({
    artifactHash: crypto.frFromHexString(artifactHash),
    privateFunctionsRoot: crypto.frFromHexString(contractClass.privateFunctionsRoot),
    publicBytecodeCommitment,
  })).toString();
  if (contractClassId !== contractClass.id) {
    return reject('class-id-mismatch',
      `recomputing the class id from this artifact gives ${contractClassId} and the chain's `
      + `instance names ${contractClass.id}`);
  }

  // The debug info, through upstream's decoder. `source_map.ts` refuses to re-implement
  // deflate-raw + base64 + JSON and this module refuses for the same reason.
  let debugInfo: DebugInfoLike;
  try {
    const infos = crypto.parseDebugSymbols(String(dispatch.debugSymbols ?? ''));
    if (!Array.isArray(infos) || infos.length === 0) throw new Error('no debug_infos');
    debugInfo = infos[0] as DebugInfoLike;
  } catch (err) {
    return reject('undecodable-debug-symbols',
      `the artifact verified but its public_dispatch debug_symbols did not decode: `
      + `${(err as Error)?.name ?? 'error'} ${String((err as Error)?.message).slice(0, 160)}`);
  }

  const files = new Map<number, SourceFile>();
  for (const [id, entry] of Object.entries(
    (artifact.fileMap ?? {}) as Record<string, { path: string; source: string }>,
  )) {
    files.set(Number(id), { path: entry.path, source: entry.source });
  }

  return {
    distributor: candidate.distributor,
    origin: candidate.origin,
    shape,
    artifactHash,
    contractClassId,
    bytecode,
    debugInfo,
    files,
    debugDigest: debugDigestOf(debugInfo, files, crypto),
  };
}

/**
 * The digest corroboration is counted on: exactly `debug_symbols` and `file_map`, and nothing else.
 *
 * The file entries are sorted by id and rendered as a triple so the digest is a function of the
 * CONTENT rather than of a JSON key order two producers need not share.
 */
export function debugDigestOf(
  debugInfo: DebugInfoLike,
  files: ReadonlyMap<number, SourceFile>,
  crypto: Pick<ArtifactCrypto, 'sha256Hex'>,
): string {
  const canonical = JSON.stringify({
    debugInfo,
    files: [...files.entries()].sort((a, b) => a[0] - b[0]).map(([id, f]) => [id, f.path, f.source]),
  });
  return crypto.sha256Hex(new TextEncoder().encode(canonical));
}

// ---------------------------------------------------------------------------------------------
// The resolution
// ---------------------------------------------------------------------------------------------

export interface ResolveOptions {
  /**
   * Refuse a resolution attested by only one distributor.
   *
   * DEFAULT `false`, and the default is a decision rather than a convenience: as measured on
   * 2026-09-01 the only class any of this campaign's captured containers resolves — FeeJuice at
   * `0x…03`, class `0x1f85d8b9…` — is served by npm and by nothing else, so `true` would ship a
   * capability that resolves zero contracts. `false` resolves it AND makes the container say
   * `corroboration=single-distributor` with the distributor named. The strict policy exists as
   * code, is exercised by the arms run, and is one argument away for a caller who wants it.
   */
  readonly requireCorroboration?: boolean;
}

/**
 * Ask every provider, verify every answer, and report what was proved.
 *
 * **EVERY PROVIDER IS ASKED EVEN AFTER ONE SUCCEEDS.** A resolver that stopped at the first
 * verified candidate could never report `corroborated`, and would make the corroboration field a
 * constant dressed as a measurement — this campaign's most-repeated defect. The cost is one extra
 * fetch per contract; the alternative is a claim nothing can contradict.
 *
 * **AND EVERY REJECTION IS KEPT.** A resolution that failed because three providers each answered
 * `artifact-hash-mismatch` is a different fact from one where three providers answered nothing, and
 * a caller reading only `resolved: false` cannot tell them apart.
 */
export async function resolveContractArtifact(
  address: string,
  contractClass: ContractClassPublicLike,
  providers: readonly ArtifactProvider[],
  crypto: ArtifactCrypto,
  options: ResolveOptions = {},
): Promise<ArtifactResolution> {
  const candidates: ArtifactCandidate[] = [];
  for (const provider of providers) {
    try {
      candidates.push(...(await provider(contractClass)));
    } catch (err) {
      // A provider that throws is a provider that answered nothing, and it is recorded as such
      // rather than aborting the resolution — one unreachable registry must not cost a contract
      // that another registry serves.
      candidates.push({
        distributor: 'provider-error',
        origin: `${(err as Error)?.name ?? 'Error'}: ${String((err as Error)?.message).slice(0, 160)}`,
        raw: null,
      });
    }
  }

  const verified: VerifiedArtifact[] = [];
  const rejected: RejectedCandidate[] = [];
  for (const candidate of candidates) {
    const outcome = await verifyCandidate(candidate, contractClass, crypto);
    if ('fault' in outcome) rejected.push(outcome);
    else verified.push(outcome);
  }

  if (verified.length === 0) {
    return {
      resolved: false,
      address,
      contractClassId: contractClass.id,
      rejected,
      candidatesConsidered: candidates.length,
      reason:
        `no off-chain artifact was proved to be class ${contractClass.id}. `
        + `${candidates.length} candidate(s) were considered and ${rejected.length} rejected`
        + (rejected.length === 0 ? '' : `: ${rejected.map(r => `${r.origin} -> ${r.fault}`).join('; ')}`)
        + '. THE RUNG STAYS 3 AND THE STEPS STAY UNPOSITIONED — a chain-fetched contract whose '
        + 'artifact cannot be proved is exactly the case recording.ts\'s ceiling describes.',
    };
  }

  // The winner is the first verified candidate; every verified candidate agrees on `artifactHash`
  // by construction, so the choice cannot change the bytecode or the class id. It CAN change the
  // debug map — see the digest below — which is why the chosen one is named in the reason.
  const chosen = verified[0]!;
  const agreeingDistributors = [
    ...new Set(verified.filter(v => v.debugDigest === chosen.debugDigest).map(v => v.distributor)),
  ].sort();
  const corroboration: SourceCorroboration =
    agreeingDistributors.length >= 2 ? 'corroborated' : 'single-distributor';

  if (options.requireCorroboration === true && corroboration !== 'corroborated') {
    return {
      resolved: false,
      address,
      contractClassId: contractClass.id,
      rejected,
      candidatesConsidered: candidates.length,
      reason:
        `class ${contractClass.id} WAS proved — ${verified.length} candidate(s) matched its `
        + `artifactHash, its packedBytecode and its class id — but only `
        + `${agreeingDistributors.length} distributor (${agreeingDistributors.join(', ')}) attests `
        + 'its debug_symbols and file_map, and requireCorroboration was set. artifactHash does not '
        + 'commit to either, so a single distributor\'s source text is unverified text, and this '
        + 'caller asked not to claim source level over it.',
    };
  }

  const others = verified.filter(v => v.debugDigest !== chosen.debugDigest);
  return {
    resolved: true,
    address,
    contractClassId: contractClass.id,
    artifact: chosen,
    agreeing: verified,
    corroboration,
    agreeingDistributors,
    rejected,
    reason:
      `class ${contractClass.id} is proved by ${chosen.origin}: computeArtifactHash = `
      + `${chosen.artifactHash} equals the class's, public_dispatch is byte-equal to the class's `
      + `packedBytecode (${chosen.bytecode.length} bytes), and recomputing the class id from them `
      + `returns ${chosen.contractClassId}. artifactHash does NOT commit to debug_symbols or `
      + `file_map, and those are attested by ${agreeingDistributors.length} distributor(s) `
      + `(${agreeingDistributors.join(', ')}) at digest ${chosen.debugDigest.slice(0, 16)}`
      + (others.length === 0
        ? ''
        : `; ${others.length} other verified candidate(s) carry a DIFFERENT debug digest and were `
          + `not used: ${others.map(o => `${o.origin}=${o.debugDigest.slice(0, 16)}`).join(', ')}`),
  };
}
