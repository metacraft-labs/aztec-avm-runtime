// port_connection_handler.ts — the WALLET side of the in-page/worker transport.
//
// ===========================================================================================
// A THIRD TRANSPORT, BESIDE UPSTREAM'S TWO, IN UPSTREAM'S OWN SHAPE.
// ===========================================================================================
//
// `@aztec/wallet-sdk` ships two connection handlers and they are the same object twice:
//
//   * `extension/handlers/background_connection_handler.ts` (456 lines) + its content script —
//     `browser.runtime` messaging for discovery, a `MessagePort` for the session.
//   * `iframe/handlers/iframe_connection_handler.ts` (274 lines) — `window.postMessage`
//     throughout, and its own header says it "mirrors BackgroundConnectionHandler ... but uses
//     window.postMessage instead of browser.runtime messaging".
//
// M33's target is neither: a wallet in the SAME PAGE as the runtime, or in a Web Worker beside
// it. That is a `MessagePort` at both ends, which upstream's extension transport already uses for
// the secure session but reaches through `browser.runtime` to establish. So this file is the
// iframe handler's state machine — pending sessions, approve/reject, ECDH, encrypted dispatch,
// PING, terminate — with `window.addEventListener('message')` replaced by `port.onmessage`, and
// nothing else moved. The FLOW below is upstream's; the comment rendering it is a PARAPHRASE of
// upstream's, and M33's review corrected that sentence rather than leaving it. Upstream writes four
// lines with `parent →` and Unicode arrows ("show approval UI", "send DISCOVERY_RESPONSE",
// "terminate session"); this writes five with `dApp ->` and ASCII, and the fifth is PING/PONG —
// which upstream's handler IMPLEMENTS (`case WalletMessageType.PING`, and the `PONG` reply) and
// upstream's comment omits. A comment that claims to be a copy is a claim and needs the same
// evidence as any other; the claim that survives is about the flow, and it was checked member for
// member against `iframe_connection_handler.ts` at the anchor.
//
//   dApp -> DISCOVERY            -> approval -> DISCOVERY_RESPONSE
//   dApp -> KEY_EXCHANGE_REQUEST -> ECDH     -> KEY_EXCHANGE_RESPONSE
//   dApp -> SECURE_MESSAGE       -> decrypt -> Wallet -> encrypt -> SECURE_RESPONSE
//   dApp -> PING                 -> PONG
//   dApp -> DISCONNECT           -> terminate
//
// ===========================================================================================
// TWO DELIBERATE DIVERGENCES FROM UPSTREAM'S HANDLER, BOTH STRICTER.
// ===========================================================================================
//
//  1. **THE SESSION BINDS `appId`, AND A SECURE MESSAGE THAT DISAGREES IS REFUSED BY NAME.**
//     Upstream's iframe handler reads `appId` out of the decrypted `WalletMessage` and hands it
//     to `getWallet(appId, chainInfo)` without comparing it to the `appId` the session was
//     established for. On a cross-origin postMessage channel the origin check carries that
//     weight; on a `MessagePort` there IS no origin, so the binding has to be explicit or the
//     field is decorative. `e2e_discovery_keyexchange_session`'s control is exactly this: a
//     message carrying the wrong `appId` — and, in the other direction, a response carrying the
//     wrong `walletId` — must be REFUSED and must not be answered.
//  2. **THE APP MANIFEST IS RECORDED WHERE IT ARRIVES.** §8.4 requires that the wallet is told,
//     and can report, that this chain is simulated and produces no proofs. Upstream already has
//     the carrier — `requestCapabilities(AppCapabilities)`, whose `metadata` field is
//     `{name, version, description?, url?, icon?}` — so nothing is invented: the runtime fills
//     `description` with `DISCLOSURE_LINE`, and the handler records the manifest BEFORE
//     dispatching, so a wallet that refuses the call has still been told. `disclosure()` is how
//     it reports.
//
// The protocol types and the crypto are VENDORED from the anchor rather than imported, and the
// reason is measured rather than argued: see `WALLET-BOUNDARY.md` §2.

import { type Wallet, WalletSchema } from '@aztec/aztec.js/wallet';
import { jsonStringify } from '@aztec/foundation/json-rpc';
import { getSchemaParameters, parseWithOptionals, schemaHasMethod } from '@aztec/foundation/schemas';

