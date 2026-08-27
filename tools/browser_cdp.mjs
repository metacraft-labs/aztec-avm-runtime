// A Chrome DevTools Protocol client, and a static file server, in one file with no dependencies.
//
// ===========================================================================================
// WHY THERE IS NO PUPPETEER HERE.
// ===========================================================================================
//
// Node 22 shipped a GLOBAL `WebSocket`, and Node 24.19 — this repository's pinned engine — has it.
// CDP is a JSON-RPC over one websocket. So the whole driver is `new WebSocket(url)`, a map of
// pending ids, and an event emitter: about two hundred lines, none of them subtle, against ~180 MB
// of `@playwright/test` or `puppeteer` and a browser download this box does not need because
// `/usr/bin/chromium` is already here.
//
// It also buys the thing this milestone is actually about. `verify_public_only_page_never_fetches_
// barretenberg` must assert on OBSERVED NETWORK REQUESTS — the milestone says so in as many words —
// and `Network.requestWillBeSent` is the browser's own record of every request it made, including
// the ones a wrapped `fetch` would not see (a `<script>` tag, a dynamic import, a wasm streaming
// compile). A test framework would give the same events through three layers of abstraction.
//
// ===========================================================================================
// EVERY WAIT IS BOUNDED, AND EXCEEDING A BOUND IS A NAMED FAILURE.
// ===========================================================================================
//
// `CAMPAIGN-BRIEF.md`: "a check that HANGS is the third state and is worse than either, because it
// reports nothing at all and blocks the sweep behind it". A browser is the most hang-prone thing in
// this campaign — a page that never fires `load`, a promise that never settles, a renderer that
// never exits. So: every `send` has a timeout, every `waitFor` has a timeout, the browser is
// launched with an exit watchdog, and `close()` escalates to SIGKILL. A bound that is exceeded
// throws an error naming the method and the bound, never a silence.

import { spawn } from 'node:child_process';
import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import path from 'node:path';
import process from 'node:process';

/** Default bound for one CDP round trip. Generous: a wasm compile happens inside one of them. */
export const DEFAULT_TIMEOUT_MS = 60_000;

/** A CDP call or a wait exceeded its bound. Named, so a hang reads as a failure. */
export class CdpTimeout extends Error {
  constructor(what, ms) {
    super(`${what} did not complete within ${ms} ms. That is the HANG state reported as a failure.`);
    this.name = 'CdpTimeout';
  }
}

/** The page threw, or a CDP method returned an error. */
export class CdpError extends Error {
  constructor(method, detail) {
    super(`${method}: ${detail}`);
    this.name = 'CdpError';
  }
}

function withTimeout(promise, ms, what) {
  let timer;
  return Promise.race([
    promise.finally(() => clearTimeout(timer)),
    new Promise((_resolve, reject) => {
      timer = setTimeout(() => reject(new CdpTimeout(what, ms)), ms);
      timer.unref?.();
    }),
  ]);
}

// ---------------------------------------------------------------------------------------------
// A static file server.
//
// `file://` IS NOT AN OPTION AND THAT IS NOT FUSSINESS. ES module imports, dynamic imports and
// `WebAssembly.compileStreaming` are all subject to the same-origin policy, and a `file://` page
// gets `null` as its origin — so the demo's own `./demo.js` would not load. It also would not be
// the environment the product claim is about: a page served over HTTP is what a user visits.
//
// `Content-Type: application/wasm` is set for `.wasm` deliberately, because that is the header that
// decides whether `compileStreaming` works. A server that answered `application/octet-stream` would
// silently push the loader onto its buffered fallback, and the loader REPORTS which path it took so
// that difference is visible rather than guessed.
// ---------------------------------------------------------------------------------------------
const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.css': 'text/css; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
};

