// `aztec-avm-runtime/browser` — DD-5's REFERENCE ENTRY POINT.
//
// ===========================================================================================
// DD-5, IN ONE SENTENCE AND THEN IN ITS CONSEQUENCES.
// ===========================================================================================
//
// "The browser entry point is the reference, and the Node entry point is the superset. Every
// feature must work in the browser; Node may add *conveniences* (fs, process args), never
// *capabilities*."
//
// So this file is the definition of the runtime's surface, and `entry_node.ts` is obliged to
// re-export all of it. `verify_browser_entry_points_are_dd5_shaped` reads both export sets out of
// the BUILT bundles — not out of these sources — and requires the Node one to be a strict superset
// whose additions are each declared, by name, with a reason of the form "a convenience", and it
// requires the browser one to reach zero Node builtins.
//
// M23 SHIPPED ONE ENTRY POINT AND MARKED THIS DELIVERABLE UNMET rather than "met in spirit". This
// is the milestone that owes it, and M28 is the gate that keeps it.
//
// ===========================================================================================
// WHAT IS *NOT* HERE, AND WHY EACH ABSENCE IS A DECISION.
// ===========================================================================================
//
//   * NO FILESYSTEM. `openAvmRuntime` takes a URL and a `fetch`.
//   * NO PERSISTENCE. M23 settled this: the replay-log `exportSnapshot`/`importSnapshot` on the
//     facade is the agreed shape, and Anvil, Hardhat and Ganache all default to ephemeral.
//     `@aztec/kv-store`'s live browser store is `./sqlite-opfs` and is DD-9-neutral (it pulls
//     `@aztec/sqlite3mc-wasm`, which ships `vendor/jswasm/sqlite3.wasm` and no `.node`), so the
//     door is open and deliberately not walked through — see `CHAIN-LOOP.md` §6.
//   * NO PROVER, and there never will be one: §8.4, and `receipt.proving` is the literal `'none'`.
//   * NO `AztecNode` TYPE. §8.4 again, and `test_no_aztec_node_type_exported` asserts it.
//
// ===========================================================================================
// THE ONE THING A PAGE MUST DO IN ORDER, AND WHY IT IS NOT HIDDEN.
// ===========================================================================================
//
// `openAvmRuntime` installs the module's poseidon2 before returning, so an ordinary caller never
// sees the ordering. A caller who assembles the pieces by hand must install it before the first
// hash — and gets `Poseidon2NotInstalled` if they do not, because the alternative design (fall
// back to bb.js) would silently fetch 7.9 MB and violate DD-11 on a page that looked fine.

// ---- opening a runtime ----------------------------------------------------------------------
export { openAvmRuntime, type OpenOptions, type OpenedRuntime } from './runtime.ts';

// ---- the module ------------------------------------------------------------------------------
export {
  AvmEngineUnsupported,
  AvmToolchainRegression,
  AvmUnknownImport,
  PAGE_BYTES,
  Reactor,
  WASI_IMPORT_NAMES,
  assertExceptionSupport,
  compileAvmFromUrl,
  engineAcceptsLegacyEh,
  engineAcceptsTryTable,
  instantiateAvm,
  memoryBytes,
  readMemoryImport,
  sectionIds,
  type BrowserWasi,
  type CompiledAvm,
  type InstantiateOptions,
  type MemoryImport,
  type ReactorExports,
} from './loader.ts';

export {
  WASI_ESUCCESS,
  WasiProcExit,
  createBrowserWasi,
  type BrowserWasiOptions,
} from './wasi.ts';

// ---- DD-11: poseidon2 from the module the page already has -----------------------------------
export {
  POSEIDON2_EXPORTS,
  POSEIDON2_STATE_WIDTH,
  Poseidon2NotExported,
  Poseidon2NotInstalled,
  Poseidon2ResultUnreadable,
  createAvmPoseidon2,
  installPoseidon2,
  moduleHasPoseidon2,
  poseidon2Backend,
  poseidon2Installed,
  type Poseidon2Backend,
} from './poseidon.ts';

