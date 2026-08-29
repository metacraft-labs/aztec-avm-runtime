// port_wallet_provider.ts — the PROVIDER (dApp) side of the in-page/worker transport.
//
// ===========================================================================================
// WHICH HALF THIS IS, BECAUSE THE WORDS POINT BOTH WAYS.
// ===========================================================================================
//
// In Aztec's vocabulary the *provider* is the dApp-side object that finds a wallet, establishes
// the encrypted channel and hands back a `Wallet`. The runtime is the dApp here: it is the thing
// that WANTS keys, note discovery and private execution, and a wallet is what has them. So this
// file is the runtime's half of the boundary, and there is nothing wallet-shaped in it.
//
// It is upstream's `ExtensionProvider`/`IframeWalletProvider` flow, unchanged:
//
//   1. wait for WALLET_READY
//   2. DISCOVERY            -> DISCOVERY_RESPONSE          (the wallet may require approval)
//   3. KEY_EXCHANGE_REQUEST -> KEY_EXCHANGE_RESPONSE       (ECDH P-256, HKDF, AES-256-GCM)
//   4. derive session keys; the verification hash is computed independently at both ends
//   5. confirm() -> a `Wallet` proxy whose calls cross as SECURE_MESSAGE / SECURE_RESPONSE
//   6. PING/PONG while a request is in flight; silence past the ceiling is a disconnect
//   7. disconnect() -> DISCONNECT
//
// ===========================================================================================
// §8.4 TRAVELS IN UPSTREAM'S OWN FIELD.
// ===========================================================================================
//
// The milestone requires that the wallet is TOLD, and can REPORT, that this chain is simulated
// and produces no proofs. Nothing needed inventing: `requestCapabilities(AppCapabilities)` is one
// of `WalletSchema`'s fifteen methods and `AppCapabilities.metadata` is
// `{name, version, description?, url?, icon?}` — upstream's own manifest, the object a wallet
// shows a user in an authorization dialog. `discloseToWallet()` sends it with `description` set to
// `DISCLOSURE_LINE` from `orchestration/src/disclosure.ts`, which is the same string
// `AvmRuntime.create` writes and which `pins.json` holds to the pinned protocol version.
//
// It is sent as the FIRST secure message, so it crosses before any capability is asked for; and
// `PortConnectionHandler` records it before dispatching, so it survives a wallet that refuses.
// A null wallet refusing `requestCapabilities` by name and having been told anyway is exactly
// the state M33 ships.
//
// ===========================================================================================
// EVERY WAIT IS BOUNDED AND EVERY TIMEOUT NAMES ITS SUBJECT.
// ===========================================================================================
//
// `CAMPAIGN-BRIEF.md`: *"every subprocess a check waits on needs a bound, and exceeding it must be
// a named failure rather than a hang"* — a rule learned when a check with no timeout blocked a
// whole sweep and reported nothing at all. The same applies to a protocol handshake: each of the
// four waits below rejects with the step's name and the bound it exceeded.

import type { Wallet } from '@aztec/aztec.js/wallet';
import { WalletSchema } from '@aztec/aztec.js/wallet';
import { jsonStringify } from '@aztec/foundation/json-rpc';
import { getSchemaReturnType, schemaHasMethod } from '@aztec/foundation/schemas';

import { DISCLOSURE_LINE, PINNED_PROTOCOL_VERSION } from '../../../orchestration/src/disclosure.ts';
import {
  type EncryptedPayload,
  type ExportedPublicKey,
  decrypt,
  deriveSessionKeys,
  encrypt,
  exportPublicKey,
  generateKeyPair,
  importPublicKey,
} from '../vendor/wallet_sdk/crypto.ts';
import {
  DEFAULT_HEARTBEAT_DEAD_AFTER_MS,
  DEFAULT_HEARTBEAT_INTERVAL_MS,
  type HeartbeatOptions,
  NOOP_LOGGER,
  type WalletInfo,
  type WalletMessage,
  WalletMessageType,
  type WalletResponse,
  type WalletSdkLogger,
} from '../vendor/wallet_sdk/types.ts';
import type { PortLike } from './port_connection_handler.ts';

