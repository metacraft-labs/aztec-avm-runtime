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
// The DEFAULT value is `false`: step collection off, which is upstream's own default for the field
// and makes the patched module behave exactly as an unpatched one would.
//
// M29: THE VALUE IS NOW A CALLER'S CHOICE AND THE KEY SET IS NOT.
//
// Until M29 this file hard-coded `false` and spread it OVER the caller's config, so no caller could
// switch step collection on and the browser had no executed step stream to record — which is the
// whole of M27's fabricated-opcode gap on the input side. `encodeForShippedModuleOnly` takes
// `{ collectExecutionSteps }` now.
//
// What is deliberately NOT relaxed is the key SET. `patchFieldsFor` builds its object from
// `PATCH_REQUIRED_CONFIG_FIELDS`' own keys and asserts, at run time, that what it produced has
// exactly those keys — so this door cannot become a second, undeclared way to add a field to the
// encoding. That is the same discipline `encodingDifferences` enforces from the other end: the
// delta between the two encodings is computed from the bytes, and a second key would fail it. A
// value change does not move that delta — `config.collectExecutionSteps` is "present on the right
// only" whichever way it is set — which is why the assertion is on the keys and the check that
// guards it is unchanged.

import { AvmFastSimulationInputs, AvmTxHint, type PublicSimulatorConfig, serializeWithMessagePack } from '@aztec/stdlib/avm';
import { ProtocolContractsList } from '@aztec/protocol-contracts';
import type { GlobalVariables, Tx } from '@aztec/stdlib/tx';
import type { WorldStateRevision } from '@aztec/stdlib/world-state';

import { encodeFastSimulationInputs } from './avm_inputs.ts';

/** Every key the shipped module requires that upstream's `PublicSimulatorConfig` does not emit. */
export const PATCH_REQUIRED_CONFIG_FIELDS: Readonly<Record<string, boolean>> = {
  collectExecutionSteps: false,
};

/** What a caller may ask of the patch-required fields. One field, because there is one key. */
export interface ShippedModuleOptions {
  /**
   * Drive M9's `ExecutionObserverInterface` for this simulation.
   *
   * `true` makes the module populate `TxSimulationResult.execution_steps` and therefore
   * `avm_steps_count()` / `avm_steps_batch()`. It is off by default because it costs the observer's
   * measured overhead on every instruction and materialises a record per instruction, and a
   * transaction nobody is recording should not pay either.
   */
  readonly collectExecutionSteps?: boolean;
}

/**
 * The patch-required fields, with the values this caller asked for.
 *
 * **The key set is asserted, not assumed.** It is built from `PATCH_REQUIRED_CONFIG_FIELDS`' own
 * keys and compared against them afterwards, so this function cannot become a second way to add a
 * field to the encoding. The comparison is over sorted key lists rather than a count, because two
 * different keys have the same count.
 */
export function patchFieldsFor(options: ShippedModuleOptions = {}): Readonly<Record<string, boolean>> {
  const asked: Record<string, boolean> = { collectExecutionSteps: options.collectExecutionSteps ?? false };
  const out: Record<string, boolean> = {};
  for (const key of Object.keys(PATCH_REQUIRED_CONFIG_FIELDS)) {
    out[key] = asked[key] ?? PATCH_REQUIRED_CONFIG_FIELDS[key]!;
  }
  const declared = Object.keys(PATCH_REQUIRED_CONFIG_FIELDS).sort().join(',');
  const produced = Object.keys(out).sort().join(',');
  if (declared !== produced) {
    throw new Error(
      `patchFieldsFor produced the keys [${produced}] where PATCH_REQUIRED_CONFIG_FIELDS declares `
        + `[${declared}]. The encoding delta this runtime declares is exactly the declared set; a `
        + 'field added here rather than there would ride into the module unannounced.',
    );
  }
  return Object.freeze(out);
}

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
  options: ShippedModuleOptions = {},
): { upstream: Uint8Array; patched: Uint8Array } {
  const upstream = encodeFastSimulationInputs(tx, globalVariables, config, wsRevision);
  const txHint = AvmTxHint.fromTx(tx, globalVariables.gasFees);
  const patchedConfig = { ...config, ...patchFieldsFor(options), ...injectedConfigFields };
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
  options: ShippedModuleOptions = {},
): Uint8Array {
  return encodeForShippedModule(tx, globalVariables, config, wsRevision, {}, options).patched;
}
