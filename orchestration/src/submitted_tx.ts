// submitted_tx.ts — DD-1: provenance is metadata ALONGSIDE `Tx`, never inside it.
//
// WHY THE TYPE IS THE EASY HALF. `SubmittedTx { tx, provenance }` is four lines and proves
// nothing. What DD-1 actually asks for is a property of the ENGINE: that execution cannot behave
// differently for a transaction we originated. A record type does not give you that — a
// `provenance.kind === 'local'` branch could be added to the execution path tomorrow and every
// type would still check.
//
// So the deliverable here is the ASSERTION, and it is made by the engine itself rather than about
// it. `sealProvenance` wraps the provenance in a `Proxy` whose every read trap fires a callback;
// `runWithProvenanceSealed` (form_a.ts) installs a callback that THROWS for the duration of the
// execution window. If any code between entering and leaving that window looks at the provenance —
// reads a property, asks `in`, enumerates the keys, spreads it, `JSON.stringify`s it, or compares
// it structurally — the transaction fails loudly at the moment of the read, naming the key.
//
// EVERY read trap, not just `get`. The first version of this file trapped `get` alone, which
// `Object.keys(provenance).length` and `'kind' in provenance` both walk straight past. The five
// traps below are the complete set through which a plain data object can be observed FROM
// ECMASCRIPT:
//
//   get                        p.kind, p?.kind, destructuring, JSON.stringify, String(p), `${p}`
//   has                        'kind' in p
//   ownKeys                    Object.keys / values / entries / getOwnPropertyNames, spread,
//                              Object.assign, for..in, Reflect.ownKeys
//   getOwnPropertyDescriptor   Object.getOwnPropertyDescriptor, and ownKeys' enumerability walk
//   getPrototypeOf             instanceof, Object.getPrototypeOf, for..in's prototype walk
//
// `Object.keys` invokes `ownKeys` AND `getOwnPropertyDescriptor` per key, so trapping only
// `ownKeys` would still catch it; both are trapped anyway, because a check that depends on which
// of two traps the engine happens to call first is a check that depends on an engine detail.
//
// THE EIGHT TRAPS THAT ARE DELIBERATELY ABSENT, and why absence is right. `set`, `defineProperty`,
// `deleteProperty`, `setPrototypeOf` and `preventExtensions` are MUTATIONS: they change the
// provenance, they do not disclose it, and DD-1 is about the engine reading provenance rather than
// about anyone writing it. `isExtensible` (which is also all `Object.isFrozen` and
// `Object.isSealed` reach for) answers a question about the proxy's shape, and both provenance
// values are freshly-built extensible object literals with the same single key — so it cannot
// tell `external` from `local` and there is nothing to branch on. `apply` and `construct` do not
// apply to a non-callable target. Measured, all thirteen, in
// `test_provenance_not_consulted_during_execution`.
//
// structuredClone is NOT in the ownKeys row, and an earlier revision of this comment said it was.
// Measured: `structuredClone(proxy)` throws `DataCloneError` and fires no trap at all. That fails
// loudly rather than disclosing anything, so it is safe — but it is not "caught by ownKeys", and a
// comment that states a measurement has to state the one that was taken.
//
// THE ONE CHANNEL NO PROXY CAN TRAP, AND WHAT IS DONE ABOUT IT. Node's `util.inspect` — and
// therefore `console.log`, `console.dir`, `util.format('%o'/'%O')` and the REPL — reads a proxy's
// TARGET through V8's debug/inspector API, which bypasses every handler by construction. With the
// provenance itself as the target, `util.inspect(sealed)` returned the string
// `"{ kind: 'local' }"` with `seal.reads` still EMPTY, so
// `util.inspect(p).includes("'local'")` was a working provenance branch that the tripwire could
// not see. Five traps were not enough, and no sixth trap exists that would have been.
//
// So the target is an EMPTY OBJECT and every read is served from the closure below. There is then
// nothing in the target to disclose: `util.inspect` prints `{}` for both provenances, which is the
// same `{}` for both and therefore un-branchable, while all five traps still fire and every value
// is still correct. The invariants hold because the target is extensible and has no own
// properties, so `ownKeys` may report keys it does not have and `getOwnPropertyDescriptor` may
// report a descriptor for one — provided the descriptor is `configurable`, which is why it is
// re-stamped below rather than forwarded verbatim.
//
// WHY NOT JUST NOT PASS IT. Because "the execution function does not take a provenance argument"
// is a property of ONE function signature, and the thing under test is a path with several
// frames in it. The seal travels with the object, so it holds wherever the object goes.
//
// THE CONTROL. `test_provenance_not_consulted_during_execution` reads the provenance inside the
// window on purpose and requires the throw. Without that arm the tripwire would pass by never
// firing, which is the campaign's most-repeated defect: an assertion that cannot fail.