/** Default bounds for the three handshake waits. */
export const READY_TIMEOUT_MS = 15_000;
/** Discovery may need a human at the wallet end, so it is the generous one. */
export const DISCOVERY_TIMEOUT_MS = 60_000;
/** Key exchange follows an approval immediately; a long window here would help a MITM. */
export const KEY_EXCHANGE_TIMEOUT_MS = 5_000;

/** The name this runtime announces itself under in `AppCapabilities.metadata`. */
export const SIMULATED_APP_NAME = 'aztec-avm-runtime (simulated)';

/** The failure every bounded wait raises, naming the step and the bound. */
export class WalletHandshakeTimeout extends Error {
  override readonly name = 'WalletHandshakeTimeout';

  constructor(
    /** Which step timed out. */
    readonly step: string,
    /** The bound it exceeded, in milliseconds. */
    readonly boundMs: number,
  ) {
    super(`WalletHandshakeTimeout: '${step}' did not complete within ${boundMs} ms`);
  }
}

/** Raised when a call is made on a channel that has been disconnected. */
export class WalletDisconnected extends Error {
  override readonly name = 'WalletDisconnected';

  constructor(
    /** Why the channel ended. */
    readonly cause_: string,
  ) {
    super(`WalletDisconnected: ${cause_}`);
  }
}

/** A refusal the provider issued rather than accepting a message. */
export interface ProviderRefusal {
  /** What was refused. */
  readonly kind: 'wrong-session' | 'wrong-wallet-id' | 'decryption-failed' | 'unknown-message-id';
  /** A detail that names the subject. */
  readonly detail: string;
}

/** What the runtime discloses to the wallet, in upstream's `AppCapabilities` shape. */
export interface AppManifest {
  /** Manifest version — upstream's literal. */
  readonly version: '1.0';
  /** The metadata a wallet shows a user. */
  readonly metadata: {
    /** Application name. */
    readonly name: string;
    /** Application version — the pinned protocol version. */
    readonly version: string;
    /** §8.4's disclosure line. */
    readonly description: string;
  };
  /** Requested capabilities. Empty: M33 asks for nothing, it only opens the seam. */
  readonly capabilities: readonly never[];
}

/**
 * The manifest this runtime sends, built from `orchestration/src/disclosure.ts` rather than typed
 * here, so §8.4's line has one source and a check that compares them is comparing two readings of
 * one string rather than two copies of it.
 */
export const SIMULATED_APP_MANIFEST: AppManifest = Object.freeze({
  version: '1.0' as const,
  metadata: Object.freeze({
    name: SIMULATED_APP_NAME,
    version: PINNED_PROTOCOL_VERSION,
    description: DISCLOSURE_LINE,
  }),
  capabilities: Object.freeze([]) as readonly never[],
});

/** A channel that has completed key exchange but not yet been confirmed by the caller. */
export interface PendingConnection {
  /** The hash to compare, out of band, against the wallet's. */
  readonly verificationHash: string;
  /** Who answered discovery. */
  readonly walletInfo: WalletInfo;
  /** Accepts the channel and returns the wallet proxy. */
  confirm(): Wallet;
  /** Abandons the channel. */
  cancel(): void;
}

/**
 * Override knobs for the three handshake bounds.
 *
 * Upstream's own precedent, and its wording: `HeartbeatOptions` is *"mostly useful for tests"*. The
 * bounds are overridable for the same reason — a check that has to wait a minute to observe a
 * NAMED timeout is a check somebody will eventually delete.
 */
export interface HandshakeTimeouts {
  /** Bound on the wait for `WALLET_READY`. */
  readyMs?: number;
  /** Bound on the wait for `DISCOVERY_RESPONSE`. */
  discoveryMs?: number;
  /** Bound on the wait for `KEY_EXCHANGE_RESPONSE`. */
  keyExchangeMs?: number;
}

