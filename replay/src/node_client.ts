// node_client.ts — L0: the client that talks to a live Aztec node, and what it is allowed to reach.
//
// THE SURFACE IS THE DELIVERABLE. `AztecNode` declares fifty-five methods at the pinned anchor
// (`node_surface.ts` has the derivation, and the correction of the milestone file's "fifty-one");
// a replay needs fourteen. A narrow adapter that REFUSES BY NAME is the difference between a
// dependency and a citation.
//
// EVERYTHING ON THE WIRE IS UPSTREAM'S:
//
//   * the schema is `AztecNodeApiSchema` from `@aztec/stdlib/interfaces/client` — the same object
//     upstream's own `createAztecNodeClient` validates against, so request and response types are
//     upstream's zod schemas and not a hand-written mirror of them;
//   * the client is `createAztecNodeClient`, upstream's factory, which namespaces every method as
//     `aztec_<name>` and installs upstream's own version handler;
//   * the version type is `ComponentsVersions` from `@aztec/stdlib/versioning`, and the mismatch
//     detection is `getVersioningResponseHandler`, which `createAztecNodeClient` wires for us.
//
// Nothing here re-declares a request or a response. `verify_client_uses_upstream_schema` asserts
// that as a SET — the client's method set against `Object.keys(AztecNodeApiSchema)` — with a
// fabricated method name as the control, because upstream's own client throws
// `Unspecified method <name> in client schema` for a name the schema does not carry, and a check
// that never exercises that is a check that could not fail.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THREE REFUSALS, AND THEY MUST NOT COLLAPSE INTO ONE.
//
// "Not found" and "the node is unreachable" are the pair the milestone names, and they are the
// pair a caller most needs kept apart: a replay that reports "no such transaction" when the truth
// is "the network is down" sends the next reader after a transaction hash that is perfectly good.
// A third, the protocol-version mismatch, is worse than either — it is the one where every answer
// LOOKS fine and means something else.
//
//   `NodeUnreachable`             the transport did not produce a JSON-RPC response at all
//   `SettledTransactionNotFound`  the node answered, and its answer was "I do not have that"
//   `ProtocolVersionMismatch`     the node answered, and it is not speaking our protocol
//   `ReplayNodeSurfaceExceeded`   nothing was asked of the node; the CALLER reached out of bounds
//
// Each is a distinct class with a distinct `kind` discriminant, each names the thing it is about
// (the url, the hash, the field), and every one of them is a THROW. A refusal is never a plausible
// value: `getTxByHash` answering `undefined` for a hash the node has never heard of is exactly the
// shape that lets a caller carry on and produce an empty recording, which is indistinguishable
// from a transaction that did nothing.
//
// HOW THE NETWORK CASE IS DETECTED, and it is not by matching a message. Upstream's `sendBatch`
// catches whatever the fetch threw and converts it into a JSON-RPC error object whose `data` field
// IS THE ORIGINAL ERROR, then throws `new Error(message, { cause: error })`. So the thrown error's
// `cause.data` is the very `NodeUnreachable` this module's fetch wrapper constructed — an identity
// comparison, not a string. `test_node_client_refusals_distinguishable` asserts the unwrapping
// works AND that a successful fetch returns, so the mechanism is measured in both directions.

import { defaultFetch } from '@aztec/foundation/json-rpc/client';
import type { TxHash } from '@aztec/stdlib/tx/tx-hash';
import { createAztecNodeClient } from '@aztec/stdlib/interfaces/client';
import type { AztecNode } from '@aztec/stdlib/interfaces/client';
import type { ComponentsVersions } from '@aztec/stdlib/versioning';

import {
  COMPONENTS_VERSION_FIELDS,
  type ComponentsVersionField,
  PINNED_NETWORK,
  PINNED_PROTOCOL_VERSION,
} from './pinned_protocol_version.ts';
import type { AssertReplayClientIsAWitnessSource } from './membership_witness_source.ts';
import { REPLAY_NODE_SURFACE, type ReplayNodeMethod, type ReplayNodeSurface } from './node_surface.ts';
import { ReplayNodeSurfaceExceeded, strictSurface } from './strict_surface.ts';

