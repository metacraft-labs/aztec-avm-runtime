// No-op stand-in for @aztec/telemetry-client, whose single entrypoint drags in koa,
// prom-client and systeminformation (a server-side metrics HTTP endpoint).
const noopMeter = { createHistogram: () => ({ record(){} }), createUpDownCounter: () => ({ add(){} }), createCounter: () => ({ add(){} }), createGauge: () => ({ record(){} }), createObservableGauge: () => ({ addCallback(){} }) };
export const Metrics = new Proxy({}, { get: (_t, p) => String(p) });
export const Attributes = new Proxy({}, { get: (_t, p) => String(p) });
export const ValueType = { INT: 0, DOUBLE: 1 };
export const millisecondBuckets = () => [];
export const getTelemetryClient = () => ({ getMeter: () => noopMeter, getTracer: () => ({ startActiveSpan: (_n, f) => f({ end(){}, setAttribute(){}, setStatus(){}, recordException(){} }) }), stop: async () => {}, isEnabled: () => false, flush: async () => {} });
export class TelemetryClient {}
export const trackSpan = () => (_t, _k, d) => d;
export const Tracer = class {};
export const createUpDownCounterWithDefault = () => ({ add(){}, });
export const Traceable = class {};
export const Gauge = class {}; export const Histogram = class {}; export const UpDownCounter = class {};
export default { getTelemetryClient };
