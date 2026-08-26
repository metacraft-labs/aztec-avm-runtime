// telemetry.ts — the module every vendored orchestration file resolves `@aztec/telemetry-client`
// to, and the reasoning that decided its shape.
//
// THE DELIVERABLE'S CONCLUSION SURVIVES. ITS STATED REASON DOES NOT, AND NEITHER DOES THE
// ASSUMPTION THAT WE HAD TO WRITE THIS.
//
// M18 says: "@aztec/telemetry-client replaced by a no-op stub. Necessary, not optional: its
// single entrypoint drags in koa, prom-client, systeminformation and @opentelemetry/host-metrics
// — a server metrics endpoint with no browser export condition."
//
// Four claims, each measured against the installed package (5.0.0-nightly.20260626) and the fork
// at the TS anchor 3a68d68ac2:
//
//  1. "single entrypoint" — FALSE. Five: `.`, `./bench`, `./config`, `./start`,
//     `./otel-pino-stream`. None carries a conditional export of any kind, browser or otherwise,
//     which is the part of the sentence that is right and is the part that matters to a bundler:
//     there is no branch to resolve away from.
//  2. "drags in koa" — FALSE OF TELEMETRY, TRUE OF SOMETHING ELSE. `koa` is not a dependency of
//     @aztec/telemetry-client; the package's only reference to it is
//     `import type Koa from 'koa'` in src/otel_propagation.ts, which is erased. It is a
//     dependency of @aztec/foundation, and it enters an import graph through
//     `@aztec/foundation/dest/json-rpc/server/safe_json_rpc_server.js` — a JSON-RPC *server*,
//     which this runtime has no more business bundling than it has bundling prom-client, but
//     which is not telemetry's doing.
//  3. "prom-client, systeminformation, @opentelemetry/host-metrics" — TRUE, and larger than
//     stated. Measured with tools/import_graph.mjs, the `.` entrypoint's transitive module
//     closure is 1,658 modules across 143 packages, including all three, eighteen
//     @opentelemetry/* packages, viem, ws, pino and protobufjs.
//  4. "necessary, not optional" — TRUE, and for a reason NOBODY HAD RECORDED, which is the
//     finding of this deliverable.
//
// THE FINDING: UPSTREAM ALREADY WROTE THIS FILE, AND THE PACKAGE BOUNDARY HIDES IT.
//
// Enumerating the whole fork for a no-op rather than walking `telemetry-client/` — because all
// seven of this campaign's reuse misses have been a directory PARALLEL to the one being searched
// — turns up four sites, and two of them are exactly this problem already solved:
//
//   * `yarn-project/telemetry-client/src/noop.ts` — 152 lines. `NoopTelemetryClient`,
//     `NoopTracer`, `NoopSpan`, `NoopMeter`, whose only runtime dependency is
//     @opentelemetry/api. Not the SDK, not an exporter, not prom-client.
//   * `yarn-project/telemetry-client/src/start.ts` — `getTelemetryClient()` ALREADY returns a
//     `NoopTelemetryClient` by default, and the heavy path is behind a lazy
//     `await import('./otel.js')`. At run time, doing nothing already gives you a no-op.
//   * `yarn-project/txe/esbuild/stubs/telemetry_stub.ts` (39 lines) and
//     `telemetry_start_stub.ts` (15 lines), wired by `yarn-project/txe/esbuild.config.mjs`,
//     which redirect the whole package and its `start` module for the browser build. TXE's own
//     comment gives the identical rationale — "start.js contains `await import('./otel.js')`
//     which forces emission of a large OpenTelemetry SDK chunk even though TXE never starts
//     telemetry". That directory holds SIXTEEN such stubs; it is a solved problem with a
//     name. (An earlier revision of this comment said twenty-one; `git ls-tree` at the anchor
//     says sixteen, and M18's review is where the two were compared.)
//
// So the honest description of this file is NOT "a stub we wrote". It is upstream's own no-op
// decision, taken from `txe/esbuild/stubs/`, with one change forced by the package boundary:
//
//   MEASURED, NOT ASSUMED — `import('@aztec/telemetry-client/dest/noop.js')` fails with
//   ERR_PACKAGE_PATH_NOT_EXPORTED, and so does `'@aztec/telemetry-client/noop'`. The `exports`
//   map has no `./noop`. TXE reaches `dest/noop.js` by a monorepo-RELATIVE path from source,
//   which a consumer of the published package cannot do; only `.` resolves, and `.` is the
//   1,658-module closure. Upstream's no-op is real, is correct, and is unreachable from outside
//   the monorepo.
//
// Adding `"./noop": "./dest/noop.js"` to the exports map is a one-line, additive, obviously
// correct contribution upstream, and it is recorded as a candidate rather than taken here,
// because M11's carry set is closed and a sixth patch is a decision for that milestone.
//
// WHAT THAT ONE LINE WOULD AND WOULD NOT DO, corrected in M18's review, because an earlier
// revision of this comment said it "would remove the need for this module entirely" and that is
// false. `dest/noop.js` IS in the published tarball and its only dependency is
// @opentelemetry/api, so the subpath would work — but it exports TWO names,
// `NoopTelemetryClient` and `NoopTracer`, and this module exports SEVEN. The other five live in
// four other modules of the same package: `trackSpan` in `dest/telemetry.js`,
// `createUpDownCounterWithDefault` in `dest/metric-utils.js`, `getTelemetryClient` and
// `initTelemetryClient` in `dest/start.js` (which pulls @aztec/foundation), and `Metrics` and
// `Attributes` in `dest/metrics.js` and `dest/attributes.js`. `NoopTelemetryClient` is not
// re-exported from `.` either. So the honest form of the contribution is a handful of subpaths
// or a re-export, not one line, and it would shrink this module rather than delete it.
//
// What is below is therefore the smallest surface the vendored files actually use, which is
// span and metric creation and nothing else, in the shape upstream's own stub uses: `Metrics`
// and `Attributes` as Proxies that answer any property name, because a metric NAME is not
// behaviour and a stub that had to enumerate them would go stale silently.