// ---------------------------------------------------------------------------------------------
// The refusals
// ---------------------------------------------------------------------------------------------

/**
 * The node did not produce a JSON-RPC response at all: DNS failure, connection refused, TLS
 * failure, timeout, or an HTTP status that is not a JSON-RPC answer.
 *
 * All of those are ONE fact — "we did not get an answer" — and none of them is "the node answered
 * and said no". The distinction this class exists for is the one between it and
 * `SettledTransactionNotFound`; sub-dividing "unreachable" further would be inventing structure
 * the transport does not give us. `cause` carries whatever `defaultFetch` threw, so a caller that
 * wants the detail has it without this class pretending to have parsed it.
 */
export class NodeUnreachable extends Error {
  readonly kind = 'replay-node-unreachable' as const;
  readonly url: string;

  constructor(url: string, cause: unknown) {
    super(
      `the Aztec node at ${url} did not answer. This is NOT 'the transaction was not found' — `
        + `nothing was found or not found, because no JSON-RPC response came back at all. `
        + `Underlying failure: ${cause instanceof Error ? cause.message : String(cause)}`,
      { cause },
    );
    this.name = 'NodeUnreachable';
    this.url = url;
  }
}

/**
 * The node answered, and its answer was that it does not have this transaction.
 *
 * A THROW rather than `undefined`, deliberately. Upstream's `getTxByHash` returns `Tx | undefined`
 * and that is the right signature for a general client; for a replay it is the shape that produces
 * a well-formed container with nothing in it. `method` is carried because the three lookups fail
 * for three slightly different reasons — the transaction is not in the node's store, or it is but
 * has no effect recorded — and a caller that gets "not found" should be able to say which question
 * was asked.
 */
export class SettledTransactionNotFound extends Error {
  readonly kind = 'replay-transaction-not-found' as const;
  readonly txHash: string;
  readonly method: string;
  readonly url: string;

  constructor(txHash: string, method: string, url: string) {
    super(
      `the Aztec node at ${url} answered ${method}(${txHash}) with 'not found'. The node IS `
        + `reachable and this is its answer, which is a different fact from the node being `
        + `unreachable; do not collapse the two. A transaction that has not settled, or has been `
        + `pruned, or never existed, all read this way.`,
      undefined,
    );
    this.name = 'SettledTransactionNotFound';
    this.txHash = txHash;
    this.method = method;
    this.url = url;
  }
}

/**
 * The node answered, and it is not speaking the protocol this repository is pinned to.
 *
 * LOUDLY is the deliverable's own word, and the reason is that this is the failure whose symptoms
 * are all plausible: a node one protocol revision away returns well-formed blocks, well-formed
 * transactions and bytecode the AVM will happily start executing, and the first sign of trouble is
 * a divergence somebody attributes to the runtime.
 *
 * The detection is upstream's: `createAztecNodeClient` installs `getVersioningResponseHandler`,
 * which compares the `x-aztec-*` response headers against the expectation on EVERY call and throws
 * `ComponentsVersionsError`. This class re-throws that, naming the field, the pin and what the node
 * said — the field is computed from the headers this module captured, so it is read from the wire
 * rather than parsed out of upstream's message.
 */
export class ProtocolVersionMismatch extends Error {
  readonly kind = 'replay-protocol-version-mismatch' as const;
  readonly url: string;
  readonly field: string;
  readonly expected: string;
  readonly actual: string;

  constructor(url: string, field: string, expected: string, actual: string, cause: unknown) {
    super(
      `the Aztec node at ${url} is not speaking the pinned protocol: ${field} is ${actual} and `
        + `pins.json (live_chain.protocol_version, network ${PINNED_NETWORK}) pins ${expected}. `
        + `REFUSING rather than continuing: a node one protocol revision away returns well-formed `
        + `blocks and bytecode the AVM will execute, and the divergence surfaces later as a fact `
        + `about this runtime instead of a fact about the node.`,
      { cause },
    );
    this.name = 'ProtocolVersionMismatch';
    this.url = url;
    this.field = field;
    this.expected = expected;
    this.actual = actual;
  }
}

