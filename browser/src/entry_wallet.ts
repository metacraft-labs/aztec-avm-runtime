// `aztec-avm-runtime/wallet` — THE WALLET PROTOCOL BOUNDARY, and nothing else.
//
// ===========================================================================================
// WHY THIS IS A FOURTH ENTRY POINT AND NOT PART OF THE BROWSER REFERENCE SURFACE.
// ===========================================================================================
//
// DD-5's rule is a relation between THREE entries — `browser` is the reference, `testing` and
// `node` are supersets of it — and `verify_browser_entry_points_are_dd5_shaped` enforces exactly
// that relation. This build already ships three further entries outside it (`demo`,
// `worker`, `worker-demo`), because a page, a worker script and a demo are not points on that
// axis. `wallet` is the fourth, and the reason it is separate is DD-11 rather than DD-5:
//
//   **A page that attaches no wallet must not download a wallet protocol to be told so.**
//
// Measured (M33's enumeration, `WALLET-BOUNDARY.md` §1): `WalletSchema` — upstream's complete
// wallet protocol, and the object every method name in this entry is derived from — carries a
// value-reachable closure of **298 files and 31,205 lines** through `@aztec/aztec.js`. That is
// the same trade `browser/build.mjs`'s five DD-11 redirects make for barretenberg and the
// contract artifacts: keep it resolvable, keep it out of the eager path.
//
// So this entry is where a page opts IN. Its exports are disjoint from `browser.js`'s, and
// `verify_provider_half_dd9_clean` asserts that in both directions — an export that leaked into
// the reference bundle, or a wallet export that vanished from here, fails.
//
// ===========================================================================================
// WHAT IS *NOT* HERE, AND WHY EACH ABSENCE IS A DECISION.
// ===========================================================================================
//
//   * NO WALLET. `createNullWallet` refuses every method of upstream's schema by name. Keys,
//     note discovery, private execution and tagging are wallet responsibilities and M34–M36 own
//     them. The seam ships exercised and empty rather than filled with plausible defaults.
//   * NO `@aztec/pxe`, and it is a MEASUREMENT rather than a build flag. The provider half's
//     value-reachable closure has zero edges to it; the wallet half's has four, all named.
//     `verify_provider_half_dd9_clean` re-derives that on the BUILT artefact.
//   * NO KEY MATERIAL OF OURS. The ECDH keypair is generated per session by upstream's own
//     `crypto.ts` and never leaves the WebCrypto `CryptoKey` objects — `generateKeyPair` asks for
//     a non-extractable private key.
//   * NO `@aztec/wallet-sdk` DEPENDENCY, and the reason is in `WALLET-BOUNDARY.md` §2: its source
//     is clean and its PACKAGE is not, because npm has no subpath-scoped install and its declared
//     dependency list names `@aztec/pxe`, which reaches `@aztec/native` and `@aztec/world-state`.

export {
  DISCOVERY_TIMEOUT_MS,
  KEY_EXCHANGE_TIMEOUT_MS,
  PortWalletProvider,
  READY_TIMEOUT_MS,
  SIMULATED_APP_MANIFEST,
  SIMULATED_APP_NAME,
  WalletDisconnected,
  WalletHandshakeTimeout,
} from './wallet/port_wallet_provider.ts';
export type {
  AppManifest,
  HandshakeTimeouts,
  PendingConnection,
  PortWalletProviderOptions,
  ProviderRefusal,
} from './wallet/port_wallet_provider.ts';

export { PortConnectionHandler } from './wallet/port_connection_handler.ts';
export type {
  ActiveSession,
  DisclosedApp,
  HandlerRefusal,
  PendingSession,
  PortConnectionCallbacks,
  PortConnectionConfig,
  PortLike,
} from './wallet/port_connection_handler.ts';

export { NO_WALLET_REASON, NULL_WALLET_METHODS, WalletNotAttached, createNullWallet } from './wallet/null_wallet.ts';
export type { NullWalletHandle, NullWalletOptions, RefusalRecord, ServedMethod } from './wallet/null_wallet.ts';

// The protocol itself, re-exported from the VENDORED copy so a consumer speaks upstream's message
// types rather than a paraphrase of them. `verify_wallet_protocol_is_upstreams` re-derives the
// enum's members from the anchor and compares them against what this bundle exports, as a SET.
export {
  DEFAULT_HEARTBEAT_DEAD_AFTER_MS,
  DEFAULT_HEARTBEAT_INTERVAL_MS,
  NOOP_LOGGER,
  WalletMessageType,
} from './vendor/wallet_sdk/types.ts';
export type {
  ConnectedWalletInfo,
  DisconnectCallback,
  DiscoveryRequest,
  DiscoveryResponse,
  HeartbeatOptions,
  KeyExchangeRequest,
  KeyExchangeResponse,
  WalletInfo,
  WalletMessage,
  WalletResponse,
  WalletSdkLogger,
} from './vendor/wallet_sdk/types.ts';

export { hashToEmoji } from './vendor/wallet_sdk/crypto.ts';
export type { EncryptedPayload, ExportedPublicKey, SecureKeyPair, SessionKeys } from './vendor/wallet_sdk/crypto.ts';

/**
 * The operations this entry point declares, as a list a check can read out of the ARTEFACT.
 *
 * M32's `WORKER_PROTOCOL_BACKING` established the shape: a capability that exists in a bundle and
 * is not declared here fails, and a declaration for something the bundle does not export fails
 * too, so the list cannot drift from the thing it describes in either direction.
 */
export const WALLET_ENTRY_OPS: readonly string[] = Object.freeze(
  [
    'PortWalletProvider',
    'PortConnectionHandler',
    'createNullWallet',
    'WalletNotAttached',
    'NULL_WALLET_METHODS',
    'NO_WALLET_REASON',
    'WalletMessageType',
    'WalletHandshakeTimeout',
    'WalletDisconnected',
    'SIMULATED_APP_MANIFEST',
    'SIMULATED_APP_NAME',
    'NOOP_LOGGER',
    'hashToEmoji',
    'READY_TIMEOUT_MS',
    'DISCOVERY_TIMEOUT_MS',
    'KEY_EXCHANGE_TIMEOUT_MS',
    'DEFAULT_HEARTBEAT_INTERVAL_MS',
    'DEFAULT_HEARTBEAT_DEAD_AFTER_MS',
  ].sort(),
);