// NO IMPORT OF @opentelemetry/api, not even a type-only one. `import type` is erased and
// would cost nothing at run time, but it would still put the package in this file's declared
// surface and in a reader's mental model of what this runtime depends on, and the whole point
// of this file is that it depends on nothing. The tracer type is structural and local.
/** Whatever a metric instrument is, this one records nothing. */
class NoopInstrument {
  add(_value: number, _attributes?: unknown): void {}
  record(_value: number, _attributes?: unknown): void {}
  addCallback(_cb: unknown): void {}
  removeCallback(_cb: unknown): void {}
}

class NoopMeter {
  createGauge(_metric?: unknown): NoopInstrument {
    return new NoopInstrument();
  }
  createObservableGauge(_metric?: unknown): NoopInstrument {
    return new NoopInstrument();
  }
  createHistogram(_metric?: unknown, _extra?: unknown): NoopInstrument {
    return new NoopInstrument();
  }
  createUpDownCounter(_metric?: unknown): NoopInstrument {
    return new NoopInstrument();
  }
  createObservableUpDownCounter(_metric?: unknown): NoopInstrument {
    return new NoopInstrument();
  }
  addBatchObservableCallback(_cb: unknown, _observables: unknown): void {}
  removeBatchObservableCallback(_cb: unknown, _observables: unknown): void {}
}

/**
 * A tracer whose spans do nothing. `startActiveSpan` MUST still call the body and return its
 * value: it is control flow, not observation, and a stub that dropped the callback would delete
 * the work the span wraps. That is the one way a no-op tracer can be wrong.
 */
class NoopTracer {
  startSpan(_name: string, _options?: unknown, _context?: unknown): NoopSpan {
    return new NoopSpan();
  }
  startActiveSpan<T>(_name: string, ...args: unknown[]): T {
    const fn = args[args.length - 1] as (span: NoopSpan) => T;
    return fn(new NoopSpan());
  }
}