export { ReplayNodeSurfaceExceeded } from './strict_surface.ts';

// ---------------------------------------------------------------------------------------------
// The client
// ---------------------------------------------------------------------------------------------

/**
 * The adapter's OWN members, named here so the guard cannot be defeated by adding a field and
 * forgetting to declare it. `constructor` is included for the same reason M21 includes it: a
 * proxied object whose `constructor` throws breaks `instanceof` and every debugging aid.
 */
export const REPLAY_CLIENT_OWN_MEMBERS = [
  'url',
  'expectedProtocolVersion',
  'assertProtocolVersion',
  'observedVersionHeaders',
  'fetchSettledTx',
  'fetchSettledTxEffect',
  'constructor',
] as const;

/** Everything a caller may touch: the fourteen upstream methods plus this adapter's own members. */
export const ALLOWED_SURFACE: readonly string[] = [
  ...REPLAY_NODE_SURFACE,
  ...REPLAY_CLIENT_OWN_MEMBERS,
];

/** What `assertProtocolVersion` reports back: the headers the node sent, per field. */
export type ObservedVersionHeaders = Partial<Record<ComponentsVersionField, string>>;

/**
 * The replay client.
 *
 * `ReplayNodeSurface` is `Pick<AztecNode, …>` over the fourteen — upstream's own narrowing idiom,
 * and every signature in it is upstream's unchanged. The two `fetchSettled*` members are this
 * adapter's, and they are the only place a `undefined` becomes a refusal.
 */
export interface ReplayNodeClient extends ReplayNodeSurface {
  /** The node this client talks to. Carried so a refusal can name it and L3 can record it. */
  readonly url: string;
  /** The pin this client checks the node against. */
  readonly expectedProtocolVersion: Partial<ComponentsVersions>;
  /** The `x-aztec-*` headers seen on the most recent response. Empty before the first call. */
  readonly observedVersionHeaders: ObservedVersionHeaders;
  /**
   * Force one round trip and check the node's protocol version.
   *
   * The check itself happens on EVERY call through upstream's response handler; this exists so a
   * caller can find out BEFORE fetching a transaction, and so "the version was checked" is
   * something a recording can state rather than something that merely did not fail.
   */
  assertProtocolVersion(): Promise<ObservedVersionHeaders>;
  /** `getTxByHash`, with `undefined` turned into `SettledTransactionNotFound`. */
  fetchSettledTx(txHash: TxHash): Promise<NonNullable<Awaited<ReturnType<AztecNode['getTxByHash']>>>>;
  /** `getTxEffect`, with `undefined` turned into `SettledTransactionNotFound`. */
  fetchSettledTxEffect(
    txHash: TxHash,
  ): Promise<NonNullable<Awaited<ReturnType<AztecNode['getTxEffect']>>>>;
}

/** Options. `fetchImpl` exists so a check can drive the client without a network. */
export type ReplayNodeClientOptions = {
  url: string;
  /** Defaults to the pin. A caller passing `{}` is opting OUT of the version check, loudly. */
  expectedProtocolVersion?: Partial<ComponentsVersions>;
  /** Upstream's `JsonRpcFetch` shape. Defaults to `defaultFetch` with no retries. */
  fetchImpl?: typeof defaultFetch;
};

function isComponentsVersionsError(err: unknown): boolean {
  // Upstream's own discriminant, in upstream's own words: `safe_json_rpc_client.js` special-cases
  // this error by `err.name === 'ComponentsVersionsError'` before converting anything else into a
  // JSON-RPC error object, so the name is load-bearing upstream and not merely conventional.
  return !!err && typeof err === 'object' && (err as { name?: unknown }).name === 'ComponentsVersionsError';
}

