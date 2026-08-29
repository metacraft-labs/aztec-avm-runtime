// _l0_fake_node.mjs — a node the L0 checks can drive, built out of UPSTREAM'S OWN SERVER.
//
// WHY NOT A HAND-WRITTEN HTTP HANDLER. The point of L0 is that request and response types are
// upstream's. A fake node that assembled JSON by hand would let a check pass over a client that
// had quietly stopped agreeing with the schema — the check and the fake would drift together, and
// nothing would notice. So the fake is:
//
//     createNamespacedSafeJsonRpcServer({ aztec: makeHandler(handler, AztecNodeApiSchema) })
//
// which is `@aztec/foundation`'s own server, validating every REQUEST against the same
// `AztecNodeApiSchema` the client validates every RESPONSE against, and namespacing methods
// `aztec_<name>` exactly as `createAztecNodeClient` expects. A response this fake produces that
// the schema rejects fails HERE rather than looking like a client defect.
//
// The version headers are upstream's too: `getVersioningMiddleware(versions)` from
// `@aztec/stdlib/versioning`, the same middleware a real node installs, emitting `x-aztec-<field>`.
// So the mismatch arm exercises the real mechanism on both ends — upstream's middleware writing
// the headers and upstream's `getVersioningResponseHandler` reading them — and the only thing
// under test is whether the replay client turns the resulting `ComponentsVersionsError` into a
// named refusal.
//
// FIXTURES ARE UPSTREAM'S TOO. `Tx.random()`, `randomIndexedTxEffect()`, `makeBlockHeader()` and
// `randomL1ContractAddresses()` are `@aztec/stdlib`'s own generators, so the bodies that cross the
// wire are objects upstream's schema accepts by construction rather than JSON somebody typed.
//
// The handler records every method it was asked for, in order, so a check can assert that a
// permitted call actually REACHED the node instead of being answered locally — the same reason
// M21's surface probe records boundary calls.

import http from 'node:http';

import { getVersioningMiddleware } from '@aztec/stdlib/versioning';
import { AztecNodeApiSchema } from '@aztec/stdlib/interfaces/client';
import { createNamespacedSafeJsonRpcServer, makeHandler } from '@aztec/foundation/json-rpc/server';

/**
 * Start a fake Aztec node.
 *
 * @param {object} opts
 * @param {Record<string, unknown>} [opts.versions] version headers to emit; `{}` emits none
 * @param {Record<string, Function>} [opts.handlers] method implementations, merged over the defaults
 * @returns {Promise<{url: string, port: number, calls: string[], close: () => Promise<void>}>}
 */
export async function startFakeNode(opts = {}) {
  const calls = [];
  const defaults = await defaultHandlers();
  const impl = { ...defaults, ...(opts.handlers ?? {}) };

  // The handler the schema is applied to. Every method is recorded before it answers, so
  // `calls` is the node's own account of what it was asked — not the client's account of what it
  // sent, which is the same object under test.
  const handler = {};
  for (const [name, fn] of Object.entries(impl)) {
    handler[name] = async (...args) => {
      calls.push(name);
      return await fn(...args);
    };
  }

  const middlewares = [];
  if (opts.versions && Object.keys(opts.versions).length > 0) {
    middlewares.push(getVersioningMiddleware(opts.versions));
  }

  // THE RAW METHOD NAMES, as they appear on the wire, before the server strips the namespace.
  // `createAztecNodeClient` passes `namespaceMethods: 'aztec'`, so a client that is really
  // upstream's sends `aztec_getBlockNumber`. Recording it here is how a check can say that
  // without reading the client's source: the wire is the artefact, the client is the subject.
  const wireMethods = [];
  //
  // Recorded AFTER `next()`, not before it: the body parser is downstream of the middleware stack,
  // so `ctx.request.body` is undefined on the way in and populated on the way out. Measured — the
  // first version of this read it on the way in and recorded an empty list while the calls were
  // plainly arriving, which is the shape of a check that passes over nothing.
  middlewares.push(async (ctx, next) => {
    await next();
    const body = ctx.request?.body;
    for (const call of Array.isArray(body) ? body : body ? [body] : []) {
      if (call && typeof call.method === 'string') {
        wireMethods.push(call.method);
      }
    }
  });

  const rpc = createNamespacedSafeJsonRpcServer(
    { aztec: makeHandler(handler, AztecNodeApiSchema) },
    { middlewares, http200OnError: true },
  );

  const app = rpc.getApp();
  const server = http.createServer(app.callback());
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();

  return {
    url: `http://127.0.0.1:${port}`,
    port,
    calls,
    wireMethods,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}

/**
 * A port nothing is listening on.
 *
 * TAKEN BY BINDING AND RELEASING, not by picking a number. A hard-coded "unused" port is a check
 * that fails on somebody else's machine for a reason that has nothing to do with its subject, and
 * this campaign has paid for state it did not produce more than once.
 */
export async function unusedPort() {
  const server = http.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(() => resolve()));
  return port;
}

/** The default answers. Only the methods a check actually drives are implemented. */
async function defaultHandlers() {
  const { Tx, randomIndexedTxEffect } = await import('@aztec/stdlib/tx');
  const { makeBlockHeader } = await import('@aztec/stdlib/testing');
  const { AppendOnlyTreeSnapshot } = await import('@aztec/stdlib/trees');
  const { BlockHash } = await import('@aztec/stdlib/block');
  const { randomL1ContractAddresses } = await import('@aztec/ethereum/l1-contract-addresses');
  const { AztecAddress } = await import('@aztec/stdlib/aztec-address');
  const { Fr } = await import('@aztec/foundation/curves/bn254');

  const tx = await Tx.random();
  const effect = await randomIndexedTxEffect();

  return {
    getBlockNumber: () => 174,

    getNodeInfo: async () => ({
      nodeVersion: '5.3.0-nightly.20260819',
      l1ChainId: 31337,
      rollupVersion: 1,
      enr: undefined,
      l1ContractAddresses: randomL1ContractAddresses(),
      protocolContractAddresses: {
        classRegistry: await AztecAddress.random(),
        feeJuice: await AztecAddress.random(),
        instanceRegistry: await AztecAddress.random(),
        multiCallEntrypoint: await AztecAddress.random(),
      },
      realProofs: false,
      txsLimits: { gas: { daGas: 1_000_000, l2Gas: 1_000_000 } },
    }),

    getTxByHash: () => tx,
    getTxsByHash: () => [tx],
    getTxEffect: () => effect,

    getBlockData: async () => ({
      header: await makeBlockHeader(1),
      archive: AppendOnlyTreeSnapshot.empty(),
      blockHash: new BlockHash(new Fr(7n)),
      checkpointNumber: 1,
      indexWithinCheckpoint: 0,
    }),
  };
}