/** Options for {@link PortWalletProvider}. */
export interface PortWalletProviderOptions {
  /** The chain this runtime is. */
  chainInfo: { chainId: unknown; version: unknown };
  /** Diagnostics. */
  logger?: WalletSdkLogger;
  /** Heartbeat tuning. */
  heartbeat?: HeartbeatOptions;
  /** Handshake bounds. */
  timeouts?: HandshakeTimeouts;
}

/**
 * The runtime's side of the wallet protocol, over a `MessagePort`.
 *
 * @example
 * ```ts
 * const { port1, port2 } = new MessageChannel();
 * new PortConnectionHandler(port2, walletConfig, { getWallet }).start();
 * const provider = new PortWalletProvider(port1, { chainInfo });
 * const pending  = await provider.connect('my-app');
 * const wallet   = pending.confirm();
 * await provider.discloseToWallet();     // §8.4 crosses here
 * ```
 */
export class PortWalletProvider {
  private readonly log: WalletSdkLogger;
  private readonly refusalLog: ProviderRefusal[] = [];
  private readonly inFlight = new Map<
    string,
    { resolve: (v: unknown) => void; reject: (e: unknown) => void }
  >();
  private readonly waiters: Array<(msg: Record<string, unknown>) => boolean> = [];
  private sessionId: string | null = null;
  private sharedKey: CryptoKey | null = null;
  private walletId: string | null = null;
  private appId: string | null = null;
  private disconnected = false;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private lastInboundAt = 0;
  private readonly heartbeatIntervalMs: number;
  private readonly heartbeatDeadAfterMs: number;
  private disclosedAt: number | null = null;

  constructor(
    private readonly port: PortLike,
    private readonly options: PortWalletProviderOptions,
  ) {
    this.log = options.logger ?? NOOP_LOGGER;
    this.heartbeatIntervalMs = options.heartbeat?.intervalMs ?? DEFAULT_HEARTBEAT_INTERVAL_MS;
    this.heartbeatDeadAfterMs = options.heartbeat?.deadAfterMs ?? DEFAULT_HEARTBEAT_DEAD_AFTER_MS;
    this.port.onmessage = (event: { data: unknown }) => this.onMessage(event.data);
    this.port.start?.();
  }

  /** Every refusal this provider issued rather than accepting a message, in order. */
  refusals(): readonly ProviderRefusal[] {
    return this.refusalLog;
  }

  /** Whether the channel has been disconnected. */
  isDisconnected(): boolean {
    return this.disconnected;
  }

  /** The manifest this runtime sends. */
  manifest(): AppManifest {
    return SIMULATED_APP_MANIFEST;
  }

  /** When §8.4's manifest crossed, or `null` if it has not. */
  disclosedAtMs(): number | null {
    return this.disclosedAt;
  }

  /**
   * Runs the whole handshake: readiness, discovery, key exchange.
   *
   * @param appId - the application identifier the session will be bound to
   * @returns a pending connection whose `confirm()` yields the wallet
   */
  async connect(appId: string): Promise<PendingConnection> {
    this.appId = appId;
    await this.waitFor(
      m => m.type === WalletMessageType.WALLET_READY,
      this.options.timeouts?.readyMs ?? READY_TIMEOUT_MS,
      'wallet-ready',
    );

    const requestId = globalThis.crypto.randomUUID();
    this.port.postMessage({
      type: WalletMessageType.DISCOVERY,
      requestId,
      appId,
      chainInfo: this.options.chainInfo,
    });
    const discovery = await this.waitFor(
      m => m.type === WalletMessageType.DISCOVERY_RESPONSE && m.requestId === requestId,
      this.options.timeouts?.discoveryMs ?? DISCOVERY_TIMEOUT_MS,
      'discovery',
    );
    const walletInfo = discovery.walletInfo as WalletInfo;

    const keyPair = await generateKeyPair();
    const publicKey = await exportPublicKey(keyPair.publicKey);
    this.port.postMessage({ type: WalletMessageType.KEY_EXCHANGE_REQUEST, requestId, publicKey });

    const exchange = await this.waitFor(
      m => m.type === WalletMessageType.KEY_EXCHANGE_RESPONSE && m.requestId === requestId,
      this.options.timeouts?.keyExchangeMs ?? KEY_EXCHANGE_TIMEOUT_MS,
      'key-exchange',
    );
    const walletPublicKey = await importPublicKey(exchange.publicKey as ExportedPublicKey);
    const keys = await deriveSessionKeys(keyPair, walletPublicKey, true);

    let cancelled = false;
    const self = this;
    return {
      verificationHash: keys.verificationHash,
      walletInfo,
      confirm(): Wallet {
        if (cancelled) {
          throw new WalletDisconnected('the connection was cancelled before it was confirmed');
        }
        self.sessionId = requestId;
        self.sharedKey = keys.encryptionKey;
        self.walletId = walletInfo.id;
        return self.asWallet();
      },
      cancel(): void {
        cancelled = true;
      },
    };
  }