class NoopSpan {
  spanContext(): { traceId: string; spanId: string; traceFlags: number } {
    return { traceId: '', spanId: '', traceFlags: 0 };
  }
  setAttribute(_k: string, _v: unknown): this {
    return this;
  }
  setAttributes(_a: unknown): this {
    return this;
  }
  addEvent(_n: string, _a?: unknown): this {
    return this;
  }
  addLink(_l: unknown): this {
    return this;
  }
  addLinks(_l: unknown): this {
    return this;
  }
  setStatus(_s: unknown): this {
    return this;
  }
  updateName(_n: string): this {
    return this;
  }
  end(_t?: unknown): void {}
  isRecording(): boolean {
    return false;
  }
  recordException(_e: unknown, _t?: unknown): void {}
}

export class NoopTelemetryClient {
  private meter = new NoopMeter();

  setExportedPublicTelemetry(_prefixes: string[]): void {}
  setPublicTelemetryCollectFrom(_roles: string[]): void {}
  getMeter(_name?: string): NoopMeter {
    return this.meter;
  }
  getTracer(_name?: string): NoopTracer {
    return new NoopTracer();
  }
  stop(): Promise<void> {
    return Promise.resolve();
  }
  flush(): Promise<void> {
    return Promise.resolve();
  }
  isEnabled(): boolean {
    return false;
  }
  getTraceContext(): string | undefined {
    return undefined;
  }
  extractPropagatedContext(_carrier: unknown): undefined {
    return undefined;
  }
}

export type TelemetryClient = NoopTelemetryClient;

// THE INSTRUMENT AND TRACER TYPE NAMES, ADDED IN M22 WHEN THE FIRST VENDORED CONSUMER ARRIVED.
//
// `@aztec/telemetry-client` re-exports these five names from `@opentelemetry/api`, and
// `PublicProcessorMetrics` and `PublicProcessor` — vendored under `vendor/` — annotate their
// fields with them. They are TYPE aliases onto the no-op classes above and nothing more: every
// one of them is erased at run time, so no @opentelemetry package enters this file's surface or a
// reader's model of what this runtime depends on. That is the same reasoning as the header's
// refusal of an `import type` — the difference is that these names are DEFINED here rather than
// imported from a package we do not want listed.
//
// They are deliberately the concrete no-op classes rather than `any`. A vendored file that called
// an instrument method this stub does not have would then fail to typecheck instead of failing at
// run time inside a metric nobody reads.
export type Gauge = NoopInstrument;
export type Histogram = NoopInstrument;
export type UpDownCounter = NoopInstrument;
export type ObservableGauge = NoopInstrument;
export type Meter = NoopMeter;
export type Tracer = NoopTracer;
export type Span = NoopSpan;

/** Upstream's marker for a class that exposes a tracer. Structural there, structural here. */
export interface Traceable {
  readonly tracer: Tracer;
}

const singleton = new NoopTelemetryClient();

export function getTelemetryClient(): TelemetryClient {
  return singleton;
}

export function initTelemetryClient(): Promise<TelemetryClient> {
  return Promise.resolve(singleton);
}

/**
 * `trackSpan` in the real package is a decorator factory that opens a span around a method.
 * Here it is the identity on the descriptor: the method still runs, unchanged, unobserved.
 */
export function trackSpan(_name: unknown, ..._rest: unknown[]) {
  return function (_target: unknown, _key: unknown, descriptor: PropertyDescriptor) {
    return descriptor;
  };
}

/**
 * Metric definitions and attribute keys are NAMES, and a stub that enumerated them would go
 * stale every time upstream added one — silently, because an undefined name reads as
 * `undefined` and a no-op meter accepts it. Upstream's own stub uses a Proxy for exactly this
 * and so does this one.
 */
export const Metrics: Record<string, { name: string; description: string; valueType: number }> =
  new Proxy(Object.create(null), {
    get: (_t, prop) =>
      typeof prop === 'string'
        ? { name: `aztec.noop.${prop.toLowerCase()}`, description: 'no-op metric', valueType: 1 }
        : undefined,
  });

export const Attributes: Record<string, string> = new Proxy(Object.create(null), {
  get: (_t, prop) => (typeof prop === 'string' ? `aztec.noop.${prop.toLowerCase()}` : undefined),
});

export function createUpDownCounterWithDefault(): NoopInstrument {
  return new NoopInstrument();
}
