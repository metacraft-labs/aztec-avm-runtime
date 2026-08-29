// null_wallet.ts — a wallet that refuses every request BY NAME.
//
// ===========================================================================================
// WHY A NULL WALLET IS A DELIVERABLE AND NOT A PLACEHOLDER.
// ===========================================================================================
//
// M33's insight is that the 68 oracles RI-65 records as unimplemented are WALLET
// responsibilities and not RUNTIME responsibilities. Keys, note discovery, private execution
// and tagging are what a wallet IS. That turns "the runtime is missing 68 oracles" into "the
// runtime has no wallet attached" — a true statement about a correct design rather than a gap
// in an incorrect one.
//
// A sentence like that is only worth anything if the seam it describes is EXERCISED. So the
// seam ships with a wallet in it before any wallet exists: one that answers every method of
// upstream's `WalletSchema` with a refusal that NAMES THE METHOD. The campaign's standing rule
// is that a missing thing must refuse by name and must never return a plausible value — and it
// matters more here than anywhere else in the campaign, because a fabricated note or nullifier
// produces a transaction that LOOKS valid.
//
// ===========================================================================================
// THE METHOD LIST IS NOT TYPED HERE. IT IS READ OUT OF THE SCHEMA.
// ===========================================================================================
//
// `CAMPAIGN-BRIEF.md`: *"a constant you have just typed into a check looks like a measurement to
// the person typing it. If a check needs a number that also exists in the thing under test, take
// it FROM the thing under test."* The same applies to a list. `NULL_WALLET_METHODS` is
// `Object.keys(WalletSchema)` — upstream's own object, imported from `@aztec/aztec.js/wallet`,
// which is where `WalletMethodSchemas`' fifteen methods and the `batch` that `createBatchSchemas`
// derives from them all live. If upstream adds a sixteenth method, this wallet refuses it on the
// day the dependency is re-pinned, with no edit here.
//
// ===========================================================================================
// THE SERVED MAP IS THE CONTROL, AND IT RUNS THROUGH THE INSTRUMENT.
// ===========================================================================================
//
// M32's review found a control that was *a second expression over a second buffer*, so it
// constrained its own code and not the subject's. The lesson — "a control has to run through the
// instrument, not beside it" — is why the permitted call is not a different object: `served` is a
// map consulted by the SAME proxy that refuses, so `test_null_wallet_refuses_by_name`'s positive
// control exercises the same dispatch path as its fifteen negatives.

import { type Wallet, WalletSchema } from '@aztec/aztec.js/wallet';

/**
 * The refusal. It names the method, so a caller's stack says which capability was wanted rather
 * than that "something" was missing.
 *
 * The `method` field is public and read by `test_null_wallet_refuses_by_name`, so the name is a
 * property of the object rather than a substring of a message somebody has to parse.
 */
export class WalletNotAttached extends Error {
  override readonly name = 'WalletNotAttached';

  constructor(
    /** The wallet method that was called. */
    readonly method: string,
    /** Why no wallet is attached — the null wallet's configured reason. */
    readonly reason: string,
  ) {
    super(
      `WalletNotAttached: no wallet is attached to this runtime, so '${method}' cannot be served. ${reason}`,
    );
  }
}

/**
 * Every method name upstream's `WalletSchema` declares, read from the schema rather than typed.
 *
 * Sorted, so a comparison against it is a comparison of SETS in a stable order.
 */
export const NULL_WALLET_METHODS: readonly string[] = Object.freeze(Object.keys(WalletSchema).sort());

/** A method implementation the null wallet is permitted to serve instead of refusing. */
export type ServedMethod = (...args: unknown[]) => unknown;

/** Options for {@link createNullWallet}. */
export interface NullWalletOptions {
  /**
   * Methods this wallet DOES serve, by name. Empty by default — a null wallet that answered
   * something without being asked to would be the plausible default this file exists to refuse.
   *
   * Every key is checked against {@link NULL_WALLET_METHODS} at construction: a `served` entry for
   * a method the schema does not declare is a typo that would otherwise sit there being refused,
   * which is the failure mode hardest to see.
   */
  served?: Record<string, ServedMethod>;
  /** The reason carried in every refusal. */
  reason?: string;
}

/**
 * The default reason. It says what would have to happen for the refusal to stop, because a
 * refusal that does not say what is missing is only half a diagnostic.
 */
export const NO_WALLET_REASON =
  'A wallet must be attached over the wallet protocol boundary '
  + '(discovery, key exchange, secure session) before any wallet capability can be served. '
  + 'Keys, note discovery, private execution and tagging are wallet responsibilities.';

/** The record a null wallet keeps of what it was asked for and refused. */
export interface RefusalRecord {
  /** The method name. */
  readonly method: string;
  /** Monotonic sequence number within this wallet, so the order is readable. */
  readonly seq: number;
}

/** A null wallet, plus the bookkeeping that makes "it refused" a fact about the object. */
export interface NullWalletHandle {
  /** The wallet itself, satisfying upstream's `Wallet` interface. */
  readonly wallet: Wallet;
  /** Every refusal this wallet has issued, in order. */
  refusals(): readonly RefusalRecord[];
  /** Every method it served instead of refusing, in order. */
  serves(): readonly RefusalRecord[];
}

/**
 * Builds a wallet that refuses every method of upstream's `WalletSchema` by name.
 *
 * @param options - the served map (the control) and the refusal reason
 * @returns the wallet and its refusal/serve ledgers
 */
export function createNullWallet(options: NullWalletOptions = {}): NullWalletHandle {
  const served = options.served ?? {};
  const reason = options.reason ?? NO_WALLET_REASON;

  const declared = new Set(NULL_WALLET_METHODS);
  for (const name of Object.keys(served)) {
    if (!declared.has(name)) {
      throw new Error(
        `createNullWallet: '${name}' is not a method of WalletSchema, so serving it would serve `
        + `nothing. Declared methods: ${NULL_WALLET_METHODS.join(', ')}`,
      );
    }
  }

  const refusals: RefusalRecord[] = [];
  const serves: RefusalRecord[] = [];
  let seq = 0;

  const target = {} as Record<string, unknown>;
  const wallet = new Proxy(target, {
    get: (_t, prop) => {
      const name = typeof prop === 'symbol' ? prop.toString() : prop;
      if (!declared.has(name)) {
        // Not a wallet method at all — `then`, `toJSON`, inspection symbols. Returning a function
        // for these makes the object look thenable and hangs the first `await`.
        return undefined;
      }
      const impl = served[name];
      if (impl) {
        return (...args: unknown[]) => {
          serves.push({ method: name, seq: seq++ });
          return impl(...args);
        };
      }
      return (..._args: unknown[]) => {
        refusals.push({ method: name, seq: seq++ });
        return Promise.reject(new WalletNotAttached(name, reason));
      };
    },
    has: (_t, prop) => declared.has(typeof prop === 'symbol' ? prop.toString() : prop),
    ownKeys: () => [...NULL_WALLET_METHODS],
    getOwnPropertyDescriptor: () => ({ configurable: true, enumerable: true, value: undefined }),
  }) as unknown as Wallet;

  return {
    wallet,
    refusals: () => refusals,
    serves: () => serves,
  };
}