import {
  type EncryptedPayload,
  decrypt,
  deriveSessionKeys,
  encrypt,
  exportPublicKey,
  generateKeyPair,
  importPublicKey,
} from '../vendor/wallet_sdk/crypto.ts';
import {
  NOOP_LOGGER,
  type WalletMessage,
  WalletMessageType,
  type WalletResponse,
  type WalletSdkLogger,
} from '../vendor/wallet_sdk/types.ts';

/** A minimal `MessagePort`, so this file compiles against the DOM lib and Node's alike. */
export interface PortLike {
  /** Sends a message to the other end. */
  postMessage(message: unknown): void;
  /** The inbound message handler. */
  onmessage: ((event: { data: unknown }) => void) | null;
  /** Begins delivery. `MessageChannel` ports are queued until this is called. */
  start?: () => void;
  /** Closes the port. */
  close?: () => void;
}

/** A discovery request that has arrived and not yet been approved. */
export interface PendingSession {
  /** Unique request identifier, chosen by the dApp. */
  readonly requestId: string;
  /** Application identifier declared by the dApp. */
  readonly appId: string;
  /** Approval status. */
  status: 'pending' | 'approved';
}

/** A session that has completed key exchange. */
export interface ActiveSession {
  /** Session identifier — the discovery `requestId`. */
  readonly sessionId: string;
  /** AES-256-GCM key derived from the ECDH exchange. */
  readonly sharedKey: CryptoKey;
  /** The hash both ends compute independently, for out-of-band comparison. */
  readonly verificationHash: string;
  /** The application identifier this session is BOUND to. */
  readonly appId: string;
}

/** The app metadata the runtime discloses through `requestCapabilities`. */
export interface DisclosedApp {
  /** Application name. */
  readonly name: string;
  /** Application version. */
  readonly version: string;
  /** The disclosure line, if the app sent one. */
  readonly description?: string;
  /** The app's URL, if it sent one. */
  readonly url?: string;
}

/** Configuration for {@link PortConnectionHandler}. */
export interface PortConnectionConfig {
  /** Unique wallet identifier. */
  walletId: string;
  /** Display name. */
  walletName: string;
  /** Version string. */
  walletVersion: string;
  /** Optional icon URL. */
  walletIcon?: string;
  /** Approve discovery without asking. There is no user on this transport; a caller decides. */
  autoApproveDiscovery?: boolean;
  /** Diagnostics. */
  logger?: WalletSdkLogger;
}

/** Event callbacks for {@link PortConnectionHandler}. */
export interface PortConnectionCallbacks {
  /** A discovery request arrived and is awaiting `approveDiscovery`. */
  onPendingDiscovery?: (session: PendingSession) => void;
  /** Key exchange completed. */
  onSessionEstablished?: (session: ActiveSession) => void;
  /** A session ended. */
  onSessionTerminated?: (sessionId: string) => void;
  /** The verification hash, for display beside the dApp's. */
  onVerificationHash?: (verificationHash: string) => void;
  /** Resolves the wallet that serves a given app. */
  getWallet: (appId: string) => Promise<Wallet> | Wallet;
}

/** A refusal this handler issued rather than answering. */
export interface HandlerRefusal {
  /** What was refused. */
  readonly kind:
    | 'unknown-session'
    | 'unapproved-key-exchange'
    | 'decryption-failed'
    | 'app-id-mismatch'
    | 'unknown-method';
  /** The session the refusal concerns, when there is one. */
  readonly sessionId?: string;
  /** A human-readable detail, always naming the subject. */
  readonly detail: string;
}

/**
 * The wallet side of the in-page/worker wallet protocol.
 *
 * @example
 * ```ts
 * const handler = new PortConnectionHandler(port, config, { getWallet: () => nullWallet });
 * handler.start();                       // posts WALLET_READY
 * handler.approveDiscovery(requestId);   // or set autoApproveDiscovery
 * ```
 */
export class PortConnectionHandler {
  private pending = new Map<string, PendingSession>();
  private active = new Map<string, ActiveSession>();
  private readonly log: WalletSdkLogger;
  private readonly refusalLog: HandlerRefusal[] = [];
  private disclosedApp: DisclosedApp | null = null;
  private started = false;

