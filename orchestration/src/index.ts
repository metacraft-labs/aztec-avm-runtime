// index.ts — the public export surface, and what is deliberately NOT in it.
//
// DD-9: "the upstream `PublicProcessor` constructor is never a public export of ours, since
// `createPublicTxSimulator` hard-defaults to the C++ path and is `protected`."
//
// Re-derived from the fork at 3a68d68ac2 rather than restated, because the deliverable's wording
// compresses two different seams into one name and only one of them is `protected`:
//
//   * `PublicProcessorFactory.createPublicTxSimulator` — public_processor.ts:102-116 — IS a
//     `protected` method and DOES hard-default to `TelemetryCppPublicTxSimulator`. It takes no
//     flag; C++ is unconditional. It is an override seam and NOTHING IN THE TREE OVERRIDES IT:
//     `extends PublicProcessorFactory` has zero hits at the anchor. So M18's "Aztec built it to
//     run two AVM implementations side by side" is not what this seam's history shows — we would
//     be its first user. The seam Aztec built for running two implementations side by side is
//     `PublicTxSimulationTester`'s `simulatorFactory` and `CppVsTsPublicTxSimulator`, in the
//     test fixtures. Using a `protected` method as an override point is still using it as
//     intended; the correction is to the sentence, not to the decision.
//   * `createPublicTxSimulatorForBlockBuilding` — public_tx_simulator/factories.ts:16-44 — is a
//     FREE exported function, not protected, and it is the production selection point: its one
//     call site is `validator-client/src/checkpoint_builder.ts:247`. It also hard-defaults to
//     `TelemetryCppPublicTxSimulator`, with one branch, on `DUMP_AVM_INPUTS_TO_DIR`, to a
//     dumping subclass of the same thing.
//
// And a third fact the deliverable does not mention, which is what makes DD-9 satisfiable
// without a subclass at all: `PublicProcessor`'s constructor takes `publicTxSimulator` as its
// FOURTH POSITIONAL ARGUMENT, typed to `PublicTxSimulatorInterface`. Injection, not inheritance.
// The constructor is public and exported upstream; what DD-9 forbids is OUR re-exporting it, so
// that no consumer of this package can construct a processor whose simulator came from a
// default.
//
// Hence: this file exports the interface, the wasm implementation, the named configurations, the
// copied checkpoint and the telemetry replacement. It exports NO factory, NO `PublicProcessor`
// and NO re-export of anything from `@aztec/native`. `test_public_processor_never_defaults_to_cpp`
// asserts that against this file and against the import graph, in both directions.

export { ForkCheckpoint } from './fork_checkpoint.ts';

export {
  Attributes,
  Metrics,
  NoopTelemetryClient,
  createUpDownCounterWithDefault,
  getTelemetryClient,
  initTelemetryClient,
  trackSpan,
  type TelemetryClient,
} from './telemetry.ts';

export {
  AVM_CONFIGURATIONS,
  AVM_IMPLEMENTATIONS,
  DIFFERENTIAL_TS_VS_NATIVE_CPP,
  DIFFERENTIAL_WASM_VS_NATIVE_CPP,
  NATIVE_CPP_AVM,
  TYPESCRIPT_INTERPRETER,
  WASM_AVM,
  configurationByName,
  defaultConfiguration,
  fromUpstreamUseCppSimulator,
  isDifferential,
  reachesNativeAddon,
  type AvmConfiguration,
  type AvmImplementation,
} from './simulator_selection.ts';

export {
  NativeAvmPathRefused,
  WasmAvmPublicTxSimulator,
  type AvmBoundary,
  type ResidentDbHandles,
  type WasmAvmPublicTxSimulatorOptions,
} from './wasm_avm_public_tx_simulator.ts';

export {
  decodePublicTxResult,
  encodeFastSimulationInputs,
  residentWorldStateRevision,
} from './avm_inputs.ts';
