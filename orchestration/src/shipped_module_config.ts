// shipped_module_config.ts — the ONE key our encoding adds, and why it is not in `avm_inputs.ts`.
//
// `avm_inputs.ts` claims "nothing here decides a field's layout, an endianness or a tag", and that
// claim is worth keeping true. This module is the single named exception, kept separate so that a
// reader of the encoder does not have to be told to look elsewhere for a caveat.
//
// DRIFT D14. M9's execution-observer patch adds `bool collect_execution_steps` to the C++
// `PublicSimulatorConfig`. In C++ that is additive — the field has a default and every existing
// construction still compiles. ON THE WIRE IT IS BREAKING: msgpack decoding of the struct requires
// every declared field to be present, so the patched module rejects upstream's own encoding with
//
//     avm_simulate failed with status 1: Missing field collectExecutionSteps
//
// which is exactly what a first Form A run against the shipped module produces. Nothing caught
// this when the patch was written because the encoder and the decoder were the same build —
// D12's shape, and D14 is its second instance.
//
// SO THE SHIPPED MODULE IS NOT UPSTREAM-ENCODING-COMPATIBLE, and pretending otherwise by quietly
// adding the key inside the encoder would hide a real property of the artefact we ship. The
// discipline here is `diffsim`'s, which met this first: the extra keys are a named constant, the
// two encodings are produced side by side, and the DELTA IS COMPUTED from the bytes rather than
// asserted from the list — so a second, unnoticed key would fail the comparison instead of riding
// along. `e2e_form_a_external_tx_roundtrip` Part 8 is that comparison: it decodes both
// encodings, walks them recursively, requires the whole difference to be this one declared
// key, and injects a second key through `injectedConfigFields` to prove the walk can fail.
// An earlier revision of this comment named a `verify_form_a_encoding_delta_is_one_named_key`
// that did not exist, so nothing called `encodeForShippedModule` at all and the discipline
// above was stated rather than delivered.
//
// The value is `false`: step collection off, which is upstream's own default for the field and
// makes the patched module behave exactly as an unpatched one would.

import { AvmFastSimulationInputs, AvmTxHint, type PublicSimulatorConfig, serializeWithMessagePack } from '@aztec/stdlib/avm';
import { ProtocolContractsList } from '@aztec/protocol-contracts';
import type { GlobalVariables, Tx } from '@aztec/stdlib/tx';
import type { WorldStateRevision } from '@aztec/stdlib/world-state';

import { encodeFastSimulationInputs } from './avm_inputs.ts';

/** Every key the shipped module requires that upstream's `PublicSimulatorConfig` does not emit. */
export const PATCH_REQUIRED_CONFIG_FIELDS: Readonly<Record<string, boolean>> = {
  collectExecutionSteps: false,
};

/**
 * Upstream's encoding, and the shipped module's, side by side.
 *
 * `injectedConfigFields` exists for the fault injection that proves the delta comparison can fail;
 * it is empty in every real call.
 */
export function encodeForShippedModule(
  tx: Tx,
  globalVariables: GlobalVariables,
  config: PublicSimulatorConfig,
  wsRevision: WorldStateRevision,
  injectedConfigFields: Record<string, boolean> = {},
): { upstream: Uint8Array; patched: Uint8Array } {
  const upstream = encodeFastSimulationInputs(tx, globalVariables, config, wsRevision);
  const txHint = AvmTxHint.fromTx(tx, globalVariables.gasFees);
  const patchedConfig = { ...config, ...PATCH_REQUIRED_CONFIG_FIELDS, ...injectedConfigFields };
  const inputs = new AvmFastSimulationInputs(
    wsRevision,
    patchedConfig as unknown as PublicSimulatorConfig,
    txHint,
    globalVariables,
    ProtocolContractsList,
  );
  return { upstream, patched: serializeWithMessagePack(inputs) };
}

/** The bytes to hand the shipped module. */
export function encodeForShippedModuleOnly(
  tx: Tx,
  globalVariables: GlobalVariables,
  config: PublicSimulatorConfig,
  wsRevision: WorldStateRevision,
): Uint8Array {
  return encodeForShippedModule(tx, globalVariables, config, wsRevision).patched;
}
