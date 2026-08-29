// settled_fixture.ts — a live chain, recorded at the TRANSPORT and replayed at the TRANSPORT.
//
// L1's deliverable is "fixtures captured from a live chain and committed, so the suite runs without
// a network, with the capture script committed beside them". This module is the format, the
// recorder and the player, declared ONCE — because two implementations of one wire format is how a
// fixture and the code that reads it come to agree with each other and with nothing else.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// WHY THIS FILE IS IN `replay/tools/` AND NOT IN `replay/src/`, AND L0'S OWN CHECK IS WHY.
//
// It was written in `replay/src/` first. `verify_client_uses_upstream_schema` went red on
// `…and replay/src does not declare [jsonrpc]  expected [0], got [1]` — L0's deliverable is that
// NOTHING IN `replay/src` DECLARES A WIRE TYPE, asserted by a scanner shown to be able to find a
// planted one, and the player below assembles a JSON-RPC response envelope by hand. The scanner was
// right and the file was in the wrong place: a fixture recorder is test infrastructure, not part of
// the client a browser ships, and putting it beside the client would have cost the invariant that
// says the client's request and response types are upstream's alone.
//
// So it lives beside the capture script that uses it. `replay/tsconfig.json` includes `tools/` so
// it is still type-checked by `just typecheck-replay`, and `replay/src/index.ts` does NOT
// re-export it — a consumer of the replay client cannot reach a fixture player by accident.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// WHY THE TRANSPORT AND NOT THE OBJECTS.
//
// The obvious fixture is a JSON dump of a `Tx` and a `TxEffect`. It is the wrong seam, for the
// reason L0's whole schema deliverable exists: the moment a check loads objects it deserialised
// itself, upstream's zod schemas have stopped running, and a fixture that has drifted from the
// schema reads exactly like a fixture that has not. This campaign has shipped an absence measured
// against a tree that excluded its subject twice; a fixture that its own reader validates is the
// same shape.
//
// So a fixture is a recording of `JsonRpcFetch` — upstream's own transport function type — and
// playing it back drives THE REAL `createReplayNodeClient`, over THE REAL `AztecNodeApiSchema`,
// with upstream's zod validating every stored response on every run. A fixture whose bytes the
// schema rejects fails LOUDLY, in the check, naming the method. That is the property that makes a
// committed fixture worth more than a network call.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// A MISS IS `FixtureMiss` AND IT MUST NOT LOOK LIKE AN ANSWER.
//
// The dangerous direction is a fixture that answers `undefined` for a request it does not carry:
// `fetchSettledTx` turns `undefined` into `SettledTransactionNotFound`, so an INCOMPLETE FIXTURE
// would read as "the chain does not have this transaction" — a fact about our recording reported as
// a fact about the chain. That is precisely the collapse L0's three refusal classes exist to
// prevent, one layer down.
//
// A miss therefore THROWS, out of the fetch, before any response is assembled. The replay client's
// own fetch wrapper catches it and re-throws `NodeUnreachable` with the `FixtureMiss` as its
// `cause` — which is the right classification and not an accident: a request the recording does not
// carry is a request for which no answer came back. Nothing was found or not found.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE VERSION HEADERS ARE RECORDED IN BOTH SHAPES, BECAUSE THE PROXY MAKES THEM DIFFER.
//
// L0 measured that dRPC's proxy returns `x-aztec-*` on a single-object JSON-RPC POST and STRIPS
// them on a batch (array) POST, and that upstream's `createAztecNodeClient` always batches. So the
// headers upstream's client actually saw are EMPTY, and `assertProtocolVersion` refuses the
// endpoint naming the absence.
//
// A fixture that quietly stored the single-post headers would make the offline suite pass a version
// check the live endpoint fails — a fixture kinder than the chain it came from, which is the worst
// kind. So the recording carries both, labelled:
//
//   `onBatchPost`        what upstream's client SAW. Empty through a proxy. The default on replay.
//   `onSingleObjectPost` a deliberately un-batched probe, taken by the capture script against the
//                        same endpoint in the same run. It is a RECONSTRUCTION, never what the
//                        client saw, and `headerSource: 'single-object-post'` must be asked for by
//                        name to get it.
//
// Playing back `onBatchPost` reproduces the live refusal offline, which is what a faithful fixture
// does. Playing back `onSingleObjectPost` measures the other half — that with the headers present
// the very same client accepts the very same node — so the caveat is a property of the PROXY and
// not of this repository's version check.

import type { defaultFetch } from '@aztec/foundation/json-rpc/client';

/** The format tag. A fixture that does not carry this exact string is refused rather than guessed at. */
export const SETTLED_FIXTURE_FORMAT = 'replay-settled-transaction-fixture/1' as const;

/** Which recorded header set a player serves. See the header. */
export type FixtureHeaderSource = 'batch-post' | 'single-object-post';