  constructor(
    private readonly port: PortLike,
    private readonly config: PortConnectionConfig,
    private readonly callbacks: PortConnectionCallbacks,
  ) {
    this.log = config.logger ?? NOOP_LOGGER;
  }

  /** Begins listening and announces the wallet with `WALLET_READY`. */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.port.onmessage = (event: { data: unknown }) => {
      void this.handle(event.data);
    };
    this.port.start?.();
    this.port.postMessage({ type: WalletMessageType.WALLET_READY });
    this.log.info('PortConnectionHandler started, posted WALLET_READY');
  }

  /** Stops listening. Sessions are left intact; `terminateSession` ends one. */
  stop(): void {
    this.port.onmessage = null;
    this.started = false;
  }

  /** Approves a pending discovery request and answers it. */
  approveDiscovery(requestId: string): void {
    const p = this.pending.get(requestId);
    if (!p || p.status !== 'pending') {
      return;
    }
    p.status = 'approved';
    this.port.postMessage({
      type: WalletMessageType.DISCOVERY_RESPONSE,
      requestId,
      walletInfo: {
        id: this.config.walletId,
        name: this.config.walletName,
        version: this.config.walletVersion,
        icon: this.config.walletIcon,
      },
    });
  }

  /** Drops a pending discovery request without answering it. */
  rejectDiscovery(requestId: string): void {
    this.pending.delete(requestId);
  }

  /** Ends a session and tells the dApp. */
  terminateSession(sessionId: string): void {
    const s = this.active.get(sessionId);
    if (!s) {
      return;
    }
    this.port.postMessage({ type: WalletMessageType.SESSION_DISCONNECTED, sessionId });
    this.active.delete(sessionId);
    this.callbacks.onSessionTerminated?.(sessionId);
  }

  /** Discovery requests awaiting approval. */
  pendingSessions(): PendingSession[] {
    return [...this.pending.values()].filter(s => s.status === 'pending');
  }

  /** Sessions that completed key exchange. */
  activeSessions(): ActiveSession[] {
    return [...this.active.values()];
  }

  /**
   * What the connected app disclosed about itself, or `null` if it has not disclosed.
   *
   * This is §8.4 across the boundary: the runtime fills `AppCapabilities.metadata.description`
   * with its disclosure line, the handler records it BEFORE dispatching to the wallet, and this
   * is how a wallet reports what it was told. Recording it before dispatch is what makes the
   * disclosure survive a wallet that refuses the call.
   */
  disclosure(): DisclosedApp | null {
    return this.disclosedApp;
  }

  /** Every refusal this handler issued rather than answering, in order. */
  refusals(): readonly HandlerRefusal[] {
    return this.refusalLog;
  }

  private refuse(r: HandlerRefusal): void {
    this.refusalLog.push(r);
    this.log.warn(`PortConnectionHandler refused: ${r.kind} — ${r.detail}`);
  }

  private async handle(data: unknown): Promise<void> {
    if (!data || typeof data !== 'object') {
      return;
    }
    const msg = data as Record<string, unknown>;
    switch (msg.type) {
      case WalletMessageType.DISCOVERY:
        this.onDiscovery(msg);
        break;
      case WalletMessageType.KEY_EXCHANGE_REQUEST:
        await this.onKeyExchange(msg);
        break;
      case WalletMessageType.SECURE_MESSAGE:
        await this.onSecureMessage(msg);
        break;
      case WalletMessageType.PING:
        this.onPing(String(msg.sessionId));
        break;
      case WalletMessageType.DISCONNECT:
        this.terminateSession(String(msg.sessionId));
        break;
      default:
        break;
    }
  }

  private onPing(sessionId: string): void {
    if (!this.active.has(sessionId)) {
      this.refuse({ kind: 'unknown-session', sessionId, detail: `PING for unknown session '${sessionId}'` });
      return;
    }
    this.port.postMessage({ type: WalletMessageType.PONG, sessionId });
  }

  private onDiscovery(msg: Record<string, unknown>): void {
    const requestId = String(msg.requestId);
    const appId = String(msg.appId);
    const session: PendingSession = { requestId, appId, status: 'pending' };
    this.pending.set(requestId, session);
    this.callbacks.onPendingDiscovery?.(session);
    if (this.config.autoApproveDiscovery) {
      this.approveDiscovery(requestId);
    }
  }

  private async onKeyExchange(msg: Record<string, unknown>): Promise<void> {
    const requestId = String(msg.requestId);
    const p = this.pending.get(requestId);
    if (!p || p.status !== 'approved') {
      this.refuse({
        kind: 'unapproved-key-exchange',
        sessionId: requestId,
        detail: `key exchange for '${requestId}', which is ${p ? 'not approved' : 'not a known request'}`,
      });
      return;
    }
    const keyPair = await generateKeyPair();
    const walletPublicKey = await exportPublicKey(keyPair.publicKey);
    const appPublicKey = await importPublicKey(msg.publicKey as Parameters<typeof importPublicKey>[0]);
    const keys = await deriveSessionKeys(keyPair, appPublicKey, false);

    const session: ActiveSession = {
      sessionId: requestId,
      sharedKey: keys.encryptionKey,
      verificationHash: keys.verificationHash,
      appId: p.appId,
    };
    this.active.set(requestId, session);
    this.pending.delete(requestId);

    this.port.postMessage({
      type: WalletMessageType.KEY_EXCHANGE_RESPONSE,
      requestId,
      publicKey: walletPublicKey,
      verificationHash: keys.verificationHash,
    });
    this.callbacks.onVerificationHash?.(keys.verificationHash);
    this.callbacks.onSessionEstablished?.(session);
  }

  private async onSecureMessage(msg: Record<string, unknown>): Promise<void> {
    const sessionId = String(msg.sessionId);
    const session = this.active.get(sessionId);
    if (!session) {
      this.refuse({
        kind: 'unknown-session',
        sessionId,
        detail: `SECURE_MESSAGE for unknown session '${sessionId}'`,
      });
      return;
    }

    let walletMessage: WalletMessage;
    try {
      walletMessage = await decrypt<WalletMessage>(session.sharedKey, msg.encrypted as EncryptedPayload);
    } catch {
      this.refuse({
        kind: 'decryption-failed',
        sessionId,
        detail: `SECURE_MESSAGE for session '${sessionId}' did not decrypt under the session key`,
      });
      return;
    }

    const { messageId, type, args, appId } = walletMessage;

    // DIVERGENCE 1. The session is bound to the appId discovery named.
    if (appId !== session.appId) {
      this.refuse({
        kind: 'app-id-mismatch',
        sessionId,
        detail:
          `SECURE_MESSAGE on session '${sessionId}' carries appId '${appId}', `
          + `but the session was established for '${session.appId}'`,
      });
      await this.respond(session, {
        messageId,
        walletId: this.config.walletId,
        error: `appId mismatch: session '${sessionId}' is bound to '${session.appId}', not '${appId}'`,
      });
      return;
    }

    // DIVERGENCE 2. §8.4's disclosure is recorded WHERE IT ARRIVES, before dispatch, so a wallet
    // that refuses `requestCapabilities` has still been told.
    if (type === 'requestCapabilities') {
      const manifest = args?.[0] as { metadata?: DisclosedApp } | undefined;
      if (manifest?.metadata) {
        this.disclosedApp = { ...manifest.metadata };
      }
    }

    let result: unknown;
    let error: string | undefined;
    try {
      if (!schemaHasMethod(WalletSchema, type)) {
        this.refuse({ kind: 'unknown-method', sessionId, detail: `unknown wallet method '${type}'` });
        throw new Error(`Unknown wallet method: ${type}`);
      }
      const wallet = await this.callbacks.getWallet(appId);
      const sanitized = await parseWithOptionals(args, getSchemaParameters(WalletSchema[type]));
      result = await (wallet as unknown as Record<string, (...a: unknown[]) => Promise<unknown>>)[type](
        ...sanitized,
      );
    } catch (err: unknown) {
      error = err instanceof Error ? err.message : String(err);
    }

    await this.respond(session, { messageId, walletId: this.config.walletId, result, error });
  }

  private async respond(session: ActiveSession, response: WalletResponse): Promise<void> {
    const encrypted = await encrypt(session.sharedKey, jsonStringify(response));
    this.port.postMessage({
      type: WalletMessageType.SECURE_RESPONSE,
      sessionId: session.sessionId,
      encrypted,
    });
  }
}