export {
  GRUMPKIN_EXPORTS,
  GrumpkinNotExported,
  GrumpkinNotInstalled,
  GrumpkinResultUnreadable,
  createAvmGrumpkin,
  grumpkinBackend,
  grumpkinInstalled,
  installGrumpkin,
  moduleHasGrumpkin,
  type GrumpkinBackend,
} from './grumpkin.ts';

// ---- the runtime's own surface, unchanged from M23's ------------------------------------------
//
// Re-exported rather than re-declared: `orchestration/src/index.ts` is where DD-9 is a property of
// the export surface, and a browser entry point that re-declared any of it would be a second place
// for that property to be false.
export {
  AVM_CONFIGURATIONS,
  AvmChain,
  AvmRuntime,
  ChainSealRefused,
  DEFAULT_BLOCK_PRODUCTION,
  DISCLOSURE_LINE,
  DateProvider,
  DisabledTicker,
  ForkCheckpoint,
  JOIN_EVENT_METADATA,
  JOIN_REASON,
  ManualDateProvider,
  ManualTicker,
  NativeAvmPathRefused,
  PINNED_PROTOCOL_VERSION,
  ProvenanceConsultedDuringExecution,
  ResidentContractsDB,
  ResidentMerkleDb,
  ResidentMerkleWriteOperations,
  RunningPromiseTicker,
  TestDateProvider,
  TraceJoinRefused,
  TxIntakeError,
  WASM_AVM,
  WasmAvmPublicTxSimulator,
  assembleBlock,
  configurationByName,
  createBlockProcessor,
  defaultConfiguration,
  externalTx,
  fundFeeJuice,
  joinRecord,
  joinRecordings,
  locallyOriginatedTx,
  nextBlockTimestamp,
  reachesNativeAddon,
  residentModuleHasArchive,
  sealBlock,
  txFromBuffer,
  validateTxShape,
  type AssembledBlock,
  type AvmConfiguration,
  type AvmRuntimeDeps,
  type AvmRuntimeOptions,
  type BlockProductionConfig,
  type BlockTicker,
  type ChainBlock,
  type ChainSnapshot,
  type Disclosure,
  type JoinRecord,
  type JoinedRecording,
  type SimulationResult,
  type SubmittedTx,
  type TraceEvent,
  type TxEvent,
  type TxProvenance,
  type TxReceipt,
} from '../../orchestration/src/index.ts';

// ---- the `.ct` writer ------------------------------------------------------------------------
//
// `ct-host` has NO dependencies and `ct_writer.wasm` declares ZERO wasm imports, so the same host
// code runs here and in Node — which `ct-host/package.json` records as the reason DD-7 chose a raw
// C ABI over wasm-bindgen. This is where that pays.
export {
  CtWriter,
  ContractSourceMap,
  RUNG_SOURCE,
  WRITER_PATH_A_PURE_RUST,
  instantiateCtWriter,
  resolveTracingConfig,
  rungFor,
  type CtRecording,
  type MappingRung,
  type StepEvent,
} from '../../ct-host/src/index.ts';

export {
  ExecutedStepsUnavailable,
  STEP_PRODUCER,
  STEP_PRODUCER_METADATA,
  fetchCtWriter,
  recordAndDownload,
  type BrowserRecording,
} from './ct_download.ts';

// ---- M29: the executed step stream -------------------------------------------------------------
//
// The drain itself is `node-host/src/steps.ts` — reused, not re-implemented; every import in that
// file is an `import type`, so it carries no runtime dependency and is browser-safe as written.
export {
  DEFAULT_STEP_BATCH,
  ExecutedStepCollector,
  INSTRUCTIONS_EXECUTED_STAT,
  formatExecutedStep,
  type ExecutedTransaction,
  type ExecutionStep,
} from './executed_steps.ts';
