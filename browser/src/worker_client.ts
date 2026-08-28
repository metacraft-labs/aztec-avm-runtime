// worker_client.ts — the page's half of the worker-hosted dev node.
//
// The page holds this; the worker holds `entry_worker.ts`. Between them is `worker_protocol.ts`,
// whose `ApiSchema` both ends drive: the client `jsonStringify`s the arguments and parses the reply
// against `getSchemaReturnType(schema[fn])`, the worker parses the arguments against
// `getSchemaParameters(schema[fn])` and `jsonStringify`s the reply. That is upstream's
// `WorkerWallet` / `wallet_worker_script` pair, over this runtime's facade.
//
// ===========================================================================================
// EVERY WAIT IS BOUNDED, INCLUDING THE ONES A TERMINATED WORKER CREATES
// ===========================================================================================
//
// `CAMPAIGN-BRIEF.md` names three states a check can be in — green, red and HUNG — and says the
// third is the worst because it reports nothing at all. A worker adds a way to reach it that a
// single-threaded page does not have: `worker.terminate()` while a request is outstanding leaves a
// promise that can never settle, because the thing that would have replied no longer exists. So
// every call carries a deadline and a terminated client REJECTS its outstanding calls by name
// rather than leaving them pending. `test_worker_restart_from_snapshot` terminates a worker
// deliberately, which is exactly the case this paragraph is about.

import * as Comlink from 'comlink';

import { jsonStringify } from '@aztec/foundation/json-rpc';
import { getSchemaReturnType, schemaHasMethod } from '@aztec/foundation/schemas';
import type { ApiSchema } from '@aztec/foundation/schemas';

import { AvmWorkerNodeSchema, WORKER_SUBSCRIPTIONS } from './worker_protocol.ts';

/** The default bound for one round trip. Generous: an `open` compiles `avm.wasm` inside it. */
export const DEFAULT_WORKER_CALL_TIMEOUT_MS = 120_000;

/** A call outlived its bound, or the worker was terminated under it. Named, so a hang is a failure. */
export class WorkerCallFailed extends Error {
  constructor(fn: string, why: string) {
    super(`the worker node's '${fn}' ${why}`);
    this.name = 'WorkerCallFailed';
  }
}

export interface WorkerNodeOptions {
  /** Where the worker bundle is. Passed in, never derived: a page knows where it served its own JS. */
  readonly workerUrl: string;
  /** Bound for one call. */
  readonly callTimeoutMs?: number;
  /** Bound for the worker announcing readiness. */
  readonly readyTimeoutMs?: number;
}

/** What the page gets back from `takeContainer`. */
export interface TakenContainer {
  readonly bytes: number;
  readonly container: Uint8Array;
  /** How long the crossing took, on the PAGE's clock. Reported, never asserted — see the check. */
  readonly elapsedMs: number;
}

interface ExposedWorkerNode {
  call(fn: string, argsJson: string): Promise<string | undefined>;
  subscribe(kind: string, callback: (payload: string) => void): Promise<void>;
  takeContainer(transfer: boolean): Promise<{ bytes: number; byteOffset: number; buffer: ArrayBuffer }>;
}

const schema = AvmWorkerNodeSchema as ApiSchema;

/**
 * Spawn a worker, wait for it to say it is ready, and wrap it.
 *
 * The readiness handshake is bb.js's `readinessListener`: the worker `postMessage`s `{ready: true}`
 * after `Comlink.expose`, and the page waits for that one message before making a call. Without it
 * the first call races module evaluation — comlink would queue it, but a worker that FAILED to
 * evaluate would be indistinguishable from one that is merely slow, and this way the failure has a
 * bound and a name.
 */
export async function openWorkerNode(options: WorkerNodeOptions): Promise<WorkerNodeClient> {
  const worker = new Worker(options.workerUrl, { type: 'module' });
  const readyMs = options.readyTimeoutMs ?? 60_000;
  const errors: string[] = [];
  worker.addEventListener('error', e => errors.push(String((e as ErrorEvent).message ?? e)));
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(
        new WorkerCallFailed(
          'readiness',
          `message did not arrive within ${readyMs} ms${errors.length ? `: ${errors.join('; ')}` : ''}. `
            + 'That is the HANG state reported as a failure.',
        ),
      );
    }, readyMs);
    const onReady = (event: MessageEvent): void => {
      if (event.data && (event.data as { ready?: boolean }).ready === true) {
        worker.removeEventListener('message', onReady);
        clearTimeout(timer);
        resolve();
      }
    };
    worker.addEventListener('message', onReady);
    worker.addEventListener('error', e => {
      clearTimeout(timer);
      reject(new WorkerCallFailed('readiness', `worker failed to load: ${String((e as ErrorEvent).message ?? e)}`));
    });
  });
  return new WorkerNodeClient(worker, Comlink.wrap<ExposedWorkerNode>(worker), options.callTimeoutMs ?? DEFAULT_WORKER_CALL_TIMEOUT_MS);
}

/**
 * The client.
 *
 * `call` is the one method that talks; everything else is a named wrapper around it, which is
 * `WorkerWallet`'s own shape. The wrappers exist so that a page holds a typed object rather than a
 * string-keyed dispatcher, and so that a name that is not on the protocol fails HERE, at the call
 * site, rather than as a message the worker refuses four layers away.
 */
export class WorkerNodeClient {
  readonly worker: Worker;
  private readonly remote: Comlink.Remote<ExposedWorkerNode>;
  private readonly timeoutMs: number;
  private terminated = false;
  /** Calls made, and the operations they named, in order. A page-side record of the protocol used. */
  readonly calls: string[] = [];

