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
 * How a transaction reached this runtime.
 *
 * `external` is M20's — the private half ran somewhere else and we were handed the result.
 * `local` is M21's, declared here so that M21 adds a case rather than a type, and so that the
 * provenance-blindness property can be tested TODAY with two distinct values rather than with one
 * value and an argument. M21's own fields (`privateExecution`, an optional `privateTrace` handle
 * that M26 consumes) are not invented here; the shape below is the minimum that lets the
 * discriminant be exercised.
 */
export type TxProvenance = { readonly kind: 'external' } | { readonly kind: 'local' };

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

/** Declared here so M21 does not have to widen the type it is testing against. */
export function locallyOriginatedTx<T>(tx: T): SubmittedTx<T> {
  return { tx, provenance: { kind: 'local' } };
}
