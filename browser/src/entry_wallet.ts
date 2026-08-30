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
//     value-reachable closure has zero edges to it; the wallet half's has THREE, out of five
//     import clauses, all named. `verify_provider_half_dd9_clean` re-derives that on every run and
//     asserts the count. (This comment said "four" until M33's review. Four is derivation 2's
//     answer — distinct `(file, specifier)` pairs, counting `import type` — and the milestone
//     corrected it to three VALUE edges in `WALLET-BOUNDARY.md` §1 and in its own log while
//     leaving it here and in `REUSE-INVENTORY.md`. A figure nobody re-derives rots, and this one
//     rotted in the same session it was corrected.)
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

// ---- M34: THE WALLET THAT FILLS THE SEAM ------------------------------------------------------
//
// M33 shipped a null wallet so the boundary was exercised before it was filled. This is the fill,
// and it is a SUBSTITUTION: `PortConnectionHandler`'s `getWallet` callback returns this instead of
// the null one and nothing about the transport changes. `DEV-WALLET.md` is the write-up; the
// design goal it exists to protect is that a DEBUGGING wallet must be the opposite of a production
// one — deterministic keys, every decision on the record, and everything unserved refusing by name.
export {
  CLASS_ARTIFACT_HASH_SEED,
  DEV_WALLET_METHODS,
  DEV_WALLET_NAME,
  DEV_WALLET_REFUSAL_REASONS,
  DEV_WALLET_REFUSED,
  DEV_WALLET_SERVED,
  DEV_WALLET_VERSION,
  DevWalletAuthorizationDeclined,
  DevWalletRefused,
  assertServedMatchesDeclaration,
  WALLET_DECISION_METADATA,
  WALLET_SEED_METADATA,
  createDevWallet,
  renderWalletDecision,
} from './wallet/dev_wallet.ts';
export type { DevWalletHandle, DevWalletHost, DevWalletOptions, WalletDecision } from './wallet/dev_wallet.ts';

export {
  DEFAULT_DEV_WALLET_SEED,
  DEV_ACCOUNT_SEPARATOR,
  DEV_ACCOUNT_SEPARATOR_LABEL,
  DEV_PARTIAL_ADDRESS_SEPARATOR,
  DEV_PARTIAL_ADDRESS_SEPARATOR_LABEL,
  UPSTREAM_SEPARATORS,
  deriveDevAccounts,
  parseDevWalletSeed,
  separatorFromLabel,
} from './wallet/dev_keys.ts';
export type { DevAccount } from './wallet/dev_keys.ts';

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

// M35: private execution. The oracle surface, and one ACIR frame driven by upstream's own
// WASMSimulator over upstream's own oracle wire. `PRIVATE-EXECUTION.md` is the write-up.
export {
  ORACLE_NAMES,
  ORACLE_IMPLEMENTED,
  ORACLE_DISCOVERY,
  ORACLE_IMPLEMENTED_WITH_DISCOVERY,
  ORACLE_REFUSING_WITH_DISCOVERY,
  ORACLE_REFUSING,
  ORACLE_REFUSAL_REASONS,
  ORACLE_ENVIRONMENT_VERSION,
  EPHEMERAL_RETURN_ORACLES,
  ORACLE_EPHEMERAL_RETURN_LABELS,
  OracleUnimplemented,
  OracleVersionIncompatible,
  assertAllowedScope,
  assertOracleSurfaceMatchesDeclaration,
  createPrivateOracleHandler,
  oracleMethodName,
} from './wallet/private_oracles.ts';
export type {
  NoteDiscoverySource,
  OracleCall,
  PrivateOracleHandle,
  PrivateOracleOptions,
} from './wallet/private_oracles.ts';

