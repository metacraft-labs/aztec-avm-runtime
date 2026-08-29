// pinned_protocol_version.ts — the protocol version a live node is checked against.
//
// THE DECLARATION IS `pins.json`'s `live_chain.protocol_version`, not this file. This file carries
// the same two values as literals because the client must work in a browser, where reading a JSON
// file off the repository root is not a thing that happens. That makes it a WITNESS in the sense
// pins.json already has a category for: a tracked file that carries a pinned value as part of what
// it is, and is therefore REQUIRED to carry the right one rather than merely allowed to.
//
// `verify_client_uses_upstream_schema` asserts the agreement THREE ways on every run:
//
//   1. this file's literals equal `pins.json`'s `live_chain.protocol_version`
//   2. …and equal `protocolContractsHash` from `@aztec/protocol-contracts` at `npm.current`
//   3. …and equal `getVKTreeRoot()` from `@aztec/noir-protocol-circuits-types/vk-tree` at the same
//
// (2) and (3) are upstream's own producers: `yarn-project/aztec/src/cli/versioning.ts` at the `cpp`
// anchor builds exactly this pair, from exactly these two expressions, when it has no chain config.
// So the pin is re-derived from upstream rather than transcribed, and a bump that moves either
// value reddens before anything ships. A figure nobody re-derives rots.
//
// WHY ONLY TWO OF THE FIVE FIELDS. `ComponentsVersions` has five: `l1ChainId`, `l1RollupAddress`,
// `rollupVersion`, `l2ProtocolContractsHash`, `l2CircuitsVkTreeRoot`. The first three are
// properties of a DEPLOYMENT, and no deployment is pinned yet — see `pins.json` →
// `live_chain._comment`, which now carries both halves of that measurement: the five endpoints
// L0's implementation probed all fail, and the two L0's REVIEW found (dRPC's Aztec mainnet and
// testnet) answer, run nodeVersion 5.2.0, and advertise exactly the two values below. What stops
// them being pinned is not reachability: both are proxies that drop the `x-aztec-*` headers on the
// BATCH requests upstream's client always sends, so a pinned proxy would be an endpoint this
// repository's own version check cannot verify.
// A partial is upstream's own supported shape, not a weakening we invented: both
// `validatePartialComponentVersionsMatch` and `getVersioningResponseHandler` skip undefined fields
// by construction, and `getVersions(undefined)` returns this exact pair.
//
// WHAT THAT MEANS FOR THE GUARANTEE, and it is now a MEASUREMENT rather than a statement: a node on
// the WRONG L1 CHAIN would not be caught by this pin today, and a node running a DIFFERENT
// PROTOCOL — different protocol contracts, different circuit verification keys — would be. Aztec
// mainnet and Aztec testnet were both read on 2026-08-29 and their two PROTOCOL-level headers are
// identical to each other and to the pair below, while all three NETWORK-level headers differ; the
// figures are in `pins.json` → `live_chain.pin_discrimination_measured`. The second half is the one
// that decides whether replayed bytecode means anything. When an endpoint is pinned, the three
// network fields go into `pins.json` beside these two and this comment changes.

import type { ComponentsVersions } from '@aztec/stdlib/versioning';

/** The five fields `ComponentsVersions` has, in upstream's own order. Used to read headers back. */
export const COMPONENTS_VERSION_FIELDS = [
  'l1ChainId',
  'l1RollupAddress',
  'rollupVersion',
  'l2ProtocolContractsHash',
  'l2CircuitsVkTreeRoot',
] as const;

export type ComponentsVersionField = (typeof COMPONENTS_VERSION_FIELDS)[number];

/**
 * The pinned expectation. Mirrors `pins.json` → `live_chain.protocol_version`.
 *
 * `Partial<ComponentsVersions>` is upstream's type, and the three absent fields are absent on
 * purpose — see the header.
 */
export const PINNED_PROTOCOL_VERSION: Partial<ComponentsVersions> = {
  l2ProtocolContractsHash: '0x2c075866eafc88a1f6f9addc7e337c6e64e45d1cb7fd7c0d612ebcec72aab2ca',
  l2CircuitsVkTreeRoot: '0x2b3b6ea4412b9c8f6457a37f91a2870306f8641e07e16a49b68bda6f8bc02892',
};

/** The network this pin belongs to. `pins.json` says UNESTABLISHED and so does this. */
export const PINNED_NETWORK = 'UNESTABLISHED';