function unwrapTransportFailure(err: unknown): NodeUnreachable | undefined {
  // `sendBatch` puts the ORIGINAL error into the JSON-RPC error object's `data`, and `request`
  // throws `new Error(message, { cause: errorObject })`. So the instance we constructed is at
  // `err.cause.data`, by identity. No message matching.
  if (!err || typeof err !== 'object') {
    return undefined;
  }
  if (err instanceof NodeUnreachable) {
    return err;
  }
  const cause = (err as { cause?: unknown }).cause;
  if (cause && typeof cause === 'object') {
    const data = (cause as { data?: unknown }).data;
    if (data instanceof NodeUnreachable) {
      return data;
    }
  }
  return undefined;
}

/**
 * Build the replay client.
 *
 * Two objects are built and only one is returned: `raw` is upstream's client, carrying all
 * fifty-five schema methods, and the returned value is `raw` narrowed to fourteen and wrapped in
 * `strictSurface`. The raw one is not exported — `verify_node_client_surface_narrow` builds its
 * own with `createAztecNodeClient` to serve as the CONTROL, so that "the guard refuses forty-one
 * methods" is measured against an object that answers for all fifty-five rather than against an
 * absence.
 */
export function createReplayNodeClient(options: ReplayNodeClientOptions): ReplayNodeClient {
  const { url } = options;
  const expected = options.expectedProtocolVersion ?? PINNED_PROTOCOL_VERSION;
  const fetchImpl = options.fetchImpl ?? defaultFetch;

  const observed: ObservedVersionHeaders = {};

  // The transport wrapper. Two jobs: turn any transport failure into `NodeUnreachable` (an
  // instance upstream will carry through untouched in the JSON-RPC error's `data`), and capture
  // the version headers so a mismatch can name its field from the wire.
  const wrappedFetch: typeof defaultFetch = async (host, body, extraHeaders, noRetry, config) => {
    let answer: Awaited<ReturnType<typeof defaultFetch>>;
    try {
      answer = await fetchImpl(host, body, extraHeaders, noRetry, config);
    } catch (err) {
      throw new NodeUnreachable(host, err);
    }
    for (const field of COMPONENTS_VERSION_FIELDS) {
      const value = answer.headers?.get?.(`x-aztec-${field}`);
      if (value !== undefined && value !== null) {
        observed[field] = value;
      } else {
        delete observed[field];
      }
    }
    return answer;
  };

  // UPSTREAM'S FACTORY, UPSTREAM'S SCHEMA, UPSTREAM'S VERSION HANDLER. `createAztecNodeClient`
  // calls `createSafeJsonRpcClient(url, AztecNodeApiSchema, { namespaceMethods: 'aztec', …,
  // onResponse: getVersioningResponseHandler(versions) })`. Passing `expected` here is what makes
  // the version check happen on every call rather than only when someone remembers to ask.
  const raw: AztecNode = createAztecNodeClient(url, expected, wrappedFetch);

  const classify = (err: unknown): never => {
    const unreachable = unwrapTransportFailure(err);
    if (unreachable) {
      throw unreachable;
    }
    if (isComponentsVersionsError(err)) {
      // Which field, read from the headers this module captured rather than parsed out of the
      // message. If more than one disagrees, the first in upstream's own field order is named —
      // upstream's handler stops at the first too, so the two agree by construction.
      for (const field of COMPONENTS_VERSION_FIELDS) {
        const want = expected[field];
        const got = observed[field];
        if (want !== undefined && got !== undefined && got !== want.toString()) {
          throw new ProtocolVersionMismatch(url, field, want.toString(), got, err);
        }
      }
      // Upstream refused and our own header reading cannot say which field. That is a real state
      // and it is reported as one rather than as a mismatch of an invented field: the headers may
      // have been read on a different batch. Upstream's message is carried verbatim.
      throw new ProtocolVersionMismatch(
        url,
        'unattributed',
        JSON.stringify(expected),
        err instanceof Error ? err.message : String(err),
        err,
      );
    }
    throw err;
  };

  const forwarded = {} as Record<ReplayNodeMethod, unknown>;
  for (const method of REPLAY_NODE_SURFACE) {
    forwarded[method] = async (...args: unknown[]) => {
      try {
        return await (raw[method] as (...a: unknown[]) => Promise<unknown>)(...args);
      } catch (err) {
        return classify(err);
      }
    };
  }

  const client = {
    ...(forwarded as unknown as ReplayNodeSurface),
    url,
    expectedProtocolVersion: expected,
    observedVersionHeaders: observed,

    async assertProtocolVersion(): Promise<ObservedVersionHeaders> {
      // `getNodeInfo` rather than a cheaper call on purpose: it is the one method whose RESULT
      // also carries chain identity (`l1ChainId`, `rollupVersion`, `nodeVersion`), so when the
      // network-level half of the pin is filled in this is where it gets compared. Today it forces
      // the header round trip and returns what the node said.
      await (client as ReplayNodeClient).getNodeInfo();

      // SILENCE IS REFUSED HERE, AND IT IS NOT REFUSED PER CALL, AND THAT IS DELIBERATE.
      // Upstream's `getVersioningResponseHandler` skips a field whose header is absent —
      // `headerValue !== undefined && headerValue !== null && headerValue !== value` — so a node
      // that sends NO `x-aztec-*` headers passes every per-call check in silence. That is the right
      // default for upstream, whose clients talk to many kinds of endpoint, and it is the wrong
      // answer for a deliberate "check the protocol version" call: an unverifiable version reported
      // as a verified one is exactly the quiet failure this class exists for. So the per-call
      // behaviour stays upstream's and THIS call is strict.
      const declared = COMPONENTS_VERSION_FIELDS.filter((f) => expected[f] !== undefined);
      if (declared.length > 0 && declared.every((f) => observed[f] === undefined)) {
        throw new ProtocolVersionMismatch(
          url,
          'absent',
          declared.join(','),
          'the node sent no x-aztec-* version headers at all',
          undefined,
        );
      }
      return { ...observed };
    },

    async fetchSettledTx(txHash: TxHash) {
      const tx = await (client as ReplayNodeClient).getTxByHash(txHash);
      if (tx === undefined || tx === null) {
        throw new SettledTransactionNotFound(txHash.toString(), 'getTxByHash', url);
      }
      return tx;
    },

    async fetchSettledTxEffect(txHash: TxHash) {
      const effect = await (client as ReplayNodeClient).getTxEffect(txHash);
      if (effect === undefined || effect === null) {
        throw new SettledTransactionNotFound(txHash.toString(), 'getTxEffect', url);
      }
      return effect;
    },
  } as unknown as ReplayNodeClient;

  return strictSurface(client, ALLOWED_SURFACE);
}