// M36: note discovery and tagging, served from the dev node's OWN history. `LOCAL-HISTORY.md` is
// the write-up and `local_history.ts` carries the boundary sentence the document quotes.
export {
  LOCAL_HISTORY_BOUNDARY,
  LOCAL_HISTORY_BOUNDARY_LABEL,
  LocalHistoryOnly,
} from './wallet/local_history.ts';
export { DevNoteDatabase, noteNonceFor, sealPrivateFrame } from './wallet/note_database.ts';
export type { NoteDbEvent, RetrievedTaggedLog, StoredNote, SyncedBlock, SyncedTx } from './wallet/note_database.ts';
export {
  DEV_EPHEMERAL_SLOT_SEPARATOR,
  DEV_EPHEMERAL_SLOT_SEPARATOR_LABEL,
  DeterministicEphemeralArrayService,
  DevTagging,
} from './wallet/dev_tagging.ts';
export type { ResolvedStrategy, TaggingAccount } from './wallet/dev_tagging.ts';
export {
  PrivateExecutionNotInitialised,
  executePrivateFunction,
  functionTypeOf,
  initPrivateExecution,
  privateExecutionAssets,
  toAddressValue,
  toFieldValue,
} from './wallet/private_execution.ts';
export type {
  AddressLike,
  FieldLike,
  PrivateExecutionAsset,
  PrivateExecutionAssets,
  PrivateExecutionReport,
  PrivateExecutionRequest,
} from './wallet/private_execution.ts';

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
    // M34: the wallet that fills the seam, its deterministic keys, and its decision ledger.
    'createDevWallet',
    'deriveDevAccounts',
    'parseDevWalletSeed',
    'separatorFromLabel',
    'renderWalletDecision',
    'DevWalletRefused',
    'DevWalletAuthorizationDeclined',
    'assertServedMatchesDeclaration',
    'DEV_WALLET_METHODS',
    'DEV_WALLET_SERVED',
    'DEV_WALLET_REFUSED',
    'DEV_WALLET_REFUSAL_REASONS',
    'DEV_WALLET_NAME',
    'DEV_WALLET_VERSION',
    'DEFAULT_DEV_WALLET_SEED',
    'DEV_ACCOUNT_SEPARATOR',
    'DEV_ACCOUNT_SEPARATOR_LABEL',
    'DEV_PARTIAL_ADDRESS_SEPARATOR',
    'DEV_PARTIAL_ADDRESS_SEPARATOR_LABEL',
    'UPSTREAM_SEPARATORS',
    'WALLET_DECISION_METADATA',
    'WALLET_SEED_METADATA',
    'CLASS_ARTIFACT_HASH_SEED',
    // M35: the private-execution oracle surface and the one-frame executor.
    'ORACLE_NAMES',
    'ORACLE_IMPLEMENTED',
    'ORACLE_REFUSING',
    'ORACLE_REFUSAL_REASONS',
    'ORACLE_ENVIRONMENT_VERSION',
    'EPHEMERAL_RETURN_ORACLES',
    'ORACLE_EPHEMERAL_RETURN_LABELS',
    'OracleUnimplemented',
    'OracleVersionIncompatible',
    'assertOracleSurfaceMatchesDeclaration',
    'assertAllowedScope',
    'createPrivateOracleHandler',
    'oracleMethodName',
    'executePrivateFunction',
    'functionTypeOf',
    'toFieldValue',
    'toAddressValue',
    'initPrivateExecution',
    'privateExecutionAssets',
    'PrivateExecutionNotInitialised',
    // M36: note discovery and tagging, over the dev node's own history.
    'ORACLE_DISCOVERY',
    'ORACLE_IMPLEMENTED_WITH_DISCOVERY',
    'ORACLE_REFUSING_WITH_DISCOVERY',
    'LOCAL_HISTORY_BOUNDARY',
    'LOCAL_HISTORY_BOUNDARY_LABEL',
    'LocalHistoryOnly',
    'DevNoteDatabase',
    'sealPrivateFrame',
    'noteNonceFor',
    'DevTagging',
    'DeterministicEphemeralArrayService',
    'DEV_EPHEMERAL_SLOT_SEPARATOR',
    'DEV_EPHEMERAL_SLOT_SEPARATOR_LABEL',
  ].sort(),
);
