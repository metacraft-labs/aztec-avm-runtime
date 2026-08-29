// strict_surface.ts — the runtime guard, and it is M21's, re-implemented rather than imported.
//
// WHY NOT `import { strictSurface } from '../../orchestration/src/settled_read_source.ts'`. Not
// tidiness — a wrong answer. `orchestration/` is pinned to `npm.deletion_era`
// (5.0.0-nightly.20260626, frozen evidence of the pre-deletion TypeScript AVM) and `replay/` is
// pinned to `npm.current` (5.3.0-nightly.20260819, which pins.json declares corresponds to the
// `cpp` anchor a live chain speaks). Importing across that boundary would put TWO `@aztec/stdlib`
// installs in one process, and `lib_m21_form_b.sh` already records why that is a correctness
// question rather than a size one: `serializeWithMessagePack` recognises an `Fr` by the class
// object of ITS OWN install. So the rejection reason is `cannot-reach-target`, and it is stated
// here because REUSE-INVENTORY.md's rule is that "we didn't find one" is not a reason.
//
// What IS reused is the design, and every decision in it is M21's:
//
//   * `get` AND `has` are both trapped, because PROBING IS THE DANGEROUS DIRECTION.
//     `'sendTx' in node` answering a silent `false` makes a duck-typed caller take another path
//     and nothing anywhere records that it asked. A throw is the only answer that leaves a trace.
//   * `ownKeys` is deliberately NOT trapped. Enumerating an object is not reaching for a method,
//     and `console.log` / `util.inspect` of the client has to keep working: this is a debugging
//     aid, not a secret. (That is the opposite call from `orchestration/src/submitted_tx.ts`'s
//     provenance seal, and for the opposite reason — there, disclosure IS the hazard.)
//   * Symbols pass through. `Symbol.toStringTag`, `Symbol.asyncIterator` and the inspect hook are
//     the language's own protocol keys; refusing them breaks `await` and `console.log`, and none
//     of them is an `AztecNode` method.
//   * THE RECEIVER IS THE TARGET, NOT THE PROXY. `Reflect.get(target, p, proxy)` runs a getter with
//     `this` bound to the proxy, so the object's own private field access re-enters this trap and
//     throws — the guard refusing the object's own internals. M21 found that by running it.

/** Thrown when something reaches for a member the replay client deliberately does not have. */
export class ReplayNodeSurfaceExceeded extends Error {
  readonly kind = 'replay-node-surface-exceeded' as const;
  readonly property: string;

  constructor(property: string, allowed: readonly string[]) {
    super(
      `the replay node client was asked for '${property}', which is not one of the `
        + `${allowed.length} member(s) it has. L0 enumerated the AztecNode surface a replay needs `
        + `and it is fourteen of fifty-five; anything else is a dependency surface growing by `
        + `accident, which is the thing enumeration exists to prevent. This object is NOT an `
        + `AztecNode and must not be made to look like one.`,
    );
    this.property = property;
  }
}

/**
 * Wrap an object so that reaching for anything outside `allowed` THROWS, on read and on `in`.
 *
 * A narrow TYPE is erased at run time; this is not. `client as any`,
 * `Reflect.get(client, 'sendTx')` and `'sendTx' in client` all fail here, at the site of the
 * reach, naming the property.
 */
export function strictSurface<T extends object>(source: T, allowed: readonly string[]): T {
  return new Proxy(source, {
    get(target, property, receiver) {
      if (typeof property === 'symbol') {
        return Reflect.get(target, property, receiver);
      }
      if (!allowed.includes(property)) {
        throw new ReplayNodeSurfaceExceeded(property, allowed);
      }
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
    has(target, property) {
      if (typeof property === 'symbol') {
        return Reflect.has(target, property);
      }
      if (!allowed.includes(property)) {
        throw new ReplayNodeSurfaceExceeded(property, allowed);
      }
      return Reflect.has(target, property);
    },
  });
}
