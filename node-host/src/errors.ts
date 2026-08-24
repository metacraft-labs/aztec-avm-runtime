// The trap / revert distinction, made a property of the type system rather than of a convention.
//
// THE FAILURE MODE THIS FILE EXISTS TO PREVENT. An AVM revert is a TRANSACTION OUTCOME: the
// transaction ran, it reverted, it still lands in a block and it still pays its fee. A wasm trap
// is a RUNTIME BUG: the instance is dead, its linear memory is in an undefined state, and nothing
// it would report afterwards means anything. A boundary that surfaces both as "the call failed"
// makes a bug in our host look like a contract that reverted, which is the one confusion that
// makes a debugger lie to its user.
//
// So the two are not two values of one type. They are:
//
//   * `TxOutcome`, a plain object with `kind: 'tx-outcome'`, RETURNED by a successful call. A
//     revert is a `TxOutcome` whose `revertCode` is non-zero — it is a success of the boundary and
//     a failure of the transaction, and those are different sentences.
//   * `AvmTrap` and `AvmHostError`, Error subclasses, THROWN. Neither is assignable to
//     `TxOutcome`: the `kind` discriminants are disjoint string literals, so a function returning
//     `TxOutcome` cannot return either of them and `typecheck/negative/` proves it by failing to
//     compile.
//
// REACTOR-ABI.md's "The calling convention" is the other half of this. The C++ side never lets an
// exception unwind out of an export — it returns a status and leaves an `AvmReactorError` in the
// result buffer — precisely so that a C++ throw cannot become a wasm trap. This file is the host
// half: what does reach the host as a trap is genuinely a trap, and is reported as one.

/** Upstream's `AvmReactorError` — one `message` field, the shape of `bb::bbapi::ErrorResponse`. */
export interface AvmReactorError {
  readonly message: string;
}

/**
 * A transaction outcome. Produced ONLY by a call that returned status 0.
 *
 * `reverted` is derived from `revertCode` in one place, so no caller has to remember which
 * direction zero means.
 */
export interface TxOutcome<TResult = unknown> {
  readonly kind: 'tx-outcome';
  /** Upstream's `RevertCode`: 0 is success, non-zero is a revert. */
  readonly revertCode: number;
  /** `revertCode !== 0`. A revert is an outcome, never an error. */
  readonly reverted: boolean;
  /** The decoded `TxSimulationResult`. */
  readonly result: TResult;
}

/**
 * The module trapped: an out-of-bounds access, an `unreachable`, a stack overflow, a division
 * that the engine refused. The instance is dead after this and must never be reused — `Reactor`
 * poisons itself when it sees one.
 *
 * This is NEVER a transaction outcome. There is no `revertCode` on it, deliberately: a caller that
 * reaches for one gets a compile error rather than `undefined`.
 */
export class AvmTrap extends Error {
  readonly kind = 'trap' as const;
  /** The engine's own error, kept so the stack that actually trapped is not thrown away. */
  override readonly cause: unknown;
  /** Which export was being called. */
  readonly exportName: string;

  constructor(exportName: string, cause: unknown) {
    super(`avm.wasm trapped in ${exportName}: ${describe(cause)}`);
    this.name = 'AvmTrap';
    this.exportName = exportName;
    this.cause = cause;
  }
}

/**
 * The module returned a non-zero status. REACTOR-ABI.md's table:
 *
 *   1  a `std::exception` escaped — including an input that is not decodable
 *   2  a non-`std::exception` escaped
 *   3  no such DB handle
 *
 * This is a failure of the CALL, not of the transaction, and it is also not a trap: the instance
 * is intact and may be used again. Status 0 never produces one.
 */
export class AvmHostError extends Error {
  readonly kind = 'host-error' as const;
  readonly status: number;
  readonly exportName: string;

  constructor(exportName: string, status: number, message: string) {
    super(`${exportName} failed with status ${status}: ${message}`);
    this.name = 'AvmHostError';
    this.status = status;
    this.exportName = exportName;
  }
}

/**
 * A call was attempted on an instance that has already trapped. Its linear memory is in an
 * undefined state, so every later answer it gives is meaningless; the pool must not hand it out
 * again and this is what says so.
 */
export class AvmInstancePoisoned extends Error {
  readonly kind = 'poisoned' as const;
  readonly exportName: string;

  constructor(exportName: string) {
    super(
      `avm.wasm instance is poisoned by an earlier trap; ${exportName} was not called. ` +
        'A trapped instance cannot be reused: its linear memory is undefined.',
    );
    this.name = 'AvmInstancePoisoned';
    this.exportName = exportName;
  }
}

/** Everything the boundary can THROW. Disjoint from `TxOutcome` by construction. */
export type AvmFailure = AvmTrap | AvmHostError | AvmInstancePoisoned;

/**
 * The one classifier. Every export call in this package goes through `Reactor.callGuarded`, which
 * calls this, so "a trap is reported as a trap" is a property of one function rather than of
 * however many call sites there are.
 *
 * V8 raises `WebAssembly.RuntimeError` for a wasm trap and `RangeError` for a stack overflow that
 * unwound through wasm frames. Both are traps: the frame state is gone either way.
 */
export function isTrapLike(e: unknown): boolean {
  if (typeof WebAssembly !== 'undefined' && e instanceof WebAssembly.RuntimeError) return true;
  if (e instanceof RangeError) return true;
  return false;
}

/**
 * The exhaustiveness guard. A `switch` over `AvmFailure['kind']` that forgets an arm fails to
 * compile here rather than falling through at run time.
 */
export function unreachableKind(x: never): never {
  throw new Error(`unhandled kind: ${JSON.stringify(x)}`);
}

/** Reads a `TxSimulationResult`'s revert code without assuming a shape the module did not send. */
export function outcomeOf<TResult>(result: TResult): TxOutcome<TResult> {
  const raw = (result as { revertCode?: unknown }).revertCode;
  if (typeof raw !== 'number') {
    throw new AvmHostError(
      'avm_simulate',
      0,
      `the module returned status 0 but no numeric revertCode (got ${typeof raw}); ` +
        'a result without a revert code is not a transaction outcome',
    );
  }
  return { kind: 'tx-outcome', revertCode: raw, reverted: raw !== 0, result };
}

function describe(e: unknown): string {
  if (e instanceof Error) return `${e.name}: ${e.message}`;
  return String(e);
}