/**
 * What ran the private half, when this runtime did.
 *
 * M21's deliverable. It is a SUMMARY and not the `PrivateExecutionResult` itself, deliberately:
 * the result is a large object graph that a consumer would then be able to read out of provenance,
 * and DD-1's whole point is that provenance is metadata beside the transaction rather than a
 * second channel into it. What a caller legitimately wants to know afterwards is what was run and
 * with what, and those are here.
 */
export interface PrivateExecutionSummary {
  /** The entrypoint's contract address, as a string. */
  readonly contract: string;
  /** The entrypoint's function selector, as a string. */
  readonly selector: string;
  /** How many nested private calls the execution produced, the entrypoint not counted. */
  readonly nestedCalls: number;
  /** How many enqueued public calls came out of it — Form B's link into the Form A path. */
  readonly publicCalls: number;
  /**
   * Which circuit simulator ran it. `wasm` is `WASMSimulator` over `@aztec/noir-acvm_js`.
   * A string rather than an enum because M27's browser host and a future native arm are different
   * implementations rather than members of a closed set this package owns.
   */
  readonly simulator: string;
}

/**
 * The handle M26 consumes. Opaque HERE on purpose.
 *
 * M26 owns what a private trace is; this milestone owns only the fact that a locally-originated
 * transaction can carry one and an externally-settled one cannot. Declaring the shape now would be
 * this campaign's own recurring defect in a new place — a type written from a deliverable's wording
 * rather than from the thing it describes.
 */
export interface PrivateTraceHandle {
  /** Identifies the trace to whatever produced it. */
  readonly id: string;
}

/** M20's arm: the private half ran somewhere else and we were handed the result. */
export interface ExternalTxProvenance {
  readonly kind: 'external';
}

/**
 * M21's arm.
 *
 * `privateExecution` IS OPTIONAL HERE AND REQUIRED WHERE IT MATTERS, and the split is deliberate.
 *
 * M20 runs all seven Form A arms under BOTH provenances, to prove that execution cannot see the
 * discriminant. Those `local` arms have no private execution — there was none — so making the
 * field required on this type would make the provenance-blindness suite unbuildable, and the
 * obvious workaround (a placeholder summary) would be a lie in a field a consumer reads.
 *
 * So the requirement lives on `LocallyExecutedTxProvenance` below, which is what Form B's producer
 * RETURNS. A path that runs a private half cannot omit the summary, because its own return type
 * carries it; a path that merely wants the discriminant can still have it.
 * `e2e_form_b_local_tx_roundtrip` section 4 asserts that the produced object always has the field,
 * by executing rather than by trusting the type, with M20's discriminant-only constructor and an
 * external transaction beside it as the two controls that it is not simply there by default.
 */
export interface LocalTxProvenance {
  readonly kind: 'local';
  readonly privateExecution?: PrivateExecutionSummary;
  readonly privateTrace?: PrivateTraceHandle;
}

/** The narrowed local arm: what Form B produces, with the summary required. */
export interface LocallyExecutedTxProvenance extends LocalTxProvenance {
  readonly privateExecution: PrivateExecutionSummary;
}

/**
 * How a transaction reached this runtime.
 *
 * `external` is M20's, `local` is M21's. The discriminant is what execution must not be able to
 * see; everything hanging off `local` is for the consumer that receives the outcome.
 */
export type TxProvenance = ExternalTxProvenance | LocalTxProvenance;

/** The boundary type. The `Tx` is upstream's, unmodified and unwrapped. */
export interface SubmittedTx<T = unknown> {
  readonly tx: T;
  readonly provenance: TxProvenance;
}

/** Thrown when the execution path observes a sealed provenance. */
export class ProvenanceConsultedDuringExecution extends Error {
  readonly kind = 'provenance-consulted-during-execution' as const;
  /** The trap that fired, e.g. `get`, `has`, `ownKeys`. */
  readonly trap: string;
  /** The property, where the trap has one. */
  readonly property: string | undefined;

