// The substitute for `@aztec/foundation/dest/crypto/grumpkin/index.js`.
//
// THE SECOND ROUTE FROM A PUBLIC-ONLY PAGE TO THE PROVING WASM, AND IT WAS FOUND THE HARD WAY.
//
// With poseidon2 coming out of `avm.wasm`, the public-only page STILL fetched
// `chunks/barretenberg-*.js` and its 7.9 MB data: URL — in the browser's own network log, which is
// the only reason it was found rather than reasoned about. The caller is `@aztec/stdlib`'s address
// derivation:
//
//     computeAddress(publicKeys, partialAddress)                   keys/derivation.js:59
//       = Grumpkin.add(Grumpkin.mul(G, preaddress), publicKeys.ivpkM)
//
// A contract's address is a commitment to its class, its salt and its public keys, so every page
// that registers a contract computes one — which is every page that executes a transaction against
// a contract. Two curve operations, and without them the page downloads a proving system.
//
// THE LESSON IS THE CAMPAIGN'S OWN, ONE LEVEL UP. "An absence claim is only as wide as the
// spellings you enumerated." The first measurement enumerated `poseidon2Hash`'s call sites, found
// four, fixed all four, and was CORRECT — and the claim it was supporting was about the proving
// wasm, not about poseidon. Grumpkin was never on the list because the Form A run that produced
// the list never built a contract instance. What closed it was not a better argument but a
// different instrument: the browser's own request log, which does not care which spellings anybody
// thought of.
//
// FIVE EXPORTS UPSTREAM, AND THIS FILE HAS THE SAME FIVE.
//
//   mul, add                 -> `avm.wasm`'s `avm_grumpkin_mul` / `avm_grumpkin_add`, whose C++ is
//                               `bbapi_ecc.cpp`'s line for line, on-curve checks included.
//   batchMul                 -> `mul` in a loop. Upstream's own implementation is the same loop,
//                               inside the wasm (`GrumpkinBatchMul::execute`); doing it here costs
//                               one crossing per point and is used by nothing in this graph.
//   getRandomFr              -> `Fr.random()`, which is `@aztec/foundation`'s own and does not
//                               reach bb.js on the browser branch.
//   reduce512BufferToFr      -> THROWS, and see below.
//
// `reduce512BufferToFr` REDUCES A 512-BIT BUFFER MOD THE FIELD, and it has exactly one caller in
// this graph: `deriveKeys`, which derives a SECRET key. This runtime has no private half —
// `JOIN-SHAPE.md` §6 records why — and a page that reached it would be deriving keys it has no use
// for. A throw naming the caller is better than a wrong reduction, and better than a silent
// 7.9 MB download to do it right.

import { Fr } from '@aztec/foundation/curves/bn254';
import { Point } from '@aztec/foundation/curves/grumpkin';

import { grumpkinBackend } from './grumpkin.ts';

/** The generator, byte for byte from the module this replaces. */
const GENERATOR_BYTES = new Uint8Array([
  // x = 1
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
  // y
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xcf, 0x13, 0x5e, 0x75, 0x06, 0xa4, 0x5d, 0x63,
  0x2d, 0x27, 0x0d, 0x45, 0xf1, 0x18, 0x12, 0x94, 0x83, 0x3f, 0xc4, 0x8d, 0x82, 0x3f, 0x27, 0x2c,
]);

/**
 * Grumpkin elliptic curve operations.
 */
export class Grumpkin {
  static generator: Point = Point.fromBuffer(Buffer.from(GENERATOR_BYTES));

  /**
   * Multiplies a point by a scalar (adds the point `scalar` amount of times).
   * @param point - Point to multiply.
   * @param scalar - Scalar to multiply by.
   * @returns Result of the multiplication.
   */
  static mul(point: Point, scalar: { toBuffer(): Buffer }): Promise<Point> {
    return Promise.resolve(grumpkinBackend().mul(point, scalar.toBuffer()));
  }

  /**
   * Add two points.
   * @param a - Point a in the addition
   * @param b - Point b to add to a
   * @returns Result of the addition.
   */
  static add(a: Point, b: Point): Promise<Point> {
    return Promise.resolve(grumpkinBackend().add(a, b));
  }

  /**
   * Multiplies a set of points by a scalar.
   * @param points - Points to multiply.
   * @param scalar - Scalar to multiply by.
   * @returns Points multiplied by the scalar.
   */
  static batchMul(points: Point[], scalar: { toBuffer(): Buffer }): Promise<Point[]> {
    const s = scalar.toBuffer();
    const backend = grumpkinBackend();
    return Promise.resolve(points.map((p) => backend.mul(p, s)));
  }

  /**
   * Gets a random field element.
   * @returns Random field element.
   */
  static getRandomFr(): Promise<Fr> {
    return Promise.resolve(Fr.random());
  }

  /**
   * Converts a 512 bits long buffer to a field.
   *
   * NOT AVAILABLE, deliberately. Its one caller in this graph is `deriveKeys`, which derives a
   * SECRET key, and this runtime has no private half. See the file header.
   */
  static reduce512BufferToFr(_uint512Buf: Buffer): Promise<Fr> {
    return Promise.reject(
      new Error(
        'Grumpkin.reduce512BufferToFr is not available in the browser build. Its only caller here ' +
          'is deriveKeys, which derives a SECRET key; this runtime has no private half (JOIN-SHAPE.md ' +
          '§6) and a page that reached it would be deriving keys it cannot use. The alternative — ' +
          'routing it through @aztec/bb.js — would fetch 7.9 MB of proving stack and break DD-11.',
      ),
    );
  }
}