/** One recorded JSON-RPC call: the wire method, its params, and the `result` the node returned. */
export type RecordedCall = {
  /** The namespaced wire method, e.g. `aztec_getTxByHash`. Upstream's spelling, not ours. */
  readonly method: string;
  /** The params array exactly as it went out, already JSON. */
  readonly params: unknown;
  /** The `result` member of the node's JSON-RPC response, exactly as it came back. */
  readonly result: unknown;
};

/**
 * What a fixture says about where it came from.
 *
 * EVERY FIELD IS REQUIRED, and that is the deliverable's own emphasis: "Record provenance per
 * fixture: which endpoint, which block, which transaction, when captured, and what the node
 * reported. Fabricated or unlabelled fixtures are the failure mode this campaign is built to
 * avoid." A fixture missing any of them is refused by `loadSettledFixture`, not defaulted.
 */
export type FixtureProvenance = {
  /** The URL the capture talked to. */
  readonly endpoint: string;
  /** A human name for the chain, e.g. `aztec-testnet`. */
  readonly chain: string;
  /** `getNodeInfo().l1ChainId` at capture time — the field today's protocol pin CANNOT check. */
  readonly l1ChainId: number;
  /** `getNodeInfo().rollupVersion` at capture time. */
  readonly rollupVersion: number;
  /** The rollup contract the node named. */
  readonly l1RollupAddress: string;
  /** `getNodeInfo().nodeVersion`. */
  readonly nodeVersion: string;
  /** ISO 8601, UTC, taken by the capture script. */
  readonly capturedAt: string;
  /** The script that produced this file, as a repository-relative path. */
  readonly capturedBy: string;
  /** The transaction this fixture is a recording of. */
  readonly txHash: string;
  /** The block it settled in, as the node reported it. */
  readonly l2BlockNumber: number;
  /** Its index in that block, as the node reported it. */
  readonly txIndexInBlock: number;
  /** The chain tip when the capture ran, so the fixture's age at capture is on the record. */
  readonly chainTipAtCapture: number;
  /** What the node said about the transaction. Re-derived from `calls` by the checks, never trusted. */
  readonly nodeReported: Readonly<Record<string, unknown>>;
  /** Both header shapes, and the note that explains why there are two. See the module header. */
  readonly versionHeaders: {
    readonly onBatchPost: Readonly<Record<string, string>>;
    readonly onSingleObjectPost: Readonly<Record<string, string>>;
    readonly note: string;
  };
};

export type SettledFixture = {
  readonly format: typeof SETTLED_FIXTURE_FORMAT;
  readonly provenance: FixtureProvenance;
  readonly calls: readonly RecordedCall[];
};

/**
 * A request the recording does not carry.
 *
 * NOT an answer. See the module header: answering `undefined` here would make an incomplete
 * recording read as a chain that does not have the transaction.
 */
export class FixtureMiss extends Error {
  readonly kind = 'replay-fixture-miss' as const;
  readonly method: string;
  readonly params: string;

  constructor(method: string, params: string, known: number) {
    super(
      `the fixture has no recording of ${method}(${params}). It carries ${known} call(s), and this `
        + `is not one of them. THIS IS NOT 'the node does not have it': nothing was found or not `
        + `found, because this recording never asked that question. Re-capture the fixture with the `
        + `call included rather than reading the miss as an answer.`,
    );
    this.name = 'FixtureMiss';
    this.method = method;
    this.params = params;
  }
}

/** A fixture file that is not one. Refused rather than defaulted — an unlabelled fixture is the failure mode. */
export class MalformedFixture extends Error {
  readonly kind = 'replay-malformed-fixture' as const;
  readonly missing: readonly string[];

  constructor(source: string, missing: readonly string[]) {
    super(
      `${source} is not a ${SETTLED_FIXTURE_FORMAT}: missing or empty ${missing.join(', ')}. `
        + `A fixture without complete provenance is refused rather than loaded, because a fixture `
        + `nobody can trace is indistinguishable from one somebody fabricated, and that is the `
        + `failure mode this campaign is built to avoid.`,
    );
    this.name = 'MalformedFixture';
    this.missing = missing;
  }
}

/** The provenance fields every fixture must carry, named so the refusal can list what is absent. */
export const REQUIRED_PROVENANCE_FIELDS = [
  'endpoint',
  'chain',
  'l1ChainId',
  'rollupVersion',
  'l1RollupAddress',
  'nodeVersion',
  'capturedAt',
  'capturedBy',
  'txHash',
  'l2BlockNumber',
  'txIndexInBlock',
  'chainTipAtCapture',
  'nodeReported',
  'versionHeaders',
] as const;