  /**
   * Sends §8.4's disclosure to the wallet, as `requestCapabilities(manifest)`.
   *
   * The call may be REFUSED — a null wallet refuses everything by name — and that is not a
   * failure of the disclosure: the manifest crossed the encrypted channel and the handler
   * recorded it before dispatching. The refusal is returned rather than thrown so a caller can
   * see both facts.
   *
   * @returns what the wallet answered, or the refusal it answered with
   */
  async discloseToWallet(): Promise<{ granted: unknown } | { refusedWith: string }> {
    this.disclosedAt = Date.now();
    try {
      const result = await this.call('requestCapabilities', [SIMULATED_APP_MANIFEST]);
      return { granted: result };
    } catch (err) {
      return { refusedWith: err instanceof Error ? err.message : String(err) };
    }
  }

  /** Ends the session and tells the wallet. */
  disconnect(): void {
    if (this.disconnected) {
      return;
    }
    if (this.sessionId) {
      this.port.postMessage({ type: WalletMessageType.DISCONNECT, sessionId: this.sessionId });
    }
    this.handleDisconnect('disconnect() was called on this side');
  }

  // ── the wallet proxy ────────────────────────────────────────────────────────────────────────

  private asWallet(): Wallet {
    const self = this;
    return new Proxy(
      {},
      {
        get: (_t, prop) => {
          const name = typeof prop === 'symbol' ? prop.toString() : prop;
          if (!schemaHasMethod(WalletSchema, name)) {
            return undefined;
          }
          return async (...args: unknown[]) => {
            const result = await self.call(name, args);
            return getSchemaReturnType(WalletSchema[name as keyof typeof WalletSchema]).parseAsync(result);
          };
        },
      },
    ) as unknown as Wallet;
  }

  private async call(type: string, args: unknown[]): Promise<unknown> {
    if (this.disconnected) {
      throw new WalletDisconnected('the channel is closed');
    }
    if (!this.sharedKey || !this.sessionId || !this.walletId || !this.appId) {
      throw new WalletDisconnected('no session: connect() and confirm() have not both run');
    }
    const messageId = globalThis.crypto.randomUUID();
    const message: WalletMessage = {
      messageId,
      type,
      args,
      chainInfo: this.options.chainInfo as WalletMessage['chainInfo'],
      appId: this.appId,
      walletId: this.walletId,
    };
    const encrypted = await encrypt(this.sharedKey, jsonStringify(message));
    const promise = new Promise<unknown>((resolve, reject) => {
      this.inFlight.set(messageId, { resolve, reject });
    });
    this.port.postMessage({
      type: WalletMessageType.SECURE_MESSAGE,
      sessionId: this.sessionId,
      encrypted,
    });
    this.startHeartbeat();
    return promise;
  }

  // ── inbound ─────────────────────────────────────────────────────────────────────────────────

  private onMessage(data: unknown): void {
    if (!data || typeof data !== 'object') {
      return;
    }
    const msg = data as Record<string, unknown>;
    this.lastInboundAt = Date.now();

    for (let i = this.waiters.length - 1; i >= 0; i--) {
      if (this.waiters[i](msg)) {
        this.waiters.splice(i, 1);
        return;
      }
    }

    if (msg.type === WalletMessageType.SECURE_RESPONSE) {
      if (this.sessionId !== null && msg.sessionId !== this.sessionId) {
        this.refusalLog.push({
          kind: 'wrong-session',
          detail: `SECURE_RESPONSE for session '${String(msg.sessionId)}', not this one ('${this.sessionId}')`,
        });
        return;
      }
      void this.onSecureResponse(msg.encrypted as EncryptedPayload);
    } else if (msg.type === WalletMessageType.SESSION_DISCONNECTED) {
      this.handleDisconnect(`the wallet ended session '${String(msg.sessionId)}'`);
    }
  }

