// Grumpkin, from the module the page has ALREADY downloaded. `poseidon.ts`'s sibling.
//
// Everything `poseidon.ts`'s header says applies here: this is DD-11 rather than an optimisation,
// `avm.wasm` is a barretenberg build that already links `ecc`, the encoder is an ARGUMENT because a
// substituted module inherits its predecessor's dependency budget, and there is deliberately NO
// fallback to bb.js — a fallback would fetch 7.9 MB and break the deliverable on a page that looked
// fine.
//
// WHAT A GRUMPKIN SCALAR IS, because getting it wrong is a silently wrong point. Grumpkin is
// bn254's cycle curve: its BASE field is bn254's SCALAR field (`Fr` here, `bb::fr` there) and its
// SCALAR field is bn254's BASE field (`Fq` here, `bb::grumpkin::fr` there). So a point's `x` and
// `y` are `Fr` and cross as the 32-byte bins every field element on this boundary uses, while the
// multiplier is an `Fq` and crosses as raw bytes, read on the far side with `from_buffer`.

import { Fr } from '@aztec/foundation/curves/bn254';
import { Point } from '@aztec/foundation/curves/grumpkin';

import { Reactor } from '../../node-host/src/reactor.ts';

/** Encodes the argument list of a grumpkin call. Upstream's `serializeWithMessagePack`. */
export type GrumpkinArgEncoder = (args: unknown[]) => Uint8Array;

export interface GrumpkinBackend {
  /** `GrumpkinMul::execute` — an on-curve check, then `element(p).mul_const_time(s)`. */
  mul(point: Point, scalar: Uint8Array): Point;
  /** `GrumpkinAdd::execute` — two on-curve checks, then `a + b`. */
  add(a: Point, b: Point): Point;
  /** Calls made into the module. So "the page used the AVM's curve" is a number. */
  readonly calls: number;
}

export const GRUMPKIN_EXPORTS: readonly string[] = Object.freeze(['avm_grumpkin_mul', 'avm_grumpkin_add']);

/** The module does not export grumpkin — i.e. it is not built from M27's overlay stack. */
export class GrumpkinNotExported extends Error {
  constructor(missing: readonly string[]) {
    super(
      `this avm.wasm does not export ${missing.join(' or ')}. A browser page needs the module's own ` +
        'grumpkin, because address derivation is two curve operations and the alternative is ' +
        'downloading 7.9 MB of proving stack for them (DD-11). Build one from M27\'s overlay stack: ' +
        'just avm-wasm-build-m27.',
    );
    this.name = 'GrumpkinNotExported';
  }
}

/** The module answered something that is not a point. */
export class GrumpkinResultUnreadable extends Error {
  constructor(what: string, got: string) {
    super(`avm.wasm's ${what} returned something this host cannot read as a point: ${got}`);
    this.name = 'GrumpkinResultUnreadable';
  }
}

/** True when this module carries M27's thirteenth overlay. Asked of the ARTEFACT, never of a flag. */
export function moduleHasGrumpkin(reactor: Reactor): boolean {
  const names = reactor.exportNames;
  return GRUMPKIN_EXPORTS.every((n) => names.includes(n));
}

function fieldFrom(what: string, raw: unknown): Fr {
  if (!(raw instanceof Uint8Array) || raw.length !== 32) {
    throw new GrumpkinResultUnreadable(
      what,
      raw instanceof Uint8Array ? `a ${raw.length}-byte binary` : Object.prototype.toString.call(raw),
    );
  }
  return Fr.fromBuffer(Buffer.from(raw));
}

function pointFrom(what: string, raw: unknown): Point {
  if (!Array.isArray(raw) || raw.length !== 2) {
    throw new GrumpkinResultUnreadable(
      what,
      Array.isArray(raw) ? `an array of ${raw.length}` : Object.prototype.toString.call(raw),
    );
  }
  return new Point(fieldFrom(what, raw[0]), fieldFrom(what, raw[1]));
}

export function createAvmGrumpkin(reactor: Reactor, encodeArgs: GrumpkinArgEncoder): GrumpkinBackend {
  const missing = GRUMPKIN_EXPORTS.filter((n) => !reactor.exportNames.includes(n));
  if (missing.length) throw new GrumpkinNotExported(missing);

  let calls = 0;
  const callBytes = (exportName: string, blob: Uint8Array): unknown => {
    const fn = reactor.exports[exportName] as (ptr: number, len: number) => number;
    return reactor.withBlob(blob, (ptr, len) => {
      reactor.callGuarded(exportName, () => fn(ptr, len));
      calls += 1;
      return reactor.decodedResult();
    });
  };

  return {
    mul(point: Point, scalar: Uint8Array): Point {
      return pointFrom(
        'avm_grumpkin_mul',
        callBytes('avm_grumpkin_mul', encodeArgs([point.x, point.y, Buffer.from(scalar)])),
      );
    },
    add(a: Point, b: Point): Point {
      return pointFrom('avm_grumpkin_add', callBytes('avm_grumpkin_add', encodeArgs([a.x, a.y, b.x, b.y])));
    },
    get calls() {
      return calls;
    },
  };
}

// The installed backend. Same shape and same reasoning as `poseidon.ts`'s, including the refusal to
// fall back: see that file's header.
let installed: GrumpkinBackend | null = null;

export class GrumpkinNotInstalled extends Error {
  constructor() {
    super(
      'no grumpkin backend is installed. Call installGrumpkin(createAvmGrumpkin(reactor, …)) after ' +
        'instantiating avm.wasm. There is deliberately no fallback to @aztec/bb.js: a fallback ' +
        'would fetch 7.9 MB of proving stack and violate DD-11 on a page that looked fine.',
    );
    this.name = 'GrumpkinNotInstalled';
  }
}

export function installGrumpkin(backend: GrumpkinBackend): void {
  installed = backend;
}

export function grumpkinBackend(): GrumpkinBackend {
  if (!installed) throw new GrumpkinNotInstalled();
  return installed;
}

export function grumpkinInstalled(): boolean {
  return installed !== null;
}