/** The key a request is stored and looked up under. One spelling, used by the recorder and the player. */
export function fixtureCallKey(method: string, params: unknown): string {
  return `${method}(${JSON.stringify(params ?? [])})`;
}

/**
 * Validate a parsed JSON object as a fixture and return it typed.
 *
 * Refuses on the format tag, on an empty call list, and on ANY absent provenance field — the
 * refusal names all of them at once rather than dying on the first, because a fixture with three
 * fields missing should say three.
 */
export function loadSettledFixture(raw: unknown, source: string): SettledFixture {
  const missing: string[] = [];
  const obj = (raw ?? {}) as Record<string, unknown>;
  if (obj['format'] !== SETTLED_FIXTURE_FORMAT) {
    missing.push(`format (expected ${SETTLED_FIXTURE_FORMAT}, got ${String(obj['format'])})`);
  }
  const calls = obj['calls'];
  if (!Array.isArray(calls) || calls.length === 0) {
    missing.push('calls (a non-empty array of recorded JSON-RPC calls)');
  }
  const provenance = (obj['provenance'] ?? {}) as Record<string, unknown>;
  for (const field of REQUIRED_PROVENANCE_FIELDS) {
    const value = provenance[field];
    if (value === undefined || value === null || value === '') {
      missing.push(`provenance.${field}`);
    }
  }
  if (missing.length > 0) {
    throw new MalformedFixture(source, missing);
  }
  return raw as SettledFixture;
}

/**
 * A `JsonRpcFetch` that RECORDS.
 *
 * Wraps a real fetch, forwards every request, and stores each `(method, params) -> result` pair
 * plus the response headers. The recording is per REQUEST rather than per POST, so a batch of five
 * becomes five entries and the fixture does not depend on how upstream happened to batch that day.
 */
export function recordingFetch(
  inner: typeof defaultFetch,
  sink: { calls: RecordedCall[]; batchHeaders: Record<string, string>; headerNames: readonly string[] },
): typeof defaultFetch {
  const seen = new Set<string>();
  return async (host, body, extraHeaders, noRetry, config) => {
    const answer = await inner(host, body, extraHeaders, noRetry, config);
    const requests = Array.isArray(body) ? body : body === undefined ? [] : [body];
    const responses = Array.isArray(answer.response)
      ? answer.response
      : answer.response === undefined
        ? []
        : [answer.response];
    const byId = new Map<unknown, unknown>();
    for (const r of responses as { id?: unknown; result?: unknown }[]) {
      byId.set(r?.id, r?.result);
    }
    for (const req of requests as { id?: unknown; method?: unknown; params?: unknown }[]) {
      if (typeof req?.method !== 'string') {
        continue;
      }
      const key = fixtureCallKey(req.method, req.params);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      sink.calls.push({ method: req.method, params: req.params ?? [], result: byId.get(req.id) ?? null });
    }
    // THE HEADERS UPSTREAM'S CLIENT SAW, on the shape upstream's client sends. Through a proxy this
    // stays empty, and that emptiness is the measurement — see the module header.
    for (const name of sink.headerNames) {
      const value = answer.headers?.get?.(name);
      if (value !== undefined && value !== null) {
        sink.batchHeaders[name] = value;
      }
    }
    return answer;
  };
}

/**
 * A `JsonRpcFetch` that PLAYS a fixture back. No network, no server, no port.
 *
 * `headerSource` decides which recorded header set the client sees, and it defaults to the one the
 * client actually saw. Asking for `single-object-post` is asking for a reconstruction and has to be
 * spelled out.
 */
export function fixtureFetch(
  fixture: SettledFixture,
  options: { headerSource?: FixtureHeaderSource } = {},
): typeof defaultFetch {
  const headerSource = options.headerSource ?? 'batch-post';
  const table = new Map<string, unknown>();
  for (const call of fixture.calls) {
    table.set(fixtureCallKey(call.method, call.params), call.result);
  }
  const headers =
    headerSource === 'single-object-post'
      ? fixture.provenance.versionHeaders.onSingleObjectPost
      : fixture.provenance.versionHeaders.onBatchPost;

  return async (_host, body) => {
    const requests = Array.isArray(body) ? body : body === undefined ? [] : [body];
    const answers = (requests as { id?: unknown; method?: unknown; params?: unknown }[]).map((req) => {
      const method = typeof req?.method === 'string' ? req.method : String(req?.method);
      const key = fixtureCallKey(method, req?.params);
      if (!table.has(key)) {
        // THROWN, not returned. See the module header.
        throw new FixtureMiss(method, JSON.stringify(req?.params ?? []), table.size);
      }
      return { jsonrpc: '2.0', id: req?.id, result: table.get(key) };
    });
    return {
      response: Array.isArray(body) ? answers : answers[0],
      headers: { get: (name: string) => headers[name.toLowerCase()] ?? null },
    };
  };
}