  private async onSecureResponse(encrypted: EncryptedPayload): Promise<void> {
    if (!this.sharedKey) {
      return;
    }
    let response: WalletResponse;
    try {
      response = await decrypt<WalletResponse>(this.sharedKey, encrypted);
    } catch {
      this.refusalLog.push({
        kind: 'decryption-failed',
        detail: 'a SECURE_RESPONSE did not decrypt under the session key',
      });
      return;
    }
    // Upstream's `IframeWallet` drops a response whose `walletId` is not the one discovery named;
    // this is that check, made a NAMED refusal so `e2e_discovery_keyexchange_session`'s control
    // can read it rather than infer it from a promise that never settled.
    if (response.walletId !== this.walletId) {
      this.refusalLog.push({
        kind: 'wrong-wallet-id',
        detail:
          `a SECURE_RESPONSE claims walletId '${String(response.walletId)}', `
          + `but this session was established with '${String(this.walletId)}'`,
      });
      return;
    }
    const pending = this.inFlight.get(response.messageId);
    if (!pending) {
      this.refusalLog.push({
        kind: 'unknown-message-id',
        detail: `a SECURE_RESPONSE carries messageId '${response.messageId}', which is not in flight`,
      });
      return;
    }
    this.inFlight.delete(response.messageId);
    this.maybeStopHeartbeat();
    if (response.error !== undefined) {
      pending.reject(new Error(String(response.error)));
    } else {
      pending.resolve(response.result);
    }
  }

  private waitFor(
    predicate: (msg: Record<string, unknown>) => boolean,
    boundMs: number,
    step: string,
  ): Promise<Record<string, unknown>> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const i = this.waiters.indexOf(waiter);
        if (i !== -1) {
          this.waiters.splice(i, 1);
        }
        reject(new WalletHandshakeTimeout(step, boundMs));
      }, boundMs);
      const waiter = (msg: Record<string, unknown>): boolean => {
        if (!predicate(msg)) {
          return false;
        }
        clearTimeout(timer);
        resolve(msg);
        return true;
      };
      this.waiters.push(waiter);
    });
  }

  // ── heartbeat ───────────────────────────────────────────────────────────────────────────────

  private startHeartbeat(): void {
    if (this.heartbeatTimer !== null || this.disconnected) {
      return;
    }
    this.lastInboundAt = Date.now();
    this.heartbeatTimer = setInterval(() => this.heartbeatTick(), this.heartbeatIntervalMs);
  }

  private maybeStopHeartbeat(): void {
    if (this.inFlight.size === 0 && this.heartbeatTimer !== null) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  private heartbeatTick(): void {
    if (this.disconnected || this.inFlight.size === 0) {
      this.maybeStopHeartbeat();
      return;
    }
    const idleMs = Date.now() - this.lastInboundAt;
    if (idleMs >= this.heartbeatDeadAfterMs) {
      this.log.warn(`wallet channel silent for ${idleMs} ms — declaring disconnect`);
      this.handleDisconnect(`the wallet was silent for ${idleMs} ms, past the ${this.heartbeatDeadAfterMs} ms ceiling`);
      return;
    }
    this.port.postMessage({ type: WalletMessageType.PING, sessionId: this.sessionId });
  }

  private handleDisconnect(why: string): void {
    if (this.disconnected) {
      return;
    }
    this.disconnected = true;
    if (this.heartbeatTimer !== null) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
    const err = new WalletDisconnected(why);
    for (const { reject } of this.inFlight.values()) {
      reject(err);
    }
    this.inFlight.clear();
    for (const waiter of this.waiters.splice(0)) {
      void waiter;
    }
    this.port.onmessage = null;
  }
}
