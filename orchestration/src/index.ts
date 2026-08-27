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

// M20 — Form A. Note what is NOT exported: nothing takes or returns a `SubmittedTx` except
// `executeExternallySettledTx`, and the simulator interface below it takes a `Tx`. DD-1 is an
// export-surface property as well as a runtime one — a consumer cannot hand provenance to
// anything that executes, because no executing export accepts it.
export {
  ProvenanceConsultedDuringExecution,
  externalTx,
  locallyExecutedTx,
  locallyOriginatedTx,
  sealProvenance,
  type ExternalTxProvenance,
  type LocalTxProvenance,
  type LocallyExecutedTxProvenance,
  type PrivateExecutionSummary,
  type PrivateTraceHandle,
  type ProvenanceSeal,
  type SubmittedTx,
  type TxProvenance,
} from './submitted_tx.ts';

// M21 — Form B. NOTE WHAT IS NOT HERE: no second execution entry point. Form B PRODUCES a
// `SubmittedTx<Tx>` and hands it to `executeExternallySettledTx` above, which is provenance-blind
// by construction, so the outcome vocabulary is one vocabulary — `processed` / `failed` — and not
// two. `e2e_form_b_local_tx_roundtrip` section 5 asserts it by running BOTH provenances through
// that one function and comparing the outcome shapes.
export {
  PRIVATE_SIMULATORS,
  originateLocalTx,
  publicOnlyPrivateExecution,
  summarisePrivateExecution,
  txFromTail,
} from './form_b.ts';

// M21 — OQ-1. §8.4: NO TYPE NAMED `AztecNode` IS EXPORTED HERE and nothing below is shaped like
// one. `AztecNode` at the anchor declares 62 methods; what Form B needs is one, and upstream
// itself says so with `Pick<AztecNode, 'findLeavesIndexes'>`.
export {
  ALLOWED_SURFACE,
  ResidentSettledReadSource,
  SETTLED_READ_TREES,
  SettledReadSourceSurfaceExceeded,
  strictSurface,
  type SettledLeafIndexSource,
} from './settled_read_source.ts';

export {
  TxIntakeError,
  phaseCallRequests,
  txFromBuffer,
  validateTxShape,
  type TxShape,
} from './tx_intake.ts';

export {
  classifyBoundaryError,
  executeExternallySettledTx,
  provenanceReadsDuring,
  type ExecuteOptions,
  type FormAProcessed,
  type FormAOutcome,
  type FormAOutcomeKind,
  type FormAFailed,
  type PublicTxSimulatorLike,
  FAILURE_NEEDLES,
  type FailureReason,
} from './form_a.ts';

export {
  computeFeePayerBalanceLeafSlot,
  defaultPublicSimulatorConfig,
  feeJuiceBalanceLeafSlot,
  feeJuiceBalanceStorageSlot,
  fundFeeJuice,
  type ResidentPublicDataTree,
} from './fee_juice.ts';

export { ResidentMerkleDb, type BlobCallable } from './resident_db.ts';

export {
  PATCH_REQUIRED_CONFIG_FIELDS,
  encodeForShippedModule,
  encodeForShippedModuleOnly,
} from './shipped_module_config.ts';

// M22 — block assembly. NOTE WHAT IS NOT HERE, AND WHY THE ONE THING THAT IS DOES NOT BREACH DD-9.
//
// `PublicProcessor` is NOT exported, and neither is `PublicProcessorFactory`, which does not exist
// any more: the vendored copy drops it, because its `protected createPublicTxSimulator` hard-
// defaults to `TelemetryCppPublicTxSimulator` with no flag to turn it off. That is the class DD-9
// is about.
//
// `createBlockProcessor` IS exported and it returns one. That is not the same thing and the
// difference is checkable rather than rhetorical: it takes the simulator as a REQUIRED positional
// argument, so there is no arrangement of arguments under which a consumer of this package gets a
// processor whose simulator came from a default — which is the property DD-9 names. Renaming a
// forbidden constructor would be an evasion; exporting one that cannot default is the opposite,
// and `test_public_processor_never_defaults_to_cpp` asserts the arity and the absence of a default
// rather than taking this paragraph's word for it.
export {
  BlockPartitionViolated,
  assembleBlock,
  createBlockProcessor,
  sealBlock,
  type AssembledBlock,
  type BlockAssemblyOptions,
  type FailedTxRecord,
  type SealOutcome,
  type SealRefusal,
} from './block_assembly.ts';

export {
  ANSWERING_METHODS,
  REFUSAL_REASONS,
  REFUSING_METHODS,
  RESIDENT_TREES,
  ResidentMerkleDbCannotAnswer,
  ResidentMerkleWriteOperations,
  ResidentSequentialInsertionResult,
  TREE_HEIGHTS,
  residentModuleHasArchive,
  type ResidentMerkleModule,
} from './resident_merkle_operations.ts';

export {
  REFUSING_CONTRACT_READS,
  ResidentContractsDB,
  ResidentContractsDbCannotAnswer,
  type PendingRegistration,
} from './resident_contracts_db.ts';

// M23 — the chain loop, the timer, and the facade.
//
// DD-4 IS AN EXPORT-SURFACE PROPERTY TOO. There is no export here that reads a wall clock: the
// clock is a constructor argument on `AvmChain` and `AvmRuntime`, and the three implementations
// re-exported from `chain_clock.ts` are UPSTREAM'S — `DateProvider`, `TestDateProvider` and
// `ManualDateProvider` from `@aztec/foundation/timer`. No `Clock` interface of ours is exported,
// because declaring one would be the parallel-type mistake the `TreeSnapshot` deliverable names.
//
// WHAT IS OURS AND EXPORTED: the three-method `BlockTicker` and its three implementations, the
// timestamp rule, the chain, the facade and §8.4's disclosure. `CHAIN-LOOP.md` records the
// enumeration that establishes that this is all of it.
export {
  DateProvider,
  DisabledTicker,
  ManualDateProvider,
  ManualTicker,
  RunningPromiseTicker,
  TestDateProvider,
  nextBlockTimestamp,
  type BlockTicker,
} from './chain_clock.ts';

export {
  AvmChain,
  ChainSealRefused,
  DEFAULT_BLOCK_PRODUCTION,
  type BlockProductionConfig,
  type ChainBlock,
  type ChainDeps,
  type ChainSubscription,
  type TraceEvent,
  type TxEvent,
} from './chain.ts';

export {
  DISCLOSURE_LINE,
  PINNED_PROTOCOL_VERSION,
  type Disclosure,
} from './disclosure.ts';

export {
  AvmRuntime,
  type AvmRuntimeDeps,
  type AvmRuntimeOptions,
  type ChainSnapshot,
  type SimulationResult,
  type TxReceipt,
} from './avm_runtime.ts';

// M26 — what makes two halves of one transaction ONE recording. The grammar and the joiner only:
// `orchestration` has no npm dependencies and cannot decode a `.ct`, so a consumer reads the
// records out of its containers with a reader and hands them here.
export {
  JOIN_EVENT_METADATA,
  JOIN_REASON,
  TraceJoinRefused,
  formatJoinRecord,
  joinRecord,
  joinRecordings,
  parseJoinRecord,
  privateTraceHandleFor,
  type HalfRecording,
  type JoinArm,
  type JoinRecord,
  type JoinedRecording,
  type TraceHalf,
} from './trace_join.ts';
