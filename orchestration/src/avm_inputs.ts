// avm_inputs.ts — the encoder, which is upstream's.
//
// This module exists to make one point checkable rather than to add behaviour: the bytes that
// cross into `avm.wasm` are produced by Aztec's own TypeScript, on Aztec's own schema, by the
// same call `CppPublicTxSimulator` makes. Nothing here decides a field's layout, an endianness
// or a tag. If it did, this runtime would own the drift of a wire format that has a C++ side we
// do not control — which is the failure the whole campaign is shaped to avoid.
//
// The chain, entirely inside @aztec/stdlib:
//
//   AvmTxHint.fromTx(tx, gasFees)
//     -> new AvmFastSimulationInputs(wsRevision, config, txHint, globals, protocolContracts)
//        -> .serializeWithMessagePack()          [dest/avm/message_pack.js]
//
// `serializeWithMessagePack` registers msgpackr extensions for `Fr`, `Fq`, `AztecAddress`,
// `Point` and `EthAddress` so that a field element goes out as the 32-byte big-endian `bin` the
// C++ side reads, and encodes with `useRecords: false` so the result is plain MessagePack maps
// rather than msgpackr's record format. REACTOR-ABI.md's enumeration of the 42 crossed types
// describes the far side of exactly this.

import {
  AvmFastSimulationInputs,
  AvmTxHint,
  type PublicSimulatorConfig,
  PublicTxResult,
  deserializeFromMessagePack,
} from '@aztec/stdlib/avm';
import { ProtocolContractsList } from '@aztec/protocol-contracts';
import type { GlobalVariables, Tx } from '@aztec/stdlib/tx';
import { WorldStateRevision } from '@aztec/stdlib/world-state';

/**
 * The world-state revision that crosses the boundary.
 *
 * CORRECTED IN M18's REVIEW. An earlier revision of this comment said upstream reads a
 * `WorldStateRevisionWithHandle`, asserts it carries a native handle and calls
 * `.toWorldStateRevision()` to strip it before serialising. Neither of those names exists
 * anywhere in the fork — at the TypeScript anchor, at the C++ anchor, or at HEAD — and the
 * paragraph described code that was never written.
 *
 * What upstream actually does, at `cpp_public_tx_simulator.ts:62-63`, is read a plain
 * `WorldStateRevision` — `(forkId, blockNumber, includeUncommitted)`, no pointer in it — with
 * `this.merkleTree.getRevision()`, and separately read an IPC PATH STRING with `getIpcPath()`,
 * which it passes to `avmSimulate` as its own argument rather than inside the payload. So the
 * revision that crosses is already handle-free upstream.
 *
 * Under the RESIDENT shape there is no IPC path either: the world state the module reads is the
 * one inside the module, named by the `merkleDb` argument to `avm_simulate`. The revision is
 * still a field of upstream's input schema, so it is still supplied, and this is where it comes
 * from.
 */
export function residentWorldStateRevision(blockNumber: number): WorldStateRevision {
  return new WorldStateRevision(0, blockNumber, true);
}

/**
 * Encode a transaction the way upstream encodes it. Every argument is upstream's type and the
 * only statement this function makes of its own is the ORDER, which is upstream's constructor's.
 */
export function encodeFastSimulationInputs(
  tx: Tx,
  globalVariables: GlobalVariables,
  config: PublicSimulatorConfig,
  wsRevision: WorldStateRevision,
): Uint8Array {
  const txHint = AvmTxHint.fromTx(tx, globalVariables.gasFees);
  const inputs = new AvmFastSimulationInputs(
    wsRevision,
    config,
    txHint,
    globalVariables,
    ProtocolContractsList,
  );
  return inputs.serializeWithMessagePack();
}

/**
 * Decode what the module returned into upstream's `PublicTxResult`.
 *
 * Two decoders exist in this repository and they are not interchangeable, which is worth saying
 * because using the wrong one would produce a plausible object:
 *
 *   * `node-host/src/msgpack.ts` decodes to `MsgpackValue` — plain JS with `Uint8Array` for
 *     `bin`. It is dependency-free and it is what the transcript checks compare, because a
 *     transcript's job is to be byte-faithful.
 *   * `deserializeFromMessagePack` from @aztec/stdlib/avm decodes THROUGH the registered
 *     extensions, so a 32-byte `bin` comes back as an `Fr` and an address as an `AztecAddress`.
 *     `PublicTxResult.fromPlainObject` needs that, and this is the path a caller who wants
 *     upstream's types must take.
 */
export function decodePublicTxResult(resultBytes: Uint8Array): PublicTxResult {
  const plain: object = deserializeFromMessagePack(Buffer.from(resultBytes));
  return PublicTxResult.fromPlainObject(plain);
}