  constructor(trap: string, property?: string | symbol) {
    const named = typeof property === 'symbol' ? property.toString() : property;
    super(
      `the execution path consulted the transaction's provenance (${trap}`
        + `${named === undefined ? '' : ` on '${named}'`}). DD-1: provenance is metadata alongside `
        + `Tx and must not reach execution, so that this runtime cannot behave differently for a `
        + `transaction it originated. Read it before entering the execution window, or not at all.`,
    );
    this.trap = trap;
    this.property = named;
  }
}

/** What a seal reports. `reads` accumulates a description of every observation. */
export interface ProvenanceSeal<P extends TxProvenance = TxProvenance> {
  /** The proxy to hand onward in place of the raw provenance. */
  readonly sealed: P;
  /** Every observation, in order, as `trap:property`. Empty is the property M20 claims. */
  readonly reads: readonly string[];
  /** Stop reporting; subsequent reads are neither recorded nor thrown on. */
  release(): void;
}

/**
 * Wrap a provenance so that every observation of it is reported.
 *
 * @param provenance the raw metadata
 * @param onRead called before each observation. Throwing from it aborts the read at its site,
 *        which is what makes the failure point at the offending frame rather than at the end.
 */
export function sealProvenance<P extends TxProvenance>(
  provenance: P,
  onRead: (trap: string, property?: string | symbol) => void,
): ProvenanceSeal<P> {
  const reads: string[] = [];
  let live = true;

  const observe = (trap: string, property?: string | symbol) => {
    if (!live) {
      return;
    }
    const named = typeof property === 'symbol' ? property.toString() : property;
    reads.push(named === undefined ? trap : `${trap}:${named}`);
    onRead(trap, property);
  };

  // The target is `{}` and NOT `provenance`. See "THE ONE CHANNEL NO PROXY CAN TRAP" above: an
  // inspector read of the target is untrappable, so the target must not be worth reading.
  const sealed: P = new Proxy({}, {
    get(_target, property, receiver) {
      observe('get', property);
      // `receiver` is the proxy on a direct read; forwarding it would re-enter this trap for an
      // accessor property. The provenance is a data object, but the substitution costs nothing.
      return Reflect.get(provenance, property, receiver === sealed ? provenance : receiver);
    },
    has(_target, property) {
      observe('has', property);
      return Reflect.has(provenance, property);
    },
    ownKeys() {
      observe('ownKeys');
      return Reflect.ownKeys(provenance);
    },
    getOwnPropertyDescriptor(_target, property) {
      observe('getOwnPropertyDescriptor', property);
      const descriptor = Reflect.getOwnPropertyDescriptor(provenance, property);
      // `configurable: true` is required, not cosmetic: reporting a non-configurable own property
      // that the empty target does not have is a TypeError from the invariant checks.
      return descriptor === undefined ? undefined : { ...descriptor, configurable: true };
    },
    getPrototypeOf() {
      observe('getPrototypeOf');
      return Reflect.getPrototypeOf(provenance);
    },
  }) as P;

  return {
    sealed,
    reads,
    release() {
      live = false;
    },
  };
}

/** The M20 constructor: a transaction whose private half ran elsewhere. */
export function externalTx<T>(tx: T): SubmittedTx<T> {
  return { tx, provenance: { kind: 'external' } };
}

/**
 * The DISCRIMINANT-ONLY local constructor, which is what M20's provenance-blindness arms use.
 *
 * It carries no private execution because there was none: these are Form A transactions submitted
 * under `local` provenance to prove the execution path cannot tell the two apart. Giving them a
 * placeholder summary would put a fabricated value in a field a consumer reads.
 */
export function locallyOriginatedTx<T>(tx: T): SubmittedTx<T> {
  return { tx, provenance: { kind: 'local' } };
}

/**
 * M21's constructor: a transaction whose private half THIS runtime ran.
 *
 * The summary is a required parameter rather than an optional one, so the Form B path cannot
 * produce a `local` transaction that has forgotten to say what it executed.
 */
export function locallyExecutedTx<T>(
  tx: T,
  privateExecution: PrivateExecutionSummary,
  privateTrace?: PrivateTraceHandle,
): SubmittedTx<T> & { readonly provenance: LocallyExecutedTxProvenance } {
  const provenance: LocallyExecutedTxProvenance =
    privateTrace === undefined
      ? { kind: 'local', privateExecution }
      : { kind: 'local', privateExecution, privateTrace };
  return { tx, provenance };
}