export async function serveDirectory(root) {
  const requests = [];
  const server = createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const rel = decodeURIComponent(url.pathname).replace(/^\/+/, '') || 'index.html';
    const full = path.join(root, rel);
    // A traversal outside the served root is refused rather than clamped: a check whose fixture
    // silently came from somewhere else is a check about nothing.
    if (!full.startsWith(path.resolve(root))) {
      res.writeHead(403).end('forbidden');
      requests.push({ path: rel, status: 403 });
      return;
    }
    if (!existsSync(full) || !statSync(full).isFile()) {
      res.writeHead(404).end('not found');
      requests.push({ path: rel, status: 404 });
      return;
    }
    const type = CONTENT_TYPES[path.extname(full)] ?? 'application/octet-stream';
    res.writeHead(200, { 'content-type': type, 'content-length': statSync(full).size });
    createReadStream(full).pipe(res);
    requests.push({ path: rel, status: 200, bytes: statSync(full).size, type });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  return {
    origin: `http://127.0.0.1:${port}`,
    /** What the SERVER saw. A second, independent record beside the browser's own network log. */
    requests,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

// ---------------------------------------------------------------------------------------------
// The browser.
// ---------------------------------------------------------------------------------------------
export async function launchChromium(binary, options = {}) {
  const userDataDir = options.userDataDir ?? path.join(process.env.HOME, '.cache', 'aztec-m27-chrome');
  const args = [
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-extensions',
    '--disable-dev-shm-usage',
    `--user-data-dir=${userDataDir}`,
    '--remote-debugging-port=0',
    ...(options.extraArgs ?? []),
    'about:blank',
  ];
  const child = spawn(binary, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  const stderrChunks = [];

  const endpoint = await withTimeout(
    new Promise((resolve, reject) => {
      let buffered = '';
      child.stderr.on('data', (d) => {
        const text = String(d);
        stderrChunks.push(text);
        buffered += text;
        const m = /DevTools listening on (ws:\/\/\S+)/.exec(buffered);
        if (m) resolve(m[1]);
      });
      child.on('exit', (code) =>
        reject(new CdpError('chromium', `exited with ${code} before announcing a DevTools endpoint:\n${stderrChunks.join('')}`)),
      );
    }),
    options.launchTimeoutMs ?? 30_000,
    'chromium launch',
  );

  return { child, endpoint, stderrChunks, userDataDir };
}

/** One CDP connection. `session` is a target's session id, or undefined for the browser itself. */
export class CdpConnection {
  constructor(ws, timeoutMs) {
    this.ws = ws;
    this.timeoutMs = timeoutMs;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Set();
    ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data));
      if (msg.id !== undefined && this.pending.has(msg.id)) {
        const { resolve, reject, method } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new CdpError(method, JSON.stringify(msg.error)));
        else resolve(msg.result);
        return;
      }
      for (const fn of [...this.listeners]) fn(msg);
    });
  }

  static async connect(endpoint, timeoutMs = DEFAULT_TIMEOUT_MS) {
    const ws = new WebSocket(endpoint);
    await withTimeout(
      new Promise((resolve, reject) => {
        ws.addEventListener('open', () => resolve());
        ws.addEventListener('error', (e) => reject(new CdpError('websocket', String(e.message ?? e.type))));
      }),
      timeoutMs,
      'websocket connect',
    );
    return new CdpConnection(ws, timeoutMs);
  }

  send(method, params = {}, sessionId) {
    const id = this.nextId++;
    const payload = { id, method, params };
    if (sessionId) payload.sessionId = sessionId;
    const promise = new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method });
    });
    this.ws.send(JSON.stringify(payload));
    return withTimeout(promise, this.timeoutMs, `${method}`);
  }

  on(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  /** Wait for the first event matching a predicate, bounded. */
  waitFor(predicate, what, ms = this.timeoutMs) {
    return withTimeout(
      new Promise((resolve) => {
        const off = this.on((msg) => {
          if (predicate(msg)) {
            off();
            resolve(msg);
          }
        });
      }),
      ms,
      what,
    );
  }

  close() {
    try {
      this.ws.close();
    } catch {
      /* the socket is already gone; nothing to do */
    }
  }
}

/**
 * A page, with its network log, its console log and its page errors collected from the first event.
 *
 * ATTACHED BEFORE NAVIGATION, ALWAYS. `Network.enable` after `Page.navigate` misses the document
 * request and usually the first script; a network log that is missing the requests made in the
 * first hundred milliseconds is exactly the log a check about a request would read as an absence.
 */
export async function openPage(conn, url, options = {}) {
  const { targetId } = await conn.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await conn.send('Target.attachToTarget', { targetId, flatten: true });

  const requests = [];
  const console_ = [];
  const errors = [];
  conn.on((msg) => {
    if (msg.sessionId !== sessionId) return;
    if (msg.method === 'Network.requestWillBeSent') {
      requests.push({
        requestId: msg.params.requestId,
        url: msg.params.request.url,
        method: msg.params.request.method,
        type: msg.params.type,
        initiator: msg.params.initiator?.type,
      });
    } else if (msg.method === 'Network.loadingFinished') {
      const last = requests.find((r) => r.requestId === msg.params.requestId);
      if (last) last.encodedDataLength = msg.params.encodedDataLength;
    } else if (msg.method === 'Runtime.consoleAPICalled') {
      console_.push({
        level: msg.params.type,
        text: msg.params.args.map((a) => a.value ?? a.description ?? a.type).join(' '),
      });
    } else if (msg.method === 'Runtime.exceptionThrown') {
      errors.push(
        msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text ?? 'unknown',
      );
    }
  });

  await conn.send('Network.enable', {}, sessionId);
  await conn.send('Runtime.enable', {}, sessionId);
  await conn.send('Page.enable', {}, sessionId);
  await conn.send('Log.enable', {}, sessionId);
  if (options.downloadPath) {
    await conn.send(
      'Browser.setDownloadBehavior',
      { behavior: 'allow', downloadPath: options.downloadPath, eventsEnabled: true },
      sessionId,
    );
  }

  const loaded = conn.waitFor(
    (m) => m.sessionId === sessionId && m.method === 'Page.loadEventFired',
    `${url} firing load`,
    options.loadTimeoutMs ?? 60_000,
  );
  await conn.send('Page.navigate', { url }, sessionId);
  await loaded;

  const page = {
    targetId,
    sessionId,
    requests,
    console: console_,
    errors,
    /** Evaluate an expression and return its JSON value. A page-side throw becomes a CdpError. */
    async eval(expression, evalTimeoutMs) {
      const result = await withTimeout(
        conn.send(
          'Runtime.evaluate',
          { expression, awaitPromise: true, returnByValue: true, timeout: evalTimeoutMs ?? 120_000 },
          sessionId,
        ),
        evalTimeoutMs ?? 120_000,
        `evaluating ${expression.slice(0, 60)}`,
      );
      if (result.exceptionDetails) {
        throw new CdpError(
          'Runtime.evaluate',
          result.exceptionDetails.exception?.description ?? result.exceptionDetails.text,
        );
      }
      return result.result.value;
    },
    send: (method, params) => conn.send(method, params, sessionId),
    close: () => conn.send('Target.closeTarget', { targetId }),
  };
  return page;
}

/** Requests whose URL contains a needle. The one predicate every DD-11 assertion is built on. */
export function requestsMatching(requests, needle) {
  return requests.filter((r) => r.url.includes(needle));
}