  constructor(worker: Worker, remote: Comlink.Remote<ExposedWorkerNode>, timeoutMs: number) {
    this.worker = worker;
    this.remote = remote;
    this.timeoutMs = timeoutMs;
  }

  /**
   * One operation on the schema channel.
   *
   * NOT `await`ED INTERNALLY BEFORE THE POST. `Comlink`'s proxy posts its message synchronously when
   * the method is called, so a caller that wants to mark a moment and then block its own thread can
   * call this, keep the promise, and await it afterwards. That is exactly what
   * `smoke_worker_chain_survives_main_thread_block` does with `state()`.
   */
  async call(fn: string, ...args: unknown[]): Promise<unknown> {
    if (!schemaHasMethod(schema, fn)) {
      throw new WorkerCallFailed(fn, 'is not an operation this protocol declares');
    }
    if (this.terminated) throw new WorkerCallFailed(fn, 'was called after the worker was terminated');
    this.calls.push(fn);
    const pending = this.remote.call(fn, jsonStringify(args));
    const replyJson = await this.bounded(fn, pending);
    const output = getSchemaReturnType(schema[fn]!);
    return output.parseAsync(replyJson === undefined ? undefined : JSON.parse(replyJson));
  }

  private bounded<T>(fn: string, promise: Promise<T>): Promise<T> {
    let timer: ReturnType<typeof setTimeout>;
    return Promise.race([
      promise.finally(() => clearTimeout(timer)),
      new Promise<T>((_resolve, reject) => {
        timer = setTimeout(
          () => reject(new WorkerCallFailed(fn, `did not answer within ${this.timeoutMs} ms`)),
          this.timeoutMs,
        );
      }),
    ]);
  }

  // -- the protocol, one wrapper per operation --------------------------------------------------

  open(request: Record<string, unknown>): Promise<unknown> { return this.call('open', request); }
  close(): Promise<unknown> { return this.call('close'); }
  start(): Promise<unknown> { return this.call('start'); }
  stop(): Promise<unknown> { return this.call('stop'); }
  submitExternal(tx: unknown): Promise<unknown> { return this.call('submitExternal', tx); }
  submitLocal(tx: unknown): Promise<unknown> { return this.call('submitLocal', tx); }
  registerContract(cls: unknown, instance: unknown): Promise<unknown> {
    return this.call('registerContract', cls, instance);
  }
  fundFeeJuice(feePayer: unknown, amount: unknown): Promise<unknown> {
    return this.call('fundFeeJuice', feePayer, amount);
  }
  injectL1ToL2Message(leaf: unknown): Promise<unknown> { return this.call('injectL1ToL2Message', leaf); }
  state(): Promise<unknown> { return this.call('state'); }
  blocks(): Promise<unknown> { return this.call('blocks'); }
  receiptFor(txHash: string): Promise<unknown> { return this.call('receiptFor', txHash); }
  produceBlock(): Promise<unknown> { return this.call('produceBlock'); }
  advanceBlocksBy(n: number): Promise<unknown> { return this.call('advanceBlocksBy', n); }
  exportSnapshot(): Promise<unknown> { return this.call('exportSnapshot'); }
  importSnapshot(snapshot: unknown): Promise<unknown> { return this.call('importSnapshot', snapshot); }
  recordContainer(request: Record<string, unknown>): Promise<unknown> {
    return this.call('recordContainer', request);
  }
  containerBufferState(): Promise<unknown> { return this.call('containerBufferState'); }
  runTokenTransfer(artifactUrl: string): Promise<unknown> { return this.call('runTokenTransfer', artifactUrl); }

  // -- the two off-schema operations -------------------------------------------------------------

  /**
   * `block` / `tx` / `trace`.
   *
   * The callback crosses as a `Comlink.proxy` — the one thing on this boundary that is not a value —
   * and the EVENT it delivers is a `jsonStringify` of the worker's own object, parsed here by the
   * caller. The kind is checked against `WORKER_SUBSCRIPTIONS` on this side too, so a typo is a
   * throw at the call site and not a subscription that silently never fires.
   */
  async subscribe(kind: string, callback: (event: unknown) => void): Promise<void> {
    if (!WORKER_SUBSCRIPTIONS.includes(kind)) {
      throw new WorkerCallFailed('subscribe', `does not offer '${kind}'; it offers ${WORKER_SUBSCRIPTIONS.join(', ')}`);
    }
    this.calls.push(`subscribe:${kind}`);
    await this.bounded(
      'subscribe',
      this.remote.subscribe(kind, Comlink.proxy((payload: string) => callback(JSON.parse(payload)))),
    );
  }

  /**
   * Take the recorded container.
   *
   * `transfer: true` is the product path: the buffer's ownership MOVES, and the worker's own
   * `containerBufferState()` afterwards is what says so. `transfer: false` is the control and is
   * kept in the shipped client rather than in a test file, because the pair is only a measurement
   * if both halves go through the same code.
   */
  async takeContainer(transfer: boolean): Promise<TakenContainer> {
    this.calls.push(`takeContainer:${transfer ? 'transfer' : 'copy'}`);
    const started = performance.now();
    const taken = await this.bounded('takeContainer', this.remote.takeContainer(transfer));
    const elapsedMs = performance.now() - started;
    return {
      bytes: taken.bytes,
      container: new Uint8Array(taken.buffer, taken.byteOffset, taken.bytes),
      elapsedMs,
    };
  }

  /** Terminate the worker. Everything outstanding fails by name; nothing is left pending. */
  terminate(): void {
    this.terminated = true;
    this.remote[Comlink.releaseProxy]();
    this.worker.terminate();
  }
}