/**
 * Upstream's client, unnarrowed and unguarded.
 *
 * EXPORTED FOR THE CONTROLS AND FOR NOTHING ELSE, and named so that is impossible to miss. Every
 * one of L0's three checks needs the other side of its own measurement: "the guard refuses
 * `sendTx`" is worth nothing unless something demonstrates that `sendTx` is there to be refused.
 * This campaign has shipped an absence asked of a tree that excluded its subject by construction
 * twice, and a guard without a control is not evidence.
 */
export function createUnguardedNodeClientForControls(
  url: string,
  fetchImpl?: typeof defaultFetch,
): AztecNode {
  return createAztecNodeClient(url, {}, fetchImpl);
}

/**
 * THE SEAM, ASSERTED BY THE COMPILER RATHER THAN BY A COMMENT.
 *
 * `membership_witness_source.ts` declares the shape M35's resident adapters and this campaign's L2
 * both answer. This line says a replay client already satisfies it — so if one of the five witness
 * methods leaves `REPLAY_NODE_SURFACE`, or changes shape upstream, `just typecheck-replay` fails
 * instead of L2 discovering it. It costs nothing at run time; `erasableSyntaxOnly` erases it.
 */
export type ReplayClientIsAWitnessSource = AssertReplayClientIsAWitnessSource<ReplayNodeClient>;
