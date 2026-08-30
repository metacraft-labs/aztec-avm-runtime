// replay_inputs.ts — the encoding, which is upstream's, plus the one key the shipped module needs.
//
// WHY THIS IS NOT `orchestration/src/avm_inputs.ts` REUSED, and it is a rejection with a
// measurement behind it rather than a preference. `replay/package.json` states it: this package is
// on `npm.current` (5.3.0-nightly.20260819, the line that corresponds to `anchors.cpp`) and
// `orchestration/` is on `npm.deletion_era` (5.0.0-nightly.20260626, frozen evidence). They have
// DIFFERENT `@aztec/stdlib` installs, and `serializeWithMessagePack` recognises an `Fr` by the class
// object of its OWN install — a value built in one and serialised by the other goes out as a plain
// object and the C++ side reads a field that is not there, or worse reads one that happens to
// decode. So the encoding is re-expressed here against this package's install, and the DERIVATION is
// still entirely upstream's: `AvmTxHint.fromTx`, `AvmFastSimulationInputs`,
// `serializeWithMessagePack`. Nothing here decides a field's layout, an endianness or a tag.
//
// THE ONE ADDED KEY, AND IT IS NOT OURS EITHER — it is DRIFT D14, recorded in
// `orchestration/src/shipped_module_config.ts` and reproduced here because the fact is about the
// ARTEFACT and not about that package. M9's execution-observer patch adds
// `bool collect_execution_steps` to the C++ `PublicSimulatorConfig`. In C++ that is additive; ON THE
// WIRE IT IS BREAKING, because msgpack decoding of the struct requires every declared field to be
// present. So the shipped module rejects upstream's own encoding with
//
//     avm_simulate failed with status 1: Missing field collectExecutionSteps
//
// The key set is `PATCH_REQUIRED_CONFIG_FIELDS`' own keys and nothing else, so this cannot become a
// second undeclared way to add a field to the encoding.
//
// AND THE THREE COLLECTION FLAGS L2 TURNS ON ARE UPSTREAM'S, NOT PATCHES.
// `collectHints` is the whole of route 3 — it is what makes the AVM report the world-state queries
// it made, which is how the state to seed is discovered rather than guessed. `collectStatistics`
// gives `total_instructions_executed`, which L3's step-count control compares the drained stream
// against. `collectPublicInputs` gives `publicTxEffect`, which is what
// `compareToPublishedEffects` holds up against the chain's own answer. All three are declared
// fields of upstream's `PublicSimulatorConfig` and default to `false`; asking for them is not a
// modification of anything.

import {
  AvmFastSimulationInputs,
  AvmTxHint,
  PublicSimulatorConfig,
  serializeWithMessagePack,
} from '@aztec/stdlib/avm';
import { ProtocolContractsList } from '@aztec/protocol-contracts';
import { WorldStateRevision } from '@aztec/stdlib/world-state';

import type { SettledTransaction } from './settled_transaction.ts';

/** Every key the shipped module requires that upstream's `PublicSimulatorConfig` does not emit. */
export const PATCH_REQUIRED_CONFIG_FIELDS: Readonly<Record<string, boolean>> = Object.freeze({
  collectExecutionSteps: false,
});

/**
 * The upstream collection flags a replay needs on, each with the deliverable that needs it.
 *
 * Named rather than spelled inline at the call site so that a check can assert the SET — a replay
 * that quietly stopped asking for `collectHints` would still run, still be green on a transaction
 * whose whole read set happens to be its write set, and hydrate nothing.
 */
export const REPLAY_COLLECTION_FLAGS: Readonly<Record<string, string>> = Object.freeze({
  collectHints: 'route 3: the AVM reports the world-state queries it made, which is how the state '
    + 'to seed is discovered instead of guessed',
  collectStatistics: 'total_instructions_executed, the AVM\'s own count, which L3 compares the '
    + 'drained step stream against',
  collectPublicInputs: 'publicTxEffect, which is what the replay is compared to the chain with',
});

/** The configuration a replay runs under. Upstream's `from`, so no default is restated here. */
export function replaySimulatorConfig(): Record<string, unknown> {
  const upstream = PublicSimulatorConfig.from({
    collectHints: true,
    collectStatistics: true,
    collectPublicInputs: true,
  });
  return { ...upstream, ...PATCH_REQUIRED_CONFIG_FIELDS, collectExecutionSteps: true };
}

/**
 * The bytes to hand the module for a settled transaction.
 *
 * `WorldStateRevision(0, blockNumber, true)` is the resident shape — fork 0, no IPC path, include
 * uncommitted — and the block number is the SETTLING block, which is what the transaction's own
 * `GlobalVariables` describe. Every other argument is read off the `SettledTransaction` rather than
 * reconstructed, so an input that disagreed with the fetch would be a type error and not a wrong
 * trace.
 */
export function encodeReplayInputs(settled: SettledTransaction): Uint8Array {
  const globalVariables = settled.blockData.header.globalVariables;
  const inputs = new AvmFastSimulationInputs(
    new WorldStateRevision(0, settled.l2BlockNumber, true),
    replaySimulatorConfig() as unknown as PublicSimulatorConfig,
    AvmTxHint.fromTx(settled.tx, globalVariables.gasFees),
    globalVariables,
    ProtocolContractsList,
  );
  return serializeWithMessagePack(inputs);
}
