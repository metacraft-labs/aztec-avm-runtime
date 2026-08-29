// run_wallet_arms.mjs — M33's arm run: the wallet protocol boundary, exercised over a real
// `MessageChannel`, against the BUILT bundle.
//
//   node tools/run_wallet_arms.mjs <work-dir>   > <work-dir>/wallet.json
//
// ===========================================================================================
// WHY THE BUNDLE AND NOT THE SOURCES.
// ===========================================================================================
//
// `CAMPAIGN-BRIEF.md`: *"anything asserted must be read from the artefact"* — and one step past it,
// *"ask WHICH artefact. A producer's report about itself is not its output."* The thing M33 ships
// is `browser/dist/wallet.js`, so that is what these arms import. Every refusal, every message type
// and every method name below is a property of the built module; a source file that says the right
// thing and a bundle that does not would be red here.
//
// ===========================================================================================
// WHY NODE AND NOT A BROWSER, STATED AS A BOUNDARY RATHER THAN GLOSSED.
// ===========================================================================================
//
// The transport is a `MessagePort`, which Node and the browser both implement, and the crypto is
// WebCrypto (`globalThis.crypto.subtle`, ECDH P-256 + HKDF + AES-256-GCM), which Node 24 and the
// browser both implement. So the handshake below is the real one on both. What Node CANNOT tell us
// is that the bundle loads in a page — and that is not this file's claim to make: M28's browser gate
// and M27's arm run already assert the bundle's browser-shape, and `verify_provider_half_dd9_clean`
// asserts on the artefact that the wallet entry reaches no Node builtin. The boundary is stated
// here so nobody later reads "the handshake runs" as "the handshake runs in Chromium".
//
// Every arm records what it OBSERVED, never what it expected: the checks compare.

import { existsSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { pathToFileURL } from 'node:url';

const WORK = process.argv[2];
if (!WORK) {
  process.stderr.write('usage: run_wallet_arms.mjs <work-dir>\n');
  process.exit(2);
}

const REPO = path.resolve(import.meta.dirname, '..');
const DIST = process.env.BROWSER_DIST ?? path.join(REPO, 'browser/dist');
const WALLET_BUNDLE = path.join(DIST, 'wallet.js');
if (!existsSync(WALLET_BUNDLE)) {
  process.stderr.write(`run_wallet_arms.mjs: there is no built wallet entry at ${WALLET_BUNDLE}\n`);
  process.exit(2);
}

const W = await import(pathToFileURL(WALLET_BUNDLE).href);

const {
  PortWalletProvider,
  PortConnectionHandler,
  createNullWallet,
  NULL_WALLET_METHODS,
  WalletMessageType,
  SIMULATED_APP_MANIFEST,
  SIMULATED_APP_NAME,
} = W;

// The chain this runtime is. Two Fr-shaped values; nothing here needs a real chain.
const CHAIN_INFO = { chainId: 1, version: 1 };

const WALLET_CONFIG = {
  walletId: 'm33-null-wallet',
  walletName: 'M33 null wallet',
  walletVersion: '0.0.0',
};

/** A bounded wait, so a hung arm is a named failure rather than a run that never ends. */
function bounded(promise, ms, what) {
  let timer;
  return Promise.race([
    promise.finally(() => clearTimeout(timer)),
    new Promise((_r, reject) => {
      timer = setTimeout(() => reject(new Error(`ArmTimeout: '${what}' exceeded ${ms} ms`)), ms);
    }),
  ]);
}

/** `{message, name}` for anything thrown, so a refusal is data rather than a stack. */
function asError(e) {
  return { name: e && e.name ? String(e.name) : 'unknown', message: e instanceof Error ? e.message : String(e) };
}

/** One wired pair: a provider on port1, a handler on port2, with a wallet behind it. */
function wire({ served, autoApprove = true, walletConfig = WALLET_CONFIG, heartbeat, timeouts } = {}) {
  const { port1, port2 } = new MessageChannel();
  const nullWallet = createNullWallet(served ? { served } : {});
  const handler = new PortConnectionHandler(
    port2,
    { ...walletConfig, autoApproveDiscovery: autoApprove },
    { getWallet: () => nullWallet.wallet },
  );
  const provider = new PortWalletProvider(port1, {
    chainInfo: CHAIN_INFO,
    ...(heartbeat ? { heartbeat } : {}),
    ...(timeouts ? { timeouts } : {}),
  });
  const close = () => {
    handler.stop();
    try {
      port1.close();
      port2.close();
    } catch {
      /* already closed */
    }
  };
  return { port1, port2, handler, provider, nullWallet, close };
}

const arms = {};

// ── ARM 1: the whole handshake, and the verification hash computed independently at both ends ──
{
  const w = wire({});
  const seen = { established: null, verificationHash: null, pending: [] };
  const w2 = new PortConnectionHandler(w.port2, { ...WALLET_CONFIG, autoApproveDiscovery: true }, {
    getWallet: () => w.nullWallet.wallet,
    onSessionEstablished: s => {
      seen.established = { sessionId: s.sessionId, appId: s.appId };
      seen.verificationHash = s.verificationHash;
    },
    onPendingDiscovery: s => seen.pending.push({ requestId: s.requestId, appId: s.appId }),
  });
  w2.start();
  const started = Date.now();
  const pending = await bounded(w.provider.connect('m33-app'), 20_000, 'handshake.connect');
  const wallet = pending.confirm();
  const disclosed = await bounded(w.provider.discloseToWallet(), 20_000, 'handshake.disclose');
  const chainInfoCall = await bounded(
    wallet.getChainInfo().then(r => ({ resolved: r }), e => ({ rejected: asError(e) })),
    20_000,
    'handshake.getChainInfo',
  );
  const walletSideDisclosure = w2.disclosure();
  const beforeDisconnect = w.provider.isDisconnected();
  w.provider.disconnect();
  const afterDisconnect = w.provider.isDisconnected();
  const afterDisconnectCall = await bounded(
    Promise.resolve()
      .then(() => wallet.getAccounts())
      .then(r => ({ resolved: r }), e => ({ rejected: asError(e) })),
    20_000,
    'handshake.afterDisconnect',
  );
  arms.handshake = {
    elapsedMs: Date.now() - started,
    walletInfo: pending.walletInfo,
    providerVerificationHash: pending.verificationHash,
    walletVerificationHash: seen.verificationHash,
    hashesEqual: pending.verificationHash === seen.verificationHash,
    hashLength: String(pending.verificationHash ?? '').length,
    sessionEstablished: seen.established,
    pendingDiscoveries: seen.pending,
    disclosed,
    walletSideDisclosure,
    manifestSent: SIMULATED_APP_MANIFEST,
    simulatedAppName: SIMULATED_APP_NAME,
    chainInfoCall,
    handlerRefusals: w2.refusals(),
    providerRefusals: w.provider.refusals(),
    disconnect: { before: beforeDisconnect, after: afterDisconnect, call: afterDisconnectCall },
    directRefusalLedger: w.nullWallet.refusals().map(r => r.method),
  };
  w.close();
}

// ── ARM 2: the null wallet's own surface, called DIRECTLY. Every method, no transport. ──
{
  const h = createNullWallet();
  const results = {};
  for (const name of NULL_WALLET_METHODS) {
    // Called with no arguments on purpose: the refusal must not depend on the arguments, because a
    // wallet that is absent is absent for every call shape.
    results[name] = await Promise.resolve()
      .then(() => h.wallet[name]())
      .then(v => ({ resolved: v === undefined ? 'undefined' : JSON.stringify(v) }), e => ({ rejected: asError(e) }));
  }
  arms.refusalsDirect = {
    declaredMethods: [...NULL_WALLET_METHODS],
    results,
    ledger: h.refusals().map(r => r.method),
    serves: h.serves().map(r => r.method),
    // A property that is not a wallet method must not look like one: returning a function for
    // `then` makes the object thenable and hangs the first `await` on it.
    notAMethod: {
      then: typeof h.wallet.then,
      toJSON: typeof h.wallet.toJSON,
      nonsense: typeof h.wallet.thisIsNotAWalletMethod,
    },
    ownKeys: Object.keys(h.wallet).sort(),
  };
}

// ── ARM 3: THE CONTROL — a permitted call reaches through, on the same object and over the wire ──
{
  // Fr-shaped, because `getChainInfo`'s OUTPUT schema is `{chainId: schemas.Fr, version: schemas.Fr}`
  // and the provider parses every reply through `getSchemaReturnType(...).parseAsync`. A served
  // method that answered with the wrong SHAPE would be refused by upstream's own codec, which is
  // itself worth knowing: the control has to reach through the parse, not merely past the dispatch.
  const CHAIN_ANSWER = {
    chainId: '0x0000000000000000000000000000000000000000000000000000000000000007',
    version: '0x0000000000000000000000000000000000000000000000000000000000000003',
  };
  const h = createNullWallet({ served: { getChainInfo: () => Promise.resolve(CHAIN_ANSWER) } });
  const direct = await Promise.resolve()
    .then(() => h.wallet.getChainInfo())
    .then(v => ({ resolved: v }), e => ({ rejected: asError(e) }));
  const directRefused = await Promise.resolve()
    .then(() => h.wallet.getAccounts())
    .then(v => ({ resolved: v }), e => ({ rejected: asError(e) }));

  const w = wire({ served: { getChainInfo: () => Promise.resolve(CHAIN_ANSWER) } });
  w.handler.start();
  const pending = await bounded(w.provider.connect('m33-app'), 20_000, 'served.connect');
  const wallet = pending.confirm();
  const overWire = await bounded(
    wallet.getChainInfo().then(v => ({ resolved: v }), e => ({ rejected: asError(e) })),
    20_000,
    'served.getChainInfo',
  );
  const overWireRefused = await bounded(
    wallet.getAccounts().then(v => ({ resolved: v }), e => ({ rejected: asError(e) })),
    20_000,
    'served.getAccounts',
  );
  arms.served = {
    answer: CHAIN_ANSWER,
    direct,
    directRefused,
    overWire,
    overWireRefused,
    serves: w.nullWallet.serves().map(r => r.method),
    refusals: w.nullWallet.refusals().map(r => r.method),
  };
  w.close();
}

// ── ARM 4: THE CONTROL — a SECURE_MESSAGE carrying the wrong appId is refused by name ──
//
// THE MUTATION IS APPLIED AND THEN READ BACK. `CAMPAIGN-BRIEF.md`'s fourth mutation state is "a
// mutation that never applied and reported its predicted number anyway", so the arm records what
// the field says AFTER the write. If the write did not take, `mutationApplied` is false and the
// check fails on that rather than on the arm's outcome.
{
  const w = wire({});
  w.handler.start();
  const pending = await bounded(w.provider.connect('the-right-app'), 20_000, 'wrongAppId.connect');
  const wallet = pending.confirm();
  // A correct call first, so the failure below is attributable to the appId and not to the channel.
  const good = await bounded(
    wallet.getChainInfo().then(v => ({ resolved: v }), e => ({ rejected: asError(e) })),
    20_000,
    'wrongAppId.good',
  );
  const boundAppId = w.provider.appId;
  w.provider.appId = 'the-wrong-app';
  const mutationApplied = w.provider.appId === 'the-wrong-app' && boundAppId === 'the-right-app';
  const bad = await bounded(
    wallet.getChainInfo().then(v => ({ resolved: v }), e => ({ rejected: asError(e) })),
    20_000,
    'wrongAppId.bad',
  );
  arms.wrongAppId = {
    boundAppId,
    mutationApplied,
    good,
    bad,
    handlerRefusals: w.handler.refusals(),
    sessionAppId: w.handler.activeSessions().map(s => s.appId),
  };
  w.close();
}

// ── ARM 5: THE CONTROL — a SECURE_RESPONSE from a wallet that is not the one discovery named ──
//
// The provider binds `walletId` at `confirm()` from `DISCOVERY_RESPONSE`'s `walletInfo.id`, and
// drops any response claiming a different one. Exercising that branch means a response whose
// `walletId` disagrees, which cannot be produced through the public surface — the genuine wallet
// answers with its own id, correctly. So the arm moves the PROVIDER's expectation instead, which is
// the same disagreement from the other side, and reads the field back to prove the move took.
{
  const w = wire({});
  w.handler.start();
  const pending = await bounded(w.provider.connect('m33-app'), 20_000, 'wrongWalletId.connect');
  const wallet = pending.confirm();
  const good = await bounded(
    wallet.getChainInfo().then(v => ({ resolved: v }), e => ({ rejected: asError(e) })),
    20_000,
    'wrongWalletId.good',
  );
  const boundWalletId = w.provider.walletId;
  w.provider.walletId = 'somebody-else';
  const mutationApplied = w.provider.walletId === 'somebody-else' && boundWalletId === WALLET_CONFIG.walletId;
  const before = w.provider.refusals().length;
  // The call must NOT settle: a response the provider refuses is one it never matches to a
  // messageId. So the outcome recorded is a TIMEOUT, and the refusal ledger is what names why.
  const outcome = await Promise.resolve()
    .then(() =>
      bounded(
        wallet.getChainInfo().then(v => ({ resolved: v }), e => ({ rejected: asError(e) })),
        1_500,
        'wrongWalletId.bad',
      ),
    )
    .then(v => v, e => ({ timedOut: asError(e) }));
  arms.wrongWalletId = {
    boundWalletId,
    mutationApplied,
    good,
    outcome,
    refusalsAdded: w.provider.refusals().length - before,
    providerRefusals: w.provider.refusals(),
  };
  w.close();
}

// ── ARM 6: THE CONTROL — key exchange without an approved discovery is refused, and the
//            handshake fails by NAME rather than hanging ──
{
  // The bound is shortened through the provider's own option so the NAMED timeout is observable in
  // a second rather than in a minute. The name and the step are the subject; the number is not.
  const w = wire({ autoApprove: false, timeouts: { readyMs: 2_000, discoveryMs: 2_000, keyExchangeMs: 2_000 } });
  w.handler.start();
  const outcome = await Promise.resolve()
    .then(() => w.provider.connect('m33-app'))
    .then(v => ({ resolved: 'connected' }), e => ({ rejected: asError(e) }));
  arms.noApproval = {
    outcome,
    pendingAtWallet: w.handler.pendingSessions().map(s => ({ requestId: s.requestId, appId: s.appId, status: s.status })),
    activeAtWallet: w.handler.activeSessions().length,
    handlerRefusals: w.handler.refusals(),
  };
  w.close();
}

// ── ARM 7: the verification hash DISCRIMINATES — two independent sessions differ ──
{
  const hashes = [];
  for (let i = 0; i < 2; i++) {
    const w = wire({});
    let walletHash = null;
    const h = new PortConnectionHandler(w.port2, { ...WALLET_CONFIG, autoApproveDiscovery: true }, {
      getWallet: () => w.nullWallet.wallet,
      onSessionEstablished: s => {
        walletHash = s.verificationHash;
      },
    });
    h.start();
    const pending = await bounded(w.provider.connect('m33-app'), 20_000, `hash.${i}`);
    hashes.push({ provider: pending.verificationHash, wallet: walletHash });
    w.close();
  }
  arms.verificationHash = {
    sessions: hashes,
    equalWithinSession: hashes.map(h => h.provider === h.wallet),
    equalAcrossSessions: hashes[0].provider === hashes[1].provider,
  };
}

// ── The message types the BUNDLE declares, so a check can compare them against the anchor ──
arms.protocol = {
  messageTypes: Object.fromEntries(Object.entries(WalletMessageType)),
  exportedNames: Object.keys(W).sort(),
  declaredOps: [...W.WALLET_ENTRY_OPS],
  nullWalletMethods: [...NULL_WALLET_METHODS],
  bundle: path.relative(REPO, WALLET_BUNDLE),
};

process.stdout.write(JSON.stringify({ measuredAt: new Date().toISOString(), work: WORK, arms }, null, 2) + '\n');
process.exit(0);
